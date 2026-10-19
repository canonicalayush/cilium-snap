# Cilium Snap

This repository packages [Cilium](https://github.com/cilium/cilium) as a snap that runs the Cilium agent outside of a Kubernetes pod, in one of two modes:

- **standalone** (default): no apiserver; Cilium's own etcd-backed kvstore holds identity and state.
- **kubernetes**: runs against a real apiserver with identity and policy state in CRDs, alongside an upstream cilium-operator installed by hack/install-cilium-operator.sh. The cluster must have no in-cluster Cilium agent DaemonSet.

Standalone mode depends on the separately-installed [`etcd`](https://snapcraft.io/etcd) snap as its kvstore. Both modes bundle datapath compilation toolchains and host CNI integration utilities.

## What this repository is responsible for

- **Snap packaging**: Defining the `cilium-snap` snap specification in `snap/snapcraft.yaml` with classic confinement.
- **Upstream component builds**: Fetching and compiling pinned versions of upstream components (`cilium` and `cni-plugins`) via `build-scripts/`.
- **Runtime service orchestration**: Providing a daemon wrapper (`cilium-agent-wrapper`) and configuration hooks to manage the local `cilium-agent` service, branching its flag set on the `mode` key -- `standalone` waits for etcd and builds the kvstore/IPAM flags, `kubernetes` points the agent at a synced kubeconfig and cluster config. Includes two one-shots: `setup-etcd` (configures and starts the external `etcd` snap as kvstore) and `setup-k8s` (mints apiserver credentials and syncs the cluster's `cilium-config`).
- **CNI deployment**: Providing a host CNI installation app (`install-cni`) that copies the CNI plugin binaries and writes the Cilium CNI config to the host. In kubernetes mode it only installs `cilium-cni`, leaving the other plugins and the conflist to k8sd and the agent respectively.
- **Cluster preparation**: A standalone script (hack/install-cilium-operator.sh), run once per cluster on a control-plane node, that installs the upstream cilium-operator, its CRDs and the agent's RBAC from the upstream Helm chart -- without the agent DaemonSet, which this snap replaces.

## Building the snap

Build the snap using Snapcraft:

```bash
snapcraft --use-lxd
```

## Basic usage (standalone mode)

Install the built snap:

```bash
sudo snap install --dangerous --classic ./cilium-snap_*.snap
```

Install and configure the external `etcd` snap, then start it as Cilium's kvstore:

```bash
sudo snap install etcd
sudo cilium-snap.setup-etcd
```

Install the CNI plugins and configuration to the host:

```bash
sudo cilium-snap.install-cni
```

Check the status of services:

```bash
sudo snap services cilium-snap
sudo cilium-snap.cilium-dbg status
```

Configure runtime options:

```bash
sudo snap set cilium-snap debug=true
```

Keys relevant to the external etcd kvstore and multi-agent setups:

- `etcd-bind-address` (default `127.0.0.1:2379`): the client URL `cilium-snap.setup-etcd` renders into the `etcd` snap's `etcd.conf.yml`. Leave at the loopback default to serve only agents on this host. Binding beyond loopback exposes an unauthenticated, plaintext etcd client port, `etcd.conf.yml` carries no TLS or auth, so anything that can reach the port can read and write Cilium's identity and policy state; firewall it to the intended agent hosts before widening this (`setup-etcd` prints a warning with an example `iptables` rule when it detects a non-loopback address). Re-run `cilium-snap.setup-etcd --force` after changing it.
- `etcd-listen-url` (default `http://127.0.0.1:2379`): where `cilium-agent` looks for etcd. Point this at the etcd host's address when etcd runs elsewhere.
- `cluster-name` / `cluster-id` (defaults `default` / `0`): namespace this agent's kvstore state when multiple independent agent groups share one etcd instance.
- `node-name` (default: the host's hostname): the name this agent registers itself under in the kvstore. Every node sharing one etcd instance under the same `cluster-name` needs a distinct `node-name`.
- `enable-auto-direct-node-routes` (default `false`): installs direct routes between node PodCIDRs without an overlay. Enable it for cross-host pod connectivity when the agent hosts share a common L2 segment -- Cilium installs a direct route only for nodes reachable in the same broadcast domain. Hosts separated by an L3/routed boundary need the pod CIDRs distributed another way (static routes, a BGP daemon, or an encapsulating routing mode) instead.

### Running multiple agents against one etcd instance

`cilium-agent` has no kvstore key prefix flag of its own, so isolation between independent agent groups sharing one etcd instance comes from `cluster-name`/`cluster-id`, distinct `node-name`s, and non-overlapping `ipv4-range`s -- the same mechanism ClusterMesh uses. On the host running etcd:

```bash
# etcd-bind-address below exposes an unauthenticated, plaintext etcd client
# port on every interface (see the etcd-bind-address note above). Restrict
# port 2379 to the agent hosts before running setup-etcd, e.g.:
#   sudo iptables -A INPUT -p tcp --dport 2379 -s <agent-host-cidr> -j ACCEPT
#   sudo iptables -A INPUT -p tcp --dport 2379 -j DROP
sudo snap set cilium-snap etcd-bind-address=0.0.0.0:2379 enable-auto-direct-node-routes=true node-name=host-a ipv4-range=10.20.1.0/24
sudo cilium-snap.setup-etcd --force
```

On every other host, point at that etcd and give each node its own name and non-overlapping pod range:

```bash
sudo snap set cilium-snap etcd-listen-url=http://<etcd-host-ip>:2379 node-name=host-b ipv4-range=10.20.2.0/24 enable-auto-direct-node-routes=true
```

The `enable-auto-direct-node-routes=true` in the commands above assumes `host-a` and `host-b` share a common L2 segment; Cilium installs a direct route to a node's PodCIDR only when that node is reachable in the same broadcast domain. If the agent hosts are separated by an L3/routed boundary, leave the setting off and distribute the pod CIDRs another way -- static routes on the intervening routers, a BGP daemon, or an encapsulating routing mode.

All nodes sharing one etcd instance must use the same `cluster-name` (the `default` default is fine as long as every node uses it).

## Kubernetes mode

Run this node's agent against a real Kubernetes apiserver, authenticating as
the `cilium` ServiceAccount, with identity and policy state in CRDs -- instead
of running standalone against etcd. This mode requires that the cluster has
*no* in-cluster Cilium agent DaemonSet: on k8s-snap, disable the bundled
network feature (it installs a full Cilium DaemonSet and operator as the
`ck-network` release, which this snap cannot coexist with), then install the
upstream operator and CRDs from a checkout of this repository, once per
cluster, on a control-plane node:

```bash
sudo k8s disable network
sudo k8s set network.kube-proxy-enabled=false   # k8s-snap would otherwise start its own kube-proxy
./hack/install-cilium-operator.sh
```

`install-cilium-operator.sh` needs `helm` and `kubectl` (or the `k8s` snap) on
PATH and a cluster-admin kubeconfig (default `/etc/kubernetes/admin.conf`,
override with `--kubeconfig`). It pins the chart to the Cilium version this
repository packages. `--pod-cidr` is auto-detected from the cluster's
existing `CiliumNode` allocations when omitted (e.g. from k8s-snap's own
bundled Cilium, briefly active before you disabled it above); pass it
explicitly only for a cluster with no Cilium-managed nodes yet, or a
non-`/16` pool layout. `--k8s-service-host` / `--k8s-service-port` (defaults
`127.0.0.1` / `6443`) and `--namespace` (default `kube-system`) must match
the cluster. `--dry-run` prints the manifest instead of applying it. See
`./hack/install-cilium-operator.sh --help`.

Then, on every node running `cilium-snap`:

```bash
sudo cilium-snap.setup-k8s     # mint apiserver credentials, sync cluster cilium-config
sudo snap set cilium-snap mode=kubernetes
sudo cilium-snap.install-cni   # installs only cilium-cni; other plugins and the conflist come from k8sd and the agent
```

**Restart every pod already running on this node.** CNI ADD only runs when
a pod's *sandbox* is created, not on a plain container restart -- so any pod
that started before this cutover (including k8s-snap's own `coredns`,
`metrics-server`, and CSI pods, which the `network`/`local-storage`/etc.
features deploy automatically) keeps the network namespace the *previous*
CNI set up. Once that CNI's agent is gone, those pods are stuck with no
managed Cilium endpoint at all -- not just misconfigured, but completely
unreachable, including from `kubelet`'s own liveness/readiness probes (silent
timeouts, not errors). Force new sandboxes so they go through `cilium-cni`
ADD on the new agent:

```bash
sudo cilium-snap.cilium-dbg endpoint list   # cross-check against `kubectl get pods -A -o wide`;
                                             # any Running pod IP missing here is orphaned
NODE="$(hostname | tr '[:upper:]' '[:lower:]')"
sudo k8s kubectl delete pod -A --field-selector spec.nodeName="$NODE"
```

Keys:

- `mode` (default `standalone`): `kubernetes` switches the agent to this mode.
- `k8s-kubeconfig-path` (default: `$SNAP_DATA/kubeconfig`, written by `setup-k8s`): credentials for the apiserver.
- `k8s-apiserver-host` / `k8s-apiserver-port` (default `127.0.0.1` / `6443`): apiserver address the agent uses for socket-LB and kube-proxy replacement. Keep these consistent with the `--k8s-service-host` / `--k8s-service-port` used for the cluster install.
- `k8s-namespace` (default `kube-system`): namespace the operator and the agent's RBAC live in.
- `k8s-config-sync` (default `true`): sync `cilium-config` from the cluster so the node-local agent inherits its settings.

`setup-k8s` requires a kubeconfig with cluster-admin access (default
`/etc/kubernetes/admin.conf`; override with `--kubeconfig`); see
`cilium-snap.setup-k8s --help` for its options.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
