## ADDED Requirements

### Requirement: A mistyped config override is refused
The config-floor helper SHALL reject an override naming a key the application's
configuration does not define, rather than carrying it into the config where
nothing reads it.

#### Scenario: A test misspells a config key
- **WHEN** a test passes an override such as `probe_timout: 1`
- **THEN** the helper raises, naming the unknown key, at the call site that
  wrote it

#### Scenario: The failure points at the mistake
- **WHEN** an unknown key is rejected
- **THEN** the message suggests the nearest known key, because the failure this
  guards against is a typo rather than a misunderstanding

#### Scenario: A test asserts on a limit it means to set
- **WHEN** a test passes an override the configuration does define
- **THEN** it is merged over the floor unchanged, exactly as before the guard

### Requirement: The known-key set is derived, not restated
The set of acceptable keys SHALL come from the application's own configuration
rather than from a list maintained beside it.

#### Scenario: A new config variable is added
- **WHEN** `AudioProxy.Config` gains a setting
- **THEN** a test may override it without any edit to the support layer
