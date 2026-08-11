# Add Azure Blob Client

## Why

Azure Blob Storage has no S3 compatibility — it speaks its own REST dialect with its own auth — so unlike GCS it cannot ride the existing client under a different profile. It also has no maintained Elixir SDK to lean on, which makes the dependency policy's answer and the ecosystem's the same: build a small client ourselves. The hand-rolled-S3 trap that `add-s3-client` escaped does not apply here, because Azure's presigning primitive (the shared access signature) is one HMAC-SHA256 over a string-to-sign — computed locally, no token exchange, no request canonicalization — and every operation the proxy needs can be performed against a SAS URL with plain HTTP. One signing routine, `:crypto` and `:httpc`, zero new packages.

This mirrors the S3 decomposition deliberately: client first (`add-s3-client`), then source backend, then variant store — each its own reviewable slice.

## What Changes

- `AudioProxy.Azure`: a facade mirroring `AudioProxy.S3`'s surface — `head/2`, `presign_get/3`, `put_stream/4`, `delete/2`, `get_stream/3`, `configured?/0` — over container/blob instead of bucket/key. All operations authenticate by minting a service SAS and issuing vanilla `:httpc` requests against it; `presign_get/3` returns the SAS URL itself. Writes use Put Block + Put Block List (block blobs), so `put_stream/4` streams chunks as they arrive; Azure has no minimum block size, so no S3-style 5 MiB re-grouping is required (grouping tiny chunks remains an implementation freedom, bounded by the 50,000-block limit).
- A group-atomic `AP_AZURE_*` config group: `AP_AZURE_ACCOUNT` + `AP_AZURE_KEY` (the base64 account key, both-or-neither), optional `AP_AZURE_ENDPOINT` (default `https://<account>.blob.core.windows.net`; overridable for Azurite and sovereign clouds — Azurite addresses path-style with the account in the path, and the client must handle both forms).
- An error vocabulary of our own atoms mapped from HTTP statuses, mirroring `AudioProxy.S3`'s discipline: `:not_found` and `:access_denied` distinct, `{:http, status, _}` for the unbounded rest, no catch-all in consumers.
- Metadata round-trip via `x-ms-meta-*`; content type and cache control set at commit time through Put Block List's blob-property headers.
- CI: Azurite (Microsoft's official emulator) joins the suite the way MinIO did, behind its own tag.

## Non-goals

- **Entra ID / managed identity / user-delegation SAS** — needs an OAuth token flow and is the Azure analog of GCS native auth; deferred by name as `add-azure-entra-auth`, proposed when a key-prohibiting deployment appears.
- Anything above block blobs (append/page blobs, tiers, immutability policies).

## Capabilities

### New Capabilities

- `azure-access`: a minimal Azure Blob client — SAS minting, HEAD/GET/streaming PUT/DELETE over block blobs — with group-atomic configuration and typed errors.

### Modified Capabilities

<!-- none -->

## Impact

- New: `AudioProxy.Azure` (+ a private SAS module), `AP_AZURE_*` in `AudioProxy.Config`, Azurite service in CI and the devcontainer compose file, README configuration rows.
- No consumer yet: this slice lands the client and its tests only; `add-azure-source-backend` and `add-azure-variant-store` wire it in and are proposed alongside.
- Estimated ~400 LOC including tests — at the slice budget, which is why source and store are not in here.
- Position: parked with trigger — first deployment on Azure. The three Azure slices move together when the trigger fires.
