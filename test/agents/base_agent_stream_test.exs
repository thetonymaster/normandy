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

  # A struct with no JSON Schema and no :chat_message: nothing to parse the answer into.
  defmodule PlainOut do
    defstruct answer: nil
  end

  # One tool round, then `:text` as the final answer, for run/2 (converse/3) and
  # stream/3 alike. `:text` may be "" (an empty final answer). With `:final`, converse/3
  # answers that struct as the response content instead.
  defmodule ToolThenText do
    defstruct text: "", final: nil, options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall
      alias Normandy.LLM.Response

      def converse(client, request, _opts) do
        content =
          cond do
            not tool_result?(request) ->
              %ToolCallResponse{
                content: nil,
                tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{"city" => "Oslo"}}]
              }

            client.final ->
              client.final

            true ->
              %ToolCallResponse{content: client.text, tool_calls: []}
          end

        {:ok, %Response{content: content, stop_reason: :end_turn}}
      end

      def stream(client, request, _opts) do
        start = %{
          type: "message_start",
          message: %{"id" => "msg_1", "model" => "m", "role" => "assistant"}
        }

        blocks =
          cond do
            not tool_result?(request) ->
              [
                %{
                  type: "content_block_start",
                  index: 0,
                  content_block: %{"type" => "tool_use", "id" => "t1", "name" => "weather"}
                },
                %{
                  type: "content_block_delta",
                  index: 0,
                  delta: %{"type" => "input_json_delta", "partial_json" => ~s({"city":"Oslo"})}
                },
                %{type: "content_block_stop", index: 0}
              ]

            client.text == "" ->
              []

            true ->
              [
                %{
                  type: "content_block_start",
                  index: 0,
                  content_block: %{"type" => "text", "text" => ""}
                },
                %{
                  type: "content_block_delta",
                  index: 0,
                  delta: %{"type" => "text_delta", "text" => client.text}
                },
                %{type: "content_block_stop", index: 0}
              ]
          end

        {:ok, [start | blocks] ++ [%{type: "message_stop"}]}
      end

      defp tool_result?(request), do: Enum.any?(request.messages, &(&1.role == "tool"))
    end
  end

  defp tool_agent(client, extra \\ %{}),
    do: client |> agent(extra) |> BaseAgent.register_tool(%Normandy.Test.FakeTool{})

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

    assert {:error, %LLMError{type: :invalid_output} = streamed} =
             BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())

    # The same answer after a tool loop in run/2 is the same error.
    tool_client = %ToolThenText{text: "not json at all", options: %{on_parse_failure: :error}}

    assert {:error, %LLMError{type: :invalid_output} = ran} =
             BaseAgent.run(tool_agent(tool_client, %{output_schema: %Answer{}}), "q")

    assert Map.take(ran, [:type, :message, :reason, :retryable?]) ==
             Map.take(streamed, [:type, :message, :reason, :retryable?])
  end

  describe "one output conversion for run/2's tool loop and stream/3" do
    test "a schema without a JSON Schema is :invalid_output, never a raise or a raw map" do
      client = %ToolThenText{text: ~s({"answer":"hi"})}
      a = tool_agent(client, %{output_schema: %PlainOut{}})

      assert {:error, %LLMError{type: :invalid_output} = ran} = BaseAgent.run(a, "q")

      assert {:error, %LLMError{type: :invalid_output} = streamed} =
               BaseAgent.stream(a, "q", collect())

      for error <- [ran, streamed] do
        assert Exception.message(error) =~ "no JSON Schema"
        assert Exception.message(error) =~ "io_schema"
        assert Exception.message(error) =~ inspect(PlainOut)
      end
    end

    test "an empty final answer is \"\" in a chat schema" do
      a = tool_agent(%ToolThenText{text: ""})

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: ""}} = BaseAgent.run(a, "q")

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: ""}} =
               BaseAgent.stream(a, "q", collect())
    end

    test "an empty final answer is :invalid_output for a non-chat schema" do
      a = tool_agent(%ToolThenText{text: ""}, %{output_schema: %Answer{}})

      assert {:error, %LLMError{type: :invalid_output}} = BaseAgent.run(a, "q")
      assert {:error, %LLMError{type: :invalid_output}} = BaseAgent.stream(a, "q", collect())
    end

    test "a final response already of the schema's module passes through, validated" do
      filled =
        tool_agent(%ToolThenText{final: %Answer{answer: "42"}}, %{output_schema: %Answer{}})

      assert {:ok, _, %Answer{answer: "42"}} = BaseAgent.run(filled, "q")

      # Validated as usual: a missing required field is the ValidationError.
      missing = tool_agent(%ToolThenText{final: %Answer{}}, %{output_schema: %Answer{}})
      assert {:error, %Normandy.Schema.ValidationError{}} = BaseAgent.run(missing, "q")
    end

    test "a final response of a different module is :invalid_output" do
      a = tool_agent(%ToolThenText{final: %Answer{answer: "42"}}, %{output_schema: %PlainOut{}})

      assert {:error, %LLMError{type: :invalid_output} = error} = BaseAgent.run(a, "q")
      assert Exception.message(error) =~ inspect(Answer)
    end

    test "the forced-final streamed answer fills a non-chat schema" do
      a =
        tool_agent(%ToolThenText{text: ~s({"answer":"42"})}, %{
          output_schema: %Answer{},
          max_tool_iterations: 1
        })

      assert {:ok, _, %Answer{answer: "42"}} = BaseAgent.stream(a, "q", collect())
    end
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

    assert error.message ==
             "Normandy.Agents.BaseAgent.run!/3: unknown option :max_turns; run!/3 takes no options"

    refute error.message =~ "stream/3"
  end

  test "run/3 rejects the old streaming options with a stream/3 hint" do
    assert_raise ArgumentError, ~r/BaseAgent.stream\/3/, fn ->
      BaseAgent.run(agent(%ScriptedTextClient{text: "x"}), "hi", stream: true, on_chunk: & &1)
    end
  end

  test "run/3 and run!/3 name themselves and reject options that are not a keyword list" do
    agent = agent(%ScriptedTextClient{text: "x"})

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.run/3: unknown option :max_turns; run/3 takes no options",
                 fn -> BaseAgent.run(agent, "hi", max_turns: 2) end

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.run/3: expected options as a keyword list, got a " <>
                   "list that is not one; run/3 takes no options",
                 fn -> BaseAgent.run(agent, "hi", [1, 2]) end

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.run!/3: expected options as a keyword list, got " <>
                   ":fast; run!/3 takes no options",
                 fn -> BaseAgent.run!(agent, "hi", :fast) end
  end

  describe "a nil output schema is the default chat schema" do
    # init/1 sets the default; nil is reached by setting it afterwards or from a
    # hand-built config template.
    defp nil_schema(config), do: %{config | output_schema: nil}

    test "run/2 and stream/3 without tools" do
      a = nil_schema(agent(%ScriptedTextClient{text: "plain"}))

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: "plain"}} = BaseAgent.run(a, "q")

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: "plain"}} =
               BaseAgent.stream(a, "q", collect())
    end

    test "run/2 and stream/3 after a tool loop" do
      a = nil_schema(tool_agent(%ToolThenText{text: "plain"}))

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: "plain"}} = BaseAgent.run(a, "q")

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: "plain"}} =
               BaseAgent.stream(a, "q", collect())
    end

    test "an empty answer after a tool loop is \"\", as with the default schema" do
      a = nil_schema(tool_agent(%ToolThenText{text: ""}))

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: ""}} = BaseAgent.run(a, "q")

      assert {:ok, _, %BaseAgentOutputSchema{chat_message: ""}} =
               BaseAgent.stream(a, "q", collect())
    end
  end
end
