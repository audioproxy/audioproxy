## Why

Multi-node deployments exist now (shared `s3://` store makes them coherent) and the proxy gives orchestrators nothing to route on except in-band 429s. Two gaps, both OSS-sized: a readiness signal distinct from liveness, and the scaling story written down — including the parts that already work (LB URI-hashing for cross-node coalescing, Fly.io concurrency limits doing load-aware routing natively).

## What Changes

- `GET /ready` (unsigned, like `/health`): 200 when the node can accept renders, 503 when queue depth crosses a threshold (`AP_READY_QUEUE_THRESHOLD`, default well below queue-full) — with flap damping (hysteresis: recover at a lower depth than trip) so cluster-wide load cannot eject every node simultaneously.
- `/health` stays pure liveness; the distinction documented (K8s: liveness vs readiness probes point at different endpoints).
- `docs/scaling.md`: the multi-node story — shared store requirement, bounded double-render honesty, LB recipes (URI consistent-hashing for cluster-wide coalescing: nginx/Envoy/ingress annotations; least-connections rationale), K8s readiness + HPA-on-queue-depth wiring (via the metrics slice), Docker Swarm honesty (L4 mesh, put nginx in front), and **Fly.io as the first-class path**: `[http_service] concurrency` soft/hard limits mapped to `AP_MAX_CONCURRENCY` (+ queue headroom) so fly-proxy load-balances and autostarts/autostops machines with zero proxy-side code.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `app-runtime`: gains the readiness endpoint and its threshold semantics.

## Impact

- New: `/ready` route + threshold config; `docs/scaling.md`.
- Modified: README (probe wiring, scaling doc link), config table.
- Depends on: merged code only. Pairs naturally with `add-metrics-endpoint` (HPA needs the gauges) but neither blocks the other.
