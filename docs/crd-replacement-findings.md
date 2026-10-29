# How `cilium-snap` replaces Cilium's Kubernetes CRDs

Findings from reviewing upstream Cilium (`~/Work/cilium`, pinned reference `main`
@ `1.21.0-dev`/`bf3e61f257`; this snap itself pins
`build-scripts/components/cilium/version` = **`v1.20.0`** — the mechanism described
below is stable across that gap, the exact CRD count may not be) against this
repo's packaging (`snap/snapcraft.yaml`, `snap/local/bin/cilium-agent-wrapper`,
`snap/local/etc/defaults.env`, `snap/hooks/configure`, `tests/smoke/`).

## 1. Why Cilium has CRDs at all

Running under Kubernetes, Cilium gets three things from the apiserver that it
cannot get any other way by default:

1. **Identity allocation** — mapping a pod's label set to a cluster-wide
   numeric security identity (`CiliumIdentity`).
2. **Policy distribution** — `CiliumNetworkPolicy` /
   `CiliumClusterwideNetworkPolicy` (plus core `NetworkPolicy`) objects pushed
   to every agent.
3. **Load-balancer state** — `Service` / `Endpoints` / `EndpointSlice`
   objects that seed the BPF service map.

`snap/snapcraft.yaml:13-20` states this plainly in the package description:

> Kubernetes normally supplies Cilium with identity allocation (CiliumIdentity
> CRDs), policy (CiliumNetworkPolicy CRDs) and load-balancer state
> (Service/EndpointSlice). Without an apiserver, Cilium needs a kvstore
> instead — and this is not optional: with `--kvstore` unset, the agent
> silently rewrites `identity-allocation-mode` to `"crd"` and then requires an
> apiserver it does not have.

Beyond those three, Cilium ships **25 CRDs** total (upstream, `main`), all
registered from embedded YAML by **the operator only**
(`pkg/k8s/apis/cell.go:68`, `createCRDs`, unless `--skip-crd-creation`) via
`CustomResourceDefinitionList()` (`pkg/k8s/apis/cilium.io/client/register.go:109`):

- **`cilium.io/v2`** (17): `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy`,
  `CiliumNode`, `CiliumEndpoint`, `CiliumIdentity`, `CiliumLocalRedirectPolicy`,
  `CiliumEgressGatewayPolicy`, `CiliumEnvoyConfig`, `CiliumClusterwideEnvoyConfig`,
  `CiliumNodeConfig`, `CiliumCIDRGroup`, `CiliumLoadBalancerIPPool`,
  `CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, `CiliumBGPAdvertisement`,
  `CiliumBGPNodeConfig`, `CiliumBGPNodeConfigOverride`.
- **`cilium.io/v2alpha1`** (8): `CiliumEndpointSlice`, `CiliumL2AnnouncementPolicy`,
  `CiliumPodIPPool`, `CiliumGatewayClassConfig`, `CiliumDatapathPlugin`,
  `CiliumNetworkDriverClusterConfig`, `CiliumNetworkDriverNodeConfig`,
  `CiliumResourceIPPool`.

Cilium's **operator** is what owns CRD registration. This snap packages only
`cilium-agent` and the host-side helpers (`build-scripts/components/cilium/build.sh:8-12`
builds `build-container`/`install-container-binary` — agent, `cilium-dbg`,
`cilium-health`, `bugtool`, `hubble`, the CNI plugin, and `tools/*`; no operator
binary). There is no operator in this snap, so there is nothing that could
register or serve any of the 25 CRDs even if an apiserver existed. The whole
design point is to avoid needing an apiserver (and therefore an operator) at
all — see `README.md:1-5`.

## 2. What this snap actually replaces, and how

Three upstream in-tree, non-CRD substitutes exist for parts of the CRD surface
(`identity-allocation-mode=kvstore`, `static-cnp-path`, `lb-state-file`). This
snap wires up **one of the three** today.

### 2a. `CiliumIdentity` → etcd kvstore (wired up)

Replaced by `--kvstore=etcd` + `--identity-allocation-mode=kvstore`, set
unconditionally in `snap/local/bin/cilium-agent-wrapper:70-74`:

```
--enable-k8s=false
--kvstore=etcd
--kvstore-opt "etcd.address=${ETCD_HOST}:${ETCD_PORT}"
--identity-allocation-mode=kvstore
```

The wrapper's own comments (`cilium-agent-wrapper:46-47`) explain why this is
mandatory rather than a tunable default: `--kvstore` empty silently rewrites
`identity-allocation-mode` to `crd` (upstream `pkg/option/config.go:2784-2789`),
and the CRD backend then has no apiserver to talk to. Per the upstream
dependency matrix, that failure mode is **not fatal, it's a silent stall** —
`InitIdentityAllocator` is simply never called, the allocator is left
backend-less, and every `AllocateIdentity` call blocks until
`--identity-allocation-timeout` expires (`daemon/cmd/daemon.go:238-245`,
`pkg/identity/cache/allocator.go:328,447-455`). The snap avoids this entire
class of bug by hard-coding the kvstore flags rather than exposing
`identity-allocation-mode` as a `snap set` key.

This snap packages a whole separate component — the `etcd` snap, driven by
`cilium-snap.setup-etcd` (`snap/local/bin/setup-etcd`) — for no other reason
than to be this identity (and node-state) backend. `README.md:30-35` and
`snap/snapcraft.yaml:166-168` document it as a hard runtime dependency, not an
optional extra.

Verified by the smoke suite: `tests/smoke/cases/40-agent.sh:29-37`
(`test_identity_allocation_via_kvstore`, reads the agent's global identity
range), `tests/smoke/cases/70-connectivity.sh:92-108`
(`test_identity_allocated_in_kvstore`, attaches a real CNI namespace and
confirms the allocated identity is written under
`cilium/state/identities/v1/` in etcd, "identities are allocated in the
kvstore, not as CRDs"), and `tests/smoke/cases/30-etcd.sh:49-70`
(`test_etcd_holds_cilium_node_state`, confirms node state —
upstream's `CiliumNode` role — lands in etcd under
`cilium/state/nodes/v1/default/`).

### 2b. `CiliumNode` → manual pod CIDR, no CRD precreation

Upstream's `CiliumNode` CRD carries node-specific IPAM/health/WireGuard state
and (depending on IPAM mode) blocks agent startup until it exists
(`daemon/cmd/daemon.go:161-164`, `needsCiliumNodeBeforeIPAM`, for IPAM modes
`cluster-pool`/`multi-pool`/`eni`/`azure`). This snap sidesteps it entirely:

- `--enable-k8s=false` means `Clientset.IsEnabled()` is `false`
  (`pkg/k8s/client/config.go:94`), so `CiliumNode` creation/annotation never
  runs (`pkg/nodediscovery/nodediscovery.go:221-285` is unreachable).
- `--ipam=cluster-pool` (`snap/local/etc/defaults.env:10`) plus a required
  `--ipv4-range="$IPV4_RANGE"` (`cilium-agent-wrapper:92`, default
  `10.20.0.0/16` in `defaults.env:25`) seeds `LocalNodeStore` directly
  (upstream `pkg/ipam/cell/ipam_init.go:68-100,135-141`), bypassing the
  `CiliumNode`/`Node` wait in `WaitForNodeInformation`
  (`pkg/node/sync/local_node_sync_wait.go:81-153`) — which itself never runs
  under `--enable-k8s=false` because it's gated inside the same
  `Clientset.IsEnabled()` block as the CRD-sync wait
  (`daemon/cmd/daemon.go:145-165`).
- `cilium-agent-wrapper:48-49` documents the IPAM-mode tradeoff directly in
  the wrapper source: "cluster-pool only needs `--ipv4-range`;
  crd/eni/azure/alibabacloud/multi-pool need a `CiliumNode` (apiserver)."

Verified by `tests/smoke/cases/40-agent.sh:18-27`
(`test_ipam_cluster_pool_active`, confirms IPAM allocates from the configured
range with no CRD) and `tests/smoke/cases/70-connectivity.sh:49-75`
(`test_cni_add_allocates_from_pod_cidr`).

### 2c. CRD sync wait → skipped, not satisfied

`--enable-k8s=false` also means the agent never blocks on
`CRDSyncPromise.Await(ctx)` (`daemon/cmd/daemon.go:149-159`) or
`K8sWatcher.InitK8sSubsystem` (`pkg/k8s/watchers/watcher.go:236-269`, which
self-exits logging "Not enabling k8s event listener because k8s is not
enabled"). This isn't a substitute for the CRDs' function — it's the absence
of the wait that normally proves the operator installed them. Confirmed live
by `tests/smoke/cases/40-agent.sh:10-16`
(`test_running_without_kubernetes`: `cilium-dbg status` reports
`.kubernetes.state == "Disabled"`).

### 2d. `CiliumNode` CIDR allocation — collision detection added (closes a real gap)

§2b's "manual pod CIDR" substitute had a real hole: `cluster-pool`'s per-node
CIDR subdivision is normally performed by `cilium-operator`
(`operator/pkg/ipam/allocator/clusterpool/clusterpool.go`), writing the
result to each node's `CiliumNode.spec.ipam.podCIDRs`
(`pkg/ipam/types/types.go:154-158`). There is **no kvstore-mode equivalent
allocator** anywhere in `pkg/ipam/` — kvstore mode's `NodeRegistrar.RegisterNode`
(`pkg/node/store/store.go:152`) only *publishes* a node's already-chosen CIDR
for other nodes to discover (one-way write, gated solely on
`client.IsEnabled()`); nothing reads it back to detect or prevent a collision.
`pkg/nodediscovery/nodediscovery.go:347` flags this split explicitly in a
comment pointing at `RegisterNode` as kvstore mode's "equivalent logic" to the
CRD-mode CiliumNode write — propagation only, not arbitration.

Without a check, two nodes sharing one etcd could be configured with
overlapping `ipv4-range`s and nothing would refuse to start either one.
Combined with `enable-auto-direct-node-routes=true` (the documented
multi-agent recipe, `README.md:64-86`), that silently installs routes
steering one node's pod traffic at another node's pods — cross-node traffic
interception, not just a routing bug.

Closed by `snap/local/bin/cilium-ipam-reserve`, invoked from
`cilium-agent-wrapper:44-50` before the agent starts and from
`snap/hooks/remove` on clean removal:

- Claims `${IPV4_RANGE}` under `cilium-snap/ipam/claims/<node-name>` in etcd
  (a prefix distinct from Cilium's own `cilium/` keyspace), guarded by
  `etcdctl lock` so two agents racing to start at the same instant cannot
  both see an empty scan and both write overlapping claims.
- Scans all other nodes' claims for CIDR overlap (pure-bash interval math,
  not string equality — `10.20.0.0/16` vs. `10.20.5.0/24` is correctly
  caught) and refuses to start (non-zero exit, `set -eu` aborts the wrapper)
  on any collision with a *different* node-name. A node reclaiming its own
  unchanged or changed range on restart is unaffected (self-claims are
  skipped during the scan).
- Ships its own `etcdctl` via a new `etcd-client` stage-package
  (`snap/snapcraft.yaml`, `runtime-deps` part) rather than depending on the
  separate `etcd` snap being installed on every agent host — the documented
  multi-host flow only installs that snap on the etcd host itself.
- Does **not** allocate a range (the admin still picks it) and does **not**
  lease-bind claims for automatic expiry: a node removed without a clean
  `snap remove` (host destroyed, not decommissioned) leaves its claim in
  etcd indefinitely, reserving that exact range against any *other*
  node-name until an operator runs `cilium-ipam-reserve release` or deletes
  the key by hand. This is a deliberate tradeoff — failing loudly on a stale
  claim beats silently expiring it and letting a collision through.

Verified end-to-end against a live etcd instance (not just by reading
source): first claim succeeds; a genuinely overlapping second claim is
rejected and never written; a disjoint second claim succeeds; the same node
re-claiming its unchanged range on "restart" is idempotent; a malformed CIDR
is rejected before any etcd call; release-then-reclaim-by-another-node works.
Smoke-test coverage: `tests/smoke/cases/40-agent.sh`
(`test_ipam_range_claimed_in_etcd`, `test_ipam_collision_rejected`,
`test_ipam_disjoint_claim_accepted`).

## 3. What this snap does **not** replace (gaps vs. the CRD surface)

Grepping this repo for the other two upstream non-CRD substitutes
(`--static-cnp-path`, `--lb-state-file`) returns **zero matches** — neither
flag is referenced anywhere in `snap/`, `build-scripts/`, or `tests/`.

### 3a. `CiliumNetworkPolicy` / `CiliumClusterwideNetworkPolicy` — not wired up

Upstream has an in-tree, non-CRD substitute:
`--static-cnp-path <dir>` (`pkg/policy/directory/cell.go:50`), which loads
CNP/CCNP policy from local YAML via a directory watcher instead of the
apiserver. This snap does not set it, does not expose a `snap set` key for
it, and does not stage a policy directory anywhere in `snap/local/`. Combined
with `--enable-k8s=false` (no core `NetworkPolicy` watch either), **this snap
currently has no mechanism to load L3/L4/L7 network policy at all.**
Every endpoint still gets a real identity via the kvstore path (§2a), so
identity-aware policy *could* be enforced — there is simply no delivery
channel wired up for the policy rules themselves yet.

`snap/snapcraft.yaml:13-14`'s own description names
"policy (CiliumNetworkPolicy CRDs)" as one of the three things Kubernetes
normally supplies — the doc comment acknowledges the gap exists even though
nothing in the parts/wrapper closes it.

### 3b. `Service` / `EndpointSlice` (load-balancer state) — not wired up

Upstream's substitute is `--lb-state-file <path>` +
`--lb-state-file-interval` (`pkg/loadbalancer/reflectors/file.go:33`),
reading `Service`/`Endpoints` definitions from a local file reflector instead
of the apiserver. Also absent from this repo. The smoke suite's service
coverage (`tests/smoke/cases/20-services.sh`) only checks that the
**snapd services** (`cilium-agent`, `etcd`) are up — it does not exercise
Cilium `Service`/load-balancer functionality at all, because there is
currently no Kubernetes-`Service`-equivalent input: pod-to-pod and pod-to-host
connectivity work (`tests/smoke/cases/70-connectivity.sh`), but there is no
ClusterIP/NodePort-style virtual-IP load balancing in this snap today.

### 3c. Hard blockers — no in-tree substitute exists upstream, for anyone

Of the 25 CRDs, upstream has **no non-CRD backend at all** (not a gap in this
snap's wiring — a gap in Cilium itself) for:

`CiliumNode`, `CiliumEndpoint`, `CiliumEndpointSlice`,
`CiliumLocalRedirectPolicy`, `CiliumEgressGatewayPolicy`,
`CiliumEnvoyConfig`, `CiliumClusterwideEnvoyConfig`, `CiliumNodeConfig`,
`CiliumCIDRGroup`, `CiliumLoadBalancerIPPool`, `CiliumBGPClusterConfig`,
`CiliumBGPPeerConfig`, `CiliumBGPAdvertisement`, `CiliumBGPNodeConfig`,
`CiliumBGPNodeConfigOverride`, `CiliumL2AnnouncementPolicy`,
`CiliumPodIPPool`, `CiliumGatewayClassConfig`, `CiliumDatapathPlugin`,
`CiliumNetworkDriverClusterConfig`, `CiliumNetworkDriverNodeConfig`,
`CiliumResourceIPPool`.

In practice this snap's standalone mode never needs most of these — BGP, L2
announcements, egress gateway, local redirect, LB/pod IP pools, and
Ingress/Gateway API are all operator-driven, multi-node, or
Kubernetes-Service-shaped features this single-host/no-apiserver snap doesn't
attempt. `CiliumEndpoint`/`CiliumEndpointSlice` are the one entry in this list
with real-world relevance beyond "feature not applicable": they are how
multi-node deployments propagate remote pod IP→identity mappings. The kvstore
backend has its own IP-cache distribution, but there is no documented 1:1
substitute confirming cross-node endpoint visibility works the same way
without `CiliumEndpoint` sync — this is flagged as an open question in the
upstream research, not confirmed either way by this snap's current smoke
coverage (which only exercises two network namespaces on a single host,
`tests/smoke/cases/70-connectivity.sh:5-7`).

## 4. Summary table

| Upstream CRD / mechanism | Normally provided by | Replaced in this snap? | Mechanism | Evidence |
|---|---|---|---|---|
| `CiliumIdentity` | apiserver + operator-registered CRD | **Yes** | `--kvstore=etcd` + `--identity-allocation-mode=kvstore` | `cilium-agent-wrapper:70-74`; `tests/smoke/cases/40-agent.sh:29-37`, `70-connectivity.sh:92-108` |
| `CiliumNode` (IPAM/node state) | apiserver | **Yes** (avoided + collision-checked, not substituted) | `--enable-k8s=false` + `--ipam=cluster-pool` + `--ipv4-range`, validated against other nodes' claims via `cilium-ipam-reserve` (§2d) | `cilium-agent-wrapper:44-50,70-92`; `tests/smoke/cases/40-agent.sh:18-27,49-80` |
| CRD-sync startup gate | operator-installed CRDs | **Yes** (skipped) | `--enable-k8s=false` | `tests/smoke/cases/40-agent.sh:10-16` |
| `CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy` | apiserver | **No** | upstream has `--static-cnp-path`; not wired up here | grep: zero hits in repo |
| `Service`/`Endpoints`/`EndpointSlice` (LB state) | apiserver | **No** | upstream has `--lb-state-file`; not wired up here | grep: zero hits in repo |
| `CiliumEndpoint`/`CiliumEndpointSlice` (cross-node) | apiserver | **No**, and no upstream substitute exists | — | N/A — hard blocker |
| BGP / L2 announce / Envoy config / egress gateway / LRP / LB-IP-pools / Gateway API (12 CRDs) | apiserver + operator | **No**, and no upstream substitute exists | — | N/A — hard blocker, feature not attempted by this snap |

## 5. Open gaps / recommendations

- **`CiliumNetworkPolicy` support is now the most actionable remaining gap**
  (the CIDR-collision gap below is closed). Wiring `--static-cnp-path` to a
  writable directory under `$SNAP_COMMON` (plus a `snap set` key, matching
  the pattern every other tunable in `defaults.env`/`configure` already
  follows) would let operators load network policy without a cluster. Low
  effort relative to upstream's existing support — the directory watcher
  is already in-tree.
- **IPAM range collisions are now detected** (§2d,
  `cilium-ipam-reserve`), closing the gap originally noted here. Residual,
  deliberate limitation: claims are not lease-bound, so a node removed
  without a clean `snap remove` leaves a stale claim in etcd that an
  operator must clear by hand before reusing that range under a different
  node-name (`cilium-ipam-reserve release`, or `etcdctl del
  cilium-snap/ipam/claims/<node-name>`). A lease/TTL-based auto-reclaim
  would close that residual gap but moves closer to the "dynamic pool
  allocator" design this fix deliberately avoided (standing
  background-renewal subsystem, not just a startup check).
- **Load-balancer state (`--lb-state-file`) is lower priority** for a
  single-host CNI use case but would be needed before this snap could claim
  any Service/NodePort-style functionality; currently none is advertised or
  tested.
- **Cross-node `CiliumEndpoint` propagation is unverified**, not just
  unimplemented — multi-agent setups (`README.md:64-86`,
  "Running multiple agents against one etcd instance") rely on kvstore node
  state (§2a) for routing but have not been confirmed to replicate the
  identity-visibility guarantees `CiliumEndpoint`/`CiliumEndpointSlice` give
  under Kubernetes. Worth an explicit multi-host smoke scenario before this
  snap's documentation promises cross-node policy enforcement.
