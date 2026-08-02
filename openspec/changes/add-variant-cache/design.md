## Context

CLAUDE.md render policy: render at full speed into the write-back; clients lag the render. The tee is therefore just another coalescing subscriber, one that consumes eagerly and writes through a storage backend.

The cache and the source layer are independent. Sources already resolve through a behaviour with `local://` shipped and `s3://` planned; the variant store now has the same shape, for the same reason. A deployment can render from disk and cache to disk, render from S3 and cache to S3, or mix.

## Goals / Non-Goals

**Goals:**
- Byte-exact write-back, atomic-or-absent variants, HIT paths in both serve modes, across both backends.
- The cache is usable with no object storage in the deployment.

**Non-Goals:**
- Eager peaks alongside variants (noted as future work in API doc §3.3).
- Cache eviction and TTL — see *Open questions*. This was previously a non-goal on the grounds that bucket lifecycle rules are the operator's tool. That reasoning does not survive a `file://` backend, so it is now an open question rather than a settled exclusion.

## Decisions

- **`AP_VARIANT_STORE`, scheme-tagged, replaces `AP_VARIANT_BUCKET`.** One setting, parsed like a source URL: `file:///var/cache/audio_proxy` or `s3://bucket`. The alternative (`AP_VARIANT_BUCKET` plus a new `AP_VARIANT_DIR`, mutually exclusive) needs a rule for what two set values mean and produces a config surface where the *combination* is what is valid. The old name is not kept as an alias: nothing is deployed on it, and one setting with two spellings is a worse legacy than a rename.
- **`VariantStore` behaviour**: `head/1`, `get_stream/2` (Range-aware), `put_stream/2`, `presign/2`, `capabilities/0`. Mirrors the source-type behaviour deliberately, so there is one shape to learn for pluggable storage in this codebase.
- **Atomicity per backend, same guarantee.** S3 gets it from multipart upload: parts only become an object on `CompleteMultipartUpload`, abort on error or cancel. Local gets it from writing to a temp file within the store and `File.rename/2` on completion — atomic within a filesystem, which is why the temp file lives *inside* the store rather than in `/tmp` (a cross-device rename is a copy, and not atomic). Neither backend can leave a partial variant readable.
- **Serve mode is a backend capability, checked at boot.** `redirect` requires `presign/2`; a `file://` store does not have it. `AP_SERVE_MODE=redirect` with a local store aborts startup with a message naming both settings, consistent with how every other unusable `AP_` value behaves. A local store therefore implies proxy-mode serving, and proxy mode is what makes `Range` work without a CDN in front.
- **Client-disconnect policy changes with cache on**: the tee counts as a subscriber, so last-*client*-gone no longer cancels the render — it completes into the store (a disconnecting client usually retries; next time it is a HIT). With cache off, prior behaviour (cancel) stands. This amends the coalescing slice's "last subscriber" rule naturally: the tee *is* a subscriber.
- **HIT check placement**: `head/1` after options/source resolution, before semaphore and coalescing. In-flight renders are still coalesced (registry checked after cache miss), so the order is cache → registry → new render.
- **The 302 response carries `Cache-Control: no-store`** — its Location is a credential with a 300 s lifetime; any cache tier holding the redirect serves expired presigned URLs. (The immutable policy belongs to the variant bytes, never to the redirect that points at them.)
- **Presigned HIT URL TTL** short (default 300 s), S3 backend only. The 302 target is per-request; long-lived caching belongs to the immutable variant URL itself, which CDNs cache by our `Cache-Control` headers.
- **Proxy mode** streams `get_stream/2` (with the request Range forwarded verbatim) through `chunk/2`, passing `Content-Length`/`Content-Range`/206 through without local buffering. The local backend serves this from the file; no `X-Sendfile`-style handoff, since that assumes a reverse proxy this project does not require.

## Risks / Trade-offs

- [HEAD-then-render race: two nodes or timing could double-render] → harmless. Deterministic argv means identical bytes, so S3 multipart-complete is last-write-wins with the same content, and a local rename replaces one identical file with another.
- [Tee keeps CPU busy for content nobody awaits] → bounded by preview-sized outputs; the alternative (cancel plus partial-abort) wastes near-complete work instead. Config escape hatch deferred until real-world data says otherwise.
- [A local store on a container's writable layer disappears with the container] → documentation problem, not a design one: the store wants a volume. Called out in the README when this lands.
- [Two nodes with separate `file://` stores each render once] → accepted. A local store is a single-node choice by definition; operators wanting a shared cache use `s3://`. Worth stating so nobody discovers it as a bug.

## Open questions

- **Redirect mode routes media bytes around a CDN.** Behind a CDN, proxy mode is the collaborating mode (the edge caches actual audio); redirect mode's edge caches only a 302 it must not cache, and every client fetches the store directly. The missing flavor: redirect to a *stable, CDN-fronted public base URL* over the store (`https://variants.example/{cache-key}`) instead of a presigned URL — cacheable Location, store behind its own CDN hostname. Plausibly a store capability (`public_url/1`) plus an `AP_VARIANT_PUBLIC_BASE` setting. Needs a deployment that wants it before it earns a slice.
- **Eviction and TTL.** Deferred deliberately, not overlooked. An S3 store hands this to bucket lifecycle rules; a `file://` store grows until the disk fills, and "the operator's tool" is then a cron job they have to write. The plausible answers are a size cap with LRU eviction, an age-based sweep, or an explicit statement that the operator manages the directory. Choosing needs usage data this project does not have yet, and choosing wrong builds a background sweeper nobody needed. **Until it is decided, the docs must say plainly that a `file://` store is unbounded and the operator is responsible for it** — an unbounded cache discovered at 3am is worse than a documented one.
