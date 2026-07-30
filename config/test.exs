import Config

# Tests drive the router through Plug.Test, so the suite binds no listening
# socket — that keeps concurrent worktrees from fighting over a port.
config :audio_proxy, start_listener: false

config :logger, level: :warning
