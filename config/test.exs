import Config

config :normandy,
  adapter: Poison

# Configure Claudio HTTP timeouts for integration tests (using Req HTTP client)
config :claudio, Claudio.Client,
  timeout: 60_000,
  recv_timeout: 120_000
