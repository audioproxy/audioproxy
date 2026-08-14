# Tasks

## 1. Option and chain
- [x] 1.1 `enhance` option: parse/normalize/round-trip; value vocabulary `voice`
- [x] 1.2 Pinned chain in the command builder; filter order fixed relative to trim/fade/gain/norm; golden argv
## 2. Tests
- [x] 2.1 Round-trip property; cache-key stability; enhance+norm combination
- [x] 2.2 `:ffmpeg` spectral assertion on a noisy sibilant fixture (chain audibly applied, not golden bytes)
- [x] 2.3 Pinning guard: chain change without a new value fails a test
## 3. Docs
- [x] 3.1 README options table, API doc, llms-full (guards enforce), docs/ffmpeg-arguments.md chain rationale
