defmodule Normandy.Context.WindowManagerTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Components.AgentMemory
  alias Normandy.Context.WindowManager

  describe "new/1" do
    test "requires :max_tokens (no static model table)" do
      assert_raise ArgumentError, ~r/requires :max_tokens/, fn -> WindowManager.new() end

      assert_raise ArgumentError, ~r/requires :max_tokens/, fn ->
        WindowManager.new(strategy: :oldest_first)
      end
    end

    test "rejects a non-positive or non-integer :max_tokens" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> WindowManager.new(max_tokens: 0) end

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        WindowManager.new(max_tokens: nil)
      end
    end

    test "defaults reserved_tokens and strategy" do
      manager = WindowManager.new(max_tokens: 100_000)
      assert manager.max_tokens == 100_000
      assert manager.reserved_tokens == 4096
      assert manager.strategy == :oldest_first
    end

    test "has no model_limits field and no for_model/2" do
      refute Map.has_key?(WindowManager.new(max_tokens: 10), :model_limits)
      Code.ensure_loaded!(WindowManager)
      refute function_exported?(WindowManager, :for_model, 2)
    end

    test "creates WindowManager with custom options" do
      manager =
        WindowManager.new(
          max_tokens: 50_000,
          reserved_tokens: 2048,
          strategy: :summarize
        )

      assert manager.max_tokens == 50_000
      assert manager.reserved_tokens == 2048
      assert manager.strategy == :summarize
    end

    test "rejects the removed :sliding_window strategy" do
      assert_raise ArgumentError, ~r/:sliding_window/, fn ->
        WindowManager.new(max_tokens: 100, strategy: :sliding_window)
      end
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

    test "estimates tokens for a list of multimodal content blocks" do
      alias Normandy.Components.ContentBlock.Document
      alias Normandy.Components.ContentBlock.Image
      alias Normandy.Components.ContentBlock.Text

      # Image-heavy list must NOT report 0 — that would silently let
      # image-heavy conversations overflow the context window.
      list = [
        Image.new_base64("DATA", "image/png"),
        Text.new("What's in this image?")
      ]

      assert WindowManager.estimate_message_content_tokens(list) > 1000

      # Each image block contributes a conservative fixed estimate.
      assert WindowManager.estimate_message_content_tokens([
               Image.new_base64("A", "image/jpeg"),
               Image.new_base64("B", "image/jpeg"),
               Text.new("compare")
             ]) >
               WindowManager.estimate_message_content_tokens([
                 Image.new_base64("A", "image/jpeg"),
                 Text.new("compare")
               ])

      # Document blocks carry their own conservative fixed estimate.
      assert WindowManager.estimate_message_content_tokens([
               Document.new_file("file_x"),
               Text.new("summarize")
             ]) > 1000
    end

    test "estimates single ContentBlock struct via its heuristic (not is_map JSON fallback)" do
      alias Normandy.Components.ContentBlock.Document
      alias Normandy.Components.ContentBlock.Image

      # A standalone single-image message must use the ~1600 heuristic, not
      # the JSON-size fallback which would undercount/vary by data length.
      # Anchor the assertion by comparing against a tiny-data image: if
      # we were JSON-encoding the struct, small data → tiny estimate.
      img = Image.new_base64("x", "image/png")
      assert WindowManager.estimate_message_content_tokens(img) >= 1600

      doc = Document.new_file("f")
      assert WindowManager.estimate_message_content_tokens(doc) >= 3000
    end

    test "estimates tokens for pre-shaped caller block maps" do
      # A raw Anthropic-shape map (e.g. with cache_control) should still
      # contribute a non-zero estimate via JSON fallback.
      list = [
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "DDD"}
        },
        %{"type" => "text", "text" => "hi"}
      ]

      assert WindowManager.estimate_message_content_tokens(list) > 0
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
    test "kept messages keep their entry ids" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "First message that is quite long")
        |> AgentMemory.add_message("assistant", "First response that is quite long")
        |> AgentMemory.add_message("user", "Second message that is quite long")
        |> AgentMemory.add_message("assistant", "Second response that is quite long")
        |> AgentMemory.add_message("user", "Third message that is quite long")
        |> AgentMemory.add_message("assistant", "Third response that is quite long")

      {:ok, truncated} =
        WindowManager.truncate_conversation(%{memory: memory, config: %{}}, manager)

      kept = AgentMemory.entry_chain(truncated.memory)
      assert length(kept) < 6

      assert Enum.map(kept, & &1.id) ==
               memory
               |> AgentMemory.entry_chain()
               |> Enum.take(-length(kept))
               |> Enum.map(& &1.id)
    end

    test "kept messages lose their thinking: their history changed" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)
      agent = %{memory: memory_ending_in_thinking_round(), config: %{}}

      {:ok, truncated} = WindowManager.truncate_conversation(agent, manager)

      blocks = kept_assistant_blocks(truncated.memory)
      assert Enum.any?(blocks, &(&1[:type] == "tool_use"))
      refute Enum.any?(blocks, &(&1["type"] == "thinking"))
    end

    test "kept messages keep their stored structs, so the kept batch is still answered" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)
      agent = %{memory: memory_ending_in_thinking_round(), config: %{}}

      {:ok, truncated} = WindowManager.truncate_conversation(agent, manager)

      messages = AgentMemory.messages(truncated.memory)

      assert [%Normandy.Agents.ToolCallResponse{thinking: []}] =
               for(%{role: "assistant", content: c} <- messages, do: c)

      assert [%Normandy.Components.ToolResult{tool_call_id: "t1"}] =
               for(%{role: "tool", content: c} <- messages, do: c)

      assert Turn.unanswered_tool_calls(messages) == []
    end

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
      assert history != []
      # First message should be removed
      first = List.first(history)
      assert first.content != "First message that is quite long"
    end
  end

  describe "truncate_conversation/2 keeps a window the API accepts" do
    test "the kept history starts at a user message" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "First message that is quite long")
        |> AgentMemory.add_message("assistant", "First response that is quite long")
        |> AgentMemory.add_message("user", "Second message that is quite long")
        |> AgentMemory.add_message("assistant", "Second response that is quite long")
        |> AgentMemory.add_message("tool", "A tool result that is quite long")
        |> AgentMemory.add_message("assistant", "Third response that is quite long")

      {:ok, %{memory: kept}} = WindowManager.truncate_conversation(%{memory: memory}, manager)

      assert [%{role: "user"} | _] = AgentMemory.history(kept)
    end

    test "a newest message larger than the target does not empty the memory" do
      manager = WindowManager.new(max_tokens: 30, reserved_tokens: 0, strategy: :oldest_first)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "short")
        |> AgentMemory.add_message("assistant", String.duplicate("long answer ", 50))

      {:ok, %{memory: kept}} = WindowManager.truncate_conversation(%{memory: memory}, manager)

      assert [%{role: "user"}, %{role: "assistant"}] = AgentMemory.history(kept)
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

      agent = %{memory: memory, client: client, model: "test-model", config: %{}}

      {:ok, truncated_agent} = WindowManager.truncate_conversation(agent, manager)

      history = AgentMemory.history(truncated_agent.memory)

      # Should have fewer messages than original
      assert length(history) < 15

      # The summarizer ran: its summary message leads the history
      assert [%{content: summary} | _] = history
      assert summary =~ "Summary of old messages"
    end

    test "raises naming :client even when the conversation is under budget" do
      manager = WindowManager.new(max_tokens: 100_000, strategy: :summarize)
      memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", "short")

      assert_raise ArgumentError, ~r/:client/, fn ->
        WindowManager.truncate_conversation(%{memory: memory, config: %{}}, manager)
      end
    end

    test "raises naming :client when the agent has none" do
      manager = WindowManager.new(max_tokens: 100, reserved_tokens: 30, strategy: :summarize)

      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i} with lots of content here")
        end)

      agent = %{memory: memory, config: %{}}

      assert_raise ArgumentError, ~r/:client/, fn ->
        WindowManager.truncate_conversation(agent, manager)
      end
    end
  end

  describe "compaction keeps turn ids" do
    defp two_turn_memory do
      old =
        Enum.reduce(1..6, AgentMemory.initialize_turn(AgentMemory.new_memory()), fn i, mem ->
          AgentMemory.add_message(mem, "user", "earlier turn message #{i} with padding text")
        end)

      old_turn = AgentMemory.get_current_turn_id(old)

      new =
        old
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", "q")
        |> AgentMemory.add_message("assistant", "a")

      {new, old_turn, AgentMemory.get_current_turn_id(new)}
    end

    test "oldest_first keeps each kept message's original turn_id" do
      {memory, old_turn, new_turn} = two_turn_memory()
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 16)

      {:ok, %{memory: compacted}} = WindowManager.ensure_within_limit(%{memory: memory}, manager)

      turn_ids = compacted |> AgentMemory.messages() |> Enum.map(& &1.turn_id)
      assert length(turn_ids) < 8
      assert List.last(turn_ids) == new_turn
      assert old_turn in turn_ids
      assert AgentMemory.get_current_turn_id(compacted) == new_turn
    end

    test "delete_turn/2 still removes only the old turn after a compaction" do
      {memory, old_turn, new_turn} = two_turn_memory()
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 16)
      {:ok, %{memory: compacted}} = WindowManager.ensure_within_limit(%{memory: memory}, manager)

      remaining = compacted |> AgentMemory.delete_turn(old_turn) |> AgentMemory.messages()
      assert remaining != []
      assert Enum.all?(remaining, &(&1.turn_id == new_turn))
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
end
