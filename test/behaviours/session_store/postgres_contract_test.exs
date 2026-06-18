defmodule Normandy.Behaviours.SessionStore.PostgresContractTest do
  @moduledoc "Run with `mix test --include postgres`. Requires Postgres."
  use ExUnit.Case, async: false
  @moduletag :postgres

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, {:shared, self()})

    # Start each contract test from an empty sessions table. list_resumable/1 is a
    # GLOBAL query, so rows committed by non-sandboxed suites (e.g. the distributed
    # handoff tests, which write with sandbox: false) would otherwise leak into it.
    # This delete runs inside the sandbox transaction and is rolled back at test end.
    Normandy.TestRepo.delete_all(Normandy.Behaviours.SessionStore.Postgres.Schemas.Session)
    :ok
  end

  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Postgres
end
