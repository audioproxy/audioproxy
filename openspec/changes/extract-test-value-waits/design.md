## Context

`extract-test-polling` left two poll loops private because both return the
value they waited for — a scrape body, a restarted pid — which `wait_until/2`
(`:ok`) and `eventually?/2` (boolean) cannot express. The proposal offered a
third function, or leaving them alone with a comment.

## Goals / Non-Goals

**Goals:**
- The value-returning wait has a home, so the rule "a poll loop is imported,
  never written" has no unexplained exceptions.
- `await_scrape/3` keeps printing the last scrape body on failure. That message
  is the entire diagnostic when a counter never reaches its expected value.

**Non-Goals:**
- A general async-assertion library. This is the third and, on current
  evidence, last shape of wait the suite needs.
- Changing what either test asserts.

## Decisions

- **A third function, `wait_for/2`.** The alternative — two documented
  exceptions — is how the previous seventeen copies started: every one of them
  was a reasonable local decision. Two exceptions in a rule this young is one
  more than it can carry.

- **The condition returns `{:ok, value}` or `{:retry, observed}`.** Not
  `nil`-means-retry: `await_scrape/3` retries on a body that is perfectly
  truthy and merely does not match yet, so truthiness cannot carry the verdict.
  The `observed` half is what makes the failure message possible, and it is why
  this is not simply `eventually?/2` with a different return type.

- **`wait_for/2` flunks rather than returning a tagged tuple.** It is the
  value-returning sibling of `wait_until/2`, and both existing call sites want
  the value or nothing. A caller that wants to *assert* on whether a value
  arrived already has `eventually?/2`.

- **The failure message names the deadline and the last `observed`.** So
  `await_scrape/3` becomes `wait_for(fn -> … end, 10_000)` with its diagnostic
  preserved by construction rather than by a custom message parameter. This is
  the reason the retry branch carries a payload at all; without it the two
  functions would be the same function.

- **Both call sites convert attempts to milliseconds, with the warning
  `extract-test-polling` earned.** `await_scrape/3` is 50 × 20 ms and
  `await_restart/2` is 100 × 20 ms, so the arithmetic says 1 s and 2 s — but
  `await_scrape/3`'s condition is an HTTP request whose cost the old loop never
  charged to the budget, exactly like the peaks wait that this project got
  wrong once already. Budget it in requests: **10 s**, with a comment saying so.
  `await_restart/2` peeks at a registry and can take the arithmetic at face
  value: 2 s.

## Risks / Trade-offs

- [A third function widens a contract kept deliberately narrow] → The narrow
  contract was two *verdicts*, flunk versus boolean. This adds a third *shape*,
  not a third verdict, and it is the shape the module could not express — which
  is a reason to add it rather than an argument against. Once it exists, the
  `CLAUDE.md` rule is exception-free.
- [Two call sites is thin evidence for an API] → Both are in metrics, which is
  one subsystem, so the sample is weaker than the count suggests. Mitigated by
  the shape being the smallest thing that serves them: one function, one return
  convention, no options.
