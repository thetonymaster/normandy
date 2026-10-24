defmodule Normandy.Agents.ToolContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch, ToolCallResponse, Turn}
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Test.TurnShell
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, FakeClient}
  alias Normandy.Tools.{Context, Toolset}

  defp probe_call, do: %ToolCall{id: "call_1", name: "probe", input: %{}}

  # One tool round with probe_call/0, then the answer "done".
  defp probe_client, do: FakeClient.new([{:tool_calls, [probe_call()]}, {:text, "done"}])

  defp agent(extra \\ %{}) do
    %{client: probe_client(), model: "test", name: "ctx-agent"}
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: self()})
  end

  test "init/1 defaults tool_context to %{} and rejects a non-map" do
    assert agent().tool_context == %{}

    assert_raise ArgumentError,
                 ~r/:tool_context option: expected a plain map \(not a struct\), got: a list/,
                 fn ->
                   BaseAgent.init(%{
                     client: FakeClient.new([]),
                     model: "test",
                     tool_context: [a: 1]
                   })
                 end
  end

  test "a BaseAgent turn hands the contextual tool the session's context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/u-1"}})

    {_config, _response} = BaseAgent.run!(config, %{chat_message: "go"})

    assert_receive {:probe_ctx,
                    %Context{
                      tool_call_id: "call_1",
                      agent_name: "ctx-agent",
                      values: %{memory_namespace: "acme/u-1"}
                    } = ctx}

    assert is_binary(ctx.turn_id)
  end

  test "the BaseAgent streaming loop hands the contextual tool the session's context" do
    config =
      agent(%{client: probe_client(), tool_context: %{memory_namespace: "acme/stream"}})

    {:ok, _config, _response} =
      BaseAgent.stream(config, %{chat_message: "go"}, fn _ -> :ok end)

    assert_receive {:probe_ctx,
                    %Context{tool_call_id: "call_1", values: %{memory_namespace: "acme/stream"}}}
  end

  test "Turn.Driver over base_agent_pipeline/1 hands the contextual tool the context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/inline"}})
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    first = %ToolCallResponse{content: nil, tool_calls: [probe_call()]}
    second = %ToolCallResponse{content: "done", tool_calls: nil}

    deps = %{
      call_llm: fn _req ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        {:ok, if(n == 0, do: first, else: second)}
      end,
      dispatch: fn calls ->
        Enum.map(
          calls,
          &Dispatch.dispatch_one(config, &1, AgentHandlers.base_agent_pipeline(config))
        )
      end,
      append: fn _role, _content -> :ok end,
      emit: fn _name, _meta -> :ok end
    }

    assert {:ok, %{stop_reason: :completed}} =
             TurnShell.run(Turn.new(max_iterations: 5, response_model: :rm), deps)

    assert_receive {:probe_ctx, %Context{values: %{memory_namespace: "acme/inline"}}}
  end

  test "base_agent_pipeline/1 (used by every interpreter) passes the context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/u-2"}})

    assert %ToolResult{is_error: false, output: ~s(ns="acme/u-2")} =
             Dispatch.dispatch_one(
               config,
               probe_call(),
               AgentHandlers.base_agent_pipeline(config)
             )
  end

  test "default_pipeline/0 passes the context" do
    config = %{
      name: "a",
      toolset: Toolset.new([%ContextProbe{}]),
      tool_context: %{memory_namespace: "n"}
    }

    assert %ToolResult{is_error: false, output: ~s(ns="n")} =
             Dispatch.dispatch_one(config, probe_call(), Dispatch.default_pipeline())
  end

  test "a user arity-3 execute_fn gets the invocation, without the call" do
    parent = self()
    config = %{name: "a", toolset: Toolset.new([%ContextProbe{}])}

    execute_fn = fn _config, invocation, name ->
      send(parent, {:invocation, invocation, name})
      {:ok, "ran"}
    end

    pipeline = %{Dispatch.default_pipeline() | execute_fn: execute_fn}

    assert %ToolResult{is_error: false, output: "ran"} =
             Dispatch.dispatch_one(config, probe_call(), pipeline)

    assert_received {:invocation, %Dispatch.Invocation{tool: %ContextProbe{}, input: %{}},
                     "probe"}
  end
end
