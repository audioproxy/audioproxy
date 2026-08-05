## 1. The writer and its lifecycle (slice 1)

- [ ] 1.1 `AP_BACKLOG_MODE` (`memory` | `spool`, default `memory`), `AP_SPOOL_DIR`, `AP_SPOOL_MAX_BYTES` in `Config`; refuse `spool` at boot if the directory is missing or not writable, rather than at the first render
- [ ] 1.2 A spool writer owned by the coordinator: one file per cache key, chunks appended as they arrive, committed offset tracked; `state.backlog`/`state.bytes` become the memory-mode branch of one seam rather than two parallel implementations
- [ ] 1.3 Removal on completion, failure, timeout and coordinator death — including the abnormal exits, which is where a `terminate/2` that only handles the happy path leaves files behind
- [ ] 1.4 Boot sweep of the spool directory; log what it removed, because a sweep that runs silently on every start is indistinguishable from one that never runs
- [ ] 1.5 Enforce `AP_SPOOL_MAX_BYTES` across in-flight renders, failing the render that would cross it with an error naming the bound

## 2. The joiner read path (slice 2)

- [ ] 2.1 A catch-up read bounded by the committed offset; `Plugs.RenderAction` stops flattening the accumulated backlog with `IO.iodata_to_binary/1` in spool mode
- [ ] 2.2 Handover from catch-up to live chunks with no duplicated or missing bytes at the boundary — the one place this change is most likely to be subtly wrong
- [ ] 2.3 Raw-mode `File.open`/`IO.binread`, so reads land on dirty I/O schedulers and a slow read does not occupy a normal one

## 3. Tests

- [ ] 3.1 Same signed request through both modes → byte-identical bodies. The whole change rests on this
- [ ] 3.2 The existing coalescing suite passes in spool mode: byte-identical streams across subscribers, late joiners, subscriber churn, failure propagation
- [ ] 3.3 A subscriber attaching mid-chunk is served only to the committed offset — assert against a torn boundary directly, not via a stream comparison that might pass by luck
- [ ] 3.4 Cancellation, `AP_RENDER_TIMEOUT` and coordinator death each leave no spool file
- [ ] 3.5 Memory does not scale with output length in spool mode — the claim the change exists for, measured rather than asserted
- [ ] 3.6 Spool bound enforced; a render crossing it fails naming the bound and does not fill the filesystem

## 4. The model and the documents (slice 3)

- [ ] 4.1 `bin/capacity_model.rb` gains the mode: `B_backlog` in the bracket for memory, out of it for spool
- [ ] 4.2 Matrix generated per mode, with the spool tables showing what stops being refused; `--verify` must hold for both
- [ ] 4.3 `docs/capacity.md`: the banner names the mode rather than the version, and the disk sizing section lands with the tmpfs trap stated plainly — a memory-backed spool mount reinstates the cost while looking like it removed it
- [ ] 4.4 `README.md` configuration rows; deployment docs for the writable spool mount
- [ ] 4.5 Re-point `CLAUDE.md`'s "escalation path" note at the shipped mechanism rather than the plan
