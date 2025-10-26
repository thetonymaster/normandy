defmodule Normandy.Context.TokenCounter do
  @moduledoc """
  Provides token counting utilities using the Anthropic token counting API.

  This module wraps Claudio's token counting functionality to provide
  accurate token counts for messages and conversations.

  ## Example

      # Count tokens for a single message
      {:ok, count} = TokenCounter.count_message(client, "Hello, world!")

      # Count tokens for an entire conversation
      {:ok, count} = TokenCounter.count_conversation(client, agent)

      # Get detailed token breakdown
      {:ok, details} = TokenCounter.count_detailed(client, agent)
  """

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Components.AgentMemory

  @doc """
  Counts tokens for a single text message.

  Uses the Anthropic API for accurate token counting.

  ## Example

      {:ok, count} = TokenCounter.count_message(client, "Hello, world!")
      #=> {:ok, %{"input_tokens" => 4}}
  """
  @spec count_message(ClaudioAdapter.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def count_message(client, text, model \\ "claude-3-5-sonnet-20241022") do
    # Build minimal request for token counting
    payload = %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => text}
      ],
      "max_tokens" => 1
    }

    count_tokens(client, payload)
  end

  @doc """
  Counts tokens for an agent's conversation history.

  ## Example

      {:ok, count} = TokenCounter.count_conversation(client, agent)
      #=> {:ok, %{"input_tokens" => 1234}}
  """
  @spec count_conversation(ClaudioAdapter.t(), struct()) ::
          {:ok, map()} | {:error, term()}
  def count_conversation(client, agent) do
    model = Map.get(agent.config, :model, "claude-3-5-sonnet-20241022")
    messages = build_messages_payload(agent.memory)

    payload = %{
      "model" => model,
      "messages" => messages,
      "max_tokens" => 1
    }

    # Add system prompt if present
    payload =
      case get_system_prompt(agent) do
        nil -> payload
        system -> Map.put(payload, "system", system)
      end

    count_tokens(client, payload)
  end

  @doc """
  Gets detailed token breakdown for an agent's conversation.

  Returns total input tokens and estimates for system/user/assistant messages.

  ## Example

      {:ok, details} = TokenCounter.count_detailed(client, agent)
      #=> {:ok, %{
        total_tokens: 1234,
        system_tokens: 100,
        message_tokens: 1134,
        messages: [
          %{role: "user", content: "Hello", estimated_tokens: 4},
          %{role: "assistant", content: "Hi!", estimated_tokens: 3}
        ]
      }}
  """
  @spec count_detailed(ClaudioAdapter.t(), struct()) ::
          {:ok, map()} | {:error, term()}
  def count_detailed(client, agent) do
    case count_conversation(client, agent) do
      {:ok, %{"input_tokens" => total}} ->
        # Get per-message estimates
        history = AgentMemory.history(agent.memory)

        message_details =
          Enum.map(history, fn msg ->
            estimated = Normandy.Context.WindowManager.estimate_message_content_tokens(msg.content)

            %{
              role: msg.role,
              content: get_content_preview(msg.content),
              estimated_tokens: estimated
            }
          end)

        system_tokens =
          case get_system_prompt(agent) do
            nil -> 0
            system -> Normandy.Context.WindowManager.estimate_tokens(system)
          end

        {:ok,
         %{
           total_tokens: total,
           system_tokens: system_tokens,
           message_tokens: total - system_tokens,
           messages: message_details
         }}

      error ->
        error
    end
  end

  # Private helpers

  defp count_tokens(%ClaudioAdapter{} = client, payload) do
    # Build Claudio client
    claudio_client = Claudio.Client.new(api_key: client.api_key)

    # Use Claudio's count_tokens function
    Claudio.Messages.count_tokens(claudio_client, payload)
  end

  defp build_messages_payload(memory) do
    history = AgentMemory.history(memory)

    Enum.map(history, fn msg ->
      %{
        "role" => msg.role,
        "content" => format_content(msg.content)
      }
    end)
    |> Enum.reject(&(&1["role"] == "system"))
  end

  defp format_content(content) when is_binary(content), do: content

  defp format_content(content) when is_map(content) do
    # For structured content, convert to JSON
    Poison.encode!(content)
  end

  defp format_content(_), do: ""

  defp get_system_prompt(agent) do
    # Try to extract system prompt from agent config or memory
    case Map.get(agent.config, :system_prompt) do
      nil -> find_system_in_memory(agent.memory)
      prompt -> prompt
    end
  end

  defp find_system_in_memory(memory) do
    history = AgentMemory.history(memory)

    case Enum.find(history, fn msg -> msg.role == "system" end) do
      nil -> nil
      msg -> format_content(msg.content)
    end
  end

  defp get_content_preview(content) when is_binary(content) do
    if String.length(content) > 50 do
      String.slice(content, 0, 47) <> "..."
    else
      content
    end
  end

  defp get_content_preview(content) when is_map(content) do
    content
    |> Poison.encode!()
    |> get_content_preview()
  end

  defp get_content_preview(_), do: ""
end
