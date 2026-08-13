## Context

Three documents describe how to use this proxy, and they have been growing
independently:

```
                    ┌──────────────────────────────────┐
                    │   docs.audioproxy.dev            │
                    │   quickstart · transforms        │
                    │   sources · rendering · scaling  │
   ┌───────────┐    │   capacity · s3-providers        │
   │ README.md │    │   rails · api-v1 (synced 1:1)    │
   │ 889 lines │    └──────────────────────────────────┘
   └───────────┘              ▲
         ✗ no link ───────────┘        ┌──────────────┐
                                       │   docs/*.md  │
   ┌──── links to ────────────────────▶│  2654 lines  │
   └───────────────────────────────────└──────────────┘
                                          ▲ authored-from
                                          │ (drift issue
                                          │  on change)
```

The site is the newest of the three and the only one designed goal-first for a
reader who wants to render audio. The README is the oldest, and it is the only
one of the three that does not know the other two exist in full.

`docs/` is not what it is described as. `CLAUDE.md` treats it as development
documentation, but only `development.md` and `ffmpeg-arguments.md` (669 lines of
2654) are that. The other five files are user and operator guides that the site
re-authors, with `bin/sync-proxy-docs` and a scheduled drift-issue workflow built
around exactly that arrangement.

Two constraints bound what can move:

- `test/readme_examples_test.exs` parses the README's example URLs against
  `AudioProxy.Options`, and its configuration table against
  `AudioProxy.Config.variables/0`.
- `openspec/specs/ai-discoverability/spec.md` requires that second comparison.

## Goals / Non-Goals

**Goals**

- `README.md` at roughly 150 lines, routing rather than duplicating.
- The documentation site discoverable from the repository.
- The rule in `CLAUDE.md` corrected, so the README does not regrow.
- No loss of coverage: everything removed is readable somewhere else, and
  everything machine-checked stays machine-checked.

**Non-Goals**

- Moving the five guide files out of `docs/`. The sync machinery depends on
  them staying, and a repository-only reader would lose `capacity.md`, which is
  the one guide an operator reads while the site might be down.
- Changing `llms.txt`, `llms-full.txt` or `docs/audio-proxy-api-v1.md`. The
  published contract is untouched by this change.
- Any `lib/` change.

## Decisions

**1. `docs/` stays as it is (option A), rather than being emptied of guides.**

The alternative — moving the five guides to the site and leaving `docs/` with
only development material — is more honest to the phrase "development
documentation", and it was rejected on cost. It inverts the sync direction for
five files, so `bin/sync-proxy-docs` and the drift workflow both need rewriting;
and it removes the repository's only offline copy of the capacity model. The
contradiction it would resolve is a naming one, and naming is cheaper to fix in
`CLAUDE.md` than by moving 1900 lines across repositories.

**2. `llms-full.txt` becomes the only guarded copy of the configuration surface.**

The README's table was guarded because it was a second hand-written copy of the
same list. Removing the copy removes the reason for the guard. Coverage is
unchanged: `llms_docs_test.exs` already compares `llms-full.txt` against
`AudioProxy.Config.variables/0`, and `ConfigTest` already fails when
`variables/0` and the reads in `config.ex` disagree. The chain from code to
published document stays intact end to end.

The site's own configuration page is deliberately *not* guarded. It lives in
another repository with no access to `AudioProxy.Config`, and the drift-issue
workflow is the mechanism that covers it — a human editorial pass, which is what
the site's authored pages get by design.

**3. `test/readme_examples_test.exs` is deleted rather than narrowed.**

Both halves lose their subject. The examples move to the site's transforms page
and the table is gone, so a narrowed file would guard an empty README. The
example option strings are still exercised: `options_property_test.exs` holds
the parse/normalize/round-trip contract, and the site's examples are checked by
editorial review the way its other pages are.

This is a real reduction in coverage, and it is worth naming: the site's example
URLs are no longer parsed by anything. That is the same posture every other
authored page on the site already has.

**4. The paired docs-site work runs in parallel, not first.**

Roughly a third of the README (~310 lines) covers material the site has no page
for: configuration, signing, errors, `/info`, variant store and serve modes,
caching and CDNs, and operations. Blocking the README on those pages would
serialize two repositories for no benefit — the README can link to a page that
lands a day later, and the interim link is a `docs/` file or the API reference,
both of which exist today.

**5. `CLAUDE.md` is edited in the same change.**

The documentation-shape table is what produced the 889 lines. Leaving it and
trimming the README would put the two in direct contradiction, and the table
wins, because it is the instruction an agent reads before writing.

## Risks / Trade-offs

- **A reader loses the single-page overview.** Someone who liked reading the
  whole surface in one scroll now follows links. → `llms-full.txt` is exactly
  that document, self-contained by requirement, and the README points at it.

- **The site's example URLs go unchecked** (decision 3). → Accepted; it matches
  the posture of every other authored page. If it bites, the guard belongs in the
  docs repository against a running proxy, not here.

- **The README links to site pages that do not exist yet** (decision 4). → Each
  such link points at its `docs/` counterpart or the API reference until the site
  page lands; a task below enumerates them so none is left pointing at a 404.

- **`docs/` remains a second copy of user material** — the contradiction this
  change consciously does not resolve. → Named in `CLAUDE.md` as the authored-from
  upstream it actually is, so it reads as deliberate rather than as drift.

## Migration Plan

No deployment, no rollback: documentation only. The one ordering constraint is
that `test/readme_examples_test.exs` must be deleted in the same commit that
removes the configuration table from the README, or the suite fails between them.
`CLAUDE.md` and the spec delta can land in either order.

## Open Questions

- **Does the README's prose keep its em-dashes?** The existing voice uses them
  heavily and it is the author's own; the rewrite should preserve the house style
  rather than quietly restyle it. Confirm before writing.
- **Which site page does each removed section link to** before its page exists?
  Enumerated as a task rather than decided here, since the docs-side work is in
  flight in parallel.
