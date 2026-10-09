# Snap Local Bin Directory (`snap/local/bin/`)

## Overview
Houses entrypoints and wrapper scripts bundled into the snap to start daemons and install host resources.

## Responsibilities
- `cilium-agent-wrapper`: Entrypoint daemon wrapper for `cilium-agent`. Manages necessary filesystem mounts (e.g., bpffs, cgroup2), waits for etcd readiness on the configured etcd endpoint (local or remote), sets runtime environment paths, and handles runtime flags.
- `setup-etcd`: One-shot utility command that renders `/var/snap/etcd/common/etcd.conf.yml` for the separately-installed `etcd` snap and starts it as Cilium's kvstore.
- `install-cni`: One-shot utility command to install Cilium CNI binaries and configuration directly onto the host filesystem (`/opt/cni/bin` and `/etc/cni/net.d`).
