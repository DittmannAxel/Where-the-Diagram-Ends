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

wait_for_exact_app_role_assignment() {
  local resource_principal_id="$1"
  local caller_principal_id="$2"
  local role_id="$3"
  local expected_assignment_id="$4"
  local attempt=1
  local assignments
  local matches
  local match_count

  while [ "${attempt}" -le "${assignment_poll_attempts}" ]; do
    assignments="$(list_app_role_assignments "${resource_principal_id}" "${caller_principal_id}")"
    matches="$(jq -c \
      --arg principal "${caller_principal_id}" \
      --arg resource "${resource_principal_id}" \
      --arg role "${role_id}" '
        [.[] | select(
          (.principalId | ascii_downcase) == ($principal | ascii_downcase) and
          (.resourceId | ascii_downcase) == ($resource | ascii_downcase) and
          (.appRoleId | ascii_downcase) == ($role | ascii_downcase)
        )]
      ' <<< "${assignments}")"
    match_count="$(jq 'length' <<< "${matches}")"
    case "${match_count}" in
      1)
        [ "$(jq -r '.[0].id' <<< "${matches}")" = "${expected_assignment_id}" ] \
          || qam_fail "live Qam.Read assignment ID does not match the bootstrap result"
        printf '%s\n' "${matches}"
        return
        ;;
      0) ;;
      *) qam_fail "live Foundry project identity has multiple matching Qam.Read assignments" ;;
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
    'Usage: configure-access.sh --registration FILE --mcp-api-client-id UUID --container-app-resource-id ID [options]' \
    '' \
    'Options:' \
    '  --mcp-display-name NAME   Existing/new MCP API app display name' \
    '' \
    'Reconciles Qam.Read for the Foundry project managed identity and emits a non-secret access' \
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
  (.applicationIdentitySource == "AgentApplication.defaultInstanceIdentity") and
  (.projectManagedIdentityClientId | type == "string") and
  (.projectManagedIdentityPrincipalId | type == "string") and
  (.projectManagedIdentitySource == "FoundryProject.identity.systemAssigned") and
  (.applicationResourceId | type == "string") and
  (.projectResourceId | type == "string") and
  (.applicationName | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.agentName | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.mcpAudience | type == "string") and
  (.accessContract.requiredAppRole == "Qam.Read") and
  (.accessContract.identitySource == "FoundryProject.identity.systemAssigned") and
  (.accessContract.callerIdentityType == "ProjectManagedIdentity") and
  (.accessContract.callerClientId == .projectManagedIdentityClientId) and
  (.accessContract.callerPrincipalId == .projectManagedIdentityPrincipalId) and
  (.accessContract.allowedClientApplicationIds == [.projectManagedIdentityClientId]) and
  (.accessContract.allowedPrincipalIds == [.projectManagedIdentityPrincipalId])
' "${registration_file}" >/dev/null || qam_fail "registration file does not satisfy the Foundry access contract"

agent_client_id="$(jq -er '.applicationClientId' "${registration_file}")"
agent_principal_id="$(jq -er '.applicationPrincipalId' "${registration_file}")"
project_client_id="$(jq -er '.projectManagedIdentityClientId' "${registration_file}")"
project_principal_id="$(jq -er '.projectManagedIdentityPrincipalId' "${registration_file}")"
application_resource_id="$(jq -er '.applicationResourceId' "${registration_file}")"
project_resource_id="$(jq -er '.projectResourceId' "${registration_file}")"
application_name="$(jq -er '.applicationName' "${registration_file}")"
agent_name="$(jq -er '.agentName' "${registration_file}")"
audience="$(jq -er '.mcpAudience' "${registration_file}")"
qam_validate_uuid "${agent_client_id}" "Foundry Agent Application client ID"
qam_validate_uuid "${agent_principal_id}" "Foundry Agent Application principal ID"
qam_validate_uuid "${project_client_id}" "Foundry project managed identity client ID"
qam_validate_uuid "${project_principal_id}" "Foundry project managed identity principal ID"
[ "$(printf '%s' "${agent_client_id}" | tr '[:upper:]' '[:lower:]')" != \
  "$(printf '%s' "${project_client_id}" | tr '[:upper:]' '[:lower:]')" ] \
  && [ "$(printf '%s' "${agent_principal_id}" | tr '[:upper:]' '[:lower:]')" != \
  "$(printf '%s' "${project_principal_id}" | tr '[:upper:]' '[:lower:]')" ] \
  || qam_fail "Agent Application and Foundry project identities must be distinct"
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

live_application_principal="$(az rest \
  --method get \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${agent_principal_id}?\$select=id,appId" \
  --output json \
  --only-show-errors)"
jq -e \
  --arg client_id "${agent_client_id}" \
  --arg principal_id "${agent_principal_id}" '
    ((.id | ascii_downcase) == ($principal_id | ascii_downcase)) and
    ((.appId | ascii_downcase) == ($client_id | ascii_downcase))
  ' <<< "${live_application_principal}" >/dev/null \
  || qam_fail "live Agent Application service principal does not match the registration"

live_project="$(az rest \
  --method get \
  --url "https://management.azure.com${project_resource_id}?api-version=2025-06-01" \
  --output json \
  --only-show-errors)"
jq -e \
  --arg resource_id "${project_resource_id}" \
  --arg principal_id "${project_principal_id}" '
    ((.id | ascii_downcase) == ($resource_id | ascii_downcase)) and
    (.identity.type == "SystemAssigned") and
    ((.identity.principalId | ascii_downcase) == ($principal_id | ascii_downcase)) and
    (.identity.tenantId | type == "string")
  ' <<< "${live_project}" >/dev/null \
  || qam_fail "live Foundry project system identity does not match the registration"
project_tenant_id="$(jq -er '.identity.tenantId' <<< "${live_project}")"
qam_validate_uuid "${project_tenant_id}" "Foundry project managed identity tenant ID"

live_project_principal="$(az rest \
  --method get \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${project_principal_id}?\$select=id,appId,servicePrincipalType" \
  --output json \
  --only-show-errors)"
jq -e \
  --arg client_id "${project_client_id}" \
  --arg principal_id "${project_principal_id}" '
    ((.id | ascii_downcase) == ($principal_id | ascii_downcase)) and
    ((.appId | ascii_downcase) == ($client_id | ascii_downcase)) and
    (.servicePrincipalType == "ManagedIdentity")
  ' <<< "${live_project_principal}" >/dev/null \
  || qam_fail "live Foundry project identity has no matching managed-identity service principal"

access_json="$("${qam_dir}/scripts/bootstrap-mcp-entra.sh" \
  --display-name "${mcp_display_name}" \
  --api-client-id "${mcp_api_client_id}" \
  --caller-client-id "${project_client_id}" \
  --caller-principal-id "${project_principal_id}")"

jq -e \
  --arg api_client "${mcp_api_client_id}" \
  --arg audience "${audience}" \
  --arg caller_client "${project_client_id}" \
  --arg caller_principal "${project_principal_id}" '
    (.mcpApiClientId | ascii_downcase) == ($api_client | ascii_downcase) and
    (.mcpApiAudience == $audience) and
    (.requestedAccessTokenVersion == 2) and
    (.qamReadAppRoleId | type == "string") and
    (.qamReadAssignments | type == "array") and
    (.qamReadAssignments | length == 1) and
    ((.qamReadAssignments[0].callerPrincipalId | ascii_downcase) == ($caller_principal | ascii_downcase)) and
    (.qamReadAssignments[0].assignmentId | type == "string") and
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
bootstrap_role_id="$(jq -er '.qamReadAppRoleId' <<< "${access_json}")"
qam_validate_uuid "${bootstrap_role_id}" "MCP bootstrap Qam.Read app-role ID"
[ "$(printf '%s' "${bootstrap_role_id}" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "${qam_role_id}" | tr '[:upper:]' '[:lower:]')" ] \
  || qam_fail "MCP bootstrap Qam.Read role ID does not match the live application role"
bootstrap_assignment_id="$(jq -er '.qamReadAssignments[0].assignmentId' <<< "${access_json}")"
[[ "${bootstrap_assignment_id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
  || qam_fail "MCP bootstrap assignment ID is not a URL-safe Microsoft Graph object key"

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

matching_assignments="$(wait_for_exact_app_role_assignment \
  "${mcp_api_principal_id}" \
  "${project_principal_id}" \
  "${qam_role_id}" \
  "${bootstrap_assignment_id}")"
qam_assignment_id="$(jq -er '.[0].id' <<< "${matching_assignments}")"
[[ "${qam_assignment_id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
  || qam_fail "Qam.Read assignment ID is not a URL-safe Microsoft Graph object key"

jq -cn \
  --arg receiptVersion 'qam-foundry-access/2.0' \
  --arg phase 'access-configured' \
  --arg agentName "${agent_name}" \
  --arg applicationName "${application_name}" \
  --arg applicationResourceId "${application_resource_id}" \
  --arg projectResourceId "${project_resource_id}" \
  --arg applicationClientId "${agent_client_id}" \
  --arg applicationPrincipalId "${agent_principal_id}" \
  --arg applicationIdentitySource 'AgentApplication.defaultInstanceIdentity' \
  --arg projectManagedIdentityClientId "${project_client_id}" \
  --arg projectManagedIdentityPrincipalId "${project_principal_id}" \
  --arg callerIdentitySource 'FoundryProject.identity.systemAssigned' \
  --arg callerIdentityType 'ProjectManagedIdentity' \
  --arg callerClientId "${project_client_id}" \
  --arg callerPrincipalId "${project_principal_id}" \
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
      applicationIdentitySource: $applicationIdentitySource,
      projectManagedIdentityClientId: $projectManagedIdentityClientId,
      projectManagedIdentityPrincipalId: $projectManagedIdentityPrincipalId,
      callerIdentitySource: $callerIdentitySource,
      callerIdentityType: $callerIdentityType,
      callerClientId: $callerClientId,
      callerPrincipalId: $callerPrincipalId,
      mcpUrl: $mcpUrl,
      mcpApiClientId: $mcpApiClientId,
      mcpApiApplicationObjectId: $mcpApiApplicationObjectId,
      mcpApiPrincipalId: $mcpApiPrincipalId,
      mcpApiAudience: $mcpApiAudience,
      mcpRequestedAccessTokenVersion: 2,
      qamReadAppRoleId: $qamReadAppRoleId,
      qamReadAssignmentId: $qamReadAssignmentId,
      containerAppResourceId: $containerAppResourceId,
      requiredAppRole: $requiredAppRole,
      allowedClientApplicationIds: $allowedClientApplicationIds,
      allowedPrincipalIds: $allowedPrincipalIds
    }
  '
