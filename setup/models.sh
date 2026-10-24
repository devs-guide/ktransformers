#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${HERE}/common.sh"

MODE="${1:-}"
shift || true
MODEL_ID=''
MODEL_ROOT=''
MODEL_PATH=''
SOURCE_URL=''
REVISION=''
SELECTOR=''
EXPECTED_SHA256=''
LICENSE_APPROVED=false

usage() {
  printf 'usage: models.sh MODE --model-id ID --model-root PATH --model-path PATH --source-url URL --revision REV --selector SELECTOR --license-approved [--expected-sha256 HEX]\n' >&2
  exit "${KT_USAGE}"
}

while (($#)); do
  case "$1" in
    --model-id) MODEL_ID="${2:-}"; shift 2 ;;
    --model-root) MODEL_ROOT="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --source-url) SOURCE_URL="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --expected-sha256) EXPECTED_SHA256="${2:-}"; shift 2 ;;
    --license-approved) LICENSE_APPROVED=true; shift ;;
    *) usage ;;
  esac
done
[[ "${MODE}" =~ ^(preflight|validate)$ ]] || usage
[[ -n "${MODEL_ID}" && -n "${MODEL_ROOT}" && -n "${MODEL_PATH}" && -n "${SOURCE_URL}" && -n "${REVISION}" && -n "${SELECTOR}" ]] || usage
[[ "${LICENSE_APPROVED}" == true ]] || kt_fail "${KT_BLOCKED}" 'operator license approval is required'
[[ -z "${EXPECTED_SHA256}" || "${EXPECTED_SHA256}" =~ ^[0-9a-f]{64}$ ]] || usage
kt_require_linux
kt_need python3

ARGS=(
  --mode "${MODE}"
  --model-id "${MODEL_ID}"
  --model-root "${MODEL_ROOT}"
  --model-path "${MODEL_PATH}"
  --source-url "${SOURCE_URL}"
  --revision "${REVISION}"
  --selector "${SELECTOR}"
)
[[ -z "${EXPECTED_SHA256}" ]] || ARGS+=(--expected-sha256 "${EXPECTED_SHA256}")
exec python3 "${HERE}/gguf.py" "${ARGS[@]}"
