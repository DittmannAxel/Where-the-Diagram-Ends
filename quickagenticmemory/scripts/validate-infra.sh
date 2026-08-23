#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

qam_require_command az

dockerignore="${QAM_REPOSITORY_ROOT}/.dockerignore"
dockerfile_specific_ignore="${QAM_REPOSITORY_ROOT}/quickagenticmemory/packages/mcp/Dockerfile.dockerignore"
expected_dockerignore="$(printf '%s\n' \
  '**' \
  '!/.dockerignore' \
  '!/quickagenticmemory/' \
  '!/quickagenticmemory/contracts/' \
  '!/quickagenticmemory/contracts/qam-graph-1.0.ts' \
  '!/quickagenticmemory/packages/' \
  '!/quickagenticmemory/packages/mcp/' \
  '!/quickagenticmemory/packages/mcp/Dockerfile' \
  '!/quickagenticmemory/packages/mcp/package.json' \
  '!/quickagenticmemory/packages/mcp/package-lock.json' \
  '!/quickagenticmemory/packages/mcp/tsconfig.json' \
  '!/quickagenticmemory/packages/mcp/src/' \
  '!/quickagenticmemory/packages/mcp/src/**')"
[ -f "${dockerignore}" ] || qam_fail "repository-root .dockerignore is required"
[ ! -e "${dockerfile_specific_ignore}" ] \
  || qam_fail "Dockerfile.dockerignore would override the reviewed repository-root build-context policy"
actual_dockerignore="$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "${dockerignore}")"
[ "${actual_dockerignore}" = "${expected_dockerignore}" ] \
  || qam_fail "repository-root .dockerignore must contain only the reviewed MCP build-context allowlist"

require_optional_tools="${QAM_REQUIRE_INFRA_TOOLS:-${CI:-false}}"
require_or_skip() {
  local command_name="$1"
  local purpose="$2"

  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${require_optional_tools}" = "true" ]; then
    qam_fail "${command_name} is required for ${purpose} in CI"
  fi
  qam_info "${command_name} is not installed; ${purpose} was skipped"
  return 1
}

if ! az bicep version >/dev/null 2>&1; then
  qam_fail "Bicep CLI is unavailable; install it with 'az bicep install'"
fi

validation_dir="$(mktemp -d)"
trap 'rm -rf "${validation_dir}"' EXIT

qam_info "building the Bicep deployment"
az bicep build \
  --file "${QAM_INFRA_DIR}/main.bicep" \
  --outfile "${validation_dir}/main.json"

qam_info "building the isolated administrator Bicep deployment"
az bicep build \
  --file "${QAM_INFRA_DIR}/admin.bicep" \
  --outfile "${validation_dir}/admin.json"

qam_info "building the optional paid Fabric and Foundry platform deployment"
az bicep build \
  --file "${QAM_INFRA_DIR}/platform.bicep" \
  --outfile "${validation_dir}/platform.json"

for parameter_file in "${QAM_INFRA_DIR}"/*.bicepparam; do
  qam_info "building $(basename "${parameter_file}")"
  az bicep build-params \
    --file "${parameter_file}" \
    --outfile "${validation_dir}/$(basename "${parameter_file}" .bicepparam).parameters.json"
done

qam_require_command jq
qam_info "validating the pre-application address handoff contract"
jq -e '
  .outputs.plannedAppResourceId.type == "string" and
  (.outputs.plannedAppResourceId.value | contains("Microsoft.App/containerApps")) and
  ((.outputs.plannedAppResourceId.value | contains("deployContainerApp")) | not) and
  .outputs.plannedAppFqdn.type == "string" and
  .outputs.plannedAppUrl.type == "string" and
  (.outputs.plannedAppUrl.value | contains("https://")) and
  (.outputs.plannedAppUrl.value | contains("containerEnvironment")) and
  ((.outputs.plannedAppUrl.value | contains("deployContainerApp")) | not) and
  (.outputs.appUrl.value | contains("deployContainerApp"))
' "${validation_dir}/main.json" >/dev/null \
  || qam_fail "compiled Bicep does not preserve separate planned and deployed app URL outputs"

qam_info "validating that the routine template has no privileged Authorization resources"
jq -e '
  (.parameters | has("deployRoleAssignments") | not) and
  (.parameters | has("deploymentPrincipalId") | not) and
  ([.. | objects | select((.type? // "") | startswith("Microsoft.Authorization/"))] | length == 0) and
  ([.. | objects | select(.type? == "Microsoft.ContainerRegistry/registries")]
    | length == 1 and .[0].apiVersion == "2025-11-01" and .[0].properties.roleAssignmentMode == "AbacRepositoryPermissions")
' "${validation_dir}/main.json" >/dev/null \
  || qam_fail "routine compiled Bicep contains privileged Authorization resources or violates the ACR ABAC contract"

qam_info "validating the isolated administrator template contract"
jq -e '
  (.parameters | keys | sort) == ["deploymentPrincipalId", "environmentName", "workloadName"] and
  (.parameters.deploymentPrincipalId | has("defaultValue") | not) and
  .parameters.deploymentPrincipalId.minLength == 36 and
  .parameters.deploymentPrincipalId.maxLength == 36 and
  .parameters.workloadName.defaultValue == "qam" and
  (.resources | length == 5) and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments")] | length == 4) and
  ([.resources[] | select(.type == "Microsoft.Authorization/policyAssignments")] | length == 1) and
  all(.resources[]; .type == "Microsoft.Authorization/roleAssignments" or .type == "Microsoft.Authorization/policyAssignments") and
  all(.resources[] | select(.type == "Microsoft.Authorization/roleAssignments");
    .apiVersion == "2022-04-01" and
    .properties.principalType == "ServicePrincipal" and
    (.properties | has("condition") | not)) and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments") | .scope | select(contains("Microsoft.ContainerRegistry/registries"))] | length == 2) and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments") | .scope | select(contains("Microsoft.KeyVault/vaults"))] | length == 1) and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments") | .scope | select(contains("Microsoft.Insights/components"))] | length == 1) and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments") | .properties.principalId | select(contains("parameters(\u0027deploymentPrincipalId\u0027)"))] | length == 1) and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments") | .properties.principalId | select(contains("Microsoft.ManagedIdentity/userAssignedIdentities"))] | length == 3) and
  (.variables.repositoryReaderRoleId | contains("b93aa761-3e63-49ed-ac28-beffa264f7ac")) and
  (.variables.repositoryWriterRoleId | contains("2a1e307c-b015-4ebd-883e-5b7698a07328")) and
  (.variables.keyVaultSecretsUserRoleId | contains("4633458b-17de-408a-b874-0445c86b69e6")) and
  (.variables.monitoringMetricsPublisherRoleId | contains("3913510d-42f4-4e42-8a64-420c390055eb")) and
  (.variables.keyVaultRbacPolicyDefinitionId | contains("12d4fa5e-1f9f-4c21-97a9-b99b3c6611b5")) and
  ([.resources[] | select(.type == "Microsoft.Authorization/policyAssignments")][0]
    | .apiVersion == "2025-11-01" and
      (.scope == null) and
      .properties.enforcementMode == "Default" and
      .properties.parameters.effect.value == "Deny" and
      (.properties.policyDefinitionId | contains("keyVaultRbacPolicyDefinitionId"))) and
  (.outputs.roleAssignmentIds.value | length == 4)
' "${validation_dir}/admin.json" >/dev/null \
  || qam_fail "administrator compiled Bicep must contain only the exact four narrow assignments and one RG-scoped Key Vault Deny policy"

qam_info "validating deterministic foundation references shared by main and administrator templates"
jq -se '
  .[0] as $main |
  .[1] as $admin |
  $admin.variables.suffix == $main.variables.suffix and
  $admin.variables.compactPrefix == $main.variables.compactPrefix and
  $admin.variables.prefix == $main.variables.prefix and
  all(["appInsights", "keyVault", "pullIdentity", "registry", "runtimeIdentity"][];
    $admin.variables.names[.] == $main.variables.names[.])
' "${validation_dir}/main.json" "${validation_dir}/admin.json" >/dev/null \
  || qam_fail "administrator template resource naming drifted from the routine foundation template"

qam_info "validating the tenant-neutral paid platform template contract"
jq -e '
  (.parameters.fabricAdminMembers | has("defaultValue") | not) and
  .parameters.fabricAdminMembers.minLength == 1 and
  .parameters.operatorPrincipalId.defaultValue == "" and
  .parameters.fabricSkuName.defaultValue == "F2" and
  .parameters.fabricSkuName.allowedValues == ["F2", "F4", "F8"] and
  .parameters.chatModelCapacity.minValue == 1 and
  .parameters.tags.defaultValue == {} and
  (.variables.commonTags | contains("public-synthetic")) and
  ([.resources[] | .type] | sort) == [
    "Microsoft.Authorization/roleAssignments",
    "Microsoft.CognitiveServices/accounts",
    "Microsoft.CognitiveServices/accounts/deployments",
    "Microsoft.CognitiveServices/accounts/projects",
    "Microsoft.Fabric/capacities"
  ] and
  ([.resources[] | select(.type == "Microsoft.Fabric/capacities")][0]
    | .apiVersion == "2023-11-01" and
      .sku.tier == "Fabric" and
      (.sku.name | contains("fabricSkuName")) and
      (.properties.administration.members | contains("fabricAdminMembers"))) and
  ([.resources[] | select(.type == "Microsoft.CognitiveServices/accounts")][0]
    | .apiVersion == "2025-06-01" and
      .kind == "AIServices" and
      .sku.name == "S0" and
      .identity.type == "SystemAssigned" and
      .properties.allowProjectManagement == true and
      .properties.disableLocalAuth == true and
      .properties.publicNetworkAccess == "Enabled" and
      .properties.restrictOutboundNetworkAccess == false) and
  ([.resources[] | select(.type == "Microsoft.CognitiveServices/accounts/projects")][0]
    | .apiVersion == "2025-06-01" and
      .identity.type == "SystemAssigned" and
      (.dependsOn | index("foundryAccount") != null)) and
  ([.resources[] | select(.type == "Microsoft.CognitiveServices/accounts/deployments")][0]
    | .apiVersion == "2025-06-01" and
      .sku.name == "GlobalStandard" and
      (.sku.capacity | contains("chatModelCapacity")) and
      .properties.model.format == "OpenAI" and
      (.properties.model.name | contains("chatModelName")) and
      (.properties.model.version | contains("chatModelVersion")) and
      .properties.versionUpgradeOption == "OnceCurrentVersionExpired") and
  ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments")][0]
    | .apiVersion == "2022-04-01" and
      (.condition | contains("operatorPrincipalId")) and
      (.scope | contains("Microsoft.CognitiveServices/accounts")) and
      ((.scope | contains("Microsoft.CognitiveServices/accounts/projects")) | not) and
      (.properties.principalId | contains("operatorPrincipalId")) and
      .properties.principalType == "User" and
      (.properties.roleDefinitionId | contains("foundryProjectManagerRoleId"))) and
  (.variables.foundryProjectManagerRoleId | contains("eadc314b-1a2d-4efa-be10-5d325db5065e")) and
  (.outputs | keys | sort) == [
    "fabricCapacityId",
    "fabricCapacityName",
    "fabricCapacitySku",
    "foundryAccountName",
    "foundryModelDeploymentName",
    "foundryModelName",
    "foundryModelVersion",
    "foundryProjectEndpoint",
    "foundryProjectId",
    "foundryProjectName"
  ]
' "${validation_dir}/platform.json" >/dev/null \
  || qam_fail "compiled platform Bicep violates the reviewed Fabric, Foundry, identity, SKU, or tenant-neutral parameter contract"

expect_cli_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    qam_fail "CLI negative test unexpectedly passed: ${label}"
  fi
}

qam_info "validating paid platform CLI guards without Azure mutations"
expect_cli_failure "missing Fabric administrator" \
  "${QAM_SCRIPTS_DIR}/platform-deploy.sh" \
  --resource-group qam-platform-contract \
  --operator-principal-id 11111111-1111-4111-8111-111111111111
expect_cli_failure "unsupported Fabric SKU" \
  "${QAM_SCRIPTS_DIR}/platform-what-if.sh" \
  --resource-group qam-platform-contract \
  --fabric-admin-member fabric-admin@example.invalid \
  --operator-principal-id 11111111-1111-4111-8111-111111111111 \
  --fabric-sku F16
expect_cli_failure "invalid Foundry operator principal" \
  "${QAM_SCRIPTS_DIR}/platform-deploy.sh" \
  --resource-group qam-platform-contract \
  --fabric-admin-member fabric-admin@example.invalid \
  --operator-principal-id not-a-uuid
expect_cli_failure "non-positive model capacity" \
  "${QAM_SCRIPTS_DIR}/platform-what-if.sh" \
  --resource-group qam-platform-contract \
  --fabric-admin-member fabric-admin@example.invalid \
  --operator-principal-id 11111111-1111-4111-8111-111111111111 \
  --chat-model-capacity 0
expect_cli_failure "unsupported capacity lifecycle action" \
  "${QAM_SCRIPTS_DIR}/manage-fabric-capacity.sh" \
  --resource-group qam-platform-contract \
  --capacity-name qamtest123fabric \
  --action delete

platform_cli_mock_log="${validation_dir}/platform-cli.log"
: > "${platform_cli_mock_log}"
(
  # shellcheck disable=SC2329 # exported into the platform scripts' Bash processes
  az() {
    case "${1:-}:${2:-}:${3:-}" in
      account:show:*)
        if [[ " $* " == *' --query id '* ]]; then
          printf '%s\n' '22222222-2222-4222-8222-222222222222'
        fi
        ;;
      deployment:group:create | deployment:group:what-if)
        printf '%q ' "$@" >> "${QAM_PLATFORM_CLI_MOCK_LOG}"
        printf '\n' >> "${QAM_PLATFORM_CLI_MOCK_LOG}"
        printf '{}\n'
        ;;
      rest:*)
        printf '%q ' "$@" >> "${QAM_PLATFORM_CLI_MOCK_LOG}"
        printf '\n' >> "${QAM_PLATFORM_CLI_MOCK_LOG}"
        printf '%s\n' '{"name":"qamtest123fabric","sku":"F2","state":"Active","provisioningState":"Succeeded"}'
        ;;
      *) return 1 ;;
    esac
  }
  export -f az
  export QAM_PLATFORM_CLI_MOCK_LOG="${platform_cli_mock_log}"

  "${QAM_SCRIPTS_DIR}/platform-deploy.sh" \
    --resource-group qam-platform-contract \
    --location westeurope \
    --environment test \
    --fabric-admin-member fabric-admin@example.invalid \
    --operator-principal-id 11111111-1111-4111-8111-111111111111 >/dev/null
  "${QAM_SCRIPTS_DIR}/platform-what-if.sh" \
    --resource-group qam-platform-contract \
    --location westeurope \
    --environment test \
    --fabric-admin-member fabric-admin@example.invalid \
    --operator-principal-id 11111111-1111-4111-8111-111111111111 >/dev/null
  "${QAM_SCRIPTS_DIR}/manage-fabric-capacity.sh" \
    --resource-group qam-platform-contract \
    --capacity-name qamtest123fabric >/dev/null
)

[ "$(grep -c '^deployment group create ' "${platform_cli_mock_log}")" -eq 1 ] \
  && [ "$(grep -c '^deployment group what-if ' "${platform_cli_mock_log}")" -eq 1 ] \
  || qam_fail "platform CLI contract expected exactly one mocked deploy and one mocked what-if"
[ "$(grep -Fc -- "--template-file ${QAM_INFRA_DIR}/platform.bicep" "${platform_cli_mock_log}")" -eq 2 ] \
  || qam_fail "paid platform scripts must select only platform.bicep"
[ "$(grep -c 'fabric-admin@example.invalid' "${platform_cli_mock_log}")" -eq 2 ] \
  && [ "$(grep -c 'operatorPrincipalId=11111111-1111-4111-8111-111111111111' "${platform_cli_mock_log}")" -eq 2 ] \
  || qam_fail "paid platform scripts did not pass tenant identities only as runtime parameters"
[ "$(grep -c '^rest --method GET ' "${platform_cli_mock_log}")" -eq 1 ] \
  || qam_fail "Fabric capacity default lifecycle action must perform exactly one read"
if grep -q '^rest --method POST ' "${platform_cli_mock_log}"; then
  qam_fail "local platform validation must never suspend or resume Fabric capacity"
fi
if ! grep -Fq '/providers/Microsoft.Fabric/capacities/qamtest123fabric' "${platform_cli_mock_log}" \
  || ! grep -Fq 'api-version=2023-11-01' "${platform_cli_mock_log}"; then
  qam_fail "Fabric capacity status command left the reviewed ARM resource or API-version contract"
fi

qam_info "validating industrial platform and commit-publication orchestrator contracts"
for script_name in \
  bootstrap-fabric-items.sh \
  deploy-industrial-platform.sh \
  generate-fabric-graph-definition.sh \
  publish-industrial-fabric.sh \
  smoke-test-foundry.sh; do
  [ -x "${QAM_SCRIPTS_DIR}/${script_name}" ] \
    || qam_fail "industrial platform script is missing or not executable: ${script_name}"
done

industrial_orchestrator="${QAM_SCRIPTS_DIR}/deploy-industrial-platform.sh"
industrial_platform_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/platform-deploy.sh" "${industrial_orchestrator}" | head -1 | cut -d: -f1)"
industrial_items_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/bootstrap-fabric-items.sh" "${industrial_orchestrator}" | head -1 | cut -d: -f1)"
industrial_access_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/grant-fabric-access.sh" "${industrial_orchestrator}" | head -1 | cut -d: -f1)"
industrial_foundry_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/smoke-test-foundry.sh" "${industrial_orchestrator}" | head -1 | cut -d: -f1)"
[ -n "${industrial_platform_line}" ] \
  && [ "${industrial_platform_line}" -lt "${industrial_items_line}" ] \
  && [ "${industrial_items_line}" -lt "${industrial_access_line}" ] \
  && [ "${industrial_access_line}" -lt "${industrial_foundry_line}" ] \
  || qam_fail "industrial orchestrator must deploy platform, bootstrap Fabric items, grant roles, then run Foundry inference"
if grep -Fq 'platform-what-if.sh' "${industrial_orchestrator}"; then
  qam_fail "industrial orchestrator must not make a separate what-if a hidden prerequisite"
fi
grep -Fq -- "--definition-updater-principal-id \"\${deployment_principal_id}\"" "${industrial_orchestrator}" \
  || qam_fail "industrial orchestrator must make the selected deployment principal the explicit definition updater"

fabric_publication="${QAM_SCRIPTS_DIR}/publish-industrial-fabric.sh"
publication_onelake_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" "${fabric_publication}" | head -1 | cut -d: -f1)"
publication_notebook_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/run-fabric-projection-notebook.sh" "${fabric_publication}" | head -1 | cut -d: -f1)"
publication_generate_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/generate-fabric-graph-definition.sh" "${fabric_publication}" | head -1 | cut -d: -f1)"
publication_update_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/update-fabric-graph-definition.sh" "${fabric_publication}" | head -1 | cut -d: -f1)"
publication_gql_line="$(grep -nF "\${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" "${fabric_publication}" | head -1 | cut -d: -f1)"
[ -n "${publication_onelake_line}" ] \
  && [ "${publication_onelake_line}" -lt "${publication_notebook_line}" ] \
  && [ "${publication_notebook_line}" -lt "${publication_generate_line}" ] \
  && [ "${publication_generate_line}" -lt "${publication_update_line}" ] \
  && [ "${publication_update_line}" -lt "${publication_gql_line}" ] \
  || qam_fail "Fabric publication must stage OneLake, run the Notebook, apply the definition, then query the graph"
# shellcheck disable=SC2016 # Match the publisher's literal manifest-derived variable names.
for manifest_gate_argument in \
  '--expected-commit-sha "${expected_commit_sha}"' \
  '--expected-projection-id "${expected_projection_id}"' \
  '--expected-repository "${expected_repository}"' \
  '--expected-node-count "${expected_node_count}"' \
  '--expected-edge-count "${expected_edge_count}"'; do
  grep -Fq -- "${manifest_gate_argument}" "${fabric_publication}" \
    || qam_fail "Fabric publication must pass every manifest-bound expectation into the final GQL gate: ${manifest_gate_argument}"
done

expect_cli_failure "industrial runtime and deployment identities are not separated" \
  "${industrial_orchestrator}" \
  --resource-group qam-platform-contract \
  --fabric-admin-member fabric-admin@example.invalid \
  --operator-principal-id 11111111-1111-4111-8111-111111111111 \
  --runtime-principal-id 22222222-2222-4222-8222-222222222222 \
  --deployment-principal-id 22222222-2222-4222-8222-222222222222
expect_cli_failure "invalid Fabric capacity name reaches the item API" \
  "${QAM_SCRIPTS_DIR}/bootstrap-fabric-items.sh" \
  --capacity-name 'INVALID-CAPACITY'
expect_cli_failure "untrusted Foundry project endpoint reaches inference" \
  "${QAM_SCRIPTS_DIR}/smoke-test-foundry.sh" \
  --project-endpoint 'https://example.invalid/api/projects/qam-test' \
  --model-deployment qam-model-test
expect_cli_failure "Fabric publication accepts a non-UUID graph ID" \
  "${fabric_publication}" \
  --workspace-id 33333333-3333-4333-8333-333333333333 \
  --lakehouse-id 44444444-4444-4444-8444-444444444444 \
  --notebook-id 55555555-5555-4555-8555-555555555555 \
  --graph-model-id not-a-uuid \
  --projection-dir "${validation_dir}/missing-projection"

qam_info "validating the generated canonical Fabric Graph public definition"
graph_definition_dir="${validation_dir}/generated-graph-definition"
graph_definition_receipt="$("${QAM_SCRIPTS_DIR}/generate-fabric-graph-definition.sh" \
  --workspace-id 33333333-3333-4333-8333-333333333333 \
  --lakehouse-id 44444444-4444-4444-8444-444444444444 \
  --output-dir "${graph_definition_dir}")"
jq -e \
  --arg directory "${graph_definition_dir}" \
  '.definitionDirectory == $directory and
   .parts == ["dataSources.json", "graphDefinition.json", "graphType.json", "stylingConfiguration.json"] and
   .lakehouseReference == "QamLakehouse" and
   .nodeTablePath == "Tables/qamnode" and
   .edgeTablePath == "Tables/qamedge"' \
  <<< "${graph_definition_receipt}" >/dev/null \
  || qam_fail "Graph definition generator returned an unexpected receipt"

validate_graph_alias_references() {
  local definition_dir="$1"

  jq -se '
    .[0] as $sources |
    .[1] as $definition |
    .[2] as $types |
    ($sources.dataSources | map(.name)) as $sourceNames |
    ($types.nodeTypes | map(.alias)) as $nodeAliases |
    ($types.edgeTypes | map(.alias)) as $edgeAliases |
    all($definition.nodeTables[];
      (.dataSourceName as $name | $sourceNames | index($name) != null) and
      (.nodeTypeAlias as $alias | $nodeAliases | index($alias) != null)) and
    all($definition.edgeTables[];
      (.dataSourceName as $name | $sourceNames | index($name) != null) and
      (.edgeTypeAlias as $alias | $edgeAliases | index($alias) != null)) and
    all($types.edgeTypes[];
      (.sourceNodeType.alias as $alias | $nodeAliases | index($alias) != null) and
      (.destinationNodeType.alias as $alias | $nodeAliases | index($alias) != null))
  ' \
    "${definition_dir}/dataSources.json" \
    "${definition_dir}/graphDefinition.json" \
    "${definition_dir}/graphType.json" >/dev/null
}

validate_graph_definition_contract() {
  local definition_dir="$1"
  local expected_workspace_id="$2"
  local expected_lakehouse_id="$3"

  jq -e \
    --arg workspaceId "${expected_workspace_id}" \
    --arg lakehouseId "${expected_lakehouse_id}" '
      .["$schema"] == "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/dataSources/1.1.0/schema.json" and
      .itemReferences == [{
        name: "QamLakehouse",
        item: {workspaceId: $workspaceId, itemId: $lakehouseId}
      }] and
      .dataSources == [
        {name: "QamNode_Table", type: "DeltaTable", properties: {
          referenceName: "QamLakehouse", path: "Tables/qamnode"
        }},
        {name: "QamEdge_Table", type: "DeltaTable", properties: {
          referenceName: "QamLakehouse", path: "Tables/qamedge"
        }}
      ]
    ' "${definition_dir}/dataSources.json" >/dev/null || return 1

  jq -e '
    .["$schema"] == "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/graphDefinition/1.0.0/schema.json" and
    (.nodeTables | length == 1) and
    .nodeTables[0].nodeTypeAlias == "QamNode" and
    .nodeTables[0].dataSourceName == "QamNode_Table" and
    (.nodeTables[0].propertyMappings | length == 24) and
    all(.nodeTables[0].propertyMappings[]; .propertyName == .sourceColumn) and
    (.edgeTables | length == 1) and
    .edgeTables[0].edgeTypeAlias == "QamEdge" and
    .edgeTables[0].dataSourceName == "QamEdge_Table" and
    .edgeTables[0].sourceNodeKeyColumns == ["from"] and
    .edgeTables[0].destinationNodeKeyColumns == ["to"] and
    (.edgeTables[0].propertyMappings | length == 8) and
    all(.edgeTables[0].propertyMappings[]; .propertyName == .sourceColumn)
  ' "${definition_dir}/graphDefinition.json" >/dev/null || return 1

  jq -e '
    .["$schema"] == "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/graphType/1.0.0/schema.json" and
    (.nodeTypes | length == 1) and
    .nodeTypes[0].alias == "QamNode" and
    .nodeTypes[0].labels == ["QamNode"] and
    .nodeTypes[0].primaryKeyProperties == ["id"] and
    (.nodeTypes[0].properties | length == 24) and
    all(.nodeTypes[0].properties[]; .type == "STRING") and
    (.edgeTypes | length == 1) and
    .edgeTypes[0].alias == "QamEdge" and
    .edgeTypes[0].labels == ["QamEdge"] and
    .edgeTypes[0].sourceNodeType.alias == "QamNode" and
    .edgeTypes[0].destinationNodeType.alias == "QamNode" and
    (.edgeTypes[0].properties | length == 8) and
    all(.edgeTypes[0].properties[]; .type == "STRING")
  ' "${definition_dir}/graphType.json" >/dev/null || return 1

  jq -e '
    . == {
      "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/stylingConfiguration/1.0.0/schema.json",
      modelLayout: {
        positions: {QamNode: {x: 120, y: 120}},
        styles: {QamNode: {size: 30}, QamEdge: {size: 20}},
        pan: {x: 0, y: 0},
        zoomLevel: 1
      },
      visualFormat: {}
    }
  ' "${definition_dir}/stylingConfiguration.json" >/dev/null || return 1

  validate_graph_alias_references "${definition_dir}" || return 1
}

make_invalid_graph_definition_fixture() {
  local target_dir="$1"
  local part="$2"
  local mutation="$3"

  mkdir -p "${target_dir}"
  cp "${graph_definition_dir}"/*.json "${target_dir}/"
  jq "${mutation}" "${target_dir}/${part}" > "${target_dir}/${part}.mutated"
  mv "${target_dir}/${part}.mutated" "${target_dir}/${part}"
}

validate_graph_definition_contract \
  "${graph_definition_dir}" \
  33333333-3333-4333-8333-333333333333 \
  44444444-4444-4444-8444-444444444444 \
  || qam_fail "generated Graph definition violates the current public schema or alias contract"

graph_missing_reference_dir="${validation_dir}/graph-missing-reference-name"
make_invalid_graph_definition_fixture \
  "${graph_missing_reference_dir}" \
  dataSources.json \
  'del(.dataSources[0].properties.referenceName)'
expect_cli_failure "Graph definition accepts a Delta table without referenceName" \
  validate_graph_definition_contract \
  "${graph_missing_reference_dir}" \
  33333333-3333-4333-8333-333333333333 \
  44444444-4444-4444-8444-444444444444

graph_unknown_node_alias_dir="${validation_dir}/graph-unknown-node-alias"
make_invalid_graph_definition_fixture \
  "${graph_unknown_node_alias_dir}" \
  graphDefinition.json \
  '.nodeTables[0].nodeTypeAlias = "UnknownNode"'
expect_cli_failure "Graph definition accepts an unknown node type alias" \
  validate_graph_alias_references \
  "${graph_unknown_node_alias_dir}"

graph_unknown_edge_alias_dir="${validation_dir}/graph-unknown-edge-alias"
make_invalid_graph_definition_fixture \
  "${graph_unknown_edge_alias_dir}" \
  graphDefinition.json \
  '.edgeTables[0].edgeTypeAlias = "UnknownEdge"'
expect_cli_failure "Graph definition accepts an unknown edge type alias" \
  validate_graph_alias_references \
  "${graph_unknown_edge_alias_dir}"

graph_unknown_endpoint_alias_dir="${validation_dir}/graph-unknown-endpoint-alias"
make_invalid_graph_definition_fixture \
  "${graph_unknown_endpoint_alias_dir}" \
  graphType.json \
  '.edgeTypes[0].sourceNodeType.alias = "UnknownNode"'
expect_cli_failure "Graph definition accepts an unknown edge endpoint alias" \
  validate_graph_alias_references \
  "${graph_unknown_endpoint_alias_dir}"

expect_cli_failure "Graph definition generator overwrites reviewed parts" \
  "${QAM_SCRIPTS_DIR}/generate-fabric-graph-definition.sh" \
  --workspace-id 33333333-3333-4333-8333-333333333333 \
  --lakehouse-id 44444444-4444-4444-8444-444444444444 \
  --output-dir "${graph_definition_dir}"

qam_info "validating Fabric item reuse and Foundry inference against local HTTP mocks"
live_api_mock_log="${validation_dir}/live-api-mock.log"
fabric_items_receipt="${validation_dir}/fabric-items-receipt.json"
foundry_smoke_receipt="${validation_dir}/foundry-smoke-receipt.json"
: > "${live_api_mock_log}"
(
  # shellcheck disable=SC2329 # exported into the Fabric and Foundry script processes
  az() {
    case "${1:-}:${2:-}:${3:-}" in
      account:show:*) ;;
      account:get-access-token:*) printf '%s\n' 'local-contract-token' ;;
      *) return 1 ;;
    esac
  }

  # shellcheck disable=SC2329 # exported into the Fabric and Foundry script processes
  curl() {
    local method='GET'
    local output_file=''
    local headers_file=''
    local data_file=''
    local url=''
    local status='200'

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --request) method="${2:?}"; shift 2 ;;
        --output) output_file="${2:?}"; shift 2 ;;
        --dump-header) headers_file="${2:?}"; shift 2 ;;
        --data-binary) data_file="${2#@}"; shift 2 ;;
        --header | --write-out) shift 2 ;;
        --silent | --show-error) shift ;;
        https://*) url="$1"; shift ;;
        *) return 97 ;;
      esac
    done
    [ -n "${output_file}" ] && [ -n "${url}" ] || return 98
    if [ -n "${headers_file}" ]; then
      : > "${headers_file}"
    fi
    printf '%s %s\n' "${method}" "${url}" >> "${QAM_LIVE_API_MOCK_LOG}"

    case "${method} ${url}" in
      'GET https://api.fabric.microsoft.com/v1/capacities')
        printf '%s\n' '{"value":[{"id":"33333333-3333-4333-8333-333333333333","displayName":"qamtest123fabric","state":"Active"}]}' > "${output_file}"
        ;;
      'GET https://api.fabric.microsoft.com/v1/workspaces')
        printf '%s\n' '{"value":[{"id":"44444444-4444-4444-8444-444444444444","displayName":"QAM Contract Evidence","capacityId":"33333333-3333-4333-8333-333333333333"}]}' > "${output_file}"
        ;;
      'GET https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/lakehouses')
        printf '%s\n' '{"value":[{"id":"55555555-5555-4555-8555-555555555555","displayName":"qam_contract_evidence"}]}' > "${output_file}"
        ;;
      'GET https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/graphModels')
        printf '%s\n' '{"value":[{"id":"66666666-6666-4666-8666-666666666666","displayName":"QAM Contract Graph"}]}' > "${output_file}"
        ;;
      'GET https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/notebooks')
        printf '%s\n' '{"value":[{"id":"77777777-7777-4777-8777-777777777777","displayName":"qam_contract_loader"}]}' > "${output_file}"
        ;;
      'POST https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/notebooks/77777777-7777-4777-8777-777777777777/updateDefinition?updateMetadata=false')
        jq -e '
          .definition.format == "fabricGitSource" and
          (.definition.parts | length == 1) and
          .definition.parts[0].path == "notebook-content.py" and
          .definition.parts[0].payloadType == "InlineBase64" and
          (.definition.parts[0].payload | length > 0)
        ' "${data_file}" >/dev/null || return 99
        printf '%s\n' '{}' > "${output_file}"
        ;;
      'POST https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/notebooks/77777777-7777-4777-8777-777777777777/getDefinition?format=ipynb')
        notebook_payload="$(
          jq -cn '{
            metadata: {kernel_info: {name: "synapse_pyspark"}},
            cells: [
              {
                metadata: {tags: ["parameters"]},
                source: [
                  "expected_projection_id = \\\"\\\"\\n",
                  "expected_commit_sha = \\\"\\\"\\n"
                ]
              },
              {metadata: {}, source: []}
            ]
          }' | base64 | tr -d '\r\n'
        )"
        jq -cn \
          --arg payload "${notebook_payload}" \
          '{definition: {parts: [{
            path: "notebook-content.ipynb",
            payloadType: "InlineBase64",
            payload: $payload
          }]}}' > "${output_file}"
        ;;
      'POST https://qamcontract.services.ai.azure.com/api/projects/qam-test-industrial/openai/v1/responses')
        jq -e '
          .model == "qam-model-test" and
          .input == "Reply with exactly QAM_FOUNDRY_OK and nothing else." and
          .max_output_tokens == 64
        ' "${data_file}" >/dev/null || return 99
        printf '%s\n' '{"status":"completed","output":[{"content":[{"type":"output_text","text":"QAM_FOUNDRY_OK"}]}],"usage":{"input_tokens":9,"output_tokens":3}}' > "${output_file}"
        ;;
      *) return 100 ;;
    esac
    printf '%s' "${status}"
  }

  export -f az curl
  export QAM_LIVE_API_MOCK_LOG="${live_api_mock_log}"

  "${QAM_SCRIPTS_DIR}/bootstrap-fabric-items.sh" \
    --capacity-name qamtest123fabric \
    --workspace-name 'QAM Contract Evidence' \
    --lakehouse-name qam_contract_evidence \
    --graph-model-name 'QAM Contract Graph' \
    --notebook-name qam_contract_loader > "${fabric_items_receipt}"
  "${QAM_SCRIPTS_DIR}/smoke-test-foundry.sh" \
    --project-endpoint 'https://qamcontract.services.ai.azure.com/api/projects/qam-test-industrial' \
    --model-deployment qam-model-test > "${foundry_smoke_receipt}"
)

jq -e '
  .capacityId == "33333333-3333-4333-8333-333333333333" and
  .workspaceId == "44444444-4444-4444-8444-444444444444" and
  .lakehouseId == "55555555-5555-4555-8555-555555555555" and
  .graphModelId == "66666666-6666-4666-8666-666666666666" and
  .notebookId == "77777777-7777-4777-8777-777777777777"
' "${fabric_items_receipt}" >/dev/null \
  || qam_fail "Fabric item bootstrap did not preserve its exact-name reuse receipt"
jq -e '
  .modelDeployment == "qam-model-test" and
  .responseStatus == "completed" and
  .outputText == "QAM_FOUNDRY_OK" and
  .usage == {inputTokens: 9, outputTokens: 3}
' "${foundry_smoke_receipt}" >/dev/null \
  || qam_fail "Foundry smoke did not return the bounded credential-free inference receipt"
[ "$(grep -c '^GET https://api.fabric.microsoft.com/v1/' "${live_api_mock_log}")" -eq 5 ] \
  || qam_fail "Fabric item reuse mock expected exactly five fixed-origin collection reads"
grep -Fxq 'POST https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/notebooks/77777777-7777-4777-8777-777777777777/updateDefinition?updateMetadata=false' \
  "${live_api_mock_log}" \
  || qam_fail "Fabric item reuse must reconcile only the checked-in Notebook definition"
grep -Fxq 'POST https://api.fabric.microsoft.com/v1/workspaces/44444444-4444-4444-8444-444444444444/notebooks/77777777-7777-4777-8777-777777777777/getDefinition?format=ipynb' \
  "${live_api_mock_log}" \
  || qam_fail "Fabric item reuse must verify the canonical Notebook parameter cell"
[ "$(grep -c '^POST https://api.fabric.microsoft.com/' "${live_api_mock_log}")" -eq 2 ] \
  || qam_fail "local Fabric item reuse validation must only reconcile and verify the checked-in Notebook"
grep -Fxq 'POST https://qamcontract.services.ai.azure.com/api/projects/qam-test-industrial/openai/v1/responses' \
  "${live_api_mock_log}" \
  || qam_fail "Foundry smoke left the exact project-scoped Responses API endpoint"

oidc_bootstrap="${QAM_SCRIPTS_DIR}/bootstrap-github-oidc.sh"
grep -q -- '--include-groups' "${oidc_bootstrap}" \
  || qam_fail "OIDC privilege audit must include transitive Entra group assignments"

deploy_workflow="${QAM_REPOSITORY_ROOT}/.github/workflows/qam-deploy.yml"
grep -Fq "'.plannedAppResourceId.value" "${deploy_workflow}" \
  || qam_fail "foundation workflow must capture plannedAppResourceId from ARM outputs"
grep -Fq "planned_app_resource_id=%s" "${deploy_workflow}" \
  || qam_fail "foundation workflow must expose plannedAppResourceId in its handoff outputs"
fabric_gate_line="$(grep -n 'name: Gate application deployment on commit-pinned Fabric Graph GQL' "${deploy_workflow}" | cut -d: -f1)"
image_build_line="$(grep -n 'name: Build and push immutable image' "${deploy_workflow}" | cut -d: -f1)"
application_deploy_line="$(grep -n 'name: Deploy MCP application' "${deploy_workflow}" | cut -d: -f1)"
[ -n "${fabric_gate_line}" ] \
  && [ "${fabric_gate_line}" -lt "${image_build_line}" ] \
  && [ "${image_build_line}" -lt "${application_deploy_line}" ] \
  || qam_fail "commit-pinned Fabric GQL must gate image build and ACA deployment"
# shellcheck disable=SC2016 # Match the literal workflow runtime variable.
grep -A 8 'name: Gate application deployment on commit-pinned Fabric Graph GQL' "${deploy_workflow}" \
  | grep -q -- '--expected-commit-sha "${GITHUB_SHA}"' \
  || qam_fail "pre-ACA Fabric GQL gate must require the workflow commit SHA"

qam_info "validating checked-in GitHub and Fabric templates"
jq empty "${QAM_INFRA_DIR}/github/github-app-settings.example.json"
qam_require_command python3
python3 -c 'import ast, pathlib; path = pathlib.Path(__import__("sys").argv[1]); ast.parse(path.read_text(), filename=str(path))' \
  "${QAM_INFRA_DIR}/fabric/qam-load-projection.notebook-content.py"

if command -v shellcheck >/dev/null 2>&1; then
  qam_info "running ShellCheck"
  find "${QAM_SCRIPTS_DIR}" -type f -name '*.sh' -print0 \
    | xargs -0 shellcheck --external-sources --source-path="${QAM_REPOSITORY_ROOT}"
else
  if [ "${require_optional_tools}" = "true" ]; then
    qam_fail "ShellCheck is required in CI"
  fi
  qam_info "ShellCheck is not installed; shell validation was skipped"
fi

qam_info "checking Bash syntax"
find "${QAM_SCRIPTS_DIR}" -type f -name '*.sh' -print0 \
  | xargs -0 -n 1 bash -n

if require_or_skip actionlint "GitHub Actions validation"; then
  qam_info "validating QAM GitHub Actions workflows"
  actionlint "${QAM_REPOSITORY_ROOT}"/.github/workflows/qam-*.yml
fi

if require_or_skip gitleaks "secret scanning"; then
  qam_info "scanning the checkout for secrets with redacted output"
  gitleaks dir --no-banner --redact "${QAM_REPOSITORY_ROOT}"
fi

qam_info "running security-control negative tests"
"${QAM_SCRIPTS_DIR}/tests/security-controls.sh"

qam_info "infrastructure validation completed"
