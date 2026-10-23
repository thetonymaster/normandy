defmodule Normandy.Behaviours.ExplicitHandlesTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.SessionRegistry
  alias Normandy.Behaviours.SessionStore

  @url "redis://localhost:6379"

  # Every case raises in option validation, before any connection opens.
  describe "Redis constructors take their handle explicitly" do
    test "SessionStore.Redis.new/1 names the missing key" do
      assert_raise ArgumentError, ~r/:namespace/, fn -> SessionStore.Redis.new(url: @url) end
      assert_raise ArgumentError, ~r/:url/, fn -> SessionStore.Redis.new(namespace: "ns") end
      assert_raise ArgumentError, ~r/:url/, fn -> SessionStore.Redis.new([]) end
    end

    test "MemoryStore.Redis.new/1 names the missing key" do
      assert_raise ArgumentError, ~r/:prefix/, fn -> MemoryStore.Redis.new(url: @url) end
      assert_raise ArgumentError, ~r/:url/, fn -> MemoryStore.Redis.new(prefix: "p") end
    end

    test "SessionRegistry.Redis.new/1 names the missing key" do
      assert_raise ArgumentError, ~r/:namespace/, fn -> SessionRegistry.Redis.new(url: @url) end
      assert_raise ArgumentError, ~r/:url/, fn -> SessionRegistry.Redis.new(namespace: "ns") end
    end
  end

  test "the Postgres stores have no default-handle constructor" do
    refute function_exported?(SessionStore.Postgres, :new, 0)
    refute function_exported?(MemoryStore.Postgres, :new, 0)
  end
end
