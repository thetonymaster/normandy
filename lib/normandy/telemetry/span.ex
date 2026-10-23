defmodule Normandy.Telemetry.Span do
  @moduledoc """
  `:telemetry.span/3` for Normandy's own spans, except that the `:exception`
  event's `stacktrace` is always `[]`.

  A stacktrace can hold call arguments (prompts, tool input, credentials), so it is
  logged by the code that rescues the failure and never emitted in telemetry. The
  raise itself keeps its original stacktrace.

  The `:exception` `reason` is redacted the same way (`exception_metadata/3`): an
  exception that is not one of Normandy's own (a bug) is emitted as
  `%Normandy.TurnError{reason: %{exception: module}}`, since its fields and message can
  hold the value it failed on. The raise itself is unchanged.

  Events, measurements and metadata are otherwise those of `:telemetry.span/3`:
  `:start` and `:stop` (and `:exception` with `kind`, `reason` on top of the start
  metadata), all sharing a `telemetry_span_context`.
  """

  alias Normandy.LLMError
  alias Normandy.TurnError

  @type event_prefix :: [atom()]

  @doc """
  Runs `fun` as the span `event_prefix`. `fun` returns `{result, stop_metadata}` or
  `{result, extra_measurements, stop_metadata}`; `result` is returned.
  """
  @spec span(
          event_prefix(),
          map(),
          (-> {result, map()} | {result, map(), map()})
        ) :: result
        when result: term()
  def span(event_prefix, start_metadata, fun)
      when is_list(event_prefix) and is_function(fun, 0) do
    {start_time, start_metadata} = emit_start(event_prefix, start_metadata)

    {result, extra_measurements, stop_metadata} =
      run(event_prefix, start_metadata, start_time, fn -> normalize(fun.()) end)

    emit_stop(event_prefix, start_metadata, start_time, extra_measurements, stop_metadata)
    result
  end

  @doc """
  Like `span/3`, for a `fun` that returns the call's result as is and a function
  that says how the span ends: `outcome` maps the result to `{:ok, stop_metadata}`
  (the `:stop` event carries exactly that metadata, plus the span context) or
  `{:error, %Normandy.LLMError{}}`, which ends the span in `:exception` without
  raising: the result is still returned. A raise, exit or throw inside `fun` is an
  `:exception` too, and is re-raised.
  """
  @spec span(event_prefix(), map(), (-> result), (result -> {:ok, map()} | {:error, LLMError.t()})) ::
          result
        when result: term()
  def span(event_prefix, start_metadata, fun, outcome)
      when is_list(event_prefix) and is_function(fun, 0) and is_function(outcome, 1) do
    {start_time, start_metadata} = emit_start(event_prefix, start_metadata)
    result = run(event_prefix, start_metadata, start_time, fun)

    case outcome.(result) do
      {:ok, stop_metadata} ->
        emit_stop(event_prefix, start_metadata, start_time, %{}, stop_metadata)

      {:error, %LLMError{} = error} ->
        emit_exception(event_prefix, start_metadata, start_time, :error, error, [])
    end

    result
  end

  defp emit_start(event_prefix, start_metadata) do
    start_time = System.monotonic_time()
    start_metadata = Map.put_new(start_metadata, :telemetry_span_context, make_ref())

    :telemetry.execute(
      event_prefix ++ [:start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      start_metadata
    )

    {start_time, start_metadata}
  end

  defp run(event_prefix, start_metadata, start_time, fun) do
    fun.()
  catch
    kind, reason ->
      emit_exception(event_prefix, start_metadata, start_time, kind, reason, __STACKTRACE__)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp emit_stop(event_prefix, start_metadata, start_time, extra_measurements, stop_metadata) do
    stop_time = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:stop],
      Map.merge(extra_measurements, %{duration: stop_time - start_time, monotonic_time: stop_time}),
      Map.put_new(stop_metadata, :telemetry_span_context, start_metadata.telemetry_span_context)
    )
  end

  defp emit_exception(event_prefix, start_metadata, start_time, kind, reason, stacktrace) do
    stop_time = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:exception],
      %{duration: stop_time - start_time, monotonic_time: stop_time},
      Map.merge(start_metadata, exception_metadata(kind, reason, stacktrace))
    )
  end

  @doc false
  # The keys every Normandy :exception event adds: `kind`, the `reason` as
  # Normandy.TurnError.redact/1 leaves it, and an empty `stacktrace`. A caught :error
  # is normalized first, so a raw {:badkey, key, map} is a KeyError reduced to its
  # module rather than the map. An exit or throw term loses every stacktrace in it
  # (TurnError.drop_stacktraces/1) and has its non-domain exceptions reduced; the rest of
  # the term is kept.
  @spec exception_metadata(:error | :exit | :throw, term(), Exception.stacktrace()) :: map()
  def exception_metadata(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)
    %{kind: :error, reason: TurnError.redact(exception), stacktrace: []}
  end

  def exception_metadata(kind, reason, _stacktrace),
    do: %{
      kind: kind,
      reason: reason |> TurnError.drop_stacktraces() |> TurnError.redact(),
      stacktrace: []
    }

  defp normalize({result, stop_metadata}), do: {result, %{}, stop_metadata}
  defp normalize({_result, _measurements, _stop_metadata} = triple), do: triple
end
