#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

cleanup_script="${QAM_SCRIPTS_DIR}/finalize-fabric-definition-updater.sh"
workspace_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
principal_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
assignment_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
second_assignment_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
other_principal_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
request_log="${test_dir}/requests.log"

# shellcheck disable=SC2329 # Exported into each isolated cleanup process.
az() {
  case "${1:-}:${2:-}:${3:-}" in
    account:show:*) return 0 ;;
    account:get-access-token:*) printf '%s\n' 'mock-fabric-token' ;;
    ad:sp:show)
      if [ "${QAM_TEST_SCENARIO:-}" = 'client-id' ]; then
        printf '%s\n' "${QAM_TEST_OTHER_PRINCIPAL_ID:?}"
      else
        printf '%s\n' "${5:?missing service-principal object ID}"
      fi
      ;;
    *) printf 'unexpected az command: %s\n' "$*" >&2; return 2 ;;
  esac
}

# shellcheck disable=SC2329 # Called by the exported curl mock.
write_assignment() {
  local selected_assignment_id="$1"
  local selected_principal_id="$2"
  local role="$3"
  local principal_type="${4:-ServicePrincipal}"

  jq -cn \
    --arg assignmentId "${selected_assignment_id}" \
    --arg principalId "${selected_principal_id}" \
    --arg role "${role}" \
    --arg principalType "${principal_type}" \
    '{id: $assignmentId,
      principal: {id: $principalId, type: $principalType},
      role: $role}'
}

# shellcheck disable=SC2329 # Exported into each isolated cleanup process.
curl() {
  local method='GET'
  local output_file=''
  local headers_file=''
  local data=''
  local url=''
  local argument
  local connect_timeout=''
  local request_timeout=''
  local base_url
  local list_count
  local exact_count
  local patch_count
  local role

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --silent | --show-error) shift ;;
      --proto | --header | --write-out) shift 2 ;;
      --connect-timeout) connect_timeout="${2:?}"; shift 2 ;;
      --max-time) request_timeout="${2:?}"; shift 2 ;;
      --request) method="${2:?}"; shift 2 ;;
      --dump-header) headers_file="${2:?}"; shift 2 ;;
      --output) output_file="${2:?}"; shift 2 ;;
      --data-binary) data="${2:?}"; shift 2 ;;
      https://*) url="$1"; shift ;;
      *) argument="$1"; printf 'unexpected curl argument: %s\n' "${argument}" >&2; return 2 ;;
    esac
  done
  [ -n "${output_file}" ] && [ -n "${headers_file}" ] && [ -n "${url}" ] \
    && [ -n "${connect_timeout}" ] && [ -n "${request_timeout}" ]
  : > "${headers_file}"
  printf '%s %s\n' "${method}" "${url}" >> "${QAM_TEST_REQUEST_LOG:?}"
  base_url="https://api.fabric.microsoft.com/v1/workspaces/${QAM_TEST_WORKSPACE_ID:?}/roleAssignments"

  if [ "${method}" = 'GET' ] && [ "${url}" = "${base_url}" ]; then
    list_count="$(grep -Fxc "GET ${base_url}" "${QAM_TEST_REQUEST_LOG}")"
    case "${QAM_TEST_SCENARIO:?}" in
      list-429-once | retry-after-too-long)
        if [ "${list_count}" -eq 1 ]; then
          if [ "${QAM_TEST_SCENARIO}" = 'retry-after-too-long' ]; then
            printf 'Retry-After: 301\r\n' > "${headers_file}"
          else
            printf 'Retry-After: 0\r\n' > "${headers_file}"
          fi
          printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
          printf '429'
          return
        fi
        ;;
      malformed-page)
        printf '%s\n' '{"value":{}}' > "${output_file}"
        printf '200'
        return
        ;;
      token-without-uri)
        printf '%s\n' '{"value":[],"continuationToken":"next"}' > "${output_file}"
        printf '200'
        return
        ;;
      cross-origin-pagination)
        printf '%s\n' '{"value":[],"continuationUri":"https://example.invalid/roleAssignments?continuationToken=next"}' > "${output_file}"
        printf '200'
        return
        ;;
      conflicting-pagination)
        jq -cn \
          --arg continuationUri "${base_url}?continuationToken=one" \
          --arg nextLink "${base_url}?continuationToken=two" \
          '{value: [], continuationToken: "next", continuationUri: $continuationUri, "@odata.nextLink": $nextLink}' \
          > "${output_file}"
        printf '200'
        return
        ;;
      duplicate-pagination)
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_PRINCIPAL_ID:?}" Contributor)" \
          --arg continuationUri "${base_url}?continuationToken=next" \
          '{value: [$assignment], continuationToken: "next", continuationUri: $continuationUri}' \
          > "${output_file}"
        printf '200'
        return
        ;;
    esac

    case "${QAM_TEST_SCENARIO}" in
      missing)
        printf '%s\n' '{"value":[]}' > "${output_file}"
        printf '200'
        return
        ;;
      duplicate | preupdate-duplicate)
        if [ "${QAM_TEST_SCENARIO}" = 'duplicate' ] \
          || [ "${list_count}" -ge 2 ]; then
          jq -cn \
            --argjson first "$(write_assignment \
              "${QAM_TEST_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_PRINCIPAL_ID:?}" Contributor)" \
            --argjson second "$(write_assignment \
              "${QAM_TEST_SECOND_ASSIGNMENT_ID:?}" \
              "${QAM_TEST_PRINCIPAL_ID:?}" Contributor)" \
            '{value: [$first, $second]}' > "${output_file}"
          printf '200'
          return
        fi
        ;;
      malformed-type)
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_PRINCIPAL_ID:?}" Contributor User)" \
          '{value: [$assignment]}' > "${output_file}"
        printf '200'
        return
        ;;
      malformed-role)
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_PRINCIPAL_ID:?}" Unknown)" \
          '{value: [$assignment]}' > "${output_file}"
        printf '200'
        return
        ;;
      member | admin)
        role='Member'
        [ "${QAM_TEST_SCENARIO}" != 'admin' ] || role='Admin'
        jq -cn \
          --argjson assignment "$(write_assignment \
            "${QAM_TEST_ASSIGNMENT_ID:?}" \
            "${QAM_TEST_PRINCIPAL_ID:?}" "${role}")" \
          '{value: [$assignment]}' > "${output_file}"
        printf '200'
        return
        ;;
      final-duplicate | final-member | final-missing | final-missing-once)
        if grep -Fq "PATCH ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_REQUEST_LOG}"; then
          case "${QAM_TEST_SCENARIO}" in
            final-duplicate)
              jq -cn \
                --argjson first "$(write_assignment \
                  "${QAM_TEST_ASSIGNMENT_ID:?}" \
                  "${QAM_TEST_PRINCIPAL_ID:?}" Viewer)" \
                --argjson second "$(write_assignment \
                  "${QAM_TEST_SECOND_ASSIGNMENT_ID:?}" \
                  "${QAM_TEST_PRINCIPAL_ID:?}" Viewer)" \
                '{value: [$first, $second]}' > "${output_file}"
              ;;
            final-member)
              jq -cn \
                --argjson assignment "$(write_assignment \
                  "${QAM_TEST_ASSIGNMENT_ID:?}" \
                  "${QAM_TEST_PRINCIPAL_ID:?}" Member)" \
                '{value: [$assignment]}' > "${output_file}"
              ;;
            final-missing) printf '%s\n' '{"value":[]}' > "${output_file}" ;;
            final-missing-once)
              if [ "${list_count}" -eq 3 ]; then
                printf '%s\n' '{"value":[]}' > "${output_file}"
              else
                role='Viewer'
                jq -cn \
                  --argjson assignment "$(write_assignment \
                    "${QAM_TEST_ASSIGNMENT_ID:?}" \
                    "${QAM_TEST_PRINCIPAL_ID:?}" "${role}")" \
                  '{value: [$assignment]}' > "${output_file}"
              fi
              ;;
          esac
          printf '200'
          return
        fi
        ;;
    esac

    role='Contributor'
    case "${QAM_TEST_SCENARIO}" in
      viewer) role='Viewer' ;;
      patch-429-once)
        patch_count="$(grep -Fc "PATCH ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_REQUEST_LOG}" || true)"
        [ "${patch_count}" -lt 2 ] || role='Viewer'
        ;;
      patch-429-applied | happy | uppercase | list-429-once | stale-final | \
        mixed-final-once | final-missing-once | final-exact-missing-once)
        if grep -Fq "PATCH ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_REQUEST_LOG}"; then
          role='Viewer'
        fi
        if [ "${QAM_TEST_SCENARIO}" = 'stale-final' ] \
          && [ "${list_count}" -eq 3 ]; then
          role='Contributor'
        fi
        ;;
    esac
    jq -cn \
      --argjson assignment "$(write_assignment \
        "${QAM_TEST_ASSIGNMENT_ID:?}" \
        "${QAM_TEST_PRINCIPAL_ID:?}" "${role}")" \
      '{value: [$assignment]}' > "${output_file}"
    printf '200'
    return
  fi

  if [ "${method}" = 'GET' ] \
    && [ "${url}" = "${base_url}?continuationToken=next" ]; then
    [ "${QAM_TEST_SCENARIO:?}" = 'duplicate-pagination' ]
    jq -cn \
      --argjson assignment "$(write_assignment \
        "${QAM_TEST_SECOND_ASSIGNMENT_ID:?}" \
        "${QAM_TEST_PRINCIPAL_ID:?}" Contributor)" \
      '{value: [$assignment]}' > "${output_file}"
    printf '200'
    return
  fi

  if [ "${method}" = 'GET' ] \
    && [ "${url}" = "${base_url}/${QAM_TEST_ASSIGNMENT_ID:?}" ]; then
    exact_count="$(grep -Fxc "GET ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
      "${QAM_TEST_REQUEST_LOG}")"
    role='Contributor'
    case "${QAM_TEST_SCENARIO:?}" in
      viewer) role='Viewer' ;;
      exact-member) role='Member' ;;
      patch-429-once)
        patch_count="$(grep -Fc "PATCH ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_REQUEST_LOG}" || true)"
        [ "${patch_count}" -lt 2 ] || role='Viewer'
        ;;
      patch-429-applied | happy | uppercase | list-429-once | stale-final | \
        mixed-final-once | final-missing-once | final-exact-missing-once)
        if grep -Fq "PATCH ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_REQUEST_LOG}"; then
          role='Viewer'
        fi
        if [ "${QAM_TEST_SCENARIO}" = 'stale-final' ] \
          && [ "${exact_count}" -eq 3 ]; then
          role='Contributor'
        fi
        if [ "${QAM_TEST_SCENARIO}" = 'mixed-final-once' ] \
          && [ "${exact_count}" -eq 3 ]; then
          role='Contributor'
        fi
        if [ "${QAM_TEST_SCENARIO}" = 'final-exact-missing-once' ] \
          && [ "${exact_count}" -eq 3 ]; then
          printf '%s\n' '{"errorCode":"ItemNotFound"}' > "${output_file}"
          printf '404'
          return
        fi
        ;;
    esac
    write_assignment \
      "${QAM_TEST_ASSIGNMENT_ID}" \
      "${QAM_TEST_PRINCIPAL_ID}" \
      "${role}" > "${output_file}"
    printf '200'
    return
  fi

  if [ "${method}" = 'PATCH' ] \
    && [ "${url}" = "${base_url}/${QAM_TEST_ASSIGNMENT_ID:?}" ]; then
    jq -e '.role == "Viewer" and (keys == ["role"])' <<< "${data}" >/dev/null
    patch_count="$(grep -Fc "PATCH ${base_url}/${QAM_TEST_ASSIGNMENT_ID}" \
      "${QAM_TEST_REQUEST_LOG}")"
    case "${QAM_TEST_SCENARIO:?}" in
      patch-429-once)
        if [ "${patch_count}" -eq 1 ]; then
          printf 'Retry-After: 0\r\n' > "${headers_file}"
          printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
          printf '429'
          return
        fi
        ;;
      patch-429-applied)
        printf 'Retry-After: 0\r\n' > "${headers_file}"
        printf '%s\n' '{"errorCode":"TooManyRequests"}' > "${output_file}"
        printf '429'
        return
        ;;
      patch-bad-status)
        write_assignment \
          "${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_PRINCIPAL_ID}" Viewer > "${output_file}"
        printf '201'
        return
        ;;
      patch-bad-body)
        write_assignment \
          "${QAM_TEST_ASSIGNMENT_ID}" \
          "${QAM_TEST_PRINCIPAL_ID}" Contributor > "${output_file}"
        printf '200'
        return
        ;;
    esac
    write_assignment \
      "${QAM_TEST_ASSIGNMENT_ID}" \
      "${QAM_TEST_PRINCIPAL_ID}" Viewer > "${output_file}"
    printf '200'
    return
  fi

  printf 'unexpected Fabric request: %s %s\n' "${method}" "${url}" >&2
  return 2
}

export -f az curl write_assignment
export QAM_TEST_WORKSPACE_ID="${workspace_id}"
export QAM_TEST_PRINCIPAL_ID="${principal_id}"
export QAM_TEST_ASSIGNMENT_ID="${assignment_id}"
export QAM_TEST_SECOND_ASSIGNMENT_ID="${second_assignment_id}"
export QAM_TEST_OTHER_PRINCIPAL_ID="${other_principal_id}"

run_cleanup() {
  local scenario="$1"
  local selected_principal_id="${2:-${principal_id}}"

  : > "${request_log}"
  QAM_TEST_SCENARIO="${scenario}" \
  QAM_TEST_REQUEST_LOG="${request_log}" \
  QAM_FABRIC_ROLE_RETRY_ATTEMPTS=3 \
  QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS=0 \
  QAM_FABRIC_ROLE_MAX_RETRY_AFTER_SECONDS=300 \
  QAM_FABRIC_CONNECT_TIMEOUT_SECONDS=2 \
  QAM_FABRIC_REQUEST_TIMEOUT_SECONDS=5 \
    bash "${cleanup_script}" \
      --workspace-id "${workspace_id}" \
      --definition-updater-principal-id "${selected_principal_id}"
}

expect_cleanup_failure() {
  local scenario="$1"

  if run_cleanup "${scenario}" >/dev/null 2>&1; then
    qam_fail "definition-updater cleanup negative test unexpectedly passed: ${scenario}"
  fi
}

receipt="$(run_cleanup happy)"
jq -e \
  --arg workspaceId "${workspace_id}" \
  --arg principalId "${principal_id}" \
  --arg assignmentId "${assignment_id}" '
    .schemaVersion == "qam-fabric-role-cleanup/1.0" and
    .workspaceId == $workspaceId and
    .definitionUpdaterPrincipalId == $principalId and
    .assignmentId == $assignmentId and
    .initialRole == "Contributor" and
    .finalRole == "Viewer" and
    .changed == true and
    .verified == true and
    .exactAssignmentCount == 1 and
    .principalType == "ServicePrincipal"
  ' <<< "${receipt}" >/dev/null \
  || qam_fail "definition-updater cleanup returned an invalid transition receipt"
[ "$(grep -Fc "PATCH https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments/${assignment_id}" "${request_log}")" -eq 1 ] \
  || qam_fail "definition-updater cleanup must use exactly one atomic PATCH in the normal transition"

receipt="$(run_cleanup viewer)"
jq -e '.initialRole == "Viewer" and .finalRole == "Viewer" and .changed == false and .verified == true' \
  <<< "${receipt}" >/dev/null \
  || qam_fail "definition-updater cleanup is not idempotent for an exact Viewer assignment"
if grep -q '^PATCH ' "${request_log}"; then
  qam_fail "definition-updater cleanup must not PATCH an already-Viewer assignment"
fi

uppercase_principal_id="$(printf '%s' "${principal_id}" | tr '[:lower:]' '[:upper:]')"
receipt="$(run_cleanup uppercase "${uppercase_principal_id}")"
jq -e --arg principalId "${uppercase_principal_id}" \
  '.definitionUpdaterPrincipalId == $principalId and .finalRole == "Viewer"' \
  <<< "${receipt}" >/dev/null \
  || qam_fail "definition-updater cleanup must match UUIDs case-insensitively"

for scenario in \
  list-429-once \
  patch-429-once \
  patch-429-applied \
  stale-final \
  mixed-final-once \
  final-missing-once \
  final-exact-missing-once; do
  receipt="$(run_cleanup "${scenario}")"
  jq -e '.initialRole == "Contributor" and .finalRole == "Viewer" and .changed == true and .verified == true' \
    <<< "${receipt}" >/dev/null \
    || qam_fail "definition-updater cleanup did not reconcile retry scenario: ${scenario}"
done
[ "$(grep -c '^PATCH ' "${request_log}")" -eq 1 ] \
  || qam_fail "stale final reads must not repeat a successful role PATCH"

for scenario in \
  missing \
  duplicate \
  duplicate-pagination \
  malformed-type \
  malformed-role \
  malformed-page \
  member \
  admin \
  exact-member \
  preupdate-duplicate \
  token-without-uri \
  cross-origin-pagination \
  conflicting-pagination \
  retry-after-too-long; do
  expect_cleanup_failure "${scenario}"
  if grep -q '^PATCH ' "${request_log}"; then
    qam_fail "definition-updater cleanup mutated the role after failed preflight: ${scenario}"
  fi
done

for scenario in \
  patch-bad-status \
  patch-bad-body \
  final-duplicate \
  final-member \
  final-missing; do
  expect_cleanup_failure "${scenario}"
done

: > "${request_log}"
if QAM_TEST_SCENARIO='client-id' \
  QAM_TEST_REQUEST_LOG="${request_log}" \
  QAM_FABRIC_ROLE_RETRY_ATTEMPTS=3 \
  QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS=0 \
  QAM_FABRIC_ROLE_MAX_RETRY_AFTER_SECONDS=300 \
  QAM_FABRIC_CONNECT_TIMEOUT_SECONDS=2 \
  QAM_FABRIC_REQUEST_TIMEOUT_SECONDS=5 \
    bash "${cleanup_script}" \
      --workspace-id "${workspace_id}" \
      --definition-updater-principal-id "${principal_id}" >/dev/null 2>&1; then
  qam_fail "definition-updater cleanup accepted an application/client ID in place of the service-principal object ID"
fi
[ ! -s "${request_log}" ] \
  || qam_fail "definition-updater cleanup reached Fabric before rejecting a non-object principal ID"

qam_info "Fabric definition-updater acceptance-cleanup tests passed"
