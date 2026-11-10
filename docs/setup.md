# Setup

For what each step does under the hood, see architecture.md. For every
tunable, see configuration.md.

## Prerequisites

- To build: [Snapcraft](https://snapcraft.io/snapcraft) and LXD.
  `snapcraft --use-lxd` runs the build inside an LXD container.
- To run: a host with a real Linux kernel, bpffs and cgroup2 must be
  mountable, on amd64 or arm64. Classic confinement, base core24.

## 1. Build the snap

```bash
snapcraft --use-lxd
```

Produces cilium-snap_<version>_<arch>.snap.

## 2. Install the snap

```bash
sudo snap install --dangerous --classic ./cilium-snap_*.snap
```

This runs the install hook, then the configure hook, then starts the
daemon. The daemon will not come up cleanly until etcd is reachable, see
step 3.

## 3. Install and configure etcd

Install the separately-maintained [etcd snap](https://snapcraft.io/etcd)
and configure it, once, on the host that will serve etcd:

```bash
sudo snap install etcd
sudo cilium-snap.setup-etcd
```

By default this binds etcd to loopback only. See the etcd section of
configuration.md before widening the bind address, the config has no TLS
or auth.

Re-run with --force after changing the bind address:

```bash
sudo cilium-snap.setup-etcd --force
```

## 4. Install the CNI plugin on the host

```bash
sudo cilium-snap.install-cni
```

Copies the CNI plugin binaries and writes the CNI config to the host.
Removed again on `snap remove`.

## 5. Verify

```bash
sudo snap services cilium-snap
sudo cilium-snap.cilium-dbg status
```

On failure, check `cilium-dbg status --all-controllers` and
`journalctl -u snap.cilium-snap.cilium-agent.service`.

## 6. Configure runtime options

```bash
sudo snap set cilium-snap debug=true
```

Full key reference in configuration.md, including the multi-agent setup.

## Uninstalling

```bash
sudo snap remove cilium-snap
```

Removes the host-installed CNI files and releases this node's IPAM claim
from etcd. The etcd snap itself is not touched.
