defmodule NormandyTest.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.{Context, Executor}
  alias Normandy.Tools.Examples.{Calculator, ListProcessor, StringManipulator}

  defp ctx(input), do: %Context{tool_call_id: "t1", input: input}

  describe "execute_tool/2" do
    test "runs the tool with the context's input" do
      input = %Calculator.Input{operation: "multiply", a: 6, b: 7}

      assert {:ok, 42.0} = Executor.execute_tool(%Calculator{}, context: ctx(input))
    end

    test "a tool with a hand-written schema gets a string-keyed map" do
      assert {:ok, "olleh"} =
               Executor.execute_tool(%StringManipulator{},
                 context: ctx(%{"operation" => "reverse", "text" => "hello"})
               )

      assert {:ok, 15} =
               Executor.execute_tool(%ListProcessor{},
                 context: ctx(%{"operation" => "sum", "numbers" => [1, 2, 3, 4, 5]})
               )
    end

    test "the tool's own error comes back as is" do
      input = %Calculator.Input{operation: "divide", a: 10, b: 0}

      assert {:error, "Cannot divide by zero"} =
               Executor.execute_tool(%Calculator{}, context: ctx(input))
    end
  end

  describe "timeout" do
    defmodule SlowTool do
      @moduledoc false
      use Normandy.Tool, name: "slow_tool", description: "sleeps for its input's delay"

      # A struct field named :timeout is configuration like any other; the executor
      # never reads it.
      defstruct timeout: 10_000

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{delay: %{type: "integer"}}}

      @impl Normandy.Tool
      def run(_tool, %Context{input: %{"delay" => delay}}) do
        Process.sleep(delay)
        {:ok, "completed"}
      end
    end

    test "a run within :timeout completes" do
      assert {:ok, "completed"} =
               Executor.execute_tool(%SlowTool{}, context: ctx(%{"delay" => 10}), timeout: 1_000)
    end

    test "a run past :timeout fails; the struct's :timeout field is not read" do
      assert {:error, "Tool execution timeout after 20ms"} =
               Executor.execute_tool(%SlowTool{timeout: 10_000},
                 context: ctx(%{"delay" => 1_000}),
                 timeout: 20
               )
    end

    test "without :timeout the default applies, not the struct's :timeout field" do
      assert {:ok, "completed"} =
               Executor.execute_tool(%SlowTool{timeout: 10}, context: ctx(%{"delay" => 50}))
    end

    test "the default is 30 seconds" do
      assert Executor.default_timeout() == 30_000
    end
  end

  describe "error handling" do
    defmodule CrashingTool do
      @moduledoc false
      use Normandy.Tool, name: "crasher", description: "A tool that crashes"

      defstruct []

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object"}

      @impl Normandy.Tool
      def run(_tool, _context), do: raise("Intentional crash for testing")
    end

    test "catches and reports tool crashes" do
      assert {:error, error} = Executor.execute_tool(%CrashingTool{}, context: ctx(%{}))
      assert error =~ "Tool execution failed"
      assert error =~ "Intentional crash"
    end
  end

  describe "results the model can use" do
    defmodule ReturnTool do
      @moduledoc false
      use Normandy.Tool, name: "return_tool", description: "returns or exits with its value"

      defstruct [:value]

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}

      @impl Normandy.Tool
      def run(%{value: {:exit, reason}}, _context), do: exit(reason)
      def run(%{value: {:sleep, ms}}, _context), do: Process.sleep(ms) && {:ok, :slept}
      def run(%{value: value}, _context), do: value
    end

    test "a result that is not {:ok, _} or {:error, _} becomes an error result" do
      for bad <- [:ok, "bare string", nil] do
        assert {:error, message} =
                 Executor.execute_tool(%ReturnTool{value: bad}, context: ctx(%{}))

        assert message =~ "invalid result"
      end
    end

    test "an exit reason is named by its tag, not copied into the result" do
      tool = %ReturnTool{value: {:exit, {:timeout, {GenServer, :call, [:db, "SELECT secret"]}}}}

      assert {:error, message} = Executor.execute_tool(tool, context: ctx(%{}))
      assert message =~ ":timeout"
      refute message =~ "SELECT secret"
    end

    test "options are validated, naming the function and the key" do
      tool = %ReturnTool{value: {:ok, 1}}

      for {opts, key} <- [
            {[context: ctx(%{}), timeout: nil], ":timeout"},
            {[context: ctx(%{}), max_retries: 1], ":max_retries"},
            {[], ":context"}
          ] do
        error = assert_raise ArgumentError, fn -> Executor.execute_tool(tool, opts) end
        assert String.starts_with?(error.message, "Normandy.Tools.Executor.execute_tool/2: ")
        assert error.message =~ key
      end
    end

    test ":context must be a %Normandy.Tools.Context{}" do
      error =
        assert_raise ArgumentError, fn ->
          Executor.execute_tool(%ReturnTool{value: {:ok, 1}}, context: %{})
        end

      assert error.message ==
               "Normandy.Tools.Executor.execute_tool/2: :context must be a " <>
                 "%Normandy.Tools.Context{}, got: a map"
    end
  end

  describe "execute_tool_classified/2" do
    alias NormandyTest.Tools.ExecutorTest.{CrashingTool, ReturnTool}

    test "success carries no error type" do
      assert {{:ok, 1}, nil} =
               Executor.execute_tool_classified(%ReturnTool{value: {:ok, 1}}, context: ctx(%{}))
    end

    test "each failure kind is named, with the same {:error, msg} execute_tool/2 returns" do
      cases = [
        {%ReturnTool{value: {:error, "nope"}}, [], :tool_error},
        {%ReturnTool{value: :bare}, [], :invalid_result},
        {%ReturnTool{value: {:exit, :boom}}, [], :exit},
        {%ReturnTool{value: {:sleep, 100}}, [timeout: 10], :timeout},
        {%CrashingTool{}, [], :exception}
      ]

      for {tool, opts, kind} <- cases do
        opts = [context: ctx(%{})] ++ opts
        assert {{:error, message}, ^kind} = Executor.execute_tool_classified(tool, opts)
        assert {:error, ^message} = Executor.execute_tool(tool, opts)
      end
    end
  end

  describe "OTel context propagation" do
    # `Task.async` spawns a fresh process, which gets an empty process
    # dictionary — and therefore an empty OpenTelemetry context. Without the
    # capture/restore dance in `Executor`, any span opened inside the tool's
    # `run/2` becomes a root span in a fresh trace instead of a child of the
    # caller's active span.
    defmodule CtxCapturingTool do
      @moduledoc false
      use Normandy.Tool, name: "ctx_capturing_tool", description: "Snapshots OTel ctx"

      defstruct [:reply_to]

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}

      @impl Normandy.Tool
      def run(%{reply_to: pid}, _context) do
        value = OpenTelemetry.Ctx.get_value(:normandy_test_marker, :missing)
        send(pid, {:captured_marker, value})
        {:ok, :captured}
      end
    end

    setup do
      on_exit(fn -> OpenTelemetry.Ctx.clear() end)
      :ok
    end

    test "execute_tool/2 propagates the active OTel context into the task" do
      marker = make_ref()
      OpenTelemetry.Ctx.set_value(:normandy_test_marker, marker)

      assert {:ok, :captured} =
               Executor.execute_tool(%CtxCapturingTool{reply_to: self()}, context: ctx(%{}))

      assert_receive {:captured_marker, ^marker}, 1_000
    end

    test "with no context set the tool still runs (no-op restore)" do
      assert {:ok, :captured} =
               Executor.execute_tool(%CtxCapturingTool{reply_to: self()}, context: ctx(%{}))

      assert_receive {:captured_marker, :missing}, 1_000
    end
  end
end
