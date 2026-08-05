## ADDED Requirements

### Requirement: The published model bounds `B_backlog` by the retention ceiling
The capacity model SHALL express the per-render backlog term as `min(variant size, AP_MAX_VARIANT_BYTES)`, and the decision matrix SHALL decide which workloads read **refused** from that ceiling rather than from the source ceiling — the retention bound being the one that actually governs whether a render survives.

The documentation SHALL state that raising the retention ceiling does not buy capacity: it is a per-render bound, so raising it licenses every concurrent slot to reach the larger figure, converting one killed render into an exhausted container. The lever that bounds the total remains `AP_MAX_CONCURRENCY`.

#### Scenario: A refused cell follows the retention ceiling
- **WHEN** `AP_MAX_VARIANT_BYTES` is set below a workload's variant size
- **THEN** the matrix marks that workload refused, whatever the source ceiling admits

#### Scenario: The document says which lever bounds the total
- **WHEN** the documentation is consulted about raising the retention ceiling to serve a longer output
- **THEN** it states that the total is `C × B_backlog` and that raising a per-render bound without lowering concurrency moves the failure from one request to the whole container
