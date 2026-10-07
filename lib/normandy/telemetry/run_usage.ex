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

  @token_keys [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens]
  @token_count length(@token_keys)

  # Slot 1 counts calls; slots 2..5 hold the token totals in @token_keys order, slots
  # 6..9 a 1 once some call reported that count.
  @llm_calls 1
  @totals Enum.with_index(@token_keys, 2)
  @reported Enum.with_index(@token_keys, 2 + @token_count)

  @type t :: :counters.counters_ref()

  @spec new() :: t()
  def new, do: :counters.new(1 + 2 * @token_count, [])

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
end
