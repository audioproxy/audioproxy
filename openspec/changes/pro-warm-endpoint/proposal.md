## Why

Ingest pipelines want variants rendered before anyone asks — "on upload, produce the mp3 and opus previews and the peaks." N parallel GETs already do this correctly (coalescing dedupes, the semaphore paces, 429 backpressures), so this endpoint buys ergonomics and efficiency, honestly scoped: one signed request instead of N held connections, fire-and-forget. It is also the delivery mechanism the later PRO rungs (upload policies, group normalization) build on. PRO scope: `pro-` prefixed for later extraction; touches no other change.

## What Changes

- New signed endpoint `GET /{sig}/warm/enc:{payload}` where the payload is a base64url JSON list of `{options}/{source}` entries, using the shared envelope from `pro-request-payloads` (encoding, canonicalization, bounds, and error mapping are defined there; a warm payload is a *request* payload, never cache-keyed). The outer signature covers the whole path — inner entries need no individual signatures.
- Each valid entry is checked against the variant store (HIT → nothing to do) and otherwise kicked into the coalescing registry; the response returns immediately with per-entry state (`hit` | `started` | `invalid` + reason) — the connection does not wait for renders.
- Statelessness preserved: there is no job store and no status API. "Queued" *is* the coalescing registry; progress *is* GETting the variant URL. A dropped warm render costs nothing — the variant renders lazily on first request, exactly as without this endpoint.
- Bounded: a maximum entry count per request (default 100); invalid entries are reported per-entry, never fatal to the batch.
- Requires a configured variant store (`AP_VARIANT_STORE`) — warming into no cache is meaningless and answers 422.

## Capabilities

### New Capabilities

- `pro-cache-warming`: The warm endpoint — batch payload, fire-and-forget semantics, per-entry reporting, and its limits.

### Modified Capabilities

<!-- none — deliberately; extraction candidate -->

## Impact

- New: warm action + route, consuming the `pro-request-payloads` codec (dependency; that change lands first).
- Depends on (implementation order, no artifact amendments): `add-render-coalescing` (the registry it kicks into), `add-variant-cache` (the HIT check and the point of warming), `add-render-semaphore` (pacing).
- Position: PRO track, after `pro-loudness-measurement` or alongside; unscheduled relative to the OSS board. Future PRO slices (upload policies) trigger this machinery from events.
