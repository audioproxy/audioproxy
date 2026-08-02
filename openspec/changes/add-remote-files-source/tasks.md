## 1. Source forms

- [x] 1.1 `AudioProxy.Source.S3`: `Source.Type` behaviour — scheme/tag, `parse/1` of `{bucket}/{key}` (missing half → structured error), `canonical/1`
- [x] 1.2 `AudioProxy.Source.Https`: `parse/1` via `URI.new/1`; refuse `http://`, userinfo, hostless URLs
- [x] 1.2a Bound the input before parsing it, as `add-local-files-source` does (64 components / 1024 bytes): its adversarial review found `Path.safe_relative/2` to be superlinear in component count — 1000 segments cost 2.76 s of scheduler time on one process. Check the cost curve of `URI.new/1` and the S3 key split on adversarial input rather than assuming it is linear, and cap accordingly
- [x] 1.3 HTTPS canonicalization: downcase scheme+host, strip trailing root dot, `:inet.parse_strict_address/1` for IP literals, drop default port, absent path → `/`, drop empty query and fragment; preserve the URL's own escaping and dot segments
- [x] 1.4 Register both types in the resolver's dispatch table
- [x] 1.5 Both types' `stat/1`/`ffmpeg_input/1` return a "no backend" error — pinned by a test per form, so the gap is visible rather than a crash (HTTPS backend: `add-https-source-backend`; S3 backend: `add-s3-client`)

## 2. Allowlist

- [x] 2.1 Pattern matcher: bucket = exact or trailing-`*` prefix glob (case-sensitive); host = exact or leading-`*.` label-anchored suffix glob (case-folded); bare `*` matches all; `*` anywhere else matches nothing
- [x] 2.2 `authorize/1` per type: subject re-derived from the source (never raises), unset-allowlist policy (S3 yes, HTTPS no) → `:ok | {:error, :not_allowed}`

## 3. Tests

- [x] 3.1 Unit: every parsing/allowlist spec scenario — both forms, both encodings, escaping, malformed inputs, allowlist hit/miss/wildcard/unset, the refused schemes
- [x] 3.2 Regression suite for the five adversarial-review findings: Unicode controls in a URL, host prefix glob, `authorize` on a hand-built tuple, trailing root dot / IP-literal spelling / empty query, inet_aton shorthand not folded
- [x] 3.3 Property: every spelling of one HTTPS URL converges on one canonical string (mixed case, `:443`, trailing dot, empty path/query, long-form IPv6)
- [x] 3.4 Property: leading-`*.` host entry admits exactly the domain and its subdomains — in particular not `{domain}.{attacker}`
- [x] 3.5 Property: bucket keys carrying reserved characters and a literal `%` round-trip through both encodings

## 4. Docs

- [x] 4.1 `docs/sources.md`: the two remote forms, HTTPS normalization and what is deliberately not normalized, the allowlist grammar and its default policy
- [x] 4.2 README *Sources*: the remote forms and the allowlist table; `AP_SOURCE_ALLOWLIST` gains its consumer in the configuration table
