defmodule Normandy.Agents.DispatchTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Pipeline
  alias Normandy.Components.BaseIOSchema

  describe "default_pipeline/0" do
    test "returns a Pipeline with allow-all policy and no-op budget/hooks" do
      p = Dispatch.default_pipeline()

      assert %Pipeline{} = p
      assert p.before_hooks == []
      assert p.after_hooks == []
      assert p.policy_fn.(%{}, %{}, %{}) == {:allow, %{}}
      assert p.budget_check_fn.(%{}, %{}) == :ok
      assert p.budget_record_fn.(%{}, %{}, %{}) == :ok
    end
  end

  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.FakeTool
  alias Normandy.Tools.Toolset

  describe "to_tool_call/1" do
    test "passes a %ToolCall{} with map input through unchanged" do
      call = %ToolCall{id: "c1", name: "weather", input: %{city: "NYC"}}
      assert Dispatch.to_tool_call(call) == call
    end

    test "normalizes nil input to a map and keeps non-object input for classify/3 to refuse" do
      assert Dispatch.to_tool_call(%ToolCall{id: "c1a", name: "weather", input: nil}).input == %{}

      assert Dispatch.to_tool_call(%ToolCall{id: "c1b", name: "weather", input: [1, 2, 3]}).input ==
               [1, 2, 3]

      assert Dispatch.to_tool_call(%ToolCall{
               id: "c1c",
               name: "weather",
               input: ~s({"city":"SF"})
             }).input == %{"city" => "SF"}
    end

    test "normalizes a string-keyed JSON map into a %ToolCall{}" do
      raw = %{"id" => "c2", "name" => "weather", "input" => %{"city" => "LA"}}

      assert Dispatch.to_tool_call(raw) ==
               %ToolCall{id: "c2", name: "weather", input: %{"city" => "LA"}}
    end

    test "decodes a JSON-string input and keeps non-object input as it came" do
      raw = %{"id" => "c3", "name" => "weather", "input" => ~s({"city":"SF"})}
      assert Dispatch.to_tool_call(raw).input == %{"city" => "SF"}

      bad = %{"id" => "c4", "name" => "weather", "input" => [1, 2, 3]}
      assert Dispatch.to_tool_call(bad).input == [1, 2, 3]

      truncated = %{"id" => "c5", "name" => "weather", "input" => ~s({"city":"S)}
      assert Dispatch.to_tool_call(truncated).input == ~s({"city":"S)
    end
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", toolset: Toolset.new(tools)}
  end

  describe "dispatch_one/3 happy path" do
    test "allow → executes the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{
               tool_call_id: "c1",
               output: "weather in NYC",
               is_error: false
             } = result
    end

    test "accepts a raw string-keyed map (streaming shape)" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c9", "name" => "weather", "input" => %{"city" => "LA"}}

      result = Dispatch.dispatch_one(config, raw, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c9", output: "weather in LA", is_error: false} = result
    end

    test "a %ToolCall{} with nil input is normalized, not crashed, before validation" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: nil}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c10", output: "weather in ", is_error: false} = result
    end
  end

  describe "dispatch_one/3 registry miss" do
    test "unknown tool → error ToolResult, tool not executed" do
      config = config_with_tools([])
      call = %ToolCall{id: "c5", name: "nope", input: %{}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{
               tool_call_id: "c5",
               is_error: true,
               output: %{error: "No tool named 'nope'. This agent has no tools."}
             } = result
    end

    test "the result names the available tools, sorted, at most 20" do
      config = config_with_tools([%FakeTool{name: "weather"}, %FakeTool{name: "billing"}])
      call = %ToolCall{id: "c5b", name: "wether", input: %{}}

      assert Dispatch.dispatch_one(config, call, Dispatch.default_pipeline()).output == %{
               error: "No tool named 'wether'. Available tools: billing, weather."
             }

      name = &"t#{String.pad_leading(Integer.to_string(&1), 2, "0")}"
      many = config_with_tools(Enum.map(23..1//-1, &%FakeTool{name: name.(&1)}))

      assert Dispatch.dispatch_one(many, call, Dispatch.default_pipeline()).output == %{
               error:
                 "No tool named 'wether'. Available tools: " <>
                   Enum.map_join(1..20, ", ", name) <> ", and 3 more."
             }
    end
  end

  describe "dispatch_one/3 policy outcomes" do
    test "deny → error ToolResult with rationale fed into output, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c6", name: "weather", input: %{"city" => "NYC"}}

      deny_policy = fn _config, _call, _tool ->
        {:deny,
         %{reason: "weather tool blocked", rule_id: "R-7", rationale: "shares state with billing"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny_policy}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{tool_call_id: "c6", is_error: true, output: output} = result

      assert output == %{
               error:
                 "This call was blocked by policy (weather tool blocked). " <>
                   "Do not retry it; continue without it or tell the user.",
               rule_id: "R-7",
               rationale: "shares state with billing",
               denied: true
             }
    end

    # PolicyEngine.Ruleset's default-action deny is %{reason: nil, rule_id: nil,
    # rationale: nil} (policy_engine_test.exs); the model used to see "error": null.
    test "a deny with nil reason, rule_id and rationale sends no null" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c6b", name: "weather", input: %{"city" => "NYC"}}
      deny = fn _config, _call, _inv -> {:deny, %{reason: nil, rule_id: nil, rationale: nil}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert result.output == %{
               error:
                 "This call was blocked by policy. Do not retry it; continue without it or tell the user.",
               denied: true
             }

      assert [%{content: content, is_error: true}] = BaseIOSchema.to_json(result)

      assert Jason.decode!(content) == %{
               "error" =>
                 "This call was blocked by policy. Do not retry it; continue without it or tell the user.",
               "denied" => true
             }
    end

    test "a deny with an atom reason shows it; any other term is not shown" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c6c", name: "weather", input: %{"city" => "NYC"}}

      for {reason, expected} <- [
            {:forbidden,
             "This call was blocked by policy (forbidden). " <>
               "Do not retry it; continue without it or tell the user."},
            {%{api_key: "sk-policy-secret"},
             "This call was blocked by policy. Do not retry it; continue without it or tell the user."},
            {true,
             "This call was blocked by policy. Do not retry it; continue without it or tell the user."}
          ] do
        deny = fn _config, _call, _inv -> {:deny, %{reason: reason}} end
        pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

        assert %ToolResult{output: %{error: ^expected}} =
                 Dispatch.dispatch_one(config, call, pipeline)
      end
    end

    test "a policy that raises, exits or throws is a denial that does not show the term" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}
      secret = %{api_key: "sk-policy-secret"}

      for {policy, rationale} <- [
            # The KeyError carries the secret map as its term, as Map.fetch!/2 would.
            {fn _, _, _ -> raise KeyError, key: :missing, term: secret end, "KeyError"},
            {fn _, _, _ -> exit({:timeout, secret}) end, "{:timeout, ...}"},
            {fn _, _, _ -> throw(secret) end, "a map"}
          ] do
        pipeline = %{Dispatch.default_pipeline() | policy_fn: policy}

        assert %ToolResult{is_error: true, output: %{denied: true} = output} =
                 Dispatch.dispatch_one(config, call, pipeline)

        refute inspect(output) =~ "sk-policy-secret"
        assert output.rationale =~ rationale
      end
    end

    test "needs_approval → a denial saying approval is not available, no pending_approval" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}

      approval_policy = fn _config, _call, _tool ->
        {:needs_approval, %{reason: "human review", rationale: "high-cost op"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: approval_policy}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{tool_call_id: "c7", is_error: true, output: output} = result

      assert output == %{
               error:
                 "This action needs human approval, which is not available in this run. " <>
                   "Do not retry it; tell the user it requires approval.",
               rationale: "high-cost op",
               denied: true
             }
    end
  end

  describe "dispatch_one/3 hooks" do
    test "before-hook returning {:halt, result} short-circuits, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}

      halting_hook = fn _config, %ToolCall{id: id} ->
        {:halt,
         %ToolResult{tool_call_id: id, output: %{error: "blocked by hook"}, is_error: true}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [halting_hook]}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert result == %ToolResult{
               tool_call_id: "c8",
               output: %{error: "blocked by hook"},
               is_error: true
             }
    end

    test "before-hook returning {:cont, call} can rewrite input" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}

      rewrite_hook = fn _config, %ToolCall{} = c ->
        {:cont, %{c | input: %{"city" => "Boston"}}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [rewrite_hook]}

      result = Dispatch.dispatch_one(config, call, pipeline)
      assert result.output == "weather in Boston"
    end

    test "a hook cannot change which call a result answers" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12", name: "weather", input: %{"city" => "NYC"}}

      for pipeline <- [
            %{
              Dispatch.default_pipeline()
              | before_hooks: [fn _c, c -> {:cont, %{c | id: "rewritten"}} end]
            },
            %{
              Dispatch.default_pipeline()
              | before_hooks: [
                  fn _c, _call -> {:halt, %ToolResult{tool_call_id: "other", output: "no"}} end
                ]
            },
            %{
              Dispatch.default_pipeline()
              | after_hooks: [fn _c, _call, r -> %{r | tool_call_id: "other"} end]
            }
          ] do
        assert %ToolResult{tool_call_id: "c12"} = Dispatch.dispatch_one(config, call, pipeline)
      end
    end

    test "after-hook transforms the result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c11", name: "weather", input: %{"city" => "NYC"}}

      redact_hook = fn _config, _call, %ToolResult{} = r ->
        %{r | output: "REDACTED"}
      end

      pipeline = %{Dispatch.default_pipeline() | after_hooks: [redact_hook]}

      result = Dispatch.dispatch_one(config, call, pipeline)
      assert result.output == "REDACTED"
    end
  end

  describe "dispatch_one/3 budget" do
    test "budget_check_fn returning {:error, reason} denies before executing" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12", name: "weather", input: %{"city" => "NYC"}}

      over_budget = fn _config, _call -> {:error, :cap_exceeded} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over_budget}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{tool_call_id: "c12", is_error: true} = result

      assert result.output == %{
               error:
                 "The tool budget is used up; the tool was not run. Answer with what you have.",
               denied: true
             }

      refute inspect(result.output) =~ "cap_exceeded"
    end

    test "a budget reason that is text is shown; any other term is not" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12b", name: "weather", input: %{"city" => "NYC"}}
      over = fn _config, _call -> {:error, "daily cap of 50 calls reached"} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      assert Dispatch.dispatch_one(config, call, pipeline).output.error ==
               "The tool budget is used up (daily cap of 50 calls reached); " <>
                 "the tool was not run. Answer with what you have."
    end

    test "budget_record_fn is called with the success result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c13", name: "weather", input: %{"city" => "NYC"}}
      test_pid = self()

      recorder = fn _config, _call, result ->
        send(test_pid, {:recorded, result})
        :ok
      end

      pipeline = %{Dispatch.default_pipeline() | budget_record_fn: recorder}

      Dispatch.dispatch_one(config, call, pipeline)

      assert_receive {:recorded, %ToolResult{output: "weather in NYC", is_error: false}}
    end
  end
end
