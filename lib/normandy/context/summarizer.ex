defmodule Normandy.Context.Summarizer do
  @moduledoc """
  Handles conversation summarization for context window management.

  When conversations exceed token limits, this module can summarize older
  messages to preserve context while reducing token usage.

  ## Example

      # Summarize old messages
      {:ok, summary} = Summarizer.summarize_messages(client, agent, messages)

      # Replace old messages with summary
      {:ok, updated_agent} = Summarizer.compress_conversation(client, agent, keep_recent: 5)
  """

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message

  @default_summarization_prompt """
  Please provide a concise summary of the following conversation history.
  Focus on key points, decisions made, and important context that should be preserved.
  Keep the summary brief but informative.

  Conversation to summarize:
  """

  @doc """
  Summarizes a list of messages using the LLM.

  ## Options

  - `:prompt` - Custom summarization prompt (default: built-in prompt)
  - `:model` - Model to use for summarization (default: from agent config)
  - `:max_tokens` - Maximum tokens for summary (default: 500)

  ## Example

      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      {:ok, summary} = Summarizer.summarize_messages(client, agent, messages)
      #=> "User greeted, assistant responded"
  """
  @spec summarize_messages(struct(), struct(), list(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def summarize_messages(client, agent, messages, opts \\ []) do
    prompt = Keyword.get(opts, :prompt, @default_summarization_prompt)
    max_tokens = Keyword.get(opts, :max_tokens, 500)

    # Format messages for summarization
    conversation_text = format_messages_for_summary(messages)

    # Build summarization request
    model = get_model(agent, opts)
    temperature = 0.3  # Lower temperature for more focused summaries

    # Create a temporary message list for summarization
    summarization_messages = [
      %Message{role: "user", content: prompt <> "\n\n" <> conversation_text}
    ]

    # Call LLM to generate summary
    case call_llm_for_summary(client, model, temperature, max_tokens, summarization_messages) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compresses a conversation by summarizing old messages.

  Keeps recent messages intact and replaces older messages with a summary.

  ## Options

  - `:keep_recent` - Number of recent messages to keep (default: 10)
  - `:summary_role` - Role for summary message (default: "system")
  - `:max_summary_tokens` - Max tokens for summary (default: 500)

  ## Example

      {:ok, updated_agent} = Summarizer.compress_conversation(
        client,
        agent,
        keep_recent: 5
      )
  """
  @spec compress_conversation(struct(), struct(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def compress_conversation(client, agent, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, 10)
    summary_role = Keyword.get(opts, :summary_role, "system")

    history = AgentMemory.history(agent.memory)
    total_messages = length(history)

    if total_messages <= keep_recent do
      # Not enough messages to warrant summarization
      {:ok, agent}
    else
      # Split into old (to summarize) and recent (to keep)
      {old_messages, recent_messages} = Enum.split(history, total_messages - keep_recent)

      # Summarize old messages
      case summarize_messages(client, agent, old_messages, opts) do
        {:ok, summary} ->
          # Create new memory with summary + recent messages
          new_memory = rebuild_memory_with_summary(
            agent.memory,
            summary,
            summary_role,
            recent_messages
          )

          {:ok, %{agent | memory: new_memory}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Estimates token savings from summarization.

  ## Example

      {:ok, savings} = Summarizer.estimate_savings(messages, summary_tokens: 200)
      #=> %{original: 1500, summary: 200, savings: 1300, savings_percent: 86.7}
  """
  @spec estimate_savings(list(), keyword()) :: {:ok, map()}
  def estimate_savings(messages, opts \\ []) do
    summary_tokens = Keyword.get(opts, :summary_tokens, 500)

    # Estimate original token count
    original_tokens =
      Enum.reduce(messages, 0, fn msg, acc ->
        tokens = Normandy.Context.WindowManager.estimate_message_content_tokens(msg.content)
        acc + tokens + 10  # Add overhead per message
      end)

    savings = original_tokens - summary_tokens
    savings_percent_raw = if original_tokens > 0, do: (savings / original_tokens) * 100, else: 0.0
    savings_percent = if is_float(savings_percent_raw), do: Float.round(savings_percent_raw, 1), else: 0.0

    {:ok,
     %{
       original: original_tokens,
       summary: summary_tokens,
       savings: savings,
       savings_percent: savings_percent
     }}
  end

  # Private functions

  defp format_messages_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = String.capitalize(msg.role)
      content = extract_content(msg.content)
      "#{role}: #{content}"
    end)
    |> Enum.join("\n\n")
  end

  defp extract_content(content) when is_binary(content), do: content

  defp extract_content(content) when is_map(content) do
    # Try to extract chat_message or convert to JSON
    case Map.get(content, :chat_message) do
      nil -> Poison.encode!(content)
      message -> message
    end
  end

  defp extract_content(_), do: ""

  defp get_model(agent, opts) do
    Keyword.get(opts, :model) || Map.get(agent, :model, "claude-3-5-sonnet-20241022")
  end

  defp call_llm_for_summary(client, model, temperature, max_tokens, messages) do
    # Create a minimal response model for text output
    response_model = %{chat_message: ""}

    # Check if client implements the Model protocol
    if implements_model_protocol?(client) do
      case Normandy.Agents.Model.converse(
             client,
             model,
             temperature,
             max_tokens,
             messages,
             response_model,
             []
           ) do
        %{chat_message: summary} when is_binary(summary) ->
          {:ok, summary}

        other ->
          {:error, {:unexpected_response, other}}
      end
    else
      {:error, :client_not_supported}
    end
  end

  defp implements_model_protocol?(client) do
    # Check if the struct implements the Normandy.Agents.Model protocol
    impl = Normandy.Agents.Model.impl_for(client)
    impl != nil
  end

  defp rebuild_memory_with_summary(original_memory, summary, summary_role, recent_messages) do
    max_messages = Map.get(original_memory, :max_messages)
    turn_id = Map.get(original_memory, :current_turn_id)

    # Start with empty memory and properly add messages using AgentMemory.add_message
    # This ensures content is stored correctly regardless of type
    memory = %{
      max_messages: max_messages,
      history: [],
      current_turn_id: turn_id
    }

    # Add summary message first
    memory = AgentMemory.add_message(memory, summary_role, "Previous conversation summary: " <> summary)

    # Add recent messages in chronological order
    # (add_message prepends, and history() will reverse, so this gives correct final order)
    recent_messages
    |> Enum.reduce(memory, fn msg, mem ->
      AgentMemory.add_message(mem, msg.role, msg.content)
    end)
  end
end
