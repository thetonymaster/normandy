# Postgres-backed tests are opt-in. Run them with `mix test.postgres` (sets the env
# var below and `--include postgres`), or directly with
# `MIX_ENV=test mix test --include postgres` (matched via argv).
postgres? =
  System.get_env("NORMANDY_POSTGRES") == "true" or
    ("--include" in System.argv() and "postgres" in System.argv())

if postgres? do
  {:ok, _} = Normandy.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, :manual)
end

ExUnit.start(exclude: [:integration, :normandy_integration, :postgres, :distributed])

if postgres?, do: ExUnit.configure(exclude: [:integration, :normandy_integration])
