## ADDED Requirements

### Requirement: The README routes rather than duplicates
`README.md` SHALL hold only material that is native to the repository: what the
proxy is, its current status and roadmap, the design sketch, the stack, the
license and image-compliance posture, a quick start short enough to try in one
paste, the pointer to the AI-agent files, and a table routing readers to every
other document.

It SHALL NOT hold usage reference material — the processing-option table, the
validation rules, the configuration surface, the error table, the signing
procedure, response and caching semantics, or operational guidance. Each of
those has a home elsewhere, and a second copy in the README is a copy that has
to be kept in step by hand.

The README SHALL link to the documentation site, so a reader arriving at the
repository can find it.

#### Scenario: A usage section is added to the README
- **WHEN** a change adds a section to `README.md` explaining how to construct,
  configure, or operate something, rather than linking to where that is explained
- **THEN** the change is rejected in review, and the material is directed to the
  documentation site or to `docs/`

#### Scenario: The routing table stays complete
- **WHEN** a document is added under `docs/`, or a page is added to the
  documentation site that has no counterpart there
- **THEN** the README's documentation table gains a row naming it and what it
  covers

#### Scenario: The site is discoverable from the repository
- **WHEN** a reader opens `README.md`
- **THEN** the documentation site's URL appears in it

### Requirement: The published contract keeps a repository-local home
`llms.txt`, `llms-full.txt` and `docs/audio-proxy-api-v1.md` SHALL remain in the
repository and SHALL remain the source of truth for the URL contract, whatever
the documentation site carries.

The site's copy of the contract is synced from this repository rather than
authored there, so the repository is where a contract change is made.

#### Scenario: Contract change made at the source
- **WHEN** the URL grammar, an option, an error code, or the signing rule changes
- **THEN** `docs/audio-proxy-api-v1.md` and `llms-full.txt` are updated in the
  same change, and the site receives it by sync rather than by a separate edit

#### Scenario: A reader with only the repository
- **WHEN** the documentation site is unreachable
- **THEN** the full URL contract is still readable from the repository alone

### Requirement: Each kind of documentation has one destination
Documentation SHALL be placed by what it is, and a slice that changes behavior
SHALL update the destination its change affects:

| Destination | Holds |
|---|---|
| `README.md` | What the project is, its status, and where everything else lives |
| `docs.audioproxy.dev` | Goal-first usage and operations: how to render, configure, sign, deploy, and observe |
| `docs/audio-proxy-api-v1.md` | The contract: URL grammar, options, cache-key rules, headers, error codes |
| `docs/` (guides) | The authored-from upstream for the site's guide pages |
| `docs/development.md`, `docs/ffmpeg-arguments.md` | Working on the repository, and how options become ffmpeg arguments |
| `llms.txt`, `llms-full.txt` | The contract as one self-contained file, machine-checked |

#### Scenario: A behavior change lands
- **WHEN** a change alters an option, an error code, an endpoint, a configuration
  variable, or the signing rule
- **THEN** it updates `docs/audio-proxy-api-v1.md` and `llms-full.txt` in the same
  change, and the documentation site's affected page is updated or a drift issue
  is raised against it

#### Scenario: Placement is decided by kind, not by convenience
- **WHEN** new documentation is written
- **THEN** it goes to the destination its kind names in the table above, rather
  than to whichever document the author is already editing
