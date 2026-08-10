## ADDED Requirements

### Requirement: Operator docs contain no code internals
The operator-facing documents (`docs/sources.md`, `docs/rendering.md`, `docs/scaling.md`, `docs/capacity.md`, `docs/s3-providers.md`) SHALL NOT reference Elixir modules, functions, or module attributes; contributor material relocates to `docs/development.md`. A test SHALL enforce the module-reference absence.

#### Scenario: The guard catches a leak
- **WHEN** an operator doc gains a string matching `AudioProxy.` (or backticked module/attribute forms)
- **THEN** the guard test fails naming the file and line

#### Scenario: Contributor material survives relocation
- **WHEN** the source-type contract section moves to `development.md`
- **THEN** its content is intact there and `sources.md` links to it for readers who turn out to be contributors

### Requirement: Examples lead with the goal
Every example in operator docs SHALL open by naming what the reader is trying to achieve, then show the URL or configuration, then explain each option used — assuming no prior ffmpeg knowledge.

#### Scenario: A reader who has never used ffmpeg
- **WHEN** they read any example in the operator docs
- **THEN** they learn what outcome it produces before they see an option string, and every option in it is explained where it first appears
