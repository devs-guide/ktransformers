#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${HERE}/common.sh"

MODE="${1:-}"
shift || true
OWNER=''
FINGERPRINT=''
ROOT_KEYS='/root/.ssh/authorized_keys'
STATE_ROOT='/var/lib/ktransformers/access'

usage() {
  printf 'usage: access.sh MODE --owner USER [--fingerprint SHA256:...] [--root-authorized-keys PATH]\n' >&2
  exit "${KT_USAGE}"
}

while (($#)); do
  case "$1" in
    --owner) OWNER="${2:-}"; shift 2 ;;
    --fingerprint) FINGERPRINT="${2:-}"; shift 2 ;;
    --root-authorized-keys) ROOT_KEYS="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${MODE}" =~ ^(preflight|apply|validate|rollback)$ ]] || usage
[[ "${OWNER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || usage
[[ "${EUID}" -eq 0 ]] || kt_fail "${KT_BLOCKED}" 'access management must run as root'
kt_require_linux
kt_need getent
kt_need ssh-keygen
getent passwd "${OWNER}" >/dev/null || kt_fail "${KT_BLOCKED}" "owner does not exist: ${OWNER}"

OWNER_HOME="$(getent passwd "${OWNER}" | cut -d: -f6)"
OWNER_GROUP="$(id -gn "${OWNER}")"
OWNER_KEYS="${OWNER_HOME}/.ssh/authorized_keys"
STATE_FILE="${STATE_ROOT}/${OWNER}.state"
MARKER="ktransformers-managed:${FINGERPRINT}"

fingerprint_line() {
  printf '%s\n' "$1" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'
}

select_root_key() {
  local line current matches=0 selected=''
  [[ -r "${ROOT_KEYS}" ]] || kt_fail "${KT_BLOCKED}" "root key file is unavailable: ${ROOT_KEYS}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    current="$(fingerprint_line "${line}" || true)"
    if [[ "${current}" == "${FINGERPRINT}" ]]; then
      selected="${line}"
      matches=$((matches + 1))
    fi
  done <"${ROOT_KEYS}"
  [[ "${matches}" -eq 1 ]] || kt_fail "${KT_BLOCKED}" "fingerprint matched ${matches} root keys; expected exactly one"
  printf '%s\n' "${selected}"
}

managed_count() {
  [[ -f "${OWNER_KEYS}" ]] || { printf '0\n'; return; }
  awk -v marker="${MARKER}" 'index($0, marker) {count++} END {print count + 0}' "${OWNER_KEYS}"
}

owner_fingerprint_count() {
  local line current count=0
  [[ -f "${OWNER_KEYS}" ]] || { printf '0\n'; return; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    current="$(fingerprint_line "${line}" || true)"
    [[ "${current}" != "${FINGERPRINT}" ]] || count=$((count + 1))
  done <"${OWNER_KEYS}"
  printf '%s\n' "${count}"
}

case "${MODE}" in
  preflight)
    [[ "${FINGERPRINT}" == SHA256:* ]] || usage
    select_root_key >/dev/null
    [[ "$(managed_count)" -eq 0 ]] || kt_fail "${KT_BLOCKED}" 'a matching managed key already exists'
    [[ "$(owner_fingerprint_count)" -eq 0 ]] || kt_fail "${KT_BLOCKED}" 'the selected key is already authorized for the owner'
    kt_json_status status ready mode preflight owner "${OWNER}"
    ;;
  apply)
    [[ "${FINGERPRINT}" == SHA256:* ]] || usage
    ROOT_LINE="$(select_root_key)"
    [[ "$(managed_count)" -eq 0 ]] || kt_fail "${KT_BLOCKED}" 'a matching managed key already exists'
    [[ "$(owner_fingerprint_count)" -eq 0 ]] || kt_fail "${KT_BLOCKED}" 'the selected key is already authorized for the owner'
    KEY_TYPE="$(awk '{print $1}' <<<"${ROOT_LINE}")"
    KEY_BODY="$(awk '{print $2}' <<<"${ROOT_LINE}")"
    [[ -n "${KEY_TYPE}" && -n "${KEY_BODY}" ]] || kt_fail "${KT_BLOCKED}" 'selected key line is malformed'
    MANAGED_LINE="${KEY_TYPE} ${KEY_BODY} ${MARKER}"
    install -d -m 0700 -o "${OWNER}" -g "${OWNER_GROUP}" "${OWNER_HOME}/.ssh"
    touch "${OWNER_KEYS}"
    chown "${OWNER}:${OWNER_GROUP}" "${OWNER_KEYS}"
    chmod 0600 "${OWNER_KEYS}"
    printf '%s\n' "${MANAGED_LINE}" >>"${OWNER_KEYS}"
    install -d -m 0700 "${STATE_ROOT}"
    printf '%s\n' "${FINGERPRINT}" >"${STATE_FILE}"
    chmod 0600 "${STATE_FILE}"
    kt_json_status status applied mode apply owner "${OWNER}"
    ;;
  validate)
    [[ -s "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'managed access state is absent'
    FINGERPRINT="$(cat "${STATE_FILE}")"
    MARKER="ktransformers-managed:${FINGERPRINT}"
    [[ "$(managed_count)" -eq 1 ]] || kt_fail "${KT_BLOCKED}" 'managed key count is not one'
    [[ "$(stat -c '%a' "${OWNER_HOME}/.ssh")" == 700 ]] || kt_fail "${KT_BLOCKED}" 'owner .ssh mode must be 0700'
    [[ "$(stat -c '%a' "${OWNER_KEYS}")" == 600 ]] || kt_fail "${KT_BLOCKED}" 'authorized_keys mode must be 0600'
    kt_json_status status accepted mode validate owner "${OWNER}"
    ;;
  rollback)
    [[ -s "${STATE_FILE}" ]] || kt_fail "${KT_BLOCKED}" 'managed access state is absent'
    FINGERPRINT="$(cat "${STATE_FILE}")"
    MARKER="ktransformers-managed:${FINGERPRINT}"
    TEMP="$(mktemp)"
    trap 'rm -f -- "${TEMP}"' EXIT
    awk -v marker="${MARKER}" 'index($0, marker) == 0' "${OWNER_KEYS}" >"${TEMP}"
    install -m 0600 -o "${OWNER}" -g "${OWNER_GROUP}" "${TEMP}" "${OWNER_KEYS}"
    rm -f -- "${STATE_FILE}"
    kt_json_status status rolled_back mode rollback owner "${OWNER}"
    ;;
esac
