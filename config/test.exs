import Config

config :normandy,
  adapter: Poison

# Configure Claudio HTTP timeouts for integration tests (using Req HTTP client)
config :claudio, Claudio.Client,
  timeout: 60_000,
  recv_timeout: 120_000

config :normandy, ecto_repos: [Normandy.TestRepo]

config :normandy, Normandy.TestRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "normandy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/test_repo"

config :normandy, :redis_url, System.get_env("REDIS_URL", "redis://localhost:6379")
