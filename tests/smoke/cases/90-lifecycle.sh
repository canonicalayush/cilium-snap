#!/bin/bash
# Lifecycle: restarts must not leave the node half-networked, and the daemons
# must recover without manual intervention.

wait_agent_ok() {
  retry_until "${1:-180}" "agent reports state Ok" \
    bash -c "[ \"\$($CILIUM_DBG status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"
}

LIFECYCLE_NETCONF="/tmp/cilium-smoke-restart.json"

write_lifecycle_netconf() {
  cat >"$LIFECYCLE_NETCONF" <<'JSON'
{"cniVersion":"1.0.0","name":"cilium","type":"cilium-cni","enable-debug":false}
JSON
  smoke_teardown_netns "$LIFECYCLE_NETCONF"
}

test_agent_restart_recovers() {
  snap restart "$AGENT_SERVICE" >/dev/null || fail "snap restart of the agent failed"
  wait_agent_ok 180

  service_active "$AGENT_SERVICE" || fail "agent service is not active after restart"
  log "ok: agent service active after restart"

  local kvstore
  kvstore="$(cilium_status_field '.kvstore.state')"
  assert_eq "Ok" "$kvstore" "agent reconnected to the kvstore after restart"
}

test_existing_endpoint_survives_agent_restart() {
  # bpffs pinning lets a restarted agent reattach to existing endpoints
  # instead of blackholing their traffic. Map inodes are not asserted: the
  # agent repins maps on every start, so only endpoint continuity matters.
  trap 'smoke_teardown_netns "$LIFECYCLE_NETCONF"' EXIT
  write_lifecycle_netconf

  local ns="${SMOKE_NETNS_PREFIX}-survivor" result ip ep_before ep_after router
  router="$(snap_config LOCAL_ROUTER_IPV4)"

  ip netns add "$ns" 2>/dev/null || true
  result="$(cni_invoke ADD "$ns" "/var/run/netns/${ns}" "$LIFECYCLE_NETCONF")" \
    || fail "CNI ADD failed: $result"
  ip="$(printf '%s' "$result" | jq -r '.ips[0].address' | cut -d/ -f1)"
  ep_before="$(endpoint_id_for_container "$ns")"
  [ -n "$ep_before" ] || fail "no endpoint created for $ip"

  endpoint_resolve_identity "$ep_before" "app=smoke-survivor" 60 \
    || fail "endpoint never resolved an identity"
  retry_until 30 "workload has connectivity before the restart" \
    ip netns exec "$ns" ping -c 2 -W 2 "$router"

  snap restart "$AGENT_SERVICE" >/dev/null || fail "snap restart of the agent failed"
  wait_agent_ok 180

  ep_after="$(endpoint_id_for_container "$ns")"
  assert_eq "$ep_before" "$ep_after" "the endpoint kept its identity across the restart"

  retry_until 60 "workload still has connectivity after the restart" \
    ip netns exec "$ns" ping -c 2 -W 2 "$router"
}

test_etcd_restart_recovers() {
  snap restart "$ETCD_SERVICE" >/dev/null || fail "snap restart of etcd failed"

  retry_until 120 "etcd becomes healthy again" "$ETCDCTL" endpoint health
  retry_until 180 "agent reconnects to the restarted kvstore" \
    bash -c "[ \"\$($CILIUM_DBG status -o json 2>/dev/null | jq -r .kvstore.state)\" = Ok ]"

  # The node object is persisted, not just cached: it must still be there.
  local keys
  keys="$("$ETCDCTL" get cilium/state/nodes/ --prefix --keys-only)"
  assert_contains "$keys" "cilium/state/nodes/v1/default/" \
    "node state persisted across the etcd restart"
}

test_full_snap_restart_recovers() {
  snap restart "$SNAP_NAME" >/dev/null || fail "snap restart failed"

  retry_until 120 "etcd is healthy after a full restart" "$ETCDCTL" endpoint health
  wait_agent_ok 180

  local out
  out="$(snap services "$SNAP_NAME")"
  assert_matches "$out" "${AGENT_SERVICE}[[:space:]]+enabled[[:space:]]+active" \
    "cilium-agent is active after a full restart"
  assert_matches "$out" "${ETCD_SERVICE}[[:space:]]+enabled[[:space:]]+active" \
    "etcd is active after a full restart"
}

test_datapath_reattached_after_restart() {
  # A restart that leaves the host datapath detached is silent until traffic
  # fails, so assert the attachment explicitly.
  local devices
  devices="$(snap_config BPF_ROOT)/cilium/devices"
  assert_dir "${devices}/cilium_host/links" "host datapath reattached"

  local mode
  mode="$(cilium_status_field '.["attach-mode"]')"
  assert_eq "tcx" "$mode" "attach mode is still tcx after restart"
}

test_new_workload_after_restart() {
  # The other half of restart recovery: the CNI path still works for workloads
  # created after the fact, not just the ones that were already attached.
  trap 'smoke_teardown_netns "$LIFECYCLE_NETCONF"' EXIT
  write_lifecycle_netconf

  local ns="${SMOKE_NETNS_PREFIX}-restart" result ip ep
  ip netns add "$ns" 2>/dev/null || true
  result="$(cni_invoke ADD "$ns" "/var/run/netns/${ns}" "$LIFECYCLE_NETCONF")" \
    || fail "CNI ADD failed after restart: $result"
  ip="$(printf '%s' "$result" | jq -r '.ips[0].address' | cut -d/ -f1)"
  assert_ne "null" "$ip" "CNI still allocates addresses after a restart"

  ep="$(endpoint_id_for_container "$ns")"
  [ -n "$ep" ] || fail "no endpoint created after restart"
  endpoint_resolve_identity "$ep" "app=smoke-restart" 60 \
    || fail "endpoint never resolved an identity after restart"

  retry_until 30 "workload reaches the cilium router IP after restart" \
    ip netns exec "$ns" ping -c 2 -W 2 "$(snap_config LOCAL_ROUTER_IPV4)"
}
