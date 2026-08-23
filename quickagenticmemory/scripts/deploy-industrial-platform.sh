#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

resource_group="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-}"
environment_name="${QAM_ENVIRONMENT:-test}"
workload_name="${QAM_WORKLOAD_NAME:-qam}"
fabric_admin_member=""
operator_principal_id=""
runtime_principal_id=""
deployment_principal_id=""
fabric_sku="F2"
chat_model_name="gpt-5.4-mini"
chat_model_version="2026-03-17"
chat_model_capacity="50"
workspace_name=""
lakehouse_name=""
graph_model_name=""
notebook_name=""

usage() {
  printf '%s\n' \
    'Usage: deploy-industrial-platform.sh [required options] [optional settings]' \
    '' \
    'Required:' \
    '  --resource-group NAME' \
    '  --fabric-admin-member UPN' \
    '  --operator-principal-id UUID' \
    '  --runtime-principal-id UUID' \
    '  --deployment-principal-id UUID' \
    '' \
    'Deploys the paid Fabric/Foundry platform, creates the isolated Fabric items,' \
    'applies least-privilege workspace roles, and runs a real Foundry inference.' \
    'It is intentionally tenant-neutral and performs no what-if prerequisite.' \
    '' \
    'Optional:' \
    '  --location REGION                  Default: resource-group location' \
    '  --workload NAME                    Default: qam' \
    '  --environment dev|test|prod        Default: test' \
    '  --fabric-sku F2|F4|F8              Default: F2' \
    '  --workspace-name NAME              Default: QAM <environment> Industrial Evidence' \
    '  --lakehouse-name NAME              Default: <workload>_<environment>_industrial' \
    '  --graph-model-name NAME            Default: QAM <environment> Industrial Knowledge Graph' \
    '  --notebook-name NAME               Default: <workload>_<environment>_load_projection' \
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
    --runtime-principal-id) runtime_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --deployment-principal-id) deployment_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --workspace-name) workspace_name="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-name) lakehouse_name="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-name) graph_model_name="${2:?missing value for $1}"; shift 2 ;;
    --notebook-name) notebook_name="${2:?missing value for $1}"; shift 2 ;;
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
[ -n "${runtime_principal_id}" ] || qam_fail "--runtime-principal-id is required"
[ -n "${deployment_principal_id}" ] || qam_fail "--deployment-principal-id is required"
qam_validate_environment "${environment_name}"
qam_validate_workload_name "${workload_name}" "workload name"
qam_validate_uuid "${operator_principal_id}" "operator principal ID"
qam_validate_uuid "${runtime_principal_id}" "runtime principal ID"
qam_validate_uuid "${deployment_principal_id}" "deployment principal ID"
[ "${runtime_principal_id}" != "${deployment_principal_id}" ] \
  || qam_fail "runtime and deployment principals must be distinct"
if [ -z "${workspace_name}" ]; then
  workspace_name="QAM ${environment_name} Industrial Evidence"
fi
if [ -z "${lakehouse_name}" ]; then
  lakehouse_name="${workload_name}_${environment_name}_industrial"
fi
if [ -z "${graph_model_name}" ]; then
  graph_model_name="QAM ${environment_name} Industrial Knowledge Graph"
fi
if [ -z "${notebook_name}" ]; then
  notebook_name="${workload_name}_${environment_name}_load_projection"
fi

platform_args=(
  --resource-group "${resource_group}"
  --workload "${workload_name}"
  --environment "${environment_name}"
  --fabric-admin-member "${fabric_admin_member}"
  --fabric-sku "${fabric_sku}"
  --operator-principal-id "${operator_principal_id}"
  --chat-model-name "${chat_model_name}"
  --chat-model-version "${chat_model_version}"
  --chat-model-capacity "${chat_model_capacity}"
)
if [ -n "${location}" ]; then
  platform_args+=(--location "${location}")
fi

qam_info "deploying the industrial Fabric and Foundry platform"
if ! platform_outputs="$("${QAM_SCRIPTS_DIR}/platform-deploy.sh" "${platform_args[@]}")"; then
  qam_fail "industrial platform ARM deployment failed"
fi
jq -e '
  .fabricCapacityName.value and .foundryProjectEndpoint.value and
  .foundryModelDeploymentName.value
' <<< "${platform_outputs}" >/dev/null \
  || qam_fail "platform deployment did not return the expected output contract"

capacity_name="$(jq -r '.fabricCapacityName.value' <<< "${platform_outputs}")"
foundry_project_endpoint="$(jq -r '.foundryProjectEndpoint.value' <<< "${platform_outputs}")"
foundry_model_deployment="$(jq -r '.foundryModelDeploymentName.value' <<< "${platform_outputs}")"

qam_info "creating or reusing the isolated Fabric workspace and items"
if ! fabric_outputs="$("${QAM_SCRIPTS_DIR}/bootstrap-fabric-items.sh" \
  --capacity-name "${capacity_name}" \
  --workspace-name "${workspace_name}" \
  --lakehouse-name "${lakehouse_name}" \
  --graph-model-name "${graph_model_name}" \
  --notebook-name "${notebook_name}")"; then
  qam_fail "Fabric item bootstrap failed"
fi
jq -e '.workspaceId and .lakehouseId and .graphModelId and .notebookId' \
  <<< "${fabric_outputs}" >/dev/null \
  || qam_fail "Fabric bootstrap did not return the expected output contract"

workspace_id="$(jq -r '.workspaceId' <<< "${fabric_outputs}")"
qam_info "applying least-privilege Fabric workspace roles"
if ! access_outputs="$("${QAM_SCRIPTS_DIR}/grant-fabric-access.sh" \
  --workspace-id "${workspace_id}" \
  --runtime-principal-id "${runtime_principal_id}" \
  --smoke-principal-id "${deployment_principal_id}" \
  --definition-updater-principal-id "${deployment_principal_id}")"; then
  qam_fail "Fabric access grant failed"
fi

qam_info "running a real Foundry Responses API inference"
if ! foundry_smoke="$("${QAM_SCRIPTS_DIR}/smoke-test-foundry.sh" \
  --project-endpoint "${foundry_project_endpoint}" \
  --model-deployment "${foundry_model_deployment}")"; then
  qam_fail "Foundry inference smoke test failed"
fi

jq -cn \
  --argjson platform "${platform_outputs}" \
  --argjson fabric "${fabric_outputs}" \
  --argjson access "${access_outputs}" \
  --argjson foundrySmoke "${foundry_smoke}" \
  '{platform: ($platform | with_entries(.value = .value.value)),
    fabric: $fabric, access: $access, foundrySmoke: $foundrySmoke}'
