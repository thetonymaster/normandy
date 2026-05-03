defmodule Normandy.Telemetry.OtelCtx do
  @moduledoc """
  Soft OpenTelemetry context propagation across process boundaries.

  Normandy doesn't depend on `:opentelemetry` directly — consumers wire it up
  via telemetry handlers. When OTel is loaded, `capture/0` snapshots the
  active context in the calling process so a spawned process can `restore/1`
  it; spans created in the spawned process then nest under the parent's
  active span instead of becoming root spans in their own trace. When OTel is
  not loaded, both functions are cheap no-ops.

  ## Usage

      parent_ctx = Normandy.Telemetry.OtelCtx.capture()

      Task.async(fn ->
        Normandy.Telemetry.OtelCtx.restore(parent_ctx)
        # ... spans opened here nest under the parent's active span
      end)
  """

  @spec capture() :: term() | nil
  def capture do
    if Code.ensure_loaded?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :get_current, 0) do
      apply(OpenTelemetry.Ctx, :get_current, [])
    end
  end

  @spec restore(term() | nil) :: :ok
  def restore(nil), do: :ok

  def restore(ctx) do
    if function_exported?(OpenTelemetry.Ctx, :attach, 1) do
      apply(OpenTelemetry.Ctx, :attach, [ctx])
    end

    :ok
  end
end
