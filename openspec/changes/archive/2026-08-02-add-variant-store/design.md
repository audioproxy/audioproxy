## Context

First half of the former 26-task `add-variant-cache` (split per the review-size convention). CLAUDE.md render policy: render at full speed into the write-back; clients lag the render — so the tee is just another coalescing subscriber, one that consumes eagerly and writes through a storage backend. The store mirrors the source layer's shape: a behaviour with `file://` shipped first and `s3://` added by the slice that owns the client.

## Goals / Non-Goals

**Goals:**
- Byte-exact, atomic-or-absent, metadata-carrying write-back; a store usable with no object storage in the deployment.

**Non-Goals:**
- Serving from the store (HIT lookup, Range/206, framing — the slimmed `add-variant-cache`).
- The S3 backend (`add-s3-client`, with a backend-parity suite there).
- Eviction/TTL — open question below.

## Decisions

- **`AP_VARIANT_STORE`, scheme-tagged, replaces `AP_VARIANT_BUCKET`.** One setting parsed like a source URL; the alternative (bucket + dir vars, mutually exclusive) makes the *combination* the valid thing. No alias: nothing is deployed, and one setting with two spellings is a worse legacy than a rename.
- **Behaviour mirrors `Source.Type` deliberately** — one shape to learn for pluggable storage in this codebase. `capabilities/0` is what lets serve-mode validation happen at boot instead of per-request.
- **Atomicity from rename-within-a-filesystem**: temp file *inside* the store directory (a cross-device rename is a copy, not atomic), `File.rename/2` on completion. The S3 analogue (multipart complete/abort) lands with that backend.
- **Metadata travels with the bytes** (`put_stream/3`): a store that keeps only bytes cannot serve a redirected fetch correctly — a player asked to decode `application/octet-stream` may refuse. Local backend: sidecar or xattr, chosen at implementation with a test against the store-direct fetch scenario.
- **Tee as coordinator subscriber** with the disconnect-policy amendment (tee counts as a subscriber; last-client-gone completes when a store is configured). This slice owns that policy change because the tee is what makes it meaningful.
- **Prefix fan-out for local keys** so one directory never accumulates every variant.

## Risks / Trade-offs

- [Tee keeps CPU busy for content nobody awaits] → bounded by output sizes and the backlog cap; the alternative (cancel + abort) wastes near-complete work. Escape hatch deferred until data says otherwise.
- [A store on a container's writable layer disappears with the container] → documentation: the store wants a volume (README task).
- [Two nodes with separate `file://` stores each render once] → accepted; a local store is a single-node choice. Shared caches use `s3://`. Stated so nobody files it as a bug.

## Open questions

- **Eviction and TTL.** An S3 store hands this to bucket lifecycle rules; a `file://` store grows until the disk fills. Plausible answers (size-capped LRU, age sweep, operator-managed) need usage data. Until decided, the docs must say plainly that a `file://` store is unbounded and the operator owns it.
