#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-}"
EXPECTED_SHA="${2:-}"
RUNNER="${3:-}"
shift 3 || true

fail() { printf '[dispatch][error] %s\n' "$*" >&2; exit 3; }
[[ "${BASE_URL}" == https://* ]] || fail 'Pages base must use HTTPS'
[[ "${EXPECTED_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail 'expected source SHA must be exact'
[[ "${RUNNER}" =~ ^setup/[a-z0-9._-]+\.sh$ ]] || fail 'invalid runner path'
for command in curl python3 sha256sum mktemp; do
  command -v "${command}" >/dev/null 2>&1 || fail "missing command: ${command}"
done

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
curl -fsSL --proto '=https' "${BASE_URL%/}/source.json" -o "${WORK}/source.json"
ACTUAL_SHA="$(python3 - "${WORK}/source.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("source_sha", ""))
PY
)"
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]] || fail "published source SHA is ${ACTUAL_SHA:-missing}, expected ${EXPECTED_SHA}"

curl -fsSL --proto '=https' "${BASE_URL%/}/manifest.json" -o "${WORK}/manifest.json"
mkdir -p "${WORK}/closure"
python3 - "${WORK}/manifest.json" "${EXPECTED_SHA}" <<'PY' >"${WORK}/files.tsv"
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("source_sha") != sys.argv[2]:
    raise SystemExit("manifest source SHA mismatch")
for item in manifest.get("files", []):
    path = item.get("path", "")
    digest = item.get("sha256", "")
    mode = item.get("mode", "")
    if not re.fullmatch(r"tools/[A-Za-z0-9._/-]+", path) or ".." in path.split("/"):
        raise SystemExit("unsafe manifest path")
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or mode not in {"0644", "0755"}:
        raise SystemExit("invalid manifest entry")
    print(path, digest, mode, sep="\t")
PY

runner_found=false
while IFS=$'\t' read -r path digest mode; do
  destination="${WORK}/closure/${path}"
  mkdir -p "$(dirname -- "${destination}")"
  curl -fsSL --proto '=https' "${BASE_URL%/}/${path}" -o "${destination}"
  printf '%s  %s\n' "${digest}" "${destination}" | sha256sum -c - >/dev/null || fail "hash mismatch: ${path}"
  chmod "${mode}" "${destination}"
  [[ "${path}" == "tools/${RUNNER}" ]] && runner_found=true
done <"${WORK}/files.tsv"
[[ "${runner_found}" == true ]] || fail "runner is absent from manifest: ${RUNNER}"

export KTRANSFORMERS_SOURCE_SHA="${EXPECTED_SHA}"
exec "${WORK}/closure/tools/${RUNNER}" "$@"
