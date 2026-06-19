defmodule Normandy.Agents.DispatchSplitTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchSplitTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  # Schema-based tool (has a generated validate/1) with required + enum constraints.
  # execute/1's return value ("did <op>") is the only way to produce a non-error
  # ToolResult, so observing it proves the tool ran; a validation deny produces a
  # structurally different (denied) result, proving it did NOT run. (We assert on
  # the returned ToolResult rather than a sent message because the Executor runs
  # execute/1 in a separate Task process — a send(self(), ...) would never reach
  # the test process.)
  defmodule SchemaTool do
    use Normandy.Tools.SchemaBaseTool

    tool_schema "schema_tool", "enum + required constrained tool" do
      field(:operation, :string, required: true, enum: ["add", "subtract"])
    end

    def execute(%__MODULE__{operation: op}) do
      {:ok, "did #{op}"}
    end
  end

  # Exports validate/1 but NOT validate!/1, so it is not shaped like a
  # SchemaBaseTool tool (the macro emits both). The hardened classify-time guard
  # requires both, so this must be OUT of scope and bypass validation. Its
  # validate/1 always errors, so if it were (wrongly) in scope, classify would
  # deny — observing :execute proves the bypass.
  defmodule ValidateOnlyTool do
    use Normandy.Schema

    schema do
      field(:n, :integer)
    end

    def validate(_params),
      do: {:error, [%{path: [:n], message: "always rejects", constraint: :custom}]}
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchSplitTest.ValidateOnlyTool do
    def tool_name(_), do: "validate_only"
    def tool_description(_), do: "exports validate/1 but not validate!/1"
    def input_schema(_), do: %{}
    def run(_tool), do: {:ok, "ran validate_only"}
  end

  # Exports BOTH validate/1 and validate!/1 (passes the scope guard), but its
  # validate/1 returns a value outside the {:ok, _} / {:error, list} contract.
  # The chokepoint must turn that into a fail-closed deny, not a CaseClauseError
  # crash (validate_input/2 runs outside apply_policy's rescue/catch).
  defmodule GarbageValidatorTool do
    use Normandy.Schema

    schema do
      field(:n, :integer)
    end

    def validate(_params), do: :totally_unexpected
    def validate!(_params), do: :unused
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchSplitTest.GarbageValidatorTool do
    def tool_name(_), do: "garbage_validator"
    def tool_description(_), do: "validate/1 returns a non-contract value"
    def input_schema(_), do: %{}
    def run(_tool), do: {:ok, "ran garbage"}
  end

  # A SchemaBaseTool tool (has validate/1 AND validate!/1) that ALSO defines a
  # custom prepare_input/2. Because the prepare_input/2 branch wins in the cond,
  # the tool owns its own validation and classify must skip the enum/required
  # schema pre-validation it would otherwise apply.
  defmodule PrepareInputTool do
    use Normandy.Tools.SchemaBaseTool

    tool_schema "prepare_input_tool", "owns its validation via prepare_input/2" do
      field(:operation, :string, required: true, enum: ["add"])
    end

    def prepare_input(tool, input) do
      op = Map.get(input, "operation") || Map.get(input, :operation)
      struct(tool, %{operation: op})
    end

    def execute(%__MODULE__{operation: op}) do
      {:ok, "did #{op}"}
    end
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", tool_registry: Registry.new(tools)}
  end

  describe "classify/3" do
    test "allow → {:execute, prepared_tool, normalized_call}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert {:execute, %FakeTool{city: "NYC"}, %ToolCall{id: "c1"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "deny → {:deny, error ToolResult}, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      deny = fn _c, _call, _tool -> {:deny, %{reason: "blocked", rule_id: "R-1"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      assert {:deny, %ToolResult{tool_call_id: "c2", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "needs_approval → {:needs_approval, prepared, call, info}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      approve = fn _c, _call, _tool -> {:needs_approval, %{rationale: "high-cost"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert {:needs_approval, %FakeTool{}, %ToolCall{id: "c3"}, %{rationale: "high-cost"}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "registry miss → {:deny, not-found ToolResult}" do
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

      boom = fn _c, _call, _tool -> raise "policy engine down" end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: boom}

      assert {:deny, %ToolResult{tool_call_id: "c11", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn that exits (timeout/unreachable) → {:deny}, fail-closed" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12", name: "weather", input: %{"city" => "NYC"}}

      timeout = fn _c, _call, _tool -> exit(:timeout) end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: timeout}

      assert {:deny, %ToolResult{tool_call_id: "c12", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "accepts a raw string-keyed map" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c6", "name" => "weather", "input" => %{"city" => "LA"}}

      assert {:execute, %FakeTool{city: "LA"}, %ToolCall{id: "c6"}} =
               Dispatch.classify(config, raw, Dispatch.default_pipeline())
    end
  end

  describe "classify/3 input validation (schema-based tools)" do
    test "malformed input (enum violation) → {:deny, validation error}, never classified to :execute" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v1", name: "schema_tool", input: %{"operation" => "power"}}

      assert {:deny, %ToolResult{tool_call_id: "v1", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert result.output.denied == true
      assert [%{constraint: :enum, path: [:operation]}] = result.output.validation_errors
    end

    test "missing required field → {:deny, validation error}" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v2", name: "schema_tool", input: %{}}

      assert {:deny, %ToolResult{tool_call_id: "v2", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert [%{constraint: :required, path: [:operation]}] = result.output.validation_errors
    end

    test "valid input still classifies to {:execute, prepared, call}" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v3", name: "schema_tool", input: %{"operation" => "add"}}

      assert {:execute, %SchemaTool{operation: "add"}, %ToolCall{id: "v3"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "dispatch_one: malformed call never reaches execute/1 (result is the deny, not execute output)" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v4", name: "schema_tool", input: %{"operation" => "power"}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "v4", is_error: true, output: %{denied: true}} = result
      # execute/1 would have produced the string "did power"; a map proves it never ran.
      refute result.output == "did power"
    end

    test "dispatch_one: valid call runs execute/1 (its return value is the result)" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v5", name: "schema_tool", input: %{"operation" => "add"}}

      assert %ToolResult{is_error: false, output: "did add"} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())
    end
  end

  describe "classify/3 validator-contract hardening" do
    test "tool exporting validate/1 without validate!/1 is out of scope → bypasses validation" do
      config = config_with_tools([%ValidateOnlyTool{}])
      call = %ToolCall{id: "h1", name: "validate_only", input: %{"n" => "not-an-int"}}

      assert {:execute, %ValidateOnlyTool{}, %ToolCall{id: "h1"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "validator returning a non-contract value → fail-closed deny, not a crash" do
      config = config_with_tools([%GarbageValidatorTool{}])
      call = %ToolCall{id: "h2", name: "garbage_validator", input: %{"n" => 1}}

      assert {:deny, %ToolResult{tool_call_id: "h2", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert result.output.denied == true
      assert [%{constraint: :internal}] = result.output.validation_errors
    end
  end

  # Locks the stated scope contract: classify-time validation applies ONLY to
  # SchemaBaseTool-shaped tools. Non-schema tools and tools that own validation
  # via prepare_input/2 must keep their pre-existing behavior (no deny on
  # validation grounds), so the seam can't silently widen later.
  describe "classify/3 validation scope (non-schema & prepare_input tools)" do
    test "non-schema tool (no generated validate/1) bypasses validation entirely" do
      config = config_with_tools([%FakeTool{}])
      # city: 123 would fail strict string validation IF FakeTool were validated;
      # it is a plain Normandy.Schema tool (no validate/1), so it must pass through.
      call = %ToolCall{id: "b1", name: "weather", input: %{"city" => 123, "bogus" => "x"}}

      assert {:execute, %FakeTool{}, %ToolCall{id: "b1"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "tool with custom prepare_input/2 owns validation → classify skips schema pre-validation" do
      config = config_with_tools([%PrepareInputTool{}])
      # "power" violates the enum; a plain schema tool WOULD deny, but this tool's
      # prepare_input/2 owns validation, so classify must route it to :execute.
      call = %ToolCall{id: "b2", name: "prepare_input_tool", input: %{"operation" => "power"}}

      assert {:execute, %PrepareInputTool{operation: "power"}, %ToolCall{id: "b2"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end
  end

  describe "execute/4" do
    test "runs the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}
      {:execute, prepared, call} = Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c7", output: "weather in NYC", is_error: false} =
               Dispatch.execute(config, prepared, call, Dispatch.default_pipeline())
    end

    test "budget {:error, reason} → budget-denial result, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}
      {:execute, prepared, call} = Dispatch.classify(config, call, Dispatch.default_pipeline())

      over = fn _c, _call -> {:error, :cap} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      result = Dispatch.execute(config, prepared, call, pipeline)
      assert %ToolResult{tool_call_id: "c8", is_error: true, output: %{denied: true}} = result
      assert result.output.error =~ "budget check failed"
    end
  end

  describe "dispatch_one/3 == classify ➞ execute" do
    test "allow path equals execute of the classified call" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c9", name: "weather", input: %{"city" => "NYC"}}
      p = Dispatch.default_pipeline()

      {:execute, prepared, call2} = Dispatch.classify(config, call, p)

      assert Dispatch.dispatch_one(config, call, p) ==
               Dispatch.execute(config, prepared, call2, p)
    end

    test "needs_approval still collapses to the interim denial (pending_approval: true)" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}
      approve = fn _c, _call, _tool -> {:needs_approval, %{rationale: "r"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert %ToolResult{is_error: true, output: %{pending_approval: true, denied: true}} =
               Dispatch.dispatch_one(config, call, pipeline)
    end
  end
end
