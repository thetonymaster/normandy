import Config

# Configure Claudio HTTP timeouts for integration tests (using Req HTTP client)
config :claudio, Claudio.Client,
  timeout: 60_000,
  recv_timeout: 120_000

config :normandy, ecto_repos: [Normandy.TestRepo]

config :normandy, Normandy.TestRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "normandy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/test_repo"

config :normandy, :redis_url, System.get_env("REDIS_URL", "redis://localhost:6379")

# No OTLP exporter in tests (silences the "opentelemetry_exporter not found" log).
# The simple processor exports synchronously; `Normandy.Test.OtelSpanBridge.attach/1`
# points it at the test process.
config :opentelemetry,
  traces_exporter: :none,
  processors: [{:otel_simple_processor, %{}}]

# No console logger in tests. Under Elixir 1.17 / OTP 27, ExUnit's capture_log removed and
# re-added the :default handler at every capture boundary; a log event arriving mid-swap
# made OTP remove it as a failing handler, and Logger.flush/0 then raised
# {:not_found, :default} in every later capture_log (694 failures on PR #59's CI).
# capture_log works through its own handler, so tests still see their logs.
config :logger, :default_handler, false
