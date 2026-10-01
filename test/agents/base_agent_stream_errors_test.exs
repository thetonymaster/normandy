defmodule Normandy.Agents.BaseAgentStreamErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings
  alias Normandy.LLMError

  # stream_converse/7 returns {:ok, events} (a list is Enumerable) or {:error, reason}.
  defmodule EventsClient do
    defstruct events: [], connect_error: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentStreamErrorsTest.EventsClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model
    def converse(_c, _m, _t, _mt, _msgs, response_model, _opts), do: response_model

    def stream_converse(%{connect_error: nil} = client, _m, _t, _mt, _msgs, _rm, _opts),
      do: {:ok, client.events}

    def stream_converse(client, _m, _t, _mt, _msgs, _rm, _opts),
      do: {:error, client.connect_error}
  end

  defp start, do: %{type: "message_start", message: %{"id" => "m", "role" => "assistant"}}

  defp block,
    do: %{type: "content_block_start", content_block: %{"type" => "text", "text" => ""}, index: 0}

  defp delta(text),
    do: %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}, index: 0}

  defp error_event,
    do: %{type: "error", error: %{"type" => "overloaded_error", "message" => "Overloaded"}}

  defp agent(events, extra \\ %{}) do
    BaseAgent.init(
      Map.merge(
        %{client: %EventsClient{events: events}, model: "claude-opus-5-5", temperature: nil},
        extra
      )
    )
  end

  defp stream(agent),
    do: BaseAgent.stream_response(agent, %{chat_message: "hi"}, fn _, _ -> :ok end)

  @incremental %{
    output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
    output_guardrails_streaming_mode: :incremental,
    output_guardrails_chunk_size: 5
  }

  test "a mid-stream error event raises" do
    agent = agent([start(), block(), delta("Hel"), error_event()])

    assert_raise LLMError, "LLM call failed: stream: Overloaded", fn -> stream(agent) end
  end

  test "an {:error, _} item in the stream raises" do
    agent = agent([start(), block(), delta("Hel"), {:error, :closed}])

    assert %LLMError{type: :stream, reason: :closed} =
             assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "a stream that ends without message_stop raises" do
    agent = agent([start(), block(), delta("Hel")])

    assert_raise LLMError, ~r/stream ended before message_stop/, fn -> stream(agent) end
  end

  test "a connection-time error raises it" do
    e = LLMError.new(type: :rate_limit, status: 429, retryable?: true)

    agent =
      BaseAgent.init(%{
        client: %EventsClient{connect_error: e},
        model: "claude-opus-5-5",
        temperature: nil
      })

    assert ^e = assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "incremental guardrails: a mid-stream error event raises (not a guardrail halt)" do
    agent = agent([start(), block(), delta("Hello there"), error_event()], @incremental)

    assert_raise LLMError, ~r/Overloaded/, fn -> stream(agent) end
  end

  test "incremental guardrails: an {:error, _} item raises" do
    agent = agent([start(), block(), delta("Hello there"), {:error, :closed}], @incremental)

    assert %LLMError{type: :stream, reason: :closed} =
             assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "incremental guardrails: a tail-check violation does not mask a stream error" do
    config = Map.put(@incremental, :output_guardrails, [{ForbiddenSubstrings, terms: ["badwd"]}])
    config = Map.put(config, :output_guardrails_chunk_size, 100)
    agent = agent([start(), block(), delta("badwd"), error_event()], config)

    assert_raise LLMError, ~r/Overloaded/, fn -> stream(agent) end
  end

  test "incremental guardrails: a violation halt is not an error" do
    agent =
      agent([start(), block(), delta("this has a badword in it"), delta(" more")], @incremental)

    {_agent, response} = stream(agent)
    assert response.guardrail_violations != []
  end
end
