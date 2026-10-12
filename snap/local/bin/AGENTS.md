# Snap Local Bin Directory (`snap/local/bin/`)

## Overview
Houses entrypoints and wrapper scripts bundled into the snap to start daemons and install host resources.

## Responsibilities
- `cilium-agent-wrapper`: Entrypoint daemon wrapper for `cilium-agent`. Mounts bpffs and cgroup2, refreshes the eBPF datapath sources from `$SNAP` into `$SNAP_COMMON` so `--lib-dir` is writable, waits for etcd readiness on the configured endpoint (local or remote), and builds the runtime flag set. PATH and `LD_LIBRARY_PATH` come from the `environment:` block in `snapcraft.yaml`, not from this script.
- `setup-etcd`: One-shot utility command that renders `/var/snap/etcd/common/etcd.conf.yml` for the separately-installed `etcd` snap and starts it as Cilium's kvstore.
- `install-cni`: One-shot utility command to install Cilium CNI binaries and configuration directly onto the host filesystem (`/opt/cni/bin` and `/etc/cni/net.d`).
