## 1. Establish the compatibility target

- [x] 1.1 Generate a reference fixture with `audiowaveform -b 8` and `-b 16` from one of the test sources, and record its header bytes and first pairs in the test that will pin them
- [x] 1.2 Determine audiowaveform's own narrowing rule for negative values (truncate toward zero versus arithmetic shift) by comparing the two fixtures, and write it down in the test rather than in a comment
- [x] 1.3 Confirm whether the version-2 flags field carries anything besides bit 0, so the field is written deliberately once it stops being a constant

## 2. Options

- [x] 2.1 Add `pk_bits` to the parser with values `8` and `16`, defaulting to `16`
- [x] 2.2 Materialize the default into the normalized options string, as `ch` is materialized for peaks, so the segment's presence cannot split one variant across two cache keys
- [x] 2.3 Refuse `pk_bits` on every format other than `f:peaks`, reporting the peaks rule rather than an incidental format rule
- [x] 2.4 Property-test the round trip: parse → normalize → cache key → identical ffmpeg args and identical serialization, for both widths
- [x] 2.5 Correct the stale `processing-options` scenario that lists `gain` and `norm` among the options refused under `f:peaks`, and add a test proving both are accepted, since the master spec and the implementation currently disagree

## 3. Serialization

- [ ] 3.1 Replace `@bits` with the width carried by the parsed options, so the JSON object reports what it actually contains
- [ ] 3.2 Narrow the 16-bit pairs at the serialization boundary under `pk_bits:8`, using the rule established in 1.2, clamped to −128..127
- [ ] 3.3 Replace `@dat_flags` with a value derived from the width, bit 0 set for 8-bit
- [ ] 3.4 Test that both serializations agree at both widths, and that the 8-bit `dat` body is exactly half the 16-bit body with a 24-byte header that differs only in the flags field
- [ ] 3.5 Test that each 8-bit value is its 16-bit counterpart narrowed, so the two widths are one waveform at two resolutions

## 4. The claim that started this

- [ ] 4.1 Add an end-to-end test that a `pk_bits:8` JSON response satisfies peaks.js's own acceptance rule: `bits == 8` and every value within the signed 8-bit range
- [ ] 4.2 Verify a `pk_bits:8` `dat` response against the reference fixture from 1.1

## 5. Contract and documentation

- [ ] 5.1 Update `docs/audio-proxy-api-v1.md` §3.3 with the `pk_bits` row, the default, and the cache-key materialization
- [ ] 5.2 Correct §3.3's statement that `bits` is always 16
- [x] 5.3 Add the `pk_bits` row to the `llms-full.txt` options table, which `test/llms_docs_test.exs` compares against `AudioProxy.Options.keys/0` and which will fail until it is there
- [ ] 5.4 Fix the false claim in `llms-full.txt` that peaks output "drops straight into peaks.js", which is what this change makes true and is currently not
- [ ] 5.5 Note in the release notes debt section that the documentation site's peaks guide is now behind, and open the drift issue there rather than editing it from here

## 6. Downstream

- [ ] 6.1 Create the companion change in `audioproxy-rails` for `pk_bits` in `KEYS` and `peak_bits` in `ALIASES`, before this one is archived, so the deferral is a change on a board rather than a note in an archived file
- [ ] 6.2 Correct the same "peaks.js already reads it" claim in the two published blog posts and their dev.to copies, which is a writing task rather than an implementation one
