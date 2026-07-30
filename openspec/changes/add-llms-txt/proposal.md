## Why

AI agents are increasingly the ones integrating APIs — generating signed URLs, choosing processing options, wiring the proxy into applications. The llms.txt convention gives them a single, token-efficient, markdown entry point. Because URLs are the entire API here, a well-formed llms.txt makes the service near-perfectly legible to an LLM: grammar, options table, error contract, done.

## What Changes

- Author `/llms.txt` per the llms.txt spec (H1 title, blockquote summary, sectioned link list) covering: URL grammar and signing, processing options, response/cache semantics, error codes, configuration.
- Author `/llms-full.txt` (expanded single-file variant) embedding the full API reference so agents need no follow-up fetches.
- Serve both unsigned from the app at `GET /llms.txt` and `GET /llms-full.txt` (like `/health`), `text/markdown`, long-lived cache headers — content compiled into the release, no filesystem dependency at runtime.
- Drift guards in the test suite: documented option keys must exactly match the options parser's known keys; documented error codes must match the ErrorJSON mapping table; llms.txt structure must lint against the spec's format.
- Convention (CLAUDE.md): any slice that changes the API surface updates llms.txt in the same change, same as the README rule.

## Capabilities

### New Capabilities

- `ai-discoverability`: llms.txt authoring, serving, and documentation-drift enforcement.

### Modified Capabilities

<!-- none — new unsigned routes only -->

## Impact

- New: `priv/llms/llms.txt`, `priv/llms/llms-full.txt` (or module attributes), routes in the router, drift-guard tests.
- Modified: CLAUDE.md conventions section.
- Depends on: `add-options-parser` and `add-render-endpoint` (the parser keys and error table the drift guards check against). Position: post-MVP, any time after slice 11 (`add-docker-release`).
