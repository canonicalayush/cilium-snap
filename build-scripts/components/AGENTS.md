# Components Directory (`build-scripts/components/`)

## Overview
Stores modular component definitions for upstream software built and bundled into the snap package, following the `canonical/k8s-snap` pattern.

## Structure
- `cilium/`: Cilium datapath, agent, and tooling build configuration.
- `cni-plugins/`: Standard CNI network plugins build configuration.

Each component subdirectory contains:
- `repository`: Git remote repository URL.
- `version`: Specific tag or full 40-character commit SHA pinned for reproducible builds (abbreviated SHAs are rejected; see `build-component.sh`).
- `build.sh`: Component build instructions executed by `build-component.sh`.
