## ADDED Requirements

### Requirement: The video verdict is a policy with a rejecting default
The gate SHALL obtain its verdict for video-containing sources from a configured policy module; the default policy SHALL reject exactly as specified today, and OSS configuration SHALL offer no way to select another — the seam is for embedding releases.

#### Scenario: Default is byte-identical
- **WHEN** no embedding release configures a policy
- **THEN** every response (status, body, headers) is identical to the pre-seam behavior, pinned by the existing gate suite running unchanged

#### Scenario: Extraction verdict never touches egress
- **WHEN** a policy answers `:extract` for a video-containing source
- **THEN** the render proceeds with `-vn -sn -dn` in argv and no video encoder reachable — the audio-only *output* guarantee holds regardless of policy
