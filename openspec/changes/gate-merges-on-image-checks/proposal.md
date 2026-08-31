## Why

Several CI jobs gate a *tag* without gating a *merge*. They are wired into `publish` through `needs:`, so a bad commit cannot publish — but nothing stops it from reaching `main`, and by the time the tag run goes red the fix is a new commit on a branch everyone has already pulled.

The repository already documents one instance of this, for `hex-package`, in a callout that has stood since that job was written. `add-multi-arch-images` added a second (`ffmpeg-arch-parity`) and made a third more visible (`license-compliance`, which has never been a required check and now runs per architecture). Three instances of a documented-and-tolerated gap is the point at which it stops being a note and becomes a change.

The reason it persists is that the fix lives in two places that cannot be edited together: the job list is in `ci.yml`, and the *rule* naming required checks is a GitHub repository setting that does not travel with a clone. A fork gets the workflow and none of the protection. So the gap cannot be closed by a commit alone, and a change that pretends otherwise would be dishonest about what it delivers.

## What Changes

- `ffmpeg-arch-parity` and `license-compliance` (both architectures) join the documented required-check set, alongside the four image checks already listed.
- The required-check list stops being hand-maintained prose that drifts from the workflow: a small check derives the expected set from `ci.yml` and fails when the document and the workflow disagree, in the same spirit as the existing configuration and error-table guards.
- `docs/development.md` states plainly that the rule itself is a repo setting, names every check it must list, and says what a fork has to do.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: every job that gates publishing SHALL also be a check that gates merging, and the documented list of those checks SHALL be verified against the workflow rather than maintained by hand.

## Impact

- Modified: `docs/development.md` (the required-check list and the fork instructions), a new guard under `test/` or `bin/`, and `.github/workflows/ci.yml` if the guard needs a job.
- **Not deliverable by commit alone:** the branch-protection rule on `main` is a repo setting. This change makes the correct list authoritative and checkable; a human applies it once, and the guard is what stops it silently rotting afterwards.
- Depends on: `add-multi-arch-images` (which renamed two required checks and added `ffmpeg-arch-parity`).
- Position: OSS, small. Sooner is better — a renamed or missing required check blocks every pull request until someone notices.
