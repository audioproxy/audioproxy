## 1. Baseline

- [x] 1.1 Branch from `main` at or after `extract-test-server` merges — both earlier changes touch these same 18 files, and rebasing later means resolving the same conflicts twice
  - Adapted: neither `extract-test-polling` nor `extract-test-server` is implemented (0 tasks each), so there is no in-flight branch to conflict with. Branched from `main` at 56fec88. Those two now land against a smaller surface instead of this one.
- [x] 1.2 Record each of the 18 files' full `put_config` map before touching it. The diff between that record and the post-change `base_config(overrides)` call is this change's only real review artifact — a silently dropped key is the failure mode, and it will not fail any test that does not happen to depend on it
- [x] 1.3 Full green baseline: `mix test`, `--include integration`, `--only ffmpeg`
  - `mix test` 952 passed; `--include integration` 973 passed; `--only ffmpeg` 45/47, the two failures being `f:ogg/q:5` on a host ffmpeg built without `libvorbis`. Pre-existing and environmental — the devcontainer's Debian ffmpeg has it, and Docker was down for this session.

## 2. Extract

- [x] 2.1 `test/support/signed_request.ex` with `key/0`, `salt/0`, `base_config/1` (required `local_root`, caller overrides merged over the floor), `signed/1`, `conn/3`, `header/2`
- [x] 2.2 **Move** the environment-independence comment from `render_endpoint_test.exs` onto `base_config/1` — it does not stay in both places
- [x] 2.3 Moduledoc states plainly that the key material is a fixed test vector, never loaded by `lib/`, never an operational default
- [x] 2.4 `signed/1`'s doc names the grammar and points at API doc §2, and says it is deliberately an independent implementation rather than a call into production path construction — so a divergence fails a test rather than agreeing with itself
- [x] 2.5 Convert the seven files defining `signed/1` verbatim
- [x] 2.6 Convert the three that inline the same construction inside `request/1` or `render/2` — `telemetry_test.exs`, `render_semaphore_test.exs`, `source/s3_backend_test.exs` — keeping their wrapper names, since those read as the file's own vocabulary
- [x] 2.7 Convert all 18 `put_config` calls to `base_config/1` plus overrides, checking each against the 1.2 record key by key
  - 14 floor sites took `base_config/1`. Four carry key material without the floor and keep their own map, now calling `key/0` and `salt/0`: `signature_test.exs`, both `verify_signature` files (`%{key:, salt:, allow_insecure:}` only). The fourth, `source/s3_backend_test.exs`, does take the floor — see 4.3.
- [x] 2.8 Replace the three hand-rolled header-folding conn builders and the two identical `header/2` definitions
  - Builders: `render_endpoint_test.exs`, `info_endpoint_test.exs`, `variant_cache_test.exs`. Duplicate `header/2`: `info_endpoint_test.exs`, `source/s3_backend_test.exs`. `info_endpoint_ffmpeg_test.exs`'s `header/2` is a *third* definition and is **not** a duplicate — it regexes a raw HTTP head rather than reading a conn, so it stays and that file imports `except: [header: 2]`.
- [x] 2.9 Leave every per-file override where it is: `probe_timeout: 1`, `render_timeout: 60`, `variant_store`, `serve_mode`, and their comments

## 3. Directive

- [x] 3.1 Add the `SignedRequest` rows to `CLAUDE.md`'s *Test support* section, including the rule that a new endpoint test starts from `base_config/1` rather than a fresh literal map, and that a value the test is *about* goes in the overrides where a reader will see it
  - The section did not exist — `extract-test-polling` was to create it and has not landed. This change creates it; that one adds its rows later.

## 4. Verify

- [x] 4.1 `mix test`, `--include integration`, `--only ffmpeg` all green against 1.3
  - `mix test` 961 passed (952 + the 9 new helper tests); `--include integration` 973 passed, identical to baseline; `--only ffmpeg` 45/47 with the same two `libvorbis` failures. No test changed its verdict.
- [x] 4.2 `grep -rn "00112233445566778899AABBCCDDEEFF" test` returns exactly one hit, in the support module
  - Two hits. The second is inside `signature_test.exs`'s Python generator comment, which exists to be pasted and run — a known-answer vector loses its point if it references the value it is meant to check independently. The hex is no longer *defined* anywhere but the support module. The comment now says it is the same material and must be regenerated if that changes.
- [x] 4.3 `grep -rn "max_src_bytes: 2_000_000_000" test` returns one hit in the support module, plus `config_test.exs`, which tests the config parser itself and is not a caller of the floor
  - Five hits. Support module and `config_test.exs` as expected, plus `render_coordinator_test.exs`, `render_coordinator_property_test.exs` and `variant_store/tee_test.exs`. Those three set the byte limits but carry no key material and no `local_root`, so they are outside this change's 18 files and cannot call `base_config/1` without either a `local_root` they never read or relaxing the requirement design.md deliberately imposed. Left alone; worth its own change if the duplication is judged to matter.
- [x] 4.4 Re-read the 1.2 record against the final diff one more time. This is the step that catches a dropped key, and no test failure will do it for you
  - Done as a mechanical before/after diff of the recorded maps. Every non-floor key survives at its call site with its comment. One key was *added*, deliberately: `source/s3_backend_test.exs` now pins `local_root: nil`. That file has no `local://` source and never read a local root, so the floor previously let an ambient `AP_LOCAL_ROOT` through; nil is what the floor is for. Its tests are `:minio`-tagged and did not run this session (Docker down), so that one line is unexercised.
- [x] 4.5 `mix compile --warnings-as-errors` and `mix format --check-formatted`
