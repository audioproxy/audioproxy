## Context

imgproxy's `local://` source pattern, adapted: one configured root, URL paths relative to it. The driver is sequencing — S3 out of the MVP chain — so the design's job is making the later S3 arrival a pure addition (one new backend behind an existing seam), not a rewiring.

## Goals / Non-Goals

**Goals:**
- MVP renders from disk with zero S3/HTTP-client code; watertight root confinement.
- The storage seam that lets `add-s3-client` land without touching render/info flows.

**Non-Goals:**
- Multiple roots or per-root allowlisting (one root; the deployment mounts what it wants served).
- Watching/uploading local files (read-only source, like every other source type).
- Replacing S3 permanently — the variant cache still requires S3; local is a source type, not a cache backend.

## Decisions

- **`Path.safe_relative/2` as the confinement primitive** (stdlib, purpose-built: rejects `..` escapes and absolute paths) after exactly-once percent-decoding, followed by a symlink check (`File.lstat` walk or `realpath` prefix assertion) — belt and braces because `safe_relative` does not resolve symlinks. Reject, never normalize-and-continue.
- **Canonical identity excludes the root** (`local://relative/path`): cache keys survive redeployments and root moves; two proxies with different mount points agree on variant identity.
- **Storage seam shape**: the `stat/1` and `ffmpeg_input/1` callbacks of `AudioProxy.Source.Type`, declared by `add-source-resolver`. `stat/1` → `{:ok, %{size, mtime-ish etag-material}} | {:error, :not_found}`; `ffmpeg_input/1` → the resolved absolute path. This slice implements them for local sources only; S3 and HTTPS backends arrive with their own slices behind the same contract.
- **ETag material for local sources** = size + mtime hash (the S3 backend will use the object ETag) — feeds the info endpoint's conditional-request story unchanged.
- **ffmpeg gets the absolute resolved path** as its input argument; with `add-audio-only-policy`, the protocol whitelist for local invocations is `file` (per-source-type whitelist — amended there).
- **404 for every confinement/authorization failure** — same no-oracle policy as bucket/host allowlists.

## Risks / Trade-offs

- [Local paths bypass the allowlist mechanism entirely] → intended: `AP_LOCAL_ROOT` *is* the allowlist for disk (nothing mounted, nothing served); spec'd as disabled-when-unset.
- [Symlink handling varies by deployment (bind mounts, container FS)] → resolve-then-prefix-check on the final path is the invariant the property test pins; deployments that want symlinked layouts can point the root at the resolved location.
- [Seam without a second backend risks being wrong for S3] → its two functions are exactly the two things render/info already needed from S3 (HEAD, presign) in the original design — the seam is extracted from, not invented ahead of, the S3 requirements.
