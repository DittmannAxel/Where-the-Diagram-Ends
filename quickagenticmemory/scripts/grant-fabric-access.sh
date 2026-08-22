#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

workspace_id="${QAM_FABRIC_WORKSPACE_ID:-}"
runtime_principal_id=""
smoke_principal_id=""
definition_updater_principal_id=""

usage() {
  printf '%s\n' \
    'Usage: grant-fabric-access.sh --workspace-id UUID --runtime-principal-id UUID [options]' \
    '' \
    'Options:' \
    '  --smoke-principal-id UUID' \
    '      Optionally grant the protected deployment identity Viewer for bounded GQL smoke tests.' \
    '  --definition-updater-principal-id UUID' \
    '      Optionally grant the deployment identity Contributor for definition updates.' \
    '' \
    'The signed-in operator must already be a workspace Member or Admin and must have' \
    'delegated Workspace.ReadWrite.All. Existing broader roles are never downgraded.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-id) workspace_id="${2:?missing value for $1}"; shift 2 ;;
    --runtime-principal-id) runtime_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --smoke-principal-id) smoke_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --definition-updater-principal-id) definition_updater_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${workspace_id}" ] || qam_fail "--workspace-id is required"
[ -n "${runtime_principal_id}" ] || qam_fail "--runtime-principal-id is required"
qam_validate_uuid "${workspace_id}" "Fabric workspace ID"
qam_validate_uuid "${runtime_principal_id}" "runtime principal ID"
if [ -n "${smoke_principal_id}" ]; then
  qam_validate_uuid "${smoke_principal_id}" "smoke principal ID"
  [ "${smoke_principal_id}" != "${runtime_principal_id}" ] \
    || qam_fail "smoke principal must be distinct from the runtime principal"
fi
if [ -n "${definition_updater_principal_id}" ]; then
  qam_validate_uuid "${definition_updater_principal_id}" "definition updater principal ID"
  [ "${definition_updater_principal_id}" != "${runtime_principal_id}" ] \
    || qam_fail "definition updater must be distinct from the runtime principal"
fi

qam_require_azure_login
qam_require_command curl
qam_require_command jq
az ad sp show --id "${runtime_principal_id}" --query id --output none \
  || qam_fail "runtime principal is not an Entra service principal"
if [ -n "${smoke_principal_id}" ]; then
  az ad sp show --id "${smoke_principal_id}" --query id --output none \
    || qam_fail "smoke principal is not an Entra service principal"
fi
if [ -n "${definition_updater_principal_id}" ]; then
  az ad sp show --id "${definition_updater_principal_id}" --query id --output none \
    || qam_fail "definition updater is not an Entra service principal"
fi

access_token="$(az account get-access-token \
  --resource 'https://api.fabric.microsoft.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Fabric access token"

workspace_assignments='[]'
next_url="https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments"
page_count=0
while [ -n "${next_url}" ]; do
  printf '%s' "${next_url}" \
    | grep -Eq "^https://api\\.fabric\\.microsoft\\.com/v1/workspaces/${workspace_id}/roleAssignments([?].*)?$" \
    || qam_fail "Fabric pagination URL left the expected HTTPS workspace roleAssignments endpoint"
  page_count=$((page_count + 1))
  [ "${page_count}" -le 100 ] || qam_fail "Fabric role-assignment pagination exceeded 100 pages"
  response_file="$(mktemp)"
  status="$(curl \
    --silent \
    --show-error \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Accept: application/json' \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${next_url}")"
  if [ "${status}" != "200" ]; then
    sed -n '1,40p' "${response_file}" >&2
    rm -f "${response_file}"
    qam_fail "listing Fabric workspace role assignments returned HTTP ${status}"
  fi
  jq -e '.value | type == "array"' "${response_file}" >/dev/null \
    || qam_fail "Fabric workspace role-assignment response has no value array"
  workspace_assignments="$(jq -cn \
    --argjson accumulated "${workspace_assignments}" \
    --slurpfile page "${response_file}" \
    '$accumulated + $page[0].value')"
  next_url="$(jq -r '.continuationUri // ."@odata.nextLink" // empty' "${response_file}")"
  rm -f "${response_file}"
done

grant_role() {
  local principal_id="$1"
  local desired_role="$2"
  local existing_roles
  local body
  local response_file
  local status

  existing_roles="$(jq -r --arg id "${principal_id}" \
    '[.[] | select(.principal.id == $id) | .role] | unique | join(",")' \
    <<< "${workspace_assignments}")"
  case "${desired_role}:${existing_roles}" in
    Viewer:Viewer | Viewer:Contributor | Viewer:Member | Viewer:Admin)
      qam_info "principal ${principal_id} already has ${existing_roles}; no downgrade"
      return
      ;;
    Contributor:Contributor | Contributor:Member | Contributor:Admin)
      qam_info "principal ${principal_id} already has ${existing_roles}"
      return
      ;;
    Contributor:Viewer)
      qam_fail "definition updater has Viewer; upgrade it manually or remove/recreate the assignment"
      ;;
    *:"") ;;
    *) qam_fail "principal ${principal_id} has unexpected or duplicate Fabric roles: ${existing_roles}" ;;
  esac

  body="$(jq -cn --arg id "${principal_id}" --arg role "${desired_role}" \
    '{principal: {id: $id, type: "ServicePrincipal"}, role: $role}')"
  response_file="$(mktemp)"
  status="$(curl \
    --silent \
    --show-error \
    --request POST \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "${body}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/roleAssignments")"
  case "${status}" in
    200 | 201) qam_info "granted ${desired_role} to ${principal_id}" ;;
    *)
      sed -n '1,40p' "${response_file}" >&2
      rm -f "${response_file}"
      qam_fail "granting Fabric ${desired_role} returned HTTP ${status}"
      ;;
  esac
  rm -f "${response_file}"
}

grant_role "${runtime_principal_id}" Viewer
# Contributor already includes read/query capability. Avoid creating a duplicate
# Viewer assignment when the same protected identity is temporarily an updater.
if [ -n "${smoke_principal_id}" ] \
  && [ "${smoke_principal_id}" != "${definition_updater_principal_id}" ]; then
  grant_role "${smoke_principal_id}" Viewer
fi
if [ -n "${definition_updater_principal_id}" ]; then
  grant_role "${definition_updater_principal_id}" Contributor
fi

jq -cn \
  --arg workspaceId "${workspace_id}" \
  --arg runtimePrincipalId "${runtime_principal_id}" \
  --arg smokePrincipalId "${smoke_principal_id}" \
  --arg definitionUpdaterPrincipalId "${definition_updater_principal_id}" \
  '{workspaceId: $workspaceId, runtimePrincipalId: $runtimePrincipalId, runtimeRole: "Viewer"}
  + if $smokePrincipalId == "" then {} else {
      smokePrincipalId: $smokePrincipalId,
      smokeMinimumRole: (if $smokePrincipalId == $definitionUpdaterPrincipalId then "Contributor" else "Viewer" end)
    } end
  + if $definitionUpdaterPrincipalId == "" then {} else {
      definitionUpdaterPrincipalId: $definitionUpdaterPrincipalId,
      definitionUpdaterMinimumRole: "Contributor"
    } end'
