## Why

`AudioProxy.Source.S3.stat/1` and `ffmpeg_input/1` still answer `{:error, :no_backend}`, so an `s3://` source parses, canonicalizes and authorizes but cannot be rendered or described. Everything they need already exists — `add-s3-client` shipped `AudioProxy.S3.head/2` and `presign_get/3`, and `add-s3-addressing` made the presigned host correct — and the code behind the seam is roughly fifteen lines.

It was not deferred for size. `add-s3-client` recorded it as **blocked on a decision**: what a client is told when S3 is *down*. §5's 404 row is deliberately blind, so that no source failure can be used to probe what exists; but an outage is not a source failure, and routing it into that row tells a client its object is gone when the store is merely unreachable — a lie that is then edge-cached for ten seconds and suppresses the retry that would have worked. This change settles that question and fills the stub. The same decision gates `add-https-source-backend`, whose stub is identical.

Until it lands the proxy renders from a mounted directory only, which is the gap between "works" and the README's "production-shaped".

## What Changes

- Decide how an upstream storage failure maps to HTTP, and extend the §5 error contract with the row it needs — a class distinct from both the blind 404 and the render-side 500.
- Classify `AudioProxy.S3`'s error type at the seam: `:not_found` and `:access_denied` stay the blind 404 (a distinguishable "forbidden" is the existence oracle §5 refuses); `:not_configured` is an operator fault, not a client one; `{:http, 5xx, _}` and `{:transport, _}` are the upstream failure.
- Implement `Source.S3.stat/1` via `S3.head/2` (size and ETag, feeding `/info`'s validator and the render path's 413) and `ffmpeg_input/1` via `S3.presign_get/3`, so ffmpeg ranges the object directly and no source bytes cross the BEAM.
- Remove the `:no_backend` reason from `Source.S3` and the test that pins the gap.
- Prove `/info` and the render path work against an `s3://` source with no changes of their own — the seam's whole claim, and the case `add-info-endpoint` deferred.

## Capabilities

### New Capabilities

<!-- none — this fills a backend behind an existing seam -->

### Modified Capabilities

- `s3-access`: the S3 source backend — `stat/1` and `ffmpeg_input/1` behind the storage seam, and how this layer's failures classify.
- `render-http`: an upstream storage failure is a status of its own, distinct from the blind 404 and from `render_failed`.

## Impact

- `lib/audio_proxy/source/s3.ex` (the two stubs and the reason list), `lib/audio_proxy/error_json.ex` (one row), `docs/audio-proxy-api-v1.md` §5, README's error table.
- Unblocks `add-https-source-backend`, which needs the same error row and nothing else from here.
- No new dependencies; no config surface beyond the `AWS_*` group and `AP_S3_ENDPOINT` that `add-s3-client` already established.
