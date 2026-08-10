## Context

Third of four stacked changes. The largest by file count (18) and the one with the most judgement in it, because unlike polling and listener boot, config is a place where files legitimately differ — so the extraction has to separate the floor everyone shares from the values each file is actually testing.

The floor is not arbitrary. It exists to make the suite independent of the developer's environment: `AudioProxy.Config` reads `AP_`-prefixed env vars at boot, and a `AP_MAX_SRC_BYTES` set in someone's shell turns a 501 assertion into a 413 failure in a file that has nothing to do with size limits. One file records this. Seventeen rely on it silently.

## Goals / Non-Goals

**Goals:**
- One home for the test key material, the config floor, and the signed-path grammar.
- The environment-independence hazard written down where the mitigation lives, not three files away.
- Per-file config overrides *more* visible after the change than before, not less — a file's `put_config` should read as "the floor, plus the two things this file is about".

**Non-Goals:**
- A fixture library. Fixture lists stay per-file; that is `extract-test-fixtures`' scope and only for the real-ffmpeg ones.
- Hiding `put_config/1`. It stays an explicit call in each file's `setup`, because `ConfigHelper`'s `on_exit` restore is what makes the global state safe and burying it would make the `async: false` requirement invisible.
- Deriving the config floor from `AudioProxy.Config.build!/1`. Tempting, and wrong: that would make the floor depend on the production defaults, so a production default change would silently move every test's baseline. The floor is a fixed literal on purpose.

## Decisions

- **`base_config/1` merges overrides rather than being merged into.** `put_config(SignedRequest.base_config(local_root: tmp_dir, probe_timeout: 1))` reads as floor-plus-subject in one expression. The alternative, `put_config(Map.merge(base_config(), %{probe_timeout: 1}))`, puts the interesting value further from the eye and invites a caller to get the merge direction wrong.
- **`local_root` is a required argument, not defaulted.** Every caller passes a per-test tmp dir, and a helper that defaulted it would make the two coalescing helpers' entire premise — that different files point the same canonical source at different roots — quietly optional. Required means a caller cannot forget.
- **The hazard comment moves, not copies.** As with `extract-script-support`: a comment left behind in duplicate is the failure mode being fixed. `render_endpoint_test.exs` loses its copy when the helper gains it.
- **`key/0` and `salt/0` as functions, not module attributes re-exported.** Attributes do not cross module boundaries, and a `defmacro` that injects them would be the kind of cleverness this suite has been right to avoid. Two zero-arity functions cost nothing; `Signature.sign/3` takes them as arguments anyway.
- **`signed/1` states the grammar in its doc, with a pointer to the API doc §2.** The grammar is the contract; the helper is one of its two implementations (the other is `lib/`). If they disagree, tests fail, which is the point — so the doc should say that this is deliberately a *reimplementation* and not a call into production signing-path construction.
- **`conn/3` folds headers; it does not call a router.** Which router is called stays at the call site, per the same rule as `extract-test-server`. The helper builds the conn and stops.
- **`header/2` returns `nil` for absent.** Both existing copies do. Keep it, and note that `Plug.Conn.get_resp_header/2` returning a list is the thing being smoothed over — a caller wanting to assert "exactly one" should use the list directly.

## Risks / Trade-offs

- [The largest diff in the stack] → sequenced third so it lands after the other two have already shrunk these files. Mechanical: a missed `@key` deletion is an unused-attribute warning and CI runs `--warnings-as-errors`.
- [A shared config floor could drift from what a file needs] → mitigated by the merge direction. A file that needs a different floor value overrides it visibly; a file that needs a *smaller* floor is telling you it is testing a limit, which is exactly the case that should be explicit.
- [Extraction could make `async: false` look optional] → `put_config/1` stays an explicit call in every `setup`, and `ConfigHelper`'s moduledoc already carries the `async: false` requirement. Do not add a wrapper that calls `put_config` for the caller.
- [Test key material in a shared file looks like a secret] → it is not, and the moduledoc should say so plainly: fixed test vectors, never loaded by `lib/`, never an operational default. Worth a sentence because a scanner or a new reader will ask.
