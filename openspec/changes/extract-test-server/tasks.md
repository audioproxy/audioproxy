## 1. Baseline

- [ ] 1.1 Branch from `main` at or after `extract-test-polling` merges — it creates the `CLAUDE.md` *Test support* section this change adds a row to, and re-creating it means a conflict for no reason
- [ ] 1.2 Confirm the socket-binding suites are green before touching them: `mix test --include integration` and `mix test --only ffmpeg`. These are the excluded-by-default tags, so a default `mix test` proves nothing about this change

## 2. Extract

- [ ] 2.1 `test/support/test_server.ex` with `start!/2` — plug module positional, Bandit options keyword merged over the defaults, returning `%{port: port, server: pid}`
- [ ] 2.2 Keep the loopback assertion in the destructure (`{:ok, {{127, 0, 0, 1}, port}}`) rather than relaxing it to `{_ip, port}`, and say in the moduledoc that it is a deliberate check, not leftover pattern
- [ ] 2.3 Moduledoc records the two things the copies never did: that `port: 0` plus read-back is chosen to survive parallel runs, and that `ThousandIsland.listener_info/1` is the upgrade-fragile line, so a future `MatchError` reads as "Bandit changed"
- [ ] 2.4 Convert the six callers that want only the port
- [ ] 2.5 Convert `render_endpoint_stream_test.exs` and `variant_cache_stream_test.exs`, which also thread the supervisor pid into their context for teardown assertions — check what each does with it before assuming `:server` is the right key
- [ ] 2.6 Leave every `put_config/1` call exactly where it is, before the boot. Config is the third change's subject, and the ordering is load-bearing

## 3. Directive

- [ ] 3.1 Add the `TestServer` row to `CLAUDE.md`'s *Test support* section: a test that binds a socket boots it through this helper

## 4. Verify

- [ ] 4.1 `mix test --include integration` and `mix test --only ffmpeg` green, compared against 1.2
- [ ] 4.2 `mix test` green — the default run binds no socket, so this is a check that nothing leaked out of an excluded tag
- [ ] 4.3 `grep -rn "ThousandIsland.listener_info" test` returns exactly one hit, in the support module
- [ ] 4.4 `mix compile --warnings-as-errors` and `mix format --check-formatted`
