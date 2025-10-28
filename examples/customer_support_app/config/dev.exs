import Config

# Development configuration
config :logger, :console, format: "[$level] $message\n"

# Configure JSON adapter
config :normandy,
  adapter: Poison
