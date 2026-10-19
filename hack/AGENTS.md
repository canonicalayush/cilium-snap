# Hack Scripts (`hack/`)

## Overview
Operator-run helper scripts that act on a cluster or host, not on the snap build.

## Responsibilities
- `install-cilium-operator.sh`: Prepares a Kubernetes cluster for the snap's kubernetes mode. Renders the upstream Cilium Helm chart (version taken from `build-scripts/components/cilium/version`) twice -- once with `agent=false` for cilium-operator, its RBAC and `cilium-config`, once with `--show-only` restricted to the agent's RBAC templates -- and applies the result, deliberately omitting the agent DaemonSet. CRDs are not in the chart; the running operator registers them, and the script waits for that. Run once per cluster on a control-plane node, after `k8s disable network`.
