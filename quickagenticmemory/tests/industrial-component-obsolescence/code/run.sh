#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QAM_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"

npm --prefix "${QAM_ROOT}" run build
exec node "${SCRIPT_DIR}/runner.mjs" \
  --data "${SCRIPT_DIR}/../data" \
  --output "${SCRIPT_DIR}/../screens/evidence/latest" \
  "$@"
