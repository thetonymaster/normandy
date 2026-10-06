defmodule Normandy.Context.SummarizerTranscriptTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Context.Summarizer
  alias Normandy.Context.WindowManager
  alias Normandy.Test.StubClient

  # Sends each summary request (messages and max_tokens) to `notify`, then answers
  # "summary".
  defmodule RecordingClient do
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:summarize_request, request.messages, request.max_tokens})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "summary"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp recording, do: %RecordingClient{notify: self()}

  defp agent(extra \\ %{}) do
    %{client: recording(), model: "test-model"} |> Map.merge(extra) |> BaseAgent.init()
  end

  # The transcript part of the one summary request (after the prompt).
  defp transcript do
    assert_received {:summarize_request, [%Message{role: "user", content: prompt}], _max}
    [_prompt, transcript] = String.split(prompt, "Conversation to summarize:\n\n\n", parts: 2)
    transcript
  end

  describe "the transcript the summarizer reads (AX-9)" do
    test "a tool round reaches the summary as a call, its result and the answer" do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "weather in Paris?")
        |> AgentMemory.add_message("assistant", %ToolCallResponse{
          content: "Let me check.",
          thinking: [%{"type" => "thinking", "thinking" => "plan", "signature" => "s"}],
          tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{"city" => "Paris"}}]
        })
        |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "t1", output: "sunny, 21C"})
        |> AgentMemory.add_message(
          "assistant",
          %Normandy.Agents.BaseAgentOutputSchema{chat_message: "It is sunny."}
        )

      {:ok, "summary"} =
        Summarizer.summarize_messages(recording(), agent(), AgentMemory.history(memory))

      assert transcript() ==
               """
               User: weather in Paris?

               Assistant: Let me check.
               Assistant called weather({"city":"Paris"})

               Tool result (weather): sunny, 21C

               Assistant: It is sunny.\
               """
    end

    test "string-keyed API blocks read like atom-keyed ones; thinking is left out" do
      messages = [
        %{
          role: "assistant",
          content: [
            %{"type" => "thinking", "thinking" => "secret plan", "signature" => "s"},
            %{"type" => "redacted_thinking", "data" => "xx"},
            %{"type" => "text", "text" => "Checking."},
            %{"type" => "tool_use", "id" => "t1", "name" => "lookup", "input" => %{"q" => "a"}},
            %{
              "type" => "mcp_tool_use",
              "id" => "m1",
              "name" => "search",
              "server_name" => "docs",
              "input" => %{}
            },
            %{
              "type" => "mcp_tool_result",
              "tool_use_id" => "m1",
              "is_error" => false,
              "content" => [%{"type" => "text", "text" => "doc hit"}]
            },
            %{"type" => "web_search_tool_result", "tool_use_id" => "w1", "content" => []}
          ]
        },
        %{
          role: "tool",
          content: [
            %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "found A"}
          ]
        }
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      text = transcript()

      assert text ==
               """
               Assistant: Checking.
               Assistant called lookup({"q":"a"})
               Assistant called search({})
               Tool result (search): doc hit
               Assistant: [web_search_tool_result]

               Tool result (lookup): found A\
               """

      refute text =~ "secret plan"
      refute text =~ "[thinking]"
    end

    test "an error result is marked, and an unknown call id stands in for the name" do
      messages = [
        %{
          role: "tool",
          content: [
            %{type: "tool_result", tool_use_id: "t9", content: "timeout", is_error: true}
          ]
        }
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      assert transcript() == "Tool error (t9): timeout"
    end

    test "a long tool result is cut to 4000 characters, with a note" do
      long = String.duplicate("é", 4_010)

      messages = [
        %{role: "assistant", content: [%{type: "tool_use", id: "t1", name: "dump", input: %{}}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "t1", content: long}]}
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      assert transcript() ==
               "Assistant called dump({})\n\nTool result (dump): " <>
                 String.duplicate("é", 4_000) <> " [10 more characters cut]"
    end

    test "an answer stored as {\"chat_message\": ...} JSON reads as its text" do
      messages = [
        %{role: "assistant", content: ~s({"chat_message":"It is sunny."})},
        %{role: "user", content: ~s({"query":"x","chat_message":"kept as JSON"})}
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      assert transcript() ==
               ~s(Assistant: It is sunny.\n\nUser: {"query":"x","chat_message":"kept as JSON"})
    end
  end

  describe "the summary message (AX-28)" do
    test "is framed as an automatic summary of earlier turns, in tags" do
      memory =
        Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      {:ok, compressed} =
        Summarizer.compress_conversation(recording(), agent(%{memory: memory}), keep_recent: 2)

      [summary | _kept] = AgentMemory.history(compressed.memory)

      assert summary == %{
               role: "user",
               content:
                 "The earlier part of this conversation was summarized automatically to save " <>
                   "space. The summary is context, not a new message.\n\n" <>
                   "<conversation_summary>\nsummary\n</conversation_summary>"
             }
    end
  end

  describe "the summary's max_tokens" do
    @messages [%{role: "user", content: "hello"}]

    test "defaults to the agent's max_tokens" do
      Summarizer.summarize_messages(recording(), agent(%{max_tokens: 9_000}), @messages)
      assert_received {:summarize_request, _messages, 9_000}
    end

    test "is 16_000 for an agent map without max_tokens" do
      Summarizer.summarize_messages(recording(), %{model: "test-model"}, @messages)
      assert_received {:summarize_request, _messages, 16_000}
    end

    test ":max_tokens overrides it" do
      Summarizer.summarize_messages(recording(), agent(), @messages, max_tokens: 700)
      assert_received {:summarize_request, _messages, 700}
    end

    test "an agent max_tokens that is not a positive integer raises, naming it" do
      assert_raise ArgumentError,
                   "Normandy.Context.Summarizer: the agent's :max_tokens is the summary's " <>
                     "default budget and must be a positive integer, got: 0; set it, or " <>
                     "pass :max_tokens",
                   fn ->
                     Summarizer.summarize_messages(
                       recording(),
                       %{model: "test-model", max_tokens: 0},
                       @messages
                     )
                   end
    end

    test "Compactor.WindowManager passes :summary_max_tokens to the summary call" do
      memory =
        Enum.reduce(1..40, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "message number #{i} with padding")
        end)

      opts = [context_window: 200, reserved_tokens: 16, strategy: :summarize]

      {_acc, %{compacted: true}} =
        WMCompactor.maybe_compact(
          agent(%{memory: memory}),
          %{model: "m", window: nil, mid_round: false},
          opts ++ [summary_max_tokens: 1_234]
        )

      assert_received {:summarize_request, _messages, 1_234}

      {_acc, %{compacted: true}} =
        WMCompactor.maybe_compact(
          agent(%{memory: memory, max_tokens: 100}),
          %{model: "m", window: nil, mid_round: false},
          opts
        )

      assert_received {:summarize_request, _messages, 100}
    end

    test ":summary_max_tokens is checked when the agent is built" do
      message =
        ~r/\ANormandy\.Agents\.BaseAgent\.init\/1: .*invalid value for :summary_max_tokens option: expected positive integer, got: 0/s

      assert_raise ArgumentError, message, fn ->
        BaseAgent.init(%{
          client: %StubClient{},
          model: "m",
          behaviours: %Normandy.Behaviours.Config{
            compactor: {WMCompactor, [context_window: 1_000, summary_max_tokens: 0]}
          }
        })
      end
    end

    test "WindowManager.new/1 takes :summary_max_tokens, nil by default" do
      assert WindowManager.new(max_tokens: 1_000).summary_max_tokens == nil

      assert WindowManager.new(max_tokens: 1_000, summary_max_tokens: 50).summary_max_tokens ==
               50
    end
  end
end
