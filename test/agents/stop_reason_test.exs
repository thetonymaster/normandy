defmodule Normandy.Agents.StopReasonTest do
  @moduledoc """
  A response cut off at max_tokens (or context-window exhaustion) or refused is an
  error on every turn path, before the core sees it: no tool runs, nothing is appended.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Components.ToolCall
  alias Normandy.LLM.Response
  alias Normandy.LLMError
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture

  # The first call's tool_use was cut off mid-input.
  defp cut_off_tool_call(stop_reason) do
    fn
      %ToolCallResponse{} = rm ->
        {:ok,
         %Response{
           content: %{
             rm
             | tool_calls: [%ToolCall{id: "toolu_1", name: "weather", input: %{"city" => "Par"}}]
           },
           stop_reason: stop_reason,
           usage: %{"input_tokens" => 5, "output_tokens" => 7}
         }}
    end
  end

  defp tool_agent(stop_reason, extra \\ %{}) do
    %{
      client: %StubClient{notify: self(), reply: cut_off_tool_call(stop_reason)},
      model: "m",
      max_tokens: 64
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%FakeTool{notify: self()})
  end

  describe "run/3 (sync)" do
    test "a tool_use cut off at max_tokens is an error and the tool never runs" do
      assert {:error, %LLMError{type: :max_tokens, reason: {:stop_reason, :max_tokens}}} =
               BaseAgent.run(tool_agent(:max_tokens), "weather in Paris?")

      assert_received {:converse, _request, _opts}
      refute_received {:converse, _request, _opts}
      refute_received {:tool_ran, _}
    end

    test "context-window exhaustion is the :max_tokens error, naming the reason" do
      assert {:error, %LLMError{type: :max_tokens} = error} =
               BaseAgent.run(tool_agent(:model_context_window_exceeded), "weather?")

      assert error.reason == {:stop_reason, :model_context_window_exceeded}
      refute_received {:tool_ran, _}
    end

    test "a refusal is the :refusal error" do
      assert {:error, %LLMError{type: :refusal}} =
               BaseAgent.run(tool_agent(:refusal), "weather?")

      refute_received {:tool_ran, _}
    end

    test "a truncated chat answer (no tools) is an error, not a partial success" do
      agent =
        BaseAgent.init(%{
          client: %StubClient{
            reply: fn rm ->
              {:ok,
               %Response{content: %{rm | chat_message: "The answer is"}, stop_reason: :max_tokens}}
            end
          },
          model: "m"
        })

      assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "question")
    end

    test "is neither retried nor counted by the circuit breaker" do
      agent =
        tool_agent(:max_tokens, %{
          retry: [max_attempts: 3, base_delay: 0, max_delay: 0, jitter: false],
          circuit_breaker: [failure_threshold: 1, scope: {__MODULE__, :not_counted}]
        })

      assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "a")
      assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "b")

      # One request per run: no retry, and the breaker (threshold 1) never opened.
      assert_received {:converse, _, _}
      assert_received {:converse, _, _}
      refute_received {:converse, _, _}
    end
  end

  describe "Turn.Server" do
    test "replies the bare :max_tokens LLMError and stores no assistant row" do
      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-max-tokens",
          config: tool_agent(:max_tokens),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:error, %LLMError{type: :max_tokens}} = Server.run(srv, %{chat_message: "go"})
      refute_received {:tool_ran, _}

      {:ok, entries} = InMemory.history(store, "s-max-tokens")
      assert Enum.map(entries, & &1.role) == ["user"]
    end
  end

  # Streams a tool_use whose input is cut off, then stops with `stop_reason`.
  defmodule CutOffStream do
    defstruct stop_reason: "max_tokens", options: %{}

    defimpl Normandy.Agents.Model do
      def converse(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}

      def stream(client, _request, _opts) do
        {:ok,
         [
           %{
             type: "message_start",
             message: %{"id" => "msg_1", "model" => "m", "role" => "assistant"}
           },
           %{
             type: "content_block_start",
             index: 0,
             content_block: %{"type" => "text", "text" => ""}
           },
           %{
             type: "content_block_delta",
             index: 0,
             delta: %{"type" => "text_delta", "text" => "Checking"}
           },
           %{type: "content_block_stop", index: 0},
           %{
             type: "content_block_start",
             index: 1,
             content_block: %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "weather",
               "input" => %{}
             }
           },
           %{
             type: "content_block_delta",
             index: 1,
             delta: %{"type" => "input_json_delta", "partial_json" => ~s({"city": "Pa)}
           },
           %{type: "content_block_stop", index: 1},
           %{
             type: "message_delta",
             delta: %{"stop_reason" => client.stop_reason},
             usage: %{"output_tokens" => 64}
           },
           %{type: "message_stop"}
         ]}
      end
    end
  end

  describe "stream/3" do
    test "a streamed tool_use cut off at max_tokens is an error; delivered text stays delivered" do
      agent =
        %{client: %CutOffStream{}, model: "m", max_tokens: 64}
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%FakeTool{notify: self()})

      test_pid = self()

      assert {:error, %LLMError{type: :max_tokens, usage: %{"output_tokens" => 64}}} =
               BaseAgent.stream(agent, "weather?", &send(test_pid, {:event, &1}))

      assert_received {:event, %StreamEvent{type: :text_delta, data: "Checking"}}
      refute_received {:tool_ran, _}
    end

    test "a streamed refusal is the :refusal error" do
      agent = BaseAgent.init(%{client: %CutOffStream{stop_reason: "refusal"}, model: "m"})

      assert {:error, %LLMError{type: :refusal}} =
               BaseAgent.stream(agent, "weather?", fn _ -> :ok end)
    end

    test "the error ends the llm_call span as :exception" do
      agent = BaseAgent.init(%{client: %CutOffStream{}, model: "m"})

      ref =
        TelemetryCapture.attach(
          [[:normandy, :agent, :llm_call, :exception]],
          fn _ -> true end
        )

      BaseAgent.stream(agent, "weather?", fn _ -> :ok end)

      assert_received {:telemetry, ^ref, _, %{reason: %LLMError{type: :max_tokens}}}
    end
  end
end
