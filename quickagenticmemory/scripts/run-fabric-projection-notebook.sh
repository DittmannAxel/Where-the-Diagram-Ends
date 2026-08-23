#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
notebook_id="${QAM_FABRIC_NOTEBOOK_ID:-}"
lakehouse_id="${QAM_FABRIC_LAKEHOUSE_ID:-}"
staging_path=""
projection_id=""
commit_sha=""

usage() {
  printf '%s\n' \
    'Usage: run-fabric-projection-notebook.sh [required options]' \
    '' \
    'Required:' \
    '  --workspace-id UUID' \
    '  --notebook-id UUID' \
    '  --lakehouse-id UUID' \
    '  --staging-path Files/qam-staging/HASH/COMMIT' \
    '  --projection-id urn:qam:projection:HASH' \
    '  --commit-sha FULL_SHA' \
    '' \
    'Runs the existing checked/reviewed PySpark notebook with the release Job Scheduler' \
    'API (beta=false), pins polling to its exact same-origin job instance URL, and' \
    'requires a structured success exit value for the requested projection.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --notebook-id) notebook_id="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-id) lakehouse_id="${2:?missing value for $1}"; shift 2 ;;
    --staging-path) staging_path="${2:?missing value for $1}"; shift 2 ;;
    --projection-id) projection_id="${2:?missing value for $1}"; shift 2 ;;
    --commit-sha) commit_sha="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

for pair in \
  "${workspace_id}:Fabric workspace ID" \
  "${notebook_id}:Fabric Notebook ID" \
  "${lakehouse_id}:Fabric Lakehouse ID"; do
  qam_validate_uuid "${pair%%:*}" "${pair#*:}"
done
printf '%s' "${projection_id}" | grep -Eq '^urn:qam:projection:[0-9a-f]{64}$' \
  || qam_fail "projection ID must be an immutable QAM SHA-256 URN"
printf '%s' "${commit_sha}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' \
  || qam_fail "commit SHA must be a lowercase full Git object ID"
expected_staging_path="Files/qam-staging/${projection_id##*:}/${commit_sha}"
[ "${staging_path}" = "${expected_staging_path}" ] \
  || qam_fail "staging path must match the requested projection and commit"

qam_require_azure_login
qam_require_command curl
qam_require_command jq
access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

request_file="$(mktemp)"
response_file="$(mktemp)"
headers_file="$(mktemp)"
trap 'rm -f "${request_file}" "${response_file}" "${headers_file}"' EXIT
jq -n \
  --arg workspace_id "${workspace_id}" \
  --arg lakehouse_id "${lakehouse_id}" \
  --arg staging_path "${staging_path}" \
  --arg projection_id "${projection_id}" \
  --arg commit_sha "${commit_sha}" \
  '{
    parameters: [
      {name: "workspace_id", value: $workspace_id, type: "Text"},
      {name: "lakehouse_id", value: $lakehouse_id, type: "Text"},
      {name: "staging_path", value: $staging_path, type: "Text"},
      {name: "expected_projection_id", value: $projection_id, type: "Text"},
      {name: "expected_commit_sha", value: $commit_sha, type: "Text"}
    ],
    executionData: {
      compute: "Spark",
      computeConfiguration: {
        defaultLakehouse: {
          referenceType: "ById",
          itemId: $lakehouse_id,
          workspaceId: $workspace_id
        }
      }
    }
  }' > "${request_file}"

run_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/notebooks/${notebook_id}/jobs/execute/instances?beta=false"
status="$(curl \
  --silent \
  --show-error \
  --request POST \
  --header "Authorization: Bearer ${access_token}" \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data-binary "@${request_file}" \
  --dump-header "${headers_file}" \
  --output "${response_file}" \
  --write-out '%{http_code}' \
  "${run_url}")"
[ "${status}" = "202" ] || {
  sed -n '1,40p' "${response_file}" >&2
  qam_fail "starting Fabric Notebook job returned HTTP ${status}"
}
operation_url="$(awk 'tolower($1) == "location:" {$1=""; sub(/^ /, ""); gsub("\\r", ""); print}' "${headers_file}" | tail -1)"
[ -n "${operation_url}" ] || qam_fail "Fabric Notebook job returned no Location header"
qam_validate_fabric_notebook_job_url "${operation_url}" "${workspace_id}" "${notebook_id}"

for _ in $(seq 1 90); do
  retry_after="$(awk 'tolower($1) == "retry-after:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
  if ! printf '%s' "${retry_after:-10}" | grep -Eq '^[0-9]+$'; then retry_after=10; fi
  if [ "${retry_after:-10}" -gt 60 ]; then retry_after=60; fi
  sleep "${retry_after:-10}"
  : > "${headers_file}"
  : > "${response_file}"
  status="$(curl \
    --silent \
    --show-error \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Accept: application/json' \
    --dump-header "${headers_file}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${operation_url}")"
  [ "${status}" = "200" ] || qam_fail "polling Fabric Notebook job returned HTTP ${status}"
  job_status="$(jq -r '.status // empty' "${response_file}")"
  case "${job_status}" in
    Completed)
      job_id="${operation_url##*/}"
      qam_validate_uuid "${job_id}" "Fabric Notebook job instance ID"
      details_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/notebooks/${notebook_id}/jobs/execute/instances/${job_id}?beta=true"
      : > "${headers_file}"
      : > "${response_file}"
      status="$(curl \
        --silent \
        --show-error \
        --header "Authorization: Bearer ${access_token}" \
        --header 'Accept: application/json' \
        --dump-header "${headers_file}" \
        --output "${response_file}" \
        --write-out '%{http_code}' \
        "${details_url}")"
      [ "${status}" = '200' ] \
        || qam_fail "reading the completed Fabric Notebook exit value returned HTTP ${status}"
      jq -e \
        --arg job_id "${job_id}" \
        --arg projection "${projection_id}" \
        --arg commit "${commit_sha}" \
        '.id == $job_id and .status == "Completed" and
        ((.exitValue // .properties.exitValue) | fromjson |
          .status == "success" and
          .projectionId == $projection and
          .commitSha == $commit and
          (.nodeCount | type == "number") and .nodeCount > 0 and .nodeCount == (.nodeCount | floor) and
          (.edgeCount | type == "number") and .edgeCount >= 0 and .edgeCount == (.edgeCount | floor))' \
        "${response_file}" >/dev/null \
        || qam_fail "Fabric Notebook completed without the expected QAM success contract"
      jq -c '(.exitValue // .properties.exitValue) | fromjson' "${response_file}"
      exit 0
      ;;
    Failed | Cancelled | Deduped)
      jq '{id, status, failureReason}' "${response_file}" >&2
      qam_fail "Fabric Notebook job ended with status ${job_status}"
      ;;
    NotStarted | InProgress) ;;
    *) qam_fail "Fabric Notebook job returned unknown status: ${job_status}" ;;
  esac
done

qam_fail "Fabric Notebook job did not complete within the polling window"
