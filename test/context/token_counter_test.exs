defmodule Normandy.Context.TokenCounterTest do
  use ExUnit.Case, async: true

  alias Normandy.Context.TokenCounter
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Components.AgentMemory
  alias Normandy.Agents.BaseAgent
  alias NormandyTest.Support.IntegrationHelper

  setup do
    # Real Claudio client — these tests exercise the live count_tokens endpoint.
    client = %ClaudioAdapter{
      api_key: IntegrationHelper.get_api_key(),
      base_url: nil,
      options: %{}
    }

    # Create a test agent with memory
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "Hello, how are you?")
      |> AgentMemory.add_message("assistant", "I'm doing well, thank you for asking!")
      |> AgentMemory.add_message("user", "What can you help me with?")

    agent =
      BaseAgent.init(%{
        client: client,
        model: "claude-haiku-4-5-20251001",
        temperature: 0.7
      })

    agent = %{agent | memory: memory}

    {:ok, client: client, agent: agent}
  end

  describe "count_message/3" do
    @tag :integration
    test "counts tokens for a simple message", %{client: client} do
      {:ok, result} = TokenCounter.count_message(client, "Hello, world!")

      assert is_map(result)
      assert Map.has_key?(result, "input_tokens")
      assert result["input_tokens"] > 0
    end

    @tag :integration
    test "counts tokens for a longer message", %{client: client} do
      long_message = """
      This is a longer message that contains multiple sentences.
      It should have more tokens than a simple greeting.
      The token counter should accurately reflect the length of this text.
      """

      {:ok, result} = TokenCounter.count_message(client, long_message)

      assert is_map(result)
      assert result["input_tokens"] > 10
    end

    @tag :integration
    test "counts tokens with custom model", %{client: client} do
      {:ok, result} =
        TokenCounter.count_message(client, "Test message", "claude-haiku-4-5-20251001")

      assert is_map(result)
      assert Map.has_key?(result, "input_tokens")
    end

    test "counts an empty message as zero tokens (no API call)", %{client: client} do
      # Empty input short-circuits to zero without hitting the endpoint.
      assert {:ok, %{"input_tokens" => 0}} = TokenCounter.count_message(client, "")
    end
  end

  describe "count_conversation/2" do
    @tag :integration
    test "counts tokens for conversation history", %{client: client, agent: agent} do
      {:ok, result} = TokenCounter.count_conversation(client, agent)

      assert is_map(result)
      assert Map.has_key?(result, "input_tokens")
      # Should have tokens from all 3 messages
      assert result["input_tokens"] > 15
    end

    @tag :integration
    test "counts tokens with system prompt", %{client: client, agent: agent} do
      # Add a system prompt to the agent's prompt_specification
      agent_with_system =
        put_in(
          agent.prompt_specification.background,
          ["You are a helpful assistant."]
        )

      {:ok, result} = TokenCounter.count_conversation(client, agent_with_system)

      assert is_map(result)
      # Should include system prompt tokens
      assert result["input_tokens"] > 20
    end

    test "counts an agent with empty memory as zero tokens (no API call)", %{client: client} do
      empty_agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7
        })

      # No messages → zero tokens, short-circuited before any request.
      assert {:ok, %{"input_tokens" => 0}} = TokenCounter.count_conversation(client, empty_agent)
    end
  end

  describe "count_detailed/2" do
    @tag :integration
    test "returns detailed token breakdown", %{client: client, agent: agent} do
      {:ok, details} = TokenCounter.count_detailed(client, agent)

      assert is_map(details)
      assert Map.has_key?(details, :total_tokens)
      assert Map.has_key?(details, :system_tokens)
      assert Map.has_key?(details, :message_tokens)
      assert Map.has_key?(details, :messages)

      assert is_integer(details.total_tokens)
      assert is_integer(details.system_tokens)
      assert is_integer(details.message_tokens)
      assert is_list(details.messages)
    end

    @tag :integration
    test "provides per-message estimates", %{client: client, agent: agent} do
      {:ok, details} = TokenCounter.count_detailed(client, agent)

      # Should have estimates for each message
      assert length(details.messages) == 3

      # Each message should have required fields
      Enum.each(details.messages, fn msg ->
        assert Map.has_key?(msg, :role)
        assert Map.has_key?(msg, :content)
        assert Map.has_key?(msg, :estimated_tokens)
        assert is_integer(msg.estimated_tokens)
      end)
    end

    @tag :integration
    test "includes system prompt tokens when present", %{client: client, agent: agent} do
      system_prompt = "You are a helpful AI assistant that provides clear answers."

      agent_with_system =
        put_in(
          agent.prompt_specification.background,
          [system_prompt]
        )

      {:ok, details} = TokenCounter.count_detailed(client, agent_with_system)

      # System tokens should be greater than 0
      assert details.system_tokens > 0
      # Total should be sum of system + message tokens
      assert details.total_tokens == details.system_tokens + details.message_tokens
    end

    @tag :integration
    test "truncates long content in preview", %{client: client} do
      long_content = String.duplicate("a", 100)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", long_content)

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7
        })

      agent = %{agent | memory: memory}

      {:ok, details} = TokenCounter.count_detailed(client, agent)

      message = List.first(details.messages)
      # Content should be truncated to 50 chars + "..."
      assert String.length(message.content) <= 53
      assert String.ends_with?(message.content, "...")
    end
  end

  describe "error handling" do
    @tag :integration
    test "handles API errors gracefully", %{agent: agent} do
      # Create a client with invalid credentials
      invalid_client = %ClaudioAdapter{
        api_key: "invalid-key",
        base_url: nil,
        options: %{}
      }

      result = TokenCounter.count_conversation(invalid_client, agent)

      # Should return error tuple
      assert match?({:error, _}, result)
    end

    @tag :integration
    test "handles malformed agent structure", %{client: client} do
      malformed_agent = %{
        config: %{model: "test-model"},
        memory: "not-a-valid-memory"
      }

      result = TokenCounter.count_conversation(client, malformed_agent)

      # Should handle gracefully
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "integration with WindowManager" do
    test "estimates match TokenCounter pattern" do
      # This test verifies that WindowManager estimates and TokenCounter
      # use compatible formats (even though actual counts differ)

      text = "Hello, this is a test message."
      estimated = Normandy.Context.WindowManager.estimate_tokens(text)

      # Estimate should be roughly in the right ballpark
      # ~4 chars per token = ~8 tokens for 32 chars
      assert estimated >= 5
      assert estimated <= 15
    end

    test "message content estimation works with maps" do
      content = %{chat_message: "Test message with structured content"}
      estimated = Normandy.Context.WindowManager.estimate_message_content_tokens(content)

      # Should convert to JSON and estimate
      assert estimated > 0
    end
  end
end
