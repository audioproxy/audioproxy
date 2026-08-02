## Why

v0.1.0 logs boot lines and render deaths — nothing else. A working proxy under load is indistinguishable from an idle one; a 401, 404, or successful render leaves no trace. Request logging is also the observability wanted *while building* the next slices (coalescing's COALESCED, the semaphore's 429 are exactly what should be visible), and instrumenting through telemetry now means the metrics slice later attaches an aggregator to events that already exist — instrument once, consume twice.

## What Changes

- Telemetry instrumentation: consume Bandit's existing `[:bandit, :request, :stop]` events; emit `[:audio_proxy, :render, :start | :stop | :exception]` from the render path with format, canonical source, duration, bytes, and failure class.
- A log handler producing one line per request: request id, endpoint class (render/info/health), normalized options, canonical source, status, duration, bytes. Levels: 2xx/3xx/4xx at info (client errors are calm), 5xx and timeouts at warning. `/health` logs at debug only.
- Request ids via `Plug.RequestId` (ships with Plug) into Logger metadata.
- `AP_LOG_LEVEL` env var (default `info`), applied at boot.
- A credential-safety guarantee: log output SHALL never contain presigned URLs or credential material — today's inputs are local paths, but the S3 backend will hand ffmpeg URLs carrying live `X-Amz-Signature` tokens, and a log line that includes the render input would leak a fetchable secret into log storage. Tested by log capture, not left to review.
- Explicitly deferred to a later slice: structured/JSON output (`AP_LOG_FORMAT`) — the default human-readable formatter with metadata ships here.

## Capabilities

### New Capabilities

- `request-logging`: Per-request and per-render log lines, level policy, log-level configuration, and the no-credentials guarantee.

### Modified Capabilities

<!-- none — the metrics slice later consumes the same telemetry events; its spec is untouched -->

## Impact

- New: telemetry attachment module + log handler, `Plug.RequestId` in the pipeline, `AP_LOG_LEVEL` config.
- Modified: render path emits lifecycle events (its ad-hoc failure logging routes through them; kill-escalation warnings stay).
- Modified artifacts: `add-metrics-endpoint` task 1.1 (HTTP/render events will already exist — attach, don't create).
- Depends on: nothing beyond what is merged (render endpoint, port pipeline).
- Position: next slice, before `add-render-coalescing`.
