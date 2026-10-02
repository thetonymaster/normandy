defmodule Normandy.Behaviours.SessionStore.PostgresBackendErrorTest do
  # No :postgres tag: the repo is a stand-in whose every call fails the way Ecto
  # does when the database is unreachable.
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.Postgres
  alias Normandy.Components.AgentMemory.Entry

  defmodule DownRepo do
    defp down!, do: raise(DBConnection.ConnectionError, "connection not available")

    def get(_schema, _id, _opts \\ []), do: down!()
    def all(_query, _opts \\ []), do: down!()
    def one(_query, _opts \\ []), do: down!()
    def insert(_struct, _opts \\ []), do: down!()
    def insert!(_struct, _opts \\ []), do: down!()
    def update(_changeset, _opts \\ []), do: down!()
    def transaction(_fun, _opts \\ []), do: down!()
  end

  test "every callback reports an unreachable database as {:error, reason}" do
    entry = %Entry{role: "user", content: "hi"}

    for {name, call} <- [
          append_entry: fn -> Postgres.append_entry(DownRepo, "s1", entry) end,
          history: fn -> Postgres.history(DownRepo, "s1") end,
          fork: fn -> Postgres.fork(DownRepo, "s1", Ecto.UUID.generate()) end,
          save_turn_state: fn -> Postgres.save_turn_state(DownRepo, "s1", :ts) end,
          load_turn_state: fn -> Postgres.load_turn_state(DownRepo, "s1") end,
          save_config_template: fn -> Postgres.save_config_template(DownRepo, "s1", %{}) end,
          list_resumable: fn -> Postgres.list_resumable(DownRepo) end,
          load_config_template: fn -> Postgres.load_config_template(DownRepo, "s1") end
        ] do
      assert {:error, %DBConnection.ConnectionError{}} = call.(), "#{name} did not return it"
    end
  end
end
