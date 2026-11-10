# Configuration

Every runtime option is a snap key, set with
`snap set cilium-snap <key>=<value>`. The configure hook renders the
active value of every key into $SNAP_DATA/config.env, falling back to
snap/local/etc/defaults.env for anything unset.

## Core keys

| Key | Default | Meaning |
|---|---|---|
| `debug` | false | Verbose agent logging. |
| `ipam` | cluster-pool | IPAM mode. cluster-pool only needs ipv4-range. delegated-plugin also works but needs an external CNI IPAM plugin. Other upstream modes need a Kubernetes apiserver this snap does not have. |
| `ipv4-range` | 10.20.0.0/16 | The pod CIDR this node allocates from. Chosen by hand per host, then validated against other nodes' claims at agent start (see the IPAM collision guard in architecture.md). |
| `routing-mode` | native | Required by local-router-ipv4 below. |
| `native-routing-cidr` | 10.20.0.0/16 | Required by native routing plus masquerade. Must cover the pod range. |
| `local-router-ipv4` | 169.254.1.1 | Required by delegated-plugin IPAM, harmless under cluster-pool. |
| `enable-ipv4` / `enable-ipv6` | true / false | Single-stack IPv4 by default. |
| `egress-interface` | (empty) | Interface used for masquerade. Empty auto-detects the default-route interface at every start. |
| `bpf-root` | /sys/fs/bpf | Where bpffs is mounted. |
| `cgroup-root` | /run/cilium/cgroupv2 | Where cgroup2 is mounted. |
| `extra-args` | (empty) | Extra flags appended to the cilium-agent invocation. Shell-escaped by the configure hook. |

## etcd and multi-host keys

| Key | Default | Meaning |
|---|---|---|
| `etcd-listen-url` | http://127.0.0.1:2379 | Where the agent looks for etcd. |
| `etcd-wait-seconds` | 60 | How long the agent waits for etcd at start. |
| `etcd-bind-address` | 127.0.0.1:2379 | The client URL setup-etcd renders into the etcd snap's config. Loopback serves only this host. Binding beyond loopback exposes an unauthenticated, plaintext etcd port, firewall it to the intended agent hosts first. Re-run `cilium-snap.setup-etcd --force` after changing this. |
| `cluster-name` / `cluster-id` | default / 0 | Namespaces this agent's kvstore state when several agent groups share one etcd. |
| `node-name` | host's hostname | This agent's name in the kvstore. Must be distinct per node sharing one etcd under the same cluster-name. |
| `enable-auto-direct-node-routes` | false | Installs direct routes between node pod CIDRs, no overlay. Only works when the agent hosts share one L2 segment. |

## Running multiple agents against one etcd instance

Isolation between agent groups sharing one etcd comes from cluster-name,
cluster-id, distinct node-name values, and non-overlapping ipv4-range
values.

On the host that will run etcd:

```bash
# Binding beyond loopback exposes an unauthenticated etcd port.
# Restrict it to the agent hosts first, e.g.:
#   sudo iptables -A INPUT -p tcp --dport 2379 -s <agent-host-cidr> -j ACCEPT
#   sudo iptables -A INPUT -p tcp --dport 2379 -j DROP
sudo snap set cilium-snap etcd-bind-address=0.0.0.0:2379 enable-auto-direct-node-routes=true node-name=host-a ipv4-range=10.20.1.0/24
sudo cilium-snap.setup-etcd --force
```

On every other host, point at that etcd with a distinct name and range:

```bash
sudo snap set cilium-snap etcd-listen-url=http://<etcd-host-ip>:2379 node-name=host-b ipv4-range=10.20.2.0/24 enable-auto-direct-node-routes=true
```

auto-direct-node-routes assumes the agent hosts share one L2 segment. If
hosts are separated by an L3 boundary, leave it off and distribute pod
CIDRs another way, static routes, a BGP daemon, or an encapsulating
routing mode.

The agent wrapper claims the configured range in etcd before starting,
guarded by a distributed lock, and refuses to start on overlap with
another node's claim. A clean `snap remove` releases the claim. A host
that disappears without that step leaves the claim reserved until an
operator removes it by hand. See the IPAM collision guard section of
architecture.md for the full mechanism.

All nodes sharing one etcd instance must use the same cluster-name.
