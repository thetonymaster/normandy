defmodule Normandy.Behaviours.SessionStoreRestoreMemoryTest do
  @moduledoc """
  `SessionStore.restore_memory/4`: the memory both shells rebuild from a store, and the
  one place a store's exit or raise, or a history `from_entries/1` refuses, becomes an
  error instead of a crash.
  """
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory

  # history/2 answers as the handle says.
  defmodule ScriptedStore do
    @moduledoc false
    def history({:entries, entries}, _sid), do: {:ok, entries}
    def history(:error, _sid), do: {:error, :store_down}
    def history(:exit, _sid), do: exit(:timeout)
    def history(:raise, _sid), do: raise(RuntimeError, "connection refused")
    def history(:throw, _sid), do: throw(:oops)
  end

  test "rebuilds the memory, applies the cap and returns the stored count" do
    store = InMemory.new()

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", "hi")

    for entry <- AgentMemory.entry_chain(memory), do: InMemory.append_entry(store, "s", entry)

    assert {:ok, %AgentMemory{max_messages: 7} = restored, nil} =
             SessionStore.restore_memory(InMemory, store, "s", 7)

    assert [%{role: "user", content: "hi"}] = AgentMemory.history(restored)
  end

  test "a store's own error is returned as it is" do
    assert {:error, :store_down} = SessionStore.restore_memory(ScriptedStore, :error, "s", nil)
  end

  test "an exit, a raise and a throw are errors, not crashes" do
    assert {:error, {:store_exit, :timeout}} =
             SessionStore.restore_memory(ScriptedStore, :exit, "s", nil)

    assert {:error, {:store_raised, %RuntimeError{message: "connection refused"}}} =
             SessionStore.restore_memory(ScriptedStore, :raise, "s", nil)

    assert {:error, {:store_raised, %ErlangError{original: {:nocatch, :oops}}}} =
             SessionStore.restore_memory(ScriptedStore, :throw, "s", nil)
  end

  test "a history from_entries/1 refuses is {:invalid_history, %ArgumentError{}}" do
    entry = %AgentMemory.Entry{
      id: "c1",
      turn_id: "t1",
      role: "compaction",
      content: %{version: 2, entries: []}
    }

    assert {:error, {:invalid_history, %ArgumentError{message: message}}} =
             SessionStore.restore_memory(ScriptedStore, {:entries, [entry]}, "s", nil)

    assert message =~ ~s|compaction entry "c1" has snapshot version 2|
  end
end
