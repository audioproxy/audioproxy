## Why

`bin/` now holds three operational Ruby scripts — `smoke-image`, `check-capacity`, `measure-ffmpeg-rss` — and they have accumulated copies of the same plumbing. The code volume is small (~30 lines: `sh`, `sh!`, `docker_run`, `docker_rm`, `published_port`, byte-identical across the scripts that have them). The comments attached to it are not, and they are the actual reason to do this: each one records a failure someone already paid for.

- `sh` keeps stderr out of its return value because docker writes advisories there, and a caller doing `Float(out)` or `JSON.parse(out)` chokes on a warning it never asked for.
- `docker_run` picks the container id out by shape rather than taking "the output", because an advisory on stdout hands `docker inspect` a container that was in fact started correctly.
- `published_port` reads the bound port back rather than choosing one, because bind-read-close-hand-over loses a race on a busy runner and the failure reads like a broken proxy.

Three copies of that knowledge means a correction to one leaves two stale, silently.

There is also one duplication that is not boilerplate: the cgroup `anon` sampler shell probe exists in both `measure-ffmpeg-rss#measure` and `check-capacity#measure_ffmpeg_text`. It has already drifted — one takes its interval from the environment, the other hardcodes `0.02` — and it is shared *technique*, where divergence costs correctness rather than tidiness.

## What Changes

- A support file under `bin/` holding only what is genuinely identical: `sh`, `sh!`, `docker_run`, `docker_rm`, `published_port`, `mib`, and the byte constants — with the hard-won comments moved rather than copied, so they have one home.
- The cgroup sampler extracted as a single helper with its interval as a parameter, replacing both hand-written probes and ending the drift between them.
- The three scripts `require_relative` it and lose their copies.

**Deliberately not extracted**, because unifying them means picking a loser:

- `log`, `step`, `check` — presentation, and each script's version reads the way that script wants. `smoke-image`'s `check` rescues exceptions into failures so one bad check does not abort the suite; `check-capacity`'s deliberately does not.
- `await_health` — `smoke-image`'s dumps container state and the last forty log lines on failure, which is most of its value; `check-capacity`'s is a bounded poll.
- `generate_fixtures`, `start_server` — same names, different fixtures and different environments.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

<!-- none — no behaviour changes; this is internal tooling structure -->

## Impact

- Modified: `bin/smoke-image`, `bin/check-capacity`, `bin/measure-ffmpeg-rss`; new support file under `bin/`.
- **Touches a release gate.** `bin/smoke-image` gates `publish`, so this is a refactor whose only real test is running all three scripts before and after and diffing the outcomes.
- Depends on: `add-capacity-model-doc` (merged, #40).
- No CI, config, docs or `lib/` changes.
