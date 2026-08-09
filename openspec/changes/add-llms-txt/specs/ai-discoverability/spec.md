## ADDED Requirements

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
