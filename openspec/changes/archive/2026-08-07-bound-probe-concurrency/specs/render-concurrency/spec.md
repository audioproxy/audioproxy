## ADDED Requirements

### Requirement: Concurrent probes have a ceiling
The system SHALL bound the number of concurrently running source probes, independently of the render slot cap. The bound SHALL NOT be the render semaphore: a probe must never wait behind an encoder, since the endpoint a client calls before it knows what to request would otherwise be the slowest path in the proxy.

Overflow SHALL answer 429 with `Retry-After`, through the same error the render queue produces when it is full.

*This requirement is conditional on the measurements in this change's task 1.3. If sharing one probe per cache key removes the pathological case, the decision to ship no bound SHALL be recorded in `design.md` and this requirement dropped rather than implemented as a formality.*

#### Scenario: The probe ceiling holds under load
- **WHEN** 3× the probe bound's worth of concurrent requests for distinct sources arrive
- **THEN** at no instant do more than the bound have a probe running, and every request either probes or is shed with 429

#### Scenario: A probe never queues behind a render
- **WHEN** every render slot is held and the render queue is full
- **THEN** a probe still runs, bounded only by its own ceiling

#### Scenario: A cache hit needs neither
- **WHEN** the probe bound is exhausted and a request's variant is already in the variant store
- **THEN** it is served from the store without probing and without being shed
