# Capacity: sizing a container

How much memory one `audio_proxy` container needs, as arithmetic over its
configuration rather than a number somebody once observed.

> **This model describes the in-memory-backlog architecture** — the one where a
> render's output is retained in the coordinator process for the life of the
> render, which is what every released version through **0.3.x** does. If a
> future version spools backlogs to disk, `B_backlog` below stops being the
> dominant term and this page is wrong for that version. Check that the version
> you run matches the banner before you size against it.

## The matrix

Find your workload in a row and your container's memory limit in a column. The
derivation is [below](#the-derivation-output-is-the-hazard-input-is-not) and accounts
for every cell; you do not need it to read one.

Three things the tables assume, all of them deliberate:

- **Worst case, not average.** Every slot busy with that workload at the same
  moment, plus the backlogs still lingering from renders that just finished. It
  is the number that belongs in a memory limit, not the number a dashboard shows.
- **The column is the container's limit, not the machine's.** A VM running
  anything else needs room for it on top.
- **This is a memory bound, not a throughput one.** It answers how many renders
  fit in RAM, not how many a host can encode in parallel — those are different
  limits, and `AP_MAX_CONCURRENCY` defaults to schedulers online for the other
  one. Take the smaller of the two.

<!-- matrix:begin -->

### How many renders fit

Maximum `AP_MAX_CONCURRENCY` whose **worst case** — every slot busy with this
workload at once, plus the backlogs still lingering — fits in the container
memory limit named by the column.

| Output | Variant | 1 GiB | 2 GiB | 4 GiB | 8 GiB | 16 GiB | 32 GiB |
|---|---|---|---|---|---|---|---|
| **30 s** | `f:mp3/br:128` | 24 | 56 | > 64 | > 64 | > 64 | > 64 |
|  | `f:opus/br:96` | 23 | 55 | > 64 | > 64 | > 64 | > 64 |
|  | `f:mp3/br:320` | 23 | 54 | > 64 | > 64 | > 64 | > 64 |
|  | `f:flac` (44.1/16) | 17 | 40 | > 64 | > 64 | > 64 | > 64 |
|  | `f:wav` (44.1/16) | 23 | 54 | > 64 | > 64 | > 64 | > 64 |
|  | `f:wav/bd:24` (48/24) | 19 | 45 | > 64 | > 64 | > 64 | > 64 |
| **10 min** | `f:mp3/br:128` | 30 | > 64 | > 64 | > 64 | > 64 | > 64 |
|  | `f:opus/br:96` | 32 | > 64 | > 64 | > 64 | > 64 | > 64 |
|  | `f:mp3/br:320` | 18 | 45 | > 64 | > 64 | > 64 | > 64 |
|  | `f:flac` (44.1/16) | 8 | 21 | 47 | > 64 | > 64 | > 64 |
|  | `f:wav` (44.1/16) | 5 | 14 | 33 | > 64 | > 64 | > 64 |
|  | `f:wav/bd:24` (48/24) | 3 | 9 | 20 | 43 | > 64 | > 64 |
| **1 h** | `f:mp3/br:128` | 9 | 24 | 53 | > 64 | > 64 | > 64 |
|  | `f:opus/br:96` | 12 | 30 | > 64 | > 64 | > 64 | > 64 |
|  | `f:mp3/br:320` | 4 | 10 | 24 | 50 | > 64 | > 64 |
|  | `f:flac` (44.1/16) | — | 3 | 8 | 19 | 41 | > 64 |
|  | `f:wav` (44.1/16) | — | 1 | 5 | 11 | 25 | 51 |
|  | `f:wav/bd:24` (48/24) | — | — | 2 | 6 | 15 | 31 |
| **2 h** | `f:mp3/br:128` | 5 | 13 | 29 | 62 | > 64 | > 64 |
|  | `f:opus/br:96` | 6 | 17 | 38 | > 64 | > 64 | > 64 |
|  | `f:mp3/br:320` | 1 | 5 | 12 | 26 | 54 | > 64 |
|  | `f:flac` (44.1/16) | — | 1 | 4 | 9 | 20 | 42 |
|  | `f:wav` (44.1/16) | — | — | 2 | 5 | 12 | 25 |
|  | `f:wav/bd:24` (48/24) | **refused** | **refused** | **refused** | **refused** | **refused** | **refused** |

`—` is a workload that does not fit at any concurrency on that limit.
`> 64` means memory has stopped being the binding constraint
and CPU has become it: size those from cores, not from this table. **refused**
is a render whose output crosses the 2 GB
`AP_MAX_SRC_BYTES` retention cap and is killed partway through — there is no
concurrency at which it works, on any host. See
[Long-form lossless](#3-long-form-lossless--fails-the-cap-loudly-by-design).

### How much memory a concurrency needs

The same model read the other way, for an operator who has fixed
`AP_MAX_CONCURRENCY` and is buying a host. Set the container limit at or above
the figure; the [worked examples](#worked-examples) round up to the next
convenient size, and so should you.

| Output | Variant | C = 1 | C = 2 | C = 4 | C = 8 | C = 16 | C = 32 |
|---|---|---|---|---|---|---|---|
| **30 s** | `f:mp3/br:128` | 292 MiB | 323 MiB | 387 MiB | 514 MiB | 767 MiB | 1.2 GiB |
|  | `f:opus/br:96` | 292 MiB | 324 MiB | 388 MiB | 517 MiB | 773 MiB | 1.3 GiB |
|  | `f:mp3/br:320` | 293 MiB | 326 MiB | 392 MiB | 525 MiB | 789 MiB | 1.3 GiB |
|  | `f:flac` (44.1/16) | 304 MiB | 348 MiB | 436 MiB | 613 MiB | 965 MiB | 1.6 GiB |
|  | `f:wav` (44.1/16) | 293 MiB | 326 MiB | 392 MiB | 525 MiB | 789 MiB | 1.3 GiB |
|  | `f:wav/bd:24` (48/24) | 299 MiB | 339 MiB | 418 MiB | 576 MiB | 892 MiB | 1.5 GiB |
| **10 min** | `f:mp3/br:128` | 309 MiB | 334 MiB | 383 MiB | 481 MiB | 677 MiB | 1.0 GiB |
|  | `f:opus/br:96` | 305 MiB | 328 MiB | 373 MiB | 463 MiB | 644 MiB | 1005 MiB |
|  | `f:mp3/br:320` | 337 MiB | 375 MiB | 451 MiB | 605 MiB | 911 MiB | 1.5 GiB |
|  | `f:flac` (44.1/16) | 420 MiB | 499 MiB | 659 MiB | 978 MiB | 1.6 GiB | 2.8 GiB |
|  | `f:wav` (44.1/16) | 485 MiB | 597 MiB | 822 MiB | 1.2 GiB | 2.1 GiB | 3.9 GiB |
|  | `f:wav/bd:24` (48/24) | 613 MiB | 789 MiB | 1.1 GiB | 1.8 GiB | 3.2 GiB | 5.9 GiB |
| **1 h** | `f:mp3/br:128` | 401 MiB | 471 MiB | 612 MiB | 893 MiB | 1.4 GiB | 2.5 GiB |
|  | `f:opus/br:96` | 374 MiB | 431 MiB | 544 MiB | 772 MiB | 1.2 GiB | 2.1 GiB |
|  | `f:mp3/br:320` | 565 MiB | 718 MiB | 1.0 GiB | 1.6 GiB | 2.8 GiB | 5.2 GiB |
|  | `f:flac` (44.1/16) | 1.0 GiB | 1.4 GiB | 2.1 GiB | 3.6 GiB | 6.6 GiB | 12.6 GiB |
|  | `f:wav` (44.1/16) | 1.5 GiB | 2.1 GiB | 3.3 GiB | 5.7 GiB | 10.5 GiB | 20.1 GiB |
|  | `f:wav/bd:24` (48/24) | 2.2 GiB | 3.2 GiB | 5.1 GiB | 9.0 GiB | 16.9 GiB | 32.5 GiB |
| **2 h** | `f:mp3/br:128` | 511 MiB | 636 MiB | 886 MiB | 1.4 GiB | 2.3 GiB | 4.3 GiB |
|  | `f:opus/br:96` | 456 MiB | 554 MiB | 750 MiB | 1.1 GiB | 1.9 GiB | 3.4 GiB |
|  | `f:mp3/br:320` | 840 MiB | 1.1 GiB | 1.7 GiB | 2.8 GiB | 5.1 GiB | 9.6 GiB |
|  | `f:flac` (44.1/16) | 1.7 GiB | 2.4 GiB | 3.9 GiB | 6.8 GiB | 12.7 GiB | 24.4 GiB |
|  | `f:wav` (44.1/16) | 2.6 GiB | 3.8 GiB | 6.2 GiB | 11.0 GiB | 20.6 GiB | 39.7 GiB |
|  | `f:wav/bd:24` (48/24) | **refused** | **refused** | **refused** | **refused** | **refused** | **refused** |

Both tables assume plain renders. `norm` (single-pass `loudnorm`) adds roughly
55 MiB per slot — `R_ffmpeg` goes from about 11 MiB to about
66 MiB. On the preview rows that is most of the per-slot
cost and divides them by about five; on the long-form rows it disappears into
the backlog term.

Generated by `bin/capacity-matrix` from the formula below and the measured
[`R_ffmpeg` table](#measured-r_ffmpeg); do not edit by hand.

<!-- matrix:end -->

### What is not in the matrix, and why

Two adjustable variables are absent, and their absence is a finding rather than
an omission.

**`AP_QUEUE_SIZE` costs approximately nothing.** A queued request is waiting for
a slot: it holds no ffmpeg subprocess, no backlog and no pipeline buffer — a few
kilobytes of coordinator state and a parked connection. Nothing in the formula
scales with it. Sizing the queue is a **latency and `429` decision** (how long a
client should wait before being told to come back), not a memory one, so it does
not get a column here. Set it from how long your clients will tolerate waiting.

**`AP_MAX_SRC_BYTES` bounds one render, not the total.** It caps the bytes a
*single* render may retain, which is why it decides whether a cell reads
**refused**. It does not bound `C × B_backlog`, so it cannot be used as a
container memory limit: eight renders each staying just under a 2 GB cap is 16 GB.
The lever that bounds the total is `AP_MAX_CONCURRENCY`, and the cap's other job
— rejecting oversized *sources* — pulls in the opposite direction. See
[`AP_MAX_SRC_BYTES` does two jobs](#ap_max_src_bytes-does-two-jobs-and-they-pull-in-opposite-directions).

## The derivation: output is the hazard, input is not

Everything from here down is where the cells above come from. It is worth
reading before trusting them with a production limit, and it is not worth
reading to find a number.

The instinct when sizing a transcoding proxy is to ask how large the source
files are. That instinct is wrong here, and it is worth getting rid of before
reading the formula.

**Input never accumulates.** Source bytes do not pass through the BEAM at all.
`audio_proxy` hands ffmpeg a URL — a presigned S3 URL, an `https://` origin, a
path under `AP_LOCAL_ROOT` — and ffmpeg reads it itself, streaming through
fixed-size buffers and issuing its own Range requests. A two-hour, 1.3 GB WAV
master and a thirty-second clip cost the same resident memory to *read*. There
is no term in the model for source size, and the measured table below is the
evidence: the two-hour rows land within a few megabytes of the sixty-second
ones.

**Output accumulates, all of it, until the render ends.**
`AudioProxy.RenderCoordinator` retains every chunk ffmpeg emits, in memory, for
the whole render — that is what lets a second request for the same variant join
a render already in flight and still receive a complete stream. Nothing trims
the backlog as clients consume it, because a client that has not arrived yet
would need the bytes an existing client already read. So the memory one render
costs is the size of the *variant it produces*, and a variant's size is
duration × bitrate.

That asymmetry is the whole story. Sizing this proxy is sizing its outputs.

## The formula

```
RAM  ≈  BEAM_base  +  T_ffmpeg  +  (C + L) × (R_ffmpeg + B_backlog + H_pipeline)  +  U × part_size
```

| Term | What it is | Where it comes from | Value |
|---|---|---|---|
| `BEAM_base` | The release at rest: ERTS, the supervision tree, Bandit's acceptors | Measured on the runtime image, idle and healthy | **≈ 110 MiB** anonymous |
| `T_ffmpeg` | ffmpeg's shared library text, resident while any render runs | Measured; paid **once**, not per render — see [Why it is not multiplied](#t_ffmpeg-is-paid-once) | **50–130 MiB**; budget 150 MiB, reclaimable |
| `C` | Simultaneous ffmpeg processes | `AP_MAX_CONCURRENCY` (default: schedulers online) | your setting |
| `L` | Completed renders still holding their backlog | `@linger` in `AudioProxy.RenderCoordinator`, **1 s** | see [Why `C` is not enough](#why-c-is-not-enough-the-linger-window) |
| `R_ffmpeg` | Private (anonymous) peak of one ffmpeg subprocess | Measured; [table below](#measured-r_ffmpeg) | 10–18 MiB plain, 64–74 MiB with `norm` |
| `B_backlog` | Retained output bytes for one render | `AudioProxy.RenderCoordinator.retain/2`, capped by `AP_MAX_SRC_BYTES` | `min(variant size, AP_MAX_SRC_BYTES)` |
| `H_pipeline` | Forwarded-but-unacknowledged bytes plus the port's read queue | `@high_water` in `AudioProxy.Ffmpeg.Render`, **1 MiB** | ≤ 1 MiB, and in practice far less |
| `U` | In-flight S3 write-back uploads | Not reachable today — see [The S3 write-back term](#the-s3-write-back-term) | **0** with a `file://` store |
| `part_size` | Bytes buffered per multipart part | `@part_size` in `AudioProxy.S3`, **5 MiB** | 5 MiB, when `U > 0` |

Everything here is a **worst case**, and deliberately so: it is the number that
belongs in a container memory limit, not the number you expect to see in a
dashboard.

### `T_ffmpeg` is paid once

The ffmpeg binary is 388 KB and the libraries behind it are 195 MB — libavcodec
carries every decoder Debian builds. Those are file-backed pages, and every
concurrent ffmpeg maps the *same* physical copy: eight renders do not cost eight
libavcodecs. So the library text is a flat term next to `BEAM_base` rather than
part of the per-render bracket, and `R_ffmpeg` in the table below is deliberately
the **anonymous** (private) peak, which is the memory one *additional* render
actually costs.

Only the pages actually touched become resident, so the term is a range rather
than a number: 47 MiB measured for a single MP3 encode, around 130 MiB for
containers exercising more of the codec surface, against a hard ceiling of the
195 MB on disk. Budget **150 MiB** and treat a deployment using every format as
the upper end. It is reclaimable — under pressure the kernel drops clean file
pages and re-reads them rather than OOM-killing — so it is headroom, not a
working set.

This is the one term in the model that is a judgement rather than a reading, and
it is worth knowing why it cannot be measured on demand. What any single
measurement captures is not the size of the library working set but *how much of
it that particular container had to fault in*, which depends entirely on what ran
before it. The same probe returns 47–93 MiB on a developer machine with a cold
cache and 2.8 MiB on a CI runner where an earlier container had already warmed
the same libraries — a thirty-fold spread with nothing behind it but cache
history. A long-lived proxy container is the cold-cache case that keeps its pages,
so 150 MiB is the figure to size against. `bin/check-capacity` predicts from that
budget and prints what its host happened to charge beside it, precisely so the
two can be seen to disagree.

Getting this wrong in either direction is the most expensive mistake available
here: multiplying it inflates a 16-slot estimate by two gigabytes of memory
nobody needs to buy, and dropping it under-sizes every deployment by the same
150 MiB.

### `B_backlog` is the term that matters

The other terms are tens of megabytes. This one is the size of a variant, and a
variant can be a gigabyte.

| Variant | Bitrate | 30 s preview | 60 min | 120 min |
|---|---|---|---|---|
| `f:mp3/br:128` | 128 kbps | 480 KB | 58 MB | 115 MB |
| `f:opus/br:96` | 96 kbps | 360 KB | 43 MB | 86 MB |
| `f:mp3/br:320` | 320 kbps | 1.2 MB | 144 MB | 288 MB |
| `f:flac` (44.1/16 stereo) | ~850 kbps | 3.2 MB | 380 MB | 760 MB |
| `f:wav` (44.1/16 stereo) | 1411 kbps | 5.3 MB | 635 MB | **1.27 GB** |
| `f:wav/bd:24` (48/24 stereo) | 2304 kbps | 8.6 MB | 1.04 GB | **2.07 GB** |

A preview-shaped deployment never notices this term. A long-form deployment is
sized by it and nothing else.

### Why `C` is not enough: the linger window

`AP_MAX_CONCURRENCY` caps *encoders*, not retained backlogs, and the two come
apart at the end of a render. When ffmpeg exits, `RenderCoordinator` releases
its semaphore slot immediately — a finished render should not hold a CPU slot
while its bytes are served from memory — and then lingers for one second so a
late request can still be served from the completed buffer.

During that second the coordinator holds its **entire backlog** while a fresh
render already occupies the slot it gave up. So the number of full backlogs
resident at once is `C + L`, where `L` is however many renders finished within
the last second:

```
L  ≤  C × (1 s / typical render duration)
```

- **Short renders** (previews finishing in well under a second): budget `L = C`,
  i.e. size for `2C` backlogs. The linger window can hold a complete second's
  worth of turnover.
- **Long-form renders** (a two-hour transcode taking a minute or more): `L` is a
  rounding error. Budget `L = 1` and move on.

This is a real term, not a theoretical one, and it is the most common way an
otherwise correct hand-calculation comes out a factor of two low.

## Measured `R_ffmpeg`

Peak **anonymous** memory of one ffmpeg subprocess — the private cost of one
more render — by output format and by whether `norm` (single-pass `loudnorm`,
the heaviest filter the API offers) is applied. Shared library text is `T_ffmpeg`
above and is deliberately not in these figures. Produced by
`bin/measure-ffmpeg-rss` against the ffmpeg the runtime image ships; see
[Regenerating this table](#regenerating-this-table).

<!-- rss-table:begin -->

| Variant | Options | Source | Peak RSS |
|---|---|---|---|
| mp3 | `f:mp3/br:128` | 60 s | 10.9 MiB |
| mp3 + norm | `f:mp3/br:128/norm:ebu` | 60 s | 64.5 MiB |
| opus | `f:opus/br:128` | 60 s | 11.1 MiB |
| opus + norm | `f:opus/br:128/norm:ebu` | 60 s | 66.8 MiB |
| ogg | `f:ogg/br:128` | 60 s | 11.4 MiB |
| ogg + norm | `f:ogg/br:128/norm:ebu` | 60 s | 67.4 MiB |
| aac | `f:aac/br:128` | 60 s | 11.5 MiB |
| aac + norm | `f:aac/br:128/norm:ebu` | 60 s | 65.0 MiB |
| m4a | `f:m4a/br:128` | 60 s | 11.5 MiB |
| m4a + norm | `f:m4a/br:128/norm:ebu` | 60 s | 65.1 MiB |
| flac | `f:flac` | 60 s | 17.7 MiB |
| flac + norm | `f:flac/norm:ebu` | 60 s | 73.5 MiB |
| wav | `f:wav` | 60 s | 10.5 MiB |
| wav + norm | `f:wav/norm:ebu` | 60 s | 55.8 MiB |
| mp3 128k | `f:mp3/br:128` | **2.0 h** | **14.4 MiB** |
| opus 96k | `f:opus/br:96` | **2.0 h** | **14.7 MiB** |
| flac | `f:flac` | **2.0 h** | **18.0 MiB** |
| mp3 128k + norm | `f:mp3/br:128/norm:ebu` | **2.0 h** | **64.7 MiB** |

Peak **anonymous** memory — the private cost of one more render, which is what the model multiplies by concurrency. Measured on `linux/arm64` against ffmpeg `7.1.5-0+deb13u1` from the pinned runtime image: the highest of 3 sampled runs per row, probe baseline subtracted. Regenerate with `bin/measure-ffmpeg-rss`.

<!-- rss-table:end -->

Two things to read out of it:

- **`norm` costs roughly 55 MiB more, flat.** Single-pass `loudnorm` buffers
  audio to measure loudness before it can correct it, and resamples to 192 kHz to
  do so (see [ffmpeg-arguments.md](ffmpeg-arguments.md) for why the filter order
  is what it is). That is a fixed window, not a growing one — the two-hour `norm`
  row costs the same as the sixty-second one — but it is several times the cost
  of an unfiltered render, so a deployment where every request carries `norm`
  should size `R_ffmpeg` from the filtered column and not the plain one.
- **Duration does not appear.** The bolded long-form rows are within a few
  megabytes of the sixty-second ones, and the small gap is sampling coverage
  rather than growth: a two-hour encode is polled a thousand times and a
  sixty-second one a few dozen, so the long rows simply get closer to the true
  peak. The claim being tested is not subtle — if output accumulated in ffmpeg
  the way it accumulates in the backlog, the two-hour MP3 row would read 115 MiB
  rather than 14. This is "input never accumulates", measured rather than argued.

A note on how the numbers are taken, because the obvious method does not work.
cgroup `memory.peak` counts page cache, and ffmpeg's library text *is* page
cache, charged to whichever container faults it in first — the same flac encode
measured anywhere from 20 MiB to 148 MiB on that basis alone, an outlier that
reads exactly like a finding about flac and is not one. The script therefore
samples anonymous memory during the encode and reports the highest sample across
several runs, which is both reproducible and the quantity the model actually
needs. It refuses to publish a row that looks like a missed sample rather than
quietly writing a small number into a table operators size containers from.

## The S3 write-back term

`U × part_size` is in the formula because the model should not need rewriting
when the S3 variant store lands, but **it is zero on every version that carries
this document**. The only merged `AP_VARIANT_STORE` backend is `file://`, which
streams to a staging file on disk and buffers nothing in memory beyond one
chunk.

When an `s3://` store does land it will upload through `AudioProxy.S3`, whose
multipart path groups the stream into parts of exactly `@part_size` — 5 MiB — and
holds one part at a time per upload. `U` is then the number of write-backs in
flight, which is bounded by `C + L` for the same reason the backlog term is: one
tee per coordinator. Add 5 MiB per concurrent render and the model still holds.

## Coalescing does not multiply the cost

`N` clients requesting the same variant while it renders do **not** cost `N`
backlogs. `AudioProxy.RenderCoordinator` runs one render per cache key and
broadcasts each chunk to every subscriber; on the BEAM a binary of more than 64
bytes is reference-counted and shared, so a broadcast `send` copies a pointer
rather than the audio. Ten subscribers to one render cost one backlog plus ten
small process heaps.

The coalescing suite's byte-identical-stream tests are the evidence that every
subscriber really does receive the same bytes from the same render; this document
does not re-prove it.

One caveat, because it is the exception that proves the rule: a client that
*joins* a render already in flight is handed the backlog-so-far as a single
contiguous binary (`IO.iodata_to_binary/1` in
`AudioProxy.Plugs.RenderAction`), which is one transient copy of however much
had accumulated at the moment it joined. It is freed as soon as the chunk is
written to the socket, and it does not recur — every subsequent chunk is shared.
For preview-sized variants it is invisible. For a long-form render being joined
late by many clients at once, it is worth knowing that the peak can briefly
exceed the model by roughly one backlog per simultaneous joiner.

## `AP_MAX_SRC_BYTES` does two jobs, and they pull in opposite directions

There is no separate backlog knob. `AP_MAX_SRC_BYTES` (default
`2000000000` — 2 GB) is checked twice:

1. Against the **source** size, before a render starts — an oversized source is
   refused with `413`.
2. Against the **cumulative output** bytes, inside
   `RenderCoordinator.retain/2` — a render whose output crosses the cap is
   killed and the request fails.

So lowering it to bound memory also lowers the largest source you will accept,
and raising it to accept large masters also raises the memory one render may
consume. A deployment serving two-hour WAV masters as MP3 previews needs the cap
*above* 1.3 GB to accept the source, which means it is not bounding the backlog
to anything useful, and the real bound has to come from `AP_MAX_CONCURRENCY`
instead.

The default is 2 GB, which is not a memory bound in any meaningful sense: with
the default `AP_MAX_CONCURRENCY` on an 8-core host, the model's worst case is
over 16 GB. **A deployment that has not thought about this has not been sized.**

## Worked examples

These are the matrix's proof rather than its substitute: the same arithmetic,
done by hand, on three shapes worth understanding. Where an example reads a
little lower than the corresponding cell, it is because each one takes
`R_ffmpeg` from the row for *its own* format while the matrix takes the largest
row that format has — a matrix cannot know which of your renders is the long
one, so it assumes all of them are.

### 1. Previews, the shape the defaults assume

30-second MP3 and Opus previews, `AP_MAX_CONCURRENCY=8`, no `norm`, `file://`
store.

```
B_backlog   = 480 KB          (30 s at 128 kbps, the larger of the two)
R_ffmpeg    = 11 MiB          (mp3, from the table)
H_pipeline  = 1 MiB
per render  ≈ 12.5 MiB

renders     = C + L = 8 + 8 = 16      (short renders: budget L = C)
             16 × 12.5 MiB = 200 MiB

RAM ≈ 110 MiB (BEAM) + 150 MiB (T_ffmpeg) + 200 MiB ≈ 460 MiB
```

**Set the container limit to 768 MiB.** The backlog term is nothing here; this
deployment is sized by the BEAM, ffmpeg's libraries, and eight copies of a small
encoder. Note that the two flat terms together are larger than everything
concurrency contributes — which is why a preview deployment gets cheaper per
slot as it grows, and why halving `AP_MAX_CONCURRENCY` here saves very little.

### 2. Long-form lossy — feasible, and a decision

Two-hour podcast episodes rendered full-length as `f:mp3/br:128`,
`AP_MAX_CONCURRENCY=16`, no `norm`.

```
B_backlog   = 115 MB ≈ 110 MiB        (7200 s at 128 kbps)
R_ffmpeg    = 11 MiB
H_pipeline  = 1 MiB
per render  ≈ 122 MiB

renders     = C + L = 16 + 1 = 17     (long renders: L is a rounding error)
             17 × 122 MiB ≈ 2.0 GiB

RAM ≈ 110 MiB (BEAM) + 150 MiB (T_ffmpeg) + 2.0 GiB ≈ 2.3 GiB
```

**Set the container limit to 3 GiB.** Opus at 96 kbps is 86 MB per episode
instead of 115 MB and brings the same calculation to ≈ 1.8 GiB. Both flat terms
have become noise: at full length the backlog is 90 % of the bill.

This is feasible, and it is a decision rather than a default: sixteen concurrent
full-length renders is two gigabytes of audio held in memory purely so that a
second listener requesting the same episode can join mid-render. If that
coalescing benefit is not worth the RAM for your traffic, the lever is
`AP_MAX_CONCURRENCY` — halve it and halve the memory, at the cost of queueing
(and `429`s past `AP_QUEUE_SIZE`).

### 3. Long-form lossless — fails the cap, loudly, by design

Two-hour masters rendered full-length as `f:wav/bd:24` at 48 kHz stereo.

```
B_backlog   = 2.07 GB per render      — and AP_MAX_SRC_BYTES defaults to 2.0 GB
```

A single render exceeds the retention cap before it finishes. What happens is
not a slow degradation: `retain/2` returns an error partway through, the render
is killed, and the request fails with

```
render output exceeded the 2000000000-byte retention cap (AP_MAX_SRC_BYTES)
```

This is the intended behaviour and the right one — the alternative is a
container that runs until the kernel OOM-kills it, taking every other in-flight
render with it. But it means **full-length lossless output is not a workload
this architecture serves**, whatever you set the cap to: raising it to 4 GB makes
one render succeed and two concurrent ones exhaust an 8 GiB container.

What to do instead, in order of preference:

1. **Serve lossless as trimmed excerpts.** A `t:` option bounds the output, and
   the model bounds with it. Five-minute excerpts of 24-bit WAV are 86 MB each.
2. **Serve full length in a lossy format**, per example 2.
3. **Wait for the spooled backlog.** The escalation named in `CLAUDE.md` — the
   coordinator writing its backlog to a scratch file rather than holding it,
   with clients reading from the file — removes `B_backlog` from the model
   entirely and makes full-length lossless a disk question instead of a memory
   one. It is not built. It is an on-demand change for a deployment whose
   primary workload is long-form lossless, and it rewrites this page when it
   lands.

## What this model does not cover

- **Page cache.** A `local://` source or a `file://` variant store reads and
  writes through the page cache, which the kernel charges to the container's
  cgroup and which `memory.peak` therefore counts — a workload can show
  hundreds of megabytes above the model's prediction with none of it in use.
  It is reclaimable: under pressure the kernel drops it rather than OOM-killing.
  The model does not try to predict it, and the CI guard subtracts it (see
  below) rather than modelling it.
- **Disk.** A `file://` variant store grows without bound; nothing in
  `audio_proxy` expires it. That is a separate sizing question with a separate
  answer (a CDN, or a lifecycle rule on the bucket).
- **CPU and throughput.** How many renders per second a container sustains is a
  different calculation. `AP_MAX_CONCURRENCY` defaults to schedulers online for
  a reason, and raising it to buy memory headroom is not free.

## How this page is kept honest

Three mechanisms, because a capacity document that drifts is worse than none.

**The matrix is generated, and then checked against itself.** Every cell at the
top of this page is `bin/capacity-matrix` evaluating the formula below over the
measured table below, using constants it shares with the CI guard
(`bin/capacity_model.rb` — one copy, required by both). A hand-maintained matrix
would be a second copy of the model, and the second copy is the one that goes
stale.

Generating it is not quite enough, though, because the matrix runs the model
*backwards* and an inversion is the easy thing to get subtly wrong — an
off-by-one in the linger term, a rounding that goes up, a short-render row halved
on the wrong side of the division. Each of those produces a table that looks
entirely reasonable and over-promises. So `bin/capacity-matrix --verify` checks
the two directions against each other on every cell: the published concurrency
must fit the column's limit, and one more slot must not. CI runs it, and it needs
no image. It has already earned its place — it caught the published figures
losing a slot to floating-point residue in about a fifth of the cells.

**The measured table is regenerated from the image.** `bin/measure-ffmpeg-rss`
takes its ffmpeg from the pinned runtime image and its argv from
`AudioProxy.Ffmpeg.Command`, so it cannot be stale about the encoder or about
the arguments the encoder is handed.

**CI runs the model against the built image.** `bin/check-capacity` starts the
release container with a known configuration, drives a concurrent workload
through it — including a two-hour source, which is where the model has the most
to be wrong about — and asserts that the container's cgroup `memory.peak`, minus
reclaimable page cache, stays under the prediction this page's formula makes for
that configuration.

On the reference workload — four concurrent two-hour MP3 renders plus eight short
ones, `AP_MAX_CONCURRENCY=4` — the model predicted 955 MiB and the container
peaked at 748 MiB adjusted: **78 % of the prediction**, on arm64.

Read that as the model being deliberately conservative rather than merely
approximate, and the conservatism is almost entirely one term. Sizing `T_ffmpeg`
at its 150 MiB budget when a given host charges 47 MiB accounts for most of the
gap; strike that difference out and the remaining terms land within about ten per
cent of the observation. Which is the property that matters — the formula is
right about `B_backlog`, the term that decides whether a long-form deployment
fits, and it errs high on the flat term where erring high costs a reader nothing
but a slightly larger container.

The guard's tolerance is a stated **1.5× headroom factor** on the prediction, and
the factor is written down here rather than buried so that nobody mistakes it for
precision. It covers BEAM allocator slack (the BEAM returns freed binaries to the
OS lazily), reference-counted binary collection lag, and CPU-architecture
variation between the arm64 the table was measured on and the amd64 CI runs. It
does not cover a new term appearing in the model — which is the point. A guard
loose enough never to fire is not a guard.

The workload is a sample, not an exhaustive search: it validates the model's
*shape* — that the terms are the right terms and the coefficients are the right
size — not every configuration an operator could choose. A failing guard means
the model has stopped describing the code, and the fix is to reconcile the two,
not to widen the factor.

## Regenerating these tables

The two measuring scripts need docker and a cgroup v2 host (`memory.peak`,
kernel ≥ 5.19); none of them needs ffmpeg or Elixir installed. `bin/capacity-matrix`
needs nothing at all — it is arithmetic over this document and a constants file.

```bash
# Measure R_ffmpeg on the current image and rewrite the measured table in place.
bin/measure-ffmpeg-rss --write docs/capacity.md

# Reuse already-built images (much faster while iterating).
SKIP_BUILD=1 bin/measure-ffmpeg-rss --write docs/capacity.md

# Regenerate the matrix from that table. Always second: it reads what the line
# above wrote.
bin/capacity-matrix --write docs/capacity.md

# Print the matrix without touching the document.
bin/capacity-matrix

# Assert every published cell inverts the model. No docker, under a second.
bin/capacity-matrix --verify

# Run the workload guard the way CI does.
SKIP_BUILD=1 bin/check-capacity

# Prove the guard still has teeth (asserts a retention-blind model is rejected).
SKIP_BUILD=1 bin/check-capacity --self-test
```

A different ffmpeg encodes differently and holds different memory, so
**regenerating both tables is a step in the pin-bump procedure** — see
[VERSIONS.md](../VERSIONS.md#bumping-a-pin).
