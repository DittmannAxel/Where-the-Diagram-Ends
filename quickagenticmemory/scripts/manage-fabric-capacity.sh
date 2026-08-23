#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=quickagenticmemory/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

resource_group="${AZURE_RESOURCE_GROUP:-}"
capacity_name=""
action="show"

usage() {
  printf '%s\n' \
    'Usage: manage-fabric-capacity.sh --resource-group NAME --capacity-name NAME [--action show|suspend|resume]' \
    '' \
    'Suspending stops the Fabric compute billing meter after in-flight usage is settled.' \
    'OneLake storage remains billable while compute is suspended.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resource-group) resource_group="${2:?missing value for $1}"; shift 2 ;;
    --capacity-name) capacity_name="${2:?missing value for $1}"; shift 2 ;;
    --action) action="${2:?missing value for $1}"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) usage >&2; qam_fail "unknown argument: $1" ;;
  esac
done

[ -n "${resource_group}" ] || qam_fail "--resource-group is required"
[ -n "${capacity_name}" ] || qam_fail "--capacity-name is required"
printf '%s' "${capacity_name}" | grep -Eq '^[a-z][a-z0-9]{2,62}$' \
  || qam_fail "capacity name is invalid"
printf '%s' "${action}" | grep -Eq '^(show|suspend|resume)$' \
  || qam_fail "action must be show, suspend, or resume"

qam_require_azure_login
subscription_id="$(az account show --query id --output tsv)"
qam_validate_uuid "${subscription_id}" "subscription ID"
resource_url="https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Fabric/capacities/${capacity_name}"

if [ "${action}" = 'show' ]; then
  az rest \
    --method GET \
    --url "${resource_url}" \
    --url-parameters api-version=2023-11-01 \
    --query '{name:name,sku:sku.name,state:properties.state,provisioningState:properties.provisioningState}' \
    --output json
  exit 0
fi

qam_info "requesting Fabric capacity ${action}"
az rest \
  --method POST \
  --url "${resource_url}/${action}" \
  --url-parameters api-version=2023-11-01 \
  --output none

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  state="$(az rest \
    --method GET \
    --url "${resource_url}" \
    --url-parameters api-version=2023-11-01 \
    --query properties.state \
    --output tsv)"
  if { [ "${action}" = 'suspend' ] && [ "${state}" = 'Paused' ]; } \
    || { [ "${action}" = 'resume' ] && [ "${state}" = 'Active' ]; }; then
    printf '%s\n' "${state}"
    exit 0
  fi
  qam_info "capacity state is ${state}; waiting for ${action} (${attempt}/10)"
  sleep 6
done

qam_fail "Fabric capacity did not reach the expected state after ${action}"
