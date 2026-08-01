## Why

The source segment (API doc §1) must be decoded and resolved before anything can be fetched. Everything *shared* by every source type lives here — the `plain/`/`enc/` encodings, decode-once escaping, the rejection rules, canonical identity for the cache key, and the seam the render and info flows call — while the source types themselves (`local://`, `s3://`, `https://`) are separate slices that plug in behind a behaviour. Pure string work plus a dispatch table; independently buildable and testable.

## What Changes

- Decode the source segment: `plain/` (percent-escaped, unescaped exactly once) and `enc/` (base64url), both converging on one decoded source string before anything else runs.
- Reject at the shared layer what no source type should ever see: malformed escapes, non-UTF-8, and control/format/separator code points.
- Split the decoded string on its scheme and dispatch to a registered `AudioProxy.Source.Type` implementation; an unregistered scheme is a structured error.
- Define the `Source.Type` behaviour: `parse/1`, `canonical/1`, `authorize/1`, and the storage seam (`stat/1`, `ffmpeg_input/1`) that `add-render-endpoint` and `add-info-endpoint` call.
- Canonical source identity as the contract `AudioProxy.CacheKey` hashes: both encodings of one source produce byte-identical output.
- Ship **no source types**. Dispatch, decoding and the seam are exercised against a test-only type.

## Capabilities

### New Capabilities

- `source-resolution`: Source-segment encodings, decode-once escaping, the source-type contract and dispatch, and canonical source identity.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/source.ex`, `lib/audio_proxy/source/type.ex`.
- Depends on: `init-project-scaffold` (config).
- Blocks: `add-local-files-source` (registers `local://`; the MVP source type), `add-remote-files-source` (registers `s3://` and `https://`), `add-render-endpoint`, `add-info-endpoint`.
- Sequencing: first in the MVP chain, implemented directly before `add-local-files-source`.
