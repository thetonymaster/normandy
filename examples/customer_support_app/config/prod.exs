import Config

# Production configuration
config :logger, level: :info

# Configure JSON adapter
config :normandy,
  adapter: Poison
