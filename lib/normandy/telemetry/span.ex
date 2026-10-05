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
    start_time = System.monotonic_time()
    start_metadata = Map.put_new(start_metadata, :telemetry_span_context, make_ref())

    :telemetry.execute(
      event_prefix ++ [:start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      start_metadata
    )

    {result, extra_measurements, stop_metadata} =
      try do
        normalize(fun.())
      catch
        kind, reason ->
          stop_time = System.monotonic_time()

          :telemetry.execute(
            event_prefix ++ [:exception],
            %{duration: stop_time - start_time, monotonic_time: stop_time},
            Map.merge(start_metadata, exception_metadata(kind, reason, __STACKTRACE__))
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    stop_time = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:stop],
      Map.merge(extra_measurements, %{duration: stop_time - start_time, monotonic_time: stop_time}),
      Map.put_new(stop_metadata, :telemetry_span_context, start_metadata.telemetry_span_context)
    )

    result
  end

  @doc false
  # The keys every Normandy :exception event adds: `kind`, the `reason` as
  # Normandy.TurnError.redact/1 leaves it, and an empty `stacktrace`. A caught :error
  # is normalized first, so a raw {:badkey, key, map} is a KeyError reduced to its
  # module rather than the map. Exits and throws keep their term.
  @spec exception_metadata(:error | :exit | :throw, term(), Exception.stacktrace()) :: map()
  def exception_metadata(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)
    %{kind: :error, reason: TurnError.redact(exception), stacktrace: []}
  end

  def exception_metadata(kind, reason, _stacktrace),
    do: %{kind: kind, reason: TurnError.redact(reason), stacktrace: []}

  defp normalize({result, stop_metadata}), do: {result, %{}, stop_metadata}
  defp normalize({_result, _measurements, _stop_metadata} = triple), do: triple
end
