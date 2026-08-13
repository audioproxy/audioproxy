# Operations: logs and metrics

What a running proxy tells you about itself, and how to read it. Health and
readiness are the third leg of this and live in
[scaling.md](scaling.md#health-and-readiness), because what they are *for* is
deciding whether a node should be sent work.

## Logs

Everything goes to stdout, one line per completed request:

```
12:31:07.442 request_id=GMf5ECU8WG_tDMEAAAJC [info] render 200 opts=br:96/f:opus src=local://piece.wav cache=MISS 27141 bytes in 63.4ms
12:31:07.981 request_id=GMf5ECU9xK2sPQ1AAAJD [info] render 200 opts=br:96/f:opus src=local://piece.wav cache=COALESCED 27141 bytes in 2.8ms
12:31:09.118 request_id=GMf5EGolMMyBOD4AAA7B [info] render 422 invalid_options 74 bytes in 0.3ms
12:31:11.006 request_id=GMf5ECRh8raItPUAAAOl [warning] render 504 render_timeout opts=f:mp3 src=local://long.wav cache=MISS 72 bytes in 300004.7ms
```

Reading one left to right: the endpoint (`render`, `health`, or `unknown` for a
path that matched no route), the status, the error code from the API doc's error
table when the request failed, the normalized options string and the canonical
source once the proxy has got far enough to know them (a `401` knows neither and
omits both), whether the request rendered or shared one, the bytes sent, and how
long it took.

`cache=` is the field to read before drawing conclusions from a duration. The
second line above delivered the same 27 kB as the first in a fortieth of the
time because it attached to the render already running for that variant — not
because ffmpeg was fast.

`request_id` is on every line, and the same id comes back to the client in the
`x-request-id` response header — so a report of "this URL was slow at 12:31" can
be traced to the render behind it. Send your own `x-request-id` and it is used
instead, which is what makes the log line up with a proxy or gateway in front.

### Levels

| Level | What appears |
|---|---|
| `error` | Nothing routine: a render the host could not start at all (no encoder on `PATH`), a subprocess that survived `SIGKILL`, and crashes |
| `warning` | `5xx` and `504` responses, and the ffmpeg diagnostic behind a failed render |
| `info` | **Default.** The above, plus one line per request, `4xx` included: a `401` is a normal outcome for a public endpoint, not an incident |
| `debug` | The above, plus `/health`, `/ready` and `/metrics` (silent otherwise, so a liveness probe every second and a scrape every fifteen do not become the log), the render lifecycle, and client disconnects |

Set the floor with `AP_LOG_LEVEL`; `warning` is the setting for a busy
production instance that wants failures only.

Presigned URLs and credentials never appear. Sources are logged by their
canonical identity (`local://piece.wav`), never by what ffmpeg was handed to
read, and diagnostics quoted back from ffmpeg have their query strings stripped.

Structured JSON output is not implemented yet — it arrives with its own slice.

## Metrics

`GET /metrics` answers in Prometheus text format. It is unsigned, and it is
served on **its own listener**, bound by default to `127.0.0.1:9568` — a sidecar
scraper and a `kubectl port-forward` reach it, and nothing off-host does. The
bind is the access control, so widening it is a deliberate act:

```console
$ curl -s localhost:9568/metrics | head -3
# HELP audio_proxy_renders_total Renders that finished, by output format and outcome.
# TYPE audio_proxy_renders_total counter
audio_proxy_renders_total{format="mp3",outcome="success"} 412
```

`AP_PORT` does not serve it — a request for `/metrics` there is a `404`.

### What is exported

| Metric | Type | Labels |
|---|---|---|
| `audio_proxy_renders_total` | counter | `format`, `outcome` |
| `audio_proxy_render_duration_seconds` | histogram | `format`, `outcome` |
| `audio_proxy_renders_running` | gauge | — |
| `audio_proxy_render_slots_held` | gauge | — |
| `audio_proxy_render_slots_capacity` | gauge | — |
| `audio_proxy_render_queue_depth` | gauge | — |
| `audio_proxy_render_queue_capacity` | gauge | — |
| `audio_proxy_render_queue_rejections_total` | counter | — |
| `audio_proxy_cache_lookups_total` | counter | `format`, `outcome` |
| `audio_proxy_variant_store_write_failures_total` | counter | — |
| `audio_proxy_http_requests_total` | counter | `endpoint`, `status` |

`format` is the output format (`mp3`, `opus`, `peaks`, …). `outcome` on a render
is `success`, `cancelled` (the client went away mid-stream), or the failure class
from the API doc's error table (`timeout`, `undecodable`, `not_found`, …); on a
cache lookup it is `hit`, `miss` or `coalesced`, the same three values the
`X-Audio-Proxy` header carries. `endpoint` is the route class (`render`, `info`,
`health`, `ready`, `metrics`, `unknown`) and `status` a code family (`2xx`,
`4xx`, …).

Every label is a fixed, bounded set. Nothing derived from a request — not the
source, not the options, not the cache key — becomes a label, so no client can
grow your scraper's series count.

`renders_running` counts *renders*, not requests: twenty clients coalesced onto
one encode are one running render, which is what `AP_MAX_CONCURRENCY` counts too.

Duration buckets are fixed at 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120 and 300
seconds. They are not configurable, so the histogram stays aggregatable across
nodes and across releases.

### Scrape config

```yaml
scrape_configs:
  - job_name: audio_proxy
    static_configs:
      - targets: ["127.0.0.1:9568"]
```

In a container, `127.0.0.1` is the pod, not the host — so a sidecar scraper in
the same pod works unchanged, and a scraper elsewhere needs
`AP_METRICS_BIND=0.0.0.0` plus a network policy that keeps the port to your
monitoring namespace. On Kubernetes, declare the port on the pod and point a
`PodMonitor` at it rather than exposing it through the Service that serves audio.

### The four signals

```promql
# Saturation: how much of this node's render budget is in use. The leading
# signal is the queue behind it — the slots are full long before it grows.
sum(audio_proxy_render_slots_held) / sum(audio_proxy_render_slots_capacity)
sum(audio_proxy_render_queue_depth)

# Latency: the 95th percentile render, by format. Split by format because a
# full-length FLAC and a 30-second Opus preview are not the same workload.
histogram_quantile(
  0.95,
  sum by (format, le) (rate(audio_proxy_render_duration_seconds_bucket[5m]))
)

# Cache efficiency: the share of requests that cost no encode at all. This is
# the number the proxy exists to move.
sum(rate(audio_proxy_cache_lookups_total{outcome=~"hit|coalesced"}[5m]))
  / sum(rate(audio_proxy_cache_lookups_total[5m]))

# Errors: the share of renders that did not deliver, and the load being shed.
sum(rate(audio_proxy_renders_total{outcome!~"success|cancelled"}[5m]))
  / sum(rate(audio_proxy_renders_total[5m]))
rate(audio_proxy_render_queue_rejections_total[5m])
```

Two more worth an alert. `audio_proxy_variant_store_write_failures_total` moving
at all means the cache has silently stopped filling — clients are being served,
so nothing else reports it, and the hit ratio decays over hours. And
`audio_proxy_render_queue_depth` is the leading signal for autoscaling: target it
well below `AP_READY_QUEUE_THRESHOLD` so the fleet grows before nodes start
shedding. See [scaling.md](scaling.md#autoscaling).
