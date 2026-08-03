## Why

The published image distributes a GPL ffmpeg build (Debian's, `--enable-gpl`) plus other (L)GPL Debian packages. Distributing binaries triggers the GPL's real obligations: license texts must ship and *corresponding source* must be available — the exact source for the exact binaries. The proxy's own code is unaffected (subprocess boundary, recorded in CLAUDE.md), but the image is a distribution and the project has never said how it complies. This closes that gap for the OSS image — and by construction for any downstream image built the same way.

## What Changes

- License texts: verify `/usr/share/doc/*/copyright` files survive image slimming (they are the Debian-shipped notices; slimming must not strip them).
- A **source manifest** baked into the image at build time (`/usr/share/audioproxy/SOURCES.txt`): `dpkg -l`-derived exact package versions plus their `snapshot.debian.org` source URLs — corresponding source, pinned, reproducible.
- A written-offer/notice section in the README and on the GHCR package page: what the image contains, where the exact sources live, how long the offer stands.
- CI check: the manifest exists in the built image, every listed version resolves against snapshot.debian.org (spot-check), and the ffmpeg copyright file is present.
- CLAUDE.md's licensing posture gains one line: images are GPL-compliant via shipped notices + snapshot-pinned source manifest; slimming must preserve `/usr/share/doc`.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: published images SHALL carry license notices and a corresponding-source manifest for the distributed (L)GPL components.

## Impact

- Modified: `Dockerfile` (manifest generation step), CI (compliance check), README, CLAUDE.md.
- Not legal advice; it implements the standard Debian-derived-image compliance pattern. The AAC patent note in CLAUDE.md is a separate axis and stands.
- Touches no other change. Position: any time; before the PRO image exists is the honest deadline, since PRO inherits this pattern.
