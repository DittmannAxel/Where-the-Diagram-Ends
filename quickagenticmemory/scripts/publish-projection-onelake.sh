#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
lakehouse_id="${QAM_FABRIC_LAKEHOUSE_ID:-}"
projection_dir=""
nodes_file=""
edges_file=""
dry_run="false"

node_fields='["id","kind","title","type","path","repositoryPath","conceptId","tagsJson","aliasesJson","projectionId","commitSha","repository","projectionGeneratedAt","okfVersion","summary","resource","status","contentHash","sourceUrl","normalizedValue","sourceIdsJson","authorsJson","usageCountsJson","lastModified"]'
edge_fields='["id","from","to","type","projectionId","commitSha","label","sourcePath"]'

usage() {
  printf '%s\n' \
    'Usage: publish-projection-onelake.sh --workspace-id UUID --lakehouse-id UUID (--projection-dir DIR | --nodes-file FILE --edges-file FILE) [options]' \
    '' \
    'Options:' \
    '  --nodes-file FILE       Explicit nodes.ndjson path (requires --edges-file)' \
    '  --edges-file FILE       Explicit edges.ndjson path (requires --nodes-file)' \
    '  --dry-run               Validate and print the immutable staging contract only' \
    '' \
    'Validates the exact flat NDJSON schemas and one immutable projection/commit pair,' \
    'then uploads nodes.ndjson and edges.ndjson through documented OneLake ADLS DFS' \
    'create/append/flush operations. It does not modify Delta tables or a Graph Model.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-id) lakehouse_id="${2:?missing value for $1}"; shift 2 ;;
    --projection-dir) projection_dir="${2:?missing value for $1}"; shift 2 ;;
    --nodes-file) nodes_file="${2:?missing value for $1}"; shift 2 ;;
    --edges-file) edges_file="${2:?missing value for $1}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${lakehouse_id}" ] || qam_fail "--lakehouse-id is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${lakehouse_id}" "Fabric Lakehouse ID"
if [ -n "${nodes_file}${edges_file}" ]; then
  [ -n "${nodes_file}" ] && [ -n "${edges_file}" ] \
    || qam_fail "--nodes-file and --edges-file must be supplied together"
  [ -z "${projection_dir}" ] || qam_fail "use either --projection-dir or explicit files"
else
  [ -n "${projection_dir}" ] || qam_fail "--projection-dir is required"
  [ -d "${projection_dir}" ] || qam_fail "projection directory not found: ${projection_dir}"
  nodes_file="${projection_dir}/nodes.ndjson"
  edges_file="${projection_dir}/edges.ndjson"
fi
[ -s "${nodes_file}" ] || qam_fail "nodes.ndjson is missing or empty"
[ -f "${edges_file}" ] || qam_fail "edges.ndjson is missing"
qam_require_command jq

validate_ndjson() {
  local label="$1"
  local file="$2"
  local expected_fields="$3"
  local allow_empty="$4"
  local physical_empty=false

  if [ ! -s "${file}" ]; then physical_empty=true; fi

  jq -s -e \
    --argjson expected "${expected_fields}" \
    --argjson allowEmpty "${allow_empty}" \
    --argjson physicalEmpty "${physical_empty}" '
    (($allowEmpty and $physicalEmpty and length == 0) or length > 0) and
    all(.[]; type == "object" and ((keys | sort) == ($expected | sort)))
  ' "${file}" >/dev/null || qam_fail "${label} does not match the exact flat ingestion schema"
}

validate_ndjson QamNode "${nodes_file}" "${node_fields}" false
validate_ndjson QamEdge "${edges_file}" "${edge_fields}" true
projection_id="$(jq -rs '[.[].projectionId] | unique | if length == 1 then .[0] else error("mixed projectionId") end' "${nodes_file}")"
commit_sha="$(jq -rs '[.[].commitSha] | unique | if length == 1 then .[0] else error("mixed commitSha") end' "${nodes_file}")"
printf '%s' "${projection_id}" | grep -Eq '^urn:qam:projection:[0-9a-f]{64}$' \
  || qam_fail "projectionId must be an immutable QAM SHA-256 URN"
printf '%s' "${commit_sha}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' \
  || qam_fail "commitSha must be a lowercase full Git object ID"
jq -s -e --arg projectionId "${projection_id}" --arg commitSha "${commit_sha}" '
  all(.[]; .projectionId == $projectionId and .commitSha == $commitSha)
' "${edges_file}" >/dev/null \
  || qam_fail "QamEdge projectionId/commitSha must match the QamNode projection"
jq -n -e --slurpfile nodes "${nodes_file}" --slurpfile edges "${edges_file}" '
  ($nodes | map(.id) | length == (unique | length)) and
  ($edges | map(.id) | length == (unique | length)) and
  ($nodes | map({key: .id, value: .kind}) | from_entries) as $kinds |
  all($edges[];
    $kinds[.from] == "Concept" and
    (if .type == "LINKS_TO" then $kinds[.to] == "Concept"
     elif .type == "HAS_TAG" then $kinds[.to] == "Tag"
     elif .type == "DERIVED_FROM" then $kinds[.to] == "Source"
     elif .type == "ALIASED_AS" then $kinds[.to] == "Term"
     else false
     end)
  )
' >/dev/null \
  || qam_fail "QamNode/QamEdge IDs, endpoints, or canonical edge type/kind matrix are invalid"
projection_hash="${projection_id##*:}"
staging_path="Files/qam-staging/${projection_hash}/${commit_sha}"

if [ "${dry_run}" = "true" ]; then
  jq -cn \
    --arg workspaceId "${workspace_id}" \
    --arg lakehouseId "${lakehouse_id}" \
    --arg stagingPath "${staging_path}" \
    --arg projectionId "${projection_id}" \
    --arg commitSha "${commit_sha}" \
    '{workspaceId: $workspaceId, lakehouseId: $lakehouseId, stagingPath: $stagingPath, projectionId: $projectionId, commitSha: $commitSha}'
  exit 0
fi

qam_require_azure_login
qam_require_command curl
qam_require_command openssl
access_token="$(az account get-access-token \
  --resource 'https://storage.azure.com/' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a OneLake/Azure Storage access token"
base_url="https://onelake.dfs.fabric.microsoft.com/${workspace_id}/${lakehouse_id}"
nodes_sha256="$(openssl dgst -sha256 -r "${nodes_file}" | awk '{print $1}')"
edges_sha256="$(openssl dgst -sha256 -r "${edges_file}" | awk '{print $1}')"
temporary_id="$(openssl rand -hex 16)"
temporary_path="Files/qam-staging/_temporary/${temporary_id}"
remote_temporary_pending='false'
verification_dir="$(mktemp -d)"

cleanup() {
  local result=$?

  trap - EXIT
  if [ "${remote_temporary_pending}" = 'true' ]; then
    curl --silent --show-error \
      --request DELETE \
      --header "Authorization: Bearer ${access_token}" \
      --header 'x-ms-version: 2021-06-08' \
      --output /dev/null \
      "${base_url}/${temporary_path}?recursive=true" >/dev/null 2>&1 || true
  fi
  rm -rf "${verification_dir}"
  unset access_token
  exit "${result}"
}
trap cleanup EXIT

request_status() {
  curl --silent --show-error \
    --header "Authorization: Bearer ${access_token}" \
    --header 'x-ms-version: 2021-06-08' \
    --output /dev/null \
    --write-out '%{http_code}' \
    "$@"
}

ensure_directory() {
  local path="$1"
  local status

  status="$(request_status --request PUT "${base_url}/${path}?resource=directory")"
  case "${status}" in
    201) ;;
    409)
      status="$(request_status --request HEAD "${base_url}/${path}")"
      [ "${status}" = "200" ] || qam_fail "OneLake path exists but is not an accessible directory: ${path}"
      ;;
    *) qam_fail "creating OneLake directory ${path} returned HTTP ${status}" ;;
  esac
}

ensure_directory 'Files/qam-staging'
ensure_directory 'Files/qam-staging/_temporary'
status="$(request_status \
  --request PUT \
  --header 'If-None-Match: *' \
  "${base_url}/${temporary_path}?resource=directory")"
[ "${status}" = '201' ] \
  || qam_fail "creating unique OneLake temporary directory returned HTTP ${status}"
remote_temporary_pending='true'

upload_file() {
  local source_file="$1"
  local target_name="$2"
  local target_url="${base_url}/${temporary_path}/${target_name}"
  local byte_count
  local status

  byte_count="$(wc -c < "${source_file}" | tr -d '[:space:]')"
  status="$(request_status \
    --request PUT \
    --header 'If-None-Match: *' \
    "${target_url}?resource=file")"
  [ "${status}" = "201" ] \
    || qam_fail "creating immutable OneLake file ${target_name} returned HTTP ${status}"
  if [ "${byte_count}" -gt 0 ]; then
    status="$(request_status \
      --request PATCH \
      --header 'Content-Type: application/octet-stream' \
      --data-binary "@${source_file}" \
      "${target_url}?action=append&position=0")"
    [ "${status}" = "202" ] || qam_fail "appending OneLake file ${target_name} returned HTTP ${status}"
  fi
  status="$(request_status --request PATCH "${target_url}?action=flush&position=${byte_count}&close=true")"
  [ "${status}" = "200" ] || qam_fail "flushing OneLake file ${target_name} returned HTTP ${status}"
}

upload_file "${nodes_file}" nodes.ndjson
upload_file "${edges_file}" edges.ndjson

verify_remote_file() {
  local remote_path="$1"
  local source_file="$2"
  local expected_sha256="$3"
  local label="$4"
  local output_file="${verification_dir}/${label}.ndjson"
  local expected_bytes
  local actual_bytes
  local actual_sha256
  local status

  expected_bytes="$(wc -c < "${source_file}" | tr -d '[:space:]')"
  if ! status="$(curl --silent --show-error \
    --header "Authorization: Bearer ${access_token}" \
    --header 'x-ms-version: 2021-06-08' \
    --max-filesize "${expected_bytes}" \
    --output "${output_file}" \
    --write-out '%{http_code}' \
    "${base_url}/${remote_path}")"; then
    qam_fail "reading ${label} back from OneLake failed or exceeded the expected byte length"
  fi
  [ "${status}" = '200' ] || qam_fail "reading ${label} back from OneLake returned HTTP ${status}"
  actual_bytes="$(wc -c < "${output_file}" | tr -d '[:space:]')"
  [ "${actual_bytes}" = "${expected_bytes}" ] \
    || qam_fail "OneLake ${label} byte length differs from the local immutable artifact"
  actual_sha256="$(openssl dgst -sha256 -r "${output_file}" | awk '{print $1}')"
  [ "${actual_sha256}" = "${expected_sha256}" ] \
    || qam_fail "OneLake ${label} SHA-256 differs from the local immutable artifact"
}

verify_remote_file "${temporary_path}/nodes.ndjson" "${nodes_file}" "${nodes_sha256}" nodes
verify_remote_file "${temporary_path}/edges.ndjson" "${edges_file}" "${edges_sha256}" edges

ensure_directory "Files/qam-staging/${projection_hash}"
rename_source="/${workspace_id}/${lakehouse_id}/${temporary_path}"
status="$(request_status \
  --request PUT \
  --header "x-ms-rename-source: ${rename_source}" \
  --header 'If-None-Match: *' \
  "${base_url}/${staging_path}")"
publish_result='created'
case "${status}" in
  201)
    remote_temporary_pending='false'
    ;;
  409 | 412)
    # A concurrent or previous publisher won. Accept only byte-identical final files.
    verify_remote_file "${staging_path}/nodes.ndjson" "${nodes_file}" "${nodes_sha256}" final-nodes
    verify_remote_file "${staging_path}/edges.ndjson" "${edges_file}" "${edges_sha256}" final-edges
    delete_status="$(request_status \
      --request DELETE \
      "${base_url}/${temporary_path}?recursive=true")"
    [ "${delete_status}" = '200' ] \
      || qam_fail "cleaning the redundant OneLake temporary directory returned HTTP ${delete_status}"
    remote_temporary_pending='false'
    publish_result='existing-identical'
    ;;
  *) qam_fail "atomically publishing the OneLake staging directory returned HTTP ${status}" ;;
esac

jq -cn \
  --arg workspaceId "${workspace_id}" \
  --arg lakehouseId "${lakehouse_id}" \
  --arg stagingPath "${staging_path}" \
  --arg projectionId "${projection_id}" \
  --arg commitSha "${commit_sha}" \
  --arg nodesSha256 "${nodes_sha256}" \
  --arg edgesSha256 "${edges_sha256}" \
  --arg publishResult "${publish_result}" \
  '{workspaceId: $workspaceId, lakehouseId: $lakehouseId, stagingPath: $stagingPath, projectionId: $projectionId, commitSha: $commitSha, nodesSha256: $nodesSha256, edgesSha256: $edgesSha256, publishResult: $publishResult}'
