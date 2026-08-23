#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

display_name=""
api_client_id=""
prepare_only="false"
declare -a caller_client_ids=()
declare -a caller_principal_ids=()
caller_client_count=0
caller_principal_count=0
assignment_poll_attempts=20
assignment_poll_interval_seconds=3
assignment_page_limit=100

list_app_role_assignments() {
  local resource_principal_id="$1"
  local caller_principal_id="$2"
  local base_url
  local filtered_url
  local fallback_url
  local url
  local page
  local next_url
  local combined='[]'
  local page_count=0
  local have_first_page='false'

  base_url="https://graph.microsoft.com/v1.0/servicePrincipals/${resource_principal_id}/appRoleAssignedTo"
  filtered_url="${base_url}?\$select=id,principalId,resourceId,appRoleId&\$filter=principalId%20eq%20${caller_principal_id}"
  fallback_url="${base_url}?\$select=id,principalId,resourceId,appRoleId"
  url="${filtered_url}"

  if page="$(az rest \
    --method GET \
    --uri "${filtered_url}" \
    --output json \
    --only-show-errors 2>/dev/null)"; then
    have_first_page='true'
  else
    qam_info "Microsoft Graph did not accept the assignment filter; enumerating every bounded page"
    url="${fallback_url}"
  fi

  while [ -n "${url}" ]; do
    case "${url}" in
      "${base_url}?"*) ;;
      *) qam_fail "Microsoft Graph returned an app-role assignment nextLink outside the expected resource" ;;
    esac
    page_count=$((page_count + 1))
    [ "${page_count}" -le "${assignment_page_limit}" ] \
      || qam_fail "Microsoft Graph app-role assignment pagination exceeded the bounded page limit"
    if [ "${have_first_page}" = 'true' ]; then
      have_first_page='false'
    else
      page="$(az rest \
        --method GET \
        --uri "${url}" \
        --output json \
        --only-show-errors)"
    fi
    jq -e '
      (type == "object") and
      (.value | type == "array") and
      (.value | all(
        (type == "object") and
        (.id | type == "string") and
        (.principalId | type == "string") and
        (.resourceId | type == "string") and
        (.appRoleId | type == "string")
      )) and
      ((has("@odata.nextLink") | not) or (."@odata.nextLink" | type == "string"))
    ' <<< "${page}" >/dev/null \
      || qam_fail "Microsoft Graph returned an invalid app-role assignment page"
    combined="$(jq -cn \
      --argjson current "${combined}" \
      --argjson page "$(jq '.value' <<< "${page}")" \
      '$current + $page')"
    next_url="$(jq -r '."@odata.nextLink" // empty' <<< "${page}")"
    url="${next_url}"
  done
  printf '%s\n' "${combined}"
}

matching_app_role_assignments() {
  local assignments="$1"
  local caller_principal_id="$2"
  local resource_principal_id="$3"
  local role_id="$4"

  jq -c \
    --arg principal "${caller_principal_id}" \
    --arg resource "${resource_principal_id}" \
    --arg role "${role_id}" '
      [.[] | select(
        (.principalId | ascii_downcase) == ($principal | ascii_downcase) and
        (.resourceId | ascii_downcase) == ($resource | ascii_downcase) and
        (.appRoleId | ascii_downcase) == ($role | ascii_downcase)
      )]
    ' <<< "${assignments}"
}

wait_for_exact_app_role_assignment() {
  local resource_principal_id="$1"
  local caller_principal_id="$2"
  local role_id="$3"
  local attempt=1
  local assignments
  local matches
  local match_count

  while [ "${attempt}" -le "${assignment_poll_attempts}" ]; do
    assignments="$(list_app_role_assignments "${resource_principal_id}" "${caller_principal_id}")"
    matches="$(matching_app_role_assignments \
      "${assignments}" "${caller_principal_id}" "${resource_principal_id}" "${role_id}")"
    match_count="$(jq 'length' <<< "${matches}")"
    case "${match_count}" in
      1) printf '%s\n' "${matches}"; return ;;
      0) ;;
      *) qam_fail "caller has multiple matching Qam.Read app-role assignments" ;;
    esac
    if [ "${attempt}" -lt "${assignment_poll_attempts}" ]; then
      sleep "${assignment_poll_interval_seconds}"
    fi
    attempt=$((attempt + 1))
  done
  qam_fail "Qam.Read assignment did not become visible within the bounded Microsoft Graph poll"
}

usage() {
  printf '%s\n' \
    'Usage: bootstrap-mcp-entra.sh --display-name NAME [options] CALLERS...' \
    '' \
    'Options:' \
    '  --api-client-id UUID       Reconcile an existing API app instead of finding/creating by name' \
    '  --prepare-only             Create/reconcile the API and service principal without callers' \
    '  --caller-client-id UUID    Repeat once per allowed managed identity/application' \
    '  --caller-principal-id UUID Repeat in the same order for each caller service principal' \
    '' \
    'The script idempotently creates/reconciles the MCP API app, its service principal,' \
    'a Qam.Read application role, assignment-required policy, and caller role assignments.' \
    'It emits IDs only. It never creates a client secret or certificate.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --display-name) display_name="${2:?missing value for $1}"; shift 2 ;;
    --api-client-id) api_client_id="${2:?missing value for $1}"; shift 2 ;;
    --prepare-only) prepare_only="true"; shift ;;
    --caller-client-id)
      caller_client_ids[caller_client_count]="${2:?missing value for $1}"
      caller_client_count=$((caller_client_count + 1))
      shift 2
      ;;
    --caller-principal-id)
      caller_principal_ids[caller_principal_count]="${2:?missing value for $1}"
      caller_principal_count=$((caller_principal_count + 1))
      shift 2
      ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${display_name}" ] || qam_fail "--display-name is required"
[ "${caller_client_count}" -eq "${caller_principal_count}" ] \
  || qam_fail "caller client-ID and principal-ID counts must match"
if [ "${prepare_only}" = "true" ]; then
  [ "${caller_client_count}" -eq 0 ] \
    || qam_fail "--prepare-only cannot be combined with caller IDs"
else
  [ "${caller_client_count}" -gt 0 ] || qam_fail "at least one caller is required"
fi
if [ -n "${api_client_id}" ]; then
  qam_validate_uuid "${api_client_id}" "MCP API client ID"
fi
assignment_receipts='[]'
index=0
while [ "${index}" -lt "${caller_client_count}" ]; do
  qam_validate_uuid "${caller_client_ids[$index]}" "caller client ID"
  qam_validate_uuid "${caller_principal_ids[$index]}" "caller principal ID"
  index=$((index + 1))
done

qam_require_azure_login
qam_require_command jq
qam_require_command uuidgen

if [ -n "${api_client_id}" ]; then
  app_json="$(az ad app show --id "${api_client_id}" --output json)"
else
  matching_apps="$(az ad app list --display-name "${display_name}" --output json \
    | jq --arg name "${display_name}" '[.[] | select(.displayName == $name)]')"
  case "$(jq 'length' <<< "${matching_apps}")" in
    0)
      qam_info "creating MCP API application registration"
      app_json="$(az ad app create --display-name "${display_name}" --sign-in-audience AzureADMyOrg --output json)"
      ;;
    1) app_json="$(jq '.[0]' <<< "${matching_apps}")" ;;
    *) qam_fail "multiple applications have the exact display name; rerun with --api-client-id" ;;
  esac
fi

api_client_id="$(jq -er '.appId' <<< "${app_json}")"
api_app_object_id="$(jq -er '.id' <<< "${app_json}")"
identifier_uri="api://${api_client_id}"
if ! jq -e --arg uri "${identifier_uri}" '.identifierUris | index($uri) != null' <<< "${app_json}" >/dev/null; then
  qam_info "setting the MCP API identifier URI"
  az ad app update --id "${api_app_object_id}" --identifier-uris "${identifier_uri}" --output none
fi

api_contract="$(az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications/${api_app_object_id}?\$select=api" \
  --output json \
  --only-show-errors)"
if [ "$(jq -r '.api.requestedAccessTokenVersion // ""' <<< "${api_contract}")" != '2' ]; then
  qam_info "setting MCP API access tokens to version 2"
  api_patch="$(jq -c '(.api // {}) | .requestedAccessTokenVersion = 2 | {api: .}' <<< "${api_contract}")"
  az rest \
    --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/${api_app_object_id}" \
    --headers 'Content-Type=application/json' \
    --body "${api_patch}" \
    --output none \
    --only-show-errors
fi
api_contract="$(az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications/${api_app_object_id}?\$select=api" \
  --output json \
  --only-show-errors)"
jq -e '.api.requestedAccessTokenVersion == 2' <<< "${api_contract}" >/dev/null \
  || qam_fail "MCP API application does not issue version 2 access tokens"

app_roles="$(az ad app show --id "${api_app_object_id}" --query appRoles --output json)"
qam_role_id="$(jq -r '.[] | select(.value == "Qam.Read") | .id' <<< "${app_roles}" | head -1)"
if [ -z "${qam_role_id}" ]; then
  qam_role_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  app_roles="$(jq --arg id "${qam_role_id}" '. + [{
    allowedMemberTypes: ["Application"],
    description: "Read the Quick Agentic Memory MCP API",
    displayName: "QAM MCP Reader",
    id: $id,
    isEnabled: true,
    value: "Qam.Read"
  }]' <<< "${app_roles}")"
  qam_info "adding the Qam.Read application role"
  az ad app update --id "${api_app_object_id}" --app-roles "${app_roles}" --output none
else
  qam_validate_uuid "${qam_role_id}" "Qam.Read app-role ID"
  jq -e '.[] | select(.value == "Qam.Read") | .isEnabled == true and (.allowedMemberTypes | index("Application") != null)' \
    <<< "${app_roles}" >/dev/null \
    || qam_fail "existing Qam.Read role is not an enabled Application role"
fi

if ! api_sp_json="$(az ad sp show --id "${api_client_id}" --output json 2>/dev/null)"; then
  qam_info "creating the MCP API service principal"
  api_sp_json="$(az ad sp create --id "${api_client_id}" --output json)"
fi
api_principal_id="$(jq -er '.id' <<< "${api_sp_json}")"

current_assignment_required="$(az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${api_principal_id}?\$select=appRoleAssignmentRequired" \
  --query appRoleAssignmentRequired \
  --output tsv)"
if [ "${current_assignment_required}" != "true" ]; then
  qam_info "requiring explicit app-role assignments for MCP tokens"
  az rest \
    --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${api_principal_id}" \
    --headers 'Content-Type=application/json' \
    --body '{"appRoleAssignmentRequired":true}' \
    --output none
fi

index=0
while [ "${index}" -lt "${caller_client_count}" ]; do
  caller_client_id="${caller_client_ids[$index]}"
  caller_principal_id="${caller_principal_ids[$index]}"
  actual_client_id="$(az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${caller_principal_id}?\$select=appId" \
    --query appId \
    --output tsv)"
  [ "$(printf '%s' "${actual_client_id}" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "${caller_client_id}" | tr '[:upper:]' '[:lower:]')" ] \
    || qam_fail "caller client ID does not belong to the supplied principal ID"

  assignments="$(list_app_role_assignments "${api_principal_id}" "${caller_principal_id}")"
  matching_assignments="$(matching_app_role_assignments \
    "${assignments}" "${caller_principal_id}" "${api_principal_id}" "${qam_role_id}")"
  matching_count="$(jq 'length' <<< "${matching_assignments}")"
  case "${matching_count}" in
    1)
      qam_info "caller ${caller_principal_id} already has Qam.Read"
      ;;
    0)
      qam_info "assigning Qam.Read to caller ${caller_principal_id}"
      assignment_body="$(jq -cn \
        --arg principal "${caller_principal_id}" \
        --arg resource "${api_principal_id}" \
        --arg role "${qam_role_id}" \
        '{principalId: $principal, resourceId: $resource, appRoleId: $role}')"
      # The grant is attempted at most once per caller in this run. If another invocation won a
      # race but its assignment has not propagated to the listing endpoint, the POST can fail as
      # a duplicate; the bounded read-only poll below reconciles that state without a second POST.
      if ! az rest \
        --method POST \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${api_principal_id}/appRoleAssignedTo" \
        --headers 'Content-Type=application/json' \
        --body "${assignment_body}" \
        --output none \
        --only-show-errors; then
        qam_info "Qam.Read grant was not accepted immediately; verifying whether an existing grant won the race"
      fi
      matching_assignments="$(wait_for_exact_app_role_assignment \
        "${api_principal_id}" "${caller_principal_id}" "${qam_role_id}")"
      ;;
    *) qam_fail "caller has multiple matching Qam.Read app-role assignments" ;;
  esac
  qam_assignment_id="$(jq -er '.[0].id' <<< "${matching_assignments}")"
  [[ "${qam_assignment_id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
    || qam_fail "Qam.Read assignment ID is not a URL-safe Microsoft Graph object key"
  assignment_receipts="$(jq -cn \
    --argjson current "${assignment_receipts}" \
    --arg callerPrincipalId "${caller_principal_id}" \
    --arg assignmentId "${qam_assignment_id}" \
    '$current + [{callerPrincipalId: $callerPrincipalId, assignmentId: $assignmentId}]')"
  index=$((index + 1))
done

allowed_client_application_ids='[]'
allowed_principal_ids='[]'
if [ "${caller_client_count}" -gt 0 ]; then
  allowed_client_application_ids="$(printf '%s\n' "${caller_client_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  allowed_principal_ids="$(printf '%s\n' "${caller_principal_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
fi

jq -cn \
  --arg mcpApiClientId "${api_client_id}" \
  --arg mcpApiPrincipalId "${api_principal_id}" \
  --arg mcpApiAudience "${identifier_uri}" \
  --arg qamReadAppRoleId "${qam_role_id}" \
  --argjson allowedClientApplicationIds "${allowed_client_application_ids}" \
  --argjson allowedPrincipalIds "${allowed_principal_ids}" \
  --argjson qamReadAssignments "${assignment_receipts}" \
  '{
    mcpApiClientId: $mcpApiClientId,
    mcpApiPrincipalId: $mcpApiPrincipalId,
    mcpApiAudience: $mcpApiAudience,
    requestedAccessTokenVersion: 2,
    qamReadAppRoleId: $qamReadAppRoleId,
    qamReadAssignments: $qamReadAssignments,
    allowedClientApplicationIds: $allowedClientApplicationIds,
    allowedPrincipalIds: $allowedPrincipalIds
  }'
