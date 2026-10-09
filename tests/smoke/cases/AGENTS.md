# Smoke Test Cases (`tests/smoke/cases/`)

## Overview
One file per concern, run in filename order. `run.sh` sources each file and runs its `test_*` functions in declaration order, each in its own subshell.

## Files
- `10-packaging.sh`: Packaging and bundled binaries.
- `20-services.sh`: Daemon units, ordering, state directories, logs.
- `30-etcd.sh`: Bundled kvstore health, persistence and Cilium node state.
- `40-agent.sh`: Standalone agent configuration and controller health.
- `50-datapath.sh`: Mounts, pinned BPF maps, runtime datapath compilation and attachment.
- `60-cni.sh`: `install-cni` output and the CNI plugin handshake.
- `70-connectivity.sh`: Real traffic through CNI-attached network namespaces.
- `80-configuration.sh`: `snap set` plumbing, quoting, and restart behaviour.
- `90-lifecycle.sh`: Restart recovery for the agent, etcd, and the whole snap.

## Writing a case
- Name the function `test_<behaviour>`; one observable contract per case.
- Fail via the assertion helpers in `lib/harness.sh`; call `skip <reason>` when a precondition genuinely does not exist on the host.
- Put cleanup in an `EXIT` trap -- cases run in subshells and `fail` exits, so `RETURN` traps never fire.
- Anything that creates network namespaces must prefix them with `$SMOKE_NETNS_PREFIX` so `smoke_teardown_netns` can reclaim them.
