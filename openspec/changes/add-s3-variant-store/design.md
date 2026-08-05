## Context

The seam is already the right shape: `AudioProxy.VariantStore` declares `head/1`, `get_stream/2`, `put_stream/3`, the optional `presign/2`, and `capabilities/0`, and `AudioProxy.S3` answers each of them almost one-to-one. The interesting work is not the mapping, it is the two places where an object store behaves unlike a filesystem, and the fact that nothing currently proves the two backends agree.

`Local` gets its atomicity from `File.rename/2` within one filesystem, and stores metadata in a `.meta` sidecar with the data file as the commit point. Neither mechanism exists in S3: there is no rename, and there is no need for a sidecar because an object carries its own `Content-Type`, `Cache-Control` and `x-amz-meta-*`.

## Goals / Non-Goals

**Goals:**
- A variant cache that outlives the container and is shared by every node.
- `AP_SERVE_MODE=redirect` reachable, since it is the documented default.
- Parity between backends proved by one suite rather than asserted in prose.

**Non-Goals:**
- Lifecycle/expiry policy on the bucket. Retention is `split-retention-cap`'s subject, and S3's own lifecycle rules are the operator's to configure.
- Multipart tuning. `add-s3-client` settled part sizing and the abort-on-failure discipline; this slice consumes it.
- Cross-region or multi-bucket stores.

## Decisions

**A PUT is its own commit point, so there is no staging.** `Local` stages under `<root>/tmp` because a partially written file is readable; an S3 object does not exist until the upload completes, and a failed multipart is aborted rather than left visible (`add-s3-client` guarantees that). Reproducing the staging dance would add a copy for nothing. The consequence worth stating: `Local`'s sidecar-then-data ordering has no analogue here, and neither does its boot-time sweep of `tmp/`.

**Metadata rides on the object, not beside it.** `Content-Type` and `Cache-Control` map to the real headers — which is what makes a redirect work at all, since the client fetches the object directly and must receive the same headers a proxied HIT would have sent. Anything else in `metadata()` goes to `x-amz-meta-*`. `head/1` reads them back off the HEAD response. This is why the seam carries `metadata` as a map rather than an opaque blob.

**`capabilities/0` is `[:presign]`, and `presign/2` uses `AP_PRESIGN_TTL`.** That is the whole reason redirect mode exists, and the boot-time check in `Config.validate!/1` already reads this list — so declaring the capability is what makes the mode reachable, with no change to the validator.

**Boot-time validation mirrors `file://`'s, by the operation it needs.** The `file://` branch proves writability by writing a probe file under `<root>/tmp` rather than by inspecting mode bits, because mode bits say nothing about a read-only mount. The same reasoning applies harder to a bucket, where reachability, credentials, region and policy can each be wrong: probe with a small PUT and DELETE under a reserved key prefix, at boot, so a misconfigured deployment fails immediately instead of rendering every variant twice and silently discarding the write-back.

Alternative considered: probe with a HEAD on a nonexistent key, which proves credentials and reachability without writing. Rejected — it does not prove *write* permission, which is the one thing a variant store must have, and a bucket that accepts reads and refuses writes is a plausible misconfiguration rather than an exotic one.

**A write failure stays a warning, not a request failure.** `VariantStore.Tee` already treats the write-back as best-effort and emits `[:audio_proxy, :variant_store, :write_failure]`; a client receiving a correct render must not be failed because the cache could not keep it. This slice changes nothing there, and the parity suite asserts it for both backends.

**Parity is one suite, parameterised by backend.** The assertions live once and run twice — round-tripping bytes and metadata, ranged reads, a miss on an absent key, and the write-failure path. A backend that answers the seam differently is then a failing test rather than a surprise in production. `Local`'s existing tests keep their backend-specific cases (the `tmp/` sweep, the sidecar) since those are mechanisms, not contract.

## Risks / Trade-offs

- **[MinIO is not S3.]** → It is what `add-s3-client` already tests against and it is honest about the operations used here; `docs/s3-providers.md` records the provider differences that matter. Real-S3 verification stays a release-time manual step.
- **[A boot probe writes to the operator's bucket.]** → One small object under a reserved prefix, deleted immediately, exactly as the `file://` branch does. Documented, and the alternative — discovering at first render that write-back has silently failed for hours — is worse.
- **[Redirect mode becomes reachable and is barely exercised.]** → Which is precisely why the 302 path gets its first end-to-end test here. Its `no-store` and its `Location` expiry are already specified in §5; this slice is the first time anything runs them.
- **[`head/1` costs a round trip per HIT check.]** → Inherent to the mode, and cheaper than the render it avoids.

## Open Questions

- Whether an upstream 5xx from the *store* should surface as `add-s3-source-backend`'s 502 or stay invisible. It splits by path: on a HIT lookup the honest answer is to treat it as a miss and render, since the render still produces correct bytes; in proxy mode mid-stream there is no status left to send. Resolve with the tests in front of us rather than here.
