## 1. Content

- [x] 1.1 Author `priv/llms/llms.txt`: H1 + blockquote summary, sections (URL grammar & signing, options overview, responses & caching, errors, config), relative + canonical links
- [x] 1.2 Author `priv/llms/llms-full.txt`: full API reference incl. options table (fixed format for drift guard), error table, worked signing example from signature test vectors

## 2. Serving

- [x] 2.1 Compile-time embedding (`@external_resource`), routes `GET /llms.txt` + `GET /llms-full.txt` (unsigned, `text/markdown`, cache headers)
- [x] 2.2 Plug.Test: 200 without signature, content type, cache headers, body non-empty for both routes

## 3. Drift guards

- [x] 3.1 `Options.known_keys/0` (and error-code introspection on ErrorJSON) exposed for tests — `Options.keys/0` already existed and is used as-is; `ErrorJSON.rows/0` is new
- [x] 3.2 Test: option keys in llms-full.txt table == parser keys (both directions, failure names the key)
- [x] 3.3 Test: documented error codes == ErrorJSON mapping codes
- [x] 3.4 Format lint test: one H1, leading blockquote, well-formed link lists under H2s

## 4. Docs & convention

- [x] 4.1 Update CLAUDE.md conventions: API-surface changes update llms.txt in the same slice (parallel to the README rule)
- [x] 4.2 Update README: mention llms.txt endpoints and the drift-guard mechanism
