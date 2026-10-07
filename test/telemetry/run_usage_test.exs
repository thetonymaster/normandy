defmodule Normandy.Telemetry.RunUsageTest do
  use ExUnit.Case, async: true

  alias Normandy.Telemetry.RunUsage

  test "a new accumulator reports no calls and no token keys" do
    assert RunUsage.stop_metadata(RunUsage.new()) == %{llm_calls: 0}
  end

  test "sums the counts of every call and keeps only the counts some call reported" do
    acc = RunUsage.new()
    assert :ok = RunUsage.add(acc, %{input_tokens: 10, output_tokens: 5, model: "m"})
    assert :ok = RunUsage.add(acc, %{input_tokens: 7, cache_read_input_tokens: 3})
    assert :ok = RunUsage.add(acc, %{})

    assert RunUsage.stop_metadata(acc) == %{
             llm_calls: 3,
             input_tokens: 17,
             output_tokens: 5,
             cache_read_input_tokens: 3
           }
  end

  test "a reported count of 0 is kept" do
    acc = RunUsage.new()
    :ok = RunUsage.add(acc, %{cache_write_input_tokens: 0})
    assert RunUsage.stop_metadata(acc) == %{llm_calls: 1, cache_write_input_tokens: 0}
  end

  test "nil (a request with no accumulator) adds nothing" do
    assert :ok = RunUsage.add(nil, %{input_tokens: 1})
  end
end
