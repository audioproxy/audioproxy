## Context

`AudioProxy.S3` already answers everything this backend needs, and its error type is the whole design problem in one place:

```elixir
@type error ::
        :not_found | :access_denied | :not_configured
        | :invalid_range | {:http, non_neg_integer(), binary()} | {:transport, term()}
```

Six shapes go in; today one status comes out, because `ErrorJSON`'s `@source_not_found` list is the only row a source failure can reach. That list exists for a real reason — §5 has no 403, and a distinguishable rejection turns the source policy into an existence oracle for a bucket the client cannot otherwise see. The reason does not extend to a 503 from S3, which says nothing about whether the object exists.

`ErrorJSON` has no catch-all clause, deliberately: an unlisted reason raises `FunctionClauseError` and fails that slice's tests rather than answering a plausible status in production. So every one of these six must be classified explicitly, and that is the work.

## Goals / Non-Goals

**Goals:**
- `s3://` sources render and describe, with no change to the render or info flows.
- An upstream failure is distinguishable from a missing object *by the client*, without making a missing object distinguishable from a forbidden one.
- One error row, reusable verbatim by `add-https-source-backend`.

**Non-Goals:**
- Retries or circuit-breaking against S3. A 502 tells the client to retry; deciding that the proxy should retry on its behalf is a separate change with its own budget question.
- Caching HEAD results. `/info`'s conditional requests are the caching story (`add-info-endpoint`), and a variant HIT already skips the stat entirely.
- IMDS / instance-role credentials, still out of scope per `add-s3-client`.

## Decisions

**The new row is `502 upstream_unavailable`, `Cache-Control: no-store`.**

The status has to say three things: it is not the client's fault, the resource may well exist, and retrying is reasonable. 502 says exactly that — the proxy is a gateway and its upstream failed. Alternatives considered:

- **503** implies *this* proxy is overloaded, and it is the status a load balancer synthesises when the app is down. Reusing it makes a store outage and a proxy outage indistinguishable in exactly the dashboards where the difference matters.
- **504** is already taken by `render_timeout`, and means a render ran and went silent. A HEAD that never answered is not that.
- **500** is where an unclassified failure goes, and lumping a transient store outage in with "no encoder on the host" would tell an operator to look at the wrong machine.
- **The blind 404**, i.e. the status quo — rejected as above: cached for ten seconds, suppresses the retry that would have worked, and reports a deletion that did not happen.

`no-store` because the condition is transient; §5 already gives `429` and `5xx` that policy, so this row inherits rather than invents.

**Classification, one clause per shape.** `:not_found` and `:access_denied` → the blind 404. Folding `:access_denied` in is the deliberate part: a bucket policy that denies HEAD is indistinguishable from a missing object *to the client*, which is the property §5 wants, and the operator gets the truth from the log rather than the response body. `:not_configured` → 500, an operator fault the client can do nothing about. `{:transport, _}` and `{:http, 5xx, _}` → the new 502. `{:http, 4xx, _}` → the blind 404, since a 4xx that is neither 404 nor 403 means we asked wrongly for an object the client named. `:invalid_range` is unreachable from `head/2` and gets no clause, so it would raise if it ever appeared — which is the module's own convention for "this should be impossible".

**`ffmpeg_input/1` presigns rather than proxies.** `S3.presign_get/3` with `AP_PRESIGN_TTL`, handed to ffmpeg as one argv element. This is the architecture decision CLAUDE.md already fixed — never pipe source bytes through the BEAM — and it is what makes `-ss` on a two-hour master read only the bytes it needs.

**`stat/1` maps `S3.head/2`'s `object()` to the seam's `stat()`**: `size` and `etag` straight across. The ETag is what `/info`'s validator hashes and what makes an S3 source's conditional requests work; the size is what answers 413 on the render path.

**No presign at `stat/1` time.** The two callbacks are called separately by both flows and a presigned URL has an expiry; minting one the caller may not use is a credential with a lifetime and no purpose.

## Risks / Trade-offs

- **[A 502 is a new signal an operator must route.]** → It is also the point: today a store outage is invisible in the response and shows up only as a mysterious rise in 404s. Documented in §5 and the README error table, and the log line already names the class.
- **[`:access_denied` collapsing into 404 hides a misconfiguration.]** → Deliberate, and mitigated where it belongs: the response stays blind, the log says `access_denied`. An operator debugging a bucket policy reads logs; a client probing for objects reads statuses.
- **[HEAD on every uncached render adds a round trip to S3.]** → Already true of the local backend's `stat`, and a variant HIT skips it entirely (`add-variant-cache` checks the store before the source is stat'd). The cost falls only on renders that were going to spawn ffmpeg anyway.
- **[Presign TTL shorter than a long render.]** → `AP_PRESIGN_TTL` bounds the URL, not the read: ffmpeg opens the object within the TTL and the connection outlives it. Worth a note in the docs, not a mechanism.

## Open Questions

- Whether `{:http, 5xx, _}` from the *variant store* should reach the same row once `add-s3-variant-store` lands. Probably yes, but that slice owns its own failure surface and should decide with its own tests in front of it.
