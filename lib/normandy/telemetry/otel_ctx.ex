defmodule Normandy.Telemetry.OtelCtx do
  @moduledoc """
  Soft OpenTelemetry context propagation across process boundaries.

  Normandy doesn't depend on `:opentelemetry` directly — consumers wire it up
  via telemetry handlers. When OTel is loaded, `capture/0` snapshots the
  active context in the calling process so another process can install it;
  spans created there then nest under the parent's active span instead of
  becoming root spans in their own trace. When OTel is not loaded, every
  function here is a cheap no-op.

  Whether each OTel module is loaded is asked of the code server once per node, then
  cached in `:persistent_term`: an absent module would otherwise cost a code-server
  round trip on every call, from every process. So OTel loaded after the first call
  that looked for it (a hot code load) is not seen until the node restarts.

  Two ways to install a captured context:

    * `restore/1` attaches it and never undoes that. Use it only at the top of
      a short-lived process (a Task, a spawned worker) whose context dies with
      it.
    * `attach/1` returns a token that `detach/1` takes to put back the context
      that was current before. Use it in a long-lived process (a gen_statem
      serving many requests), so one request's context does not leak into the
      next.

  A context lives only in memory. To keep one across a restart, `inject/1`
  turns it into a W3C text-map carrier (a list of string pairs) that can be
  persisted, and `extract/1` rebuilds a context from that carrier.

  ## Usage

      parent_ctx = Normandy.Telemetry.OtelCtx.capture()

      Task.async(fn ->
        Normandy.Telemetry.OtelCtx.restore(parent_ctx)
        # ... spans opened here nest under the parent's active span
      end)

      # In a long-lived process:
      token = Normandy.Telemetry.OtelCtx.attach(caller_ctx)
      # ... spans opened here nest under the caller's active span
      Normandy.Telemetry.OtelCtx.detach(token)
  """

  @doc false
  # Code.ensure_loaded?/1, asked once per node and module (see the moduledoc). Public
  # for its test only.
  @spec __loaded__?(module()) :: boolean()
  def __loaded__?(module) do
    key = {__MODULE__, module}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        loaded = Code.ensure_loaded?(module)
        :persistent_term.put(key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  @spec capture() :: term() | nil
  def capture do
    if __loaded__?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :get_current, 0) do
      # OpenTelemetry is a soft dependency: a direct call would emit an
      # undefined-module compile warning when it is absent.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(OpenTelemetry.Ctx, :get_current, [])
    end
  end

  @doc """
  Attaches `ctx` for good. Only for short-lived processes; see the moduledoc.
  """
  @spec restore(term() | nil) :: :ok
  def restore(ctx) do
    _ = attach(ctx)
    :ok
  end

  @doc """
  Attaches `ctx` and returns a token for `detach/1`, or `nil` when `ctx` is
  `nil` or OTel is absent.
  """
  @spec attach(term() | nil) :: term() | nil
  def attach(nil), do: nil

  def attach(ctx) do
    if __loaded__?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :attach, 1) do
      # Soft dependency, see capture/0.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(OpenTelemetry.Ctx, :attach, [ctx])
    end
  end

  @doc """
  Writes `ctx` into a W3C text-map carrier (`[{"traceparent", ...}]`, plus
  `tracestate`/`baggage` when present) with the globally configured
  propagator. `[]` when `ctx` is `nil`, holds no span, or OTel is absent.

  Unlike a context, a carrier is plain strings, so it can be persisted and
  read back by another process, node or Normandy release.
  """
  @spec inject(term() | nil) :: [{String.t(), String.t()}]
  def inject(nil), do: []

  def inject(ctx) do
    if __loaded__?(:otel_propagator_text_map) do
      # Soft dependency, see capture/0.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(:otel_propagator_text_map, :inject_from, [ctx, []])
    else
      []
    end
  end

  @doc """
  Rebuilds a context from a carrier written by `inject/1`, without touching
  the calling process's current context; install it with `attach/1`. `nil`
  for an empty carrier, a carrier with no valid span context (no or a
  malformed `traceparent`), or when OTel is absent, so a caller that attaches
  the result keeps its current context.
  """
  @spec extract([{String.t(), String.t()}]) :: term() | nil
  def extract([]), do: nil

  def extract(carrier) when is_list(carrier) do
    if __loaded__?(:otel_propagator_text_map) and __loaded__?(:otel_ctx) do
      # Soft dependency, see capture/0.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      empty = apply(:otel_ctx, :new, [])
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      ctx = apply(:otel_propagator_text_map, :extract_to, [empty, carrier])
      if valid_span?(ctx), do: ctx
    end
  end

  defp valid_span?(ctx) do
    # Soft dependency, see capture/0.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    span_ctx = apply(:otel_tracer, :current_span_ctx, [ctx])
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    span_ctx != :undefined and apply(:otel_span, :is_valid, [span_ctx])
  end

  @doc """
  Puts back the context that was current before the `attach/1` that returned
  `token`. A `nil` token is a no-op.
  """
  @spec detach(term() | nil) :: :ok
  def detach(nil), do: :ok

  def detach(token) do
    if __loaded__?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :detach, 1) do
      # Soft dependency, see capture/0.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(OpenTelemetry.Ctx, :detach, [token])
    end

    :ok
  end
end
