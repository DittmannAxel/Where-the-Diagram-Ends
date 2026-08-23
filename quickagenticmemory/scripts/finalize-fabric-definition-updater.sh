#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
definition_updater_principal_id=""

usage() {
  printf '%s\n' \
    'Usage: finalize-fabric-definition-updater.sh --workspace-id UUID --definition-updater-principal-id UUID' \
    '' \
    'Downgrades exactly one temporary Fabric workspace ServicePrincipal assignment' \
    'from Contributor to Viewer after acceptance. An already-Viewer assignment is' \
    'accepted idempotently. Missing, duplicate, malformed, Member, and Admin' \
    'assignments fail closed and are never created, deleted, or downgraded.' \
    '' \
    'The signed-in operator must have delegated Workspace.ReadWrite.All and the' \
    'workspace Admin role required by the Fabric role-assignment update API.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --definition-updater-principal-id)
      definition_updater_principal_id="${2:?missing value for $1}"
      shift 2
      ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${definition_updater_principal_id}" ] \
  || qam_fail "--definition-updater-principal-id is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid \
  "${definition_updater_principal_id}" "definition updater principal ID"

qam_require_azure_login
qam_require_command curl
qam_require_command jq

if ! resolved_principal_id="$(az ad sp show \
  --id "${definition_updater_principal_id}" \
  --query id \
  --output tsv)"; then
  qam_fail "definition updater principal is not an Entra service principal"
fi
qam_validate_uuid "${resolved_principal_id}" \
  "resolved definition updater principal object ID"
[ "$(printf '%s' "${resolved_principal_id}" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "${definition_updater_principal_id}" | tr '[:upper:]' '[:lower:]')" ] \
  || qam_fail "definition updater principal must be the service-principal object ID, not an application/client ID"

access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] \
  || qam_fail "could not acquire a Microsoft Fabric access token"

fabric_role_retry_attempts="${QAM_FABRIC_ROLE_RETRY_ATTEMPTS:-8}"
fabric_role_retry_delay_seconds="${QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS:-3}"
fabric_role_max_retry_after_seconds="${QAM_FABRIC_ROLE_MAX_RETRY_AFTER_SECONDS:-300}"
fabric_connect_timeout_seconds="${QAM_FABRIC_CONNECT_TIMEOUT_SECONDS:-10}"
fabric_request_timeout_seconds="${QAM_FABRIC_REQUEST_TIMEOUT_SECONDS:-60}"
printf '%s' "${fabric_role_retry_attempts}" | grep -Eq '^[1-9][0-9]?$' \
  || qam_fail "QAM_FABRIC_ROLE_RETRY_ATTEMPTS must be an integer from 1 to 20"
[ "${fabric_role_retry_attempts}" -le 20 ] \
  || qam_fail "QAM_FABRIC_ROLE_RETRY_ATTEMPTS must be an integer from 1 to 20"
printf '%s' "${fabric_role_retry_delay_seconds}" | grep -Eq '^[0-9]+$' \
  || qam_fail "QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS must be an integer from 0 to 30"
[ "${fabric_role_retry_delay_seconds}" -le 30 ] \
  || qam_fail "QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS must be an integer from 0 to 30"
printf '%s' "${fabric_role_max_retry_after_seconds}" | grep -Eq '^[0-9]+$' \
  || qam_fail "QAM_FABRIC_ROLE_MAX_RETRY_AFTER_SECONDS must be an integer from 0 to 3600"
[ "${fabric_role_max_retry_after_seconds}" -le 3600 ] \
  || qam_fail "QAM_FABRIC_ROLE_MAX_RETRY_AFTER_SECONDS must be an integer from 0 to 3600"
[ "${fabric_role_max_retry_after_seconds}" -ge "${fabric_role_retry_delay_seconds}" ] \
  || qam_fail "QAM_FABRIC_ROLE_MAX_RETRY_AFTER_SECONDS must not be below QAM_FABRIC_ROLE_RETRY_DELAY_SECONDS"
printf '%s' "${fabric_connect_timeout_seconds}" | grep -Eq '^[1-9][0-9]*$' \
  || qam_fail "QAM_FABRIC_CONNECT_TIMEOUT_SECONDS must be an integer from 1 to 300"
[ "${fabric_connect_timeout_seconds}" -le 300 ] \
  || qam_fail "QAM_FABRIC_CONNECT_TIMEOUT_SECONDS must be an integer from 1 to 300"
printf '%s' "${fabric_request_timeout_seconds}" | grep -Eq '^[1-9][0-9]*$' \
  || qam_fail "QAM_FABRIC_REQUEST_TIMEOUT_SECONDS must be an integer from 1 to 900"
[ "${fabric_request_timeout_seconds}" -le 900 ] \
  || qam_fail "QAM_FABRIC_REQUEST_TIMEOUT_SECONDS must be an integer from 1 to 900"
[ "${fabric_request_timeout_seconds}" -ge "${fabric_connect_timeout_seconds}" ] \
  || qam_fail "QAM_FABRIC_REQUEST_TIMEOUT_SECONDS must not be below QAM_FABRIC_CONNECT_TIMEOUT_SECONDS"

cleanup_tmp_dir="$(mktemp -d)"
trap 'rm -rf "${cleanup_tmp_dir}"' EXIT

wait_before_fabric_retry() {
  local delay_seconds="${1:-${fabric_role_retry_delay_seconds}}"

  printf '%s' "${delay_seconds}" | grep -Eq '^[0-9]+$' \
    || qam_fail "Fabric Retry-After is not a supported non-negative delta-seconds value; refusing an early retry"
  [ "${delay_seconds}" -le "${fabric_role_max_retry_after_seconds}" ] \
    || qam_fail "Fabric Retry-After exceeds the configured safe wait limit; refusing an early retry"
  if [ "${delay_seconds}" -gt 0 ]; then
    sleep "${delay_seconds}"
  fi
}

fabric_request_once() {
  local response_file="$1"
  local headers_file="$2"
  shift 2
  local status

  : > "${headers_file}"
  if ! status="$(curl \
    --silent \
    --show-error \
    --proto '=https' \
    --connect-timeout "${fabric_connect_timeout_seconds}" \
    --max-time "${fabric_request_timeout_seconds}" \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Accept: application/json' \
    --dump-header "${headers_file}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "$@")"; then
    qam_fail "Fabric role-assignment request failed before an HTTP response"
  fi
  printf '%s' "${status}"
}

fabric_retry_after() {
  local headers_file="$1"

  awk '
    tolower($1) == "retry-after:" {
      gsub("\\r", "", $2)
      print $2
      exit
    }
  ' "${headers_file}"
}

fabric_read() {
  local response_file="$1"
  shift
  local headers_file="${cleanup_tmp_dir}/read-headers"
  local retry_after
  local status
  local attempt=1

  while :; do
    status="$(fabric_request_once "${response_file}" "${headers_file}" "$@")"
    if [ "${status}" != "429" ] \
      || [ "${attempt}" -ge "${fabric_role_retry_attempts}" ]; then
      break
    fi
    retry_after="$(fabric_retry_after "${headers_file}")"
    qam_info "Fabric role API returned 429; retrying read (${attempt}/${fabric_role_retry_attempts})"
    wait_before_fabric_retry \
      "${retry_after:-${fabric_role_retry_delay_seconds}}"
    attempt=$((attempt + 1))
  done
  printf '%s' "${status}"
}

workspace_assignments='[]'
load_workspace_assignments() {
  local accumulated='[]'
  local continuation_token
  local next_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments"
  local page_count=0
  local response_file
  local status

  while [ -n "${next_url}" ]; do
    printf '%s' "${next_url}" \
      | grep -Eq "^https://api\\.fabric\\.microsoft\\.com/v1/workspaces/${workspace_id}/roleAssignments([?].*)?$" \
      || qam_fail "Fabric pagination URL left the expected HTTPS workspace roleAssignments endpoint"
    page_count=$((page_count + 1))
    [ "${page_count}" -le 100 ] \
      || qam_fail "Fabric role-assignment pagination exceeded 100 pages"
    response_file="${cleanup_tmp_dir}/role-page-${page_count}.json"
    status="$(fabric_read "${response_file}" "${next_url}")"
    if [ "${status}" != "200" ]; then
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "listing Fabric workspace role assignments returned HTTP ${status}"
    fi
    jq -e '
      (.value | type == "array") and
      all(.value[]; type == "object") and
      ((has("continuationToken") | not) or
        ((.continuationToken | type) == "string" and (.continuationToken | length) > 0)) and
      ((has("continuationUri") | not) or (.continuationUri | type) == "string") and
      ((has("@odata.nextLink") | not) or (."@odata.nextLink" | type) == "string") and
      ((has("continuationUri") and has("@odata.nextLink") | not) or
        .continuationUri == ."@odata.nextLink")
    ' "${response_file}" >/dev/null \
      || qam_fail "Fabric workspace role-assignment response has an invalid page contract"
    accumulated="$(jq -cn \
      --argjson current "${accumulated}" \
      --slurpfile page "${response_file}" \
      '$current + $page[0].value')"
    continuation_token="$(jq -r '.continuationToken // empty' "${response_file}")"
    next_url="$(jq -r '.continuationUri // ."@odata.nextLink" // empty' "${response_file}")"
    if [ -n "${continuation_token}" ] && [ -z "${next_url}" ]; then
      qam_fail "Fabric role-assignment page has a continuation token without a continuation URL"
    fi
  done
  workspace_assignments="${accumulated}"
}

target_assignment_id=""
target_assignment_role=""
select_exact_target_assignment() {
  local phase="$1"
  local allow_missing="${2:-false}"
  local assignments
  local assignment_count
  local candidate

  assignments="$(jq -c --arg id "${definition_updater_principal_id}" '
    [.[] | select(
      ((.principal.id? | type) == "string") and
      ((.principal.id | ascii_downcase) == ($id | ascii_downcase))
    )]
  ' <<< "${workspace_assignments}")"
  assignment_count="$(jq -r 'length' <<< "${assignments}")"
  if [ "${assignment_count}" -eq 0 ] && [ "${allow_missing}" = 'true' ]; then
    target_assignment_id=""
    target_assignment_role=""
    return 1
  fi
  [ "${assignment_count}" -eq 1 ] \
    || qam_fail "${phase}: definition updater has ${assignment_count} Fabric role assignments; expected exactly one"
  candidate="$(jq -c '.[0]' <<< "${assignments}")"
  jq -e \
    --arg principalId "${definition_updater_principal_id}" '
      ((.id? | type) == "string") and
      (.id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) and
      ((.principal.id? | type) == "string") and
      ((.principal.id | ascii_downcase) == ($principalId | ascii_downcase)) and
      .principal.type == "ServicePrincipal" and
      (.role == "Viewer" or .role == "Contributor" or .role == "Member" or .role == "Admin")
    ' <<< "${candidate}" >/dev/null \
    || qam_fail "${phase}: definition updater assignment is malformed"
  target_assignment_id="$(jq -r '.id' <<< "${candidate}")"
  target_assignment_role="$(jq -r '.role' <<< "${candidate}")"
}

exact_assignment_role=""
get_exact_assignment() {
  local assignment_id="$1"
  local phase="$2"
  local allow_missing="${3:-false}"
  local response_file="${cleanup_tmp_dir}/exact-assignment.json"
  local status

  status="$(fabric_read \
    "${response_file}" \
    "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments/${assignment_id}")"
  if [ "${status}" = "404" ] && [ "${allow_missing}" = 'true' ]; then
    exact_assignment_role=""
    return 1
  fi
  if [ "${status}" != "200" ]; then
    sed -n '1,40p' "${response_file}" >&2
    qam_fail "${phase}: getting the exact Fabric role assignment returned HTTP ${status}"
  fi
  jq -e \
    --arg assignmentId "${assignment_id}" \
    --arg principalId "${definition_updater_principal_id}" '
      ((.id? | type) == "string") and
      ((.id | ascii_downcase) == ($assignmentId | ascii_downcase)) and
      ((.principal.id? | type) == "string") and
      ((.principal.id | ascii_downcase) == ($principalId | ascii_downcase)) and
      .principal.type == "ServicePrincipal" and
      (.role == "Viewer" or .role == "Contributor" or .role == "Member" or .role == "Admin")
    ' "${response_file}" >/dev/null \
    || qam_fail "${phase}: exact definition updater assignment is malformed or changed principal"
  exact_assignment_role="$(jq -r '.role' "${response_file}")"
}

reject_broader_or_unknown_role() {
  local role="$1"
  local phase="$2"

  case "${role}" in
    Viewer | Contributor) ;;
    Member | Admin)
      qam_fail "${phase}: definition updater has broader ${role} access; refusing to downgrade it"
      ;;
    *) qam_fail "${phase}: definition updater has an unsupported Fabric role" ;;
  esac
}

assignment_id=""
initial_role=""
changed='false'

load_workspace_assignments
select_exact_target_assignment "cleanup preflight"
assignment_id="${target_assignment_id}"
initial_role="${target_assignment_role}"
reject_broader_or_unknown_role "${initial_role}" "cleanup preflight"

get_exact_assignment "${assignment_id}" "cleanup preflight"
reject_broader_or_unknown_role "${exact_assignment_role}" "cleanup preflight"

if [ "${exact_assignment_role}" = "Contributor" ]; then
  # Re-list immediately before the first mutation. The public API has no ETag
  # precondition for role updates, so both collection and exact-item state are
  # checked as closely as possible before the atomic PATCH.
  load_workspace_assignments
  select_exact_target_assignment "pre-update reconcile"
  [ "$(printf '%s' "${target_assignment_id}" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "${assignment_id}" | tr '[:upper:]' '[:lower:]')" ] \
    || qam_fail "pre-update reconcile: definition updater assignment ID changed"
  reject_broader_or_unknown_role \
    "${target_assignment_role}" "pre-update reconcile"
  get_exact_assignment "${assignment_id}" "pre-update reconcile"
  reject_broader_or_unknown_role \
    "${exact_assignment_role}" "pre-update reconcile"

  if [ "${target_assignment_role}" = "Contributor" ] \
    && [ "${exact_assignment_role}" = "Contributor" ]; then
    patch_response_file="${cleanup_tmp_dir}/patch-response.json"
    patch_headers_file="${cleanup_tmp_dir}/patch-headers"
    patch_body='{"role":"Viewer"}'
    patch_attempt=1

    while :; do
      patch_status="$(fabric_request_once \
        "${patch_response_file}" \
        "${patch_headers_file}" \
        --request PATCH \
        --header 'Content-Type: application/json' \
        --data-binary "${patch_body}" \
        "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments/${assignment_id}")"
      if [ "${patch_status}" != "429" ]; then
        break
      fi

      retry_after="$(fabric_retry_after "${patch_headers_file}")"
      qam_info "Fabric Viewer update returned 429; reconciling live state before retry (${patch_attempt}/${fabric_role_retry_attempts})"
      wait_before_fabric_retry \
        "${retry_after:-${fabric_role_retry_delay_seconds}}"
      reconcile_attempt=1
      while :; do
        load_workspace_assignments
        if ! select_exact_target_assignment \
          "throttled-update reconcile" true; then
          if [ "${reconcile_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
            qam_fail "throttled-update reconcile: definition updater assignment remained missing after ${reconcile_attempt} reads"
          fi
          qam_info "throttled-update reconcile temporarily found no assignment; retrying (${reconcile_attempt}/${fabric_role_retry_attempts})"
          wait_before_fabric_retry
          reconcile_attempt=$((reconcile_attempt + 1))
          continue
        fi
        [ "$(printf '%s' "${target_assignment_id}" | tr '[:upper:]' '[:lower:]')" = \
          "$(printf '%s' "${assignment_id}" | tr '[:upper:]' '[:lower:]')" ] \
          || qam_fail "throttled-update reconcile: definition updater assignment ID changed"
        reject_broader_or_unknown_role \
          "${target_assignment_role}" "throttled-update reconcile"
        if ! get_exact_assignment \
          "${assignment_id}" "throttled-update reconcile" true; then
          if [ "${reconcile_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
            qam_fail "throttled-update reconcile: exact assignment remained missing after ${reconcile_attempt} reads"
          fi
          qam_info "throttled-update reconcile exact assignment is not visible yet; retrying (${reconcile_attempt}/${fabric_role_retry_attempts})"
          wait_before_fabric_retry
          reconcile_attempt=$((reconcile_attempt + 1))
          continue
        fi
        reject_broader_or_unknown_role \
          "${exact_assignment_role}" "throttled-update reconcile"
        if [ "${target_assignment_role}" = "${exact_assignment_role}" ]; then
          break
        fi
        if [ "${reconcile_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
          qam_fail "throttled-update reconcile: collection and exact assignment roles did not converge"
        fi
        qam_info "throttled-update reconcile reads are eventually consistent; retrying (${reconcile_attempt}/${fabric_role_retry_attempts})"
        wait_before_fabric_retry
        reconcile_attempt=$((reconcile_attempt + 1))
      done
      if [ "${target_assignment_role}" = "Viewer" ] \
        && [ "${exact_assignment_role}" = "Viewer" ]; then
        changed='true'
        patch_status='200'
        jq -cn \
          --arg id "${assignment_id}" \
          --arg principalId "${definition_updater_principal_id}" \
          '{id: $id, principal: {id: $principalId, type: "ServicePrincipal"}, role: "Viewer"}' \
          > "${patch_response_file}"
        break
      fi
      [ "${target_assignment_role}" = "Contributor" ] \
        && [ "${exact_assignment_role}" = "Contributor" ] \
        || qam_fail "throttled-update reconcile: collection and exact assignment roles disagree"
      if [ "${patch_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
        qam_fail "Fabric Viewer update remained throttled after ${patch_attempt} attempts"
      fi
      patch_attempt=$((patch_attempt + 1))
    done

    if [ "${patch_status}" != "200" ]; then
      sed -n '1,40p' "${patch_response_file}" >&2
      qam_fail "downgrading Fabric Contributor to Viewer returned HTTP ${patch_status}"
    fi
    jq -e \
      --arg assignmentId "${assignment_id}" \
      --arg principalId "${definition_updater_principal_id}" '
        ((.id? | type) == "string") and
        ((.id | ascii_downcase) == ($assignmentId | ascii_downcase)) and
        ((.principal.id? | type) == "string") and
        ((.principal.id | ascii_downcase) == ($principalId | ascii_downcase)) and
        .principal.type == "ServicePrincipal" and
        .role == "Viewer"
      ' "${patch_response_file}" >/dev/null \
      || qam_fail "Fabric Viewer update returned an unexpected assignment"
    changed='true'
  fi
fi

final_role=""
verification_attempt=1
while :; do
  load_workspace_assignments
  if ! select_exact_target_assignment "final cleanup verification" true; then
    if [ "${verification_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
      qam_fail "final cleanup verification: definition updater assignment remained missing after ${verification_attempt} reads"
    fi
    qam_info "final cleanup verification temporarily found no assignment; retrying (${verification_attempt}/${fabric_role_retry_attempts})"
    wait_before_fabric_retry
    verification_attempt=$((verification_attempt + 1))
    continue
  fi
  [ "$(printf '%s' "${target_assignment_id}" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "${assignment_id}" | tr '[:upper:]' '[:lower:]')" ] \
    || qam_fail "final cleanup verification: definition updater assignment ID changed"
  reject_broader_or_unknown_role \
    "${target_assignment_role}" "final cleanup verification"
  if ! get_exact_assignment \
    "${assignment_id}" "final cleanup verification" true; then
    if [ "${verification_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
      qam_fail "final cleanup verification: exact assignment remained missing after ${verification_attempt} reads"
    fi
    qam_info "final cleanup verification exact assignment is not visible yet; retrying (${verification_attempt}/${fabric_role_retry_attempts})"
    wait_before_fabric_retry
    verification_attempt=$((verification_attempt + 1))
    continue
  fi
  reject_broader_or_unknown_role \
    "${exact_assignment_role}" "final cleanup verification"

  if [ "${target_assignment_role}" = "Viewer" ] \
    && [ "${exact_assignment_role}" = "Viewer" ]; then
    final_role='Viewer'
    break
  fi
  if [ "${verification_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
    qam_fail "Fabric definition updater did not converge to one exact Viewer after ${verification_attempt} reads"
  fi
  qam_info "Fabric definition updater cleanup has not fully propagated; retrying final verification (${verification_attempt}/${fabric_role_retry_attempts})"
  wait_before_fabric_retry
  verification_attempt=$((verification_attempt + 1))
done

jq -cn \
  --arg workspaceId "${workspace_id}" \
  --arg principalId "${definition_updater_principal_id}" \
  --arg assignmentId "${assignment_id}" \
  --arg initialRole "${initial_role}" \
  --arg finalRole "${final_role}" \
  --argjson changed "${changed}" \
  '{schemaVersion: "qam-fabric-role-cleanup/1.0",
    workspaceId: $workspaceId,
    definitionUpdaterPrincipalId: $principalId,
    assignmentId: $assignmentId,
    initialRole: $initialRole,
    finalRole: $finalRole,
    changed: $changed,
    verified: true,
    exactAssignmentCount: 1,
    principalType: "ServicePrincipal"}'
