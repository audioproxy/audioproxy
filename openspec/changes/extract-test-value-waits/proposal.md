## Why

`extract-test-polling` collapsed seventeen private poll loops into
`AudioProxy.Eventually`. Two survive, and they survive for a reason worth
writing down rather than rediscovering:

```elixir
# metrics_endpoint_test.exs
defp await_scrape(port, expected, attempts \\ 50) do
  socket = RawHttp.get("/metrics", port)
  %{body: body} = RawHttp.read_one(socket, 5_000)

  cond do
    body =~ expected -> body
    attempts > 0 -> Process.sleep(20) && await_scrape(port, expected, attempts - 1)
    true -> flunk("counter never reached #{expected}; last scrape:\n#{body}")
  end
end

# metrics_test.exs
defp await_restart(old, attempts \\ 100) do
  case Process.whereis(Metrics) do
    nil when attempts > 0 -> Process.sleep(20) && await_restart(old, attempts - 1)
    ^old when attempts > 0 -> Process.sleep(20) && await_restart(old, attempts - 1)
    other -> other
  end
end
```

Both **return the value they waited for** — the scrape body that finally
matched, the pid of the restarted process — and both are called for that value.
`wait_until/2` returns `:ok` and `eventually?/2` returns a boolean, so neither
can express them. Folding them in as they stand would mean rewriting each call
site to poll and then re-read, which reintroduces the race the poll exists to
close: between the wait returning and the re-read running, the value can change
again.

`await_scrape/3` also carries a failure message the generic one cannot replace
— it prints the last scrape body, which is the entire diagnostic when a counter
never reaches its expected value.

So the cost of leaving them is not duplication of a loop that already exists.
It is that `test/support/` now covers polling *except* for the one shape that
needs a value back, and the sixteenth author who needs that shape has no
answer, which is exactly the belief `extract-test-polling` was trying to end.

## What Changes

Pick one of two shapes, decided in `design.md` before implementing:

- **A third function on `AudioProxy.Eventually`.** Something in the shape of
  `wait_for/2`, whose condition returns `{:ok, value} | :retry` (or `nil` for
  "not yet") and which returns the value or flunks. Both call sites become a
  closure and a deadline. Widens the module's contract by one function and one
  return convention, against a design that deliberately kept it to two waits.
- **Leave the loops private and pay for it in a comment.** Each keeps its
  `defp`, with a note saying why the shared module does not fit. Cheapest, and
  it makes the `CLAUDE.md` rule ("a poll loop is imported, never written") a
  rule with two unexplained exceptions — which is how the previous seventeen
  copies started.

The first is the safer default. The second is only worth it if a value-returning
wait turns out to be genuinely rare rather than merely uncommon so far; the two
existing call sites are both in metrics, which is one subsystem and therefore
weak evidence either way.

Whichever wins, the failure message has to stay customisable enough that
`await_scrape/3` keeps printing the last scrape body.

**Deliberately not changed:** the deadline convention. Whatever shape lands
takes its budget at the call site, like the other three functions, and both of
these count attempts today (50 × 20 ms, 100 × 20 ms) so both need the same
attempts-to-milliseconds conversion `extract-test-polling` did for peaks — and
the same warning attached to it, since `await_scrape/3`'s condition is an HTTP
request whose own cost the old loop never charged to the budget.

## Capabilities

### Modified Capabilities

- `test-support` — polling covers the wait that has to hand back a value.

## Impact

- Modified: `test/support/eventually.ex` (or nothing, under the second shape).
- Modified: `test/audio_proxy/metrics_endpoint_test.exs`,
  `test/audio_proxy/metrics_test.exs`.
- Modified: `CLAUDE.md` *Test support* section — a row under `AudioProxy.Eventually`
  either way: a new function, or a stated exception to the import-don't-write rule.
- No `lib/`, CI, config or user-facing docs changes.
- Small — well under the review target. Deferred from `extract-test-polling`,
  whose *Deferred out of this change* section names it.
