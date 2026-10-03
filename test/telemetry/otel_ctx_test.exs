defmodule NormandyTest.Telemetry.OtelCtxTest do
  # OTel's text-map propagator is global; keep this file serial with the other
  # telemetry tests.
  use ExUnit.Case, async: false

  alias Normandy.Telemetry.OtelCtx

  defp ctx_with_span do
    tracer = :opentelemetry.get_application_tracer(__MODULE__)
    span = :otel_tracer.start_span(:otel_ctx.new(), tracer, "carrier", %{})
    {:otel_tracer.set_current_span(:otel_ctx.new(), span), span}
  end

  describe "inject/1" do
    test "writes the context's span as a W3C traceparent" do
      {ctx, span} = ctx_with_span()

      assert [{"traceparent", traceparent}] = OtelCtx.inject(ctx)

      trace_hex = :otel_span.hex_trace_id(span)
      span_hex = :otel_span.hex_span_id(span)
      assert traceparent =~ ~r/^00-#{trace_hex}-#{span_hex}-0[01]$/
    end

    test "is [] for a nil context or one with no span" do
      assert OtelCtx.inject(nil) == []
      assert OtelCtx.inject(:otel_ctx.new()) == []
    end
  end

  describe "extract/1" do
    test "rebuilds a context whose current span carries the injected ids" do
      {ctx, span} = ctx_with_span()

      extracted = OtelCtx.extract(OtelCtx.inject(ctx))
      remote = :otel_tracer.current_span_ctx(extracted)

      assert :otel_span.trace_id(remote) == :otel_span.trace_id(span)
      assert :otel_span.span_id(remote) == :otel_span.span_id(span)
    end

    test "is nil for an empty carrier" do
      assert OtelCtx.extract([]) == nil
    end

    test "does not change the calling process's current context" do
      {ctx, _span} = ctx_with_span()
      before = :otel_ctx.get_current()

      _ = OtelCtx.extract(OtelCtx.inject(ctx))

      assert :otel_ctx.get_current() == before
    end
  end
end
