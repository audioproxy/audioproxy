import Config

# Application behaviour is configured through AP_-prefixed environment variables
# (see AudioProxy.Config), not through this file. The only switches here are
# build-time concerns that env vars cannot express.

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
