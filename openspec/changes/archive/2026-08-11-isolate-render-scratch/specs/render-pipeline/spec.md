## ADDED Requirements

### Requirement: Render scratch is isolated per instance
Two instances running on one host SHALL NOT share the directory their renders' stderr files are written to, whether or not either is a distributed node.

#### Scenario: Two undistributed VMs on one host
- **WHEN** two instances start on the same host, neither given a node name, and both resolve the scratch directory
- **THEN** the two directories differ

#### Scenario: A failure is classified while another instance boots
- **WHEN** an instance boots and performs its scratch sweep while a render in another instance is running
- **THEN** that render's stderr file still exists when its failure is classified, so the failure keeps its class rather than degrading to the unclassified one

### Requirement: The boot sweep reclaims only orphans
The boot sweep SHALL remove scratch belonging to instances that are no longer running, and SHALL NOT remove scratch belonging to a running instance.

#### Scenario: An instance was killed without cleanup
- **WHEN** an instance dies to `kill -9`, an OOM kill or a container crash, leaving stderr files behind, and a later instance boots
- **THEN** the dead instance's files are removed

#### Scenario: Ownership cannot be established
- **WHEN** the sweep cannot determine that the owner of some scratch is gone
- **THEN** it leaves that scratch alone, preferring to reclaim it at a later boot over deleting a file that may be in use
