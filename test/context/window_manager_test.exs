defmodule Normandy.Context.WindowManagerTest do
  use ExUnit.Case, async: true

  alias Normandy.Context.WindowManager
  alias Normandy.Components.AgentMemory

  describe "new/1" do
    test "creates WindowManager with default options" do
      manager = WindowManager.new()

      assert manager.max_tokens == 100_000
      assert manager.reserved_tokens == 4096
      assert manager.strategy == :oldest_first
    end

    test "creates WindowManager with custom options" do
      manager =
        WindowManager.new(
          max_tokens: 50_000,
          reserved_tokens: 2048,
          strategy: :sliding_window
        )

      assert manager.max_tokens == 50_000
      assert manager.reserved_tokens == 2048
      assert manager.strategy == :sliding_window
    end
  end

  describe "for_model/2" do
    test "sets max_tokens based on known model limits" do
      manager = WindowManager.for_model("claude-haiku-4-5-20251001")
      assert manager.max_tokens == 200_000
    end

    test "uses default for unknown models" do
      manager = WindowManager.for_model("unknown-model")
      assert manager.max_tokens == 100_000
    end

    test "allows override with options" do
      manager =
        WindowManager.for_model("claude-haiku-4-5-20251001",
          reserved_tokens: 8192
        )

      assert manager.max_tokens == 200_000
      assert manager.reserved_tokens == 8192
    end
  end

  describe "estimate_tokens/1" do
    test "estimates tokens for short text" do
      tokens = WindowManager.estimate_tokens("Hello, world!")
      assert tokens >= 2
      assert tokens <= 5
    end

    test "estimates tokens for longer text" do
      text = String.duplicate("word ", 100)
      tokens = WindowManager.estimate_tokens(text)
      assert tokens >= 100
    end

    test "returns minimum 1 for empty string" do
      tokens = WindowManager.estimate_tokens("")
      assert tokens == 1
    end

    test "returns 0 for non-string input" do
      tokens = WindowManager.estimate_tokens(nil)
      assert tokens == 0
    end
  end

  describe "estimate_message_content_tokens/1" do
    test "estimates tokens for binary content" do
      tokens = WindowManager.estimate_message_content_tokens("Hello")
      assert tokens >= 1
    end

    test "estimates tokens for map content" do
      content = %{chat_message: "Hello, world!"}
      tokens = WindowManager.estimate_message_content_tokens(content)
      assert tokens >= 3
    end

    test "returns 0 for invalid content" do
      tokens = WindowManager.estimate_message_content_tokens(nil)
      assert tokens == 0
    end
  end

  describe "estimate_conversation_tokens/1" do
    test "estimates tokens for empty conversation" do
      memory = AgentMemory.new_memory()
      tokens = WindowManager.estimate_conversation_tokens(memory)
      assert tokens == 0
    end

    test "estimates tokens for conversation with messages" do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "Hello")
        |> AgentMemory.add_message("assistant", "Hi there!")

      tokens = WindowManager.estimate_conversation_tokens(memory)
      # Should include message content + overhead
      assert tokens > 10
    end
  end

  describe "within_limit?/2" do
    test "returns true when under limit" do
      manager = WindowManager.new(max_tokens: 100_000)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "Hello")

      agent = %{memory: memory}

      assert {:ok, true} = WindowManager.within_limit?(manager, agent)
    end

    test "returns false when over limit" do
      manager = WindowManager.new(max_tokens: 100, reserved_tokens: 50)

      # Create memory with many messages
      memory =
        Enum.reduce(1..100, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i} with some content")
        end)

      agent = %{memory: memory}

      assert {:ok, false} = WindowManager.within_limit?(manager, agent)
    end
  end

  describe "ensure_within_limit/2" do
    test "returns agent unchanged when within limit" do
      manager = WindowManager.new(max_tokens: 100_000)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "Hello")

      agent = %{memory: memory, config: %{}}

      assert {:ok, returned_agent} = WindowManager.ensure_within_limit(agent, manager)
      assert returned_agent == agent
    end

    test "truncates when over limit" do
      manager = WindowManager.new(max_tokens: 100, reserved_tokens: 50)

      # Create memory with many messages
      memory =
        Enum.reduce(1..20, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{memory: memory, config: %{}}

      assert {:ok, truncated_agent} = WindowManager.ensure_within_limit(agent, manager)

      # Should have fewer messages than original
      original_count = AgentMemory.count_messages(memory)
      truncated_count = AgentMemory.count_messages(truncated_agent.memory)

      assert truncated_count < original_count
    end
  end

  describe "truncate_conversation/2 with :oldest_first strategy" do
    test "removes oldest messages first" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "First message that is quite long")
        |> AgentMemory.add_message("assistant", "First response that is quite long")
        |> AgentMemory.add_message("user", "Second message that is quite long")
        |> AgentMemory.add_message("assistant", "Second response that is quite long")
        |> AgentMemory.add_message("user", "Third message that is quite long")
        |> AgentMemory.add_message("assistant", "Third response that is quite long")

      agent = %{memory: memory, config: %{}}

      {:ok, truncated_agent} = WindowManager.truncate_conversation(agent, manager)

      history = AgentMemory.history(truncated_agent.memory)

      # Should keep most recent messages
      assert length(history) < 6
      assert length(history) > 0
      # First message should be removed
      first = List.first(history)
      assert first.content != "First message that is quite long"
    end
  end

  describe "truncate_conversation/2 with :sliding_window strategy" do
    test "keeps most recent messages" do
      manager =
        WindowManager.new(max_tokens: 100, reserved_tokens: 30, strategy: :sliding_window)

      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message number #{i} with some content here")
        end)

      agent = %{memory: memory, config: %{}}

      {:ok, truncated_agent} = WindowManager.truncate_conversation(agent, manager)

      history = AgentMemory.history(truncated_agent.memory)

      # Should keep most recent messages
      assert length(history) > 0
      assert length(history) < 10
    end
  end

  describe "truncate_conversation/2 with :summarize strategy" do
    test "summarizes old messages when client is available" do
      # Create a mock client
      client = %Normandy.Test.MockSummarizerClient{
        summary_response: "Summary of old messages"
      }

      manager = WindowManager.new(max_tokens: 100, reserved_tokens: 30, strategy: :summarize)

      memory =
        Enum.reduce(1..15, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message number #{i} with content here")
        end)

      agent = %{memory: memory, config: %{client: client, model: "test-model"}}

      {:ok, truncated_agent} = WindowManager.truncate_conversation(agent, manager)

      history = AgentMemory.history(truncated_agent.memory)

      # Should have fewer messages than original
      assert length(history) < 15
      # Should have at least one summary message
      assert length(history) > 0
    end

    test "falls back to oldest_first when no client available" do
      manager = WindowManager.new(max_tokens: 100, reserved_tokens: 30, strategy: :summarize)

      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i} with lots of content here")
        end)

      agent = %{memory: memory, config: %{}}

      {:ok, truncated_agent} = WindowManager.truncate_conversation(agent, manager)

      # Should still truncate, just using oldest_first strategy
      assert AgentMemory.count_messages(truncated_agent.memory) <
               AgentMemory.count_messages(memory)
    end
  end
end
