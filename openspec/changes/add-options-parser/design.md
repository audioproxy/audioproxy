## Context

Options are the cache key (API doc §1, §3). CLAUDE.md convention: every option must round-trip parse → normalize → cache key → identical ffmpeg args, property-tested. This slice owns the first three stages; the argv stage lands in `add-ffmpeg-command-builder`.

## Goals / Non-Goals

**Goals:**
- One typed `%Options{}` struct as the single internal representation.
- Canonical normalization strong enough that the normalized string can serve directly as the cache-key input.

**Non-Goals:**
- ffmpeg argv construction; source parsing; HTTP concerns (only structured errors that a later slice maps to 422).

## Decisions

- **Two-phase design**: `parse/1` (string → struct, per-key parsers) then `validate/1` (cross-key rules: `br`⊕`q`, `bd` only for `flac`/`wav`, `pts`/`pk_fmt` only with `f:peaks`, fade must fit inside trim duration when both bounded). Cross-key rules live in one place instead of scattered through parsers.
- **Canonical value rendering**: decimals emitted minimally (`12.5`, not `12.50`; `30`, not `30.0`) via a single `render_number/1`; keys sorted lexicographically; defaults materialized. Normalized string = `Enum.map_join("/", &render/1)` — this exact string is hashed for the cache key.
- **Cache key = SHA-256(normalized-options ‖ "\n" ‖ canonical-source)** hex-encoded, used as the variant-bucket object key. Human-debuggable prefix (`f=opus` style) rejected: object keys should be flat and length-bounded.
- **Duration semantics**: `t:START[:DURATION]`, floats with ≤ 3 decimal places (millisecond precision cap) so float formatting can never destabilize the cache key.
- **Errors as data**: `{:error, %OptionError{segment: "br:abc", reason: :invalid_integer}}` — the HTTP slice renders these as 422 JSON.

## Risks / Trade-offs

- [Float canonicalization is a classic determinism trap] → millisecond precision cap + property test `normalize(parse(normalize(x))) == normalize(x)`.
- [Validation rules will grow (e.g., codec-specific `q` ranges)] → per-key parser modules keep additions local; spec scenarios enumerate the v1 rule set explicitly.
