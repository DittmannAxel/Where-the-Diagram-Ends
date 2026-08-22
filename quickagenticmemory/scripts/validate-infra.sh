#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

qam_require_command az

dockerignore="${QAM_REPOSITORY_ROOT}/.dockerignore"
dockerfile_specific_ignore="${QAM_REPOSITORY_ROOT}/quickagenticmemory/packages/mcp/Dockerfile.dockerignore"
expected_dockerignore="$(printf '%s\n' \
  '**' \
  '!/.dockerignore' \
  '!/quickagenticmemory/' \
  '!/quickagenticmemory/contracts/' \
  '!/quickagenticmemory/contracts/qam-graph-1.0.ts' \
  '!/quickagenticmemory/packages/' \
  '!/quickagenticmemory/packages/mcp/' \
  '!/quickagenticmemory/packages/mcp/Dockerfile' \
  '!/quickagenticmemory/packages/mcp/package.json' \
  '!/quickagenticmemory/packages/mcp/package-lock.json' \
  '!/quickagenticmemory/packages/mcp/tsconfig.json' \
  '!/quickagenticmemory/packages/mcp/src/' \
  '!/quickagenticmemory/packages/mcp/src/**')"
[ -f "${dockerignore}" ] || qam_fail "repository-root .dockerignore is required"
[ ! -e "${dockerfile_specific_ignore}" ] \
  || qam_fail "Dockerfile.dockerignore would override the reviewed repository-root build-context policy"
actual_dockerignore="$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "${dockerignore}")"
[ "${actual_dockerignore}" = "${expected_dockerignore}" ] \
  || qam_fail "repository-root .dockerignore must contain only the reviewed MCP build-context allowlist"

require_optional_tools="${QAM_REQUIRE_INFRA_TOOLS:-${CI:-false}}"
require_or_skip() {
  local command_name="$1"
  local purpose="$2"

  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${require_optional_tools}" = "true" ]; then
    qam_fail "${command_name} is required for ${purpose} in CI"
  fi
  qam_info "${command_name} is not installed; ${purpose} was skipped"
  return 1
}

if ! az bicep version >/dev/null 2>&1; then
  qam_fail "Bicep CLI is unavailable; install it with 'az bicep install'"
fi

validation_dir="$(mktemp -d)"
trap 'rm -rf "${validation_dir}"' EXIT

qam_info "building the Bicep deployment"
az bicep build \
  --file "${QAM_INFRA_DIR}/main.bicep" \
  --outfile "${validation_dir}/main.json"

for parameter_file in "${QAM_INFRA_DIR}"/*.bicepparam; do
  qam_info "building $(basename "${parameter_file}")"
  az bicep build-params \
    --file "${parameter_file}" \
    --outfile "${validation_dir}/$(basename "${parameter_file}" .bicepparam).parameters.json"
done

qam_require_command jq
qam_info "validating the pre-application address handoff contract"
jq -e '
  .outputs.plannedAppResourceId.type == "string" and
  (.outputs.plannedAppResourceId.value | contains("Microsoft.App/containerApps")) and
  ((.outputs.plannedAppResourceId.value | contains("deployContainerApp")) | not) and
  .outputs.plannedAppFqdn.type == "string" and
  .outputs.plannedAppUrl.type == "string" and
  (.outputs.plannedAppUrl.value | contains("https://")) and
  (.outputs.plannedAppUrl.value | contains("containerEnvironment")) and
  ((.outputs.plannedAppUrl.value | contains("deployContainerApp")) | not) and
  (.outputs.appUrl.value | contains("deployContainerApp"))
' "${validation_dir}/main.json" >/dev/null \
  || qam_fail "compiled Bicep does not preserve separate planned and deployed app URL outputs"

qam_info "validating the privileged foundation split and ACR ABAC contract"
jq -e '
  .parameters.deployRoleAssignments.defaultValue == false and
  (.variables.reconcilePrivilegedFoundation | contains("parameters(\u0027deployRoleAssignments\u0027)")) and
  (.variables.reconcilePrivilegedFoundation | contains("parameters(\u0027deployContainerApp\u0027)")) and
  (.variables.reconcilePrivilegedFoundation | contains("parameters(\u0027deploymentPrincipalId\u0027)")) and
  ([.resources[]
    | select(.type == "Microsoft.Resources/deployments")
    | select(.properties.parameters.deployRoleAssignments? != null)
    | .properties.parameters.deployRoleAssignments.value]
    == ["[variables(\u0027reconcilePrivilegedFoundation\u0027)]", "[variables(\u0027reconcilePrivilegedFoundation\u0027)]", "[variables(\u0027reconcilePrivilegedFoundation\u0027)]"]) and
  ([.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")] | length == 4) and
  all(.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments");
    (.condition | contains("parameters(\u0027deployRoleAssignments\u0027)"))) and
  ([.. | objects | .repositoryReaderRoleId? // empty]
    == ["[subscriptionResourceId(\u0027Microsoft.Authorization/roleDefinitions\u0027, \u0027b93aa761-3e63-49ed-ac28-beffa264f7ac\u0027)]"]) and
  ([.. | objects | .repositoryWriterRoleId? // empty]
    == ["[subscriptionResourceId(\u0027Microsoft.Authorization/roleDefinitions\u0027, \u00272a1e307c-b015-4ebd-883e-5b7698a07328\u0027)]"]) and
  ([.. | objects | select(.type? == "Microsoft.ContainerRegistry/registries")]
    | length == 1 and .[0].apiVersion == "2025-11-01" and .[0].properties.roleAssignmentMode == "AbacRepositoryPermissions") and
  ([.. | objects | select(.type? == "Microsoft.Authorization/policyAssignments")]
    | length == 1 and
      .[0].apiVersion == "2025-11-01" and
      (.[0].condition | contains("reconcilePrivilegedFoundation")) and
      .[0].properties.enforcementMode == "Default" and
      .[0].properties.parameters.effect.value == "Deny") and
  (.variables.keyVaultRbacPolicyDefinitionId | contains("12d4fa5e-1f9f-4c21-97a9-b99b3c6611b5"))
' "${validation_dir}/main.json" >/dev/null \
  || qam_fail "compiled Bicep violates the privileged foundation or ACR ABAC contract"

for compiled_parameter_file in "${validation_dir}"/*.parameters.json; do
  jq -e '.parameters.deployRoleAssignments.value == false' "${compiled_parameter_file}" >/dev/null \
    || qam_fail "$(basename "${compiled_parameter_file}") must keep deployRoleAssignments=false"
done

oidc_bootstrap="${QAM_SCRIPTS_DIR}/bootstrap-github-oidc.sh"
grep -q -- '--include-groups' "${oidc_bootstrap}" \
  || qam_fail "OIDC privilege audit must include transitive Entra group assignments"

deploy_workflow="${QAM_REPOSITORY_ROOT}/.github/workflows/qam-deploy.yml"
grep -Fq "'.plannedAppResourceId.value" "${deploy_workflow}" \
  || qam_fail "foundation workflow must capture plannedAppResourceId from ARM outputs"
grep -Fq "planned_app_resource_id=%s" "${deploy_workflow}" \
  || qam_fail "foundation workflow must expose plannedAppResourceId in its handoff outputs"
fabric_gate_line="$(grep -n 'name: Gate application deployment on commit-pinned Fabric Graph GQL' "${deploy_workflow}" | cut -d: -f1)"
image_build_line="$(grep -n 'name: Build and push immutable image' "${deploy_workflow}" | cut -d: -f1)"
application_deploy_line="$(grep -n 'name: Deploy MCP application' "${deploy_workflow}" | cut -d: -f1)"
[ -n "${fabric_gate_line}" ] \
  && [ "${fabric_gate_line}" -lt "${image_build_line}" ] \
  && [ "${image_build_line}" -lt "${application_deploy_line}" ] \
  || qam_fail "commit-pinned Fabric GQL must gate image build and ACA deployment"
# shellcheck disable=SC2016 # Match the literal workflow runtime variable.
grep -A 8 'name: Gate application deployment on commit-pinned Fabric Graph GQL' "${deploy_workflow}" \
  | grep -q -- '--expected-commit-sha "${GITHUB_SHA}"' \
  || qam_fail "pre-ACA Fabric GQL gate must require the workflow commit SHA"

qam_info "validating checked-in GitHub and Fabric templates"
jq empty "${QAM_INFRA_DIR}/github/github-app-settings.example.json"
qam_require_command python3
python3 -c 'import ast, pathlib; path = pathlib.Path(__import__("sys").argv[1]); ast.parse(path.read_text(), filename=str(path))' \
  "${QAM_INFRA_DIR}/fabric/qam-load-projection.notebook-content.py"

if command -v shellcheck >/dev/null 2>&1; then
  qam_info "running ShellCheck"
  find "${QAM_SCRIPTS_DIR}" -type f -name '*.sh' -print0 \
    | xargs -0 shellcheck --external-sources --source-path="${QAM_REPOSITORY_ROOT}"
else
  if [ "${require_optional_tools}" = "true" ]; then
    qam_fail "ShellCheck is required in CI"
  fi
  qam_info "ShellCheck is not installed; shell validation was skipped"
fi

qam_info "checking Bash syntax"
find "${QAM_SCRIPTS_DIR}" -type f -name '*.sh' -print0 \
  | xargs -0 -n 1 bash -n

if require_or_skip actionlint "GitHub Actions validation"; then
  qam_info "validating QAM GitHub Actions workflows"
  actionlint "${QAM_REPOSITORY_ROOT}"/.github/workflows/qam-*.yml
fi

if require_or_skip gitleaks "secret scanning"; then
  qam_info "scanning the checkout for secrets with redacted output"
  gitleaks dir --no-banner --redact "${QAM_REPOSITORY_ROOT}"
fi

qam_info "running security-control negative tests"
"${QAM_SCRIPTS_DIR}/tests/security-controls.sh"

qam_info "infrastructure validation completed"
