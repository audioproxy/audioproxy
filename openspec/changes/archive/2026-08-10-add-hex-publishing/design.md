## Context

Publishing an OTP *application* (not a library) to hex — precedented (Livebook et al.) and exactly what the PRO wrapper-release model needs: the OSS app as a versioned dependency whose start-up boots the full proxy.

## Goals / Non-Goals

**Goals:**
- One tag → one version everywhere (git, mix.exs, image, hex package, hexdocs).

**Non-Goals:**
- A hex *organization* with private packages (PRO distribution is the private image; private hex is a later option).
- Claiming the `audioproxy` name as well — name-squatting a variant spelling buys confusion, not protection.
- CHANGELOG file — release notes live on GitHub releases; hexdocs links there.

## Decisions

- **Apache-2.0 over MIT**: identical open-core mechanics, plus the explicit patent grant enterprise buyers ask about. Over AGPL+CLA: sole-author dual-licensing works today but taxes every future contributor with a CLA — wrong trade for a young project whose moat is private code, not copyleft.
- **Curated `files:` allowlist, CI-enforced**: hex packages are effectively permanent; the check makes "the tarball is exactly what we ship" a property, not a habit.
- **Publish step reuses the release gate**: `needs: smoke`, after the image push, same `mix.exs`==tag assertion. A hex-side failure after the image published is acceptable partial state (retry by re-running the job; hex rejects duplicates idempotently).
- **`ex_doc` dev-only** — the dependency policy is untouched at runtime.
- **Docs front page = README** with the embedding note added to it (single source; hexdocs `main: "readme"`).

## Risks / Trade-offs

- [Published versions are immutable; a bad tarball is forever] → the content check + `mix hex.build` dry-run task; worst case `mix hex.retire` marks a version.
- [App-boots-listener surprises a naive embedder] → documented contract; an opt-out (start without listener) is a future knob if a real embedder asks — the PRO wrapper wants the listener.
