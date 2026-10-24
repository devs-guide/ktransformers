#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PUBLISH_DIR="${PUBLISH_DIR:-${ROOT}/static}"
SOURCE_SHA="${SOURCE_SHA:-unknown}"
RELEASE_VERSION="${RELEASE_VERSION:-0.0.1}"

case "${PUBLISH_DIR}" in
  ""|"/"|"${ROOT}")
    printf '[www.pages][error] unsafe publish directory: %s\n' "${PUBLISH_DIR}" >&2
    exit 1
    ;;
esac

rm -rf -- "${PUBLISH_DIR}"
mkdir -p "${PUBLISH_DIR}/source/releases"
cp -R "${ROOT}/www/." "${PUBLISH_DIR}/"
cp "${ROOT}/readme.md" "${PUBLISH_DIR}/source/readme.md"
cp "${ROOT}/LICENSE" "${PUBLISH_DIR}/source/LICENSE"
cp "${ROOT}/docs/releases/0.0.1.md" "${PUBLISH_DIR}/source/releases/0.0.1.md"
touch "${PUBLISH_DIR}/.nojekyll"

python3 - "${PUBLISH_DIR}/source.json" "${SOURCE_SHA}" "${RELEASE_VERSION}" <<'PY'
import json
import sys

path, source_sha, release_version = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "repository": "devs-guide/ktransformers",
            "release_version": release_version,
            "source_sha": source_sha,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

printf '[www.pages] published %s at %s\n' "${SOURCE_SHA}" "${PUBLISH_DIR}"

