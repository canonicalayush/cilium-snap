#!/bin/bash
# Prepare a Kubernetes cluster for cilium-snap's kubernetes mode.
#
# Installs, from the upstream Cilium Helm chart: cilium-operator and its
# RBAC, the agent's RBAC/ServiceAccount, and the cilium-config ConfigMap --
# deliberately NOT the agent DaemonSet, because cilium-snap runs the agent
# on each node itself. The CRDs come from upstream too, but not from the
# chart: the chart ships none, and the running operator registers them at
# startup. This script waits for that to happen.
#
# Run once per cluster, on a control-plane node, after disabling k8s-snap's
# own bundled Cilium:
#
#   sudo k8s disable network
#   sudo k8s set network.kube-proxy-enabled=false
#   ./hack/install-cilium-operator.sh
#
# Then, on every node running cilium-snap:
#
#   sudo cilium-snap.setup-k8s
#   sudo snap set cilium-snap mode=kubernetes
#   sudo cilium-snap.install-cni
#
# Requires helm and kubectl (or the k8s snap) on PATH. --pod-cidr is
# auto-detected from this cluster's existing CiliumNode allocations when
# omitted; pass it explicitly only for a brand new cluster with no
# Cilium-managed nodes yet, or one using a non-/16 pool layout.
set -eu

DIR="$(realpath "$(dirname "${0}")")"

KUBECONFIG_PATH="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE=kube-system
K8S_SERVICE_HOST=127.0.0.1
K8S_SERVICE_PORT=6443
# Fallback when there's no cluster to inspect yet (--dry-run) or no
# existing CiliumNode to infer from (a genuinely fresh cluster). On a real
# run against a cluster that already has Cilium-managed nodes, this is
# overridden by auto-detection below unless --pod-cidr is passed.
POD_CIDR=10.20.0.0/16
POD_CIDR_EXPLICIT=0
# Chart version tracks the agent this repository packages; they must match.
# Left empty here -- defaulted after arg parsing, so --chart-version can
# override it without this repository's build-scripts/ directory existing.
CHART_VERSION=
DRY_RUN=0

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="${2:?--kubeconfig needs a path}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --k8s-service-host) K8S_SERVICE_HOST="${2:?--k8s-service-host needs a value}"; shift 2 ;;
    --k8s-service-port) K8S_SERVICE_PORT="${2:?--k8s-service-port needs a value}"; shift 2 ;;
    --pod-cidr) POD_CIDR="${2:?--pod-cidr needs a value}"; POD_CIDR_EXPLICIT=1; shift 2 ;;
    --chart-version) CHART_VERSION="${2:?--chart-version needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done

if [ -z "$CHART_VERSION" ]; then
  CHART_VERSION="$(sed 's/^v//' "$DIR/../build-scripts/components/cilium/version")" || {
    echo "could not read the chart version from $DIR/../build-scripts/components/cilium/version; pass --chart-version explicitly" >&2
    exit 1
  }
fi

command -v helm >/dev/null 2>&1 || { echo "need helm on PATH" >&2; exit 1; }

CHART_DIR="$(mktemp -d)"
trap 'rm -rf "$CHART_DIR"' EXIT

# helm.cilium.io is GitHub Pages over github.com/cilium/charts; pulling
# through the repo URL (rather than curl-ing the tarball out of that repo)
# verifies the chart against the digest recorded in its index.yaml.
helm pull --repo https://helm.cilium.io cilium \
  --version "$CHART_VERSION" --untar --untardir "$CHART_DIR"

# Mirrors the values k8sd's own ApplyNetwork sets for its ck-network
# release, minus everything that only affects the agent DaemonSet (image,
# bpf/cgroup mounts, CNI paths) -- that DaemonSet is never rendered here,
# and cilium-snap owns those settings on the host instead. IPv4 only.
# A function, not a one-shot heredoc: called again after pod-cidr
# auto-detection (below) picks a different value than this initial default.
write_values_yaml() {
  cat > "$CHART_DIR/values.yaml" <<EOF
operator:
  enabled: true
  replicas: 1
socketLB:
  enabled: true
kubeProxyReplacement: true
nodePort:
  enabled: true
  enableHealthCheck: true
disableEnvoyVersionCheck: true
envoy:
  enabled: false
enableRuntimeDeviceDetection: true
sessionAffinity: true
loadBalancer:
  protocolDifferentiation:
    enabled: true
ipv4:
  enabled: true
ipv6:
  enabled: false
k8sServiceHost: "${K8S_SERVICE_HOST}"
k8sServicePort: "${K8S_SERVICE_PORT}"
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: ["${POD_CIDR}"]
EOF
}
write_values_yaml

# Two renders: the chart's single `agent` flag gates the agent DaemonSet and
# the agent's RBAC together, so the RBAC is taken from a second render that
# --show-only restricts to exactly those templates, never reaching the
# DaemonSet.
render() {
  helm template cilium "$CHART_DIR/cilium" \
    --namespace "$NAMESPACE" \
    --set agent=false \
    -f "$CHART_DIR/values.yaml"

  helm template cilium "$CHART_DIR/cilium" \
    --namespace "$NAMESPACE" \
    --set agent=true \
    --set operator.enabled=false \
    -f "$CHART_DIR/values.yaml" \
    --show-only templates/cilium-agent/serviceaccount.yaml \
    --show-only templates/cilium-agent/clusterrole.yaml \
    --show-only templates/cilium-agent/clusterrolebinding.yaml \
    --show-only templates/cilium-agent/role.yaml \
    --show-only templates/cilium-agent/rolebinding.yaml
}

if [ "$DRY_RUN" -eq 1 ]; then
  render
  exit 0
fi

if [ ! -f "$KUBECONFIG_PATH" ]; then
  cat >&2 <<EOF
no kubeconfig at $KUBECONFIG_PATH
admin.conf only exists on control-plane nodes; run this there, or pass
--kubeconfig <path>.
EOF
  exit 1
fi

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v k8s >/dev/null 2>&1; then
  KUBECTL=(k8s kubectl)
else
  echo "need kubectl (or the k8s snap) on PATH" >&2
  exit 1
fi
kubectl() { "${KUBECTL[@]}" --kubeconfig "$KUBECONFIG_PATH" "$@"; }

# k8s-snap's own release would fight this one over the same objects.
EXISTING_RELEASE="$(kubectl get configmap cilium-config -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
if [ "$EXISTING_RELEASE" = "ck-network" ]; then
  cat >&2 <<EOF
${NAMESPACE}/cilium-config is managed by k8s-snap's own "ck-network" Helm
release; disable k8s-snap's bundled Cilium first:
  sudo k8s disable network
  sudo k8s set network.kube-proxy-enabled=false
EOF
  exit 1
fi

# ClusterPool IPAM only allocates a podCIDR to a CiliumNode whose
# .spec.ipam.podCIDRs is empty -- it never reclaims/reassigns an existing
# one, even across an operator reinstall with a different pool. CiliumNode
# objects aren't Helm-templated, so they survive a prior release's
# uninstall; a cluster bootstrapped once with k8s-snap's own Cilium already
# has nodes assigned out of its own pool. Nothing outside Cilium's own CRDs
# records what that pool was (checked against this project's own cluster:
# no --cluster-cidr on kube-controller-manager, no --pod-cidr on kubelet,
# node.spec.podCIDR empty -- k8s-snap's own Cilium owned IPAM entirely). So
# when --pod-cidr wasn't passed explicitly, infer it from what's already
# assigned instead of defaulting to a value with no relation to the
# cluster.
ipv4_in_cidr() {
  local parent="$1" child="${2%%,*}"
  local p_ip="${parent%/*}" p_bits="${parent#*/}"
  local c_ip="${child%/*}"
  local IFS=.
  local -a p_oct c_oct
  read -r -a p_oct <<<"$p_ip"
  read -r -a c_oct <<<"$c_ip"
  local p_int=$(( (p_oct[0]<<24) + (p_oct[1]<<16) + (p_oct[2]<<8) + p_oct[3] ))
  local c_int=$(( (c_oct[0]<<24) + (c_oct[1]<<16) + (c_oct[2]<<8) + c_oct[3] ))
  local mask=$(( p_bits == 0 ? 0 : (0xFFFFFFFF << (32 - p_bits)) & 0xFFFFFFFF ))
  [ $(( p_int & mask )) -eq $(( c_int & mask )) ]
}

# Supernet of an already-assigned per-node CIDR, widened to a /16 -- matches
# how both k8s-snap's own default and this script's own fallback lay the
# pool out (a /16 sliced into per-node /24s). Only sound for a single,
# conventional private-range layout; a cluster using something else needs
# --pod-cidr passed explicitly.
pod_cidr_supernet() {
  local ip="${1%/*}" a b
  IFS=. read -r a b _ _ <<<"$ip"
  printf '%s.%s.0.0/16' "$a" "$b"
}

EXISTING_CIDRS="$(kubectl get ciliumnodes.cilium.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.ipam.podCIDRs[0]}{"\n"}{end}' 2>/dev/null || true)"

if [ "$POD_CIDR_EXPLICIT" -eq 0 ]; then
  DETECTED_SRC="$(printf '%s\n' "$EXISTING_CIDRS" | awk -F'\t' '$2 != "" {print $2; exit}')"
  if [ -n "$DETECTED_SRC" ]; then
    DETECTED="$(pod_cidr_supernet "$DETECTED_SRC")"
    if [ "$DETECTED" != "$POD_CIDR" ]; then
      echo "no --pod-cidr given; detected ${DETECTED} from this cluster's existing CiliumNode allocations (e.g. ${DETECTED_SRC}), overriding the ${POD_CIDR} default" >&2
      POD_CIDR="$DETECTED"
      write_values_yaml
    fi
  fi
fi

MISMATCHED_NODES=""
while IFS=$'\t' read -r node cidrs; do
  if [ -z "$node" ] || [ -z "$cidrs" ]; then continue; fi
  ipv4_in_cidr "$POD_CIDR" "$cidrs" || MISMATCHED_NODES="${MISMATCHED_NODES}  ${node}: ${cidrs}\n"
done <<<"$EXISTING_CIDRS"

if [ -n "$MISMATCHED_NODES" ]; then
  printf 'warning: these CiliumNodes already hold a podCIDR outside %s -- they keep it (ClusterPool never reclaims an assigned CIDR), but any *new* node will be allocated from %s instead, splitting the cluster across inconsistent pools:\n%b' \
    "$POD_CIDR" "$POD_CIDR" "$MISMATCHED_NODES" >&2
  echo "pass --pod-cidr matching the range above if that's unintentional." >&2
fi

echo "installing cilium ${CHART_VERSION} operator, agent RBAC and cilium-config into ${NAMESPACE} (no agent DaemonSet)"
render | kubectl apply -f -

# The chart's cilium-operator pod template carries no cilium-config
# checksum annotation, so it only reads cilium-config at process startup --
# `kubectl apply` alone never restarts it, leaving a stale in-memory config
# (e.g. an old cluster-pool-ipv4-cidr) even though the ConfigMap on disk is
# current. Force a restart every run; idempotent, and safe -- the operator
# does IPAM/identity reconciliation, not datapath traffic, so a brief
# restart doesn't disrupt already-running pods.
echo "restarting cilium-operator to pick up the current cilium-config"
kubectl -n "$NAMESPACE" rollout restart deployment/cilium-operator
echo "waiting for cilium-operator rollout"
kubectl -n "$NAMESPACE" rollout status deployment/cilium-operator --timeout=120s

echo "waiting for cilium-operator to register CRDs"
for _ in $(seq 1 60); do
  kubectl get crd ciliumnodes.cilium.io ciliumidentities.cilium.io ciliumendpoints.cilium.io >/dev/null 2>&1 && break
  sleep 1
done
kubectl get crd ciliumnodes.cilium.io ciliumidentities.cilium.io ciliumendpoints.cilium.io >/dev/null

echo "done. On every cilium-snap node: sudo cilium-snap.setup-k8s && sudo snap set cilium-snap mode=kubernetes && sudo cilium-snap.install-cni"
