#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

resource_group="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-}"
environment_name="${QAM_ENVIRONMENT:-dev}"
image_digest="${QAM_IMAGE_DIGEST:-}"
deployment_principal_id="${AZURE_PRINCIPAL_ID:-}"
mcp_api_client_id="${QAM_MCP_API_CLIENT_ID:-}"
allowed_client_application_ids="${QAM_ALLOWED_CLIENT_APPLICATION_IDS:-}"
allowed_principal_ids="${QAM_ALLOWED_PRINCIPAL_IDS:-}"
fabric_workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
fabric_graph_model_id="${QAM_FABRIC_GRAPH_MODEL_ID:-}"
github_repository="${QAM_GITHUB_REPOSITORY:-}"
github_authentication_mode="${QAM_GITHUB_AUTH_MODE:-none}"
github_app_id="${QAM_GITHUB_APP_ID:-}"
github_installation_id="${QAM_GITHUB_INSTALLATION_ID:-}"
github_private_key_secret_uri="${QAM_GITHUB_PRIVATE_KEY_SECRET_URI:-}"
github_token_secret_uri="${QAM_GITHUB_TOKEN_SECRET_URI:-}"
github_api_url="${QAM_GITHUB_API_URL:-https://api.github.com}"
github_web_url="${QAM_GITHUB_WEB_URL:-https://github.com}"
private_networking="false"
deploy_container_app="true"
deploy_role_assignments="false"
enable_entra_authentication="true"
parameter_file=""

usage() {
  printf '%s\n' \
    'Usage: deploy.sh --resource-group NAME [options]' \
    '' \
    'The command prints only ARM deployment outputs as JSON to stdout.' \
    'Progress and diagnostics go to stderr.' \
    '' \
    'Options match what-if.sh:' \
    '  --location REGION' \
    '  --environment dev|test|prod' \
    '  --image-digest sha256:HEX' \
    '  --deployment-principal-id UUID' \
    '  --mcp-api-client-id UUID' \
    '  --allowed-client-application-ids UUID[,UUID...]' \
    '  --allowed-principal-ids UUID[,UUID...]' \
    '  --fabric-workspace-id UUID' \
    '  --fabric-graph-model-id UUID' \
    '  --github-repository OWNER/REPOSITORY' \
    '  --github-auth-mode app|token|none' \
    '  --github-app-id DECIMAL_ID' \
    '  --github-installation-id DECIMAL_ID' \
    '  --github-private-key-secret-uri KEY_VAULT_SECRET_URI' \
    '  --github-token-secret-uri KEY_VAULT_SECRET_URI' \
    '  --github-api-url URL' \
    '  --github-web-url URL' \
    '  --parameters FILE' \
    '  --private' \
    '  --skip-app' \
    '  --include-role-assignments  Admin-only: four narrow assignments plus Key Vault RBAC Deny policy; requires --skip-app and --deployment-principal-id'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resource-group) resource_group="${2:?missing value for $1}"; shift 2 ;;
    --location) location="${2:?missing value for $1}"; shift 2 ;;
    --environment) environment_name="${2:?missing value for $1}"; shift 2 ;;
    --image-digest) image_digest="${2:?missing value for $1}"; shift 2 ;;
    --deployment-principal-id) deployment_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --mcp-api-client-id) mcp_api_client_id="${2:?missing value for $1}"; shift 2 ;;
    --allowed-client-application-ids) allowed_client_application_ids="${2:?missing value for $1}"; shift 2 ;;
    --allowed-principal-ids) allowed_principal_ids="${2:?missing value for $1}"; shift 2 ;;
    --fabric-workspace-id) fabric_workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --fabric-graph-model-id) fabric_graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --github-repository) github_repository="${2:?missing value for $1}"; shift 2 ;;
    --github-auth-mode) github_authentication_mode="${2:?missing value for $1}"; shift 2 ;;
    --github-app-id) github_app_id="${2:?missing value for $1}"; shift 2 ;;
    --github-installation-id) github_installation_id="${2:?missing value for $1}"; shift 2 ;;
    --github-private-key-secret-uri) github_private_key_secret_uri="${2:?missing value for $1}"; shift 2 ;;
    --github-token-secret-uri) github_token_secret_uri="${2:?missing value for $1}"; shift 2 ;;
    --github-api-url) github_api_url="${2:?missing value for $1}"; shift 2 ;;
    --github-web-url) github_web_url="${2:?missing value for $1}"; shift 2 ;;
    --parameters) parameter_file="${2:?missing value for $1}"; shift 2 ;;
    --private) private_networking="true"; shift ;;
    --skip-app) deploy_container_app="false"; shift ;;
    --include-role-assignments) deploy_role_assignments="true"; shift ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${resource_group}" ] || qam_fail "--resource-group is required"
qam_validate_environment "${environment_name}"
if [ "${deploy_role_assignments}" = "true" ]; then
  [ "${deploy_container_app}" = "false" ] \
    || qam_fail "--include-role-assignments requires --skip-app"
  [ -n "${deployment_principal_id}" ] \
    || qam_fail "--include-role-assignments requires --deployment-principal-id"
fi

if [ -z "${parameter_file}" ]; then
  if [ "${private_networking}" = "true" ]; then
    parameter_file="${QAM_INFRA_DIR}/main.private.bicepparam"
  else
    parameter_file="${QAM_INFRA_DIR}/main.poc.bicepparam"
  fi
fi
[ -f "${parameter_file}" ] || qam_fail "parameter file not found: ${parameter_file}"

if [ "${deploy_container_app}" = "true" ] && [ "${enable_entra_authentication}" = "true" ]; then
  [ -n "${mcp_api_client_id}" ] || qam_fail "--mcp-api-client-id is required when Entra authentication is enabled"
  qam_validate_uuid "${mcp_api_client_id}" "MCP API client ID"
  qam_validate_uuid_csv "${allowed_client_application_ids}" "allowed caller application IDs"
  qam_validate_uuid_csv "${allowed_principal_ids}" "allowed caller principal IDs"
fi
if [ "${deploy_container_app}" = "true" ] && [ "${enable_entra_authentication}" != "true" ]; then
  qam_fail "cloud Container App deployment requires Entra authentication"
fi
if [ -n "${deployment_principal_id}" ]; then
  qam_validate_uuid "${deployment_principal_id}" "deployment principal ID"
fi
if [ -n "${fabric_workspace_id}" ]; then
  qam_validate_uuid "${fabric_workspace_id}" "Fabric workspace ID"
fi
if [ -n "${fabric_graph_model_id}" ]; then
  qam_validate_uuid "${fabric_graph_model_id}" "Fabric Graph Model ID"
fi
if [ "${deploy_container_app}" = "true" ]; then
  [ -n "${image_digest}" ] || qam_fail "--image-digest is required when the Container App is deployed"
  qam_validate_image_digest "${image_digest}" "image digest"
  [ -n "${fabric_workspace_id}" ] || qam_fail "--fabric-workspace-id is required when the Container App is deployed"
  [ -n "${fabric_graph_model_id}" ] || qam_fail "--fabric-graph-model-id is required when the Container App is deployed"
  [ -n "${github_repository}" ] || qam_fail "--github-repository is required when the Container App is deployed"
fi
if [ -n "${github_repository}" ]; then
  qam_validate_github_repository "${github_repository}" "GitHub repository"
fi
qam_validate_github_origins "${github_api_url}" "${github_web_url}"
if [ "${deploy_container_app}" = "true" ]; then
  qam_validate_github_auth \
    "${github_authentication_mode}" \
    "${github_app_id}" \
    "${github_installation_id}" \
    "${github_private_key_secret_uri}" \
    "${github_token_secret_uri}"
fi

qam_require_azure_login
if [ -z "${location}" ]; then
  location="$(az group show --name "${resource_group}" --query location --output tsv)"
fi

arm_parameters=(
  "location=${location}"
  "environmentName=${environment_name}"
  "deployContainerApp=${deploy_container_app}"
  "deployRoleAssignments=${deploy_role_assignments}"
  "enablePrivateNetworking=${private_networking}"
  "enableEntraAuthentication=${enable_entra_authentication}"
  "deploymentPrincipalId=${deployment_principal_id}"
  "mcpApiClientId=${mcp_api_client_id}"
  "fabricWorkspaceId=${fabric_workspace_id}"
  "fabricGraphModelId=${fabric_graph_model_id}"
  "githubRepository=${github_repository}"
  "githubAuthenticationMode=${github_authentication_mode}"
  "githubAppId=${github_app_id}"
  "githubInstallationId=${github_installation_id}"
  "githubPrivateKeySecretUri=${github_private_key_secret_uri}"
  "githubTokenSecretUri=${github_token_secret_uri}"
  "githubApiUrl=${github_api_url}"
  "githubWebUrl=${github_web_url}"
)
if [ -n "${image_digest}" ]; then
  arm_parameters+=("imageDigest=${image_digest}")
fi
if [ -n "${allowed_client_application_ids}" ]; then
  arm_parameters+=("allowedClientApplicationIds=$(qam_uuid_csv_to_json "${allowed_client_application_ids}")")
fi
if [ -n "${allowed_principal_ids}" ]; then
  arm_parameters+=("allowedPrincipalIds=$(qam_uuid_csv_to_json "${allowed_principal_ids}")")
fi

deployment_name="qam-${environment_name}-$(date -u +%Y%m%d%H%M%S)"
if [ "${deploy_role_assignments}" = "true" ]; then
  qam_info "admin-only role/policy reconciliation requested; the signed-in identity must have roleAssignments/write and policyAssignments/write"
fi
qam_info "deploying ${deployment_name} to ${resource_group}"
az deployment group create \
  --name "${deployment_name}" \
  --resource-group "${resource_group}" \
  --template-file "${QAM_INFRA_DIR}/main.bicep" \
  --parameters "${parameter_file}" \
  --parameters "${arm_parameters[@]}" \
  --query properties.outputs \
  --output json
