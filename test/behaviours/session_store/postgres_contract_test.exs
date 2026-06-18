defmodule Normandy.Behaviours.SessionStore.PostgresContractTest do
  @moduledoc "Run with `mix test --include postgres`. Requires Postgres."
  use ExUnit.Case, async: false
  @moduletag :postgres

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Postgres
end
