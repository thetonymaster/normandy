defmodule Normandy.Behaviours.MemoryStore.PostgresTest do
  @moduledoc "Run with `mix test --include postgres`. Requires Postgres and `MIX_ENV=test mix ecto.migrate`."
  # async: false — the Postgres sandbox runs in shared mode (the contract's concurrency
  # test spawns tasks).
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Normandy.TestRepo)
    Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Postgres
end
