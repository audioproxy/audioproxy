## Context

Fills the 501 seam `add-request-plugs` left: the action between "every check passed" and "bytes on the socket". Bandit + `Plug.Conn.chunk/2`; the pipeline's consumer contract does the rest.

## Goals / Non-Goals

**Goals:**
- The MISS-path streaming lifecycle over a real socket, with disconnect and failure semantics per §5.

**Non-Goals:**
- HIT/write-back (variant-cache); coalescing and concurrency limiting (their own post-MVP slices — the spawn stays a single call site for the coordinator swap); peaks/info routes.

## Decisions

- **TOCTOU posture (task 1.1a): accept the exposure, under the read-only-root assumption the README already states.** `Source.ffmpeg_input/1` returns a path, and between its check and ffmpeg's `open` the file can be swapped. Pinning the inode was the alternative and it does not survive contact with the runtime: the descriptor would have to be opened in the BEAM and *inherited* by the subprocess, but the emulator opens its file descriptors close-on-exec, so nothing a port spawns can see `/dev/fd/N` from this side. Closing the window would mean a helper binary or a NIF that opens the file and execs ffmpeg — a new moving part, and one that buys nothing for the remote source types where the "file" is an HTTP URL and no inode exists to pin. What the seam does give is narrowing, and it is kept: `ffmpeg_input/1` re-resolves confinement and re-checks that the target is a regular file, so the swap an attacker needs is a swap *into* the root, not merely a race — and a FIFO, the case that would hang a render slot until the timeout, is refused on the way past rather than trusted from an earlier `stat/1`. The residual exposure is therefore exactly "someone can write into `AP_LOCAL_ROOT`", which is already the whole access-control story for disk: write access to the root is equivalent to choosing what the proxy serves. Revisit if a source type ever serves a root that is not operator-controlled.
- **The endpoint consumes the pipeline directly**: spawn `Ffmpeg.Render` with itself as consumer, one call site, so `add-render-coalescing` swaps exactly that call for `RenderCoordinator.subscribe/2` — same message contract, streaming loop untouched.
- **Streaming loop** in the endpoint process: receive pipeline messages, `chunk(conn, data)`; `{:error, closed}` from `chunk/2` = disconnect → cancel + exit (pipeline's consumer-down kill as backstop). A `receive`-loop plug action, no GenServer — conn ownership stays simple.
- **`AP_RENDER_TIMEOUT` as the receive deadline**: expiry pre-first-byte maps to 504 through the existing ErrorJSON table; mid-stream it's an abnormal close (nothing better exists over plain HTTP, per §5).
- **Test harness**: boot on an ephemeral port with a local fixture dir as `AP_LOCAL_ROOT` + real ffmpeg; `:gen_tcp` raw-socket client for disconnect and chunk-timing assertions. No new test deps — `:httpc` + `:gen_tcp` suffice.

## Risks / Trade-offs

- [Disconnect detection only fires on next chunk write] → acceptable: renders produce chunks continuously; teardown is bounded by chunk cadence.
- [No coalescing or cap until post-MVP: same-variant bursts render N times, distinct-key bursts unbounded] → declared demo/integration-only exposure until slices 11–12 land.
