# test-support Specification

## Purpose
What `test/support/` owns, and what a test file is therefore not allowed to
define for itself.

The suite has repeatedly grown another copy of something that already existed —
a poll loop, a listener boot, a signing preamble — because the next author
needed one and wrote one rather than finding the ones already in the tree. The
poll loop reached seventeen copies, under four names, before anyone counted.
The copies then drift, and the drift hides the one distinction that mattered:
of those seventeen, some flunked on expiry and some returned a boolean, and
which was which was legible only from the file you happened to be reading.

So the rule is about *where a thing lives*, not merely about repetition: when a
helper carries a reason (why a config value is pinned, why a deadline is what it
is), that reason has to live with the helper, because the files that depend on
it will not carry it and a reader tidying one of them will not find it.
## Requirements
### Requirement: Test key material has one home
The suite's signing key and salt SHALL be defined once in the support layer and referenced by every test that signs a URL.

#### Scenario: A test needs to sign a request
- **WHEN** a test builds a signed path
- **THEN** it takes the key and salt from the support layer and defines no literal of its own

#### Scenario: The material is not mistaken for a secret
- **WHEN** a reader or a scanner encounters the key material
- **THEN** the file states that it is a fixed test vector, never loaded by `lib/` and never an operational default

### Requirement: The config floor is stated once, with its reason
The configuration values that exist to make tests independent of the developer's environment SHALL be supplied by one helper, together with the explanation of what they are defending against.

#### Scenario: A limit is set in the environment
- **WHEN** a developer has `AP_MAX_SRC_BYTES` or a similar variable set in their shell
- **THEN** tests that assert on unrelated statuses still pass, because the floor pins the values the chain reads

#### Scenario: Someone tidies the floor
- **WHEN** a reader wonders why the floor pins a limit no test appears to need
- **THEN** the answer is attached to the helper, not to one of the eighteen files that depend on it

### Requirement: Per-file config stays visible
The shared floor SHALL be overridable per test file, and a value a test is about SHALL be visible at that file's call site.

#### Scenario: A file tests a timeout
- **WHEN** a test file needs a short probe or render timeout to make its point
- **THEN** that value appears in that file's setup, merged over the floor rather than hidden inside it

#### Scenario: The local root is per test
- **WHEN** a test file supplies its config
- **THEN** it must name its own local root; the helper does not default one

### Requirement: The signed-path grammar is implemented once in the suite
The construction of a signed path from a request remainder SHALL exist in one place in the test support layer.

#### Scenario: The URL grammar changes
- **WHEN** the signed-path grammar in the API contract changes
- **THEN** one test-support function changes, and every signing test follows

#### Scenario: The suite disagrees with production
- **WHEN** the test helper's construction and the production implementation diverge
- **THEN** tests fail, because the helper is deliberately an independent implementation rather than a call into production code

### Requirement: Polling helpers have one home
Any test that waits for a condition by polling SHALL use the shared support module rather than defining its own loop.

#### Scenario: A poll loop is needed
- **WHEN** a test must wait for a condition that sends no message when it becomes true
- **THEN** it calls the shared helper, and defines no local `wait_until`, `eventually` or equivalent

#### Scenario: The interval is corrected once
- **WHEN** the polling interval or the failure message is changed in the shared helper
- **THEN** every waiting test carries the change, with no stale duplicate left behind

### Requirement: Waiting distinguishes flunking from reporting
The support layer SHALL offer two distinct waits: one that fails the test when its deadline expires, and one that returns whether the condition held.

#### Scenario: The condition is a precondition
- **WHEN** a test waits for something that must become true for the test to mean anything
- **THEN** expiry fails the test, with a message naming the deadline that was exceeded

#### Scenario: The condition is the assertion
- **WHEN** a test waits for something it intends to assert on, including asserting it does *not* happen
- **THEN** the wait returns a boolean and the test asserts on it

### Requirement: Deadlines stay at the call site
Unifying the poll loop SHALL NOT unify the deadlines.

#### Scenario: A test needs a longer budget
- **WHEN** a test's condition is slower than the default budget allows
- **THEN** it passes its own deadline explicitly, visible where the test is read

### Requirement: Fixture paths are unique per run
A generated test fixture SHALL live under a path unique to the run that generated it, and SHALL be removed when that run ends.

#### Scenario: Two worktrees run the ffmpeg suite at once
- **WHEN** two `mix test --only ffmpeg` runs execute concurrently from separate worktrees
- **THEN** neither can read, truncate or delete a fixture belonging to the other, because they share no path

#### Scenario: A run leaves a directory behind
- **WHEN** a run crashes before its cleanup executes
- **THEN** the directory it left is named after the suite that created it

#### Scenario: A fixed path is proposed
- **WHEN** a test needs a generated file
- **THEN** it takes a path from the shared fixture helper, and never names a fixed path under the system temporary directory

### Requirement: Test outputs are separate from fixture inputs
A test that writes a file in order to inspect it SHALL write it outside the fixture root.

#### Scenario: A render is written out to be probed
- **WHEN** a test writes rendered bytes to disk so a prober can read them back
- **THEN** the file lands in that test's own temporary directory, not beside the module's shared inputs

### Requirement: Fixture generation has one home
The ffmpeg invocation that generates audio fixtures SHALL exist in one place.

#### Scenario: The generation arguments change
- **WHEN** the fixture-generation invocation needs a new flag
- **THEN** one helper changes and every generated fixture follows

#### Scenario: A fixture's character stays at the call site
- **WHEN** a fixture's duration, amplitude, rate or codec is what a test is about
- **THEN** that value is named where the fixture is requested, not defaulted inside the helper

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

### Requirement: A wait may hand back what it waited for
The support layer SHALL cover the poll whose result is a value rather than a verdict, so that a test needing one does not write its own loop.

#### Scenario: The value is the point of the wait

- **WHEN** a test polls until something exists — a scrape body that matches, a
  restarted process's pid — and then asserts on that thing
- **THEN** the wait returns it directly, and the test does not re-read it
  afterwards

#### Scenario: Re-reading would reopen the race

- **WHEN** a value can change again between the wait succeeding and a separate
  read of it
- **THEN** the test is not required to perform that separate read, because the
  wait already carries the value it observed

### Requirement: A value wait keeps its diagnostic
Replacing a private value-returning loop SHALL NOT cost the failure message that made it debuggable.

#### Scenario: The condition never holds

- **WHEN** a value wait expires without its condition ever holding
- **THEN** the failure names both the deadline and what the test last observed,
  where the observation is what identifies the fault

