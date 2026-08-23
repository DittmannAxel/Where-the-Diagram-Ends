#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

build_script="${QAM_SCRIPTS_DIR}/build-cloud-image.sh"
source_sha='1111111111111111111111111111111111111111'
source_url='https://github.com/example/repository.git'
image_digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
other_digest='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
principal_id='22222222-2222-4222-8222-222222222222'
subscription_id='33333333-3333-4333-8333-333333333333'
registry_id="/subscriptions/${subscription_id}/resourceGroups/qam-test/providers/Microsoft.ContainerRegistry/registries/qamtest123"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mock_bin="${test_dir}/bin"
mkdir -p "${mock_bin}"

cat > "${mock_bin}/az" <<'MOCK_AZ'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%q ' "$@" >> "${QAM_CLOUD_BUILD_LOG:?}"
printf '\n' >> "${QAM_CLOUD_BUILD_LOG}"

argument=''
previous=''
name=''
image=''
run_id=''
role=''
scope=''
principal_id=''
principal_type=''
for argument in "$@"; do
  case "${previous}" in
    --name) name="${argument}" ;;
    --image) image="${argument}" ;;
    --run-id) run_id="${argument}" ;;
    --role) role="${argument}" ;;
    --scope) scope="${argument}" ;;
    --assignee-object-id) principal_id="${argument}" ;;
    --assignee-principal-type) principal_type="${argument}" ;;
  esac
  previous="${argument}"
done

case "${1:-}:${2:-}:${3:-}" in
  account:show:*) exit 0 ;;
  acr:show:*)
    jq -cn \
      --arg id "${QAM_CLOUD_BUILD_REGISTRY_ID:?}" \
      '{id: $id, name: "qamtest123", loginServer: "qamtest123.azurecr.io", roleAssignmentMode: "AbacRepositoryPermissions"}'
    ;;
  acr:repository:show)
    case "${QAM_CLOUD_BUILD_SCENARIO:?}" in
      existing | existing-mismatch)
        jq -cn \
          --arg digest "${QAM_CLOUD_BUILD_DIGEST:?}" \
          '{digest: $digest, changeableAttributes: {writeEnabled: false, deleteEnabled: false}}'
        ;;
      existing-unlocked)
        jq -cn \
          --arg digest "${QAM_CLOUD_BUILD_DIGEST:?}" \
          '{digest: $digest, changeableAttributes: {writeEnabled: true, deleteEnabled: false}}'
        ;;
      *)
        if [ "${QAM_CLOUD_BUILD_SCENARIO:?}" = 'tag-lookup-error' ]; then
          printf '%s\n' 'ERROR: authentication required' >&2
          exit 1
        fi
        repository_show_count=0
        if [ -f "${QAM_CLOUD_BUILD_SHOW_COUNT_FILE:?}" ]; then
          repository_show_count="$(< "${QAM_CLOUD_BUILD_SHOW_COUNT_FILE}")"
        fi
        repository_show_count=$((repository_show_count + 1))
        printf '%s\n' "${repository_show_count}" > "${QAM_CLOUD_BUILD_SHOW_COUNT_FILE}"
        if [ "${repository_show_count}" -eq 1 ]; then
          printf '%s\n' 'ERROR: manifest unknown' >&2
          exit 3
        fi
        write_enabled=true
        delete_enabled=true
        if [ -f "${QAM_CLOUD_BUILD_LOCK_FILE:?}" ]; then
          write_enabled=false
          delete_enabled=false
        fi
        jq -cn \
          --arg digest "${QAM_CLOUD_BUILD_DIGEST:?}" \
          --argjson writeEnabled "${write_enabled}" \
          --argjson deleteEnabled "${delete_enabled}" \
          '{digest: $digest, changeableAttributes: {writeEnabled: $writeEnabled, deleteEnabled: $deleteEnabled}}'
        ;;
    esac
    ;;
  acr:repository:update)
    [ "${image}" = "qam-mcp@${QAM_CLOUD_BUILD_DIGEST:?}" ] || exit 81
    touch "${QAM_CLOUD_BUILD_LOCK_FILE:?}"
    ;;
  acr:build:*)
    [ "${@: -1}" = "${QAM_CLOUD_BUILD_SOURCE_URL:?}#${QAM_CLOUD_BUILD_SOURCE_SHA:?}" ] || exit 82
    printf '%s\n' '{"runId":"dt-test","status":"Queued"}'
    ;;
  acr:task:show-run)
    [ "${run_id}" = 'dt-test' ] || exit 83
    run_count=0
    if [ -f "${QAM_CLOUD_BUILD_RUN_COUNT_FILE:?}" ]; then
      run_count="$(< "${QAM_CLOUD_BUILD_RUN_COUNT_FILE}")"
    fi
    run_count=$((run_count + 1))
    printf '%s\n' "${run_count}" > "${QAM_CLOUD_BUILD_RUN_COUNT_FILE}"
    status='Succeeded'
    output_digest="${QAM_CLOUD_BUILD_DIGEST:?}"
    output_repository='qam-mcp'
    case "${QAM_CLOUD_BUILD_SCENARIO:?}" in
      success | temporary-success | cleanup-stuck)
        [ "${run_count}" -gt 1 ] || status='Running'
        ;;
      terminal-failure) status='Failed' ;;
      timeout-cancel)
        if [ -f "${QAM_CLOUD_BUILD_CANCEL_FILE:?}" ]; then status='Canceled'; else status='Running'; fi
        ;;
      malformed-run)
        if [ -f "${QAM_CLOUD_BUILD_CANCEL_FILE:?}" ]; then
          status='Canceled'
        else
          printf 'STATUS Malformed\n' >> "${QAM_CLOUD_BUILD_LOG}"
          printf '%s\n' '{"runId":"wrong-run","status":"Running"}'
          exit 0
        fi
        ;;
      output-mismatch) output_digest="${QAM_CLOUD_BUILD_OTHER_DIGEST:?}" ;;
      malformed-role) status='Succeeded' ;;
    esac
    printf 'STATUS %s\n' "${status}" >> "${QAM_CLOUD_BUILD_LOG}"
    jq -cn \
      --arg runId 'dt-test' \
      --arg status "${status}" \
      --arg digest "${output_digest}" \
      --arg repository "${output_repository}" \
      --arg tag "${QAM_CLOUD_BUILD_SOURCE_SHA:?}" \
      '{runId: $runId, status: $status, outputImages: [{digest: $digest, repository: $repository, tag: $tag}]}'
    ;;
  acr:task:cancel-run)
    touch "${QAM_CLOUD_BUILD_CANCEL_FILE:?}"
    ;;
  role:assignment:create)
    printf '%s\n' "${name}" > "${QAM_CLOUD_BUILD_ASSIGNMENT_NAME_FILE:?}"
    assignment_id="${QAM_CLOUD_BUILD_REGISTRY_ID:?}/providers/Microsoft.Authorization/roleAssignments/${name}"
    if [ "${QAM_CLOUD_BUILD_SCENARIO:?}" = 'malformed-role' ]; then
      principal_type='Group'
    fi
    jq -cn \
      --arg id "${assignment_id}" \
      --arg principalId "${principal_id}" \
      --arg principalType "${principal_type}" \
      --arg scope "${scope}" \
      --arg roleDefinitionId "${role}" \
      '{id: $id, principalId: $principalId, principalType: $principalType, scope: $scope, roleDefinitionId: $roleDefinitionId, condition: null}'
    ;;
  role:assignment:delete)
    touch "${QAM_CLOUD_BUILD_DELETE_FILE:?}"
    ;;
  role:assignment:list)
    if [ "${QAM_CLOUD_BUILD_SCENARIO:?}" = 'cleanup-stuck' ]; then
      assignment_name="$(< "${QAM_CLOUD_BUILD_ASSIGNMENT_NAME_FILE:?}")"
      jq -cn \
        --arg id "${QAM_CLOUD_BUILD_REGISTRY_ID:?}/providers/Microsoft.Authorization/roleAssignments/${assignment_name}" \
        '[{id: $id}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  *)
    printf 'unexpected az command: %s\n' "$*" >&2
    exit 84
    ;;
esac
MOCK_AZ
chmod +x "${mock_bin}/az"

export PATH="${mock_bin}:${PATH}"
export QAM_CLOUD_BUILD_REGISTRY_ID="${registry_id}"
export QAM_CLOUD_BUILD_SOURCE_URL="${source_url}"
export QAM_CLOUD_BUILD_SOURCE_SHA="${source_sha}"
export QAM_CLOUD_BUILD_DIGEST="${image_digest}"
export QAM_CLOUD_BUILD_OTHER_DIGEST="${other_digest}"

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    qam_fail "negative cloud-build test unexpectedly passed: ${label}"
  fi
}

reset_scenario() {
  export QAM_CLOUD_BUILD_SCENARIO="$1"
  export QAM_CLOUD_BUILD_LOG="${test_dir}/$1.log"
  export QAM_CLOUD_BUILD_SHOW_COUNT_FILE="${test_dir}/$1-show-count"
  export QAM_CLOUD_BUILD_RUN_COUNT_FILE="${test_dir}/$1-run-count"
  export QAM_CLOUD_BUILD_LOCK_FILE="${test_dir}/$1-lock"
  export QAM_CLOUD_BUILD_CANCEL_FILE="${test_dir}/$1-cancel"
  export QAM_CLOUD_BUILD_DELETE_FILE="${test_dir}/$1-delete"
  export QAM_CLOUD_BUILD_ASSIGNMENT_NAME_FILE="${test_dir}/$1-assignment-name"
  : > "${QAM_CLOUD_BUILD_LOG}"
  rm -f \
    "${QAM_CLOUD_BUILD_SHOW_COUNT_FILE}" \
    "${QAM_CLOUD_BUILD_RUN_COUNT_FILE}" \
    "${QAM_CLOUD_BUILD_LOCK_FILE}" \
    "${QAM_CLOUD_BUILD_CANCEL_FILE}" \
    "${QAM_CLOUD_BUILD_DELETE_FILE}" \
    "${QAM_CLOUD_BUILD_ASSIGNMENT_NAME_FILE}"
}

base_args=(
  --registry qamtest123
  --source-git-url "${source_url}"
  --source-ref "${source_sha}"
  --poll-interval-seconds 0
  --build-timeout-seconds 60
)

expect_failure 'source URL with embedded credentials' \
  "${build_script}" \
  --registry qamtest123 \
  --source-git-url 'https://user@github.com/example/repository.git' \
  --source-ref "${source_sha}"
expect_failure 'source URL with a branch fragment' \
  "${build_script}" \
  --registry qamtest123 \
  --source-git-url 'https://github.com/example/repository.git#main' \
  --source-ref "${source_sha}"
expect_failure 'abbreviated source commit' \
  "${build_script}" \
  --registry qamtest123 \
  --source-git-url "${source_url}" \
  --source-ref 1111111
expect_failure 'uppercase source commit' \
  "${build_script}" \
  --registry qamtest123 \
  --source-git-url "${source_url}" \
  --source-ref AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
expect_failure 'image tag different from exact source commit' \
  "${build_script}" "${base_args[@]}" \
  --image-tag release-candidate
expect_failure 'temporary writer ID without type' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}"
expect_failure 'unrecognized temporary writer principal type' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type Device

reset_scenario existing
expect_failure 'existing tag without explicit digest' \
  "${build_script}" "${base_args[@]}"
reset_scenario existing-mismatch
expect_failure 'existing tag with a different explicit digest' \
  "${build_script}" "${base_args[@]}" \
  --expected-existing-digest "${other_digest}"
reset_scenario existing-unlocked
expect_failure 'existing matching tag that is still mutable' \
  "${build_script}" "${base_args[@]}" \
  --expected-existing-digest "${image_digest}"

reset_scenario tag-lookup-error
expect_failure 'ACR tag existence lookup authorization error' \
  "${build_script}" "${base_args[@]}"
if grep -q '^acr build ' "${QAM_CLOUD_BUILD_LOG}"; then
  qam_fail 'cloud build proceeded without proving that the target tag was absent'
fi

reset_scenario existing
existing_receipt="$("${build_script}" "${base_args[@]}" \
  --expected-existing-digest "${image_digest}")"
jq -e \
  --arg sourceGitUrl "${source_url}" \
  --arg sourceCommitSha "${source_sha}" \
  --arg digest "${image_digest}" '
    .contractVersion == "qam-acr-cloud-build/1.0" and
    .cloudBuild == true and
    .source.gitUrl == $sourceGitUrl and
    .source.commitSha == $sourceCommitSha and
    .image.digest == $digest and
    .image.writeEnabled == false and
    .image.deleteEnabled == false and
    .build == {runId: null, status: "Succeeded", reusedExisting: true} and
    .temporaryWriter == {requested: false, selfCreated: false, removed: false} and
    .verified == true' \
  <<< "${existing_receipt}" >/dev/null \
  || qam_fail 'existing immutable image receipt did not preserve the exact source/digest contract'
if grep -q '^acr build ' "${QAM_CLOUD_BUILD_LOG}"; then
  qam_fail 'existing immutable image reuse unexpectedly queued a cloud build'
fi

reset_scenario existing
existing_temporary_receipt="$("${build_script}" "${base_args[@]}" \
  --expected-existing-digest "${image_digest}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type User)"
jq -e '.build.reusedExisting == true and .temporaryWriter == {requested: true, selfCreated: true, removed: true}' \
  <<< "${existing_temporary_receipt}" >/dev/null \
  || qam_fail 'existing-tag reuse did not verify its requested temporary writer cleanup'

reset_scenario success
success_receipt="$("${build_script}" "${base_args[@]}")"
jq -e \
  --arg sourceGitUrl "${source_url}" \
  --arg sourceCommitSha "${source_sha}" \
  --arg digest "${image_digest}" '
    .cloudBuild == true and
    .source == {
      gitUrl: $sourceGitUrl,
      repository: "example/repository",
      commitSha: $sourceCommitSha,
      dockerfile: "quickagenticmemory/packages/mcp/Dockerfile"
    } and
    .image.repository == "qam-mcp" and
    .image.tag == $sourceCommitSha and
    .image.digest == $digest and
    .image.writeEnabled == false and
    .image.deleteEnabled == false and
    .build == {runId: "dt-test", status: "Succeeded", reusedExisting: false} and
    .temporaryWriter == {requested: false, selfCreated: false, removed: false} and
    .verified == true' \
  <<< "${success_receipt}" >/dev/null \
  || qam_fail 'successful cloud build did not emit the exact non-secret receipt'
grep -Fq -- "${source_url}#${source_sha}" "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'ACR build did not use the exact public Git URL and full commit SHA'
grep -Fq -- '--no-wait' "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'ACR build must submit asynchronously for bounded status polling'
grep -Fq -- '--file quickagenticmemory/packages/mcp/Dockerfile' "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'ACR build did not pin the reviewed repository-root Dockerfile path'
if grep -Eq '(^|[[:space:]])docker([[:space:]]|$)' "${QAM_CLOUD_BUILD_LOG}"; then
  qam_fail 'cloud build invoked local Docker'
fi

reset_scenario temporary-success
temporary_receipt="$("${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type ServicePrincipal)"
jq -e '
  .build.status == "Succeeded" and
  .temporaryWriter == {requested: true, selfCreated: true, removed: true} and
  .verified == true' \
  <<< "${temporary_receipt}" >/dev/null \
  || qam_fail 'temporary-writer cloud build did not prove its cleanup in the receipt'
grep -Fq -- "--role /subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/2a1e307c-b015-4ebd-883e-5b7698a07328" \
  "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'temporary build permission was not the exact Repository Writer role'
grep -Fq -- "--assignee-principal-type ServicePrincipal" "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'temporary build permission omitted the explicit principal type'
terminal_line="$(grep -n '^STATUS Succeeded$' "${QAM_CLOUD_BUILD_LOG}" | tail -1 | cut -d: -f1)"
delete_line="$(grep -n '^role assignment delete ' "${QAM_CLOUD_BUILD_LOG}" | cut -d: -f1)"
[ -n "${terminal_line}" ] && [ -n "${delete_line}" ] && [ "${terminal_line}" -lt "${delete_line}" ] \
  || qam_fail 'temporary Repository Writer was removed before the ACR run became terminal'
[ -f "${QAM_CLOUD_BUILD_DELETE_FILE}" ] \
  || qam_fail 'temporary Repository Writer cleanup was not attempted'

reset_scenario terminal-failure
expect_failure 'terminal ACR build failure' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type User
[ -f "${QAM_CLOUD_BUILD_DELETE_FILE}" ] \
  || qam_fail 'terminal build failure did not trigger exact role-assignment cleanup'
failure_terminal_line="$(grep -n '^STATUS Failed$' "${QAM_CLOUD_BUILD_LOG}" | tail -1 | cut -d: -f1)"
failure_delete_line="$(grep -n '^role assignment delete ' "${QAM_CLOUD_BUILD_LOG}" | head -1 | cut -d: -f1)"
[ "${failure_terminal_line}" -lt "${failure_delete_line}" ] \
  || qam_fail 'terminal build failure removed the writer assignment too early'

reset_scenario malformed-role
expect_failure 'role-assignment response with changed principal type' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type ServicePrincipal
[ -f "${QAM_CLOUD_BUILD_DELETE_FILE}" ] \
  || qam_fail 'malformed role-assignment response did not trigger exact cleanup'

reset_scenario timeout-cancel
expect_failure 'bounded polling timeout' \
  "${build_script}" "${base_args[@]}" \
  --max-poll-attempts 1 \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type ServicePrincipal
grep -q '^acr task cancel-run ' "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'bounded polling timeout did not cancel the active ACR run'
cancel_terminal_line="$(grep -n '^STATUS Canceled$' "${QAM_CLOUD_BUILD_LOG}" | tail -1 | cut -d: -f1)"
cancel_delete_line="$(grep -n '^role assignment delete ' "${QAM_CLOUD_BUILD_LOG}" | head -1 | cut -d: -f1)"
[ "${cancel_terminal_line}" -lt "${cancel_delete_line}" ] \
  || qam_fail 'poll timeout removed the writer assignment before canceled became terminal'

reset_scenario output-mismatch
expect_failure 'successful run with an unexpected output digest' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type ServicePrincipal
[ -f "${QAM_CLOUD_BUILD_DELETE_FILE}" ] \
  || qam_fail 'output digest mismatch did not trigger exact role-assignment cleanup'

reset_scenario malformed-run
expect_failure 'malformed status for a submitted ACR run' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type ServicePrincipal
grep -q '^acr task cancel-run ' "${QAM_CLOUD_BUILD_LOG}" \
  || qam_fail 'malformed submitted-run response did not trigger bounded cancellation'
malformed_terminal_line="$(grep -n '^STATUS Canceled$' "${QAM_CLOUD_BUILD_LOG}" | tail -1 | cut -d: -f1)"
malformed_delete_line="$(grep -n '^role assignment delete ' "${QAM_CLOUD_BUILD_LOG}" | head -1 | cut -d: -f1)"
[ "${malformed_terminal_line}" -lt "${malformed_delete_line}" ] \
  || qam_fail 'malformed run response removed writer before cancellation became terminal'

reset_scenario cleanup-stuck
expect_failure 'temporary writer still visible after exact deletion' \
  "${build_script}" "${base_args[@]}" \
  --temporary-writer-principal-id "${principal_id}" \
  --temporary-writer-principal-type ServicePrincipal

qam_info 'ACR cloud-build helper tests passed'
