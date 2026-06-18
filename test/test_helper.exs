# Postgres-backed tests are opt-in: run with `mix test --include postgres`.
postgres? = "--include" in System.argv() and "postgres" in System.argv()

if postgres? do
  {:ok, _} = Normandy.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, :manual)
end

ExUnit.start(exclude: [:integration, :normandy_integration, :postgres, :distributed])

if postgres?, do: ExUnit.configure(exclude: [:integration, :normandy_integration])
