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

  describe "create_tables/1" do
    test "defaults to :normandy_memory_documents with :disc_copies, and is idempotent" do
      on_exit(fn ->
        :mnesia.stop()
        :mnesia.delete_schema([node()])
      end)

      assert :ok = MnesiaStore.create_tables()
      assert :ok = MnesiaStore.create_tables()

      assert :normandy_memory_documents in :mnesia.system_info(:tables)
      assert :mnesia.table_info(:normandy_memory_documents, :disc_copies) == [node()]
      assert :mnesia.table_info(:normandy_memory_documents, :ram_copies) == []
      assert :mnesia.table_info(:normandy_memory_documents, :attributes) == [:namespace, :docs]

      # usable as a store handle
      assert {:ok, 1} =
               MnesiaStore.put(:normandy_memory_documents, "ns", "/memories/a", "x", :new)
    end

    test "honours :table and :copies" do
      assert :ok = MnesiaStore.create_tables(table: :normandy_memory_custom, copies: :ram_copies)
      assert :ok = MnesiaStore.create_tables(table: :normandy_memory_custom, copies: :ram_copies)

      assert :mnesia.table_info(:normandy_memory_custom, :ram_copies) == [node()]
      assert :mnesia.table_info(:normandy_memory_custom, :disc_copies) == []
      refute :normandy_memory_documents in :mnesia.system_info(:tables)
    end
  end
end
