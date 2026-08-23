#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qam_root="$(cd "${script_dir}/../../.." && pwd)"
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "${qam_root}/scripts/lib/common.sh"

config_file=''
resume='false'
from_stage='preflight'
through_stage='acceptance'

readonly data_repository_path='quickagenticmemory/tests/industrial-component-obsolescence/data/knowledge'
readonly index_repository_path="${data_repository_path}/index.md"
readonly cleanup_module="${QAM_ROOT_DIR}/agents/foundry/src/qam_foundry/cleanup.py"

stages=(
  preflight
  foundation
  platform
  projection
  fabric
  image
  mcp-api
  identity
  access
  application
  invoker
  attach
  smoke
  cleanup
  acceptance
)

usage() {
  printf '%s\n' \
    'Usage: cloud-run.sh --config FILE [options]' \
    '' \
    'Runs the authorized industrial QAM proof from one exact public Git commit.' \
    'All tenant-specific receipts stay below quickagenticmemory/.artifacts/.' \
    '' \
    'Required:' \
    '  --config FILE              Untracked qam-industrial-cloud-config/1.0 JSON below .artifacts/' \
    '' \
    'Options:' \
    '  --resume                   Verify and reuse completed stage receipts' \
    '  --from-stage NAME          Start after verifying every earlier stage; requires --resume' \
    '  --through-stage NAME       Stop after this stage; default: acceptance' \
    '  --list-stages              Print the ordered stage names and exit' \
    '' \
    'This driver does not run what-if, Docker, or the local A/B test. It compiles only the' \
    'public projection client, then uses Fabric, ACR Tasks, Container Apps, Entra, and Foundry.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) config_file="${2:?missing value for $1}"; shift 2 ;;
    --resume) resume='true'; shift ;;
    --from-stage) from_stage="${2:?missing value for $1}"; shift 2 ;;
    --through-stage) through_stage="${2:?missing value for $1}"; shift 2 ;;
    --list-stages) printf '%s\n' "${stages[@]}"; exit 0 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${config_file}" ] || qam_fail "--config is required"
[ -f "${config_file}" ] || qam_fail "config file does not exist"

qam_require_command az
qam_require_command curl
qam_require_command git
qam_require_command jq
qam_require_command node
qam_require_command npm
qam_require_command uv
qam_require_command uuidgen

config_dir="$(cd "$(dirname "${config_file}")" && pwd)"
config_file="${config_dir}/$(basename "${config_file}")"
artifacts_base="${QAM_ROOT_DIR}/.artifacts"
case "${config_file}" in
  "${artifacts_base}"/*) ;;
  *) qam_fail "the populated config must stay below quickagenticmemory/.artifacts/" ;;
esac

jq -e '
  .schemaVersion == "qam-industrial-cloud-config/1.0" and
  (.source.repository | type == "string" and length > 2) and
  (.source.gitUrl | type == "string" and length > 10) and
  (.source.commitSha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.azure.subscription | type == "string" and length > 0) and
  (.azure.resourceGroup | type == "string" and length > 0) and
  (.azure.location | type == "string" and test("^[a-z0-9]+$")) and
  (.azure.workload | type == "string") and
  (.azure.environment == "dev" or .azure.environment == "test" or .azure.environment == "prod") and
  (.principals.fabricAdminMember | type == "string" and contains("@")) and
  (.principals.operatorPrincipalId | type == "string") and
  (.principals.deploymentPrincipalId | type == "string") and
  (.principals.invokerPrincipalId | type == "string") and
  .principals.invokerPrincipalType == "User" and
  (.principals.temporaryAcrWriter == null or
    ((.principals.temporaryAcrWriter.principalId | type == "string") and
     .principals.temporaryAcrWriter.principalType == "User")) and
  (.platform.fabricSku == "F2" or .platform.fabricSku == "F4" or .platform.fabricSku == "F8") and
  (.platform.workspaceName | type == "string" and length > 0) and
  (.platform.lakehouseName | type == "string" and length > 0) and
  (.platform.graphModelName | type == "string" and length > 0) and
  (.platform.notebookName | type == "string" and length > 0) and
  (.platform.chatModelName | type == "string" and length > 0) and
  (.platform.chatModelVersion | type == "string" and length > 0) and
  (.platform.chatModelCapacity | type == "number" and floor == . and . > 0) and
  (.foundry.mcpApiDisplayName | type == "string" and length > 0) and
  (.foundry.mcpApiClientId | type == "string" and
    (. == "" or test("^[0-9a-fA-F-]{36}$"))) and
  (.foundry.agentName | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.foundry.applicationName | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.foundry.deploymentName | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  .foundry.connectionName == "qam-mcp-project-identity" and
  .foundry.cleanupSupersededAccess == true and
  .image.repository == "qam-mcp" and
  (.image.expectedExistingDigest | type == "string" and
    (. == "" or test("^sha256:[0-9a-f]{64}$"))) and
  (.acceptance.documents | type == "number" and floor == . and . > 0) and
  (.acceptance.nodes | type == "number" and floor == . and . > 0) and
  (.acceptance.edges | type == "number" and floor == . and . >= 0) and
  (.acceptance.conceptTerm | type == "string" and length > 0) and
  (.acceptance.contentMarker | type == "string" and length > 0) and
  ([.. | strings | select(test("[<>]"))] | length) == 0
' "${config_file}" >/dev/null || qam_fail "config is incomplete or violates the cloud-run contract"

json_string() {
  jq -er "$1 | select(type == \"string\")" "${config_file}"
}

json_number() {
  jq -er "$1 | select(type == \"number\")" "${config_file}"
}

casefold() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

public_repository="$(json_string '.source.repository')"
public_git_url="$(json_string '.source.gitUrl')"
public_sha="$(json_string '.source.commitSha')"
subscription="$(json_string '.azure.subscription')"
resource_group="$(json_string '.azure.resourceGroup')"
location="$(json_string '.azure.location')"
workload="$(json_string '.azure.workload')"
environment_name="$(json_string '.azure.environment')"
fabric_admin_member="$(json_string '.principals.fabricAdminMember')"
operator_principal_id="$(json_string '.principals.operatorPrincipalId')"
deployment_principal_id="$(json_string '.principals.deploymentPrincipalId')"
invoker_principal_id="$(json_string '.principals.invokerPrincipalId')"
invoker_principal_type="$(json_string '.principals.invokerPrincipalType')"
fabric_sku="$(json_string '.platform.fabricSku')"
workspace_name="$(json_string '.platform.workspaceName')"
lakehouse_name="$(json_string '.platform.lakehouseName')"
graph_model_name="$(json_string '.platform.graphModelName')"
notebook_name="$(json_string '.platform.notebookName')"
chat_model_name="$(json_string '.platform.chatModelName')"
chat_model_version="$(json_string '.platform.chatModelVersion')"
chat_model_capacity="$(json_number '.platform.chatModelCapacity')"
mcp_api_display_name="$(json_string '.foundry.mcpApiDisplayName')"
configured_mcp_api_client_id="$(json_string '.foundry.mcpApiClientId')"
agent_name="$(json_string '.foundry.agentName')"
application_name="$(json_string '.foundry.applicationName')"
deployment_name="$(json_string '.foundry.deploymentName')"
connection_name="$(json_string '.foundry.connectionName')"
image_repository="$(json_string '.image.repository')"
expected_existing_digest="$(json_string '.image.expectedExistingDigest')"
expected_documents="$(json_number '.acceptance.documents')"
expected_nodes="$(json_number '.acceptance.nodes')"
expected_edges="$(json_number '.acceptance.edges')"
concept_term="$(json_string '.acceptance.conceptTerm')"
content_marker="$(json_string '.acceptance.contentMarker')"

qam_validate_github_repository "${public_repository}" "public source repository"
[ "${public_git_url}" = "https://github.com/${public_repository}.git" ] \
  || qam_fail "source gitUrl must be the canonical public GitHub URL for source.repository"
qam_validate_environment "${environment_name}"
qam_validate_workload_name "${workload}" "workload name"
qam_validate_uuid "${operator_principal_id}" "operator principal ID"
qam_validate_uuid "${deployment_principal_id}" "deployment principal ID"
qam_validate_uuid "${invoker_principal_id}" "invoker principal ID"
[ "$(casefold "${operator_principal_id}")" = "$(casefold "${invoker_principal_id}")" ] \
  || qam_fail "the signed-in operator must also be the configured smoke invoker"
if [ -n "${configured_mcp_api_client_id}" ]; then
  qam_validate_uuid "${configured_mcp_api_client_id}" "MCP API client ID"
fi
if [ -n "${expected_existing_digest}" ]; then
  qam_validate_image_digest "${expected_existing_digest}" "expected existing image digest"
fi

temporary_writer_principal_id=''
temporary_writer_principal_type=''
if [ "$(jq -r '.principals.temporaryAcrWriter == null' "${config_file}")" != 'true' ]; then
  temporary_writer_principal_id="$(json_string '.principals.temporaryAcrWriter.principalId')"
  temporary_writer_principal_type="$(json_string '.principals.temporaryAcrWriter.principalType')"
  qam_validate_uuid "${temporary_writer_principal_id}" "temporary ACR writer principal ID"
fi

repo_root="$(git -C "${QAM_ROOT_DIR}" rev-parse --show-toplevel)"
config_repository_path="${config_file#"${repo_root}/"}"
if [ "${config_repository_path}" != "${config_file}" ] \
  && git -C "${repo_root}" ls-files --error-unmatch \
    -- "${config_repository_path}" >/dev/null 2>&1; then
  qam_fail "the populated cloud config must not be tracked by Git"
fi
# The reviewed reuse digest is a resume-only assertion. Excluding only that field lets an
# operator add it after an interrupted successful build without invalidating unrelated stages.
config_blob_sha="$(jq -cS '.image.expectedExistingDigest = ""' "${config_file}" \
  | git hash-object --stdin)"
artifact_root="${QAM_ROOT_DIR}/.artifacts/cloud-${public_sha:0:12}"
receipts_dir="${artifact_root}/receipts"
stages_dir="${artifact_root}/stages"
public_source_dir="${artifact_root}/public-source"
projection_dir="${artifact_root}/industrial-projection"
definition_dir="${artifact_root}/fabric-definition"

preflight_receipt="${receipts_dir}/public-source.json"
foundation_receipt="${receipts_dir}/foundation.json"
foundation_admin_receipt="${receipts_dir}/foundation-admin.json"
platform_receipt="${receipts_dir}/industrial-platform.json"
fabric_receipt="${receipts_dir}/fabric-publication.json"
image_receipt="${receipts_dir}/image.json"
mcp_api_receipt="${receipts_dir}/mcp-api.json"
identity_receipt="${receipts_dir}/foundry-published-identity.json"
access_receipt="${receipts_dir}/foundry-access.json"
application_receipt="${receipts_dir}/application-deployment.json"
http_smoke_receipt="${receipts_dir}/http-smoke.json"
container_app_receipt="${receipts_dir}/container-app-live.json"
revisions_receipt="${receipts_dir}/container-app-revisions.json"
easyauth_receipt="${receipts_dir}/easyauth-live.json"
invoker_receipt="${receipts_dir}/foundry-invoker.json"
attached_receipt="${receipts_dir}/foundry-attached.json"
foundry_smoke_receipt="${receipts_dir}/foundry-smoke.json"
cleanup_receipt="${receipts_dir}/foundry-cleanup.json"
acceptance_receipt="${receipts_dir}/cloud-acceptance.json"

stage_index() {
  local requested="$1"
  local index
  for index in "${!stages[@]}"; do
    if [ "${stages[$index]}" = "${requested}" ]; then
      printf '%s\n' "${index}"
      return 0
    fi
  done
  return 1
}

start_index="$(stage_index "${from_stage}")" || qam_fail "unknown --from-stage: ${from_stage}"
stop_index="$(stage_index "${through_stage}")" || qam_fail "unknown --through-stage: ${through_stage}"
[ "${start_index}" -le "${stop_index}" ] || qam_fail "--from-stage must not follow --through-stage"
if [ "${from_stage}" != 'preflight' ] && [ "${resume}" != 'true' ]; then
  qam_fail "--from-stage requires --resume"
fi

if [ "${resume}" != 'true' ] && [ -d "${artifact_root}" ] \
  && find "${artifact_root}" -mindepth 1 -print -quit | grep -q .; then
  qam_fail "artifact directory already contains state; use --resume or select a new public commit"
fi
mkdir -p "${receipts_dir}" "${stages_dir}" "${public_source_dir}"

marker_file() {
  printf '%s/%s.complete.json\n' "${stages_dir}" "$1"
}

mark_stage() {
  local stage="$1"
  local marker
  local temporary
  marker="$(marker_file "${stage}")"
  temporary="${marker}.tmp"
  jq -cn \
    --arg schemaVersion 'qam-industrial-cloud-stage/1.0' \
    --arg stage "${stage}" \
    --arg sourceCommitSha "${public_sha}" \
    --arg configBlobSha "${config_blob_sha}" \
    '{schemaVersion: $schemaVersion, stage: $stage,
      sourceCommitSha: $sourceCommitSha, configBlobSha: $configBlobSha}' \
    > "${temporary}"
  mv "${temporary}" "${marker}"
}

verify_marker() {
  local stage="$1"
  local marker
  marker="$(marker_file "${stage}")"
  jq -e \
    --arg stage "${stage}" \
    --arg sha "${public_sha}" \
    --arg config "${config_blob_sha}" '
      .schemaVersion == "qam-industrial-cloud-stage/1.0" and
      .stage == $stage and
      .sourceCommitSha == $sha and
      .configBlobSha == $config
    ' "${marker}" >/dev/null
}

verify_preflight() {
  jq -e \
    --arg repository "${public_repository}" \
    --arg sha "${public_sha}" \
    --argjson documents "${expected_documents}" '
      .contractVersion == "qam-public-source/1.0" and
      .repository == $repository and
      .commitSha == $sha and
      .publicCommit == true and
      .publicIndexRead == true and
      .cloudValidation == "success" and
      .markdownDocuments == $documents and
      .verified == true
    ' "${preflight_receipt}" >/dev/null
}

verify_foundation() {
  jq -e '
    .acrName.value and .acrLoginServer.value and
    .plannedAppResourceId.value and .plannedAppFqdn.value and .plannedAppUrl.value and
    .runtimeIdentityClientId.value and .runtimeIdentityPrincipalId.value
  ' "${foundation_receipt}" >/dev/null &&
    jq -e '
      (.roleAssignmentIds.value | type == "array" and length == 4) and
      (.keyVaultRbacPolicyAssignmentId.value | type == "string" and length > 0)
    ' "${foundation_admin_receipt}" >/dev/null
}

verify_platform() {
  jq -e \
    --arg sku "${fabric_sku}" '
      .platform.fabricCapacitySku == $sku and
      .fabric.workspaceId and .fabric.lakehouseId and
      .fabric.graphModelId and .fabric.notebookId and
      .foundrySmoke.responseStatus == "completed" and
      .foundrySmoke.outputText == "QAM_FOUNDRY_OK"
    ' "${platform_receipt}" >/dev/null
}

verify_projection() {
  jq -e \
    --arg sha "${public_sha}" \
    --arg repository "https://github.com/${public_repository}" \
    --argjson documents "${expected_documents}" \
    --argjson nodes "${expected_nodes}" \
    --argjson edges "${expected_edges}" '
      .schemaVersion == "qam-graph/1.0" and
      .source.commitSha == $sha and
      .source.repository == $repository and
      (.source.projectionId | type == "string" and
        test("^urn:qam:projection:[0-9a-f]{64}$")) and
      .counts.documents == $documents and
      .counts.nodes == $nodes and
      .counts.edges == $edges
    ' "${projection_dir}/manifest.json" >/dev/null
}

verify_fabric() {
  jq -e \
    --arg sha "${public_sha}" \
    --arg projectionId "$(jq -er '.source.projectionId' "${projection_dir}/manifest.json")" \
    --argjson nodes "${expected_nodes}" \
    --argjson edges "${expected_edges}" '
      .publication.commitSha == $sha and
      .notebook.status == "success" and .notebook.commitSha == $sha and
      .notebook.nodeCount == $nodes and .notebook.edgeCount == $edges and
      .graphRefresh.verified == true and
      (.graphRefresh.status == "Completed" or .graphRefresh.status == "Succeeded") and
      .graphQuery.verified == true and .graphQuery.commitSha == $sha and
      .graphQuery.nodeCount == $nodes and .graphQuery.edgeCount == $edges and
      (.graphQuery.projectionId | type == "string" and
        test("^urn:qam:projection:[0-9a-f]{64}$")) and
      .graphQuery.projectionId == $projectionId and
      .publication.projectionId == .graphQuery.projectionId and
      .notebook.projectionId == .graphQuery.projectionId and
      .acceptanceCleanup.completed == true and
      .acceptanceCleanup.finalRole == "Viewer" and
      .acceptanceCleanup.exactAssignmentCount == 1
    ' "${fabric_receipt}" >/dev/null
}

verify_image() {
  jq -e \
    --arg sha "${public_sha}" \
    --arg gitUrl "${public_git_url}" \
    --arg sourceRepository "${public_repository}" \
    --arg imageRepository "${image_repository}" '
      .contractVersion == "qam-acr-cloud-build/1.0" and
      .cloudBuild == true and .source.gitUrl == $gitUrl and
      .source.repository == $sourceRepository and
      .source.commitSha == $sha and .image.repository == $imageRepository and
      .image.tag == $sha and .image.writeEnabled == false and
      .image.deleteEnabled == false and
      (.image.digest | test("^sha256:[0-9a-f]{64}$")) and
      .build.status == "Succeeded" and .verified == true and
      (.temporaryWriter.requested == false or .temporaryWriter.removed == true)
    ' "${image_receipt}" >/dev/null
}

verify_mcp_api() {
  jq -e '
    (.mcpApiClientId | test("^[0-9a-fA-F-]{36}$")) and
    .mcpApiAudience == ("api://" + .mcpApiClientId) and
    .requestedAccessTokenVersion == 2 and
    .allowedClientApplicationIds == [] and .allowedPrincipalIds == []
  ' "${mcp_api_receipt}" >/dev/null
}

verify_identity() {
  jq -e '
    .phase == "published-identity" and
    .applicationIdentitySource == "AgentApplication.defaultInstanceIdentity" and
    .projectManagedIdentitySource == "FoundryProject.identity.systemAssigned" and
    .connectionName == "qam-mcp-project-identity" and
    .accessContract.callerIdentityType == "ProjectManagedIdentity" and
    .accessContract.allowedClientApplicationIds == [.projectManagedIdentityClientId] and
    .accessContract.allowedPrincipalIds == [.projectManagedIdentityPrincipalId]
  ' "${identity_receipt}" >/dev/null
}

verify_access() {
  jq -e '
    .receiptVersion == "qam-foundry-access/2.0" and
    .phase == "access-configured" and
    .callerIdentityType == "ProjectManagedIdentity" and
    .mcpRequestedAccessTokenVersion == 2 and
    .allowedClientApplicationIds == [.projectManagedIdentityClientId] and
    .allowedPrincipalIds == [.projectManagedIdentityPrincipalId]
  ' "${access_receipt}" >/dev/null
}

verify_application() {
  local expected_image
  local project_client_id
  local project_principal_id
  expected_image="$(jq -er '.acrLoginServer.value' "${foundation_receipt}")/${image_repository}@$(jq -er '.image.digest' "${image_receipt}")"
  project_client_id="$(jq -er '.projectManagedIdentityClientId' "${access_receipt}")"
  project_principal_id="$(jq -er '.projectManagedIdentityPrincipalId' "${access_receipt}")"
  jq -e '.verified == true and .healthz.status == 200 and .anonymousMcp.status == 401' \
    "${http_smoke_receipt}" >/dev/null &&
    jq -e \
      --arg image "${expected_image}" \
      --arg repository "${public_repository}" \
      --arg sourceRepository "https://github.com/${public_repository}" \
      --arg workspaceId "$(jq -er '.fabric.workspaceId' "${platform_receipt}")" \
      --arg graphModelId "$(jq -er '.fabric.graphModelId' "${platform_receipt}")" '
        def env($name):
          [.properties.template.containers[0].env[] |
           select(.name == $name) | .value] |
          if length == 1 then .[0] else null end;
        .properties.provisioningState == "Succeeded" and
        .properties.runningStatus == "Running" and
        (.identity.userAssignedIdentities | keys | length) == 2 and
        .properties.template.containers[0].image == $image and
        .properties.latestRevisionName == .properties.latestReadyRevisionName and
        env("QAM_GRAPH_ADAPTER") == "fabric-gql" and
        env("QAM_FABRIC_WORKSPACE_ID") == $workspaceId and
        env("QAM_FABRIC_GRAPH_MODEL_ID") == $graphModelId and
        env("QAM_CONTENT_ADAPTER") == "github" and
        env("QAM_GITHUB_REPOSITORY") == $repository and
        env("QAM_SOURCE_REPOSITORY") == $sourceRepository and
        env("QAM_GITHUB_AUTH_MODE") == "none"
      ' "${container_app_receipt}" >/dev/null &&
    jq -e '
      ([.[] | select(.properties.active == true)] | length) == 1 and
      ([.[] | select(.properties.active == true and
        .properties.runningState == "Running" and
        .properties.healthState == "Healthy" and
        .properties.provisioningState == "Provisioned")] | length) == 1
    ' "${revisions_receipt}" >/dev/null &&
    jq -e \
      --arg api "$(jq -er '.mcpApiClientId' "${mcp_api_receipt}")" \
      --arg client "${project_client_id}" \
      --arg principal "${project_principal_id}" '
        .properties.platform.enabled == true and
        .properties.httpSettings.requireHttps == true and
        .properties.globalValidation.excludedPaths == ["/healthz"] and
        .properties.globalValidation.unauthenticatedClientAction == "Return401" and
        .properties.identityProviders.azureActiveDirectory.registration.clientId == $api and
        .properties.identityProviders.azureActiveDirectory.validation.allowedAudiences == [("api://" + $api)] and
        .properties.identityProviders.azureActiveDirectory.validation
          .defaultAuthorizationPolicy.allowedApplications == [$client] and
        (.properties.identityProviders.azureActiveDirectory.validation
          .defaultAuthorizationPolicy.allowedPrincipals | keys) == ["identities"] and
        .properties.identityProviders.azureActiveDirectory.validation
          .defaultAuthorizationPolicy.allowedPrincipals.identities == [$principal]
      ' "${easyauth_receipt}" >/dev/null
}

verify_invoker() {
  jq -e \
    --arg principal "${invoker_principal_id}" \
    --arg type "${invoker_principal_type}" '
      .invokerPrincipalId == $principal and
      .invokerPrincipalType == $type and .role == "Foundry User"
    ' "${invoker_receipt}" >/dev/null
}

verify_attach() {
  jq -e '
    .phase == "attached" and
    .accessReceiptVersion == "qam-foundry-access/2.0" and
    .projectManagedIdentitySource == "FoundryProject.identity.systemAssigned" and
    .connectionName == "qam-mcp-project-identity" and
    .allowedTools == [
      "browse_index", "resolve_concepts", "get_neighbors", "get_backlinks",
      "find_path", "read_concepts", "trace_provenance"
    ]
  ' "${attached_receipt}" >/dev/null
}

verify_smoke() {
  jq -e --arg sha "${public_sha}" '
    .receiptVersion == "qam-foundry-smoke/1.0" and
    .status == "passed" and .verifiedCommit == $sha and
    .contentMarkerVerified == true and
    .toolEvents == [
      "qam.resolve_concepts", "qam.get_neighbors",
      "qam.trace_provenance", "qam.read_concepts"
    ]
  ' "${foundry_smoke_receipt}" >/dev/null
}

verify_cleanup() {
  jq -e --arg sha "${public_sha}" '
    .receiptVersion == "qam-foundry-project-mi-cleanup/1.0" and
    .phase == "cleanup-verified" and .status == "passed" and
    .verifiedCommit == $sha and
    .activeConnectionName == "qam-mcp-project-identity" and
    .activeConnectionAuthType == "ProjectManagedIdentity" and
    .finalProjectManagedIdentityQamReadCount == 1 and
    .finalAgentApplicationQamReadCount == 0
  ' "${cleanup_receipt}" >/dev/null
}

verify_acceptance() {
  jq -e \
    --arg sha "${public_sha}" \
    --arg repository "${public_repository}" \
    --arg fabricSku "${fabric_sku}" \
    --argjson documents "${expected_documents}" \
    --argjson nodes "${expected_nodes}" \
    --argjson edges "${expected_edges}" '
      .receiptVersion == "qam-industrial-cloud-acceptance/1.0" and
      .status == "passed" and .source.repository == $repository and
      .source.commitSha == $sha and .source.public == true and
      .source.markdownDocuments == $documents and
      .azure.fabricSku == $fabricSku and
      .fabric.nodeCount == $nodes and
      .fabric.edgeCount == $edges and .image.cloudBuild == true and
      .image.immutable == true and
      .containerApp.healthz == 200 and .containerApp.anonymousMcp == 401 and
      .containerApp.activeHealthyRevisions == 1 and
      .containerApp.userAssignedIdentities == 2 and
      .entra.requestedAccessTokenVersion == 2 and
      .entra.projectManagedIdentityQamReadCount == 1 and
      .entra.agentApplicationQamReadCount == 0 and
      .foundry.toolEvents == [
        "qam.resolve_concepts", "qam.get_neighbors",
        "qam.trace_provenance", "qam.read_concepts"
      ] and .foundry.cleanupVerified == true
    ' "${acceptance_receipt}" >/dev/null
}

verify_stage() {
  case "$1" in
    preflight) verify_preflight ;;
    foundation) verify_foundation ;;
    platform) verify_platform ;;
    projection) verify_projection ;;
    fabric) verify_fabric ;;
    image) verify_image ;;
    mcp-api) verify_mcp_api ;;
    identity) verify_identity ;;
    access) verify_access ;;
    application) verify_application ;;
    invoker) verify_invoker ;;
    attach) verify_attach ;;
    smoke) verify_smoke ;;
    cleanup) verify_cleanup ;;
    acceptance) verify_acceptance ;;
    *) return 1 ;;
  esac
}

stage_preflight() {
  local current_user_id
  local current_user_upn
  local status
  local markdown_count

  qam_require_azure_login
  az account set --subscription "${subscription}"
  az group show --name "${resource_group}" --output none

  current_user_id="$(az ad signed-in-user show --query id --output tsv)"
  current_user_upn="$(az ad signed-in-user show --query userPrincipalName --output tsv)"
  [ "$(casefold "${current_user_id}")" = "$(casefold "${operator_principal_id}")" ] \
    || qam_fail "the Azure CLI user does not match operatorPrincipalId"
  [ "$(casefold "${current_user_upn}")" = "$(casefold "${fabric_admin_member}")" ] \
    || qam_fail "the Azure CLI user does not match fabricAdminMember"
  [ "$(casefold "$(az ad sp show --id "${deployment_principal_id}" --query id --output tsv)")" = \
    "$(casefold "${deployment_principal_id}")" ] \
    || qam_fail "deploymentPrincipalId does not identify a visible Entra service principal"
  if [ -n "${temporary_writer_principal_id}" ]; then
    [ "$(casefold "${current_user_id}")" = "$(casefold "${temporary_writer_principal_id}")" ] \
      || qam_fail "temporary ACR writer must be the current Azure CLI user"
  fi

  [ "$(git -C "${repo_root}" rev-parse HEAD)" = "${public_sha}" ] \
    || qam_fail "run cloud-run.sh from a detached or branch checkout of the configured public commit"
  test -z "$(git -C "${repo_root}" status --porcelain --untracked-files=no)" \
    || qam_fail "tracked checkout changes are not allowed in a public-SHA cloud run"

  status="$(curl --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${public_source_dir}/commit.json" \
    --write-out '%{http_code}' \
    "https://api.github.com/repos/${public_repository}/commits/${public_sha}")"
  [ "${status}" = '200' ] || qam_fail "public GitHub commit read returned HTTP ${status}"
  jq -e --arg sha "${public_sha}" '.sha == $sha' \
    "${public_source_dir}/commit.json" >/dev/null \
    || qam_fail "public GitHub commit response does not match the configured SHA"

  status="$(curl --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${public_source_dir}/tree.json" \
    --write-out '%{http_code}' \
    "https://api.github.com/repos/${public_repository}/git/trees/${public_sha}?recursive=1")"
  [ "${status}" = '200' ] || qam_fail "public GitHub tree read returned HTTP ${status}"
  markdown_count="$(jq -er \
    --arg prefix "${data_repository_path}/" '
      select(.truncated == false) |
      [.tree[] | select(.type == "blob") |
       select(.path | startswith($prefix)) |
       select(.path | endswith(".md"))] | length
    ' "${public_source_dir}/tree.json")"
  [ "${markdown_count}" = "${expected_documents}" ] \
    || qam_fail "public data directory Markdown count does not match acceptance config"

  status="$(curl --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${public_source_dir}/check-runs.json" \
    --write-out '%{http_code}' \
    "https://api.github.com/repos/${public_repository}/commits/${public_sha}/check-runs?per_page=100")"
  [ "${status}" = '200' ] || qam_fail "public GitHub check-runs read returned HTTP ${status}"
  jq -e --arg sha "${public_sha}" '
    [.check_runs[] | select(
      .head_sha == $sha and .name == "validate" and
      .status == "completed" and .conclusion == "success"
    )] | length >= 1
  ' "${public_source_dir}/check-runs.json" >/dev/null \
    || qam_fail "QAM validate has no successful GitHub Actions check for the public commit"

  "${QAM_ROOT_DIR}/scripts/validate-github-access.sh" \
    --repository "${public_repository}" \
    --auth-mode none \
    --github-api-url 'https://api.github.com' \
    --github-web-url 'https://github.com' \
    --content-path "${index_repository_path}" \
    --commit-sha "${public_sha}" \
    --live \
    > "${receipts_dir}/github-access.json"

  jq -cn \
    --arg contractVersion 'qam-public-source/1.0' \
    --arg repository "${public_repository}" \
    --arg gitUrl "${public_git_url}" \
    --arg commitSha "${public_sha}" \
    --arg dataPath "${data_repository_path}" \
    --argjson markdownDocuments "${markdown_count}" \
    '{contractVersion: $contractVersion, repository: $repository, gitUrl: $gitUrl,
      commitSha: $commitSha, dataPath: $dataPath, publicCommit: true,
      publicIndexRead: true, cloudValidation: "success",
      markdownDocuments: $markdownDocuments, verified: true}' \
    > "${preflight_receipt}"
}

stage_foundation() {
  "${QAM_ROOT_DIR}/scripts/deploy.sh" \
    --resource-group "${resource_group}" \
    --location "${location}" \
    --workload "${workload}" \
    --environment "${environment_name}" \
    --deployment-principal-id "${deployment_principal_id}" \
    --skip-app \
    > "${foundation_receipt}"

  "${QAM_ROOT_DIR}/scripts/deploy.sh" \
    --resource-group "${resource_group}" \
    --workload "${workload}" \
    --environment "${environment_name}" \
    --deployment-principal-id "${deployment_principal_id}" \
    --skip-app \
    --include-role-assignments \
    > "${foundation_admin_receipt}"
}

stage_platform() {
  local runtime_principal_id
  runtime_principal_id="$(jq -er '.runtimeIdentityPrincipalId.value' "${foundation_receipt}")"
  qam_validate_uuid "${runtime_principal_id}" "runtime principal ID"
  [ "$(casefold "${runtime_principal_id}")" != "$(casefold "${deployment_principal_id}")" ] \
    || qam_fail "runtime and deployment principals must be distinct"

  "${QAM_ROOT_DIR}/scripts/deploy-industrial-platform.sh" \
    --resource-group "${resource_group}" \
    --location "${location}" \
    --workload "${workload}" \
    --environment "${environment_name}" \
    --fabric-admin-member "${fabric_admin_member}" \
    --operator-principal-id "${operator_principal_id}" \
    --runtime-principal-id "${runtime_principal_id}" \
    --deployment-principal-id "${deployment_principal_id}" \
    --fabric-sku "${fabric_sku}" \
    --workspace-name "${workspace_name}" \
    --lakehouse-name "${lakehouse_name}" \
    --graph-model-name "${graph_model_name}" \
    --notebook-name "${notebook_name}" \
    --chat-model-name "${chat_model_name}" \
    --chat-model-version "${chat_model_version}" \
    --chat-model-capacity "${chat_model_capacity}" \
    > "${platform_receipt}"
}

stage_projection() {
  local commit_timestamp
  commit_timestamp="$(git -C "${repo_root}" show -s --format=%cI "${public_sha}")"
  mkdir -p "${projection_dir}"
  npm --prefix "${QAM_ROOT_DIR}" ci >&2
  npm --prefix "${QAM_ROOT_DIR}" run build \
    --workspace @quick-agentic-memory/core >&2
  node "${QAM_ROOT_DIR}/packages/core/dist/cli.js" project \
    "${QAM_ROOT_DIR}/tests/industrial-component-obsolescence/data/knowledge" \
    --output "${projection_dir}" \
    --git-sha "${public_sha}" \
    --generated-at "${commit_timestamp}" \
    --repository "https://github.com/${public_repository}" \
    --path-in-repository "${data_repository_path}" \
    --source-base-url \
      "https://github.com/${public_repository}/blob/${public_sha}/${data_repository_path}" >&2
}

stage_fabric() {
  local workspace_id
  local lakehouse_id
  local notebook_id
  local graph_model_id
  workspace_id="$(jq -er '.fabric.workspaceId' "${platform_receipt}")"
  lakehouse_id="$(jq -er '.fabric.lakehouseId' "${platform_receipt}")"
  notebook_id="$(jq -er '.fabric.notebookId' "${platform_receipt}")"
  graph_model_id="$(jq -er '.fabric.graphModelId' "${platform_receipt}")"
  mkdir -p "${definition_dir}"

  "${QAM_ROOT_DIR}/scripts/publish-industrial-fabric.sh" \
    --workspace-id "${workspace_id}" \
    --lakehouse-id "${lakehouse_id}" \
    --notebook-id "${notebook_id}" \
    --graph-model-id "${graph_model_id}" \
    --projection-dir "${projection_dir}" \
    --definition-dir "${definition_dir}" \
    --acceptance-cleanup \
    --definition-updater-principal-id "${deployment_principal_id}" \
    > "${fabric_receipt}"
}

stage_image() {
  local registry_name
  local -a args
  registry_name="$(jq -er '.acrName.value' "${foundation_receipt}")"
  args=(
    --registry "${registry_name}"
    --repository "${image_repository}"
    --image-tag "${public_sha}"
    --source-git-url "${public_git_url}"
    --source-ref "${public_sha}"
  )
  if [ -n "${expected_existing_digest}" ]; then
    args+=(--expected-existing-digest "${expected_existing_digest}")
  fi
  if [ -n "${temporary_writer_principal_id}" ]; then
    args+=(
      --temporary-writer-principal-id "${temporary_writer_principal_id}"
      --temporary-writer-principal-type "${temporary_writer_principal_type}"
    )
  fi
  "${QAM_ROOT_DIR}/scripts/build-cloud-image.sh" "${args[@]}" \
    > "${image_receipt}"
}

stage_mcp_api() {
  local -a args
  args=(--display-name "${mcp_api_display_name}" --prepare-only)
  if [ -n "${configured_mcp_api_client_id}" ]; then
    args+=(--api-client-id "${configured_mcp_api_client_id}")
  fi
  "${QAM_ROOT_DIR}/scripts/bootstrap-mcp-entra.sh" "${args[@]}" \
    > "${mcp_api_receipt}"
}

stage_identity() {
  local project_endpoint
  local project_resource_id
  local model_deployment
  local app_url
  local app_fqdn
  local mcp_api_client_id
  project_endpoint="$(jq -er '.platform.foundryProjectEndpoint' "${platform_receipt}")"
  project_resource_id="$(jq -er '.platform.foundryProjectId' "${platform_receipt}")"
  model_deployment="$(jq -er '.platform.foundryModelDeploymentName' "${platform_receipt}")"
  app_url="$(jq -er '.plannedAppUrl.value' "${foundation_receipt}")"
  app_fqdn="$(jq -er '.plannedAppFqdn.value' "${foundation_receipt}")"
  mcp_api_client_id="$(jq -er '.mcpApiClientId' "${mcp_api_receipt}")"

  (
    cd "${QAM_ROOT_DIR}/agents/foundry"
    uv sync --locked --all-groups >&2
    uv run qam-foundry-register identity \
      --project-endpoint "${project_endpoint}" \
      --project-resource-id "${project_resource_id}" \
      --model "${model_deployment}" \
      --agent-name "${agent_name}" \
      --application-name "${application_name}" \
      --deployment-name "${deployment_name}" \
      --connection-name "${connection_name}" \
      --mcp-url "${app_url}/mcp" \
      --mcp-audience "api://${mcp_api_client_id}" \
      --allowed-mcp-host "${app_fqdn}" \
      --output "${identity_receipt}"
  )
}

stage_access() {
  "${QAM_ROOT_DIR}/agents/foundry/configure-access.sh" \
    --registration "${identity_receipt}" \
    --mcp-api-client-id "$(jq -er '.mcpApiClientId' "${mcp_api_receipt}")" \
    --mcp-display-name "${mcp_api_display_name}" \
    --container-app-resource-id "$(jq -er '.plannedAppResourceId.value' "${foundation_receipt}")" \
    > "${access_receipt}"
}

stage_application() {
  local workspace_id
  local graph_model_id
  local image_digest
  local allowed_client_ids
  local allowed_principal_ids
  local app_url
  local app_resource_id
  local app_name
  local converged='false'
  local attempt

  workspace_id="$(jq -er '.fabric.workspaceId' "${platform_receipt}")"
  graph_model_id="$(jq -er '.fabric.graphModelId' "${platform_receipt}")"
  image_digest="$(jq -er '.image.digest' "${image_receipt}")"
  allowed_client_ids="$(jq -er '.allowedClientApplicationIds | join(",")' "${access_receipt}")"
  allowed_principal_ids="$(jq -er '.allowedPrincipalIds | join(",")' "${access_receipt}")"

  "${QAM_ROOT_DIR}/scripts/deploy.sh" \
    --resource-group "${resource_group}" \
    --location "${location}" \
    --workload "${workload}" \
    --environment "${environment_name}" \
    --image-digest "${image_digest}" \
    --deployment-principal-id "${deployment_principal_id}" \
    --mcp-api-client-id "$(jq -er '.mcpApiClientId' "${mcp_api_receipt}")" \
    --allowed-client-application-ids "${allowed_client_ids}" \
    --allowed-principal-ids "${allowed_principal_ids}" \
    --fabric-workspace-id "${workspace_id}" \
    --fabric-graph-model-id "${graph_model_id}" \
    --github-repository "${public_repository}" \
    --github-auth-mode none \
    --github-api-url 'https://api.github.com' \
    --github-web-url 'https://github.com' \
    > "${application_receipt}"

  app_url="$(jq -er '.appUrl.value' "${application_receipt}")"
  [ "${app_url}" = "$(jq -er '.plannedAppUrl.value' "${foundation_receipt}")" ] \
    || qam_fail "deployed Container App URL differs from the foundation address contract"
  "${QAM_ROOT_DIR}/scripts/smoke-test.sh" --url "${app_url}"
  jq -cn '{verified: true, healthz: {status: 200}, anonymousMcp: {status: 401}}' \
    > "${http_smoke_receipt}"

  app_resource_id="$(jq -er '.plannedAppResourceId.value' "${foundation_receipt}")"
  app_name="$(jq -er '.appName.value' "${application_receipt}")"
  for ((attempt = 1; attempt <= 60; attempt += 1)); do
    az rest --method GET \
      --url "https://management.azure.com${app_resource_id}?api-version=2025-01-01" \
      --output json > "${container_app_receipt}"
    az containerapp revision list \
      --name "${app_name}" \
      --resource-group "${resource_group}" \
      --output json > "${revisions_receipt}"
    az rest --method GET \
      --url "https://management.azure.com${app_resource_id}/authConfigs/current?api-version=2025-01-01" \
      --output json > "${easyauth_receipt}"
    if verify_application; then
      converged='true'
      break
    fi
    if [ "${attempt}" -lt 60 ]; then sleep 5; fi
  done
  [ "${converged}" = 'true' ] || qam_fail "Container App did not converge to the exact healthy boundary"
}

stage_invoker() {
  "${QAM_ROOT_DIR}/agents/foundry/configure-invoker.sh" \
    --registration "${identity_receipt}" \
    --invoker-principal-id "${invoker_principal_id}" \
    --invoker-principal-type "${invoker_principal_type}" \
    > "${invoker_receipt}"
}

stage_attach() {
  local project_endpoint
  local project_resource_id
  local model_deployment
  local app_url
  local app_fqdn
  local mcp_api_client_id
  project_endpoint="$(jq -er '.platform.foundryProjectEndpoint' "${platform_receipt}")"
  project_resource_id="$(jq -er '.platform.foundryProjectId' "${platform_receipt}")"
  model_deployment="$(jq -er '.platform.foundryModelDeploymentName' "${platform_receipt}")"
  app_url="$(jq -er '.plannedAppUrl.value' "${foundation_receipt}")"
  app_fqdn="$(jq -er '.plannedAppFqdn.value' "${foundation_receipt}")"
  mcp_api_client_id="$(jq -er '.mcpApiClientId' "${mcp_api_receipt}")"

  (
    cd "${QAM_ROOT_DIR}/agents/foundry"
    uv run qam-foundry-register attach \
      --project-endpoint "${project_endpoint}" \
      --project-resource-id "${project_resource_id}" \
      --model "${model_deployment}" \
      --agent-name "${agent_name}" \
      --application-name "${application_name}" \
      --deployment-name "${deployment_name}" \
      --connection-name "${connection_name}" \
      --mcp-url "${app_url}/mcp" \
      --mcp-audience "api://${mcp_api_client_id}" \
      --allowed-mcp-host "${app_fqdn}" \
      --registration "${identity_receipt}" \
      --access-receipt "${access_receipt}" \
      --output "${attached_receipt}"
  )
}

stage_smoke() {
  (
    cd "${QAM_ROOT_DIR}/agents/foundry"
    uv run qam-foundry-smoke \
      --project-endpoint "$(jq -er '.platform.foundryProjectEndpoint' "${platform_receipt}")" \
      --application-name "${application_name}" \
      --registration "${attached_receipt}" \
      --expected-commit "${public_sha}" \
      --concept-term "${concept_term}" \
      --expected-content "${content_marker}" \
      > "${foundry_smoke_receipt}"
  )
}

stage_cleanup() {
  [ -f "${cleanup_module}" ] \
    || qam_fail "the reviewed qam_foundry.cleanup helper is required for final least-privilege proof"
  (
    cd "${QAM_ROOT_DIR}/agents/foundry"
    uv run qam-foundry-cleanup \
      --smoke-receipt "${foundry_smoke_receipt}" \
      --access-receipt "${access_receipt}" \
      --registration "${attached_receipt}" \
      --expected-commit "${public_sha}" \
      --output "${cleanup_receipt}"
  )
}

stage_acceptance() {
  jq -cn \
    --arg receiptVersion 'qam-industrial-cloud-acceptance/1.0' \
    --arg repository "${public_repository}" \
    --arg commitSha "${public_sha}" \
    --arg dataPath "${data_repository_path}" \
    --arg region "${location}" \
    --arg fabricSku "${fabric_sku}" \
    --arg modelName "${chat_model_name}" \
    --arg modelVersion "${chat_model_version}" \
    --arg projectionId "$(jq -er '.graphQuery.projectionId' "${fabric_receipt}")" \
    --arg imageDigest "$(jq -er '.image.digest' "${image_receipt}")" \
    --argjson documentCount "${expected_documents}" \
    --argjson nodeCount "${expected_nodes}" \
    --argjson edgeCount "${expected_edges}" \
    --argjson toolEvents "$(jq '.toolEvents' "${foundry_smoke_receipt}")" '
      {
        receiptVersion: $receiptVersion,
        status: "passed",
        source: {repository: $repository, commitSha: $commitSha,
          dataPath: $dataPath, markdownDocuments: $documentCount, public: true},
        azure: {region: $region, fabricSku: $fabricSku,
          modelName: $modelName, modelVersion: $modelVersion},
        fabric: {projectionId: $projectionId, nodeCount: $nodeCount,
          edgeCount: $edgeCount, refreshVerified: true, gqlVerified: true,
          definitionUpdaterFinalRole: "Viewer"},
        image: {cloudBuild: true, digest: $imageDigest, immutable: true},
        containerApp: {healthz: 200, anonymousMcp: 401,
          activeHealthyRevisions: 1, userAssignedIdentities: 2,
          easyAuthProjectManagedIdentityOnly: true},
        entra: {requestedAccessTokenVersion: 2,
          projectManagedIdentityQamReadCount: 1,
          agentApplicationQamReadCount: 0},
        foundry: {connectionAuthType: "ProjectManagedIdentity",
          toolEvents: $toolEvents, cleanupVerified: true}
      }
    ' > "${acceptance_receipt}"
}

run_stage() {
  local stage="$1"
  local function_name
  local marker
  marker="$(marker_file "${stage}")"
  function_name="stage_${stage//-/_}"

  if [ -f "${marker}" ]; then
    [ "${resume}" = 'true' ] || qam_fail "stage ${stage} is already complete; rerun with --resume"
    if ! verify_marker "${stage}" || ! verify_stage "${stage}"; then
      qam_fail "completed stage ${stage} no longer verifies"
    fi
    qam_info "resume verified stage ${stage}; skipping mutation"
    return 0
  fi

  if [ "${resume}" = 'true' ] && verify_stage "${stage}" >/dev/null 2>&1; then
    mark_stage "${stage}"
    qam_info "resume recovered verified stage ${stage} from its receipt"
    return 0
  fi

  qam_info "starting cloud stage ${stage}"
  "${function_name}"
  verify_stage "${stage}" || qam_fail "stage ${stage} did not produce its exact receipt contract"
  mark_stage "${stage}"
  qam_info "completed cloud stage ${stage}"
}

index=0
while [ "${index}" -lt "${start_index}" ]; do
  prior_stage="${stages[$index]}"
  if [ ! -f "$(marker_file "${prior_stage}")" ] \
    && [ "${resume}" = 'true' ] && verify_stage "${prior_stage}" >/dev/null 2>&1; then
    mark_stage "${prior_stage}"
  fi
  if ! verify_marker "${prior_stage}" || ! verify_stage "${prior_stage}"; then
    qam_fail "cannot start at ${from_stage}; prior stage ${prior_stage} is not verified"
  fi
  index=$((index + 1))
done

index="${start_index}"
while [ "${index}" -le "${stop_index}" ]; do
  run_stage "${stages[$index]}"
  index=$((index + 1))
done

if [ "${through_stage}" = 'acceptance' ]; then
  printf '%s\n' "${acceptance_receipt}"
else
  qam_info "stopped after stage ${through_stage}; resume from the next stage when ready"
fi
