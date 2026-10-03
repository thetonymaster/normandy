defmodule Normandy.Test.OtelSpanBridge do
  @moduledoc """
  Test-only bridge from `:telemetry` span events to real OpenTelemetry spans,
  plus a collector that hands finished spans back to the test.

  Normandy does not create OTel spans itself; consumers do it in telemetry
  handlers. This bridge plays that consumer so tests can assert the resulting
  parent/child structure.

  ## Usage

      setup do
        Normandy.Test.OtelSpanBridge.attach()
        on_exit(&Normandy.Test.OtelSpanBridge.detach/0)
      end

      test "..." do
        # ... run something ...
        spans = Normandy.Test.OtelSpanBridge.finished_spans()
        # [%{name: "normandy.agent.run", span_id: _, parent_span_id: _, trace_id: _}, ...]
      end

  A span for the event prefix `[:normandy, :agent, :run]` is named
  `"normandy.agent.run"`. `attach/1` takes extra prefixes, so later tasks can
  bridge more spans (`[:normandy, :llm, :request]`, `[:normandy, :workflow, :run]`, ...)
  by adding them to `@default_prefixes` or passing `prefixes: [...]`.

  Start and stop of one span fire in the same process, so the open spans are
  tracked per process in a stack kept in the process dictionary. A span's OTel
  context is made current on start and the previous context restored on
  stop/exception.

  ## Cross-process hierarchy

  A parent/child link across processes exists only if the code under test
  propagates the OTel context (see `Normandy.Telemetry.OtelCtx`). A spawned
  process starts with an empty context, so the bridge opens a new root span
  there with a new `trace_id`. That is exactly what later tests assert: a
  broken link shows up as a different `trace_id` or a missing parent.

  Spans ended in other processes may finish after the test body does; use
  `await_spans/2` rather than `finished_spans/0` for those.

  ## Killed runs

  A coordinator that kills a task mid-run emits a synthetic run `:exception`
  with `reason: :killed` from its own process (see
  `Normandy.Telemetry.KilledRun`). That process has no open span for it, and
  the killed process's span can't be reached, so the bridge drops the event
  like a real process-keyed bridge would, instead of reporting it. The killed
  run's span is never exported.

  ## Bridge errors

  A stop/exception event with no open span, or whose name differs from the span
  on top of that process's stack, is a bridge error. Telemetry swallows handler
  raises, so the handler sends `{:otel_bridge_error, details}` to the process
  that called `attach/1`; `assert_no_bridge_errors/0` (also called by
  `await_spans/2`) fails the test if any arrived.

  The collector needs the OTel SDK's span processor to be the simple
  (synchronous) one and its exporter to be `:otel_exporter_pid`; see
  `config/test.exs` (`processors`) and `attach/1` (`set_exporter`).
  """

  @default_prefixes [
    [:normandy, :agent, :run],
    [:normandy, :agent, :llm_call],
    [:normandy, :tool, :execute]
  ]

  @handler_id "normandy-test-otel-span-bridge"
  @stack_key {__MODULE__, :stack}

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @type finished_span :: %{
          name: String.t(),
          span_id: non_neg_integer(),
          parent_span_id: non_neg_integer() | :undefined,
          trace_id: non_neg_integer()
        }

  @doc """
  Attaches the bridge handlers and routes finished spans to the calling process.

  Options:

    * `:prefixes` - event prefixes to bridge (default: agent run, agent llm_call,
      tool execute). Use `default_prefixes/0 ++ [...]` to extend.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    prefixes = Keyword.get(opts, :prefixes, @default_prefixes)

    events =
      for prefix <- prefixes, suffix <- [:start, :stop, :exception], do: prefix ++ [suffix]

    detach()
    owner = self()
    :ok = :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, owner)

    # The SDK logs an info line when the exporter initialises; keep test output clean.
    _ =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, owner)
      end)

    flush_messages()
    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @spec default_prefixes() :: [[atom()]]
  def default_prefixes, do: @default_prefixes

  @doc """
  Returns the spans finished so far (and delivered to the calling process, which
  must be the one that called `attach/1`), in the order they ended.
  """
  @spec finished_spans() :: [finished_span()]
  def finished_spans do
    drain([])
  end

  @doc """
  Blocks until the expected spans have finished, then returns every span
  delivered so far (same shape as `finished_spans/0`).

  `expected` is a span count, or a list of names (repeat a name to expect it
  several times). Raises on timeout, or if the bridge recorded an error.
  """
  @spec await_spans(non_neg_integer() | [String.t()], timeout()) :: [finished_span()]
  def await_spans(expected, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    spans = await_loop(expected, deadline, drain([]))
    assert_no_bridge_errors()
    spans
  end

  @doc "Fails the test if the bridge recorded any stop/exception mismatch."
  @spec assert_no_bridge_errors() :: :ok
  def assert_no_bridge_errors do
    case drain_errors([]) do
      [] -> :ok
      errors -> ExUnit.Assertions.flunk("OtelSpanBridge errors: #{inspect(errors)}")
    end
  end

  @doc "Finds the one span with `name` (e.g. `\"normandy.agent.run\"`); raises if not exactly one."
  @spec fetch_span!([finished_span()], String.t()) :: finished_span()
  def fetch_span!(spans, name) do
    case Enum.filter(spans, &(&1.name == name)) do
      [one] -> one
      other -> raise "expected exactly one span named #{inspect(name)}, got #{length(other)}"
    end
  end

  @doc false
  def handle_event(event, _measurements, metadata, owner) do
    {prefix, [kind]} = Enum.split(event, -1)
    name = Enum.map_join(prefix, ".", &Atom.to_string/1)

    cond do
      kind == :start -> open_span(name)
      killed_elsewhere?(kind, metadata) -> :ok
      true -> close_span(name, kind, owner)
    end
  end

  # A coordinator's synthetic exception for a run it killed fires in the
  # coordinator, which has no open span for it (see "Killed runs").
  defp killed_elsewhere?(:exception, %{reason: :killed}),
    do: Process.get(@stack_key, []) == []

  defp killed_elsewhere?(_kind, _metadata), do: false

  defp open_span(name) do
    tracer = :opentelemetry.get_application_tracer(__MODULE__)
    parent_ctx = :otel_ctx.get_current()
    otel_span = :otel_tracer.start_span(parent_ctx, tracer, name, %{})
    token = :otel_ctx.attach(:otel_tracer.set_current_span(parent_ctx, otel_span))
    _ = Process.put(@stack_key, [{name, otel_span, token} | Process.get(@stack_key, [])])
    :ok
  end

  defp close_span(name, kind, owner) do
    case Process.get(@stack_key, []) do
      [{^name, otel_span, token} | rest] ->
        _ = Process.put(@stack_key, rest)
        _ = :otel_span.end_span(otel_span)
        _ = :otel_ctx.detach(token)
        :ok

      [{open_name, otel_span, token} | rest] ->
        # Still unwind so the process context stays sane after the mismatch.
        _ = Process.put(@stack_key, rest)
        _ = :otel_span.end_span(otel_span)
        _ = :otel_ctx.detach(token)
        report(owner, %{reason: :name_mismatch, event: {name, kind}, open_span: open_name})

      [] ->
        report(owner, %{reason: :no_open_span, event: {name, kind}})
    end
  end

  defp report(owner, details) do
    send(owner, {:otel_bridge_error, Map.put(details, :pid, self())})
    :ok
  end

  defp await_loop(expected, deadline, spans) do
    if satisfied?(expected, spans) do
      spans
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:span, record} when Record.is_record(record, :span) ->
          await_loop(expected, deadline, spans ++ [to_map(record)])
      after
        remaining ->
          raise "timed out waiting for spans #{inspect(expected)}; got " <>
                  inspect(Enum.map(spans, & &1.name))
      end
    end
  end

  defp satisfied?(count, spans) when is_integer(count), do: length(spans) >= count

  defp satisfied?(names, spans) when is_list(names) do
    have = Enum.frequencies_by(spans, & &1.name)
    want = Enum.frequencies(names)
    Enum.all?(want, fn {name, n} -> Map.get(have, name, 0) >= n end)
  end

  defp drain_errors(acc) do
    receive do
      {:otel_bridge_error, details} -> drain_errors([details | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain(acc) do
    receive do
      {:span, record} when Record.is_record(record, :span) ->
        drain([to_map(record) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_messages do
    receive do
      {:span, _} -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp to_map(record) do
    %{
      name: span(record, :name),
      span_id: span(record, :span_id),
      parent_span_id: span(record, :parent_span_id),
      trace_id: span(record, :trace_id)
    }
  end
end
