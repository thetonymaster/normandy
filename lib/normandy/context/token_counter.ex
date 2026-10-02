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

  alias Claudio.Messages.Request
  alias Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter, as: ClaudioModel
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Components.ContentBlock.Document
  alias Normandy.Components.ContentBlock.Image
  alias Normandy.Components.ContentBlock.Text
  alias Normandy.Components.Message
  alias Normandy.Context.WindowManager
  alias Normandy.LLM.ClaudioAdapter

  @doc """
  Counts tokens for a single text message.

  Uses the Anthropic API for accurate token counting.

  ## Example

      {:ok, count} = TokenCounter.count_message(client, "Hello, world!")
      #=> {:ok, %{"input_tokens" => 4}}
  """
  @spec count_message(ClaudioAdapter.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def count_message(client, text, model \\ "claude-haiku-4-5-20251001")

  def count_message(_client, text, _model) when text in [nil, ""] do
    # Empty input has no tokens; short-circuit rather than send a request the
    # count_tokens endpoint rejects ("user messages must have non-empty content").
    {:ok, %{"input_tokens" => 0}}
  end

  def count_message(client, text, model) do
    # Build minimal request for token counting. The /v1/messages/count_tokens
    # endpoint rejects `max_tokens` ("Extra inputs are not permitted"), so it
    # is intentionally omitted.
    payload = %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => text}
      ]
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
    model = agent_model!(agent)
    messages = build_messages_payload(agent_memory!(agent))

    if messages == [] do
      # No messages → no tokens; short-circuit rather than send a request the
      # count_tokens endpoint rejects ("at least one message is required").
      {:ok, %{"input_tokens" => 0}}
    else
      # `max_tokens` intentionally omitted: the count_tokens endpoint rejects it.
      payload = %{
        "model" => model,
        "messages" => messages
      }

      # Add system prompt if present
      payload =
        case get_system_prompt(agent) do
          nil -> payload
          system -> Map.put(payload, "system", system)
        end

      count_tokens(client, payload)
    end
  end

  # Tokenizers differ between model generations, so the count needs the agent's
  # own model; a malformed agent is a caller bug and raises before any request.
  defp agent_model!(%{model: model}) when is_binary(model) and model != "", do: model

  defp agent_model!(_agent) do
    raise ArgumentError,
          "TokenCounter.count_conversation/2: agent has no :model (a non-empty string)"
  end

  defp agent_memory!(%{memory: %AgentMemory{} = memory}), do: memory

  defp agent_memory!(_agent) do
    raise ArgumentError,
          "TokenCounter.count_conversation/2: agent has no :memory (a %Normandy.Components.AgentMemory{})"
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
            estimated =
              WindowManager.estimate_message_content_tokens(msg.content)

            %{
              role: msg.role,
              content: get_content_preview(msg.content),
              estimated_tokens: estimated
            }
          end)

        system_tokens =
          case get_system_prompt(agent) do
            nil -> 0
            system -> WindowManager.estimate_tokens(system)
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
    claudio_client = ClaudioAdapter.to_claudio_client(client)
    Claudio.Messages.count_tokens(claudio_client, payload)
  end

  # The messages as a request would send them, built by the adapter's own
  # conversion: tool results become user tool_result blocks and tool calls
  # assistant tool_use blocks (count_tokens accepts only user and assistant).
  defp build_messages_payload(memory) do
    messages =
      memory
      |> AgentMemory.history()
      |> Enum.reject(&(&1.role == "system"))
      |> Enum.map(&%Message{role: &1.role, content: &1.content})

    Request.new("token-count")
    |> ClaudioModel.add_messages(messages, false)
    |> Map.fetch!(:messages)
  end

  defp format_content(content) when is_binary(content), do: content

  defp format_content(content) when is_map(content) do
    # For structured content, convert to JSON (a text rendering; Poison, not the
    # configured adapter, because it encodes any struct)
    Poison.encode!(content)
  end

  defp format_content(content) when is_list(content) do
    # Multimodal content — convert each block to its Anthropic-shape map
    # so the Claudio `count_tokens` endpoint sees the real payload rather
    # than an empty string.
    Enum.map(content, &block_to_claudio_map/1)
  end

  defp format_content(other) do
    raise ArgumentError,
          "TokenCounter: cannot count message content of type " <>
            Describe.type_of(other)
  end

  defp block_to_claudio_map(%Normandy.Components.ContentBlock.Text{} = b),
    do: Text.to_claudio(b)

  defp block_to_claudio_map(%Normandy.Components.ContentBlock.Image{} = b),
    do: Image.to_claudio(b)

  defp block_to_claudio_map(%Normandy.Components.ContentBlock.Document{} = b),
    do: Document.to_claudio(b)

  defp block_to_claudio_map(%{} = raw), do: raw

  defp get_system_prompt(agent) do
    # Try to extract system prompt from agent's prompt_specification or memory
    background =
      case agent do
        %{prompt_specification: %{background: bg}} -> bg
        _ -> nil
      end

    case background do
      nil -> find_system_in_memory(agent.memory)
      [] -> find_system_in_memory(agent.memory)
      bg when is_list(bg) -> Enum.join(bg, "\n")
      bg -> bg
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

  defp get_content_preview(content) when is_list(content) do
    # Build a short textual summary of multimodal blocks so the debug
    # view in `count_detailed/2` doesn't silently blank out.
    parts =
      Enum.map(content, fn
        %Normandy.Components.ContentBlock.Text{text: t} -> truncate(t, 40)
        %Normandy.Components.ContentBlock.Image{} -> "[image]"
        %Normandy.Components.ContentBlock.Document{} -> "[document]"
        %{"type" => "text", "text" => t} when is_binary(t) -> truncate(t, 40)
        %{"type" => type} -> "[#{type}]"
        _ -> "[block]"
      end)

    get_content_preview(Enum.join(parts, " "))
  end

  defp get_content_preview(_), do: ""

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n - 3) <> "...", else: s
  end
end
