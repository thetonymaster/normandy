defmodule Normandy.Behaviours.SessionStore.PostgresContractTest do
  @moduledoc "Run with `mix test --include postgres`. Requires Postgres."
  # async: false — the Postgres sandbox runs in shared mode (one connection for every process).
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Normandy.TestRepo)
    Sandbox.mode(Normandy.TestRepo, {:shared, self()})

    # Start each contract test from an empty sessions table. list_resumable/1 is a
    # GLOBAL query, so rows committed by non-sandboxed suites (e.g. the distributed
    # handoff tests, which write with sandbox: false) would otherwise leak into it.
    # This delete runs inside the sandbox transaction and is rolled back at test end.
    Normandy.TestRepo.delete_all(Normandy.Behaviours.SessionStore.Postgres.Schemas.Session)
    :ok
  end

  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.Postgres,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  def stored_entry_ids(repo) do
    %{rows: rows} = repo.query!("SELECT id FROM normandy_session_entries")
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end
end
