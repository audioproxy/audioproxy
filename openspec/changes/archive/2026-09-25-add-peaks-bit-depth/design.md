## Context

`AudioProxy.Peaks` pins two module attributes: `@bits 16` and `@dat_flags 0`. The second already carries a comment describing the convention this change needs — *"v2 flag bits: 0 is 16-bit samples, 1 would be 8-bit"* — so the format was understood when it was written; only the option to reach it was missing.

The reduction itself is unaffected. Peaks are computed from decoded samples into min/max pairs; the width is a property of how those pairs are written, not of how they are found.

The consumer evidence is specific rather than general. peaks.js 4.0.0 refuses on `waveformData.bits !== 8` in its loader, and its README instructs `audiowaveform -b 8`. wavesurfer.js does not read the format at all and needs floats either way, so it is indifferent to this change.

## Goals / Non-Goals

**Goals:**

- Make `f:peaks` output directly loadable by peaks.js, through `dataUri` with no client-side conversion.
- Keep the two widths provably the same waveform, so choosing one is a resolution decision and never a correctness one.
- Keep the bytes for every existing peaks URL unchanged. The cache key changes once (see Migration Plan).

**Non-Goals:**

- Changing the default. 16-bit stays.
- Matching audiowaveform's binary byte-for-byte across every input. Compatibility here means a reader that accepts audiowaveform's 8-bit output accepts ours.
- Any `bd` change. `bd` remains encoded-output-only and remains refused under `f:peaks`.

## Decisions

**`pk_bits`, not `bd:8`.** `bd` names the sample format of encoded output, with values `16 | 24 | 32f` and a lossless-only rule. Extending it would give one segment two meanings depending on the format beside it — PCM depth on `f:wav`, serialization width on `f:peaks` — and would add a value that is invalid everywhere except peaks. `pk_bits` sits beside `pk_fmt`, which already namespaces a peaks-only concern, so the naming pattern exists rather than being invented.

*Alternative considered:* a single `peaks:<fmt>:<bits>` compound. Rejected: it would break the existing `pk_fmt` URLs, and multi-value segments are reserved in this grammar for genuinely positional values like `t` and `norm`.

**Reduce once at full width, narrow when serializing.** The reducer keeps producing 16-bit pairs; `pk_bits:8` divides each by 256 at the serialization boundary. Two consequences are worth the choice. The spec's claim that the narrow picture is a reduction of the wide one becomes true by construction rather than by testing two code paths against each other. And the decode, which is the expensive half, stays identical for both widths, so nothing about render cost or the ffprobe-then-decode shape changes.

*Alternative considered:* asking the reducer for 8-bit directly. Rejected: two accumulation paths to keep in agreement, for a saving that is a rounding step per bucket.

**`@dat_flags` becomes a function of the width.** Bit 0 set means 8-bit in audiowaveform's version-2 layout, which is how a reader that handles both widths decides how to parse the body. Emitting 8-bit values behind a flags field of 0 would produce a file that is wrong in the one way nobody checks for.

**The default is materialized into the cache key**, like `ch` for peaks. `f:peaks/pts:800` and `f:peaks/pts:800/pk_bits:16` are one variant, so they must be one key.

## Risks / Trade-offs

**The rounding rule may not match audiowaveform's.** Dividing by 256 in Elixir truncates toward zero; an arithmetic shift floors. The two disagree for negative values (`-300 / 256` is `-1` truncating, `-2` shifting), which is exactly half the data in a min/max series. A waveform drawn from either is indistinguishable by eye, so this is not a rendering risk, but it is a compatibility claim we would be making loosely. → Resolve by generating a fixture with `audiowaveform -b 8` and comparing our output against it during implementation, then pinning the rule in a test rather than in a comment.

**8-bit is a genuinely coarser picture.** A quiet passage reduced to 8 bits has 256 levels rather than 65,536, and near-silence flattens. → Not mitigated, because it is the point: the default stays 16-bit and the narrow form is opt-in for a consumer that requires it.

**A second cache entry per variant, for callers who ask for both.** That was the original argument against offering 8-bit at all, and it still holds; what changed is that the coarser picture turns out to be the only one the primary consumer accepts. → Bounded by the option set: `pk_bits` doubles the peaks key space at most, and only for callers who use both.

## Migration Plan

The default `pk_bits:16` is materialized into the canonical options string, as `ch`, `pts` and `pk_fmt` are under `f:peaks`. That string is the cache-key input, so every peaks cache key changes once when this ships. The bytes behind each URL do not change.

The consequence is a one-time miss per cached peaks variant. The first request after the deploy renders again and writes back under the new key. The objects under the old keys are no longer reachable and stay in the variant bucket until a lifecycle rule or an operator removes them. Peaks objects are small, and a render is a decode and a reduction, so the cost is bounded.

*Alternative considered:* omitting the default from the canonical string, which keeps every existing key. Rejected in favour of one rule for all peaks defaults: a key that is materialized for `ch`, `pts` and `pk_fmt` but omitted for `pk_bits` is an exception that the next option would copy or forget.

The gem cannot emit the new key until its own change lands, and will raise on it meanwhile, which is the correct failure rather than a silent one.

## Open Questions

- Does audiowaveform set any other flag bit we are currently writing as zero? The comment in `peaks.ex` names only bit 0. Worth confirming against the format's own documentation while the fixture above is being generated, since we are about to make the field meaningful rather than constant.
- Should the documentation site's peaks guide gain a worked peaks.js example once this lands? It is authored downstream, so the answer is a drift issue there rather than an edit here, but this change is the reason it would be written.
