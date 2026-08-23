#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

repository="${QAM_GITHUB_REPOSITORY:-}"
auth_mode="${QAM_GITHUB_AUTH_MODE:-none}"
app_id="${QAM_GITHUB_APP_ID:-}"
installation_id="${QAM_GITHUB_INSTALLATION_ID:-}"
private_key_secret_uri="${QAM_GITHUB_PRIVATE_KEY_SECRET_URI:-}"
token_secret_uri="${QAM_GITHUB_TOKEN_SECRET_URI:-}"
github_api_url="${QAM_GITHUB_API_URL:-https://api.github.com}"
github_web_url="${QAM_GITHUB_WEB_URL:-https://github.com}"
content_path=""
commit_sha=""
live_check="false"
max_content_bytes=1048576

usage() {
  printf '%s\n' \
    'Usage: validate-github-access.sh --repository OWNER/REPO --auth-mode MODE [options]' \
    '' \
    'Options:' \
    '  --app-id DECIMAL_ID' \
    '  --installation-id DECIMAL_ID' \
    '  --private-key-secret-uri VERSIONLESS_KEY_VAULT_URI' \
    '  --token-secret-uri VERSIONLESS_KEY_VAULT_URI' \
    '  --github-api-url URL' \
    '  --github-web-url URL' \
    '  --content-path SAFE.md  Markdown path read by the runtime (required with --live)' \
    '  --commit-sha FULL_SHA   Immutable Git object ID (required with --live)' \
    '  --live   Read the selected Key Vault secret and verify commit-pinned Contents:read' \
    '' \
    'Live app validation requests an installation token restricted to the selected' \
    'repository and Contents:read. Secret and token values are never printed.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository="${2:?missing value for $1}"; shift 2 ;;
    --auth-mode) auth_mode="${2:?missing value for $1}"; shift 2 ;;
    --app-id) app_id="${2:?missing value for $1}"; shift 2 ;;
    --installation-id) installation_id="${2:?missing value for $1}"; shift 2 ;;
    --private-key-secret-uri) private_key_secret_uri="${2:?missing value for $1}"; shift 2 ;;
    --token-secret-uri) token_secret_uri="${2:?missing value for $1}"; shift 2 ;;
    --github-api-url) github_api_url="${2:?missing value for $1}"; shift 2 ;;
    --github-web-url) github_web_url="${2:?missing value for $1}"; shift 2 ;;
    --content-path) content_path="${2:?missing value for $1}"; shift 2 ;;
    --commit-sha) commit_sha="${2:?missing value for $1}"; shift 2 ;;
    --live) live_check="true"; shift ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${repository}" ] || qam_fail "--repository is required"
qam_validate_github_repository "${repository}" "GitHub repository"
qam_validate_github_origins "${github_api_url}" "${github_web_url}"
qam_validate_github_auth \
  "${auth_mode}" "${app_id}" "${installation_id}" \
  "${private_key_secret_uri}" "${token_secret_uri}"

if [ "${live_check}" = "true" ]; then
  printf '%s' "${content_path}" \
    | grep -Eq '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.[mM][dD]$' \
    || qam_fail "--content-path must be a safe repository-relative Markdown path"
  case "/${content_path}/" in
    *'/../'* | *'/./'*) qam_fail "--content-path cannot contain dot path segments" ;;
  esac
  printf '%s' "${commit_sha}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' \
    || qam_fail "--commit-sha must be a lowercase full Git object ID"
  qam_require_command curl
  qam_require_command jq
  response_file="$(mktemp)"
  trap 'rm -f "${response_file}"; unset private_key github_token app_jwt' EXIT
  github_token=""

  case "${auth_mode}" in
    app)
      qam_require_azure_login
      qam_require_command openssl
      private_key="$(az keyvault secret show --id "${private_key_secret_uri}" --query value --output tsv)"
      case "${private_key}" in
        *'BEGIN RSA PRIVATE KEY'* | *'BEGIN PRIVATE KEY'*) ;;
        *) qam_fail "Key Vault secret is not a supported PEM RSA private key" ;;
      esac
      now="$(date +%s)"
      header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
      payload="$(jq -cn --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" --arg iss "${app_id}" \
        '{iat: $iat, exp: $exp, iss: $iss}' \
        | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
      signature="$(printf '%s' "${header}.${payload}" \
        | openssl dgst -sha256 -sign <(printf '%s' "${private_key}") \
        | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
      app_jwt="${header}.${payload}.${signature}"
      repository_name="${repository#*/}"
      request_body="$(jq -cn --arg repository "${repository_name}" \
        '{repositories: [$repository], permissions: {contents: "read"}}')"
      status="$(curl --silent --show-error --request POST \
        --header "Authorization: Bearer ${app_jwt}" \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --header 'Content-Type: application/json' \
        --data-binary "${request_body}" \
        --output "${response_file}" --write-out '%{http_code}' \
        "${github_api_url}/app/installations/${installation_id}/access_tokens")"
      [ "${status}" = "201" ] || qam_fail "GitHub App installation-token request returned HTTP ${status}"
      jq -e --arg expected "${repository}" '
        (.token | type == "string" and length > 0) and
        .permissions.contents == "read" and
        ((.permissions | keys_unsorted - ["contents", "metadata"]) | length == 0) and
        ((.permissions.metadata // "read") == "read") and
        (.repositories | type == "array" and length == 1) and
        (.repositories[0].full_name | ascii_downcase == ($expected | ascii_downcase))
      ' "${response_file}" >/dev/null \
        || qam_fail "GitHub App token response did not preserve the exact repository and Contents:read-only contract"
      github_token="$(jq -er '.token' "${response_file}")"
      ;;
    token)
      qam_require_azure_login
      github_token="$(az keyvault secret show --id "${token_secret_uri}" --query value --output tsv)"
      ;;
    none) ;;
  esac

  content_request_args=(
    --silent
    --show-error
    --header 'Accept: application/vnd.github.raw+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
    --max-filesize "${max_content_bytes}"
    --output "${response_file}"
    --write-out '%{http_code}'
  )
  if [ -n "${github_token}" ]; then
    content_request_args+=(--header "Authorization: Bearer ${github_token}")
  fi
  : > "${response_file}"
  if ! status="$(curl "${content_request_args[@]}" \
    "${github_api_url}/repos/${repository}/contents/${content_path}?ref=${commit_sha}")"; then
    qam_fail "GitHub commit-pinned Markdown read failed or exceeded ${max_content_bytes} bytes"
  fi
  [ "${status}" = "200" ] || qam_fail "GitHub commit-pinned Markdown read returned HTTP ${status}"
  content_bytes="$(wc -c < "${response_file}" | tr -d '[:space:]')"
  [ "${content_bytes}" -gt 0 ] && [ "${content_bytes}" -le "${max_content_bytes}" ] \
    || qam_fail "GitHub Markdown response must be non-empty and at most ${max_content_bytes} bytes"
fi

qam_require_command jq
jq -cn \
  --arg repository "${github_web_url}/${repository}" \
  --arg authMode "${auth_mode}" \
  --arg appId "${app_id}" \
  --arg installationId "${installation_id}" \
  '{repository: $repository, authMode: $authMode}
   + if $authMode == "app" then {appId: $appId, installationId: $installationId} else {} end'
