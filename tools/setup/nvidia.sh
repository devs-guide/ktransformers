#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${HERE}/common.sh"

MODE="${1:-}"
shift || true
DEVICES='auto'
STATE_ROOT='/var/lib/ktransformers'

usage() {
  printf 'usage: nvidia.sh MODE [--devices auto|INDEX,...] [--state-root PATH]\n' >&2
  exit "${KT_USAGE}"
}
while (($#)); do
  case "$1" in
    --devices) DEVICES="${2:-}"; shift 2 ;;
    --state-root) STATE_ROOT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${MODE}" =~ ^(preflight|apply|validate|restore|status)$ ]] || usage
[[ "${DEVICES}" == auto || "${DEVICES}" =~ ^[0-9]+(,[0-9]+)*$ ]] || usage
[[ "${STATE_ROOT}" == /* ]] || usage
kt_require_linux
kt_need nvidia-smi
kt_need nvtop
kt_need python3

STATE_DIR="${STATE_ROOT}/nvidia"
STATE_FILE="${STATE_DIR}/power.state.tsv"
EXPLICIT=false
[[ "${DEVICES}" == auto ]] || EXPLICIT=true

selected() {
  local index="$1"
  [[ "${DEVICES}" == auto ]] && return 0
  [[ ",${DEVICES}," == *",${index},"* ]]
}

make_plan() {
  local output="$1" rows index uuid minimum maximum current capability total free target
  rows="$(nvidia-smi --query-gpu=index,uuid,power.min_limit,power.max_limit,power.limit,compute_cap,memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null)"
  : >"${output}"
  while IFS=',' read -r index uuid minimum maximum current capability total free; do
    index="${index//[[:space:]]/}"; uuid="${uuid//[[:space:]]/}"
    minimum="${minimum//[[:space:]]/}"; maximum="${maximum//[[:space:]]/}"; current="${current//[[:space:]]/}"
    capability="${capability//[[:space:]]/}"; total="${total//[[:space:]]/}"; free="${free//[[:space:]]/}"
    selected "${index}" || continue
    target=''
    if python3 - "${minimum}" "${maximum}" <<'PY'
import sys
try: low, high = map(float, sys.argv[1:])
except ValueError: raise SystemExit(1)
raise SystemExit(0 if low <= 150 <= high else 1)
PY
    then target=150
    elif python3 - "${minimum}" "${maximum}" <<'PY'
import sys
try: low, high = map(float, sys.argv[1:])
except ValueError: raise SystemExit(1)
raise SystemExit(0 if low <= 75 <= high else 1)
PY
    then target=75
    elif [[ "${EXPLICIT}" == true ]]; then
      kt_fail "${KT_BLOCKED}" "selected device ${index} supports neither 150 W nor 75 W"
    else
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${index}" "${uuid}" "${current}" "${target}" "${capability}" "${total}" "${free}" >>"${output}"
  done <<<"${rows}"
  [[ -s "${output}" ]] || kt_fail "${KT_BLOCKED}" 'no compatible NVIDIA device remained selected'
  if [[ "${EXPLICIT}" == true ]]; then
    local expected actual
    expected="$(tr ',' '\n' <<<"${DEVICES}" | sort -u | awk 'END {print NR}')"
    actual="$(awk 'END {print NR}' "${output}")"
    [[ "${actual}" -eq "${expected}" ]] || kt_fail "${KT_BLOCKED}" 'one or more explicitly selected devices were unavailable'
  fi
}

emit_plan() {
  python3 - "$1" "${MODE}" <<'PY'
import json, sys
devices = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        index, _uuid, previous, target, capability, total, free = line.rstrip("\n").split("\t")
        devices.append({"index": int(index), "previous_watts": float(previous), "target_watts": int(target), "compute_capability": capability, "memory_total_mib": int(float(total)), "memory_free_mib": int(float(free))})
print(json.dumps({"schema_version": 1, "status": "accepted", "mode": sys.argv[2], "devices": devices, "monitor": "nvtop"}, sort_keys=True))
PY
}

restore_file() {
  local file="$1" index uuid previous current_uuid failures=0
  while IFS=$'\t' read -r index uuid previous _rest; do
    current_uuid="$(nvidia-smi -i "${index}" --query-gpu=uuid --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')"
    if [[ "${current_uuid}" != "${uuid}" ]] || ! kt_sudo nvidia-smi -i "${index}" --power-limit="${previous}" >/dev/null; then
      failures=$((failures + 1))
    fi
  done <"${file}"
  (( failures == 0 )) || kt_fail "${KT_BLOCKED}" "failed to restore ${failures} NVIDIA power limits"
}

case "${MODE}" in
  preflight)
    TEMP="$(mktemp)"; trap 'rm -f -- "${TEMP}"' EXIT
    make_plan "${TEMP}"; emit_plan "${TEMP}"
    ;;
  apply)
    [[ ! -e "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'a power recovery record already exists; restore it first'
    TEMP="$(mktemp)"; trap 'rm -f -- "${TEMP}"' EXIT
    make_plan "${TEMP}"
    kt_sudo install -d -m 0750 -o "$(id -un)" -g "$(id -gn)" "${STATE_DIR}"
    kt_sudo install -m 0600 -o "$(id -un)" -g "$(id -gn)" "${TEMP}" "${STATE_FILE}"
    APPLIED=0
    while IFS=$'\t' read -r index _uuid _previous target _rest; do
      if ! kt_sudo nvidia-smi -i "${index}" --power-limit="${target}" >/dev/null; then
        restore_file "${STATE_FILE}"
        rm -f -- "${STATE_FILE}"
        kt_fail "${KT_BLOCKED}" "failed to apply power limit to device ${index}"
      fi
      APPLIED=$((APPLIED + 1))
    done <"${STATE_FILE}"
    emit_plan "${STATE_FILE}"
    ;;
  validate)
    [[ -r "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'power recovery record is absent'
    while IFS=$'\t' read -r index uuid _previous target _rest; do
      CURRENT_UUID="$(nvidia-smi -i "${index}" --query-gpu=uuid --format=csv,noheader,nounits | tr -d '[:space:]')"
      CURRENT_LIMIT="$(nvidia-smi -i "${index}" --query-gpu=power.limit --format=csv,noheader,nounits | tr -d '[:space:]')"
      [[ "${CURRENT_UUID}" == "${uuid}" ]] || kt_fail "${KT_BLOCKED}" "device identity drift at index ${index}"
      python3 - "${CURRENT_LIMIT}" "${target}" <<'PY' || exit 3
import sys
raise SystemExit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 0.1 else 1)
PY
    done <"${STATE_FILE}"
    emit_plan "${STATE_FILE}"
    ;;
  restore)
    [[ -r "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'power recovery record is absent'
    restore_file "${STATE_FILE}"
    rm -f -- "${STATE_FILE}"
    kt_json_status status restored mode restore
    ;;
  status)
    if [[ -r "${STATE_FILE}" ]]; then emit_plan "${STATE_FILE}"; else kt_json_status status inactive mode status; fi
    ;;
esac
