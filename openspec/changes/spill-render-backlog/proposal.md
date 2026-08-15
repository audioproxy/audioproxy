# Spill The Backlog By Size, Not By Mode

## Why

`spool-render-backlog` lands the file-backed backlog behind `AP_BACKLOG_MODE`, defaulting to memory. That flag is the right way to *ship* a rewrite of the retention path, and the wrong place to leave it: a mode asks the operator a question they usually cannot answer — "will you ever serve long-form lossless?" — and punishes a wrong guess with an OOM rather than a degradation. The operator most likely to answer wrong is precisely the one who has not read `docs/capacity.md` and does not know that memory scales with output length.

Neither mode is the right default, because the choice does not belong to configuration at all. A render's size is discovered while it runs, so the retention path can decide for itself: keep the backlog in memory while it is small, spill to a file once it is not. Preview-shaped renders (a 30-second Opus is ~360 KB) never touch disk, keeping every advantage `spool-render-backlog`'s design claims for the memory path — no syscalls, no directory, no sweep — and long-form stops being a memory bomb without anyone predicting it.

## What Changes

- **`AP_BACKLOG_SPILL_BYTES`** (a size, not a mode): a render retains its backlog in memory until it exceeds this many bytes, then writes what it holds to a spool file and continues there for the rest of the render. Default sized so preview-shaped work never spills and long-form always does.
- **The transition is one-way and mid-render.** Once spilled, a render stays spilled; there is no path back to memory. Subscribers attached before the spill and after it must still receive byte-identical streams, which is the property this change most has to prove.
- **A failed spill kills the render.** If the flush or a subsequent write fails, the render fails rather than silently reverting to memory: a subscriber that catches up from a file while another is served from memory is the divergence the coalescing suite exists to catch. The client sees the same error a retention breach produces today.
- **`AP_BACKLOG_MODE` gains a third value** (`auto`) rather than being removed here, so the rollout can prove spilling against both fixed modes before anything is retired.

## Non-goals

- Retiring `AP_BACKLOG_MODE`. That is the third step and its own change (`retire-backlog-mode`), once `auto` has earned the default. Removing a switch in the same change that introduces the behaviour it selects leaves nothing to fall back to.
- Spilling back to memory when a render shrinks. Renders do not shrink.
- Changing what the spool is: file per cache key, bounded by `AP_SPOOL_MAX_BYTES`, swept at boot, all as `spool-render-backlog` defines it.

## Capabilities

### Modified Capabilities

- `render-coalescing`: the backlog's storage is chosen by size at runtime rather than by configuration at boot, with a defined one-way transition.

## Impact

- Depends on: `spool-render-backlog` (this needs the file path to exist and be proven).
- Modified: the coordinator's retention path (a buffer that changes backing store mid-life), config, `docs/capacity.md`'s sizing section, README.
- Tests: byte-identical streams for subscribers attaching before, during and after the spill (the transition is the risk); a spill failure kills the render and does not fall back; the threshold is respected exactly; preview-shaped renders never create a file, asserted by watching the spool directory.
- Estimated ~250 LOC on top of `spool-render-backlog`.
- Position: parked with the same trigger as its dependency. Recorded now so the mode question is settled before the code exists rather than after.
