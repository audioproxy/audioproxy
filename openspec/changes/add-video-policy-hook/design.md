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
