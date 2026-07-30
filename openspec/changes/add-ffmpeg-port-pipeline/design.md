## Context

BEAM Ports close stdin/stdout but do not kill the OS process on close — orphan prevention must be explicit. CLAUDE.md decides: raw Port + bounded-buffer GenServer now; named-pipe (FIFO) pattern documented as the escalation for full-length transcodes.

## Goals / Non-Goals

**Goals:**
- Watertight lifecycle: every exit path (normal, consumer death, cancel, timeout, VM shutdown) leaves no OS process behind.
- A consumer contract (`{:chunk, bin}`, `{:done, info}`, `{:error, reason}`) that coalescing builds on unchanged.

**Non-Goals:**
- FIFO backpressure implementation (documented escalation path only); retry policy (a render fails once, the client retries).

## Decisions

- **One GenServer per render** under a `DynamicSupervisor`; `Port.open({:spawn_executable, ffmpeg_path}, [:binary, :exit_status, args: argv])`. The GenServer monitors its consumer and traps exits.
- **Kill discipline**: on any teardown, close the port, then SIGTERM the OS pid (from `Port.info(:os_pid)`), then SIGKILL after a 2 s grace. Release shutdown runs supervisor termination, so VM stop takes the same path.
- **stderr to a per-render temp file** (scratch dir), tail read on nonzero exit, deleted after. `:stderr_to_stdout` is unusable here — it would corrupt the output byte stream — and a second pipe needs a wrapper process; the temp file is boring, race-free, and zero-dep.
- **Bounded buffer without true backpressure**: Ports have no passive read mode, so the wrapper accounts outstanding (unacked) bytes; above high-water it stops forwarding and buffers. ffmpeg eventually blocks on the ~64 KB OS pipe. Sufficient for preview-sized outputs per CLAUDE.md; true backpressure is the documented mkfifo escalation (passive `IO.binread` on dirty schedulers).
- **Timeout** via `Process.send_after`; classification table over exit status + stderr regexes (`Invalid data`, `403 Forbidden`/`404 Not Found`, `Connection refused`).
- **Test doubles**: a committed `fake_cmd.sh` (emit N bytes, sleep, exit K, ignore TERM — variants via args) exercises every lifecycle path without ffmpeg; `@tag :ffmpeg` tests generate fixtures with `ffmpeg -f lavfi -i sine=...` at test-setup time (no binary fixtures in git).

## Risks / Trade-offs

- [OS pipe + wrapper buffer is not true backpressure] → accepted per CLAUDE.md for preview-sized outputs; escalation path recorded in module doc.
- [PID reuse between TERM and KILL could kill an innocent process] → 2 s window makes reuse implausible on any real system — accepted.
- [stderr temp file I/O per render] → trivial next to an ffmpeg spawn; scratch dir cleaned on boot.
