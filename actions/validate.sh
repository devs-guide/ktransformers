#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}"

fail() { printf '[validate][error] %s\n' "$*" >&2; exit 1; }

while read -r source destination mode extra; do
  [[ -n "${source}" && -z "${extra:-}" ]] || fail 'invalid publication.files row'
  [[ -f "${source}" ]] || fail "publication source is absent: ${source}"
  [[ "${destination}" == tools/* && "${destination}" != *..* ]] || fail "unsafe publication destination: ${destination}"
  [[ "${mode}" == 0644 || "${mode}" == 0755 ]] || fail "invalid publication mode: ${mode}"
done <actions/publication.files

[[ "$(awk '{print $2}' actions/publication.files | sort | uniq -d | wc -l)" -eq 0 ]] || fail 'publication destinations are not unique'

for script in actions/*.sh setup/*.sh; do
  bash -n "${script}"
done
python3 - <<'PY'
import ast
from pathlib import Path
for path in Path("setup").glob("*.py"):
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY

if git ls-files | grep -E '\.(gguf|safetensors|ckpt|onnx|pt|pth|tflite|xet)$' >/dev/null; then
  fail 'model content is tracked'
fi
if git grep -n -E '10\.0\.0\.[0-9]+' -- . ':!actions/validate.sh' >/dev/null; then
  fail 'private target identity is present'
fi
if git grep -n -E 'RTX[ -]?3090|sm_?86|36 physical cores|96 GiB|4 GiB' -- . ':!actions/validate.sh' >/dev/null; then
  fail 'observed deployment hardware leaked into project defaults'
fi
if git grep -n -E '(wget|curl).*(huggingface\.co|\.gguf|\.safetensors)' -- setup actions ':!setup/dispatch.sh' ':!actions/validate.sh' >/dev/null; then
  fail 'model acquisition behavior is forbidden'
fi

SOURCE_SHA="${SOURCE_SHA:-$(git rev-parse HEAD)}" bash actions/www.pages.sh
python3 - "${SOURCE_SHA:-$(git rev-parse HEAD)}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path("static")
source = json.loads((root / "source.json").read_text(encoding="utf-8"))
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
if source["source_sha"] != sys.argv[1] or manifest["source_sha"] != sys.argv[1]:
    raise SystemExit("publication source SHA mismatch")
for item in manifest["files"]:
    path = root / item["path"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        raise SystemExit(f"publication hash mismatch: {item['path']}")
PY
printf '[validate] repository and publication closure accepted\n'
