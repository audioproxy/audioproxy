## Why

`RenderCoordinator` retains every chunk a render emits, in memory, until the render ends. That is what lets a late request join a render already in flight and still receive a complete stream, and it is why `docs/capacity.md` is mostly a document about one term. `B_backlog` is the size of the variant being produced, and a variant is duration × bitrate, so the architecture's memory cost scales with output length without limit.

The consequence is a workload the proxy refuses rather than serves. Two-hour 24-bit stereo is 2.07 GB of output, past the default retention cap; four hours is 4.15 GB and wants an 8 GiB container to run *one at a time*; eight hours wants 16 GiB. These are not exotic — archival transfers, conference and concert recordings, long-form radio. The current answers are a `t:` window, a lossy format, or nothing, and for a catalogue whose product *is* the full-length lossless file, the first two are not answers.

Raising `AP_MAX_SRC_BYTES` (or, after `split-retention-cap`, `AP_MAX_VARIANT_BYTES`) is the reflex and is worse than the refusal: the cap is per-render while the bill is `C × B_backlog`, so raising it to fit one render licenses every slot to reach that size. The refusal is currently the thing keeping a container alive.

`CLAUDE.md` has named the escalation from the start: the coordinator writes its backlog to a scratch file and clients read from the file, so OS-level file I/O replaces the in-memory list. This is the change that builds it. It removes `B_backlog` from the memory model entirely and makes full-length lossless a **disk** question — which is a question with cheap answers, unlike the memory one.

This is a large change against the most load-bearing module in the system, and it is worth doing only if long-form lossless is a workload being served rather than one being asked about. The alternative — declining it and keeping the honest refusal — stays defensible.

## What Changes

- **The backlog moves to a spool file.** One file per in-flight cache key under `AP_SPOOL_DIR`, written as chunks arrive. `state.backlog`'s in-memory list and `state.bytes` counter are replaced by a file handle and an offset.
- **Subscribers read from the file, not from a message.** A late joiner is currently handed the backlog-so-far as one contiguous binary (`IO.iodata_to_binary/1` in `Plugs.RenderAction`) — a transient copy of everything accumulated so far, per joiner. It reads from the spool file at its own pace instead, which removes the one place the current model can be exceeded by a burst of simultaneous joiners.
- **Live chunks stay in-band.** A subscriber caught up to the write offset keeps receiving broadcast chunks directly; the file is how it *catches up*, not how it keeps up. Round-tripping every live chunk through the filesystem would add latency to the common case to fix the uncommon one.
- **The spool is bounded and swept.** `AP_SPOOL_MAX_BYTES` bounds the directory; files are removed when the render completes, fails, times out, or the coordinator dies, and orphans from an unclean shutdown are swept at boot. Disk that nothing expires is the failure this change trades memory for, and it has to be answered here rather than in an operations note.
- **`docs/capacity.md` is rewritten around a model without `B_backlog`.** The banner already says this page describes the in-memory-backlog architecture and is wrong for a version that spools; this is that version. The matrix collapses toward flat terms, refusals largely disappear, and a disk sizing section replaces most of the memory argument.
- **`AP_BACKLOG_MODE`** selects memory or spool, defaulting to memory. A rewrite of the retention path lands behind a switch that can be turned back.

## Capabilities

### New Capabilities

<!-- none — spooling is how coalescing retains, not a new capability -->

### Modified Capabilities

- `render-coalescing`: the backlog acquires a storage backend; the byte-identical-stream guarantee has to survive it.
- `capacity-model`: `B_backlog` leaves the formula in spool mode and disk becomes a sized resource.
- `deployment`: a writable spool directory becomes a container requirement.

## Impact

- Modified: `lib/audio_proxy/render_coordinator.ex` (substantially), `lib/audio_proxy/plugs/render_action.ex` (the joiner path), `Config`, `docs/capacity.md`, `bin/capacity_model.rb` and the matrix, `README.md`, the Dockerfile/compose for the spool mount.
- **Touches the module every render goes through**, including coalescing, cancellation, timeout and failure propagation — all of which have suites that exist precisely because these paths are hard.
- Depends on: `split-retention-cap` (the retention bound is what this makes largely moot, and having it separated first keeps the two arguments apart).
- **Sizing note:** this exceeds the ~500 LOC slice target and should land stacked — the spool writer and its lifecycle first, the joiner read path second, the capacity rewrite third.
