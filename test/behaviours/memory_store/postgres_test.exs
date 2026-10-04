defmodule Normandy.Behaviours.MemoryStore.PostgresTest do
  @moduledoc "Run with `mix test --include postgres`. Requires Postgres and `MIX_ENV=test mix ecto.migrate`."
  # async: false — the Postgres sandbox runs in shared mode (the contract's concurrency
  # test spawns tasks).
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Normandy.TestRepo)
    # Shared mode serializes every query on one connection, so the concurrency contract
    # tests compare-and-set conflicts but not real row-lock contention between
    # transactions (lock ordering and deadlocks are not exercised here).
    Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  # Delegates to the real repo, but just before the rename's UPDATE it inserts the
  # destination row on the same connection: the unique-key race, made deterministic.
  defmodule RacingRepo do
    def transaction(fun), do: Normandy.TestRepo.transaction(fun)
    def query(sql, params), do: Normandy.TestRepo.query(sql, params)

    def query!("UPDATE" <> _ = sql, [ns, _from, to, _moving] = params) do
      Normandy.TestRepo.query!(
        "INSERT INTO normandy_memory_documents (namespace, path, content, version, updated_at) VALUES ($1, $2, 'raced', 1, now())",
        [ns, to]
      )

      Normandy.TestRepo.query!(sql, params)
    end

    def query!(sql, params), do: Normandy.TestRepo.query!(sql, params)
  end

  defmodule MissingTableRepo do
    # Every statement fails server-side (Postgrex.Error), as when the migration never ran.
    def query(_sql, _params), do: Normandy.TestRepo.query("SELECT 1 FROM no_such_table", [])
    def query!(_sql, _params), do: Normandy.TestRepo.query!("SELECT 1 FROM no_such_table", [])
    def transaction(fun), do: Normandy.TestRepo.transaction(fun)
  end

  alias Normandy.Behaviours.MemoryStore.Postgres

  test "a rename that loses the race for its destination is {:error, :exists} and rolls back" do
    repo = Normandy.TestRepo
    ns = "race-#{System.unique_integer([:positive])}"
    {:ok, 1} = Postgres.put(repo, ns, "a", "src", :new)

    assert {:error, :exists} = Postgres.rename(RacingRepo, ns, "a", "b")
    assert {:ok, %{content: "src"}} = Postgres.get(repo, ns, "a")
    # The injected destination row lived in the rolled-back transaction too.
    assert :not_found = Postgres.get(repo, ns, "b")
  end

  defmodule ConnectionLostRepo do
    # Every statement raises DBConnection.ConnectionError, as when the pool has no live
    # connection: the other half of backend/1's rescue.
    def query(_sql, _params), do: raise(DBConnection.ConnectionError, "connection lost")
    def query!(_sql, _params), do: raise(DBConnection.ConnectionError, "connection lost")
    def transaction(_fun), do: raise(DBConnection.ConnectionError, "connection lost")
  end

  defp backend_calls(repo) do
    [
      list: fn -> Postgres.list(repo, "n", "") end,
      get: fn -> Postgres.get(repo, "n", "a") end,
      put_new: fn -> Postgres.put(repo, "n", "a", "x", :new) end,
      put_any: fn -> Postgres.put(repo, "n", "a", "x", :any) end,
      put_cas: fn -> Postgres.put(repo, "n", "a", "x", 1) end,
      delete_any: fn -> Postgres.delete(repo, "n", "a", :any) end,
      delete_cas: fn -> Postgres.delete(repo, "n", "a", 1) end,
      delete_tree: fn -> Postgres.delete_tree(repo, "n", "a") end,
      rename: fn -> Postgres.rename(repo, "n", "a", "b") end,
      delete_namespace: fn -> Postgres.delete_namespace(repo, "n") end
    ]
  end

  test "a failing backend is {:error, _}, never :not_found" do
    for {name, call} <- backend_calls(MissingTableRepo) do
      assert {:error, %Postgrex.Error{}} = call.(), "#{name} did not report the backend error"
    end
  end

  test "a lost connection is {:error, %DBConnection.ConnectionError{}}, never :not_found" do
    for {name, call} <- backend_calls(ConnectionLostRepo) do
      assert {:error, %DBConnection.ConnectionError{message: "connection lost"}} = call.(),
             "#{name} did not report the connection error"
    end
  end

  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Postgres
end
