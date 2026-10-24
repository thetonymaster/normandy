defmodule Normandy.Behaviours.SessionStore.PostgresConcurrentDeleteTest do
  @moduledoc """
  Two sessions forked from one ancestor, deleted at the same time on two connections:
  the entries only the two of them reached must go. Each delete saw the other's head
  under READ COMMITTED and kept them; the lock on the tree's root serialises the deletes.

  The sandbox runs every test in one connection's transaction, so each process here
  checks out a connection of its own outside the sandbox (`sandbox: false`) and commits
  for real; the session ids are unique and the test deletes what it wrote.
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Normandy.Behaviours.SessionStore.Postgres
  alias Normandy.Components.AgentMemory.Entry

  @rounds 25

  defp entry(content), do: %Entry{id: UUID.uuid4(), turn_id: "t", role: "user", content: content}

  # Runs `fun` on a connection of this process's own, outside the sandbox.
  defp live(fun) do
    :ok = Sandbox.checkout(Normandy.TestRepo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Normandy.TestRepo)
    end
  end

  defp stored?(ids) do
    live(fn ->
      %{rows: rows} =
        SQL.query!(
          Normandy.TestRepo,
          "SELECT count(*) FROM normandy_session_entries WHERE id = ANY($1::uuid[])",
          [Enum.map(ids, &Ecto.UUID.dump!/1)]
        )

      rows
    end)
  end

  test "concurrent deletes of two forks of one ancestor leave none of their entries" do
    for round <- 1..@rounds do
      base = "cdel-#{System.unique_integer([:positive])}-#{round}"

      ids =
        live(fn ->
          {:ok, x} = Postgres.append_entry(Normandy.TestRepo, base, entry("x"))
          {:ok, a} = Postgres.fork(Normandy.TestRepo, base, x)
          {:ok, b} = Postgres.fork(Normandy.TestRepo, base, x)
          :ok = Postgres.delete_session(Normandy.TestRepo, base)
          {:ok, a_own} = Postgres.append_entry(Normandy.TestRepo, a, entry("a"))
          {:ok, b_own} = Postgres.append_entry(Normandy.TestRepo, b, entry("b"))
          %{x: x, sessions: [a, b], own: [a_own, b_own]}
        end)

      ids.sessions
      |> Enum.map(fn sid ->
        Task.async(fn ->
          live(fn -> Postgres.delete_session(Normandy.TestRepo, sid) end)
        end)
      end)
      |> Task.await_many(5_000)
      |> Enum.each(&assert(&1 == :ok))

      assert stored?([ids.x | ids.own]) == [[0]], "round #{round} kept shared entries"
    end
  end
end
