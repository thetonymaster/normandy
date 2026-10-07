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
      assert :mnesia.table_info(:normandy_memory_documents, :attributes) == [:key, :value]
      assert :mnesia.table_info(:normandy_memory_documents, :type) == :ordered_set

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

    test "refuses an existing table of another layout, naming both" do
      {:atomic, :ok} =
        :mnesia.create_table(:normandy_memory_old,
          attributes: [:namespace, :docs],
          ram_copies: [node()]
        )

      assert_raise RuntimeError,
                   "Mnesia table :normandy_memory_old exists with attributes " <>
                     "[:namespace, :docs] and type :set; expected [:key, :value] and " <>
                     ":ordered_set. Delete the table or use another table name.",
                   fn ->
                     MnesiaStore.create_tables(table: :normandy_memory_old, copies: :ram_copies)
                   end
    end
  end

  describe "row layout (PERF-10)" do
    test "one record per document plus one totals record per namespace" do
      table = MnesiaStore.new()

      for i <- 1..5, do: {:ok, 1} = MnesiaStore.put(table, "ns", "/memories/f#{i}", "abc", :new)

      assert :mnesia.table_info(table, :size) == 6

      assert [{^table, {"ns", "/memories/f3"}, %{content: "abc", version: 1}}] =
               :mnesia.dirty_read(table, {"ns", "/memories/f3"})

      assert :mnesia.dirty_read(table, {"ns", 0}) == [{table, {"ns", 0}, {15, 5}}]

      assert {:ok, 5} = MnesiaStore.delete_tree(table, "ns", "/memories")
      assert :mnesia.table_info(table, :size) == 0
    end
  end
end
