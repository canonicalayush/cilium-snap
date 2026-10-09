#!/bin/bash
# Datapath: the mounts, pinned maps and runtime-compiled objects that make
# cilium-agent an actual dataplane rather than a daemon that merely starts.

test_bpffs_mounted() {
  # Pinned maps live here and must survive restarts (pkg/bpf/bpffs_linux.go).
  # snapd refused this mount for confined snaps (LP#2048506); the wrapper does it.
  assert_mountpoint "$(snap_config BPF_ROOT)" "bpf"
}

test_cgroup2_mounted() {
  # Required for the socket load-balancer attach points.
  assert_mountpoint "$(snap_config CGROUP_ROOT)" "cgroup2"
}

test_bpf_maps_pinned() {
  local bpf_root globals count
  bpf_root="$(snap_config BPF_ROOT)"
  globals="${bpf_root}/tc/globals"
  assert_dir "$globals" "pinned BPF map directory"

  count="$(find "$globals" -maxdepth 1 -name 'cilium_*' | wc -l)"
  [ "$count" -ge 20 ] || fail "expected the full cilium map set to be pinned, found $count"
  log "ok: $count cilium BPF maps pinned under $globals"

  # Spot-check the maps the standalone datapath cannot work without.
  local map
  for map in cilium_ipcache_v2 cilium_ct4_global cilium_lxc cilium_events; do
    [ -e "${globals}/${map}" ] || fail "required BPF map not pinned: ${map}"
    log "ok: ${map} is pinned"
  done
}

test_datapath_compiled_at_runtime() {
  # cilium-agent compiles bpf_lxc.c/bpf_host.c with the bundled clang on first
  # use (pkg/datapath/loader/compile.go); finding the ELFs proves it worked.
  local templates="${SNAP_COMMON}/cilium/state/state/templates"
  assert_dir "$templates" "datapath template directory"

  local objects
  objects="$(find "$templates" -name '*.o' | wc -l)"
  [ "$objects" -gt 0 ] || fail "no compiled datapath objects found under $templates"
  log "ok: $objects compiled datapath object(s) present"

  find "$templates" -name 'bpf_host.o' | grep -q . \
    || fail "bpf_host.o was never compiled; the host datapath is not loaded"
  log "ok: bpf_host.o compiled"
}

test_datapath_attached_to_devices() {
  # cilium_host/cilium_net link dirs prove attachment, not just compilation:
  # the agent creates them itself, one per attached device.
  local bpf_root devices
  bpf_root="$(snap_config BPF_ROOT)"
  devices="${bpf_root}/cilium/devices"
  assert_dir "$devices" "attached-device link directory"

  local dev
  for dev in cilium_host cilium_net; do
    assert_dir "${devices}/${dev}/links" "datapath attached to ${dev}"
  done

  local egress
  egress="$(snap_config EGRESS_INTERFACE)"
  [ -n "$egress" ] || egress="$(ip -4 route show default | awk '{print $5; exit}')"
  if [ -n "$egress" ]; then
    assert_dir "${devices}/${egress}/links" "datapath attached to the egress device (${egress})"
  else
    warn "no default-route device; skipping egress attach check"
  fi
}

test_cilium_host_devices_exist() {
  local addr
  ip link show cilium_host >/dev/null 2>&1 || fail "cilium_host device was not created"
  ip link show cilium_net >/dev/null 2>&1 || fail "cilium_net device was not created"
  log "ok: cilium_host and cilium_net exist"

  addr="$(ip -4 -o addr show cilium_host | awk '{print $4}' | cut -d/ -f1)"
  assert_eq "$(snap_config LOCAL_ROUTER_IPV4)" "$addr" \
    "cilium_host carries the configured router IP"
}

test_attach_mode_is_tcx() {
  local mode
  mode="$(cilium_status_field '.["attach-mode"]')"
  assert_eq "tcx" "$mode" "datapath uses tcx attachment"
}

test_masquerade_rules_installed() {
  # The snap ships its own iptables binary; a bad ELF patch surfaces here as
  # missing rules rather than a crash.
  local out
  out="$(iptables-save -t nat 2>/dev/null || true)"
  assert_contains "$out" "CILIUM" "cilium installed its nat chains"
}
