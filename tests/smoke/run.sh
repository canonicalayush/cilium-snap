#!/bin/bash
# Smoke test runner for the cilium-snap package.
#
# Runs as root on the machine under test. It does not build anything: point it
# at an already-installed snap, or hand it a .snap file to install first.
#
#   sudo tests/smoke/run.sh
#   sudo tests/smoke/run.sh --snap ./cilium-snap_*.snap
#   sudo tests/smoke/run.sh --filter connectivity
#   sudo tests/smoke/run.sh --list
#
# Exit status is non-zero if any case fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="${SCRIPT_DIR}/cases"

SNAP_FILE=""
FILTER=""
LIST_ONLY=0
KEEP_INSTALL=1

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --snap)    SNAP_FILE="${2:?--snap needs a path}"; shift 2 ;;
    --filter)  FILTER="${2:?--filter needs a pattern}"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    --remove)  KEEP_INSTALL=0; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done

# shellcheck source=lib/harness.sh
. "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=lib/snap.sh
. "${SCRIPT_DIR}/lib/snap.sh"

require_root() {
  [ "$(id -u)" -eq 0 ] || { printf 'this suite must run as root\n' >&2; exit 2; }
}

require_tools() {
  local missing=() tool
  for tool in jq ip ping pgrep snap systemctl findmnt mountpoint iptables-save; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'missing required tools: %s\n' "${missing[*]}" >&2
    exit 2
  fi
}

ensure_etcd_configured() {
  # cilium-agent's kvstore is now the separately-installed `etcd` snap, not
  # bundled into cilium-snap: install it if missing, then (re)configure and
  # start it unconditionally so a reused host's stale etcd.conf.yml can't
  # leave the agent pointed at a dead kvstore.
  if ! snap list etcd >/dev/null 2>&1; then
    info "installing the etcd snap"
    snap install etcd || { printf 'failed to install the etcd snap\n' >&2; exit 2; }
  fi
  info "configuring etcd via ${SNAP_NAME}.setup-etcd"
  "${SNAP_NAME}.setup-etcd" --force \
    || { printf '%s.setup-etcd failed\n' "$SNAP_NAME" >&2; exit 2; }
}

install_snap_file() {
  local file="$1"
  [ -f "$file" ] || { printf 'no such snap file: %s\n' "$file" >&2; exit 2; }

  info "installing $file"
  snap install --dangerous --classic "$file" || { printf 'snap install failed\n' >&2; exit 2; }

  ensure_etcd_configured

  info "waiting for services to settle"
  retry_until 180 "agent reports state Ok after install" \
    bash -c "[ \"\$(${SNAP_NAME}.cilium-dbg status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]" \
    || exit 1
}

global_cleanup() {
  smoke_teardown_netns /tmp/cilium-smoke-netconf.json
  smoke_teardown_netns /tmp/cilium-smoke-restart.json
  rm -f /tmp/cilium-smoke-netconf.json /tmp/cilium-smoke-restart.json \
        /tmp/cilium-smoke-injection
  snap unset "$SNAP_NAME" debug >/dev/null 2>&1 || true
  snap unset "$SNAP_NAME" extra-args >/dev/null 2>&1 || true
  if [ "$KEEP_INSTALL" -eq 0 ]; then
    info "removing $SNAP_NAME"
    snap remove --purge "$SNAP_NAME" >/dev/null 2>&1 || true
  fi
}

collect_cases() {
  # Reads `test_*` names from the file, not `declare -F` (which sorts), so
  # cases run in the order the author wrote them.
  local file fn
  for file in "$CASES_DIR"/*.sh; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in
      *"$FILTER"*) ;;
      *) continue ;;
    esac

    # shellcheck disable=SC1090
    . "$file"

    while read -r fn; do
      [ -n "$fn" ] || continue
      CASE_FILES["$fn"]="$(basename "$file")"
      CASE_ORDER+=("$fn")
    done < <(grep -oE '^test_[A-Za-z0-9_]+' "$file")
  done
}

declare -A CASE_FILES=()
CASE_ORDER=()

require_root
require_tools
collect_cases

if [ "${#CASE_ORDER[@]}" -eq 0 ]; then
  printf 'no test cases matched filter "%s"\n' "$FILTER" >&2
  exit 2
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for fn in "${CASE_ORDER[@]}"; do
    printf '%-28s %s\n' "${CASE_FILES[$fn]}" "$fn"
  done
  exit 0
fi

trap global_cleanup EXIT
[ -n "$SNAP_FILE" ] && install_snap_file "$SNAP_FILE"

printf '%scilium-snap smoke tests%s\n' "$C_BOLD" "$C_RESET"
printf '  host     %s (%s)\n' "$(hostname)" "$(uname -r)"
printf '  snap     %s\n' "$(snap list "$SNAP_NAME" 2>/dev/null | awk 'NR==2 {print $2" (rev "$3")"}')"
printf '  cases    %d\n\n' "${#CASE_ORDER[@]}"

CURRENT_FILE=""
for fn in "${CASE_ORDER[@]}"; do
  if [ "${CASE_FILES[$fn]}" != "$CURRENT_FILE" ]; then
    CURRENT_FILE="${CASE_FILES[$fn]}"
    printf '%s--- %s%s\n' "$C_BLUE" "$CURRENT_FILE" "$C_RESET"
  fi
  run_case "$fn"
done

print_summary
