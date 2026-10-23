defmodule Normandy.Context.WindowManager do
  @moduledoc """
  Manages context window limits for conversations with automatic truncation strategies.

  Provides utilities for tracking token usage, managing context window limits,
  and automatically truncating conversation history when approaching limits.

  ## Features

  - Token counting for messages and conversations
  - Context window passed in by the caller (no built-in model table)
  - Multiple truncation strategies (oldest-first, sliding window, summarization)
  - Automatic context management with AgentMemory integration

  ## Example

      # Create a window manager with the model's context window
      manager = WindowManager.new(max_tokens: 200_000)

      # Check if we're within limits
      {:ok, within_limit?} = WindowManager.within_limit?(manager, agent)

      # Automatically truncate if needed
      case WindowManager.ensure_within_limit(agent, manager) do
        {:ok, updated_agent} -> updated_agent
        {:error, reason} -> handle_summary_failure(agent, reason)
      end

  ## Truncation Strategies

  - `:oldest_first` - Remove oldest messages first (default)
  - `:summarize` - Summarize old messages before removing; needs the agent's
    `:client` (a `%BaseAgentConfig{}` always has one) and raises `ArgumentError`
    without it

  The kept messages always start at a user message, so the conversation stays
  valid for the API (no leading assistant turn, no tool result without its
  tool use). If the newest messages alone exceed the limit, their whole turn is
  kept rather than an empty history.
  """

  alias Normandy.Components.AgentMemory
  alias Normandy.Context.Summarizer
  alias Normandy.Context.TokenEstimate
  alias Normandy.Options

  @type strategy :: :oldest_first | :summarize
  @type t :: %__MODULE__{
          max_tokens: pos_integer(),
          reserved_tokens: non_neg_integer(),
          strategy: strategy(),
          summary_max_tokens: pos_integer() | nil
        }

  defstruct max_tokens: nil,
            reserved_tokens: 4096,
            strategy: :oldest_first,
            summary_max_tokens: nil

  @new_opts_schema NimbleOptions.new!(
                     max_tokens: [
                       type: :pos_integer,
                       doc:
                         "**Required.** The model's context window in tokens. Inside an agent the " <>
                           "compactor passes the window resolved through the configured " <>
                           "`Normandy.Behaviours.ModelCatalog`; standalone, take it from " <>
                           "`Claudio.Models.get/2` (`\"max_input_tokens\"`)."
                     ],
                     reserved_tokens: [
                       type: :non_neg_integer,
                       default: 4096,
                       doc: "Tokens kept free for the response."
                     ],
                     strategy: [
                       type: {:in, [:oldest_first, :summarize]},
                       default: :oldest_first,
                       doc: "The truncation strategy."
                     ],
                     summary_max_tokens: [
                       type: {:or, [:pos_integer, nil]},
                       default: nil,
                       doc:
                         "`max_tokens` of the `:summarize` strategy's summary call; `nil` is " <>
                           "`Normandy.Context.Summarizer`'s default (the agent's `max_tokens`, " <>
                           "else 16_000)."
                     ]
                   )

  @doc false
  # The compactor (Behaviours.Compactor.WindowManager) takes :strategy's type from here.
  def __opts_schema__(:new), do: @new_opts_schema

  @doc """
  Creates a new WindowManager.

  ## Options

  #{Options.docs(@new_opts_schema)}

  ## Example

      manager = WindowManager.new(max_tokens: 200_000, strategy: :oldest_first)
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

    unless Keyword.has_key?(opts, :max_tokens) do
      raise ArgumentError,
            "Normandy.Context.WindowManager.new/1: requires :max_tokens (the model's context " <>
              "window in tokens); Normandy no longer ships a static model table. Use the " <>
              "agent's resolved window or Claudio.Models.get/2 \"max_input_tokens\"."
    end

    %__MODULE__{
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      reserved_tokens: Keyword.fetch!(opts, :reserved_tokens),
      strategy: Keyword.fetch!(opts, :strategy),
      summary_max_tokens: Keyword.fetch!(opts, :summary_max_tokens)
    }
  end

  @doc """
  Estimates token count for a message.

  This is a rough estimate based on character count.
  For accurate counts, use `Normandy.Context.TokenCounter.count_message/3`.

  ## Example

      tokens = WindowManager.estimate_tokens("Hello, world!")
      #=> ~4 tokens
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  defdelegate estimate_tokens(text), to: TokenEstimate

  @doc """
  Estimates total tokens in conversation history.

  ## Example

      tokens = WindowManager.estimate_conversation_tokens(agent.memory)
  """
  @spec estimate_conversation_tokens(AgentMemory.t()) :: non_neg_integer()
  def estimate_conversation_tokens(memory) do
    # Each message's estimate (its content plus ~10 tokens for role and structure) is
    # computed when the message is stored (AgentMemory.Entry's `tokens`).
    memory
    |> AgentMemory.entry_chain()
    |> Enum.reduce(0, fn entry, acc -> acc + AgentMemory.entry_tokens(entry) end)
  end

  @doc """
  Estimates token count for message content.

  ## Example

      tokens = WindowManager.estimate_message_content_tokens("Hello")
      #=> ~2
  """
  @spec estimate_message_content_tokens(term()) :: non_neg_integer()
  defdelegate estimate_message_content_tokens(content), to: TokenEstimate

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
  Returns `{:error, reason}` when the `:summarize` strategy's summarization
  fails, leaving the agent unchanged.

  ## Example

      {:ok, updated_agent} = WindowManager.ensure_within_limit(agent, manager)
  """
  @spec ensure_within_limit(struct(), t()) :: {:ok, struct()} | {:error, term()}
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

  Returns `{:error, reason}` when the `:summarize` strategy's summarization
  fails, leaving the agent unchanged.

  ## Example

      case WindowManager.truncate_conversation(agent, manager) do
        {:ok, updated_agent} -> updated_agent
        {:error, reason} -> handle_summary_failure(agent, reason)
      end
  """
  @spec truncate_conversation(struct(), t()) :: {:ok, struct()} | {:error, term()}
  def truncate_conversation(agent, %__MODULE__{strategy: strategy} = manager) do
    case strategy do
      :oldest_first ->
        truncate_oldest_first(agent, manager)

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
      # Remove oldest messages until under limit, reading each message's cached
      # estimate (AgentMemory.Entry's `tokens`).
      entries = AgentMemory.entry_chain(agent.memory)

      # Start the kept window at a user message (see AgentMemory.keep_count/2);
      # a newest message larger than the target keeps its turn rather than
      # emptying the memory.
      keep =
        entries
        |> Enum.reverse()
        |> Enum.map(& &1.role)
        |> AgentMemory.keep_count(max(newest_fitting(entries, target_tokens), 1))

      # Each kept message stays under its entry id (a compactor reports what it dropped
      # by entry id) and turn, with its stored content.
      new_memory = AgentMemory.keep_entries(agent.memory, Enum.take(entries, -keep))
      {:ok, %{agent | memory: new_memory}}
    end
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

      client =
        Map.get(agent, :client) ||
          raise ArgumentError,
                "Normandy.Context.WindowManager.truncate_conversation/2: the :summarize " <>
                  "strategy needs the agent's :client, got #{inspect(Map.get(agent, :client))}"

      # A nil budget is the Summarizer's default.
      Summarizer.compress_conversation(
        client,
        agent,
        [keep_recent: keep_messages] ++ summary_budget(manager)
      )
    end
  end

  defp summary_budget(%__MODULE__{summary_max_tokens: nil}), do: []
  defp summary_budget(%__MODULE__{summary_max_tokens: n}), do: [max_tokens: n]

  # Keep at least 5 messages.
  defp estimate_messages_for_tokens(memory, target_tokens),
    do: memory |> AgentMemory.entry_chain() |> newest_fitting(target_tokens) |> max(5)

  # How many of the newest entries fit in `target_tokens` together (cached estimates).
  defp newest_fitting(entries, target_tokens) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while({0, 0}, fn entry, {count, tokens} ->
      entry_tokens = AgentMemory.entry_tokens(entry)

      if tokens + entry_tokens <= target_tokens do
        {:cont, {count + 1, tokens + entry_tokens}}
      else
        {:halt, {count, tokens}}
      end
    end)
    |> elem(0)
  end
end
