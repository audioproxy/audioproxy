## Context

`AudioProxy.Peaks` pins two module attributes: `@bits 16` and `@dat_flags 0`. The second already carries a comment describing the convention this change needs — *"v2 flag bits: 0 is 16-bit samples, 1 would be 8-bit"* — so the format was understood when it was written; only the option to reach it was missing.

The reduction itself is unaffected. Peaks are computed from decoded samples into min/max pairs; the width is a property of how those pairs are written, not of how they are found.

The consumer evidence is specific rather than general. peaks.js 4.0.0 refuses on `waveformData.bits !== 8` in its loader, and its README instructs `audiowaveform -b 8`. wavesurfer.js does not read the format at all and needs floats either way, so it is indifferent to this change.

## Goals / Non-Goals

**Goals:**

- Make `f:peaks` output directly loadable by peaks.js, through `dataUri` with no client-side conversion.
- Keep the two widths provably the same waveform, so choosing one is a resolution decision and never a correctness one.
- Leave every cache key that exists today pointing at the same bytes.

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

Nothing to migrate. Every peaks URL rendered before this ships omits `pk_bits`, and the default resolves to the bytes those URLs already produced, so no cached variant is invalidated and no stored object becomes unreachable.

The gem cannot emit the new key until its own change lands, and will raise on it meanwhile, which is the correct failure rather than a silent one.

## Open Questions

- Does audiowaveform set any other flag bit we are currently writing as zero? The comment in `peaks.ex` names only bit 0. Worth confirming against the format's own documentation while the fixture above is being generated, since we are about to make the field meaningful rather than constant.
- Should the documentation site's peaks guide gain a worked peaks.js example once this lands? It is authored downstream, so the answer is a drift issue there rather than an edit here, but this change is the reason it would be written.
