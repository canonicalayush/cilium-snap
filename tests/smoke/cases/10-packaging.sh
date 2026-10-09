#!/bin/bash
# Packaging: the snap is installed, classic, and every declared app resolves.

test_snap_installed() {
  local out
  out="$(snap list "$SNAP_NAME" 2>&1)" || fail "snap $SNAP_NAME is not installed: $out"
  assert_contains "$out" "classic" "snap is installed with classic confinement"

  local version
  version="$(snap list "$SNAP_NAME" | awk 'NR==2 {print $2}')"
  assert_ne "" "$version" "snap reports a version"
  info "installed version: $version"
}

test_snap_apps_present() {
  # snapcraft.yaml declares six apps: two daemons and four commands.
  local expected="cilium-agent cilium-dbg etcd etcdctl hubble install-cni"
  local app
  for app in $expected; do
    snap run --help >/dev/null 2>&1 || true
    if [ -x "/snap/bin/${SNAP_NAME}.${app}" ] || snap services "${SNAP_NAME}.${app}" >/dev/null 2>&1; then
      log "ok: app ${SNAP_NAME}.${app} is present"
    else
      fail "app ${SNAP_NAME}.${app} is missing"
    fi
  done
}

test_client_binaries_run() {
  # These are the user-facing entrypoints; a broken ELF patch or a missing
  # library shows up here before anything else does.
  local out

  out="$("$CILIUM_DBG" version 2>&1)" || fail "cilium-dbg version failed: $out"
  assert_matches "$out" "^Client: [0-9]+\.[0-9]+" "cilium-dbg reports a client version"
  assert_contains "$out" "Daemon:" "cilium-dbg reaches the agent API"

  out="$("$ETCDCTL" version 2>&1)" || fail "etcdctl version failed: $out"
  assert_matches "$out" "etcdctl version: [0-9]+\.[0-9]+\.[0-9]+" "etcdctl reports a version"

  out="$("$HUBBLE" version 2>&1)" || fail "hubble version failed: $out"
  assert_matches "$out" "hubble v?[0-9]+\.[0-9]+" "hubble reports a version"
}

test_pinned_versions_match_build() {
  # The snap version string is built from components/cilium/version, so the
  # agent the snap ships must report the same abbreviated SHA.
  local snap_version agent_version
  snap_version="$(snap list "$SNAP_NAME" | awk 'NR==2 {print $2}')"
  agent_version="$(cilium_status_field '.cilium.msg')"

  case "$snap_version" in
    *+git.*)
      local pinned_sha="${snap_version##*+git.}"
      assert_contains "$agent_version" "${pinned_sha:0:8}" \
        "agent build SHA matches the snap version string"
      ;;
    *)
      skip "snap version '$snap_version' carries no git pin to cross-check"
      ;;
  esac
}

test_bundled_toolchain_runs() {
  # cilium-agent shells out to clang at runtime to build datapath templates
  # (pkg/datapath/loader/compile.go), so the bundled compiler must execute.
  local clang="/snap/${SNAP_NAME}/current/usr/lib/llvm-18/bin/clang"
  assert_executable "$clang" "bundled clang is executable"

  local out
  out="$("$clang" --version 2>&1)" || fail "bundled clang failed to run: $out"
  assert_matches "$out" "clang version [0-9]+" "bundled clang reports a version"

  local llc="/snap/${SNAP_NAME}/current/usr/lib/llvm-18/bin/llc"
  assert_executable "$llc" "bundled llc is executable"
}
