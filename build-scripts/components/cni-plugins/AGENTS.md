# CNI Plugins Component (`build-scripts/components/cni-plugins/`)

## Overview
Defines the upstream source repository, pinned version, and build steps for containernetworking/plugins.

## Files
- `repository`: Points to `https://github.com/containernetworking/plugins`.
- `version`: Pinned version tag of upstream CNI plugins.
- `build.sh`: Builds standard CNI plugins (such as `loopback`) needed on the host or by Cilium.
