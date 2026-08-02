## 1. Instrumentation

- [ ] 1.1 Telemetry attachment module in the supervision tree; handler for `[:bandit, :request, :stop]` reading class/options/source from `conn.assigns`
- [ ] 1.2 `[:audio_proxy, :render, :start | :stop | :exception]` events at the render action boundary (format, canonical source, duration, bytes, failure class); route the existing render-outcome warning through them
- [ ] 1.3 `Plug.RequestId` in the pipeline; request id into Logger metadata and response headers

## 2. Log handler & config

- [ ] 2.1 Request line formatting (id, class, options, source, status, duration, bytes); level policy (2xx–4xx info, 5xx/timeout warning); `/health` → debug
- [ ] 2.2 `AP_LOG_LEVEL` in `AudioProxy.Config` (enum, default info, boot validation) applied via `Logger.configure/1`

## 3. Tests

- [ ] 3.1 CaptureLog: 200 render line contents; 401/404/422 at info with error class; 504/mid-stream at warning; `/health` silent at info, present at debug
- [ ] 3.2 `AP_LOG_LEVEL=warning` suppresses info lines, keeps warnings; invalid value fails boot naming the var
- [ ] 3.3 Telemetry contract: test handler observes start/stop/exception with documented measurements/metadata; second handler sees identical data
- [ ] 3.4 Credential safety: render with a URL-shaped input carrying `X-Amz-Signature` (failure and success paths), capture all logs, assert no `X-Amz`/query-string substring while the canonical source appears

## 4. Docs & cross-slice

- [ ] 4.1 README ops section: log line anatomy, levels, `AP_LOG_LEVEL`; note JSON format is deferred to a later slice
- [ ] 4.2 Amend `add-metrics-endpoint` task 1.1: HTTP/render telemetry events exist as of this slice — attach the aggregator, create only what's missing (cache outcomes, write-back failures)
