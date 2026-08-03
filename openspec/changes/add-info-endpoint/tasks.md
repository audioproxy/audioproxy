## 1. Probe module

- [x] 1.1 `AudioProxy.Ffprobe.probe(url)`: argv build, run via Port wrapper (collect mode, probe timeout), stdlib JSON decode
- [x] 1.2 Contract mapping: format/duration/sample_rate/channels/bit_depth/bitrate/size/tags with per-format fallbacks; omission rules
- [x] 1.3 Unit tests: canned ffprobe JSON fixtures (wav/mp3/flac/ogg/multichannel) → expected contract JSON; malformed probe output → error

## 2. Endpoint

- [x] 2.1 `info` as exclusive pseudo-option in ParseOptions (422 with any other option)
- [x] 2.2 Info action: resolve → `Source.stat/1` (404/size) → `Source.ffmpeg_input/1` → probe → JSON response; ETag derivation (source identity + stat etag material) + `If-None-Match`/304; Cache-Control
- [x] 2.3 Error mapping: unprobeable → 415; probe timeout → 504

## 3. Integration (`@tag :ffmpeg`)

- [x] 3.1 Generated fixtures (incl. tagged mp3) from the local fixture root: full contract assertions per spec scenarios; 304 revalidation; text file → 415; S3-source case once `add-s3-client` has landed

## 4. Docs

- [x] 4.1 Update README: info endpoint, response fields, caching behavior
