defmodule Normandy.Agents.BaseAgentStreamTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
  alias Normandy.Components.StreamEvent
  alias Normandy.LLMError
  alias Normandy.Test.ScriptedTextClient

  defmodule Answer do
    use Normandy.Schema

    io_schema "An answer" do
      field(:answer, :string, required: true)
    end
  end

  defp agent(client, extra \\ %{}),
    do: BaseAgent.init(Map.merge(%{client: client, model: "m"}, extra))

  defp collect do
    test_pid = self()
    fn %StreamEvent{} = event -> send(test_pid, {:event, event}) end
  end

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  test "stream/3 and run/2 return the same chat output" do
    client = %ScriptedTextClient{text: "Actors share nothing."}

    assert {:ok, _, %BaseAgentOutputSchema{chat_message: "Actors share nothing."} = streamed} =
             BaseAgent.stream(agent(client), %{chat_message: "hi"}, collect())

    assert {:ok, _, ^streamed} = BaseAgent.run(agent(client), %{chat_message: "hi"})
  end

  test "stream/3 and run/2 return the same struct for a non-chat schema" do
    client = %ScriptedTextClient{text: ~s({"answer": "42"})}
    a = agent(client, %{output_schema: %Answer{}})

    assert {:ok, _, %Answer{answer: "42"} = streamed} = BaseAgent.stream(a, "q", collect())
    assert {:ok, _, ^streamed} = BaseAgent.run(a, "q")
  end

  test "the callback receives %StreamEvent{} in order" do
    BaseAgent.stream(agent(%ScriptedTextClient{text: "abcd"}), "hi", collect())

    assert [
             %StreamEvent{type: :message_start, data: %{id: "msg_1", model: "m"}},
             %StreamEvent{type: :text_delta, data: "ab"},
             %StreamEvent{type: :text_delta, data: "cd"},
             %StreamEvent{type: :message_stop, data: nil}
           ] = events()
  end

  test "a non-chat schema is shown in the streaming system prompt; a chat schema is not" do
    client = %ScriptedTextClient{text: ~s({"answer": "42"}), notify: self()}

    BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
    assert_received {:stream_request, %{system: answer_prompt}}
    assert answer_prompt =~ "# OUTPUT SCHEMA"

    BaseAgent.stream(agent(%{client | text: "hi"}), "q", collect())
    assert_received {:stream_request, %{system: chat_prompt}}
    refute chat_prompt =~ "# OUTPUT SCHEMA"
  end

  test "a non-chat answer that isn't JSON is the error run/2 would give" do
    client = %ScriptedTextClient{text: "not json at all", options: %{on_parse_failure: :error}}

    assert {:error, %LLMError{type: :invalid_output}} =
             BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
  end

  test "a stream that fails after output reached the callback is not retried" do
    calls = :counters.new(1, [])
    client = %ScriptedTextClient{text: "abcd", fail_after_first_delta: true, calls: calls}
    a = agent(client, %{retry_options: [max_attempts: 3, base_delay: 1]})

    assert {:error, %LLMError{type: :stream}} = BaseAgent.stream(a, "hi", collect())
    assert :counters.get(calls, 1) == 1

    assert [%StreamEvent{type: :message_start}, %StreamEvent{type: :text_delta, data: "ab"}] =
             events()
  end

  test "a client that can't stream gives {:error, %LLMError{type: :unsupported}}" do
    assert {:error, %LLMError{type: :unsupported}} =
             BaseAgent.stream(agent(%Normandy.Test.StubClient{}), "hi", collect())
  end

  test "the old entry points are gone" do
    Code.ensure_loaded!(BaseAgent)
    refute function_exported?(BaseAgent, :run_with_tools, 2)
    refute function_exported?(BaseAgent, :stream_response, 3)
    refute function_exported?(BaseAgent, :stream_with_tools, 3)
  end

  test "run/3 rejects any option" do
    error =
      assert_raise ArgumentError, fn ->
        BaseAgent.run!(agent(%ScriptedTextClient{text: "x"}), "hi", max_turns: 2)
      end

    assert error.message =~ "unknown options [:max_turns]"
    refute error.message =~ "stream/3"
  end

  test "run/3 rejects the old streaming options with a stream/3 hint" do
    assert_raise ArgumentError, ~r/BaseAgent.stream\/3/, fn ->
      BaseAgent.run(agent(%ScriptedTextClient{text: "x"}), "hi", stream: true, on_chunk: & &1)
    end
  end
end
