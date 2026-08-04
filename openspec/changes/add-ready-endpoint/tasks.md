## 1. Endpoint

- [ ] 1.1 `GET /ready`: threshold + hysteresis over the semaphore depth gauge; `AP_READY_QUEUE_THRESHOLD` config (default + `0` = disabled) with boot validation
- [ ] 1.2 Tests: trip/recover hysteresis (one flip per excursion), 503/200 transitions, `/health` unaffected under load, disabled mode

## 2. Scaling doc

- [ ] 2.1 `docs/scaling.md`: shared-store requirement, bounded double-render honesty, URI-hash LB recipes (nginx, Envoy, ingress annotation), least-connections rationale, K8s probes + HPA wiring, Swarm honesty, Fly.io section (`concurrency` soft/hard ↔ `AP_MAX_CONCURRENCY`, autostart/autostop; state plainly that fly-proxy has no URI-hash mode — the cross-node-coalescing LB recipe does not apply there, per-fleet single-flight is PRO territory — and that a CDN in front collapses same-URL storms at the edge, making the fleet's duplicate-render cost "occasionally k cold renders")
- [ ] 2.2 README: probe wiring note, config row, scaling doc link
