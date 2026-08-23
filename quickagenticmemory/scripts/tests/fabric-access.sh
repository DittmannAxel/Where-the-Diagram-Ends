#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

workspace_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
runtime_principal_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
viewer_assignment_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
second_viewer_assignment_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
created_assignment_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
smoke_principal_id='ffffffff-ffff-4fff-8fff-ffffffffffff'

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mock_bin="${test_dir}/bin"
mkdir -p "${mock_bin}"

cat > "${mock_bin}/az" <<'MOCK_AZ'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}:${2:-}:${3:-}" in
  account:show:*) exit 0 ;;
  account:get-access-token:*) printf '%s\n' 'test-fabric-token' ;;
  ad:sp:show)
    if [ "${QAM_TEST_SCENARIO:-}" = 'sp-client-id' ]; then
      printf '%s\n' "${QAM_TEST_SMOKE_PRINCIPAL_ID:?}"
    else
      printf '%s\n' "${5:?missing service-principal ID}"
    fi
    ;;
  *) printf 'unexpected az command: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK_AZ

cat > "${mock_bin}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
method='GET'
output_file=''
headers_file=''
connect_timeout=''
request_timeout=''
data=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --silent | --show-error) shift ;;
    --connect-timeout) connect_timeout="${2:?}"; shift 2 ;;
    --max-time) request_timeout="${2:?}"; shift 2 ;;
    --request) method="${2:?}"; shift 2 ;;
    --header | --write-out) shift 2 ;;
    --dump-header) headers_file="${2:?}"; shift 2 ;;
    --data-binary) data="${2:?}"; shift 2 ;;
    --output) output_file="${2:?}"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) printf 'unexpected curl argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "${output_file}" ] && [ -n "${headers_file}" ] && [ -n "${url}" ] \
  && [ -n "${connect_timeout}" ] && [ -n "${request_timeout}" ]
: > "${headers_file}"
base_url="https://api.fabric.microsoft.com/v1/workspaces/${QAM_TEST_WORKSPACE_ID:?}/roleAssignments"

write_assignment() {
  local assignment_id="$1"
  local principal_id="$2"
  local role="$3"
  jq -cn \
    --arg assignmentId "${assignment_id}" \
    --arg principalId "${principal_id}" \
    --arg role "${role}" \
    '{id: $assignmentId, principal: {id: $principalId, type: "ServicePrincipal"}, role: $role}'
}

case "${method}:${url}" in
  "GET:${base_url}")
    list_count=0
    if [ -f "${QAM_TEST_LIST_COUNT_FILE:?}" ]; then
      list_count="$(< "${QAM_TEST_LIST_COUNT_FILE}")"
    fi
    list_count=$((list_count + 1))
    printf '%s\n' "${list_count}" > "${QAM_TEST_LIST_COUNT_FILE}"
    if { [ "${QAM_TEST_SCENARIO:?}" = 'list-429-once' ] \
        || [ "${QAM_TEST_SCENARIO}" = 'list-retry-after-too-long' ]; } \
      && [ "${list_count}" -eq 1 ]; then
      retry_after='0'
      [ "${QAM_TEST_SCENARIO}" != 'list-retry-after-too-long' ] || retry_after='301'
      printf 'Retry-After: %s\n' "${retry_after}" > "${headers_file}"
      printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
      printf '429'
      exit 0
    fi
    if grep -q '^POST ' "${QAM_TEST_REQUEST_LOG:?}"; then
      case "${QAM_TEST_SCENARIO:?}" in
        post-429-delayed | post-409-delayed)
          if [ "${list_count}" -eq 2 ]; then
            printf '%s\n' '{"value":[]}' > "${output_file}"
          else
            jq -cn \
              --argjson assignment "$(write_assignment \
                "${QAM_TEST_CREATED_ASSIGNMENT_ID:?}" \
                "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Contributor)" \
              '{value: [$assignment]}' > "${output_file}"
          fi
          printf '200'
          exit 0
          ;;
        post-429-persistent-null)
          printf '%s\n' '{"value":[]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
        post-429-existing)
          jq -cn \
            --argjson assignment "$(write_assignment \
              "${QAM_TEST_CREATED_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Contributor)" \
            '{value: [$assignment]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
        post-429-duplicate)
          jq -cn \
            --argjson first "$(write_assignment \
              "${QAM_TEST_CREATED_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Contributor)" \
            --argjson second "$(write_assignment \
              "${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Contributor)" \
            '{value: [$first, $second]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
      esac
      sed -n 's/^POST //p' "${QAM_TEST_REQUEST_LOG}" \
        | jq -s \
          --arg createdId "${QAM_TEST_CREATED_ASSIGNMENT_ID:?}" \
          --arg secondId "${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}" \
          --arg smokePrincipalId "${QAM_TEST_SMOKE_PRINCIPAL_ID:?}" '
            {value: map({
              id: (if .principal.id == $smokePrincipalId then $secondId else $createdId end),
              principal: .principal,
              role: .role
            })}
          ' > "${output_file}"
      printf '200'
      exit 0
    fi
    if [ "${list_count}" -ge 2 ]; then
      case "${QAM_TEST_SCENARIO:?}" in
        viewer-exact-member | viewer-patch-429-member | viewer-patch-429-admin)
          final_role='Member'
          [ "${QAM_TEST_SCENARIO}" != 'viewer-patch-429-admin' ] || final_role='Admin'
          jq -cn \
            --argjson assignment "$(write_assignment \
              "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" "${final_role}")" \
            '{value: [$assignment]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
        contributor-final-viewer)
          jq -cn \
            --argjson assignment "$(write_assignment \
              "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
            '{value: [$assignment]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
        contributor-final-viewer-once)
          if [ "${list_count}" -eq 2 ]; then
            jq -cn \
              --argjson assignment "$(write_assignment \
                "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
                "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
              '{value: [$assignment]}' > "${output_file}"
            printf '200'
            exit 0
          fi
          ;;
        contributor-final-missing)
          printf '%s\n' '{"value":[]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
        contributor-final-duplicate)
          jq -cn \
            --argjson first "$(write_assignment \
              "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Contributor)" \
            --argjson second "$(write_assignment \
              "${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Contributor)" \
            '{value: [$first, $second]}' > "${output_file}"
          printf '200'
          exit 0
          ;;
      esac
    fi
    case "${QAM_TEST_SCENARIO:?}" in
      none | bad-post | list-429-once | list-retry-after-too-long | \
        post-429-delayed | post-429-persistent-null | post-429-existing | \
        post-429-duplicate | post-409-delayed | runtime-none-smoke-none | \
        runtime-none-smoke-updater)
        printf '%s\n' '{"value":[]}' > "${output_file}"
        ;;
      viewer | viewer-exact-member | viewer-post-get-viewer | \
        viewer-post-get-stale-once | viewer-patch-429-once | \
        viewer-patch-429-member | viewer-patch-429-admin | \
        viewer-patch-fail | viewer-patch-bad-response)
        role='Viewer'
        [ ! -e "${QAM_TEST_STATE_FILE:?}" ] || role='Contributor'
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" "${role}")" \
          '{value: [$assignment]}' > "${output_file}"
        ;;
      contributor | contributor-final-viewer | contributor-final-missing | \
        contributor-final-duplicate | contributor-final-viewer-once | member | admin)
        role='Contributor'
        case "${QAM_TEST_SCENARIO}" in
          contributor | contributor-final-viewer | contributor-final-missing | \
            contributor-final-duplicate | contributor-final-viewer-once) ;;
          member) role='Member' ;;
          admin) role='Admin' ;;
        esac
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" "${role}")" \
          '{value: [$assignment]}' > "${output_file}"
        ;;
      duplicate-viewer)
        jq -cn \
          --argjson first "$(write_assignment \
            "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
          --argjson second "$(write_assignment \
            "${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
          '{value: [$first, $second]}' > "${output_file}"
        ;;
      duplicate-pagination)
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
          --arg continuationUri "${base_url}?continuationToken=next" \
          '{value: [$assignment], continuationUri: $continuationUri}' > "${output_file}"
        ;;
      cross-origin-pagination)
        jq -cn \
          --arg continuationUri 'https://example.invalid/roleAssignments?continuationToken=next' \
          '{value: [], continuationUri: $continuationUri}' > "${output_file}"
        ;;
      token-without-uri)
        printf '%s\n' '{"value":[],"continuationToken":"next"}' > "${output_file}"
        ;;
      malformed-id)
        jq -cn \
          --argjson assignment "$(write_assignment \
            'not-a-uuid' \
            "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
          '{value: [$assignment]}' > "${output_file}"
        ;;
      runtime-none-smoke-duplicate)
        jq -cn \
          --argjson first "$(write_assignment \
            "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_SMOKE_PRINCIPAL_ID:?}" Viewer)" \
          --argjson second "$(write_assignment \
            "${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_SMOKE_PRINCIPAL_ID:?}" Viewer)" \
          '{value: [$first, $second]}' > "${output_file}"
        ;;
      *) printf 'unexpected list scenario: %s\n' "${QAM_TEST_SCENARIO}" >&2; exit 2 ;;
    esac
    printf '200'
    ;;
  "GET:${base_url}?continuationToken=next")
    [ "${QAM_TEST_SCENARIO:?}" = 'duplicate-pagination' ]
    jq -cn \
      --argjson assignment "$(write_assignment \
        "${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}" \
        "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" Viewer)" \
      '{value: [$assignment]}' > "${output_file}"
    printf '200'
    ;;
  "GET:${base_url}/"*)
    printf 'GET-EXACT %s\n' "${url}" >> "${QAM_TEST_REQUEST_LOG:?}"
    exact_get_count="$(grep -c '^GET-EXACT ' "${QAM_TEST_REQUEST_LOG}")"
    role='Viewer'
    [ ! -e "${QAM_TEST_STATE_FILE:?}" ] || role='Contributor'
    if [ "${QAM_TEST_SCENARIO:?}" = 'viewer-exact-member' ]; then
      role='Member'
    elif [ "${QAM_TEST_SCENARIO}" = 'viewer-patch-429-member' ] \
      && grep -q '^PATCH ' "${QAM_TEST_REQUEST_LOG:?}"; then
      role='Member'
    elif [ "${QAM_TEST_SCENARIO}" = 'viewer-patch-429-admin' ] \
      && grep -q '^PATCH ' "${QAM_TEST_REQUEST_LOG:?}"; then
      role='Admin'
    elif [ "${QAM_TEST_SCENARIO}" = 'viewer-post-get-viewer' ] \
      && [ "${exact_get_count}" -ge 2 ]; then
      role='Viewer'
    elif [ "${QAM_TEST_SCENARIO}" = 'viewer-post-get-stale-once' ] \
      && [ "${exact_get_count}" -eq 2 ]; then
      role='Viewer'
    fi
    write_assignment \
      "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
      "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" \
      "${role}" > "${output_file}"
    printf '200'
    ;;
  "PATCH:${base_url}/"*)
    printf 'PATCH %s %s\n' "${url}" "${data}" >> "${QAM_TEST_REQUEST_LOG:?}"
    patch_count="$(grep -c '^PATCH ' "${QAM_TEST_REQUEST_LOG}")"
    if { [ "${QAM_TEST_SCENARIO:?}" = 'viewer-patch-429-once' ] \
        || [ "${QAM_TEST_SCENARIO}" = 'viewer-patch-429-member' ] \
        || [ "${QAM_TEST_SCENARIO}" = 'viewer-patch-429-admin' ]; } \
      && [ "${patch_count}" -eq 1 ]; then
      printf '%s\n' 'Retry-After: 0' > "${headers_file}"
      printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
      printf '429'
      exit 0
    fi
    if [ "${QAM_TEST_SCENARIO:?}" = 'viewer-patch-fail' ]; then
      printf '%s\n' '{"errorCode":"Forbidden"}' > "${output_file}"
      printf '403'
      exit 0
    fi
    printf '%s\n' 'patched' > "${QAM_TEST_STATE_FILE:?}"
    patch_role='Contributor'
    [ "${QAM_TEST_SCENARIO}" != 'viewer-patch-bad-response' ] || patch_role='Member'
    write_assignment \
      "${QAM_TEST_VIEWER_ASSIGNMENT_ID:?}" \
      "${QAM_TEST_RUNTIME_PRINCIPAL_ID:?}" \
      "${patch_role}" > "${output_file}"
    printf '200'
    ;;
  "POST:${base_url}")
    printf 'POST %s\n' "${data}" >> "${QAM_TEST_REQUEST_LOG:?}"
    case "${QAM_TEST_SCENARIO:?}" in
      post-429-delayed | post-429-persistent-null | post-429-existing | \
        post-429-duplicate)
        printf '%s\n' 'Retry-After: 0' > "${headers_file}"
        printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
        printf '429'
        exit 0
        ;;
      post-409-delayed)
        printf '%s\n' '{"errorCode":"Conflict"}' > "${output_file}"
        printf '409'
        exit 0
        ;;
    esac
    principal_id="$(jq -r '.principal.id' <<< "${data}")"
    role="$(jq -r '.role' <<< "${data}")"
    if [ "${QAM_TEST_SCENARIO:?}" = 'bad-post' ]; then
      role='Admin'
    fi
    assignment_id="${QAM_TEST_CREATED_ASSIGNMENT_ID:?}"
    if [ "${principal_id}" = "${QAM_TEST_SMOKE_PRINCIPAL_ID:?}" ]; then
      assignment_id="${QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID:?}"
    fi
    write_assignment \
      "${assignment_id}" \
      "${principal_id}" \
      "${role}" > "${output_file}"
    printf '201'
    ;;
  *) printf 'unexpected curl request: %s %s\n' "${method}" "${url}" >&2; exit 2 ;;
esac
MOCK_CURL

chmod +x "${mock_bin}/az" "${mock_bin}/curl"

run_access() {
  local scenario="$1"
  local receipt_file="$2"
  local request_log="$3"
  shift 3

  : > "${request_log}"
  rm -f "${test_dir}/state"
  rm -f "${test_dir}/list-count"
  QAM_TEST_SCENARIO="${scenario}" \
  QAM_TEST_WORKSPACE_ID="${workspace_id}" \
  QAM_TEST_RUNTIME_PRINCIPAL_ID="${runtime_principal_id}" \
  QAM_TEST_SMOKE_PRINCIPAL_ID="${smoke_principal_id}" \
  QAM_TEST_VIEWER_ASSIGNMENT_ID="${viewer_assignment_id}" \
  QAM_TEST_SECOND_VIEWER_ASSIGNMENT_ID="${second_viewer_assignment_id}" \
  QAM_TEST_CREATED_ASSIGNMENT_ID="${created_assignment_id}" \
  QAM_TEST_REQUEST_LOG="${request_log}" \
  QAM_TEST_STATE_FILE="${test_dir}/state" \
  QAM_TEST_LIST_COUNT_FILE="${test_dir}/list-count" \
  QAM_FABRIC_ROLE_RETRY_ATTEMPTS=3 \
  QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS=0 \
  PATH="${mock_bin}:${PATH}" \
    "${QAM_SCRIPTS_DIR}/grant-fabric-access.sh" \
      --workspace-id "${workspace_id}" \
      --runtime-principal-id "${runtime_principal_id}" \
      "$@" > "${receipt_file}"
}

receipt_file="${test_dir}/receipt.json"
request_log="${test_dir}/requests.log"

run_access none "${receipt_file}" "${request_log}"
jq -e '
  .runtimeRole == "Viewer" and
  .runtimeMinimumRole == "Viewer" and
  .runtimeObservedRole == "Viewer"
' "${receipt_file}" >/dev/null \
  || qam_fail "Fabric's documented runtime default must remain Viewer"
jq -e '.role == "Viewer"' <<< "$(sed -n 's/^POST //p' "${request_log}")" >/dev/null \
  || qam_fail "the default Fabric runtime grant did not request Viewer"

run_access none "${receipt_file}" "${request_log}" --runtime-role Contributor
jq -e '
  .runtimeRole == "Contributor" and
  .runtimeMinimumRole == "Contributor" and
  .runtimeObservedRole == "Contributor"
' "${receipt_file}" >/dev/null \
  || qam_fail "the explicit Fabric runtime workaround must report Contributor"
jq -e '.role == "Contributor"' <<< "$(sed -n 's/^POST //p' "${request_log}")" >/dev/null \
  || qam_fail "a missing Fabric runtime assignment did not create explicit Contributor"

run_access list-429-once "${receipt_file}" "${request_log}" --runtime-role Contributor
if [ "$(< "${test_dir}/list-count")" -ne 3 ] \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a documented list 429 must honor bounded retry and still verify final state"
fi

if run_access list-retry-after-too-long "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "Retry-After above the configured safe wait limit must fail closed"
fi
[ "$(< "${test_dir}/list-count")" -eq 1 ] && [ ! -s "${request_log}" ] \
  || qam_fail "an unsafe Retry-After must not trigger an early retry or mutation"

run_access post-429-delayed "${receipt_file}" "${request_log}" --runtime-role Contributor
if [ "$(grep -c '^POST ' "${request_log}")" -ne 1 ] \
  || [ "$(< "${test_dir}/list-count")" -ne 4 ] \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a throttled create with delayed visibility must reconcile without repeating POST"
fi

if run_access post-429-persistent-null "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "a throttled create that remains invisible must fail closed"
fi
if [ "$(grep -c '^POST ' "${request_log}")" -ne 1 ] \
  || [ "$(< "${test_dir}/list-count")" -ne 4 ] \
  || grep -q '^PATCH ' "${request_log}"; then
  qam_fail "persistent null reconciliation must never repeat or replace the ambiguous POST"
fi

run_access post-429-existing "${receipt_file}" "${request_log}" --runtime-role Contributor
if [ "$(grep -c '^POST ' "${request_log}")" -ne 1 ] \
  || grep -q '^PATCH ' "${request_log}" \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a live assignment after a throttled create must be reconciled without a duplicate POST"
fi

run_access post-409-delayed "${receipt_file}" "${request_log}" --runtime-role Contributor
if [ "$(grep -c '^POST ' "${request_log}")" -ne 1 ] \
  || [ "$(< "${test_dir}/list-count")" -ne 4 ] \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a conflicting create with delayed visibility must reconcile without repeating POST"
fi

if run_access post-429-duplicate "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "ambiguous live assignments after a throttled create must fail closed"
fi
if [ "$(grep -c '^POST ' "${request_log}")" -ne 1 ] \
  || grep -q '^PATCH ' "${request_log}"; then
  qam_fail "a throttled create must never retry after discovering duplicate live assignments"
fi

run_access viewer "${receipt_file}" "${request_log}" --runtime-role Contributor
if [ "$(grep -c '^GET-EXACT ' "${request_log}")" -ne 2 ] \
  || [ "$(grep -c '^PATCH ' "${request_log}")" -ne 1 ] \
  || grep -q '^POST\|^DELETE' "${request_log}"; then
  qam_fail "a single Viewer must be checked, patched in place, and verified"
fi
grep -Fxq \
  "PATCH https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments/${viewer_assignment_id} {\"role\":\"Contributor\"}" \
  "${request_log}" \
  || qam_fail "the Viewer update left the exact assignment or request-body contract"

run_access viewer-patch-429-once "${receipt_file}" "${request_log}" \
  --runtime-role Contributor
if [ "$(grep -c '^PATCH ' "${request_log}")" -ne 2 ] \
  || [ "$(grep -c '^GET-EXACT ' "${request_log}")" -ne 3 ] \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a PATCH 429 must re-read Viewer before retrying the exact update"
fi

for broader_role in member admin; do
  run_access "viewer-patch-429-${broader_role}" "${receipt_file}" "${request_log}" \
    --runtime-role Contributor
  case "${broader_role}" in
    member) expected_observed_role='Member' ;;
    admin) expected_observed_role='Admin' ;;
  esac
  if [ "$(grep -c '^PATCH ' "${request_log}")" -ne 1 ] \
    || [ "$(grep -c '^GET-EXACT ' "${request_log}")" -ne 2 ] \
    || grep -q '^POST ' "${request_log}" \
    || ! jq -e --arg observedRole "${expected_observed_role}" \
      '.runtimeObservedRole == $observedRole' "${receipt_file}" >/dev/null; then
    qam_fail "a broader role observed after PATCH 429 must never be downgraded"
  fi
done

run_access viewer-post-get-stale-once "${receipt_file}" "${request_log}" \
  --runtime-role Contributor
if [ "$(grep -c '^GET-EXACT ' "${request_log}")" -ne 3 ] \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a stale post-PATCH Viewer must be retried before emitting a receipt"
fi

for existing_role in contributor member admin; do
  run_access "${existing_role}" "${receipt_file}" "${request_log}" --runtime-role Contributor
  [ ! -s "${request_log}" ] \
    || qam_fail "an existing ${existing_role} role must be preserved without mutation"
  case "${existing_role}" in
    contributor) expected_observed_role='Contributor' ;;
    member) expected_observed_role='Member' ;;
    admin) expected_observed_role='Admin' ;;
  esac
  jq -e --arg observedRole "${expected_observed_role}" '
    .runtimeRole == "Contributor" and
    .runtimeMinimumRole == "Contributor" and
    .runtimeObservedRole == $observedRole
  ' "${receipt_file}" >/dev/null \
    || qam_fail "the ${existing_role} receipt must separate minimum from observed role"
done

run_access viewer-exact-member "${receipt_file}" "${request_log}" \
  --runtime-role Contributor
if [ "$(grep -c '^GET-EXACT ' "${request_log}")" -ne 1 ] \
  || grep -q '^PATCH\|^POST\|^DELETE' "${request_log}"; then
  qam_fail "a concurrent broader role must be preserved without PATCH"
fi
jq -e '
  .runtimeMinimumRole == "Contributor" and
  .runtimeObservedRole == "Member"
' "${receipt_file}" >/dev/null \
  || qam_fail "the final receipt must observe a concurrent broader role"

for final_race in contributor-final-viewer contributor-final-missing contributor-final-duplicate; do
  if run_access "${final_race}" "${receipt_file}" "${request_log}" \
    --runtime-role Contributor 2>/dev/null; then
    qam_fail "${final_race} must fail the final live role gate"
  fi
done

run_access contributor-final-viewer-once "${receipt_file}" "${request_log}" \
  --runtime-role Contributor
if [ "$(< "${test_dir}/list-count")" -ne 3 ] \
  || ! jq -e '.runtimeObservedRole == "Contributor"' "${receipt_file}" >/dev/null; then
  qam_fail "a stale final role page must be retried before emitting a receipt"
fi

for malformed_scenario in malformed-id cross-origin-pagination token-without-uri; do
  if run_access "${malformed_scenario}" "${receipt_file}" "${request_log}" \
    --runtime-role Contributor 2>/dev/null; then
    qam_fail "${malformed_scenario} must fail closed"
  fi
  [ ! -s "${request_log}" ] \
    || qam_fail "${malformed_scenario} must fail before mutating Fabric access"
done

if run_access sp-client-id "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "an application/client ID must not be accepted as a service-principal object ID"
fi
[ ! -s "${request_log}" ] && [ ! -e "${test_dir}/list-count" ] \
  || qam_fail "service-principal object-ID validation must precede every Fabric API call"

for duplicate_scenario in duplicate-viewer duplicate-pagination; do
  if run_access "${duplicate_scenario}" "${receipt_file}" "${request_log}" \
    --runtime-role Contributor 2>/dev/null; then
    qam_fail "${duplicate_scenario} must fail closed"
  fi
  [ ! -s "${request_log}" ] \
    || qam_fail "${duplicate_scenario} must not mutate Fabric access"
done

if run_access runtime-none-smoke-duplicate "${receipt_file}" "${request_log}" \
  --runtime-role Contributor --smoke-principal-id "${smoke_principal_id}" 2>/dev/null; then
  qam_fail "a duplicate later target must fail before the runtime mutation"
fi
[ ! -s "${request_log}" ] \
  || qam_fail "all Fabric role targets must be preflighted before the first mutation"

if run_access viewer-patch-fail "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "a rejected Fabric role update must fail"
fi
[ "$(grep -c '^PATCH ' "${request_log}")" -eq 1 ] \
  || qam_fail "the rejected Fabric update must make exactly one bounded PATCH"

if run_access bad-post "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "an unexpected Fabric role-creation response must fail"
fi

if run_access viewer-patch-bad-response "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "an unexpected Fabric role-update response must fail"
fi

if run_access viewer-post-get-viewer "${receipt_file}" "${request_log}" \
  --runtime-role Contributor 2>/dev/null; then
  qam_fail "a post-PATCH Viewer read-back must fail"
fi

run_access runtime-none-smoke-none "${receipt_file}" "${request_log}" \
  --runtime-role Contributor --smoke-principal-id "${smoke_principal_id}"
jq -e \
  --arg runtimePrincipalId "${runtime_principal_id}" \
  --arg smokePrincipalId "${smoke_principal_id}" '
    length == 2 and
    any(.[]; .principal.id == $runtimePrincipalId and .role == "Contributor") and
    any(.[]; .principal.id == $smokePrincipalId and .role == "Viewer")
  ' <<< "$(sed -n 's/^POST //p' "${request_log}" | jq -s '.')" >/dev/null \
  || qam_fail "the separate smoke principal must receive only Viewer"
jq -e '
  .smokeMinimumRole == "Viewer" and
  .smokeObservedRole == "Viewer"
' "${receipt_file}" >/dev/null \
  || qam_fail "the separate smoke receipt must report Viewer"

run_access runtime-none-smoke-updater "${receipt_file}" "${request_log}" \
  --runtime-role Contributor \
  --smoke-principal-id "${smoke_principal_id}" \
  --definition-updater-principal-id "${smoke_principal_id}"
jq -e \
  --arg smokePrincipalId "${smoke_principal_id}" '
    length == 2 and
    ([.[] | select(.principal.id == $smokePrincipalId)] | length == 1) and
    all(.[]; .role == "Contributor")
  ' <<< "$(sed -n 's/^POST //p' "${request_log}" | jq -s '.')" >/dev/null \
  || qam_fail "one smoke/updater principal must receive one Contributor assignment"
jq -e '
  .smokeMinimumRole == "Contributor" and
  .smokeObservedRole == "Contributor" and
  .definitionUpdaterMinimumRole == "Contributor" and
  .definitionUpdaterObservedRole == "Contributor"
' "${receipt_file}" >/dev/null \
  || qam_fail "the combined smoke/updater receipt must report Contributor"

qam_info "Fabric access role tests completed"
