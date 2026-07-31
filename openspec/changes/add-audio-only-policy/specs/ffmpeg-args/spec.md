## ADDED Requirements

### Requirement: Non-audio streams are disabled in every argv
The command builder SHALL include `-vn`, `-sn`, and `-dn` in every render argument vector (audio and peaks modes alike), regardless of options, so no video, subtitle, or data stream can ever be decoded, filtered, or encoded.

#### Scenario: Flags present for every format
- **WHEN** argv is built for each supported output format and for PCM/peaks extraction
- **THEN** `-vn`, `-sn`, and `-dn` are present in each

### Requirement: Input protocol whitelist in every argv
The command builder SHALL include `-protocol_whitelist` before the input in every argument vector, with the minimal set for the resolved source type: `file` for local sources; `https,tls,tcp` for HTTPS sources (plus `http` only when a plaintext dev endpoint is configured).

#### Scenario: Whitelist precedes input
- **WHEN** any argv is built
- **THEN** `-protocol_whitelist` appears as an input option (before `-i`) with the source type's set

#### Scenario: Local sources cannot reach the network
- **WHEN** argv is built for a local source
- **THEN** the whitelist is exactly `file` — no network protocol is available to the invocation

#### Scenario: Remote sources cannot reach the filesystem
- **WHEN** argv is built for an HTTPS source
- **THEN** the whitelist contains no `file` entry

### Requirement: Flag allowlist is introspectable
The command builder SHALL expose the complete set of flags it can ever emit, so the argv-allowlist property test compares against a published set rather than a hardcoded copy.

#### Scenario: Allowlist covers reality
- **WHEN** argv is built for randomly generated valid options (property test)
- **THEN** every `-`-prefixed token is in `Command.allowed_flags/0`
