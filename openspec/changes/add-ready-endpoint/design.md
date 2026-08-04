## Context

Readiness is routing advice, not health. The endpoint must be cheap (it will be polled every few seconds per node) and must fail toward accepting work — a wrongly-unready fleet is an outage, a wrongly-ready node just queues.

## Goals / Non-Goals

**Goals:**
- A signal orchestrators can act on before requests eat a 429; the scaling story in one document.

**Non-Goals:**
- Cross-node awareness (PRO cluster mode); autoscaling logic (HPA/fly-proxy own it); changing 429 semantics.

## Decisions

- **Threshold + hysteresis over instantaneous depth**: trip at `AP_READY_QUEUE_THRESHOLD`, recover at half of it — one state flip per excursion. The failure mode this buys off: synchronized readiness oscillation across a loaded fleet.
- **Reads the semaphore's existing telemetry state** (depth gauge), no new bookkeeping; the endpoint is a cheap ETS/counter read.
- **Fly guidance prefers `[http_service] concurrency` over `/ready`**: fly-proxy's soft/hard limits are load-aware routing *plus* autoscaling in one mechanism; `/ready` exists for K8s and generic LBs. The doc says which knob on which platform — one platform, one mechanism.
- **`docs/scaling.md` owns the honesty**: double-renders across nodes are bounded and harmless (deterministic bytes); URI-hash LB upgrades node-local coalescing to cluster-wide; per-node capacity math links the capacity doc.

## Risks / Trade-offs

- [All nodes unready under cluster-wide overload] → threshold defaults well below queue-full, hysteresis dampens, and the doc states the failure mode plus the HPA/autoscaler pairing that actually resolves it (shed → scale, not shed → eject).
