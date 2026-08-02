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

- **Trigger: a `Range` header on a MISS.** Preferred mechanism, because it requires no new API surface and matches what clients already do. A browser that wants to seek sends `Range`; today it is ignored and answered with a chunked `200`. Honouring it means: materialise the variant, then answer `206`. The client asked a question that only a complete object can answer, and gets one.
  - Weighed against an explicit request header (`Prefer: wait`, or `X-Audio-Proxy-Sync: 1`). That is more precise and allows a non-Range client to opt in, but adds surface, needs a `Vary` for correctness behind a CDN, and duplicates a signal HTTP already has. **Recommendation: honour `Range` first; add an explicit header only if a real client needs materialisation without wanting a byte range.**
  - Weighed against a query parameter: rejected for the same cache-key reason as a path option, plus it would have to be excluded from the signature or it changes the URL identity.

- **Materialise means render → store → serve as a HIT.** With a variant store configured, this is not a new delivery path at all: render to completion, write back, then answer from the store using the machinery `add-variant-cache` already builds. That is why this change depends on it. The alternative — a bespoke buffer-and-serve path — would duplicate range handling and metadata for no gain.

- **Without a store, spool to disk, not memory.** A materialising request with no cache configured has to hold the whole variant somewhere. Memory scales with concurrent requests times variant size and is an obvious way to be killed by the OOM killer. A temp file under a configured spool directory, deleted after the response, is the bounded form. If neither store nor spool is available, the request is answered as an ordinary chunked MISS rather than failing: degrading to the documented default beats a 500.

- **A materialising request holds a render slot for the whole render.** With the semaphore in place this is charged normally, so a burst of materialising requests exhausts the pool and later ones queue and then 429 — the existing backpressure, not a new one. Worth stating because the failure mode is invisible otherwise: a handful of long transcodes requested this way can starve streaming clients.

- **`AP_RENDER_TIMEOUT` applies unchanged**, and is the ceiling on how long a connection is held. A render that exceeds it is killed and answered `504`, exactly as a streaming render would be.

## Risks / Trade-offs

- **[Is this worth building at all?]** The honest counter-argument: once `add-variant-cache` ships, a client that needs seeking can request the variant, discard the response, and request again — two requests, no new API, no held slot. That is ugly but free, and it is what a CDN-fronted deployment does naturally on the second hit. This change earns its place only if first-request seeking matters for real players. **Decide with a real client before implementing.** The proposal is recorded now because the question arose from a real observation, not because the answer is settled.
- [Held connections are a denial-of-service surface] → bounded by the semaphore, the queue, and `AP_RENDER_TIMEOUT`. The residual risk is that a materialising request is strictly more expensive than a streaming one for the same URL, so an attacker prefers it. Mitigation is the same 429 path; worth measuring before assuming it suffices.
- [Time to first byte becomes the whole render] → the trade the client explicitly asked for. It should still be documented loudly, because a `Range` header is a *quiet* way to opt into a much slower response, and a client that sends `Range` by reflex would get a surprise.
- [Two shapes for a MISS complicates the contract] → API doc §5 gains a second row. Acceptable, but it is the reason this is not simply "always honour Range": the streaming default is the one that makes this project useful, and it must stay the default.
