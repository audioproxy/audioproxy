## Context

Second of four stacked changes extracting the test suite's shared setup. Eight files boot Bandit identically; the only variable is which plug they mount.

The interesting content is not the five lines. It is that those five lines reach into `ThousandIsland` through a Bandit supervisor pid to ask what port was bound — a coupling to two dependencies' internals, replicated eight times, with nothing written down about why it is shaped that way.

## Goals / Non-Goals

**Goals:**
- One place where the suite couples to Bandit's and Thousand Island's start-and-ask-the-port shape.
- A written note that `port: 0` plus read-back is deliberate, matching the argument `dev-tooling` already records for `bin/`.
- A return shape that serves the two callers needing the supervisor pid without making the other six unpack something they do not want.

**Non-Goals:**
- Defaulting the plug. Which router boots is the test's subject.
- Sharing one listener across tests. Each file starts its own under `start_supervised!`, which is what makes teardown automatic; a shared listener would need config to be stable across files, and it is not — `put_config` differs per file.
- Changing tagging or exclusion rules.

## Decisions

- **`start!/2` returns a map, not a bare port.** `%{port: port, server: pid}`. Six callers pattern-match `%{port: port}` and ignore the rest; two want the pid. A bare port would force those two back to hand-rolling, which defeats the change. A map rather than a tuple because callers already thread it through ExUnit context, which is a map.
- **The IP is asserted, not assumed.** The current code destructures `{:ok, {{127, 0, 0, 1}, port}}`, which quietly asserts the bind address matched. Keep that — it is a free check that the listener is loopback-only, and a helper that pattern-matched `{:ok, {_ip, port}}` would drop it. State it in the moduledoc so it reads as intentional rather than as leftover.
- **Extra Bandit options pass through.** `start!/2` takes a keyword list merged over the defaults, so a future test needing, say, a different `http_options` does not fork the helper. No current caller needs it; the parameter exists because the alternative when one does is a ninth copy.
- **It does not put config.** Every one of the eight files calls `put_config/1` before booting, with different values, and the ordering matters — the plug chain reads config per request, but `AP_LOCAL_ROOT` has to be right before the first one arrives. Folding config into the server helper would couple two things that vary independently. The third change in this stack (`extract-signed-request-helper`) is where the config duplication is addressed, and it stays separate from this.

## Risks / Trade-offs

- [A helper hides which router is under test] → the reason `start!/2` takes the plug as its first positional argument rather than as an option with a default. `TestServer.start!(AudioProxy.FakeFfmpeg.Router)` says as much as the five lines did, in one.
- [Coupling eight files to one helper] → they are already coupled by copy-paste to two dependencies' internals. This makes the coupling one edit wide instead of eight.
- [`ThousandIsland.listener_info/1` could change] → that is the argument *for* the change, not against it. Note in the moduledoc that this is the upgrade-fragile line, so a future `MatchError` here is read as "Bandit changed" rather than "the test is broken".
