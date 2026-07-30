## Context

The source is the last path portion; everything before it (signature, options) is consumed by earlier plugs. Two encodings exist because URL-escaping nested URLs is error-prone; both must converge on one canonical identity.

## Goals / Non-Goals

**Goals:**
- Typed sources, one canonical string, allowlist policy in one place.

**Non-Goals:**
- Fetching bytes or presigning (S3 slice); existence checks (resolver is offline/pure).

## Decisions

- **Parse `enc/` first to the plain form, then share one code path** — guarantees the two encodings can't drift semantically.
- **Canonical form = the decoded plain form** (`s3://bucket/key` with raw key bytes, or the normalized HTTP URL) — human-readable in logs, stable for hashing.
- **Allowlist patterns**: exact match or trailing-`*` glob only (no regex — predictable, unsurprising security surface). Matched against bucket for S3, host (lowercased) for HTTP.
- **Unset allowlist policy**: S3 allowed (credentials gate access), HTTP denied (SSRF surface requires an explicit opt-in). Spec'd explicitly so it can't be an accident.
- **Authorization failure maps to 404, not 403** — per API doc §5 there is no 403; 404 avoids existence oracles.

## Risks / Trade-offs

- [HTTP sources are an SSRF vector even with allowlist] → deny-by-default, no redirects-to-anywhere (ffmpeg fetches; document that allowlisted hosts are trusted), never fetch in this module.
- [Key escaping subtleties (`+`, `%2F`)] → decode exactly once, property-test escape/unescape round-trip.
