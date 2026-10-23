defmodule Normandy.Context.TokenCounterTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request, as: ClaudioRequest
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter, as: ClaudioModel
  alias Normandy.Components.AgentMemory
  alias Normandy.Context.TokenCounter
  alias Normandy.Context.WindowManager
  alias Normandy.LLM.ClaudioAdapter
  alias NormandyTest.Support.IntegrationHelper

  setup do
    # Real Claudio client — these tests exercise the live count_tokens endpoint.
    client = %ClaudioAdapter{
      # A placeholder when no key is set: the tests that run without one make no API call.
      api_key: IntegrationHelper.get_api_key() || "no-api-key-set",
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

      # A malformed agent is a caller bug: it raises rather than reaching the API.
      assert_raise ArgumentError, fn ->
        TokenCounter.count_conversation(client, malformed_agent)
      end
    end
  end

  describe "count_conversation/2 payload" do
    test "a tool round is sent as the API expects: no \"tool\" role" do
      test_pid = self()

      Req.Test.stub(__MODULE__.ToolRound, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})
        Req.Test.json(conn, %{"input_tokens" => 42})
      end)

      client = %ClaudioAdapter{
        api_key: "k",
        options: %{req_options: [plug: {Req.Test, __MODULE__.ToolRound}, retry: false]}
      }

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "weather?")
        |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
          tool_calls: [%Normandy.Components.ToolCall{id: "t1", name: "weather", input: %{}}]
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t1",
          output: "sunny"
        })

      agent = %{BaseAgent.init(%{client: client, model: "claude-haiku-4-5"}) | memory: memory}

      assert {:ok, %{"input_tokens" => 42}} = TokenCounter.count_conversation(client, agent)
      assert_received {:payload, payload}

      assert Enum.map(payload["messages"], & &1["role"]) == ["user", "assistant", "user"]
      assert [%{"type" => "tool_use", "id" => "t1"}] = Enum.at(payload["messages"], 1)["content"]

      assert [%{"type" => "tool_result", "tool_use_id" => "t1"}] =
               Enum.at(payload["messages"], 2)["content"]
    end
  end

  describe "count_conversation/2 payload, parallel tool results" do
    test "a batch of tool results is counted as one user message, as a request sends it" do
      test_pid = self()

      Req.Test.stub(__MODULE__.Batch, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})
        Req.Test.json(conn, %{"input_tokens" => 7})
      end)

      client = %ClaudioAdapter{
        api_key: "k",
        options: %{req_options: [plug: {Req.Test, __MODULE__.Batch}, retry: false]}
      }

      calls =
        for id <- ["t1", "t2"],
            do: %Normandy.Components.ToolCall{id: id, name: "weather", input: %{}}

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "weather?")
        |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
          tool_calls: calls
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t1",
          output: "sunny"
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t2",
          output: "rainy"
        })

      agent = %{BaseAgent.init(%{client: client, model: "claude-haiku-4-5"}) | memory: memory}

      assert {:ok, %{"input_tokens" => 7}} = TokenCounter.count_conversation(client, agent)
      assert_received {:payload, payload}

      assert Enum.map(payload["messages"], & &1["role"]) == ["user", "assistant", "user"]

      assert [%{"tool_use_id" => "t1"}, %{"tool_use_id" => "t2"}] =
               List.last(payload["messages"])["content"]
    end
  end

  describe "count_conversation/2 payload, a tool-round answer" do
    test "counts the request's messages: the repeated answer once" do
      test_pid = self()

      Req.Test.stub(__MODULE__.Once, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})
        Req.Test.json(conn, %{"input_tokens" => 9})
      end)

      client = %ClaudioAdapter{
        api_key: "k",
        options: %{req_options: [plug: {Req.Test, __MODULE__.Once}, retry: false]}
      }

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "Capital of France?")
        |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
          content: "Paris.",
          tool_calls: [%Normandy.Components.ToolCall{id: "t1", name: "record", input: %{}}]
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t1",
          output: "recorded"
        })
        |> AgentMemory.add_message("assistant", %Normandy.Agents.BaseAgentOutputSchema{
          chat_message: "Paris."
        })
        |> AgentMemory.add_message("user", "Thanks")

      agent = %{BaseAgent.init(%{client: client, model: "claude-haiku-4-5"}) | memory: memory}

      assert {:ok, %{"input_tokens" => 9}} = TokenCounter.count_conversation(client, agent)
      assert_received {:payload, payload}

      expected =
        ClaudioRequest.new("token-count")
        |> ClaudioModel.add_messages(
          AgentMemory.request_messages_for(memory, 0),
          false
        )
        |> Map.fetch!(:messages)
        |> Jason.encode!()
        |> Jason.decode!()

      assert payload["messages"] == expected
      assert [%{"type" => "tool_use", "id" => "t1"}] = Enum.at(payload["messages"], 1)["content"]
    end
  end

  describe "count_conversation/2 input checks" do
    test "an agent without a model raises instead of being counted against a default model",
         %{client: client, agent: agent} do
      assert_raise ArgumentError, ~r/agent has no :model/, fn ->
        TokenCounter.count_conversation(client, %{agent | model: nil})
      end
    end
  end

  describe "integration with WindowManager" do
    test "estimates match TokenCounter pattern" do
      # This test verifies that WindowManager estimates and TokenCounter
      # use compatible formats (even though actual counts differ)

      text = "Hello, this is a test message."
      estimated = WindowManager.estimate_tokens(text)

      # Estimate should be roughly in the right ballpark
      # ~4 chars per token = ~8 tokens for 32 chars
      assert estimated >= 5
      assert estimated <= 15
    end

    test "message content estimation works with maps" do
      content = %{chat_message: "Test message with structured content"}
      estimated = WindowManager.estimate_message_content_tokens(content)

      # Should convert to JSON and estimate
      assert estimated > 0
    end
  end

  describe "client construction" do
    test "count_message sends to the adapter's base_url (not api.anthropic.com)" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"input_tokens" => 7}))
      end)

      client = %Normandy.LLM.ClaudioAdapter{
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}/"
      }

      assert {:ok, _body} = TokenCounter.count_message(client, "hi")
    end
  end
end
