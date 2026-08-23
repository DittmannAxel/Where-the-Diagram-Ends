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
    '' \
    'Publishes one clean, commit-pinned projection to immutable OneLake staging,' \
    'loads its Delta tables, applies the canonical Graph definition, and requires' \
    'bounded live GQL to return the same Git commit.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-id) lakehouse_id="${2:?missing value for $1}"; shift 2 ;;
    --notebook-id) notebook_id="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-id) graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --projection-dir) projection_dir="${2:?missing value for $1}"; shift 2 ;;
    --definition-dir) definition_dir="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

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

graph_verified='false'
for attempt in $(seq 1 20); do
  if "${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
    --workspace-id "${workspace_id}" \
    --graph-model-id "${graph_model_id}" \
    --expected-commit-sha "${commit_sha}"; then
    graph_verified='true'
    break
  fi
  qam_info "Graph index is not queryable at the selected commit yet (${attempt}/20)"
  sleep 15
done
[ "${graph_verified}" = 'true' ] || qam_fail "Fabric Graph did not expose the selected commit"

jq -cn \
  --argjson publication "${publish_receipt}" \
  --argjson notebook "${notebook_receipt}" \
  --argjson definition "${definition_receipt}" \
  '{publication: $publication, notebook: $notebook,
    graphDefinition: {parts: $definition.parts}, graphQuery: {verified: true}}'
