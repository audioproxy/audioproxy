# Tasks

## 1. Headers

- [ ] 1.1 Hit path: emit the same header set as `GET` (verdict, length, ranges, etag, cache-control, content-type); mirror the `302` and its `no-store` in redirect mode
- [ ] 1.2 Miss path: `x-audio-proxy: MISS`, content type from the options, cache-control; deliberately no length or ranges

## 2. Tests

- [ ] 2.1 Hit parity asserted as a set difference between `GET` and `HEAD` headers, so a header added to `GET` later cannot silently skip `HEAD`
- [ ] 2.2 Miss shape
- [ ] 2.3 `HEAD` on a cold variant starts no render: no slot taken, store empty afterwards, and a following `GET` still reports `MISS`
- [ ] 2.4 Signature, expiry and allowlist refusals identical to `GET`

## 3. Docs

- [ ] 3.1 API doc §5: the two `HEAD` shapes, stated as contract
- [ ] 3.2 README line describing `x-audio-proxy` mentions `HEAD` parity
