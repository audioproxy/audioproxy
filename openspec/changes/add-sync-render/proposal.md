## Why

A variant that is not yet cached is delivered as a chunked `200` with no `Content-Length` and no `Accept-Ranges` (API doc §5), which is correct: a render in progress has no length and nothing to seek into. The consequence is that **the first listener of any variant cannot seek**. A browser `<audio>` element shows an unknown duration and a dead scrubber, verified against `v0.1.0`: `duration` is `Infinity`, `seekable` is empty. Once `add-variant-cache` lands the *second* request is seekable, so this is a cold-start problem rather than a permanent one — but "the first person to open this track gets a broken scrubber" is a poor answer for a player UI, and it does not improve with traffic for a long tail of rarely-requested variants.

This change gives a client a way to ask for a complete, seekable response instead, trading time-to-first-byte for a working scrubber.

## What Changes

- A client can request **materialise-then-serve**: the proxy renders to completion, then answers `200` with `Content-Length` and `Accept-Ranges`, or `206` for a range request. Time to first byte becomes the whole render; seeking works immediately.
- **Not a processing option.** `sync` describes delivery, not output. Putting it in the options path would give two cache keys for byte-identical variants, which breaks the project's round-trip rule and doubles cache occupancy. The trigger is transport-level (see design.md for the mechanism and the alternatives weighed).
- Requests that materialise SHALL still write back to the variant store, so the cost is paid once and later requests are ordinary HITs.
- With no variant store configured, a materialising request needs somewhere to put the bytes; the spool location and its bound are part of this change.
- Interaction with `AP_RENDER_TIMEOUT`, the concurrency semaphore and coalescing is specified rather than left to emerge: a materialising request occupies a render slot for its whole duration, which is a denial-of-service surface if unbounded.

## Capabilities

### New Capabilities

- `sync-render`: Materialise-then-serve delivery for uncached variants — the trigger, the completed-response contract, write-back on completion, spooling when no store is configured, and the limits that keep held connections bounded.

### Modified Capabilities

- `render-http`: The render endpoint SHALL support a second delivery mode for a cache MISS, answering with a complete range-capable response rather than a chunked stream.
- `variant-cache`: A materialised render SHALL populate the store on completion, so the work is not repeated.

## Impact

- New: `lib/audio_proxy/plugs/` delivery branch, spool handling.
- Modified: render endpoint action, API doc §5 (a MISS now has two possible shapes), README.
- Depends on: `add-variant-cache` (materialise-then-serve is most coherent as *render → write-back → serve as a HIT*; without a store it needs a temp spool, which is the weaker form), `add-render-semaphore` (a held slot is the cost being bounded).
- **Open question carried into design:** whether this is worth building at all, or whether the honest answer is that clients needing seek should request once to warm the cache. Recorded rather than assumed — see design.md.
