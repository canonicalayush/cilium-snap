# Cilium Component (`build-scripts/components/cilium/`)

## Overview
Defines the upstream source repository, pinned version, and build steps for Cilium.

## Files
- `repository`: Points to `https://github.com/cilium/cilium`.
- `version`: Pinned upstream Cilium ref (release tag, tracking canonical/k8s-snap's Helm chart version in `build-scripts/hack/update-cilium-chart.sh`; a bare commit SHA also works, see `build-component.sh`).
- `build.sh`: Compiles `cilium-agent`, `cilium-dbg`, `hubble`, CNI plugin binaries, and bundles the eBPF datapath C headers and templates into the target install path.
