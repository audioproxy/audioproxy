# Extract the Signed Chain

## Why

`AudioProxy.Plugs.RenderPipeline` mounts the checks every signed request passes
— verify, parse, check expiry, resolve — and then the action. Two test
mountings in `test/support/fake_ffmpeg.ex` (`FakeFfmpeg.Pipeline` and
`CountingProbe.Pipeline`) copy that list by hand so they can swap the action's
executable for a stand-in. Three copies of one chain, kept in step by nobody.

`add-expiring-urls` showed what that costs. It added `AudioProxy.Plugs.CheckExpiry`
to all three, and the adversarial review then found that **deleting the plug
from the production pipeline left all 1051 tests passing** — every expiry test
drives `FakeFfmpeg.Router`, so the suite asserted the copy and said nothing
about the deployment. A single 410 through `AudioProxy.Router` closed that
particular hole, but the shape remains: the next plug added to the chain is
one hand-copy away from the same silence, and the test that would catch it has
to be remembered rather than being structural.

The fix is to stop having copies. If the checks are one mountable unit, a plug
added to it reaches production and both test mountings at once, and no test has
to be written to prove that it did.

## What Changes

- **A builder holding the checks**, mounted by all three pipelines. Everything
  ahead of `AudioProxy.Plugs.Action`, in order, in one place. `RenderPipeline`
  becomes that unit plus the action; each test pipeline becomes the same unit
  plus its own action options.
- **The action stays out of it.** Its options are exactly what the test
  mountings vary — the stand-in encoder, the counting prober — so the seam goes
  where the variation already is.
- The assigns contract currently documented in `RenderPipeline`'s moduledoc
  moves with the plugs it describes.

## Non-goals

- **Changing the chain, its order, or any plug's behaviour.** This is a
  mounting refactor; the request path must be byte-identical before and after,
  which is what makes the existing suite the regression test for it.
- Making the action itself mountable through the same unit, or giving the test
  pipelines a way to omit a check. Both would reintroduce the ability to drift,
  in a form that looks deliberate.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `render-http`: the signed chain has one mounting, shared by the production pipeline and the test pipelines.

## Impact

- Modified: `AudioProxy.Plugs.RenderPipeline`, a new builder module beside it,
  `test/support/fake_ffmpeg.ex` (both pipelines).
- Tests: none new. The point is that the existing suite covers the deployed
  chain once there is only one; the verification is that it passes unchanged,
  plus a mutation check that removing a plug from the shared unit now fails.
- Small — well under the slice target.
- Position: ready when picked up. Deferred out of `add-expiring-urls`, which
  fixed the instance and left the class.
