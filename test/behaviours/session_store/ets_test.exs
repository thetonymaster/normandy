defmodule Normandy.Behaviours.SessionStore.ETSTest do
  use ExUnit.Case, async: true

  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.ETS,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.ETS

  # The table is private to its owner: read it there. :sys.replace_state/2 runs the
  # function in the owner and replies after it, so the message is already here.
  def stored_entry_ids(pid) do
    test_pid = self()

    :sys.replace_state(pid, fn table ->
      send(test_pid, {:entry_ids, :ets.select(table, [{{{:entry, :_, :"$1"}, :_}, [], [:"$1"]}])})
      table
    end)

    receive do
      {:entry_ids, ids} -> ids
    after
      0 -> raise "ETS owner did not report its entry ids"
    end
  end
end

defmodule Normandy.Behaviours.SessionStore.ETSLayoutTest do
  @moduledoc "Task 6.3b (B5): one row per entry, so an append does not copy the history."
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.ETS
  alias Normandy.Components.AgentMemory.Entry

  defp entry(content), do: %Entry{turn_id: "t", role: "user", content: content}

  # :ets.info/2 works on a private table from another process; the owner's state is the tid.
  test "an append adds one entry row; the session keeps one head row" do
    store = ETS.new()
    table = :sys.get_state(store)

    for n <- 1..5, do: {:ok, _} = ETS.append_entry(store, "s1", entry(n))

    assert :ets.info(table, :size) == 6
    assert {:ok, entries} = ETS.history(store, "s1")
    assert Enum.map(entries, & &1.content) == [1, 2, 3, 4, 5]
  end

  test "fork copies only the chain up to the fork point" do
    store = ETS.new()
    table = :sys.get_state(store)
    {:ok, _} = ETS.append_entry(store, "s1", entry("a"))
    {:ok, at} = ETS.append_entry(store, "s1", entry("b"))
    {:ok, _} = ETS.append_entry(store, "s1", entry("c"))

    {:ok, forked} = ETS.fork(store, "s1", at)

    # s1: 3 entries + head; the fork: a, b + head.
    assert :ets.info(table, :size) == 7
    assert {:ok, [%{content: "a"}, %{content: "b", id: ^at}]} = ETS.history(store, forked)
  end
end
