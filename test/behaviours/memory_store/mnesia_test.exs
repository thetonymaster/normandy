defmodule Normandy.Behaviours.MemoryStore.MnesiaTest do
  # async: false — Mnesia is node-global state. The reset mirrors
  # test/behaviours/session_store/mnesia_test.exs (see its comment on the phantom
  # :nonode@nohost db_node).
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.MemoryStore.Mnesia, as: MnesiaStore

  setup do
    :mnesia.stop()
    :mnesia.delete_schema([node()])
    :ok = :mnesia.start()
    on_exit(fn -> :mnesia.stop() end)
  end

  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Mnesia

  test "a missing table is a backend error, not :not_found" do
    assert {:error, _} = MnesiaStore.get(:normandy_no_such_table, "ns", "/memories/a")
  end
end
