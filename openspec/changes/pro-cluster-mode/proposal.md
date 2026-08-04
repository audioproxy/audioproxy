## Why

Multiple proxies behind a load balancer work today, with two costs: same-variant storms render once per node instead of once per cluster, and a saturated node can only refuse (429) rather than hand work to an idle sibling. Fixing either from the outside demands a smart LB the operator must own. The BEAM makes the inside fix native: nodes that know their peers, agree on who owns a render, and share load hints — using only OTP distribution. PRO scope, `pro-` prefixed; the fifth ladder rung, and the first distributed-systems one, so it stays behind the others.

## What Changes

- **Cluster membership, autoconnecting**: libcluster/dns_cluster with per-platform strategies — Fly.io via the private IPv6 mesh (`<app>.internal` DNS polling; machines join as they autostart), K8s via headless-service DNS, static list for everything else. Shared cookie from a secret.
- **Cluster-wide single-flight**: rendezvous hashing over (cache key, member list) elects a render owner every node computes identically — no coordinator. Non-owners hand MISS renders over: on Fly via the `Fly-Replay` response header (fly-proxy re-routes the request; zero proxied bytes), elsewhere by forwarding to the peer.
- **Load-aware shedding**: nodes gossip queue depth (a few bytes/second over distribution); a node at capacity answers with a redirect toward its least-loaded peer instead of a bare 429 (which remains the everyone-is-full answer).
- **Hints, never truth**: every cluster signal is advisory. Partition, stale membership, or gossip loss degrades each node to exact single-node behavior — worst cases are a duplicate render (already harmless: deterministic bytes, last-write-wins) or a suboptimal redirect. Correctness continues to live in the URL and the store.

## Capabilities

### New Capabilities

- `pro-cluster-mode`: membership, render ownership, load-aware shedding, and the degradation contract.

### Modified Capabilities

<!-- none — consumes existing seams (coalescing registry, semaphore telemetry); no OSS deltas -->

## Impact

- New: cluster supervisor (membership + gossip), ownership module, forward/replay handling in the render path (single call site, same pattern the coordinator swap used).
- Deps (new, PRO-side only): `libcluster` or `dns_cluster` — OSS dependency policy untouched.
- Depends on: merged OSS core; sensible after the other PRO rungs ship. Fly.io is the reference platform (autoscaling + autoconnect are its defaults); K8s the second target.
