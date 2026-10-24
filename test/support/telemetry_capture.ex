defmodule Normandy.Test.TelemetryCapture do
  @moduledoc """
  Scoped `:telemetry` capture for tests.

  `:telemetry` handlers are global, so a handler attached by one `async: true`
  test sees the events of every other test running at the same time. These
  helpers attach a handler that only forwards events matching `filter`, and
  detach it on exit.

  `filter` is a keyword list (every `{key, value}` must be present and equal in
  the event metadata, e.g. `[session_id: "s1"]` or `[agent_name: name]`), or a
  1-arity function over the metadata. Pin on something unique to the test.

      ref = TelemetryCapture.attach([[:normandy, :turn, :approval, :stop]], session_id: sid)
      assert_received {:telemetry, ^ref, %{duration: _}, %{outcome: :approved}}

      TelemetryCapture.attach_span([[:normandy, :agent, :run, :start]], agent_name: name)
      assert_received {:span, [:normandy, :agent, :run, :start], %{agent_name: ^name}}
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @type filter :: keyword() | (map() -> boolean())

  @doc "Forwards matching events as `{:telemetry, ref, measurements, metadata}`; returns `ref`."
  @spec attach([:telemetry.event_name()], filter()) :: reference()
  def attach(events, filter) do
    ref = make_ref()
    do_attach(events, filter, fn _event, m, meta -> {:telemetry, ref, m, meta} end)
    ref
  end

  @doc "Forwards matching events as `{:span, event, metadata}`."
  @spec attach_span([:telemetry.event_name()], filter()) :: :ok
  def attach_span(events, filter) do
    do_attach(events, filter, fn event, _m, meta -> {:span, event, meta} end)
  end

  @doc false
  def handle(event, measurements, metadata, {pid, filter, message}) do
    if matches?(filter, metadata), do: send(pid, message.(event, measurements, metadata))
    :ok
  end

  defp do_attach(events, filter, message) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(id, events, &__MODULE__.handle/4, {self(), filter, message})

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp matches?(filter, metadata) when is_function(filter, 1), do: filter.(metadata)

  defp matches?(filter, metadata) when is_list(filter),
    do: Enum.all?(filter, fn {k, v} -> Map.get(metadata, k, :__absent__) == v end)
end
