## Context

`:telemetry` is already in the tree (Bandit and Plug depend on it) and Bandit emits per-request events nobody consumes. The render path logs only its failures, ad hoc. This slice is plumbing existing signals to stdout, not inventing infrastructure.

## Goals / Non-Goals

**Goals:**
- One informative line per request; render lifecycle as telemetry events shared with the future metrics aggregator; credential-clean logs.

**Non-Goals:**
- Structured/JSON output (`AP_LOG_FORMAT`) — deferred to its own slice; the default formatter with metadata ships here.
- Prometheus/aggregation (`add-metrics-endpoint` attaches to these events later).
- Access-log completeness for non-API paths (unknown routes log through the same handler as 404s; nothing special).

## Decisions

- **Bandit telemetry over `Plug.Logger`**: one line per request instead of two, real durations from monotonic measurements, and protocol-level failures included. The handler reads endpoint class/options/source from `conn.assigns` (stashed by the existing plugs), so the log line speaks the API's vocabulary — the normalized options string *is* the variant identity.
- **Render events at the action boundary**: `[:audio_proxy, :render, :start | :stop | :exception]` emitted where the render is spawned/completes; the existing "render failed (class, exit N)" warning routes through the handler consuming these events. Kill-escalation and SIGKILL-survivor warnings in `Ffmpeg.Render` stay as direct `Logger` calls — they are process-level anomalies, not request events.
- **`Plug.RequestId` + Logger metadata** for correlation — ships with Plug, no dep; the id also lands in the response headers for client-side correlation.
- **`AP_LOG_LEVEL` applied via `Logger.configure/1` at boot** from the validated config, same failure mode as every other `AP_` var.
- **Credential safety by construction, plus redaction, plus test**: log calls receive the *canonical source* (already threaded through assigns), never `ffmpeg_input/1`'s return, and argv is never inspected into log lines. The stderr tail is the one field carrying text this application did not build, and it is **redacted** — `AudioProxy.LogHandler.redact/1` strips query strings from anything URL-shaped and removes bare credential parameters — rather than logged verbatim.

  *Amended during implementation.* The original decision logged tails as-is, on the reasoning that ffmpeg does not echo its input arguments into diagnostics; the risk register already named "the tail gets a scrub pass then" as the fallback. Two things brought it forward. The requirement is unconditional ("SHALL hold on every path, including failure paths that log diagnostics"), and its scenario asks for a *test* against an input carrying `X-Amz-Signature` — but with `local://` the only registered source type, no URL-shaped ffmpeg input is reachable end to end, so the only way to demonstrate the guarantee is to poison a diagnostic and show it does not survive. Demonstrating it that way means redacting. The cost is ~25 lines and two regexes; the gain is that the guarantee no longer rests on an assumption about a third-party binary's output, which is what the S3 slice would otherwise have inherited untested. `test/support/fake_ffmpeg.sh` grew a `presigned.*` case — the ffmpeg build that *does* echo its input — so the test drives the real render path rather than the handler in isolation.
- **`/health` filtered in the handler** by endpoint class (emitted at debug) — cheaper than a router split and keeps the one-handler invariant.

## Risks / Trade-offs

- [One line per request is real volume at high RPS] → `AP_LOG_LEVEL=warning` silences the happy path wholesale; per-class sampling is a later knob if ever needed.
- [ffmpeg stderr tails could in principle contain fragments of the input URL] → resolved rather than accepted: tails are redacted before they are logged, and the stand-in encoder has a case that echoes a presigned URL so the redaction is exercised on the real render path. The residual risk is a credential shape neither regex matches, which is a regex to add, not a design to revisit.
- [Two log producers during migration (events + legacy direct calls)] → the slice routes the render-outcome warning through events in the same PR; only the process-anomaly warnings remain direct, intentionally.
