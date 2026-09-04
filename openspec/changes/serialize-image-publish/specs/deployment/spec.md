## ADDED Requirements

### Requirement: Publishing is serialized per ref
Publishing SHALL be serialized per ref, such that two pipelines in flight at
once cannot interleave their writes to the moving tags (`:edge`, `:latest`,
`:X.Y`), and a moving tag SHALL always name a manifest list stitched by a
single run.

This is an interleaving guarantee, not an ordering one: the queue is entered on
arrival at the publishing job, so a run whose build was slower MAY publish after
a newer one. Making a moving tag monotonic in commit order is out of scope.

#### Scenario: Two pushes in quick succession
- **WHEN** two commits are pushed to `main` close enough together that both
  pipelines are in flight
- **THEN** their publish jobs run one after the other, and neither observes a
  tag set the other left half-written

#### Scenario: A publish in progress is not cancelled
- **WHEN** a new push arrives while an earlier publish is stitching manifests
- **THEN** the in-flight publish runs to completion rather than being cancelled
  part-way through

#### Scenario: A queued pipeline is not evicted by an earlier one
- **WHEN** a run is queued behind an earlier run's publish
- **THEN** it is not cancelled before it publishes, and the moving tag ends on
  its commit

### Requirement: Only the publishing job is serialized
Exactly one job SHALL declare the publishing concurrency group, and it SHALL be
the job that writes the tags. The platform permits one pending job per group and
evicts the previously pending one when another is queued, so a second member
lets one pipeline contend with itself and evict a newer pipeline's queued work.

#### Scenario: A second job is proposed for the group
- **WHEN** a change would add the group to any job other than the publishing job
- **THEN** it is rejected in review as a regression rather than accepted as a
  tightening, on the reasoning recorded beside the group and in the development
  documentation
