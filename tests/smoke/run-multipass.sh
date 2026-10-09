#!/bin/bash
# Run the smoke suite inside a Multipass VM.
#
# The suite needs root, a real kernel and a free 127.0.0.1:2379, so it is not
# safe to run on a workstation directly. This wrapper provisions (or reuses) a
# VM, copies the snap and the tests in, and runs them there.
#
#   tests/smoke/run-multipass.sh --snap ./cilium-snap_*.snap
#   tests/smoke/run-multipass.sh --vm cilium-standalone          # reuse, snap already installed
#   tests/smoke/run-multipass.sh --create --snap ./cilium-snap_*.snap
#   tests/smoke/run-multipass.sh --vm scratch --create --delete  # throwaway VM
set -euo pipefail

VM_NAME="cilium-snap-smoke"
SNAP_FILE=""
CREATE=0
DELETE=0
FILTER=""
REMOTE_DIR="/home/ubuntu/cilium-snap-smoke"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vm)     VM_NAME="${2:?--vm needs a name}"; shift 2 ;;
    --snap)   SNAP_FILE="${2:?--snap needs a path}"; shift 2 ;;
    --filter) FILTER="${2:?--filter needs a pattern}"; shift 2 ;;
    --create) CREATE=1; shift ;;
    --delete) DELETE=1; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done

command -v multipass >/dev/null 2>&1 || {
  printf 'multipass is not installed\n' >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vm_exists() { multipass info "$VM_NAME" >/dev/null 2>&1; }

if [ "$CREATE" -eq 1 ]; then
  if vm_exists; then
    printf 'VM %s already exists; reusing it\n' "$VM_NAME"
  else
    printf 'launching %s\n' "$VM_NAME"
    # Building is done outside; these are sized for running the agent, the
    # bundled etcd and a handful of network namespaces.
    multipass launch 24.04 --name "$VM_NAME" --cpus 4 --memory 8G --disk 20G
  fi
fi

vm_exists || {
  printf 'no such VM: %s (pass --create to provision one)\n' "$VM_NAME" >&2
  exit 2
}

multipass start "$VM_NAME" >/dev/null 2>&1 || true

cleanup() {
  if [ "$DELETE" -eq 1 ]; then
    printf 'deleting %s\n' "$VM_NAME"
    multipass delete --purge "$VM_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf 'installing test prerequisites in %s\n' "$VM_NAME"
multipass exec "$VM_NAME" -- sudo apt-get update -qq
multipass exec "$VM_NAME" -- sudo apt-get install -y -qq jq iproute2 iputils-ping

# The distro etcd snap would claim 127.0.0.1:2379 before ours does.
multipass exec "$VM_NAME" -- sudo snap stop --disable etcd >/dev/null 2>&1 || true

printf 'copying the suite to %s:%s\n' "$VM_NAME" "$REMOTE_DIR"
multipass exec "$VM_NAME" -- rm -rf "$REMOTE_DIR"
multipass exec "$VM_NAME" -- mkdir -p "${REMOTE_DIR}/lib" "${REMOTE_DIR}/cases"
multipass transfer "${SCRIPT_DIR}/run.sh" "${VM_NAME}:${REMOTE_DIR}/run.sh"
for f in "${SCRIPT_DIR}"/lib/*.sh;   do multipass transfer "$f" "${VM_NAME}:${REMOTE_DIR}/lib/$(basename "$f")"; done
for f in "${SCRIPT_DIR}"/cases/*.sh; do multipass transfer "$f" "${VM_NAME}:${REMOTE_DIR}/cases/$(basename "$f")"; done
multipass exec "$VM_NAME" -- chmod +x "${REMOTE_DIR}/run.sh"

ARGS=()
if [ -n "$SNAP_FILE" ]; then
  [ -f "$SNAP_FILE" ] || { printf 'no such snap file: %s\n' "$SNAP_FILE" >&2; exit 2; }
  printf 'copying %s (this takes a moment)\n' "$SNAP_FILE"
  multipass transfer "$SNAP_FILE" "${VM_NAME}:${REMOTE_DIR}/cilium-snap.snap"
  ARGS+=(--snap "${REMOTE_DIR}/cilium-snap.snap")
fi
[ -n "$FILTER" ] && ARGS+=(--filter "$FILTER")

printf '\n'
multipass exec "$VM_NAME" --working-directory "$REMOTE_DIR" -- sudo ./run.sh "${ARGS[@]}"
