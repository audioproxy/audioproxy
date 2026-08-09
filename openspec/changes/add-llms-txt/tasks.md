## 1. Content

- [x] 1.1 Author `llms.txt`: H1 + blockquote summary, sections (URL grammar & signing, options overview, responses & caching, errors, config), links to the canonical docs
- [x] 1.2 Author `llms-full.txt`: full API reference incl. options table (fixed format for drift guard), error table, worked signing example from signature test vectors

## 2. Drift guards

- [x] 2.1 `Options.known_keys/0` (and error-code introspection on ErrorJSON) exposed for tests — `Options.keys/0` already existed and is used as-is; `ErrorJSON.rows/0` is new
- [x] 2.2 Test: option keys in llms-full.txt table == parser keys (both directions, failure names the key)
- [x] 2.3 Test: documented error rows == ErrorJSON's rows
- [x] 2.4 Test: the worked signing example recomputes from `Signature.sign/3`
- [x] 2.5 Test: neither table repeats a row, so a duplicate cannot collapse into an equal set
- [x] 2.6 Test: `ErrorJSON.rows/0` covers every `render/1` clause, so the guard cannot be satisfied by an incomplete set
- [x] 2.7 Format lint test: one H1, leading blockquote, well-formed link lists under H2s

## 3. Docs & convention

- [x] 3.1 Update CLAUDE.md conventions: API-surface changes update llms-full.txt in the same slice (parallel to the README rule), and state what the guards do *not* cover
- [x] 3.2 Update README: the two files and the drift-guard mechanism

## 4. Serving — cut

- [x] 4.1 Serving both files from the app was built and then removed; `proposal.md` records the argument. `add-hex-publishing` must carry both files in its `files:` list — noted in its proposal
