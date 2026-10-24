#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${HERE}/common.sh"

VERSION='v0.7.0'
COMMIT='620d2225cc436ab0b001e3200e590e3b286ef9ab'
UPSTREAM='https://github.com/ggml-org/llama.cpp.git'
MODE="${1:-}"
shift || true
VARIANT='cpu'
DEVICES='auto'
STATE_ROOT='/var/lib/ktransformers'
INSTALL_ROOT='/opt/ktransformers'
SOURCE_DIR=''
ACQUIRE_SOURCE=false

usage() {
  printf 'usage: llamacpp.sh MODE [--variant cpu|nvidia] [--devices auto|INDEX,...] [--source-dir PATH] [--acquire-source] [--state-root PATH] [--install-root PATH]\n' >&2
  exit "${KT_USAGE}"
}

while (($#)); do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --devices) DEVICES="${2:-}"; shift 2 ;;
    --source-dir) SOURCE_DIR="${2:-}"; shift 2 ;;
    --acquire-source) ACQUIRE_SOURCE=true; shift ;;
    --state-root) STATE_ROOT="${2:-}"; shift 2 ;;
    --install-root) INSTALL_ROOT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${MODE}" =~ ^(preflight|apply|validate|upgrade|status)$ ]] || usage
[[ "${VARIANT}" == cpu || "${VARIANT}" == nvidia ]] || usage
[[ "${STATE_ROOT}" == /* && "${INSTALL_ROOT}" == /* ]] || usage
[[ -n "${SOURCE_DIR}" ]] || SOURCE_DIR="${STATE_ROOT}/sources/llama.cpp/${COMMIT}"
[[ "${SOURCE_DIR}" == /* ]] || usage
kt_require_linux

BUILD_DIR="${STATE_ROOT}/build/llama.cpp/${COMMIT}/${VARIANT}"
PROFILE_DIR="${INSTALL_ROOT}/runtimes/llama.cpp/${COMMIT}/${VARIANT}"
PROFILE_FILE="${STATE_ROOT}/profiles/llama.cpp-${VARIANT}.json"
OWNER="$(id -un)"
GROUP="$(id -gn)"

derive_cuda() {
  kt_need nvidia-smi
  kt_need nvcc
  local rows selected index capability
  rows="$(nvidia-smi --query-gpu=index,compute_cap --format=csv,noheader,nounits 2>/dev/null)"
  [[ -n "${rows}" ]] || kt_fail "${KT_BLOCKED}" 'no CUDA-capable NVIDIA device was discovered'
  if [[ "${DEVICES}" == auto ]]; then
    selected="$(awk -F, '{gsub(/ /, "", $1); printf "%s%s", separator, $1; separator=","}' <<<"${rows}")"
  else
    [[ "${DEVICES}" =~ ^[0-9]+(,[0-9]+)*$ ]] || usage
    selected="${DEVICES}"
  fi
  CUDA_ARCHS=''
  IFS=',' read -ra device_list <<<"${selected}"
  for index in "${device_list[@]}"; do
    capability="$(awk -F, -v wanted="${index}" '{gsub(/ /, "", $1); gsub(/ /, "", $2); if ($1 == wanted) print $2}' <<<"${rows}")"
    [[ "${capability}" =~ ^[0-9]+\.[0-9]+$ ]] || kt_fail "${KT_BLOCKED}" "selected device is unavailable or lacks a compute capability: ${index}"
    capability="${capability/.}"
    if [[ ";${CUDA_ARCHS};" != *";${capability};"* ]]; then
      CUDA_ARCHS="${CUDA_ARCHS:+${CUDA_ARCHS};}${capability}"
    fi
  done
  CUDA_DEVICES="${selected}"
}

verify_source() {
  [[ -d "${SOURCE_DIR}/.git" ]] || kt_fail "${KT_BLOCKED}" "pinned llama.cpp source is absent: ${SOURCE_DIR}"
  local actual remote
  actual="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
  remote="$(git -C "${SOURCE_DIR}" remote get-url origin)"
  [[ "${actual}" == "${COMMIT}" ]] || kt_fail "${KT_BLOCKED}" "llama.cpp source is ${actual}, expected ${COMMIT}"
  [[ "${remote}" == "${UPSTREAM}" || "${remote}" == "${UPSTREAM%.git}" ]] || kt_fail "${KT_BLOCKED}" 'llama.cpp source remote is not the pinned upstream'
}

acquire_source() {
  [[ "${ACQUIRE_SOURCE}" == true ]] || kt_fail "${KT_BLOCKED}" 'source is absent; acquisition requires explicit --acquire-source'
  kt_need git
  [[ ! -e "${SOURCE_DIR}" ]] || kt_fail "${KT_BLOCKED}" 'source destination exists but is not an exact checkout'
  kt_sudo install -d -m 0750 -o "${OWNER}" -g "${GROUP}" "$(dirname -- "${SOURCE_DIR}")"
  git clone --filter=blob:none --branch "${VERSION}" --detach "${UPSTREAM}" "${SOURCE_DIR}"
  verify_source
}

write_profile() {
  local temp="$1"
  python3 - "${temp}" "${VARIANT}" "${CUDA_ARCHS:-}" "${CUDA_DEVICES:-}" "${PROFILE_DIR}" "${KTRANSFORMERS_SOURCE_SHA:-unknown}" <<'PY'
import json, sys
path, variant, arches, devices, install, source_sha = sys.argv[1:]
record = {
    "schema_version": 1,
    "status": "accepted",
    "upstream": "https://github.com/ggml-org/llama.cpp.git",
    "version": "v0.7.0",
    "commit": "620d2225cc436ab0b001e3200e590e3b286ef9ab",
    "variant": variant,
    "cuda_architectures": [item for item in arches.split(";") if item],
    "selected_devices": [int(item) for item in devices.split(",") if item],
    "install_dir": install,
    "source_sha": source_sha,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True)
    handle.write("\n")
print(json.dumps(record, sort_keys=True))
PY
}

[[ "${VARIANT}" == cpu ]] || derive_cuda
case "${MODE}" in
  preflight)
    kt_need git
    kt_need cmake
    kt_need ninja
    kt_need c++
    [[ -d "${SOURCE_DIR}/.git" ]] && verify_source || [[ "${ACQUIRE_SOURCE}" == true ]] || kt_fail "${KT_BLOCKED}" 'pinned source is absent and acquisition was not authorized'
    kt_json_status status ready mode preflight variant "${VARIANT}" version "${VERSION}" commit "${COMMIT}" cuda_architectures "${CUDA_ARCHS:-}"
    ;;
  apply|upgrade)
    kt_need git
    kt_need cmake
    kt_need ninja
    kt_need c++
    [[ -d "${SOURCE_DIR}/.git" ]] || acquire_source
    verify_source
    if [[ -x "${PROFILE_DIR}/llama-cli" && -x "${PROFILE_DIR}/llama-server" && -r "${PROFILE_FILE}" ]]; then
      cat "${PROFILE_FILE}"
      exit 0
    fi
    kt_sudo install -d -m 0750 -o "${OWNER}" -g "${GROUP}" "${BUILD_DIR}" "${PROFILE_DIR}" "$(dirname -- "${PROFILE_FILE}")"
    CMAKE_ARGS=(
      -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja
      -DCMAKE_BUILD_TYPE=Release
      -DBUILD_SHARED_LIBS=OFF
      -DGGML_NATIVE=ON
      -DLLAMA_BUILD_TESTS=OFF
      -DLLAMA_BUILD_SERVER=ON
      -DLLAMA_CURL=OFF
    )
    if [[ "${VARIANT}" == nvidia ]]; then
      CMAKE_ARGS+=( -DGGML_CUDA=ON "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHS}" )
      CUDA_VISIBLE_DEVICES="${CUDA_DEVICES}" cmake "${CMAKE_ARGS[@]}" >&2
      CUDA_VISIBLE_DEVICES="${CUDA_DEVICES}" cmake --build "${BUILD_DIR}" --target llama-cli llama-server >&2
    else
      CMAKE_ARGS+=( -DGGML_CUDA=OFF )
      cmake "${CMAKE_ARGS[@]}" >&2
      cmake --build "${BUILD_DIR}" --target llama-cli llama-server >&2
    fi
    kt_sudo install -m 0755 "${BUILD_DIR}/bin/llama-cli" "${PROFILE_DIR}/llama-cli"
    kt_sudo install -m 0755 "${BUILD_DIR}/bin/llama-server" "${PROFILE_DIR}/llama-server"
    TEMP="$(mktemp)"
    trap 'rm -f -- "${TEMP}"' EXIT
    write_profile "${TEMP}" >/dev/null
    kt_sudo install -m 0640 -o "${OWNER}" -g "${GROUP}" "${TEMP}" "${PROFILE_FILE}"
    cat "${TEMP}"
    ;;
  validate)
    verify_source
    for binary in llama-cli llama-server; do
      [[ -x "${PROFILE_DIR}/${binary}" ]] || kt_fail "${KT_BLOCKED}" "runtime binary is absent: ${binary}"
      HELP="$(${PROFILE_DIR}/${binary} --help 2>&1 || true)"
      [[ "${HELP}" == *'--model'* ]] || kt_fail "${KT_BLOCKED}" "${binary} lacks the expected model interface"
    done
    [[ -r "${PROFILE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'runtime profile is absent'
    python3 - "${PROFILE_FILE}" "${VARIANT}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    record = json.load(handle)
if record.get("variant") != sys.argv[2] or record.get("commit") != "620d2225cc436ab0b001e3200e590e3b286ef9ab":
    raise SystemExit("runtime profile mismatch")
record["mode"] = "validate"
print(json.dumps(record, sort_keys=True))
PY
    ;;
  status)
    [[ -r "${PROFILE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'runtime profile is absent'
    cat "${PROFILE_FILE}"
    ;;
esac
