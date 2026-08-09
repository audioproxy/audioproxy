## Why

Two consumers want `audio_proxy` as a declared dependency: the PRO wrapper release (one BEAM node, `{:audio_proxy, "~> 0.x"}`) and anyone embedding the proxy in their own supervision tree. That needs the package on hex.pm — and it surfaces a prerequisite: **the repo has no LICENSE file**, so it is not legally open source at all today. License decided: **Apache-2.0** (explicit patent grant, zero friction for the open-core wrapper, no CLA needed; the commercial moat is the private PRO code, not the license). Both `audio_proxy` and `audioproxy` are unclaimed on hex.

## What Changes

- `LICENSE` (Apache-2.0) at the repo root; license headers not required (Apache-2.0 does not mandate per-file headers).
- `mix.exs` package metadata: `description`, `package` (licenses, GitHub link, curated `files:` list — `lib`, `mix.exs`, `README.md`, `LICENSE`, `VERSIONS.md`, `docs/`, **`llms.txt`, `llms-full.txt`**; never `openspec/`, `test/`, `examples/`, `Dockerfile`, `.github/`), `docs` config; `{:ex_doc, only: :dev, runtime: false}`.

  **The two llms files are the point of shipping docs in the package at all.** `add-llms-txt` put them at the repo root: `llms-full.txt` is the whole API contract in one self-contained markdown file, machine-checked against the parser and the error mapping. An embedder who has `{:audio_proxy, "~> 0.x"}` in their `mix.exs` should find it in `deps/audio_proxy/`, next to the code it describes, rather than having to go back to GitHub and work out which tag they are on. Nothing breaks without them — they are read by tests, not compiled in — but leaving them out removes the one advantage a package has over a URL.
- CI: `mix hex.publish --yes` joins the tag-triggered publish job, gated behind smoke like the image push, authenticated via a write-scoped `HEX_API_KEY` secret — a `v*` tag ships image and package atomically, with the existing mix.exs==tag assertion guaranteeing version agreement.
- A tarball-content check in CI (`mix hex.build` + inspection) so the curated file list cannot silently regress.
- Embedding contract documented: starting the `audio_proxy` application boots its listener and runs config validation from env — the intended behavior for a wrapper release, stated on hexdocs so no embedder is surprised.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: releases SHALL additionally publish the hex package, version-locked to the git tag and image.

## Impact

- New: `LICENSE`; hex.pm account/org + `HEX_API_KEY` repo secret (manual, documented).
- Modified: `mix.exs`, `.github/workflows/ci.yml`, README (hexdocs link + embedding note).
- Depends on: merged code only. First publish rides the next release tag.
