## 1. Image

- [x] 1.1 Dockerfile: manifest generation step (`dpkg-query` versions + snapshot.debian.org URLs + base-image snapshot timestamp → `/usr/share/audioproxy/SOURCES.txt`); confirm `/usr/share/doc` survives any slimming
- [x] 1.2 CI compliance check: manifest present, matches `dpkg -l`, spot-checked URLs resolve, ffmpeg copyright file present

## 2. Docs

- [x] 2.1 README: compliance/notice section (image contents, source availability, offer); GHCR package description links it
- [x] 2.2 CLAUDE.md stack section: one line — images comply via notices + snapshot-pinned manifest; slimming must preserve `/usr/share/doc`
