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
