## 1. Probe module

- [ ] 1.1 `AudioProxy.Ffprobe.probe(url)`: argv build, run via Port wrapper (collect mode, probe timeout), stdlib JSON decode
- [ ] 1.2 Contract mapping: format/duration/sample_rate/channels/bit_depth/bitrate/size/tags with per-format fallbacks; omission rules
- [ ] 1.3 Unit tests: canned ffprobe JSON fixtures (wav/mp3/flac/ogg/multichannel) → expected contract JSON; malformed probe output → error

## 2. Endpoint

- [ ] 2.1 `info` as exclusive pseudo-option in ParseOptions (422 with any other option)
- [ ] 2.2 Info action: resolve → HEAD (404/size) → presign → probe → JSON response; ETag derivation + `If-None-Match`/304; Cache-Control
- [ ] 2.3 Error mapping: unprobeable → 415; probe timeout → 504

## 3. Integration (`@tag :ffmpeg`)

- [ ] 3.1 Generated fixtures (incl. tagged mp3) through fake S3: full contract assertions per spec scenarios; 304 revalidation; text file → 415

## 4. Docs

- [ ] 4.1 Update README: info endpoint, response fields, caching behavior
