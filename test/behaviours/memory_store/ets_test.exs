defmodule Normandy.Behaviours.MemoryStore.ETSTest do
  use ExUnit.Case, async: true
  use Normandy.Test.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.ETS

  alias Normandy.Behaviours.MemoryStore.ETS, as: EtsMem

  describe "row layout (PERF-10)" do
    test "one row per document plus one totals row per namespace" do
      {_pid, table} = store = EtsMem.new()

      for i <- 1..5, do: {:ok, 1} = EtsMem.put(store, "ns", "/memories/f#{i}", "abc", :new)
      {:ok, 1} = EtsMem.put(store, "other", "/memories/x", "z", :new)

      assert :ets.info(table, :type) == :ordered_set
      assert :ets.info(table, :size) == 5 + 1 + 1 + 1

      assert [{{"ns", "/memories/f3"}, %{content: "abc", version: 1}}] =
               :ets.lookup(table, {"ns", "/memories/f3"})

      assert :ets.lookup(table, {"ns", 0}) == [{{"ns", 0}, {15, 5}}]
      assert :ets.lookup(table, {"other", 0}) == [{{"other", 0}, {1, 1}}]
    end

    test "an overwrite rewrites its row and the totals row only" do
      {_pid, table} = store = EtsMem.new()
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/a", "12345", :new)
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/b", "1", :new)
      {:ok, 2} = EtsMem.put(store, "ns", "/memories/a", "12", 1)

      assert :ets.info(table, :size) == 3
      assert :ets.lookup(table, {"ns", 0}) == [{{"ns", 0}, {3, 2}}]
    end

    test "emptying a namespace removes its totals row" do
      {_pid, table} = store = EtsMem.new()
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/a", "x", :new)
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/d/b", "y", :new)

      assert :ok = EtsMem.delete(store, "ns", "/memories/a", :any)
      assert {:ok, 1} = EtsMem.delete_tree(store, "ns", "/memories/d")
      assert :ets.info(table, :size) == 0

      {:ok, 1} = EtsMem.put(store, "ns", "/memories/a", "x", :new)
      assert :ok = EtsMem.delete_namespace(store, "ns")
      assert :ets.info(table, :size) == 0
    end
  end
end
