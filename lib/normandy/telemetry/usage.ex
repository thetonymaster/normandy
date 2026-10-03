defmodule Normandy.Telemetry.Usage do
  @moduledoc """
  Normalizes a provider token-usage map into the token counts telemetry reports.

  Anthropic reports `input_tokens` as the uncached remainder only: cache reads
  (`cache_read_input_tokens`) and cache writes (`cache_creation_input_tokens`)
  are separate fields. OpenTelemetry's GenAI conventions want
  `gen_ai.usage.input_tokens` to include all of them, so `normalize/1` sums them.

  The result uses these Normandy-side keys (all optional):

    * `:input_tokens` - input + cache read + cache write, summed over the
      fields that are present
    * `:output_tokens`
    * `:cache_read_input_tokens`
    * `:cache_write_input_tokens` - Anthropic's `cache_creation_input_tokens`

  A count the provider did not report (missing or `nil`) is left out of the
  result, never `0` or `nil`. When it reports no count at all, the result is
  `%{}`.

  The input may be a map or struct with atom keys, string keys, or a mix
  (Claudio's non-streaming usage uses atoms; streamed usage arrives with
  string keys). When it carries a non-empty `iterations` list (Claudio's
  refusal `:fallbacks` and compaction record every attempt there while the
  top-level counts cover only the returned one), the billed totals are the sum
  over the iterations and the top-level counts are ignored.

  The raw `usage` map on `[:normandy, :agent, :llm_call, :stop]` is unchanged;
  these keys are added beside it.
  """

  @type normalized :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:cache_read_input_tokens) => non_neg_integer(),
          optional(:cache_write_input_tokens) => non_neg_integer()
        }

  @doc """
  Returns the normalized token counts for `usage`, or `%{}` when `usage` is not
  a map or reports no counts.

  ## Examples

      iex> Normandy.Telemetry.Usage.normalize(%{
      ...>   input_tokens: 10,
      ...>   output_tokens: 5,
      ...>   cache_read_input_tokens: 100,
      ...>   cache_creation_input_tokens: 20
      ...> })
      %{input_tokens: 130, output_tokens: 5, cache_read_input_tokens: 100, cache_write_input_tokens: 20}

      iex> Normandy.Telemetry.Usage.normalize(nil)
      %{}
  """
  @spec normalize(term()) :: normalized()
  def normalize(usage) do
    usage
    |> sources()
    |> Enum.map(&counts/1)
    |> Enum.reduce(%{}, fn counts, acc -> Map.merge(acc, counts, fn _k, a, b -> a + b end) end)
    |> total_input()
  end

  defp sources(usage) do
    usage = to_map(usage)

    case fetch(usage, :iterations) do
      [_ | _] = iterations -> iterations |> Enum.map(&to_map/1) |> Enum.reject(&(&1 == %{}))
      _ -> [usage]
    end
  end

  defp to_map(%_{} = struct), do: struct |> Map.from_struct() |> Map.delete(:__meta__)
  defp to_map(%{} = map), do: map
  defp to_map(_other), do: %{}

  # Per-source counts under the pre-sum names; absent counts are omitted.
  defp counts(source) do
    [
      uncached_input: :input_tokens,
      output_tokens: :output_tokens,
      cache_read_input_tokens: :cache_read_input_tokens,
      cache_write_input_tokens: :cache_creation_input_tokens
    ]
    |> Enum.flat_map(fn {key, field} ->
      case fetch(source, field) do
        n when is_integer(n) -> [{key, n}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp total_input(counts) do
    {uncached, counts} = Map.pop(counts, :uncached_input)

    inputs =
      Enum.reject(
        [uncached, counts[:cache_read_input_tokens], counts[:cache_write_input_tokens]],
        &is_nil/1
      )

    case inputs do
      [] -> counts
      _ -> Map.put(counts, :input_tokens, Enum.sum(inputs))
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
