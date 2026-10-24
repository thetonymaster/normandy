defmodule Normandy.Agents.DispatchSplitTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Invocation
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.FakeTool
  alias Normandy.Tools.{Context, Executor, Toolset}

  # A tool with a declared input schema (required + enum). run/2's return value
  # ("did <op>") is the only way to get a non-error ToolResult, so seeing it proves the
  # tool ran; a validation denial is a different (denied) result, proving it did not.
  defmodule SchemaTool do
    @moduledoc false
    defmodule Params do
      @moduledoc false
      use Normandy.Schema

      io_schema "enum + required constrained input" do
        field(:operation, :string, required: true, enum: ["add", "subtract"])
      end
    end

    use Normandy.Tool,
      name: "schema_tool",
      description: "enum + required constrained tool",
      input: Params

    defstruct []

    @impl Normandy.Tool
    def run(_tool, %Context{input: %Params{operation: op}}), do: {:ok, "did #{op}"}
  end

  defp config_with_tools(tools), do: %{name: "test-agent", toolset: Toolset.new(tools)}

  describe "classify/3" do
    test "allow → {:execute, %Invocation{}, call}: the tool as registered, the validated input, the registration timeout" do
      tool = %FakeTool{}
      config = config_with_tools([{tool, timeout: 1_234}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert {:execute, %Invocation{tool: ^tool, input: %{"city" => "NYC"}, timeout: 1_234},
              %ToolCall{id: "c1"}} = Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "a tool registered without :timeout gets the executor's default" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{}}
      default = Executor.default_timeout()

      assert {:execute, %Invocation{timeout: ^default}, _call} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "input that is not a JSON object is refused and the model is told" do
      config = config_with_tools([%FakeTool{}])

      for input <- [~s({"city": "NY), "[1, 2]", 42] do
        call = %ToolCall{id: "bad", name: "weather", input: input}

        assert {:deny, %ToolResult{tool_call_id: "bad", is_error: true, output: output}} =
                 Dispatch.classify(config, call, Dispatch.default_pipeline())

        assert output == %{
                 error:
                   "tool input is not a JSON object (it may have been cut off); " <>
                     "the tool was not run. Send the arguments as a JSON object."
               }
      end
    end

    test "deny → {:deny, error ToolResult}, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      deny = fn _c, _call, _invocation -> {:deny, %{reason: "blocked", rule_id: "R-1"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      assert {:deny, %ToolResult{tool_call_id: "c2", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "needs_approval → {:needs_approval, %Invocation{}, call, info}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      approve = fn _c, _call, _invocation -> {:needs_approval, %{rationale: "high-cost"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert {:needs_approval, %Invocation{tool: %FakeTool{}}, %ToolCall{id: "c3"},
              %{rationale: "high-cost"}} = Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn gets the invocation: the registered tool and the validated input" do
      parent = self()
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c13", name: "weather", input: %{"city" => "NYC"}}

      policy = fn _c, _call, invocation ->
        send(parent, {:policy_saw, invocation})
        {:allow, %{}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: policy}

      assert {:execute, _invocation, _call} = Dispatch.classify(config, call, pipeline)

      assert_received {:policy_saw,
                       %Invocation{tool: %FakeTool{name: "weather"}, input: %{"city" => "NYC"}}}
    end

    test "toolset miss → {:deny, not-found ToolResult}" do
      config = config_with_tools([])
      call = %ToolCall{id: "c4", name: "nope", input: %{}}

      assert {:deny, %ToolResult{tool_call_id: "c4", is_error: true}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "before-hook {:halt, result} → {:deny, result}, policy not consulted" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c5", name: "weather", input: %{"city" => "NYC"}}

      halt = fn _c, %ToolCall{id: id} ->
        {:halt, %ToolResult{tool_call_id: id, output: %{error: "hooked"}, is_error: true}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [halt]}

      assert {:deny, %ToolResult{tool_call_id: "c5", output: %{error: "hooked"}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn that raises → {:deny}, fail-closed (belt-and-suspenders)" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c11", name: "weather", input: %{"city" => "NYC"}}

      boom = fn _c, _call, _invocation -> raise "policy engine down" end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: boom}

      assert {:deny, %ToolResult{tool_call_id: "c11", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn that exits (timeout/unreachable) → {:deny}, fail-closed" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12", name: "weather", input: %{"city" => "NYC"}}

      timeout = fn _c, _call, _invocation -> exit(:timeout) end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: timeout}

      assert {:deny, %ToolResult{tool_call_id: "c12", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "accepts a raw string-keyed map" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c6", "name" => "weather", "input" => %{"city" => "LA"}}

      assert {:execute, %Invocation{input: %{"city" => "LA"}}, %ToolCall{id: "c6"}} =
               Dispatch.classify(config, raw, Dispatch.default_pipeline())
    end
  end

  describe "classify/3 input validation" do
    test "an enum violation → {:deny, validation error}, never classified to :execute" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v1", name: "schema_tool", input: %{"operation" => "power"}}

      assert {:deny, %ToolResult{tool_call_id: "v1", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      # A fixable mistake is not a denial: the model is told to correct it and retry.
      refute Map.has_key?(result.output, :denied)
      assert [%{constraint: :enum, path: [:operation]}] = result.output.validation_errors

      assert result.output.error ==
               ~s(invalid input for schema_tool: operation must be one of ["add", "subtract"]; ) <>
                 "the tool was not run. Correct the input and call the tool again."
    end

    test "a missing required field → {:deny, validation error}" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v2", name: "schema_tool", input: %{}}

      assert {:deny, %ToolResult{tool_call_id: "v2", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert [%{constraint: :required, path: [:operation]}] = result.output.validation_errors
    end

    test "valid input becomes the declared schema's struct" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v3", name: "schema_tool", input: %{"operation" => "add"}}

      assert {:execute,
              %Invocation{tool: %SchemaTool{}, input: %SchemaTool.Params{operation: "add"}},
              %ToolCall{id: "v3"}} = Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "unknown keys on a hand-written schema are named in the result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "v6", name: "weather", input: %{"city" => "x", "bogus" => 1}}

      assert {:deny, %ToolResult{is_error: true, output: output}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert output.error ==
               ~s(invalid input for weather: unknown key "bogus"; expected only "city"; ) <>
                 "the tool was not run. Correct the input and call the tool again."
    end

    test "a value of the wrong basic type on a hand-written schema" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "v7", name: "weather", input: %{"city" => 123}}

      assert {:deny, %ToolResult{output: %{validation_errors: [error]}}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert error == %{
               path: ["city"],
               message: "expected type string, got integer",
               constraint: :type
             }
    end

    test "the input a before-hook produced is what gets validated" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "v8", name: "weather", input: %{"city" => "x"}}
      hook = fn _c, call -> {:cont, %{call | input: Map.put(call.input, "bogus", 1)}} end
      pipeline = %{Dispatch.default_pipeline() | before_hooks: [hook]}

      assert {:deny, %ToolResult{output: %{validation_errors: [%{constraint: :unknown_keys}]}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "dispatch_one: a malformed call never reaches run/2" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v4", name: "schema_tool", input: %{"operation" => "power"}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "v4", is_error: true, output: %{validation_errors: [_]}} =
               result

      # run/2 would have produced the string "did power"; a map proves it never ran.
      refute result.output == "did power"
    end

    test "dispatch_one: a valid call runs run/2 (its return value is the result)" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v5", name: "schema_tool", input: %{"operation" => "add"}}

      assert %ToolResult{is_error: false, output: "did add"} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())
    end
  end

  describe "execute/4" do
    test "runs the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}

      {:execute, invocation, call} =
        Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c7", output: "weather in NYC", is_error: false} =
               Dispatch.execute(config, invocation, call, Dispatch.default_pipeline())
    end

    test "budget {:error, reason} → budget-denial result, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}

      {:execute, invocation, call} =
        Dispatch.classify(config, call, Dispatch.default_pipeline())

      over = fn _c, _call -> {:error, :cap} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      result = Dispatch.execute(config, invocation, call, pipeline)
      assert %ToolResult{tool_call_id: "c8", is_error: true, output: %{denied: true}} = result
      assert result.output.error =~ "The tool budget is used up"
    end

    test "the registration timeout bounds the run" do
      config = config_with_tools([{%FakeTool{sleep_ms: 1_000}, timeout: 20}])
      call = %ToolCall{id: "c14", name: "weather", input: %{}}

      # A binary error reason is sent as it is (AX-15), with is_error set.
      assert %ToolResult{is_error: true, output: "Tool execution timeout after 20ms"} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())
    end
  end

  describe "execute_approved/3" do
    test "re-validates the parked call's input and runs it without consulting policy" do
      parent = self()
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "a1", name: "weather", input: %{"city" => "Oslo"}}

      policy = fn _c, _call, _invocation ->
        send(parent, :policy_ran)
        {:deny, %{reason: "no"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: policy}

      assert %ToolResult{tool_call_id: "a1", output: "weather in Oslo", is_error: false} =
               Dispatch.execute_approved(config, call, pipeline)

      refute_received :policy_ran
    end

    test "a tool no longer registered is a not-found result, not a crash" do
      config = config_with_tools([])
      call = %ToolCall{id: "a2", name: "weather", input: %{}}

      assert %ToolResult{tool_call_id: "a2", is_error: true, output: %{error: error}} =
               Dispatch.execute_approved(config, call, Dispatch.default_pipeline())

      assert error =~ "weather"
    end

    test "input that no longer validates is answered with the validation result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "a3", name: "weather", input: %{"bogus" => 1}}

      assert %ToolResult{
               tool_call_id: "a3",
               is_error: true,
               output: %{validation_errors: [%{constraint: :unknown_keys}]}
             } = Dispatch.execute_approved(config, call, Dispatch.default_pipeline())
    end
  end

  describe "dispatch_one/3 == classify ➞ execute" do
    test "allow path equals execute of the classified call" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c9", name: "weather", input: %{"city" => "NYC"}}
      p = Dispatch.default_pipeline()

      {:execute, invocation, call2} = Dispatch.classify(config, call, p)

      assert Dispatch.dispatch_one(config, call, p) ==
               Dispatch.execute(config, invocation, call2, p)
    end

    test "needs_approval still collapses to the interim denial" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}
      approve = fn _c, _call, _invocation -> {:needs_approval, %{rationale: "r"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert %ToolResult{is_error: true, output: %{denied: true} = output} =
               Dispatch.dispatch_one(config, call, pipeline)

      refute Map.has_key?(output, :pending_approval)
      assert output.error =~ "needs human approval, which is not available in this run"
    end
  end
end
