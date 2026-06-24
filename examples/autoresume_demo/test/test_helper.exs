{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

_ = Ecto.Adapters.Postgres.storage_up(AutoresumeDemo.Repo.config())
{:ok, _} = AutoresumeDemo.Repo.start_link()
Ecto.Migrator.run(AutoresumeDemo.Repo, :up, all: true)

ExUnit.start()
