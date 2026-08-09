## Context

llms.txt is a plain-markdown convention (llmstxt.org): concise index at `/llms.txt`, optional expanded `/llms-full.txt`. For a URL-is-the-API service, the docs can be verified against code — the option table and error table both have single sources of truth in the implementation.

## Goals / Non-Goals

**Goals:**
- An agent with only `/llms-full.txt` can construct correct signed URLs (given a key) and interpret every response.
- Zero doc-drift by construction: CI fails when code and docs disagree.

**Non-Goals:**
- MCP server, OpenAPI spec, or interactive tooling (llms.txt first; others can layer on later if demand appears).
- Documenting operator-only concerns (deployment internals) — llms.txt targets API consumers.

## Decisions

- **Content lives in `priv/llms/*.md`**, embedded at compile time (`@external_resource` + `File.read!` into a module attribute) — served from memory, immutable per release, no runtime filesystem reads.
- **Drift guards compare sets, not prose**: extract option keys from the llms-full.txt options table (markdown table parse in the test) and compare with `Options.known_keys/0`; same for error codes vs the ErrorJSON table. Prose quality stays human-owned; only *coverage* is machine-enforced.
- **Link URLs in llms.txt are relative** (`/llms-full.txt`, `/health`) plus the canonical GitHub doc links — the file works regardless of deployment hostname.
- **Format lint as a unit test**, not an external tool: ~30 lines of markdown structure assertions, keeping the dependency policy intact.
- **Signing guidance includes a worked example** (fixed demo key/salt/path → signature) reusing the signature module's test vectors — an agent can validate its own implementation against it.

## Risks / Trade-offs

- [Two docs (README + llms.txt) to keep current] → drift guards cover llms.txt mechanically; the CLAUDE.md convention covers both editorially; llms-full.txt embeds shared content rather than duplicating semantics prose-first.
- [Table-parsing tests are brittle to markdown reformatting] → constrain the options/errors tables to a fixed, simple format (documented in a comment at the top of the file).
