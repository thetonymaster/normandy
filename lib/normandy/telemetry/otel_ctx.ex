defmodule Normandy.Telemetry.OtelCtx do
  @moduledoc """
  Soft OpenTelemetry context propagation across process boundaries.

  Normandy doesn't depend on `:opentelemetry` directly — consumers wire it up
  via telemetry handlers. When OTel is loaded, `capture/0` snapshots the
  active context in the calling process so another process can install it;
  spans created there then nest under the parent's active span instead of
  becoming root spans in their own trace. When OTel is not loaded, every
  function here is a cheap no-op.

  Two ways to install a captured context:

    * `restore/1` attaches it and never undoes that. Use it only at the top of
      a short-lived process (a Task, a spawned worker) whose context dies with
      it.
    * `attach/1` returns a token that `detach/1` takes to put back the context
      that was current before. Use it in a long-lived process (a gen_statem
      serving many requests), so one request's context does not leak into the
      next.

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

  @spec capture() :: term() | nil
  def capture do
    if Code.ensure_loaded?(OpenTelemetry.Ctx) and
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
    if Code.ensure_loaded?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :attach, 1) do
      # Soft dependency, see capture/0.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(OpenTelemetry.Ctx, :attach, [ctx])
    end
  end

  @doc """
  Puts back the context that was current before the `attach/1` that returned
  `token`. A `nil` token is a no-op.
  """
  @spec detach(term() | nil) :: :ok
  def detach(nil), do: :ok

  def detach(token) do
    if Code.ensure_loaded?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :detach, 1) do
      # Soft dependency, see capture/0.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(OpenTelemetry.Ctx, :detach, [token])
    end

    :ok
  end
end
