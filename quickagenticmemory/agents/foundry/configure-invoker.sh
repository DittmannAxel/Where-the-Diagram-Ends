#!/usr/bin/env bash

set -Eeuo pipefail

agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qam_dir="$(cd "${agent_dir}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${qam_dir}/scripts/lib/common.sh"

readonly foundry_user_role_id="53ca6127-db72-4b80-b1b0-d745d6d5456d"
registration_file=""
invoker_principal_id=""
invoker_principal_type="ServicePrincipal"

usage() {
  printf '%s\n' \
    'Usage: configure-invoker.sh --registration FILE --invoker-principal-id UUID [options]' \
    '' \
    'Options:' \
    '  --invoker-principal-type TYPE   ServicePrincipal (default), User, or Group' \
    '' \
    'Assigns Foundry User at exactly the published Agent Application scope. This grants' \
    'inbound invocation only; it is separate from the application outbound QAM identity.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registration) registration_file="${2:?missing value for $1}"; shift 2 ;;
    --invoker-principal-id) invoker_principal_id="${2:?missing value for $1}"; shift 2 ;;
    --invoker-principal-type) invoker_principal_type="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${registration_file}" ] || qam_fail "--registration is required"
[ -f "${registration_file}" ] || qam_fail "registration file does not exist"
[ -n "${invoker_principal_id}" ] || qam_fail "--invoker-principal-id is required"
qam_validate_uuid "${invoker_principal_id}" "invoker principal ID"
case "${invoker_principal_type}" in
  ServicePrincipal | User | Group) ;;
  *) qam_fail "invoker principal type must be ServicePrincipal, User, or Group" ;;
esac
qam_require_azure_login
qam_require_command jq

jq -e '
  (.phase == "published-identity") and
  (.applicationResourceId | type == "string") and
  (.projectResourceId | type == "string") and
  (.applicationClientId | type == "string") and
  (.applicationPrincipalId | type == "string") and
  (.applicationName | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")) and
  (.agentName | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$"))
' "${registration_file}" >/dev/null \
  || qam_fail "registration file does not identify a published Agent Application"

application_scope="$(jq -er '.applicationResourceId' "${registration_file}")"
project_scope="$(jq -er '.projectResourceId' "${registration_file}")"
application_name="$(jq -er '.applicationName' "${registration_file}")"
application_client_id="$(jq -er '.applicationClientId' "${registration_file}")"
application_principal_id="$(jq -er '.applicationPrincipalId' "${registration_file}")"
agent_name="$(jq -er '.agentName' "${registration_file}")"
qam_validate_uuid "${application_client_id}" "Foundry Agent Application client ID"
qam_validate_uuid "${application_principal_id}" "Foundry Agent Application principal ID"
[ "${application_scope}" = "${project_scope%/}/applications/${application_name}" ] \
  || qam_fail "registration application resource ID does not match its project and application name"
printf '%s' "${application_scope}" \
  | grep -Eqi '^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.CognitiveServices/accounts/[A-Za-z0-9-]+/projects/[A-Za-z0-9._-]+/applications/[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' \
  || qam_fail "registration application resource ID has an unexpected shape"

live_application="$(az rest \
  --method get \
  --url "https://management.azure.com${application_scope}?api-version=2026-05-01" \
  --output json \
  --only-show-errors)"
jq -e \
  --arg client_id "${application_client_id}" \
  --arg principal_id "${application_principal_id}" \
  --arg agent_name "${agent_name}" '
    (.properties.provisioningState == "Succeeded") and
    (.properties.authorizationPolicy.type == "Default") and
    (.properties.agents | length == 1) and
    (.properties.agents[0].agentName == $agent_name) and
    (.properties.defaultInstanceIdentity.kind == "AgentInstance") and
    (.properties.defaultInstanceIdentity.clientId == $client_id) and
    (.properties.defaultInstanceIdentity.principalId == $principal_id)
  ' <<< "${live_application}" >/dev/null \
  || qam_fail "live Agent Application identity does not match the registration"

existing_count="$(az role assignment list \
  --scope "${application_scope}" \
  --role "${foundry_user_role_id}" \
  --query "[?principalId=='${invoker_principal_id}'] | length(@)" \
  --output tsv \
  --only-show-errors)"

case "${existing_count}" in
  0)
    az role assignment create \
      --assignee-object-id "${invoker_principal_id}" \
      --assignee-principal-type "${invoker_principal_type}" \
      --role "${foundry_user_role_id}" \
      --scope "${application_scope}" \
      --output none \
      --only-show-errors
    ;;
  '' | *[!0-9]*) qam_fail "Azure returned an invalid role-assignment count" ;;
esac

jq -cn \
  --arg applicationResourceId "${application_scope}" \
  --arg invokerPrincipalId "${invoker_principal_id}" \
  --arg invokerPrincipalType "${invoker_principal_type}" \
  --arg roleDefinitionId "${foundry_user_role_id}" \
  '{
    applicationResourceId: $applicationResourceId,
    invokerPrincipalId: $invokerPrincipalId,
    invokerPrincipalType: $invokerPrincipalType,
    roleDefinitionId: $roleDefinitionId,
    role: "Foundry User"
  }'
