#!/bin/bash
# Build the reference CNI plugins.
#
# cilium-cni is not self-sufficient: a CNI runtime also needs `loopback` to
# configure lo inside the container netns. Cilium ships exactly that plugin in
# its own runtime image, pinned to this same version
# (images/runtime/build-cni.sh:12), and canonical/k8s-snap pins the same repo
# and tag in build-scripts/components/cni.
#
# Built here (deliberately a short list, not the full plugin set):
#   loopback   - required by any CNI runtime for lo
#   portmap    - hostPort support; the plugin Cilium chains with for port maps
#   host-local - the delegated IPAM backend, needed only if --ipam is switched
#                back to delegated-plugin
#
# Installed into opt/cni/bin so they land beside cilium-cni, which `make
# install-container-binary` puts there via CNIBINDIR (Makefile.defs:26).

INSTALL="${1}/opt/cni/bin"
VERSION="${2}"

mkdir -p "${INSTALL}"

export GOTOOLCHAIN=local
export CGO_ENABLED=0

LDFLAGS="-s -w -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=${VERSION}"

for plugin in loopback portmap host-local; do
  case "${plugin}" in
    host-local) src="./plugins/ipam/host-local" ;;
    portmap)    src="./plugins/meta/portmap" ;;
    *)          src="./plugins/main/${plugin}" ;;
  esac
  go build -o "${INSTALL}/${plugin}" -ldflags "${LDFLAGS}" "${src}"
done

ls -l "${INSTALL}"
