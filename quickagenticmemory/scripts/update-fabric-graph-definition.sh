#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
graph_model_id="${QAM_FABRIC_GRAPH_MODEL_ID:-}"
definition_dir=""
dry_run="false"
operation_id=""

usage() {
  printf '%s\n' \
    'Usage: update-fabric-graph-definition.sh [required options]' \
    '' \
    'Required:' \
    '  --workspace-id UUID' \
    '  --graph-model-id UUID' \
    '  --definition-dir DIRECTORY' \
    '' \
    'Optional:' \
    '  --dry-run        Validate the exported definition without calling Fabric' \
    '' \
    'This updates an existing Preview Graph Model. It does not create OneLake' \
    'Delta tables, design mappings, or create the Graph Model itself.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-id) graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --definition-dir) definition_dir="${2:?missing value for $1}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${graph_model_id}" ] || qam_fail "--graph-model-id is required"
[ -n "${definition_dir}" ] || qam_fail "--definition-dir is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${graph_model_id}" "Fabric Graph Model ID"
[ -d "${definition_dir}" ] || qam_fail "definition directory not found: ${definition_dir}"
qam_require_command jq
qam_require_command base64

required_parts='dataSources.json graphDefinition.json graphType.json stylingConfiguration.json'
for part in ${required_parts}; do
  [ -f "${definition_dir}/${part}" ] || qam_fail "required definition part missing: ${part}"
  jq empty "${definition_dir}/${part}" || qam_fail "invalid JSON in definition part: ${part}"
done
if [ -f "${definition_dir}/.platform" ]; then
  jq empty "${definition_dir}/.platform" || qam_fail "invalid JSON in definition part: .platform"
fi

request_file="$(mktemp)"
response_file="$(mktemp)"
headers_file="$(mktemp)"
trap 'rm -f "${request_file}" "${response_file}" "${headers_file}"' EXIT

parts='[]'
for part in ${required_parts}; do
  payload="$(base64 < "${definition_dir}/${part}" | tr -d '\r\n')"
  parts="$(jq \
    --arg path "${part}" \
    --arg payload "${payload}" \
    '. + [{path: $path, payload: $payload, payloadType: "InlineBase64"}]' \
    <<< "${parts}")"
done
if [ -f "${definition_dir}/.platform" ]; then
  payload="$(base64 < "${definition_dir}/.platform" | tr -d '\r\n')"
  parts="$(jq \
    --arg payload "${payload}" \
    '. + [{path: ".platform", payload: $payload, payloadType: "InlineBase64"}]' \
    <<< "${parts}")"
fi
jq -n --argjson parts "${parts}" \
  '{definition: {format: "json", parts: $parts}}' > "${request_file}"

if [ "${dry_run}" = "true" ]; then
  qam_info "validated an exported definition with $(jq '.definition.parts | length' "${request_file}") part(s)"
  exit 0
fi

qam_require_azure_login
qam_require_command curl
access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

update_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/graphModels/${graph_model_id}/updateDefinition?updateMetadata=false"

attempt=1
while [ "${attempt}" -le 5 ]; do
  : > "${headers_file}"
  : > "${response_file}"
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
    "${update_url}")"
  if [ "${status}" != "429" ]; then
    break
  fi
  retry_after="$(awk 'tolower($1) == "retry-after:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
  sleep "${retry_after:-10}"
  attempt=$((attempt + 1))
done

case "${status}" in
  200 | 201 | 204)
    qam_info "Fabric Graph Model definition updated"
    exit 0
    ;;
  202)
    operation_id="$(awk 'tolower($1) == "x-ms-operation-id:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
    if [ -n "${operation_id}" ]; then
      qam_validate_uuid "${operation_id}" "Fabric operation ID"
      operation_url="https://api.fabric.microsoft.com/v1/operations/${operation_id}"
    else
      operation_url="$(awk 'tolower($1) == "location:" {$1=""; sub(/^ /, ""); gsub("\\r", ""); print}' "${headers_file}" | tail -1)"
      [ -n "${operation_url}" ] || qam_fail "Fabric returned 202 without an operation identifier"
      qam_validate_fabric_operation_url "${operation_url}"
    fi
    ;;
  *)
    sed -n '1,40p' "${response_file}" >&2
    qam_fail "Fabric definition update returned HTTP ${status}"
    ;;
esac

for _ in $(seq 1 30); do
  retry_after="$(awk 'tolower($1) == "retry-after:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
  sleep "${retry_after:-5}"
  : > "${headers_file}"
  : > "${response_file}"
  status="$(curl \
    --silent \
    --show-error \
    --request GET \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Accept: application/json' \
    --dump-header "${headers_file}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${operation_url}")"
  operation_status="$(jq -r '.status // empty' "${response_file}" 2>/dev/null || true)"
  case "${operation_status}" in
    Succeeded)
      qam_info "Fabric Graph Model definition update succeeded"
      exit 0
      ;;
    Failed | Cancelled)
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "Fabric operation ended with status ${operation_status}"
      ;;
  esac
  case "${status}" in
    200 | 202 | 429) ;;
    *)
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "Fabric operation polling returned HTTP ${status}"
      ;;
  esac
done

qam_fail "Fabric operation did not complete within the polling window"
