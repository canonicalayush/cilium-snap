#!/bin/bash
# Configuration: `snap set` must reach the running agent through the configure
# hook and the rendered config.env, without a rebuild.

CONFIG_ENV="${SNAP_DATA_DIR}/config.env"

agent_flag() {
  # agent_flag <flag-name> -- echoes the value the running agent was started with.
  pgrep -af 'cilium-agent' 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E "^--${1}=" \
    | head -1 \
    | cut -d= -f2-
}

restore_debug() {
  snap unset "$SNAP_NAME" debug >/dev/null 2>&1 || true
}

test_config_env_rendered() {
  assert_file "$CONFIG_ENV" "configure hook rendered config.env"

  local key
  for key in ETCD_LISTEN_URL IPAM ROUTING_MODE NATIVE_ROUTING_CIDR IPV4_RANGE \
             BPF_ROOT CGROUP_ROOT DEBUG EXTRA_ARGS; do
    grep -qE "^${key}=" "$CONFIG_ENV" || fail "config.env is missing key ${key}"
  done
  log "ok: config.env carries every key the wrappers source"
}

test_config_values_are_shell_quoted() {
  # The wrappers `source` this file; an unquoted value such as
  # extra-args='--foo; reboot' would execute. The hook %q-escapes for that.
  local hostile='--devices=eth0; touch /tmp/cilium-smoke-injection'
  rm -f /tmp/cilium-smoke-injection

  snap set "$SNAP_NAME" extra-args="$hostile" >/dev/null
  # shellcheck disable=SC1090
  ( set -eu; . "$CONFIG_ENV"; [ "$EXTRA_ARGS" = "$hostile" ] ) \
    || fail "sourcing config.env did not reproduce the configured extra-args verbatim"
  [ ! -e /tmp/cilium-smoke-injection ] \
    || fail "sourcing config.env executed an injected command"
  log "ok: hostile extra-args round-trips as inert data"

  # The agent crash-looped on those arguments; the configure hook already
  # restarts on unset, so an explicit `snap restart` here would only burn
  # one more of systemd's five permitted starts per ten seconds.
  snap unset "$SNAP_NAME" extra-args >/dev/null
  retry_until 180 "agent recovers after clearing extra-args" \
    bash -c "[ \"\$(${CILIUM_DBG} status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"
}

test_snap_set_lifecycle_reaches_the_agent() {
  # Exercises the full path once: snap config -> config.env -> wrapper ->
  # agent command line -> observable behaviour, and back again on unset.
  trap restore_debug EXIT

  assert_eq "false" "$(agent_flag debug)" "agent starts with --debug=false"

  snap set "$SNAP_NAME" debug=true >/dev/null
  assert_matches "$(grep -E '^DEBUG=' "$CONFIG_ENV")" "DEBUG=.?true" \
    "configure hook rendered debug=true"

  retry_until 180 "restarted agent runs with --debug=true" \
    bash -c "[ \"\$(pgrep -af cilium-agent | tr ' ' '\n' | grep -E '^--debug=' | head -1)\" = '--debug=true' ]"
  retry_until 180 "agent API is serving again" \
    bash -c "[ \"\$(${CILIUM_DBG} status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"

  # A flag reaching the command line without changing behaviour would be a
  # silent no-op.
  retry_until 60 "agent emits debug-level log records" \
    bash -c "journalctl -u snap.${AGENT_SERVICE}.service --since '-2min' --no-pager | grep -q 'level=debug'"

  snap unset "$SNAP_NAME" debug >/dev/null
  retry_until 180 "unsetting debug falls back to the shipped default" \
    bash -c "[ \"\$(pgrep -af cilium-agent | tr ' ' '\n' | grep -E '^--debug=' | head -1)\" = '--debug=false' ]"
  retry_until 180 "agent is healthy on the restored default" \
    bash -c "[ \"\$(${CILIUM_DBG} status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"
}

test_unchanged_config_does_not_restart() {
  # systemd permits 5 starts/10s and snapd exposes neither knob; a hook that
  # restarted on every `snap set` would let harmless no-op settings wedge
  # the agent in start-limit-hit.
  trap restore_debug EXIT

  snap set "$SNAP_NAME" debug=true >/dev/null
  retry_until 180 "agent is up with debug set" \
    bash -c "[ \"\$(${CILIUM_DBG} status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"

  local pid_before pid_after
  pid_before="$(systemctl show "snap.${AGENT_SERVICE}.service" -p MainPID --value)"

  snap set "$SNAP_NAME" debug=true >/dev/null
  snap set "$SNAP_NAME" debug=true >/dev/null
  snap set "$SNAP_NAME" debug=true >/dev/null

  pid_after="$(systemctl show "snap.${AGENT_SERVICE}.service" -p MainPID --value)"
  assert_eq "$pid_before" "$pid_after" \
    "repeating an unchanged setting does not restart the agent"

  service_active "$AGENT_SERVICE" \
    || fail "agent is no longer active after repeated no-op settings"
  log "ok: agent still active after repeated no-op settings"
}

test_rapid_setting_changes_do_not_wedge_the_agent() {
  # Five starts inside ten seconds trips systemd's start limit, after which
  # `snap set` can no longer recover the agent; the configure hook clears
  # the counter before restarting.
  trap restore_debug EXIT

  local i
  for i in 1 2 3 4 5 6; do
    if [ $((i % 2)) -eq 0 ]; then
      snap set "$SNAP_NAME" debug=true >/dev/null
    else
      snap set "$SNAP_NAME" debug=false >/dev/null
    fi
  done

  retry_until 180 "agent survives six back-to-back setting changes" \
    bash -c "[ \"\$(${CILIUM_DBG} status -o json 2>/dev/null | jq -r .cilium.state)\" = Ok ]"
  service_active "$AGENT_SERVICE" \
    || fail "agent is not active after rapid setting changes"
  log "ok: agent is active after rapid setting changes"
}

test_defaults_env_is_the_fallback() {
  # Every key the hook reads must have a shipped default, otherwise an unset
  # option renders as an empty value and the agent gets a bare flag.
  local defaults="/snap/${SNAP_NAME}/current/etc/defaults.env"
  assert_file "$defaults" "shipped defaults.env"

  local key
  while read -r key; do
    grep -qE "^${key}=" "$defaults" \
      || fail "config.env key ${key} has no default in defaults.env"
  done < <(grep -oE '^[A-Z0-9_]+' "$CONFIG_ENV")
  log "ok: every rendered key has a shipped default"
}
