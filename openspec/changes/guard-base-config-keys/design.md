## Context

`base_config/1` merges overrides with `Map.merge/2`, so `probe_timout: 1`
installs a key nothing reads and the test fails — or passes — far from the
typo. The proposal left two things to decide: where the known-key set comes
from, and whether `put_config/1` gets the same guard.

Measured before deciding: 23 `base_config/1` call sites, and **127**
`put_config(%{…})` call sites. Guarding only `base_config/1` would leave the
large majority of config overrides in the suite unguarded.

## Goals / Non-Goals

**Goals:**
- A mistyped override key raises at the call site that wrote it.
- The known-key set is derived from `AudioProxy.Config`, not restated beside it.
- No `lib/` change.

**Non-Goals:**
- Validating override *values*. `Config.build!/1` owns that, and a test that
  pins a deliberately invalid value is a legitimate thing to write.
- Changing the floor's contents or the `local_root` requirement.

## Decisions

- **The key set is `Map.keys(AudioProxy.Config.build!(%{}))`.** Neither option
  the proposal offered, and better than both: `build!/1` on an empty env is
  pure, needs no application to be running, and returns a complete config, so
  the key set is derived from the same code that constructs the real one. The
  runtime `Config.all()` option was rejected because it reflects whatever
  happens to be *installed* — including, once `put_config/1` is guarded, keys a
  previous test put there. A `keys/0` on `Config` was rejected because it is a
  `lib/` change bought for nothing: `Options.keys/0` exists because an options
  *string* has no other machine-readable shape, whereas a config map is already
  a map of exactly the right keys.

  Verified before choosing: `build!(%{})` yields 21 top-level keys and 7 under
  `:s3`, and reads no environment.

- **Computed per call, not into a module attribute.** A `@known_keys` at
  compile time would make a test helper compile-depend on `lib/`'s boot path,
  for a saving measured in microseconds against a helper that already builds a
  map. If the suite ever notices the cost, that is the moment to reconsider.

- **`put_config/1` gets the guard too, and it is the primary site.** It is
  where 127 of the 150 call sites are, and it is the chokepoint every config
  override in the suite passes through — `base_config/1`'s output included. The
  check therefore lives in `AudioProxy.ConfigHelper` as a public
  `validate_keys!/2`, called by both; `base_config/1` calls it so that the
  error names the call site that wrote the override rather than the `put_config`
  one line below.

- **Nested `s3` keys are checked one level down.** Several tests pass
  `s3: %{endpoint: …, ca_bundle: …}`, so a top-level-only guard would miss
  exactly the map whose keys are least familiar. `build!(%{}).s3` supplies that
  set the same way. No deeper recursion: nothing below `:s3` is a map.

- **The suggestion uses `String.jaro_distance/2`,** stdlib, on the key names,
  reporting the nearest above 0.8 and staying silent below it. A wrong
  suggestion is worse than none, and the failure being guarded is a typo, which
  is precisely what jaro is good at.

## Risks / Trade-offs

- [Guarding 127 existing call sites may reject one of them] → That is the
  change earning its place, not a regression: a key that is rejected is a key
  nothing reads. The suite says so on the first run, and any rejection gets
  fixed in this change rather than worked around. If a call site turns out to
  need a key `Config` does not define, that is a finding worth a conversation
  before the guard ships.
- [`build!(%{})` per call] → Pure, no I/O, and dwarfed by `put_config/1`'s own
  `:persistent_term` write. Stated so the next reader does not have to measure
  it again.
- [The guard hides a legitimate future key] → It cannot: the set comes from
  `Config` itself, so a new setting is accepted the moment `lib/` defines it,
  with no support-layer edit. That is the second requirement in the spec delta.
