defmodule NormandyTest.Telemetry.ToolTelemetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Test.FakeTool
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  defmodule RaisingDescriptionTool do
    defstruct []

    defimpl Normandy.Tools.BaseTool do
      def tool_name(_), do: "raising_description"
      def tool_description(_), do: raise("no description")
      def input_schema(_), do: %{}
      def run(_), do: {:ok, "ran"}
    end
  end

  defmodule MockMCPAdapter do
    def call_tool(_client, "search", _args, _opts), do: {:ok, "found"}
  end

  def handle_event(event, measurements, meta, {parent, agent_name}) do
    if meta[:agent_name] == agent_name, do: send(parent, {:event, event, measurements, meta})
  end

  # Telemetry handlers are global and these tests run async: forward only the
  # events of this test's agent.
  defp attach(events, agent_name) do
    parent = self()
    id = "tool-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      events,
      &__MODULE__.handle_event/4,
      {parent, agent_name}
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defmodule NoCallClient do
    defstruct []

    defimpl Normandy.Agents.Model do
      def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(_config, _model, _temperature, _max_tokens, _messages, _response_model, _opts),
        do: raise("these tests dispatch tools directly; no LLM call is made")
    end
  end

  defp config(tools) do
    BaseAgent.init(%{
      name: "tool-agent-#{System.unique_integer([:positive])}",
      client: %NoCallClient{},
      model: "test-model",
      session_id: "sess-tool",
      tool_registry: Registry.new(tools)
    })
  end

  @span [[:normandy, :tool, :execute, :start], [:normandy, :tool, :execute, :stop]]

  describe "tool execute span metadata" do
    test "a local tool reports its call id, description and :function type" do
      config = config([%FakeTool{}])
      attach(@span, config.name)
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "Oslo"}}

      Dispatch.dispatch_one(config, call, BaseAgent.base_agent_pipeline(config))

      for phase <- [:start, :stop] do
        assert_received {:event, [:normandy, :tool, :execute, ^phase], _,
                         %{
                           tool_name: "weather",
                           tool_call_id: "c1",
                           tool_description: "fake",
                           tool_type: :function,
                           session_id: "sess-tool"
                         } = meta}

        refute Map.has_key?(meta, :error_type)
      end
    end

    test "stop carries error_type when the tool failed; the model still sees {:error, msg}" do
      config = config([%Calculator{}])
      attach(@span, config.name)

      call = %ToolCall{
        id: "c2",
        name: "calculator",
        input: %{"operation" => "divide", "a" => 1, "b" => 0}
      }

      result = Dispatch.dispatch_one(config, call, BaseAgent.base_agent_pipeline(config))

      assert %ToolResult{is_error: true, output: %{error: "Cannot divide by zero"}} = result

      assert_received {:event, [:normandy, :tool, :execute, :stop], _,
                       %{status: :error, error_type: :tool_error, tool_call_id: "c2"}}
    end

    test "a tool whose tool_description/1 raises still runs; the span omits the description" do
      config = config([%RaisingDescriptionTool{}])
      attach(@span, config.name)
      call = %ToolCall{id: "c6", name: "raising_description", input: %{}}

      assert %ToolResult{tool_call_id: "c6", output: "ran", is_error: false} =
               Dispatch.dispatch_one(config, call, BaseAgent.base_agent_pipeline(config))

      for phase <- [:start, :stop] do
        assert_received {:event, [:normandy, :tool, :execute, ^phase], _,
                         %{tool_call_id: "c6", tool_type: :function} = meta}

        refute Map.has_key?(meta, :tool_description)
      end
    end

    test "an MCP-wrapped tool reports :extension" do
      mcp_tool = %Claudio.MCP.Client.Tool{
        name: "search",
        description: "Search the web",
        input_schema: %{"type" => "object"}
      }

      config = config([ToolWrapper.new(MockMCPAdapter, nil, mcp_tool)])
      attach(@span, config.name)
      call = %ToolCall{id: "c3", name: "search", input: %{}}

      Dispatch.dispatch_one(config, call, BaseAgent.base_agent_pipeline(config))

      assert_received {:event, [:normandy, :tool, :execute, :start], _,
                       %{
                         tool_type: :extension,
                         tool_description: "Search the web",
                         tool_call_id: "c3"
                       }}
    end
  end

  describe "execute_fn arity" do
    test "an arity-3 execute_fn still gets the tool name" do
      config = config([%FakeTool{}])
      parent = self()

      execute_fn = fn _config, _tool, name ->
        send(parent, {:executed, name})
        {:ok, "ran"}
      end

      pipeline = %{Dispatch.default_pipeline() | execute_fn: execute_fn}
      call = %ToolCall{id: "c4", name: "weather", input: %{}}

      assert %ToolResult{output: "ran"} = Dispatch.dispatch_one(config, call, pipeline)
      assert_received {:executed, "weather"}
    end

    test "an arity-4 execute_fn also gets the %ToolCall{}" do
      config = config([%FakeTool{}])
      parent = self()

      execute_fn = fn _config, _tool, name, call ->
        send(parent, {:executed, name, call})
        {:ok, "ran"}
      end

      pipeline = %{Dispatch.default_pipeline() | execute_fn: execute_fn}
      call = %ToolCall{id: "c5", name: "weather", input: %{}}

      assert %ToolResult{output: "ran"} = Dispatch.dispatch_one(config, call, pipeline)
      assert_received {:executed, "weather", %ToolCall{id: "c5"}}
    end
  end

  describe "[:normandy, :tool, :denied]" do
    @denied [[:normandy, :tool, :denied]]

    defp dispatch_denied(pipeline_overrides, call_id) do
      config = config([%FakeTool{}])
      attach(@denied, config.name)
      pipeline = struct(Dispatch.default_pipeline(), pipeline_overrides)
      call = %ToolCall{id: call_id, name: "weather", input: %{}}
      result = Dispatch.dispatch_one(config, call, pipeline)
      {config, result}
    end

    test "a policy denial names the rule" do
      deny = fn _c, _call, _t -> {:deny, %{reason: "blocked", rule_id: "R-7"}} end
      {config, result} = dispatch_denied([policy_fn: deny], "d1")
      name = config.name

      assert %ToolResult{is_error: true} = result

      assert_received {:event, [:normandy, :tool, :denied], %{count: 1},
                       %{
                         tool_name: "weather",
                         tool_call_id: "d1",
                         reason: :policy,
                         rule_id: "R-7",
                         agent_name: ^name,
                         session_id: "sess-tool"
                       }}
    end

    test "a call needing approval on the synchronous path is a policy denial" do
      park = fn _c, _call, _t -> {:needs_approval, %{rule_id: "R-9"}} end
      dispatch_denied([policy_fn: park], "d2")

      assert_received {:event, [:normandy, :tool, :denied], %{count: 1},
                       %{tool_call_id: "d2", reason: :policy, rule_id: "R-9"}}
    end

    test "a before-hook halt" do
      halt = fn _c, call -> {:halt, %ToolResult{tool_call_id: call.id, is_error: true}} end
      dispatch_denied([before_hooks: [halt]], "d3")

      assert_received {:event, [:normandy, :tool, :denied], %{count: 1},
                       %{tool_call_id: "d3", reason: :hook_halt} = meta}

      refute Map.has_key?(meta, :rule_id)
    end

    test "a budget refusal" do
      over = fn _c, _call -> {:error, :over_budget} end
      dispatch_denied([budget_check_fn: over], "d4")

      assert_received {:event, [:normandy, :tool, :denied], %{count: 1},
                       %{tool_call_id: "d4", reason: :budget}}
    end

    test "allowed calls and registry misses emit no denial" do
      config = config([%FakeTool{}])
      attach(@denied, config.name)

      Dispatch.dispatch_one(config, %ToolCall{id: "d5", name: "weather", input: %{}})
      Dispatch.dispatch_one(config, %ToolCall{id: "d6", name: "missing", input: %{}})

      refute_received {:event, [:normandy, :tool, :denied], _, _}
    end
  end
end
