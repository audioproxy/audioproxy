## ADDED Requirements

### Requirement: HEAD carries the headers a GET would
For a request that a `GET` would answer from the variant store, a `HEAD` SHALL carry the same response headers as that `GET`, body excluded, including `x-audio-proxy`, `content-length`, `accept-ranges`, `etag`, `cache-control` and `content-type`; in redirect serve mode it SHALL mirror the redirect a `GET` would produce, `location` and its `no-store` included.

#### Scenario: Hit parity
- **WHEN** a variant is cached and both a `GET` and a `HEAD` are issued for it
- **THEN** the `HEAD` response's header set equals the `GET` response's header set, and its `x-audio-proxy` reads `HIT`

#### Scenario: Size without downloading
- **WHEN** a client issues a `HEAD` for a cached variant
- **THEN** `content-length` reports the stored object's size and `accept-ranges` reports `bytes`

### Requirement: HEAD on a miss reports only what is known without rendering
For a request whose variant is not cached, a `HEAD` SHALL answer with `x-audio-proxy: MISS`, the `content-type` implied by the options, and the response's `cache-control`, and SHALL omit `content-length` and `accept-ranges`, whose values exist only once the render has run.

#### Scenario: Miss is answerable and cheap
- **WHEN** a `HEAD` names an uncached variant
- **THEN** the response reports `MISS` without `content-length` or `accept-ranges`

### Requirement: HEAD never renders
A `HEAD` SHALL NOT start a render, occupy a render slot, or write to the variant store, so that repeated probing stays cheap regardless of volume.

#### Scenario: Probing does not warm
- **WHEN** a `HEAD` is issued for an uncached variant and a `GET` for the same URL follows
- **THEN** no render ran for the `HEAD`, the variant store held nothing in between, and the `GET` reports `MISS`

#### Scenario: Gates still apply
- **WHEN** a `HEAD` carries an invalid signature, an expired `exp`, or a source outside the allowlist
- **THEN** it is refused exactly as the equivalent `GET` would be, revealing nothing about whether the variant exists
