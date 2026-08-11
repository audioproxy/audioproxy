# Add Azure Blob Source Backend

## Why

`add-azure-client` gives the proxy an Azure Blob client with the exact seam surface a source type needs — a HEAD and a presignable GET — but nothing speaks it yet. This slice adds the `azblob://` scheme so an Azure-hosted catalogue is a first-class source: `stat/1` answers 404/413 before a subprocess starts, `ffmpeg_input/1` is a SAS URL ffmpeg Range-reads directly, and the source bytes never cross the BEAM — the input-side architecture unchanged, third provider.

## What Changes

- An `azblob://container/blob` source scheme, `AudioProxy.Source.Azblob`, implementing the five `Source.Type` callbacks. Split at the first `/`, both halves required, blob name kept as raw decoded bytes; container bounded at 63 bytes and blob name at 1024 (Azure's own maxima), body bounded before the split — the `s3://` discipline, Azure's numbers.
- `stat/1` = `Azure.head/2`; `ffmpeg_input/1` = `Azure.presign_get/3`. Error mapping is exhaustive with no catch-all, mirroring `Source.S3`'s: 404-shaped causes → 404, `:access_denied` → 404 (the blind row), `:not_configured` → 500.
- Container allowlisting via the existing `AP_SOURCE_ALLOWLIST`, same semantics as `s3://` buckets — refusal is a 404 indistinguishable from a missing blob.
- An `azblob://` source with no `AP_AZURE_*` group configured is `:not_configured` → 500.
- Docs: API doc §1 scheme table, README sources section, `llms-full.txt` scheme list; docs site sources guide follows via the drift notifier.

## Non-goals

- Snapshot/version pinning (`?snapshot=`) — a blob name is current-version only; a versioned-source story would be a cross-scheme design, not an Azure footnote.
- The variant-store side — `add-azure-variant-store`, proposed alongside.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `remote-sources`: a fourth remote scheme, `azblob://`, with container/blob semantics parallel to `s3://`'s bucket/key.

## Impact

- New: `AudioProxy.Source.Azblob`. Modified: resolver dispatch table, README, API doc, `llms-full.txt`.
- Hard dependency: `add-azure-client`.
- End-to-end tests render from an `azblob://` source against Azurite (`@tag :azurite`); the parse/canonical/bounds property tests mirror `Source.S3`'s.
- Estimated ~250 LOC including tests.
- Position: with the Azure track — the three slices move together when an Azure deployment appears. Source and store are independent of each other once the client is in; they can land in either order or in parallel worktrees.
