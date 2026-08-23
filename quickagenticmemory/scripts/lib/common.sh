#!/usr/bin/env bash

set -Eeuo pipefail

# These globals are intentionally consumed by scripts that source this file.
# shellcheck disable=SC2034
QAM_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QAM_ROOT_DIR="$(cd "${QAM_SCRIPTS_DIR}/.." && pwd)"
# shellcheck disable=SC2034
QAM_REPOSITORY_ROOT="$(cd "${QAM_ROOT_DIR}/.." && pwd)"
# shellcheck disable=SC2034
QAM_INFRA_DIR="${QAM_ROOT_DIR}/infra"

qam_info() {
  printf 'qam: %s\n' "$*" >&2
}

qam_fail() {
  printf 'qam: error: %s\n' "$*" >&2
  exit 1
}

qam_require_command() {
  command -v "$1" >/dev/null 2>&1 || qam_fail "required command not found: $1"
}

qam_require_azure_login() {
  qam_require_command az
  az account show --output none >/dev/null 2>&1 || qam_fail "Azure CLI is not signed in"
}

qam_validate_environment() {
  case "$1" in
    dev | test | prod) ;;
    *) qam_fail "environment must be dev, test, or prod" ;;
  esac
}

qam_validate_workload_name() {
  printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{1,9}$' \
    || qam_fail "$2 must be 2-10 lowercase letters, digits, or hyphens and start with a letter"
  case "$1" in
    *--* | *-) qam_fail "$2 must not contain consecutive hyphens or end with a hyphen" ;;
  esac
}

qam_validate_uuid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
    || qam_fail "$2 must be a UUID"
}

qam_validate_image_tag() {
  [ -n "$1" ] || qam_fail "image tag must not be empty"
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" != "latest" ] \
    || qam_fail "the mutable image tag 'latest' is not allowed"
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' \
    || qam_fail "image tag is not a valid OCI tag"
}

qam_validate_image_digest() {
  printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$' \
    || qam_fail "$2 must be a lowercase sha256 OCI digest"
}

qam_validate_uuid_csv() {
  local value="$1"
  local label="$2"
  local item
  local -a items

  [ -n "${value}" ] || qam_fail "${label} must contain at least one UUID"
  IFS=',' read -r -a items <<< "${value}"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "${item}" ] || qam_fail "${label} contains an empty value"
    qam_validate_uuid "${item}" "${label} entry"
  done
}

qam_uuid_csv_to_json() {
  local value="$1"

  qam_require_command jq
  jq -cn --arg csv "${value}" \
    '$csv | split(",") | map(gsub("^\\s+|\\s+$"; ""))'
}

qam_validate_github_repository() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || qam_fail "$2 must use owner/repository form"
  case "$1" in
    *.git) qam_fail "$2 must omit the .git suffix" ;;
  esac
}

qam_validate_versionless_key_vault_secret_uri() {
  printf '%s' "$1" | grep -Eq '^https://[a-zA-Z0-9-]+\.vault\.azure\.net/secrets/[A-Za-z0-9-]+/?$' \
    || qam_fail "$2 must be a versionless Azure Key Vault secret URI"
}

qam_validate_github_auth() {
  local mode="$1"
  local app_id="$2"
  local installation_id="$3"
  local private_key_secret_uri="$4"
  local token_secret_uri="$5"

  case "${mode}" in
    app)
      printf '%s' "${app_id}" | grep -Eq '^[1-9][0-9]*$' \
        || qam_fail "GitHub App ID must be a positive decimal integer in app mode"
      printf '%s' "${installation_id}" | grep -Eq '^[1-9][0-9]*$' \
        || qam_fail "GitHub installation ID must be a positive decimal integer in app mode"
      [ -n "${private_key_secret_uri}" ] \
        || qam_fail "GitHub private-key secret URI is required in app mode"
      qam_validate_versionless_key_vault_secret_uri \
        "${private_key_secret_uri}" "GitHub private-key secret URI"
      [ -z "${token_secret_uri}" ] \
        || qam_fail "GitHub token secret URI must be empty in app mode"
      ;;
    token)
      [ -n "${token_secret_uri}" ] \
        || qam_fail "GitHub token secret URI is required in token mode"
      qam_validate_versionless_key_vault_secret_uri \
        "${token_secret_uri}" "GitHub token secret URI"
      [ -z "${app_id}${installation_id}${private_key_secret_uri}" ] \
        || qam_fail "GitHub App fields must be empty in token mode"
      ;;
    none)
      [ -z "${app_id}${installation_id}${private_key_secret_uri}${token_secret_uri}" ] \
        || qam_fail "GitHub credential fields must be empty in none mode"
      ;;
    *) qam_fail "GitHub authentication mode must be app, token, or none" ;;
  esac
}

qam_validate_github_origins() {
  local api_url="$1"
  local web_url="$2"
  local api_host
  local web_host

  if [ "${api_url}" = "https://api.github.com" ] && [ "${web_url}" = "https://github.com" ]; then
    return
  fi
  if [[ ! "${api_url}" =~ ^https://([A-Za-z0-9.-]+(:[0-9]+)?)/api/v3$ ]]; then
    qam_fail "GHES API URL must be https://HOST[:PORT]/api/v3"
  fi
  api_host="${BASH_REMATCH[1]}"
  if [[ ! "${web_url}" =~ ^https://([A-Za-z0-9.-]+(:[0-9]+)?)$ ]]; then
    qam_fail "GHES web URL must be the HTTPS origin without a path"
  fi
  web_host="${BASH_REMATCH[1]}"
  [ "$(printf '%s' "${api_host}" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "${web_host}" | tr '[:upper:]' '[:lower:]')" ] \
    || qam_fail "GHES API and web URLs must use the same origin"
}

qam_validate_fabric_api_url() {
  case "${1%/}" in
    https://api.fabric.microsoft.com) ;;
    *) qam_fail "Fabric API URL is fixed to https://api.fabric.microsoft.com" ;;
  esac
}

qam_validate_fabric_operation_url() {
  local operation_id

  printf '%s' "$1" | grep -Eq '^https://api\.fabric\.microsoft\.com/v1/operations/[0-9a-fA-F-]{36}$' \
    || qam_fail "Fabric operation Location must be an HTTPS api.fabric.microsoft.com /v1/operations/{uuid} URL"

  operation_id="${1##*/}"
  qam_validate_uuid "${operation_id}" "Fabric operation ID"
}

qam_validate_fabric_notebook_job_url() {
  local url="$1"
  local workspace_id="$2"
  local notebook_id="$3"
  local job_id

  printf '%s' "${url}" \
    | grep -Eq "^https://api\\.fabric\\.microsoft\\.com/v1/workspaces/${workspace_id}/items/${notebook_id}/jobs/instances/[0-9a-fA-F-]{36}$" \
    || qam_fail "Notebook Location must stay on the expected HTTPS workspace/item job endpoint"
  job_id="${url##*/}"
  qam_validate_uuid "${job_id}" "Fabric Notebook job instance ID"
}

qam_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes) printf 'true' ;;
    false | 0 | no) printf 'false' ;;
    *) qam_fail "$2 must be true or false" ;;
  esac
}
