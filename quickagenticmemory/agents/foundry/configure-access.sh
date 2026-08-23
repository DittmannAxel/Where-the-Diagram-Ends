#!/usr/bin/env bash

set -Eeuo pipefail

agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qam_dir="$(cd "${agent_dir}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${qam_dir}/scripts/lib/common.sh"

registration_file=""
mcp_api_client_id="${QAM_MCP_API_CLIENT_ID:-}"
mcp_display_name="${QAM_MCP_API_DISPLAY_NAME:-Quick Agentic Memory MCP}"
container_app_resource_id="${QAM_CONTAINER_APP_RESOURCE_ID:-}"

usage() {
  printf '%s\n' \
    'Usage: configure-access.sh --registration FILE --mcp-api-client-id UUID --container-app-resource-id ID [options]' \
    '' \
    'Options:' \
    '  --mcp-display-name NAME   Existing/new MCP API app display name' \
    '' \
    'Reconciles Qam.Read for the published Agent Application identity and emits a non-secret access' \
    'receipt bound to the exact future/current Container App. Pass its allowlists to deployment;' \
    'live attach rechecks both the role assignment and Container Apps EasyAuth before mutation.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registration) registration_file="${2:?missing value for $1}"; shift 2 ;;
    --mcp-api-client-id) mcp_api_client_id="${2:?missing value for $1}"; shift 2 ;;
    --mcp-display-name) mcp_display_name="${2:?missing value for $1}"; shift 2 ;;
    --container-app-resource-id) container_app_resource_id="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${registration_file}" ] || qam_fail "--registration is required"
[ -f "${registration_file}" ] || qam_fail "registration file does not exist"
[ -n "${mcp_api_client_id}" ] || qam_fail "--mcp-api-client-id is required"
[ -n "${container_app_resource_id}" ] || qam_fail "--container-app-resource-id is required"
qam_validate_uuid "${mcp_api_client_id}" "MCP API client ID"
if [[ ! "${container_app_resource_id}" =~ ^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/[A-Za-z0-9._()-]{1,90}/providers/Microsoft\.App/containerApps/[A-Za-z0-9][A-Za-z0-9-]{0,31}$ ]]; then
  qam_fail "--container-app-resource-id must identify one Azure Container App"
fi
qam_validate_uuid "${BASH_REMATCH[1]}" "Container App subscription ID"
qam_require_command jq
qam_require_azure_login

jq -e '
  (.phase == "published-identity") and
  (.applicationClientId | type == "string") and
  (.applicationPrincipalId | type == "string") and
  (.applicationResourceId | type == "string") and
  (.projectResourceId | type == "string") and
  (.applicationName | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.agentName | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.mcpAudience | type == "string") and
  (.accessContract.requiredAppRole == "Qam.Read") and
  (.accessContract.identitySource == "AgentApplication.defaultInstanceIdentity") and
  (.accessContract.allowedClientApplicationIds == [.applicationClientId]) and
  (.accessContract.allowedPrincipalIds == [.applicationPrincipalId])
' "${registration_file}" >/dev/null || qam_fail "registration file does not satisfy the Foundry access contract"

agent_client_id="$(jq -er '.applicationClientId' "${registration_file}")"
agent_principal_id="$(jq -er '.applicationPrincipalId' "${registration_file}")"
application_resource_id="$(jq -er '.applicationResourceId' "${registration_file}")"
project_resource_id="$(jq -er '.projectResourceId' "${registration_file}")"
application_name="$(jq -er '.applicationName' "${registration_file}")"
agent_name="$(jq -er '.agentName' "${registration_file}")"
audience="$(jq -er '.mcpAudience' "${registration_file}")"
qam_validate_uuid "${agent_client_id}" "Foundry Agent Application client ID"
qam_validate_uuid "${agent_principal_id}" "Foundry Agent Application principal ID"
[ "${audience}" = "api://${mcp_api_client_id}" ] \
  || qam_fail "registration audience does not match the supplied MCP API client ID"
[ "${application_resource_id}" = "${project_resource_id%/}/applications/${application_name}" ] \
  || qam_fail "registration application resource ID does not match its project and application name"
printf '%s' "${application_resource_id}" \
  | grep -Eqi '^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.CognitiveServices/accounts/[A-Za-z0-9-]+/projects/[A-Za-z0-9._-]+/applications/[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' \
  || qam_fail "registration application resource ID has an unexpected shape"

live_application="$(az rest \
  --method get \
  --url "https://management.azure.com${application_resource_id}?api-version=2026-05-15-preview" \
  --output json \
  --only-show-errors)"
jq -e \
  --arg client_id "${agent_client_id}" \
  --arg principal_id "${agent_principal_id}" \
  --arg agent_name "${agent_name}" '
    (.properties.provisioningState == "Succeeded") and
    (.properties.authorizationPolicy.authorizationScheme == "Default") and
    (.properties.agents | length == 1) and
    (.properties.agents[0].agentName == $agent_name) and
    (.properties.defaultInstanceIdentity.kind == "AgentInstance") and
    (.properties.defaultInstanceIdentity.clientId == $client_id) and
    (.properties.defaultInstanceIdentity.principalId == $principal_id)
  ' <<< "${live_application}" >/dev/null \
  || qam_fail "live Agent Application identity does not match the registration"

access_json="$("${qam_dir}/scripts/bootstrap-mcp-entra.sh" \
  --display-name "${mcp_display_name}" \
  --api-client-id "${mcp_api_client_id}" \
  --caller-client-id "${agent_client_id}" \
  --caller-principal-id "${agent_principal_id}")"

jq -e \
  --arg api_client "${mcp_api_client_id}" \
  --arg audience "${audience}" \
  --arg caller_client "${agent_client_id}" \
  --arg caller_principal "${agent_principal_id}" '
    (.mcpApiClientId | ascii_downcase) == ($api_client | ascii_downcase) and
    (.mcpApiAudience == $audience) and
    (.allowedClientApplicationIds | map(ascii_downcase)) == [($caller_client | ascii_downcase)] and
    (.allowedPrincipalIds | map(ascii_downcase)) == [($caller_principal | ascii_downcase)] and
    (.mcpApiPrincipalId | type == "string")
  ' <<< "${access_json}" >/dev/null \
  || qam_fail "MCP bootstrap result does not match the requested access contract"

mcp_api_principal_id="$(jq -er '.mcpApiPrincipalId' <<< "${access_json}")"
qam_validate_uuid "${mcp_api_principal_id}" "MCP API principal ID"

mcp_api_application="$(az ad app show --id "${mcp_api_client_id}" --output json)"
mcp_api_application_object_id="$(jq -er '.id' <<< "${mcp_api_application}")"
qam_validate_uuid "${mcp_api_application_object_id}" "MCP API application object ID"
app_roles="$(jq -e '.appRoles' <<< "${mcp_api_application}")"
qam_roles="$(jq '[.[] | select(
  .value == "Qam.Read" and
  .isEnabled == true and
  (.allowedMemberTypes | index("Application") != null)
)]' <<< "${app_roles}")"
[ "$(jq 'length' <<< "${qam_roles}")" -eq 1 ] \
  || qam_fail "MCP API must expose exactly one enabled Application Qam.Read role"
qam_role_id="$(jq -er '.[0].id' <<< "${qam_roles}")"
qam_validate_uuid "${qam_role_id}" "Qam.Read app-role ID"

live_api_principal="$(az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mcp_api_principal_id}?\$select=id,appId,appRoleAssignmentRequired" \
  --output json \
  --only-show-errors)"
jq -e \
  --arg principal "${mcp_api_principal_id}" \
  --arg client "${mcp_api_client_id}" '
    (.id | ascii_downcase) == ($principal | ascii_downcase) and
    (.appId | ascii_downcase) == ($client | ascii_downcase) and
    (.appRoleAssignmentRequired == true)
  ' <<< "${live_api_principal}" >/dev/null \
  || qam_fail "live MCP API service principal is not assignment-required or does not match"

assignment_page="$(az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mcp_api_principal_id}/appRoleAssignedTo?\$select=id,principalId,resourceId,appRoleId" \
  --output json \
  --only-show-errors)"
matching_assignments="$(jq \
  --arg principal "${agent_principal_id}" \
  --arg resource "${mcp_api_principal_id}" \
  --arg role "${qam_role_id}" '
    [.value[] | select(
      (.principalId | ascii_downcase) == ($principal | ascii_downcase) and
      (.resourceId | ascii_downcase) == ($resource | ascii_downcase) and
      (.appRoleId | ascii_downcase) == ($role | ascii_downcase)
    )]
  ' <<< "${assignment_page}")"
[ "$(jq 'length' <<< "${matching_assignments}")" -eq 1 ] \
  || qam_fail "live Agent Application must have exactly one matching Qam.Read assignment"
qam_assignment_id="$(jq -er '.[0].id' <<< "${matching_assignments}")"
[[ "${qam_assignment_id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
  || qam_fail "Qam.Read assignment ID is not a URL-safe Microsoft Graph object key"

jq -cn \
  --arg receiptVersion 'qam-foundry-access/1.0' \
  --arg phase 'access-configured' \
  --arg agentName "${agent_name}" \
  --arg applicationName "${application_name}" \
  --arg applicationResourceId "${application_resource_id}" \
  --arg projectResourceId "${project_resource_id}" \
  --arg applicationClientId "${agent_client_id}" \
  --arg applicationPrincipalId "${agent_principal_id}" \
  --arg mcpUrl "$(jq -er '.mcpUrl' "${registration_file}")" \
  --arg mcpApiClientId "${mcp_api_client_id}" \
  --arg mcpApiApplicationObjectId "${mcp_api_application_object_id}" \
  --arg mcpApiPrincipalId "${mcp_api_principal_id}" \
  --arg mcpApiAudience "${audience}" \
  --arg qamReadAppRoleId "${qam_role_id}" \
  --arg qamReadAssignmentId "${qam_assignment_id}" \
  --arg containerAppResourceId "${container_app_resource_id}" \
  --arg requiredAppRole 'Qam.Read' \
  --argjson allowedClientApplicationIds "$(jq '.allowedClientApplicationIds' <<< "${access_json}")" \
  --argjson allowedPrincipalIds "$(jq '.allowedPrincipalIds' <<< "${access_json}")" '
    {
      receiptVersion: $receiptVersion,
      phase: $phase,
      agentName: $agentName,
      applicationName: $applicationName,
      applicationResourceId: $applicationResourceId,
      projectResourceId: $projectResourceId,
      applicationClientId: $applicationClientId,
      applicationPrincipalId: $applicationPrincipalId,
      mcpUrl: $mcpUrl,
      mcpApiClientId: $mcpApiClientId,
      mcpApiApplicationObjectId: $mcpApiApplicationObjectId,
      mcpApiPrincipalId: $mcpApiPrincipalId,
      mcpApiAudience: $mcpApiAudience,
      qamReadAppRoleId: $qamReadAppRoleId,
      qamReadAssignmentId: $qamReadAssignmentId,
      containerAppResourceId: $containerAppResourceId,
      requiredAppRole: $requiredAppRole,
      allowedClientApplicationIds: $allowedClientApplicationIds,
      allowedPrincipalIds: $allowedPrincipalIds
    }
  '
