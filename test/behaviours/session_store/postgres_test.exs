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

  test "fork yields the ancestor chain and isolates appends" do
    {:ok, _} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("user", "a"))
    {:ok, at} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("assistant", "b"))
    {:ok, _} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("user", "c"))

    {:ok, forked} = Postgres.fork(Normandy.TestRepo, "s1", at)
    assert {:ok, fe} = Postgres.history(Normandy.TestRepo, forked)
    assert Enum.map(fe, & &1.content) == ["a", "b"]

    {:ok, _} = Postgres.append_entry(Normandy.TestRepo, forked, entry("assistant", "d"))
    assert {:ok, oe} = Postgres.history(Normandy.TestRepo, "s1")
    assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
    assert {:ok, fe2} = Postgres.history(Normandy.TestRepo, forked)
    assert Enum.map(fe2, & &1.content) == ["a", "b", "d"]
  end

  test "fork on unknown entry errors" do
    {:ok, _} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("user", "a"))
    assert {:error, _} = Postgres.fork(Normandy.TestRepo, "s1", Ecto.UUID.generate())
  end

  test "fork on unknown session errors" do
    assert {:error, _} = Postgres.fork(Normandy.TestRepo, "nope", Ecto.UUID.generate())
  end

  test "turn state round-trips an opaque term; missing is :error" do
    term = {:turn, %{step: 3, calls: [:a, :b]}, "opaque"}
    assert :ok = Postgres.save_turn_state(Normandy.TestRepo, "s1", term)
    assert {:ok, ^term} = Postgres.load_turn_state(Normandy.TestRepo, "s1")
    assert :error = Postgres.load_turn_state(Normandy.TestRepo, "never")
  end

  test "save_turn_state on a session created by appends keeps both" do
    {:ok, _} = Postgres.append_entry(Normandy.TestRepo, "s1", entry("user", "a"))
    assert :ok = Postgres.save_turn_state(Normandy.TestRepo, "s1", %{x: 1})
    assert {:ok, %{x: 1}} = Postgres.load_turn_state(Normandy.TestRepo, "s1")
    assert {:ok, [e]} = Postgres.history(Normandy.TestRepo, "s1")
    assert e.content == "a"
  end
end
