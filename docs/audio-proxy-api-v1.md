# Audio Proxy — API v1 (draft)

An imgproxy-style on-the-fly audio transcoding proxy. Sources live in S3 (or any HTTP-reachable store); variants are rendered on demand, streamed to the first requester, and written back to a variant bucket for cached, range-capable serving thereafter.

Design principles, in order: URLs are the entire API (no request bodies, no state); every variant is fully described by its processing options, which double as the cache key; everything is signed.

---

## 1. URL structure

```
GET /{signature}/{options}/{source}
```

- **signature** — `base64url(HMAC-SHA256(key, salt ‖ path))` over everything after the signature segment: the exact byte sequence following `/{signature}`, leading `/` included, taken from the raw (still percent-encoded) request path. Signatures are emitted unpadded; the canonical padded form (one trailing `=`) is accepted, but non-canonical spellings (over-padding, variant final characters) are rejected, so each signature has exactly two accepted spellings. In dev mode the literal `insecure` is accepted (disabled by default in prod).
- **options** — ordered, `/`-separated `key:value` segments (see §3). Order is normalized before hashing into the cache key, so `f:opus/br:96` and `br:96/f:opus` yield the same variant.
- **source** — one of:
  - `plain/local://{path}` — file below `AP_LOCAL_ROOT` (URL-escaped path)
  - `plain/s3://{bucket}/{key}` — S3 object (URL-escaped key)
  - `plain/{https-url}` — an `https://` source, URL-escaped; subject to an allowlist. `http://` is refused
  - `enc/{base64url(source)}` — encoded form, avoids escaping headaches

### Local sources

`local://{path}` names a path relative to `AP_LOCAL_ROOT`. The root is deployment configuration and does not participate in identity: the canonical source string is `local://{path}` with no root in it, so the same relative path is the same variant however a deployment mounted it, and variants survive a root move.

When `AP_LOCAL_ROOT` is unset, local sources are disabled — the root *is* the allowlist for disk, so nothing mounted means nothing served.

Confinement is over *paths*, and uniform. After the source has been decoded exactly once (never before — a check on a half-decoded string proves nothing), the path must be relative, must not climb out of the root with `..`, and must still resolve inside the root once every symlink on it has been followed. A path that fails any of these is refused, never normalized and retried. Every refusal is **404**, the same status as a missing file: §5 has no 403, and a distinct status would turn the root into an existence oracle for the filesystem around it.

Two things sit outside a path-based check, and both are deployment assumptions rather than gaps the proxy can close: a **hardlink** inside the root pointing at an inode outside it is indistinguishable from an ordinary file, and the window between resolving a path and ffmpeg opening it (**TOCTOU**) allows a file to be swapped for a symlink. Both require write access to the root. **Mount the root read-only and do not let untrusted code write into it.**

Paths are bounded before resolution: at most 64 components and 1024 bytes, refused as 404. The bound is a denial-of-service control — the confinement primitive is superlinear in component count.

Metadata comes from the filesystem: regular files only (a directory, FIFO or device is a 404, as is a missing file), size checked against `AP_MAX_SRC_BYTES` for the 413, and size-plus-mtime as the ETag material behind conditional requests on `/info`.

### Remote sources

`s3://{bucket}/{key}` names an object; both halves are required, and the key is kept as its raw decoded bytes, since that is what S3 stores. `https://{host}/{path}` names a URL. Bounds are the stores' own: 63 bytes of bucket and 1024 of key (S3's maxima), 2048 bytes of URL and 253 of host (the de-facto URL maximum and DNS's name limit).

The canonical string for an HTTPS source folds every second *spelling* of one resource — case, a trailing root dot, an explicit `:443`, an absent path (rendered `/`), an empty query, any fragment, and an IP literal's spelling (`[0:0:0:0:0:0:0:1]` → `[::1]`) — because each survivor would buy one object a second cache key. It preserves the URL's own percent-encoding and its dot segments, because only the origin knows whether `a%2Fb` and `a/b`, or `a/../b` and `b`, are the same object. IP literals fold through strict parsing only: the lenient parser reads `01.2.3.4` as 1.2.3.4, and folding that would let one allowlist entry admit two subjects.

`http://` and userinfo (`https://user:pass@…`) are refused at the grammar rather than left to the allowlist, which keeps the allowlist single-axis: host, and nothing else.

`AP_SOURCE_ALLOWLIST` gates both forms. An entry is an exact name, a trailing-`*` prefix glob for buckets, a leading-`*.` label-anchored suffix glob for hosts, or a bare `*`; a `*` anywhere else matches nothing. Buckets match case-sensitively and hosts fold case, as S3 and DNS respectively do; an IP-literal host is matched bracketless. **Unset accepts S3 sources and refuses HTTPS ones** — bucket credentials are already a gate, an outbound fetch has none. A source failing the allowlist is the same **404** as a missing one.

Example:

```
/aG1hYy.../f:opus/br:96/t:12.5:30/fade:0.5:1/plain/s3://masters/2026/piece-final.wav
```

→ a 30-second Opus preview at 96 kbps, starting at 12.5 s, with a 0.5 s fade-in and 1 s fade-out.

---

## 2. Resources & endpoints

| Endpoint | Purpose |
|---|---|
| `GET /{sig}/{options}/{source}` | Rendered audio variant (the core resource) |
| `GET /{sig}/info/{source}` | Probe metadata as JSON (no processing options) |
| `GET /{sig}/f:peaks/…/{source}` | Waveform peaks (a *format*, not a separate resource — see §3.3) |
| `GET /health` | Liveness/readiness (unsigned) |
| `GET /metrics` | Prometheus metrics (unsigned, bind-address-restricted) |
| `GET /hls/{sig}/{options}/{source}/index.m3u8` | **Reserved for v2** — segmented streaming |
| `GET /hls/{sig}/{options}/{source}/seg-{n}.m4s` | **Reserved for v2** |

No write endpoints in v1: variant write-back to S3 is a side effect of a GET render, not a client-facing API. Methods other than GET answer `404`, everywhere: the signed space is GET-only, and a `405` would confirm a route's shape without telling a client anything useful.

---

## 3. Processing options

### 3.1 Output format & encoding

| Option | Values | Notes |
|---|---|---|
| `f` | `mp3` `opus` `ogg` `aac` `m4a` `flac` `wav` `peaks` | `aac` = ADTS stream (streamable); `m4a` = fragmented MP4, cut on duration (`-movflags empty_moov+default_base_moof -frag_duration 1000000`) — `frag_keyframe` cuts at video keyframes, and audio has none, so it yields one fragment flushed at EOF; default `mp3` |
| `br` | integer, kbps | CBR/ABR bitrate for lossy formats |
| `q` | codec-specific number | VBR quality; mutually exclusive with `br`. The codec's own scale and range: mp3 0–9, ogg −1–10, aac/m4a 0.1–2, opus 0–10, flac 0–12 (the last two are `compression_level`). Out of range is a 422 — `f:flac/q:13` is rejected by ffmpeg itself |
| `sr` | Hz (`44100`, `48000`, …) | Resample; default: source rate, capped at 48 kHz for lossy |
| `ch` | `1` \| `2` | Downmix (defensible defaults: >2ch → 2) |
| `bd` | `16` \| `24` \| `32f` | Bit depth, lossless formats only; default: the source's depth, as `sr` defaults to its rate. `32f` is wav-only (flac encodes integers) |

### 3.2 Time-domain / preview

| Option | Values | Notes |
|---|---|---|
| `t` | `start[:duration]` seconds, decimals ok | Trim. `t:30` = from 30 s to end; `t:30:15` = 15 s from 30 s |
| `fade` | `in[:out]` seconds | Applied inside the trimmed region |
| `gain` | dB, signed | Static gain |
| `norm` | `ebu[:I[:TP[:LRA]]]` | Loudness normalization via `loudnorm`; default `-16:-1.5:11`. **Note:** proper two-pass loudnorm requires a full first pass — v1 does single-pass (good enough for previews), flag in docs |

### 3.3 Peaks (`f:peaks`)

| Option | Values | Notes |
|---|---|---|
| `pts` | integer | Number of min/max pairs (default 800) |
| `pk_fmt` | `json` \| `dat` | JSON or compact binary; both are [audiowaveform](https://github.com/bbc/audiowaveform)'s formats (default `json`) |
| `ch` | `1` \| `2` | **Default 1**, unlike every other format — peaks downmix rather than follow the source. `ch:2` gives per-channel pairs. The default is materialized into the cache key |

Peaks respect `t`, `ch` and `fade`, ignore encoding options. Cheap enough to render eagerly alongside any audio variant later, but v1 renders on request.

Both serializations carry the same numbers: `version` 2, `channels`, `sample_rate`, `samples_per_pixel`, `bits` (always 16), `length` (always exactly `pts`), and `length × 2 × channels` signed 16-bit values — a minimum and a maximum per pixel per channel, interleaved. `pk_fmt:json` is `application/json` with those field names; `pk_fmt:dat` is `application/octet-stream`, a little-endian header of version, flags, sample rate, samples-per-pixel, length and channel count, then the values as `int16`.

Peaks are a *format*, so they participate in the cache key, the write-back and the HIT redirect exactly as audio variants do.

### 3.4 Delivery

| Option | Values | Notes |
|---|---|---|
| `dl` | filename (URL-escaped) | Sets `Content-Disposition: attachment` |
| `cb` | opaque string | Cache-buster, participates in cache key |

---

## 4. `info` response

```json
{
  "format": "wav",
  "duration": 3612.44,
  "sample_rate": 96000,
  "channels": 4,
  "bit_depth": 24,
  "bitrate": 9216000,
  "size": 4161273856,
  "tags": { "title": "…", "artist": "…" }
}
```

Derived from `ffprobe -show_format -show_streams -select_streams a:0`, filtered to the fields above. `info` takes **no** processing options: any option segment alongside it is a `422`.

### 4.1 Field rules

The mapping is explicit rather than a passthrough, because ffprobe's output is verbose, version-dependent and inconsistent across containers while this object is none of those.

| Field | Source | Rule |
|---|---|---|
| `format` | `format.format_name`, refined by `stream.codec_name` | Whichever name in ffprobe's comma-separated list is a §3.1 token, so the `mov,mp4,m4a,3gp,3g2,mj2` family is `m4a` and Ogg is `opus` or `ogg` by codec. Membership, not the whole string: the list's contents and order are ffprobe's business and change between versions. A container §3.1 has no token for falls through to the first name (`matroska,webm` → `matroska`) — `format` describes the *source*, and a source may be in a container this proxy cannot emit |
| `duration` | `format.duration`, else `stream.duration` | Seconds, float |
| `sample_rate`, `channels` | the audio stream | Integers |
| `bit_depth` | `stream.bits_per_raw_sample`, else `stream.bits_per_sample` | Never `sample_fmt`: a lossy stream decodes to a float format and has no depth to report |
| `bitrate` | `format.bit_rate`, else `stream.bit_rate` | Integer, bits per second |
| `size` | the storage backend's `stat`, else `format.size` | The store is authoritative for the object |
| `tags` | `format.tags` | String-valued entries only, keys lowercased, capped in count and length. Arbitrary bytes from a file the operator may not control |

Each fallback is tried on the *extracted* value: ffprobe writes `"N/A"` rather than omitting a field it cannot answer, so taking the first key that is present would stop at the `"N/A"` and never reach the section that knows.

**A field ffprobe cannot answer is omitted, never `null` and never a zero standing in for "unknown".** `"bit_depth" in info` is therefore a true answer for every source. A source with no audio stream at all — a video-only MP4, a text file — is a `415`, not an object with everything missing.

### 4.2 Caching

`ETag` is `hash(canonical-source ‖ source ETag)`: it changes exactly when the object does, and `If-None-Match` is answered `304` after the source `stat` and before the probe, which is the expensive half.

`Cache-Control` is `public, max-age=3600` — **not** `immutable`, unlike a variant's. A variant's URL describes its bytes completely, so it can never become stale; `/info` describes a *mutable* source, and the same URL answers differently after a re-upload. `immutable` there would tell caches never to revalidate a document that has no other way of being corrected. An hour plus a cheap `304` is the aggressive caching this endpoint can honestly offer. A backend with no ETag material to give gets `public, max-age=60` and no validator, since nothing could correct it early.

A `HEAD` answers what the check chain determines — `401`, `404`, `413` and the caching headers — and stops there, so it never spawns a probe and therefore answers `200` where a `GET` would answer `415`. That is the same discipline `HEAD` follows on the render endpoint, for the same reason: diagnosing `415` *is* the work `HEAD` exists to skip.

### 4.3 Cost

`AP_MAX_SRC_BYTES` does **not** apply to `/info`, unlike every other signed request: a probe reads container headers and never decodes, so a source too large to *render* still costs a probe nothing to describe — and the client most in need of the endpoint is precisely the one holding a long source it means to ask a trimmed preview of.

A probe reads container headers and stops; it never decodes. It therefore does **not** take an `AP_MAX_CONCURRENCY` slot — that cap exists to bound encoders pinning cores, and queueing probes behind renders would make the endpoint a client calls *before* it knows what to request the slowest thing in the proxy. `AP_PROBE_TIMEOUT` is what bounds this path, and it is separate from and shorter than `AP_RENDER_TIMEOUT`.

---

## 5. Response semantics

### Cache MISS (first request for a variant)

- `200 OK`, `Transfer-Encoding: chunked`, no `Content-Length`, **no** `Accept-Ranges`.
- Bytes stream as the encoder produces them; simultaneously teed to the variant bucket (`s3://{variant-bucket}/{cache-key}`).
- Concurrent requests for the same cache key **coalesce**: one render, all clients subscribe to its chunk stream.
- Header: `X-Audio-Proxy: MISS` (or `COALESCED`).

### Cache HIT

Checked before coalescing and before the source is stat'd — a stored variant is immutable bytes that owe nothing to a source which may since have been deleted. Header: `X-Audio-Proxy: HIT`, in both modes.

**Redirect mode** (`AP_SERVE_MODE=redirect`, the default): `302` to a presigned URL for the variant object, valid for `AP_PRESIGN_TTL` seconds → S3/CDN serves `Accept-Ranges`, `206` and `Content-Length` natively and the proxy leaves the hot path. The redirect itself carries `Cache-Control: no-store`: its `Location` is a credential with an expiry, and a cached `302` hands out URLs that have already expired. The variant's own `Content-Type` and `Cache-Control` come from the store, which holds the ones the write-back saved — so a followed redirect delivers what a proxied HIT would have sent.

**Proxy mode** (`AP_SERVE_MODE=proxy`): the proxy serves the object itself — `200` with `Content-Length` and `Accept-Ranges: bytes`, relayed as it is read, so a declared length and progressive delivery are both true and the whole object is never resident. A `Range` is answered with `206` and `Content-Range`. A syntactically valid range no byte can satisfy is a `416` with `Content-Range: bytes */{size}` and `Cache-Control: no-store` — its body depends on a request header, and nothing here sends `Vary: Range`. Multi-range specs, non-`bytes` units and malformed values are ignored and answered with the whole variant, which RFC 9110 §14.2 permits; there is no `multipart/byteranges` response.

### Cache state changes the framing

The same URL is framed differently depending on what is cached, and clients must not assume one framing for a given URL:

| | MISS / COALESCED | HIT |
|---|---|---|
| Framing | `Transfer-Encoding: chunked` | `Content-Length` |
| `Accept-Ranges` | absent | `bytes` |
| `Range` | ignored | `206` / `416` |

Both begin delivering before the variant is complete or fully read. What a client observes is a property of the *cache state*, never of the configured backend or serve mode: the same signed URL against a `file://` deployment and an `s3://` one delivers the same bytes with the same `Content-Type`, `ETag` and `Cache-Control`, and is range-capable on a HIT either way. Backends differ in where the bytes come from, never in what a client must implement.

### Common headers

`Content-Type` per format · `Cache-Control: public, max-age=31536000, immutable, no-transform` (URL encodes the variant, so it *is* immutable; `no-transform` because the bytes are the product and must survive edge features that recompress or mangle bodies) · `ETag` = cache key, sent quoted, since RFC 9110 defines an entity-tag as a quoted-string and a bare token is not one.

### Edge-cache discipline

Every response, success or error, carries an explicit `Cache-Control` — no CDN negative-caching default ever decides retention:

- Errors: `404`/`413`/`415` → `max-age=10` (verdicts about the current source bytes; a re-upload changes them), `401`/`422` → `max-age=60` (pure functions of the URL; only a deploy changes them), `416`/`429`/`5xx` → `no-store` (transient, or — for `416` — dependent on a request header no `Vary` declares). The `502` row inherits that rather than inventing it, and the inheritance is the point: a store outage is exactly the failure that must not be cached, since the retry it suppresses is the one that would have worked. `/health` and the unmatched-route `404` state theirs too (`no-store` and `max-age=10`).
- **Conditional requests**: an `If-None-Match` matching the URL-derived `ETag` answers `304` with `ETag` and `Cache-Control`, no body, no render, no storage access. Placed after signature verification — never an existence oracle for unsigned probes.
- **HEAD** on signed endpoints answers the status and headers a `GET` would, through the full check chain including the source stat, with an empty body and no render subprocess. Errors as `GET`, bodiless. No `X-Audio-Proxy`: that header reports a render's outcome, and none ran. It deliberately does **not** consult the variant cache, so it reports the render path's framing even where a `GET` would answer a HIT's, or a `302`; making HEAD the one request whose answer depends on cache state would invite clients to build on exactly what the framing contract above tells them not to.
- **Range on a MISS is ignored**: the full `200` chunked stream, no `Accept-Ranges`, no `206`/`416` (RFC 9110 §14.2 permits ignoring `Range`). `206` semantics belong to cached variants — served by the proxy or by storage, per the serve mode.

### Errors (JSON body)

| Status | Meaning |
|---|---|
| `401` | Invalid/missing signature |
| `404` | Source not found / not readable |
| `413` | Source exceeds `AP_MAX_SRC_BYTES` |
| `415` | Source format not decodable |
| `416` | `Range` unsatisfiable against a cached variant (proxy mode only) |
| `422` | Invalid or conflicting options |
| `429` | No render slot: the wait queue was full, or this request waited in it longer than `AP_RENDER_TIMEOUT` without reaching the front (`Retry-After` set) |
| `500` | The render failed for a reason that is not the client's: no encoder, no space, a diagnostic the classifier does not recognise |
| `500` | The storage backend a source names is misconfigured: no credentials, or a store that answers a redirect because the configured region or endpoint is not the object's. No client action can resolve either |
| `502` | The storage backend could not be reached: a transport failure, or a `5xx` from the store itself |
| `504` | A render started and then exceeded `AP_RENDER_TIMEOUT` |

`/info` adds two rows of its own — `probe_failed` (`500`) and `probe_timeout` (`504`) — rather than reusing the render pair. The bodies name the limit an operator would raise, and `AP_RENDER_TIMEOUT` is not that limit for a probe; an error naming the wrong variable sends them to the wrong place.

Every other row is something the *client* got wrong, which is why `500` and `502` are worth stating rather than leaving to the adapter: a render can fail with none of them true, and answering a plausible `4xx` would tell a client to stop retrying something that might well work next time.

`502` is deliberately not the `404`. That row is blind on purpose, so no source failure can be used to probe what exists — but an outage is not a source failure. It says nothing about whether the object is there, and routing it into the `404` tells a client its object is gone when the store is merely unreachable: a deletion reported that did not happen, then cached for the ten seconds that row carries, suppressing the retry that would have worked. A store that answers `5xx` or does not answer at all is `502`; a store that says "no such object" — and one that refuses the credential, which stays indistinguishable from that by design — is the `404`.

`429` and `504` divide on whether a render ever ran, not on how long the client waited — both can take the full `AP_RENDER_TIMEOUT`. A request that spent that budget queued for a slot has nothing to report about a render, so it is told to come back, with the same `Retry-After` a full queue would have given it up front. `504` means a render held a slot and then went silent. Answering `504` for a wait would name a timeout that never happened, and would tell a client its variant is too expensive to encode when the truth is that the box is busy.

Mid-stream render failure after `200` is signaled by abnormal termination of the chunked stream (nothing better exists over plain HTTP; one more argument for HLS in v2).

---

## 6. Configuration (env)

| Var | Purpose |
|---|---|
| `AP_KEY`, `AP_SALT` | Hex-encoded HMAC key/salt; key must decode to ≥ 32 bytes (generate: `openssl rand -hex 32`) |
| `AP_ALLOW_INSECURE` | Accept unsigned URLs (dev only) |
| `AP_SOURCE_ALLOWLIST` | Comma-separated bucket/host patterns; unset accepts every bucket and refuses every host (§1) |
| `AP_LOCAL_ROOT` | Root directory for `local://` sources; unset = local sources disabled. Must exist at boot |
| `AP_VARIANT_STORE` | Variant store, scheme-tagged: `file:///path` or `s3://bucket` (S3 backend pending); unset = no cache, always render. `file://` must exist and be writable at boot |
| `AP_MAX_CONCURRENCY` | Max simultaneous ffmpeg processes (default: CPU count). Coalesced requests share one, so this counts renders and not requests |
| `AP_QUEUE_SIZE` | Requests that may wait for a slot before the next is answered `429` |
| `AP_MAX_SRC_BYTES`, `AP_RENDER_TIMEOUT` | Abuse limits |
| `AP_PROBE_TIMEOUT` | Seconds an `/info` probe may take before ffprobe is killed and the request answered `504` (default: 10). Separate from `AP_RENDER_TIMEOUT` because a probe reads headers rather than decoding — see §4.3 |
| `AP_SERVE_MODE` | `redirect` \| `proxy` |
| `AP_PRESIGN_TTL` | Seconds a HIT's presigned URL stays valid (default: 300); redirect mode only |
| `AP_LOG_LEVEL` | `debug` \| `info` \| `warning` \| `error` (default: `info`) |
| `AP_S3_ENDPOINT` | Origin URL of an S3-compatible store (`http://minio:9000`); unset = AWS proper. An origin and nothing else — a path, query, fragment or embedded credentials are refused at boot |
| `AP_S3_ADDRESSING` | `virtual` \| `path`: whether a request names its bucket in the host or in the path. Default: `virtual` with no `AP_S3_ENDPOINT`, `path` with one. Signed requests and presigned URLs always use the same style, since the host is inside the signature |
| `AP_S3_CA_BUNDLE` | PEM bundle to verify the store's certificate against, replacing the system trust store; a readable file at boot. There is no way to disable verification |

S3 credentials are the exception to the `AP_` rule and keep the standard AWS names — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and `AWS_REGION` (or `AWS_DEFAULT_REGION`) — validated as a group at boot: all of key, secret and region, or none. There is no IMDS or STS lookup, so credentials come from the environment or not at all.

Redirect serving is a *capability of the store's backend*: `redirect` answers a HIT with a 302 to a presigned variant URL, which only a backend that can presign (`s3://`) can produce. `AP_SERVE_MODE=redirect` against a store without that capability (`file://`) is refused at boot, with an error naming both variables — never per request.

---

## 7. Explicitly out of scope for v1

HLS/DASH output · two-pass loudness · multi-source stitching/concat · upload endpoints · per-client auth beyond URL signing · webhooks on render completion.
