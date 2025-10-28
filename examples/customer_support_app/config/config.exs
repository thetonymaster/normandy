import Config

# Configure the JSON adapter for Normandy
config :normandy,
  adapter: Poison

# Import environment specific config
import_config "#{config_env()}.exs"
