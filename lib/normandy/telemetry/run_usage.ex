defmodule Normandy.Telemetry.RunUsage do
  @moduledoc false
  # A run's totals over its llm_call spans, for the run :stop metadata (see "Run totals"
  # in Normandy.Telemetry). The value is an explicit :counters array carried on the
  # transient call request as request[:run_usage], never process state and never
  # persisted: Turn.Server makes each LLM call in a fresh worker process, and the turn
  # state it persists must not change shape. A call request without the key (a custom
  # shell) adds nothing (add/2 takes nil).
  #
  # Only llm_call spans that reach :stop are counted: a failed call adds nothing, and a
  # summary call (compaction, Normandy.Context.Summarizer) is not counted, since it is
  # made without the request.
  #
  # One more slot records where a successful run's answer came from (answer_source/1):
  # set by mark_tool_round_answer/1 when the validate step replaced a blank chat answer
  # with this turn's last tool-round text (BaseAgent.validate_marking_answer/4).

  @token_keys [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens]
  @token_count length(@token_keys)

  # Slot 1 counts calls; slots 2..5 hold the token totals in @token_keys order, slots
  # 6..9 a 1 once some call reported that count; slot 10 a 1 once the answer was
  # taken from the tool round.
  @llm_calls 1
  @totals Enum.with_index(@token_keys, 2)
  @reported Enum.with_index(@token_keys, 2 + @token_count)
  @tool_round_answer 2 + 2 * @token_count

  @type t :: :counters.counters_ref()

  @spec new() :: t()
  def new, do: :counters.new(@tool_round_answer, [])

  # Adds one finished llm_call: its stop metadata's normalized counts
  # (Normandy.Telemetry.Usage keys), each only when present.
  @spec add(t() | nil, map()) :: :ok
  def add(nil, _stop_metadata), do: :ok

  def add(ref, stop_metadata) when is_map(stop_metadata) do
    :counters.add(ref, @llm_calls, 1)

    for {{key, total}, {key, reported}} <- Enum.zip(@totals, @reported),
        count = Map.get(stop_metadata, key),
        is_integer(count) do
      :counters.add(ref, total, count)
      :counters.put(ref, reported, 1)
    end

    :ok
  end

  # %{llm_calls: n} plus each token total some call reported.
  @spec stop_metadata(t()) :: map()
  def stop_metadata(ref) do
    for {{key, total}, {key, reported}} <- Enum.zip(@totals, @reported),
        :counters.get(ref, reported) == 1,
        into: %{llm_calls: :counters.get(ref, @llm_calls)},
        do: {key, :counters.get(ref, total)}
  end

  # Records that the run's answer is this turn's last tool-round text, not the final
  # response's (the run :stop's answer_source: :tool_round).
  @spec mark_tool_round_answer(t() | nil) :: :ok
  def mark_tool_round_answer(nil), do: :ok
  def mark_tool_round_answer(ref), do: :counters.put(ref, @tool_round_answer, 1)

  # :tool_round once mark_tool_round_answer/1 ran, else :final.
  @spec answer_source(t()) :: :tool_round | :final
  def answer_source(ref) do
    if :counters.get(ref, @tool_round_answer) == 1, do: :tool_round, else: :final
  end
end
