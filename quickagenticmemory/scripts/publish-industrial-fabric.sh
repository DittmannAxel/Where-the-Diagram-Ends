#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
lakehouse_id="${QAM_FABRIC_LAKEHOUSE_ID:-}"
notebook_id="${QAM_FABRIC_NOTEBOOK_ID:-}"
graph_model_id="${QAM_FABRIC_GRAPH_MODEL_ID:-}"
projection_dir=""
definition_dir=""
acceptance_cleanup='false'
definition_updater_principal_id=""
graph_query_attempt_limit="${QAM_FABRIC_GRAPH_QUERY_ATTEMPTS:-60}"
graph_query_retry_seconds="${QAM_FABRIC_GRAPH_QUERY_RETRY_SECONDS:-30}"

usage() {
  printf '%s\n' \
    'Usage: publish-industrial-fabric.sh [required options]' \
    '' \
    'Required:' \
    '  --workspace-id UUID' \
    '  --lakehouse-id UUID' \
    '  --notebook-id UUID' \
    '  --graph-model-id UUID' \
    '  --projection-dir DIRECTORY' \
    '' \
    'Optional:' \
    '  --definition-dir DIRECTORY   Preserve generated public Graph definition here.' \
    '  --acceptance-cleanup' \
    '      After the live GQL gate, explicitly downgrade the temporary definition updater to Viewer.' \
    '  --definition-updater-principal-id UUID' \
    '      Required with --acceptance-cleanup; must be the Entra service-principal object ID.' \
    '' \
    'Publishes one clean, commit-pinned projection to immutable OneLake staging,' \
    'loads its Delta tables, applies the canonical Graph definition, completes the' \
    'official RefreshGraph job, and requires bounded live GQL to return the exact' \
    'repository, projection, commit, and counts.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-id) lakehouse_id="${2:?missing value for $1}"; shift 2 ;;
    --notebook-id) notebook_id="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-id) graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --projection-dir) projection_dir="${2:?missing value for $1}"; shift 2 ;;
    --definition-dir) definition_dir="${2:?missing value for $1}"; shift 2 ;;
    --acceptance-cleanup) acceptance_cleanup='true'; shift ;;
    --definition-updater-principal-id)
      definition_updater_principal_id="${2:?missing value for $1}"
      shift 2
      ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

if [ "${acceptance_cleanup}" = 'true' ]; then
  [ -n "${definition_updater_principal_id}" ] \
    || qam_fail "--definition-updater-principal-id is required with --acceptance-cleanup"
  qam_validate_uuid \
    "${definition_updater_principal_id}" "definition updater principal ID"
elif [ -n "${definition_updater_principal_id}" ]; then
  qam_fail "--definition-updater-principal-id requires the explicit --acceptance-cleanup flag"
fi

for pair in \
  "${workspace_id}:Fabric workspace ID" \
  "${lakehouse_id}:Fabric Lakehouse ID" \
  "${notebook_id}:Fabric Notebook ID" \
  "${graph_model_id}:Fabric Graph Model ID"; do
  qam_validate_uuid "${pair%%:*}" "${pair#*:}"
done
[ -n "${projection_dir}" ] || qam_fail "--projection-dir is required"
[ -d "${projection_dir}" ] || qam_fail "projection directory not found: ${projection_dir}"
for file in nodes.ndjson edges.ndjson manifest.json; do
  [ -f "${projection_dir}/${file}" ] || qam_fail "projection file missing: ${file}"
done
qam_require_command jq
printf '%s' "${graph_query_attempt_limit}" | grep -Eq '^[1-9][0-9]*$' \
  && [ "${graph_query_attempt_limit}" -le 120 ] \
  || qam_fail "Fabric Graph query attempts must be an integer from 1 through 120"
printf '%s' "${graph_query_retry_seconds}" | grep -Eq '^[1-9][0-9]*$' \
  && [ "${graph_query_retry_seconds}" -le 300 ] \
  || qam_fail "Fabric Graph query retry seconds must be an integer from 1 through 300"

manifest_file="${projection_dir}/manifest.json"
jq -e '
  .schemaVersion == "qam-graph/1.0" and
  (.source.repository | type == "string" and length > 0) and
  (.source.projectionId | type == "string" and test("^urn:qam:projection:[0-9a-f]{64}$")) and
  (.source.commitSha | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
  (.counts.nodes | type == "number" and floor == . and . > 0 and . < 10000) and
  (.counts.edges | type == "number" and floor == . and . >= 0 and . < 50000)
' "${manifest_file}" >/dev/null \
  || qam_fail "projection manifest does not satisfy the bounded immutable publication contract"
expected_repository="$(jq -r '.source.repository' "${manifest_file}")"
expected_projection_id="$(jq -r '.source.projectionId' "${manifest_file}")"
expected_commit_sha="$(jq -r '.source.commitSha' "${manifest_file}")"
expected_node_count="$(jq -r '.counts.nodes' "${manifest_file}")"
expected_edge_count="$(jq -r '.counts.edges' "${manifest_file}")"

if [ -z "${definition_dir}" ]; then
  definition_dir="$(mktemp -d)"
  trap 'rm -rf "${definition_dir}"' EXIT
fi

qam_info "publishing the immutable projection to OneLake staging"
if ! publish_receipt="$("${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id "${workspace_id}" \
  --lakehouse-id "${lakehouse_id}" \
  --projection-dir "${projection_dir}")"; then
  qam_fail "OneLake projection publication failed"
fi
jq -e '.stagingPath and .projectionId and .commitSha' <<< "${publish_receipt}" >/dev/null \
  || qam_fail "OneLake publisher did not return the expected receipt"
staging_path="$(jq -r '.stagingPath' <<< "${publish_receipt}")"
projection_id="$(jq -r '.projectionId' <<< "${publish_receipt}")"
commit_sha="$(jq -r '.commitSha' <<< "${publish_receipt}")"
[ "${projection_id}" = "${expected_projection_id}" ] \
  || qam_fail "OneLake publication projection ID does not match manifest"
[ "${commit_sha}" = "${expected_commit_sha}" ] \
  || qam_fail "OneLake publication commit does not match manifest"

qam_info "running the checked-in Fabric projection Notebook"
if ! notebook_receipt="$("${QAM_SCRIPTS_DIR}/run-fabric-projection-notebook.sh" \
  --workspace-id "${workspace_id}" \
  --notebook-id "${notebook_id}" \
  --lakehouse-id "${lakehouse_id}" \
  --staging-path "${staging_path}" \
  --projection-id "${projection_id}" \
  --commit-sha "${commit_sha}")"; then
  qam_fail "Fabric projection Notebook failed"
fi
jq -e \
  --arg projectionId "${expected_projection_id}" \
  --arg commitSha "${expected_commit_sha}" \
  --argjson nodeCount "${expected_node_count}" \
  --argjson edgeCount "${expected_edge_count}" '
    .status == "success" and
    .projectionId == $projectionId and
    .commitSha == $commitSha and
    .nodeCount == $nodeCount and
    .edgeCount == $edgeCount
  ' <<< "${notebook_receipt}" >/dev/null \
  || qam_fail "Fabric projection Notebook receipt does not match the manifest"

qam_info "generating and applying the canonical public Graph Model definition"
if ! definition_receipt="$("${QAM_SCRIPTS_DIR}/generate-fabric-graph-definition.sh" \
  --workspace-id "${workspace_id}" \
  --lakehouse-id "${lakehouse_id}" \
  --output-dir "${definition_dir}")"; then
  qam_fail "Graph Model definition generation failed"
fi
if ! "${QAM_SCRIPTS_DIR}/update-fabric-graph-definition.sh" \
  --workspace-id "${workspace_id}" \
  --graph-model-id "${graph_model_id}" \
  --definition-dir "${definition_dir}"; then
  qam_fail "Graph Model definition update failed"
fi

qam_info "refreshing the queryable Fabric Graph from the updated model"
if ! graph_refresh_receipt="$("${QAM_SCRIPTS_DIR}/refresh-fabric-graph.sh" \
  --workspace-id "${workspace_id}" \
  --graph-model-id "${graph_model_id}")"; then
  qam_fail "Fabric Graph refresh failed"
fi
jq -e \
  --arg workspaceId "${workspace_id}" \
  --arg graphModelId "${graph_model_id}" '
    .schemaVersion == "qam-fabric-graph-refresh/1.0" and
    ((.workspaceId | ascii_downcase) == ($workspaceId | ascii_downcase)) and
    ((.graphModelId | ascii_downcase) == ($graphModelId | ascii_downcase)) and
    ((.startHttpStatus == 200 and .jobInstanceId == "" and .pollAttempts == 0) or
      (.startHttpStatus == 202 and
       (.jobInstanceId | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) and
       (.pollAttempts | type == "number" and . >= 1))) and
    (.status == "Completed" or .status == "Succeeded") and
    .verified == true
  ' <<< "${graph_refresh_receipt}" >/dev/null \
  || qam_fail "Fabric Graph refresh returned an unexpected receipt"

graph_verified='false'
for attempt in $(seq 1 "${graph_query_attempt_limit}"); do
  if "${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
    --workspace-id "${workspace_id}" \
    --graph-model-id "${graph_model_id}" \
    --expected-commit-sha "${expected_commit_sha}" \
    --expected-projection-id "${expected_projection_id}" \
    --expected-repository "${expected_repository}" \
    --expected-node-count "${expected_node_count}" \
    --expected-edge-count "${expected_edge_count}"; then
    graph_verified='true'
    break
  fi
  qam_info "Graph index is not queryable at the selected commit yet (${attempt}/${graph_query_attempt_limit})"
  if [ "${attempt}" -lt "${graph_query_attempt_limit}" ]; then
    sleep "${graph_query_retry_seconds}"
  fi
done
[ "${graph_verified}" = 'true' ] || qam_fail "Fabric Graph did not expose the selected commit"

acceptance_cleanup_receipt='{"requested":false,"completed":false}'
if [ "${acceptance_cleanup}" = 'true' ]; then
  qam_info "final live GQL passed; running the explicit definition-updater acceptance cleanup"
  if ! raw_cleanup_receipt="$("${QAM_SCRIPTS_DIR}/finalize-fabric-definition-updater.sh" \
    --workspace-id "${workspace_id}" \
    --definition-updater-principal-id "${definition_updater_principal_id}")"; then
    qam_fail "Fabric publication succeeded, but the explicit acceptance cleanup failed; inspect the live role and rerun finalize-fabric-definition-updater.sh"
  fi
  jq -e \
    --arg workspaceId "${workspace_id}" \
    --arg principalId "${definition_updater_principal_id}" '
      .schemaVersion == "qam-fabric-role-cleanup/1.0" and
      ((.workspaceId | ascii_downcase) == ($workspaceId | ascii_downcase)) and
      ((.definitionUpdaterPrincipalId | ascii_downcase) == ($principalId | ascii_downcase)) and
      ((.assignmentId | type) == "string" and
        (.assignmentId | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))) and
      (.initialRole == "Contributor" or .initialRole == "Viewer") and
      .finalRole == "Viewer" and
      (.changed | type) == "boolean" and
      .verified == true and
      .exactAssignmentCount == 1 and
      .principalType == "ServicePrincipal"
    ' <<< "${raw_cleanup_receipt}" >/dev/null \
    || qam_fail "definition-updater cleanup returned an unexpected receipt"
  acceptance_cleanup_receipt="$(jq -cn \
    --argjson cleanup "${raw_cleanup_receipt}" \
    '$cleanup + {requested: true, completed: true}')"
fi

jq -cn \
  --argjson publication "${publish_receipt}" \
  --argjson notebook "${notebook_receipt}" \
  --argjson definition "${definition_receipt}" \
  --argjson graphRefresh "${graph_refresh_receipt}" \
  --arg repository "${expected_repository}" \
  --arg projectionId "${expected_projection_id}" \
  --arg commitSha "${expected_commit_sha}" \
  --argjson nodeCount "${expected_node_count}" \
  --argjson edgeCount "${expected_edge_count}" \
  --argjson acceptanceCleanup "${acceptance_cleanup_receipt}" \
  '{publication: $publication, notebook: $notebook,
    graphDefinition: {parts: $definition.parts},
    graphRefresh: $graphRefresh,
    graphQuery: {
      verified: true,
      repository: $repository,
      projectionId: $projectionId,
      commitSha: $commitSha,
      nodeCount: $nodeCount,
      edgeCount: $edgeCount
    },
    acceptanceCleanup: $acceptanceCleanup}'
