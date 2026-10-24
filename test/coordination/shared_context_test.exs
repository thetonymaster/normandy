defmodule Normandy.Coordination.SharedContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Coordination.SharedContext

  test "put/fetch round-trips a value; a missing key is :error" do
    ctx = SharedContext.put(SharedContext.new(), "k", 1)

    assert {:ok, 1} = SharedContext.fetch(ctx, "k")
    assert :error = SharedContext.fetch(ctx, "missing")
  end

  test "get/3 returns the default only when the key is missing" do
    ctx = SharedContext.put(SharedContext.new(), "k", nil)

    assert SharedContext.get(ctx, "k", :default) == nil
    assert SharedContext.get(ctx, "missing", :default) == :default
  end

  test "a {namespace, key} key is stored as \"namespace:key\"" do
    ctx = SharedContext.put(SharedContext.new(), {"agent_1", "status"}, "active")

    assert SharedContext.keys(ctx) == ["agent_1:status"]
    assert {:ok, "active"} = SharedContext.fetch(ctx, "agent_1:status")
    assert SharedContext.has_key?(ctx, {"agent_1", "status"})
  end

  test "delete removes a key" do
    ctx = SharedContext.new() |> SharedContext.put("k", 1) |> SharedContext.delete("k")

    refute SharedContext.has_key?(ctx, "k")
  end

  test "update starts from the initial value, then applies the function to the stored one" do
    inc = &(&1 + 1)
    ctx = SharedContext.update(SharedContext.new(), "n", 0, inc)
    assert {:ok, 1} = SharedContext.fetch(ctx, "n")

    ctx = SharedContext.update(ctx, "n", 0, inc)
    assert {:ok, 2} = SharedContext.fetch(ctx, "n")
  end

  test "merge takes the second context's value on a key conflict" do
    left = SharedContext.new() |> SharedContext.put("a", 1) |> SharedContext.put("b", 1)
    right = SharedContext.put(SharedContext.new(), "b", 2)

    assert SharedContext.to_map(SharedContext.merge(left, right)) == %{"a" => 1, "b" => 2}
  end

  test "writes move updated_at forward and keep created_at" do
    ctx = SharedContext.new()
    ctx = %{ctx | metadata: %{created_at: 1, updated_at: 1}}

    updated = SharedContext.put(ctx, "k", 1)

    assert updated.metadata.created_at == 1
    assert updated.metadata.updated_at > 1
  end
end
