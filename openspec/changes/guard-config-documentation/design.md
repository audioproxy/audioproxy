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
- Guarding the `AWS_*` variables through the same seam — they are deliberately not `AP_`-prefixed, and are read in a different place. Decide whether they get a second, smaller list or stay reviewed.

## Decisions

- **The seam is a list of variables, not a reflection trick.** `Config` gains something like `variables/0` returning the `AP_`-prefixed names it reads. Hand-maintained inside the module it describes, one file away from the `build!/1` line that reads each one — the same trade `ErrorJSON.not_found_reasons/0` and `@representative_errors` already make. The point is not that it cannot be forgotten; it is that forgetting it fails a test rather than shipping a wrong document.

  `add-llms-txt` learned the sharp edge here the hard way: a derived list that a new clause does not automatically join is a guard with a hole in one direction. Whatever shape `variables/0` takes, the change must also answer "what fails when someone adds a variable to `build!/1` and nothing else?" — and if the answer is "nothing", it needs the equivalent of the clause-count test that closed that hole.

- **The parser is reused, not rewritten.** `llms_test.exs` already extracts backticked first cells from a marked region. The config table's first cell is `` `AP_QUEUE_SIZE` ``, which fits that shape unchanged.

- **The README table is checked by the same test.** It is not marked with HTML comments today, and adding markers to a README is uglier than to a `priv/` file. Either mark it, or anchor on the section heading — decide during implementation, and prefer whichever leaves the README readable.

## Risks / Trade-offs

- [The seam is another list to keep in step, and this change exists because lists drift] → mitigated only if the change ships the test that catches a stale seam, not just the test that catches a stale document. This is the central risk; treat it as the acceptance criterion.
- [Guarding defaults constrains how the table may be written] → see the open question in the proposal. Guarding names only is a smaller, honest step, and the change should say plainly in `CLAUDE.md` which of the two it delivered rather than letting readers assume the stronger one.
