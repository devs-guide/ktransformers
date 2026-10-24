#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PUBLISH_DIR="${PUBLISH_DIR:-${ROOT}/static}"
SOURCE_SHA="${SOURCE_SHA:-}"
CHANNEL="${PUBLICATION_CHANNEL:-current}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
FILE_LIST="${ROOT}/actions/publication.files"

fail() { printf '[www.pages][error] %s\n' "$*" >&2; exit 1; }
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail 'SOURCE_SHA must be an exact commit'
[[ "${CHANNEL}" == current || "${CHANNEL}" == release ]] || fail 'publication channel must be current or release'
if [[ "${CHANNEL}" == release ]]; then
  [[ "${RELEASE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'release publication requires a semantic version'
  [[ -s "${ROOT}/docs/releases/${RELEASE_VERSION}.md" ]] || fail 'release notes are absent'
fi
case "${PUBLISH_DIR}" in
  ""|"/"|"${ROOT}") fail "unsafe publish directory: ${PUBLISH_DIR}" ;;
esac

rm -rf -- "${PUBLISH_DIR}"
mkdir -p "${PUBLISH_DIR}/source/releases" "${PUBLISH_DIR}/tools"
cp -R "${ROOT}/www/." "${PUBLISH_DIR}/"
cp "${ROOT}/readme.md" "${PUBLISH_DIR}/source/readme.md"
cp "${ROOT}/LICENSE" "${PUBLISH_DIR}/source/LICENSE"
cp "${ROOT}"/docs/releases/*.md "${PUBLISH_DIR}/source/releases/"
touch "${PUBLISH_DIR}/.nojekyll"

while read -r source destination mode extra; do
  [[ -n "${source}" && -z "${extra:-}" ]] || fail 'invalid publication.files entry'
  [[ -f "${ROOT}/${source}" ]] || fail "missing publication source: ${source}"
  mkdir -p "${PUBLISH_DIR}/$(dirname -- "${destination}")"
  install -m "${mode}" "${ROOT}/${source}" "${PUBLISH_DIR}/${destination}"
done <"${FILE_LIST}"

python3 - "${PUBLISH_DIR}/source.json" "${SOURCE_SHA}" "${CHANNEL}" "${RELEASE_VERSION}" <<'PY'
import json, sys
path, source_sha, channel, release_version = sys.argv[1:]
record = {
    "schema_version": 1,
    "repository": "devs-guide/ktransformers",
    "source_sha": source_sha,
    "channel": channel,
    "release_version": release_version or None,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

python3 - "${PUBLISH_DIR}" "${SOURCE_SHA}" "${CHANNEL}" "${RELEASE_VERSION}" "${FILE_LIST}" <<'PY'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = []
with open(sys.argv[5], encoding="utf-8") as handle:
    for line in handle:
        source, destination, mode = line.split()
        path = root / destination
        files.append({
            "path": destination,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size_bytes": path.stat().st_size,
            "mode": mode,
        })
record = {
    "schema_version": 1,
    "repository": "devs-guide/ktransformers",
    "source_sha": sys.argv[2],
    "channel": sys.argv[3],
    "release_version": sys.argv[4] or None,
    "files": files,
}
with open(root / "manifest.json", "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

printf '[www.pages] built %s channel at %s\n' "${CHANNEL}" "${SOURCE_SHA}"
