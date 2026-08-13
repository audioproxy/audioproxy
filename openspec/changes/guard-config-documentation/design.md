## Context

`add-llms-txt` established the pattern: a marked region in `priv/llms/llms-full.txt`, a table parser in `test/audio_proxy/llms_test.exs` that reads the first cell of each row, and a set comparison against something the implementation publishes (`Options.keys/0`, `ErrorJSON.rows/0`). Two of the three guards are set comparisons over names; the third recomputes a value.

The configuration table is the largest hand-maintained claim in the file — 22 rows — and the only one with no counterpart in code that a test can reach. `AudioProxy.Config.all/0` returns a map keyed by internal atom, and the variable names themselves are string literals inside `build!/1`.

## Goals / Non-Goals

**Goals:**
- A variable added to `Config` and not documented fails CI, naming the variable.
- A variable documented that `Config` does not read fails CI, naming it.
- One parser serves all three (soon four) marked tables.

**Non-Goals:**
- Validating prose in the `Purpose` column. Same line as the existing guards: coverage is enforced, prose is reviewed.
- Generating the table from the module. A generated table would be accurate and unreadable, and the file's value is that it reads like documentation.
- Guarding the `AWS_*` variables through the same seam — they are deliberately not `AP_`-prefixed. Settled below: they stay reviewed.

## Decisions

- **The seam is a list of variables, not a reflection trick.** `Config` gains something like `variables/0` returning the `AP_`-prefixed names it reads. Hand-maintained inside the module it describes, one file away from the `build!/1` line that reads each one — the same trade `ErrorJSON.not_found_reasons/0` and `@representative_errors` already make. The point is not that it cannot be forgotten; it is that forgetting it fails a test rather than shipping a wrong document.

  `add-llms-txt` learned the sharp edge here the hard way: a derived list that a new clause does not automatically join is a guard with a hole in one direction. Whatever shape `variables/0` takes, the change must also answer "what fails when someone adds a variable to `build!/1` and nothing else?" — and if the answer is "nothing", it needs the equivalent of the clause-count test that closed that hole.

- **Names only, not defaults.** Settled here rather than left to the implementation, because the alternative constrains how the tables may be written and the constraint is worse than the bug it prevents. The two documents already render the same default differently, on purpose and for different readers: `AP_MAX_PROBE_CONCURRENCY` is `4 × AP_MAX_CONCURRENCY` in the README and `` `4 ×` the above `` in `llms-full.txt`; `AP_S3_ADDRESSING` is "`virtual` with no `AP_S3_ENDPOINT`, `path` with one" in one and "`virtual`, or `path` with an endpoint" in the other. Guarding defaults means the module publishing one rendered string and both documents quoting it verbatim, which flattens two audiences into one phrasing and makes every default cell unreadable in at least one of the files. So: the guard is a set comparison over variable names, in both directions, and `CLAUDE.md` says so plainly rather than letting a reader assume the stronger guarantee.

  This is the smaller, honest step the trade-off note asks for, and it catches the failure that actually happens — a variable ships undocumented. A default that moves is still caught by review, and by the fact that a default lives one `@default_*` attribute away from the table row that quotes it.

- **The `AWS_*` variables stay out.** `Config` reads five of them, and they are deliberately not `AP_`-prefixed because every credential tool already writes those names. The guard's subject is "the `AP_` surface this proxy defines", which is what both tables are headed with and what the requirement says; folding in a set of standard AWS names would mean the tables growing rows for variables the proxy did not invent and does not validate individually. Both documents describe them in prose below the table, and that prose stays reviewed rather than checked. The seam and both parsers therefore filter on the `AP_` prefix, which also keeps the source scan below from tripping over `AWS_REGION`.

- **The seam is guarded by scanning its own module's source.** Every read in `Config` goes through a parser helper whose first two arguments are `env` and the variable name as a literal — `integer(env, "AP_QUEUE_SIZE", …)`, `fetch(env, "AP_PORT")`, `enum(env, "AP_S3_ADDRESSING", …)`. So the test that answers "what fails when someone adds a variable to `build!/1` and nothing else?" reads `lib/audio_proxy/config.ex` and compares every `(env, "AP_…")` literal against `variables/0`, both directions. It is a scan of the one file the seam describes, not reflection over the codebase, and it fails on the same line the author is already editing.

- **The parser is reused, not rewritten.** `llms_test.exs` already extracts backticked first cells from a marked region. The config table's first cell is `` `AP_QUEUE_SIZE` ``, which fits that shape unchanged.

- **The README table is checked by the same test.** It is not marked with HTML comments today, and adding markers to a README is uglier than to a `priv/` file. Either mark it, or anchor on the section heading — decide during implementation, and prefer whichever leaves the README readable.

## Risks / Trade-offs

- [The seam is another list to keep in step, and this change exists because lists drift] → mitigated only if the change ships the test that catches a stale seam, not just the test that catches a stale document. This is the central risk; treat it as the acceptance criterion.
- [Guarding defaults constrains how the table may be written] → see the open question in the proposal. Guarding names only is a smaller, honest step, and the change should say plainly in `CLAUDE.md` which of the two it delivered rather than letting readers assume the stronger one.
