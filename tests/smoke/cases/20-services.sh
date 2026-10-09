#!/bin/bash
# Services: both daemons are enabled, active, and the install hook laid out
# the state directories the wrappers expect.

test_services_enabled_and_active() {
  local out
  out="$(snap services "$SNAP_NAME" 2>&1)" || fail "snap services failed: $out"

  assert_matches "$out" "${AGENT_SERVICE}[[:space:]]+enabled[[:space:]]+active" \
    "cilium-agent service is enabled and active"
  assert_matches "$out" "${ETCD_SERVICE}[[:space:]]+enabled[[:space:]]+active" \
    "etcd service is enabled and active"
}

test_systemd_units_healthy() {
  local unit
  for unit in "$ETCD_SERVICE" "$AGENT_SERVICE"; do
    service_active "$unit" || fail "systemd unit snap.${unit}.service is not active"
    log "ok: snap.${unit}.service is active"

    # A unit that is active but has been restarting is not healthy; the agent
    # is restart-condition: on-failure, so a crash loop hides behind "active".
    local restarts
    restarts="$(systemctl show "snap.${unit}.service" -p NRestarts --value)"
    if [ "${restarts:-0}" -gt 0 ]; then
      warn "snap.${unit}.service has restarted ${restarts} time(s) since boot"
    fi
  done
}

test_start_ordering() {
  # snapcraft.yaml orders etcd before cilium-agent; without it the agent
  # races the kvstore and only the wrapper's TCP poll saves it.
  local after
  after="$(systemctl show "snap.${AGENT_SERVICE}.service" -p After --value)"
  assert_contains "$after" "snap.${ETCD_SERVICE}.service" \
    "cilium-agent is ordered after etcd"
}

test_state_directories_created() {
  # Created by the install hook; the wrappers mkdir them too, but a missing
  # hook would silently change ownership semantics on refresh.
  assert_dir "${SNAP_COMMON}/etcd/data" "etcd data directory"
  assert_dir "${SNAP_COMMON}/cilium/state" "cilium state directory"
  assert_dir "${SNAP_COMMON}/cilium/lib" "cilium lib directory"
}

test_datapath_sources_staged() {
  # cilium-agent-wrapper rsyncs the eBPF C sources out of the read-only $SNAP
  # into SNAP_COMMON on every start, because --lib-dir must be writable.
  assert_dir "${SNAP_COMMON}/cilium/lib/bpf" "staged eBPF source tree"
  assert_file "${SNAP_COMMON}/cilium/lib/bpf/bpf_lxc.c" "bpf_lxc.c staged for runtime compilation"

  local count
  count="$(find "${SNAP_COMMON}/cilium/lib/bpf" -name '*.h' | wc -l)"
  [ "$count" -gt 10 ] || fail "expected the bpf header tree to be staged, found only $count headers"
  log "ok: $count eBPF headers staged"
}

test_no_fatal_logs_in_current_run() {
  # Scoped to the current invocation, not a time window: an agent restart
  # mid-compile cancels clang and exits with `level=fatal` by design, so
  # older invocations carry expected noise.
  local unit inv out
  for unit in "$ETCD_SERVICE" "$AGENT_SERVICE"; do
    inv="$(systemctl show "snap.${unit}.service" -p InvocationID --value)"
    [ -n "$inv" ] || fail "snap.${unit}.service has no current invocation"

    out="$(journalctl "_SYSTEMD_INVOCATION_ID=${inv}" --no-pager 2>/dev/null || true)"
    assert_not_contains "$out" "panic:" "no panic in the current snap.${unit}.service run"
    assert_not_contains "$out" "level=fatal" "no fatal log in the current snap.${unit}.service run"
  done
}
