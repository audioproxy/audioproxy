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

**In the running system this high-water mark is not what bounds memory**, and
the reason is the next section. The render's only consumer is the coalescing
coordinator, which retains every byte anyway and therefore acknowledges each
chunk the moment it arrives. The bound that applies is the coordinator's
retention cap. The mechanism above is still what protects a *direct* consumer
of the contract, and is what the FIFO escalation replaces.

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

## Coalescing: one render per cache key

Requests do not reach `AudioProxy.Ffmpeg.Render` directly. They go through
`AudioProxy.RenderCoordinator`, which is a single-flight in front of it: a
`Registry` of unique cache keys, one coordinator process per key, and a
`DynamicSupervisor` holding them. Twenty simultaneous requests for the same
variant run one ffmpeg, not twenty.

Subscribing and starting are the same operation, which is what makes the start
race a non-event. `DynamicSupervisor.start_child/2` either succeeds — this
caller started the render, and is `MISS` — or answers `{:error, {:already_started,
pid}}`, which is `COALESCED` and a join. Nobody has to check whether a render
exists before deciding to start one.

The coordinator broadcasts the consumer contract above, with itself as the
handle, so a consumer written against the render works against the coordinator
unchanged. Two calls differ, because they name a handle:

| Render | Coordinator | Why |
|---|---|---|
| `ack/2` | — | the coordinator retains the bytes and acknowledges for you |
| `cancel/1` | `unsubscribe/1` | one subscriber leaving must not cancel a render the others are reading |

**Late joiners are handed a backlog.** Everything produced so far, in order,
returned by the same call that registers the subscriber — one coordinator
callback, so there is no window in which a chunk could be both broadcast and
backlogged, or neither. The consumer writes the backlog, then the live chunks.

**Retention is the memory bound.** The bytes are held anyway (the variant-cache
slice tees the same ones to storage), so what stops a render growing without
limit is a cap: output past `AP_MAX_SRC_BYTES` fails the render for every
subscriber. That is a source-size limit doing double duty, which is honest for
preview-sized outputs and is the reason the FIFO escalation above is written
down — spooling instead of retaining changes nothing in the contract.

Three ways a coordinator ends, differing in what happens to the key:

- **Done** — the completion is broadcast, then it lingers about a second, still
  registered, so a request that arrives just too late gets the finished bytes
  instead of re-rendering. A straggler past the linger starts a fresh render:
  wasteful, never wrong.
- **Failure** — broadcast to every current subscriber, then the key is
  unregistered *immediately*, so the next request retries rather than attaching
  to a corpse.
- **Last subscriber gone** — nobody is listening, so the subprocess is
  cancelled. `unsubscribe/1` returns only once that has happened, which makes
  it a barrier the way `cancel/1` is. One subscriber dying among several is
  just a removal; the render continues.

`AP_MAX_CONCURRENCY` is not enforced here yet — the semaphore slice acquires a
slot before the coordinator spawns its pipeline and releases it on terminate,
so the slot's lifetime is the subprocess' lifetime and queue waiting happens
before deduplicated work starts. Coalescing already bounds the worst hot-key
case; what is still uncapped is a burst across *distinct* keys.

## Delivery over HTTP

The render endpoint (`AudioProxy.Plugs.RenderAction`) is a consumer of the
contract above and nothing more: it subscribes to the coordinator for its cache
key, writes the catch-up backlog if it was handed one, then loops on the mailbox
writing each chunk with `Plug.Conn.chunk/2`. It reports which it was in
`X-Audio-Proxy`: `MISS` for the request that started the render, `COALESCED` for
one that attached to it.

**Before and after the first byte are different worlds.** Before it, nothing has
been sent and a failure is an ordinary JSON error: the class maps to 404, 415,
500 or 504. After it, the status line is spent, and the only signal HTTP/1.1
leaves is an abnormal close — the connection is torn down without the
terminating chunk, which is what §5 means by "abnormal termination of the
chunked stream". A client that treats a truncated chunked response as a
complete file will believe a failed render succeeded.

**Disconnect is detected by writing.** `chunk/2` answering `{:error, _}` means
the socket is gone, and the request unsubscribes on the spot; whether the render
stops is the coordinator's call, since another client may still be reading the
same variant. That is not the only guarantee — the coordinator monitors its
subscribers and the render monitors its consumer — but it is the prompt one. It
costs a caveat: detection happens on the
*next* chunk, so teardown is bounded by chunk cadence rather than by wall clock.
For an encoder producing output continuously that is milliseconds; for one
stalled on a slow input it is the render timeout, which is the same bound that
applies to a client still listening.

**The endpoint's own deadline is a backstop.** `AP_RENDER_TIMEOUT` is enforced
by the render process, which owns the subprocess and can classify the failure.
The endpoint applies the same budget to its own mailbox, slightly wider, so that
a render dying without a word cannot leave a request hanging — but the timeout a
client normally sees is the render's, with its class intact.
