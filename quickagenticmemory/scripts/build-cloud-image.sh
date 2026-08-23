#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

readonly repository_writer_role_id='2a1e307c-b015-4ebd-883e-5b7698a07328'
readonly dockerfile_path='quickagenticmemory/packages/mcp/Dockerfile'

registry_name=''
repository='qam-mcp'
image_tag=''
source_git_url=''
source_ref=''
expected_existing_digest=''
temporary_writer_principal_id=''
temporary_writer_principal_type=''
poll_interval_seconds=5
max_poll_attempts=480
build_timeout_seconds=1800
cleanup_poll_attempts=12

registry_id=''
temporary_assignment_id=''
temporary_assignment_expected_id=''
temporary_assignment_cleanup_required='false'
temporary_assignment_created='false'
temporary_assignment_removed='false'
build_run_id=''
build_terminal_verified='false'
remote_manifest_error=''
submission_error=''

usage() {
  printf '%s\n' \
    'Usage: build-cloud-image.sh --registry NAME --source-git-url URL --source-ref FULL_SHA [options]' \
    '' \
    'Build the MCP image in Azure Container Registry from one exact public GitHub commit.' \
    'The command emits a non-secret JSON receipt to stdout; progress goes to stderr.' \
    '' \
    'Required:' \
    '  --registry NAME                 Lowercase Azure Container Registry name' \
    '  --source-git-url URL            Exact https://github.com/OWNER/REPOSITORY.git URL' \
    '  --source-ref FULL_SHA           Full lowercase 40-character Git commit SHA' \
    '' \
    'Image options:' \
    '  --repository NAME               OCI repository; default: qam-mcp' \
    '  --image-tag TAG                 Immutable tag; default: source commit SHA' \
    '  --expected-existing-digest DIGEST' \
    '                                  Reuse an existing locked tag only after this exact match' \
    '' \
    'Optional short-lived build permission (both values are required together):' \
    '  --temporary-writer-principal-id UUID' \
    '                                  Current Azure CLI caller object ID' \
    '  --temporary-writer-principal-type TYPE' \
    '                                  ServicePrincipal, User, Group, or ForeignGroup' \
    '' \
    'Bounded execution options:' \
    '  --poll-interval-seconds N       0-60; default: 5' \
    '  --max-poll-attempts N           1-720; default: 480' \
    '  --build-timeout-seconds N       60-10800; default: 1800'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry) registry_name="${2:?missing value for $1}"; shift 2 ;;
    --repository) repository="${2:?missing value for $1}"; shift 2 ;;
    --image-tag) image_tag="${2:?missing value for $1}"; shift 2 ;;
    --source-git-url) source_git_url="${2:?missing value for $1}"; shift 2 ;;
    --source-ref) source_ref="${2:?missing value for $1}"; shift 2 ;;
    --expected-existing-digest) expected_existing_digest="${2:?missing value for $1}"; shift 2 ;;
    --temporary-writer-principal-id)
      temporary_writer_principal_id="${2:?missing value for $1}"
      shift 2
      ;;
    --temporary-writer-principal-type)
      temporary_writer_principal_type="${2:?missing value for $1}"
      shift 2
      ;;
    --poll-interval-seconds) poll_interval_seconds="${2:?missing value for $1}"; shift 2 ;;
    --max-poll-attempts) max_poll_attempts="${2:?missing value for $1}"; shift 2 ;;
    --build-timeout-seconds) build_timeout_seconds="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${registry_name}" ] || qam_fail "--registry is required"
[ -n "${source_git_url}" ] || qam_fail "--source-git-url is required"
[ -n "${source_ref}" ] || qam_fail "--source-ref is required"
printf '%s' "${registry_name}" | grep -Eq '^[a-z0-9]{5,50}$' \
  || qam_fail "registry name must be 5-50 lowercase letters or digits"
printf '%s' "${repository}" | grep -Eq '^[a-z0-9]+([._/-][a-z0-9]+)*$' \
  || qam_fail "repository is not a valid lowercase OCI repository name"
printf '%s' "${source_ref}" | grep -Eq '^[0-9a-f]{40}$' \
  || qam_fail "--source-ref must be a full lowercase 40-character Git commit SHA"

if [[ ! "${source_git_url}" =~ ^https://github\.com/([^/]+)/([^/]+)\.git$ ]]; then
  qam_fail "--source-git-url must be exactly https://github.com/OWNER/REPOSITORY.git"
fi
source_owner="${BASH_REMATCH[1]}"
source_repository_name="${BASH_REMATCH[2]}"
source_repository="${source_owner}/${source_repository_name}"
qam_validate_github_repository "${source_repository}" "source GitHub repository"
case "${source_owner}" in
  -* | *- | *..*) qam_fail "source GitHub owner is not canonical" ;;
esac
case "${source_repository_name}" in
  . | .. | .* | *..* | *-) qam_fail "source GitHub repository name is not canonical" ;;
esac

if [ -z "${image_tag}" ]; then
  image_tag="${source_ref}"
fi
qam_validate_image_tag "${image_tag}"
[ "${image_tag}" = "${source_ref}" ] \
  || qam_fail "cloud image tag must equal the exact source commit SHA"
if [ -n "${expected_existing_digest}" ]; then
  qam_validate_image_digest "${expected_existing_digest}" "expected existing image digest"
fi

case "${poll_interval_seconds}" in
  '' | *[!0-9]*) qam_fail "--poll-interval-seconds must be an integer from 0 through 60" ;;
esac
[ "${poll_interval_seconds}" -le 60 ] \
  || qam_fail "--poll-interval-seconds must be an integer from 0 through 60"
case "${max_poll_attempts}" in
  '' | *[!0-9]*) qam_fail "--max-poll-attempts must be an integer from 1 through 720" ;;
esac
[ "${max_poll_attempts}" -ge 1 ] && [ "${max_poll_attempts}" -le 720 ] \
  || qam_fail "--max-poll-attempts must be an integer from 1 through 720"
case "${build_timeout_seconds}" in
  '' | *[!0-9]*) qam_fail "--build-timeout-seconds must be an integer from 60 through 10800" ;;
esac
[ "${build_timeout_seconds}" -ge 60 ] && [ "${build_timeout_seconds}" -le 10800 ] \
  || qam_fail "--build-timeout-seconds must be an integer from 60 through 10800"

if [ -n "${temporary_writer_principal_id}${temporary_writer_principal_type}" ]; then
  [ -n "${temporary_writer_principal_id}" ] \
    && [ -n "${temporary_writer_principal_type}" ] \
    || qam_fail "temporary writer principal ID and type must be supplied together"
  qam_validate_uuid "${temporary_writer_principal_id}" "temporary writer principal ID"
  case "${temporary_writer_principal_type}" in
    ServicePrincipal | User | Group | ForeignGroup) ;;
    *) qam_fail "temporary writer principal type must be ServicePrincipal, User, Group, or ForeignGroup" ;;
  esac
fi

qam_require_azure_login
qam_require_command jq

new_role_assignment_uuid() {
  local variant
  variant=$(((RANDOM & 0x3fff) | 0x8000))
  printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x' \
    "${RANDOM}" "${RANDOM}" "${RANDOM}" "$((RANDOM & 0x0fff))" \
    "${variant}" "${RANDOM}" "${RANDOM}" "${RANDOM}"
}

cleanup_temporary_writer() {
  local assignment_list=''
  local attempt
  local remaining_count=''
  local delete_failed='false'

  [ "${temporary_assignment_cleanup_required}" = 'true' ] || return 0
  qam_info "removing the exact short-lived ACR Repository Writer assignment"
  if ! az role assignment delete \
    --ids "${temporary_assignment_expected_id}" \
    --output none >&2; then
    delete_failed='true'
    qam_info "the exact temporary role-assignment delete returned an error; verifying its final absence"
  fi

  for ((attempt = 1; attempt <= cleanup_poll_attempts; attempt += 1)); do
    if assignment_list="$(az role assignment list \
      --assignee-object-id "${temporary_writer_principal_id}" \
      --scope "${registry_id}" \
      --fill-principal-name false \
      --fill-role-definition-name false \
      --output json 2>/dev/null)" \
      && jq -e 'type == "array"' <<< "${assignment_list}" >/dev/null; then
      remaining_count="$(jq -r \
        --arg expectedId "$(printf '%s' "${temporary_assignment_expected_id}" | tr '[:upper:]' '[:lower:]')" \
        '[.[] | select((.id // "" | ascii_downcase) == $expectedId)] | length' \
        <<< "${assignment_list}")"
      if [ "${remaining_count}" = '0' ]; then
        temporary_assignment_cleanup_required='false'
        temporary_assignment_removed='true'
        qam_info "verified that the exact temporary writer assignment is absent"
        return 0
      fi
    fi
    if [ "${attempt}" -lt "${cleanup_poll_attempts}" ]; then
      sleep "${poll_interval_seconds}"
    fi
  done

  if [ "${delete_failed}" = 'true' ]; then
    qam_info "temporary writer cleanup could not verify absence after a delete error"
  fi
  return 1
}

settle_build_before_writer_cleanup() {
  local settle_attempt
  local settle_json=''
  local settle_status=''

  [ -n "${build_run_id}" ] || return 0
  [ "${build_terminal_verified}" != 'true' ] || return 0
  qam_info "requesting cancellation so the submitted ACR run is terminal before writer cleanup"
  az acr task cancel-run \
    --registry "${registry_name}" \
    --run-id "${build_run_id}" \
    --output none >&2 || true

  for ((settle_attempt = 1; settle_attempt <= cleanup_poll_attempts; settle_attempt += 1)); do
    if settle_json="$(az acr task show-run \
      --registry "${registry_name}" \
      --run-id "${build_run_id}" \
      --output json 2>/dev/null)"; then
      settle_status="$(jq -r \
        --arg runId "${build_run_id}" '
          if (.runId == $runId or .name == $runId) and (.status | type == "string")
          then .status else "" end' \
        <<< "${settle_json}")"
      case "${settle_status}" in
        Succeeded | Failed | Canceled | Error | Timeout)
          build_terminal_verified='true'
          qam_info "verified terminal ACR run status ${settle_status} before writer cleanup"
          return 0
          ;;
      esac
    fi
    if [ "${settle_attempt}" -lt "${cleanup_poll_attempts}" ]; then
      sleep "${poll_interval_seconds}"
    fi
  done
  return 1
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "${remote_manifest_error}" ] && [ -f "${remote_manifest_error}" ]; then
    rm -f "${remote_manifest_error}"
  fi
  if [ -n "${submission_error}" ] && [ -f "${submission_error}" ]; then
    rm -f "${submission_error}"
  fi
  if [ "${temporary_assignment_cleanup_required}" = 'true' ]; then
    if ! settle_build_before_writer_cleanup; then
      qam_info "submitted ACR run could not be proven terminal within the cancellation bound"
      status=1
    fi
    if ! cleanup_temporary_writer; then
      qam_info "failed closed because the exact temporary writer assignment was not proven absent"
      status=1
    fi
  fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

registry_json="$(az acr show --name "${registry_name}" --output json)"
registry_id="$(jq -er '.id | select(type == "string" and length > 0)' <<< "${registry_json}")" \
  || qam_fail "ACR response omitted its resource ID"
jq -e '.loginServer | select(type == "string" and length > 0)' \
  <<< "${registry_json}" >/dev/null \
  || qam_fail "ACR response omitted its login server"
registry_mode="$(jq -er '.roleAssignmentMode | select(type == "string" and length > 0)' <<< "${registry_json}")" \
  || qam_fail "ACR response omitted roleAssignmentMode"
[ "${registry_mode}" = 'AbacRepositoryPermissions' ] \
  || qam_fail "ACR must use AbacRepositoryPermissions for the repository-scoped build contract"
expected_registry_suffix="/providers/Microsoft.ContainerRegistry/registries/${registry_name}"
case "$(printf '%s' "${registry_id}" | tr '[:upper:]' '[:lower:]')" in
  /subscriptions/*/resourcegroups/*"$(printf '%s' "${expected_registry_suffix}" | tr '[:upper:]' '[:lower:]')") ;;
  *) qam_fail "ACR returned an unexpected resource ID" ;;
esac

emit_receipt() {
  local digest="$1"
  local run_status="$2"
  local reused_existing="$3"

  jq -cn \
    --arg contractVersion 'qam-acr-cloud-build/1.0' \
    --arg sourceGitUrl "${source_git_url}" \
    --arg sourceRepository "${source_repository}" \
    --arg sourceCommitSha "${source_ref}" \
    --arg dockerfile "${dockerfile_path}" \
    --arg repository "${repository}" \
    --arg tag "${image_tag}" \
    --arg digest "${digest}" \
    --arg runId "${build_run_id}" \
    --arg runStatus "${run_status}" \
    --argjson reusedExisting "${reused_existing}" \
    --argjson temporaryWriterRequested "$([ -n "${temporary_writer_principal_id}" ] && printf true || printf false)" \
    --argjson temporaryWriterCreated "${temporary_assignment_created}" \
    --argjson temporaryWriterRemoved "${temporary_assignment_removed}" '
      {
        contractVersion: $contractVersion,
        cloudBuild: true,
        source: {
          gitUrl: $sourceGitUrl,
          repository: $sourceRepository,
          commitSha: $sourceCommitSha,
          dockerfile: $dockerfile
        },
        image: {
          repository: $repository,
          tag: $tag,
          digest: $digest,
          writeEnabled: false,
          deleteEnabled: false
        },
        build: {
          runId: (if $runId == "" then null else $runId end),
          status: $runStatus,
          reusedExisting: $reusedExisting
        },
        temporaryWriter: {
          requested: $temporaryWriterRequested,
          selfCreated: $temporaryWriterCreated,
          removed: $temporaryWriterRemoved
        },
        verified: true
      }'
}

if [ -n "${temporary_writer_principal_id}" ]; then
  subscription_id="$(jq -er '.id | capture("^/subscriptions/(?<subscription>[^/]+)/").subscription' \
    <<< "${registry_json}")" || qam_fail "could not derive the ACR subscription"
  qam_validate_uuid "${subscription_id}" "ACR subscription ID"
  writer_role_definition="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${repository_writer_role_id}"
  temporary_assignment_id="$(new_role_assignment_uuid)"
  temporary_assignment_expected_id="${registry_id}/providers/Microsoft.Authorization/roleAssignments/${temporary_assignment_id}"
  temporary_assignment_cleanup_required='true'

  qam_info "creating one exact short-lived ACR Repository Writer assignment"
  assignment_json="$(az role assignment create \
    --name "${temporary_assignment_id}" \
    --assignee-object-id "${temporary_writer_principal_id}" \
    --assignee-principal-type "${temporary_writer_principal_type}" \
    --role "${writer_role_definition}" \
    --scope "${registry_id}" \
    --output json)"
  jq -e \
    --arg expectedId "$(printf '%s' "${temporary_assignment_expected_id}" | tr '[:upper:]' '[:lower:]')" \
    --arg principalId "$(printf '%s' "${temporary_writer_principal_id}" | tr '[:upper:]' '[:lower:]')" \
    --arg principalType "${temporary_writer_principal_type}" \
    --arg scope "$(printf '%s' "${registry_id}" | tr '[:upper:]' '[:lower:]')" \
    --arg roleDefinitionId "$(printf '%s' "${writer_role_definition}" | tr '[:upper:]' '[:lower:]')" '
      ((.id // "") | ascii_downcase) == $expectedId and
      ((.principalId // "") | ascii_downcase) == $principalId and
      .principalType == $principalType and
      ((.scope // "") | ascii_downcase) == $scope and
      ((.roleDefinitionId // "") | ascii_downcase) == $roleDefinitionId and
      (.condition == null)' \
    <<< "${assignment_json}" >/dev/null \
    || qam_fail "temporary Repository Writer assignment response did not match the exact requested contract"
  temporary_assignment_created='true'
fi

remote_manifest=''
remote_manifest_error="$(mktemp)"
remote_manifest_found='false'
remote_manifest_absent='false'
tag_probe_attempt=1
tag_probe_attempts=3
[ "${temporary_assignment_created}" != 'true' ] || tag_probe_attempts=12
while [ "${tag_probe_attempt}" -le "${tag_probe_attempts}" ]; do
  : > "${remote_manifest_error}"
  if remote_manifest="$(az acr repository show \
    --name "${registry_name}" \
    --image "${repository}:${image_tag}" \
    --output json 2>"${remote_manifest_error}")"; then
    jq -e 'type == "object" and (.digest | type == "string" and length > 0)' \
      <<< "${remote_manifest}" >/dev/null \
      || qam_fail "existing ACR image lookup returned a malformed response"
    remote_manifest_found='true'
    break
  fi
  if grep -Eiq \
    'manifest_unknown|manifest unknown|manifest[^[:cntrl:]]*not found|not found[^[:cntrl:]]*manifest|specified tag does not exist' \
    "${remote_manifest_error}"; then
    remote_manifest_absent='true'
    break
  fi
  if [ "${tag_probe_attempt}" -lt "${tag_probe_attempts}" ]; then
    qam_info "ACR tag lookup is not yet authorized or available; retrying within bounds"
    sleep "${poll_interval_seconds}"
  fi
  tag_probe_attempt=$((tag_probe_attempt + 1))
done
rm -f "${remote_manifest_error}"
remote_manifest_error=''
[ "${remote_manifest_found}" = 'true' ] || [ "${remote_manifest_absent}" = 'true' ] \
  || qam_fail "could not prove whether the target ACR tag already exists"

if [ "${remote_manifest_found}" = 'true' ]; then
  remote_digest="$(jq -er '.digest' <<< "${remote_manifest}")" \
    || qam_fail "existing ACR image lookup omitted its digest"
  qam_validate_image_digest "${remote_digest}" "existing ACR image digest"
  [ -n "${expected_existing_digest}" ] \
    || qam_fail "tag ${image_tag} already exists; pass --expected-existing-digest only after verifying its provenance"
  [ "${remote_digest}" = "${expected_existing_digest}" ] \
    || qam_fail "existing tag digest does not match --expected-existing-digest"
  [ "$(jq -r '.changeableAttributes.writeEnabled? == false' <<< "${remote_manifest}")" = 'true' ] \
    || qam_fail "existing image is not locked against writes"
  [ "$(jq -r '.changeableAttributes.deleteEnabled? == false' <<< "${remote_manifest}")" = 'true' ] \
    || qam_fail "existing image is not locked against deletion"
  if [ "${temporary_assignment_cleanup_required}" = 'true' ]; then
    cleanup_temporary_writer \
      || qam_fail "could not remove and verify the exact temporary writer assignment"
  fi
  qam_info "verified the explicitly approved existing immutable image"
  emit_receipt "${remote_digest}" 'Succeeded' 'true'
  exit 0
fi

source_context="${source_git_url}#${source_ref}"
qam_info "queuing an ACR remote build from the exact public Git commit"
submission_error="$(mktemp)"
if ! submission_json="$(az acr build \
  --registry "${registry_name}" \
  --image "${repository}:${image_tag}" \
  --file "${dockerfile_path}" \
  --platform linux/amd64 \
  --timeout "${build_timeout_seconds}" \
  --source-acr-auth-id '[caller]' \
  --no-logs \
  --no-wait \
  --output json \
  "${source_context}" 2>"${submission_error}")"; then
  sed -n '1,20p' "${submission_error}" >&2
  qam_fail "ACR cloud-build submission failed"
fi
sed -n '1,20p' "${submission_error}" >&2
build_run_id="$(jq -er '.runId | select(type == "string" and length > 0)' \
  <<< "${submission_json}" 2>/dev/null || true)"
if [ -z "${build_run_id}" ]; then
  queued_run_ids="$(sed -nE \
    's/^WARNING: Queued a build with ID: ([A-Za-z0-9][A-Za-z0-9._-]{0,127})\.?$/\1/p' \
    "${submission_error}" | sort -u)"
  [ "$(printf '%s\n' "${queued_run_ids}" | sed '/^$/d' | wc -l | tr -d ' ')" = '1' ] \
    || qam_fail "ACR build submission omitted one unambiguous run ID"
  build_run_id="${queued_run_ids}"
fi
rm -f "${submission_error}"
submission_error=''
printf '%s' "${build_run_id}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' \
  || qam_fail "ACR build returned an invalid run ID"

run_json=''
run_status=''
poll_attempt=1
while [ "${poll_attempt}" -le "${max_poll_attempts}" ]; do
  run_json="$(az acr task show-run \
    --registry "${registry_name}" \
    --run-id "${build_run_id}" \
    --output json)"
  jq -e --arg runId "${build_run_id}" \
    '(.runId == $runId or .name == $runId) and (.status | type == "string" and length > 0)' \
    <<< "${run_json}" >/dev/null \
    || qam_fail "ACR run status response did not match the submitted run"
  run_status="$(jq -r '.status' <<< "${run_json}")"
  case "${run_status}" in
    Succeeded)
      build_terminal_verified='true'
      break
      ;;
    Failed | Canceled | Error | Timeout)
      build_terminal_verified='true'
      qam_fail "ACR cloud build ${build_run_id} reached terminal status ${run_status}"
      ;;
    Queued | Started | Running)
      if [ "${poll_attempt}" -lt "${max_poll_attempts}" ]; then
        sleep "${poll_interval_seconds}"
      fi
      ;;
    *) qam_fail "ACR cloud build returned unknown status ${run_status}" ;;
  esac
  poll_attempt=$((poll_attempt + 1))
done

if [ "${run_status}" != 'Succeeded' ]; then
  qam_info "polling bound reached; requesting cancellation before permission cleanup"
  az acr task cancel-run \
    --registry "${registry_name}" \
    --run-id "${build_run_id}" \
    --output none >&2 \
    || qam_fail "could not cancel the non-terminal ACR build after bounded polling"
  cancel_attempt=1
  while [ "${cancel_attempt}" -le "${cleanup_poll_attempts}" ]; do
    run_json="$(az acr task show-run \
      --registry "${registry_name}" \
      --run-id "${build_run_id}" \
      --output json)"
    run_status="$(jq -er --arg runId "${build_run_id}" \
      'select((.runId == $runId or .name == $runId) and (.status | type == "string" and length > 0)) | .status' \
      <<< "${run_json}")" || qam_fail "canceled ACR run returned a malformed status response"
    case "${run_status}" in
      Succeeded | Failed | Canceled | Error | Timeout)
        build_terminal_verified='true'
        break
        ;;
      Queued | Started | Running) ;;
      *) qam_fail "canceled ACR build returned unknown status ${run_status}" ;;
    esac
    if [ "${cancel_attempt}" -lt "${cleanup_poll_attempts}" ]; then
      sleep "${poll_interval_seconds}"
    fi
    cancel_attempt=$((cancel_attempt + 1))
  done
  case "${run_status}" in
    Succeeded | Failed | Canceled | Error | Timeout)
      qam_fail "ACR build did not succeed within the bounded polling window; terminal status ${run_status}"
      ;;
    *) qam_fail "ACR build remained non-terminal after bounded cancellation" ;;
  esac
fi

run_digest="$(jq -er \
  --arg repository "${repository}" \
  --arg tag "${image_tag}" '
    [.outputImages[]? | select(.repository == $repository and .tag == $tag)]
    | select(length == 1) | .[0].digest' \
  <<< "${run_json}")" || qam_fail "successful ACR run did not emit exactly one expected output image"
qam_validate_image_digest "${run_digest}" "ACR run output image digest"

published_manifest="$(az acr repository show \
  --name "${registry_name}" \
  --image "${repository}:${image_tag}" \
  --output json)"
published_digest="$(jq -er '.digest' <<< "${published_manifest}")" \
  || qam_fail "published ACR manifest omitted its digest"
qam_validate_image_digest "${published_digest}" "published ACR image digest"
[ "${published_digest}" = "${run_digest}" ] \
  || qam_fail "published tag digest does not match the successful ACR run output"

qam_info "locking the exact built manifest against writes and deletion"
az acr repository update \
  --name "${registry_name}" \
  --image "${repository}@${published_digest}" \
  --delete-enabled false \
  --write-enabled false \
  --output none >&2

locked_manifest="$(az acr repository show \
  --name "${registry_name}" \
  --image "${repository}:${image_tag}" \
  --output json)"
jq -e --arg digest "${published_digest}" '
  .digest == $digest and
  .changeableAttributes.writeEnabled == false and
  .changeableAttributes.deleteEnabled == false' \
  <<< "${locked_manifest}" >/dev/null \
  || qam_fail "ACR did not preserve the exact digest with write/delete locks"

if [ "${temporary_assignment_cleanup_required}" = 'true' ]; then
  cleanup_temporary_writer \
    || qam_fail "could not remove and verify the exact temporary writer assignment"
fi

emit_receipt "${published_digest}" 'Succeeded' 'false'
