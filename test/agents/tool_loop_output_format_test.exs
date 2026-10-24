defmodule Normandy.Agents.ToolLoopOutputFormatTest do
  @moduledoc """
  Task 5.1 (AX-1, decision 11): a tool-using agent with a non-chat output schema sends
  that schema as `output_config.format` beside its tools, on `run/3`, `stream/3` and
  under `Turn.Server`, and gets the typed struct back on the structured path and on
  both fallback paths (structured outputs off, the schema refused with a 400).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLM.Request
  alias Normandy.LLMError
  alias Normandy.Schema.ValidationError
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true, enum: ["approve", "deny"])
    end
  end

  @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @rejection %{
    "type" => "error",
    "error" => %{
      "type" => "invalid_request_error",
      "message" => "output_config.format.schema: unsupported keyword"
    }
  }

  defp text(text), do: %{"type" => "text", "text" => text}

  defp agent(client, output_schema \\ %Decision{}) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      output_schema: output_schema,
      toolset: Toolset.new([%FakeTool{}])
    })
  end

  defp server_run(config, session_id) do
    {:ok, srv} =
      Server.start_link(
        session_id: session_id,
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    Server.run(srv, %{chat_message: "decide"})
  end

  defp streamed_text(text) do
    WireScript.message(
      "msg_s",
      WireScript.block(0, text(""), [%{"type" => "text_delta", "text" => text}]),
      "end_turn"
    )
  end

  defp format(body), do: get_in(body, ["output_config", "format"])

  describe "the request" do
    defp stub_agent(output_schema) do
      %StubClient{notify: self(), reply: fn rm -> %{rm | content: ~s({"action": "deny"})} end}
      |> agent(output_schema)
    end

    test "a tool-loop call carries the non-chat output schema as output_format" do
      assert {:ok, _config, %Decision{action: "deny"}} =
               BaseAgent.run(stub_agent(%Decision{}), %{chat_message: "decide"})

      assert_receive {:converse,
                      %Request{response_model: %ToolCallResponse{}, output_format: %Decision{}},
                      _opts}
    end

    test "a chat agent's tool-loop call carries none" do
      assert {:ok, _config, _output} =
               BaseAgent.run(stub_agent(nil), %{chat_message: "hi"})

      assert_receive {:converse, %Request{response_model: %ToolCallResponse{}} = request, _}
      assert request.output_format == nil
    end

    test "a call without tools carries none: its response model is the format" do
      config =
        BaseAgent.init(%{
          client: %StubClient{notify: self(), reply: fn _rm -> %Decision{action: "deny"} end},
          model: "claude-opus-5-5",
          output_schema: %Decision{}
        })

      assert {:ok, _config, %Decision{}} = BaseAgent.run(config, %{chat_message: "decide"})
      assert_receive {:converse, %Request{response_model: %Decision{}} = request, _}
      assert request.output_format == nil
    end

    test "under Turn.Server the tool-loop call carries it too" do
      assert {:ok, %Decision{action: "deny"}} =
               server_run(stub_agent(%Decision{}), "s-output-format")

      assert_receive {:converse, %Request{output_format: %Decision{}}, _opts}
    end
  end

  describe "on the wire" do
    test "run/3 sends output_config.format with the tools on every loop call" do
      client =
        WireScript.client([
          {:json, [@tool_use], "tool_use"},
          {:json, [text(~s({"action": "deny"}))], "end_turn"}
        ])

      assert {:ok, _config, %Decision{action: "deny"}} =
               BaseAgent.run(agent(client), %{chat_message: "decide"})

      for n <- [0, 1] do
        assert_receive {:wire_body, ^n, body}
        assert %{"type" => "json_schema", "schema" => schema} = format(body)
        assert Map.has_key?(schema["properties"], "action")
        assert [%{"name" => "weather"}] = body["tools"]
      end
    end

    test "stream/3 sends it too" do
      client = WireScript.client([{:sse, streamed_text(~s({"action": "approve"}))}])

      assert {:ok, _config, %Decision{action: "approve"}} =
               BaseAgent.stream(agent(client), %{chat_message: "decide"}, fn _ -> :ok end)

      assert_receive {:wire_body, 0, body}
      assert %{"type" => "json_schema"} = format(body)
    end

    test "llm_call start reports structured_output: true for a tool-loop call and a stream" do
      name = "fmt-#{System.unique_integer([:positive])}"
      ref = TelemetryCapture.attach([[:normandy, :agent, :llm_call, :start]], agent_name: name)

      client =
        WireScript.client([
          {:json, [text(~s({"action": "deny"}))], "end_turn"},
          {:sse, streamed_text(~s({"action": "deny"}))}
        ])

      config = %{agent(client) | name: name}
      assert {:ok, config, %Decision{}} = BaseAgent.run(config, %{chat_message: "x"})

      assert {:ok, _, %Decision{}} =
               BaseAgent.stream(config, %{chat_message: "x"}, fn _ -> :ok end)

      assert_received {:telemetry, ^ref, _, %{stream: false, structured_output: true}}
      assert_received {:telemetry, ^ref, _, %{stream: true, structured_output: true}}
    end

    test "a chat agent's stream sends none" do
      client = WireScript.client([{:sse, streamed_text("Hello.")}])

      assert {:ok, _config, %{chat_message: "Hello."}} =
               BaseAgent.stream(agent(client, nil), "hi", fn _ -> :ok end)

      assert_receive {:wire_body, 0, body}
      assert format(body) == nil
    end
  end

  # Review Focus #1: the answer arrives on a fallback path. Each route gives the
  # parsed struct, :invalid_output (undecodable) or ValidationError (decoded, invalid),
  # never a %ToolCallResponse{}.
  describe "the fallback paths" do
    @outcomes [
      {~s({"action": "deny"}), :parsed},
      {"I would deny it.", :invalid_output},
      {~s({"action": "delete_everything"}), :validation_error}
    ]

    # :off has structured outputs switched off; :rejected has the schema refused by a
    # 400, then the same request re-sent without it.
    defp sync_client(:off, answer),
      do: WireScript.client([{:json, [text(answer)], "end_turn"}], %{structured_outputs: false})

    defp sync_client(:rejected, answer),
      do:
        WireScript.client([
          {:status, 400, @rejection},
          {:json, [text(answer)], "end_turn"}
        ])

    defp stream_client(:off, answer),
      do: WireScript.client([{:sse, streamed_text(answer)}], %{structured_outputs: false})

    defp stream_client(:rejected, answer),
      do:
        WireScript.client([
          {:status, 400, @rejection},
          {:sse, streamed_text(answer)}
        ])

    defp assert_outcome(result, :parsed), do: assert({:ok, %Decision{action: "deny"}} = result)

    defp assert_outcome(result, :invalid_output),
      do: assert({:error, %LLMError{type: :invalid_output}} = result)

    defp assert_outcome(result, :validation_error),
      do: assert({:error, %ValidationError{}} = result)

    defp without_config({:ok, _config, output}), do: {:ok, output}
    defp without_config(error), do: error

    for route <- [:off, :rejected], {answer, outcome} <- @outcomes do
      @route route
      @answer answer
      @outcome outcome

      test "run/3, #{route}: #{outcome}" do
        @route
        |> sync_client(@answer)
        |> agent()
        |> BaseAgent.run(%{chat_message: "decide"})
        |> without_config()
        |> assert_outcome(@outcome)

        # The request that produced the answer: the only one, or the re-sent one.
        answered = if @route == :off, do: 0, else: 1
        assert_received {:wire_body, ^answered, body}
        assert format(body) == nil
        # Caching is on by default (MIGRATING-2.0.md §38): the system prompt is one block.
        assert [%{"text" => system, "cache_control" => %{"type" => "ephemeral"}}] = body["system"]
        assert system =~ "# OUTPUT SCHEMA"
      end

      test "stream/3, #{route}: #{outcome}" do
        @route
        |> stream_client(@answer)
        |> agent()
        |> BaseAgent.stream(%{chat_message: "decide"}, fn _ -> :ok end)
        |> without_config()
        |> assert_outcome(@outcome)
      end

      test "Turn.Server, #{route}: #{outcome}" do
        @route
        |> sync_client(@answer)
        |> agent()
        |> server_run("s-fallback-#{@route}-#{@outcome}")
        |> assert_outcome(@outcome)
      end
    end

    test "the rejected request carried the format; the re-sent one does not" do
      client = sync_client(:rejected, ~s({"action": "deny"}))
      assert {:ok, _config, %Decision{}} = BaseAgent.run(agent(client), %{chat_message: "x"})

      assert_receive {:wire_body, 0, first}
      assert_receive {:wire_body, 1, second}
      assert %{"type" => "json_schema"} = format(first)
      assert format(second) == nil
      assert Map.delete(first, "output_config") == Map.delete(second, "output_config")
    end
  end
end
