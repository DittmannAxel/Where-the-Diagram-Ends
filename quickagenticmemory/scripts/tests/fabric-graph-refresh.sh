#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

refresh_script="${QAM_SCRIPTS_DIR}/refresh-fabric-graph.sh"
workspace_id='11111111-1111-4111-8111-111111111111'
graph_model_id='22222222-2222-4222-8222-222222222222'
job_instance_id='33333333-3333-4333-8333-333333333333'
refresh_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/graphModels/${graph_model_id}/jobs/refreshGraph/instances"
job_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/items/${graph_model_id}/jobs/instances/${job_instance_id}"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

# shellcheck disable=SC2329 # exported into the refresh script's Bash process
az() {
  case "${1:-} ${2:-}" in
    'account show') return 0 ;;
    'account get-access-token') printf '%s\n' 'mock-fabric-token'; return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2329 # exported into the refresh script's Bash process
sleep() {
  printf '%s\n' "$1" >> "${QAM_REFRESH_TEST_SLEEP_LOG}"
}

# shellcheck disable=SC2329 # exported into the refresh script's Bash process
date() {
  local count
  if [ "${QAM_REFRESH_TEST_SCENARIO}" != 'hard-deadline' ]; then
    command date "$@"
    return
  fi
  count="$(wc -l < "${QAM_REFRESH_TEST_DATE_LOG}" | tr -d ' ')"
  printf 'date\n' >> "${QAM_REFRESH_TEST_DATE_LOG}"
  if [ "${count}" -eq 0 ]; then
    printf '%s\n' '1000'
  else
    printf '%s\n' '1002'
  fi
}

# shellcheck disable=SC2329 # exported into the refresh script's Bash process
curl() {
  local argument=''
  local previous=''
  local method='GET'
  local output_file='/dev/null'
  local headers_file='/dev/null'
  local connect_timeout=''
  local max_time=''
  local content_length='absent'
  local url=''
  local request_number
  local status='200'
  local job_status='Completed'

  for argument in "$@"; do
    case "${previous}" in
      --request) method="${argument}" ;;
      --output) output_file="${argument}" ;;
      --dump-header) headers_file="${argument}" ;;
      --connect-timeout) connect_timeout="${argument}" ;;
      --max-time) max_time="${argument}" ;;
      --header)
        if [ "${argument}" = 'Content-Length: 0' ]; then
          content_length='0'
        fi
        ;;
    esac
    previous="${argument}"
    url="${argument}"
  done
  printf '%s %s connect=%s max=%s content-length=%s\n' \
    "${method}" "${url}" "${connect_timeout}" "${max_time}" "${content_length}" \
    >> "${QAM_REFRESH_TEST_REQUEST_LOG}"
  request_number="$(wc -l < "${QAM_REFRESH_TEST_REQUEST_LOG}" | tr -d ' ')"
  : > "${headers_file}"
  : > "${output_file}"

  if [ "${QAM_REFRESH_TEST_SCENARIO}" = 'curl-timeout' ]; then
    return 28
  fi

  if [ "${method}" = 'POST' ]; then
    if [ "${content_length}" != '0' ]; then
      printf '%s\n' '<html><body>Length Required</body></html>' > "${output_file}"
      printf '411'
      return
    fi
    case "${QAM_REFRESH_TEST_SCENARIO}" in
      start-throttle)
        if [ "${request_number}" -eq 1 ]; then
          printf 'Retry-After: 0\r\n' > "${headers_file}"
          printf '%s\n' '{"errorCode":"TooManyRequestsForJobs"}' > "${output_file}"
          printf '429'
          return
        fi
        ;;
      start-throttle-missing-retry)
        printf '%s\n' '{"errorCode":"TooManyRequestsForJobs"}' > "${output_file}"
        printf '429'
        return
        ;;
      unsafe-retry)
        printf 'Retry-After: 601\r\n' > "${headers_file}"
        printf '429'
        return
        ;;
      cross-origin) QAM_REFRESH_TEST_JOB_URL='https://attacker.example/jobs/33333333-3333-4333-8333-333333333333' ;;
      cross-item) QAM_REFRESH_TEST_JOB_URL="https://api.fabric.microsoft.com/v1/workspaces/${QAM_REFRESH_TEST_WORKSPACE}/items/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/jobs/instances/${QAM_REFRESH_TEST_JOB}" ;;
      location-suffix) QAM_REFRESH_TEST_JOB_URL="${QAM_REFRESH_TEST_JOB_URL}?redirect=attacker" ;;
      missing-location)
        printf 'Retry-After: 0\r\n' > "${headers_file}"
        printf '202'
        return
        ;;
      start-202-missing-retry)
        printf 'Location: %s\r\n' "${QAM_REFRESH_TEST_JOB_URL}" > "${headers_file}"
        printf '202'
        return
        ;;
    esac
    if [ "${QAM_REFRESH_TEST_SCENARIO}" = 'start-200' ]; then
      status='200'
    else
      printf 'Location: %s\r\nRetry-After: 0\r\n' "${QAM_REFRESH_TEST_JOB_URL}" > "${headers_file}"
      status='202'
    fi
    printf '%s' "${status}"
    return
  fi

  case "${QAM_REFRESH_TEST_SCENARIO}" in
    success)
      if [ "${request_number}" -eq 2 ]; then job_status='InProgress'; fi
      ;;
    poll-throttle)
      if [ "${request_number}" -eq 2 ]; then
        printf 'Retry-After: 0\r\n' > "${headers_file}"
        printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
        printf '429'
        return
      fi
      job_status='Completed'
      ;;
    failed) job_status='Failed' ;;
    unknown-status) job_status='Paused' ;;
    malformed-job)
      jq -cn \
        --arg id "${QAM_REFRESH_TEST_JOB}" \
        --arg itemId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
        '{id: $id, itemId: $itemId, status: "Completed"}' > "${output_file}"
      printf '200'
      return
      ;;
    bounded)
      job_status='InProgress'
      ;;
    start-200) job_status='Succeeded' ;;
  esac
  if [ "${job_status}" = 'InProgress' ]; then
    printf 'Retry-After: 0\r\n' > "${headers_file}"
  fi
  jq -cn \
    --arg id "${QAM_REFRESH_TEST_JOB}" \
    --arg itemId "${QAM_REFRESH_TEST_GRAPH}" \
    --arg status "${job_status}" \
    '{id: $id, itemId: $itemId, status: $status,
      failureReason: (if $status == "Failed" then {errorCode: "RefreshFailed"} else null end)}' \
    > "${output_file}"
  printf '200'
}

export -f az curl date sleep

run_scenario() {
  local scenario="$1"
  local scenario_dir="${test_root}/${scenario}-$RANDOM"
  mkdir -p "${scenario_dir}"
  : > "${scenario_dir}/requests.log"
  : > "${scenario_dir}/sleep.log"
  : > "${scenario_dir}/date.log"
  QAM_REFRESH_TEST_SCENARIO="${scenario}" \
  QAM_REFRESH_TEST_REQUEST_LOG="${scenario_dir}/requests.log" \
  QAM_REFRESH_TEST_SLEEP_LOG="${scenario_dir}/sleep.log" \
  QAM_REFRESH_TEST_DATE_LOG="${scenario_dir}/date.log" \
  QAM_REFRESH_TEST_WORKSPACE="${workspace_id}" \
  QAM_REFRESH_TEST_GRAPH="${graph_model_id}" \
  QAM_REFRESH_TEST_JOB="${job_instance_id}" \
  QAM_REFRESH_TEST_JOB_URL="${job_url}" \
  QAM_FABRIC_GRAPH_REFRESH_START_ATTEMPTS=3 \
  QAM_FABRIC_GRAPH_REFRESH_POLL_ATTEMPTS=3 \
  QAM_FABRIC_GRAPH_REFRESH_TIMEOUT_SECONDS=30 \
  QAM_FABRIC_GRAPH_REFRESH_REQUEST_TIMEOUT_SECONDS=5 \
  QAM_FABRIC_GRAPH_REFRESH_CONNECT_TIMEOUT_SECONDS=2 \
  QAM_FABRIC_GRAPH_REFRESH_DEFAULT_POLL_SECONDS=0 \
  QAM_FABRIC_GRAPH_REFRESH_MAX_RETRY_AFTER_SECONDS=600 \
    "${refresh_script}" \
      --workspace-id "${workspace_id}" \
      --graph-model-id "${graph_model_id}"
}

expect_failure() {
  local scenario="$1"
  if run_scenario "${scenario}" >/dev/null 2>&1; then
    qam_fail "Fabric Graph refresh negative test unexpectedly passed: ${scenario}"
  fi
}

success_receipt="$(run_scenario success)"
jq -e \
  --arg workspaceId "${workspace_id}" \
  --arg graphModelId "${graph_model_id}" \
  --arg jobInstanceId "${job_instance_id}" '
    .schemaVersion == "qam-fabric-graph-refresh/1.0" and
    .workspaceId == $workspaceId and
    .graphModelId == $graphModelId and
    .jobInstanceId == $jobInstanceId and
    .startHttpStatus == 202 and
    .status == "Completed" and
    .pollAttempts == 2 and
    .timeoutSeconds == 30 and
    .verified == true
  ' <<< "${success_receipt}" >/dev/null \
  || qam_fail "Fabric Graph refresh success receipt violates its contract"
success_log="$(find "${test_root}" -type f -path '*success-*/*requests.log' | head -1)"
grep -Fxq "POST ${refresh_url} connect=2 max=5 content-length=0" "${success_log}" \
  || qam_fail "Fabric Graph refresh did not call the official start endpoint with an explicit zero-length body and hard curl timeouts"
[ "$(grep -Fxc "GET ${job_url} connect=2 max=5 content-length=absent" "${success_log}")" -eq 2 ] \
  || qam_fail "Fabric Graph refresh did not poll only the exact Core job-instance endpoint"

start_200_receipt="$(run_scenario start-200)"
jq -e '.startHttpStatus == 200 and .jobInstanceId == "" and
       .status == "Completed" and .pollAttempts == 0' \
  <<< "${start_200_receipt}" >/dev/null \
  || qam_fail "Fabric Graph refresh did not accept the documented synchronous HTTP 200 response"
start_200_log="$(find "${test_root}" -type f -path '*start-200-*/*requests.log' | head -1)"
[ "$(wc -l < "${start_200_log}" | tr -d ' ')" -eq 1 ] \
  || qam_fail "synchronous HTTP 200 must not require a fabricated job-instance poll"

start_throttle_receipt="$(run_scenario start-throttle)"
jq -e '.status == "Completed" and .verified == true' <<< "${start_throttle_receipt}" >/dev/null \
  || qam_fail "Fabric Graph refresh did not recover from start throttling"
poll_throttle_receipt="$(run_scenario poll-throttle)"
jq -e '.status == "Completed" and .pollAttempts == 2' <<< "${poll_throttle_receipt}" >/dev/null \
  || qam_fail "Fabric Graph refresh did not recover from poll throttling"

for scenario in \
  cross-origin \
  cross-item \
  location-suffix \
  missing-location \
  start-202-missing-retry \
  start-throttle-missing-retry \
  unsafe-retry \
  failed \
  unknown-status \
  malformed-job \
  bounded \
  curl-timeout; do
  expect_failure "${scenario}"
done

if QAM_REFRESH_TEST_SCENARIO='success' \
  QAM_FABRIC_GRAPH_REFRESH_CONNECT_TIMEOUT_SECONDS=6 \
  QAM_FABRIC_GRAPH_REFRESH_REQUEST_TIMEOUT_SECONDS=5 \
  "${refresh_script}" \
    --workspace-id "${workspace_id}" \
    --graph-model-id "${graph_model_id}" >/dev/null 2>&1; then
  qam_fail "Fabric Graph refresh accepted a connect timeout above its request timeout"
fi

touch "${test_root}/hard-deadline-requests.log" \
  "${test_root}/hard-deadline-sleep.log" \
  "${test_root}/hard-deadline-date.log"
if QAM_REFRESH_TEST_SCENARIO='hard-deadline' \
  QAM_REFRESH_TEST_REQUEST_LOG="${test_root}/hard-deadline-requests.log" \
  QAM_REFRESH_TEST_SLEEP_LOG="${test_root}/hard-deadline-sleep.log" \
  QAM_REFRESH_TEST_DATE_LOG="${test_root}/hard-deadline-date.log" \
  QAM_REFRESH_TEST_WORKSPACE="${workspace_id}" \
  QAM_REFRESH_TEST_GRAPH="${graph_model_id}" \
  QAM_REFRESH_TEST_JOB="${job_instance_id}" \
  QAM_REFRESH_TEST_JOB_URL="${job_url}" \
  QAM_FABRIC_GRAPH_REFRESH_TIMEOUT_SECONDS=1 \
  QAM_FABRIC_GRAPH_REFRESH_REQUEST_TIMEOUT_SECONDS=1 \
  QAM_FABRIC_GRAPH_REFRESH_CONNECT_TIMEOUT_SECONDS=1 \
  "${refresh_script}" \
    --workspace-id "${workspace_id}" \
    --graph-model-id "${graph_model_id}" >/dev/null 2>&1; then
  qam_fail "Fabric Graph refresh exceeded its overall deadline without failing closed"
fi

qam_info "Fabric Graph RefreshGraph tests passed"
