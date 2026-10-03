defmodule Normandy.Agents.ToolContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch, ToolCallResponse, Turn}
  alias Normandy.Agents.Turn.Inline
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, ScriptedToolClient}
  alias Normandy.Tools.{Context, Executor, Registry}

  defmodule StreamingProbeClient do
    @moduledoc false
    defstruct options: %{}

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model
      def converse(_c, _m, _t, _mt, _msgs, response_model, _opts), do: response_model

      def stream_converse(_c, _m, _t, _mt, messages, _response_model, _opts) do
        events =
          if Enum.any?(messages, &(Map.get(&1, :role) == "tool")) do
            [
              %{type: "message_start", message: %{"id" => "m2", "role" => "assistant"}},
              %{
                type: "content_block_start",
                content_block: %{"type" => "text", "text" => ""},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => "done"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          else
            [
              %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
              %{
                type: "content_block_start",
                content_block: %{"type" => "tool_use", "id" => "call_1", "name" => "probe"},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => "{}"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  defp probe_call, do: %ToolCall{id: "call_1", name: "probe", input: %{}}

  defp agent(extra \\ %{}) do
    %{client: %ScriptedToolClient{calls: [probe_call()]}, model: "test", name: "ctx-agent"}
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: self()})
  end

  test "init/1 defaults tool_context to %{} and rejects a non-map" do
    assert agent().tool_context == %{}

    assert_raise ArgumentError, ~r/tool_context must be a map/, fn ->
      BaseAgent.init(%{client: %ScriptedToolClient{}, model: "test", tool_context: [a: 1]})
    end
  end

  test "a BaseAgent turn hands the contextual tool the session's context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/u-1"}})

    {_config, _response} = BaseAgent.run_with_tools(config, %{chat_message: "go"})

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
      agent(%{client: %StreamingProbeClient{}, tool_context: %{memory_namespace: "acme/stream"}})

    {_config, _response} =
      BaseAgent.stream_with_tools(config, %{chat_message: "go"}, fn _, _ -> :ok end)

    assert_receive {:probe_ctx,
                    %Context{tool_call_id: "call_1", values: %{memory_namespace: "acme/stream"}}}
  end

  test "Turn.Inline over base_agent_pipeline/1 hands the contextual tool the context" do
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
        Enum.map(calls, &Dispatch.dispatch_one(config, &1, BaseAgent.base_agent_pipeline(config)))
      end,
      append: fn _role, _content -> :ok end,
      emit: fn _name, _meta -> :ok end
    }

    assert {:ok, %{stop_reason: :completed}} =
             Inline.run(Turn.new(max_iterations: 5, response_model: :rm), deps)

    assert_receive {:probe_ctx, %Context{values: %{memory_namespace: "acme/inline"}}}
  end

  test "base_agent_pipeline/1 (used by every interpreter) passes the context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/u-2"}})

    assert %ToolResult{is_error: false, output: ~s(ns="acme/u-2")} =
             Dispatch.dispatch_one(config, probe_call(), BaseAgent.base_agent_pipeline(config))
  end

  test "default_pipeline/0 passes the context" do
    config = %{
      name: "a",
      tool_registry: Registry.new([%ContextProbe{}]),
      tool_context: %{memory_namespace: "n"}
    }

    assert %ToolResult{is_error: false, output: ~s(ns="n")} =
             Dispatch.dispatch_one(config, probe_call(), Dispatch.default_pipeline())
  end

  test "a user arity-3 execute_fn has no call, so a contextual tool returns its error" do
    config = %{name: "a", tool_registry: Registry.new([%ContextProbe{}])}

    pipeline = %{
      Dispatch.default_pipeline()
      | execute_fn: fn _config, tool, _name -> Executor.execute_tool(tool) end
    }

    assert %ToolResult{is_error: true, output: %{error: msg}} =
             Dispatch.dispatch_one(config, probe_call(), pipeline)

    assert msg =~ "requires tool context"
  end
end
