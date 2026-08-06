## Why

`AP_MAX_SRC_BYTES` is one configured number read at two unrelated call sites: against the statted source in `Plugs.RenderAction` (oversized → `413`, before a render starts) and against cumulative *output* in `RenderCoordinator.retain/2` (crossed → the render is killed mid-stream). `docs/capacity.md` already says these two jobs pull in opposite directions. What it does not say, because until now there was nothing to say, is that the most ordinary long-form deployment cannot be expressed at all.

A catalogue of two-hour 24-bit masters served as thirty-second MP3 previews needs the source ceiling above 2.07 GB to accept its own files. Setting it there simultaneously licenses *any single render* to retain 2.07 GB of output — for a workload whose actual outputs are 480 KB. The operator wanted "accept big inputs, produce small outputs" and the configuration vocabulary has no way to say it. They get the memory exposure of full-length lossless while serving previews, and the only remaining bound on the total is `AP_MAX_CONCURRENCY`.

The reflex when a render is refused is to raise the cap, and raising it is precisely wrong: the cap is per-render while the bill is `C × B_backlog`, so raising it to fit one render licenses every slot to reach that size. A 4 h `f:wav/bd:24` render is 4.15 GB and wants an 8 GiB container to run *one at a time*. Today that request fails as one killed render with a legible message and the other renders survive; with the cap raised it succeeds, two concurrent ones exhaust the container, and the kernel picks the victim — which is every in-flight render rather than the one that misbehaved. The knob that looks like the answer converts a clean failure into an indiscriminate one.

Splitting the knob does not make long-form lossless fit. Nothing short of `spool-render-backlog` does. It makes the refusal land on the right thing and lets a preview deployment stop carrying a lossless deployment's exposure.

## What Changes

- **`AP_MAX_VARIANT_BYTES`**, a second ceiling, bounding what one render may retain. `RenderCoordinator.retain/2` checks it instead of `AP_MAX_SRC_BYTES`; the source check in `Plugs.RenderAction` and `local-files` is untouched and keeps its name.
- **It defaults to `AP_MAX_SRC_BYTES`'s effective value**, so an existing deployment upgrades to byte-identical behaviour and the split is opt-in. A default that tightened the retention bound would refuse renders that work today — full-length FLAC at 760 MB, for one — and a capacity change whose upgrade path breaks working deployments is not worth the expressiveness.
- **The retention bound gets a spec requirement.** It is enforced in code and stated in `docs/capacity.md`, but no capability spec covers it: `AP_MAX_SRC_BYTES` appears in `render-http` and `local-files`, both about the *source*. The kill-mid-render behaviour has never been specified, which is why it was possible for one variable to acquire a second job unnoticed.
- **The failure's shape is written down**, because it is not the source cap's. A retention breach happens after the response has committed to `200` and started streaming, so it cannot become a `413` — the client sees a truncated body and a `500`-class outcome for a request that was already in flight. Predicting variant size before rendering would allow a clean refusal and is deliberately out of scope (see design).
- **The matrix's refusal test moves to the new key.** `bin/capacity_model.rb` decides which cells read **refused** from `DEFAULT_MAX_SRC_BYTES`; that becomes the variant cap, which is the number that actually governs, and the legend in `docs/capacity.md` says so.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `render-coalescing`: the retained backlog gains a stated bound, with its own configured ceiling.
- `capacity-model`: the model's `B_backlog` term is bounded by `AP_MAX_VARIANT_BYTES` rather than by the source cap.

## Impact

- Modified: `lib/audio_proxy/config.ex`, `lib/audio_proxy/render_coordinator.ex` (one call site), `bin/capacity_model.rb`, `docs/capacity.md`, `README.md`'s configuration table.
- Not modified: `Plugs.RenderAction`'s source check, `local-files`, the error table. No endpoint, URL or cache-key change.
- Depends on: `add-capacity-decision-matrix` (#41) for the constant the matrix reads.
- **Behaviour is unchanged on upgrade** by construction — the new key's default is the old key's value. The test that matters is that a deployment setting neither variable sees byte-identical refusals.
