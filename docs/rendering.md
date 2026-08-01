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

A render runs at full speed; the client's chunked stream lags it rather than
throttling it. A client listening in real time must not be able to pin a CPU
slot for the duration of the audio.

The write-back this policy was written for does not exist yet — there is no
variant bucket and no tee, so today "full speed" means only that the encoder is
never paced by the socket. The policy is what the write-back will land into
(`add-variant-cache`), not something already running.

## Lifecycle: no ffmpeg outlives its render

This is the guarantee the module is arranged around, because the failure it
prevents is the expensive one: an orphaned encoder holds a CPU slot, and a
proxy that leaks one per cancelled request degrades until it is restarted.

Every way a render can end — a clean finish, `cancel/1`, the timeout, a dead
consumer, the supervisor shutting down at VM stop — arrives at the same
`terminate/2`, which is why exits are trapped: shutdown becomes one of the
ordinary paths rather than an exception to them. From there:

1. close the port,
2. `SIGTERM` the subprocess,
3. `SIGKILL` after a two-second grace, if it is still there.

**Closing the port is not enough on its own**, and that is the whole reason for
steps 2 and 3. The BEAM does not signal the process on the far side of a closed
port. An ffmpeg blocked reading a slow HTTP input may not touch its stdout for
minutes, never notice that nobody is listening, and sit there holding a slot.
Measured on this project: a `SIGTERM`-ignoring subprocess survives
`Port.close/1` indefinitely.

The grace is a trade. Two seconds is long enough for ffmpeg to flush and close
cleanly, short enough that a cancelled request is not noticeably held open.
Within that window a PID could in principle be reused and the `SIGKILL` land on
an innocent process; on any real system the window makes that implausible, and
the alternative — never escalating — is the orphan this exists to prevent.

## Timeout

A render exceeding `AP_RENDER_TIMEOUT` (seconds, default 300) is killed by the
same discipline and reported as `:timeout`, which the HTTP layer maps to 504.
The timer is armed at spawn from configuration, so an operator raising the
limit for long masters changes one environment variable and nothing else.

## Failure classification

ffmpeg exits 1 for almost everything, so the exit status alone cannot separate
"the file isn't there" from "the file isn't audio" — and those want different
HTTP statuses. The class therefore comes from matching a bounded tail of
stderr:

| Class | Recognised from | HTTP |
|---|---|---|
| `:not_found` | `No such file or directory`, `Server returned 404`, `403`/`Forbidden` | 404 |
| `:undecodable` | `Invalid data found when processing input`, `could not find codec parameters` | 415 |
| `:timeout` | the render timer, not stderr | 504 |
| `:cancelled` | `cancel/1` | — the client has already gone |
| `:render_failed` | anything else | 500 |

The consumer receives `%{class: _, exit_status: _, stderr: _}`. Keeping the raw
tail alongside the class matters: the class is what the proxy acts on, the tail
is what an operator needs when the class is `:render_failed` and the question
is *why*.

stderr goes to a per-render file in a scratch directory, never merged into
stdout — merging would splice diagnostics into the audio. Only the last 4 KiB
is read back, so a decoder in a complaining mood cannot turn a failed render
into a memory problem. Each render deletes its own file, and the supervisor
sweeps the directory at boot for the renders that died with the VM.

One note on how that file is arranged, since it is the only place a shell
appears in a project that otherwise forbids them. Erlang ports offer stdout, or
stdout with stderr merged in, and nothing else: there is no port option for
redirecting stderr to a file. So the subprocess is spawned as

```
/bin/sh -c 'exec "$0" "$@" 2>"$AP_RENDER_STDERR"' <binary> <args…>
```

The script is a compile-time constant with no user data in it. The binary
arrives as `$0`, its arguments as `"$@"`, and the path through the environment,
so a source URL full of metacharacters is quoted shell *data* and never shell
text. `exec` then replaces the shell with ffmpeg, which means the pid the kill
discipline signals is ffmpeg's own and there is no intermediate process left to
orphan.

## Delivery over HTTP

The render endpoint (`AudioProxy.Plugs.RenderAction`) is a consumer of the
contract above and nothing more: it spawns a render with itself as consumer,
then loops on the mailbox, writing each chunk with `Plug.Conn.chunk/2` and
acknowledging it. Acknowledging is not bookkeeping — forwarding stops above the
high-water mark, so a loop that stopped acking would receive one buffer's worth
of audio and then silence, `{:done, _, _}` included.

The spawn is deliberately a single call site. Coalescing replaces exactly that
call with a subscription to a shared render; the message contract is the same,
so the loop does not change.

**Before and after the first byte are different worlds.** Before it, nothing has
been sent and a failure is an ordinary JSON error: the class maps to 404, 415,
500 or 504. After it, the status line is spent, and the only signal HTTP/1.1
leaves is an abnormal close — the connection is torn down without the
terminating chunk, which is what §5 means by "abnormal termination of the
chunked stream". A client that treats a truncated chunked response as a
complete file will believe a failed render succeeded.

**Disconnect is detected by writing.** `chunk/2` answering `{:error, _}` means
the socket is gone, and the render is cancelled on the spot. That is not the
only guarantee — the render monitors its consumer and kills the subprocess when
it dies — but it is the prompt one. It costs a caveat: detection happens on the
*next* chunk, so teardown is bounded by chunk cadence rather than by wall clock.
For an encoder producing output continuously that is milliseconds; for one
stalled on a slow input it is the render timeout, which is the same bound that
applies to a client still listening.

**The endpoint's own deadline is a backstop.** `AP_RENDER_TIMEOUT` is enforced
by the render process, which owns the subprocess and can classify the failure.
The endpoint applies the same budget to its own mailbox, slightly wider, so that
a render dying without a word cannot leave a request hanging — but the timeout a
client normally sees is the render's, with its class intact.
