## ADDED Requirements

### Requirement: The byte-limit floor is reachable without signing
The byte limits that defend a test against a boot-time `AP_MAX_SRC_BYTES` SHALL be available to a test file that signs nothing and resolves no local source.

#### Scenario: A test needs the limits but has no key material
- **WHEN** a test file pins the byte limits so an environment variable cannot
  change what it asserts, but neither signs a URL nor reads a local root
- **THEN** it takes those limits from the support layer and writes no literal of
  its own

#### Scenario: The floor's value changes
- **WHEN** the byte-limit floor is revised
- **THEN** one support-layer definition changes, and every file that pins the
  limits follows — including the ones that do not sign

### Requirement: The local-root requirement stays intact
Making the limits reachable SHALL NOT make `local_root` optional for callers that do resolve local sources.

#### Scenario: A signing test still names its root
- **WHEN** a test file resolves `local://` sources
- **THEN** it must still name its own local root, and the helper does not
  default one
