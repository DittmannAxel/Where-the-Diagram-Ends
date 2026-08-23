#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

registry_name=""
repository="qam-mcp"
image_tag="${QAM_IMAGE_TAG:-}"
lock_manifest="true"
expected_existing_digest=""

usage() {
  printf '%s\n' \
    'Usage: build-push-image.sh --registry NAME --image-tag TAG [options]' \
    '' \
    'Options:' \
    '  --repository NAME   Default: qam-mcp' \
    '  --expected-existing-digest sha256:HEX' \
    '                      Reuse an existing locked tag only after an explicit digest match' \
    '  --no-lock           Do not lock the pushed manifest against mutation/deletion'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry) registry_name="${2:?missing value for $1}"; shift 2 ;;
    --repository) repository="${2:?missing value for $1}"; shift 2 ;;
    --image-tag) image_tag="${2:?missing value for $1}"; shift 2 ;;
    --expected-existing-digest) expected_existing_digest="${2:?missing value for $1}"; shift 2 ;;
    --no-lock) lock_manifest="false"; shift ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${registry_name}" ] || qam_fail "--registry is required"
qam_validate_image_tag "${image_tag}"
if [ -n "${expected_existing_digest}" ]; then
  qam_validate_image_digest "${expected_existing_digest}" "expected existing image digest"
fi
printf '%s' "${repository}" | grep -Eq '^[a-z0-9]+([._/-][a-z0-9]+)*$' \
  || qam_fail "repository is not a valid lowercase OCI repository name"
qam_require_azure_login
qam_require_command docker
qam_require_command jq

dockerfile="${QAM_ROOT_DIR}/packages/mcp/Dockerfile"
[ -f "${dockerfile}" ] || qam_fail "Dockerfile not found: ${dockerfile}"
login_server="$(az acr show --name "${registry_name}" --query loginServer --output tsv)"
image="${login_server}/${repository}:${image_tag}"
remote_manifest="$(az acr repository show \
  --name "${registry_name}" \
  --image "${repository}:${image_tag}" \
  --output json 2>/dev/null || true)"
remote_digest="$(jq -r '.digest // empty' <<< "${remote_manifest:-{}}")"

if [ -n "${remote_digest}" ]; then
  qam_validate_image_digest "${remote_digest}" "existing ACR image digest"
  [ -n "${expected_existing_digest}" ] \
    || qam_fail "tag ${image_tag} already exists; pass --expected-existing-digest only after verifying its provenance"
  [ "${remote_digest}" = "${expected_existing_digest}" ] \
    || qam_fail "existing tag digest does not match --expected-existing-digest"
  [ "$(jq -r '.changeableAttributes.writeEnabled // true' <<< "${remote_manifest}")" = "false" ] \
    || qam_fail "existing image is not locked against writes"
  [ "$(jq -r '.changeableAttributes.deleteEnabled // true' <<< "${remote_manifest}")" = "false" ] \
    || qam_fail "existing image is not locked against deletion"
  qam_info "verified existing immutable image ${login_server}/${repository}@${remote_digest}"
  printf '%s\n' "${remote_digest}"
  exit 0
fi

qam_info "signing Docker into ${registry_name} with the current Azure identity"
login_attempt=1
until az acr login --name "${registry_name}" --output none >&2; do
  [ "${login_attempt}" -lt 6 ] || qam_fail "could not sign Docker into ${registry_name}"
  qam_info "ACR role assignment may still be propagating; retrying"
  sleep 10
  login_attempt=$((login_attempt + 1))
done

qam_info "building ${image} from the repository root"
docker build \
  --pull \
  --file "${dockerfile}" \
  --tag "${image}" \
  "${QAM_REPOSITORY_ROOT}" >&2

qam_info "pushing ${image}"
docker push "${image}" >&2

image_digest="$(az acr repository show \
  --name "${registry_name}" \
  --image "${repository}:${image_tag}" \
  --query digest \
  --output tsv)"
qam_validate_image_digest "${image_digest}" "pushed ACR image digest"

if [ "${lock_manifest}" = "true" ]; then
  qam_info "locking the immutable manifest"
  az acr repository update \
    --name "${registry_name}" \
    --image "${repository}:${image_tag}" \
    --delete-enabled false \
    --write-enabled false \
    --output none >&2
fi

printf '%s\n' "${image_digest}"
