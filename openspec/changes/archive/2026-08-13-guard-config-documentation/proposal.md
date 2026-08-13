## Why

`add-llms-txt` made three things in `priv/llms/llms-full.txt` machine-checked — the option keys, the error rows, and the worked signing example — and left the configuration table, 22 environment variables with their defaults, hand-transcribed and unguarded. The adversarial review on that change flagged it as the next guard worth having, and the reasoning is the same one that justified the first three: an agent reads `llms-full.txt` *instead of* the code, so a stale default there is not a documentation nit, it is a wrong answer delivered confidently.

Config is also the surface most likely to move. Defaults have already changed once (`AP_S3_ADDRESSING` flipped from path to virtual in `v0.3.0`), variables arrive with most slices, and nothing today fails when one lands undocumented. The option table gets a test; `AP_QUEUE_SIZE` changing from `32` does not.

The obstacle is that `AudioProxy.Config` does not publish the names it reads. `all/0` returns a map keyed by internal atom (`:queue_size`), not by variable (`AP_QUEUE_SIZE`), and the strings live inline in `build!/1`. So this change is mostly about giving the module a seam, and only then a test.

## What Changes

- `AudioProxy.Config` publishes the variables it reads, as data: name, and whether it has a default. One list, consumed by the guard, so a variable added to `build!/1` without a row there is the thing that fails.
- A drift guard in `test/audio_proxy/llms_test.exs`: the set of `AP_`-prefixed variables in the configuration table of `llms-full.txt` equals the set the module publishes, both directions, each failure naming the variable.
- Mark the config table in `llms-full.txt` with the same `<!-- config-table:start -->` delimiters the other two tables use, so one parser serves all three.
- Extend the same guard to the README's configuration table, which is the other hand-maintained copy of this list and drifts for the same reason.
- Decide, and write down, whether *default values* are guarded too or only variable names — see Open questions.

## Capabilities

### Modified Capabilities

- `ai-discoverability`: the documentation-drift requirement grows a third machine-checked set.

## Impact

- New: a public seam on `AudioProxy.Config`, one guard, delimiters in `priv/llms/llms-full.txt`.
- Modified: `CLAUDE.md` (the guarded list becomes three sets, not two-plus-an-example), `README.md` (the sentence about what is checked).
- **Depends on `add-llms-txt`**, which introduces the file, the guard module and the delimiter convention this builds on. It is a strict follow-up: nothing here makes sense before that lands.

## Open questions

- **Names only, or names *and* defaults?** Names are cheap and catch the common failure (a variable ships undocumented). Defaults are where the expensive errors live — a documented `300` that is now `600` misleads far worse than a missing row — but a default is not always a literal (`AP_MAX_PROBE_CONCURRENCY` is `4 ×` another variable, `AP_MAX_VARIANT_BYTES` inherits `AP_MAX_SRC_BYTES`, `AP_MAX_CONCURRENCY` is `System.schedulers_online()`), so comparing them means the module publishing a rendered *description* of each default and the document quoting it verbatim. That is a real constraint on how the table may be written. Decide before implementing; do not discover it halfway.
- Whether the README and llms tables should be checked against each other as well as against the module — probably not, since agreeing with the code implies agreeing with each other.
