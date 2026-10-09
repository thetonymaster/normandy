defmodule NormandyTest.E2E.Prices do
  @moduledoc """
  USD per million tokens for the models the live e2e suite calls: Anthropic API list prices
  as of 2026-10. `cache_write` is the 5-minute cache write (1.25 x input). Used by
  `e2e/support.exs` for each scenario's usage line and by `NormandyTest.E2E.Runner` for the
  summary and `mix e2e --estimate`. An estimate, not an invoice: no batch or fast-mode
  pricing, no server-tool fees (web search bills per search).
  """

  @prices [
    {"claude-haiku-4-5", %{input: 1.00, output: 5.00, cache_read: 0.10, cache_write: 1.25}},
    {"claude-sonnet-5-5", %{input: 2.00, output: 10.00, cache_read: 0.20, cache_write: 2.50}},
    {"claude-opus-5-5", %{input: 4.00, output: 20.00, cache_read: 0.20, cache_write: 5.00}}
  ]

  @zero %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}

  @doc "The price row whose model-id prefix `model` starts with (dated ids included)."
  @spec price!(String.t()) :: map()
  def price!(model) when is_binary(model) do
    case Enum.find(@prices, fn {prefix, _} -> String.starts_with?(model, prefix) end) do
      {_prefix, price} ->
        price

      nil ->
        raise ArgumentError,
              "no e2e price for model #{inspect(model)}; add it to #{inspect(__MODULE__)} " <>
                "(known prefixes: #{Enum.map_join(@prices, ", ", &inspect(elem(&1, 0)))})"
    end
  end

  @doc """
  Token totals and estimated cost of `calls`, a list of `{model, measurements}` where the
  measurements are Claudio's telemetry token keys. A call with no tokens costs nothing
  whatever its model (a streamed request's `create` stop); one with tokens needs a model.
  """
  @spec totals([{String.t() | nil, map()}]) :: map()
  def totals(calls) do
    Enum.reduce(calls, @zero, fn {model, m}, acc ->
      t = %{
        input: Map.get(m, :input_tokens, 0),
        output: Map.get(m, :output_tokens, 0),
        cache_read: Map.get(m, :cache_read_input_tokens, 0),
        cache_write: Map.get(m, :cache_creation_input_tokens, 0)
      }

      sum([acc, Map.put(t, :cost, cost(model, t))])
    end)
  end

  @doc """
  Like `totals/1`, but never raises: when a call cannot be priced (unknown model, or tokens
  without a model) the token counts are still summed and `cost` is `nil`. For reports that
  must print on a failure path.
  """
  @spec safe_totals([{String.t() | nil, map()}]) :: map()
  def safe_totals(calls) do
    totals(calls)
  rescue
    ArgumentError ->
      calls
      |> Enum.map(fn {_model, m} -> totals([{"claude-haiku-4-5", m}]) end)
      |> sum()
      |> Map.put(:cost, nil)
  end

  defp cost(_model, %{input: 0, output: 0, cache_read: 0, cache_write: 0}), do: 0.0

  defp cost(nil, t) do
    raise ArgumentError,
          "an e2e call carries tokens but no model in its telemetry metadata: #{inspect(t)}"
  end

  defp cost(model, t) do
    p = price!(model)

    (t.input * p.input + t.output * p.output + t.cache_read * p.cache_read +
       t.cache_write * p.cache_write) / 1_000_000
  end

  @doc "Adds totals maps."
  @spec sum([map()]) :: map()
  def sum(totals) do
    Enum.reduce(totals, @zero, fn t, acc ->
      t = Map.update!(t, :cost, &(&1 || 0.0))

      %{
        input: acc.input + t.input,
        output: acc.output + t.output,
        cache_read: acc.cache_read + t.cache_read,
        cache_write: acc.cache_write + t.cache_write,
        cost: acc.cost + t.cost
      }
    end)
  end

  @doc "The one-line usage report: `<label>: input=N output=N cache_read=N cache_write=N est_cost=$X.XX`."
  @spec format(map(), String.t()) :: String.t()
  def format(t, label \\ "usage") do
    "#{label}: input=#{t.input} output=#{t.output} cache_read=#{t.cache_read} " <>
      "cache_write=#{t.cache_write} est_cost=#{if t.cost, do: "$" <> dollars(t.cost), else: "unknown"}"
  end

  @doc "Dollars with two decimals."
  @spec dollars(number()) :: String.t()
  def dollars(amount), do: :erlang.float_to_binary(amount / 1, decimals: 2)
end
