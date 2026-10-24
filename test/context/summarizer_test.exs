defmodule Normandy.Context.SummarizerTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter, as: ClaudioModel
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Context.Summarizer
  alias Normandy.Test.MockSummarizerClient
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture

  # Sends each request's messages to `notify`, then returns a fixed summary.
  defmodule RecordingClient do
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:summarize_request, request.messages})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "summary"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  setup do
    # Create a mock client for summarization
    client = %MockSummarizerClient{
      summary_response: "This is a test summary of the conversation"
    }

    # Create an agent with the mock client
    agent =
      BaseAgent.init(%{
        client: client,
        model: "test-model",
        temperature: 0.7
      })

    {:ok, agent: agent, client: client}
  end

  describe "summarize_messages/4" do
    # Call (6280534) rejects content: nil; text or a struct without :chat_message still
    # reaches the summarizer, which reports it.
    test "an answer that is not the summary schema is an :unexpected_response error", %{
      agent: agent
    } do
      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      for content <- ["plain text", %Normandy.Agents.ToolCallResponse{}] do
        client = %StubClient{reply: fn _ -> content end}

        assert {:error, {:unexpected_response, ^content}} =
                 Summarizer.summarize_messages(client, agent, messages)
      end

      nil_client = %StubClient{reply: fn _ -> {:ok, %Normandy.LLM.Response{content: nil}} end}

      assert_raise ArgumentError, ~r/content: nil/, fn ->
        Summarizer.summarize_messages(nil_client, agent, messages)
      end
    end

    test "the default prompt keeps stated facts word for word, across summaries", %{agent: agent} do
      messages = [
        %{role: "user", content: "Previous conversation summary: The vault code is TANGERINE-7."},
        %{role: "user", content: "Describe glaciers."},
        %{role: "assistant", content: "Glaciers are slow rivers of ice."}
      ]

      {:ok, "summary"} =
        Summarizer.summarize_messages(%RecordingClient{notify: self()}, agent, messages)

      assert_received {:summarize_request, [%Message{role: "user", content: prompt}]}
      assert prompt =~ "word for word"
      assert prompt =~ "earlier summary"
      assert prompt =~ "TANGERINE-7"
    end

    test "summarizes a list of messages", %{client: client, agent: agent} do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"},
        %{role: "user", content: "How are you?"},
        %{role: "assistant", content: "I'm doing well, thank you!"}
      ]

      {:ok, summary} = Summarizer.summarize_messages(client, agent, messages)

      assert is_binary(summary)
      assert String.length(summary) > 0
      assert summary == "This is a test summary of the conversation"
    end

    test "raises when neither opts nor the agent name a model", %{client: client} do
      messages = [%{role: "user", content: "hello"}]

      assert_raise ArgumentError, ~r/Summarizer needs a model/, fn ->
        Summarizer.summarize_messages(client, %{}, messages)
      end
    end

    test "handles empty message list", %{client: client, agent: agent} do
      {:ok, summary} = Summarizer.summarize_messages(client, agent, [])

      assert is_binary(summary)
    end

    test "uses custom prompt when provided", %{client: client, agent: agent} do
      messages = [%{role: "user", content: "Test"}]
      custom_prompt = "Summarize this briefly:"

      {:ok, summary} =
        Summarizer.summarize_messages(client, agent, messages, prompt: custom_prompt)

      assert is_binary(summary)
    end

    test "succeeds when the client's response carries usage (ClaudioAdapter shape)" do
      # Mirrors ClaudioAdapter: a %Response{} with content and usage.
      client = %StubClient{
        reply: fn response_model ->
          {:ok,
           %Normandy.LLM.Response{
             content: %{response_model | chat_message: "tuple-summary"},
             usage: %{tokens: 1}
           }}
        end
      }

      agent = BaseAgent.init(%{client: client, model: "test-model", temperature: 0.7})

      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      assert {:ok, "tuple-summary"} = Summarizer.summarize_messages(client, agent, messages)
    end

    test "handles client errors gracefully" do
      failing_client = %MockSummarizerClient{should_fail: true}

      agent =
        BaseAgent.init(%{
          client: failing_client,
          model: "test-model",
          temperature: 0.7
        })

      messages = [%{role: "user", content: "Test"}]

      assert_raise RuntimeError, "Mock summarization failed", fn ->
        Summarizer.summarize_messages(failing_client, agent, messages)
      end
    end
  end

  describe "LLM failures" do
    test "summarize_messages returns the LLMError instead of an empty summary" do
      agent =
        BaseAgent.init(%{
          client: %StubClient{
            reply: fn _ ->
              {:error, Normandy.LLMError.new(type: :rate_limit, status: 429, retryable?: true)}
            end
          },
          model: "test-model",
          temperature: nil
        })

      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert {:error, %Normandy.LLMError{type: :rate_limit}} =
               Summarizer.summarize_messages(agent.client, agent, messages)
    end
  end

  describe "telemetry" do
    setup do
      name = "summarizer-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [
          [:normandy, :agent, :llm_call, :start],
          [:normandy, :agent, :llm_call, :stop],
          [:normandy, :agent, :llm_call, :exception]
        ],
        agent_name: name
      )

      {:ok, name: name}
    end

    defp named_agent(name, reply) do
      agent = BaseAgent.init(%{client: %StubClient{reply: reply}, model: "test-model"})
      %{agent | name: name, memory: AgentMemory.initialize_turn(agent.memory)}
    end

    test "a summary call is an llm_call span with the agent's ids and its tokens", %{name: name} do
      agent =
        named_agent(name, fn rm ->
          {:ok,
           %Normandy.LLM.Response{
             content: %{rm | chat_message: "summary"},
             usage: %{"input_tokens" => 40, "output_tokens" => 9}
           }}
        end)

      turn_id = AgentMemory.get_current_turn_id(agent.memory)
      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert {:ok, "summary"} = Summarizer.summarize_messages(agent.client, agent, messages)

      assert_received {:span, [:normandy, :agent, :llm_call, :start], start}
      assert %{purpose: :summary, model: "test-model", turn_id: ^turn_id, stream: false} = start
      refute Map.has_key?(start, :iteration)

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], stop}
      assert %{input_tokens: 40, output_tokens: 9, attempts: 1, purpose: :summary} = stop
    end

    test "a summary call whose provider reports no usage has no :usage key", %{name: name} do
      agent =
        named_agent(name, fn rm ->
          {:ok, %Normandy.LLM.Response{content: %{rm | chat_message: "summary"}}}
        end)

      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert {:ok, "summary"} = Summarizer.summarize_messages(agent.client, agent, messages)

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], stop}
      refute Map.has_key?(stop, :usage)
    end

    test "a failed summary call ends the span with the LLMError", %{name: name} do
      error = Normandy.LLMError.new(type: :rate_limit, status: 429, retryable?: true)
      agent = named_agent(name, fn _ -> {:error, error} end)
      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert {:error, ^error} = Summarizer.summarize_messages(agent.client, agent, messages)

      assert_received {:span, [:normandy, :agent, :llm_call, :exception], meta}
      assert %{kind: :error, reason: ^error, purpose: :summary, stacktrace: []} = meta
    end

    test "a raising client ends the span with stacktrace: [] and still raises", %{name: name} do
      agent = named_agent(name, fn _ -> raise "client bug" end)
      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert_raise RuntimeError, "client bug", fn ->
        Summarizer.summarize_messages(agent.client, agent, messages)
      end

      assert_received {:span, [:normandy, :agent, :llm_call, :exception], meta}
      assert %{kind: :error, purpose: :summary, stacktrace: []} = meta

      assert %Normandy.TurnError{type: :task_down, reason: %{exception: RuntimeError}} =
               meta.reason
    end
  end

  describe "compress_conversation/3" do
    test "kept messages lose their thinking: it was produced before the summary existed",
         %{client: client} do
      agent = %{memory: memory_ending_in_thinking_round(), model: "test-model", config: %{}}

      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 3)

      blocks = kept_assistant_blocks(compressed.memory)
      assert Enum.any?(blocks, &(&1[:type] == "tool_use"))
      refute Enum.any?(blocks, &(&1["type"] == "thinking"))
    end

    test "kept messages keep their stored structs", %{client: client} do
      agent = %{memory: memory_ending_in_thinking_round(), model: "test-model", config: %{}}

      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 3)

      messages = AgentMemory.messages(compressed.memory)

      assert [%Normandy.Agents.ToolCallResponse{thinking: []}] =
               for(%{role: "assistant", content: c} <- messages, do: c)

      assert [%Normandy.Components.ToolResult{tool_call_id: "t1"}] =
               for(%{role: "tool", content: c} <- messages, do: c)
    end

    test "the kept messages start at a user message, never an orphan tool result",
         %{client: client} do
      memory =
        Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)
        |> AgentMemory.add_message("user", "weather?")
        |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
          tool_calls: [%Normandy.Components.ToolCall{id: "t1", name: "weather", input: %{}}]
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t1",
          output: "sunny"
        })
        |> AgentMemory.add_message("assistant", "It is sunny.")
        |> AgentMemory.add_message("user", "thanks")
        |> AgentMemory.add_message("assistant", "You're welcome.")

      agent = %{memory: memory, model: "test-model", config: %{}}

      # A fixed count of 4 would keep [tool result, assistant, user, assistant].
      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 4)

      [summary | kept] = AgentMemory.history(compressed.memory)
      assert summary.content =~ "<conversation_summary>"
      assert [%{role: "user", content: "thanks"}, %{role: "assistant"}] = kept
    end

    test "compresses conversation by summarizing old messages", %{client: client} do
      # Create agent with many messages
      memory =
        Enum.reduce(1..20, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      {:ok, compressed_agent} =
        Summarizer.compress_conversation(client, agent, keep_recent: 5)

      # Should have fewer messages now (summary + 5 recent)
      history = AgentMemory.history(compressed_agent.memory)
      # 1 summary + 5 recent messages
      assert length(history) == 6

      # First message should be the summary
      summary_msg = List.first(history)
      assert summary_msg.role == "user"
      assert String.contains?(summary_msg.content, "<conversation_summary>")
    end

    test "the summary reaches the model as plain text, not a JSON-wrapped schema", %{
      client: client
    } do
      memory =
        Enum.reduce(1..8, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{memory: memory, model: "test-model", config: %{}}
      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 2)

      [summary | _] = AgentMemory.history(compressed.memory)

      assert summary.content =~
               ~r/\AThe earlier part of this conversation was summarized automatically/
    end

    test "keeps all messages if below keep_recent threshold", %{client: client} do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "Hello")
        |> AgentMemory.add_message("assistant", "Hi")

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      {:ok, unchanged_agent} =
        Summarizer.compress_conversation(client, agent, keep_recent: 10)

      # Should be unchanged
      assert AgentMemory.count_messages(unchanged_agent.memory) ==
               AgentMemory.count_messages(memory)
    end

    test "uses custom summary role when provided", %{client: client} do
      memory =
        Enum.reduce(1..15, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      {:ok, compressed_agent} =
        Summarizer.compress_conversation(client, agent,
          keep_recent: 5,
          summary_role: "assistant"
        )

      history = AgentMemory.history(compressed_agent.memory)
      summary_msg = List.first(history)
      assert summary_msg.role == "assistant"
    end

    test "a compacted conversation still sends the agent's system prompt", %{client: client} do
      memory =
        Enum.reduce(1..15, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 5)

      # The [system | history] list BaseAgent sends after a compaction.
      messages =
        [%Message{role: "system", content: "You are the real system prompt."}] ++
          Enum.map(AgentMemory.history(compressed.memory), fn %{role: role, content: content} ->
            %Message{role: role, content: content}
          end)

      request =
        ClaudioModel.add_messages(Request.new("test-model"), messages, false)

      assert request.system == "You are the real system prompt."
    end

    test "preserves most recent messages", %{client: client} do
      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      {:ok, compressed_agent} =
        Summarizer.compress_conversation(client, agent, keep_recent: 3)

      history = AgentMemory.history(compressed_agent.memory)

      # Should have summary + 3 recent messages
      assert length(history) == 4

      # Last message should be "Message 10"
      last_msg = List.last(history)
      assert last_msg.content == "Message 10"
    end

    test "kept messages keep their turn ids; the summary takes the current turn", %{
      client: client
    } do
      old =
        Enum.reduce(1..8, AgentMemory.initialize_turn(AgentMemory.new_memory()), fn i, mem ->
          AgentMemory.add_message(mem, "user", "old #{i}")
        end)

      old_turn = AgentMemory.get_current_turn_id(old)

      memory =
        old
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", "new 1")
        |> AgentMemory.add_message("assistant", "new 2")

      new_turn = AgentMemory.get_current_turn_id(memory)

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      {:ok, %{memory: compressed}} =
        Summarizer.compress_conversation(client, agent, keep_recent: 4)

      [summary | kept] = AgentMemory.messages(compressed)
      assert summary.turn_id == new_turn
      assert Enum.map(kept, & &1.turn_id) == [old_turn, old_turn, new_turn, new_turn]
    end
  end

  describe "estimate_savings/2" do
    test "estimates token savings from summarization" do
      messages = [
        %{role: "user", content: "This is a long message with lots of content"},
        %{role: "assistant", content: "This is another long message with even more content"},
        %{role: "user", content: "Yet another message to add to the conversation"}
      ]

      {:ok, savings} = Summarizer.estimate_savings(messages, summary_tokens: 50)

      assert savings.original > 0
      assert savings.summary == 50
      assert savings.savings > 0
      assert savings.savings_percent > 0
      assert savings.savings_percent <= 100
    end

    test "handles empty message list" do
      {:ok, savings} = Summarizer.estimate_savings([], summary_tokens: 100)

      assert savings.original == 0
      assert savings.summary == 100
      assert savings.savings == -100
      assert savings.savings_percent == 0
    end

    test "calculates high savings for many messages" do
      # Create many messages
      messages =
        Enum.map(1..50, fn i ->
          %{role: "user", content: "Message number #{i} with some content"}
        end)

      {:ok, savings} = Summarizer.estimate_savings(messages, summary_tokens: 200)

      # Should save significant tokens (rough estimate: ~14 chars/msg * 50 msgs / 4
      # = ~175 tokens per msg + 10 overhead = ~9250 tokens)
      # Actual is lower due to shorter messages, so expect > 500 tokens savings
      assert savings.savings > 500
      assert savings.savings_percent > 70
    end
  end

  describe "format_messages_for_summary/1" do
    test "formats messages with different content types" do
      messages = [
        %{role: "user", content: "Text message"},
        %{role: "assistant", content: %{chat_message: "Structured message"}}
      ]

      # This is tested indirectly through summarize_messages
      {:ok, summary} =
        Summarizer.summarize_messages(
          %MockSummarizerClient{},
          %{model: "test", config: %{model: "test"}},
          messages
        )

      assert is_binary(summary)
    end
  end

  # 20 filler user messages, then a tool round whose assistant turn carries thinking.
  defp memory_ending_in_thinking_round do
    filler =
      Enum.reduce(1..20, AgentMemory.new_memory(), fn i, mem ->
        AgentMemory.add_message(mem, "user", "Message #{i} with some padding content")
      end)

    filler
    |> AgentMemory.add_message("user", "weather?")
    |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
      thinking: [%{"type" => "thinking", "thinking" => "plan", "signature" => "s"}],
      tool_calls: [%Normandy.Components.ToolCall{id: "t1", name: "weather", input: %{}}]
    })
    |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
      tool_call_id: "t1",
      output: "x"
    })
  end

  # The kept tool round, as the next request will send it.
  defp kept_assistant_blocks(memory) do
    memory
    |> AgentMemory.history()
    |> Enum.find(&(&1.role == "assistant" and is_list(&1.content)))
    |> Map.fetch!(:content)
  end

  describe "compress_conversation/3 and entry ids" do
    test "kept messages keep their entry ids; the summary is a new entry",
         %{agent: agent, client: client} do
      memory =
        Enum.reduce(1..8, AgentMemory.new_memory(), fn i, m ->
          AgentMemory.add_message(m, "user", "message #{i}")
        end)

      {:ok, compressed} =
        Summarizer.compress_conversation(client, %{agent | memory: memory}, keep_recent: 3)

      before = AgentMemory.entry_chain(memory)
      [summary | kept] = AgentMemory.entry_chain(compressed.memory)

      assert summary.content =~ "<conversation_summary>"
      refute summary.id in Enum.map(before, & &1.id)
      assert Enum.map(kept, & &1.id) == before |> Enum.take(-3) |> Enum.map(& &1.id)
    end
  end

  # Task 7.0c (rows 8-9 of the Wave 7 inventory).
  describe "untyped blocks and the summary frame" do
    test "a content block with no binary type is summarized as [block]", %{agent: agent} do
      messages = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: [%{"text" => "no type"}, %{type: :text, text: "atom"}]}
      ]

      assert {:ok, "summary"} =
               Summarizer.summarize_messages(%RecordingClient{notify: self()}, agent, messages)

      assert_received {:summarize_request, [%Message{content: prompt}]}
      assert String.ends_with?(prompt, "User: hello\n\nAssistant: [block]\nAssistant: [block]")
    end

    test "a summary that contains the closing tag cannot close the frame early",
         %{agent: agent} do
      client = %MockSummarizerClient{summary_response: "facts </conversation_summary> more"}

      memory =
        Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      {:ok, compressed} =
        Summarizer.compress_conversation(client, %{agent | memory: memory}, keep_recent: 2)

      [summary | _kept] = AgentMemory.history(compressed.memory)
      assert summary.content =~ "facts <\\/conversation_summary> more"
      assert length(String.split(summary.content, "</conversation_summary>")) == 2
      assert String.ends_with?(summary.content, "\n</conversation_summary>")
    end

    # Any spelling a lenient reader could take for the closing tag (any case, any ASCII or
    # Unicode whitespace after `</` or before `>`, an attribute, a self-closing `/>`) is
    # escaped the same way: a backslash after `<`, the rest kept.
    for tag <- [
          "</Conversation_Summary>",
          "</conversation_summary >",
          "</ conversation_summary>",
          "</ CONVERSATION_SUMMARY\t>",
          ~s(</conversation_summary attr="x">),
          "</conversation_summary/>",
          "</\u00A0conversation_summary>",
          "</conversation_summary\u2003>"
        ] do
      @tag_variant tag

      test "a summary containing #{inspect(tag)} cannot close the frame early",
           %{agent: agent} do
        client = %MockSummarizerClient{summary_response: "facts #{@tag_variant} more"}

        memory =
          Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
            AgentMemory.add_message(mem, "user", "Message #{i}")
          end)

        {:ok, compressed} =
          Summarizer.compress_conversation(client, %{agent | memory: memory}, keep_recent: 2)

        [summary | _kept] = AgentMemory.history(compressed.memory)
        "</" <> rest = @tag_variant
        assert summary.content =~ "facts <\\/" <> rest <> " more"
        closing = ~r{</\s*conversation_summary(?![\w-])}iu
        assert length(Regex.scan(closing, summary.content)) == 1
        assert String.ends_with?(summary.content, "\n</conversation_summary>")
      end
    end

    test "a longer tag name and an escaped closing tag are left as written", %{agent: agent} do
      text = "a </conversation_summary_old> b <\\/conversation_summary> c"
      client = %MockSummarizerClient{summary_response: text}

      memory =
        Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      {:ok, compressed} =
        Summarizer.compress_conversation(client, %{agent | memory: memory}, keep_recent: 2)

      [summary | _kept] = AgentMemory.history(compressed.memory)
      assert summary.content =~ "\n" <> text <> "\n</conversation_summary>"
    end
  end
end
