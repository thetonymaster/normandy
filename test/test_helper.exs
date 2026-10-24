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

# Horde 0.10's DynamicSupervisorImpl logs "Starting ..." at :info in init/1 before it
# traps exits, and has no handle_info/2 clause for {:EXIT, _, _}. ExUnit's capture_log
# handler runs in the logging process and links a Task to it; a Task that exits :normal
# after the impl traps exits crashes the impl and its Horde supervisor. No handler runs
# for that line at :warning (Task 7.0e, test/agents/turn/horde_init_log_test.exs).
:ok = Logger.put_module_level(Horde.DynamicSupervisorImpl, :warning)

base_exclude = [:integration, :normandy_integration, :postgres, :distributed, :redis]
ExUnit.start(exclude: base_exclude)

# Drop a tag from the exclude list when its opt-in flag is set (mirrors the original
# postgres-only reconfigure). `:distributed` stays excluded unless `--include`d explicitly.
final_exclude =
  base_exclude
  |> then(&if(postgres?, do: List.delete(&1, :postgres), else: &1))
  |> then(&if(redis?, do: List.delete(&1, :redis), else: &1))

ExUnit.configure(exclude: final_exclude)
