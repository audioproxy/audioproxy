## Why

`f:peaks` output cannot be read by [peaks.js](https://github.com/bbc/peaks.js), the library the format exists to feed. Its loader checks `waveformData.bits !== 8` and refuses, and its README instructs users to pass `audiowaveform -b 8` "as Peaks.js does not currently support 16-bit waveform data files". The proxy pins `bits` at 16, so every consumer has to fetch the JSON, scale each value by 256, and hand the result to `waveformData: { json }` — which also gives up the compact `dat` path entirely, because `dataUri` fetches and then rejects.

This was found by building a working peaks.js integration rather than by reading, and the same wrong claim ("drops straight into peaks.js") is currently published in `llms-full.txt` and in two blog posts.

`peaks-rendering` refuses the 8-bit variant on the grounds that it "would be a second cache key for a coarser picture of the same audio". That reasoning was sound when the only cost was storage. It did not account for the coarser picture being the only one the primary consumer accepts.

## What Changes

- Add `pk_bits`, a peaks-scoped option taking `8` or `16`, defaulting to `16`, materialized into the cache key exactly as `ch` is.
- `pk_bits:8` emits values in the signed 8-bit range in both serializations: `bits: 8` in the JSON object, and `int8` pairs after the header in the `dat` layout.
- **Reverse** the `peaks-rendering` requirement that the 8-bit variant SHALL NOT be offered, replacing the storage argument with the compatibility evidence above.
- Refuse `pk_bits` on every format other than `f:peaks`, with the same `422` and the same reasoning as the existing peaks rule: an option that cannot change the output would hand one result two cache keys.
- Correct a stale scenario in `processing-options` that lists `gain` and `norm` among the options refused with `f:peaks`. Both are accepted, and measured as accepted in 0.7.2 (`200`, with peak values that differ from the unprocessed render). The API contract already says peaks respect them; only the spec disagrees.
- Update the API contract §3.3, and the `llms-full.txt` options table plus its false claim that peaks output "drops straight into peaks.js".

Not in scope: changing the default. `pk_bits:16` stays the default because it is the more faithful picture and because changing it would silently invalidate every cached peaks variant.

## Capabilities

### New Capabilities

None. This extends two existing ones.

### Modified Capabilities

- `peaks-rendering`: the 8-bit serialization becomes offerable rather than forbidden, and both output requirements gain a width that follows `pk_bits` instead of being fixed at 16.
- `processing-options`: a new option key with its own validation, default materialization and cross-format refusal, plus the correction of the stale `gain`/`norm` scenario.

## Impact

**Code.** The options parser and its normalized-key ordering, the peaks reducer that currently writes `int16` unconditionally, and the `dat` header writer. The JSON serializer already emits `bits` from a value rather than a literal, so it follows the reducer.

**Contract and docs.** `docs/audio-proxy-api-v1.md` §3.3; `llms-full.txt`, whose options table is compared against `AudioProxy.Options.keys/0` by `test/llms_docs_test.exs` and will fail until the row is added; the peaks guide on the documentation site, which is authored downstream and gets a drift issue rather than an edit.

**Downstream.** `audioproxy-rails` needs the key in `KEYS` and an alias (`peak_bits`), which is its own change in that repo rather than a note here. Nothing in the gem breaks meanwhile: an unknown key raises there, so the gem simply cannot emit `pk_bits` until it lands.

**Cache.** No existing variant changes. Every URL rendered before this ships omits `pk_bits`, and the default materializes to the same bytes those URLs already produced.
