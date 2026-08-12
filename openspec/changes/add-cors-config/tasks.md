# Tasks

## 1. Config

- [x] 1.1 `AudioProxy.Config`: `AP_ALLOW_ORIGIN` — `*` or a `scheme://host[:port]` origin, validated at boot (abort naming the var on anything else), unset by default

## 2. Headers

- [x] 2.1 Response header injection on the main listener: `Access-Control-Allow-Origin`, `Vary: Origin` (non-`*` only), `Access-Control-Expose-Headers: x-audio-proxy, retry-after, accept-ranges, etag` — on every response, success and error, in one place the whole plug chain shares
- [x] 2.2 `OPTIONS` route when enabled: 204, `Access-Control-Allow-Methods: GET, HEAD`, echoed `Access-Control-Allow-Headers`, `Access-Control-Max-Age: 86400`; unchanged 404 when disabled

## 3. Tests

- [x] 3.1 Default-off pinning: unset var → no `Access-Control-*` header on 200/302/404/429, `OPTIONS` → 404
- [x] 3.2 Enabled: headers present on 200, 302 (HIT redirect), 4xx, 5xx; `Vary: Origin` only for a non-`*` value
- [x] 3.3 Expose-headers list covers `retry-after` on the queue-full 429 and `x-audio-proxy` on renders
- [x] 3.4 Preflight 204 shape; boot abort on malformed origin

## 4. Docs

- [x] 4.1 README configuration table row; API doc §2 non-GET rule gains the preflight carve-out sentence, §6 the variable
- [x] 4.2 `llms-full.txt` config table
- [x] 4.3 Docs site sources/rendering guides note the variable for browser consumers (drift notifier will flag)
