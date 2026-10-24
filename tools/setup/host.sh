#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${HERE}/common.sh"

MODE="${1:-}"
shift || true
OWNER="$(id -un)"
GROUP="$(id -gn)"
STATE_ROOT='/var/lib/ktransformers'
REQUIRE_PMEM=false
HOST_RESERVE_GIB=''

usage() {
  printf 'usage: host.sh MODE [--owner USER] [--group GROUP] [--state-root PATH] [--require-pmem-memory-mode] [--host-reserve-gib N]\n' >&2
  exit "${KT_USAGE}"
}

while (($#)); do
  case "$1" in
    --owner) OWNER="${2:-}"; shift 2 ;;
    --group) GROUP="${2:-}"; shift 2 ;;
    --state-root) STATE_ROOT="${2:-}"; shift 2 ;;
    --require-pmem-memory-mode) REQUIRE_PMEM=true; shift ;;
    --host-reserve-gib) HOST_RESERVE_GIB="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${MODE}" =~ ^(preflight|apply|validate|status)$ ]] || usage
[[ "${STATE_ROOT}" == /* && "${STATE_ROOT}" != / ]] || usage
[[ -z "${HOST_RESERVE_GIB}" ]] || kt_positive_number "${HOST_RESERVE_GIB}" || usage
kt_require_linux
kt_need python3
kt_need lscpu
kt_need getconf

FLAGS="$(awk -F: '/^flags[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo)"
for flag in avx512f avx512_vnni; do
  [[ " ${FLAGS} " == *" ${flag} "* ]] || kt_fail "${KT_BLOCKED}" "required CPU capability is missing: ${flag}"
done

AVAILABLE_KIB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -n "${HOST_RESERVE_GIB}" ]]; then
  REQUIRED_KIB="$(python3 - "${HOST_RESERVE_GIB}" <<'PY'
import sys
print(int(float(sys.argv[1]) * 1024 * 1024))
PY
)"
  (( AVAILABLE_KIB >= REQUIRED_KIB )) || kt_fail "${KT_BLOCKED}" 'operator-selected host-memory reserve is not available'
fi

PMEM_MODE='unknown'
if command -v ipmctl >/dev/null 2>&1; then
  PMEM_FACTS="$(ipmctl show -memoryresources 2>/dev/null || true)"
  if grep -Eq '(MemoryModeCapacity|VolatileCapacity)[^0-9]*[1-9]' <<<"${PMEM_FACTS}"; then
    PMEM_MODE='memory-mode-observed'
  else
    PMEM_MODE='not-observed'
  fi
fi
[[ "${REQUIRE_PMEM}" == false || "${PMEM_MODE}" == memory-mode-observed ]] || kt_fail "${KT_BLOCKED}" 'operator-required PMem Memory Mode was not observed'

PHYSICAL_CORES="$(lscpu -p=SOCKET,CORE 2>/dev/null | awk -F, '!/^#/ {seen[$1 FS $2]=1} END {print length(seen)}')"
LOGICAL_CPUS="$(getconf _NPROCESSORS_ONLN)"
GPU_COUNT=0
CUDA_READY=false
NVIDIA_MONITOR=false
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | awk 'NF {count++} END {print count + 0}')"
fi
command -v nvcc >/dev/null 2>&1 && CUDA_READY=true
command -v nvtop >/dev/null 2>&1 && NVIDIA_MONITOR=true

emit_facts() {
  python3 - "${MODE}" "${PHYSICAL_CORES}" "${LOGICAL_CPUS}" "${AVAILABLE_KIB}" "${PMEM_MODE}" "${GPU_COUNT}" "${CUDA_READY}" "${NVIDIA_MONITOR}" "${HOST_RESERVE_GIB}" "${KTRANSFORMERS_SOURCE_SHA:-unknown}" <<'PY'
import json, sys
mode, physical, logical, available, pmem, gpu_count, cuda, nvtop, reserve, source_sha = sys.argv[1:]
record = {
    "schema_version": 1,
    "status": "accepted",
    "mode": mode,
    "source_sha": source_sha,
    "required_capabilities": {"avx512f": True, "avx512_vnni": True},
    "cpu": {"physical_cores": int(physical), "logical_cpus": int(logical)},
    "memory": {"available_kib": int(available), "operator_reserve_gib": float(reserve) if reserve else None},
    "pmem": {"observation": pmem},
    "nvidia": {"device_count": int(gpu_count), "cuda_compiler": cuda == "true", "nvtop": nvtop == "true"},
}
print(json.dumps(record, sort_keys=True))
PY
}

STATE_FILE="${STATE_ROOT}/facts/host.json"
case "${MODE}" in
  preflight) emit_facts ;;
  apply)
    getent passwd "${OWNER}" >/dev/null || kt_fail "${KT_BLOCKED}" "owner does not exist: ${OWNER}"
    getent group "${GROUP}" >/dev/null || kt_fail "${KT_BLOCKED}" "group does not exist: ${GROUP}"
    TEMP="$(mktemp)"
    trap 'rm -f -- "${TEMP}"' EXIT
    emit_facts >"${TEMP}"
    kt_sudo install -d -m 0750 -o "${OWNER}" -g "${GROUP}" "/etc/ktransformers" "/opt/ktransformers" "${STATE_ROOT}" "${STATE_ROOT}/facts" "/var/log/ktransformers"
    kt_sudo install -m 0640 -o "${OWNER}" -g "${GROUP}" "${TEMP}" "${STATE_FILE}"
    cat "${TEMP}"
    ;;
  validate)
    [[ -r "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" "host facts are absent: ${STATE_FILE}"
    CURRENT="$(emit_facts)"
    python3 - "${STATE_FILE}" "${CURRENT}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    saved = json.load(handle)
current = json.loads(sys.argv[2])
for key in ("required_capabilities", "cpu"):
    if saved.get(key) != current.get(key):
        raise SystemExit(f"host fact drift: {key}")
current["mode"] = "validate"
print(json.dumps(current, sort_keys=True))
PY
    ;;
  status)
    [[ -r "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" "host facts are absent: ${STATE_FILE}"
    cat "${STATE_FILE}"
    ;;
esac
