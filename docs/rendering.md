# Rendering

How a render runs: the subprocess, the chunk stream it produces, and the rules
that bound it. The argument vector handed to that subprocess is a separate
subject — see [ffmpeg-arguments.md](ffmpeg-arguments.md).

`AudioProxy.Ffmpeg.Render` is one GenServer per render, under
`AudioProxy.Ffmpeg.RenderSupervisor`. It owns exactly one ffmpeg process and
exists for exactly as long as that process does.

## The consumer contract

A render is started with an argv list and a consumer process. The consumer
receives three kinds of message, and `render` is the render's pid:

| Message | Meaning |
|---|---|
| `{:chunk, render, binary}` | stdout bytes, in order |
| `{:done, render, %{exit_status: 0}}` | clean exit, every byte delivered |
| `{:error, render, reason}` | anything else |

Exactly one `{:done, …}` or `{:error, …}` is sent, always after the last chunk,
and the render stops immediately afterwards. A consumer that wants to hear
about a render that *crashed* — as opposed to one that failed — monitors it,
because a crash sends no message at all.

This contract is the seam the rest of the system is built on. Coalescing
subscribes several requests to one render's chunk stream; chunked HTTP delivery
and the S3 write-back both consume it; `/info` reuses the same subprocess
plumbing for `ffprobe`. None of them know what ffmpeg is.

## Why a subprocess at all

ffmpeg does every byte of decoding and encoding; the Elixir side only
orchestrates. That is a licensing posture as much as an architectural one — the
(L)GPL boundary is a *process* boundary, so invoking a CLI keeps even a
GPL-configured ffmpeg from reaching this source tree.

The subprocess is spawned from an argv list with
`Port.open({:spawn_executable, …}, args: argv)`. There is no shell anywhere in
the path, which is what makes a source URL containing `;`, `$(…)`, a quote or a
space simply one argument. The injection-safety property that
`AudioProxy.Ffmpeg.Command` is written for only holds because nothing between
it and `execve` re-parses its output.

## Buffering, and what it is not

Ports have no passive read mode. The VM drains the subprocess' stdout pipe as
fast as the OS fills it and mails the bytes to the render process, whether or
not anything downstream is ready for them. Left alone, a slow client would
therefore turn into an unbounded mailbox.

So the render accounts *outstanding* bytes — forwarded to the consumer but not
yet acknowledged with `ack/2`. Above a high-water mark of 1 MiB it stops
forwarding and queues internally; ffmpeg fills the ~64 KB OS pipe and blocks on
its own write. Acknowledging drops the count and releases the queue. A consumer
that never acknowledges receives the high-water mark plus at most one chunk, and
then nothing further — including the completion message, which is deliberately
withheld until every chunk before it has been delivered.

**This is a bounded buffer, not true backpressure.** Between the high-water mark
and ffmpeg actually blocking there is a pipe's worth of slack, and whatever the
render has queued is still held in memory. For preview-sized outputs — the
sizes this proxy is built for — that is the right trade: no extra moving parts,
no dependencies, and a bound that a container can multiply by
`AP_MAX_CONCURRENCY` and reason about.

The escalation, if full-length transcodes ever need it, is the named-pipe
pattern: ffmpeg writes to a `mkfifo`, and Elixir reads it passively with
`IO.binread` in raw mode, where the OS pipe blocking *is* the backpressure (file
reads have run on dirty I/O schedulers since OTP 21). It is a change of
mechanism behind the same consumer contract, which is why it can wait until
there is a measurement asking for it.

## Render policy

A render runs at full speed into the write-back; the client's chunked stream
lags it rather than throttling it. A client listening in real time must not be
able to pin a CPU slot for the duration of the audio.

## Lifecycle

> **Incomplete.** The `SIGTERM` → `SIGKILL` escalation, `AP_RENDER_TIMEOUT`
> enforcement, cancellation and failure classification are the hardening slice
> (`add-ffmpeg-port-pipeline` tasks 1.3 and 1.4). Until then, consumer death and
> application shutdown close the port, which drops the subprocess' stdout and
> usually kills it by `SIGPIPE` — *usually* being exactly the gap that slice
> closes.
