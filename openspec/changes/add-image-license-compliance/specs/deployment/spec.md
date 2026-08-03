## ADDED Requirements

### Requirement: Distributed images carry license notices and corresponding source
The published image SHALL include the Debian copyright notices for its packages and a source manifest (`/usr/share/audioproxy/SOURCES.txt`) listing every installed package at its exact version with a resolvable `snapshot.debian.org` source URL; the README SHALL state the compliance posture and the offer.

#### Scenario: Notices present
- **WHEN** the built image is inspected
- **THEN** `/usr/share/doc/ffmpeg/copyright` (and peers) exist — image slimming has not stripped them

#### Scenario: Manifest resolves
- **WHEN** the CI compliance check runs
- **THEN** the manifest exists in the image and spot-checked entries resolve to fetchable sources at the pinned versions

#### Scenario: Manifest matches the image
- **WHEN** the manifest is compared against `dpkg -l` in the same image
- **THEN** every installed package appears at its installed version
