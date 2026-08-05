## 1. Licensing & metadata

- [x] 1.1 `LICENSE` (Apache-2.0) at the repo root — landed early (pulled forward; the repo was public without a license)
- [ ] 1.2 `mix.exs`: `description`, `package` (licenses, links, curated `files:`), `docs` (`main: "readme"`, extras); `{:ex_doc, only: :dev, runtime: false}`
- [ ] 1.3 README: embedding-contract note (app start boots the listener, validates `AP_*` env); hexdocs/hex badges

## 2. Publishing

- [ ] 2.1 hex.pm account/org, write-scoped key → `HEX_API_KEY` repo secret (manual; document in docs/development.md release procedure)
- [ ] 2.2 CI: `mix hex.publish --yes` in the tag publish job (`needs: smoke`), after the image push
- [ ] 2.3 Tarball-content check in CI: `mix hex.build`, assert LICENSE present and no `openspec/`/`test/`/`examples/`/`Dockerfile`/`.github/` paths
- [ ] 2.4 Dry-run locally (`mix hex.build` + inspect) before the first tagged publish

## 3. Verification

- [ ] 3.1 First release tag after merge: confirm package on hex.pm, docs on hexdocs.pm, version == tag == image
