## 1. Decide first

- [ ] 1.1 Settle the open question: names only, or names *and* defaults. Write the answer into `design.md` before writing code — it constrains how the table may be written
- [ ] 1.2 Settle whether the `AWS_*` credentials variables are in scope

## 2. The seam

- [ ] 2.1 `AudioProxy.Config` publishes the `AP_`-prefixed variables it reads, as data
- [ ] 2.2 A test that fails when `build!/1` reads a variable the published list omits — the guard against the guard, per `design.md`'s central risk

## 3. The guard

- [ ] 3.1 Mark the configuration table in `priv/llms/llms-full.txt` with `<!-- config-table:start -->` / `<!-- config-table:end -->`
- [ ] 3.2 Test: documented variables == published variables, both directions, failure names the variable
- [ ] 3.3 Extend the same check to the README's configuration table (mark it, or anchor on the heading — whichever leaves the README readable)

## 4. Docs

- [ ] 4.1 `CLAUDE.md`: the machine-checked list becomes three sets plus the signing example, and states plainly whether defaults are covered
- [ ] 4.2 `README.md`: update the sentence naming what is checked
