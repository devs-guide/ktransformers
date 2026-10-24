#!/usr/bin/env bash
set -euo pipefail

TARGET="${KTRANSFORMERS_TARGET:-}"
SOURCE_SHA="${KTRANSFORMERS_SOURCE_SHA:-}"
PAGES_BASE="${KTRANSFORMERS_PAGES_BASE:-https://devs-guide.github.io/ktransformers}"

usage() {
  printf 'usage: %s --target USER@HOST --source-sha SHA [--pages-base URL] -- setup/RUNNER.sh MODE [ARGS...]\n' "$0" >&2
  exit 64
}

while (($#)); do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --source-sha) SOURCE_SHA="${2:-}"; shift 2 ;;
    --pages-base) PAGES_BASE="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done

[[ -n "${TARGET}" && "${TARGET}" != -* && "${TARGET}" != *$'\n'* ]] || usage
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "${PAGES_BASE}" == https://* ]] || usage
(($# >= 2)) || usage
[[ "$1" =~ ^setup/[a-z0-9._-]+\.sh$ ]] || usage

printf -v remote_command 'set -o pipefail; curl -fsSL --proto =https %q | bash -s -- %q %q' \
  "${PAGES_BASE%/}/tools/dispatch.sh" "${PAGES_BASE%/}" "${SOURCE_SHA}"
for argument in "$@"; do
  printf -v remote_command '%s %q' "${remote_command}" "${argument}"
done

exec ssh -tt "${TARGET}" "${remote_command}"
