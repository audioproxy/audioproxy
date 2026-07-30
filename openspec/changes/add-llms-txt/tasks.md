## 1. Content

- [ ] 1.1 Author `priv/llms/llms.txt`: H1 + blockquote summary, sections (URL grammar & signing, options overview, responses & caching, errors, config), relative + canonical links
- [ ] 1.2 Author `priv/llms/llms-full.txt`: full API reference incl. options table (fixed format for drift guard), error table, worked signing example from signature test vectors

## 2. Serving

- [ ] 2.1 Compile-time embedding (`@external_resource`), routes `GET /llms.txt` + `GET /llms-full.txt` (unsigned, `text/markdown`, cache headers)
- [ ] 2.2 Plug.Test: 200 without signature, content type, cache headers, body non-empty for both routes

## 3. Drift guards

- [ ] 3.1 `Options.known_keys/0` (and error-code introspection on ErrorJSON) exposed for tests
- [ ] 3.2 Test: option keys in llms-full.txt table == parser keys (both directions, failure names the key)
- [ ] 3.3 Test: documented error codes == ErrorJSON mapping codes
- [ ] 3.4 Format lint test: one H1, leading blockquote, well-formed link lists under H2s

## 4. Docs & convention

- [ ] 4.1 Update CLAUDE.md conventions: API-surface changes update llms.txt in the same slice (parallel to the README rule)
- [ ] 4.2 Update README: mention llms.txt endpoints and the drift-guard mechanism
