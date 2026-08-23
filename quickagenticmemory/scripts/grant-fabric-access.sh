#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
runtime_principal_id=""
runtime_principal_key=""
runtime_role="Viewer"
smoke_principal_id=""
smoke_principal_key=""
definition_updater_principal_id=""
definition_updater_principal_key=""

usage() {
  printf '%s\n' \
    'Usage: grant-fabric-access.sh --workspace-id UUID --runtime-principal-id UUID [options]' \
    '' \
    'Options:' \
    '  --runtime-role Viewer|Contributor' \
    '      Default: Viewer. Contributor enables the observed Graph Preview service-principal workaround.' \
    '  --smoke-principal-id UUID' \
    '      Optionally grant the protected deployment identity Viewer for bounded GQL smoke tests.' \
    '  --definition-updater-principal-id UUID' \
    '      Optionally grant the deployment identity Contributor for definition updates.' \
    '' \
    'The signed-in operator must have delegated Workspace.ReadWrite.All. Adding roles needs' \
    'workspace Member or Admin; updating an existing Viewer to Contributor needs Admin.' \
    'A single Viewer is updated in place, and broader roles are never downgraded.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --runtime-principal-id) runtime_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --runtime-role) runtime_role="${2:?missing value for $1}"; shift 2 ;;
    --smoke-principal-id) smoke_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --definition-updater-principal-id) definition_updater_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${runtime_principal_id}" ] || qam_fail "--runtime-principal-id is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${runtime_principal_id}" "runtime principal ID"
runtime_principal_key="$(printf '%s' "${runtime_principal_id}" | tr '[:upper:]' '[:lower:]')"
case "${runtime_role}" in
  Viewer | Contributor) ;;
  *) qam_fail "--runtime-role must be Viewer or Contributor" ;;
esac
if [ -n "${smoke_principal_id}" ]; then
  qam_validate_uuid "${smoke_principal_id}" "smoke principal ID"
  smoke_principal_key="$(printf '%s' "${smoke_principal_id}" | tr '[:upper:]' '[:lower:]')"
  [ "${smoke_principal_key}" != "${runtime_principal_key}" ] \
    || qam_fail "smoke principal must be distinct from the runtime principal"
fi
if [ -n "${definition_updater_principal_id}" ]; then
  qam_validate_uuid "${definition_updater_principal_id}" "definition updater principal ID"
  definition_updater_principal_key="$(printf '%s' "${definition_updater_principal_id}" | tr '[:upper:]' '[:lower:]')"
  [ "${definition_updater_principal_key}" != "${runtime_principal_key}" ] \
    || qam_fail "definition updater must be distinct from the runtime principal"
fi

qam_require_azure_login
qam_require_command curl
qam_require_command jq
verify_service_principal_object_id() {
  local principal_id="$1"
  local label="$2"
  local resolved_id

  if ! resolved_id="$(az ad sp show \
    --id "${principal_id}" \
    --query id \
    --output tsv)"; then
    qam_fail "${label} is not an Entra service principal"
  fi
  qam_validate_uuid "${resolved_id}" "resolved ${label} object ID"
  [ "$(printf '%s' "${resolved_id}" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "${principal_id}" | tr '[:upper:]' '[:lower:]')" ] \
    || qam_fail "${label} must be the service-principal object ID, not an application/client ID"
}

verify_service_principal_object_id "${runtime_principal_id}" "runtime principal"
if [ -n "${smoke_principal_id}" ]; then
  verify_service_principal_object_id "${smoke_principal_id}" "smoke principal"
fi
if [ -n "${definition_updater_principal_id}" ]; then
  verify_service_principal_object_id \
    "${definition_updater_principal_id}" "definition updater principal"
fi

access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

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
  local headers_file
  local retry_after
  local status
  local attempt=1

  headers_file="$(mktemp)"
  while :; do
    status="$(fabric_request_once "${response_file}" "${headers_file}" "$@")"
    if [ "${status}" != "429" ] || [ "${attempt}" -ge "${fabric_role_retry_attempts}" ]; then
      break
    fi
    retry_after="$(fabric_retry_after "${headers_file}")"
    qam_info "Fabric role API returned 429; retrying read (${attempt}/${fabric_role_retry_attempts})"
    wait_before_fabric_retry "${retry_after:-${fabric_role_retry_delay_seconds}}"
    attempt=$((attempt + 1))
  done
  rm -f "${headers_file}"
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
    [ "${page_count}" -le 100 ] || qam_fail "Fabric role-assignment pagination exceeded 100 pages"
    response_file="$(mktemp)"
    status="$(fabric_read "${response_file}" "${next_url}")"
    if [ "${status}" != "200" ]; then
      sed -n '1,40p' "${response_file}" >&2
      rm -f "${response_file}"
      qam_fail "listing Fabric workspace role assignments returned HTTP ${status}"
    fi
    if ! jq -e '
      (.value | type == "array") and
      ((has("continuationToken") | not) or
        ((.continuationToken | type) == "string" and (.continuationToken | length) > 0)) and
      ((has("continuationUri") | not) or (.continuationUri | type) == "string") and
      ((has("@odata.nextLink") | not) or (."@odata.nextLink" | type) == "string")
    ' "${response_file}" >/dev/null; then
      rm -f "${response_file}"
      qam_fail "Fabric workspace role-assignment response has an invalid page contract"
    fi
    accumulated="$(jq -cn \
      --argjson current "${accumulated}" \
      --slurpfile page "${response_file}" \
      '$current + $page[0].value')"
    continuation_token="$(jq -r '.continuationToken // empty' "${response_file}")"
    next_url="$(jq -r '.continuationUri // ."@odata.nextLink" // empty' "${response_file}")"
    if [ -n "${continuation_token}" ] && [ -z "${next_url}" ]; then
      rm -f "${response_file}"
      qam_fail "Fabric role-assignment page has a continuation token without a continuation URL"
    fi
    rm -f "${response_file}"
  done
  workspace_assignments="${accumulated}"
}

load_workspace_assignments

principal_assignments() {
  local principal_id="$1"

  jq -c --arg id "${principal_id}" '
    [.[] | select(
      ((.principal.id? | type) == "string") and
      ((.principal.id | ascii_downcase) == ($id | ascii_downcase))
    )]
  ' <<< "${workspace_assignments}"
}

validate_assignment_file() {
  local response_file="$1"
  local assignment_id="$2"
  local principal_id="$3"

  jq -e \
    --arg assignmentId "${assignment_id}" \
    --arg principalId "${principal_id}" '
      ((.id? | type) == "string") and
      ((.id | ascii_downcase) == ($assignmentId | ascii_downcase)) and
      ((.principal.id? | type) == "string") and
      ((.principal.id | ascii_downcase) == ($principalId | ascii_downcase)) and
      .principal.type == "ServicePrincipal" and
      (.role == "Viewer" or .role == "Contributor" or .role == "Member" or .role == "Admin")
    ' "${response_file}" >/dev/null
}

replace_cached_assignment() {
  local assignment_id="$1"
  local replacement_file="$2"

  workspace_assignments="$(jq -cn \
    --argjson assignments "${workspace_assignments}" \
    --arg assignmentId "${assignment_id}" \
    --slurpfile replacement "${replacement_file}" '
      $assignments | map(
        if ((.id? // "") | ascii_downcase) == ($assignmentId | ascii_downcase)
        then $replacement[0]
        else .
        end
      )
    ')"
}

preflight_role() {
  local principal_id="$1"
  local desired_role="$2"
  local assignments
  local assignment_count
  local assignment_id
  local existing_role
  local principal_type

  assignments="$(principal_assignments "${principal_id}")"
  assignment_count="$(jq -r 'length' <<< "${assignments}")"
  [ "${assignment_count}" -le 1 ] \
    || qam_fail "principal ${principal_id} has ${assignment_count} Fabric role assignments; refusing ambiguous access"
  if [ "${assignment_count}" -eq 0 ]; then
    return
  fi

  assignment_id="$(jq -r '.[0].id // empty' <<< "${assignments}")"
  qam_validate_uuid "${assignment_id}" "Fabric role-assignment ID"
  principal_type="$(jq -r '.[0].principal.type // empty' <<< "${assignments}")"
  [ "${principal_type}" = "ServicePrincipal" ] \
    || qam_fail "Fabric assignment ${assignment_id} does not target a service principal"
  existing_role="$(jq -r '.[0].role // empty' <<< "${assignments}")"
  case "${existing_role}" in
    Viewer | Contributor | Member | Admin) ;;
    *) qam_fail "principal ${principal_id} has unexpected Fabric role: ${existing_role}" ;;
  esac
  case "${desired_role}:${existing_role}" in
    Viewer:* | Contributor:Viewer | Contributor:Contributor | Contributor:Member | Contributor:Admin) ;;
    *) qam_fail "unsupported Fabric role transition ${existing_role} to ${desired_role}" ;;
  esac
}

get_exact_assignment() {
  local assignment_id="$1"
  local response_file="$2"
  local status

  status="$(fabric_read \
    "${response_file}" \
    "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments/${assignment_id}")"
  if [ "${status}" != "200" ]; then
    sed -n '1,40p' "${response_file}" >&2
    qam_fail "getting Fabric role assignment ${assignment_id} returned HTTP ${status}"
  fi
}

upgrade_viewer_to_contributor() {
  local principal_id="$1"
  local assignment_id="$2"
  local response_file
  local headers_file
  local verification_file
  local current_role
  local final_role
  local body
  local retry_after
  local status
  local update_attempt=1
  local verification_attempt

  response_file="$(mktemp)"
  get_exact_assignment "${assignment_id}" "${response_file}"
  if ! validate_assignment_file "${response_file}" "${assignment_id}" "${principal_id}"; then
    rm -f "${response_file}"
    qam_fail "Fabric role assignment changed or is malformed before the Contributor update"
  fi
  current_role="$(jq -r '.role' "${response_file}")"
  case "${current_role}" in
    Contributor | Member | Admin)
      qam_info "principal ${principal_id} now has ${current_role}; no downgrade"
      replace_cached_assignment "${assignment_id}" "${response_file}"
      rm -f "${response_file}"
      return
      ;;
    Viewer) ;;
    *)
      rm -f "${response_file}"
      qam_fail "Fabric role assignment changed to unexpected role ${current_role}"
      ;;
  esac
  rm -f "${response_file}"

  body='{"role":"Contributor"}'
  response_file="$(mktemp)"
  headers_file="$(mktemp)"
  while :; do
    status="$(fabric_request_once \
      "${response_file}" \
      "${headers_file}" \
      --request PATCH \
      --header 'Content-Type: application/json' \
      --data-binary "${body}" \
      "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments/${assignment_id}")"
    [ "${status}" = "429" ] || break

    retry_after="$(fabric_retry_after "${headers_file}")"
    qam_info "Fabric role update returned 429; re-reading the exact assignment before retry (${update_attempt}/${fabric_role_retry_attempts})"
    wait_before_fabric_retry "${retry_after:-${fabric_role_retry_delay_seconds}}"
    get_exact_assignment "${assignment_id}" "${response_file}"
    if ! validate_assignment_file "${response_file}" "${assignment_id}" "${principal_id}"; then
      rm -f "${response_file}" "${headers_file}"
      qam_fail "Fabric role assignment changed or is malformed after a throttled Contributor update"
    fi
    current_role="$(jq -r '.role' "${response_file}")"
    case "${current_role}" in
      Contributor | Member | Admin)
        replace_cached_assignment "${assignment_id}" "${response_file}"
        rm -f "${response_file}" "${headers_file}"
        qam_info "principal ${principal_id} now has ${current_role}; no retry or downgrade"
        return
        ;;
      Viewer)
        if [ "${update_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
          rm -f "${response_file}" "${headers_file}"
          qam_fail "Fabric Viewer update remained throttled after ${update_attempt} attempts"
        fi
        update_attempt=$((update_attempt + 1))
        ;;
      *)
        rm -f "${response_file}" "${headers_file}"
        qam_fail "Fabric role assignment changed to unexpected role ${current_role} after a throttled update"
        ;;
    esac
  done
  rm -f "${headers_file}"
  if [ "${status}" != "200" ]; then
    sed -n '1,40p' "${response_file}" >&2
    rm -f "${response_file}"
    qam_fail "updating Fabric Viewer to Contributor returned HTTP ${status}"
  fi
  if ! validate_assignment_file "${response_file}" "${assignment_id}" "${principal_id}" \
    || [ "$(jq -r '.role' "${response_file}")" != "Contributor" ]; then
    rm -f "${response_file}"
    qam_fail "Fabric Contributor update returned an unexpected assignment"
  fi
  rm -f "${response_file}"

  verification_file="$(mktemp)"
  verification_attempt=1
  while :; do
    get_exact_assignment "${assignment_id}" "${verification_file}"
    if ! validate_assignment_file "${verification_file}" "${assignment_id}" "${principal_id}"; then
      rm -f "${verification_file}"
      qam_fail "Fabric role assignment is malformed after the Contributor update"
    fi
    final_role="$(jq -r '.role' "${verification_file}")"
    case "${final_role}" in
      Contributor | Member | Admin) break ;;
      Viewer)
        if [ "${verification_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
          rm -f "${verification_file}"
          qam_fail "Fabric role assignment did not propagate Contributor after ${verification_attempt} reads"
        fi
        qam_info "Fabric role update still reads Viewer; retrying verification (${verification_attempt}/${fabric_role_retry_attempts})"
        wait_before_fabric_retry
        verification_attempt=$((verification_attempt + 1))
        ;;
      *)
        rm -f "${verification_file}"
        qam_fail "Fabric role assignment changed to unexpected role ${final_role} after update"
        ;;
    esac
  done
  replace_cached_assignment "${assignment_id}" "${verification_file}"
  rm -f "${verification_file}"
  qam_info "updated Viewer to ${final_role} for ${principal_id}"
}

grant_role() {
  local principal_id="$1"
  local desired_role="$2"
  local assignments
  local assignment_count
  local assignment_id
  local existing_role
  local created_assignment_id
  local body
  local response_file
  local headers_file
  local retry_after
  local status
  local reconciliation_attempt

  assignments="$(principal_assignments "${principal_id}")"
  assignment_count="$(jq -r 'length' <<< "${assignments}")"
  if [ "${assignment_count}" -eq 1 ]; then
    assignment_id="$(jq -r '.[0].id' <<< "${assignments}")"
    existing_role="$(jq -r '.[0].role' <<< "${assignments}")"
    if [ "${desired_role}:${existing_role}" = "Contributor:Viewer" ]; then
      upgrade_viewer_to_contributor "${principal_id}" "${assignment_id}"
    else
      qam_info "principal ${principal_id} already has ${existing_role}; no downgrade"
    fi
    return
  fi
  [ "${assignment_count}" -eq 0 ] \
    || qam_fail "principal ${principal_id} changed after Fabric role preflight"

  body="$(jq -cn --arg id "${principal_id}" --arg role "${desired_role}" \
    '{principal: {id: $id, type: "ServicePrincipal"}, role: $role}')"
  response_file="$(mktemp)"
  headers_file="$(mktemp)"
  status="$(fabric_request_once \
    "${response_file}" \
    "${headers_file}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary "${body}" \
    "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments")"
  if [ "${status}" = "429" ] || [ "${status}" = "409" ]; then
    retry_after="$(fabric_retry_after "${headers_file}")"
    qam_info "Fabric role creation returned HTTP ${status}; reconciling live assignments without repeating POST"
    wait_before_fabric_retry "${retry_after:-${fabric_role_retry_delay_seconds}}"
    reconciliation_attempt=1
    while :; do
      load_workspace_assignments
      assignments="$(principal_assignments "${principal_id}")"
      assignment_count="$(jq -r 'length' <<< "${assignments}")"
      if [ "${assignment_count}" -gt 0 ]; then
        # An ambiguous create response can race with a successful or concurrent
        # create. Reconcile that live assignment instead of risking a duplicate.
        rm -f "${response_file}" "${headers_file}"
        preflight_role "${principal_id}" "${desired_role}"
        grant_role "${principal_id}" "${desired_role}"
        return
      fi
      if [ "${reconciliation_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
        rm -f "${response_file}" "${headers_file}"
        qam_fail "Fabric ${desired_role} creation returned HTTP ${status}, but no live assignment appeared after ${reconciliation_attempt} reconciliation reads; refusing a duplicate POST"
      fi
      qam_info "Fabric role assignment is not visible after HTTP ${status}; retrying read-only reconciliation (${reconciliation_attempt}/${fabric_role_retry_attempts})"
      wait_before_fabric_retry
      reconciliation_attempt=$((reconciliation_attempt + 1))
    done
  fi
  rm -f "${headers_file}"
  if [ "${status}" != "201" ]; then
    sed -n '1,40p' "${response_file}" >&2
    rm -f "${response_file}"
    qam_fail "granting Fabric ${desired_role} returned HTTP ${status}"
  fi
  created_assignment_id="$(jq -r '.id // empty' "${response_file}")"
  qam_validate_uuid "${created_assignment_id}" "created Fabric role-assignment ID"
  if ! validate_assignment_file "${response_file}" "${created_assignment_id}" "${principal_id}" \
    || [ "$(jq -r '.role' "${response_file}")" != "${desired_role}" ]; then
    rm -f "${response_file}"
    qam_fail "Fabric role creation returned an unexpected assignment"
  fi
  workspace_assignments="$(jq -cn \
    --argjson assignments "${workspace_assignments}" \
    --slurpfile created "${response_file}" '$assignments + [$created[0]]')"
  rm -f "${response_file}"
  qam_info "granted ${desired_role} to ${principal_id}"
}

try_reconciled_role() {
  local principal_id="$1"
  local minimum_role="$2"
  local assignments
  local assignment_count
  local assignment
  local assignment_id
  local observed_role

  assignments="$(principal_assignments "${principal_id}")"
  assignment_count="$(jq -r 'length' <<< "${assignments}")"
  [ "${assignment_count}" -eq 1 ] || return 1
  assignment_id="$(jq -r '.[0].id // empty' <<< "${assignments}")"
  printf '%s' "${assignment_id}" \
    | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
    || return 1
  assignment="$(jq -c '.[0]' <<< "${assignments}")"
  jq -e \
    --arg assignmentId "${assignment_id}" \
    --arg principalId "${principal_id}" '
      ((.id? | type) == "string") and
      ((.id | ascii_downcase) == ($assignmentId | ascii_downcase)) and
      ((.principal.id? | type) == "string") and
      ((.principal.id | ascii_downcase) == ($principalId | ascii_downcase)) and
      .principal.type == "ServicePrincipal" and
      (.role == "Viewer" or .role == "Contributor" or .role == "Member" or .role == "Admin")
    ' <<< "${assignment}" >/dev/null || return 1
  observed_role="$(jq -r '.role' <<< "${assignment}")"
  case "${minimum_role}:${observed_role}" in
    Viewer:Viewer | Viewer:Contributor | Viewer:Member | Viewer:Admin | \
      Contributor:Contributor | Contributor:Member | Contributor:Admin) ;;
    *) return 1 ;;
  esac
  printf '%s' "${observed_role}"
}

# Preflight every target before the first mutation so a duplicate later target
# cannot leave an earlier principal partially reconciled.
preflight_role "${runtime_principal_id}" "${runtime_role}"
if [ -n "${smoke_principal_id}" ] \
  && [ "${smoke_principal_key}" != "${definition_updater_principal_key}" ]; then
  preflight_role "${smoke_principal_id}" Viewer
fi
if [ -n "${definition_updater_principal_id}" ]; then
  preflight_role "${definition_updater_principal_id}" Contributor
fi

grant_role "${runtime_principal_id}" "${runtime_role}"
# Contributor already includes read/query capability. Avoid creating a duplicate
# Viewer assignment when the same protected identity is temporarily an updater.
if [ -n "${smoke_principal_id}" ] \
  && [ "${smoke_principal_key}" != "${definition_updater_principal_key}" ]; then
  grant_role "${smoke_principal_id}" Viewer
fi
if [ -n "${definition_updater_principal_id}" ]; then
  grant_role "${definition_updater_principal_id}" Contributor
fi

# Re-list the live service after every mutation. Receipts must never be built
# from a stale preflight snapshot or hide a concurrent duplicate/downgrade.
smoke_minimum_role="Viewer"
if [ -n "${smoke_principal_id}" ] \
  && [ "${smoke_principal_key}" = "${definition_updater_principal_key}" ]; then
  smoke_minimum_role="Contributor"
fi
reconciliation_attempt=1
while :; do
  load_workspace_assignments
  reconciliation_valid="true"
  if ! runtime_observed_role="$(try_reconciled_role \
    "${runtime_principal_id}" "${runtime_role}")"; then
    reconciliation_valid="false"
  fi
  smoke_observed_role=""
  if [ -n "${smoke_principal_id}" ] \
    && ! smoke_observed_role="$(try_reconciled_role \
      "${smoke_principal_id}" "${smoke_minimum_role}")"; then
    reconciliation_valid="false"
  fi
  definition_updater_observed_role=""
  if [ -n "${definition_updater_principal_id}" ] \
    && ! definition_updater_observed_role="$(try_reconciled_role \
      "${definition_updater_principal_id}" Contributor)"; then
    reconciliation_valid="false"
  fi
  if [ "${reconciliation_valid}" = "true" ]; then
    break
  fi
  if [ "${reconciliation_attempt}" -ge "${fabric_role_retry_attempts}" ]; then
    qam_fail "final Fabric role assignments did not meet the exact cardinality, shape, and minimum-role contract after ${reconciliation_attempt} reads"
  fi
  qam_info "Fabric role assignments have not fully propagated; retrying final verification (${reconciliation_attempt}/${fabric_role_retry_attempts})"
  wait_before_fabric_retry
  reconciliation_attempt=$((reconciliation_attempt + 1))
done

jq -cn \
  --arg workspaceId "${workspace_id}" \
  --arg runtimePrincipalId "${runtime_principal_id}" \
  --arg runtimeMinimumRole "${runtime_role}" \
  --arg runtimeObservedRole "${runtime_observed_role}" \
  --arg smokePrincipalId "${smoke_principal_id}" \
  --arg smokeMinimumRole "${smoke_minimum_role}" \
  --arg smokeObservedRole "${smoke_observed_role}" \
  --arg definitionUpdaterPrincipalId "${definition_updater_principal_id}" \
  --arg definitionUpdaterObservedRole "${definition_updater_observed_role}" \
  '{workspaceId: $workspaceId,
    runtimePrincipalId: $runtimePrincipalId,
    runtimeRole: $runtimeMinimumRole,
    runtimeMinimumRole: $runtimeMinimumRole,
    runtimeObservedRole: $runtimeObservedRole}
  + if $smokePrincipalId == "" then {} else {
      smokePrincipalId: $smokePrincipalId,
      smokeMinimumRole: $smokeMinimumRole,
      smokeObservedRole: $smokeObservedRole
    } end
  + if $definitionUpdaterPrincipalId == "" then {} else {
      definitionUpdaterPrincipalId: $definitionUpdaterPrincipalId,
      definitionUpdaterMinimumRole: "Contributor",
      definitionUpdaterObservedRole: $definitionUpdaterObservedRole
    } end'
