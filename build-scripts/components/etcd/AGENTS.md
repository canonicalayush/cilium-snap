# etcd Component (`build-scripts/components/etcd/`)

## Overview
Defines the upstream source repository, pinned version, and build steps for etcd.

## Files
- `repository`: Points to `https://github.com/etcd-io/etcd`.
- `version`: Pinned version tag of upstream etcd (e.g., `v3.7.2`).
- `build.sh`: Compiles `etcd` and `etcdctl` Go binaries and places them into the destination binary path.
