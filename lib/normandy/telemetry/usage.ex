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

  OpenAI-shaped usage (`prompt_tokens`, `completion_tokens`, optionally
  `prompt_tokens_details.cached_tokens`) is recognized too, when the map has no
  `input_tokens`: `prompt_tokens` already includes cached tokens, so it is the
  `:input_tokens` total as is, `completion_tokens` is `:output_tokens`, and
  `cached_tokens` (when present) is `:cache_read_input_tokens`. OpenAI reports no
  cache writes.

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
    |> Enum.map(&(&1 |> openai_to_anthropic() |> counts()))
    |> Enum.reduce(%{}, fn counts, acc -> Map.merge(acc, counts, fn _k, a, b -> a + b end) end)
    |> total_input()
  end

  @doc """
  Puts the raw provider `usage` under `:usage` in `metadata` when it is a non-empty map,
  and returns `metadata` unchanged otherwise, so a call whose provider reported no usage
  has no `:usage` key (never `usage: nil`).

  ## Examples

      iex> Normandy.Telemetry.Usage.put_raw(%{}, %{input_tokens: 3})
      %{usage: %{input_tokens: 3}}

      iex> Normandy.Telemetry.Usage.put_raw(%{}, nil)
      %{}
  """
  @spec put_raw(map(), term()) :: map()
  def put_raw(metadata, usage) when is_map(usage) and map_size(usage) > 0,
    do: Map.put(metadata, :usage, usage)

  def put_raw(metadata, _usage), do: metadata

  @doc """
  Adds two raw provider usage maps (or structs), the one rule for combining the usage of
  several calls. A `nil` side returns the other (as a map). Keys are atoms in the result, so a
  string-keyed (wire) side adds to an atom-keyed one. Integer counts are summed and any other
  value is the later side's. When either side carries `iterations`, the result's
  `iterations` are both sides' entries in order (a side without them contributes one entry
  built from its top-level counts), so `normalize/1` bills their sum and not the top-level
  counts.

  ## Examples

      iex> Normandy.Telemetry.Usage.sum(%{input_tokens: 3}, %{input_tokens: 4})
      %{input_tokens: 7}

      iex> Normandy.Telemetry.Usage.sum(nil, %{input_tokens: 4})
      %{input_tokens: 4}
  """
  @spec sum(map() | struct() | nil, map() | struct() | nil) :: map() | struct() | nil
  def sum(nil, nil), do: nil
  def sum(nil, usage), do: plain(usage)
  def sum(usage, nil), do: plain(usage)

  def sum(%{} = a, %{} = b) do
    a = plain(a)
    b = plain(b)

    merged =
      Map.merge(a, b, fn
        _key, x, y when is_integer(x) and is_integer(y) -> x + y
        _key, _x, y -> y
      end)

    # The top-level counts are summed, but `iterations` must not be overwritten:
    # normalize/1 bills the sum over iterations when they are present.
    if iterations_of(a) == [] and iterations_of(b) == [] do
      merged
    else
      Map.put(merged, :iterations, side_iterations(a) ++ side_iterations(b))
    end
  end

  defp plain(%_{} = usage), do: usage |> Map.from_struct() |> Map.delete(:__meta__) |> plain()
  defp plain(usage), do: Map.new(usage, fn {key, value} -> {atom_key(key), value} end)

  # Wire usage (a stream's final message) has string keys, an adapter's atom keys; a
  # string with no existing atom is no count normalize/1 reads, so it stays a string.
  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp atom_key(key), do: key

  defp iterations_of(usage) do
    case Map.get(usage, :iterations) do
      [_ | _] = iterations -> iterations
      _ -> []
    end
  end

  # Claudio's usage keys its counts with atoms; an iteration entry is the raw API map,
  # string-keyed.
  @iteration_count_keys [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens
  ]

  defp side_iterations(usage) do
    case iterations_of(usage) do
      [] ->
        counts =
          for key <- @iteration_count_keys,
              n = Map.get(usage, key),
              is_integer(n),
              into: %{},
              do: {Atom.to_string(key), n}

        [counts]

      iterations ->
        iterations
    end
  end

  defp sources(usage) do
    usage = to_map(usage)

    with [_ | _] = iterations <- fetch(usage, :iterations),
         [_ | _] = maps <- iterations |> Enum.map(&to_map/1) |> Enum.reject(&(&1 == %{})) do
      maps
    else
      _ -> [usage]
    end
  end

  defp to_map(%_{} = struct), do: struct |> Map.from_struct() |> Map.delete(:__meta__)
  defp to_map(%{} = map), do: map
  defp to_map(_other), do: %{}

  # Rewrites OpenAI-shaped usage into the Anthropic field names so the same
  # summing applies: uncached input = prompt_tokens - cached_tokens.
  defp openai_to_anthropic(source) do
    prompt = fetch(source, :prompt_tokens)

    if is_integer(prompt) and not is_integer(fetch(source, :input_tokens)) do
      cached = cached_tokens(source)
      uncached = %{input_tokens: max(prompt - (cached || 0), 0)}
      base = Map.put(uncached, :output_tokens, fetch(source, :completion_tokens))
      if cached, do: Map.put(base, :cache_read_input_tokens, cached), else: base
    else
      source
    end
  end

  defp cached_tokens(source) do
    with %{} = details <- fetch(source, :prompt_tokens_details),
         n when is_integer(n) <- fetch(details, :cached_tokens) do
      n
    else
      _ -> nil
    end
  end

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
