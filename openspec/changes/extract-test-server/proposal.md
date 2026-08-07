## Why

Eight test files boot a listener, and all eight do it with the same five lines:

```elixir
bandit =
  start_supervised!(
    {Bandit, plug: AudioProxy.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
  )

{:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
```

The only thing that varies is the plug module — `AudioProxy.Router` in five files, `AudioProxy.FakeFfmpeg.Router` in three. Everything else, including the destructuring pattern that hardcodes `{127, 0, 0, 1}` on both sides, is copied.

Three things make this worth one file rather than eight:

- **`ThousandIsland.listener_info/1` is a dependency's internal-ish API reached through Bandit's supervisor pid.** It is the one line here that a Bandit upgrade can break, and when it does it breaks in eight places at once with an unhelpful `MatchError`. That is the same argument `AudioProxy.RequestLoggingIntegrationTest` already makes for itself about Bandit's telemetry contract: pin the dependency's shape in one place so an upgrade fails somewhere legible.
- **`port: 0` plus read-back is a technique, not a line.** `bin/check-capacity` learned the same lesson on the operational side and `dev-tooling`'s `published_port` records it: bind-read-close-hand-over loses a race on a busy runner, so you bind zero and ask what you got. The suite arrived at the same answer independently and has no note saying so.
- Two of the eight files (`variant_cache_stream_test.exs`, `render_endpoint_stream_test.exs`) also need the supervisor pid afterwards, for teardown assertions. So the helper has to return more than a port, and picking that shape once is cheaper than eight files each deciding.

## What Changes

- A new `AudioProxy.TestServer` support module: `start!/1` takes the plug module (and optional Bandit options), starts it under the test supervisor on an ephemeral port, and returns `%{port: port, server: pid}`.
- The eight files call it and lose their copies.
- The `CLAUDE.md` **Test support** section (added by `extract-test-polling`) gains a row for it.

**Deliberately not changed:** which router each file boots. Five boot the production `AudioProxy.Router` and three boot `AudioProxy.FakeFfmpeg.Router`, and that choice is the whole point of each of those files — a real-ffmpeg test and a stand-in test differ in exactly that argument. The helper takes it; it does not default it.

**Also not changed:** the `:integration` and `:ffmpeg` tags, or the exclusion rules in `test/test_helper.exs`. A test that binds a socket is still excluded by default and still says so.

## Capabilities

### New Capabilities

<!-- none — `test-support` is introduced by `extract-test-polling` -->

### Modified Capabilities

- `test-support` — gains the requirement that listener boot has one home.

## Impact

- New: `test/support/test_server.ex`.
- Modified: `test/audio_proxy/peaks_endpoint_ffmpeg_test.exs`, `render_endpoint_ffmpeg_test.exs`, `info_endpoint_ffmpeg_test.exs`, `render_endpoint_stream_test.exs`, `variant_cache_stream_test.exs`, `request_logging_integration_test.exs`, `source/s3_backend_test.exs`, `plugs/verify_signature_integration_test.exs`.
- Modified: `CLAUDE.md` — one row in *Test support*.
- Depends on `extract-test-polling` (first in the stack) for the `CLAUDE.md` section it extends. Rebase onto it rather than re-creating the section.
- No `lib/`, CI, config or user-facing docs changes.
