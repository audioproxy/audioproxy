## Why

Two consumers want `audio_proxy` as a declared dependency: the PRO wrapper release (one BEAM node, `{:audio_proxy, "~> 0.x"}`) and anyone embedding the proxy in their own supervision tree. That needs the package on hex.pm — and it surfaces a prerequisite: **the repo has no LICENSE file**, so it is not legally open source at all today. License decided: **Apache-2.0** (explicit patent grant, zero friction for the open-core wrapper, no CLA needed; the commercial moat is the private PRO code, not the license). Both `audio_proxy` and `audioproxy` are unclaimed on hex.

## What Changes

- `LICENSE` (Apache-2.0) at the repo root; license headers not required (Apache-2.0 does not mandate per-file headers).
- `mix.exs` package metadata: `description`, `package` (licenses, GitHub link, curated `files:` list — `lib`, **`priv`**, `mix.exs`, `README.md`, `LICENSE`, `VERSIONS.md`, `docs/`; never `openspec/`, `test/`, `examples/`, `Dockerfile`, `.github/`), `docs` config; `{:ex_doc, only: :dev, runtime: false}`.

  **`priv` is load-bearing, not tidiness.** `add-llms-txt` put `priv/llms/llms.txt` and `priv/llms/llms-full.txt` in the tree and has `AudioProxy.Llms` read them with `File.read!` at *compile* time. A dependency is compiled from source at the consumer, so a tarball without `priv/llms/` does not degrade at runtime — it fails to compile, with a `File.Error` naming a path that is not in the package. The curated list predates that change and would ship exactly that break.
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
