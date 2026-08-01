## 1. Source forms

- [ ] 1.1 `AudioProxy.Source.S3`: `Source.Type` behaviour — scheme/tag, `parse/1` of `{bucket}/{key}` (missing half → structured error), `canonical/1`
- [ ] 1.2 `AudioProxy.Source.Https`: `parse/1` via `URI.new/1`; refuse `http://`, userinfo, hostless URLs
- [ ] 1.3 HTTPS canonicalization: downcase scheme+host, strip trailing root dot, `:inet.parse_strict_address/1` for IP literals, drop default port, absent path → `/`, drop empty query and fragment; preserve the URL's own escaping and dot segments
- [ ] 1.4 Register both types in the resolver's dispatch table

## 2. Allowlist

- [ ] 2.1 Pattern matcher: bucket = exact or trailing-`*` prefix glob (case-sensitive); host = exact or leading-`*.` label-anchored suffix glob (case-folded); bare `*` matches all; `*` anywhere else matches nothing
- [ ] 2.2 `authorize/1` per type: subject re-derived from the source (never raises), unset-allowlist policy (S3 yes, HTTPS no) → `:ok | {:error, :not_allowed}`

## 3. Storage seam

- [ ] 3.1 HTTPS `stat/1`: HEAD → size + ETag material; absent `Content-Length` → known-to-exist with unknown size; failure/4xx/5xx → `:not_found`
- [ ] 3.2 HTTPS `ffmpeg_input/1`: the canonical URL
- [ ] 3.3 S3 `stat/1`/`ffmpeg_input/1` return a "no backend" error until `add-s3-client` lands — pinned by a test, so the gap is visible rather than a crash

## 4. Tests

- [ ] 4.1 Unit: every spec scenario — both forms, both encodings, escaping, malformed inputs, allowlist hit/miss/wildcard/unset, the refused schemes
- [ ] 4.2 Regression suite for the five adversarial-review findings: Unicode controls in a URL, host prefix glob, `authorize` on a hand-built tuple, trailing root dot / IP-literal spelling / empty query, inet_aton shorthand not folded
- [ ] 4.3 Property: every spelling of one HTTPS URL converges on one canonical string (mixed case, `:443`, trailing dot, empty path/query, long-form IPv6)
- [ ] 4.4 Property: leading-`*.` host entry admits exactly the domain and its subdomains — in particular not `{domain}.{attacker}`
- [ ] 4.5 Property: bucket keys carrying reserved characters and a literal `%` round-trip through both encodings
- [ ] 4.6 `stat/1` against a stub origin: size present, size absent, 404, connection failure

## 5. Docs

- [ ] 5.1 `docs/sources.md`: the two remote forms, HTTPS normalization and what is deliberately not normalized, the allowlist grammar and its default policy
- [ ] 5.2 README *Sources*: the remote forms and the allowlist table; `AP_SOURCE_ALLOWLIST` gains its consumer in the configuration table
