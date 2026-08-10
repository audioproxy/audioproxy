## 1. Licensing & metadata

- [x] 1.1 `LICENSE` (Apache-2.0) at the repo root — landed early (pulled forward; the repo was public without a license)
- [x] 1.2 `mix.exs`: `description`, `package` (licenses, links, curated `files:`), `docs` (`main: "readme"`, extras); `{:ex_doc, only: :dev, runtime: false}`
- [x] 1.3 README: embedding-contract note (app start boots the listener, validates `AP_*` env); hexdocs/hex badges

## 2. Publishing

- [x] 2.1 hex.pm account/org, write-scoped key → `HEX_API_KEY` repo secret — done as a **repository** secret (an environment secret would not resolve: the `publish` job declares no `environment:`). Generated at hex.pm/dashboard/keys, since Hex 2.5.1 has no user-key CLI; the procedure is in `docs/development.md`, *The hex credentials*, along with the expiry trap — a lapsed key fails a tag *after* the image has pushed.
- [x] 2.2 CI: `mix hex.publish --yes` in the tag publish job (`needs: smoke`), after the image push
- [x] 2.3 Tarball-content check in CI: `mix hex.build`, assert LICENSE **and `llms.txt` + `llms-full.txt`** present, and no `openspec/`/`test/`/`examples/`/`Dockerfile`/`.github/` paths — `bin/check-hex-package`, run by the `hex-package` job on every pull request rather than only on a tag
- [x] 2.4 Compile the built tarball outside the repo — unpack, `mix compile` — so "the package builds for a consumer" is tested rather than inferred from the file list. `MIX_ENV=prod` explicitly: CI exports `test`, and `elixirc_paths(:test)` names `test/support`, which the tarball correctly does not carry
- [x] 2.5 Dry-run locally (`mix hex.build` + inspect) before the first tagged publish — run green on this branch, and in the release procedure as step 3. The guard was also red-path checked: adding an `openspec/` path to `files:` fails it

- [ ] 2.6 Add **"the hex package is what we meant to ship"** to `main`'s required status checks — **maintainer action.** Added after the adversarial review: `needs:` stops a bad *tag* from publishing, but nothing stops a pull request from merging a bad tarball, and by tag time the fix is a new version rather than an edit. Until the protection rule names it, a red `hex-package` is advisory. Noted in `docs/development.md` under branch protection

## 3. Verification

- [ ] 3.1 First release tag after merge: confirm package on hex.pm, docs on hexdocs.pm, version == tag == image — **post-merge, on the next release tag.** Nothing reaches hex until a `vX.Y.Z` tag is pushed *and* 2.1 is done
