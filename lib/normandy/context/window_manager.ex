defmodule Normandy.Context.WindowManager do
  @moduledoc """
  Manages context window limits for conversations with automatic truncation strategies.

  Provides utilities for tracking token usage, managing context window limits,
  and automatically truncating conversation history when approaching limits.

  ## Features

  - Token counting for messages and conversations
  - Configurable context window limits per model
  - Multiple truncation strategies (oldest-first, sliding window, summarization)
  - Automatic context management with AgentMemory integration

  ## Example

      # Create a window manager with 100k token limit
      manager = WindowManager.new(max_tokens: 100_000)

      # Check if we're within limits
      {:ok, within_limit?} = WindowManager.within_limit?(manager, agent)

      # Automatically truncate if needed
      {:ok, updated_agent} = WindowManager.ensure_within_limit(agent, manager)

  ## Truncation Strategies

  - `:oldest_first` - Remove oldest messages first (default)
  - `:sliding_window` - Keep most recent N messages
  - `:summarize` - Summarize old messages before removing
  """

  alias Normandy.Components.AgentMemory

  @type strategy :: :oldest_first | :sliding_window | :summarize
  @type t :: %__MODULE__{
          max_tokens: pos_integer(),
          reserved_tokens: pos_integer(),
          strategy: strategy(),
          model_limits: map()
        }

  defstruct max_tokens: 100_000,
            reserved_tokens: 4096,
            strategy: :oldest_first,
            model_limits: %{
              "claude-3-5-sonnet-20241022" => 200_000,
              "claude-3-5-haiku-20241022" => 200_000,
              "claude-3-opus-20240229" => 200_000,
              "claude-3-sonnet-20240229" => 200_000,
              "claude-3-haiku-20240307" => 200_000
            }

  @doc """
  Creates a new WindowManager with optional configuration.

  ## Options

  - `:max_tokens` - Maximum tokens for context window (default: 100,000)
  - `:reserved_tokens` - Tokens to reserve for response (default: 4096)
  - `:strategy` - Truncation strategy (default: :oldest_first)

  ## Example

      manager = WindowManager.new(max_tokens: 50_000, strategy: :sliding_window)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 100_000)
    reserved_tokens = Keyword.get(opts, :reserved_tokens, 4096)
    strategy = Keyword.get(opts, :strategy, :oldest_first)

    %__MODULE__{
      max_tokens: max_tokens,
      reserved_tokens: reserved_tokens,
      strategy: strategy
    }
  end

  @doc """
  Creates a WindowManager configured for a specific model.

  Uses the model's known context window limit.

  ## Example

      manager = WindowManager.for_model("claude-3-5-sonnet-20241022")
  """
  @spec for_model(String.t(), keyword()) :: t()
  def for_model(model, opts \\ []) do
    manager = new(opts)
    model_limit = Map.get(manager.model_limits, model, manager.max_tokens)

    %{manager | max_tokens: model_limit}
  end

  @doc """
  Estimates token count for a message.

  This is a rough estimate based on character count.
  For accurate counts, use count_tokens_api/2.

  ## Example

      tokens = WindowManager.estimate_tokens("Hello, world!")
      #=> ~4 tokens
  """
  @spec estimate_tokens(String.t()) :: pos_integer()
  def estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 characters per token
    # More accurate for English text
    max(1, div(String.length(text), 4))
  end

  def estimate_tokens(_), do: 0

  @doc """
  Estimates total tokens in conversation history.

  ## Example

      tokens = WindowManager.estimate_conversation_tokens(agent.memory)
  """
  @spec estimate_conversation_tokens(map()) :: pos_integer()
  def estimate_conversation_tokens(memory) do
    history = AgentMemory.history(memory)

    Enum.reduce(history, 0, fn msg, acc ->
      content_tokens = estimate_message_content_tokens(msg.content)
      # Add overhead for role and structure (~10 tokens per message)
      acc + content_tokens + 10
    end)
  end

  @doc """
  Estimates token count for message content.

  ## Example

      tokens = WindowManager.estimate_message_content_tokens("Hello")
      #=> ~2
  """
  @spec estimate_message_content_tokens(term()) :: pos_integer()
  def estimate_message_content_tokens(content) when is_binary(content) do
    estimate_tokens(content)
  end

  def estimate_message_content_tokens(content) when is_map(content) do
    # For structured content, estimate based on JSON representation
    content
    |> Poison.encode!()
    |> estimate_tokens()
  end

  def estimate_message_content_tokens(_), do: 0

  @doc """
  Checks if current conversation is within token limit.

  ## Example

      case WindowManager.within_limit?(manager, agent) do
        {:ok, true} -> :continue
        {:ok, false} -> :truncate_needed
      end
  """
  @spec within_limit?(t(), struct()) :: {:ok, boolean()}
  def within_limit?(%__MODULE__{} = manager, agent) do
    current_tokens = estimate_conversation_tokens(agent.memory)
    available_tokens = manager.max_tokens - manager.reserved_tokens

    {:ok, current_tokens <= available_tokens}
  end

  @doc """
  Ensures agent's conversation stays within context window limit.

  Automatically truncates history if needed using the configured strategy.

  ## Example

      {:ok, updated_agent} = WindowManager.ensure_within_limit(agent, manager)
  """
  @spec ensure_within_limit(struct(), t()) :: {:ok, struct()}
  def ensure_within_limit(agent, %__MODULE__{} = manager) do
    case within_limit?(manager, agent) do
      {:ok, true} ->
        {:ok, agent}

      {:ok, false} ->
        truncate_conversation(agent, manager)
    end
  end

  @doc """
  Truncates conversation history using the configured strategy.

  ## Example

      {:ok, updated_agent} = WindowManager.truncate_conversation(agent, manager)
  """
  @spec truncate_conversation(struct(), t()) :: {:ok, struct()}
  def truncate_conversation(agent, %__MODULE__{strategy: strategy} = manager) do
    case strategy do
      :oldest_first ->
        truncate_oldest_first(agent, manager)

      :sliding_window ->
        truncate_sliding_window(agent, manager)

      :summarize ->
        truncate_with_summary(agent, manager)
    end
  end

  # Private truncation strategies

  defp truncate_oldest_first(agent, manager) do
    target_tokens = manager.max_tokens - manager.reserved_tokens
    current_tokens = estimate_conversation_tokens(agent.memory)

    if current_tokens <= target_tokens do
      {:ok, agent}
    else
      # Remove oldest messages until under limit
      history = AgentMemory.history(agent.memory)
      {keep_messages, _removed} = split_to_fit(history, target_tokens)

      # Rebuild memory with kept messages
      new_memory = rebuild_memory(keep_messages, agent.memory)
      {:ok, %{agent | memory: new_memory}}
    end
  end

  defp truncate_sliding_window(agent, manager) do
    # Keep most recent messages that fit within limit
    truncate_oldest_first(agent, manager)
  end

  defp truncate_with_summary(agent, manager) do
    # Calculate how many recent messages to keep
    target_tokens = manager.max_tokens - manager.reserved_tokens
    current_tokens = estimate_conversation_tokens(agent.memory)

    if current_tokens <= target_tokens do
      {:ok, agent}
    else
      # Keep approximately half the target tokens worth of recent messages
      # and summarize the rest
      keep_messages = estimate_messages_for_tokens(agent.memory, div(target_tokens, 2))

      # Get client from agent
      client = Map.get(agent, :client)

      if client do
        # Use summarizer to compress conversation
        Normandy.Context.Summarizer.compress_conversation(
          client,
          agent,
          keep_recent: keep_messages
        )
      else
        # Fall back to oldest-first if no client available
        truncate_oldest_first(agent, manager)
      end
    end
  end

  defp estimate_messages_for_tokens(memory, target_tokens) do
    history = AgentMemory.history(memory)

    # Count from newest to oldest
    history
    |> Enum.reverse()
    |> Enum.reduce_while({0, 0}, fn msg, {count, tokens} ->
      msg_tokens = estimate_message_content_tokens(msg.content) + 10

      if tokens + msg_tokens <= target_tokens do
        {:cont, {count + 1, tokens + msg_tokens}}
      else
        {:halt, {count, tokens}}
      end
    end)
    |> elem(0)
    |> max(5)  # Keep at least 5 messages
  end

  defp split_to_fit(messages, target_tokens) do
    # Reverse to process from newest to oldest
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {keep, tokens} ->
      msg_tokens = estimate_message_content_tokens(msg.content) + 10

      if tokens + msg_tokens <= target_tokens do
        {:cont, {[msg | keep], tokens + msg_tokens}}
      else
        {:halt, {keep, tokens}}
      end
    end)
    |> then(fn {keep, _tokens} ->
      removed_count = length(messages) - length(keep)
      {keep, removed_count}
    end)
  end

  defp rebuild_memory(messages, original_memory) do
    max_messages = Map.get(original_memory, :max_messages)
    turn_id = Map.get(original_memory, :current_turn_id)

    # Start with empty memory and properly add messages using AgentMemory.add_message
    memory = %{
      max_messages: max_messages,
      history: [],
      current_turn_id: turn_id
    }

    # Add messages in chronological order
    # (add_message prepends, and history() will reverse, so this gives correct final order)
    messages
    |> Enum.reduce(memory, fn msg, mem ->
      AgentMemory.add_message(mem, msg.role, msg.content)
    end)
  end
end
