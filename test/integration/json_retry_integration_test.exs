defmodule Normandy.Integration.JsonRetryIntegrationTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Components.PromptSpecification

  @moduletag :integration
  @moduletag :json_retry

  describe "JSON retry integration with real LLM" do
    setup do
      api_key = System.get_env("API_KEY") || System.get_env("ANTHROPIC_API_KEY")

      if is_nil(api_key) do
        {:skip, "API_KEY or ANTHROPIC_API_KEY not set"}
      else
        client = %ClaudioAdapter{
          api_key: api_key,
          options: %{timeout: 60_000, enable_caching: false}
        }

        {:ok, client: client}
      end
    end

    @tag timeout: 120_000
    test "agent with JSON retry enabled handles malformed responses", %{client: client} do
      # Create an agent with a prompt that might produce malformed JSON
      prompt_spec = %PromptSpecification{
        background: [
          "You are a test assistant that sometimes produces malformed JSON."
        ],
        steps: [
          "1. Read the user's message",
          "2. Respond with a chat message"
        ],
        output_instructions: [
          "Respond with JSON in the format: {\"chat_message\": \"your response\"}",
          "IMPORTANT: Your response should be valid JSON."
        ]
      }

      # Initialize agent WITH JSON retry enabled
      agent_with_retry =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7,
          max_tokens: 1024,
          prompt_specification: prompt_spec,
          enable_json_retry: true,
          json_retry_max_attempts: 2
        })

      # Run the agent with a simple query
      input = %BaseAgentOutputSchema{chat_message: "Say hello"}
      {_updated_agent, response} = BaseAgent.run(agent_with_retry, input)

      # Verify we got a valid response
      assert is_struct(response, BaseAgentOutputSchema)
      assert is_binary(response.chat_message)
      assert String.length(response.chat_message) > 0

      # Response should not contain JSON artifacts
      refute response.chat_message =~ ~r/\{.*"chat_message".*\}/
      refute response.chat_message =~ "```"
    end

    @tag timeout: 120_000
    test "agent without JSON retry works normally", %{client: client} do
      prompt_spec = %PromptSpecification{
        background: ["You are a helpful assistant."],
        steps: [
          "1. Understand the question",
          "2. Provide a clear answer"
        ],
        output_instructions: [
          "Respond with valid JSON: {\"chat_message\": \"your response\"}"
        ]
      }

      # Initialize agent WITHOUT JSON retry (default)
      agent_without_retry =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7,
          max_tokens: 1024,
          prompt_specification: prompt_spec,
          enable_json_retry: false
        })

      input = %BaseAgentOutputSchema{chat_message: "What is 2+2?"}
      {_updated_agent, response} = BaseAgent.run(agent_without_retry, input)

      # Verify normal operation
      assert is_struct(response, BaseAgentOutputSchema)
      assert is_binary(response.chat_message)
      assert String.length(response.chat_message) > 0
    end

    @tag timeout: 120_000
    test "JSON retry handles field name variations", %{client: client} do
      prompt_spec = %PromptSpecification{
        background: ["You are a test assistant."],
        steps: ["Respond to the user."],
        output_instructions: [
          "Respond with JSON. You may use any of these field names:",
          "- \"response\"",
          "- \"message\"",
          "- \"text\"",
          "- \"chat_message\"",
          "",
          "All will be normalized correctly."
        ]
      }

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7,
          max_tokens: 1024,
          prompt_specification: prompt_spec,
          enable_json_retry: true,
          json_retry_max_attempts: 2
        })

      input = %BaseAgentOutputSchema{chat_message: "Test message"}
      {_updated_agent, response} = BaseAgent.run(agent, input)

      # Should successfully normalize any field variant
      assert is_struct(response, BaseAgentOutputSchema)
      assert is_binary(response.chat_message)
      assert String.length(response.chat_message) > 0
    end

    @tag timeout: 120_000
    test "JSON retry handles markdown code fences", %{client: client} do
      prompt_spec = %PromptSpecification{
        background: ["You are a test assistant."],
        steps: ["Respond to the user."],
        output_instructions: [
          "You may wrap your JSON response in markdown code fences like:",
          "```json",
          "{\"chat_message\": \"response\"}",
          "```",
          "",
          "This will be handled correctly."
        ]
      }

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7,
          max_tokens: 1024,
          prompt_specification: prompt_spec,
          enable_json_retry: true,
          json_retry_max_attempts: 2
        })

      input = %BaseAgentOutputSchema{chat_message: "Respond with fenced JSON"}
      {_updated_agent, response} = BaseAgent.run(agent, input)

      # Should strip code fences and parse correctly
      assert is_struct(response, BaseAgentOutputSchema)
      assert is_binary(response.chat_message)
      refute response.chat_message =~ "```"
    end

    @tag timeout: 180_000
    test "JSON retry recovers from initial parse failures", %{client: client} do
      # This test uses a deliberately tricky prompt to potentially trigger
      # a malformed response, then verifies recovery via retry

      prompt_spec = %PromptSpecification{
        background: [
          "You are an assistant that needs to respond with structured data."
        ],
        steps: [
          "1. Process the user's input",
          "2. Generate a response",
          "3. Format as JSON"
        ],
        output_instructions: [
          "Respond with JSON matching this schema:",
          "{\"chat_message\": \"your response text\"}",
          "",
          "Make sure it's valid JSON."
        ]
      }

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-haiku-4-5-20251001",
          temperature: 0.9,
          max_tokens: 1024,
          # Higher temperature to potentially trigger more varied responses
          prompt_specification: prompt_spec,
          enable_json_retry: true,
          json_retry_max_attempts: 3
        })

      # Run multiple iterations to test consistency
      inputs = [
        "Tell me about Elixir",
        "What is functional programming?",
        "Explain pattern matching"
      ]

      results =
        Enum.map(inputs, fn input_text ->
          input = %BaseAgentOutputSchema{chat_message: input_text}
          {_updated_agent, response} = BaseAgent.run(agent, input)
          response
        end)

      # All responses should be valid
      Enum.each(results, fn response ->
        assert is_struct(response, BaseAgentOutputSchema)
        assert is_binary(response.chat_message)
        assert String.length(response.chat_message) > 0
        # Should not contain nested JSON strings
        refute response.chat_message =~ ~r/\{.*"chat_message".*\}/
      end)
    end
  end
end
