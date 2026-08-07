## Why

Eighteen test files open with the same preamble. Not similar — identical:

```elixir
@key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
@salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")
```

Eighteen more repeat the same config floor:

```elixir
put_config(%{
  key: @key, salt: @salt, allow_insecure: false, local_root: tmp_dir,
  max_src_bytes: 2_000_000_000, max_variant_bytes: 2_000_000_000
})
```

And seven define, character for character:

```elixir
defp signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"
```

Three more spell the same thing inline inside a `request/1` or `render/2`.

The volume is the smaller half of the problem. The larger half is that the config floor has a *reason*, and the reason exists in exactly one of the eighteen files. `render_endpoint_test.exs` carries it:

> Pin every config value the chain reads: a boot-time `AP_MAX_SRC_BYTES` in the environment must not be able to flip these tests' 501s to 413s.

That is a hazard someone found the hard way — a developer with a limit set in their shell watching unrelated tests fail with the wrong status. Seventeen files depend on the mitigation and say nothing about it. Anyone tidying up a `put_config` map that "sets a limit no test needs" would break them, and the comment that would have stopped them is in a file they are not reading.

The `signed/1` copies carry a smaller version of the same problem: the signature covers `rest` and the path is `"/" <> sig <> rest`, which is the URL grammar from the API doc §2. Ten copies of a grammar is ten places to correct when the grammar moves.

## What Changes

- A new `AudioProxy.SignedRequest` support module holding:
  - `key/0` and `salt/0` — the suite's test key material, decoded once.
  - `base_config/1` — the config floor, taking the per-test `local_root` and merging caller overrides on top. The hazard comment moves here.
  - `signed/1` — `rest` to a signed path, once, against the URL grammar.
  - `conn/3` — build a `Plug.Test` conn with request headers folded in, replacing the three files that hand-roll the identical `Enum.reduce(headers, conn(method, path), …)`.
  - `header/2` — first response header or `nil`, replacing two identical copies.
- The 18 files import it, keep their own `put_config` call, and pass only what they actually vary.
- The `CLAUDE.md` **Test support** section gains rows for it, including the directive that a new endpoint test starts from `base_config/1` rather than a fresh literal map.

**Deliberately not changed:**

- **Per-file config overrides stay at the call site.** `probe_timeout: 1` in `info_endpoint_test.exs`, `render_timeout: 60` in the ffmpeg files, `variant_store`/`serve_mode` in the cache files — each is that file's subject, and each has a comment saying why. `base_config/1` supplies the floor and merges overrides over it; it never supplies a value a test is about.
- **The fixture lists.** Every file's `File.write!` block names the sources that file is about, and the filenames are directives to the shell stand-ins (`hang.wav` means "produce no bytes"). Unifying them would make every test file depend on every other file's fixtures.
- **`AudioProxy.CountingProbe.Router` and `AudioProxy.FakeFfmpeg.Router` choices.** Which router a file calls is its subject, exactly as in `extract-test-server`.

## Capabilities

### New Capabilities

<!-- none — `test-support` is introduced by `extract-test-polling` -->

### Modified Capabilities

- `test-support` — gains requirements for shared key material, the config floor, and the signed-path grammar.

## Impact

- New: `test/support/signed_request.ex`.
- Modified: 18 test files under `test/audio_proxy/` — the largest diff of the four, and the reason it is third rather than first: the two changes before it shrink these same files, so this one lands against a smaller surface.
- Modified: `CLAUDE.md` — rows in *Test support*.
- Depends on `extract-test-polling` and `extract-test-server`. Rebase onto both.
- No `lib/`, CI, config or user-facing docs changes. The test key material is test-only and stays test-only; it is not a secret and is not referenced by `lib/` or by `README.md`.
