defmodule Normandy.LLM.ClaudioAdapterThinkingTest do
  @moduledoc """
  A thinking model needs the thinking blocks of the assistant message that
  carries tool calls when the tool results go back. These tests follow the
  blocks from the response to the next request.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Test.FakeTool
  alias Normandy.Tools.Registry

  # A context provider whose text changes on every call, so each request's
  # system prompt differs from the last.
  defmodule CountingProvider do
    defstruct [:counter]

    defimpl Normandy.Components.ContextProvider do
      def title(_), do: "Call"

      def get_info(%{counter: counter}) do
        :counters.add(counter, 1, 1)
        "call #{:counters.get(counter, 1)}"
      end
    end
  end

  @thinking %{"type" => "thinking", "thinking" => "check the weather", "signature" => "sig1"}
  @redacted %{"type" => "redacted_thinking", "data" => "opaque"}
  @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}

  defp client(name),
    do: %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, name}, retry: false]}
    }

  defp reply_with(name, content) do
    Req.Test.stub(name, fn conn ->
      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => content,
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)
  end

  defp converse(name) do
    Model.converse(
      client(name),
      "claude-opus-5-5",
      nil,
      1024,
      [%Message{role: "user", content: "weather?"}],
      %ToolCallResponse{},
      tools: [%{name: "weather", description: "w", input_schema: %{type: "object"}}]
    )
  end

  describe "non-streaming" do
    test "a tool-call response keeps its thinking blocks in order" do
      reply_with(__MODULE__.Keep, [@thinking, @redacted, @tool_use])

      assert {%ToolCallResponse{} = response, _usage, _meta} = converse(__MODULE__.Keep)
      assert response.thinking == [@thinking, @redacted]
      assert [%{id: "t1"}] = response.tool_calls
    end

    test "thinking from a model that declined (before a fallback block) is dropped" do
      fallback = %{"type" => "fallback", "model" => "b"}
      served = %{@thinking | "signature" => "sig2"}
      reply_with(__MODULE__.Fallback, [@thinking, fallback, served, @tool_use])

      assert {response, _usage, _meta} = converse(__MODULE__.Fallback)
      assert response.thinking == [served]
    end
  end

  describe "tool loop" do
    # First call: thinking + a tool call. Second call: the final answer. Each
    # request body is sent to the test process.
    defp script(name) do
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        n = Agent.get_and_update(calls, &{&1, &1 + 1})

        {content, stop} =
          if n == 0,
            do: {[@thinking, @redacted, @tool_use], "tool_use"},
            else: {[%{"type" => "text", "text" => "Sunny."}], "end_turn"}

        Req.Test.json(conn, %{
          "id" => "msg_#{n}",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => content,
          "stop_reason" => stop,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)
    end

    test "the tool results go back after the thinking blocks that came with the call" do
      script(__MODULE__.Loop)

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.Loop),
          model: "claude-opus-5-5",
          tool_registry: Registry.new([%FakeTool{}])
        })

      BaseAgent.run_with_tools(agent, "weather?")

      assert_received {:body, _first}
      assert_received {:body, second}

      assert [_user, %{"role" => "assistant", "content" => assistant}, _results] =
               second["messages"]

      assert [@thinking, @redacted, %{"type" => "tool_use", "id" => "t1"}] = assistant
    end
  end

  describe "a changed system prompt" do
    test "the forced final call at max_tool_iterations does not replay the loop's thinking" do
      script(__MODULE__.Forced)

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.Forced),
          model: "claude-opus-5-5",
          tool_registry: Registry.new([%FakeTool{}]),
          max_tool_iterations: 1
        })

      BaseAgent.run_with_tools(agent, "weather?")

      assert_received {:body, first}
      assert_received {:body, forced}

      # The forced call asks for the output schema, so its system prompt differs and
      # the loop's thinking no longer applies; the tool call itself still goes back.
      refute first["system"] == forced["system"]
      assistant = Enum.find(forced["messages"], &(&1["role"] == "assistant"))
      assert [%{"type" => "tool_use", "id" => "t1"}] = assistant["content"]
    end
  end

  describe "a changed model" do
    test "thinking produced by another model is not replayed" do
      script(__MODULE__.ModelChange)

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.ModelChange),
          model: "claude-opus-5-5",
          tool_registry: Registry.new([%FakeTool{}])
        })

      {agent, _} = BaseAgent.run_with_tools(agent, "weather?")
      BaseAgent.run_with_tools(%{agent | model: "claude-sonnet-5-5"}, "and tomorrow?")

      assert_received {:body, _first}
      assert_received {:body, _second}
      assert_received {:body, third}

      assistant = Enum.find(third["messages"], &(&1["role"] == "assistant"))
      assert [%{"type" => "tool_use", "id" => "t1"}] = assistant["content"]
    end

    test "thinking from a fallback model is not replayed to the requested model" do
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      fallback = %{"type" => "fallback", "to" => %{"model" => "claude-sonnet-5-5"}}
      served = %{@thinking | "signature" => "sig-b"}

      Req.Test.stub(__MODULE__.FallbackModel, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        n = Agent.get_and_update(calls, &{&1, &1 + 1})

        {content, stop} =
          if n == 0,
            do: {[@thinking, fallback, served, @tool_use], "tool_use"},
            else: {[%{"type" => "text", "text" => "Sunny."}], "end_turn"}

        Req.Test.json(conn, %{
          "id" => "msg_#{n}",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => content,
          "stop_reason" => stop,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.FallbackModel),
          model: "claude-opus-5-5",
          tool_registry: Registry.new([%FakeTool{}])
        })

      BaseAgent.run_with_tools(agent, "weather?")

      assert_received {:body, _first}
      assert_received {:body, second}
      assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))
      assert [%{"type" => "tool_use", "id" => "t1"}] = assistant["content"]
    end
  end

  describe "streaming" do
    defp sse(events) do
      Enum.map_join(events, fn data ->
        "event: #{data["type"]}\ndata: #{Jason.encode!(data)}\n\n"
      end)
    end

    defp block(index, block, deltas) do
      [%{"type" => "content_block_start", "index" => index, "content_block" => block}] ++
        Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
        [%{"type" => "content_block_stop", "index" => index}]
    end

    defp message(id, blocks, stop) do
      [
        %{
          "type" => "message_start",
          "message" => %{
            "id" => id,
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-opus-5-5",
            "content" => [],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
          }
        }
      ] ++
        blocks ++
        [
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => stop},
            "usage" => %{"output_tokens" => 1}
          },
          %{"type" => "message_stop"}
        ]
    end

    defp stream_script(name) do
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      first =
        message(
          "msg_0",
          block(0, %{"type" => "thinking", "thinking" => ""}, [
            %{"type" => "thinking_delta", "thinking" => "check the weather"},
            %{"type" => "signature_delta", "signature" => "sig1"}
          ]) ++
            block(1, @redacted, []) ++
            block(2, %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}, [
              %{"type" => "input_json_delta", "partial_json" => "{}"}
            ]),
          "tool_use"
        )

      second =
        message(
          "msg_1",
          block(0, %{"type" => "text", "text" => ""}, [
            %{"type" => "text_delta", "text" => "Sunny."}
          ]),
          "end_turn"
        )

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        n = Agent.get_and_update(calls, &{&1, &1 + 1})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse(if n == 0, do: first, else: second))
      end)
    end

    test "thinking from a different system prompt is not replayed" do
      stream_script(__MODULE__.StreamChanged)

      agent =
        %{
          client: client(__MODULE__.StreamChanged),
          model: "claude-opus-5-5",
          tool_registry: Registry.new([%FakeTool{}])
        }
        |> BaseAgent.init()
        |> BaseAgent.register_context_provider("call", %CountingProvider{
          counter: :counters.new(1, [])
        })

      BaseAgent.stream_with_tools(agent, "weather?", fn _, _ -> :ok end)

      assert_received {:body, first}
      assert_received {:body, second}
      refute first["system"] == second["system"]

      assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))
      assert [%{"type" => "tool_use", "id" => "t1"}] = assistant["content"]
    end

    test "the tool results go back after the streamed thinking blocks" do
      stream_script(__MODULE__.Stream)

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.Stream),
          model: "claude-opus-5-5",
          tool_registry: Registry.new([%FakeTool{}])
        })

      BaseAgent.stream_with_tools(agent, "weather?", fn _, _ -> :ok end)

      assert_received {:body, _first}
      assert_received {:body, second}

      assert [_user, %{"role" => "assistant", "content" => assistant}, _results] =
               second["messages"]

      assert [@thinking, @redacted, %{"type" => "tool_use", "id" => "t1"}] = assistant
    end
  end
end
