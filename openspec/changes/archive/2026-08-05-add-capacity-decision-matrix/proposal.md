## Why

`docs/capacity.md` (shipped in `add-capacity-model-doc`) is correct and answers the wrong question first. It hands an operator a formula and a per-format RSS table, from which the decision they actually came for — **how large can `AP_MAX_CONCURRENCY` be on this host?** — is derivable in about four steps of arithmetic. Nobody sizing a container wants to do four steps of arithmetic; they want to find their workload in a row, their host in a column, and read a number.

The formula is the *justification* for that number, not the thing to lead with. Today the document is ordered the way it was discovered rather than the way it is used.

## What Changes

- **A decision matrix goes first**, immediately after the version banner and before the formula: maximum safe `AP_MAX_CONCURRENCY` as a function of the variables an operator actually controls —
  - **source/output length** (30 s preview, 10 min, 1 h, 2 h),
  - **codec and bitrate** (the `B_backlog` driver: mp3 128/320, opus 96, flac, wav),
  - **host memory** (1, 2, 4, 8, 16, 32 GiB),
  with cells computed by inverting the published formula: `C_max = (RAM_budget − BEAM_base − T_ffmpeg) / (R_ffmpeg + B_backlog + H_pipeline) − L`.
- **The reverse table alongside it**: RAM required for a chosen concurrency, for operators who have fixed `C` and are buying a host.
- **The two knobs that are not in the matrix get a short section saying why**: `AP_QUEUE_SIZE` costs approximately nothing (a queued coordinator holds no backlog and no subprocess, so the queue is a latency and `429` decision, not a memory one), and `AP_MAX_SRC_BYTES` is a per-render ceiling rather than a total — it bounds the worst case a single render can reach, and does not bound `C × B_backlog`.
- **Cells that cannot be served are marked as such**, not left as small numbers: a 2 h `f:wav/bd:24` render exceeds the default retention cap outright, so its row says so rather than reading `C_max = 1`.
- The existing formula, term table, measured `R_ffmpeg` table and worked examples move below the matrix and stay as the derivation. The worked examples become the matrix's proof rather than its substitute.
- The matrix is **generated, not hand-written** — a mode on `bin/check-capacity` (or a small sibling) emits it from the same constants the guard predicts with, so it cannot drift from the model or from the measured table.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `capacity-model`: the published model gains a decision-first presentation and a generated concurrency matrix.

## Impact

- Modified: `docs/capacity.md` (restructured), the generator in `bin/`.
- Depends on: `add-capacity-model-doc` (merged in #40) — the model, the measured table and the guard all exist; this slice is presentation plus a generator.
- Not affected: the CI guard's assertion, which continues to check the same formula.
