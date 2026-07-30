## ADDED Requirements

### Requirement: llms.txt endpoints
The system SHALL serve `GET /llms.txt` and `GET /llms-full.txt` unsigned, as `text/markdown; charset=utf-8`, with long-lived `Cache-Control`, from content embedded in the release.

#### Scenario: Fetchable without signature
- **WHEN** a client requests `/llms.txt` with no signature
- **THEN** the response is 200 markdown with cache headers

#### Scenario: Full variant served
- **WHEN** a client requests `/llms-full.txt`
- **THEN** the response contains the complete API reference in one document

### Requirement: llms.txt conforms to the format
The `/llms.txt` document SHALL follow the llms.txt convention: exactly one H1 title, a blockquote summary immediately after it, and H2-sectioned link lists; `/llms-full.txt` SHALL carry the same lead plus embedded reference content.

#### Scenario: Structural lint
- **WHEN** the test suite parses `/llms.txt`
- **THEN** it finds one H1, a leading blockquote, and only well-formed `- [name](url): description` entries under H2 sections

### Requirement: Documentation cannot drift from the implementation
The test suite SHALL fail when llms content disagrees with the implementation: the set of documented processing-option keys MUST equal the options parser's known keys, and the set of documented error status codes MUST equal the error mapping table's codes.

#### Scenario: Option added without documentation
- **WHEN** a new option key exists in the parser but not in llms-full.txt
- **THEN** the drift-guard test fails naming the missing key

#### Scenario: Stale documentation
- **WHEN** llms-full.txt documents an option key the parser does not know
- **THEN** the drift-guard test fails naming the stale key

#### Scenario: Error table parity
- **WHEN** the error codes documented in llms-full.txt differ from the ErrorJSON mapping
- **THEN** the drift-guard test fails
