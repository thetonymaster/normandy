import Config

config :normandy, adapter: Poison

import_config "#{config_env()}.exs"
