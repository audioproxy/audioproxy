## Context

All terms now exist in merged code or land with `add-variant-cache`: the coalescing backlog cap (merged), the port pipeline's high-water buffer (merged), the S3 multipart part size (with the S3 backend), subprocess RSS (measurable on the pinned image). The doc's job is assembling them; the CI job's job is keeping them assembled.

## Goals / Non-Goals

**Goals:**
- Container memory limits computable from config; long-form (1–2 h) treated as a first-class sizing case; the model unable to drift silently.

**Non-Goals:**
- Building the spooled backlog (named as the long-form escalation; its own change when a deployment demands it).
- CPU/throughput capacity modeling (render-rate math is a different doc when someone needs it).
- Modeling page cache (reclaimable; the guard adjusts for it rather than modeling it).

## Decisions

- **The formula is per-architecture-era and says so**: it models the in-memory-backlog design. A future spooled backlog rewrites `B_backlog`; the doc carries a version banner tied to the design decisions it derives from, so an operator on an older image reads matching math.
- **Measurement over estimation for `R_ffmpeg`**: cgroup-scoped peak RSS per render, matrix over formats × {plain, `norm`} — the two axes that move decoder/filter memory. Ruby script (user convention), runnable inside the image, output committed as the table.
- **The guard's tolerance is explicit**: predicted bound × a stated headroom factor (BEAM allocator slack, binary GC lag), with page cache subtracted via `memory.stat`'s inactive-file. A guard with silent slack is a guard that never fires; the factor is written down and justified.
- **Long-form framing**: the doc leads with the asymmetry — *input never accumulates, output is the hazard* — because it is the counterintuitive fact that makes the rest of the model make sense, and it is what a podcast-scale operator needs first.
- **Refc-binary sharing stated as a guarantee with a test reference**: N coalesced subscribers ≈ one backlog. The coalescing suite's byte-identical-streams tests are the evidence; the doc links rather than re-proves.

## Risks / Trade-offs

- [The CI workload is a sample, not the worst case] → it validates the model's *shape* (terms and coefficients), not every configuration; the doc says so. A failing guard means the model lies — that is the signal that matters.
- [RSS varies across ffmpeg builds] → the table is pinned-image output and regenerated on pin bumps (the docker slice's upgrade procedure gains one step, recorded in its README section by this slice's docs task).
- [Long runtimes for the long-form CI fixture] → a 1–2 h *duration* fixture is seconds of lavfi generation and ~1–2 min of transcode at typical speeds; bounded and parallel to other jobs.
