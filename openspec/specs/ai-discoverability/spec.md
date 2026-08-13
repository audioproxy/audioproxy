# ai-discoverability Specification

## Purpose
What an agent integrating against this proxy can read instead of the code, and
what keeps that document honest.

URLs are the entire API here, which makes the service unusually legible to an
LLM: a grammar, an options table, an error contract, and the signing rule are
the whole of it. `llms-full.txt` is that, self-contained, so an agent needs one
fetch rather than a tour of the repository.

A second hand-maintained copy of an API is exactly the kind of document that
rots, so the guards matter as much as the prose. Three sets are machine-checked
against the implementation — option keys, error rows, and the worked signing
example — and CI fails when they disagree. Everything else in the file is
reviewed the way the README is. That boundary is deliberate and stated in the
documents themselves: coverage is enforced, prose is owned by whoever writes it.

These are published files, not endpoints. Serving them from the app was built
and then cut: `/health` already reports the version unsigned, and the repository
is public and tagged, so an agent resolves version → docs-at-that-tag without
the proxy publishing anything. The argument, including the case that still
favours serving, is recorded in the archived `add-llms-txt` change.

## Requirements

### Requirement: llms.txt documents exist and conform to the format
The repository SHALL carry `llms.txt` and `llms-full.txt` at its root, following the llms.txt convention: exactly one H1 title, a blockquote summary immediately after it, and H2-sectioned link lists; `llms-full.txt` SHALL carry the same lead plus the complete API reference, sufficient on its own to construct a correct signed URL.

They SHALL be included in the published package, so a consumer that declares `audio_proxy` as a dependency finds them in its dependency tree.

#### Scenario: Structural lint
- **WHEN** the test suite parses `llms.txt`
- **THEN** it finds one H1, a leading blockquote, and only well-formed `- [name](url): description` entries under H2 sections

#### Scenario: Self-contained reference
- **WHEN** an integrator reads `llms-full.txt` alone
- **THEN** it carries the URL grammar, the signing rule with a worked example, every processing option, the cross-key rules, cache-key derivation, response semantics, the error table and the configuration surface

### Requirement: Documentation cannot drift from the implementation
The test suite SHALL fail when llms content disagrees with the implementation: the set of documented processing-option keys MUST equal the options parser's known keys, the set of documented error rows MUST equal the error mapping's rows, and the worked signing example MUST equal what the signer produces.

The error mapping SHALL publish its rows as data, and a test SHALL fail when that published set does not cover every response the mapping can render — otherwise the guard checks the document against an incomplete set and passes.

#### Scenario: Option added without documentation
- **WHEN** a new option key exists in the parser but not in `llms-full.txt`
- **THEN** the drift-guard test fails naming the missing key

#### Scenario: Stale documentation
- **WHEN** `llms-full.txt` documents an option key the parser does not know
- **THEN** the drift-guard test fails naming the stale key

#### Scenario: Error table parity
- **WHEN** the error rows documented in `llms-full.txt` differ from the error mapping's rows
- **THEN** the drift-guard test fails naming the rows that differ

#### Scenario: A repeated row cannot satisfy the comparison
- **WHEN** a table repeats a row for a key or error it already documents
- **THEN** the drift-guard test fails, rather than the duplicate collapsing into an equal set

#### Scenario: The published error set cannot silently narrow
- **WHEN** the error mapping gains a response it can render that its published rows omit
- **THEN** a test fails, so the drift guard cannot be satisfied by an incomplete set

#### Scenario: Signing example stays valid
- **WHEN** the worked signing example no longer equals what the signer produces
- **THEN** the test fails, so an agent validating its own HMAC against it cannot be misled

### Requirement: Documented configuration cannot drift from the implementation
The test suite SHALL fail when the set of `AP_`-prefixed environment variables documented in the llms content differs from the set `AudioProxy.Config` reads, in either direction, and the failure SHALL name the variables that differ. The README's configuration table SHALL be held to the same comparison, being the same list written twice.

The configuration surface SHALL be published by `AudioProxy.Config` as data, so the check runs against the module's own list rather than a copy of it.

Variable *names* are compared, not their default values: several defaults are derived rather than literal, and the two documents render those differently for different readers.

#### Scenario: Variable added without documentation
- **WHEN** `AudioProxy.Config` reads an `AP_`-prefixed variable that the configuration table in `llms-full.txt` does not list
- **THEN** the drift-guard test fails naming the missing variable

#### Scenario: Stale documentation
- **WHEN** the configuration table lists an `AP_`-prefixed variable that `AudioProxy.Config` does not read
- **THEN** the drift-guard test fails naming the stale variable

#### Scenario: The published list cannot itself go stale
- **WHEN** a variable is read by `AudioProxy.Config` but absent from the list it publishes
- **THEN** a test fails, so the seam cannot silently narrow what the guard checks

#### Scenario: A read that moves out of the recognised shape cannot be trimmed away
- **WHEN** a variable's read moves to a form the call-site scan does not recognise — a module attribute, a helper whose first argument is named differently — and the variable is then removed from the published list to make that failure go away
- **THEN** a test still fails, because the variable's name remains written in the module as a string literal, and the failure names the variable rather than accepting the narrower list
