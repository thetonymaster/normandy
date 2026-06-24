import Config

config :autoresume_demo, ecto_repos: [AutoresumeDemo.Repo]

config :autoresume_demo, AutoresumeDemo.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: System.get_env("POSTGRES_DB", "autoresume_demo"),
  pool_size: 10

config :autoresume_demo,
  role: String.to_atom(System.get_env("DEMO_ROLE", "observer")),
  demo_mode: String.to_atom(System.get_env("DEMO_MODE", "real")),
  demo_model: System.get_env("DEMO_MODEL", "claude-3-5-sonnet-20241022"),
  dashboard_port: String.to_integer(System.get_env("DASHBOARD_PORT", "4000")),
  worker_node_count: String.to_integer(System.get_env("WORKER_NODES", "3")),
  sim_step_delay_ms: String.to_integer(System.get_env("SIM_STEP_DELAY_MS", "1500"))
