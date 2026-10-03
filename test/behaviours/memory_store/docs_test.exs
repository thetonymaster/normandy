defmodule Normandy.Behaviours.MemoryStore.DocsTest do
  use ExUnit.Case, async: true
  alias Normandy.Behaviours.MemoryStore

  test "at_or_under?/2 matches on a / boundary only" do
    assert MemoryStore.at_or_under?("/memories/a", "/memories/a")
    assert MemoryStore.at_or_under?("/memories/a/b", "/memories/a")
    refute MemoryStore.at_or_under?("/memories/ab", "/memories/a")
  end

  test "reparent/3 swaps the prefix" do
    assert MemoryStore.reparent("/memories/d/e/2", "/memories/d", "/memories/z") ==
             "/memories/z/e/2"
  end

  describe "Docs (pure)" do
    alias MemoryStore.Docs

    test "put/get/delete thread the docs map and versions" do
      {{:ok, 1}, d} = Docs.put(%{}, "/memories/a", "x", :new)
      assert {{:error, :conflict}, ^d} = Docs.put(d, "/memories/a", "y", :new)
      {{:ok, 2}, d} = Docs.put(d, "/memories/a", "y", 1)
      assert {:ok, %{content: "y", version: 2}} = Docs.get(d, "/memories/a")
      assert {{:error, :conflict}, ^d} = Docs.delete(d, "/memories/a", 1)
      assert {:ok, %{}} = Docs.delete(d, "/memories/a", 2)
      assert {:not_found, %{}} = Docs.delete(%{}, "/memories/a", :any)
    end

    test "list is prefix-bounded, sorted and sized" do
      {_, d} = Docs.put(%{}, "/memories/b/1", "22", :new)
      {_, d} = Docs.put(d, "/memories/bb", "x", :new)
      assert [%{path: "/memories/b/1", size: 2}] = Docs.list(d, "/memories/b")
    end

    test "rename keeps versions and refuses an occupied target" do
      {_, d} = Docs.put(%{}, "/memories/d/1", "1", :new)
      {_, d} = Docs.put(d, "/memories/d/1", "1b", 1)
      {_, d} = Docs.put(d, "/memories/x", "x", :new)
      assert {{:error, :exists}, ^d} = Docs.rename(d, "/memories/d", "/memories/x")
      assert {{:ok, 1}, d2} = Docs.rename(d, "/memories/d", "/memories/z")
      assert {:ok, %{version: 2}} = Docs.get(d2, "/memories/z/1")
      assert {:not_found, ^d2} = Docs.rename(d2, "/memories/nope", "/memories/q")
    end

    test "delete_tree counts and keeps siblings" do
      {_, d} = Docs.put(%{}, "/memories/d/1", "1", :new)
      {_, d} = Docs.put(d, "/memories/dd", "1", :new)
      assert {{:ok, 1}, kept} = Docs.delete_tree(d, "/memories/d")
      assert Map.keys(kept) == ["/memories/dd"]
    end
  end
end
