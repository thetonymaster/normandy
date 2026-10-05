defmodule Normandy.Telemetry.SpanTest do
  # async: false — attaches global telemetry handlers.
  use ExUnit.Case, async: false

  alias Normandy.Telemetry.Span

  def forward(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata})

  setup do
    id = "span-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      for(
        prefix <- [[:t], [:ref]],
        suffix <- [:start, :stop, :exception],
        do: prefix ++ [suffix]
      ),
      &__MODULE__.forward/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "an :exception event carries stacktrace: [] and the raise keeps its stacktrace" do
    error =
      assert_raise RuntimeError, "boom", fn ->
        Span.span([:t], %{a: 1}, fn -> raise "boom" end)
      end

    assert %RuntimeError{} = error

    assert_received {:telemetry, [:t, :start], _, %{a: 1, telemetry_span_context: ctx}}

    assert_received {:telemetry, [:t, :exception], %{duration: _, monotonic_time: _},
                     %{
                       a: 1,
                       kind: :error,
                       reason: %RuntimeError{message: "boom"},
                       stacktrace: [],
                       telemetry_span_context: ^ctx
                     }}
  end

  test "the original stacktrace survives the re-raise" do
    {_, stacktrace} =
      try do
        Span.span([:t], %{}, fn -> raise "boom" end)
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert [_ | _] = stacktrace
  end

  test "throws and exits are re-raised with their kind" do
    assert catch_throw(Span.span([:t], %{}, fn -> throw(:x) end)) == :x
    assert_received {:telemetry, [:t, :exception], _, %{kind: :throw, reason: :x, stacktrace: []}}
    assert catch_exit(Span.span([:t], %{}, fn -> exit(:y) end)) == :y
  end

  test "start and stop match :telemetry.span/3, and the result passes through" do
    assert :ok = Span.span([:t], %{a: 1}, fn -> {:ok, %{b: 2}} end)
    assert :ok = :telemetry.span([:ref], %{a: 1}, fn -> {:ok, %{b: 2}} end)

    for suffix <- [:start, :stop] do
      assert_received {:telemetry, [:t, ^suffix], m1, md1}
      assert_received {:telemetry, [:ref, ^suffix], m2, md2}
      assert Map.keys(m1) |> Enum.sort() == Map.keys(m2) |> Enum.sort()
      assert Map.keys(md1) |> Enum.sort() == Map.keys(md2) |> Enum.sort()
    end
  end

  test "stop shares the start's span context and merges extra measurements" do
    assert :r = Span.span([:t], %{}, fn -> {:r, %{bytes: 3}, %{c: 1}} end)

    assert_received {:telemetry, [:t, :start], _, %{telemetry_span_context: ctx}}

    assert_received {:telemetry, [:t, :stop], %{bytes: 3, duration: _, monotonic_time: _},
                     %{c: 1, telemetry_span_context: ^ctx}}
  end
end
