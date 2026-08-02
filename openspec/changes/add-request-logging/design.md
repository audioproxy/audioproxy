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
- **Credential safety by construction plus test**: log calls receive the *canonical source* (already threaded through assigns), never `ffmpeg_input/1`'s return; argv is never inspected into log lines (stderr tails are — they cannot contain the input URL's query because ffmpeg does not echo its input arguments into diagnostics; the capture test guards the whole surface anyway).
- **`/health` filtered in the handler** by endpoint class (emitted at debug) — cheaper than a router split and keeps the one-handler invariant.

## Risks / Trade-offs

- [One line per request is real volume at high RPS] → `AP_LOG_LEVEL=warning` silences the happy path wholesale; per-class sampling is a later knob if ever needed.
- [ffmpeg stderr tails could in principle contain fragments of the input URL] → the capture test renders against a URL-shaped input and asserts cleanliness; if a real ffmpeg build ever echoes it, the test catches it and the tail gets a scrub pass then.
- [Two log producers during migration (events + legacy direct calls)] → the slice routes the render-outcome warning through events in the same PR; only the process-anomaly warnings remain direct, intentionally.
