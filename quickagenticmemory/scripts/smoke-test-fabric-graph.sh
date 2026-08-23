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
expected_projection_id=""
expected_repository=""
expected_node_count=""
expected_edge_count=""
node_limit=10000
edge_limit=50000

# Backticks are GQL identifier quoting, not shell substitutions.
# shellcheck disable=SC2016
node_query='MATCH (n:`QamNode`) RETURN n.`id` AS `id`, n.`kind` AS `kind`, n.`title` AS `title`, n.`type` AS `type`, n.`path` AS `path`, n.`repositoryPath` AS `repositoryPath`, n.`conceptId` AS `conceptId`, n.`tagsJson` AS `tagsJson`, n.`aliasesJson` AS `aliasesJson`, n.`projectionId` AS `projectionId`, n.`commitSha` AS `commitSha`, n.`repository` AS `repository`, n.`projectionGeneratedAt` AS `projectionGeneratedAt`, n.`okfVersion` AS `okfVersion`, n.`summary` AS `summary`, n.`resource` AS `resource`, n.`status` AS `status`, n.`contentHash` AS `contentHash`, n.`sourceUrl` AS `sourceUrl`, n.`normalizedValue` AS `normalizedValue`, n.`sourceIdsJson` AS `sourceIdsJson`, n.`authorsJson` AS `authorsJson`, n.`usageCountsJson` AS `usageCountsJson`, n.`lastModified` AS `lastModified` LIMIT 10000;'
# shellcheck disable=SC2016
edge_query='MATCH (source:`QamNode`)-[e:`QamEdge`]->(target:`QamNode`) RETURN e.`id` AS `id`, source.`id` AS `from`, target.`id` AS `to`, e.`type` AS `type`, e.`projectionId` AS `projectionId`, e.`commitSha` AS `commitSha`, e.`label` AS `label`, e.`sourcePath` AS `sourcePath` LIMIT 50000;'
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
    '                        Require every row to expose this lowercase 40/64-char Git SHA' \
    '  --expected-projection-id URN' \
    '                        Require every row to expose this deterministic projection ID' \
    '  --expected-repository REPOSITORY' \
    '                        Require every QamNode row to expose this repository' \
    '  --expected-node-count COUNT' \
    '  --expected-edge-count COUNT' \
    '                        Require the exact complete projection counts' \
    '' \
    'The public Fabric endpoint and scope are intentionally fixed. The command runs' \
    'bounded QamNode and QamEdge queries and verifies GQL status, TABLE shape,' \
    'provenance, row bounds, and graph endpoint semantics. The endpoint and Graph' \
    'Model are Preview.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-id) graph_model_id="${2:?missing value for $1}"; shift 2 ;;
    --show-response) show_response="true"; shift ;;
    --node-response-file) node_response_file="${2:?missing value for $1}"; shift 2 ;;
    --edge-response-file) edge_response_file="${2:?missing value for $1}"; shift 2 ;;
    --expected-commit-sha) expected_commit_sha="${2:?missing value for $1}"; shift 2 ;;
    --expected-projection-id) expected_projection_id="${2:?missing value for $1}"; shift 2 ;;
    --expected-repository) expected_repository="${2:?missing value for $1}"; shift 2 ;;
    --expected-node-count) expected_node_count="${2:?missing value for $1}"; shift 2 ;;
    --expected-edge-count) expected_edge_count="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

qam_require_command jq
if [ -n "${expected_commit_sha}" ]; then
  printf '%s' "${expected_commit_sha}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' \
    || qam_fail "expected commit SHA must be a lowercase full Git object ID"
fi
if [ -n "${expected_projection_id}" ]; then
  printf '%s' "${expected_projection_id}" | grep -Eq '^urn:qam:projection:[0-9a-f]{64}$' \
    || qam_fail "expected projection ID must be a deterministic urn:qam:projection SHA-256 identifier"
fi
[ -z "${expected_repository}" ] || [ "${#expected_repository}" -le 500 ] \
  || qam_fail "expected repository exceeds the QAM contract limit"
for count_spec in \
  "${expected_node_count}:expected node count" \
  "${expected_edge_count}:expected edge count"; do
  count_value="${count_spec%%:*}"
  [ -z "${count_value}" ] || printf '%s' "${count_value}" | grep -Eq '^(0|[1-9][0-9]*)$' \
    || qam_fail "${count_spec#*:} must be a non-negative integer"
done
[ -z "${expected_node_count}" ] || [ "${expected_node_count}" -gt 0 ] \
  || qam_fail "expected node count must be greater than zero"
[ -z "${expected_node_count}" ] || [ "${expected_node_count}" -lt "${node_limit}" ] \
  || qam_fail "expected node count must stay below the bounded GQL limit"
[ -z "${expected_edge_count}" ] || [ "${expected_edge_count}" -lt "${edge_limit}" ] \
  || qam_fail "expected edge count must stay below the bounded GQL limit"

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

validate_expected_provenance() {
  local response_file="$1"
  local require_row="$2"
  local include_repository="$3"

  jq -e \
    --arg commitSha "${expected_commit_sha}" \
    --arg projectionId "${expected_projection_id}" \
    --arg repository "${expected_repository}" \
    --argjson requireRow "${require_row}" \
    --argjson includeRepository "${include_repository}" '
    def unwrap: if type == "object" and has("gqlType") and has("value") then .value else . end;
    (.result.data | type == "array") and
    (if $requireRow then (.result.data | length > 0) else true end) and
    all(.result.data[];
      ($commitSha == "" or (.commitSha | unwrap) == $commitSha) and
      ($projectionId == "" or (.projectionId | unwrap) == $projectionId) and
      (($repository == "" or ($includeRepository | not)) or (.repository | unwrap) == $repository)
    )
  ' "${response_file}" >/dev/null \
    || qam_fail "Fabric result does not match the expected immutable provenance"
}

validate_projection_consistency() {
  local node_file="$1"
  local edge_file="$2"

  jq -en --slurpfile nodes "${node_file}" --slurpfile edges "${edge_file}" '
    def unwrap: if type == "object" and has("gqlType") and has("value") then .value else . end;
    ([$nodes[0].result.data[].projectionId | unwrap] | unique) as $nodeProjectionIds |
    ([$edges[0].result.data[].projectionId | unwrap] | unique) as $edgeProjectionIds |
    ([$nodes[0].result.data[].commitSha | unwrap] | unique) as $nodeCommitShas |
    ([$edges[0].result.data[].commitSha | unwrap] | unique) as $edgeCommitShas |
    ([$nodes[0].result.data[].repository | unwrap] | unique) as $repositories |
    ($nodeProjectionIds | length == 1) and
    ($nodeCommitShas | length == 1) and
    ($repositories | length == 1) and
    (($edgeProjectionIds | length == 0) or ($edgeProjectionIds == $nodeProjectionIds)) and
    (($edgeCommitShas | length == 0) or ($edgeCommitShas == $nodeCommitShas))
  ' >/dev/null \
    || qam_fail "Fabric QamNode/QamEdge results do not expose one consistent immutable projection"
}

validate_complete_counts() {
  local node_file="$1"
  local edge_file="$2"
  local node_count
  local edge_count

  node_count="$(jq -r '.result.data | length' "${node_file}")"
  edge_count="$(jq -r '.result.data | length' "${edge_file}")"
  [ "${node_count}" -lt "${node_limit}" ] \
    || qam_fail "Fabric QamNode reached the GQL LIMIT; the graph may be truncated"
  [ "${edge_count}" -lt "${edge_limit}" ] \
    || qam_fail "Fabric QamEdge reached the GQL LIMIT; the graph may be truncated"
  [ -z "${expected_node_count}" ] || [ "${node_count}" -eq "${expected_node_count}" ] \
    || qam_fail "Fabric QamNode count ${node_count} does not match expected ${expected_node_count}"
  [ -z "${expected_edge_count}" ] || [ "${edge_count}" -eq "${expected_edge_count}" ] \
    || qam_fail "Fabric QamEdge count ${edge_count} does not match expected ${expected_edge_count}"
}

validate_graph_semantics() {
  local node_file="$1"
  local edge_file="$2"

  jq -en --slurpfile nodes "${node_file}" --slurpfile edges "${edge_file}" '
    def unwrap: if type == "object" and has("gqlType") and has("value") then .value else . end;
    def nonempty_string: unwrap | type == "string" and length > 0;
    def optional_string: unwrap | . == null or type == "string";
    def git_sha: unwrap | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
    def projection_id: unwrap | type == "string" and test("^urn:qam:projection:[0-9a-f]{64}$");
    def sha256: unwrap | type == "string" and test("^[0-9a-f]{64}$");
    def string_array_json:
      unwrap as $encoded |
      ($encoded | type == "string") and
      ((try ($encoded | fromjson) catch null) as $decoded |
        ($decoded | type == "array") and all($decoded[]; type == "string" and length > 0));
    def integer_array_json:
      unwrap as $encoded |
      ($encoded | type == "string") and
      ((try ($encoded | fromjson) catch null) as $decoded |
        ($decoded | type == "array") and all($decoded[]; type == "number" and floor == . and . >= 0));

    $nodes[0].result.data as $nodeRows |
    $edges[0].result.data as $edgeRows |
    ([$nodeRows[] | {key: (.id | unwrap), value: (.kind | unwrap)}] | from_entries) as $nodeKinds |
    ($nodeRows | length > 0) and
    (([$nodeRows[].id | unwrap] | unique | length) == ($nodeRows | length)) and
    (([$edgeRows[].id | unwrap] | unique | length) == ($edgeRows | length)) and
    all($nodeRows[];
      (.id | nonempty_string) and
      (.kind | unwrap | . == "Concept" or . == "Tag" or . == "Source" or . == "Term") and
      (.title | nonempty_string) and
      (.type | nonempty_string) and
      (.tagsJson | string_array_json) and
      (.aliasesJson | string_array_json) and
      (.commitSha | git_sha) and
      (.projectionId | projection_id) and
      ((.kind | unwrap) as $kind |
        if $kind == "Concept" then
          (.path | nonempty_string) and
          (.repositoryPath | nonempty_string) and
          (.conceptId | nonempty_string) and
          (.status | unwrap | . == "draft" or . == "stable" or . == "deprecated") and
          (.contentHash | sha256) and
          (.summary | optional_string) and
          (.resource | optional_string) and
          (.sourceUrl | optional_string)
        elif $kind == "Source" then
          (.type | unwrap) == "Source" and
          (.resource | nonempty_string) and
          (.sourceIdsJson | string_array_json) and
          (.authorsJson | string_array_json) and
          (.usageCountsJson | integer_array_json) and
          (.lastModified | optional_string)
        else
          (.type | unwrap) == $kind and (.normalizedValue | nonempty_string)
        end)
    ) and
    all($edgeRows[];
      (.id | nonempty_string) and
      (.from | nonempty_string) and
      (.to | nonempty_string) and
      (.type | unwrap | . == "LINKS_TO" or . == "HAS_TAG" or . == "DERIVED_FROM" or . == "ALIASED_AS") and
      (.projectionId | projection_id) and
      (.commitSha | git_sha) and
      (.label | optional_string) and
      (.sourcePath | optional_string) and
      ((.from | unwrap) as $from | (.to | unwrap) as $to | (.type | unwrap) as $type |
        ($nodeKinds | has($from)) and ($nodeKinds | has($to)) and
        if $type == "LINKS_TO" then $nodeKinds[$from] == "Concept" and $nodeKinds[$to] == "Concept"
        elif $type == "HAS_TAG" then $nodeKinds[$from] == "Concept" and $nodeKinds[$to] == "Tag"
        elif $type == "DERIVED_FROM" then $nodeKinds[$from] == "Concept" and $nodeKinds[$to] == "Source"
        else $nodeKinds[$from] == "Concept" and $nodeKinds[$to] == "Term"
        end)
    )
  ' >/dev/null \
    || qam_fail "Fabric QamNode/QamEdge rows failed graph identity, field, or endpoint semantics"
}

if [ -n "${node_response_file}${edge_response_file}" ]; then
  [ -n "${node_response_file}" ] && [ -n "${edge_response_file}" ] \
    || qam_fail "offline validation requires both response files"
  [ -f "${node_response_file}" ] || qam_fail "node response file not found: ${node_response_file}"
  [ -f "${edge_response_file}" ] || qam_fail "edge response file not found: ${edge_response_file}"
  validate_response "QamNode" "${node_response_file}" "${node_fields}" true
  validate_response "QamEdge" "${edge_response_file}" "${edge_fields}" false
  validate_expected_provenance "${node_response_file}" true true
  validate_expected_provenance "${edge_response_file}" false false
  validate_projection_consistency "${node_response_file}" "${edge_response_file}"
  validate_complete_counts "${node_response_file}" "${edge_response_file}"
  validate_graph_semantics "${node_response_file}" "${edge_response_file}"
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
    --connect-timeout 10 \
    --max-time 45 \
    --retry 2 \
    --retry-connrefused \
    --retry-delay 1 \
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
validate_expected_provenance "${node_response_file}" true true
run_query "QamEdge" "${edge_request_file}" "${edge_response_file}" "${edge_fields}"
validate_expected_provenance "${edge_response_file}" false false
validate_projection_consistency "${node_response_file}" "${edge_response_file}"
validate_complete_counts "${node_response_file}" "${edge_response_file}"
validate_graph_semantics "${node_response_file}" "${edge_response_file}"
report_edge_semantics "${edge_response_file}"
qam_info "Fabric GQL QamNode/QamEdge smoke queries passed"
