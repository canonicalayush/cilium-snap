# Cilium Standalone Snap

This repository packages [Cilium](https://github.com/cilium/cilium) as a snap designed to run on a single host without a Kubernetes apiserver.

Because Cilium requires a key-value store for identity and state management when running standalone, this snap depends on the separately-installed [`etcd`](https://snapcraft.io/etcd) snap as that kvstore, and bundles datapath compilation toolchains and host CNI integration utilities.

## What this repository is responsible for

- **Snap packaging**: Defining the `cilium-snap` snap specification in `snap/snapcraft.yaml` with classic confinement.
- **Upstream component builds**: Fetching and compiling pinned versions of upstream components (`cilium` and `cni-plugins`) via `build-scripts/`.
- **Runtime service orchestration**: Providing a daemon wrapper (`cilium-agent-wrapper`) and configuration hooks to manage the local `cilium-agent` service and settings, plus a one-shot (`setup-etcd`) to configure and start the external `etcd` snap as its kvstore.
- **CNI deployment**: Providing host CNI installation scripts (`install-cni`) to configure network interfaces and plugins on the host.

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

- `etcd-bind-address` (default `127.0.0.1:2379`): the client URL `cilium-snap.setup-etcd` renders into the `etcd` snap's `etcd.conf.yml`. Leave at the loopback default to serve only agents on this host; set to `0.0.0.0:2379` or a routable `<host-ip>:2379` to also serve agents on other hosts. Re-run `cilium-snap.setup-etcd --force` after changing it.
- `etcd-listen-url` (default `http://127.0.0.1:2379`): where `cilium-agent` looks for etcd. Point this at the etcd host's address when etcd runs elsewhere.
- `cluster-name` / `cluster-id` (defaults `default` / `0`): namespace this agent's kvstore state when multiple independent agent groups share one etcd instance.
- `node-name` (default: the host's hostname): the name this agent registers itself under in the kvstore. Every node sharing one etcd instance under the same `cluster-name` needs a distinct `node-name`.
- `enable-auto-direct-node-routes` (default `false`): installs L2 routes between node PodCIDRs without an overlay. Required for cross-host pod connectivity when multiple agents share one etcd.

### Running multiple agents against one etcd instance

`cilium-agent` has no kvstore key prefix flag of its own, so isolation between independent agent groups sharing one etcd instance comes from `cluster-name`/`cluster-id`, distinct `node-name`s, and non-overlapping `ipv4-range`s -- the same mechanism ClusterMesh uses. On the host running etcd:

```bash
sudo snap set cilium-snap etcd-bind-address=0.0.0.0:2379 enable-auto-direct-node-routes=true node-name=host-a ipv4-range=10.20.1.0/24
sudo cilium-snap.setup-etcd --force
```

On every other host, point at that etcd and give each node its own name and non-overlapping pod range:

```bash
sudo snap set cilium-snap etcd-listen-url=http://<etcd-host-ip>:2379 node-name=host-b ipv4-range=10.20.2.0/24 enable-auto-direct-node-routes=true
```

All nodes sharing one etcd instance must use the same `cluster-name` (the `default` default is fine as long as every node uses it).

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
