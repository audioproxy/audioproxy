## Context

`AudioProxy.S3` sends every request path-style (`endpoint/bucket/key`), and that was never chosen — it is `ex_aws`'s default. `ExAws.Operation.S3.add_bucket_to_path/2` has three clauses; the two that produce `bucket.host` both require `virtual_host: true` in the config map, and the fallback puts the bucket in the path. Nothing in `add-s3-client` sets the flag.

Two consequences, one immediate and one latent:

- **Tigris is unreachable.** It requires virtual-hosted addressing for buckets created after 19 February 2025 and is withdrawing path-style for new buckets. A client deployment on Fly.io needs it.
- **AWS is probably broken for modern buckets.** AWS deprecated path-style, and regions launched after 2019 never supported it. The no-endpoint path has no test, so this has never been observed either way.

The claim in `AudioProxy.S3`'s moduledoc, the README and `docs/s3-providers.md` — virtual-hosted for AWS, path-style for custom endpoints — describes the intent of `add-s3-client` and not its behaviour.

Constraint that shapes everything below: **neither Tigris nor AWS is reachable from CI.** MinIO is the only store this project can test against, and MinIO is happy with path-style, which is exactly the configuration that already works. So the new behaviour cannot be verified end-to-end by the suite that exists.

## Goals / Non-Goals

**Goals:**

- Make addressing a configured choice, with a default that keeps every currently working deployment working.
- Get it right in both places `ex_aws` reads it, since they read it from different sources.
- Make the addressing decision assertable without a live non-MinIO store.
- Remove two adjacent portability blockers already documented as limitations: variable multipart part sizes, and no way to trust a private CA.
- Leave the documentation true.

**Non-Goals:**

- Per-bucket or per-operation addressing. One deployment, one choice.
- Separate endpoints for sources and variants. That is a real limitation and a different change.
- IMDS or any credential provider chain.
- Verifying Tigris or AWS in CI. Not possible; the mitigation is unit-level assertions plus a documented manual check.

## Decisions

### `AP_S3_ADDRESSING`, defaulting on whether an endpoint is set

`path` or `virtual`. Default: `virtual` when `AP_S3_ENDPOINT` is unset, `path` when it is set.

The asymmetry is deliberate and is the whole point of the default. Unset endpoint means AWS, where virtual-hosted is what works now. A set endpoint means an S3-compatible store, and the ones this project documents — MinIO, Ceph, B2, DigitalOcean, Scaleway, Hetzner — are all working today on path-style. Defaulting a custom endpoint to `virtual` would break every existing deployment to fix one that does not exist yet.

Alternatives considered:

- **Always default to `virtual`**, matching where the industry is going. Rejected: it is a silent breaking change for every current operator, and path-style stores are not going away (MinIO and Ceph are the self-hosting default).
- **Sniff the endpoint hostname** and switch on `fly.storage.tigris.dev`. Rejected as magic that fails opaquely for the next store, and unmaintainable — a hostname allowlist is exactly what we refused to own for AWS partitions.
- **A boolean `AP_S3_VIRTUAL_HOST`.** Rejected: booleans with a context-dependent default read badly in a config table, and an enum leaves room for a third style if one appears.

### Thread it into both call sites, and pin that they agree

The request path reads `virtual_host` from the **config map**; `ExAws.S3.presigned_url/5` reads `:virtual_host` from its **options**. They are separate code paths in the dependency.

This is the sharpest failure mode in the change. Set the config and not the presign options and requests go to `bucket.host` while presigned URLs go to `host/bucket`. The host is inside the SigV4 signature, so the URL is not merely wrong, it is unverifiable — and it would pass every test that only checks writes, because writes go through the request path. A test that asserts both forms agree is therefore not optional.

### Assert on the built URL, not only on round trips

Because CI cannot reach a virtual-hosted store, the addressing decision is pinned by inspecting what gets built:

- `AudioProxy.S3.config/0` carries `virtual_host: true` exactly when configured to.
- A presigned URL's host is `bucket.endpoint-host` under `virtual`, and `endpoint-host` with the bucket leading the path under `path`.

Presigning is a pure local computation, so this is cheap and deterministic — no store required. It is weaker evidence than a real fetch, and the honest mitigation is to say so in the docs and give operators the one command that checks their own store.

### Exact-size parts by splitting at the boundary

`into_parts/1` accumulates until the buffer *reaches* 5 MiB and then flushes whatever it has, so a part is "at least 5 MiB" and its exact size depends on where chunk boundaries fall. Cloudflare R2 requires every part but the last to be identical in size.

Change it to emit exactly `@part_size` bytes per part, carrying the remainder of a straddling chunk forward. The last part keeps whatever is left, which every store permits.

Alternative: leave it and document R2 as unsupported, which is the status quo. Rejected because the fix is small, the current behaviour has no upside, and equal-size parts are strictly more compatible.

### `AP_S3_CA_BUNDLE` as a path to a PEM file

`ssl_options/1` hardcodes `:public_key.cacerts_get()`. When set, use `cacertfile:` instead, validated at boot as a readable file — the same posture as `AP_LOCAL_ROOT`, so a bad path fails at startup rather than on the first upload.

Deliberately not offering `verify: :verify_none`. An operator who wants to skip verification can already use `http://`, and a flag that turns off certificate checking is the kind of thing that ends up set in production because it made a staging error go away.

## Risks / Trade-offs

- [The new addressing path cannot be verified against a real store in CI] → Unit-level assertions on the built URL for both call sites, plus a documented `AP_TEST_MINIO_ENDPOINT` run operators can point at their own store. Accept that "Tigris works" will rest on one manual verification against the client's actual bucket, and say so in `docs/s3-providers.md` rather than implying coverage.

- [Changing the AWS default from path-style to virtual-hosted alters behaviour for existing AWS deployments] → It is a fix, not a regression: path-style is deprecated and unsupported in newer regions. But it is still a behaviour change on a path with no test coverage, so it belongs in the changelog, and `AP_S3_ADDRESSING=path` is the escape hatch for anyone relying on an old bucket.

- [Exact-size parts add a split-and-carry step to a hot loop] → One extra `binary_part/3` per straddling chunk, against a network write of 5 MiB. Bounded memory is unchanged: one part plus one chunk.

- [Two more configuration variables on a surface that is already large] → Both are optional, both default to today's behaviour, and both replace an entry in `docs/s3-providers.md`'s limitations list. Net documentation shrinks.

- [`cacertfile:` and `cacerts:` are mutually exclusive in `:ssl`] → Pass one or the other, never both, and cover the default path in a test so the common case cannot regress while the new one is being added.

## Migration Plan

No data migration; configuration only. Rollout is a deploy.

- Existing MinIO, Ceph, B2, DigitalOcean, Scaleway and Hetzner deployments: no change required, defaults preserve current behaviour.
- Existing AWS deployments: addressing switches to virtual-hosted. If a pre-2020 bucket depends on path-style, set `AP_S3_ADDRESSING=path`.
- Tigris: set `AP_S3_ADDRESSING=virtual` alongside `AP_S3_ENDPOINT=https://fly.storage.tigris.dev` and `AWS_REGION=auto`.

Rollback is reverting the variable, since the old behaviour is `AP_S3_ADDRESSING=path`.

## Open Questions

- **Does Tigris require anything else we do not send?** Addressing is the known blocker; whether its multipart or metadata handling holds any further surprises is unverified. The client deployment is the first real test, and the exact-size parts in this change remove the most likely second problem.
- **Should `AP_S3_ADDRESSING=path` against AWS warn at boot?** It is a deprecated configuration that will eventually stop working. A warning is friendly; it is also noise for the operator who set it deliberately. Leaning toward no warning and a note in the README.
- **Does any documented provider need virtual-hosted sooner than we think?** Scaleway already accepts both. If several move, the default for a custom endpoint should flip, which is a follow-up rather than something to pre-empt here.
