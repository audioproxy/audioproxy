Lands as **two stacked PRs** per the review-size convention: PR 1 the source
forms and the allowlist, PR 2 the HTTPS storage backend.

## PR 1 — source forms & allowlist

- [ ] 1.1 `AudioProxy.Source.S3`: `Source.Type` behaviour — scheme/tag, `parse/1` of `{bucket}/{key}` (missing half → structured error), `canonical/1`
- [ ] 1.2 `AudioProxy.Source.Https`: `parse/1` via `URI.new/1`; refuse `http://`, userinfo, hostless URLs
- [ ] 1.2a Bound the input before parsing it, as `add-local-files-source` does (64 components / 1024 bytes): its adversarial review found `Path.safe_relative/2` to be superlinear in component count — 1000 segments cost 2.76 s of scheduler time on one process. Check the cost curve of `URI.new/1` and the S3 key split on adversarial input rather than assuming it is linear, and cap accordingly
- [ ] 1.3 HTTPS canonicalization: downcase scheme+host, strip trailing root dot, `:inet.parse_strict_address/1` for IP literals, drop default port, absent path → `/`, drop empty query and fragment; preserve the URL's own escaping and dot segments
- [ ] 1.4 Register both types in the resolver's dispatch table
- [ ] 1.5 Allowlist pattern matcher: bucket = exact or trailing-`*` prefix glob (case-sensitive); host = exact or leading-`*.` label-anchored suffix glob (case-folded); bare `*` matches all; `*` anywhere else matches nothing
- [ ] 1.6 `authorize/1` per type: subject re-derived from the source (never raises), unset-allowlist policy (S3 yes, HTTPS no) → `:ok | {:error, :not_allowed}`
- [ ] 1.7 Both types' `stat/1`/`ffmpeg_input/1` return a "no backend" error — pinned by a test, so the gap is visible rather than a crash (HTTPS backend lands in PR 2; S3 backend in `add-s3-client`)
- [ ] 1.8 Unit: every parsing/allowlist spec scenario — both forms, both encodings, escaping, malformed inputs, allowlist hit/miss/wildcard/unset, the refused schemes
- [ ] 1.9 Regression suite for the five adversarial-review findings: Unicode controls in a URL, host prefix glob, `authorize` on a hand-built tuple, trailing root dot / IP-literal spelling / empty query, inet_aton shorthand not folded
- [ ] 1.10 Property: every spelling of one HTTPS URL converges on one canonical string (mixed case, `:443`, trailing dot, empty path/query, long-form IPv6)
- [ ] 1.11 Property: leading-`*.` host entry admits exactly the domain and its subdomains — in particular not `{domain}.{attacker}`
- [ ] 1.12 Property: bucket keys carrying reserved characters and a literal `%` round-trip through both encodings
- [ ] 1.13 Docs: `docs/sources.md` — the two remote forms, HTTPS normalization and what is deliberately not normalized, the allowlist grammar and its default policy; README *Sources* + `AP_SOURCE_ALLOWLIST` in the configuration table

## PR 2 — HTTPS storage backend

- [ ] 2.1 HTTPS `stat/1`: HEAD → size + ETag material; absent `Content-Length` → known-to-exist with unknown size; failure/4xx/5xx → `:not_found`
- [ ] 2.2 HTTPS `ffmpeg_input/1`: the canonical URL (replaces PR 1's "no backend" stub for HTTPS; the S3 stub stays until `add-s3-client`)
- [ ] 2.3 `stat/1` against a stub origin: size present, size absent, 404, connection failure
- [ ] 2.4 Docs: `docs/sources.md` HTTPS fetch semantics (HEAD behavior, unknown-size policy)
