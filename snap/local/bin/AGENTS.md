# Snap Local Bin Directory (`snap/local/bin/`)

## Overview
Houses entrypoints and wrapper scripts bundled into the snap to start daemons and install host resources.

## Responsibilities
- `cilium-agent-wrapper`: Entrypoint daemon wrapper for `cilium-agent`. Mounts bpffs and cgroup2, refreshes the eBPF datapath sources from `$SNAP` into `$SNAP_COMMON` so `--lib-dir` is writable, and builds the runtime flag set, branching on `$MODE`: standalone waits for etcd readiness and builds the kvstore/IPAM flag set; kubernetes points the agent at `$SNAP_DATA/kubeconfig` and the synced cluster config directory. PATH and `LD_LIBRARY_PATH` come from the `environment:` block in `snapcraft.yaml`, not from this script.
- `setup-etcd`: One-shot utility command that renders `/var/snap/etcd/common/etcd.conf.yml` for the separately-installed `etcd` snap and starts it as Cilium's kvstore.
- `setup-k8s`: One-shot utility command for kubernetes mode. Mints apiserver credentials for this node's agent, syncs the cluster's `kube-system/cilium-config` into `$SNAP_DATA/cilium-config`, and excludes this node from the in-cluster `cilium` DaemonSet.
- `install-cni`: One-shot utility command to install Cilium CNI binaries and configuration directly onto the host filesystem (`/opt/cni/bin` and `/etc/cni/net.d`). In kubernetes mode it only installs `cilium-cni` unconditionally -- other plugins and the conflist are left to k8sd and the agent respectively.
