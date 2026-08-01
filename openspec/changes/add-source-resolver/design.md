## Context

The source is the last path portion; everything before it (signature, options) is consumed by earlier plugs. Two encodings exist because URL-escaping nested URLs is error-prone; both must converge on one canonical identity. Source *types* differ in almost every respect — a bucket and key, a URL, a path under a root — but share every one of those encoding concerns, so the split is between what is shared and what is not.

## Goals / Non-Goals

**Goals:**
- One decoding pipeline, one canonical-identity contract, one place a source type registers.
- A slice that is complete and testable while shipping zero source types.

**Non-Goals:**
- Any concrete source form (`local://` is `add-local-files-source`, `s3://` and `https://` are `add-remote-files-source`).
- Fetching bytes, presigning, or existence checks — the resolver is offline and pure; the seam is declared here and implemented by each type.
- A runtime plugin registry. Types are a compile-time list; nothing loads a source type from config.

## Decisions

- **Parse `enc/` to the plain form first, then share one code path** — guarantees the two encodings cannot drift semantically, and fixes the ordering every type depends on: decode exactly once, *then* interpret. Confinement checks and URL parsing are only sound on a fully-decoded string.
- **The shared layer owns rejection of anything no type should see**: malformed escapes, non-UTF-8, and control-class code points. Doing it once means a new source type cannot forget it — a NUL byte never reaches a path confinement check, and a bidi override never reaches an object key.
- **Control characters are matched by Unicode category** (`Cc`, `Cf`, `Zl`, `Zp`), not the ASCII range. `\x00-\x1f` alone lets U+0085, U+2028 and U+202E through, and a right-to-left override in a filename is a spoofing tool.
- **Malformed escapes are refused, not passed through.** `%zz` and `%25zz` would both decode to `%zz`, and one source with two spellings is one variant with two cache keys.
- **Both base64url spellings are accepted.** Padded and unpadded decode to the same bytes and therefore the same source and key; there is nothing to gain by refusing one, unlike a signature, which must not be malleable.
- **Dispatch on the scheme, via a compile-time list of type modules.** Each type declares its scheme and its tag; the resolver builds both lookups from the list. `parse/1` takes the registry as an optional argument so this slice can test dispatch, delegation and error paths against a test-only type without shipping a real one.
- **Typed sources stay tagged tuples** (`{:local, path}`, `{:s3, bucket, key}`, …) rather than a struct, so the tag is the dispatch key downstream and consumers pattern-match the shape their slice documents.
- **Authorization is a type callback, not a shared policy.** "Permitted" means a host allowlist for HTTPS, a bucket allowlist for S3, and root confinement for local — the shared layer would have to know all three to own it, so it owns none. It only guarantees that every type has an answer.
- **The storage seam is declared here and implemented per type.** Its two functions are exactly what render and info need from a source — metadata for 404/413, and an ffmpeg input — so it belongs with the contract rather than with whichever backend happened to be built first.

## Risks / Trade-offs

- [A slice with no source types has no end-to-end behavior] → mitigated by the injectable registry: decoding, dispatch, delegation and every rejection path are tested against a fake type, which is also the executable documentation of the contract.
- [The behaviour adds an indirection the codebase does not otherwise use] → accepted, and bounded: five callbacks, a compile-time list, no runtime configuration. The alternative — every type editing one module's private clauses — makes each source type a merge conflict with the others and leaves nothing to test until the first one lands.
- [Declaring `stat/1` and `ffmpeg_input/1` before any backend exists risks specifying them wrong] → they are lifted from what `add-render-endpoint` and `add-info-endpoint` already specified needing (HEAD-or-stat, presign-or-path), not invented ahead of a requirement.
- [Key escaping subtleties (`+`, `%2F`)] → decode exactly once, property-tested for escape/unescape round-trip against a fake type whose bodies carry reserved characters.
