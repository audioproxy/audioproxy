# Running more than one node

One container is the whole product for most deployments: it is stateless, it renders as fast as its CPU allows, and [docs/capacity.md](capacity.md) tells you how much memory a given `AP_MAX_CONCURRENCY` needs. This document is about the point after that — when one node's schedulers are the ceiling, and the answer is more nodes.

Nothing here needs a cluster mode, a gossip protocol or a shared database, because the proxy has no cross-node state worth sharing. What it has instead is a URL that names its own output completely. Two nodes handed the same URL produce the same audio, so the worst a badly-routed fleet does is repeat work. (Identical *bytes* too, on nodes of the same CPU architecture — see [A mixed-architecture fleet](#a-mixed-architecture-fleet) for the one case where that is not quite the same statement.) Everything below is about making that repetition rare rather than about preventing it.

## Contents

- [The one requirement: a shared variant store](#the-one-requirement-a-shared-variant-store)
- [What duplicate renders actually cost](#what-duplicate-renders-actually-cost)
- [Health and readiness](#health-and-readiness)
- [Load balancers](#load-balancers)
- [Kubernetes](#kubernetes)
- [Fly.io](#flyio)
- [Docker Swarm](#docker-swarm)
- [Sizing a fleet](#sizing-a-fleet)

## The one requirement: a shared variant store

Every node must point `AP_VARIANT_STORE` at the same place.

The variant store is where a render is written back, and it is the only thing that makes a second request for the same URL cheap. Give each node its own store and you have not built a fleet of *n* nodes; you have built *n* separate proxies that each pay the first render, each hold a partial cache, and each miss on whatever the others warmed. The cache hit rate falls by roughly the factor you scaled by, which is the opposite of the reason you scaled.

"The same place" means a store every node can read and write:

- **An `s3://` store** — `AP_VARIANT_STORE=s3://bucket`, and the right answer for most fleets: nodes share nothing but a bucket, there is no volume to mount on every host, and `AP_SERVE_MODE=redirect` takes the proxy out of the byte path entirely by handing each client a presigned URL. The bucket is probed for writability at boot, so a fleet pointed at one it cannot write fails to start rather than silently rendering everything twice forever.
- **A `file://` store on a shared filesystem** — an NFS mount, an EFS/Filestore volume, a Kubernetes `ReadWriteMany` volume. Workable, and the only option if object storage is off the table. Redirect mode is refused against a `file://` store at boot (there are no URLs to presign), so a shared-filesystem fleet runs `AP_SERVE_MODE=proxy` and keeps the proxy in the byte path.

A per-node store is not *wrong* — the proxy runs fine that way, and for a fleet fronted by a CDN that absorbs the repeats it can even be reasonable. It is just not a cache you are sharing, and it should be a decision rather than an accident.

### A mixed-architecture fleet

The image is published for `linux/amd64` and `linux/arm64`, so a fleet can hold both — an x86 baseline with Graviton or Ampere nodes added for cost, most commonly. Everything above applies unchanged, with one thing worth knowing before you mix them.

**The two architectures render the same URL to the same audio, not to the same bytes.** ffmpeg is entitled to differ in the last bit or two across hardware: different SIMD paths, different float rounding. Format, duration, channel layout, bitrate and everything the URL asks for are identical, and every decoder agrees; the file's checksum is not guaranteed to be. Both architectures ship the same ffmpeg version — CI refuses to publish a tag whose two images disagree about it — so the variance stays down at the level of arithmetic and is never a difference of encoder.

The cache key knows nothing about architecture, deliberately. So on a fleet sharing one variant store, a given URL is rendered once by whichever node got the miss, and every node afterwards serves *that* object. Which architecture rendered it is decided by routing and by nothing else, and it can change after the object ages out or the bucket is cleared.

For almost every deployment that is a non-event: clients decode audio, and the audio is the same. It matters in exactly two cases.

- **You checksum variants** — an integrity manifest, a fixture test, a CDN that diffs objects. Compare decoded audio, or pin one architecture for rendering.
- **You need reproducibility across a rebuild** — the same requirement, with time as the second axis. An ffmpeg pin bump already moves those bytes (see [VERSIONS.md](https://github.com/audioproxy/audioproxy/blob/main/VERSIONS.md)); architecture is a second axis of the same kind, and pinning one architecture removes it.

Pinning is ordinary scheduling, not a proxy setting: a node selector, an instance type, or simply not adding the other kind of machine.

## What duplicate renders actually cost

Within one node, concurrent requests for the same variant are coalesced: the first one starts a render, the rest attach to it and receive the same chunk stream, and the response log says `COALESCED`. One encode, *n* clients. That mechanism is a `Registry` keyed on the cache key, so it is node-local by construction.

Across nodes there is no coalescing. If *k* nodes are each handed a request for the same cold URL at the same moment, you get *k* renders instead of one, and *k* writes of identical bytes to the store.

This is bounded and harmless, and it is worth being precise about why:

- **The bytes are identical.** The cache key is a hash of the normalized options plus the source, and the same options produce the same ffmpeg argv. Two nodes racing to write the same key write the same object; last-writer-wins is a correct outcome because there is nothing to lose.
- **The window is one render long.** Once any node has written it back, every node hits. The duplication is a property of the cold moment, not of the URL.
- **It is capped by the fleet, not by traffic.** A thousand simultaneous requests for one cold URL across ten nodes cost ten renders, not a thousand — the node-local coalescing absorbs the rest. The worst case is *k* = the number of nodes, and only for URLs that are cold.

So the honest summary is: **occasionally *k* cold renders.** If that is acceptable, route however you like and stop reading at [Kubernetes](#kubernetes). The next section is for when it is not.

## Health and readiness

Two unsigned endpoints, and the distinction between them matters more in a fleet than on one box:

| | Question it answers | What a failure should trigger |
|---|---|---|
| `GET /health` | Is this VM running? | Restart the container |
| `GET /ready` | Should this node be sent new work? | Route elsewhere; do **not** restart |

`/health` is pure liveness. It is unaffected by load — a node with a full queue answers it `200`, because a busy proxy is a working proxy, and a liveness probe that failed under load would restart exactly the containers that were carrying the traffic.

`/ready` reports queue depth against a threshold:

```console
$ curl -s localhost:4000/ready
{"status":"ready","queued":0,"threshold":16}

# …under load:
$ curl -si localhost:4000/ready | head -1
HTTP/1.1 503 Service Unavailable
```

The node trips to `503` once the semaphore's wait queue reaches `AP_READY_QUEUE_THRESHOLD`, and recovers only once depth falls back to **half** of it, rounded down — a threshold of 5 recovers at a depth of 2, and a threshold of 1 recovers only at an empty queue. That lower recovery mark is hysteresis, and it is the whole reason the endpoint is trustworthy: without it a node hovering at the threshold would flip on every poll, and a fleet under uniform load hovers *together*, so every node would flip together and the balancer would briefly have an empty pool. With it, one excursion above the threshold produces exactly one not-ready period.

`AP_READY_QUEUE_THRESHOLD` defaults to half of `AP_QUEUE_SIZE`, rounded down but never below 1 for a queue that can hold anything — deep enough that a node shrugging off a burst is not ejected for it, shallow enough that the orchestrator learns about the backlog well before the queue fills and requests start becoming `429`s. Setting it to `0` disables the check, and `/ready` becomes a second liveness endpoint; that is the right setting for a single node, where there is nowhere else to route. A value above `AP_QUEUE_SIZE` is refused at boot, because queue depth could never reach it.

Both probes are logged at `debug`, so polling them every few seconds does not drown the log. A `/ready` 503 is not promoted to a warning: it is the mechanism working.

**Readiness is not backpressure.** The `429` with `Retry-After` is still what happens when the queue is genuinely full, and `/ready` does not change it. Readiness is advice given *before* that point, so that a client never has to see it.

## Load balancers

### Least connections, not round robin

Renders vary in cost by orders of magnitude — a 30-second preview and a full-length FLAC transcode arrive through the same endpoint. Round robin distributes *requests*, which is not the resource under contention; a node can collect several long transcodes while its neighbour finishes previews, and round robin keeps feeding it.

Least-connections tracks in-flight work, which for this proxy is a much better proxy for load: a request is "connected" for as long as its render streams. Prefer it wherever it is available.

### URI hashing, if you want cluster-wide coalescing

Hashing the request URI to a backend upgrades node-local coalescing to fleet-wide coalescing for free: all requests for one variant land on one node, that node coalesces them, and *k* cold renders becomes one.

The trade is that hashing is not load-aware. A single very popular cold URL pins its render to one node regardless of how busy that node is, and adding or removing a node reshuffles keys (consistent hashing bounds the reshuffle, but does not eliminate it). It is the right choice when your traffic has hot URLs and a shared store; it is the wrong choice when your traffic is uniformly spread, where least-connections wins and the duplicate renders never happen anyway.

**nginx** — `$request_uri` is the full path plus query, which is exactly the variant identity:

```nginx
upstream audio_proxy {
    hash $request_uri consistent;
    server proxy-1:4000;
    server proxy-2:4000;
    server proxy-3:4000;
}

server {
    listen 80;
    location / {
        proxy_pass http://audio_proxy;
        proxy_http_version 1.1;

        # Renders stream as they encode; buffering would hold the whole
        # variant at the balancer and delay first byte by the render.
        proxy_buffering off;

        # A long transcode can outlive a default 60s read timeout.
        proxy_read_timeout 310s;
    }
}
```

Size `proxy_read_timeout` above `AP_RENDER_TIMEOUT` (default 300s), so that a render that hits its own timeout answers `504` from the proxy — with a body saying what happened — rather than being cut off by the balancer first.

**Envoy** — `RING_HASH` with a path-based hash policy:

```yaml
clusters:
  - name: audio_proxy
    lb_policy: RING_HASH
    type: STRICT_DNS
    load_assignment: { cluster_name: audio_proxy, endpoints: [...] }

routes:
  - match: { prefix: "/" }
    route:
      cluster: audio_proxy
      timeout: 310s          # above AP_RENDER_TIMEOUT
      hash_policy:
        - header: { header_name: ":path" }
```

**Kubernetes ingress-nginx** — the same thing as an annotation on the Ingress:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/upstream-hash-by: "$request_uri"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "310"
```

**Hashing and readiness compose here, and do not in the plain-nginx recipe above.** The difference is where the backend list comes from, and it is worth being exact about because the two look identical in the config:

- **ingress-nginx** builds its upstream from the Service's *ready* endpoints. A pod that fails its readiness probe is removed from those endpoints, so it leaves the hash ring too, and the keys that hashed to it remap to pods that are ready. Readiness moves traffic exactly as it would under least-connections; hashing just decides *which* ready pod. Note the corollary: because the ring changes when a pod goes unready, some keys land on a node that has not rendered them, which is the reshuffle cost paid early. That is the correct trade — a duplicate render is cheaper than a queued one.
- **A static nginx `upstream` block** (the recipe above) polls nothing. nginx OSS has passive health checks only; active HTTP health checks are an nginx Plus feature. So `/ready` has no reader, and a node answering `503` keeps receiving its hashed share until it fails outright. If you want readiness to move traffic in front of a static upstream, something has to consume it — nginx Plus, or a service-discovery layer that rewrites the upstream and reloads.

That asymmetry is the practical argument for running this on Kubernetes or Fly rather than behind a hand-rolled nginx: the readiness signal is only worth what the thing in front of it does with it.

## Kubernetes

### Probes

Point them at different endpoints. This is the entire reason `/ready` exists:

```yaml
livenessProbe:
  httpGet: { path: /health, port: 4000 }
  initialDelaySeconds: 5
  periodSeconds: 10

readinessProbe:
  httpGet: { path: /ready, port: 4000 }
  periodSeconds: 5
  # One failed poll is enough: hysteresis already damped the signal, so a
  # second confirmation would only add latency to shedding.
  failureThreshold: 1
  # Two clean polls before coming back, which costs a little and buys against
  # a node that recovers into the same burst.
  successThreshold: 2
```

A pod that fails its readiness probe is removed from the Service's endpoints and stops receiving new connections. It keeps serving what it has, which is what you want: the queue drains, depth falls below the recovery mark, and the pod comes back.

**`terminationGracePeriodSeconds` must exceed `AP_RENDER_TIMEOUT`.** A rolling update sends `SIGTERM`; renders in flight need to finish or be killed cleanly, and the default 30 seconds will cut a long transcode off mid-stream. Set it to `AP_RENDER_TIMEOUT` plus a margin.

Set `resources.limits.memory` from the matrix in [docs/capacity.md](capacity.md) for your `AP_MAX_CONCURRENCY` and the longest output you serve — a container OOM-killed mid-render is a `502` for every request attached to it.

### Autoscaling

CPU is a workable HPA signal and needs nothing from the proxy:

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 70 }
```

It is a lagging signal, though: ffmpeg saturates a slot's CPU whether the queue behind it is empty or thirty deep, so utilization tells you the node is working, not that it is behind. **Queue depth is the leading signal** — it is the thing `/ready` already thresholds on, and scaling on it means adding capacity while requests are waiting rather than after they start timing out.

`audio_proxy_render_queue_depth` is that number, exported by [`/metrics`](operations.md#metrics). The HPA shape is a custom Pods metric on it, with a target well below `AP_READY_QUEUE_THRESHOLD` so the fleet scales *before* nodes start shedding:

```yaml
metrics:
  - type: Pods
    pods:
      metric: { name: audio_proxy_render_queue_depth }
      target: { type: AverageValue, averageValue: "4" }
```

Two things have to be in place first. The scrape port is on its own listener bound to loopback by default, so a scraper outside the pod needs `AP_METRICS_BIND=0.0.0.0` and a `PodMonitor` on `AP_METRICS_PORT` — declare the port on the pod, not on the Service that serves audio. And the metric has to reach the HPA, which means Prometheus Adapter or an equivalent bridge; the HPA reads the custom metrics API, never the exposition directly.

`audio_proxy_render_queue_rejections_total` is the alert that pairs with this target. Depth is the signal you scale on; rejections are the signal that you scaled too late.

Until then, the practical pairing is CPU-based HPA plus readiness: readiness sheds within the current fleet, CPU grows the fleet. The failure mode worth naming is the one where they are not paired — under cluster-wide overload *every* node crosses the threshold, every node reports unready, and the Service has no endpoints at all. Readiness on its own can only redistribute load; it cannot create capacity. The autoscaler is what resolves an overload. Shed, then scale — never shed alone.

## Fly.io

Fly is the platform where most of this document is unnecessary, because fly-proxy already does load-aware routing and autoscaling with one mechanism.

```toml
[http_service]
  internal_port = 4000
  auto_stop_machines = "suspend"
  auto_start_machines = true
  min_machines_running = 1

  [http_service.concurrency]
    type = "requests"
    soft_limit = 8
    hard_limit = 12

[[http_service.checks]]
  path = "/health"
  interval = "10s"
  timeout = "2s"
```

**Map the concurrency limits to the render budget, not to a guess.** `soft_limit` is the point at which fly-proxy starts preferring other machines and, with `auto_start_machines`, starts new ones; `hard_limit` is the point at which it stops sending a machine requests at all. So:

- `soft_limit` = `AP_MAX_CONCURRENCY`. Above this the machine is queueing rather than rendering, which is exactly when you want another machine.
- `hard_limit` = `AP_MAX_CONCURRENCY` + the queue headroom you are willing to hold, comfortably below `AP_MAX_CONCURRENCY + AP_QUEUE_SIZE`. Leaving the gap means fly-proxy stops feeding a machine before the proxy has to start answering `429`.

With that mapping, fly-proxy is doing what `/ready` does for Kubernetes, at a finer grain and without a polling loop. **Use the concurrency limits as the primary mechanism on Fly**, and point the health check at `/health`. One platform, one mechanism; running both is not harmful, but it is two things to tune where one would do.

**fly-proxy has no URI-hash mode.** The [URI hashing](#uri-hashing-if-you-want-cluster-wide-coalescing) recipes above do not apply, and there is no supported way to pin a variant's requests to one machine. So on a multi-machine Fly app you keep the *k*-cold-renders cost described earlier. Fleet-wide single-flight — one render per key across every node — is a distributed-lock problem the OSS proxy deliberately does not solve; it is PRO territory.

Two things make this a small cost in practice:

- **`auto_stop_machines`/`min_machines_running` keep *k* small.** A fleet that scales to one machine at idle has *k* = 1 for cold URLs outside peak.
- **A CDN in front collapses same-URL storms at the edge.** Fly Proxy is not a cache; put a CDN in front and a thousand simultaneous requests for one cold URL become one origin request, so the *k* nodes never see the storm at all. Media responses are already `public, max-age=31536000, immutable`, and `AP_SERVE_MODE=proxy` is the mode that collaborates with an edge (see [edge-cache discipline](audio-proxy-api-v1.md#edge-cache-discipline) — redirect mode routes the bytes around the CDN). With that in place, the fleet's duplicate-render cost is what the summary above says: occasionally *k* cold renders, and only for URLs nothing has asked for yet.

Size the machine from [docs/capacity.md](capacity.md): `AP_MAX_CONCURRENCY` against the VM's memory, not against its CPU count, since output is what is held in memory.

## Docker Swarm

Swarm's routing mesh is L4. It does not read the HTTP request, so **there is no URI hashing and no request-aware balancing** — and its published-port load balancing is round robin over VIPs, which is the distribution strategy least suited to this workload.

Swarm's `healthcheck` is also liveness-shaped: a container failing it is restarted, not drained. Pointing it at `/ready` would restart busy containers, which is the exact mistake `/ready` exists to let you avoid. **Point Swarm's healthcheck at `/health`, always.**

If you want either least-connections or URI hashing on Swarm, put nginx in front of the service and use the recipe above, with the proxy service on an overlay network and nginx as the only published port. That is a real component to run and monitor; it is worth it if you have hot URLs and it is not otherwise.

The image already ships a `HEALTHCHECK` against `/health`, so the common case needs no `healthcheck:` block at all:

```yaml
services:
  proxy:
    image: ghcr.io/audioproxy/audioproxy:0.7.1
    deploy:
      replicas: 3
```

Override it only to change the cadence, and keep it pointed at `/health`:

```yaml
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:4000/health"]
      interval: 10s
```

## Sizing a fleet

Per-node capacity first, then node count:

1. **Per node**, `AP_MAX_CONCURRENCY` comes from [docs/capacity.md](capacity.md) — memory, not cores, is usually the binding constraint, because a render holds its output until it ends.
2. **Fleet throughput** is `nodes × AP_MAX_CONCURRENCY` simultaneous renders. Cache hits do not consume a slot at all, so on a warm cache the real ceiling is the store's and the network's, not the proxy's. Size for the *miss* rate, not the request rate.
3. **`AP_QUEUE_SIZE`** buys tolerance for bursts, not throughput. A deep queue with no autoscaler behind it converts a burst into a long wait and then a `504`. Keep it modest and let readiness plus the autoscaler handle sustained load.
4. **`AP_READY_QUEUE_THRESHOLD`** at its default (half the queue) is a reasonable starting point. Lower it if you would rather shed early and scale aggressively; raise it if your nodes routinely absorb bursts that the balancer should not react to.

The measurement that tells you whether any of this is working is the ratio of `MISS`/`COALESCED` to `HIT` in the request log (see [Logs](operations.md#logs)). A fleet whose miss rate does not fall as it warms is usually a fleet without a shared store.
