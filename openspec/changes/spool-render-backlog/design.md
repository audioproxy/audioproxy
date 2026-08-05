## Context

`RenderCoordinator` holds `state.backlog` as a reversed iodata list and `state.bytes` as its running size. Chunks arriving from `Ffmpeg.Render` are appended and broadcast to subscribers; a subscriber attaching mid-render is sent the accumulated backlog, which `Plugs.RenderAction` flattens with `IO.iodata_to_binary/1` before writing. Everything the render produced is resident until the coordinator stops, one second after the render finishes.

On the BEAM this is cheaper than it looks — binaries over 64 bytes are reference-counted, so broadcasting to N subscribers copies pointers rather than audio — which is exactly why the memory cost tracks *output size* and not subscriber count. Removing it means moving the bytes off the heap without losing the property that makes coalescing worth having.

## Goals / Non-Goals

**Goals:**
- `B_backlog` leaves the memory model. A container's memory stops scaling with output length.
- Every subscriber still receives a byte-identical complete stream, whenever it attached.
- Disk is bounded and reclaimed, including after an unclean shutdown.

**Non-Goals:**
- Persisting variants across restarts. The spool is scratch for an in-flight render; the variant store is what makes a render durable, and conflating them would make the spool a cache with an eviction policy.
- Serving Range from the spool. A MISS is chunked `200` today and stays that way; Range is the variant store's job via the `302`.
- Replacing the in-memory path. It is better for the preview-shaped deployment that the defaults assume — no syscalls, no directory, no sweep — and stays the default.

## Decisions

- **A file per cache key, not a shared log.** The cache key already identifies the render, one writer owns the file for its lifetime, and deleting it is the whole cleanup story. A shared append log would need offsets, tenancy and compaction to save inodes nobody is short of.
- **Catch-up reads from the file; live chunks stay in-band.** A subscriber attaching at offset N reads 0..N from the spool and then receives broadcasts. Pushing every live chunk through the filesystem would put a write and a read on the latency path of the common case — a preview with a single subscriber that never falls behind — to fix the case where someone joins a long render late. The seam is "how do you catch up", and it is the only seam that needs to change.
- **Raw-mode `File.open`/`IO.binread`, per `CLAUDE.md`.** OS pipe and file semantics do the work; OTP ≥ 21 runs file reads on dirty I/O schedulers, so a slow read does not occupy a normal scheduler. No new dependency, and the escalation path was named with this shape in mind.
- **The reader must not outrun the writer.** The coordinator knows the committed offset; a catch-up reader is given a bound and never reads past it. Reading a partially-written chunk would produce a stream that differs from another subscriber's by a torn boundary — the exact property the coalescing suite's byte-identical tests exist to catch, and the most likely way this change is subtly wrong.
- **Behind `AP_BACKLOG_MODE`, defaulting to memory.** This rewrites the retention path of the module every request goes through. A flag makes the first deployments reversible without a rollback, and makes the two modes testable against each other — the same request through both paths must produce the same bytes.
- **Disk gets the discipline memory had.** `AP_SPOOL_MAX_BYTES` bounds the directory and a render that would cross it fails the way a retention breach does today; files are unlinked on completion, failure, timeout and coordinator death; a boot sweep removes orphans. Trading an OOM for a full disk that silently fails every subsequent render is not a trade, and "the operator will notice" is not a mechanism.
- **Unlink-on-open is tempting and rejected.** Unlinking immediately after open gives automatic cleanup on process death and defeats the boot sweep, external inspection and any operator asking what is on their disk. Explicit removal plus a sweep is more code and less magic; when a spool file is left behind, somebody needs to be able to see it.

## Risks / Trade-offs

- [The most load-bearing module in the system gets its retention path rewritten] → the flag, and stacked PRs: writer and lifecycle, then the joiner read path, then the capacity rewrite. Merging it as one change would be several hundred lines against coalescing, cancellation, timeout and failure propagation at once.
- [Disk replaces memory as the unbounded resource] → bounded and swept above, but the honest statement is that the failure mode moves rather than disappears. A full spool disk fails renders; it does not take the container down with it, which is the improvement.
- [The container needs a writable directory] → a real deployment change. Ephemeral container storage is often small and sometimes an overlay; the sizing section has to say what the spool actually needs, which is roughly `C × variant size` — the same arithmetic, moved to a cheaper resource.
- [Filesystem behaviour varies] → overlayfs, tmpfs and a network mount have different performance and different failure modes, and tmpfs would put the bytes back in memory while looking like it had not. The documentation has to name that trap explicitly, because a tmpfs spool is the configuration that appears to work and silently reinstates the problem.
- [Latency for late joiners] → a joiner now waits on file I/O where it previously got a memory copy. For the long renders this change exists for, reading a few hundred megabytes off local disk is faster than the render producing them, so the joiner stays behind the writer rather than the reverse.
