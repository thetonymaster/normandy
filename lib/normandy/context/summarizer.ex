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

  alias Normandy.Agents.ConverseResult
  alias Normandy.Agents.Model
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Context.WindowManager

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
    temperature = nil

    # Create a temporary message list for summarization
    summarization_messages = [
      %Message{role: "user", content: prompt <> "\n\n" <> conversation_text}
    ]

    # Call LLM to generate summary
    call_llm_for_summary(client, model, temperature, max_tokens, summarization_messages)
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

    do_compress_conversation(
      client,
      agent,
      history,
      total_messages,
      keep_recent,
      summary_role,
      opts
    )
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
        tokens = WindowManager.estimate_message_content_tokens(msg.content)
        # Add overhead per message
        acc + tokens + 10
      end)

    savings = original_tokens - summary_tokens
    savings_percent_raw = if original_tokens > 0, do: savings / original_tokens * 100, else: 0.0

    savings_percent =
      if is_float(savings_percent_raw), do: Float.round(savings_percent_raw, 1), else: 0.0

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
    |> Enum.map_join("\n\n", fn msg ->
      role = String.capitalize(msg.role)
      content = extract_content(msg.content)
      "#{role}: #{content}"
    end)
  end

  defp extract_content(content) when is_binary(content), do: content

  defp extract_content(content) when is_map(content) do
    # Try to extract chat_message or convert to JSON
    case Map.get(content, :chat_message) do
      nil -> Poison.encode!(content)
      message -> message
    end
  end

  defp extract_content(content) when is_list(content) do
    # Multimodal content — join text blocks for the summary transcript
    # and emit a short placeholder for non-text blocks so summaries
    # don't silently drop images/documents from the context.
    content
    |> Enum.map(fn
      %Normandy.Components.ContentBlock.Text{text: t} -> t
      %Normandy.Components.ContentBlock.Image{} -> "[image]"
      %Normandy.Components.ContentBlock.Document{} -> "[document]"
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{"type" => type} -> "[#{type}]"
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp extract_content(_), do: ""

  defp get_model(agent, opts) do
    Keyword.get(opts, :model) || Map.get(agent, :model) ||
      raise ArgumentError,
            "Summarizer needs a model: pass opts[:model] or an agent with :model " <>
              "(there is no default; a hard-coded model goes stale); got agent keys " <>
              "#{inspect(Map.keys(agent))}"
  end

  defp call_llm_for_summary(client, model, temperature, max_tokens, messages) do
    # Create a proper struct response model for text output
    response_model = %Normandy.Agents.BaseAgentOutputSchema{chat_message: ""}

    case ConverseResult.normalize(
           Model.converse(client, model, temperature, max_tokens, messages, response_model, [])
         ) do
      {:ok, {%{chat_message: summary}, _usage, _meta}}
      when is_binary(summary) and summary != "" ->
        {:ok, summary}

      {:ok, {%{chat_message: _empty_or_not_text}, _usage, _meta}} ->
        {:error, :empty_summary}

      {:ok, {other, _usage, _meta}} ->
        {:error, {:unexpected_response, other}}

      {:error, %Normandy.LLMError{}} = error ->
        error
    end
  end

  defp rebuild_memory_with_summary(original_memory, summary, summary_role, recent_messages) do
    max_messages = Map.get(original_memory, :max_messages)
    turn_id = Map.get(original_memory, :current_turn_id)

    # Start from a fresh entry-graph memory, preserving the active turn id.
    memory = %{AgentMemory.new_memory(max_messages) | current_turn_id: turn_id}

    # Add summary message first - wrap in proper IO schema struct
    summary_content = %Normandy.Agents.BaseAgentOutputSchema{
      chat_message: "Previous conversation summary: " <> summary
    }

    memory = AgentMemory.add_message(memory, summary_role, summary_content)

    # Add recent messages in chronological order, each under its original turn.
    # The summary (added above) takes current_turn_id.
    Enum.reduce(recent_messages, memory, fn {msg, turn_id}, mem ->
      AgentMemory.add_message(mem, msg.role, msg.content, turn_id: turn_id)
    end)
  end

  # history/1 and messages/1 walk the same chain in the same order, so the kept
  # suffix's turn ids are the last `count` turn ids.
  defp recent_turn_ids(memory, count) do
    memory |> AgentMemory.messages() |> Enum.map(& &1.turn_id) |> Enum.take(-count)
  end

  # Helper function that uses pattern matching instead of conditionals
  # to avoid dialyzer warnings about unreachable branches
  defp do_compress_conversation(
         _client,
         agent,
         _history,
         total_messages,
         keep_recent,
         _summary_role,
         _opts
       )
       when total_messages <= keep_recent do
    # Not enough messages to warrant summarization
    {:ok, agent}
  end

  defp do_compress_conversation(
         client,
         agent,
         history,
         total_messages,
         keep_recent,
         summary_role,
         opts
       ) do
    # Split into old (to summarize) and recent (to keep)
    {old_messages, recent_messages} = Enum.split(history, total_messages - keep_recent)

    # Summarize old messages
    case summarize_messages(client, agent, old_messages, opts) do
      {:ok, summary} ->
        # Create new memory with summary + recent messages
        new_memory =
          rebuild_memory_with_summary(
            agent.memory,
            summary,
            summary_role,
            Enum.zip(recent_messages, recent_turn_ids(agent.memory, length(recent_messages)))
          )

        {:ok, %{agent | memory: new_memory}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
