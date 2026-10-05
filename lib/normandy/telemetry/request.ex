defmodule Normandy.Telemetry.Request do
  @moduledoc """
  The `[:normandy, :llm, :request]` span: one per provider request made inside an
  `[:normandy, :agent, :llm_call]` span, so retries, JSON parse retries and the
  structured-outputs fallback show up individually.

  ## Who emits it

    * Non-streaming: the bundled adapters (`Normandy.LLM.ClaudioAdapter`,
      `Normandy.LLM.OpenAICompatibleAdapter`), around each HTTP request they make
      (a `converse/3` can make several: the structured-outputs 400 fallback and the
      JSON parse retries happen inside the adapter).
    * Streaming: `Normandy.Agents.BaseAgent`, around each stream attempt (the
      request and the consumption of its events), since the stream is consumed there.

  A third-party `Normandy.Agents.Model` emits no request spans unless it calls
  `span/5` itself with the `:request_tracker` it receives in `converse/3`'s opts.
  The llm_call stop's `attempts` then falls back to the number of times BaseAgent
  called `converse/3`.

  ## Counting across layers

  BaseAgent creates a tracker (`new/1`) per llm_call and passes it to
  `Model.converse/3` as the `:request_tracker` option; the adapter hands it to
  the JSON retry loop, which passes it back with `request_kind: :json_retry`.
  The tracker is an explicit value (a `:counters` array), never process state, so
  BaseAgent's retries (outside the adapter) and the adapter's own extra requests
  share one 1-based `attempt` sequence.

  ## Metadata

  Start: `:model`, `:provider` (when known), `:stream`, `:attempt`, `:request_kind`
  (`:initial | :retry | :json_retry | :structured_fallback`; not `:kind`, which the
  exception event uses for the error class), and the llm_call's
  ids (`:turn_id`, `:session_id`, `:conversation_id`) and `:agent_name` when the
  tracker carries them. Stop adds `:status` (`:ok`), `:response_id`,
  `:finish_reason` (a string) and this request's normalized token counts
  (`Normandy.Telemetry.Usage`), each when known. A failed request emits
  `:exception` with `kind: :error` and the `%Normandy.LLMError{}` as `:reason`
  (`stacktrace: []` when the request returned the error rather than raising).

  The llm_call stop gets `summary/1`: `:attempts`, `:json_retries`,
  `:structured_fallback`.
  """

  alias Normandy.LLMError
  alias Normandy.Telemetry.Span
  alias Normandy.Telemetry.Usage

  @event [:normandy, :llm, :request]

  # Counter slots.
  @requests 1
  @json_retries 2
  @structured_fallback 3
  @converse_calls 4

  @enforce_keys [:counters]
  defstruct counters: nil, metadata: %{}

  @type t :: %__MODULE__{counters: :counters.counters_ref(), metadata: map()}
  @type kind :: :initial | :retry | :json_retry | :structured_fallback
  @type outcome :: {:ok, map()} | {:error, LLMError.t()}

  @doc """
  A tracker for one llm_call; `metadata` (nil values dropped) is added to every
  request span's start.
  """
  @spec new(map()) :: t()
  def new(metadata \\ %{}),
    do: %__MODULE__{counters: :counters.new(4, []), metadata: reject_nil(metadata)}

  @doc """
  Notes that the caller is about to call `converse/3` (or start a stream attempt)
  once more. The first request of any call after the first is a `:retry`.
  """
  @spec note_call(t() | nil) :: :ok
  def note_call(nil), do: :ok
  def note_call(%__MODULE__{counters: c}), do: :counters.add(c, @converse_calls, 1)

  @doc """
  `:attempts`, `:json_retries` and `:structured_fallback` for the llm_call stop.
  `attempts` is the number of requests, or of converse calls when the client
  emitted no request spans.
  """
  @spec summary(t()) :: %{
          attempts: non_neg_integer(),
          json_retries: non_neg_integer(),
          structured_fallback: boolean()
        }
  def summary(%__MODULE__{counters: c}) do
    %{
      attempts: max(:counters.get(c, @requests), :counters.get(c, @converse_calls)),
      json_retries: :counters.get(c, @json_retries),
      structured_fallback: :counters.get(c, @structured_fallback) > 0
    }
  end

  @doc """
  Runs `fun` (one provider request) in a request span and returns its result
  unchanged.

  `kind` is `:json_retry` or `:structured_fallback` when the caller knows it, else
  `nil` (`:initial`, or `:retry` once `note_call/1` counted a second call).
  `metadata` holds `:model`, `:provider`, `:stream`. `outcome` maps the result to
  `{:ok, stop_metadata}` (see `stop_metadata/3`) or `{:error, %LLMError{}}`.
  """
  @spec span(t() | nil, kind() | nil, map(), (-> result), (result -> outcome())) :: result
        when result: term()
  def span(tracker, kind, metadata, fun, outcome) do
    {attempt, kind} = next_attempt(tracker, kind)

    start_metadata =
      tracker
      |> tracker_metadata()
      |> Map.merge(reject_nil(metadata))
      |> Map.merge(%{attempt: attempt, request_kind: kind, telemetry_span_context: make_ref()})

    start_time = System.monotonic_time()

    :telemetry.execute(
      @event ++ [:start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      start_metadata
    )

    result =
      try do
        fun.()
      catch
        class, reason ->
          emit_exception(start_metadata, start_time, class, reason, __STACKTRACE__)
          :erlang.raise(class, reason, __STACKTRACE__)
      end

    case outcome.(result) do
      {:ok, stop_metadata} ->
        stop_time = System.monotonic_time()

        :telemetry.execute(
          @event ++ [:stop],
          %{duration: stop_time - start_time, monotonic_time: stop_time},
          start_metadata |> Map.merge(stop_metadata) |> Map.put(:status, :ok)
        )

      {:error, %LLMError{} = error} ->
        emit_exception(start_metadata, start_time, :error, error, [])
    end

    result
  end

  @doc """
  Stop metadata from a response's id, stop reason (converted to a string) and raw
  usage (normalized); missing values are left out.
  """
  @spec stop_metadata(String.t() | nil, atom() | String.t() | nil, map() | nil) :: map()
  def stop_metadata(response_id, finish_reason, usage) do
    %{response_id: response_id, finish_reason: finish_reason_string(finish_reason)}
    |> reject_nil()
    |> Map.merge(Usage.normalize(usage))
  end

  defp tracker_metadata(nil), do: %{}
  defp tracker_metadata(%__MODULE__{metadata: metadata}), do: metadata

  defp next_attempt(nil, kind), do: {1, kind || :initial}

  defp next_attempt(%__MODULE__{counters: c}, kind) do
    :counters.add(c, @requests, 1)

    case kind do
      :json_retry -> :counters.add(c, @json_retries, 1)
      :structured_fallback -> :counters.put(c, @structured_fallback, 1)
      _ -> :ok
    end

    kind = kind || if :counters.get(c, @converse_calls) > 1, do: :retry, else: :initial
    {:counters.get(c, @requests), kind}
  end

  defp emit_exception(start_metadata, start_time, kind, reason, stacktrace) do
    stop_time = System.monotonic_time()

    :telemetry.execute(
      @event ++ [:exception],
      %{duration: stop_time - start_time, monotonic_time: stop_time},
      Map.merge(start_metadata, Span.exception_metadata(kind, reason, stacktrace))
    )
  end

  defp finish_reason_string(reason) when is_atom(reason) and reason != nil,
    do: Atom.to_string(reason)

  defp finish_reason_string(reason), do: reason

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
