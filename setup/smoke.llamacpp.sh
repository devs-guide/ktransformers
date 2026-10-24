#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${HERE}/common.sh"

MODE="${1:-}"
shift || true
PROFILE='cpu'
DEVICES='auto'
STATE_ROOT='/var/lib/ktransformers'
INSTALL_ROOT='/opt/ktransformers'
MODEL_ID=''
MODEL_ROOT=''
MODEL_PATH=''
SOURCE_URL=''
REVISION=''
SELECTOR=''
EXPECTED_SHA256=''
LICENSE_APPROVED=false
HOST_RESERVE_GIB=''
GPU_RESERVE_MIB=''

usage() {
  printf 'usage: smoke.llamacpp.sh MODE --profile cpu|nvidia --model-id ID --model-root PATH --model-path PATH --source-url URL --revision REV --selector SELECTOR --license-approved --host-reserve-gib N [--gpu-reserve-mib N] [--devices auto|INDEX,...] [--expected-sha256 HEX]\n' >&2
  exit "${KT_USAGE}"
}

while (($#)); do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --devices) DEVICES="${2:-}"; shift 2 ;;
    --state-root) STATE_ROOT="${2:-}"; shift 2 ;;
    --install-root) INSTALL_ROOT="${2:-}"; shift 2 ;;
    --model-id) MODEL_ID="${2:-}"; shift 2 ;;
    --model-root) MODEL_ROOT="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --source-url) SOURCE_URL="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --expected-sha256) EXPECTED_SHA256="${2:-}"; shift 2 ;;
    --license-approved) LICENSE_APPROVED=true; shift ;;
    --host-reserve-gib) HOST_RESERVE_GIB="${2:-}"; shift 2 ;;
    --gpu-reserve-mib) GPU_RESERVE_MIB="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${MODE}" =~ ^(preflight|run|validate|status)$ ]] || usage
[[ "${PROFILE}" == cpu || "${PROFILE}" == nvidia ]] || usage
[[ "${STATE_ROOT}" == /* && "${INSTALL_ROOT}" == /* ]] || usage
[[ "${DEVICES}" == auto || "${DEVICES}" =~ ^[0-9]+(,[0-9]+)*$ ]] || usage
kt_require_linux
kt_need python3

COMMIT='620d2225cc436ab0b001e3200e590e3b286ef9ab'
RUNTIME_DIR="${INSTALL_ROOT}/runtimes/llama.cpp/${COMMIT}/${PROFILE}"
CLI="${RUNTIME_DIR}/llama-cli"
SERVER="${RUNTIME_DIR}/llama-server"
EVIDENCE_DIR="${STATE_ROOT}/evidence/llamacpp-smoke/${PROFILE}"
CURRENT="${EVIDENCE_DIR}/current.json"

if [[ "${MODE}" == status ]]; then
  [[ -r "${CURRENT}" ]] || kt_fail "${KT_BLOCKED}" 'smoke evidence is absent'
  cat "${CURRENT}"
  exit 0
fi
if [[ "${MODE}" == validate ]]; then
  [[ -r "${CURRENT}" ]] || kt_fail "${KT_BLOCKED}" 'smoke evidence is absent'
  python3 - "${CURRENT}" "${PROFILE}" "${STATE_ROOT}/nvidia/power.state.tsv" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    record = json.load(handle)
if record.get("profile") != sys.argv[2] or record.get("status") != "accepted":
    raise SystemExit("smoke evidence profile/status mismatch")
if len(set(record.get("cli_output_sha256", []))) != 1 or len(record.get("cli_output_sha256", [])) != 2:
    raise SystemExit("CLI outputs are not a stable pair")
if len(set(record.get("api_content_sha256", []))) != 1 or len(record.get("api_content_sha256", [])) != 2:
    raise SystemExit("API outputs are not a stable pair")
if sys.argv[2] == "nvidia" and os.path.exists(sys.argv[3]):
    raise SystemExit("NVIDIA power recovery record still exists")
record["mode"] = "validate"
print(json.dumps(record, sort_keys=True))
PY
  exit 0
fi

[[ -n "${MODEL_ID}" && -n "${MODEL_ROOT}" && -n "${MODEL_PATH}" && -n "${SOURCE_URL}" && -n "${REVISION}" && -n "${SELECTOR}" ]] || usage
[[ "${LICENSE_APPROVED}" == true ]] || kt_fail "${KT_BLOCKED}" 'operator license approval is required'
[[ -n "${HOST_RESERVE_GIB}" ]] || kt_fail "${KT_USAGE}" 'an operator-selected --host-reserve-gib value is required'
kt_positive_number "${HOST_RESERVE_GIB}" || usage
if [[ "${PROFILE}" == nvidia ]]; then
  [[ -n "${GPU_RESERVE_MIB}" ]] || kt_fail "${KT_USAGE}" 'NVIDIA smoke requires an operator-selected --gpu-reserve-mib value'
  kt_positive_number "${GPU_RESERVE_MIB}" || usage
fi
[[ -x "${CLI}" && -x "${SERVER}" ]] || kt_fail "${KT_BLOCKED}" "runtime profile is incomplete: ${RUNTIME_DIR}"
kt_need timeout
kt_need curl
kt_need sha256sum

MODEL_ARGS=(
  --model-id "${MODEL_ID}" --model-root "${MODEL_ROOT}" --model-path "${MODEL_PATH}"
  --source-url "${SOURCE_URL}" --revision "${REVISION}" --selector "${SELECTOR}" --license-approved
)
[[ -z "${EXPECTED_SHA256}" ]] || MODEL_ARGS+=(--expected-sha256 "${EXPECTED_SHA256}")
MODEL_JSON="$(${HERE}/models.sh preflight "${MODEL_ARGS[@]}")"
CANONICAL_MODEL="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["canonical_path"])' <<<"${MODEL_JSON}")"
MODEL_SHA="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])' <<<"${MODEL_JSON}")"
BLOCK_COUNT="$(python3 -c 'import json,sys; d=json.load(sys.stdin)["metadata"]; print(next((v for k,v in d.items() if k.endswith(".block_count")), 0))' <<<"${MODEL_JSON}")"
[[ "${BLOCK_COUNT}" =~ ^[1-9][0-9]*$ ]] || kt_fail "${KT_BLOCKED}" 'GGUF block count is unavailable'

AVAILABLE_KIB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
REQUIRED_KIB="$(python3 - "${HOST_RESERVE_GIB}" <<'PY'
import sys
print(int(float(sys.argv[1]) * 1024 * 1024))
PY
)"
(( AVAILABLE_KIB >= REQUIRED_KIB )) || kt_fail "${KT_BLOCKED}" 'operator-selected host-memory reserve is not available'
THREADS="$(lscpu -p=SOCKET,CORE | awk -F, '!/^#/ {seen[$1 FS $2]=1} END {print length(seen)}')"
[[ "${THREADS}" =~ ^[1-9][0-9]*$ ]] || kt_fail "${KT_BLOCKED}" 'physical core count is unavailable'

HELP="$(${CLI} --help 2>&1 || true)"
for option in --offline --check-tensors --seed; do
  [[ "${HELP}" == *"${option}"* ]] || kt_fail "${KT_BLOCKED}" "runtime lacks required option: ${option}"
done
if [[ "${PROFILE}" == nvidia ]]; then
  [[ "${HELP}" == *'--override-tensor'* ]] || kt_fail "${KT_BLOCKED}" 'runtime lacks tensor placement override support'
fi

if [[ "${MODE}" == preflight ]]; then
  kt_json_status status ready mode preflight profile "${PROFILE}" model_sha256 "${MODEL_SHA}" threads "${THREADS}" block_count "${BLOCK_COUNT}"
  exit 0
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="${EVIDENCE_DIR}/${RUN_ID}"
install -d -m 0750 "${RUN_DIR}"
SERVER_PID=''
POWER_APPLIED=false
cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  if [[ "${POWER_APPLIED}" == true ]]; then
    if ! "${HERE}/nvidia.sh" restore --state-root "${STATE_ROOT}" >"${RUN_DIR}/power-restore.json"; then
      kt_log error 'NVIDIA power restoration failed; recovery record was retained'
      exit 3
    fi
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

COMMON_ARGS=(
  --model "${CANONICAL_MODEL}" --ctx-size 2048 --batch-size 512 --ubatch-size 128
  --threads "${THREADS}" --seed 1 --temp 0 --predict 32 --offline --check-tensors --no-warmup
)
ENV_ARGS=()
PLACEMENT_ARGS=()
SELECTED_DEVICES=''
if [[ "${PROFILE}" == nvidia ]]; then
  "${HERE}/nvidia.sh" apply --devices "${DEVICES}" --state-root "${STATE_ROOT}" >"${RUN_DIR}/power-apply.json"
  POWER_APPLIED=true
  SELECTED_DEVICES="$(python3 -c 'import json,sys; print(",".join(str(x["index"]) for x in json.load(sys.stdin)["devices"]))' <"${RUN_DIR}/power-apply.json")"
  TENSOR_SPLIT=''
  IFS=',' read -ra selected_list <<<"${SELECTED_DEVICES}"
  for index in "${selected_list[@]}"; do
    FREE_MIB="$(nvidia-smi -i "${index}" --query-gpu=memory.free --format=csv,noheader,nounits | tr -d '[:space:]')"
    python3 - "${FREE_MIB}" "${GPU_RESERVE_MIB}" <<'PY' || kt_fail "${KT_BLOCKED}" 'operator-selected GPU-memory reserve is not available'
import sys
raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY
    TENSOR_SPLIT="${TENSOR_SPLIT:+${TENSOR_SPLIT},}${FREE_MIB}"
  done
  ENV_ARGS=(env "CUDA_VISIBLE_DEVICES=${SELECTED_DEVICES}")
  PLACEMENT_ARGS=(--n-gpu-layers "${BLOCK_COUNT}" --split-mode layer --tensor-split "${TENSOR_SPLIT}" --override-tensor 'blk\.[0-9]+\.ffn_.*=CPU')
fi

PROMPT='Reply with exactly: smoke-ok'
CLI_HASHES=()
for run in 1 2; do
  "${ENV_ARGS[@]}" timeout 900 "${CLI}" "${COMMON_ARGS[@]}" "${PLACEMENT_ARGS[@]}" --no-display-prompt --simple-io --prompt "${PROMPT}" \
    >"${RUN_DIR}/cli-${run}.out" 2>"${RUN_DIR}/cli-${run}.err"
  python3 - "${RUN_DIR}/cli-${run}.out" <<'PY' >"${RUN_DIR}/cli-${run}.normalized"
import re, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    print(re.sub(r"\s+", " ", handle.read()).strip())
PY
  CLI_HASHES+=("$(sha256sum "${RUN_DIR}/cli-${run}.normalized" | awk '{print $1}')")
  [[ -s "${RUN_DIR}/cli-${run}.normalized" ]] || kt_fail "${KT_BLOCKED}" 'CLI output is empty'
done
[[ "${CLI_HASHES[0]}" == "${CLI_HASHES[1]}" ]] || kt_fail "${KT_BLOCKED}" 'CLI outputs were not stable across two runs'

PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
"${ENV_ARGS[@]}" timeout 900 "${SERVER}" "${COMMON_ARGS[@]}" "${PLACEMENT_ARGS[@]}" --host 127.0.0.1 --port "${PORT}" --parallel 1 \
  >"${RUN_DIR}/server.out" 2>"${RUN_DIR}/server.err" &
SERVER_PID=$!
READY=false
for _attempt in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then READY=true; break; fi
  kill -0 "${SERVER_PID}" 2>/dev/null || break
  sleep 1
done
[[ "${READY}" == true ]] || kt_fail "${KT_BLOCKED}" 'loopback llama.cpp server did not become ready'

API_HASHES=()
REQUEST="$(python3 -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1],"n_predict":32,"temperature":0,"seed":1}))' "${PROMPT}")"
for run in 1 2; do
  curl -fsS --max-time 900 -H 'Content-Type: application/json' -d "${REQUEST}" "http://127.0.0.1:${PORT}/completion" >"${RUN_DIR}/api-${run}.json"
  python3 - "${RUN_DIR}/api-${run}.json" <<'PY' >"${RUN_DIR}/api-${run}.content"
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    content = json.load(handle).get("content", "")
if not content:
    raise SystemExit("API response content is empty")
print(re.sub(r"\s+", " ", content).strip())
PY
  API_HASHES+=("$(sha256sum "${RUN_DIR}/api-${run}.content" | awk '{print $1}')")
done
[[ "${API_HASHES[0]}" == "${API_HASHES[1]}" ]] || kt_fail "${KT_BLOCKED}" 'API outputs were not stable across two requests'
kill "${SERVER_PID}" 2>/dev/null || true
wait "${SERVER_PID}" 2>/dev/null || true
SERVER_PID=''

grep -E 'CUDA|buffer|offload|load_tensors' "${RUN_DIR}"/*.err >"${RUN_DIR}/placement.log" || true
PLACEMENT_SHA="$(sha256sum "${RUN_DIR}/placement.log" | awk '{print $1}')"
[[ "${PROFILE}" == cpu || -s "${RUN_DIR}/placement.log" ]] || kt_fail "${KT_BLOCKED}" 'NVIDIA placement evidence is absent'
AVAILABLE_AFTER_KIB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
(( AVAILABLE_AFTER_KIB >= REQUIRED_KIB )) || kt_fail "${KT_BLOCKED}" 'host-memory reserve did not hold after smoke'
if [[ "${POWER_APPLIED}" == true ]]; then
  "${HERE}/nvidia.sh" restore --state-root "${STATE_ROOT}" >"${RUN_DIR}/power-restore.json"
  POWER_APPLIED=false
  IFS=',' read -ra selected_list <<<"${SELECTED_DEVICES}"
  for index in "${selected_list[@]}"; do
    FREE_MIB="$(nvidia-smi -i "${index}" --query-gpu=memory.free --format=csv,noheader,nounits | tr -d '[:space:]')"
    python3 - "${FREE_MIB}" "${GPU_RESERVE_MIB}" <<'PY' || kt_fail "${KT_BLOCKED}" 'GPU-memory reserve did not hold after smoke'
import sys
raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY
  done
fi

TEMP="$(mktemp)"
trap 'rm -f -- "${TEMP}"' RETURN
python3 - "${TEMP}" "${PROFILE}" "${RUN_ID}" "${MODEL_SHA}" "${THREADS}" "${BLOCK_COUNT}" "${CLI_HASHES[0]}" "${CLI_HASHES[1]}" "${API_HASHES[0]}" "${API_HASHES[1]}" "${PLACEMENT_SHA}" "${SELECTED_DEVICES}" "${KTRANSFORMERS_SOURCE_SHA:-unknown}" <<'PY'
import json, sys
path, profile, run_id, model_sha, threads, blocks, cli1, cli2, api1, api2, placement, devices, source_sha = sys.argv[1:]
record = {
    "schema_version": 1, "status": "accepted", "mode": "run", "profile": profile,
    "run_id": run_id, "source_sha": source_sha, "model_sha256": model_sha,
    "threads": int(threads), "block_count": int(blocks),
    "cli_output_sha256": [cli1, cli2], "api_content_sha256": [api1, api2],
    "placement_log_sha256": placement,
    "selected_devices": [int(item) for item in devices.split(",") if item],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True)
    handle.write("\n")
print(json.dumps(record, sort_keys=True))
PY
install -m 0640 "${TEMP}" "${CURRENT}"
rm -f -- "${TEMP}"
trap - RETURN
