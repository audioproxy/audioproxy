## ADDED Requirements

### Requirement: Non-audio streams are disabled in every argv
The command builder SHALL include `-vn`, `-sn`, and `-dn` in every render argument vector (audio and peaks modes alike), regardless of options, so no video, subtitle, or data stream can ever be decoded, filtered, or encoded.

#### Scenario: Flags present for every format
- **WHEN** argv is built for each supported output format and for PCM/peaks extraction
- **THEN** `-vn`, `-sn`, and `-dn` are present in each

### Requirement: Input protocol whitelist in every argv
The command builder SHALL include `-protocol_whitelist` with the configured audio-input protocol set (default `https,tls,tcp`) before the input in every argument vector.

#### Scenario: Whitelist precedes input
- **WHEN** any argv is built
- **THEN** `-protocol_whitelist` appears as an input option (before `-i`) with the configured set

### Requirement: Flag allowlist is introspectable
The command builder SHALL expose the complete set of flags it can ever emit, so the argv-allowlist property test compares against a published set rather than a hardcoded copy.

#### Scenario: Allowlist covers reality
- **WHEN** argv is built for randomly generated valid options (property test)
- **THEN** every `-`-prefixed token is in `Command.allowed_flags/0`
