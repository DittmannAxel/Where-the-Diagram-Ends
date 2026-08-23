#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

capacity_name="${QAM_FABRIC_CAPACITY_NAME:-}"
workspace_name="${QAM_FABRIC_WORKSPACE_NAME:-QAM Industrial Evidence}"
lakehouse_name="${QAM_FABRIC_LAKEHOUSE_NAME:-qam_industrial_evidence}"
graph_model_name="${QAM_FABRIC_GRAPH_MODEL_NAME:-QAM Industrial Knowledge Graph}"
notebook_name="${QAM_FABRIC_NOTEBOOK_NAME:-qam_load_projection}"
notebook_source="${QAM_INFRA_DIR}/fabric/qam-load-projection.notebook-content.py"
fabric_api='https://api.fabric.microsoft.com/v1'

usage() {
  printf '%s\n' \
    'Usage: bootstrap-fabric-items.sh --capacity-name NAME [options]' \
    '' \
    'Creates or reuses one isolated Fabric workspace and its QAM Lakehouse,' \
    'Graph Model, and checked-in projection Notebook. Exact-name matching makes' \
    'the operation idempotent; duplicates or incompatible reuse fail closed.' \
    '' \
    'Options:' \
    '  --workspace-name NAME       Default: QAM Industrial Evidence' \
    '  --lakehouse-name NAME       Default: qam_industrial_evidence' \
    '  --graph-model-name NAME     Default: QAM Industrial Knowledge Graph' \
    '  --notebook-name NAME        Default: qam_load_projection' \
    '  --notebook-source FILE      Default: checked-in FabricGitSource template'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --capacity-name) capacity_name="${2:?missing value for $1}"; shift 2 ;;
    --workspace-name) workspace_name="${2:?missing value for $1}"; shift 2 ;;
    --lakehouse-name) lakehouse_name="${2:?missing value for $1}"; shift 2 ;;
    --graph-model-name) graph_model_name="${2:?missing value for $1}"; shift 2 ;;
    --notebook-name) notebook_name="${2:?missing value for $1}"; shift 2 ;;
    --notebook-source) notebook_source="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${capacity_name}" ] || qam_fail "--capacity-name is required"
printf '%s' "${capacity_name}" | grep -Eq '^[a-z][a-z0-9]{2,62}$' \
  || qam_fail "capacity name is invalid"
for value in "${workspace_name}" "${lakehouse_name}" "${graph_model_name}" "${notebook_name}"; do
  [ -n "${value}" ] || qam_fail "Fabric item names must not be empty"
  [ "${#value}" -le 256 ] || qam_fail "Fabric item names must not exceed 256 characters"
done
[ -s "${notebook_source}" ] || qam_fail "Notebook source is missing or empty: ${notebook_source}"
grep -Fq '# Fabric notebook source' "${notebook_source}" \
  || qam_fail "Notebook source is not FabricGitSource"

qam_require_azure_login
qam_require_command base64
qam_require_command curl
qam_require_command jq

access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

temp_dir="$(mktemp -d)"
response_file="${temp_dir}/response.json"
headers_file="${temp_dir}/headers.txt"
request_file="${temp_dir}/request.json"
trap 'rm -rf "${temp_dir}"' EXIT
FABRIC_HTTP_STATUS=''
FABRIC_LIST_RESULT='[]'
FABRIC_EXACT_ITEM_ID=''
FABRIC_CREATED_ITEM_ID=''
FABRIC_ITEM_ID=''

fabric_request() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  local -a request_args

  case "${url}" in
    "${fabric_api}"/*) ;;
    *) qam_fail "Fabric request URL left the fixed v1 API origin" ;;
  esac
  request_args=(
    --silent
    --show-error
    --request "${method}"
    --header "Authorization: Bearer ${access_token}"
    --header 'Accept: application/json'
    --dump-header "${headers_file}"
    --output "${response_file}"
    --write-out '%{http_code}'
  )
  if [ -n "${body_file}" ]; then
    request_args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  fi
  : > "${headers_file}"
  : > "${response_file}"
  if ! FABRIC_HTTP_STATUS="$(curl "${request_args[@]}" "${url}")"; then
    qam_fail "Fabric ${method} request failed"
  fi
}

list_all() {
  local base_url="$1"
  local next_url="${base_url}"
  local status
  local page_count=0
  local accumulated='[]'

  while [ -n "${next_url}" ]; do
    case "${next_url}" in
      "${base_url}" | "${base_url}"\?*) ;;
      *) qam_fail "Fabric pagination URL left the expected collection endpoint" ;;
    esac
    page_count=$((page_count + 1))
    [ "${page_count}" -le 100 ] || qam_fail "Fabric pagination exceeded 100 pages"
    fabric_request GET "${next_url}"
    status="${FABRIC_HTTP_STATUS}"
    [ "${status}" = '200' ] || {
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "listing Fabric resources returned HTTP ${status}"
    }
    jq -e '.value | type == "array"' "${response_file}" >/dev/null \
      || qam_fail "Fabric list response has no value array"
    accumulated="$(jq -cn \
      --argjson accumulated "${accumulated}" \
      --slurpfile page "${response_file}" \
      '$accumulated + $page[0].value')"
    next_url="$(jq -r '.continuationUri // ."@odata.nextLink" // empty' "${response_file}")"
  done
  FABRIC_LIST_RESULT="${accumulated}"
}

poll_operation() {
  local operation_url="$1"
  local status
  local operation_status
  local retry_after

  qam_validate_fabric_operation_url "${operation_url}"
  for _ in $(seq 1 60); do
    retry_after="$(awk 'tolower($1) == "retry-after:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
    if ! printf '%s' "${retry_after:-5}" | grep -Eq '^[0-9]+$'; then retry_after=5; fi
    if [ "${retry_after:-5}" -gt 30 ]; then retry_after=30; fi
    sleep "${retry_after:-5}"
    fabric_request GET "${operation_url}"
    status="${FABRIC_HTTP_STATUS}"
    [ "${status}" = '200' ] || {
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "polling Fabric operation returned HTTP ${status}"
    }
    operation_status="$(jq -r '.status // empty' "${response_file}")"
    case "${operation_status}" in
      Succeeded) return 0 ;;
      Failed)
        jq '{status, error}' "${response_file}" >&2
        qam_fail "Fabric operation failed"
        ;;
      NotStarted | Running) ;;
      *) qam_fail "Fabric operation returned unknown status: ${operation_status}" ;;
    esac
  done
  qam_fail "Fabric operation did not complete within the polling window"
}

create_collection_item() {
  local collection_url="$1"
  local display_name="$2"
  local description="$3"
  local definition_kind="${4:-}"
  local status
  local operation_url
  local operation_id
  local payload

  FABRIC_CREATED_ITEM_ID=''

  if [ "${definition_kind}" = 'notebook' ]; then
    payload="$(base64 < "${notebook_source}" | tr -d '\r\n')"
    jq -n \
      --arg displayName "${display_name}" \
      --arg description "${description}" \
      --arg payload "${payload}" \
      '{displayName: $displayName, description: $description,
        definition: {format: "fabricGitSource", parts: [{
          path: "notebook-content.py", payload: $payload, payloadType: "InlineBase64"
        }]}}' > "${request_file}"
  else
    jq -n \
      --arg displayName "${display_name}" \
      --arg description "${description}" \
      '{displayName: $displayName, description: $description}' > "${request_file}"
  fi

  fabric_request POST "${collection_url}" "${request_file}"
  status="${FABRIC_HTTP_STATUS}"
  case "${status}" in
    201)
      FABRIC_CREATED_ITEM_ID="$(jq -r '.id // empty' "${response_file}")"
      ;;
    202)
      operation_id="$(awk 'tolower($1) == "x-ms-operation-id:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
      if [ -n "${operation_id}" ]; then
        qam_validate_uuid "${operation_id}" "Fabric operation ID"
        operation_url="${fabric_api}/operations/${operation_id}"
      else
        operation_url="$(awk 'tolower($1) == "location:" {$1=""; sub(/^ /, ""); gsub("\\r", ""); print}' "${headers_file}" | tail -1)"
        [ -n "${operation_url}" ] || qam_fail "Fabric returned 202 without an operation identifier"
      fi
      poll_operation "${operation_url}"
      ;;
    *)
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "creating Fabric item returned HTTP ${status}"
      ;;
  esac
}

find_exact_item() {
  local collection_url="$1"
  local display_name="$2"
  local items
  local count

  FABRIC_EXACT_ITEM_ID=''
  list_all "${collection_url}"
  items="${FABRIC_LIST_RESULT}"
  count="$(jq --arg name "${display_name}" '[.[] | select(.displayName == $name)] | length' <<< "${items}")"
  [ "${count}" -le 1 ] || qam_fail "multiple Fabric items have the exact name: ${display_name}"
  if [ "${count}" = '1' ]; then
    FABRIC_EXACT_ITEM_ID="$(jq -r --arg name "${display_name}" '.[] | select(.displayName == $name) | .id' <<< "${items}")"
  fi
}

ensure_collection_item() {
  local collection_url="$1"
  local display_name="$2"
  local description="$3"
  local definition_kind="${4:-}"
  local item_id

  FABRIC_ITEM_ID=''
  find_exact_item "${collection_url}" "${display_name}"
  item_id="${FABRIC_EXACT_ITEM_ID}"
  if [ -n "${item_id}" ]; then
    qam_info "reusing Fabric item: ${display_name}"
    FABRIC_ITEM_ID="${item_id}"
    return
  fi

  qam_info "creating Fabric item: ${display_name}"
  create_collection_item "${collection_url}" "${display_name}" "${description}" "${definition_kind}"
  item_id="${FABRIC_CREATED_ITEM_ID}"
  if [ -z "${item_id}" ]; then
    for _ in $(seq 1 12); do
      sleep 5
      find_exact_item "${collection_url}" "${display_name}"
      item_id="${FABRIC_EXACT_ITEM_ID}"
      [ -z "${item_id}" ] || break
    done
  fi
  [ -n "${item_id}" ] || qam_fail "created Fabric item was not discoverable: ${display_name}"
  qam_validate_uuid "${item_id}" "Fabric item ID"
  FABRIC_ITEM_ID="${item_id}"
}

reconcile_notebook_definition() {
  local notebook_id="$1"
  local payload
  local status
  local operation_url
  local operation_id

  payload="$(base64 < "${notebook_source}" | tr -d '\r\n')"
  jq -n \
    --arg payload "${payload}" \
    '{definition: {format: "fabricGitSource", parts: [{
      path: "notebook-content.py", payload: $payload, payloadType: "InlineBase64"
    }]}}' > "${request_file}"
  qam_info "reconciling checked-in Notebook definition: ${notebook_name}"
  fabric_request POST \
    "${fabric_api}/workspaces/${workspace_id}/notebooks/${notebook_id}/updateDefinition?updateMetadata=false" \
    "${request_file}"
  status="${FABRIC_HTTP_STATUS}"
  case "${status}" in
    200 | 201 | 204) return ;;
    202)
      operation_id="$(awk 'tolower($1) == "x-ms-operation-id:" {gsub("\\r", "", $2); print $2}' "${headers_file}" | tail -1)"
      if [ -n "${operation_id}" ]; then
        qam_validate_uuid "${operation_id}" "Fabric operation ID"
        operation_url="${fabric_api}/operations/${operation_id}"
      else
        operation_url="$(awk 'tolower($1) == "location:" {$1=""; sub(/^ /, ""); gsub("\\r", ""); print}' "${headers_file}" | tail -1)"
        [ -n "${operation_url}" ] || qam_fail "Fabric Notebook update returned no operation identifier"
      fi
      poll_operation "${operation_url}"
      ;;
    *)
      sed -n '1,40p' "${response_file}" >&2
      qam_fail "updating Fabric Notebook definition returned HTTP ${status}"
      ;;
  esac
}

list_all "${fabric_api}/capacities"
capacities="${FABRIC_LIST_RESULT}"
capacity_count="$(jq --arg name "${capacity_name}" '[.[] | select(.displayName == $name)] | length' <<< "${capacities}")"
[ "${capacity_count}" = '1' ] || qam_fail "expected exactly one visible Fabric capacity named ${capacity_name}; found ${capacity_count}"
capacity_id="$(jq -r --arg name "${capacity_name}" '.[] | select(.displayName == $name) | .id' <<< "${capacities}")"
capacity_state="$(jq -r --arg name "${capacity_name}" '.[] | select(.displayName == $name) | .state' <<< "${capacities}")"
qam_validate_uuid "${capacity_id}" "Fabric capacity ID"
[ "${capacity_state}" = 'Active' ] || qam_fail "Fabric capacity must be Active; current state is ${capacity_state}"

list_all "${fabric_api}/workspaces"
workspaces="${FABRIC_LIST_RESULT}"
workspace_count="$(jq --arg name "${workspace_name}" '[.[] | select(.displayName == $name)] | length' <<< "${workspaces}")"
[ "${workspace_count}" -le 1 ] || qam_fail "multiple Fabric workspaces have the exact name: ${workspace_name}"
if [ "${workspace_count}" = '1' ]; then
  workspace="$(jq -c --arg name "${workspace_name}" '.[] | select(.displayName == $name)' <<< "${workspaces}")"
  workspace_id="$(jq -r '.id' <<< "${workspace}")"
  existing_capacity_id="$(jq -r '.capacityId // empty' <<< "${workspace}")"
  [ "${existing_capacity_id}" = "${capacity_id}" ] \
    || qam_fail "existing workspace is assigned to a different capacity"
  qam_info "reusing Fabric workspace: ${workspace_name}"
else
  qam_info "creating Fabric workspace: ${workspace_name}"
  jq -n \
    --arg displayName "${workspace_name}" \
    --arg description 'Isolated public-synthetic industrial evidence workspace for Quick Agentic Memory.' \
    --arg capacityId "${capacity_id}" \
    '{displayName: $displayName, description: $description, capacityId: $capacityId}' > "${request_file}"
  fabric_request POST "${fabric_api}/workspaces" "${request_file}"
  status="${FABRIC_HTTP_STATUS}"
  [ "${status}" = '201' ] || {
    sed -n '1,40p' "${response_file}" >&2
    qam_fail "creating Fabric workspace returned HTTP ${status}"
  }
  workspace_id="$(jq -r '.id // empty' "${response_file}")"
fi
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"

ensure_collection_item \
  "${fabric_api}/workspaces/${workspace_id}/lakehouses" \
  "${lakehouse_name}" \
  'Immutable QAM projections and normalized Delta tables for the synthetic industrial evidence test.'
lakehouse_id="${FABRIC_ITEM_ID}"
ensure_collection_item \
  "${fabric_api}/workspaces/${workspace_id}/graphModels" \
  "${graph_model_name}" \
  'Preview graph model for commit-pinned QAM evidence traversal.'
graph_model_id="${FABRIC_ITEM_ID}"
ensure_collection_item \
  "${fabric_api}/workspaces/${workspace_id}/notebooks" \
  "${notebook_name}" \
  'Checked-in PySpark loader that validates and atomically publishes one immutable QAM projection.' \
  notebook
notebook_id="${FABRIC_ITEM_ID}"
reconcile_notebook_definition "${notebook_id}"

jq -cn \
  --arg capacityId "${capacity_id}" \
  --arg capacityName "${capacity_name}" \
  --arg workspaceId "${workspace_id}" \
  --arg workspaceName "${workspace_name}" \
  --arg lakehouseId "${lakehouse_id}" \
  --arg lakehouseName "${lakehouse_name}" \
  --arg graphModelId "${graph_model_id}" \
  --arg graphModelName "${graph_model_name}" \
  --arg notebookId "${notebook_id}" \
  --arg notebookName "${notebook_name}" \
  '{capacityId: $capacityId, capacityName: $capacityName,
    workspaceId: $workspaceId, workspaceName: $workspaceName,
    lakehouseId: $lakehouseId, lakehouseName: $lakehouseName,
    graphModelId: $graphModelId, graphModelName: $graphModelName,
    notebookId: $notebookId, notebookName: $notebookName}'
