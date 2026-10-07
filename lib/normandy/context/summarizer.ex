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

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock
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

  @tool_call_types ["tool_use", "server_tool_use", "mcp_tool_use"]
  @tool_result_types ["tool_result", "mcp_tool_result"]
  @max_result_chars 4_000

  @summary_opts [
    prompt: [
      type: :string,
      doc: "The summarization prompt (default: the built-in prompt, which keeps stated facts)."
    ],
    model: [type: :string, doc: "The model to summarize with (default: the agent's model)."],
    max_tokens: [
      type: :pos_integer,
      doc:
        "Maximum tokens for the summary call (default: the agent's `max_tokens`, else " <>
          "16_000). Thinking shares this budget, and current models cannot turn it off."
    ]
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
    max_tokens = Keyword.get_lazy(opts, :max_tokens, fn -> agent_max_tokens!(agent) end)

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

  # The transcript the summary model reads: one paragraph per message, "Role: text" per
  # text block, and a line of its own for each tool call and tool result, so the facts a
  # tool returned reach the summary. history/1 gives blocks string-keyed (a response's API
  # blocks) or atom-keyed (ToolResult, a rebuilt ToolCallResponse); both read the same.
  # Thinking is left out: it is the model's scratch work, not conversation.
  defp format_messages_for_summary(messages) do
    names = tool_names(messages)

    messages
    |> Enum.map(fn msg -> msg.content |> content_lines(msg.role, names) |> Enum.join("\n") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp content_lines(content, role, _names) when is_binary(content),
    do: [label(role, unwrap_chat_message(content))]

  defp content_lines(content, role, names) when is_list(content),
    do: Enum.flat_map(content, &block_lines(&1, role, names))

  # A struct or map given to summarize_messages/4 directly: its chat_message, else JSON.
  defp content_lines(content, role, _names) when is_map(content) do
    case Map.get(content, :chat_message) do
      nil -> [label(role, Normandy.JSON.encode!(content))]
      message -> [label(role, message)]
    end
  end

  defp content_lines(nil, _role, _names), do: []

  defp block_lines(%ContentBlock.Text{text: text}, role, _names), do: [label(role, text)]
  defp block_lines(%ContentBlock.Image{}, role, _names), do: [label(role, "[image]")]
  defp block_lines(%ContentBlock.Document{}, role, _names), do: [label(role, "[document]")]

  defp block_lines(block, role, names) when is_map(block) do
    case field(block, :type) do
      "text" ->
        [label(role, field(block, :text))]

      type when type in ["thinking", "redacted_thinking"] ->
        []

      type when type in @tool_call_types ->
        input = Normandy.JSON.encode!(field(block, :input) || %{})
        ["Assistant called #{field(block, :name)}(#{input})"]

      type when type in @tool_result_types ->
        id = field(block, :tool_use_id)
        kind = if field(block, :is_error) == true, do: "Tool error", else: "Tool result"
        ["#{kind} (#{Map.get(names, id, id)}): #{cap(result_text(field(block, :content)))}"]

      type when is_binary(type) ->
        [label(role, "[#{type}]")]
    end
  end

  # The name of every call in the messages, by id, so a result names its tool.
  defp tool_names(messages) do
    for %{content: blocks} when is_list(blocks) <- messages,
        block when is_map(block) <- blocks,
        field(block, :type) in @tool_call_types,
        into: %{},
        do: {field(block, :id), field(block, :name)}
  end

  defp result_text(text) when is_binary(text), do: text
  defp result_text(nil), do: ""

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, " ", fn block ->
      case field(block, :type) do
        "text" -> field(block, :text)
        type -> "[#{type}]"
      end
    end)
  end

  # A tool result keeps its first @max_result_chars characters (graphemes) in the
  # transcript; the summary needs its facts, not a whole page.
  defp cap(text) when byte_size(text) <= @max_result_chars, do: text

  defp cap(text) do
    case String.length(text) - @max_result_chars do
      cut when cut > 0 ->
        String.slice(text, 0, @max_result_chars) <> " [#{cut} more characters cut]"

      _fits ->
        text
    end
  end

  # A final answer the structured path stored as {"chat_message": ...} JSON reads as its
  # text. Any other JSON (a custom schema's) stays as it is.
  defp unwrap_chat_message("{" <> _ = text) do
    case Normandy.JSON.decode(text) do
      {:ok, %{"chat_message" => message} = map} when map_size(map) == 1 and is_binary(message) ->
        message

      _not_a_chat_message ->
        text
    end
  end

  defp unwrap_chat_message(text), do: text

  defp label(role, text), do: "#{String.capitalize(role)}: #{text}"

  defp field(block, key), do: Map.get(block, key, Map.get(block, Atom.to_string(key)))

  # Thinking shares max_tokens with the summary text and cannot be turned off on current
  # models, so the summary gets the agent's own answer budget, not a summary-sized one.
  defp agent_max_tokens!(agent) do
    case Map.get(agent, :max_tokens) do
      nil ->
        BaseAgentConfig.default_max_tokens()

      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "Normandy.Context.Summarizer: the agent's :max_tokens is the summary's default " <>
                "budget and must be a positive integer, got: #{inspect(other)}; set it, or " <>
                "pass :max_tokens"
    end
  end

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

  # Framed so the model does not read the summary as something the user just said (AX-28).
  defp summary_message(summary) do
    "The earlier part of this conversation was summarized automatically to save space. " <>
      "The summary is context, not a new message.\n\n" <>
      "<conversation_summary>\n" <> summary <> "\n</conversation_summary>"
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
        # The summary goes first, as plain text: wrapped in a schema it reached the
        # model as {"chat_message": ...} JSON, which Haiku 4.5 read as data, not
        # conversation. The recent messages follow under their own ids and turns.
        new_memory =
          AgentMemory.keep_entries(
            agent.memory,
            recent_entries(agent.memory, length(recent_messages)),
            summary: {summary_role, summary_message(summary)}
          )

        {:ok, %{agent | memory: new_memory}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
