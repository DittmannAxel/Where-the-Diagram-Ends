#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

display_name=""
api_client_id=""
declare -a caller_client_ids=()
declare -a caller_principal_ids=()

usage() {
  printf '%s\n' \
    'Usage: bootstrap-mcp-entra.sh --display-name NAME [options] CALLERS...' \
    '' \
    'Options:' \
    '  --api-client-id UUID       Reconcile an existing API app instead of finding/creating by name' \
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
    --caller-client-id) caller_client_ids+=("${2:?missing value for $1}"); shift 2 ;;
    --caller-principal-id) caller_principal_ids+=("${2:?missing value for $1}"); shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${display_name}" ] || qam_fail "--display-name is required"
[ "${#caller_client_ids[@]}" -gt 0 ] || qam_fail "at least one caller is required"
[ "${#caller_client_ids[@]}" -eq "${#caller_principal_ids[@]}" ] \
  || qam_fail "caller client-ID and principal-ID counts must match"
if [ -n "${api_client_id}" ]; then
  qam_validate_uuid "${api_client_id}" "MCP API client ID"
fi
for caller_client_id in "${caller_client_ids[@]}"; do
  qam_validate_uuid "${caller_client_id}" "caller client ID"
done
for caller_principal_id in "${caller_principal_ids[@]}"; do
  qam_validate_uuid "${caller_principal_id}" "caller principal ID"
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

for index in "${!caller_client_ids[@]}"; do
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

  assignments="$(az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${caller_principal_id}/appRoleAssignments" \
    --output json)"
  if jq -e --arg resource "${api_principal_id}" --arg role "${qam_role_id}" \
    '.value[] | select(.resourceId == $resource and .appRoleId == $role)' \
    <<< "${assignments}" >/dev/null; then
    qam_info "caller ${caller_principal_id} already has Qam.Read"
    continue
  fi
  qam_info "assigning Qam.Read to caller ${caller_principal_id}"
  assignment_body="$(jq -cn \
    --arg principal "${caller_principal_id}" \
    --arg resource "${api_principal_id}" \
    --arg role "${qam_role_id}" \
    '{principalId: $principal, resourceId: $resource, appRoleId: $role}')"
  az rest \
    --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${caller_principal_id}/appRoleAssignments" \
    --headers 'Content-Type=application/json' \
    --body "${assignment_body}" \
    --output none
done

jq -cn \
  --arg mcpApiClientId "${api_client_id}" \
  --arg mcpApiPrincipalId "${api_principal_id}" \
  --arg mcpApiAudience "${identifier_uri}" \
  --argjson allowedClientApplicationIds "$(printf '%s\n' "${caller_client_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson allowedPrincipalIds "$(printf '%s\n' "${caller_principal_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  '{
    mcpApiClientId: $mcpApiClientId,
    mcpApiPrincipalId: $mcpApiPrincipalId,
    mcpApiAudience: $mcpApiAudience,
    allowedClientApplicationIds: $allowedClientApplicationIds,
    allowedPrincipalIds: $allowedPrincipalIds
  }'
