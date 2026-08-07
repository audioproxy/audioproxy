## ADDED Requirements

### Requirement: Listener boot has one home
Tests that bind a real socket SHALL start it through the shared support helper rather than constructing the Bandit child spec and reading the port back themselves.

#### Scenario: A test needs a real listener
- **WHEN** a test must speak HTTP over a socket rather than through `Plug.Test`
- **THEN** it starts the listener through the shared helper, naming only the plug it wants mounted

#### Scenario: A dependency changes its shape
- **WHEN** Bandit or Thousand Island changes how a bound port is reported
- **THEN** exactly one file fails to match, and its moduledoc says that is what happened

### Requirement: Listeners bind an ephemeral loopback port
The shared helper SHALL bind port zero on loopback and read the assigned port back, rather than choosing a port in advance.

#### Scenario: Parallel runs do not collide
- **WHEN** two test runs bind listeners at the same time, in separate worktrees or in CI
- **THEN** neither can take a port the other wanted, because neither chose one

#### Scenario: The bind address is checked
- **WHEN** the helper reads the listener's address back
- **THEN** a listener that did not bind loopback fails the match rather than being accepted

### Requirement: The mounted plug stays visible
Extraction SHALL NOT default or hide which plug a test mounts.

#### Scenario: A stand-in router is under test
- **WHEN** a test boots the ffmpeg stand-in router rather than the production one
- **THEN** that choice is named at the call site, not inherited from the helper
