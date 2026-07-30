## 1. Instrumentation

- [ ] 1.1 Telemetry events: render start/stop/exception (duration, format, outcome), cache hit/miss/coalesced, HTTP request stop (endpoint class, status), write-back failure; semaphore events already exist
- [ ] 1.2 Unit tests: each code path fires its event with expected measurements/metadata (test handlers)

## 2. Aggregation & exposition

- [ ] 2.1 `AudioProxy.Metrics` GenServer + ETS: counters, gauges, fixed-bucket histograms; telemetry attachment
- [ ] 2.2 Prometheus text renderer (# HELP/# TYPE, label escaping, histogram +Inf/sum/count invariants)
- [ ] 2.3 Unit tests: event sequences → exact exposition output; histogram bucket math; concurrent-update counter accuracy

## 3. Endpoint

- [ ] 3.1 Second Bandit listener on `AP_METRICS_BIND`/`AP_METRICS_PORT` (config + validation); `/metrics` absent from public router
- [ ] 3.2 Tests: scrape parses (strict line grammar), bind restriction (public listener 404s), end-to-end counters move after a real request cycle

## 4. Docs

- [ ] 4.1 Update README: metrics list with labels, scrape config example, example PromQL for the four signals
