## Context

The non-streaming half of the former `add-render-endpoint`. Everything here is a pure function of the request plus one `File.stat` — no Port, no chunked response, so the whole slice tests through `Plug.Test`.

## Goals / Non-Goals

**Goals:**
- Every §5 status producible or table-tested before a single render exists; a 501 seam the action slice replaces.

**Non-Goals:**
- Streaming, headers-on-200, disconnect (the action slice); coalescing/semaphore (post-MVP).

## Decisions

- **Plug order**: VerifySignature → ParseOptions → ResolveSource (parse + authorize) → action (stat → 501). Cheapest checks first; stat is the only I/O and runs last.
- **Stat in the action, not a plug** — the info endpoint will share the plugs but wants stat *after* deciding what it's serving (conditional requests short-circuit it). The plugs are not literally I/O-free: `authorize/1` resolves confinement on the filesystem for `local://` sources (root resolution plus an existence-blind symlink hop per path component, on every request). What stays out of them is source-*metadata* I/O — `stat` — which is the read that reuse needs to control.
- **One `ErrorJSON` table, keyed by structured-error class**, not call sites: plugs and actions return `{:error, %OptionError{}}`-style values and one function renders them. Unreachable rows (415/504/429) ship because the table is the contract — producers arrive without touching the mapping.
- **501 over 404 for the placeholder**: a 404 would lie (the resource is valid, the capability is absent) and would be indistinguishable from the no-oracle 404s this slice takes pains to keep uniform.

## Risks / Trade-offs

- [Stat-then-render TOCTOU window] → explicitly deferred to the action slice's task 1.1a (inode pinning vs read-only-root posture); this slice never hands the path to anything.
- [501 briefly user-visible if deployed mid-chain] → intentional: the MVP milestone is the docker slice, two changes away; nothing before it is deployed.
