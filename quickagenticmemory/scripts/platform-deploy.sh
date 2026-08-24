#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

resource_group="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-}"
environment_name="${QAM_ENVIRONMENT:-test}"
workload_name="${QAM_WORKLOAD_NAME:-qam}"
fabric_admin_member=""
fabric_sku="F2"
operator_principal_id=""
chat_model_name="gpt-5.4-mini"
chat_model_version="2026-03-17"
chat_model_capacity="50"

usage() {
  printf '%s\n' \
    'Usage: platform-deploy.sh --resource-group NAME --fabric-admin-member UPN --operator-principal-id UUID [options]' \
    '' \
    'Deploys the Fabric capacity and Microsoft Foundry project/model platform.' \
    'platform-what-if.sh is available as an optional preview with the same arguments.' \
    '' \
    'Options:' \
    '  --location REGION                  Default: resource-group location' \
    '  --workload NAME                    Default: qam' \
    '  --environment dev|test|prod        Default: test' \
    '  --fabric-sku F2|F4|F8|F16|F32|F64  Default: F2' \
    '  --chat-model-name NAME             Default: gpt-5.4-mini' \
    '  --chat-model-version VERSION       Default: 2026-03-17' \
    '  --chat-model-capacity KTPM         Default: 50'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resource-group) resource_group="${2:?missing value for $1}"; shift 2 ;;
    --location) location="${2:?missing value for $1}"; shift 2 ;;
    --workload) workload_name="${2:?missing value for $1}"; shift 2 ;;
    --environment) environment_name="${2:?missing value for $1}"; shift 2 ;;
    --fabric-admin-member) fabric_admin_member="${2:?missing value for $1}"; shift 2 ;;
    --fabric-sku) fabric_sku="${2:?missing value for $1}"; shift 2 ;;
    --operator-principal-id) operator_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --chat-model-name) chat_model_name="${2:?missing value for $1}"; shift 2 ;;
    --chat-model-version) chat_model_version="${2:?missing value for $1}"; shift 2 ;;
    --chat-model-capacity) chat_model_capacity="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${resource_group}" ] || qam_fail "--resource-group is required"
[ -n "${fabric_admin_member}" ] || qam_fail "--fabric-admin-member is required"
[ -n "${operator_principal_id}" ] || qam_fail "--operator-principal-id is required"
qam_validate_environment "${environment_name}"
qam_validate_workload_name "${workload_name}" "workload name"
qam_validate_uuid "${operator_principal_id}" "operator principal ID"
printf '%s' "${fabric_admin_member}" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+$' \
  || qam_fail "Fabric admin member must be a user principal name"
printf '%s' "${fabric_sku}" | grep -Eq '^F(2|4|8|16|32|64)$' \
  || qam_fail "Fabric SKU must be F2, F4, F8, F16, F32, or F64"
printf '%s' "${chat_model_capacity}" | grep -Eq '^[1-9][0-9]*$' \
  || qam_fail "chat model capacity must be a positive integer"

qam_require_azure_login
if [ -z "${location}" ]; then
  location="$(az group show --name "${resource_group}" --query location --output tsv)"
fi

deployment_name="qam-platform-${environment_name}-$(date -u +%Y%m%d%H%M%S)"
qam_info "deploying Fabric ${fabric_sku} and Foundry ${chat_model_name}@${chat_model_version} as ${deployment_name}"
az deployment group create \
  --name "${deployment_name}" \
  --resource-group "${resource_group}" \
  --template-file "${QAM_INFRA_DIR}/platform.bicep" \
  --parameters \
    "location=${location}" \
    "workloadName=${workload_name}" \
    "environmentName=${environment_name}" \
    "fabricAdminMembers=[\"${fabric_admin_member}\"]" \
    "fabricSkuName=${fabric_sku}" \
    "operatorPrincipalId=${operator_principal_id}" \
    "chatModelName=${chat_model_name}" \
    "chatModelVersion=${chat_model_version}" \
    "chatModelCapacity=${chat_model_capacity}" \
  --query properties.outputs \
  --output json
