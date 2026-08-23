#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
graph_model_id="${QAM_FABRIC_GRAPH_MODEL_ID:-}"

start_attempt_limit="${QAM_FABRIC_GRAPH_REFRESH_START_ATTEMPTS:-5}"
poll_attempt_limit="${QAM_FABRIC_GRAPH_REFRESH_POLL_ATTEMPTS:-120}"
overall_timeout_seconds="${QAM_FABRIC_GRAPH_REFRESH_TIMEOUT_SECONDS:-1800}"
request_timeout_seconds="${QAM_FABRIC_GRAPH_REFRESH_REQUEST_TIMEOUT_SECONDS:-60}"
connect_timeout_seconds="${QAM_FABRIC_GRAPH_REFRESH_CONNECT_TIMEOUT_SECONDS:-10}"
default_poll_seconds="${QAM_FABRIC_GRAPH_REFRESH_DEFAULT_POLL_SECONDS:-10}"
max_retry_after_seconds="${QAM_FABRIC_GRAPH_REFRESH_MAX_RETRY_AFTER_SECONDS:-300}"

usage() {
  printf '%s\n' \
    'Usage: refresh-fabric-graph.sh --workspace-id UUID --graph-model-id UUID' \
    '' \
    'Starts the official Preview RefreshGraph job, follows only its exact' \
    'same-origin Core job-instance Location, and emits a receipt only after' \
    'the bounded job reaches Completed or Succeeded.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-id) graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${graph_model_id}" ] || qam_fail "--graph-model-id is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${graph_model_id}" "Fabric Graph Model ID"

validate_positive_integer() {
  local value="$1"
  local label="$2"
  local maximum="$3"

  printf '%s' "${value}" | grep -Eq '^[1-9][0-9]*$' \
    || qam_fail "${label} must be a positive integer"
  [ "${value}" -le "${maximum}" ] \
    || qam_fail "${label} exceeds the supported maximum of ${maximum}"
}

validate_nonnegative_integer() {
  local value="$1"
  local label="$2"
  local maximum="$3"

  printf '%s' "${value}" | grep -Eq '^[0-9]+$' \
    || qam_fail "${label} must be a non-negative integer"
  [ "${value}" -le "${maximum}" ] \
    || qam_fail "${label} exceeds the supported maximum of ${maximum}"
}

validate_positive_integer "${start_attempt_limit}" "start attempt limit" 20
validate_positive_integer "${poll_attempt_limit}" "poll attempt limit" 1000
validate_positive_integer "${overall_timeout_seconds}" "overall refresh timeout" 7200
validate_positive_integer "${request_timeout_seconds}" "request timeout" 300
validate_positive_integer "${connect_timeout_seconds}" "connect timeout" 60
validate_nonnegative_integer "${default_poll_seconds}" "default poll interval" 300
validate_nonnegative_integer "${max_retry_after_seconds}" "maximum Retry-After" 600
[ "${connect_timeout_seconds}" -le "${request_timeout_seconds}" ] \
  || qam_fail "connect timeout must not exceed request timeout"

qam_require_azure_login
qam_require_command curl
qam_require_command date
qam_require_command jq

access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

response_file="$(mktemp)"
headers_file="$(mktemp)"
trap 'rm -f "${response_file}" "${headers_file}"' EXIT

started_at="$(date +%s)"
deadline=$((started_at + overall_timeout_seconds))

remaining_seconds() {
  local now
  now="$(date +%s)"
  if [ "${now}" -ge "${deadline}" ]; then
    qam_fail "Fabric Graph refresh exceeded the hard ${overall_timeout_seconds}-second timeout"
  fi
  printf '%s' "$((deadline - now))"
}

extract_header() {
  local header_name="$1"
  awk -v expected="${header_name}:" '
    tolower($1) == tolower(expected) {
      $1=""
      sub(/^[[:space:]]+/, "")
      gsub(/\r/, "")
      value=$0
    }
    END { print value }
  ' "${headers_file}"
}

retry_after_seconds() {
  local required="$1"
  local value
  value="$(extract_header 'Retry-After')"
  if [ -z "${value}" ]; then
    [ "${required}" = 'false' ] || qam_fail "Fabric response omitted the required Retry-After header"
    printf '%s' "${default_poll_seconds}"
    return
  fi
  printf '%s' "${value}" | grep -Eq '^[0-9]+$' \
    || qam_fail "Fabric Retry-After must be non-negative delta-seconds"
  [ "${value}" -le "${max_retry_after_seconds}" ] \
    || qam_fail "Fabric Retry-After exceeds the configured safe wait limit"
  printf '%s' "${value}"
}

wait_before_retry() {
  local delay="$1"
  local remaining
  remaining="$(remaining_seconds)"
  [ "${delay}" -lt "${remaining}" ] \
    || qam_fail "Fabric Retry-After would exceed the hard refresh timeout"
  sleep "${delay}"
}

fabric_request() {
  local method="$1"
  local url="$2"
  local remaining
  local call_timeout
  local -a request_headers=(
    --header "Authorization: Bearer ${access_token}"
    --header 'Accept: application/json'
  )

  remaining="$(remaining_seconds)"
  call_timeout="${request_timeout_seconds}"
  if [ "${remaining}" -lt "${call_timeout}" ]; then
    call_timeout="${remaining}"
  fi
  : > "${headers_file}"
  : > "${response_file}"
  if [ "${method}" = 'POST' ]; then
    # Fabric's front door rejects a bodyless POST without an explicit length
    # with HTTP 411. The RefreshGraph start operation has no request body, so
    # make that zero-length contract unambiguous without sending `{}`.
    request_headers+=(--header 'Content-Length: 0')
  fi
  if ! curl \
    --silent \
    --show-error \
    --connect-timeout "${connect_timeout_seconds}" \
    --max-time "${call_timeout}" \
    --request "${method}" \
    "${request_headers[@]}" \
    --dump-header "${headers_file}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${url}"; then
    qam_fail "Fabric Graph refresh ${method} request failed or timed out"
  fi
}

refresh_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/graphModels/${graph_model_id}/jobs/refreshGraph/instances"
start_http_status=''
for start_attempt in $(seq 1 "${start_attempt_limit}"); do
  start_http_status="$(fabric_request POST "${refresh_url}")"
  case "${start_http_status}" in
    200 | 202) break ;;
    429)
      [ "${start_attempt}" -lt "${start_attempt_limit}" ] || {
        sed -n '1,40p' "${response_file}" >&2
        qam_fail "starting Fabric Graph refresh remained throttled after ${start_attempt_limit} attempts"
      }
      wait_before_retry "$(retry_after_seconds true)"
      ;;
    *)
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "starting Fabric Graph refresh returned HTTP ${start_http_status}"
      ;;
  esac
done

job_url=''
job_instance_id=''
poll_attempts=0
terminal_status=''
if [ "${start_http_status}" = '200' ]; then
  # The documented synchronous response has no job instance to poll. The
  # manifest-bound GQL postcondition in the caller still proves data freshness.
  terminal_status='Completed'
else
  job_url="$(extract_header 'Location')"
  [ -n "${job_url}" ] || qam_fail "Fabric Graph refresh returned no job-instance Location"
  expected_job_prefix="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/items/${graph_model_id}/jobs/instances/"
  case "${job_url}" in
    "${expected_job_prefix}"*) ;;
    *) qam_fail "Fabric Graph refresh Location left the exact workspace/Graph Model Core job endpoint" ;;
  esac
  job_instance_id="${job_url##*/}"
  qam_validate_uuid "${job_instance_id}" "Fabric Graph refresh job instance ID"
  [ "${job_url}" = "${expected_job_prefix}${job_instance_id}" ] \
    || qam_fail "Fabric Graph refresh Location contains an unexpected suffix"

  wait_before_retry "$(retry_after_seconds true)"
fi

while [ -z "${terminal_status}" ] \
  && [ "${poll_attempts}" -lt "${poll_attempt_limit}" ]; do
  poll_attempts=$((poll_attempts + 1))
  poll_http_status="$(fabric_request GET "${job_url}")"
  case "${poll_http_status}" in
    429)
      wait_before_retry "$(retry_after_seconds true)"
      continue
      ;;
    200) ;;
    *)
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "polling Fabric Graph refresh returned HTTP ${poll_http_status}"
      ;;
  esac

  jq -e \
    --arg id "${job_instance_id}" \
    --arg itemId "${graph_model_id}" '
      ((.id | type) == "string" and ((.id | ascii_downcase) == ($id | ascii_downcase))) and
      ((.itemId | type) == "string" and ((.itemId | ascii_downcase) == ($itemId | ascii_downcase))) and
      ((.status | type) == "string" and (.status | length) > 0)
    ' "${response_file}" >/dev/null \
    || qam_fail "Fabric Graph refresh returned a malformed or mismatched job instance"
  job_status="$(jq -r '.status' "${response_file}")"
  case "${job_status}" in
    Completed | Succeeded)
      terminal_status="${job_status}"
      break
      ;;
    Failed | Cancelled | Deduped)
      jq '{id, itemId, status, failureReason}' "${response_file}" >&2
      qam_fail "Fabric Graph refresh ended with status ${job_status}"
      ;;
    NotStarted | InProgress) ;;
    *) qam_fail "Fabric Graph refresh returned unknown status: ${job_status}" ;;
  esac

  wait_before_retry "$(retry_after_seconds true)"
done

[ -n "${terminal_status}" ] \
  || qam_fail "Fabric Graph refresh did not complete within ${poll_attempt_limit} bounded polls"

completed_at="$(date +%s)"
jq -cn \
  --arg workspaceId "${workspace_id}" \
  --arg graphModelId "${graph_model_id}" \
  --arg jobInstanceId "${job_instance_id}" \
  --arg status "${terminal_status}" \
  --argjson startHttpStatus "${start_http_status}" \
  --argjson pollAttempts "${poll_attempts}" \
  --argjson timeoutSeconds "${overall_timeout_seconds}" \
  --argjson elapsedSeconds "$((completed_at - started_at))" '
    {
      schemaVersion: "qam-fabric-graph-refresh/1.0",
      workspaceId: $workspaceId,
      graphModelId: $graphModelId,
      jobInstanceId: $jobInstanceId,
      startHttpStatus: $startHttpStatus,
      status: $status,
      pollAttempts: $pollAttempts,
      timeoutSeconds: $timeoutSeconds,
      elapsedSeconds: $elapsedSeconds,
      verified: true
    }
  '
