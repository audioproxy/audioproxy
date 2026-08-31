## ADDED Requirements

### Requirement: A moving tag names the newest completed publish
Publishing SHALL be serialized per ref, such that a moving tag (`:edge`, `:latest`, `:X.Y`) resolves to the most recent commit whose publish completed, rather than to whichever concurrently running pipeline finished last.

#### Scenario: Two pushes in quick succession
- **WHEN** two commits are pushed to `main` close enough together that both pipelines are in flight
- **THEN** their publish jobs run one after the other, and `:edge` ends on the later commit

#### Scenario: A publish in progress is not cancelled
- **WHEN** a new push arrives while an earlier publish is stitching manifests
- **THEN** the in-flight publish runs to completion rather than being cancelled part-way through
