#!/bin/sh
# `fake_ffprobe.sh` with a tally: every invocation appends its input to a log
# beside the file it was asked about, and then behaves exactly as the shared
# stand-in does.
#
# The tally is what "exactly one probe was spawned" is asserted against.
# Counting coordinators or registry entries would not say it — the property is
# about *subprocesses*, and a coordinator that spawned two would look identical
# from the registry's side.
#
# The log lives at `<dirname of input>/.probe-log`, which is the per-test tmp
# dir the source was written into. Deriving it from the input rather than an
# environment variable is deliberate: a port inherits the BEAM's environment, so
# an `AP_`-shaped variable set by one test would still be set for the next one,
# and a stale path under `set -eu` turns an unrelated probe into a failure.
#
# `>>` of a single short line is atomic on Linux, which is what makes the count
# trustworthy under the concurrent bursts these tests exist to create.

set -eu

input=""
for arg in "$@"; do
  input="$arg"
done

printf '%s\n' "$input" >> "$(dirname "$input")/.probe-log"

exec "$(dirname "$0")/fake_ffprobe.sh" "$@"
