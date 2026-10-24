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

  test "check_limits/3: bytes first, then documents; a write that does not grow passes" do
    lim = [max_bytes: 10, max_documents: 2]
    assert MemoryStore.check_limits(lim, {5, 1}, {10, 2}) == :ok

    assert MemoryStore.check_limits(lim, {5, 1}, {11, 3}) ==
             {:error, {:namespace_full, :bytes, 11}}

    assert MemoryStore.check_limits(lim, {5, 1}, {6, 3}) ==
             {:error, {:namespace_full, :documents, 3}}

    assert MemoryStore.check_limits(lim, {20, 5}, {19, 5}) == :ok

    assert MemoryStore.check_limits(lim, {20, 5}, {20, 6}) ==
             {:error, {:namespace_full, :documents, 6}}

    assert MemoryStore.check_limits([], {0, 0}, {10_000_000, 10_000}) == :ok
    assert MemoryStore.check_limits([max_bytes: nil, max_documents: nil], {0, 0}, {9, 9}) == :ok
  end

  describe "Docs (pure)" do
    alias MemoryStore.Docs

    test "put/get/delete thread the docs map and versions" do
      {{:ok, 1}, d} = Docs.put(Docs.new(), "/memories/a", "x", :new)
      assert {{:error, :conflict}, ^d} = Docs.put(d, "/memories/a", "y", :new)
      {{:ok, 2}, d} = Docs.put(d, "/memories/a", "y", 1)
      assert {:ok, %{content: "y", version: 2}} = Docs.get(d, "/memories/a")
      assert {{:error, :conflict}, ^d} = Docs.delete(d, "/memories/a", 1)
      # compare whole values: a `%{}` pattern would match any map
      assert Docs.delete(d, "/memories/a", 2) == {:ok, Docs.new()}
      assert Docs.delete(Docs.new(), "/memories/a", :any) == {:not_found, Docs.new()}
    end

    test "list is prefix-bounded, sorted and sized" do
      {_, d} = Docs.put(Docs.new(), "/memories/b/1", "22", :new)
      {_, d} = Docs.put(d, "/memories/bb", "x", :new)
      assert [%{path: "/memories/b/1", size: 2}] = Docs.list(d, "/memories/b")
    end

    test "rename keeps versions and refuses an occupied target" do
      {_, d} = Docs.put(Docs.new(), "/memories/d/1", "1", :new)
      {_, d} = Docs.put(d, "/memories/d/1", "1b", 1)
      {_, d} = Docs.put(d, "/memories/x", "x", :new)
      assert {{:error, :exists}, ^d} = Docs.rename(d, "/memories/d", "/memories/x")
      assert {{:ok, 1}, d2} = Docs.rename(d, "/memories/d", "/memories/z")
      assert {:ok, %{version: 2}} = Docs.get(d2, "/memories/z/1")
      assert {:not_found, ^d2} = Docs.rename(d2, "/memories/nope", "/memories/q")
    end

    test "put/5 checks the namespace's totals and writes nothing when full" do
      {{:ok, 1}, d} = Docs.put(Docs.new(), "/memories/a", "12345", :new, max_bytes: 10)

      assert {{:error, {:namespace_full, :bytes, 11}}, ^d} =
               Docs.put(d, "/memories/b", "123456", :new, max_bytes: 10)

      assert {{:error, {:namespace_full, :documents, 2}}, ^d} =
               Docs.put(d, "/memories/b", "", :new, max_documents: 1)

      assert {{:ok, 2}, _d} = Docs.put(d, "/memories/a", "1234567890", :any, max_bytes: 10)
    end

    test "bytes follows every write without a recount" do
      recount = fn d ->
        d.docs |> Map.values() |> Enum.map(&byte_size(&1.content)) |> Enum.sum()
      end

      {_, d} = Docs.put(Docs.new(), "/memories/a", "12345", :new)
      {_, d} = Docs.put(d, "/memories/b/c", "日本", :new)
      assert d.bytes == 11
      {_, d} = Docs.put(d, "/memories/a", "1", :any)
      assert d.bytes == 7
      {_, d} = Docs.put(d, "/memories/x", "toolarge", :new, max_bytes: 8)
      assert d.bytes == 7
      {_, d} = Docs.rename(d, "/memories/b", "/memories/z")
      assert d.bytes == 7
      {_, d} = Docs.delete(d, "/memories/a", :any)
      assert d.bytes == 6 and d.bytes == recount.(d)
      {_, d} = Docs.delete_tree(d, "/memories/z")
      assert d == Docs.new()
    end

    test "delete_tree counts and keeps siblings" do
      {_, d} = Docs.put(Docs.new(), "/memories/d/1", "1", :new)
      {_, d} = Docs.put(d, "/memories/dd", "1", :new)
      assert {{:ok, 1}, kept} = Docs.delete_tree(d, "/memories/d")
      assert Map.keys(kept.docs) == ["/memories/dd"]
      assert kept.bytes == 1
    end
  end
end
