# Smoke Test Suite (`tests/smoke/`)

## Overview
Bash smoke suite that validates an installed `cilium-snap` end to end: packaging, daemons, kvstore, agent configuration, datapath, CNI, real pod-to-pod traffic, `snap set` plumbing and restart recovery.

The suite needs root, a real kernel, and a free `127.0.0.1:2379`. It never builds anything -- point it at an installed snap or hand it a `.snap` file.

## Responsibilities
- `run.sh`: Orchestrator. Discovers `test_*` functions in `cases/`, runs each in its own subshell, prints a summary and exits non-zero on failure. Options: `--snap <file>` (install first), `--filter <pattern>`, `--list`, `--remove`.
- `run-multipass.sh`: Provisions or reuses a Multipass VM, copies the suite and the snap in, and runs `run.sh` there. The on-prem entry point.
- `lib/harness.sh`: Assertions (`assert_eq`, `assert_contains`, `assert_matches`, `assert_mountpoint`, `retry_until`, ...), case registration and result reporting. `fail` aborts a case; `skip` marks it skipped.
- `lib/snap.sh`: Snap-specific helpers -- effective config lookup (`snap_config`), `cilium-dbg` JSON accessors, CNI invocation, endpoint identity resolution and namespace teardown.
- `cases/*.sh`: Numbered case files, run in filename order; functions run in declaration order.

## Cases
- `10-packaging.sh`: Snap installed and classic, every app present, client binaries run, pinned SHA matches the build, bundled clang executes.
- `20-services.sh`: Both daemons enabled and active, start ordering, state directories, staged eBPF sources, no fatal logs.
- `30-etcd.sh`: Endpoint health, read/write roundtrip, single-node cluster, Cilium node state persisted, agent connected with quorum.
- `40-agent.sh`: Agent Ok, Kubernetes disabled, IPAM range, kvstore identity allocation, controller health, routing and masquerade configuration.
- `50-datapath.sh`: bpffs and cgroup2 mounts, pinned BPF maps, runtime-compiled datapath objects, device attachment, iptables chains.
- `60-cni.sh`: `install-cni` places binaries and a valid conflist, is idempotent, plugin version handshake, bad invocation rejected.
- `70-connectivity.sh`: CNI ADD/DEL against real network namespaces, pod-to-pod, pod-to-host and masqueraded egress traffic, default-deny for endpoints still in `reserved:init`.
- `80-configuration.sh`: `config.env` rendering and shell-quoting, `snap set`/`snap unset` reaching the agent, no-op settings not restarting it, rapid changes not wedging it.
- `90-lifecycle.sh`: Agent, etcd and whole-snap restarts recover, pinned maps survive, datapath reattaches, workloads can still be networked afterwards.

## Conventions
- A case is a `test_*` function; it fails by calling an assertion helper or returning non-zero.
- Cleanup belongs in an `EXIT` trap inside the case -- cases run in subshells and `fail` exits, so `RETURN` traps would not fire.
- Declare locals that reference other locals in a separate `local` statement; bash evaluates arithmetic in a multi-name `local` before the earlier names are assigned.
