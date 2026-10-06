# Cilium Component (`build-scripts/components/cilium/`)

## Overview
Defines the upstream source repository, pinned version, and build steps for Cilium.

## Files
- `repository`: Points to `https://github.com/cilium/cilium`.
- `version`: Pinned commit hash of upstream Cilium.
- `build.sh`: Compiles `cilium-agent`, `cilium-dbg`, `hubble`, CNI plugin binaries, and bundles the eBPF datapath C headers and templates into the target install path.
