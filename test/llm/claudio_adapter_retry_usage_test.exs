defmodule Normandy.LLM.ClaudioAdapterRetryUsageTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Telemetry.Usage

  defp collect(first, retries) do
    ref = make_ref()
    for r <- retries, do: send(self(), {ref, :retry_usage, r})
    ClaudioAdapter.collect_retry_usage(ref, first)
  end

  test "a retry without iterations is appended to the first call's iterations" do
    first = %{
      input_tokens: 10,
      output_tokens: 5,
      iterations: [
        %{"type" => "message", "input_tokens" => 10, "output_tokens" => 1},
        %{"type" => "fallback_message", "input_tokens" => 10, "output_tokens" => 5}
      ]
    }

    retry = %{input_tokens: 4, output_tokens: 2, cache_read_input_tokens: 30}
    merged = collect(first, [retry])

    # raw top-level semantics unchanged: summed integers
    assert merged.input_tokens == 14
    assert merged.output_tokens == 7
    assert length(merged.iterations) == 3

    assert Usage.normalize(merged) == %{
             input_tokens: 10 + 10 + 4 + 30,
             output_tokens: 1 + 5 + 2,
             cache_read_input_tokens: 30
           }
  end

  test "both calls carrying iterations are concatenated" do
    first = %{
      input_tokens: 1,
      output_tokens: 1,
      iterations: [%{"input_tokens" => 1, "output_tokens" => 1}]
    }

    retry = %{
      "input_tokens" => 2,
      "output_tokens" => 2,
      "iterations" => [
        %{"input_tokens" => 5, "output_tokens" => 1},
        %{"input_tokens" => 2, "output_tokens" => 2}
      ]
    }

    merged = collect(first, [retry])
    assert length(merged.iterations) == 3
    refute Map.has_key?(merged, "iterations")
    assert Usage.normalize(merged) == %{input_tokens: 8, output_tokens: 4}
  end

  test "first call without iterations and a retry with them" do
    first = %{input_tokens: 3, output_tokens: 3}

    retry = %{
      input_tokens: 2,
      output_tokens: 2,
      iterations: [%{"input_tokens" => 2, "output_tokens" => 2}]
    }

    assert Usage.normalize(collect(first, [retry])) == %{input_tokens: 5, output_tokens: 5}
  end

  test "without iterations on either side usage merges as before" do
    merged = collect(%{input_tokens: 3, output_tokens: 3}, [%{input_tokens: 2, output_tokens: 1}])
    assert merged == %{input_tokens: 5, output_tokens: 4}
  end
end
