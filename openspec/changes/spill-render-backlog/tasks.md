# Tasks

## 1. Behaviour

- [ ] 1.1 `AP_BACKLOG_SPILL_BYTES` config, and `AP_BACKLOG_MODE=auto` selecting size-based spilling
- [ ] 1.2 Retention path: in-memory until the threshold, one-way flush to the spool file, continue on file
- [ ] 1.3 A failed flush or write fails the render; no fallback to memory

## 2. Tests

- [ ] 2.1 Byte-identical streams for subscribers attaching before, during and after the spill
- [ ] 2.2 Threshold respected exactly; a render one byte under it creates no file (assert on the spool directory)
- [ ] 2.3 Spill failure is terminal and reported as a render failure
- [ ] 2.4 `auto` compared against both fixed modes on the same requests

## 3. Docs

- [ ] 3.1 `docs/capacity.md`: sizing by threshold rather than by mode
- [ ] 3.2 README configuration row; note that `AP_BACKLOG_MODE` is on its way out (`retire-backlog-mode`)
