# Cilium Standalone Snap

This repository packages [Cilium](https://github.com/cilium/cilium) as a
snap designed to run on a single host without a Kubernetes apiserver.

Because Cilium requires a key-value store for identity and state
management when running standalone, this snap depends on the
separately-installed [etcd snap](https://snapcraft.io/etcd) as that
kvstore, and bundles the datapath compilation toolchain and host CNI
integration utilities Cilium needs at runtime.

## Documentation

- [Architecture](docs/architecture.md): how the snap is built and how
  it runs, with a diagram.
- [Setup](docs/setup.md): build, install, and first-run walkthrough.
- [Configuration](docs/configuration.md): every `snap set` key, and the
  multi-host/multi-agent recipe.
- [Testing](docs/testing.md): the smoke test suite and CI workflows.
- [Findings](docs/findings.md): agent-summarised investigation
  write-ups.

Every directory also has its own AGENTS.md with directory-local context
for coding agents, starting at the root [AGENTS.md](AGENTS.md).

## What this repository is responsible for

- **Snap packaging**: defining the cilium-snap specification in
  snap/snapcraft.yaml with classic confinement.
- **Upstream component builds**: fetching and compiling pinned versions
  of Cilium and the reference CNI plugins through build-scripts/.
- **Runtime service orchestration**: a daemon wrapper managing the
  local agent and its configuration, plus a one-shot command that
  configures and starts the external etcd snap as its kvstore.
- **CNI deployment**: a host CNI installation command that copies the
  CNI plugin binaries and writes the Cilium CNI config to the host.

## Quick start

```bash
snapcraft --use-lxd
sudo snap install --dangerous --classic ./cilium-snap_*.snap
sudo snap install etcd
sudo cilium-snap.setup-etcd
sudo cilium-snap.install-cni
sudo snap services cilium-snap
```

See [docs/setup.md](docs/setup.md) for the full walkthrough and
[docs/configuration.md](docs/configuration.md) for every tunable,
including running multiple agents against one shared etcd instance.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
