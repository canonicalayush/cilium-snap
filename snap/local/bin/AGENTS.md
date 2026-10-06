# Snap Local Bin Directory (`snap/local/bin/`)

## Overview
Houses entrypoints and wrapper scripts bundled into the snap to start daemons and install host resources.

## Responsibilities
- `cilium-agent-wrapper`: Entrypoint daemon wrapper for `cilium-agent`. Manages necessary filesystem mounts (e.g., bpffs, cgroup2), waits for etcd readiness on `127.0.0.1:2379`, sets runtime environment paths, and handles runtime flags.
- `etcd-wrapper`: Entrypoint daemon wrapper for standalone `etcd`. Sets up data directories and starts etcd listening on localhost.
- `install-cni`: One-shot utility command to install Cilium CNI binaries and configuration directly onto the host filesystem (`/opt/cni/bin` and `/etc/cni/net.d`).
