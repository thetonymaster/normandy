defmodule Normandy.Behaviours.SessionStore.PostgresTest do
  @moduledoc """
  Run with: `mix test test/behaviours/session_store/postgres_test.exs --include postgres`
  Requires a reachable Postgres (see config/test.exs).
  """
  use ExUnit.Case, async: true
  @moduletag :postgres

  alias Normandy.Behaviours.SessionStore.Postgres
  alias Normandy.Components.AgentMemory.Entry

  defp entry(role, content), do: %Entry{turn_id: "t", role: role, content: content}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
  end

  test "new/0 returns the configured repo handle and the behaviour is implemented" do
    assert Postgres.new() == Normandy.TestRepo
    behaviours = Postgres.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.SessionStore in behaviours
  end

  test "append then history is chronological" do
    {:ok, id1} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("user", "a"))
    {:ok, id2} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("assistant", "b"))
    assert is_binary(id1) and is_binary(id2)
    assert {:ok, entries} = Postgres.history(Normandy.TestRepo, "s1")
    assert Enum.map(entries, & &1.content) == ["a", "b"]
    assert Enum.map(entries, & &1.role) == ["user", "assistant"]
  end

  test "history on unknown session is empty" do
    assert {:ok, []} = Postgres.history(Normandy.TestRepo, "missing")
  end

  test "content round-trips arbitrary terms" do
    {:ok, _} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("user", %{a: [1, 2]}))
    assert {:ok, [e]} = Postgres.history(Normandy.TestRepo, "s1")
    assert e.content == %{a: [1, 2]}
  end
end
