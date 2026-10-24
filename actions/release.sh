#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="${RELEASE_VERSION:-}"
SOURCE_SHA="${SOURCE_SHA:-}"
MODE="${RELEASE_MODE:-}"
PHASE="${RELEASE_PHASE:-prepare}"
CONFIRMATION="${RELEASE_CONFIRMATION:-}"
REPOSITORY="${GITHUB_REPOSITORY:-devs-guide/ktransformers}"
NOTES="${ROOT}/docs/releases/${VERSION}.md"

fail() { printf '[release][error] %s\n' "$*" >&2; exit 1; }
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid version'
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail 'source SHA must be exact'
[[ "${MODE}" == draft || "${MODE}" == publish ]] || fail 'mode must be draft or publish'
[[ "${PHASE}" == prepare || "${PHASE}" == finalize ]] || fail 'phase must be prepare or finalize'
[[ "${CONFIRMATION}" == "release ${VERSION}@${SOURCE_SHA} ${MODE}" ]] || fail 'confirmation does not match'
[[ -s "${NOTES}" ]] || fail "missing release notes: ${NOTES}"

cd "${ROOT}"
[[ "$(git rev-parse HEAD)" == "${SOURCE_SHA}" ]] || fail 'checkout does not match source SHA'
REMOTE_MAIN="$(git ls-remote --exit-code --heads origin refs/heads/main | awk 'NR == 1 {print $1}')"
[[ "${REMOTE_MAIN}" == "${SOURCE_SHA}" ]] || fail 'source SHA is not current remote main'
TITLE="$(sed -n '1s/^# //p' "${NOTES}")"
[[ -n "${TITLE}" ]] || fail 'release notes need a level-one title'

if git rev-parse --verify --quiet "refs/tags/${VERSION}" >/dev/null; then
  [[ "$(git cat-file -t "refs/tags/${VERSION}")" == tag ]] || fail 'tag is not annotated'
  [[ "$(git rev-list -n 1 "${VERSION}")" == "${SOURCE_SHA}" ]] || fail 'tag points elsewhere'
elif [[ "${MODE}" == draft && "${PHASE}" == prepare ]]; then
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git tag -a "${VERSION}" -m "${TITLE}" "${SOURCE_SHA}"
  git push origin "refs/tags/${VERSION}"
else
  fail 'publish requires the reviewed annotated tag created with the draft'
fi

if [[ "${MODE}" == draft ]]; then
  [[ "${PHASE}" == prepare ]] || fail 'draft mode has no finalize phase'
  if gh release view "${VERSION}" --repo "${REPOSITORY}" >/dev/null 2>&1; then
    gh release edit "${VERSION}" --repo "${REPOSITORY}" --target "${SOURCE_SHA}" --title "${TITLE}" --notes-file "${NOTES}" --draft
  else
    gh release create "${VERSION}" --repo "${REPOSITORY}" --verify-tag --target "${SOURCE_SHA}" --title "${TITLE}" --notes-file "${NOTES}" --draft
  fi
elif [[ "${PHASE}" == prepare ]]; then
  gh release view "${VERSION}" --repo "${REPOSITORY}" --json isDraft --jq '.isDraft' | grep -qx true || fail 'publish requires an existing draft'
else
  gh release edit "${VERSION}" --repo "${REPOSITORY}" --draft=false --latest
fi

ASSET_COUNT="$(gh release view "${VERSION}" --repo "${REPOSITORY}" --json assets --jq '.assets | length')"
[[ "${ASSET_COUNT}" == 0 ]] || fail 'unexpected uploaded release assets'
printf '[release] verified %s/%s %s at %s\n' "${MODE}" "${PHASE}" "${VERSION}" "${SOURCE_SHA}"
