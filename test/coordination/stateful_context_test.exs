defmodule Normandy.Coordination.StatefulContextTest do
  use ExUnit.Case, async: true

  import Normandy.Test.Eventually

  alias Normandy.Coordination.StatefulContext

  describe "start_link/1" do
    test "starts a context process" do
      assert {:ok, pid} = StatefulContext.start_link()
      assert Process.alive?(pid)
    end

    test "starts a named context process" do
      # A unique name, so no other test can hold it.
      name = :"test_context_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} = StatefulContext.start_link(name: name)
      assert Process.whereis(name) != nil
    end
  end

  describe "put/3 and fetch/2" do
    setup do
      {:ok, pid} = StatefulContext.start_link()
      %{context: pid}
    end

    test "stores and retrieves values", %{context: ctx} do
      assert :ok = StatefulContext.put(ctx, "key1", "value1")
      assert {:ok, "value1"} = StatefulContext.fetch(ctx, "key1")
    end

    test "supports complex values", %{context: ctx} do
      complex_value = %{data: [1, 2, 3], nested: %{foo: "bar"}}
      assert :ok = StatefulContext.put(ctx, "complex", complex_value)
      assert {:ok, ^complex_value} = StatefulContext.fetch(ctx, "complex")
    end

    test "supports namespaced keys", %{context: ctx} do
      assert :ok = StatefulContext.put(ctx, {"agent_1", "status"}, "active")
      assert {:ok, "active"} = StatefulContext.fetch(ctx, {"agent_1", "status"})
    end

    test "returns error for missing keys", %{context: ctx} do
      assert :error = StatefulContext.fetch(ctx, "missing")
    end

    test "get/3 returns default for missing keys", %{context: ctx} do
      assert "default" = StatefulContext.get(ctx, "missing", "default")
    end

    test "overwrites existing values", %{context: ctx} do
      :ok = StatefulContext.put(ctx, "key", "value1")
      :ok = StatefulContext.put(ctx, "key", "value2")
      assert {:ok, "value2"} = StatefulContext.fetch(ctx, "key")
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes" do
      {:ok, ctx} = StatefulContext.start_link()

      # Start multiple tasks that write concurrently
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            StatefulContext.put(ctx, "key_#{i}", "value_#{i}")
          end)
        end

      # Wait for all writes
      Task.await_many(tasks)

      # Verify all values are present
      for i <- 1..50 do
        expected_value = "value_#{i}"
        assert {:ok, ^expected_value} = StatefulContext.fetch(ctx, "key_#{i}")
      end
    end

    test "concurrent reads are fast (no GenServer bottleneck)" do
      {:ok, ctx} = StatefulContext.start_link()
      StatefulContext.put(ctx, "shared_key", "shared_value")

      # Multiple concurrent readers
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            StatefulContext.fetch(ctx, "shared_key")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == {:ok, "shared_value"}))
    end
  end

  describe "has_key?/2" do
    setup do
      {:ok, pid} = StatefulContext.start_link()
      %{context: pid}
    end

    test "returns true for existing keys", %{context: ctx} do
      StatefulContext.put(ctx, "key", "value")
      assert StatefulContext.has_key?(ctx, "key") == true
    end

    test "returns false for missing keys", %{context: ctx} do
      assert StatefulContext.has_key?(ctx, "missing") == false
    end

    test "works with namespaced keys", %{context: ctx} do
      StatefulContext.put(ctx, {"ns", "key"}, "value")
      assert StatefulContext.has_key?(ctx, {"ns", "key"}) == true
    end
  end

  describe "delete/2" do
    setup do
      {:ok, pid} = StatefulContext.start_link()
      %{context: pid}
    end

    test "removes keys", %{context: ctx} do
      StatefulContext.put(ctx, "key", "value")
      assert :ok = StatefulContext.delete(ctx, "key")
      assert :error = StatefulContext.fetch(ctx, "key")
    end

    test "returns ok even for missing keys", %{context: ctx} do
      assert :ok = StatefulContext.delete(ctx, "nonexistent")
    end
  end

  describe "keys/1" do
    setup do
      {:ok, pid} = StatefulContext.start_link()
      %{context: pid}
    end

    test "returns empty list for empty context", %{context: ctx} do
      assert StatefulContext.keys(ctx) == []
    end

    test "returns all keys", %{context: ctx} do
      StatefulContext.put(ctx, "key1", "value1")
      StatefulContext.put(ctx, "key2", "value2")
      StatefulContext.put(ctx, {"ns", "key3"}, "value3")

      keys = StatefulContext.keys(ctx)
      assert length(keys) == 3
      assert "key1" in keys
      assert "key2" in keys
      assert "ns:key3" in keys
    end
  end

  describe "update/4" do
    setup do
      {:ok, pid} = StatefulContext.start_link()
      %{context: pid}
    end

    test "updates existing values", %{context: ctx} do
      StatefulContext.put(ctx, "counter", 1)
      :ok = StatefulContext.update(ctx, "counter", 0, fn count -> count + 1 end)
      assert {:ok, 2} = StatefulContext.fetch(ctx, "counter")
    end

    test "uses initial value for missing keys", %{context: ctx} do
      :ok = StatefulContext.update(ctx, "new_counter", 10, fn count -> count + 5 end)
      assert {:ok, 15} = StatefulContext.fetch(ctx, "new_counter")
    end

    test "handles complex updates", %{context: ctx} do
      StatefulContext.put(ctx, "list", [1, 2, 3])
      :ok = StatefulContext.update(ctx, "list", [], fn list -> list ++ [4] end)
      assert {:ok, [1, 2, 3, 4]} = StatefulContext.fetch(ctx, "list")
    end

    test "a read during a slow update does not wait for it", %{context: ctx} do
      StatefulContext.put(ctx, "k", 1)

      updater =
        Task.async(fn ->
          StatefulContext.update(ctx, "slow", 0, fn n ->
            Process.sleep(500)
            n + 1
          end)
        end)

      Process.sleep(20)

      {elapsed_us, result} = :timer.tc(fn -> StatefulContext.fetch(ctx, "k") end)

      assert result == {:ok, 1}
      assert elapsed_us < 50_000, "fetch took #{div(elapsed_us, 1000)} ms behind an update"
      assert :ok = Task.await(updater)
      assert {:ok, 1} = StatefulContext.fetch(ctx, "slow")
    end

    test "concurrent updates of one key are not lost", %{context: ctx} do
      1..50
      |> Task.async_stream(fn _ ->
        StatefulContext.update(ctx, "n", 0, fn n ->
          Process.sleep(1)
          n + 1
        end)
      end)
      |> Stream.run()

      assert {:ok, 50} = StatefulContext.fetch(ctx, "n")
    end

    test "an update that keeps losing the race still finishes", %{context: ctx} do
      writer =
        spawn_link(fn ->
          Stream.repeatedly(fn ->
            StatefulContext.put(ctx, "hot", System.unique_integer())
            Process.sleep(1)
          end)
          |> Stream.run()
        end)

      Process.sleep(10)

      task =
        Task.async(fn ->
          StatefulContext.update(ctx, "hot", 0, fn _ ->
            Process.sleep(30)
            :updated
          end)
        end)

      assert :ok = Task.await(task, 5_000)
      Process.unlink(writer)
      Process.exit(writer, :kill)
    end

    test "a function that raises raises in the caller and leaves the context running",
         %{context: ctx} do
      StatefulContext.put(ctx, "k", 1)

      assert_raise RuntimeError, "boom", fn ->
        StatefulContext.update(ctx, "k", 0, fn _ -> raise "boom" end)
      end

      assert {:ok, 1} = StatefulContext.fetch(ctx, "k")
    end
  end

  describe "to_map/1" do
    setup do
      {:ok, pid} = StatefulContext.start_link()
      %{context: pid}
    end

    test "returns empty map for empty context", %{context: ctx} do
      assert StatefulContext.to_map(ctx) == %{}
    end

    test "returns all data as map", %{context: ctx} do
      StatefulContext.put(ctx, "key1", "value1")
      StatefulContext.put(ctx, "key2", "value2")
      StatefulContext.put(ctx, {"ns", "key3"}, "value3")

      data = StatefulContext.to_map(ctx)
      assert data["key1"] == "value1"
      assert data["key2"] == "value2"
      assert data["ns:key3"] == "value3"
    end
  end

  describe "subscribe/2 and notifications" do
    setup do
      {:ok, pid} = StatefulContext.start_link(notify_on_change: true)
      %{context: pid}
    end

    test "sends notifications on put", %{context: ctx} do
      :ok = StatefulContext.subscribe(ctx, self())

      StatefulContext.put(ctx, "key", "value1")

      assert_receive {:context_changed, "key", {:error, :not_found}, "value1"}
    end

    test "sends notifications on update", %{context: ctx} do
      :ok = StatefulContext.subscribe(ctx, self())
      StatefulContext.put(ctx, "key", "old_value")

      # Clear initial notification
      receive do
        {:context_changed, _, _, _} -> :ok
      end

      StatefulContext.put(ctx, "key", "new_value")

      assert_receive {:context_changed, "key", {:ok, "old_value"}, "new_value"}
    end

    test "sends notifications on delete", %{context: ctx} do
      :ok = StatefulContext.subscribe(ctx, self())
      StatefulContext.put(ctx, "key", "value")

      # Clear initial notification
      receive do
        {:context_changed, _, _, _} -> :ok
      end

      StatefulContext.delete(ctx, "key")

      assert_receive {:context_changed, "key", {:ok, "value"}, :deleted}
    end

    test "supports multiple subscribers", %{context: ctx} do
      pid1 = spawn(fn -> receive do: ({:context_changed, _, _, _} -> :ok) end)
      pid2 = spawn(fn -> receive do: ({:context_changed, _, _, _} -> :ok) end)

      StatefulContext.subscribe(ctx, pid1)
      StatefulContext.subscribe(ctx, pid2)
      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      StatefulContext.put(ctx, "key", "value")

      # Each subscriber exits once it receives the notification.
      assert_receive {:DOWN, ^ref1, :process, ^pid1, :normal}
      assert_receive {:DOWN, ^ref2, :process, ^pid2, :normal}
    end

    test "unsubscribe stops notifications", %{context: ctx} do
      :ok = StatefulContext.subscribe(ctx, self())
      :ok = StatefulContext.unsubscribe(ctx, self())

      StatefulContext.put(ctx, "key", "value")

      refute_receive {:context_changed, _, _, _}, 100
    end
  end

  describe "get_table/1" do
    test "returns ETS table reference" do
      {:ok, ctx} = StatefulContext.start_link()
      StatefulContext.put(ctx, "key", "value")

      table = StatefulContext.get_table(ctx)
      assert is_reference(table) or is_atom(table)

      # Direct ETS access should work
      assert [{_key, "value"}] = :ets.lookup(table, "key")
    end
  end

  describe "the table is :protected" do
    test "another process can read it but not write it" do
      {:ok, ctx} = StatefulContext.start_link()
      :ok = StatefulContext.put(ctx, "key", "value")
      table = StatefulContext.get_table(ctx)

      assert [{"key", "value"}] = :ets.lookup(table, "key")
      assert_raise ArgumentError, fn -> :ets.insert(table, {"key", "forged"}) end
      assert StatefulContext.fetch(ctx, "key") == {:ok, "value"}
    end
  end

  describe "process termination" do
    test "cleans up ETS table on termination" do
      {:ok, ctx} = StatefulContext.start_link()
      table = StatefulContext.get_table(ctx)

      StatefulContext.put(ctx, "key", "value")
      assert :ets.info(table) != :undefined

      # Stop the process; its table goes with it.
      GenServer.stop(ctx)

      assert wait_until(fn -> :ets.info(table) == :undefined end)
    end
  end
end
