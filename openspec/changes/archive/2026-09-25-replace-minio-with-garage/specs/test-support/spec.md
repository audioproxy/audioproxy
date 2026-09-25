## ADDED Requirements

### Requirement: Store credentials have one home
The access key and secret the store-backed suite authenticates with SHALL be defined once in the support layer and referenced by every test that talks to the store. A test that needs a second, distinct identity to tell requests apart MAY define that one itself.

#### Scenario: A test configures the store
- **WHEN** a store-backed test builds its S3 configuration
- **THEN** it takes the key and secret from the support layer and writes no literal of its own

#### Scenario: The material is not mistaken for a secret
- **WHEN** a reader or a scanner encounters the credentials
- **THEN** the definition states that they are fixed test values for a throwaway store, never loaded by `lib/`
