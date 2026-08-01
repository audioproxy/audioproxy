import Config

# Evaluated at boot — in a release by the boot script before the application
# starts, and by Mix in dev and test. This is the only config file that runs at
# runtime; `config.exs` and its environment siblings are compiled into the
# release and frozen there.
#
# There are deliberately no `AP_*` reads here. The whole `AP_` surface is read,
# typed, and validated by `AudioProxy.Config.load!/1` from
# `AudioProxy.Application.start/2`, which is runtime in a release exactly as it
# is in dev — so both boot paths share one parser, one set of error messages,
# and one test suite, and a malformed variable aborts the boot rather than
# resolving to a surprising default. Reading them here instead would split that
# validation across two mechanisms and put half of it out of reach of
# `AudioProxy.Config.build!/1`, which is what the tests exercise.
#
# What belongs here is configuration that env vars cannot express through
# `AudioProxy.Config` — application environment consumed by dependencies before
# our supervision tree starts. Nothing qualifies yet.
