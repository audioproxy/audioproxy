## 1. Licensing & metadata

- [x] 1.1 `LICENSE` (Apache-2.0) at the repo root — landed early (pulled forward; the repo was public without a license)
- [x] 1.2 `mix.exs`: `description`, `package` (licenses, links, curated `files:`), `docs` (`main: "readme"`, extras); `{:ex_doc, only: :dev, runtime: false}`
- [x] 1.3 README: embedding-contract note (app start boots the listener, validates `AP_*` env); hexdocs/hex badges

## 2. Publishing

- [x] 2.1 hex.pm account/org, write-scoped key → `HEX_API_KEY` repo secret — done as a **repository** secret (an environment secret would not resolve: the `publish` job declares no `environment:`). Generated at hex.pm/dashboard/keys, since Hex 2.5.1 has no user-key CLI; the procedure is in `docs/development.md`, *The hex credentials*, along with the expiry trap — a lapsed key fails a tag *after* the image has pushed.
- [x] 2.2 CI: `mix hex.publish` in the tag publish job (`needs: smoke`), after the image push — landed as **two** steps, `package` then `docs`. A published version can only be overwritten within an hour and only with `--replace`, while docs have no limit, so a combined command whose docs half failed left a release a re-run could not repair
- [x] 2.3 Tarball-content check in CI: `mix hex.build`, assert LICENSE **and `llms.txt` + `llms-full.txt`** present, and no `openspec/`/`test/`/`examples/`/`Dockerfile`/`.github/` paths — `bin/check-hex-package`, run by the `hex-package` job on every pull request rather than only on a tag
- [x] 2.4 Compile the built tarball outside the repo — unpack, `mix compile` — so "the package builds for a consumer" is tested rather than inferred from the file list. `MIX_ENV=prod` explicitly: CI exports `test`, and `elixirc_paths(:test)` names `test/support`, which the tarball correctly does not carry
- [x] 2.5 Dry-run locally (`mix hex.build` + inspect) before the first tagged publish — run green on this branch, and in the release procedure as step 3. The guard was also red-path checked: adding an `openspec/` path to `files:` fails it
- [x] 2.6 Add **"the hex package is what we meant to ship"** to `main`'s required status checks — **maintainer action.** Added after the adversarial review: `needs:` stops a bad *tag* from publishing, but nothing stops a pull request from merging a bad tarball, and by tag time the fix is a new version rather than an edit. Until the protection rule names it, a red `hex-package` is advisory. Noted in `docs/development.md` under branch protection

## 3. Verification

- [x] 3.1 First release tag after merge: confirm package on hex.pm, docs on hexdocs.pm, version == tag == image — **verified on `v0.4.0`.** hex.pm reports `audio_proxy 0.4.0` (Apache-2.0, sole version), hexdocs.pm/audio_proxy/0.4.0 answers 200, and the GHCR image `:0.4.0` carries `org.opencontainers.image.version=0.4.0` with `revision=29e7411` — the tagged commit, so image and package are provably the same code. Release: https://github.com/audioproxy/audioproxy/releases/tag/v0.4.0

  **It took three tags, and both failures were in the release path itself** — worth knowing before the next one, because neither could have been caught by a pull request:

  - A property test refuted a legitimate subdomain (`*.lv.m` vs `lv.m.lv.m`) once every few hundred generated runs. Fixed in #64, with both claims pinned as ordinary tests.
  - The tag/`mix.exs` version assertion grepped for `version: "…"`, which this very change had refactored into a `@version` attribute — so it compared the tag against an empty string. Fixed in #65 by moving the extraction to `bin/project-version`, shared with `bin/check-hex-package` so a pull request exercises it.

  Nothing published on either failed attempt (image push and hex are both behind the assertion), so `v0.4.0` was re-tagged twice at no cost. Before the third attempt the remaining tag-only steps were rehearsed with `mix hex.publish package --dry-run` and `docs --dry-run`; hex.pm stayed 404 throughout.
