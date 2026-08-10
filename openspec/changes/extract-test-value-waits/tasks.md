## 1. Extract

- [ ] 1.1 `AudioProxy.Eventually.wait_for/2` — polls a condition returning `{:ok, value}` or `{:retry, observed}`, returns `value`, flunks on expiry naming both the deadline and the last `observed`
- [ ] 1.2 Express it over the same private `poll` the other three use, so there is still one loop and one interval. If it cannot reuse `poll` without contorting it, say so in the code rather than quietly forking a second loop
- [ ] 1.3 Extend the moduledoc's "two waits, because there are two contracts" section to three, keeping its shape: what each is *for*, not what each returns. The reason `{:retry, observed}` carries a payload — the failure message — belongs here

## 2. Convert

- [ ] 2.1 `metrics_endpoint_test.exs`'s `await_scrape/3` → `wait_for/2` at **10 s**, with a comment that each attempt is an HTTP request so the budget is denominated in requests, not polls. Its diagnostic (the last scrape body) must survive, now via `observed`
- [ ] 2.2 `metrics_test.exs`'s `await_restart/2` → `wait_for/2` at 2 s. Its condition is a registry peek, so the attempts-to-milliseconds arithmetic holds here
- [ ] 2.3 `grep -rn "defp await\|defp wait_\|defp eventually" test` returns nothing. This is the check that the rule now has no exceptions

## 3. Docs

- [ ] 3.1 `CLAUDE.md` *Test support* — a row for `wait_for/2` in the `AudioProxy.Eventually` table, phrased so the three read as a set: verdict, boolean, value
- [ ] 3.2 Drop the qualification from the import rule if one was added — after this change "a poll loop is imported, never written" is true without exception

## 4. Verify

- [ ] 4.1 `mix test`, `mix test --include integration`, `mix test --only ffmpeg`
- [ ] 4.2 `mix compile --warnings-as-errors` and `mix format --check-formatted`
- [ ] 4.3 Force one failure by hand — a `wait_for/2` whose condition never returns `{:ok, _}` — and read the message. If it does not name the last `observed`, the payload half of the design bought nothing
