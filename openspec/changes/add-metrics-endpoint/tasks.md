## 1. Instrumentation

- [ ] 1.1 Attach the aggregator to the telemetry that already exists; create only what is missing. Present as of `add-request-logging`: `[:audio_proxy, :render, :start | :stop | :exception]` with duration, bytes, format, canonical source and outcome/failure class (`AudioProxy.Telemetry` documents the contract, and `AudioProxy.LogHandler` is the proof a second consumer costs the render path nothing), plus the HTTP side as Bandit's own `[:bandit, :request, :stop]` read through `conn.assigns` for endpoint class, error class, options and source. The semaphore's events already exist too. **Still to create:** cache outcomes (hit/miss/coalesced) and write-back failures
- [ ] 1.2 Unit tests for the events this slice creates: each code path fires with the expected measurements/metadata (test handlers). The render and HTTP events are already covered by `AudioProxy.TelemetryTest` and `AudioProxy.RequestLoggingIntegrationTest` — extend rather than restate

## 2. Aggregation & exposition

- [ ] 2.1 `AudioProxy.Metrics` GenServer + ETS: counters, gauges, fixed-bucket histograms; telemetry attachment
- [x] 2.2 Prometheus text renderer (# HELP/# TYPE, label escaping, histogram +Inf/sum/count invariants)
- [ ] 2.3 Unit tests: event sequences → exact exposition output; histogram bucket math; concurrent-update counter accuracy

## 3. Endpoint

- [ ] 3.1 Second Bandit listener on `AP_METRICS_BIND`/`AP_METRICS_PORT` (config + validation); `/metrics` absent from public router
- [ ] 3.2 Tests: scrape parses (strict line grammar), bind restriction (public listener 404s), end-to-end counters move after a real request cycle

## 4. Docs

- [ ] 4.1 Update README: metrics list with labels, scrape config example, example PromQL for the four signals
