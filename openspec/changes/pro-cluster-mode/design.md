## Context

Fifth PRO rung; the first distributed one. The discipline that keeps it shippable: distribution carries *hints* — who probably owns a render, who is probably busy — while correctness stays where the OSS design put it (deterministic argv, immutable URLs, last-write-wins store).

## Goals / Non-Goals

**Goals:**
- Once-per-cluster renders and redirect-not-refuse shedding, with zero operator-owned LB intelligence and zero coordination services.

**Non-Goals:**
- Distributed state of any kind (no global registry, no consensus, no shared counters); cross-node backlog streaming (the owner serves its own subscribers; others' clients arrive via replay/forward, not via chunk relay); multi-region ownership (region-local clusters first — cross-region hits the store anyway).

## Decisions

- **Rendezvous over consistent-hash rings**: no token management, minimal reshuffle on membership change, and every node computes ownership from (key, members) with no shared structure — the no-coordinator property is the feature.
- **Fly fast path: `Fly-Replay`** — the non-owner answers with a replay header and fly-proxy re-runs the request against the owner machine; no proxied media bytes, no inter-node HTTP. Generic path: forward the request to the owner and stream its response through. One call site, feature-flagged per platform.
- **Fly autostop interplay**: stopped machines leave the mesh (DNS poll catches it) and ownership recomputes; a machine autostarting on fly-proxy's signal joins and takes its share. No special handling — membership churn IS the normal case.
- **Gossip = periodic depth broadcast** over distribution (`send` to peers, a few bytes/second); no vector clocks, no CRDTs — stale data is acceptable by the advisory contract.
- **Distribution security**: cookie from a secret, distribution bound to the private network (Fly 6PN / K8s pod network), TLS distribution as a knob for shared networks. Documented, not defaulted.
- **`libcluster` (or `dns_cluster`) is a PRO dependency** — the OSS dependency policy is untouched; the PRO wrapper has its own mix.exs.

## Risks / Trade-offs

- [Replay/forward adds a hop to cold renders] → one intra-network hop against a multi-second render; HITs never hop (any node serves the store).
- [Gossip staleness misroutes shedding] → advisory: worst case a redirect to a busy peer, which then sheds or 429s — never worse than no cluster.
- [Erlang distribution is a mesh; very large clusters strain it] → render fleets are tens of nodes, not thousands; documented ceiling, revisit with partial mesh if ever real.
