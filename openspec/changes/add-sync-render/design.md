## Context

Today a MISS is chunked and unseekable, and that is specified behaviour rather than an omission: bytes leave as the encoder produces them, so there is no length to declare and nothing to seek into. The cost lands on the first requester of every variant. `add-variant-cache` fixes the second request onward; it cannot fix the first, and for a long tail of rarely-requested variants nearly every request is a first request.

The question is what mechanism lets a client say "I would rather wait and get something I can seek", without that preference becoming part of the variant's identity.

## Goals / Non-Goals

**Goals:**
- A client that needs seeking can obtain a complete, range-capable response for an uncached variant.
- Byte-identical variants keep one cache key regardless of how they were delivered.
- The work is not wasted: a materialised render populates the store.
- The cost of holding a connection and a render slot is bounded and explicit.

**Non-Goals:**
- Changing what a normal streaming MISS does. The chunked path stays the default and stays unseekable.
- Seeking *during* a render (partial-content over an in-flight encode). That is a different and much larger problem.
- Making this the recommended path. It is a fallback for clients that need seek before a cache exists.

## Decisions

- **Not a processing option, and this is the load-bearing decision.** `sync:1` in the options path would be the obvious spelling and is wrong: the option does not change a single output byte, so two URLs would render identical audio under two cache keys. That breaks the project's rule that every option round-trips to an identical cache key, doubles storage, and halves hit rate. Delivery preferences do not belong in an identifier for content.

- **Trigger: `Range` on a MISS — proposed, then measured, and it does not work for browsers.** The idea was that a client wanting to seek sends `Range`, so honouring it needs no new API surface. Measurement against Chrome killed it. With a logging server and two `<audio>` elements:

  ```
  GET /chunked  | Range="bytes=0-"       <- first load, before any interaction
  GET /seekable | Range="bytes=0-"       <- same
  GET /seekable | Range="bytes=131072-"  <- an actual seek
  GET /chunked  | Range="bytes=0-"       <- "seek" on the unseekable one: a restart
  ```

  Three findings, each closing off a rescue:

  1. **A browser sends `Range: bytes=0-` on the first media request, always.** Treating bare `Range` as the signal would make every `<audio>` playback wait for a full render, destroying streaming for the most common client there is.
  2. **Narrowing the trigger to a non-zero offset does not help.** A chunked response without `Accept-Ranges` marks the element non-seekable — measured `seekable.end(0)` of `0` against `20` for a range-capable response — so the user cannot drag the scrubber and the browser never issues a seek range. The trigger cannot fire for the case that motivated it. To let a browser seek, the *first* response must already carry `Content-Length` and `Accept-Ranges`, which means deciding to materialise before anything is known about intent.
  3. **`<audio src>` cannot set request headers**, so `Prefer: wait` is equally unreachable from HTML. A page author would need `fetch()` plus an object URL, and having fetched the bytes they no longer need the server to materialise anything.

  **Conclusion: there is no trigger that serves a browser.** Any mechanism reaches only clients that construct requests deliberately — scripts, downloaders, ffmpeg. That is a much smaller audience than the player UI this change was written for.

- **What actually serves a browser is warming the cache.** Fetch the URL once and discard it, then set `src`; the second request is a HIT with `Content-Length` and `Accept-Ranges` and seeks normally. Two requests, no new API surface, no held render slot, nothing to build here. It is available to any page author in three lines, and it works today the moment `add-variant-cache` lands.
  - Query parameter: rejected for the same cache-key reason as a path option, plus it would have to be excluded from the signature or it changes URL identity.

- **Materialise means render → store → serve as a HIT.** With a variant store configured, this is not a new delivery path at all: render to completion, write back, then answer from the store using the machinery `add-variant-cache` already builds. That is why this change depends on it. The alternative — a bespoke buffer-and-serve path — would duplicate range handling and metadata for no gain.

- **Without a store, spool to disk, not memory.** A materialising request with no cache configured has to hold the whole variant somewhere. Memory scales with concurrent requests times variant size and is an obvious way to be killed by the OOM killer. A temp file under a configured spool directory, deleted after the response, is the bounded form. If neither store nor spool is available, the request is answered as an ordinary chunked MISS rather than failing: degrading to the documented default beats a 500.

- **A materialising request holds a render slot for the whole render.** With the semaphore in place this is charged normally, so a burst of materialising requests exhausts the pool and later ones queue and then 429 — the existing backpressure, not a new one. Worth stating because the failure mode is invisible otherwise: a handful of long transcodes requested this way can starve streaming clients.

- **`AP_RENDER_TIMEOUT` applies unchanged**, and is the ceiling on how long a connection is held. A render that exceeds it is killed and answered `504`, exactly as a streaming render would be.

## Risks / Trade-offs

- **[Is this worth building at all?] The evidence now says probably not.** The trigger cannot reach a browser (see Decisions), so this feature would serve only clients that build requests deliberately. Those clients can already warm the cache with one discarded request. **The recommendation is to close this change unless a concrete non-browser client needs materialisation and cannot warm.** It is kept on record because the question was worth asking and the measurement is worth not repeating.
- [Held connections are a denial-of-service surface] → bounded by the semaphore, the queue, and `AP_RENDER_TIMEOUT`. The residual risk is that a materialising request is strictly more expensive than a streaming one for the same URL, so an attacker prefers it. Mitigation is the same 429 path; worth measuring before assuming it suffices.
- [Time to first byte becomes the whole render] → the trade the client explicitly asked for. It should still be documented loudly, because a `Range` header is a *quiet* way to opt into a much slower response, and a client that sends `Range` by reflex would get a surprise.
- [Two shapes for a MISS complicates the contract] → API doc §5 gains a second row. Acceptable, but it is the reason this is not simply "always honour Range": the streaming default is the one that makes this project useful, and it must stay the default.
