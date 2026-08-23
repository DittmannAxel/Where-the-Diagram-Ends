#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

app_url=""

usage() {
  printf '%s\n' \
    'Usage: smoke-test.sh --url https://APP_FQDN' \
    '' \
    'The deployed auth policy intentionally exempts only /healthz.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) app_url="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${app_url}" ] || qam_fail "--url is required"
case "${app_url}" in
  https://*) ;;
  *) qam_fail "smoke-test URL must use HTTPS" ;;
esac
qam_require_command curl

app_url="${app_url%/}"
response_file="$(mktemp)"
trap 'rm -f "${response_file}"' EXIT

check_public_endpoint() {
  endpoint="$1"
  qam_info "checking ${endpoint}"
  status="$(curl \
    --silent \
    --show-error \
    --location \
    --retry 12 \
    --retry-all-errors \
    --retry-delay 5 \
    --connect-timeout 10 \
    --max-time 20 \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${app_url}${endpoint}")"
  case "${status}" in
    2??) ;;
    *)
      sed -n '1,20p' "${response_file}" >&2
      qam_fail "${endpoint} returned HTTP ${status}"
      ;;
  esac
}

check_unauthenticated_rejection() {
  endpoint="$1"
  qam_info "checking that ${endpoint} rejects an anonymous request"
  status="$(curl \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 20 \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "${app_url}${endpoint}")"
  if [ "${status}" != "401" ]; then
    sed -n '1,20p' "${response_file}" >&2
    qam_fail "${endpoint} returned HTTP ${status}; expected anonymous access to return 401"
  fi
}

check_public_endpoint '/healthz'
check_unauthenticated_rejection '/mcp'
qam_info "public health and anonymous-auth-boundary smoke tests passed"
