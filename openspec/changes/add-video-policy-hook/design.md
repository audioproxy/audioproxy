## Context

Mirror of `add-semaphore-classes`: OSS ships a seam with zero producers, proven invisible by the existing suite running unchanged against the default.

## Goals / Non-Goals

**Goals:** verdict swappable; everything else — probe, attached_pic handling, error shape, argv hardening — shared between both verdicts.

**Non-Goals:** any OSS-facing configuration (no `AP_` var — a knob would let an unlicensed deployment flip it); track selection (rung-6 follow-up, see `pro-video-sources`); frames-out of any kind.

## Decisions

- **App-env module, not config var**: the consumer is an embedding release (the PRO wrapper) that owns its application env; operators of the OSS image get no lever, which is the point.
- **Verdict enum is closed** (`:reject | :extract`) — a policy cannot invent behaviors; it picks between two the OSS code fully defines and tests.
- **The `:extract` path is tested in OSS** with a test-only policy module (the injectable-registry trick from the source resolver): OSS proves both verdicts work; PRO proves only its licensing gate.

## Risks / Trade-offs

- [Seam without an OSS producer] → default-indistinguishability is pinned by the existing suite plus an explicit property; the test-only policy exercises the second verdict.
- [**A verdict is not part of the cache identity**] → the gate runs on a MISS only, by design (`cached_or_rendered/3` reaches the gate only when `VariantCache.lookup/1` misses), and the cache key derives from options and canonical source alone. So a variant rendered under `:extract` is served from the variant store on every later request for that key **without the gate running**, and outlives a change of verdict. Found independently by both halves of the adversarial review.

  Not closed in code, deliberately: putting the verdict in the cache key would make every OSS key encode a constant and would break "every option round-trips to an identical cache key". It is recorded here because it is the consumer's problem to reason about — a PRO release whose policy *is* its licensing gate keeps serving already-extracted variants after a licence lapses, for as long as they remain in the store. Cache lifetime is the bound, and purging the store is the lever.
- [**A misconfigured policy raises rather than refusing**] → a value that is not a module, or a module not exporting `verdict/1`, raises `UndefinedFunctionError` and the request is a 500. This is the `AudioProxy.Config` call — fail immediately rather than serve traffic with a surprising default — and is fail-closed on the question that matters, since no video is extracted. An audio-only catalogue is unaffected either way, because the policy is still never consulted for it.
