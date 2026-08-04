## ADDED Requirements

### Requirement: Nodes form a cluster automatically
Cluster members SHALL discover and connect to each other via the configured strategy (Fly private-network DNS, K8s headless-service DNS, or a static list), with membership tracked as machines start and stop; a node that cannot cluster SHALL run correctly alone.

#### Scenario: Autoscaled machine joins
- **WHEN** a new machine starts on Fly and resolves `<app>.internal`
- **THEN** it joins the cluster within the poll interval and participates in ownership

#### Scenario: Clusterless degradation
- **WHEN** discovery fails entirely
- **THEN** the node serves exactly as a single-node deployment, with a logged warning

### Requirement: Cluster-wide single-flight
For a cache MISS, all members SHALL agree on one render owner per cache key (rendezvous hashing over the member list); non-owners SHALL route the render to the owner — via `Fly-Replay` on Fly, request forwarding elsewhere — so one storm renders once per cluster.

#### Scenario: Storm across nodes
- **WHEN** the same uncached variant hits every node simultaneously
- **THEN** one subprocess runs cluster-wide and all clients receive the bytes

#### Scenario: Membership change mid-flight
- **WHEN** the owner leaves during a render
- **THEN** subsequent requests elect the new owner; an orphaned duplicate render is permitted (bounded, harmless)

### Requirement: Load-aware shedding
A node whose queue is saturated SHALL, when a less-loaded peer exists per gossip, redirect the request to that peer rather than answering 429; 429 remains the answer when the whole cluster is saturated.

#### Scenario: One hot node
- **WHEN** a node hits its queue threshold while a peer sits idle
- **THEN** the request is redirected to the idle peer and succeeds

#### Scenario: Cluster-wide saturation
- **WHEN** gossip shows every peer at capacity
- **THEN** the node answers 429 with `Retry-After`, exactly as single-node

### Requirement: Cluster signals are advisory
Ownership, membership, and load data SHALL never gate correctness: any staleness or partition degrades behavior to single-node semantics, never to an error a single node would not produce.

#### Scenario: Partition
- **WHEN** the cluster splits
- **THEN** each side serves correctly (duplicate renders possible, results identical), and no request fails because of the split
