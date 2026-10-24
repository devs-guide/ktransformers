#!/usr/bin/env bash

KT_BLOCKED=3
KT_USAGE=64

kt_log() {
  printf '[ktransformers][%s] %s\n' "$1" "$2" >&2
}

kt_fail() {
  local code="$1"
  shift
  kt_log error "$*"
  exit "${code}"
}

kt_need() {
  command -v "$1" >/dev/null 2>&1 || kt_fail "${KT_BLOCKED}" "required command is unavailable: $1"
}

kt_require_linux() {
  [[ "$(uname -s)" == Linux ]] || kt_fail "${KT_BLOCKED}" 'target tooling requires Linux'
}

kt_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

kt_json_status() {
  python3 - "$@" <<'PY'
import json
import sys

items = sys.argv[1:]
if len(items) % 2:
    raise SystemExit("JSON status arguments must be key/value pairs")
record = {items[index]: items[index + 1] for index in range(0, len(items), 2)}
print(json.dumps(record, sort_keys=True))
PY
}

kt_positive_number() {
  python3 - "$1" <<'PY'
import math
import sys
try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if math.isfinite(value) and value >= 0 else 1)
PY
}
