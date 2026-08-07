## Context

The suite is ~15,000 lines across 65 files, with a support layer of 15 modules under `test/support/` that is well-scoped where it exists. What never got promoted into it is the last mile: waiting, booting, signing, and fixture generation. This change takes the first of those.

Polling appears in 13 files under three names and four sleep intervals. The variation is accidental — there is no file whose interval or failure message was chosen — but the split between a flunking wait and a boolean wait is not.

## Goals / Non-Goals

**Goals:**
- One poll loop, with the flunk/boolean distinction made explicit in the names.
- No change to what any test asserts, or to any per-file deadline.
- A `CLAUDE.md` directive, so the next author finds the module instead of writing the tenth copy.

**Non-Goals:**
- Unifying deadlines. They differ for reasons.
- A general-purpose async-assertion library. `assert_receive` already exists and covers the message cases; this is only for conditions that have to be *polled* because nothing sends a message when they become true.
- Touching `RenderHarness.collect/2`, which is a protocol driver, not a wait.

## Decisions

- **Two functions, not one with a flag.** `wait_until/2` flunks; `eventually?/2` returns a boolean. A single function taking `flunk: true` would put the contract in a keyword at the call site, which is exactly the thing that is currently unreadable. The `?` suffix carries it instead.
- **`gone_within?/2` is written in terms of `eventually?/2`.** It is a poll for `not alive?(pid)` and nothing else. Expressing it as such rather than as a fourth hand-rolled loop is the point; the only reason it exists separately is that `alive?/1` needs a home.
- **Interval unified at 10 ms; deadline stays a parameter.** 10 ms is what six of the nine already use, so it is the choice that moves the fewest files. The two files at 20/25 ms get slightly more responsive polls and no behaviour change — nothing asserts on how often a condition is checked. The 5 ms case (`semaphore_property_test.exs`) gets slower polls inside a property test, which is where the sleep budget actually matters; verify the property suite's runtime does not regress noticeably, and if it does, that file passes an explicit interval rather than the module changing its default.
- **`flunk` message includes the deadline.** `"condition never held within 5000ms"` beats `"condition never held"` by exactly the piece of information a person debugging a flake wants first, and it costs nothing.
- **`import`, not `alias`.** These read as bare verbs at the call site (`wait_until(fn -> … end)`), which is how all 13 files already call them, so importing keeps every call site byte-identical apart from the deleted definitions.

## Risks / Trade-offs

- [A unified interval changes timing in a property test] → `semaphore_property_test.exs` polls at 5 ms today. Doubling it doubles the worst-case latency of each check inside a generator loop. Measured, not assumed: run the property suite before and after and compare. The escape hatch is a per-call interval, not a different default.
- [Extraction hides the deadline] → mitigated by keeping the deadline an explicit argument with the per-file `@deadline` attributes intact. A reader still sees the budget where it is chosen.
- [13 files in one diff] → mechanical and uniform, and the compiler catches a missed deletion (an unused private function is a warning, and CI runs `--warnings-as-errors`). The diff is large in file count and tiny in reviewable surface.
