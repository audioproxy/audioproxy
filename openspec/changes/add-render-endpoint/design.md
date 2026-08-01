## Context

Fills the 501 seam `add-request-plugs` left: the action between "every check passed" and "bytes on the socket". Bandit + `Plug.Conn.chunk/2`; the pipeline's consumer contract does the rest.

## Goals / Non-Goals

**Goals:**
- The MISS-path streaming lifecycle over a real socket, with disconnect and failure semantics per §5.

**Non-Goals:**
- HIT/write-back (variant-cache); coalescing and concurrency limiting (their own post-MVP slices — the spawn stays a single call site for the coordinator swap); peaks/info routes.

## Decisions

- **TOCTOU posture (task 1.1a, decided in-slice)**: `Source.ffmpeg_input/1` returns a path whose file can be swapped after stat; either pin the inode (open here, hand ffmpeg `/dev/fd/N` — which also reframes the protocol-whitelist story) or accept the exposure under the documented read-only-root deployment assumption. Recorded here once decided; not inherited silently.
- **The endpoint consumes the pipeline directly**: spawn `Ffmpeg.Render` with itself as consumer, one call site, so `add-render-coalescing` swaps exactly that call for `RenderCoordinator.subscribe/2` — same message contract, streaming loop untouched.
- **Streaming loop** in the endpoint process: receive pipeline messages, `chunk(conn, data)`; `{:error, closed}` from `chunk/2` = disconnect → cancel + exit (pipeline's consumer-down kill as backstop). A `receive`-loop plug action, no GenServer — conn ownership stays simple.
- **`AP_RENDER_TIMEOUT` as the receive deadline**: expiry pre-first-byte maps to 504 through the existing ErrorJSON table; mid-stream it's an abnormal close (nothing better exists over plain HTTP, per §5).
- **Test harness**: boot on an ephemeral port with a local fixture dir as `AP_LOCAL_ROOT` + real ffmpeg; `:gen_tcp` raw-socket client for disconnect and chunk-timing assertions. No new test deps — `:httpc` + `:gen_tcp` suffice.

## Risks / Trade-offs

- [Disconnect detection only fires on next chunk write] → acceptable: renders produce chunks continuously; teardown is bounded by chunk cadence.
- [No coalescing or cap until post-MVP: same-variant bursts render N times, distinct-key bursts unbounded] → declared demo/integration-only exposure until slices 11–12 land.
