#!/bin/bash
# Build etcd.
#
# Pinned to v3.7.2 to match the etcd server Cilium itself ships in its
# clustermesh-apiserver image (images/clustermesh-apiserver/Dockerfile:18);
# Cilium vendors the matching client, go.etcd.io/etcd/client/v3 v3.7.1
# (go.mod:109). For reference, canonical/k8s-snap pins v3.7.1.
#
# `make build` emits etcd, etcdctl and etcdutl into ./bin. etcdctl is kept:
# the agent wrapper uses it for the etcd readiness probe, and it is the
# obvious tool for inspecting Cilium's kvstore state by hand.

INSTALL="${1}/usr/bin"

mkdir -p "${INSTALL}"

export GOTOOLCHAIN=local
export CGO_ENABLED=0

make build
cp bin/etcd bin/etcdctl bin/etcdutl "${INSTALL}/"
