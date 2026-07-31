## ADDED Requirements

### Requirement: Local source form
The source grammar SHALL additionally accept `local://{path}` in both `plain/` and `enc/` encodings, yielding a typed local source whose canonical identity is `local://` plus the decoded, root-relative path.

#### Scenario: Local form parses
- **WHEN** parsing `plain/local://previews/track.wav`
- **THEN** the result is a local source with relative path `previews/track.wav`

#### Scenario: Encoding equivalence holds for local
- **WHEN** the same local source arrives via `plain` and `enc` forms
- **THEN** both yield the same typed source and byte-identical canonical strings

#### Scenario: Cache identity is root-independent
- **WHEN** the same relative path is served under different `AP_LOCAL_ROOT` values
- **THEN** the canonical source string (and thus the cache key) is unchanged — the root is deployment config, not source identity
