## 1. Extract

- [x] 1.1 `AudioProxy.ConfigHelper.byte_limits/1` — the two limits, with the caller's overrides merged over them, requiring nothing
- [x] 1.2 Carry the *reason* onto it, not just the numbers: an `AP_MAX_SRC_BYTES` in a developer's shell must not be able to turn an assertion about coordinator behaviour into a size-limit failure. That sentence is the whole point of the helper
- [x] 1.3 Rebuild `SignedRequest.base_config/1` on it, so the numbers exist once, and note the direction of the dependency in the moduledoc — config is the lower layer

## 2. Convert

- [x] 2.1 `render_coordinator_test.exs` and `render_coordinator_property_test.exs` — `put_config(byte_limits())`
- [x] 2.2 `variant_store/tee_test.exs` — `put_config(byte_limits(variant_store: {:file, tmp_dir}))`, keeping the store override visible where the file's subject is
- [x] 2.3 Confirm no literal `2_000_000_000` survives outside the support layer and `config_test.exs`, whose job is to assert the shipped default: `grep -rn "2_000_000_000" test`

## 3. Docs

- [x] 3.1 `CLAUDE.md` *Test support* — a row for `byte_limits/1` under `ConfigHelper`, and one line saying which helper to reach for: signing tests take `base_config/1`, everything else that only needs the limits takes `byte_limits/1`

## 4. Verify

- [x] 4.1 `mix test`, `mix test --include integration`, `mix test --only ffmpeg`
- [x] 4.2 `mix compile --warnings-as-errors` and `mix format --check-formatted`
- [x] 4.3 Confirm `base_config/1` still refuses a missing `local_root` — the requirement this change deliberately did not relax should have a test standing on it before the change lands, and it does not yet
