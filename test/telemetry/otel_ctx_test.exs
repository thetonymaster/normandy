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

  describe "__loaded__?/1" do
    test "asks the code server once per module, then answers from the cache" do
      module = NormandyTest.NoSuchOtelModule
      key = {OtelCtx, module}
      :persistent_term.erase(key)
      on_exit(fn -> :persistent_term.erase(key) end)

      code_server = Process.whereis(:code_server)
      :erlang.trace(code_server, true, [:receive])

      results = for _ <- 1..100, do: OtelCtx.__loaded__?(module)

      :erlang.trace(code_server, false, [:receive])
      trace_ref = :erlang.trace_delivered(code_server)
      assert_receive {:trace_delivered, ^code_server, ^trace_ref}

      assert Enum.uniq(results) == [false]
      assert code_server_calls_about(module) == 1
    end

    test "every function reads the cache" do
      {ctx, _span} = ctx_with_span()
      carrier = OtelCtx.inject(ctx)

      keys =
        for module <- [OpenTelemetry.Ctx, :otel_propagator_text_map, :otel_ctx],
            do: {OtelCtx, module}

      on_exit(fn -> Enum.each(keys, &:persistent_term.erase/1) end)

      # OTel is loaded in the test env; a cached `false` must make every function a no-op.
      Enum.each(keys, &:persistent_term.put(&1, false))

      assert OtelCtx.capture() == nil
      assert OtelCtx.attach(ctx) == nil
      assert OtelCtx.detach(make_ref()) == :ok
      assert OtelCtx.inject(ctx) == []
      assert OtelCtx.extract(carrier) == nil
    end
  end

  # The trace messages the code server received from this process naming `module`.
  defp code_server_calls_about(module) do
    me = self()

    receive_all()
    |> Enum.count(fn
      {:trace, _cs, :receive, {:code_call, ^me, request}} when is_tuple(request) ->
        module in Tuple.to_list(request)

      _other ->
        false
    end)
  end

  defp receive_all(acc \\ []) do
    receive do
      {:trace, _, :receive, _} = msg -> receive_all([msg | acc])
    after
      0 -> acc
    end
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

    test "is nil when the carrier holds no valid span context" do
      assert OtelCtx.extract([{"traceparent", "garbage"}]) == nil
      assert OtelCtx.extract([{"x-tenant", "t1"}]) == nil
    end

    test "does not change the calling process's current context" do
      {ctx, _span} = ctx_with_span()
      before = :otel_ctx.get_current()

      _ = OtelCtx.extract(OtelCtx.inject(ctx))

      assert :otel_ctx.get_current() == before
    end
  end
end
