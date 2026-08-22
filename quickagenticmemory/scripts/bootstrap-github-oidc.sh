#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

subscription_id=""
resource_group=""
location="westeurope"
github_owner=""
github_repository=""
github_environment=""
identity_name=""
remove_legacy_rbac_admin="false"

usage() {
  printf '%s\n' \
    'Usage: bootstrap-github-oidc.sh [required options]' \
    '' \
    'Required:' \
    '  --subscription-id UUID' \
    '  --resource-group NAME' \
    '  --github-owner OWNER' \
    '  --github-repository REPOSITORY' \
    '  --github-environment qam-dev|qam-test|qam-prod' \
    '' \
    'Optional:' \
    '  --location REGION             Default: westeurope' \
    '  --identity-name NAME          Default: qam-<environment>-github' \
    '  --remove-legacy-rbac-admin    Remove only a direct legacy RG-scoped RBAC Administrator assignment; every other privileged assignment fails closed'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --subscription-id) subscription_id="${2:?missing value for $1}"; shift 2 ;;
    --resource-group) resource_group="${2:?missing value for $1}"; shift 2 ;;
    --location) location="${2:?missing value for $1}"; shift 2 ;;
    --github-owner) github_owner="${2:?missing value for $1}"; shift 2 ;;
    --github-repository) github_repository="${2:?missing value for $1}"; shift 2 ;;
    --github-environment) github_environment="${2:?missing value for $1}"; shift 2 ;;
    --identity-name) identity_name="${2:?missing value for $1}"; shift 2 ;;
    --remove-legacy-rbac-admin) remove_legacy_rbac_admin="true"; shift ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${subscription_id}" ] || qam_fail "--subscription-id is required"
[ -n "${resource_group}" ] || qam_fail "--resource-group is required"
[ -n "${github_owner}" ] || qam_fail "--github-owner is required"
[ -n "${github_repository}" ] || qam_fail "--github-repository is required"
[ -n "${github_environment}" ] || qam_fail "--github-environment is required"
qam_validate_uuid "${subscription_id}" "subscription ID"
printf '%s' "${github_environment}" | grep -Eq '^qam-(dev|test|prod)$' \
  || qam_fail "GitHub environment must be qam-dev, qam-test, or qam-prod"
qam_require_azure_login
qam_require_command jq

az account set --subscription "${subscription_id}"
az group create \
  --name "${resource_group}" \
  --location "${location}" \
  --tags application=quick-agentic-memory managedBy=bootstrap \
  --output none

if [ -z "${identity_name}" ]; then
  identity_name="${github_environment}-github"
fi

if ! az identity show --resource-group "${resource_group}" --name "${identity_name}" --output none 2>/dev/null; then
  qam_info "creating the GitHub deployment identity"
  az identity create \
    --resource-group "${resource_group}" \
    --name "${identity_name}" \
    --location "${location}" \
    --tags application=quick-agentic-memory purpose=github-oidc \
    --output none
fi

client_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query clientId --output tsv)"
principal_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query principalId --output tsv)"
tenant_id="$(az account show --query tenantId --output tsv)"
resource_group_id="$(az group show --name "${resource_group}" --query id --output tsv)"
subject="repo:${github_owner}/${github_repository}:environment:${github_environment}"
credential_name="github-${github_environment}"

existing_subject="$(az identity federated-credential show \
  --resource-group "${resource_group}" \
  --identity-name "${identity_name}" \
  --name "${credential_name}" \
  --query subject \
  --output tsv 2>/dev/null || true)"
if [ -n "${existing_subject}" ] && [ "${existing_subject}" != "${subject}" ]; then
  qam_fail "federated credential ${credential_name} already exists with a different subject"
fi
if [ -z "${existing_subject}" ]; then
  qam_info "creating the GitHub environment federated credential"
  az identity federated-credential create \
    --resource-group "${resource_group}" \
    --identity-name "${identity_name}" \
    --name "${credential_name}" \
    --issuer 'https://token.actions.githubusercontent.com' \
    --subject "${subject}" \
    --audiences 'api://AzureADTokenExchange' \
    --output none
fi

# The routine GitHub identity deploys resources but cannot create role assignments.
qam_info "ensuring Contributor on the isolated resource group"
az role assignment create \
  --assignee-object-id "${principal_id}" \
  --assignee-principal-type ServicePrincipal \
  --role 'Contributor' \
  --scope "${resource_group_id}" \
  --output none

# Older revisions granted this identity broad role-assignment write access. Role
# names alone are insufficient: Owner, access-administrator roles, and custom
# roles can all grant the same action. Resolve every effective definition at the
# resource group or an inherited parent and evaluate Actions - NotActions. An
# assignment condition is deliberately ignored because it is not an explicit
# deny; a matching role therefore fails closed even when conditioned.
qam_rbac_action_matches() {
  local pattern
  local target
  pattern="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  target="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  # shellcheck disable=SC2254 # Azure RBAC action patterns intentionally contain wildcards.
  case "${target}" in
    ${pattern}) return 0 ;;
    *) return 1 ;;
  esac
}

qam_role_definition_grants_role_assignment_write() {
  local definition_json="$1"
  local permission_json
  local action
  local excluded_action
  local action_allowed
  local action_excluded
  local target_action='microsoft.authorization/roleassignments/write'

  jq -e '
    (.permissions | type == "array" and length > 0) and
    all(.permissions[]; (.actions | type == "array") and (.notActions | type == "array"))
  ' <<< "${definition_json}" >/dev/null \
    || qam_fail "role definition permissions could not be evaluated safely"

  while IFS= read -r permission_json; do
    action_allowed='false'
    while IFS= read -r action; do
      if qam_rbac_action_matches "${action}" "${target_action}"; then
        action_allowed='true'
        break
      fi
    done < <(jq -r '.actions[]' <<< "${permission_json}")
    [ "${action_allowed}" = 'true' ] || continue

    action_excluded='false'
    while IFS= read -r excluded_action; do
      if qam_rbac_action_matches "${excluded_action}" "${target_action}"; then
        action_excluded='true'
        break
      fi
    done < <(jq -r '.notActions[]' <<< "${permission_json}")
    [ "${action_excluded}" = 'true' ] || return 0
  done < <(jq -c '.permissions[]' <<< "${definition_json}")
  return 1
}

qam_audit_role_assignment_privileges() {
  local allow_direct_legacy_removal="$1"
  local assignments_json
  local assignment_json
  local assignment_id
  local assignment_principal_id
  local assignment_scope
  local assignment_condition
  local role_definition_id
  local role_definition_name
  local definitions_json
  local definition_json
  local role_name
  local role_type
  local direct_scope
  local unsafe_count=0

  assignments_json="$(az role assignment list \
    --assignee "${principal_id}" \
    --scope "${resource_group_id}" \
    --include-groups \
    --include-inherited \
    --all \
    --output json)"
  jq -e 'type == "array"' <<< "${assignments_json}" >/dev/null \
    || qam_fail "effective Azure role assignments could not be enumerated"

  while IFS= read -r assignment_json; do
    assignment_id="$(jq -er '.id | select(type == "string" and length > 0)' <<< "${assignment_json}")" \
      || qam_fail "an effective role assignment has no resolvable ID"
    assignment_principal_id="$(jq -er '.principalId | select(type == "string" and length > 0)' <<< "${assignment_json}")" \
      || qam_fail "an effective role assignment has no resolvable principal ID"
    assignment_scope="$(jq -er '.scope | select(type == "string" and length > 0)' <<< "${assignment_json}")" \
      || qam_fail "an effective role assignment has no resolvable scope"
    role_definition_id="$(jq -er '.roleDefinitionId | select(type == "string" and length > 0)' <<< "${assignment_json}")" \
      || qam_fail "an effective role assignment has no resolvable role definition"
    assignment_condition="$(jq -r '.condition // empty' <<< "${assignment_json}")"
    role_definition_name="${role_definition_id##*/}"
    definitions_json="$(az role definition list --name "${role_definition_name}" --output json)"
    definition_json="$(jq -cer 'if length == 1 then .[0] else error("expected exactly one role definition") end' \
      <<< "${definitions_json}")" \
      || qam_fail "role definition ${role_definition_id} could not be resolved uniquely"

    if ! qam_role_definition_grants_role_assignment_write "${definition_json}"; then
      continue
    fi

    role_name="$(jq -r '.roleName // .name // "<unknown>"' <<< "${definition_json}")"
    role_type="$(jq -r '.roleType // "<unknown>"' <<< "${definition_json}")"
    direct_scope="false"
    if [ "$(printf '%s' "${assignment_scope}" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "${resource_group_id}" | tr '[:upper:]' '[:lower:]')" ]; then
      direct_scope="true"
    fi

    if [ "${allow_direct_legacy_removal}" = 'true' ] \
      && [ "${direct_scope}" = 'true' ] \
      && [ "$(printf '%s' "${assignment_principal_id}" | tr '[:upper:]' '[:lower:]')" = \
        "$(printf '%s' "${principal_id}" | tr '[:upper:]' '[:lower:]')" ] \
      && [ "${role_name}" = 'Role Based Access Control Administrator' ]; then
      qam_info "removing the reviewed direct legacy RG-scoped RBAC Administrator assignment"
      az role assignment delete --ids "${assignment_id}"
      continue
    fi

    qam_info "unsafe effective Azure role assignment: role=${role_name} type=${role_type} scope=${assignment_scope}"
    if [ -n "${assignment_condition}" ]; then
      qam_info "the assignment has a condition; the audit conservatively treats roleAssignments/write as effective"
    fi
    printf 'Review, then remove explicitly: az role assignment delete --ids %q\n' "${assignment_id}" >&2
    unsafe_count=$((unsafe_count + 1))
  done < <(jq -c '.[]' <<< "${assignments_json}")

  [ "${unsafe_count}" -eq 0 ] \
    || qam_fail "refusing to return GitHub handoff IDs while roleAssignments/write is effective"
}

qam_audit_role_assignment_privileges "${remove_legacy_rbac_admin}"
# Re-read Azure state after an optional exact-ID removal; assignments are never
# considered safe merely because a delete command returned success.
qam_audit_role_assignment_privileges 'false'

printf '%s\n' \
  'Create these GitHub Environment variables (none is a secret):' \
  "AZURE_CLIENT_ID=${client_id}" \
  "AZURE_PRINCIPAL_ID=${principal_id}" \
  "AZURE_TENANT_ID=${tenant_id}" \
  "AZURE_SUBSCRIPTION_ID=${subscription_id}" \
  "AZURE_RESOURCE_GROUP=${resource_group}" \
  "AZURE_LOCATION=${location}"
