## Why

`README.md` has reached 889 lines because it is still written as though it were
the only user-facing document. It is not, and has not been for some time:
`docs.audioproxy.dev` carries nine authored pages covering the same ground, and
the README does not link to it once. A grep for the site's name across
`README.md`, `docs/`, `llms*.txt` and `CLAUDE.md` returns nothing, so a reader
arriving at the repository has no way to discover the documentation site at all.

The result is the same material written three times — README, `docs/*.md`, and
the site — with only the third one designed for a reader who wants to *use* the
proxy. Two of the three then have to be kept in step by hand.

The root cause is a rule, not an oversight. `CLAUDE.md`'s documentation-shape
table instructs that the README holds "every option and its validation rules,
configuration, how to run it", and it predates the documentation site. Left
as it is, the README regrows whatever this change removes.

## What Changes

- **`README.md` becomes a landing page of roughly 150 lines.** It keeps what is
  genuinely repo-native — the pitch, a six-line quick start, the roadmap, the
  design sketch, the stack, the license and compliance posture, the AI-agent
  pointer, and a documentation routing table — and links out for everything else.
- **Every "how do I" section is delegated to `docs.audioproxy.dev`,** which the
  README links to prominently for the first time.
- **The configuration table is removed from the README.** `llms-full.txt` already
  carries the same list under the same machine-checked guard, so coverage is
  unchanged; only the second hand-maintained copy goes.
- **`test/readme_examples_test.exs` is deleted in full.** Both of the things it
  guards — the example option strings and the configuration table — are leaving
  the README, so the file would have nothing left to check.
- **`docs/` is unchanged.** It remains the authored-from upstream for the site's
  guide pages, and `bin/sync-proxy-docs` plus the drift-issue workflow in the
  docs repository keep working exactly as they do today.
- **`CLAUDE.md`'s documentation-shape table gains the site as a destination** and
  the README's entry is rewritten from "usage" to "routing", so the rule that
  produced the 889 lines no longer does.

Paired, in `audioproxy-docs`, tracked separately and running in parallel: the
site grows the pages that today exist only in the README — configuration,
signing, errors, `/info`, variant store and serve modes, caching and CDNs, and
operations (logs, metrics, health and readiness).

**BREAKING** for nobody: no code, no API surface, and no published contract
changes. `llms.txt`, `llms-full.txt` and `docs/audio-proxy-api-v1.md` are
untouched, so an agent or integrator reading the contract sees no difference.

## Capabilities

### New Capabilities
- `documentation-layout`: which document holds which kind of material, that the
  README routes rather than duplicates, and that the published contract keeps a
  repo-local home regardless of what the site carries.

### Modified Capabilities
- `ai-discoverability`: the configuration drift guard stops covering the
  README's table, because that table no longer exists. The guard against
  `llms-full.txt` is unchanged, and remains the enforced copy.

## Impact

- `README.md` — reduced from 889 lines to roughly 150.
- `test/readme_examples_test.exs` — deleted.
- `CLAUDE.md` — documentation-shape table updated.
- `openspec/specs/url-signing/spec.md` — a Purpose sentence citing "README
  examples" as a consumer of the signing vectors becomes stale; corrected in
  place, not a requirement change.
- `openspec/specs/ai-discoverability/spec.md` — one sentence removed, per above.
- No `lib/` changes. No dependency changes. No configuration changes.
