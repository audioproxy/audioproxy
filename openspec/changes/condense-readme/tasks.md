## 1. Decide the link targets

- [ ] 1.1 List every README section being removed and name its destination URL, distinguishing pages that exist on the site today from pages the paired docs-side work will add
- [ ] 1.2 For each destination that does not exist yet, choose the interim target (its `docs/` counterpart, or `docs/audio-proxy-api-v1.md`) so no link ships pointing at a 404
- [ ] 1.3 Confirm the README keeps its existing prose voice, em-dashes included, rather than being restyled by the rewrite

## 2. Rewrite the README

- [ ] 2.1 Keep and tighten the repo-native sections: pitch, status, Roadmap, Design, Stack, License, For AI agents
- [ ] 2.2 Reduce Quick start to the shortest thing that renders one variant, and link to the site's quickstart for the rest
- [ ] 2.3 Remove the sections the site owns: What you can do with it, Signing URLs, Rendering a variant, Asking what a source is, Processing options, Sources, Errors, Variant store, Cache semantics, Choosing a serve mode, Caching and CDNs, Health and readiness, Logs, Metrics
- [ ] 2.4 Remove the configuration table and its `<!-- config-table:start -->` / `:end` markers
- [ ] 2.5 Rewrite the Documentation table as the routing table, with the documentation site as its first row
- [ ] 2.6 Add the site link to the header area, so it is visible without scrolling
- [ ] 2.7 Verify every remaining internal anchor still resolves, since most of the sections they pointed at are gone

## 3. Drop the guard

- [ ] 3.1 Delete `test/readme_examples_test.exs`
- [ ] 3.2 Confirm `test/llms_docs_test.exs` still covers the configuration surface against `AudioProxy.Config.variables/0`, unchanged
- [ ] 3.3 Check `test/support/marked_table.ex` for callers other than the llms guard; keep the module if `llms_docs_test.exs` still uses it, and update its `CLAUDE.md` row if the README is no longer one of the documents it parses
- [ ] 3.4 `mix test` green, `mix format`, `mix compile --warnings-as-errors`

## 4. Correct the rules

- [ ] 4.1 Update `CLAUDE.md`'s documentation-shape table: add `docs.audioproxy.dev` as a destination, rewrite the `README.md` row from usage to routing, and describe `docs/` as the authored-from upstream for the site's guides rather than as development documentation
- [ ] 4.2 Update the `CLAUDE.md` paragraph on the llms guards so it no longer says the README's configuration table is held to the same comparison
- [ ] 4.3 Update the Test support table in `CLAUDE.md` if `MarkedTable`'s row changed in 3.3
- [ ] 4.4 Correct the Purpose sentence in `openspec/specs/url-signing/spec.md` that cites README examples as a consumer of the signing vectors

## 5. Review and land

- [ ] 5.1 Read the rewritten README end to end as a first-time visitor: can they render something, and can they find everything else?
- [ ] 5.2 Confirm the line count is in the target range and no usage reference material remains
- [ ] 5.3 Adversarial review per `CLAUDE.md`, reconciled against a self-review written first
- [ ] 5.4 Commit as `docs:` scoped changes, one logical change each; open the PR

## 6. Paired work in `audioproxy-docs` (tracked there, running in parallel)

- [ ] 6.1 Configuration page: the full `AP_*` surface, the `AWS_*` credentials group, sizing guidance
- [ ] 6.2 Signing page: the HMAC rule, the Elixir and Ruby reference signers, dev mode
- [ ] 6.3 Errors page: the status/code/when table
- [ ] 6.4 `/info` page: the endpoint, its fields, its caching and probe behavior
- [ ] 6.5 Variant store and serve modes page: backends, write-back, `redirect` vs `proxy`
- [ ] 6.6 Caching and CDNs page: the `Cache-Control` table, revalidation, `HEAD`, `Range`
- [ ] 6.7 Operations page: logs, metrics, health and readiness
- [ ] 6.8 Fold the README's example URLs into the transforms page
- [ ] 6.9 Confirm the interim links chosen in 1.2 are replaced with their real targets once these land
