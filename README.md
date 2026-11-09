# Cilium Standalone Snap

This repository packages [Cilium](https://github.com/cilium/cilium) as a snap designed to run on a single host without a Kubernetes apiserver.

Because Cilium requires a key-value store for identity and state management when running standalone, this snap depends on the separately-installed [`etcd`](https://snapcraft.io/etcd) snap as that kvstore, and bundles datapath compilation toolchains and host CNI integration utilities.

## What this repository is responsible for

- **Snap packaging**: Defining the `cilium-snap` snap specification in `snap/snapcraft.yaml` with classic confinement.
- **Upstream component builds**: Fetching and compiling pinned versions of upstream components (`cilium` and `cni-plugins`) via `build-scripts/`.
- **Runtime service orchestration**: Providing a daemon wrapper (`cilium-agent-wrapper`) and configuration hooks to manage the local `cilium-agent` service and settings, plus a one-shot (`setup-etcd`) to configure and start the external `etcd` snap as its kvstore.
- **CNI deployment**: Providing a host CNI installation app (`install-cni`) that copies the CNI plugin binaries and writes the Cilium CNI config to the host.

## Building the snap

Build the snap using Snapcraft:

```bash
snapcraft --use-lxd
```

## Basic usage

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

Cilium's own cluster-pool IPAM mode normally gets non-overlapping `ipv4-range`s from the cilium-operator; this snap ships no operator, so `ipv4-range` is a value you choose by hand per host. Before starting, `cilium-agent-wrapper` claims the configured range under `cilium-snap/ipam/claims/<node-name>` in etcd (guarded by an etcd distributed lock) and **refuses to start** if it overlaps a range already claimed by a different `node-name` -- two overlapping ranges would otherwise make `enable-auto-direct-node-routes` install routes that steer one node's pod traffic at another node's pods. A node reclaims its own prior range on restart without issue. Decommissioning a node cleanly (`sudo snap remove cilium-snap`) releases its claim automatically; a host that disappears without that step leaves its claim in etcd until an operator removes it by hand (`etcdctl del cilium-snap/ipam/claims/<node-name>`), so that exact range stays reserved for it.

All nodes sharing one etcd instance must use the same `cluster-name` (the `default` default is fine as long as every node uses it).

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
