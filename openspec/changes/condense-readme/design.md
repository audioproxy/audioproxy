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

**3. `test/readme_examples_test.exs` is narrowed rather than deleted.**

Only its configuration half loses its subject. The example half keeps one: the
condensed quick start still renders variants, and an example URL that has
quietly become a 422 is exactly the failure this file was written for. The
options parser has tightened twice for combinations no encoder can honour, and
each time an example could have rotted unnoticed until a reader pasted it.

So the `describe "the configuration table"` block goes, along with the
`MarkedTable` and `Config` aliases and the two helpers only it used. The four
example tests stay, with their minimum-count assertion lowered to the number of
examples the condensed quick start actually carries. Deleting the file was the
earlier plan, and it gave up a live guard to save a five-line edit.

The examples that move to the site's transforms page are unguarded there, the
same posture every other authored page has.

**4. The paired docs-site work runs in parallel, not first.**

Roughly a third of the README (~310 lines) covers material the site has no page
for: configuration, signing, errors, `/info`, variant store and serve modes,
caching and CDNs, and operations. Blocking the README on those pages would
serialize two repositories for no benefit — the README can link to a page that
lands a day later, and the interim link is a `docs/` file or the API reference,
both of which exist today.

**5. Logs and metrics move to `docs/operations.md` rather than being deleted.**

Found while checking cross-links: of everything the README carried, all of it
had a second home except two sections. Configuration, errors, `/info`, cache
semantics and serve modes are in `docs/audio-proxy-api-v1.md`; signing and
cache-key derivation are in §1 and §3; health and readiness are in
`docs/scaling.md`, at more length than the README had them. But the metrics
catalogue (eleven metric names, their labels, the fixed histogram buckets, the
scrape config, the four signals) and the request-log format appeared **nowhere
else in the repository** — not in the API doc, not in `llms-full.txt`, not on
the site.

Deleting them would have lost them until the site's operations page was written,
which is scheduled in another repository on another timeline. So they become
`docs/operations.md`, which is exactly the role decision 1 assigns `docs/`: the
authored-from upstream a site guide is written against. Task 6.7 now has a
source rather than a blank page.

This is why the link audit runs before the commit and not after. The README was
the only home for two sections, and nothing about removing them says so.

**6. `CLAUDE.md` is edited in the same change.**

The documentation-shape table is what produced the 889 lines. Leaving it and
trimming the README would put the two in direct contradiction, and the table
wins, because it is the instruction an agent reads before writing.

## Risks / Trade-offs

- **A reader loses the single-page overview.** Someone who liked reading the
  whole surface in one scroll now follows links. → `llms-full.txt` is exactly
  that document, self-contained by requirement, and the README points at it.

- **The examples that move to the site go unchecked** (decision 3). → Accepted;
  it matches the posture of every other authored page. If it bites, the guard
  belongs in the docs repository against a running proxy, not here. The ones the
  README keeps stay guarded.

- **The narrowed guard could be satisfied by too few examples.** A quick start
  trimmed further in some later change would shrink the guarded set silently. →
  The minimum-count assertion is the backstop, and it is set to what the quick
  start carries rather than to zero.

- **The README links to site pages that do not exist yet** (decision 4). → Each
  such link points at its `docs/` counterpart or the API reference until the site
  page lands; a task below enumerates them so none is left pointing at a 404.

- **`docs/` remains a second copy of user material** — the contradiction this
  change consciously does not resolve. → Named in `CLAUDE.md` as the authored-from
  upstream it actually is, so it reads as deliberate rather than as drift.

## Migration Plan

No deployment, no rollback: documentation only. The one ordering constraint is
that the configuration-table guard must be removed in the same commit that
removes the table from the README, or the suite fails between them. `CLAUDE.md`
and the spec delta can land in either order.

## Decided since drafting

- **The README's prose drops its em-dashes.** The rewrite replaces them with
  commas, semicolons, parentheses, or separate sentences, rather than carrying
  the existing style forward. This applies to the README's prose only; `docs/`,
  `CLAUDE.md` and the spec files keep theirs, since this change is not a
  repository-wide restyle.

## Open Questions

- **Which site page does each removed section link to** before its page exists?
  Enumerated as a task rather than decided here, since the docs-side work is in
  flight in parallel.
