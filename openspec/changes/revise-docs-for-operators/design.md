## Context

Editorial change with one mechanical component. The grep guard is the piece that makes it durable: the same docs-with-teeth pattern as the llms drift guards and the config-documentation guard, applied to audience discipline.

## Goals / Non-Goals

**Goals:** operator pages readable by someone who has never run ffmpeg and never will read Elixir; contributor content preserved where contributors look.

**Non-Goals:** rewriting `ffmpeg-arguments.md` or `development.md` (internals are their job); changing any example's *behavior*; touching the API doc (the contract's precision is its audience).

## Decisions

- **Guard scope is module-shaped strings, not vocabulary**: `AudioProxy.`-prefixed identifiers and `@attribute`-in-backticks forms. Words like "coordinator" or "semaphore" stay allowed — behavior names are how operator docs *should* speak; it is the code addresses that are banned.
- **Constants keep their values, lose their addresses**: capacity's table stays numerically exact ("1 MiB high-water") with a single line pointing contributors at `development.md` for where numbers live in code.
- **Goal-first is a review criterion, not a lint**: the spec states the standard so PR review has something to point at; no tool pretends to check prose intent.

## Risks / Trade-offs

- [Behavior-named references are vaguer than module names] → for this audience, precision about code locations is noise; the contributor pointer preserves the path for the other audience.
