# Testing

tests/smoke/ is a bash suite that installs the built snap on a real host
and exercises the agent, etcd, the CNI plugin, and real pod traffic. It
needs root, a real kernel, and a free loopback etcd port, so run it in a
VM or CI, not nested inside a container.

## Running locally

```bash
sudo tests/smoke/run.sh                              # against an installed snap
sudo tests/smoke/run.sh --snap ./cilium-snap_*.snap   # install first
sudo tests/smoke/run.sh --filter connectivity         # only matching cases
sudo tests/smoke/run.sh --list                        # list cases
sudo tests/smoke/run.sh --reset-etcd                  # wipe etcd state first
```

Requires jq, ip, ping, snap, systemctl, findmnt, mountpoint and
iptables-save on PATH.

## Running in a Multipass VM

```bash
tests/smoke/run-multipass.sh --create --snap ./cilium-snap_*.snap
tests/smoke/run-multipass.sh --vm cilium-snap-smoke        # reuse
tests/smoke/run-multipass.sh --vm scratch --create --delete  # throwaway
```

## Suite structure

- lib/harness.sh: test registration, assertions, polling, output helpers.
- lib/snap.sh: knowledge specific to this snap, app and service names,
  config lookups, cilium-dbg JSON accessors, CNI and endpoint helpers.
- cases/: one file per concern, run in filename order.

  - 10-packaging.sh: packaging and bundled binaries.
  - 20-services.sh: daemon units, state directories, logs.
  - 30-etcd.sh: external kvstore health and node state.
  - 40-agent.sh: standalone agent configuration and controller health.
  - 50-datapath.sh: mounts, pinned BPF maps, datapath compilation.
  - 60-cni.sh: install-cni output and the CNI handshake.
  - 70-connectivity.sh: real traffic through CNI network namespaces.
  - 80-configuration.sh: snap set plumbing and restart behaviour.
  - 90-lifecycle.sh: restart recovery for the agent, etcd, and the snap.

## Writing a new case

- Name the function `test_<behaviour>`, one observable contract per case.
- Fail through the assertion helpers in lib/harness.sh. Call `skip` when
  a precondition does not exist on the host.
- Put cleanup in an EXIT trap, cases run in subshells so RETURN never
  fires.
- Prefix any network namespace with the shared smoke namespace prefix so
  teardown can reclaim it.

## CI workflows

lint.yaml runs on every PR and push to main: bash syntax checks and
ShellCheck, yamllint against snapcraft.yaml and .github/, codespell, and
a line-ending and trailing-whitespace check.

smoke-tests.yaml runs on PRs: builds the snap with Snapcraft and LXD,
installs it on a fresh runner, and runs the smoke suite as root. On
failure it collects service status, cilium-dbg status, and the agent and
etcd journal logs.
