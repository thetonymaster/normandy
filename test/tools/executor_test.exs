defmodule NormandyTest.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.{Executor, Registry}
  alias Normandy.Tools.Examples.{Calculator, StringManipulator, ListProcessor}

  describe "Executor.execute/3" do
    test "executes tool successfully" do
      tool = %Calculator{operation: "add", a: 5, b: 3}
      registry = Registry.new([tool])

      assert {:ok, 8.0} = Executor.execute(registry, "calculator")
    end

    test "returns error for nonexistent tool" do
      registry = Registry.new()

      assert {:error, "Tool 'nonexistent' not found in registry"} =
               Executor.execute(registry, "nonexistent")
    end

    test "handles tool execution errors" do
      tool = %Calculator{operation: "divide", a: 10, b: 0}
      registry = Registry.new([tool])

      assert {:error, "Cannot divide by zero"} = Executor.execute(registry, "calculator")
    end
  end

  describe "Executor.execute_tool/2" do
    test "executes tool instance directly" do
      tool = %Calculator{operation: "multiply", a: 6, b: 7}

      assert {:ok, 42.0} = Executor.execute_tool(tool)
    end

    test "executes string manipulator tool" do
      tool = %StringManipulator{operation: "reverse", text: "hello"}

      assert {:ok, "olleh"} = Executor.execute_tool(tool)
    end

    test "executes list processor tool" do
      tool = %ListProcessor{operation: "sum", numbers: [1, 2, 3, 4, 5]}

      assert {:ok, 15} = Executor.execute_tool(tool)
    end
  end

  describe "Executor with timeout" do
    defmodule SlowTool do
      defstruct [:delay]

      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: "slow_tool"
        def tool_description(_), do: "A slow tool for testing timeouts"
        def input_schema(_), do: %{type: "object", properties: %{delay: %{type: "integer"}}}

        def run(%{delay: delay}) do
          Process.sleep(delay)
          {:ok, "completed"}
        end
      end
    end

    test "respects timeout setting" do
      tool = %SlowTool{delay: 100}

      # Should complete within timeout
      assert {:ok, "completed"} = Executor.execute_tool(tool, timeout: 200)
    end

    test "times out slow tools" do
      tool = %SlowTool{delay: 200}

      # Should timeout
      assert {:error, error} = Executor.execute_tool(tool, timeout: 50)
      assert error =~ "timeout"
    end
  end

  describe "Executor.execute_parallel/3" do
    test "executes multiple tools in parallel" do
      calc1 = %Calculator{operation: "add", a: 1, b: 2}
      calc2 = %Calculator{operation: "multiply", a: 3, b: 4}

      registry = Registry.new([calc1, calc2])

      results =
        Executor.execute_parallel(registry, [
          {"calculator", calc1},
          {"calculator", calc2}
        ])

      assert length(results) == 2
      # Both should succeed (though they're the same tool name, different instances)
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  describe "Executor.execute_sequential/3" do
    test "executes tools sequentially and returns all results" do
      calc = %Calculator{operation: "add", a: 1, b: 2}
      string = %StringManipulator{operation: "uppercase", text: "hello"}

      registry = Registry.new([calc, string])

      assert {:ok, results} =
               Executor.execute_sequential(registry, ["calculator", "string_manipulator"])

      assert length(results) == 2
      assert 3.0 in results
      assert "HELLO" in results
    end

    test "stops on first error (fail-fast)" do
      good_calc = %Calculator{operation: "add", a: 1, b: 2}
      bad_calc = %Calculator{operation: "divide", a: 10, b: 0}

      registry = Registry.new([good_calc])
      # Register bad_calc second (will be looked up by name "calculator")
      registry = Registry.register(registry, bad_calc)

      # The bad calculator will fail, stopping execution
      assert {:error, "Cannot divide by zero"} =
               Executor.execute_sequential(registry, ["calculator", "calculator"])
    end
  end

  describe "Executor error handling" do
    defmodule CrashingTool do
      defstruct []

      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: "crasher"
        def tool_description(_), do: "A tool that crashes"
        def input_schema(_), do: %{type: "object"}

        def run(_) do
          raise "Intentional crash for testing"
        end
      end
    end

    test "catches and reports tool crashes" do
      tool = %CrashingTool{}

      assert {:error, error} = Executor.execute_tool(tool)
      assert error =~ "Tool execution failed"
      assert error =~ "Intentional crash"
    end
  end

  describe "Executor OTel context propagation" do
    # `Task.async` spawns a fresh process, which gets an empty process
    # dictionary — and therefore an empty OpenTelemetry context. Without the
    # capture/restore dance in `Executor`, any span opened inside the tool's
    # `run/1` becomes a root span in a fresh trace instead of a child of the
    # caller's active span. These tests verify the propagation by setting a
    # known key in the parent's OTel context and asserting the spawned tool
    # sees it via `get_value/2`.
    defmodule CtxCapturingTool do
      defstruct [:reply_to]

      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: "ctx_capturing_tool"
        def tool_description(_), do: "Snapshots OTel ctx for the test harness"
        def input_schema(_), do: %{type: "object", properties: %{}}

        def run(%{reply_to: pid}) do
          value = OpenTelemetry.Ctx.get_value(:normandy_test_marker, :missing)
          send(pid, {:captured_marker, value})
          {:ok, :captured}
        end
      end
    end

    setup do
      # Each test attaches its own ctx and detaches in on_exit so tests don't
      # leak ctx state into each other. Tests run with `async: true` but each
      # has its own process dictionary, so isolation is per-process.
      on_exit(fn -> OpenTelemetry.Ctx.clear() end)
      :ok
    end

    test "execute_tool/2 propagates active OTel context into the spawned task" do
      marker = make_ref()
      OpenTelemetry.Ctx.set_value(:normandy_test_marker, marker)

      tool = %CtxCapturingTool{reply_to: self()}
      assert {:ok, :captured} = Executor.execute_tool(tool)

      assert_receive {:captured_marker, ^marker}, 1_000
    end

    test "execute_parallel/3 propagates active OTel context into each task" do
      marker = make_ref()
      OpenTelemetry.Ctx.set_value(:normandy_test_marker, marker)

      tool = %CtxCapturingTool{reply_to: self()}
      registry = Registry.new([tool])

      results =
        Executor.execute_parallel(registry, [
          {"ctx_capturing_tool", %{}},
          {"ctx_capturing_tool", %{}}
        ])

      assert results == [{:ok, :captured}, {:ok, :captured}]
      assert_receive {:captured_marker, ^marker}, 1_000
      assert_receive {:captured_marker, ^marker}, 1_000
    end

    test "execute_tool/2 with empty ctx still works (no-op restore)" do
      # Sanity check: with no parent ctx set, capture returns the default
      # ctx and restore is a no-op. The tool runs normally and reads `:missing`
      # because the test marker was never set.
      tool = %CtxCapturingTool{reply_to: self()}
      assert {:ok, :captured} = Executor.execute_tool(tool)

      assert_receive {:captured_marker, :missing}, 1_000
    end
  end
end
