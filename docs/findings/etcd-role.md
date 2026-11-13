# What etcd actually does for cilium-agent in this snap

> **Provenance:** this is an agent-generated research summary, written by
> an AI coding assistant tracing through upstream Cilium source and this
> repo's packaging. Treat it as a well-evidenced starting point, not an
> authoritative spec. Check the cited file and line references before
> relying on a claim here.

Findings are from a local Cilium checkout at `~/Work/cilium`, branch `main`
(`1.21.0-dev`, commit `bf3e61f257`), which carries no tags and no release
branches. Every load-bearing claim below was independently re-checked against
the GitHub v1.20.0 tag (the version this snap actually pins,
build-scripts/components/cilium/version) and holds with identical
symbols, constants and lease flags. Line numbers cited are `main` line
numbers unless noted; `pkg/endpoint/policy.go` is the one file whose line
numbers shift between the two (`runIPIdentitySync` is `main:1199` vs
`v1.20.0:1133`; see §10).

## 1. The question: is etcd a CRD replacement?

Short answer: partly. etcd carries exactly three Cilium state families and
nothing else. The complete key namespace is defined in
`pkg/kvstore/kvstore.go:23-51`: `BaseKeyPrefix = "cilium"` (:25),
`StatePrefix = "cilium/state"` (:28), `CachePrefix = "cilium/cache"` (:32,
KVStoreMesh only), `InitLockPath = "cilium/.initlock"` (:35),
`HeartbeatPath = "cilium/.heartbeat"` (:39),
`ClusterConfigPrefix = "cilium/cluster-config"` (:42),
`SyncedPrefix = "cilium/synced"` (:46),
`HeartbeatWriteInterval = time.Minute` (:50).

Under `cilium/state/` only five sub-prefixes exist anywhere in the tree:
`identities/v1` (`pkg/identity/cache/allocator.go:47`), `ip/v1`
(`pkg/ipcache/kvstore.go:38`), `nodes/v1` (`pkg/node/store/store.go:26`),
`services/v1` (`pkg/clustermesh/store/store.go:25`), `endpointslices/v1`
(`pkg/clustermesh/types/endpointslice/endpointslice.go:27`), plus
`serviceexports/v1`
(`pkg/clustermesh/mcsapi/types/mcsapiservicespec.go:31`). There is no policy
prefix and no local-endpoint prefix.

Of those, a standalone agent uses three (`identities/v1`, `nodes/v1`,
`ip/v1`); the service/endpointslice/serviceexport prefixes are written only
by `clustermesh-apiserver`
(`clustermesh-apiserver/clustermesh/service_sync.go`,
`endpointslice_export_sync.go`) and read only by the ClusterMesh subsystem,
which never instantiates here because `NewClusterMesh` returns `nil` when
`ClusterInfo.ID == 0` or `ClusterMeshConfig == ""`
(`pkg/clustermesh/clustermesh.go:132-135`).

For identities / nodes / IP→identity, etcd *is* the substitute data plane
for what CRDs do under Kubernetes, including read-back; for policy / local
endpoints / services it is not a substitute at all, and that state must come
from the third channel (local files + the agent API, §7).

## 2. How the agent connects, and what happens when etcd is absent or late

- Flags this snap passes: `snap/local/bin/cilium-agent-wrapper:70-73`
  (`--enable-k8s=false`, `--kvstore=etcd`,
  `--kvstore-opt etcd.address=…`, `--identity-allocation-mode=kvstore`).
- Cell wiring: the agent registers
  `kvstore.Cell(kvstore.DisabledBackendName, kvstore.OptAsyncWaitForEstablished)`
  (`daemon/cmd/cells.go:154-156`); with `--kvstore=""` the cell
  short-circuits to a disabled client (`pkg/kvstore/cell.go:52-54`,
  `clientImpl{enabled: false}`), which is what makes every kvstore-gated
  subsystem below silently inert.
- Startup is **not** blocking-fatal at first: `OptAsyncWaitForEstablished`
  gives a 5 s circuit breaker (`pkg/kvstore/client.go:47-97`); success logs
  `"Connection to kvstore successfully established"`, timeout logs `"Failed
  to establish connection to kvstore within timeout, continuing in
  background"` and moves the wait into a one-shot job. If the background
  connection never succeeds within
  `initialConnectionTimeout = 15 * time.Minute` (`pkg/kvstore/etcd.go:92`),
  that job returns with `job.WithShutdown()` and the agent process exits.
- A second, harder deadline exists on the node-registration path:
  `StartDiscovery` retries `RegisterNode` forever in a goroutine and a
  watchdog calls `logging.Fatal(n.logger, "Unable to initialize local node
  due to timeout")` after `defaults.NodeInitTimeout = 15 * time.Minute`
  (`pkg/nodediscovery/nodediscovery.go:123-140`,
  `pkg/defaults/defaults.go:238`). Practical consequence for the snap: a
  `cilium-agent` started against a dead etcd does not fail fast. It runs
  degraded for up to 15 minutes and then dies, which is why
  `cilium-agent-wrapper:36-43` polls the etcd port for `ETCD_WAIT_SECONDS`
  (default 60, `snap/local/etc/defaults.env:3-4`) before exec'ing the agent.
- Quorum is proven by lock, not by heartbeat:
  `isConnectedAndHasQuorum` → `maybeWaitForInitLock` takes and immediately
  releases `cilium/.initlock/<random-hex>`
  (`pkg/kvstore/etcd.go:380-406`, debug log `"Distributed lock successful,
  etcd has quorum"`); on repeated failure the status goes `Failure` with
  `"quorum check failed %d times in a row: %w"` after
  `defaults.KVstoreMaxConsecutiveQuorumErrors = 2`
  (`pkg/defaults/defaults.go:323`).
- The `cilium-dbg status` kvstore row comes from the `"kvstore"` probe in
  `pkg/status/status_collector.go:647-660` (returns `StatusStateDisabled`
  when the client is disabled, else `KVStoreClient.Status()`), rendered by
  `pkg/client/client.go:326-328`. The string the smoke suite asserts
  (`tests/smoke/cases/30-etcd.sh:72-80`, `has-quorum=true`, `1/1 connected`)
  is built in `pkg/kvstore/etcd.go:1020-1050`.

## 3. cilium/.heartbeat: written elsewhere, harmless for this snap

The most counter-intuitive finding:

- The heartbeat key is written only by `heartbeat.Cell`
  (`pkg/kvstore/heartbeat/cell.go:39`,
  `client.Update(tctx, kvstore.HeartbeatPath, []byte(time.Now().Format(time.RFC3339)), true)`,
  every `HeartbeatWriteInterval = 1m`), and that cell is instantiated only
  by `cilium-operator` (`operator/cmd/root.go:215`), `clustermesh-apiserver`
  (`clustermesh-apiserver/clustermesh/cells.go:58`) and `kvstoremesh`
  (`clustermesh-apiserver/kvstoremesh/cells.go:38`). **`cilium-agent` never
  writes it**, so in this snap the key never exists.
- Every etcd client watches it (`pkg/kvstore/etcd.go:575`
  `e.ListAndWatch(ctx, HeartbeatPath)`), and `statusChecker` seeds
  `lastHeartbeat = time.Now()` when zero (`pkg/kvstore/etcd.go:983-992`).
- The staleness check is explicitly scoped away from the main connection:
  `if e.extraOptions.NoEndpointStatusChecks && e.extraOptions.NoLockQuorumCheck { … quorumError = fmt.Errorf("%s since last heartbeat update has been received", heartbeatDelta) }`
  (`pkg/kvstore/etcd.go:1004-1016`), with the upstream comment: "This check
  is only performed for Clustermesh clients, but not for the main KVStore
  connections… it is not actually required to have operational operator to
  function properly." Both flags are false for the agent's own kvstore
  client (they are set only for remote ClusterMesh clients), so the missing
  heartbeat is never evaluated.
- Conclusion: no degradation, no warning, no status change from the absent
  operator heartbeat. Confirmed live by the smoke assertion that
  `.kvstore.state == "Ok"` with `has-quorum=true`
  (`tests/smoke/cases/30-etcd.sh:72-80`).

## 4. cilium/state/identities/v1: the one subsystem that genuinely needs etcd

- Layout: base `IdentitiesPath = cilium/state/identities/v1`
  (`pkg/identity/cache/allocator.go:47`), split by the kvstore allocator
  backend into `idPrefix = …/id`, `valuePrefix = …/value`,
  `lockPrefix = …/locks` (`pkg/kvstore/allocator/allocator.go:96-102`).
  - **Master key** `cilium/state/identities/v1/id/<numeric-id>` → sorted
    label string (`labels.SortedList()`), created with
    `CreateOnly…(…, lease=false)`
    (`pkg/kvstore/allocator/allocator.go:125,133-141`). Never
    lease-bound, never expires.
  - **Slave key** `cilium/state/identities/v1/value/<labels>/<suffix>` →
    decimal ID, written with `UpdateIfDifferent…(…, lease=true)`
    (`pkg/kvstore/allocator/allocator.go:153-161`); `suffix` is this agent's
    node IP (`pkg/identity/cache/cell/cell.go:171-188`). Lease TTL
    `--kvstore-lease-ttl`, default `defaults.KVstoreLeaseTTL = 15m`
    (`pkg/defaults/defaults.go:319`), refreshed by `syncLocalKeys` every
    `--identity-allocation-sync-interval` (default 5m,
    `pkg/identity/cache/cell/cell.go:104`).
  - Allocation is a locked CAS loop: `backend.Lock` on
    `cilium/state/identities/v1/locks/value/<labels>`
    (`pkg/kvstore/allocator/allocator.go:168-170`, etcd concurrency mutex at
    `pkg/kvstore/etcd.go:619-633`, lock lease TTL
    `defaults.LockLeaseTTL = 25s`, `pkg/defaults/defaults.go:326`) →
    `GetIfLocked` → pick free ID from the in-memory `idpool` →
    `GetNoCache` double-check → `CreateOnlyIfLocked` master key (etcd txn
    `If(Version(key)==0)`, `pkg/kvstore/etcd.go:1398-1456`) → write slave
    key; retry with backoff up to `defaultMaxAllocAttempts`
    (`pkg/allocator/allocator.go:530-671,704-740`).
  - ID space for `--cluster-id=0`: `[256, 65535]`
    (`pkg/identity/cache/allocator.go:224-232`,
    `pkg/clustermesh/types/types.go:73-92`).
- **Read-back is real, and it is what makes identities stable across
  restarts.** The backend does `ListPrefix` + watch on `…/id`
  (`pkg/kvstore/allocator/allocator.go:625-667`) feeding
  `identityWatcher.watch()` → `UpdateIdentities` into the SelectorCache
  (`pkg/identity/cache/cache.go:181-228`). On agent restart, endpoints are
  restored from `--state-dir` and re-allocate by label set
  (`pkg/endpoint/restore.go:210-217`), and because the master key survived,
  the endpoint gets the **same numeric identity** back rather than a fresh
  one, no BPF policy-map renumbering. Local disk checkpointing
  (`local_allocator_state.json`, `pkg/identity/cache/allocator.go:50-53`)
  covers only *local-scope* identities, not global ones.
- **What never touches etcd:** reserved identities 1–10 and well-known IDs
  ≥100 (`pkg/identity/numericidentity.go:32-150`, e.g. `host=1`, `world=2`,
  `health=4`, `remote-node=6`), and all local-scope identities: CIDR, FQDN,
  CIDR-group, ingress (`pkg/identity/identity.go:151-177`,
  `pkg/identity/cache/local.go`). Gate: `needsGlobalIdentity`
  (`pkg/identity/cache/allocator.go:533-538`). So CIDR- and FQDN-based policy
  would work with etcd down; workload-label policy would not.
- **GC is operator-only, and this snap has no operator.** `RunGC` lives in
  the kvstore backend (`pkg/kvstore/allocator/allocator.go:424-582`,
  two-round stale marking) but is invoked only from
  `operator/identitygc/kvstore_gc.go:18-87`;
  `pkg/allocator/allocator.go:282-283,288-289` says verbatim that `RunGC`
  and `RunLocksGC` are "used by the cilium-operator and is not invoked by
  cilium-agent". Consequence for snap users: slave keys expire with their
  15-minute lease when an agent dies, but **master keys under `…/id/` are
  never deleted**. With stable workload label sets this is bounded (the
  same IDs get reused); with high-cardinality/churning labels the
  `[256, 65535]` space leaks until allocation fails with "no more available
  IDs in configured space" (`pkg/allocator/allocator.go:590`). Manual
  remedy: delete unused `cilium/state/identities/v1/id/<n>` keys with
  `etcdctl`.
- **Mid-run etcd loss:** running endpoints keep their in-memory identities
  and traffic continues; any new endpoint or label change blocks on
  `AllocateIdentity` for `--identity-allocation-timeout` (default `2m`,
  `pkg/identity/cache/cell/cell.go:103`) and then fails regeneration with
  `"unable to resolve identity: …"` logged as a warning plus controller
  retry (`pkg/endpoint/endpoint.go:2462-2465`).

## 5. cilium/state/nodes/v1: node registry, read as well as written

- Key `cilium/state/nodes/v1/<cluster-name>/<node-name>`
  (`pkg/node/store/store.go:26`, `pkg/node/types/node.go:460-471`), value =
  JSON `nodeTypes.Node` (`pkg/node/types/node.go:35-98`): name, cluster,
  clusterID, `IPAddresses`, `IPv4AllocCIDR`/`IPv6AllocCIDR`, health/ingress
  IPs, `EncryptionKey`, `WireguardPubKey`, `BootID`, labels, annotations.
  PodCIDRs are preserved only for `kubernetes`/`cluster-pool`/`multi-pool`
  IPAM and stripped otherwise (`pkg/node/store/store.go:190-206`). This
  snap runs cluster-pool, so the CIDR is published.
- Write gate is the **kvstore**, not Kubernetes: `RegisterNode` returns
  early only on `!client.IsEnabled()` (`pkg/node/store/store.go:152-155`);
  the k8s-only branch is `updateLocalNode`'s
  `if n.clientset.IsEnabled() { n.updateCiliumNodeResource(...) }`
  (`pkg/nodediscovery/nodediscovery.go:198-203`), which is skipped under
  `--enable-k8s=false`. Ongoing updates are driven by the `"propagating
  local node change to kv-store"` controller
  (`pkg/nodediscovery/nodediscovery.go:171-197`). The key is lease-bound
  (`UpdateLocalKeySync` → `syncLocalKey(…, lease=true)`,
  `pkg/kvstore/store/store.go:301-315,350-355`), resynced every 30 min
  (`pkg/node/store/store.go:163`), so a dead node's record expires after
  the 15-minute lease TTL.
- Read side is active for a plain standalone agent: `JoinSharedStore` with
  `Observer: NewNodeObserver(manager, source.KVStore)`
  (`pkg/node/store/store.go:158-166`) starts a `ListAndWatch` on the prefix
  (`pkg/kvstore/store/store.go:428-444`); `OnUpdate` ignores the local key
  and feeds every *remote* node into `NodeManager.NodeUpdated`
  (`pkg/node/store/store.go:113-119`). Deletions are delayed by
  `defaults.NodeDeleteDelay = 30s` (`pkg/defaults/defaults.go:316`).
- Datapath effect of a discovered remote node: ipcache metadata for the
  node IPs and for its PodCIDRs with the node IP as tunnel endpoint
  (`pkg/node/manager/manager.go:531-564`), health/ingress IPs (`:566-611`),
  then handler fan-out (`:634`) reaching `linuxNodeHandler` which installs
  direct routes to the remote PodCIDR when `EnableAutoDirectRouting` is on
  and encapsulation is off (`pkg/datapath/linux/node.go:831-838` →
  `installDirectRoute` `:542-570`). This is exactly what
  `enable-auto-direct-node-routes`
  (`snap/local/etc/defaults.env:35-38`, `README.md:62,64-88`) depends on,
  and why overlapping `ipv4-range` values are dangerous enough to warrant
  `snap/local/bin/cilium-ipam-reserve`.
- **Trap worth documenting:** `NewNodeDiscovery` returns an empty, inert
  `&NodeDiscovery{}` when `option.Config.EnableCiliumNodeCRD` is false
  (`pkg/nodediscovery/nodediscovery.go:78-82`, log `"CiliumNode CRD is
  disabled; skipping CiliumNode resource management"`). That single flag
  kills kvstore node registration as well, despite the CRD-sounding name. It
  defaults true (`pkg/defaults/defaults.go:538-539`) and
  `PopulateEnableCiliumNodeCRD` force-flips it back to true unless IPAM is
  `delegated-plugin` *and* identity allocation is `crd`
  (`pkg/option/config.go:2865-2885`), so this snap's configuration can never
  reach the inert path, but anyone adding `--enable-ciliumnode-crd=false`
  via `EXTRA_ARGS` would silently lose node state in etcd.
- Note what etcd does *not* do here: it publishes a node's already-chosen
  PodCIDR; nothing in `pkg/ipam/` arbitrates or allocates CIDRs in kvstore
  mode (that is `cilium-operator`'s clusterpool allocator), which is the gap
  `cilium-ipam-reserve` closes (cross-reference
  crd-replacement.md §2d rather than repeating it).

## 6. cilium/state/ip/v1: pod IP→identity, the actual CiliumEndpoint substitute

- Key `cilium/state/ip/v1/default/<ip>` (`pkg/ipcache/kvstore.go:38,42,95`),
  value = JSON `identity.IPIdentityPair` (IP, numeric ID, HostIP, encryption
  key, k8s namespace/pod/UID (empty without Kubernetes), and named ports).
- Write: per-endpoint controller `runIPIdentitySync`
  (`pkg/endpoint/policy.go:1199-1285` on `main`; `:1133` at v1.20.0), gated
  purely on `e.kvstoreSyncher.IsEnabled()` → `client.IsEnabled()`
  (`pkg/ipcache/kvstore.go:139-141`), writing with
  `UpdateIfDifferent(…, lease=true)` (`pkg/ipcache/kvstore.go:122`).
  Lease-bound, so a dead node's pod IPs drain out of etcd automatically.
- Read: `LocalIPIdentityWatcher`, provided in the agent's always-on ipcache
  cell (`pkg/ipcache/cell/cell.go:40`), starts
  `job.OneShot("watch", watcher.Watch)` whenever `client.IsEnabled()`, no
  ClusterMesh and no Kubernetes involved
  (`pkg/ipcache/kvstore.go:152-190`), logging `"Starting IP identity
  watcher"`. It watches `cilium/state/ip/v1/default`
  (`pkg/ipcache/kvstore.go:335`) and upserts each pair into the ipcache with
  `Source: source.KVStore` (`:446-449`), rewriting a peer's `host` identity
  to `remote-node` (`:424-431`).
- Self-entries: the watcher sees its own keys too, but `source.KVStore`
  ranks below `source.Local` in the ownership order
  (`pkg/source/source.go:26-33,73-80`), so locally-owned entries win; and
  `WithSelfDeletionProtection` re-creates an own key if it is observed
  deleted while still alive, logging `"Received kvstore delete notification
  for alive ipcache entry"` (`pkg/ipcache/kvstore.go:276-280,464-466,483-502`).

This confirms the function that `CiliumEndpoint`/`CiliumEndpointSlice`
serve under Kubernetes: for two agents sharing one etcd, node A learns node
B's **pod IP → security identity** mappings through this prefix.
Cross-node identity-aware policy is therefore fed, in principle; what is
still missing is a policy delivery channel (§7) and any multi-host smoke
coverage (`tests/smoke/cases/70-connectivity.sh:5-7` is single-host, two
netns).

## 7. What etcd does **not** carry, and where that state has to come from instead

- **Policy**: no kvstore path exists anywhere in Cilium. Ingestion is only:
  k8s CNP/CCNP watcher (`pkg/policy/k8s/cilium_network_policy.go:147-151`,
  `source.CustomResource`), k8s `NetworkPolicy` watcher
  (`pkg/policy/k8s/network_policy.go:40-44`, `source.Kubernetes`), and the
  local directory watcher `--static-cnp-path`
  (`pkg/policy/directory/cell.go:24-80`, `providePolicyWatcher` no-ops when
  the path is empty; `source.Directory`). The policy-source metric
  enumerates exactly those three and not `source.KVStore`
  (`pkg/metrics/metrics.go:804-806`). There is **no** `PUT /policy` API and
  no `cilium-dbg policy import` in current Cilium.
  `api/v1/server/restapi/policy/` contains only `get_*` handlers and
  `cilium-dbg/cmd/` has only `policy_get.go` / `policy_selectors.go` /
  `policy_wait.go`. So with `--enable-k8s=false` and `--static-cnp-path`
  unset, this snap has no way to load network policy at all, consistent
  with crd-replacement.md §3a.
- **Local endpoints**: never in etcd. Persistence is the local
  `--state-dir` (`snap/local/bin/cilium-agent-wrapper:13` →
  `$SNAP_COMMON/cilium/state`): endpoints are serialized per-ID and
  restored by `ReadEPsFromDirNames`/`ParseEndpoint`/`RegenerateAfterRestore`
  (`pkg/endpoint/restore.go:47-58,156-174`). Creation is the agent REST API
  `PUT /endpoint/{id}` used by the CNI plugin
  (`pkg/endpoint/api/endpoint_api_handler.go:195-224`,
  `plugins/cilium-cni/cmd/cmd.go:893`).
- **Services / load balancing**: `cilium/state/services/v1` is
  ClusterMesh-only (written by `clustermesh-apiserver`, read by
  `pkg/clustermesh/remote_cluster.go:134,149`), and ClusterMesh is not
  instantiated here (`pkg/clustermesh/clustermesh.go:132-135`). The non-k8s
  substitute is `--lb-state-file` + `--lb-state-file-interval`
  (`pkg/loadbalancer/reflectors/file.go:32-72`,
  `StateFile{Services, Endpoints}`), unused by this snap.
- **Cluster config**: `cilium/cluster-config/<cluster>` holds
  `cmtypes.CiliumClusterConfig{ID, Capabilities}`
  (`pkg/clustermesh/types/types.go:140-164`) and is written by the
  operator/clustermesh-apiserver cell `clustercfgcell.Cell`
  (`pkg/clustermesh/clustercfg/enforce.go:21-45`, instantiated at
  `operator/cmd/root.go:59`, `clustermesh-apiserver/clustermesh/cells.go:15`),
  which `daemon/cmd/cells.go` never imports. A standalone agent neither
  writes nor requires it; its absence causes no warning and no startup
  block. Worth stating explicitly, because `cluster-name`/`cluster-id` are
  user-facing `snap set` keys (`README.md:60`) and a reader may expect a
  cluster-config key to appear in etcd.

Summary: three state-input channels feed cilium-agent here: Kubernetes/
CRDs (off), kvstore/etcd (identities, nodes, IP→identity), local files +
agent API (`--state-dir`, CNI via REST, `--static-cnp-path`,
`--lb-state-file`).

## 8. Key-by-key reference table

| etcd key | written by | read by | lease-bound? | active in this snap? | evidence |
|---|---|---|---|---|---|
| `cilium/.initlock/<rand>` | any agent (quorum probe) | not read back (take+release only) | lock lease 25s | yes | `pkg/kvstore/etcd.go:380-406` |
| `cilium/.heartbeat` | operator / clustermesh-apiserver / kvstoremesh only | watched by all, evaluated only for ClusterMesh clients | yes (impl.) | no (never written here; watched but unused) | `pkg/kvstore/heartbeat/cell.go:39`, `pkg/kvstore/etcd.go:1004-1016` |
| `cilium/cluster-config/<cluster>` | operator / clustermesh-apiserver | ClusterMesh remote-cluster code | no | no | `pkg/clustermesh/clustercfg/enforce.go:21-45` |
| `cilium/state/identities/v1/id/<id>` | any agent (allocator) | all agents (list+watch) | **no lease** | yes | `pkg/kvstore/allocator/allocator.go:125,625-667` |
| `cilium/state/identities/v1/value/<labels>/<node-ip>` | owning agent | allocator GC (operator only) | 15m | yes | `pkg/kvstore/allocator/allocator.go:153-161` |
| `cilium/state/identities/v1/locks/...` | agent (CAS) | none | lock lease 25s | yes | `pkg/kvstore/allocator/allocator.go:168-170` |
| `cilium/state/nodes/v1/<cluster>/<node>` | owning agent | all other agents | 15m | yes | `pkg/node/store/store.go:152-166` |
| `cilium/state/ip/v1/default/<ip>` | owning agent (per endpoint) | all agents | 15m | yes | `pkg/ipcache/kvstore.go:95-141,152-190` |
| `cilium/state/services/v1`, `.../endpointslices/v1`, `.../serviceexports/v1` | clustermesh-apiserver | ClusterMesh clients | yes (impl.) | no | `pkg/clustermesh/store/store.go:25` |
| `cilium/cache/...`, `cilium/synced/...` | KVStoreMesh | KVStoreMesh clients | n/a | no | `pkg/kvstore/kvstore.go:32,46` |
| `cilium-snap/ipam/claims/<node-name>` | `snap/local/bin/cilium-ipam-reserve` (outside Cilium's `cilium/` namespace) | same script, at agent startup | no lease, by design | yes | cross-ref crd-replacement.md §2d |

## 9. What this means for `cilium-snap`

1. etcd is a hard dependency even single-node: without it
   `--identity-allocation-mode` is rewritten to `crd`
   (`pkg/option/config.go:2784-2793`, warning `"Running Cilium with %q=%q
   requires identity allocation via CRDs. Changing %s to %q"`), which then
   needs an apiserver this snap does not have.
2. Single-node value of etcd is identity allocation + identity stability
   across restarts (§4 read-back), not merely bookkeeping.
3. Multi-node value is the node registry and the IP→identity bus (§5, §6);
   both work with `--enable-k8s=false` and without ClusterMesh.
4. Operator-shaped gaps this snap inherits: no identity GC (master-key
   leak, §4), no PodCIDR arbitration (mitigated by `cilium-ipam-reserve`),
   no heartbeat (harmless, §3).
5. Still no policy channel (§7), unchanged from crd-replacement.md
   §3a. Wiring --static-cnp-path remains the highest-value next step.
6. etcd content is sensitive and unauthenticated in this setup: identities,
   node IPs/CIDRs and every pod IP→identity mapping are readable by
   anything that can reach the client port, reinforcing the
   `etcd-bind-address` warning in `snap/local/bin/setup-etcd:40-52` and
   `README.md:58`.
7. Suggested verification gap: a multi-host smoke scenario asserting node
   B's pod IP appears in node A's `cilium-dbg bpf ipcache list` would prove
   §6 end-to-end; current coverage is single-host.

## 10. v1.20.0 verification note

All claims above were re-checked against the GitHub `v1.20.0` tag (the
version this snap's build pins) and hold with identical symbols, constants
and lease flags. The only delta found is line numbers in
`pkg/endpoint/policy.go`: `runIPIdentitySync` is at `v1.20.0:1133-1134`
(call sites `:1256,:1259`) versus `main:1199-1200` (call sites
`:1332,:1335`). The local `~/Work/cilium` clone carries no tags, so
reproducing this check requires fetching the tag or reading
`https://raw.githubusercontent.com/cilium/cilium/v1.20.0/<path>` directly.
