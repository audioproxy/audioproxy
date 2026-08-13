## ADDED Requirements

### Requirement: Two S3 configuration profiles
The system SHALL assemble two S3 client profiles — source-side (the shared `AWS_*`/`AP_S3_*` group) and store-side (`AP_VARIANT_S3_*` overrides) — where every unset store-side value falls back to the source-side value, and a store-side credential triple SHALL be all-or-nothing: setting a strict subset aborts boot naming the missing variables.

#### Scenario: No overrides is one profile
- **WHEN** no `AP_VARIANT_S3_*` variable is set
- **THEN** both profiles are identical and observable behavior is byte-identical to the pre-split proxy

#### Scenario: Cross-provider profiles
- **WHEN** `AP_VARIANT_S3_ENDPOINT` and the variant credential triple point at a different provider
- **THEN** source fetches use the shared profile while store operations (HEAD, multipart, presign) use the variant profile

#### Scenario: Partial credentials refused
- **WHEN** `AP_VARIANT_S3_ACCESS_KEY_ID` is set without its secret
- **THEN** boot aborts naming the incomplete group

#### Scenario: Addressing derives per side
- **WHEN** the variant endpoint is custom and `AP_VARIANT_S3_ADDRESSING` is unset
- **THEN** store requests use path-style, regardless of what the source side derived
