#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
lakehouse_id="${QAM_FABRIC_LAKEHOUSE_ID:-}"
output_dir=""

node_fields='["id","kind","title","type","path","repositoryPath","conceptId","tagsJson","aliasesJson","projectionId","commitSha","repository","projectionGeneratedAt","okfVersion","summary","resource","status","contentHash","sourceUrl","normalizedValue","sourceIdsJson","authorsJson","usageCountsJson","lastModified"]'
edge_fields='["id","from","to","type","projectionId","commitSha","label","sourcePath"]'

usage() {
  printf '%s\n' \
    'Usage: generate-fabric-graph-definition.sh --workspace-id UUID --lakehouse-id UUID --output-dir DIRECTORY' \
    '' \
    'Generates the complete public Graph Model definition for the canonical QamNode' \
    'and QamEdge Delta tables. Existing definition files are not overwritten.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-id) lakehouse_id="${2:?missing value for $1}"; shift 2 ;;
    --output-dir) output_dir="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${lakehouse_id}" ] || qam_fail "--lakehouse-id is required"
[ -n "${output_dir}" ] || qam_fail "--output-dir is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${lakehouse_id}" "Fabric Lakehouse ID"
qam_require_command jq

if [ -e "${output_dir}" ]; then
  [ -d "${output_dir}" ] || qam_fail "output path exists and is not a directory"
  for part in dataSources.json graphDefinition.json graphType.json stylingConfiguration.json; do
    [ ! -e "${output_dir}/${part}" ] || qam_fail "refusing to overwrite existing definition part: ${output_dir}/${part}"
  done
else
  mkdir -p "${output_dir}"
fi

lakehouse_reference='QamLakehouse'
node_path='Tables/qamnode'
edge_path='Tables/qamedge'

jq -n \
  --arg workspaceId "${workspace_id}" \
  --arg lakehouseId "${lakehouse_id}" \
  --arg referenceName "${lakehouse_reference}" \
  --arg nodePath "${node_path}" \
  --arg edgePath "${edge_path}" \
  '{
    "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/dataSources/1.1.0/schema.json",
    itemReferences: [{
      name: $referenceName,
      item: {workspaceId: $workspaceId, itemId: $lakehouseId}
    }],
    dataSources: [
      {name: "QamNode_Table", type: "DeltaTable",
        properties: {referenceName: $referenceName, path: $nodePath}},
      {name: "QamEdge_Table", type: "DeltaTable",
        properties: {referenceName: $referenceName, path: $edgePath}}
    ]
  }' > "${output_dir}/dataSources.json"

jq -n \
  --argjson nodeFields "${node_fields}" \
  --argjson edgeFields "${edge_fields}" \
  '{
    "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/graphDefinition/1.0.0/schema.json",
    nodeTables: [{
      id: "QamNode_mapping",
      nodeTypeAlias: "QamNode",
      dataSourceName: "QamNode_Table",
      propertyMappings: ($nodeFields | map({propertyName: ., sourceColumn: .}))
    }],
    edgeTables: [{
      id: "QamEdge_mapping",
      edgeTypeAlias: "QamEdge",
      dataSourceName: "QamEdge_Table",
      sourceNodeKeyColumns: ["from"],
      destinationNodeKeyColumns: ["to"],
      propertyMappings: ($edgeFields | map({propertyName: ., sourceColumn: .}))
    }]
  }' > "${output_dir}/graphDefinition.json"

jq -n \
  --argjson nodeFields "${node_fields}" \
  --argjson edgeFields "${edge_fields}" \
  '{
    "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/graphType/1.0.0/schema.json",
    nodeTypes: [{
      alias: "QamNode",
      labels: ["QamNode"],
      primaryKeyProperties: ["id"],
      properties: ($nodeFields | map({name: ., type: "STRING"}))
    }],
    edgeTypes: [{
      alias: "QamEdge",
      labels: ["QamEdge"],
      sourceNodeType: {alias: "QamNode"},
      destinationNodeType: {alias: "QamNode"},
      properties: ($edgeFields | map({name: ., type: "STRING"}))
    }]
  }' > "${output_dir}/graphType.json"

jq -n '{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/graphIndex/definition/stylingConfiguration/1.0.0/schema.json",
  modelLayout: {
    positions: {QamNode: {x: 120, y: 120}},
    styles: {QamNode: {size: 30}, QamEdge: {size: 20}},
    pan: {x: 0, y: 0},
    zoomLevel: 1
  },
  visualFormat: {}
}' > "${output_dir}/stylingConfiguration.json"

jq -cn \
  --arg definitionDirectory "${output_dir}" \
  --arg lakehouseReference "${lakehouse_reference}" \
  --arg nodeTablePath "${node_path}" \
  --arg edgeTablePath "${edge_path}" \
  '{definitionDirectory: $definitionDirectory,
    parts: ["dataSources.json", "graphDefinition.json", "graphType.json", "stylingConfiguration.json"],
    lakehouseReference: $lakehouseReference,
    nodeTablePath: $nodeTablePath, edgeTablePath: $edgeTablePath}'
