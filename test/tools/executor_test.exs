defmodule NormandyTest.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.{Executor, Registry}
  alias Normandy.Tools.Examples.{Calculator, StringManipulator, ListProcessor}

  describe "Executor.execute/3" do
    test "executes tool successfully" do
      tool = %Calculator{operation: "add", a: 5, b: 3}
      registry = Registry.new([tool])

      assert {:ok, 8} = Executor.execute(registry, "calculator")
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

      assert {:ok, 42} = Executor.execute_tool(tool)
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
      assert 3 in results
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
end
