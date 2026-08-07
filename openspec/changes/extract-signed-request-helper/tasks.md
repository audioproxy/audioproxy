## 1. Baseline

- [ ] 1.1 Branch from `main` at or after `extract-test-server` merges — both earlier changes touch these same 18 files, and rebasing later means resolving the same conflicts twice
- [ ] 1.2 Record each of the 18 files' full `put_config` map before touching it. The diff between that record and the post-change `base_config(overrides)` call is this change's only real review artifact — a silently dropped key is the failure mode, and it will not fail any test that does not happen to depend on it
- [ ] 1.3 Full green baseline: `mix test`, `--include integration`, `--only ffmpeg`

## 2. Extract

- [ ] 2.1 `test/support/signed_request.ex` with `key/0`, `salt/0`, `base_config/1` (required `local_root`, caller overrides merged over the floor), `signed/1`, `conn/3`, `header/2`
- [ ] 2.2 **Move** the environment-independence comment from `render_endpoint_test.exs` onto `base_config/1` — it does not stay in both places
- [ ] 2.3 Moduledoc states plainly that the key material is a fixed test vector, never loaded by `lib/`, never an operational default
- [ ] 2.4 `signed/1`'s doc names the grammar and points at API doc §2, and says it is deliberately an independent implementation rather than a call into production path construction — so a divergence fails a test rather than agreeing with itself
- [ ] 2.5 Convert the seven files defining `signed/1` verbatim
- [ ] 2.6 Convert the three that inline the same construction inside `request/1` or `render/2` — `telemetry_test.exs`, `render_semaphore_test.exs`, `source/s3_backend_test.exs` — keeping their wrapper names, since those read as the file's own vocabulary
- [ ] 2.7 Convert all 18 `put_config` calls to `base_config/1` plus overrides, checking each against the 1.2 record key by key
- [ ] 2.8 Replace the three hand-rolled header-folding conn builders and the two identical `header/2` definitions
- [ ] 2.9 Leave every per-file override where it is: `probe_timeout: 1`, `render_timeout: 60`, `variant_store`, `serve_mode`, and their comments

## 3. Directive

- [ ] 3.1 Add the `SignedRequest` rows to `CLAUDE.md`'s *Test support* section, including the rule that a new endpoint test starts from `base_config/1` rather than a fresh literal map, and that a value the test is *about* goes in the overrides where a reader will see it

## 4. Verify

- [ ] 4.1 `mix test`, `--include integration`, `--only ffmpeg` all green against 1.3
- [ ] 4.2 `grep -rn "00112233445566778899AABBCCDDEEFF" test` returns exactly one hit, in the support module
- [ ] 4.3 `grep -rn "max_src_bytes: 2_000_000_000" test` returns one hit in the support module, plus `config_test.exs`, which tests the config parser itself and is not a caller of the floor
- [ ] 4.4 Re-read the 1.2 record against the final diff one more time. This is the step that catches a dropped key, and no test failure will do it for you
- [ ] 4.5 `mix compile --warnings-as-errors` and `mix format --check-formatted`
