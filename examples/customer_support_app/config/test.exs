import Config

# Test configuration
config :logger, level: :warning

# Configure JSON adapter
config :normandy,
  adapter: Poison
