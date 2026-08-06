## 1. The second ceiling

- [x] 1.1 `AP_MAX_VARIANT_BYTES` in `Config`, positive integer, resolving at config time to the *effective* `AP_MAX_SRC_BYTES` when unset — so an operator who already raised the source ceiling keeps their current retention bound rather than being tightened to the shipped default
- [x] 1.2 `RenderCoordinator.retain/2` reads it instead of `:max_src_bytes`; the failure detail names `AP_MAX_VARIANT_BYTES` and the byte figure
- [x] 1.3 Leave `Plugs.RenderAction`'s source check and its `413` alone

## 2. Tests

- [x] 2.1 Neither variable set → refusals are byte-identical to today's, at the same threshold. This is the upgrade-path test and the one that would make the change unshippable if it failed
- [x] 2.2 Only `AP_MAX_SRC_BYTES` set, above the default → retention bounds at that value, not at 2 GB
- [x] 2.3 Variant ceiling below source ceiling → a large source is accepted and a render exceeding the variant ceiling is killed; the source ceiling alone no longer bounds retention
- [x] 2.4 A breach with several subscribers attached fails all of them and releases the cache key, so the next request renders afresh
- [x] 2.5 A breach after the response has committed is a failed stream, not a `413`

## 3. The model and the documents

- [ ] 3.1 `bin/capacity_model.rb`: the refusal test follows the retention ceiling; rename the constant to match what it now means
- [ ] 3.2 Regenerate the matrix (`bin/capacity-matrix --write docs/capacity.md`) and confirm no cell moves — the default makes the two numbers equal, so a moved cell means the resolution is wrong
- [ ] 3.3 `docs/capacity.md`: "`AP_MAX_SRC_BYTES` does two jobs" becomes the section on two ceilings and which one bounds what; state plainly that raising the retention ceiling licenses every slot to reach it, so the lever for the total is `AP_MAX_CONCURRENCY`
- [ ] 3.4 `README.md` configuration table: the new row, and the existing row loses the "also caps the bytes a render may hold in memory" clause it no longer owns
