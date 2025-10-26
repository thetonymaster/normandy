defmodule Normandy.Test.MockSummarizerClient do
  @moduledoc """
  Mock LLM client for testing summarization functionality.

  This client returns predictable summaries for testing purposes.
  """

  use Normandy.Schema

  schema do
    field(:summary_response, :string, default: "Summary of previous conversation")
    field(:delay, :integer, default: 0)
    field(:should_fail, :boolean, default: false)
  end

  defimpl Normandy.Agents.Model do
    @moduledoc """
    Mock implementation of the Model protocol for summarization testing.
    """

    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
      response_model
    end

    def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts) do
      # Simulate processing delay if configured
      if client.delay > 0, do: Process.sleep(client.delay)

      # Simulate failure if configured
      if client.should_fail do
        raise "Mock summarization failed"
      end

      # Extract the conversation content from the last message
      last_message = List.last(messages)
      conversation_text = extract_conversation(last_message)

      # Generate a mock summary
      summary = generate_mock_summary(client.summary_response, conversation_text)

      # Return response with summary
      %{response_model | chat_message: summary}
    end

    defp extract_conversation(%{content: content}) when is_binary(content) do
      content
    end

    defp extract_conversation(%{content: %{chat_message: message}}) do
      message
    end

    defp extract_conversation(_), do: ""

    defp generate_mock_summary(custom_response, conversation_text) do
      # If custom response is provided, use it
      if custom_response && custom_response != "" do
        custom_response
      else
        # Generate a simple summary based on message count
        message_count =
          conversation_text
          |> String.split("\n\n")
          |> length()

        "Summary: Conversation with #{message_count} messages exchanged"
      end
    end
  end
end
