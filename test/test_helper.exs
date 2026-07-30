# Tests tagged :ffmpeg shell out to the real binaries, so they are excluded by
# default and run in CI's `test-ffmpeg` job (`mix test --only ffmpeg`), which
# installs ffmpeg first. Run them locally the same way.
ExUnit.start(exclude: [:ffmpeg])
