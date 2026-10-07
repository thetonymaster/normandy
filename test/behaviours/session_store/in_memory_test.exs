defmodule Normandy.Behaviours.SessionStore.InMemoryTest do
  use ExUnit.Case, async: true

  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.InMemory,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  def stored_entry_ids(pid) do
    Agent.get(pid, fn state ->
      Enum.flat_map(state.sessions, fn {_sid, memory} -> Map.keys(memory.entries) end)
    end)
  end
end
