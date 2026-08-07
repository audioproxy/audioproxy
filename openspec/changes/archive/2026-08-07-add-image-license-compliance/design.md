## Context

Standard compliance pattern for Debian-based distributed images: notices ride in `/usr/share/doc`, corresponding source is pinned via snapshot.debian.org rather than mirrored. The proxy's own process-boundary posture (CLAUDE.md) is unchanged — this is about the image as a distribution.

## Goals / Non-Goals

**Goals:**
- Every published image self-describes its (L)GPL contents and where their exact sources live; the claim is CI-checked, not aspirational.

**Non-Goals:**
- Mirroring source tarballs (snapshot.debian.org is the pinned archive; mirroring is the escalation if it ever proves unreliable).
- Legal review of the AAC patent posture — separate axis, already an open question in CLAUDE.md.
- SBOM tooling (SPDX/syft) — heavier machinery than the obligation requires; a future observability nicety, not compliance.

## Decisions

- **snapshot.debian.org URLs over mirrored tarballs**: the archive is version-exact and stable; the manifest records the snapshot timestamp of the base image so URLs stay resolvable. Escalate to mirroring only on evidence.
- **Manifest generated in the Dockerfile** (one `dpkg-query` + awk step at build), not by CI — the artifact carries its own compliance, so a locally built image is as compliant as a published one.
- **README written-offer section** kept short and factual: contents, where sources live, contact. GHCR package description links to it.

## Risks / Trade-offs

- [snapshot.debian.org availability] → it is Debian's own archival service; the CI spot-check turns silent rot into a red build.
- [`/usr/share/doc` adds a few MB] → negligible against ffmpeg; slimming exclusions documented so a future size pass does not strip notices.
