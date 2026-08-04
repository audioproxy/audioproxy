## Context

`add-capacity-model-doc` established the model, measured its constants, and guards it in CI. What it did not do is put the answer where a reader looking for it will land. The reference run's own numbers make the point: the operator-facing question ("can this 4 GiB host run 16 concurrent 2 h transcodes?") is one division away from the published formula, but nothing in the document performs that division.

## Goals / Non-Goals

**Goals:**
- An operator finds their workload and host in a table and reads a concurrency number, within the first screen of the document.
- Every cell is derived from the published formula and the measured table, by a generator, so the matrix cannot drift from the model the CI guard enforces.
- Workloads the architecture refuses are visible as refusals rather than as small numbers.

**Non-Goals:**
- Changing the model, the measured constants, or the guard's assertion. This is presentation plus a generator over numbers that already exist.
- CPU/throughput sizing. The matrix answers "how many fit in memory", not "how many can this host actually encode in parallel" — those are different limits and conflating them would be worse than omitting one. The document should say which limit it is describing, and that `AP_MAX_CONCURRENCY` defaults to schedulers online for the other reason.

## Decisions

- **Inverting the formula is the whole trick, and rounding goes down.** `C_max` is a floor, and the `L` (linger) term is subtracted rather than ignored, so the short-render rows stay honest about needing `2C` worth of backlog.
- **Host memory columns are the container's limit, not the machine's.** The matrix assumes the number in the column is what the cgroup gets, and says so; an operator sizing a VM has to leave room for everything else on it.
- **Generated from the same constants the guard uses.** A hand-maintained matrix is a second copy of the model, and the second copy is the one that goes stale. The generator reads `R_ffmpeg` from the document's own measured table (the guard already does this) and shares `BEAM_base`, `T_ffmpeg`, `H_pipeline` and `LINGER_BACKLOGS` with `bin/check-capacity`.
- **Refusals are first-class cells.** `f:wav/bd:24` at 2 h is 2.07 GB against a 2 GB default `AP_MAX_SRC_BYTES`; the cell says "exceeds the retention cap" and links to the lossless section, because printing `1` there would imply a deployment that in fact fails on its first request.
- **The reverse table earns its place** because the two populations are different: someone with a fixed host size reads the matrix, someone with a fixed throughput requirement reads the reverse and goes shopping.

## Risks / Trade-offs

- [A matrix invites reading the cell and skipping the model] → that is mostly *fine*, and is the point; the risk is an operator missing that the numbers assume worst-case simultaneity. Mitigated by a one-line caveat on the table rather than by withholding it.
- [Two tables plus the existing one is a lot of tables] → the measured `R_ffmpeg` table moves down into the derivation, so the top of the document has exactly one thing to look at.
- [The generator is another script to keep working] → it is small, shares its constants with the guard, and the CI guard already fails if the underlying model drifts; the marginal maintenance is the emission code only.
