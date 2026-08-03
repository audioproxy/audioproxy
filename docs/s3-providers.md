# S3-compatible providers

The proxy talks to object storage over the S3 API, so it is not limited to AWS.
Point `AP_S3_ENDPOINT` at another provider and addressing switches from
virtual-hosted (`bucket.s3.region.amazonaws.com`) to path-style
(`endpoint/bucket/key`), which is what every provider below expects.

This page collects working configurations. For what the variables mean, see
[S3 credentials](../README.md#s3-credentials) in the README.

## What is tested and what is not

**MinIO is the only store this project tests against.** The `:minio` suite runs
in CI and in the devcontainer, and it exercises the same code path every
provider here uses: path-style addressing against a custom endpoint, SigV4
signing, multipart upload, ranged reads.

Everything on this page is derived from each provider's own documentation, not
from a test run against it. AWS itself is in the same position — expected to
work, never exercised, because the virtual-hosted branch has no test.

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
path-style we send is fine.

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

**No custom CA bundle.** TLS verification uses the system trust store, so a
self-hosted store behind a private CA cannot be reached over `https://`. Every
provider on this page uses publicly trusted certificates, so this only bites
self-hosted MinIO or Ceph.

**Multipart part sizes vary.** Parts are at least 5 MiB but not all exactly
equal, because they are grouped from a live render's chunks rather than from a
file of known length. Every provider here accepts that. **Cloudflare R2 does
not** — it requires all parts except the last to be the same size — which is
why R2 is absent from this page.

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
