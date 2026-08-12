## Why

`extract-signed-request-helper` moved the config floor into
`AudioProxy.SignedRequest.base_config/1` and converted the fifteen files that
carry key material. Three files were left behind, and they are left behind for a
reason worth writing down rather than rediscovering:

```elixir
# render_coordinator_test.exs, render_coordinator_property_test.exs
put_config(%{max_src_bytes: 2_000_000_000, max_variant_bytes: 2_000_000_000})

# variant_store/tee_test.exs
put_config(%{
  max_src_bytes: 2_000_000_000,
  max_variant_bytes: 2_000_000_000,
  variant_store: {:file, tmp_dir}
})
```

These set the same two limits for the same reason every other file does — so a
boot-time `AP_MAX_SRC_BYTES` in a developer's shell cannot turn an assertion
about coordinator behaviour into a size-limit failure. But they sign nothing, so
they have no key material, and they resolve no `local://` source, so they have no
`local_root`. `base_config/1` requires one.

That requirement is not an accident to be worked around: `extract-signed-request-helper`'s
design chose it deliberately, because a defaulted root would make it invisible
which root a file's sources resolve against. So these three cannot simply call
the helper, and the duplication survived a change whose whole subject was
removing it.

The cost today is small — two literals in three files. The cost of leaving it is
that the *next* reader learns the floor is something you sometimes write out by
hand, which is exactly the belief the previous change was trying to end.

## What Changes

Pick one of two shapes, decided in `design.md` before implementing:

- **A second helper.** `AudioProxy.SignedRequest.byte_limits/1` (or a better home
  — these files have nothing to do with signing, which is an argument that
  `base_config/1` is in the wrong module for them). Returns just the two limits,
  merged with overrides, requiring nothing.
- **Relax `local_root` to a keyword that may be absent** rather than must be
  present, and let these three call `base_config/1` without it. Cheaper, and it
  weakens a rule the previous change argued for on the record. Would need that
  argument answered, not ignored.

The first is the safer default. The second is only worth it if the `local_root`
rule turns out to be defending less than it claims.

**Deliberately not changed:** the per-file `variant_store` in `tee_test.exs`.
That is what the file is about.

## Capabilities

### Modified Capabilities

- `test-support` — the floor becomes reachable by a file that signs nothing.

## Impact

- Modified: `test/support/signed_request.ex` (or a new support module).
- Modified: `test/audio_proxy/render_coordinator_test.exs`,
  `test/audio_proxy/render_coordinator_property_test.exs`,
  `test/audio_proxy/variant_store/tee_test.exs`.
- Modified: `CLAUDE.md` *Test support* section, if a second function joins the table.
- No `lib/`, CI, config or user-facing docs changes.
- Small — well under the review target. Deferred from `extract-signed-request-helper`,
  whose task 4.3 names it.
