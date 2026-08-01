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
  - `plain/{https-url}` — arbitrary HTTP(S) source, URL-escaped; subject to an allowlist
  - `enc/{base64url(source)}` — encoded form, avoids escaping headaches

### Local sources

`local://{path}` names a path relative to `AP_LOCAL_ROOT`. The root is deployment configuration and does not participate in identity: the canonical source string is `local://{path}` with no root in it, so the same relative path is the same variant however a deployment mounted it, and variants survive a root move.

When `AP_LOCAL_ROOT` is unset, local sources are disabled — the root *is* the allowlist for disk, so nothing mounted means nothing served.

Confinement is over *paths*, and uniform. After the source has been decoded exactly once (never before — a check on a half-decoded string proves nothing), the path must be relative, must not climb out of the root with `..`, and must still resolve inside the root once every symlink on it has been followed. A path that fails any of these is refused, never normalized and retried. Every refusal is **404**, the same status as a missing file: §5 has no 403, and a distinct status would turn the root into an existence oracle for the filesystem around it.

Two things sit outside a path-based check, and both are deployment assumptions rather than gaps the proxy can close: a **hardlink** inside the root pointing at an inode outside it is indistinguishable from an ordinary file, and the window between resolving a path and ffmpeg opening it (**TOCTOU**) allows a file to be swapped for a symlink. Both require write access to the root. **Mount the root read-only and do not let untrusted code write into it.**

Paths are bounded before resolution: at most 64 components and 1024 bytes, refused as 404. The bound is a denial-of-service control — the confinement primitive is superlinear in component count.

Metadata comes from the filesystem: regular files only (a directory, FIFO or device is a 404, as is a missing file), size checked against `AP_MAX_SRC_BYTES` for the 413, and size-plus-mtime as the ETag material behind conditional requests on `/info`.

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
| `pk_fmt` | `json` \| `dat` | JSON (audiowaveform-compatible-ish) or compact binary |

Peaks respect `t` and `ch`, ignore encoding options. Cheap enough to render eagerly alongside any audio variant later, but v1 renders on request.

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

Straight mapping of `ffprobe -show_format -show_streams`, filtered. Cached aggressively (immutable per source ETag).

---

## 5. Response semantics

### Cache MISS (first request for a variant)

- `200 OK`, `Transfer-Encoding: chunked`, no `Content-Length`, **no** `Accept-Ranges`.
- Bytes stream as the encoder produces them; simultaneously teed to the variant bucket (`s3://{variant-bucket}/{cache-key}`).
- Concurrent requests for the same cache key **coalesce**: one render, all clients subscribe to its chunk stream.
- Header: `X-Audio-Proxy: MISS` (or `COALESCED`).

### Cache HIT

- Default: `302` redirect to a short-lived presigned URL for the variant object → S3/CDN serves `Accept-Ranges`, `206`, `Content-Length` natively and the proxy leaves the hot path.
- Optional proxied mode (`AP_SERVE_MODE=proxy`): proxy serves the object itself with full Range support.
- Header: `X-Audio-Proxy: HIT`.

### Common headers

`Content-Type` per format · `Cache-Control: public, max-age=31536000, immutable` (URL encodes the variant, so it *is* immutable) · `ETag` = cache key.

### Errors (JSON body)

| Status | Meaning |
|---|---|
| `401` | Invalid/missing signature |
| `404` | Source not found / not readable |
| `413` | Source exceeds `AP_MAX_SRC_BYTES` |
| `415` | Source format not decodable |
| `422` | Invalid or conflicting options |
| `429` | Render queue full (`Retry-After` set) |
| `500` | The render failed for a reason that is not the client's: no encoder, no space, a diagnostic the classifier does not recognise |
| `504` | Render exceeded `AP_RENDER_TIMEOUT` |

Every other row is something the *client* got wrong, which is why `500` is worth stating rather than leaving to the adapter: a render can fail with none of them true, and answering a plausible `4xx` would tell a client to stop retrying something that might well work next time.

Mid-stream render failure after `200` is signaled by abnormal termination of the chunked stream (nothing better exists over plain HTTP; one more argument for HLS in v2).

---

## 6. Configuration (env)

| Var | Purpose |
|---|---|
| `AP_KEY`, `AP_SALT` | Hex-encoded HMAC key/salt; key must decode to ≥ 32 bytes (generate: `openssl rand -hex 32`) |
| `AP_ALLOW_INSECURE` | Accept unsigned URLs (dev only) |
| `AP_SOURCE_ALLOWLIST` | Comma-separated bucket/host patterns |
| `AP_LOCAL_ROOT` | Root directory for `local://` sources; unset = local sources disabled. Must exist at boot |
| `AP_VARIANT_BUCKET` | Write-back target; unset = no cache, always render |
| `AP_MAX_CONCURRENCY` | Max simultaneous ffmpeg processes (default: CPU count) |
| `AP_QUEUE_SIZE` | Waiting renders before `429` |
| `AP_MAX_SRC_BYTES`, `AP_RENDER_TIMEOUT` | Abuse limits |
| `AP_SERVE_MODE` | `redirect` \| `proxy` |

---

## 7. Explicitly out of scope for v1

HLS/DASH output · two-pass loudness · multi-source stitching/concat · upload endpoints · per-client auth beyond URL signing · webhooks on render completion.
