defmodule NormandyTest.E2E.PricesTest do
  @moduledoc "Task 7.6a: e2e token totals and their estimated cost (REL-9)."
  use ExUnit.Case, async: true

  alias NormandyTest.E2E.Prices

  test "totals/1 sums tokens per call and prices them by model" do
    calls = [
      {"claude-haiku-4-5-20251001",
       %{
         input_tokens: 1_000_000,
         output_tokens: 100_000,
         cache_read_input_tokens: 1_000_000,
         cache_creation_input_tokens: 0
       }},
      {"claude-opus-5-5",
       %{input_tokens: 0, output_tokens: 50_000, cache_creation_input_tokens: 200_000}},
      # A streamed call's create:stop carries no tokens and may carry no model.
      {nil, %{}}
    ]

    assert %{
             input: 1_000_000,
             output: 150_000,
             cache_read: 1_000_000,
             cache_write: 200_000,
             cost: cost
           } = Prices.totals(calls)

    # Haiku 1.00 + 0.50 + 0.10; Opus 1.00 (output) + 1.00 (cache write).
    assert_in_delta cost, 3.60, 1.0e-9
  end

  test "format/2 prints the usage line" do
    totals = %{input: 10, output: 2, cache_read: 0, cache_write: 4, cost: 1.234}

    assert Prices.format(totals) ==
             "usage: input=10 output=2 cache_read=0 cache_write=4 est_cost=$1.23"

    assert Prices.format(totals, "usage (known)") =~ "usage (known): input=10"
  end

  test "price!/1 names an unknown model, and a priced call needs a model" do
    assert_raise ArgumentError,
                 ~s(no e2e price for model "gpt-x"; add it to NormandyTest.E2E.Prices ) <>
                   ~s{(known prefixes: "claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5")},
                 fn -> Prices.price!("gpt-x") end

    assert_raise ArgumentError, ~r/carries tokens but no model/, fn ->
      Prices.totals([{nil, %{input_tokens: 5}}])
    end
  end

  test "sum/1 adds totals" do
    a = %{input: 1, output: 2, cache_read: 3, cache_write: 4, cost: 0.5}
    assert Prices.sum([a, a]) == %{input: 2, output: 4, cache_read: 6, cache_write: 8, cost: 1.0}
    assert Prices.sum([]) == %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
  end
end
