{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

_ = Ecto.Adapters.Postgres.storage_up(AutoresumeDemo.Repo.config())
{:ok, _} = AutoresumeDemo.Repo.start_link()
Ecto.Migrator.run(AutoresumeDemo.Repo, :up, all: true)

# The distributed handoff test requires a named, distributed VM (so :peer can
# start worker nodes). Exclude it from a normal `mix test` run; opt in with
# `mix test --only distributed` on a distributed VM (elixir --sname ... --cookie ...).
ExUnit.start(exclude: [:distributed])
