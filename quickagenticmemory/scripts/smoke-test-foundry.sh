#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

project_endpoint="${AZURE_AI_PROJECT_ENDPOINT:-}"
model_deployment="${AZURE_AI_MODEL_DEPLOYMENT_NAME:-}"
expected_text="QAM_FOUNDRY_OK"

usage() {
  printf '%s\n' \
    'Usage: smoke-test-foundry.sh --project-endpoint URL --model-deployment NAME [options]' \
    '' \
    'Calls the project-scoped Responses API with the signed-in Entra identity.' \
    'The script emits a bounded, credential-free JSON result.' \
    '' \
    'Options:' \
    '  --expected-text TEXT      Default: QAM_FOUNDRY_OK'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-endpoint) project_endpoint="${2:?missing value for $1}"; shift 2 ;;
    --model-deployment) model_deployment="${2:?missing value for $1}"; shift 2 ;;
    --expected-text) expected_text="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${project_endpoint}" ] || qam_fail "--project-endpoint is required"
[ -n "${model_deployment}" ] || qam_fail "--model-deployment is required"
[ -n "${expected_text}" ] || qam_fail "--expected-text must not be empty"
printf '%s' "${project_endpoint%/}" \
  | grep -Eq '^https://[a-z0-9-]+\.services\.ai\.azure\.com/api/projects/[A-Za-z0-9._-]+$' \
  || qam_fail "project endpoint must be an HTTPS Foundry services.ai.azure.com project URL"
printf '%s' "${model_deployment}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' \
  || qam_fail "model deployment name is invalid"
[ "${#expected_text}" -le 128 ] || qam_fail "expected text must not exceed 128 characters"

qam_require_azure_login
qam_require_command curl
qam_require_command jq

access_token="$(az account get-access-token \
  --resource 'https://ai.azure.com' \
  --query accessToken \
  --output tsv)"
[ -n "${access_token}" ] || qam_fail "could not acquire a Microsoft Foundry access token"

temp_dir="$(mktemp -d)"
request_file="${temp_dir}/request.json"
response_file="${temp_dir}/response.json"
trap 'rm -rf "${temp_dir}"' EXIT

jq -n \
  --arg model "${model_deployment}" \
  --arg expected "${expected_text}" \
  '{model: $model, input: ("Reply with exactly " + $expected + " and nothing else."), max_output_tokens: 64}' \
  > "${request_file}"

status="$(curl \
  --silent \
  --show-error \
  --request POST \
  --header "Authorization: Bearer ${access_token}" \
  --header 'Content-Type: application/json' \
  --data-binary "@${request_file}" \
  --output "${response_file}" \
  --write-out '%{http_code}' \
  "${project_endpoint%/}/openai/v1/responses")"
if [ "${status}" != '200' ]; then
  jq '{error: (.error.message // .message // "Foundry request failed")}' "${response_file}" >&2 2>/dev/null \
    || qam_info "Foundry returned a non-JSON error"
  qam_fail "Foundry Responses API returned HTTP ${status}"
fi

output_text="$(jq -r '[.output[]?.content[]? | select(.type == "output_text") | .text] | join("")' "${response_file}")"
jq -e \
  --arg expected "${expected_text}" \
  '.status == "completed" and
   ([.output[]?.content[]? | select(.type == "output_text") | .text] | join("")) == $expected' \
  "${response_file}" >/dev/null \
  || qam_fail "Foundry response did not complete with the expected bounded text"

jq -cn \
  --arg modelDeployment "${model_deployment}" \
  --arg responseStatus "$(jq -r '.status' "${response_file}")" \
  --arg outputText "${output_text}" \
  --argjson inputTokens "$(jq '.usage.input_tokens // 0' "${response_file}")" \
  --argjson outputTokens "$(jq '.usage.output_tokens // 0' "${response_file}")" \
  '{modelDeployment: $modelDeployment, responseStatus: $responseStatus,
    outputText: $outputText, usage: {inputTokens: $inputTokens, outputTokens: $outputTokens}}'
