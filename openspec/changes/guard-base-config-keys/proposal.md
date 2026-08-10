## Why

`AudioProxy.SignedRequest.base_config/1` merges a caller's overrides over the
config floor with `Map.merge/2`, which accepts any key at all:

```elixir
put_config(base_config(local_root: tmp_dir, probe_timout: 1))
```

That typo compiles, runs, and installs `:probe_timout` into the config map where
nothing ever reads it. `probe_timeout` keeps whatever the floor or the boot
environment gave it. The test then fails somewhere far from the mistake — a
timeout assertion that waits the default duration and times out for the wrong
reason — or, worse, *passes* while asserting something weaker than intended.

This is the same class of failure the config floor exists to prevent. The floor
stops the *environment* from silently changing what a test asserts; nothing yet
stops a *typo* from doing it. And the extraction made the hazard slightly more
reachable, because overrides are now the normal way to say anything per-file:
before, a wrong key sat in a literal map a reader could compare against its
neighbours; now it sits in a short argument list that looks correct.

`AudioProxy.ConfigHelper.put_config/1` has always had this property, so this is
not a regression. It is an opportunity: `base_config/1` is a new, narrow seam
that every endpoint test now passes through, which makes it the cheapest place
the check has ever been available.

## What Changes

- `base_config/1` rejects any override key `AudioProxy.Config` does not define,
  raising an `ArgumentError` that names the offending key and — worth the effort
  — suggests the nearest known key, since the failure mode is a typo.
- The known-key set has to come from somewhere, and that choice is the design
  question:
  - `Map.keys(AudioProxy.Config.all())` at runtime. No `lib/` change, but it
    depends on config being loaded and silently accepts whatever happens to be
    installed.
  - A `keys/0` on `AudioProxy.Config`, derived from its `@type t`. Honest, and a
    `lib/` change in service of tests — which needs an argument, though
    `AudioProxy.Options.keys/0` and `AudioProxy.ErrorJSON.rows/0` are precedent
    for `lib/` exposing its own shape so a guard can hold it to it.
- Consider extending the same guard to `put_config/1`. Broader blast radius —
  several call sites pass keys deliberately — so decide it in `design.md` rather
  than assuming.

**Deliberately not changed:** the floor's contents, and the `local_root`
requirement. This is about the keys a caller may name, not which values are
pinned.

## Capabilities

### Modified Capabilities

- `test-support` — a mistyped override becomes an error at the call site rather
  than a puzzle downstream.

## Impact

- Modified: `test/support/signed_request.ex`.
- Possibly modified: `lib/audio_proxy/config.ex` (a `keys/0`), and
  `test/support/config_helper.ex` if the guard extends to `put_config/1`.
- New: tests for the guard itself, in `test/audio_proxy/signed_request_test.exs`.
- Small. Deferred from `extract-signed-request-helper`, which left it out
  because that slice deliberately touched no `lib/`.
