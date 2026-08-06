## Context

`Config` exposes `max_src_bytes` from `AP_MAX_SRC_BYTES`, defaulting to 2 GB. Two callers read it: `Plugs.RenderAction` stats the source and answers `413` above the limit, and `RenderCoordinator.retain/2` accumulates `state.bytes` and returns a `:render_failed` error above it. Neither knows about the other. The coupling is invisible at both call sites and visible only in the configuration table, where it reads as one number with a compound description.

## Goals / Non-Goals

**Goals:**
- An operator can accept a 3 GB source and still bound one render's retention to 256 MB.
- No behaviour change for a deployment that sets neither variable, or only the old one.
- The retention bound is specified, not merely implemented.

**Non-Goals:**
- Making full-length lossless fit. It does not fit, this does not change that, and the honest answer stays `spool-render-backlog` or a `t:` window.
- Predicting variant size before rendering. See below — it is the obviously attractive follow-on and it is a different change with a different risk.
- Touching the source ceiling's name, default, status code or spec. Renaming a documented variable to gain symmetry would break every existing deployment for a tidier table.

## Decisions

- **Two keys, not a mode.** The alternative shape — one key plus a flag choosing what it bounds — is smaller in the config table and worse everywhere else: the two limits genuinely differ in value for the deployments that need the split, so a single number cannot serve both no matter which flag is set.
- **`AP_MAX_VARIANT_BYTES` defaults to the resolved `AP_MAX_SRC_BYTES`, not to its own literal.** Resolving to the *effective* value matters: an operator who has already raised the source cap to 4 GB to accept large masters keeps today's behaviour rather than being silently tightened to the 2 GB default. The fallback is a config-time resolution so the coordinator reads one number and has no fallback logic in the hot path.
- **"Variant", not "output" or "retained", in the name.** The document, the URL grammar and the variant store all call the produced object a variant; a fourth word for it would be a fourth thing to learn. It also reads correctly against the thing it bounds — the size of the variant, which is duration × bitrate.
- **The retention failure stays a killed render, not a `413`.** By the time `retain/2` can know the output is too large, the response is a committed `200` with bytes already on the wire. A status code cannot be revised, so the honest behaviour is the current one: kill the render, fail the request, and let the client see a truncated body. The change specifies this rather than improving it.
- **Predicting the variant up front is out of scope, and this is the reasoning worth keeping.** Duration × bitrate is computable, which makes a pre-render `413` look easy. It is not: duration is not known without probing the source, the render path deliberately does not probe (that is `/info`'s job and a second subprocess per request), and a bitrate estimate for a VBR or lossless output is an estimate — refusing a request on an estimate means refusing renders that would have succeeded. A cheap wrong answer at the front is worse than an expensive right one partway through. If it is ever built it needs its own change and its own argument about probe cost.
- **The matrix reads the variant cap.** `bin/capacity_model.rb`'s refusal test is about what a render may retain, so it follows the retention key. Cells do not move — the default is the same number — but the reason a cell reads **refused** stops being a coincidence of the two limits sharing a variable.

## Risks / Trade-offs

- [A second memory knob is a second thing to get wrong] → mitigated by the default: an operator who does not know it exists is in exactly the position they are in today. The knob is for the deployment that has a reason to reach for it.
- [Two variables invite the belief that raising the retention cap buys capacity] → it does not, and this is the misreading with real consequences: raising it licenses every slot to reach the new size, so it converts one killed render into an OOM that takes every concurrent render with it. The `AP_MAX_VARIANT_BYTES` row in the README and the capacity document both have to say that the lever for the *total* is `AP_MAX_CONCURRENCY`, and the matrix is where you find out what the total costs.
- [Specifying the kill-mid-render behaviour makes an unpleasant property official] → that is the point. It is already the behaviour; leaving it unspecified has not made it nicer, and it is the property that motivates `spool-render-backlog`.
