## Context

Three files pin `max_src_bytes` and `max_variant_bytes` by hand because
`base_config/1` requires `local_root` and they resolve no local source and sign
nothing. The proposal offered two shapes: a second helper, or relaxing the
`local_root` requirement.

One fact decides it. All three files — `render_coordinator_test.exs`,
`render_coordinator_property_test.exs`, `variant_store/tee_test.exs` — already
`import AudioProxy.ConfigHelper`, and none of them imports `SignedRequest`.
They are not signing tests that happen to lack a root; they are config
consumers that have nothing to do with signing at all.

## Goals / Non-Goals

**Goals:**
- One definition of the byte-limit floor, reachable by a file that signs nothing.
- The `local_root` requirement left exactly as `extract-signed-request-helper`
  argued for it.

**Non-Goals:**
- Moving `base_config/1`. Endpoint tests are its callers and it is fine where
  it is.
- The per-file `variant_store` in `tee_test.exs`. That is what the file is about.

## Decisions

- **`AudioProxy.ConfigHelper.byte_limits/1`,** not a second function on
  `SignedRequest`. The floor's byte half has no relationship to signing, and
  putting it in the signing module would make three files import a signing
  helper to say "do not let the environment change my size limits". All three
  already import `ConfigHelper`, so this costs them no new import and reads
  correctly at the call site: `put_config(byte_limits())`.

- **`base_config/1` is rebuilt on top of it,** so the numbers exist once.
  `SignedRequest` gains a dependency on `ConfigHelper` for the two limits, and
  keeps the key material, `allow_insecure` and the `local_root` requirement.
  The alternative — leaving both literals and testing that they match — keeps a
  drift that a test would only report after the fact.

- **`local_root` stays mandatory, untouched.** The second shape in the proposal
  asked whether the rule was defending less than it claims. It is not: the rule
  exists so "which root does this file resolve against" is visible in the file
  that cares, and these three files are not evidence against it, because they
  resolve nothing. Relaxing a rule to accommodate callers it was never aimed at
  is how rules stop meaning anything.

- **`byte_limits/1` takes overrides and requires nothing.** `tee_test.exs`
  needs `variant_store: {:file, tmp_dir}` alongside the limits, so the helper
  merges overrides the way `base_config/1` does. Without that it would save two
  lines in two files and not the third.

## Risks / Trade-offs

- [Two floor helpers invite a third] → Mitigated by the direction of the
  dependency: `byte_limits/1` is the base and `base_config/1` builds on it, so
  a future helper extends the chain rather than starting a parallel one. The
  `CLAUDE.md` table gains a row, which is the shape that section was rebuilt
  for.
- [`SignedRequest` now depends on `ConfigHelper`] → One direction only, and the
  natural one: config is the lower layer. Worth a sentence in the moduledoc so
  the next reader sees it as intended rather than accidental.
