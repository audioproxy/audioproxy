# S3-compatible providers

The proxy talks to object storage over the S3 API, so it is not limited to AWS.
Point `AP_S3_ENDPOINT` at another provider and addressing defaults to
path-style (`endpoint/bucket/key`), which is what every provider below expects
except Tigris. With no endpoint set — AWS proper — the default is
virtual-hosted (`bucket.s3.region.amazonaws.com`). Either default can be
overridden with `AP_S3_ADDRESSING`.

This page collects working configurations. For what the variables mean, see
[S3 credentials](../README.md#s3-credentials) in the README.

## What is tested and what is not

**MinIO is the only store this project tests against.** The `:minio` suite runs
in CI and in the devcontainer, and it exercises the same code path most
providers here use: path-style addressing against a custom endpoint, SigV4
signing, multipart upload, ranged reads.

Everything on this page is derived from each provider's own documentation, not
from a test run against it.

**Virtual-hosted addressing is asserted, not exercised.** Neither Tigris nor
AWS is reachable from CI, and MinIO is reached by hostname and port, so
`bucket.minio` would need DNS nobody configured. The suite therefore pins the
virtual-hosted decision by inspecting the URL that would go on the wire — for a
signed request and for a presigned URL, checking that the two agree — rather
than by fetching anything. That catches a misconfigured addressing style
deterministically, and it is genuinely weaker than a round trip: it cannot tell
you the store accepts what we send. If you are deploying against Tigris or AWS,
verify it yourself with the borrowed suite below.

Two things that used to be listed here as limitations no longer are. Every part
of a multipart upload except the last is now exactly 5 MiB, which is what
Cloudflare R2 requires and every other store here already tolerated — R2 is
absent from this page because nobody has written a verified configuration for
it, not because of a known incompatibility. And a store behind a private
certificate authority can be reached over `https://` by pointing
`AP_S3_CA_BUNDLE` at a PEM bundle, which matters for self-hosted MinIO or Ceph;
every provider below uses publicly trusted certificates and needs nothing.

If you want certainty for your provider, you can borrow the suite. It takes an
endpoint from the environment, creates its own bucket, and cleans up after
itself:

```bash
AP_TEST_MINIO_ENDPOINT=https://s3.fr-par.scw.cloud mix test --only minio
```

It will need credentials in the environment too, and a couple of tests assume
the `minioadmin` fixture user, so expect to read the failures rather than
trust a clean pass. It is still the fastest way to find out whether a store
accepts what we send.

## Backblaze B2

The endpoint carries the region, and the region is the segment between `s3.`
and `.backblazeb2.com`. Both have to be set, and they have to agree.

```bash
AWS_ACCESS_KEY_ID=<application key ID>
AWS_SECRET_ACCESS_KEY=<application key>
AWS_REGION=us-west-004
AP_S3_ENDPOINT=https://s3.us-west-004.backblazeb2.com
AP_VARIANT_STORE=s3://my-variants/audio-proxy
```

Credentials are a B2 **application key**, not your account password: create one
in the B2 console and use the key ID as `AWS_ACCESS_KEY_ID`. A key scoped to a
single bucket is enough, and is what you want.

## DigitalOcean Spaces

The endpoint is the datacenter region plus `digitaloceanspaces.com`.

```bash
AWS_ACCESS_KEY_ID=<spaces access key>
AWS_SECRET_ACCESS_KEY=<spaces secret>
AWS_REGION=nyc3
AP_S3_ENDPOINT=https://nyc3.digitaloceanspaces.com
AP_VARIANT_STORE=s3://my-variants/audio-proxy
```

Available regions include `nyc3`, `ams3`, `sgp1`, `fra1`, `sfo3` and `syd1`.

If you see signature errors, try `AWS_REGION=us-east-1` while leaving
`AP_S3_ENDPOINT` alone. DigitalOcean's own SDK guidance uses `us-east-1` as a
validation-only region for several languages, and the request still goes to the
endpoint you configured. The region matters to us because it is part of the
SigV4 credential scope, so the value the store expects to verify against is the
one to use.

Spaces keys are created under **API → Spaces keys** in the control panel, and
are separate from DigitalOcean API tokens.

## Hetzner Object Storage

The endpoint is the location plus `your-objectstorage.com`.

```bash
AWS_ACCESS_KEY_ID=<access key>
AWS_SECRET_ACCESS_KEY=<secret key>
AWS_REGION=fsn1
AP_S3_ENDPOINT=https://fsn1.your-objectstorage.com
AP_VARIANT_STORE=s3://my-variants/audio-proxy
```

Locations are `fsn1` (Falkenstein), `nbg1` (Nuremberg) and `hel1` (Helsinki).
The location appears in **both** the endpoint and `AWS_REGION`, which reads as
redundant and is not: Hetzner's documentation is explicit that the region has
to be given in the URL as well as the region field.

A bucket's region cannot be changed after creation, so if you are unsure which
one a bucket is in, check the Hetzner Cloud Console under Object Storage rather
than guessing — a mismatched region fails as a signature error, which is not a
helpful thing to debug.

## Scaleway Object Storage

```bash
AWS_ACCESS_KEY_ID=<access key>
AWS_SECRET_ACCESS_KEY=<secret key>
AWS_REGION=fr-par
AP_S3_ENDPOINT=https://s3.fr-par.scw.cloud
AP_VARIANT_STORE=s3://my-variants/audio-proxy
```

Regions are `fr-par` (Paris), `nl-ams` (Amsterdam) and `pl-waw` (Warsaw).
Scaleway accepts both path-style and virtual-hosted addressing, so the
path-style default is fine and `AP_S3_ADDRESSING=virtual` also works.

## Tigris (Fly.io)

Tigris is the one provider here that **requires** virtual-hosted addressing:
buckets created after 19 February 2025 do not accept path-style at all, so
`AP_S3_ADDRESSING=virtual` is not optional.

```bash
AWS_ACCESS_KEY_ID=<tigris access key>
AWS_SECRET_ACCESS_KEY=<tigris secret>
AWS_REGION=auto
AP_S3_ENDPOINT=https://fly.storage.tigris.dev
AP_S3_ADDRESSING=virtual
AP_VARIANT_STORE=s3://my-variants/audio-proxy
```

`AWS_REGION=auto` is right rather than lazy: Tigris is globally distributed and
`auto` is the literal region string it expects in the SigV4 credential scope.

`fly storage create` writes its own variable names into the app's secrets, and
they do not all match ours. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_REGION` carry over unchanged; **`AWS_ENDPOINT_URL_S3` is the one to
rename** — the proxy reads `AP_S3_ENDPOINT`, and an endpoint left only in
`AWS_ENDPOINT_URL_S3` is not read by anything, which presents as requests going
to AWS with Tigris credentials.

Like every other provider on this page, this configuration is not exercised in
CI — see *What is tested and what is not* above for what the suite does pin.

## Serving cache hits

`AP_SERVE_MODE=redirect` (the default) works on all of these: a cache hit is a
`302` to a presigned URL, valid for `AP_PRESIGN_TTL` seconds, and the provider
serves the bytes and the Range requests. That is the mode worth using — the
proxy leaves the hot path entirely.

`AP_SERVE_MODE=proxy` also works and relays the bytes through the proxy. It
costs more round trips against every provider here, because there is no
in-memory streaming read in the S3 client and a read is assembled from
sequential ranged GETs. Use it when you cannot redirect clients to storage.

## Limitations worth knowing before you commit

**One endpoint for the whole deployment.** `AP_S3_ENDPOINT` is global, so
source objects and cached variants must live on the same provider. Reading
sources from AWS while caching variants to Hetzner is not expressible today.

**One addressing style for the whole deployment.** `AP_S3_ADDRESSING` is
global, so sources and variants are addressed the same way. Since the endpoint
is global too, this only matters if a single store wants different styles for
different buckets, which none of these do.

**Incomplete multipart uploads.** The proxy aborts an upload on every failure
path it can see, but not on a hard kill of the VM. Set a lifecycle rule
expiring incomplete multipart uploads; every provider here supports one, and
without it an interrupted render can leave parts that are billed and invisible
in a bucket listing.

## Sources

- [Backblaze: Introduction to the S3-Compatible API](https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api)
- [Backblaze: Use the AWS CLI with B2](https://www.backblaze.com/docs/cloud-storage-use-the-aws-cli-with-backblaze-b2)
- [DigitalOcean: Use Spaces with AWS S3 SDKs](https://docs.digitalocean.com/products/spaces/reference/aws-sdks/)
- [Hetzner: Using S3 compatible CLI tools](https://docs.hetzner.com/storage/object-storage/getting-started/using-s3-api-tools/)
- [Scaleway: Object Storage concepts](https://www.scaleway.com/en/docs/object-storage/concepts/)
