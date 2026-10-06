# Cilium Standalone Snap

This repository packages [Cilium](https://github.com/cilium/cilium) as a snap designed to run on a single host without a Kubernetes apiserver.

Because Cilium requires a key-value store for identity and state management when running standalone, this snap bundles [etcd](https://github.com/etcd-io/etcd), datapath compilation toolchains, and host CNI integration utilities.

## What this repository is responsible for

- **Snap packaging**: Defining the `cilium-snap` snap specification in `snap/snapcraft.yaml` with classic confinement.
- **Upstream component builds**: Fetching and compiling pinned versions of upstream components (`cilium`, `etcd`, and `cni-plugins`) via `build-scripts/`.
- **Runtime service orchestration**: Providing daemon wrappers (`etcd-wrapper`, `cilium-agent-wrapper`) and configuration hooks to manage local services and settings.
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

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
