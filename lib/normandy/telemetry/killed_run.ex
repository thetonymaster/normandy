defmodule Normandy.Telemetry.KilledRun do
  @moduledoc """
  Synthetic `[:normandy, :agent, :run, :exception]` for an agent run that a
  coordinator killed.

  `BaseAgent.run` wraps the run in a span (`:start`, then `:stop` or
  `:exception`). When the process running it is killed (a
  `Reactive.race`/`Reactive.some` loser shut down with
  `:brutal_kill`, or a `Task.async_stream` task stopped by
  `on_timeout: :kill_task`), the span's `:stop`/`:exception` never fires. The
  coordinator that did the killing calls `emit/3` instead, so a handler still
  sees the run end.

  The event matches a real run exception except where noted:

    * measurements: `%{duration: native, monotonic_time: native}`, with
      `duration` measured by the coordinator from the task's start (for an
      `async_stream` timeout, the per-task timeout itself)
    * metadata: the run's start metadata (`model`, `agent_name`) plus
      `kind: :exit`, `reason: :killed`, `stacktrace: []`. It has no
      `telemetry_span_context`: that reference was created inside the killed
      process and died with it.

  ## Guarantees and limits

    * Emitted once for every task a coordinator started to run an agent struct
      and then killed before the run returned. The coordinator can't see
      whether the run's `:start` had fired yet, so a handler may get a killed
      `:exception` with no matching `:start` and must tolerate that.
    * Not emitted for a task killed after its run returned, for example while
      it ran an `on_complete`, `on_agent_complete` or `:transform` callback.
      The task marks its run as done (`mark_run_done/2`) as soon as the run
      returns, and the coordinator checks the mark (`run_done?/2`) before
      emitting. The mark is written after the run's `:stop`/`:exception` has
      fired, so a kill landing between the two still gets a synthetic
      `:exception` after the real one; that window is short. `Batch.Processor` runs no callbacks in the task and doesn't mark:
      its window, from the run's `:stop` to the task's reply, is the same short window.
    * Not emitted for agent processes (a pid in `Reactive.race/3`): killing
      the task that waits on `AgentProcess.run/3` does not kill a run in flight,
      which ends normally in the agent process's worker; a run still queued
      behind another is skipped.
    * Not emitted for tasks `Task.async_stream` shuts down because the
      consumer halted the stream early (`Reactive.all/3` with `fail_fast`):
      the coordinator can't tell which tasks were still running.
    * The `llm_call` and `tool` spans that were open inside the killed run are
      left open; nothing emits their `:stop`/`:exception`.

  ## OpenTelemetry bridges

  The OTel context the killed task ran under (the caller's, captured with
  `Normandy.Telemetry.OtelCtx`) is attached around the event, so a handler
  sees the caller's span as current. A bridge still can't end the killed
  run's span from here: span bridges such as `opentelemetry_telemetry` keep
  the open span in the process dictionary of the process that fired
  `:start`, and that process is gone. In the coordinator the bridge finds no
  open span and drops the event (the test bridge reports it as
  `:no_open_span`). The OTel SDK's span sweeper eventually discards the
  orphaned span. Handlers that want the kill on the trace can record it from
  this event, under the current (caller's) span.

  If the coordinator process itself has spans open (a `Reactive.race/3` run
  from inside a tool, say, whose `tool` span is open in that process), a
  bridge that falls back to the top of the per-process span stack instead of
  matching the event to its own span may end that unrelated span here.
  """

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Telemetry.Metadata
  alias Normandy.Telemetry.OtelCtx

  @doc """
  Emits the synthetic run exception for `agent`, killed after running for
  `duration` (native time units), with `otel_ctx` attached while emitting.

  A no-op for anything other than a `%BaseAgentConfig{}` (an agent pid, say).
  """
  @spec emit(term(), integer(), term() | nil) :: :ok
  def emit(%BaseAgentConfig{} = agent, duration, otel_ctx) do
    measurements = %{duration: duration, monotonic_time: System.monotonic_time()}

    metadata =
      Map.merge(Metadata.run(agent), %{kind: :exit, reason: :killed, stacktrace: []})

    token = OtelCtx.attach(otel_ctx)

    try do
      :telemetry.execute([:normandy, :agent, :run, :exception], measurements, metadata)
    after
      OtelCtx.detach(token)
    end

    :ok
  end

  def emit(_not_an_agent, _duration, _otel_ctx), do: :ok

  @doc """
  Returns run-done marks for `count` tasks, all unset. A task marks its slot
  with `mark_run_done/2` once its run returns; the coordinator checks it with
  `run_done?/2` before emitting. Slots are 0-based.
  """
  @spec new_run_marks(non_neg_integer()) :: :atomics.atomics_ref()
  def new_run_marks(count), do: :atomics.new(max(count, 1), [])

  @doc "Marks task `index`'s run as returned."
  @spec mark_run_done(:atomics.atomics_ref(), non_neg_integer()) :: :ok
  def mark_run_done(marks, index), do: :atomics.put(marks, index + 1, 1)

  @doc "Whether task `index`'s run returned before the task was killed."
  @spec run_done?(:atomics.atomics_ref(), non_neg_integer()) :: boolean()
  def run_done?(marks, index), do: :atomics.get(marks, index + 1) == 1

  @doc """
  `emit/3` for a `Task.async_stream` task killed by `on_timeout: :kill_task`
  after `timeout_ms`, which is how long the task ran.
  """
  @spec emit_timeout(term(), non_neg_integer(), term() | nil) :: :ok
  def emit_timeout(agent, timeout_ms, otel_ctx) do
    emit(agent, System.convert_time_unit(timeout_ms, :millisecond, :native), otel_ctx)
  end
end
