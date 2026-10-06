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
  alias Normandy.Context.WindowManager
  alias Normandy.LLM.Call
  alias Normandy.LLM.Request, as: LLMRequest
  alias Normandy.LLM.Response
  alias Normandy.LLMError
  alias Normandy.Options
  alias Normandy.Telemetry.Metadata
  alias Normandy.Telemetry.Provider
  alias Normandy.Telemetry.Request
  alias Normandy.Telemetry.Span
  alias Normandy.Telemetry.Usage

  # Compaction summarizes its own earlier summaries, so a fact the conversation has moved
  # past must be carried forward explicitly or a later round drops it.
  @default_summarization_prompt """
  Summarize the conversation below. Your summary replaces it in the assistant's memory, so
  anything you leave out is forgotten.

  - Keep every fact the user stated or asked to be remembered (names, numbers, codes, dates,
    preferences) word for word, even when the conversation moved on to other topics.
  - If the conversation begins with an earlier summary, carry all of its facts forward.
  - Then note briefly the topics covered, decisions made and any open requests.
  - Leave out the assistant's remarks about its own abilities or memory.

  Conversation to summarize:
  """

  @summary_opts [
    prompt: [
      type: :string,
      doc: "The summarization prompt (default: the built-in prompt, which keeps stated facts)."
    ],
    model: [type: :string, doc: "The model to summarize with (default: the agent's model)."],
    max_tokens: [type: :pos_integer, default: 500, doc: "Maximum tokens for the summary."]
  ]

  @summarize_messages_opts_schema NimbleOptions.new!(@summary_opts)
  @compress_conversation_opts_schema NimbleOptions.new!(
                                       [
                                         keep_recent: [
                                           type: :non_neg_integer,
                                           default: 10,
                                           doc:
                                             "Recent messages kept as they are. The kept " <>
                                               "messages start at a user message: the oldest " <>
                                               "one among the last `:keep_recent`, or the " <>
                                               "newest one when none is."
                                         ],
                                         summary_role: [
                                           type: {:in, ["user", "assistant"]},
                                           default: "user",
                                           doc:
                                             "The summary message's role. Not \"system\": the " <>
                                               "adapter sends the agent's own system prompt and " <>
                                               "refuses a second one."
                                         ]
                                       ] ++ @summary_opts
                                     )
  @estimate_savings_opts_schema NimbleOptions.new!(
                                  summary_tokens: [
                                    type: :non_neg_integer,
                                    default: 500,
                                    doc: "The summary's expected size in tokens."
                                  ]
                                )

  @doc """
  Summarizes a list of messages using the LLM.

  ## Options

  #{Options.docs(@summarize_messages_opts_schema)}

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
    opts =
      Options.validate!(
        opts,
        @summarize_messages_opts_schema,
        {__MODULE__, :summarize_messages, 4}
      )

    prompt = Keyword.get(opts, :prompt, @default_summarization_prompt)
    max_tokens = Keyword.fetch!(opts, :max_tokens)

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
    call_llm_for_summary(client, agent, model, temperature, max_tokens, summarization_messages)
  end

  @doc """
  Compresses a conversation by summarizing old messages.

  Keeps recent messages intact and replaces older messages with a summary.

  ## Options

  #{Options.docs(@compress_conversation_opts_schema)}

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
    opts =
      Options.validate!(
        opts,
        @compress_conversation_opts_schema,
        {__MODULE__, :compress_conversation, 3}
      )

    keep_recent = Keyword.fetch!(opts, :keep_recent)
    summary_role = Keyword.fetch!(opts, :summary_role)

    history = AgentMemory.history(agent.memory)
    total_messages = length(history)

    # The kept messages start at a user message, as trimming's do: starting at a
    # tool result whose tool_use was summarized away gets every later call a 400.
    keep =
      history
      |> Enum.reverse()
      |> Enum.map(& &1.role)
      |> AgentMemory.keep_count(keep_recent)

    do_compress_conversation(
      client,
      agent,
      history,
      total_messages,
      keep,
      summary_role,
      opts
    )
  end

  @doc """
  Estimates token savings from summarization.

  ## Options

  #{Options.docs(@estimate_savings_opts_schema)}

  ## Example

      {:ok, savings} = Summarizer.estimate_savings(messages, summary_tokens: 200)
      #=> %{original: 1500, summary: 200, savings: 1300, savings_percent: 86.7}
  """
  @spec estimate_savings(list(), keyword()) :: {:ok, map()}
  def estimate_savings(messages, opts \\ []) do
    opts =
      Options.validate!(opts, @estimate_savings_opts_schema, {__MODULE__, :estimate_savings, 2})

    summary_tokens = Keyword.fetch!(opts, :summary_tokens)

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
    # Try to extract chat_message or convert to JSON (structs as their maps).
    case Map.get(content, :chat_message) do
      nil -> Normandy.JSON.encode!(content)
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

  defp call_llm_for_summary(client, agent, model, temperature, max_tokens, messages) do
    # Create a proper struct response model for text output
    response_model = %Normandy.Agents.BaseAgentOutputSchema{chat_message: ""}

    metadata =
      %{model: model, agent_name: Map.get(agent, :name), purpose: :summary}
      |> Map.merge(Metadata.ids(agent))
      |> Map.merge(
        Provider.request_metadata(
          %{client: client, max_tokens: max_tokens, temperature: temperature},
          stream: false,
          response_model: response_model
        )
      )

    # The summary's provider requests carry the agent's ids, like a turn's do.
    tracker =
      metadata
      |> Map.take([:agent_name, :turn_id, :session_id, :conversation_id])
      |> Request.new()

    request = %LLMRequest{
      model: model,
      messages: messages,
      response_model: response_model,
      temperature: temperature,
      max_tokens: max_tokens
    }

    llm_call_span(metadata, tracker, fn ->
      Request.note_call(tracker)
      Call.converse(client, request, request_tracker: tracker)
    end)
    |> case do
      {:ok, %Response{content: %{chat_message: summary}}}
      when is_binary(summary) and summary != "" ->
        {:ok, summary}

      {:ok, %Response{content: %{chat_message: _empty_or_not_text}}} ->
        {:error, :empty_summary}

      {:ok, %Response{content: other}} ->
        {:error, {:unexpected_response, other}}

      {:error, %LLMError{}} = error ->
        error
    end
  end

  # The summary request is an [:normandy, :agent, :llm_call] span (see
  # Normandy.Telemetry), so its tokens count with the agent's other calls. Emitted by
  # hand, as :telemetry.span/3 would: the returned {:error, %LLMError{}} must end it
  # in :exception without being raised, which would also turn a raising client's
  # LLMError into a return value.
  defp llm_call_span(metadata, tracker, fun) do
    start_time = System.monotonic_time()
    metadata = Map.put(metadata, :telemetry_span_context, make_ref())

    :telemetry.execute(
      [:normandy, :agent, :llm_call, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      metadata
    )

    result =
      try do
        fun.()
      catch
        kind, reason ->
          llm_call_exception(metadata, start_time, kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case result do
      {:ok, %Response{usage: usage, meta: meta}} ->
        stop_time = System.monotonic_time()

        stop_metadata =
          metadata
          |> Map.put(:usage, usage)
          |> Map.merge(Usage.normalize(usage))
          |> Map.merge(response_metadata(meta))
          |> Map.merge(Request.summary(tracker))

        :telemetry.execute(
          [:normandy, :agent, :llm_call, :stop],
          %{duration: stop_time - start_time, monotonic_time: stop_time},
          stop_metadata
        )

      {:error, %LLMError{} = error} ->
        llm_call_exception(metadata, start_time, :error, error, [])
    end

    result
  end

  defp llm_call_exception(metadata, start_time, kind, reason, stacktrace) do
    stop_time = System.monotonic_time()

    :telemetry.execute(
      [:normandy, :agent, :llm_call, :exception],
      %{duration: stop_time - start_time, monotonic_time: stop_time},
      Map.merge(metadata, Span.exception_metadata(kind, reason, stacktrace))
    )
  end

  defp response_metadata(meta) do
    meta
    |> Map.take([:served_by, :response_id, :finish_reason])
    |> Map.update(:finish_reason, nil, fn
      reason when is_atom(reason) and reason != nil -> Atom.to_string(reason)
      reason -> reason
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp rebuild_memory_with_summary(original_memory, summary, summary_role, recent_messages) do
    max_messages = Map.get(original_memory, :max_messages)
    turn_id = Map.get(original_memory, :current_turn_id)

    # Start from a fresh entry-graph memory, preserving the active turn id.
    memory = %{AgentMemory.new_memory(max_messages) | current_turn_id: turn_id}

    # The summary goes first, as plain text: wrapped in a schema it reached the model
    # as {"chat_message": ...} JSON, which Haiku 4.5 read as data, not conversation.
    memory =
      AgentMemory.add_message(memory, summary_role, "Previous conversation summary: " <> summary)

    # Add recent messages in chronological order, each under its original turn and
    # entry id. The summary (added above) takes current_turn_id and a new id. Their
    # thinking was produced before the summary existed, so it no longer applies.
    Enum.reduce(recent_messages, memory, fn {msg, entry}, mem ->
      AgentMemory.add_message(mem, msg.role, AgentMemory.drop_thinking(msg.content),
        turn_id: entry.turn_id,
        id: entry.id
      )
    end)
  end

  # history/1 and entry_chain/1 walk the same chain in the same order, so the kept
  # suffix's entries are the last `count` entries.
  defp recent_entries(memory, count) do
    memory |> AgentMemory.entry_chain() |> Enum.take(-count)
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
    case summarize_messages(
           client,
           agent,
           old_messages,
           Keyword.take(opts, [:prompt, :model, :max_tokens])
         ) do
      {:ok, summary} ->
        # Create new memory with summary + recent messages
        new_memory =
          rebuild_memory_with_summary(
            agent.memory,
            summary,
            summary_role,
            Enum.zip(recent_messages, recent_entries(agent.memory, length(recent_messages)))
          )

        {:ok, %{agent | memory: new_memory}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
