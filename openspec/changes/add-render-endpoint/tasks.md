## 1. Plug chain & error surface

- [ ] 1.1 `ParseOptions` + `ResolveSource` plugs bridging existing modules into `conn.assigns`; halt-with-error on failure
- [ ] 1.2 `ErrorJSON`: structured-error → {status, body} table for 401/404/413/415/422/429/504; unit tests per mapping incl. `Retry-After` on 429
- [ ] 1.3 Route `GET /:sig/*rest` in router (options/source split), keeping `/health` unsigned
- [ ] 1.4 Router-level test: every signed route 401s without a valid signature (guards against mounting `VerifySignature` after `:dispatch` or omitting it on a new route)

## 2. Render action

- [ ] 2.1 Source stat via `Source.stat/1`: not-found → 404, size > `AP_MAX_SRC_BYTES` → 413; `Source.ffmpeg_input/1` for the render input (local path for MVP; presigned URL once the S3 backend exists)
- [ ] 2.2 Subscribe to coordinator; send response headers (Content-Type, Cache-Control, ETag, X-Audio-Proxy, optional Content-Disposition); chunked streaming receive-loop
- [ ] 2.3 Disconnect handling: `chunk/2` error → unsubscribe/exit; receive-deadline → 504 pre-stream, abnormal close mid-stream

## 3. Tests

- [ ] 3.1 Plug.Test: header assertions, dl attachment, each error status via stubbed collaborators
- [ ] 3.2 Full-stack (`@tag :ffmpeg`): fixture WAV from a local fixture dir (`AP_LOCAL_ROOT`) → decodable mp3/opus; first-chunk-before-completion timing; coalesced second client byte-equality + header
- [ ] 3.3 Disconnect (`:gen_tcp`): sole client closes mid-stream → ffmpeg pid dead, slot free (probe semaphore)
- [ ] 3.4 Error end-to-end: bad signature, missing file, oversized file, text-file source (415), saturated queue (429), `fake_cmd` hang (504)

## 4. Docs

- [ ] 4.1 Update README: endpoint usage walkthrough (sign → curl → stream, local source), error table
