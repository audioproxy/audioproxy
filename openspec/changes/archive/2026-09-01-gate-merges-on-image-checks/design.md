## Context

Two failure modes share one cause. A required check that no longer exists blocks every pull request forever, showing *Expected — waiting for status*, which is visually identical to a job still running. A gating job that is *not* required lets a red commit merge. Both come from the required-check list being a hand-written copy of a job-name list that lives somewhere else.

## Goals / Non-Goals

**Goals:**
- Everything that gates a tag also gates a merge.
- The documented list cannot silently disagree with the workflow.

**Non-Goals:**
- Applying the branch-protection rule from code. It needs repo-admin scope, and a workflow that could rewrite its own merge gate is a worse problem than the one being solved.
- Requiring `capacity`. It is slow and its guard already spans both architectures; leaving it advisory is a deliberate cost decision, and the guard should record that rather than quietly omit it.

## Decisions

- **Derive the expected list from `ci.yml`, compare against the document.** The job names are computable: any job in the gating set, expanded across its matrix. `AudioProxy.MarkedTable` already exists for reading a table out of a marked region of a published document, and this is the same shape of problem as the configuration and error-table guards.
- **A matrix job's checks are its legs, not the job.** `container smoke suite` reports as `container smoke suite (amd64)` and `(arm64)`. The guard must expand the matrix the same way GitHub does, or it will assert the wrong names — which is exactly the trap `add-multi-arch-images` walked into.
- **The guard fails on disagreement in either direction.** A check in the workflow but not the document is an ungated merge; one in the document but not the workflow is a pull request that blocks forever. Both are the failure, so both are red.

## Risks / Trade-offs

- [The guard checks the document, not the actual repo setting] → unavoidable without admin API access, and worth being explicit about in the document itself: the guard keeps the *instructions* right, a human keeps the *rule* right.
- [Matrix expansion in the guard is a second implementation of GitHub's naming] → small and well-defined (`name (leg)`), and a divergence shows up as a failing guard rather than as a silent gap.
