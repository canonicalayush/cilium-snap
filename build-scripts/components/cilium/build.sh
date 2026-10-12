#!/bin/bash
# Build cilium-agent and its host-side helpers, plus the eBPF C sources.
#
# Uses the same make targets as upstream's own agent image
# (images/cilium/Dockerfile:44-45), so what lands in the snap matches what
# lands in quay.io/cilium/cilium:
#
#   build-container          -> daemon, cilium-dbg, cilium-health, bugtool,
#                               hubble, plugins/cilium-cni, tools/*
#   install-container-binary -> installs the above into $DESTDIR/usr/bin and,
#                               via its install-bpf dependency (Makefile:200),
#                               copies bpf/ into $DESTDIR/var/lib/cilium/bpf.
#
# NOSTRIP=1 keeps symbols (Makefile.defs:149-156); useful while debugging a PoC.

INSTALL="${1}"

set -eu

export GOTOOLCHAIN=local
export CGO_ENABLED=0
# Snapcraft's `platforms:` shorthand currently builds each arch natively
# (build-on == build-for), so `go env GOARCH` is already correct; this only
# matters if a future build-on/build-for split cross-builds instead, same as
# upstream's own Dockerfile (images/cilium/Dockerfile:44, GOARCH=${TARGETARCH}).
export GOARCH="${CRAFT_ARCH_BUILD_FOR:-$(go env GOARCH)}"

make \
  DESTDIR="${INSTALL}" \
  PKG_BUILD=1 \
  NOSTRIP=1 \
  build-container install-container-binary
