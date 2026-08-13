# Tasks

## 1. The shared unit

- [ ] 1.1 A `Plug.Builder` holding the four checks in order, carrying the assigns contract from `RenderPipeline`'s moduledoc
- [ ] 1.2 `RenderPipeline` becomes that unit plus `Action`; its moduledoc keeps only what is about the action seam

## 2. The test mountings

- [ ] 2.1 `FakeFfmpeg.Pipeline` and `CountingProbe.Pipeline` mount the shared unit; the hand-copied plug lists and the "keep this in step" comment go
- [ ] 2.2 Confirm no other hand-copy exists (`grep -rn "Plugs.VerifySignature" test/`)

## 3. Verification

- [ ] 3.1 Suite passes unchanged — no test edits, which is what shows the request path did not move
- [ ] 3.2 Mutation: removing a plug from the shared unit fails the suite; record which tests catch it
