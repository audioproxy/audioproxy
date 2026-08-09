## Why

AI agents are increasingly the ones integrating APIs — generating signed URLs, choosing processing options, wiring the proxy into applications. The llms.txt convention gives them a single, token-efficient, markdown entry point. Because URLs are the entire API here, a well-formed llms.txt makes the service near-perfectly legible to an LLM: grammar, options table, error contract, done.

The reference has to be *correct*, though, and a second hand-maintained copy of the API is exactly the kind of document that rots. So the point of this change is as much the guards as the prose: the option table, the error table and the signing example are checked against the implementation, and CI fails when they disagree.

## What Changes

- Author `llms.txt` per the llms.txt spec (H1 title, blockquote summary, sectioned link list) covering: URL grammar and signing, processing options, response/cache semantics, error codes, configuration.
- Author `llms-full.txt` (expanded single-file variant) carrying the full API reference so agents need no follow-up fetches.
- Both at the repository root, where the convention puts them and where anyone browsing the repo finds them — and included in the hex package, so an embedder gets them in its dependency tree.
- Drift guards in the test suite: documented option keys must exactly match the options parser's known keys; documented error rows must match the error mapping's; the worked signing example must recompute; neither table may repeat a row; and the error mapping's published row set must cover everything it can render, so the guard cannot be satisfied by an incomplete set.
- Convention (CLAUDE.md): any slice that changes the API surface updates `llms-full.txt` in the same change, same as the README rule — stated alongside what the guards do *not* cover, so they are not mistaken for covering the file.

## Capabilities

### New Capabilities

- `ai-discoverability`: llms.txt authoring and documentation-drift enforcement.

### Modified Capabilities

<!-- none -->

## Not serving these over HTTP

An earlier draft of this change served both files from the app at `GET /llms.txt` and `GET /llms-full.txt`, unsigned, embedded into the release. That was built, reviewed and then removed, and the reasoning is worth keeping.

The argument for serving was version-matching: documents compiled into the release describe the build that is answering, not whatever is on `main`. It does not survive contact with the fact that this repo is public and tagged. `/health` already reports the version unsigned, so an agent can resolve `BASE` → version → the docs at that tag on GitHub, and get the same guarantee without the proxy serving anything. The convention itself targets *websites*, where a crawler discovers `/llms.txt` at a site root; an agent integrating with a self-hosted proxy realistically reads the repository instead.

What serving cost, against that: every deployment publishing 15 KB of unsigned documentation with no way to switch it off — a fingerprinting surface an operator never opted into — plus a router route, an endpoint class (and therefore a change to the `observability` spec's class enumeration), a compile-time embedding module, a `COPY priv priv` in two Docker stages, and a smoke check to prove the image carried it.

The one case that genuinely favours serving is an untagged build: `:edge` and `:sha-…` images report the same `mix.exs` version as the last release while carrying more API than that tag documents. That is narrow, and it is an argument about untagged images rather than about the feature.

Reopen this if a hosted docs site appears (llms.txt belongs at *its* root, not the proxy's), or if `:edge` deployments turn out to be a real integration target.

## Impact

- New: `llms.txt`, `llms-full.txt`, `AudioProxy.ErrorJSON.rows/0`, drift-guard tests (`test/llms_docs_test.exs`).
- Modified: CLAUDE.md conventions section, README (`For AI agents`, the documentation table).
- Depends on: the options parser and error table (merged) that the drift guards check against. Position: **after `add-metrics-endpoint` and `add-ready-endpoint`, before `add-hex-publishing`** — the guards cover option keys and error rows but not the endpoint list or config table, so llms content written before those two endpoints would go stale with no test failing. Landing last-but-one means the content is born complete. `add-hex-publishing` must add both files to its curated `files:` list; that is noted in its proposal.

## Deferred

- **The configuration table is not guarded.** 22 variables and their defaults, hand-transcribed into `llms-full.txt`, with nothing failing when one goes stale — `Config` publishes no list of the names it reads, so the guard needs a seam before it needs a test. Deferred to **`guard-config-documentation`**, which is on the board. The table is correct as of this change; what is missing is the thing that keeps it correct.
