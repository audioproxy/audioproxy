## Context

Integration slice: no new domain logic, but the wiring decisions (plug order, streaming loop, disconnect detection) carry the §5 contract. Bandit + `Plug.Conn.chunk/2`.

## Goals / Non-Goals

**Goals:**
- Full MISS-path request lifecycle over a real socket, with every error mapped.

**Non-Goals:**
- HIT/write-back (variant-cache slice adds a lookup step here); peaks/info routes.
- Coalescing and concurrency limiting — post-MVP slices that plug into this endpoint's spawn point; the MVP renders once per request, uncapped.

## Decisions

- **Plug order**: VerifySignature → ParseOptions → ResolveSource → (endpoint action: source stat/size check → ffmpeg input from the source's type → spawn render → stream). Cheapest checks first; everything user-derived validated before any storage/filesystem call.
- **Size/existence via `Source.stat/1`** (delegating to the source's `Source.Type` backend) before handing ffmpeg its input — buys 404/413 before a subprocess ever starts. Local sources: `File.stat` (MVP). S3 sources (post-MVP): HEAD behind the same seam. HTTPS sources: HEAD with fallback to accepting unknown size (enforced post-hoc by render byte cap) — owned by `add-remote-files-source`, which implements that backend rather than leaving it to this slice.
- **The endpoint consumes the pipeline directly** for the MVP: spawn `Ffmpeg.Render` with itself as consumer. The spawn is kept in one function so `add-render-coalescing` replaces exactly that call with `RenderCoordinator.subscribe/2` — the coordinator broadcasts the same message contract the pipeline emits, which is why the streaming loop needs no change.
- **Streaming loop** in the endpoint process: receive pipeline (later coordinator) messages, `chunk(conn, data)`; `{:error, closed}` from `chunk/2` = disconnect → cancel the render + exit (pipeline's consumer-down kill is the backstop). A `receive`-loop plug action (no GenServer) keeps conn ownership simple.
- **Timeout of first chunk** bounded by the render timeout (plus the semaphore queue wait, once that lands post-MVP) — the loop itself uses `AP_RENDER_TIMEOUT` as its receive deadline and maps expiry to 504 (pre-first-byte) or abnormal termination (mid-stream).
- **Errors as `ErrorJSON.render(conn, status, reason)`** — single mapping table from structured errors (option/source/render classes) to §5 codes; tested exhaustively at the unit level, spot-checked end-to-end.
- **Test harness**: full-stack tests boot the app on an ephemeral port with a local fixture directory as `AP_LOCAL_ROOT` + real ffmpeg — no network stub needed for the MVP path; raw-socket client (`:gen_tcp`) for disconnect and chunk-timing assertions where `Req`-style clients are too high-level. (Test-only HTTP client dep stays out; `:httpc` + `:gen_tcp` suffice. S3-source coverage joins via the fake-S3 stub when `add-s3-client` lands.)

## Risks / Trade-offs

- [Disconnect detection only fires on next chunk write] → acceptable: renders produce chunks continuously; idle-client teardown is bounded by chunk cadence.
- [HEAD-based 413 misses chunked-encoding HTTP sources] → post-hoc render byte cap as backstop (documented).
- [No coalescing until post-MVP: same-variant bursts render N times] → correct output, wasted CPU; bounded by the MVP's demo/integration-only exposure, same declaration as the missing concurrency cap.
