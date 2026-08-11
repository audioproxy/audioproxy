# Tasks

## 1. Envelope

- [ ] 1.1 Standard Webhooks envelope module: id, timestamp, HMAC-SHA256 signature under a per-receiver secret; KAT vectors from the Standard Webhooks reference
- [ ] 1.2 Event schema v1: `variant.rendered`, `variant.render_failed`, `variant.served`, `info.probed` payloads carrying source + options string + cache key; documented as part of the PRO contract

## 2. Sender

- [ ] 2.1 Telemetry consumer mapping existing `:telemetry` events to event payloads (no new instrumentation in the OSS tree; missing measurements become a separate OSS change)
- [ ] 2.2 Sender GenServer: bounded queue, drop-oldest with a drop counter, at-least-once POST with exponential backoff and retry cap, per-receiver event-type filter, `variant.served` sampling
- [ ] 2.3 Config group: receiver URL(s) + secrets (HTTPS required off-loopback), filters, sample rate, queue bound

## 3. Tests

- [ ] 3.1 Envelope KAT vectors; tampered payload and wrong-secret verification failures
- [ ] 3.2 Fake receiver: signature asserted, 5xx → backoff → success arrives once; stalled receiver → drops counted, render latency unchanged (property: emission never blocks the render path)
- [ ] 3.3 Filter and sampling behavior per receiver

## 4. Docs

- [ ] 4.1 PRO receiver guide with a worked Rails consumer (Standard Webhooks verification in a controller, correlation via source + options)
- [ ] 4.2 Contract doc: event schema v1, delivery semantics, the loss-on-restart statement
