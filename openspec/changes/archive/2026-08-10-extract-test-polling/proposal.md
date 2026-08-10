## Why

Eleven test files define `wait_until/2`. Two more define `eventually/2`. Two define `await/2`. Four define `gone_within?/2` and `alive?/1`. All of it is the same idea — poll a condition until it holds or a deadline runs out — and none of the copies agree.

*(Counts corrected during implementation: the census below was written against nine `wait_until` files and missed `await/2` entirely. Seventeen files hold a copy, not thirteen. `tasks.md` §1.2 has the file-by-file table.)*

The sleep interval is 5 ms in `semaphore_property_test.exs`, 10 ms in five files, 20 ms in `render_semaphore_test.exs`, 25 ms in `probe_coordinator_test.exs`, 50 ms in `peaks_endpoint_ffmpeg_test.exs`. The failure message is `"the semaphore never returned to empty"` in one, `"queue depth did not settle within Nms"` in two, and `"condition never held"` in the rest. Three files spell the body with `cond`, six with `unless`. `alive?/1` calls `Integer.to_string` in two files and `to_string` in one.

None of that variation is meaningful. It is what happens when the fourteenth author needs a poll loop and writes one rather than finding the thirteen that exist.

There is one distinction underneath the noise that *is* meaningful, and the duplication hides it. `wait_until/2` flunks when the deadline expires; `eventually/2` returns `false`. Those are different contracts for different jobs — "this must become true or the test is broken" versus "did this become true, and I am going to assert on the answer" — and today they are told apart only by which file you are reading. Extracting both under names that say which is which is most of the value here; collapsing nine copies to one is the rest.

## What Changes

- A new `AudioProxy.Eventually` support module holding:
  - `wait_until/2` — polls, flunks on expiry. One interval, one message.
  - `eventually?/2` — polls, returns a boolean. For callers that assert on the answer.
  - `gone_within?/2` and `alive?/1` — the OS-process pair, expressed in terms of `eventually?/2` rather than hand-rolling their own loop a fourth time.
- The 17 files lose their local copies and import it.
- A **Test support** section in `CLAUDE.md` recording that poll loops come from this module, so the fifteenth author finds it instead of writing the tenth copy.

**Deliberately not changed:** per-file deadlines. `@deadline` varies from 2 s to 10 s across these files for real reasons — a probe timeout test wants a different budget from a semaphore drain — so the deadline stays a call-site argument with a modest default, exactly as it is now. Only the *polling interval* is unified, because no file has a reason for its interval and several would be surprised to learn what theirs is.

**Also not changed:** `AudioProxy.RenderHarness.collect/2`. It looks like another duplicated wait, and it is not — it plays the render message contract and acks, which is domain, not polling.

## Capabilities

### New Capabilities

- `test-support` — what the suite's support layer owns, and the rule for what a test file is allowed to define for itself.

### Modified Capabilities

<!-- none — no production code changes -->

## Impact

- New: `test/support/eventually.ex`.
- Modified: 13 test files under `test/audio_proxy/` (their helper sections only; no assertion changes).
- Modified: `CLAUDE.md` — new *Test support* section.
- First of four stacked changes extracting the test suite's shared setup. Lowest risk of the four and therefore first: it touches only helper definitions, and a mistake fails loudly rather than silently passing.
- No `lib/`, CI, config or user-facing docs changes.
