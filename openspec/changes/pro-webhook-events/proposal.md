# PRO: Webhook Events

## Why

Deployments migrating off Mux rely on its asset-lifecycle webhooks (`video.asset.ready` and friends) to know when media is playable and to drive downstream state — the first concrete case is a Rails app that joins those events back to its records and would consume audioproxy's the same way. The proxy already knows everything the server-side half of that story needs (render started/finished/failed, HIT/MISS, variant written, probe results); it just tells no one. An outbound webhook sender closes that gap and becomes the delivery channel later PRO rungs (upload policies, playback-beacon relay) ride on.

The seam is deliberately app-agnostic: payloads follow the [Standard Webhooks](https://www.standardwebhooks.com) spec (signed envelope, versioned schema, documented retry semantics), and correlation needs no passthrough metadata — the consuming app constructed the URL, so it joins events on source + options (or the cache key) by construction. PRO scope: `pro-` prefixed for later extraction; touches no other change.

## What Changes

- An event sender POSTing JSON to one or more configured receiver URLs: `variant.rendered` (source, options string, cache key, render duration, output bytes, format), `variant.render_failed` (same identity + error class), `variant.served` (proxy-mode deliveries only, sampled), `info.probed`. Fed from the `:telemetry` events observability already emits — no new instrumentation points, only a consumer.
- Standard Webhooks envelope: `webhook-id`, `webhook-timestamp`, `webhook-signature` (HMAC-SHA256, own secret per receiver — never the URL-signing key), versioned `type` strings, payload schema documented as part of the PRO contract.
- Delivery is at-least-once with exponential backoff and a retry cap; a bounded in-memory queue drops oldest under pressure and counts what it dropped (events are telemetry, not ledger entries — a dropped event must never block or slow a render).
- Configuration: receiver URL(s) + per-receiver secret, event-type filter, sample rate for `variant.served`. HTTPS required for non-loopback receivers.
- Statelessness preserved: no outbox table, no delivery history. A crashed proxy loses queued events, stated plainly in the contract; the redelivery story for state that matters is the app re-requesting `/info` or the variant itself.

## Non-goals

- **Playback/view analytics.** Structurally impossible server-side: in redirect mode (the default) the 302 hands serving to S3/CDN and the proxy never sees another byte, and even proxy-mode Range traffic cannot distinguish listening from scrubbing. The client-side half is the documented DIY beacon guide (audioproxy-docs) today and a possible `pro-playback-beacon` relay later — this change's channel is where relayed events would be delivered, which is one more reason it lands first.
- Delivery-usage accounting (Mux's delivered-seconds API). Redirect-mode truth lives in CDN/S3 logs; a log-ingest story is named here so its absence is a decision, not an oversight.
- An events dashboard or query API. The receiving app owns storage and presentation.

## Capabilities

### New Capabilities

- `pro-event-webhooks`: outbound, Standard-Webhooks-signed lifecycle events with bounded at-least-once delivery.

### Modified Capabilities

<!-- none -->

## Impact

- New (PRO tree): sender GenServer + bounded queue, envelope/signing module, config group, receiver docs with a worked Rails consumer example (the existing `Webhooks::BaseController` pattern makes it a drop-in third controller).
- OSS tree untouched: the sender subscribes to existing telemetry; if a needed measurement is missing from an OSS event, adding it is a tiny OSS change proposed separately, not smuggled in.
- Tests: envelope KAT vectors against the Standard Webhooks reference vectors; a fake receiver asserting signature, retry/backoff on 5xx, drop-oldest accounting under a stalled receiver; property test that event emission never blocks the render path (render latency unchanged with a black-holed receiver).
- Estimated ~350 LOC in the PRO tree.
- Position: first of the PRO analytics rungs; prerequisite channel for any future `pro-playback-beacon`.
