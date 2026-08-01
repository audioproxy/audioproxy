## Why

`add-render-endpoint` was heading past the review-size target: request plumbing plus a streaming action plus two test harnesses in one diff. This slice takes the plumbing — the plug chain, routing, source checks, and the complete §5 error mapping — all of it pure `Plug.Test` territory with no subprocess anywhere. The streaming action follows in the slimmed `add-render-endpoint`.

## What Changes

- `ParseOptions` + `ResolveSource` plugs bridging the existing modules into `conn.assigns`, halting with structured errors.
- Route `GET /:sig/*rest` (options/source split); `/health` stays unsigned.
- Source checks in the request path: `Source.authorize/1` (404, no oracle) and `Source.stat/1` (missing → 404, size > `AP_MAX_SRC_BYTES` → 413) — every non-streaming status is producible before any render exists.
- `ErrorJSON`: the single structured-error → {status, body} table for 401/404/413/415/422/429/504. Rows whose producers land later (415/504 with the render action, 429 with the semaphore) ship now, unit-tested, unreachable — the established stub pattern.
- Interim action: a fully valid request answers `501` with a JSON body naming the missing piece, pinned by a test, so the gap is visible until `add-render-endpoint` replaces it.

## Capabilities

### New Capabilities

- `render-http`: created here with the routing, source-check, and error-contract requirements; the streaming requirements arrive with `add-render-endpoint`.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/plugs/{parse_options,resolve_source}.ex`, `lib/audio_proxy/error_json.ex`; router route.
- Depends on: `add-signature-verification`, `add-options-parser`, `add-source-resolver`, `add-local-files-source`.
- Blocks: `add-render-endpoint` (replaces the 501 action), `add-info-endpoint` (reuses the plug chain).
