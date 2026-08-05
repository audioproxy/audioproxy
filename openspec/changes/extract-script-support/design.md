## Context

Three `bin/` scripts, ~1500 lines between them, sharing about 30 lines of identical plumbing and roughly 35 lines of comment explaining why that plumbing is shaped the way it is. The scripts are run by hand and by CI with `ruby bin/<name>`; nothing about them requires being single-file, and `require_relative` works unchanged in both.

## Goals / Non-Goals

**Goals:**
- One home for the docker/shell plumbing and, more importantly, for the comments that justify it.
- One implementation of the cgroup sampler, since the two copies have already diverged.
- No behaviour change in any of the three scripts.

**Non-Goals:**
- A general-purpose library. This is three callers; the support file should hold what all of them need and nothing speculative.
- Unifying the presentation helpers or the health-check helpers — see the proposal's exclusion list. Their differences are deliberate.
- Rewriting anything in Elixir. These are operational scripts and Ruby is the convention.

## Decisions

- **Extract on the "byte-identical" test, not the "looks similar" test.** Functions that already differ between scripts differ for reasons; merging them would mean choosing one script's behaviour for another, which is a behaviour change wearing a refactor's clothes.
- **The sampler takes its interval as a parameter.** That is the drift that already happened, so the extracted form has to make the interval explicit at the call site rather than defaulting it invisibly.
- **Comments move, not copy.** The point of the exercise. A comment left behind in duplicate is the failure mode being fixed.
- **File placement:** under `bin/`, since it is only ever loaded by things in `bin/`. It is not executable and not a script; naming should make that obvious at a glance so nobody tries to run it.
- **Two support files, not one.** `bin/capacity_model.rb` arrived with #41 and holds the published memory model — constants, arithmetic, and the parser for the table `docs/capacity.md` publishes. It does not merge into this change's file, and the test is the one that decides everything else here: plumbing moves, domain stays. Docker invocation and shell capture mean nothing to a reader following the capacity argument, and the capacity model means nothing to a reader wondering why `docker_run` picks its container id out by shape. One file would be the union of two audiences and the natural home for neither. The visible cost is `check-capacity` requiring two of them, which is the honest shape and cheaper than the merged file's slow accumulation of everything any script ever needed.

## Risks / Trade-offs

- [`bin/smoke-image` gates `publish`] → the highest-risk file in the change is the one with the most to lose. Verification is running all three scripts before and after and comparing output, not reading the diff and trusting it.
- [Indirection costs a reader a jump] → real, and the reason the exclusion list is as long as it is. Only plumbing with no domain content moves; anything a reader needs in context to understand a script's argument stays in that script.
- [A shared file couples three scripts] → accepted deliberately: they are already coupled through copy-paste, and this makes the coupling visible and correctable in one place instead of invisible and correctable in three.
