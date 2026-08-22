#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
graph_model_id="${QAM_FABRIC_GRAPH_MODEL_ID:-}"
show_response="false"
node_response_file=""
edge_response_file=""
expected_commit_sha=""

# Backticks are GQL identifier quoting, not shell substitutions.
# shellcheck disable=SC2016
node_query='MATCH (n:`QamNode`) RETURN n.id AS `id`, n.kind AS `kind`, n.title AS `title`, n.type AS `type`, n.path AS `path`, n.repositoryPath AS `repositoryPath`, n.conceptId AS `conceptId`, n.tagsJson AS `tagsJson`, n.aliasesJson AS `aliasesJson`, n.projectionId AS `projectionId`, n.commitSha AS `commitSha`, n.repository AS `repository`, n.projectionGeneratedAt AS `projectionGeneratedAt`, n.okfVersion AS `okfVersion`, n.summary AS `summary`, n.resource AS `resource`, n.status AS `status`, n.contentHash AS `contentHash`, n.sourceUrl AS `sourceUrl`, n.normalizedValue AS `normalizedValue`, n.sourceIdsJson AS `sourceIdsJson`, n.authorsJson AS `authorsJson`, n.usageCountsJson AS `usageCountsJson`, n.lastModified AS `lastModified` LIMIT 1;'
# shellcheck disable=SC2016
edge_query='MATCH (source:`QamNode`)-[e:`QamEdge`]->(target:`QamNode`) RETURN e.id AS `id`, source.id AS `from`, target.id AS `to`, e.type AS `type`, e.projectionId AS `projectionId`, e.commitSha AS `commitSha`, e.label AS `label`, e.sourcePath AS `sourcePath` LIMIT 1;'
node_fields='["id","kind","title","type","path","repositoryPath","conceptId","tagsJson","aliasesJson","projectionId","commitSha","repository","projectionGeneratedAt","okfVersion","summary","resource","status","contentHash","sourceUrl","normalizedValue","sourceIdsJson","authorsJson","usageCountsJson","lastModified"]'
edge_fields='["id","from","to","type","projectionId","commitSha","label","sourcePath"]'

usage() {
  printf '%s\n' \
    'Usage: smoke-test-fabric-graph.sh --workspace-id UUID --graph-model-id UUID [options]' \
    '' \
    'Options:' \
    '  --show-response       May disclose graph data in terminal or CI logs' \
    '  --node-response-file FILE' \
    '  --edge-response-file FILE' \
    '                        Offline contract validation; both files are required' \
    '  --expected-commit-sha FULL_SHA' \
    '                        Require QamNode to expose this lowercase 40/64-char Git SHA' \
    '' \
    'The public Fabric endpoint and scope are intentionally fixed. The command runs' \
    'bounded QamNode and QamEdge queries and verifies GQL status, TABLE shape, and' \
    'the complete projection field contract. The endpoint and Graph Model are Preview.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-id) graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --show-response) show_response="true"; shift ;;
    --node-response-file) node_response_file="${2:?missing value for $1}"; shift 2 ;;
    --edge-response-file) edge_response_file="${2:?missing value for $1}"; shift 2 ;;
    --expected-commit-sha) expected_commit_sha="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

qam_require_command jq
if [ -n "${expected_commit_sha}" ]; then
  printf '%s' "${expected_commit_sha}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' \
    || qam_fail "expected commit SHA must be a lowercase full Git object ID"
fi

validate_response() {
  local label="$1"
  local response_file="$2"
  local expected_fields="$3"
  local require_row="$4"

  jq empty "${response_file}" || qam_fail "Fabric ${label} response was not JSON"
  if ! jq -e --argjson expected "${expected_fields}" --argjson requireRow "${require_row}" '
    (.status.code | type == "string" and test("^(00|01|02|03)")) and
    (.result.kind == "TABLE") and
    (.result.columns | type == "array") and
    ((.result.columns | map(.name)) as $columns | ($expected - $columns | length) == 0) and
    (.result.data | type == "array") and
    (if $requireRow then
      (.result.data | length > 0) and
      ((.result.data[0] | keys) as $keys | ($expected - $keys | length) == 0)
    else
      (.result.data | length == 0) or
      ((.result.data[0] | keys) as $keys | ($expected - $keys | length) == 0)
    end)
  ' "${response_file}" >/dev/null; then
    jq '{status: .status.code, resultKind: .result.kind, columns: [.result.columns[]?.name], rowCount: (.result.data | length?)}' \
      "${response_file}" >&2 || true
    qam_fail "Fabric ${label} response failed the QAM TABLE contract"
  fi
}

report_edge_semantics() {
  local response_file="$1"

  if [ "$(jq -r '.result.data | length' "${response_file}")" = "0" ]; then
    qam_info "Fabric QamEdge returned zero rows; the zero-edge snapshot is valid, so edge-row semantics were skipped"
  fi
}

validate_expected_commit() {
  local response_file="$1"

  [ -n "${expected_commit_sha}" ] || return 0
  jq -e --arg commitSha "${expected_commit_sha}" '
    def unwrap: if type == "object" and has("gqlType") and has("value") then .value else . end;
    (.result.data | length > 0) and all(.result.data[]; (.commitSha | unwrap) == $commitSha)
  ' "${response_file}" >/dev/null \
    || qam_fail "Fabric QamNode result does not match the expected commit SHA"
}

if [ -n "${node_response_file}${edge_response_file}" ]; then
  [ -n "${node_response_file}" ] && [ -n "${edge_response_file}" ] \
    || qam_fail "offline validation requires both response files"
  [ -f "${node_response_file}" ] || qam_fail "node response file not found: ${node_response_file}"
  [ -f "${edge_response_file}" ] || qam_fail "edge response file not found: ${edge_response_file}"
  validate_response "QamNode" "${node_response_file}" "${node_fields}" true
  validate_response "QamEdge" "${edge_response_file}" "${edge_fields}" false
  validate_expected_commit "${node_response_file}"
  report_edge_semantics "${edge_response_file}"
  qam_info "offline Fabric GQL response contract passed"
  exit 0
fi

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${graph_model_id}" ] || qam_fail "--graph-model-id is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${graph_model_id}" "Fabric Graph Model ID"
qam_require_azure_login
qam_require_command curl

access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

node_request_file="$(mktemp)"
edge_request_file="$(mktemp)"
node_response_file="$(mktemp)"
edge_response_file="$(mktemp)"
trap 'rm -f "${node_request_file}" "${edge_request_file}" "${node_response_file}" "${edge_response_file}"' EXIT
jq -n --arg query "${node_query}" '{query: $query}' > "${node_request_file}"
jq -n --arg query "${edge_query}" '{query: $query}' > "${edge_request_file}"
query_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/GraphModels/${graph_model_id}/executeQuery?preview=true"

run_query() {
  local label="$1"
  local request_file="$2"
  local response_file="$3"
  local expected_fields="$4"
  local status

  status="$(curl \
    --silent \
    --show-error \
    --request POST \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@${request_file}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${query_url}")"
  if [ "${status}" != "200" ]; then
    sed -n '1,40p' "${response_file}" >&2
    qam_fail "Fabric ${label} smoke query returned HTTP ${status}"
  fi
  if [ "${label}" = "QamNode" ]; then
    validate_response "${label}" "${response_file}" "${expected_fields}" true
  else
    validate_response "${label}" "${response_file}" "${expected_fields}" false
  fi
  if [ "${show_response}" = "true" ]; then
    jq . "${response_file}"
  fi
}

run_query "QamNode" "${node_request_file}" "${node_response_file}" "${node_fields}"
validate_expected_commit "${node_response_file}"
run_query "QamEdge" "${edge_request_file}" "${edge_response_file}" "${edge_fields}"
report_edge_semantics "${edge_response_file}"
qam_info "Fabric GQL QamNode/QamEdge smoke queries passed"
