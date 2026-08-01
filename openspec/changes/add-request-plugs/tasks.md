## 1. Plugs & routing

- [x] 1.1 `ParseOptions` + `ResolveSource` plugs bridging existing modules into `conn.assigns`; halt-with-error on failure
- [x] 1.2 Route `GET /:sig/*rest` in router (options/source split), keeping `/health` unsigned
- [x] 1.3 Action skeleton: `Source.authorize/1` + `Source.stat/1` (404/413), then 501 JSON placeholder

## 2. Error surface

- [x] 2.1 `ErrorJSON`: structured-error → {status, body} table for 401/404/413/415/422/429/504; unit tests per row incl. `Retry-After` on 429 (415/504 producers: `add-render-endpoint`; 429: `add-render-semaphore`)
- [x] 2.2 Uniform-404 check: unauthorized and missing sources produce byte-identical bodies

## 3. Tests (all Plug.Test)

- [x] 3.1 Router-level: every signed route 401s without a valid signature; `/health` open
- [x] 3.2 End-to-end statuses: bad sig 401, unknown option 422, disallowed source 404, missing file 404, oversized file 413
- [x] 3.3 Pinned 501 for a fully valid request

## 4. Docs

- [x] 4.1 Update README: error table; note the render action follows in the next slice
