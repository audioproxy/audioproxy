## ADDED Requirements

### Requirement: A moving tag never moves backwards
A moving tag (`:edge`, `:latest`, `:X.Y`) SHALL NOT be moved from the image of a
newer commit to the image of an older one. Publishing SHALL compare the commit
behind the tag's current image against the commit being published, and SHALL
leave the tag untouched when the current image is the newer of the two.

Skipping a tag on those grounds is a successful outcome and SHALL be logged as
such, not reported as a failure: a newer image already holding the tag is the
intended end state.

#### Scenario: An older pipeline publishes last
- **WHEN** two pipelines are in flight and the one built from the older commit
  reaches publishing second
- **THEN** it publishes its immutable `:sha-<12>` tag, leaves the moving tags on
  the newer commit's image, and reports success

#### Scenario: The ordinary case is unaffected
- **WHEN** the commit being published is newer than the one behind the tag, or
  the tag does not yet exist
- **THEN** every tag moves as it does today

#### Scenario: The comparison cannot be made
- **WHEN** the image currently behind a moving tag carries no readable commit
  ordering
- **THEN** publishing fails rather than guessing, naming the tag and the image it
  could not place
