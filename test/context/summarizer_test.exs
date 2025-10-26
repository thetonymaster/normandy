defmodule Normandy.Context.SummarizerTest do
  use ExUnit.Case, async: true

  alias Normandy.Context.Summarizer
  alias Normandy.Components.AgentMemory
  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.MockSummarizerClient

  setup do
    # Create a mock client for summarization
    client = %MockSummarizerClient{
      summary_response: "This is a test summary of the conversation"
    }

    # Create an agent with the mock client
    agent = BaseAgent.init(%{
      client: client,
      model: "test-model",
      temperature: 0.7
    })

    {:ok, agent: agent, client: client}
  end

  describe "summarize_messages/4" do
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

    test "handles client errors gracefully" do
      failing_client = %MockSummarizerClient{should_fail: true}

      agent = BaseAgent.init(%{
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

  describe "compress_conversation/3" do
    test "compresses conversation by summarizing old messages", %{client: client} do
      # Create agent with many messages
      memory =
        Enum.reduce(1..20, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
        config: %{client: client, model: "test-model"}
      }

      {:ok, compressed_agent} =
        Summarizer.compress_conversation(client, agent, keep_recent: 5)

      # Should have fewer messages now (summary + 5 recent)
      history = AgentMemory.history(compressed_agent.memory)
      assert length(history) == 6  # 1 summary + 5 recent messages

      # First message should be the summary
      summary_msg = List.first(history)
      assert summary_msg.role == "system"
      assert String.contains?(summary_msg.content, "Previous conversation summary")
    end

    test "keeps all messages if below keep_recent threshold", %{client: client} do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "Hello")
        |> AgentMemory.add_message("assistant", "Hi")

      agent = %{
        memory: memory,
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

    test "preserves most recent messages", %{client: client} do
      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
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

      # Should save significant tokens (rough estimate: ~14 chars/msg * 50 msgs / 4 = ~175 tokens per msg + 10 overhead = ~9250 tokens)
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
          %{config: %{model: "test"}},
          messages
        )

      assert is_binary(summary)
    end
  end
end
