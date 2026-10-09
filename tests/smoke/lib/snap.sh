#!/bin/bash
# Snap-specific helpers shared by the smoke test cases.

SNAP_NAME="${SNAP_NAME:-cilium-snap}"
SNAP_COMMON="/var/snap/${SNAP_NAME}/common"
SNAP_DATA_DIR="/var/snap/${SNAP_NAME}/current"

CILIUM_DBG="${SNAP_NAME}.cilium-dbg"
ETCDCTL="${SNAP_NAME}.etcdctl"
HUBBLE="${SNAP_NAME}.hubble"
INSTALL_CNI="${SNAP_NAME}.install-cni"

AGENT_SERVICE="${SNAP_NAME}.cilium-agent"
ETCD_SERVICE="${SNAP_NAME}.etcd"

# Namespaces and container ids created by the connectivity case. Tracked here
# so the top-level cleanup can tear them down even if a case aborts midway.
SMOKE_NETNS_PREFIX="cilium-smoke"

snap_config() {
  # snap_config <KEY> -- effective value from the rendered config.env, falling
  # back to the shipped default. Both wrappers read these exact files.
  local key="$1" value=""
  if [ -f "${SNAP_DATA_DIR}/config.env" ]; then
    value="$(grep -E "^${key}=" "${SNAP_DATA_DIR}/config.env" | tail -1 | cut -d= -f2-)"
  fi
  if [ -z "$value" ] && [ -f "/snap/${SNAP_NAME}/current/etc/defaults.env" ]; then
    value="$(grep -E "^${key}=" "/snap/${SNAP_NAME}/current/etc/defaults.env" | tail -1 | cut -d= -f2-)"
  fi
  # The configure hook writes %q-quoted values; strip the shell quoting.
  printf '%s' "$value" | sed -E "s/^'(.*)'$/\1/"
}

cilium_status_json() {
  "$CILIUM_DBG" status -o json 2>/dev/null
}

cilium_status_field() {
  # cilium_status_field <jq-filter>
  cilium_status_json | jq -r "$1"
}

service_active() {
  systemctl is-active --quiet "snap.${1}.service"
}

# cni_conf_path echoes the conflist path that install-cni writes to.
cni_conf_path() {
  local out
  out="$("$INSTALL_CNI" 2>&1)" || return 1
  printf '%s' "$out" | sed -n 's/.*installed CNI config *-> *//p' | tail -1
}

# cni_invoke <ADD|DEL|CHECK> <container-id> <netns-path> <netconf-file>
cni_invoke() {
  local command="$1" id="$2" netns="$3" conf="$4"
  CNI_COMMAND="$command" \
  CNI_CONTAINERID="$id" \
  CNI_NETNS="$netns" \
  CNI_IFNAME=eth0 \
  CNI_PATH="${CNI_BIN_DIR:-/opt/cni/bin}" \
    "${CNI_BIN_DIR:-/opt/cni/bin}/cilium-cni" <"$conf"
}

# endpoint_id_for_container <container-id>
#
# Keyed on the CNI attachment ID, not the IP: IPAM reuses a freed IP
# immediately, so an IP lookup can match the endpoint being torn down.
endpoint_id_for_container() {
  "$CILIUM_DBG" endpoint list -o json 2>/dev/null \
    | jq -r --arg id "${1}:eth0" \
           '.[] | select(.status["external-identifiers"]["cni-attachment-id"]? == $id) | .id' \
    | head -1
}

# Labels the endpoint and waits for an identity, atomically: a fresh
# endpoint already reports state=ready while still on identity 5
# (reserved:init), so waiting on state alone is not a safe condition.
#
# endpoint_resolve_identity <endpoint-id> <label> [timeout-seconds]
endpoint_resolve_identity() {
  # Note: bash evaluates arithmetic in a multi-name `local` before the earlier
  # names on the same line are assigned, so `deadline` gets its own statement.
  local id="$1" label="$2" timeout="${3:-60}" snapshot=""
  local deadline=$((SECONDS + timeout))

  "$CILIUM_DBG" endpoint labels "$id" --add "$label" >/dev/null
  "$CILIUM_DBG" endpoint labels "$id" --delete "reserved:init" >/dev/null 2>&1 || true

  while [ "$SECONDS" -lt "$deadline" ]; do
    snapshot="$("$CILIUM_DBG" endpoint get "$id" -o json 2>/dev/null \
      | jq -r '.[0] | "\(.status.state)|\(.status.identity.id)|\(.status.labels["security-relevant"] | join(","))"')"
    case "$snapshot" in
      ready\|*)
        local identity="${snapshot#*|}"
        identity="${identity%%|*}"
        local labels="${snapshot##*|}"
        case "$labels" in
          *reserved:init*) ;;
          *) [ "${identity:-0}" -ge 256 ] && return 0 ;;
        esac
        ;;
    esac
    sleep 1
  done

  printf 'endpoint %s never resolved an identity (last: %s)\n' "$id" "${snapshot:-unknown}" >&2
  return 1
}

# smoke_endpoint_count -- how many endpoints the agent still holds under a
# smoke attachment ID.
smoke_endpoint_count() {
  "$CILIUM_DBG" endpoint list -o json 2>/dev/null \
    | jq -r --arg p "$SMOKE_NETNS_PREFIX" \
           '[.[] | select(.status["external-identifiers"]["cni-attachment-id"]? // "" | startswith($p))] | length' \
    2>/dev/null || printf '0'
}

# smoke_teardown_netns <netconf-file>
#
# Best-effort, never aborts the caller. Deletes the namespace and
# disconnects any endpoint still keyed to its CNI attachment ID (a
# deleted namespace alone leaves a stale attachment blocking the next
# ADD), then waits for it to vanish -- IPAM reuses the IP immediately,
# so returning early races the next attach.
smoke_teardown_netns() {
  local conf="${1:-}" ns ep

  for ns in $(ip netns list 2>/dev/null | awk '{print $1}' | grep "^${SMOKE_NETNS_PREFIX}" || true); do
    if [ -n "$conf" ] && [ -f "$conf" ]; then
      cni_invoke DEL "$ns" "/var/run/netns/$ns" "$conf" >/dev/null 2>&1 || true
    fi
    ip netns del "$ns" >/dev/null 2>&1 || true
  done

  for ep in $("$CILIUM_DBG" endpoint list -o json 2>/dev/null \
                | jq -r --arg p "$SMOKE_NETNS_PREFIX" \
                       '.[] | select(.status["external-identifiers"]["cni-attachment-id"]? // "" | startswith($p)) | .id' \
                || true); do
    "$CILIUM_DBG" endpoint disconnect "$ep" >/dev/null 2>&1 || true
  done

  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(smoke_endpoint_count)" = "0" ] && return 0
    sleep 1
  done
  printf 'warning: smoke endpoints still present after teardown\n' >&2
}

# ip_in_cidr <ipv4> <cidr> -- exit 0 when the address falls inside the range.
ip_in_cidr() {
  local ip="$1" cidr="$2" base prefix
  base="${cidr%%/*}"
  prefix="${cidr##*/}"

  _ipv4_to_int() {
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    printf '%s' "$(((a << 24) | (b << 16) | (c << 8) | d))"
  }

  local ip_int base_int mask
  ip_int="$(_ipv4_to_int "$ip")"
  base_int="$(_ipv4_to_int "$base")"
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))

  [ $((ip_int & mask)) -eq $((base_int & mask)) ]
}
