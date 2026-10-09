#!/bin/bash
# CNI: the one-shot host installer and the plugin it drops.

test_install_cni_places_binaries() {
  local out
  out="$("$INSTALL_CNI" 2>&1)" || fail "install-cni failed: $out"

  local bin
  for bin in cilium-cni loopback portmap host-local; do
    assert_contains "$out" "installed ${bin} ->" "install-cni reports installing ${bin}"
  done

  local bin_dir
  bin_dir="$(printf '%s' "$out" | sed -n 's/.*installed cilium-cni *-> *//p' | tail -1)"
  assert_ne "" "$bin_dir" "install-cni reports a target binary directory"
  info "CNI binary directory: $bin_dir"

  for bin in cilium-cni loopback portmap host-local; do
    assert_executable "${bin_dir}/${bin}" "${bin} installed on the host"
  done
}

test_install_cni_writes_valid_conflist() {
  local conf
  conf="$(cni_conf_path)" || fail "install-cni failed while resolving the conflist path"
  assert_ne "" "$conf" "install-cni reports a conflist path"
  assert_file "$conf" "CNI conflist written"
  assert_json "$conf" "CNI conflist is valid JSON"

  local name version plugins
  name="$(jq -r '.name' "$conf")"
  version="$(jq -r '.cniVersion' "$conf")"
  plugins="$(jq -r '[.plugins[].type] | join(",")' "$conf")"

  assert_eq "cilium" "$name" "conflist declares the cilium network"
  assert_matches "$version" "^1\.[0-9]+\.[0-9]+$" "conflist declares a CNI 1.x version"
  assert_contains "$plugins" "cilium-cni" "conflist chains the cilium-cni plugin"
  assert_contains "$plugins" "portmap" "conflist chains portmap for host port mappings"

  local portmap_caps
  portmap_caps="$(jq -r '.plugins[] | select(.type=="portmap") | .capabilities.portMappings' "$conf")"
  assert_eq "true" "$portmap_caps" "portmap advertises the portMappings capability"
}

test_install_cni_is_idempotent() {
  # It is a one-shot command users are told to re-run after a refresh.
  local first second
  first="$(cni_conf_path)"
  "$INSTALL_CNI" >/dev/null 2>&1 || fail "second install-cni run failed"
  second="$(cni_conf_path)"
  assert_eq "$first" "$second" "repeated install-cni runs target the same conflist"
  assert_json "$second" "conflist still valid after reinstalling"
}

test_cni_plugin_reports_version() {
  # CNI_COMMAND=VERSION is the spec handshake every runtime performs first.
  local bin_dir out
  bin_dir="${CNI_BIN_DIR:-/opt/cni/bin}"
  out="$(CNI_COMMAND=VERSION CNI_PATH="$bin_dir" "${bin_dir}/cilium-cni" </dev/null 2>&1)" \
    || fail "cilium-cni VERSION handshake failed: $out"

  printf '%s' "$out" | jq empty 2>/dev/null || fail "VERSION output is not JSON: $out"
  local supported
  supported="$(printf '%s' "$out" | jq -r '.supportedVersions | join(",")')"
  assert_contains "$supported" "1.0.0" "cilium-cni supports CNI 1.0.0"
}

test_cni_plugin_rejects_bad_invocation() {
  # A plugin that returns success on garbage input would mask real failures in
  # the ADD path below.
  local bin_dir
  bin_dir="${CNI_BIN_DIR:-/opt/cni/bin}"
  assert_cmd_fails "cilium-cni rejects an unknown CNI_COMMAND" \
    env CNI_COMMAND=NONSENSE CNI_PATH="$bin_dir" "${bin_dir}/cilium-cni"
}
