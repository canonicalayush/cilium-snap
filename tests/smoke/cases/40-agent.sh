#!/bin/bash
# Agent: the standalone configuration the snap exists to produce.

test_agent_status_ok() {
  local state
  state="$(cilium_status_field '.cilium.state')"
  assert_eq "Ok" "$state" "agent reports overall state Ok"
}

test_running_without_kubernetes() {
  # The entire point of this snap. If this ever reports anything but Disabled,
  # the agent has found an apiserver and the standalone path is untested.
  local state
  state="$(cilium_status_field '.kubernetes.state')"
  assert_eq "Disabled" "$state" "Kubernetes integration is disabled"
}

test_ipam_cluster_pool_active() {
  local ipam_status configured_range
  ipam_status="$(cilium_status_field '.ipam.status')"
  configured_range="$(snap_config IPV4_RANGE)"

  assert_contains "$ipam_status" "$configured_range" \
    "IPAM allocates from the configured range ($configured_range)"
  assert_matches "$ipam_status" "IPv4: [0-9]+/[0-9]+ allocated" \
    "IPAM reports IPv4 allocation counters"
}

# --- cilium-ipam-reserve ------------------------------------------------
# cluster-pool's per-node CIDR is a hand-set flag with no operator to
# allocate it (see bin/cilium-ipam-reserve); these confirm the running
# agent claimed its own range in etcd, and that a second node claiming an
# overlapping range is refused rather than silently starting.

ipam_reserve_bin() {
  printf '/snap/%s/current/bin/cilium-ipam-reserve' "$SNAP_NAME"
}

# etcd_host_port -- echoes "<host> <port>" parsed from the configured
# etcd-listen-url, same form cilium-agent-wrapper parses.
etcd_host_port() {
  local url
  url="$(snap_config ETCD_LISTEN_URL)"
  [[ "$url" =~ ^https?://(\[[^]]+\]|[^:/]+):([0-9]+)/?$ ]] \
    || fail "ETCD_LISTEN_URL in config.env is not host:port form: $url"
  printf '%s %s' "${BASH_REMATCH[1]//[\[\]]/}" "${BASH_REMATCH[2]}"
}

test_ipam_range_claimed_in_etcd() {
  local node_name configured_range claimed
  node_name="$(snap_config NODE_NAME)"
  [ -n "$node_name" ] || node_name="$(hostname)"
  configured_range="$(snap_config IPV4_RANGE)"

  claimed="$("$ETCDCTL" get "cilium-snap/ipam/claims/${node_name}" --print-value-only 2>&1)" \
    || fail "failed to read this node's IPAM claim from etcd: $claimed"
  assert_eq "$configured_range" "$claimed" \
    "this node's configured ipv4-range is claimed in etcd under its own name"
}

test_ipam_collision_rejected() {
  # Simulates a second node racing to claim a range that overlaps the
  # already-running agent's. Must be refused, not silently accepted.
  # set -eu is active per-case (lib/harness.sh run_case), so the expected
  # non-zero exit below has to be caught by a conditional, not $?.
  local host port overlapping other_node out
  read -r host port < <(etcd_host_port)
  overlapping="$(snap_config IPV4_RANGE)"
  other_node="cilium-smoke-other-node-$$"
  trap '"$ETCDCTL" del "cilium-snap/ipam/claims/${other_node}" >/dev/null 2>&1 || true' EXIT

  if out="$("$(ipam_reserve_bin)" claim "$other_node" "$host" "$port" "$overlapping" 2>&1)"; then
    fail "cilium-ipam-reserve accepted an overlapping claim for a second node"
  fi
  assert_contains "$out" "overlaps node" "rejection names the colliding node"

  local leaked
  leaked="$("$ETCDCTL" get "cilium-snap/ipam/claims/${other_node}" --print-value-only 2>/dev/null)"
  assert_eq "" "$leaked" "the rejected claim was not written to etcd"
}

test_ipam_disjoint_claim_accepted() {
  # A genuinely free range must still be claimable -- the check rejects
  # collisions, not every second claimant.
  local host port other_node out
  read -r host port < <(etcd_host_port)
  other_node="cilium-smoke-other-node-$$"
  trap '"$ETCDCTL" del "cilium-snap/ipam/claims/${other_node}" >/dev/null 2>&1 || true' EXIT

  out="$("$(ipam_reserve_bin)" claim "$other_node" "$host" "$port" "172.31.0.0/16" 2>&1)" \
    || fail "cilium-ipam-reserve rejected a disjoint range: $out"

  local claimed
  claimed="$("$ETCDCTL" get "cilium-snap/ipam/claims/${other_node}" --print-value-only)"
  assert_eq "172.31.0.0/16" "$claimed" "the disjoint claim was written to etcd"
}

test_identity_allocation_via_kvstore() {
  # --identity-allocation-mode=kvstore is what replaces CiliumIdentity CRDs.
  local range_min range_max
  range_min="$(cilium_status_field '.["identity-range"]["min-identity"]')"
  range_max="$(cilium_status_field '.["identity-range"]["max-identity"]')"
  assert_ne "null" "$range_min" "agent exposes a global identity range minimum"
  [ "$range_max" -gt "$range_min" ] || fail "identity range is empty: $range_min..$range_max"
  log "ok: global identity range $range_min..$range_max"
}

test_controllers_healthy() {
  local json total failing
  json="$("$CILIUM_DBG" status --all-controllers -o json 2>/dev/null)"
  total="$(printf '%s' "$json" | jq -r '.controllers | length')"
  [ "$total" -gt 0 ] || fail "agent reports no controllers at all"

  failing="$(printf '%s' "$json" \
    | jq -r '[.controllers[] | select((.status["consecutive-failure-count"] // 0) > 0) | .name] | join(", ")')"
  assert_eq "" "$failing" "no controller is in consecutive failure ($total controllers running)"
}

test_host_endpoint_present() {
  # The agent always manages a reserved:host endpoint for the node itself.
  local host_ep
  host_ep="$("$CILIUM_DBG" endpoint list -o json \
    | jq -r '[.[] | select(.status.labels["security-relevant"][]? == "reserved:host")] | length')"
  assert_eq "1" "$host_ep" "the reserved:host endpoint exists"
}

test_routing_and_masquerade_configuration() {
  local routing masq_enabled snat_exclusion
  routing="$(cilium_status_field '.routing["inter-host-routing-mode"]')"
  # Status spells the mode with a leading capital; the config key is lowercase.
  assert_eq "$(snap_config ROUTING_MODE)" "$(printf '%s' "$routing" | tr '[:upper:]' '[:lower:]')" \
    "agent uses the configured routing mode"

  masq_enabled="$(cilium_status_field '.masquerading.enabled')"
  assert_eq "true" "$masq_enabled" "IPv4 masquerading is enabled for pod egress"

  # Native routing plus masquerade requires an explicit native routing CIDR;
  # the agent turns that into the SNAT exclusion range.
  snat_exclusion="$(cilium_status_field '.masquerading["snat-exclusion-cidr-v4"]')"
  assert_eq "$(snap_config NATIVE_ROUTING_CIDR)" "$snat_exclusion" \
    "pod-to-pod traffic is excluded from SNAT"
}

test_proxy_binds_router_ip() {
  local proxy_ip
  proxy_ip="$(cilium_status_field '.proxy.ip')"
  assert_eq "$(snap_config LOCAL_ROUTER_IPV4)" "$proxy_ip" \
    "proxy binds the configured router IP"
}

test_cni_config_management_disabled() {
  # There is no kubelet here, so the agent must not try to own the CNI
  # conflist; install-cni writes it instead.
  local state
  state="$(cilium_status_field '.["cni-file"].state')"
  assert_eq "Disabled" "$state" "agent does not manage the CNI configuration file"

  local chaining
  chaining="$(cilium_status_field '.["cni-chaining"].mode')"
  assert_eq "none" "$chaining" "CNI chaining is not in use"
}
