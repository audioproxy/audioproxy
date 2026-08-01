## 1. Decoding

- [x] 1.1 `AudioProxy.Source.parse/1`: split `plain/` vs `enc/`, base64url decode (padded or unpadded), percent-unescape exactly once, yielding one decoded source string
- [x] 1.2 Structured errors: unknown encoding prefix, undecodable `enc/`, malformed percent-escape, empty source, non-UTF-8
- [x] 1.3 Universal rejection of control/format/separator code points, by Unicode category rather than ASCII range

## 2. Source-type contract

- [x] 2.1 `AudioProxy.Source.Type` behaviour: `scheme/0`, `tag/0`, `parse/1`, `canonical/1`, `authorize/1`, `stat/1`, `ffmpeg_input/1`
- [x] 2.2 Scheme split and case-insensitive dispatch to a registered type; unregistered scheme and schemeless source → structured error
- [x] 2.3 `Source.canonical/1`, `authorize/1`, `stat/1`, `ffmpeg_input/1` delegate to the source's own type by tag
- [x] 2.4 Compile-time registry, empty in this slice, injectable for tests

## 3. Tests

- [x] 3.1 Test-only source type in `test/support`, exercising the contract end to end
- [x] 3.2 Unit: every spec scenario — both encodings, escaping, malformed inputs, Unicode controls, dispatch hit/miss, empty registry
- [x] 3.3 Property: `parse(enc(source)) == parse(plain(source))` for generated bodies including reserved characters and a literal `%`
- [x] 3.4 Property: canonical string is stable across encoding variants, and the cache key derived from it is too

## 4. Docs

- [x] 4.1 `docs/sources.md`: the two encodings, decode-once escaping and its double-escaping consequence, canonical identity, the type contract
- [x] 4.2 README *Sources*: the encodings and the escaping rule a caller has to know; source forms are documented by their own slices
