#!/bin/bash
# Kubernetes mode: config validation and install-cni's host-ownership rules,
# exercised cluster-free on the standalone smoke VM. Every case here must
# leave the install back in mode=standalone so 90-lifecycle.sh still sees a
# healthy agent.

SETUP_K8S="${SNAP_NAME}.setup-k8s"

restore_standalone_mode() {
  snap set "$SNAP_NAME" mode=standalone >/dev/null 2>&1 || true
}

restore_foreign_loopback() {
  local bak="/tmp/cilium-smoke-loopback.bak" dir
  dir="$(snap_config CNI_BIN_DIR)"
  [ -n "$dir" ] || dir="/opt/cni/bin"
  [ -f "$bak" ] && cp -a "$bak" "${dir}/loopback" && rm -f "$bak"
  rm -f "$SNAP_DATA_DIR/kubeconfig"
  restore_standalone_mode
}

test_mode_key_rejects_unknown_value() {
  assert_cmd_fails "snap set rejects an unknown mode" \
    snap set "$SNAP_NAME" mode=bogus
  assert_matches "$(grep -E '^MODE=' "$SNAP_DATA_DIR/config.env")" "MODE=.?standalone" \
    "config.env still carries the last valid mode"
}

test_kubernetes_mode_without_credentials_fails_fast() {
  trap restore_standalone_mode EXIT
  rm -f "$SNAP_DATA_DIR/kubeconfig"

  snap set "$SNAP_NAME" mode=kubernetes >/dev/null
  retry_until 60 "agent service stops without kubeconfig" \
    bash -c "! systemctl is-active --quiet snap.${AGENT_SERVICE}.service"

  local log
  log="$(journalctl -u "snap.${AGENT_SERVICE}.service" -n 50 --no-pager)"
  assert_contains "$log" "run: sudo cilium-snap.setup-k8s" \
    "journal names the recovery command"

  snap set "$SNAP_NAME" mode=standalone >/dev/null
  retry_until 180 "agent recovers after switching back to standalone" \
    bash -c "[ \"\$(${CILIUM_DBG} status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"
}

test_install_cni_in_kubernetes_mode_preserves_foreign_plugins() {
  trap restore_foreign_loopback EXIT

  local bin_dir real
  bin_dir="$(snap_config CNI_BIN_DIR)"
  [ -n "$bin_dir" ] || bin_dir="/opt/cni/bin"
  real="${bin_dir}/loopback"

  cp -a "$real" /tmp/cilium-smoke-loopback.bak
  printf 'not a real cni plugin\n' > "$real"
  printf 'dummy\n' > "$SNAP_DATA_DIR/kubeconfig"
  snap set "$SNAP_NAME" mode=kubernetes >/dev/null

  local out
  out="$("$INSTALL_CNI" 2>&1)" || fail "install-cni failed in kubernetes mode: $out"

  assert_contains "$out" "written by cilium-agent" \
    "install-cni defers the conflist to the agent"
  assert_contains "$out" "installed cilium-cni ->" \
    "install-cni (re)installs cilium-cni"
  assert_eq "not a real cni plugin" "$(cat "$real")" \
    "install-cni left the pre-existing loopback binary untouched"
}

test_setup_k8s_requires_an_admin_kubeconfig() {
  local out
  out="$("$SETUP_K8S" --kubeconfig /nonexistent 2>&1)" \
    && fail "setup-k8s unexpectedly succeeded with a missing kubeconfig: $out"
  assert_contains "$out" "/nonexistent" \
    "setup-k8s names the missing kubeconfig path"
}
