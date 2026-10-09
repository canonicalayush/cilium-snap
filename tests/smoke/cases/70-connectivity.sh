#!/bin/bash
# Connectivity: drives the CNI plugin like a real runtime and proves the
# datapath forwards traffic between attached network namespaces.

SMOKE_NETCONF="/tmp/cilium-smoke-netconf.json"
SMOKE_NS_A="${SMOKE_NETNS_PREFIX}-a"
SMOKE_NS_B="${SMOKE_NETNS_PREFIX}-b"

write_netconf() {
  # A single plugin, not the shipped conflist: chaining through portmap would
  # need cnitool, and the cilium plugin is what this snap owns.
  cat >"$SMOKE_NETCONF" <<'JSON'
{
  "cniVersion": "1.0.0",
  "name": "cilium",
  "type": "cilium-cni",
  "enable-debug": false
}
JSON
  # A case that aborted mid-attach leaves an endpoint registered under the
  # same CNI attachment ID, which makes every later ADD fail. Sweep first.
  smoke_teardown_netns "$SMOKE_NETCONF"
}

# attach_namespace <netns-name> <label> -> echoes the allocated IPv4
attach_namespace() {
  local ns="$1" label="$2" result ip ep

  ip netns add "$ns" 2>/dev/null || true
  result="$(cni_invoke ADD "$ns" "/var/run/netns/${ns}" "$SMOKE_NETCONF")" \
    || { printf 'CNI ADD failed for %s: %s\n' "$ns" "$result" >&2; return 1; }

  ip="$(printf '%s' "$result" | jq -r '.ips[0].address' | cut -d/ -f1)"
  if [ -z "$ip" ] || [ "$ip" = "null" ]; then
    printf 'CNI ADD returned no IP for %s\n' "$ns" >&2
    return 1
  fi

  ep="$(endpoint_id_for_container "$ns")"
  [ -n "$ep" ] || { printf 'no cilium endpoint for %s (%s)\n' "$ns" "$ip" >&2; return 1; }

  # Without an orchestrator the endpoint stays in reserved:init, where the
  # datapath default-denies traffic until an identity is resolved.
  endpoint_resolve_identity "$ep" "$label" 60 || return 1

  printf '%s' "$ip"
}

test_cni_add_allocates_from_pod_cidr() {
  trap 'smoke_teardown_netns "$SMOKE_NETCONF"' EXIT
  write_netconf

  local ip range
  ip="$(attach_namespace "$SMOKE_NS_A" "app=smoke-a")" || fail "could not attach $SMOKE_NS_A"
  range="$(snap_config IPV4_RANGE)"
  info "allocated $ip"

  # Belongs to the configured /16 pod range.
  ip_in_cidr "$ip" "$range" || fail "allocated IP $ip is outside the pod CIDR $range"
  log "ok: allocated IP is inside the pod CIDR ($range)"

  # The namespace really got the address and the cilium gateway route.
  local ns_addr ns_route
  ns_addr="$(ip netns exec "$SMOKE_NS_A" ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
  assert_eq "$ip" "$ns_addr" "namespace interface carries the allocated IP"

  ns_route="$(ip netns exec "$SMOKE_NS_A" ip -4 route show default)"
  assert_contains "$ns_route" "$(snap_config LOCAL_ROUTER_IPV4)" \
    "namespace default route points at the cilium router IP"

  # IPAM accounting moved.
  local ipam
  ipam="$(cilium_status_field '.ipam.status')"
  assert_matches "$ipam" "IPv4: [1-9][0-9]*/" "IPAM reports at least one allocated address"
}

test_pod_to_pod_connectivity() {
  trap 'smoke_teardown_netns "$SMOKE_NETCONF"' EXIT
  write_netconf

  local ip_a ip_b
  ip_a="$(attach_namespace "$SMOKE_NS_A" "app=smoke-a")" || fail "could not attach $SMOKE_NS_A"
  ip_b="$(attach_namespace "$SMOKE_NS_B" "app=smoke-b")" || fail "could not attach $SMOKE_NS_B"
  info "endpoints: $ip_a <-> $ip_b"

  retry_until 30 "pod A reaches pod B" \
    ip netns exec "$SMOKE_NS_A" ping -c 2 -W 2 "$ip_b"
  retry_until 30 "pod B reaches pod A" \
    ip netns exec "$SMOKE_NS_B" ping -c 2 -W 2 "$ip_a"
}

test_pod_to_host_connectivity() {
  trap 'smoke_teardown_netns "$SMOKE_NETCONF"' EXIT
  write_netconf

  local ip_a host_ip
  ip_a="$(attach_namespace "$SMOKE_NS_A" "app=smoke-a")" || fail "could not attach $SMOKE_NS_A"
  host_ip="$(ip -4 -o addr show "$(ip -4 route show default | awk '{print $5; exit}')" \
    | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$host_ip" ] || skip "host has no routable IPv4 address"

  retry_until 30 "pod reaches the host node IP ($host_ip)" \
    ip netns exec "$SMOKE_NS_A" ping -c 2 -W 2 "$host_ip"
}

test_pod_egress_is_masqueraded() {
  trap 'smoke_teardown_netns "$SMOKE_NETCONF"' EXIT
  write_netconf

  local gateway ip_a
  gateway="$(ip -4 route show default | awk '{print $3; exit}')"
  [ -n "$gateway" ] || skip "host has no default gateway to egress through"

  # Some hosted networks never answer ICMP on the gateway at all; confirm
  # the host itself can reach it before asserting the pod can, so a network
  # policy outside the snap's control is skipped, not reported as a failure.
  ping -c 1 -W 2 "$gateway" >/dev/null 2>&1 \
    || skip "host cannot reach gateway $gateway via ICMP in this network"

  ip_a="$(attach_namespace "$SMOKE_NS_A" "app=smoke-a")" || fail "could not attach $SMOKE_NS_A"

  # The pod CIDR is not routable off-host, so reaching the gateway at all
  # proves the SNAT rules the agent installed are doing their job.
  retry_until 30 "pod egresses to the default gateway ($gateway)" \
    ip netns exec "$SMOKE_NS_A" ping -c 2 -W 2 "$gateway"
}

test_cni_del_releases_endpoint() {
  trap 'smoke_teardown_netns "$SMOKE_NETCONF"' EXIT
  write_netconf

  local ip ep_before ep_after
  ip="$(attach_namespace "$SMOKE_NS_A" "app=smoke-a")" || fail "could not attach $SMOKE_NS_A"
  ep_before="$(endpoint_id_for_container "$SMOKE_NS_A")"
  assert_ne "" "$ep_before" "endpoint exists before CNI DEL"

  cni_invoke DEL "$SMOKE_NS_A" "/var/run/netns/${SMOKE_NS_A}" "$SMOKE_NETCONF" >/dev/null \
    || fail "CNI DEL failed"
  ip netns del "$SMOKE_NS_A" 2>/dev/null || true

  # Endpoint teardown is asynchronous.
  local deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    ep_after="$(endpoint_id_for_container "$SMOKE_NS_A")"
    [ -z "$ep_after" ] && break
    sleep 1
  done
  assert_eq "" "$ep_after" "CNI DEL removed the cilium endpoint"

  # And the lxc veth went with it.
  if ip link show "lxc$(printf '%s' "$ep_before")" >/dev/null 2>&1; then
    fail "host-side veth for endpoint $ep_before survived CNI DEL"
  fi
  log "ok: host-side veth removed"
}

test_endpoint_in_init_state_is_denied() {
  # The one policy behaviour reachable without an apiserver: an endpoint with
  # no identity yet is default-denied.
  trap 'smoke_teardown_netns "$SMOKE_NETCONF"' EXIT
  write_netconf

  local ip_a ip_b result
  ip_a="$(attach_namespace "$SMOKE_NS_A" "app=smoke-a")" || fail "could not attach $SMOKE_NS_A"

  # Attach B but deliberately leave it in reserved:init.
  ip netns add "$SMOKE_NS_B" 2>/dev/null || true
  result="$(cni_invoke ADD "$SMOKE_NS_B" "/var/run/netns/${SMOKE_NS_B}" "$SMOKE_NETCONF")" \
    || fail "CNI ADD failed for $SMOKE_NS_B"
  ip_b="$(printf '%s' "$result" | jq -r '.ips[0].address' | cut -d/ -f1)"

  local ep_b labels
  ep_b="$(endpoint_id_for_container "$SMOKE_NS_B")"
  labels="$("$CILIUM_DBG" endpoint get "$ep_b" -o json | jq -r '.[0].status.labels["security-relevant"] | join(",")')"
  assert_contains "$labels" "reserved:init" "unlabelled endpoint stays in reserved:init"

  if ip netns exec "$SMOKE_NS_A" ping -c 2 -W 2 "$ip_b" >/dev/null 2>&1; then
    fail "traffic to an endpoint still in reserved:init was allowed"
  fi
  log "ok: datapath denies traffic to an endpoint in reserved:init"
}
