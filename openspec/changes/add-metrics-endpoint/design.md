## Context

Dependency policy question: `telemetry` is already in the tree (Plug/Bandit depend on it), but Prometheus libraries (`prom_ex`, `telemetry_metrics_prometheus`) are not. The metric set is small and fixed.

## Goals / Non-Goals

**Goals:**
- The four operator signals (saturation, latency, cache efficiency, errors) exportable to any Prometheus-compatible scraper.

**Non-Goals:**
- Tracing/OpenTelemetry; per-source cardinality (labels are bounded enums only); Grafana dashboards (README example queries instead).

## Decisions

- **Hand-rolled aggregation + exposition over prom_ex**: a GenServer owning ETS tables (counters via `:ets.update_counter`, gauges, fixed-bucket histograms), attached to telemetry events; exposition is string assembly. ~150 lines for exactly our metric set vs. a dependency tree with Phoenix-oriented plumbing — consistent with the dependency policy and the S3 precedent.
- **Label discipline**: only bounded sets (format enum, outcome enum, status family, endpoint class) — no user-derived label values, no cardinality explosions.
- **Bind restriction via a second Bandit listener** on `AP_METRICS_BIND:AP_METRICS_PORT` (default `127.0.0.1:9568`) serving only `/metrics` — cleaner than IP-checking middleware on the public listener, and matches the §2 "bind-address-restricted" wording literally.
- **Histogram buckets** fixed at render-appropriate edges (0.1–60 s, exponential); documented, not configurable in v1.

## Risks / Trade-offs

- [Hand-rolled exposition format bugs] → format is tiny and stable; tests parse output with a strict line-grammar checker; example scrape validated against `promtool check metrics` in CI (optional, best-effort).
- [Second listener = second port to configure] → default loopback works for sidecar scrapers; documented for container networking.
