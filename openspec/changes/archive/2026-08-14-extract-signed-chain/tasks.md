# Tasks

## 1. The shared unit

- [x] 1.1 A `Plug.Builder` holding the four checks in order, carrying the assigns contract from `RenderPipeline`'s moduledoc
- [x] 1.2 `RenderPipeline` becomes that unit plus `Action`; its moduledoc keeps only what is about the action seam

## 2. The test mountings

- [x] 2.1 `FakeFfmpeg.Pipeline` and `CountingProbe.Pipeline` mount the shared unit; the hand-copied plug lists and the "keep this in step" comment go
- [x] 2.2 Confirm no other hand-copy exists (`grep -rn "Plugs.VerifySignature" test/`)
      — the only other mount is `VerifySignatureTest.BoundaryPipeline`, a single
      plug in front of a 200 stub. Not a chain copy; it asserts the
      signed/unsigned boundary and must not gain the rest of the chain.

## 3. Verification

- [x] 3.1 Suite passes unchanged — no test edits, which is what shows the request path did not move
      — 1076 passed (35 doctests, 49 properties, 992 tests), 166 excluded.
      The only file touched under `test/` is `test/support/fake_ffmpeg.ex`,
      and only its two mountings.
- [x] 3.2 Mutation: removing a plug from the shared unit fails the suite; record which tests catch it

      All four fail, and only `CheckExpiry` fails narrowly enough to name:

      | Removed | Result | How it fails |
      |---|---|---|
      | `VerifySignature` | 913/1076 | 163 failures, `KeyError :rest_of_path` |
      | `ParseOptions` | 928/1076 | 148 failures, `KeyError :source_string` |
      | `CheckExpiry` | 1070/1076 | 6 failures, all assertions |
      | `ResolveSource` | 939/1076 | 137 failures, `KeyError :source` |

      The three loud ones fail structurally: each plug reads what its
      predecessor assigns, so its absence raises rather than mis-answers.
      `CheckExpiry` assigns nothing, so it is the one that has to be caught by
      assertion — and it is, by six in `AudioProxy.ExpiringUrlsTest`
      (`expiring_urls_test.exs:84, 95, 110, 120, 129, 174`).

      That is the change's point, measured: before it, deleting `CheckExpiry`
      from the *production* pipeline left the suite green, because five of
      those six drive a test mounting. They now drive the same unit the
      deployment does, so `:129` — the hand-written "the production router
      refuses it, not merely the test mounting" — is no longer the only test
      standing between that plug and silence.
