import Config

config :autoresume_demo, AutoresumeDemo.Repo,
  database: System.get_env("POSTGRES_DB", "autoresume_demo_test"),
  pool_size: 10

config :autoresume_demo, role: :test
config :autoresume_demo, sim_step_delay_ms: 0
config :logger, level: :warning
