# Tasks

## 1. Schema and resolution
- [ ] 1.1 Track schema validation (count cap, field bounds, first-track-is-program)
- [ ] 1.2 N-source resolution: authorize + stat each track via existing source types; aggregate error mapping (any failure fails the request with the single-source status)
## 2. Render
- [ ] 2.1 Filter-graph builder: adelay/volume/aloop/sidechaincompress/amix, argv only; golden tests per combination
- [ ] 2.2 Wire into the render pipeline as a program-source transform ahead of existing options; one slot, existing timeout/kill semantics
## 3. Tests
- [ ] 3.1 Cache-key stability across spellings; payload in key, exp still excluded
- [ ] 3.2 Rendered duck assertion (bed RMS under speech vs gaps); loop-to-program-length assertion
## 4. Docs
- [ ] 4.1 PRO contract: track schema, bounds, examples (bed, accessibility separation)
