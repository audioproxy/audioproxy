# Tests tagged :ffmpeg shell out to the real binaries, so they are excluded by
# default and run in CI's `test-ffmpeg` job (`mix test --only ffmpeg`), which
# installs ffmpeg first. Run them locally the same way.
#
# Tests tagged :integration bind a real socket (Bandit on a fixed port), so
# they are excluded by default too; CI's `test` job runs them via
# `mix test --include integration`. Run them locally the same way.
#
# Tests tagged :minio need a real S3-compatible store. A stub cannot verify a
# signature, so it cannot tell a correct request from a self-consistently
# wrong one — which is the thing an S3 client is most likely to get wrong.
# Excluded by default, run with `mix test --only minio` (MinIO is a compose
# service in the devcontainer; `docs/development.md` covers running it
# anywhere else). They fail rather than skip when it is absent: a green run
# against nothing is a lie about coverage.
ExUnit.start(exclude: [:ffmpeg, :integration, :minio])
