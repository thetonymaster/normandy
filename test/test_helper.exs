# Postgres-backed tests are opt-in. Run them with `mix test.postgres`.
postgres? =
  System.get_env("NORMANDY_POSTGRES") == "true" or
    ("--include" in System.argv() and "postgres" in System.argv())

# Redis-backed tests are opt-in. Run them with `mix test.redis` (needs a reachable Redis).
redis? =
  System.get_env("NORMANDY_REDIS") == "true" or
    ("--include" in System.argv() and "redis" in System.argv())

if postgres? do
  {:ok, _} = Normandy.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, :manual)
end

base_exclude = [:integration, :normandy_integration, :postgres, :distributed, :redis]
ExUnit.start(exclude: base_exclude)

# Drop a tag from the exclude list when its opt-in flag is set (mirrors the original
# postgres-only reconfigure). `:distributed` stays excluded unless `--include`d explicitly.
final_exclude =
  base_exclude
  |> then(&if(postgres?, do: List.delete(&1, :postgres), else: &1))
  |> then(&if(redis?, do: List.delete(&1, :redis), else: &1))

ExUnit.configure(exclude: final_exclude)
