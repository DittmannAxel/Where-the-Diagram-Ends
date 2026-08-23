#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

fixtures_dir="${QAM_SCRIPTS_DIR}/tests/fixtures"

dockerignore="${QAM_REPOSITORY_ROOT}/.dockerignore"
[ -f "${dockerignore}" ] || qam_fail "repository-root .dockerignore is required"
[ ! -e "${QAM_REPOSITORY_ROOT}/quickagenticmemory/packages/mcp/Dockerfile.dockerignore" ] \
  || qam_fail "Dockerfile.dockerignore must not override the repository-root build-context policy"
expected_docker_exceptions="$(printf '%s\n' \
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
actual_docker_exceptions="$(grep '^!' "${dockerignore}")"
[ "${actual_docker_exceptions}" = "${expected_docker_exceptions}" ] \
  || qam_fail ".dockerignore contains an unreviewed build-context exception"
[ "$(grep -c '^\*\*$' "${dockerignore}")" -eq 1 ] \
  || qam_fail ".dockerignore must default-deny the complete repository build context"
validate_workflow="${QAM_REPOSITORY_ROOT}/.github/workflows/qam-validate.yml"
[ "$(grep -c "      - '.dockerignore'" "${validate_workflow}")" -eq 2 ] \
  || qam_fail "QAM validation must run when the root Docker build-context policy changes"
fixture_commit='1111111111111111111111111111111111111111'

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    qam_fail "negative test unexpectedly passed: ${label}"
  fi
}

"${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
  --node-response-file "${fixtures_dir}/fabric-node-ok.json" \
  --edge-response-file "${fixtures_dir}/fabric-edge-ok.json" \
  --expected-commit-sha "${fixture_commit}"

"${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
  --node-response-file "${fixtures_dir}/fabric-node-ok.json" \
  --edge-response-file "${fixtures_dir}/fabric-edge-empty.json" \
  --expected-commit-sha "${fixture_commit}"

expect_failure "Fabric GQL snapshot at an unexpected commit" \
  "${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
  --node-response-file "${fixtures_dir}/fabric-node-ok.json" \
  --edge-response-file "${fixtures_dir}/fabric-edge-empty.json" \
  --expected-commit-sha 2222222222222222222222222222222222222222

expect_failure "non-canonical expected Fabric commit" \
  "${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
  --node-response-file "${fixtures_dir}/fabric-node-ok.json" \
  --edge-response-file "${fixtures_dir}/fabric-edge-empty.json" \
  --expected-commit-sha AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

expect_failure "Fabric GQL 04xxx status" \
  "${QAM_SCRIPTS_DIR}/smoke-test-fabric-graph.sh" \
  --node-response-file "${fixtures_dir}/fabric-node-invalid-status.json" \
  --edge-response-file "${fixtures_dir}/fabric-edge-ok.json"

# shellcheck disable=SC2016
expect_failure "cross-origin Fabric operation Location" \
  bash -c 'source "$1"; qam_validate_fabric_operation_url "https://attacker.example/v1/operations/11111111-1111-4111-8111-111111111111"' \
  _ "${QAM_SCRIPTS_DIR}/lib/common.sh"

# shellcheck disable=SC2016
expect_failure "cross-origin Fabric Notebook Location" \
  bash -c 'source "$1"; qam_validate_fabric_notebook_job_url "https://attacker.example/v1/workspaces/11111111-1111-4111-8111-111111111111/items/22222222-2222-4222-8222-222222222222/jobs/instances/33333333-3333-4333-8333-333333333333" "11111111-1111-4111-8111-111111111111" "22222222-2222-4222-8222-222222222222"' \
  _ "${QAM_SCRIPTS_DIR}/lib/common.sh"

notebook_mock_workspace='11111111-1111-4111-8111-111111111111'
notebook_mock_id='22222222-2222-4222-8222-222222222222'
notebook_mock_lakehouse='33333333-3333-4333-8333-333333333333'
notebook_mock_projection="urn:qam:projection:$(printf 'a%.0s' {1..64})"
notebook_mock_job='44444444-4444-4444-8444-444444444444'
# shellcheck disable=SC2329 # exported into the notebook runner's Bash process
az() {
  case "${1:-} ${2:-}" in
    'account show') return 0 ;;
    'account get-access-token') printf '%s\n' 'mock-fabric-access-token'; return 0 ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2329 # exported into the notebook runner's Bash process
sleep() { :; }
# shellcheck disable=SC2329 # exported into the notebook runner's Bash process
curl() {
  local argument=''
  local previous=''
  local request='GET'
  local output_file='/dev/null'
  local headers_file='/dev/null'

  for argument in "$@"; do
    case "${previous}" in
      --request) request="${argument}" ;;
      --output) output_file="${argument}" ;;
      --dump-header) headers_file="${argument}" ;;
    esac
    previous="${argument}"
  done
  if [ "${request}" = 'POST' ]; then
    printf 'Location: https://api.fabric.microsoft.com/v1/workspaces/%s/items/%s/jobs/instances/%s\r\nRetry-After: 0\r\n' \
      "${QAM_NOTEBOOK_MOCK_WORKSPACE}" "${QAM_NOTEBOOK_MOCK_ID}" "${QAM_NOTEBOOK_MOCK_JOB}" \
      > "${headers_file}"
    printf '{}\n' > "${output_file}"
    printf '202'
    return
  fi
  jq -cn \
    --arg id "${QAM_NOTEBOOK_MOCK_JOB}" \
    --arg projectionId "${QAM_NOTEBOOK_MOCK_PROJECTION}" \
    --arg commitSha "${QAM_NOTEBOOK_MOCK_COMMIT}" \
    '{id: $id, status: "Completed", exitValue: ({status: "success", projectionId: $projectionId, commitSha: $commitSha, nodeCount: 1, edgeCount: 0} | tojson)}' \
    > "${output_file}"
  printf '200'
}
export -f az curl sleep
export QAM_NOTEBOOK_MOCK_WORKSPACE="${notebook_mock_workspace}"
export QAM_NOTEBOOK_MOCK_ID="${notebook_mock_id}"
export QAM_NOTEBOOK_MOCK_JOB="${notebook_mock_job}"
export QAM_NOTEBOOK_MOCK_PROJECTION="${notebook_mock_projection}"
export QAM_NOTEBOOK_MOCK_COMMIT="${fixture_commit}"
notebook_zero_edge_result="$("${QAM_SCRIPTS_DIR}/run-fabric-projection-notebook.sh" \
  --workspace-id "${notebook_mock_workspace}" \
  --notebook-id "${notebook_mock_id}" \
  --lakehouse-id "${notebook_mock_lakehouse}" \
  --staging-path "Files/qam-staging/${notebook_mock_projection##*:}/${fixture_commit}" \
  --projection-id "${notebook_mock_projection}" \
  --commit-sha "${fixture_commit}")"
jq -e '.status == "success" and .nodeCount == 1 and .edgeCount == 0' <<< "${notebook_zero_edge_result}" >/dev/null \
  || qam_fail "Fabric Notebook runner rejected the valid zero-edge success contract"
unset -f az curl sleep
unset QAM_NOTEBOOK_MOCK_WORKSPACE QAM_NOTEBOOK_MOCK_ID QAM_NOTEBOOK_MOCK_JOB
unset QAM_NOTEBOOK_MOCK_PROJECTION QAM_NOTEBOOK_MOCK_COMMIT
python3 "${QAM_SCRIPTS_DIR}/tests/check-fabric-notebook-contract.py"

projection_contract="$("${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-nodes.ndjson" \
  --edges-file "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-edges.ndjson" \
  --dry-run)"
jq -e '.stagingPath | test("^Files/qam-staging/[0-9a-f]{64}/([0-9a-f]{40}|[0-9a-f]{64})$")' <<< "${projection_contract}" >/dev/null \
  || qam_fail "OneLake projection dry-run did not emit an immutable staging path"

empty_edges_file="$(mktemp)"
empty_edge_projection_contract="$("${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-nodes.ndjson" \
  --edges-file "${empty_edges_file}" \
  --dry-run)"
jq -e --arg projectionId "$(jq -r '.projectionId' <<< "${projection_contract}")" \
  '.projectionId == $projectionId' <<< "${empty_edge_projection_contract}" >/dev/null \
  || qam_fail "zero-edge OneLake dry-run changed the node-derived projection identity"

wrong_kind_edges_file="$(mktemp)"
jq -c 'if .type == "HAS_TAG" then .type = "DERIVED_FROM" else . end' \
  "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-edges.ndjson" > "${wrong_kind_edges_file}"
expect_failure "edge type and endpoint-kind mismatch" \
  "${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-nodes.ndjson" \
  --edges-file "${wrong_kind_edges_file}" \
  --dry-run
rm -f "${wrong_kind_edges_file}"

expect_failure "custom OneLake staging prefix" \
  "${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-nodes.ndjson" \
  --edges-file "${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-edges.ndjson" \
  --staging-prefix custom \
  --dry-run

onelake_mock_log="$(mktemp)"
# shellcheck disable=SC2329 # exported into the publisher's Bash process
az() {
  case "${1:-} ${2:-}" in
    'account show') return 0 ;;
    'account get-access-token') printf '%s\n' 'mock-storage-access-token'; return 0 ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2329 # exported into the publisher's Bash process
curl() {
  local argument=''
  local previous=''
  local request='GET'
  local output_file='/dev/null'
  local url=''
  local file_create='false'
  local conditional='false'
  local rename_source=''

  for argument in "$@"; do
    case "${previous}" in
      --request) request="${argument}" ;;
      --output) output_file="${argument}" ;;
    esac
    case "${argument}" in
      *'?resource=file') file_create='true' ;;
      'If-None-Match: *') conditional='true' ;;
      'x-ms-rename-source: '*) rename_source="${argument#x-ms-rename-source: }" ;;
      https://*) url="${argument}" ;;
    esac
    previous="${argument}"
  done

  if [ "${request}" = 'PUT' ] && [ "${file_create}" = 'true' ]; then
    printf 'FILE_CREATE conditional=%s url=%s\n' "${conditional}" "${url}" >> "${QAM_ONELAKE_MOCK_LOG}"
    printf '201'
    return
  fi
  if [ "${request}" = 'PUT' ] && [[ "${url}" == *'?resource=directory' ]]; then
    printf 'DIRECTORY conditional=%s url=%s\n' "${conditional}" "${url}" >> "${QAM_ONELAKE_MOCK_LOG}"
    printf '201'
    return
  fi

  case "${request}:${url}" in
    PATCH:*'nodes.ndjson?action=append'*)
      printf 'APPEND nodes\n' >> "${QAM_ONELAKE_MOCK_LOG}"
      printf '202'
      ;;
    PATCH:*'edges.ndjson?action=append'*)
      printf 'APPEND edges\n' >> "${QAM_ONELAKE_MOCK_LOG}"
      if [ "${QAM_ONELAKE_MOCK_MODE}" = 'partial' ]; then printf '500'; else printf '202'; fi
      ;;
    PATCH:*'?action=flush'*) printf '200' ;;
    PUT:*)
      [ -n "${rename_source}" ] || { printf '500'; return; }
      printf 'RENAME conditional=%s source=%s target=%s\n' \
        "${conditional}" "${rename_source}" "${url}" >> "${QAM_ONELAKE_MOCK_LOG}"
      case "${QAM_ONELAKE_MOCK_MODE}" in
        existing | mismatch) printf '412' ;;
        *) printf '201' ;;
      esac
      ;;
    GET:*nodes.ndjson)
      command cp "${QAM_ONELAKE_MOCK_NODES}" "${output_file}"
      if [[ "${url}" != *'/_temporary/'* ]]; then printf 'GET_FINAL nodes\n' >> "${QAM_ONELAKE_MOCK_LOG}"; fi
      printf '200'
      ;;
    GET:*edges.ndjson)
      if [ "${QAM_ONELAKE_MOCK_MODE}" = 'mismatch' ] && [[ "${url}" != *'/_temporary/'* ]]; then
        printf '{}\n' > "${output_file}"
      else
        command cp "${QAM_ONELAKE_MOCK_EDGES}" "${output_file}"
      fi
      if [[ "${url}" != *'/_temporary/'* ]]; then printf 'GET_FINAL edges\n' >> "${QAM_ONELAKE_MOCK_LOG}"; fi
      printf '200'
      ;;
    DELETE:*)
      printf 'DELETE temporary url=%s\n' "${url}" >> "${QAM_ONELAKE_MOCK_LOG}"
      printf '200'
      ;;
    HEAD:*) printf '200' ;;
    *)
      printf 'UNHANDLED request=%s url=%s file_create=%s\n' \
        "${request}" "${url}" "${file_create}" >> "${QAM_ONELAKE_MOCK_LOG}"
      printf '500'
      ;;
  esac
}
export -f az curl
export QAM_ONELAKE_MOCK_LOG="${onelake_mock_log}"
export QAM_ONELAKE_MOCK_NODES="${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-nodes.ndjson"
export QAM_ONELAKE_MOCK_EDGES="${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-edges.ndjson"
export QAM_ONELAKE_MOCK_MODE='partial'
expect_failure "partial OneLake temporary upload" \
  "${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ONELAKE_MOCK_NODES}" \
  --edges-file "${QAM_ONELAKE_MOCK_EDGES}"
if grep -q '^RENAME ' "${onelake_mock_log}"; then
  qam_fail "OneLake publisher exposed a final path after a partial temporary upload"
fi
grep -q '^DELETE temporary ' "${onelake_mock_log}" \
  || qam_fail "OneLake publisher did not clean up a partial temporary upload"

: > "${onelake_mock_log}"
export QAM_ONELAKE_MOCK_MODE='success'
retry_contract="$("${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ONELAKE_MOCK_NODES}" \
  --edges-file "${QAM_ONELAKE_MOCK_EDGES}")"
jq -e '.publishResult == "created" and (.nodesSha256 | test("^[0-9a-f]{64}$")) and (.edgesSha256 | test("^[0-9a-f]{64}$"))' \
  <<< "${retry_contract}" >/dev/null || qam_fail "OneLake retry did not publish the verified temporary directory"
grep -q '^RENAME conditional=true ' "${onelake_mock_log}" \
  || qam_fail "OneLake final rename omitted If-None-Match: *"
if grep -Eq '^FILE_CREATE .*qam-staging/[0-9a-f]{64}/[0-9a-f]{40,64}/' "${onelake_mock_log}"; then
  qam_fail "OneLake publisher wrote a file directly below the final immutable path"
fi

: > "${onelake_mock_log}"
export QAM_ONELAKE_MOCK_EDGES="${empty_edges_file}"
zero_edge_contract="$("${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ONELAKE_MOCK_NODES}" \
  --edges-file "${QAM_ONELAKE_MOCK_EDGES}")"
jq -e '.publishResult == "created" and (.edgesSha256 | test("^[0-9a-f]{64}$"))' \
  <<< "${zero_edge_contract}" >/dev/null || qam_fail "zero-edge OneLake publication was not verified"
if grep -q '^APPEND edges$' "${onelake_mock_log}"; then
  qam_fail "zero-byte edges.ndjson must be created and flushed without an append request"
fi
export QAM_ONELAKE_MOCK_EDGES="${QAM_ROOT_DIR}/packages/core/test/fixtures/gateway-edges.ndjson"
rm -f "${empty_edges_file}"

: > "${onelake_mock_log}"
export QAM_ONELAKE_MOCK_MODE='existing'
existing_contract="$("${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ONELAKE_MOCK_NODES}" \
  --edges-file "${QAM_ONELAKE_MOCK_EDGES}")"
jq -e '.publishResult == "existing-identical"' <<< "${existing_contract}" >/dev/null \
  || qam_fail "OneLake publisher did not accept a byte-identical existing target"
if ! grep -q '^GET_FINAL nodes$' "${onelake_mock_log}" \
  || ! grep -q '^GET_FINAL edges$' "${onelake_mock_log}"; then
  qam_fail "OneLake publisher did not verify both existing final artifacts"
fi

: > "${onelake_mock_log}"
export QAM_ONELAKE_MOCK_MODE='mismatch'
expect_failure "different existing OneLake target" \
  "${QAM_SCRIPTS_DIR}/publish-projection-onelake.sh" \
  --workspace-id 11111111-1111-4111-8111-111111111111 \
  --lakehouse-id 22222222-2222-4222-8222-222222222222 \
  --nodes-file "${QAM_ONELAKE_MOCK_NODES}" \
  --edges-file "${QAM_ONELAKE_MOCK_EDGES}"
unset -f az curl
unset QAM_ONELAKE_MOCK_LOG QAM_ONELAKE_MOCK_NODES QAM_ONELAKE_MOCK_EDGES QAM_ONELAKE_MOCK_MODE
rm -f "${onelake_mock_log}"

expect_failure "empty Entra caller allow-lists" \
  az bicep build-params \
  --file "${QAM_INFRA_DIR}/tests/invalid-empty-authorizers.bicepparam" \
  --outfile "${TMPDIR:-/tmp}/qam-invalid-authorizers.parameters.json"

expect_failure "deployment without Entra caller allow-lists" \
  "${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --image-digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
  --mcp-api-client-id 11111111-1111-4111-8111-111111111111 \
  --fabric-workspace-id 22222222-2222-4222-8222-222222222222 \
  --fabric-graph-model-id 33333333-3333-4333-8333-333333333333 \
  --github-repository example/repository

expect_failure "mixed GitHub App and token credentials" \
  "${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --image-digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
  --mcp-api-client-id 11111111-1111-4111-8111-111111111111 \
  --allowed-client-application-ids 22222222-2222-4222-8222-222222222222 \
  --allowed-principal-ids 33333333-3333-4333-8333-333333333333 \
  --fabric-workspace-id 44444444-4444-4444-8444-444444444444 \
  --fabric-graph-model-id 55555555-5555-4555-8555-555555555555 \
  --github-repository example/repository \
  --github-auth-mode app \
  --github-app-id 1234 \
  --github-installation-id 5678 \
  --github-private-key-secret-uri https://example-vault.vault.azure.net/secrets/github-app-key \
  --github-token-secret-uri https://example-vault.vault.azure.net/secrets/github-token

expect_failure "live GitHub check without immutable content target" \
  "${QAM_SCRIPTS_DIR}/validate-github-access.sh" \
  --repository example/repository \
  --auth-mode none \
  --live

expect_failure "live GitHub check with unsafe content path" \
  "${QAM_SCRIPTS_DIR}/validate-github-access.sh" \
  --repository example/repository \
  --auth-mode none \
  --content-path ../README.md \
  --commit-sha 1111111111111111111111111111111111111111 \
  --live

expect_failure "role-assignment phase with application deployment" \
  "${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --include-role-assignments

expect_failure "role-assignment phase without deployment principal" \
  "${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --skip-app \
  --include-role-assignments

expect_failure "role-assignment what-if with application deployment" \
  "${QAM_SCRIPTS_DIR}/what-if.sh" \
  --resource-group qam-negative-test \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --include-role-assignments

expect_failure "role-assignment what-if without deployment principal" \
  "${QAM_SCRIPTS_DIR}/what-if.sh" \
  --resource-group qam-negative-test \
  --skip-app \
  --include-role-assignments

expect_failure "role-assignment deployment with foundation parameter file" \
  "${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --parameters "${QAM_INFRA_DIR}/main.poc.bicepparam" \
  --skip-app \
  --include-role-assignments

expect_failure "role-assignment what-if with foundation networking switch" \
  "${QAM_SCRIPTS_DIR}/what-if.sh" \
  --resource-group qam-negative-test \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --private \
  --skip-app \
  --include-role-assignments

expect_failure "role-assignment deployment with invalid workload name" \
  "${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --workload 'QAM unsafe' \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --skip-app \
  --include-role-assignments

# Prove with a non-mutating Azure CLI mock that both administrator entry points
# select only admin.bicep and pass no foundation parameter file or switch.
admin_deployment_mock_log="$(mktemp)"
# shellcheck disable=SC2329 # exported into the deployment scripts' Bash processes
az() {
  case "${1:-}:${2:-}:${3:-}" in
    account:show:*) return 0 ;;
    deployment:group:create | deployment:group:what-if)
      printf '%q ' "$@" >> "${QAM_ADMIN_DEPLOYMENT_MOCK_LOG}"
      printf '\n' >> "${QAM_ADMIN_DEPLOYMENT_MOCK_LOG}"
      printf '{}\n'
      ;;
    *) return 1 ;;
  esac
}
export -f az
export QAM_ADMIN_DEPLOYMENT_MOCK_LOG="${admin_deployment_mock_log}"
"${QAM_SCRIPTS_DIR}/deploy.sh" \
  --resource-group qam-negative-test \
  --workload qam \
  --environment test \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --skip-app \
  --include-role-assignments >/dev/null
"${QAM_SCRIPTS_DIR}/what-if.sh" \
  --resource-group qam-negative-test \
  --workload qam \
  --environment test \
  --deployment-principal-id 11111111-1111-4111-8111-111111111111 \
  --skip-app \
  --include-role-assignments >/dev/null
[ "$(wc -l < "${admin_deployment_mock_log}" | tr -d '[:space:]')" -eq 2 ] \
  || qam_fail "administrator script test expected exactly one deploy and one what-if command"
[ "$(grep -Fc -- "--template-file ${QAM_INFRA_DIR}/admin.bicep" "${admin_deployment_mock_log}")" -eq 2 ] \
  || qam_fail "administrator scripts must select only admin.bicep"
if grep -Fq 'main.bicep' "${admin_deployment_mock_log}" \
  || grep -Fq '.bicepparam' "${admin_deployment_mock_log}" \
  || grep -Eq 'deployContainerApp|enablePrivateNetworking|location=' "${admin_deployment_mock_log}"; then
  qam_fail "administrator scripts leaked foundation reconciliation arguments"
fi
[ "$(grep -c 'environmentName=test' "${admin_deployment_mock_log}")" -eq 2 ] \
  && [ "$(grep -c 'workloadName=qam' "${admin_deployment_mock_log}")" -eq 2 ] \
  && [ "$(grep -c 'deploymentPrincipalId=11111111-1111-4111-8111-111111111111' "${admin_deployment_mock_log}")" -eq 2 ] \
  || qam_fail "administrator scripts did not bind the exact environment, workload, and deployment principal"
unset -f az
unset QAM_ADMIN_DEPLOYMENT_MOCK_LOG
rm -f "${admin_deployment_mock_log}"

deploy_workflow="${QAM_REPOSITORY_ROOT}/.github/workflows/qam-deploy.yml"
[ "$(grep -c -- '--include-role-assignments' "${deploy_workflow}")" -eq 1 ] \
  || qam_fail "normal deployment workflow must never opt into the administrator role-assignment phase"
grep -- '--include-role-assignments' "${deploy_workflow}" | grep -q "printf '" \
  || qam_fail "the only workflow role-assignment command must be administrator handoff text"
graph_gate_line="$(grep -n 'Gate application deployment on commit-pinned Fabric Graph GQL' "${deploy_workflow}" | cut -d: -f1)"
image_build_line="$(grep -n 'Build and push immutable image' "${deploy_workflow}" | cut -d: -f1)"
[ -n "${graph_gate_line}" ] && [ -n "${image_build_line}" ] && [ "${graph_gate_line}" -lt "${image_build_line}" ] \
  || qam_fail "commit-pinned Fabric Graph smoke must run before the ACA image build/deploy"
# shellcheck disable=SC2016 # Match the literal workflow runtime variable.
sed -n "${graph_gate_line},$((graph_gate_line + 8))p" "${deploy_workflow}" \
  | grep -q -- '--expected-commit-sha "${GITHUB_SHA}"' \
  || qam_fail "protected deploy workflow must pin the Fabric Graph smoke to GITHUB_SHA"

oidc_bootstrap="${QAM_SCRIPTS_DIR}/bootstrap-github-oidc.sh"
[ "$(grep -c 'az role assignment create' "${oidc_bootstrap}")" -eq 1 ] \
  || qam_fail "GitHub OIDC bootstrap must create exactly one Azure role assignment"
grep -A 6 'az role assignment create' "${oidc_bootstrap}" | grep -q -- "--role 'Contributor'" \
  || qam_fail "GitHub OIDC bootstrap must assign only Contributor"
grep -q 'az role definition list' "${oidc_bootstrap}" \
  || qam_fail "GitHub OIDC bootstrap must resolve effective RoleDefinitions"
grep -qi 'microsoft.authorization/roleassignments/write' "${oidc_bootstrap}" \
  || qam_fail "GitHub OIDC bootstrap must audit roleAssignments/write rather than role names only"
if grep -A 7 'az role assignment list' "${oidc_bootstrap}" | grep -q -- '--all'; then
  qam_fail "GitHub OIDC privilege audit must not combine scoped enumeration with --all"
fi

# Exercise the effective-role audit without Azure mutations. Contributor is safe
# because its NotActions excludes Authorization writes; Owner and an equivalent
# conditioned custom role must fail before handoff IDs are returned.
bootstrap_mock_log="$(mktemp)"
# shellcheck disable=SC2329 # exported into the bootstrap script's Bash process
az() {
  local first="${1:-}"
  local second="${2:-}"
  local third="${3:-}"
  local argument
  local previous=''
  local query=''
  local definition_name=''

  for argument in "$@"; do
    case "${previous}" in
      --query) query="${argument}" ;;
      --name) definition_name="${argument}" ;;
    esac
    previous="${argument}"
  done

  case "${first}:${second}:${third}" in
    account:show:*)
      if [ "${query}" = 'tenantId' ]; then printf '%s\n' '22222222-2222-4222-8222-222222222222'; fi
      ;;
    account:set:*) ;;
    group:create:*) ;;
    group:show:*)
      if [ "${query}" = 'location' ]; then
        printf '%s\n' 'westeurope'
      else
        printf '%s\n' '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/qam-negative-test'
      fi
      ;;
    identity:show:*)
      case "${query}" in
        clientId) printf '%s\n' '33333333-3333-4333-8333-333333333333' ;;
        principalId) printf '%s\n' '44444444-4444-4444-8444-444444444444' ;;
      esac
      ;;
    identity:federated-credential:show)
      printf '%s\n' 'repo:example/repository:environment:qam-dev'
      ;;
    role:assignment:create)
      printf '%q ' "$@" >> "${QAM_BOOTSTRAP_MOCK_LOG}"
      printf '\n' >> "${QAM_BOOTSTRAP_MOCK_LOG}"
      ;;
    role:assignment:list)
      case "${QAM_BOOTSTRAP_MOCK_MODE}" in
        safe)
          printf '%s\n' '[{"id":"/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/qam-negative-test/providers/Microsoft.Authorization/roleAssignments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","principalId":"44444444-4444-4444-8444-444444444444","scope":"/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/qam-negative-test","roleDefinitionId":"/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c","condition":null}]'
          ;;
        owner)
          printf '%s\n' '[{"id":"/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleAssignments/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","principalId":"55555555-5555-4555-8555-555555555555","scope":"/subscriptions/11111111-1111-4111-8111-111111111111","roleDefinitionId":"/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635","condition":null}]'
          ;;
        custom)
          printf '%s\n' '[{"id":"/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/qam-negative-test/providers/Microsoft.Authorization/roleAssignments/cccccccc-cccc-4ccc-8ccc-cccccccccccc","principalId":"44444444-4444-4444-8444-444444444444","scope":"/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/qam-negative-test","roleDefinitionId":"/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/dddddddd-dddd-4ddd-8ddd-dddddddddddd","condition":"@Request[x] StringEquals y"}]'
          ;;
      esac
      ;;
    role:definition:list)
      case "${definition_name}" in
        b24988ac-6180-42a0-ab88-20f7382dd24c)
          printf '%s\n' '[{"roleName":"Contributor","roleType":"BuiltInRole","permissions":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write","Microsoft.Authorization/*/Delete"]}]}]'
          ;;
        8e3af657-a8ff-443c-a75c-2fe8c4bcb635)
          printf '%s\n' '[{"roleName":"Owner","roleType":"BuiltInRole","permissions":[{"actions":["*"],"notActions":[]}]}]'
          ;;
        dddddddd-dddd-4ddd-8ddd-dddddddddddd)
          printf '%s\n' '[{"roleName":"Custom access manager","roleType":"CustomRole","permissions":[{"actions":["Microsoft.Authorization/roleAssignments/*"],"notActions":[]}]}]'
          ;;
        *) return 1 ;;
      esac
      ;;
    role:assignment:delete)
      return 1
      ;;
    *) return 1 ;;
  esac
}
export -f az
export QAM_BOOTSTRAP_MOCK_LOG="${bootstrap_mock_log}"
export QAM_BOOTSTRAP_MOCK_MODE='safe'
bootstrap_safe_output="$("${oidc_bootstrap}" \
  --subscription-id 11111111-1111-4111-8111-111111111111 \
  --resource-group qam-negative-test \
  --github-owner example \
  --github-repository repository \
  --github-environment qam-dev)"
grep -q '^AZURE_PRINCIPAL_ID=44444444-4444-4444-8444-444444444444$' <<< "${bootstrap_safe_output}" \
  || qam_fail "safe Contributor bootstrap did not return the expected principal ID"
grep -q -- "--role Contributor" "${bootstrap_mock_log}" \
  || qam_fail "mocked OIDC bootstrap did not grant Contributor"

export QAM_BOOTSTRAP_MOCK_MODE='owner'
expect_failure "inherited Owner on GitHub OIDC identity" \
  "${oidc_bootstrap}" \
  --subscription-id 11111111-1111-4111-8111-111111111111 \
  --resource-group qam-negative-test \
  --github-owner example \
  --github-repository repository \
  --github-environment qam-dev

export QAM_BOOTSTRAP_MOCK_MODE='custom'
expect_failure "conditioned custom role with roleAssignments/write" \
  "${oidc_bootstrap}" \
  --subscription-id 11111111-1111-4111-8111-111111111111 \
  --resource-group qam-negative-test \
  --github-owner example \
  --github-repository repository \
  --github-environment qam-dev
unset -f az
unset QAM_BOOTSTRAP_MOCK_LOG QAM_BOOTSTRAP_MOCK_MODE
rm -f "${bootstrap_mock_log}"

qam_info "security control tests passed"
