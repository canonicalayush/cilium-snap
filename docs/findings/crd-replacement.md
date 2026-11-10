# How cilium-snap replaces Cilium's Kubernetes CRDs

> Agent-generated research summary, produced by an AI coding assistant
> tracing through upstream Cilium and this repo's packaging source.
> Treat it as a well-evidenced starting point, not an authoritative
> spec. Check the cited file and line references before relying on a
> claim here.

Reviewed against upstream Cilium (pinned reference main @
1.21.0-dev/bf3e61f257; this snap itself pins
build-scripts/components/cilium/version = v1.20.0, the mechanism below
is stable across that gap, the exact CRD count may not be) and this
repo's packaging (snap/snapcraft.yaml, cilium-agent-wrapper,
defaults.env, snap/hooks/configure, tests/smoke/).

## 1. Why Cilium has CRDs at all

Under Kubernetes, Cilium gets three things from the apiserver it cannot
get any other way by default:

1. Identity allocation: mapping a pod's label set to a cluster-wide
   numeric security identity (CiliumIdentity).
2. Policy distribution: CiliumNetworkPolicy, CiliumClusterwideNetworkPolicy
   and core NetworkPolicy objects pushed to every agent.
3. Load-balancer state: Service, Endpoints and EndpointSlice objects
   that seed the BPF service map.

snap/snapcraft.yaml:13-20 states this in the package description, and
notes that with --kvstore unset the agent silently rewrites
identity-allocation-mode to "crd" and then requires an apiserver it
doesn't have.

Beyond those three, Cilium ships 25 CRDs total (upstream, main), all
registered from embedded YAML by the operator only
(pkg/k8s/apis/cell.go:68, createCRDs, unless --skip-crd-creation), 17 in
cilium.io/v2 and 8 in cilium.io/v2alpha1.

This snap packages only cilium-agent and host-side helpers
(build-scripts/components/cilium/build.sh:8-12 builds agent, cilium-dbg,
cilium-health, bugtool, hubble, the CNI plugin, and tools/*, no operator
binary). There is no operator here, so nothing could register or serve
any of the 25 CRDs even if an apiserver existed. The design point is to
avoid needing an apiserver, and therefore an operator, at all.

## 2. What this snap replaces, and how

Upstream has three in-tree, non-CRD substitutes:
identity-allocation-mode=kvstore, static-cnp-path, and lb-state-file.
This snap wires up one of the three.

### 2a. CiliumIdentity: etcd kvstore (wired up)

Replaced by --kvstore=etcd plus --identity-allocation-mode=kvstore, set
unconditionally in cilium-agent-wrapper:70-74. The wrapper's own
comments (cilium-agent-wrapper:46-47) explain why this is mandatory
rather than a tunable: an empty --kvstore silently rewrites
identity-allocation-mode to crd (pkg/option/config.go:2784-2789), and
the CRD backend then has no apiserver to talk to. That failure mode is
not fatal, it's a silent stall: InitIdentityAllocator is never called,
and every AllocateIdentity call blocks until
--identity-allocation-timeout expires (daemon/cmd/daemon.go:238-245,
pkg/identity/cache/allocator.go:328,447-455).

This snap packages a separate component, the etcd snap driven by
cilium-snap.setup-etcd, for no other reason than to be this identity
(and node-state) backend. README.md and snapcraft.yaml:166-168 document
it as a hard runtime dependency.

Verified by the smoke suite: 40-agent.sh:29-37
(test_identity_allocation_via_kvstore), 70-connectivity.sh:92-108
(test_identity_allocated_in_kvstore, confirms identity is written under
cilium/state/identities/v1/ in etcd), and 30-etcd.sh:49-70
(test_etcd_holds_cilium_node_state, confirms node state, upstream's
CiliumNode role, lands under cilium/state/nodes/v1/default/).

### 2b. CiliumNode: manual pod CIDR, no CRD precreation

Upstream's CiliumNode CRD carries node IPAM/health/WireGuard state and,
depending on IPAM mode, blocks agent startup until it exists
(daemon/cmd/daemon.go:161-164). This snap sidesteps it:

- --enable-k8s=false means Clientset.IsEnabled() is false, so CiliumNode
  creation never runs (pkg/nodediscovery/nodediscovery.go:221-285 is
  unreachable).
- --ipam=cluster-pool plus a required --ipv4-range seeds LocalNodeStore
  directly (pkg/ipam/cell/ipam_init.go:68-100,135-141), bypassing the
  CiliumNode/Node wait in WaitForNodeInformation, which itself never
  runs under --enable-k8s=false.

Verified by 40-agent.sh:18-27 (test_ipam_cluster_pool_active) and
70-connectivity.sh:49-75 (test_cni_add_allocates_from_pod_cidr).

### 2c. CRD sync wait: skipped, not satisfied

--enable-k8s=false also means the agent never blocks on
CRDSyncPromise.Await (daemon/cmd/daemon.go:149-159) or
K8sWatcher.InitK8sSubsystem. This is the absence of the wait that
normally proves the operator installed the CRDs, not a substitute for
their function. Confirmed by 40-agent.sh:10-16
(test_running_without_kubernetes: cilium-dbg status reports
kubernetes.state == Disabled).

### 2d. CiliumNode CIDR allocation: collision detection added

Section 2b's manual pod CIDR substitute had a real hole: cluster-pool's
per-node CIDR subdivision is normally done by cilium-operator, writing
the result to each node's CiliumNode.spec.ipam.podCIDRs. There is no
kvstore-mode equivalent allocator: kvstore mode's
NodeRegistrar.RegisterNode only publishes a node's already-chosen CIDR,
nothing reads it back to detect a collision.

Two nodes sharing one etcd could be configured with overlapping
ipv4-ranges and nothing would refuse to start either one. Combined with
enable-auto-direct-node-routes=true (the documented multi-agent recipe),
that silently installs routes steering one node's pod traffic at
another node's pods.

Closed by cilium-ipam-reserve, invoked from cilium-agent-wrapper:44-50
before the agent starts and from snap/hooks/remove on clean removal:

- Claims the configured range under cilium-snap/ipam/claims/<node-name>
  in etcd, guarded by an etcd lock, so two agents racing to start
  cannot both write overlapping claims.
- Scans other nodes' claims for CIDR overlap using interval math, not
  string equality, and refuses to start on any collision with a
  different node name.
- Ships its own etcdctl via a new etcd-client stage-package rather than
  depending on the etcd snap being installed on every agent host.
- Does not allocate a range (the admin still picks it) and does not
  lease-bind claims: a node removed without a clean snap remove leaves
  its claim in etcd indefinitely, reserving that range until an
  operator runs cilium-ipam-reserve release or deletes the key by hand.
  Deliberate: failing loudly on a stale claim beats silently expiring
  it.

Verified end to end against a live etcd instance: first claim succeeds,
an overlapping second claim is rejected and never written, a disjoint
second claim succeeds, the same node re-claiming its unchanged range on
restart is idempotent, a malformed CIDR is rejected before any etcd
call, and release-then-reclaim-by-another-node works. Smoke-test
coverage: 40-agent.sh (test_ipam_range_claimed_in_etcd,
test_ipam_collision_rejected, test_ipam_disjoint_claim_accepted).

## 3. What this snap does not replace

Grepping this repo for the other two upstream substitutes
(--static-cnp-path, --lb-state-file) returns zero matches.

### 3a. CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy: not wired up

Upstream's substitute is --static-cnp-path (pkg/policy/directory/cell.go:50),
loading CNP/CCNP policy from local YAML via a directory watcher instead
of the apiserver. This snap doesn't set it, doesn't expose a config key
for it, and doesn't stage a policy directory. Combined with
--enable-k8s=false (no core NetworkPolicy watch either), this snap
currently has no mechanism to load L3/L4/L7 network policy at all.
Every endpoint still gets a real identity via the kvstore path (2a), so
identity-aware policy could be enforced, there is simply no delivery
channel for the rules themselves yet.

### 3b. Service / EndpointSlice (load-balancer state): not wired up

Upstream's substitute is --lb-state-file (pkg/loadbalancer/reflectors/file.go:33),
reading Service/Endpoints from a local file instead of the apiserver.
Also absent here. The smoke suite's service coverage
(20-services.sh) only checks that the snapd services are up, it does
not exercise Cilium's Service/load-balancer functionality: pod-to-pod
and pod-to-host connectivity work (70-connectivity.sh), but there is no
ClusterIP/NodePort-style virtual-IP load balancing in this snap today.

### 3c. Hard blockers: no in-tree substitute exists upstream, for anyone

Of the 25 CRDs, upstream has no non-CRD backend at all, a gap in Cilium
itself, not in this snap's wiring, for: CiliumNode, CiliumEndpoint,
CiliumEndpointSlice, CiliumLocalRedirectPolicy,
CiliumEgressGatewayPolicy, CiliumEnvoyConfig,
CiliumClusterwideEnvoyConfig, CiliumNodeConfig, CiliumCIDRGroup,
CiliumLoadBalancerIPPool, the CiliumBGP* types,
CiliumL2AnnouncementPolicy, CiliumPodIPPool, CiliumGatewayClassConfig,
CiliumDatapathPlugin, CiliumNetworkDriver*, CiliumResourceIPPool.

Most of these don't matter for this snap's standalone mode: BGP, L2
announcements, egress gateway, local redirect, LB/pod IP pools and
Gateway API are operator-driven, multi-node, or Service-shaped features
this single-host snap doesn't attempt. CiliumEndpoint/CiliumEndpointSlice
are the exception with real relevance: they're how multi-node
deployments propagate remote pod IP-to-identity mappings. The kvstore
backend has its own IP-cache distribution, but there is no confirmed 1:1
substitute for cross-node endpoint visibility without CiliumEndpoint
sync. Open question, not confirmed either way by current smoke coverage
(which only exercises two network namespaces on a single host,
70-connectivity.sh:5-7).

## 4. Summary table

| Upstream CRD / mechanism | Normally provided by | Replaced here? | Mechanism | Evidence |
|---|---|---|---|---|
| CiliumIdentity | apiserver + operator CRD | Yes | --kvstore=etcd + --identity-allocation-mode=kvstore | cilium-agent-wrapper:70-74; 40-agent.sh:29-37, 70-connectivity.sh:92-108 |
| CiliumNode (IPAM/node state) | apiserver | Yes, avoided and collision-checked, not substituted | --enable-k8s=false + --ipam=cluster-pool + --ipv4-range, validated via cilium-ipam-reserve (2d) | cilium-agent-wrapper:44-50,70-92; 40-agent.sh:18-27,49-80 |
| CRD-sync startup gate | operator-installed CRDs | Yes, skipped | --enable-k8s=false | 40-agent.sh:10-16 |
| CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy | apiserver | No | upstream has --static-cnp-path, not wired up here | grep: zero hits in repo |
| Service/Endpoints/EndpointSlice (LB state) | apiserver | No | upstream has --lb-state-file, not wired up here | grep: zero hits in repo |
| CiliumEndpoint/CiliumEndpointSlice (cross-node) | apiserver | No, and no upstream substitute exists | n/a | hard blocker |
| BGP / L2 announce / Envoy config / egress gateway / LRP / LB-IP-pools / Gateway API (12 CRDs) | apiserver + operator | No, and no upstream substitute exists | n/a | hard blocker, feature not attempted |

## 5. Open gaps / recommendations

- CiliumNetworkPolicy support is the most actionable remaining gap
  (the CIDR-collision gap is closed, see 2d). Wiring --static-cnp-path
  to a writable directory under $SNAP_COMMON, plus a config key, would
  let operators load network policy without a cluster. Low effort, the
  directory watcher is already in-tree.
- IPAM range collisions are now detected (2d, cilium-ipam-reserve).
  Residual, deliberate limitation: claims are not lease-bound, so a
  node removed without a clean snap remove leaves a stale claim that an
  operator must clear by hand before reusing that range under a
  different node name. A lease/TTL-based auto-reclaim would close this,
  but moves closer to a standing background-renewal subsystem than this
  fix deliberately chose.
- Load-balancer state (--lb-state-file) is lower priority for a
  single-host CNI use case but would be needed before this snap could
  claim any Service/NodePort-style functionality, currently none is
  advertised or tested.
- Cross-node CiliumEndpoint propagation is unverified, not just
  unimplemented. Multi-agent setups rely on kvstore node state (2a) for
  routing but have not been confirmed to replicate the
  identity-visibility guarantees CiliumEndpoint/CiliumEndpointSlice give
  under Kubernetes. Worth an explicit multi-host smoke scenario before
  this snap's documentation promises cross-node policy enforcement.
