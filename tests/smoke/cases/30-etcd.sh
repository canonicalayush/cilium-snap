#!/bin/bash
# etcd: the bundled kvstore is reachable, writable, and actually carries the
# Cilium state that makes standalone operation possible.

ETCD_SMOKE_KEY="/cilium-snap-smoke/probe"

cleanup_etcd_key() {
  "$ETCDCTL" del "$ETCD_SMOKE_KEY" >/dev/null 2>&1 || true
}

test_etcd_endpoint_healthy() {
  local out
  out="$("$ETCDCTL" endpoint health 2>&1)" || fail "etcd endpoint health failed: $out"
  assert_contains "$out" "is healthy" "etcd endpoint reports healthy"

  local listen_url
  listen_url="$(snap_config ETCD_LISTEN_URL)"
  assert_contains "$out" "${listen_url#http://}" "etcd listens on the configured URL ($listen_url)"
}

test_etcd_read_write_roundtrip() {
  trap cleanup_etcd_key EXIT
  local value
  value="smoke-$$-$(date +%s)"

  assert_cmd "etcd accepts a write" "$ETCDCTL" put "$ETCD_SMOKE_KEY" "$value"

  local got
  got="$("$ETCDCTL" get "$ETCD_SMOKE_KEY" --print-value-only)"
  assert_eq "$value" "$got" "etcd returns the value that was written"

  "$ETCDCTL" del "$ETCD_SMOKE_KEY" >/dev/null
  got="$("$ETCDCTL" get "$ETCD_SMOKE_KEY" --print-value-only)"
  assert_eq "" "$got" "etcd deletes the key"
}

test_etcd_single_node_cluster() {
  # The wrapper starts a single-node, loopback-only cluster named cilium-snap.
  local out
  out="$("$ETCDCTL" member list 2>&1)" || fail "etcd member list failed: $out"
  assert_contains "$out" "$SNAP_NAME" "etcd member is named after the snap"

  local members
  members="$(printf '%s\n' "$out" | grep -c ',')"
  assert_eq "1" "$members" "etcd runs as a single-node cluster"
}

test_etcd_holds_cilium_node_state() {
  # This is the whole reason etcd is bundled: with --kvstore unset the agent
  # rewrites identity-allocation-mode to crd and needs an apiserver.
  local keys
  keys="$("$ETCDCTL" get cilium/state/nodes/ --prefix --keys-only 2>&1)" \
    || fail "failed to read cilium node state from etcd: $keys"
  assert_contains "$keys" "cilium/state/nodes/v1/default/" \
    "agent has registered its node object in the kvstore"

  local node_json
  node_json="$("$ETCDCTL" get cilium/state/nodes/ --prefix --print-value-only | head -1)"
  printf '%s' "$node_json" | jq empty 2>/dev/null \
    || fail "node object in etcd is not valid JSON: $node_json"
  log "ok: node object in etcd is valid JSON"

  local alloc_cidr
  alloc_cidr="$(printf '%s' "$node_json" | jq -r '.IPv4AllocCIDR.IP')"
  local configured_range
  configured_range="$(snap_config IPV4_RANGE)"
  assert_eq "${configured_range%%/*}" "$alloc_cidr" \
    "node advertises the configured pod CIDR base ($configured_range)"
}

test_agent_sees_kvstore() {
  local state msg
  state="$(cilium_status_field '.kvstore.state')"
  assert_eq "Ok" "$state" "agent reports kvstore state Ok"

  msg="$(cilium_status_field '.kvstore.msg')"
  assert_contains "$msg" "has-quorum=true" "kvstore has quorum"
  assert_contains "$msg" "1/1 connected" "agent is connected to its single etcd endpoint"
}
