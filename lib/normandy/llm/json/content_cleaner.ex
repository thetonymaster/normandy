defmodule Normandy.LLM.Json.ContentCleaner do
  @moduledoc false
  # Cleans raw LLM output into a parseable JSON string: strips markdown code
  # fences and trims. `extract_balanced/1` is the prose-extraction fallback
  # (implemented in the hardening phase).

  @doc "Strip code fences and trim. Non-binary content passes through unchanged."
  def clean(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n/, "")
    |> String.replace(~r/^```\n/, "")
    |> String.replace(~r/\n```$/, "")
    |> String.trim()
  end

  def clean(content), do: content

  @doc "Locate the first balanced JSON object/array within surrounding prose."
  @spec extract_balanced(binary()) :: {:ok, binary()} | :error
  def extract_balanced(content) when is_binary(content) do
    case extract_balanced(content, 0) do
      {:ok, region, _start} -> {:ok, region}
      :error -> :error
    end
  end

  def extract_balanced(_content), do: :error

  @doc """
  Like `extract_balanced/1` but begins scanning at byte offset `from` and also
  returns the byte offset where the located region started.
  """
  @spec extract_balanced(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | :error
  def extract_balanced(content, from)
      when is_binary(content) and is_integer(from) and from >= 0 do
    case next_region(content, from, %{}) do
      {{region, start}, _state} -> {:ok, region, start}
      nil -> :error
    end
  end

  def extract_balanced(_content, _from), do: :error

  @doc """
  Every balanced `{...}`/`[...]` region of `content`, in order of the byte offset
  it starts at, as `{region, start}`. A region nested in an earlier one is
  yielded too, so a caller that rejects an outer region still sees the inner
  ones. Lazy, and linear in the size of `content` for the usual input: a scan
  that starts at an opener settles every same-kind opener it passes outside a
  string, so an unclosed `{` costs one pass, not one pass per later `{`.
  """
  @spec balanced_regions(binary()) :: Enumerable.t()
  def balanced_regions(content) when is_binary(content) do
    Stream.unfold({0, %{}}, fn {from, memo} -> next_region(content, from, memo) end)
  end

  # The next balanced region at or after `from`, or nil. `memo` maps the offset
  # of an opener already settled by an earlier scan to `{:closed, stop}` or
  # `:unclosed`. An opener whose region never closes is skipped, so a stray
  # brace in prose doesn't hide a valid region later in the string.
  defp next_region(content, from, _memo) when from >= byte_size(content), do: nil

  defp next_region(content, from, memo) do
    rest = binary_part(content, from, byte_size(content) - from)

    case :binary.match(rest, ["{", "["]) do
      {rel, 1} ->
        start = from + rel
        {memo, settled} = settle(content, start, memo)

        case settled do
          {:closed, stop} ->
            {{binary_part(content, start, stop - start), start}, {start + 1, memo}}

          :unclosed ->
            next_region(content, start + 1, memo)
        end

      :nomatch ->
        nil
    end
  end

  defp settle(content, start, memo) do
    case memo do
      %{^start => settled} ->
        {memo, settled}

      _ ->
        opener = :binary.at(content, start)
        closer = if opener == ?{, do: ?}, else: ?]
        memo = scan(content, start + 1, opener, closer, [start], false, false, memo)
        {memo, Map.fetch!(memo, start)}
    end
  end

  # scan(content, pos, opener, closer, open_stack, in_string?, escape?, memo)
  # `open_stack` holds the offsets of the openers still unclosed, innermost
  # first. Each closer settles the innermost one; the scan stops when the opener
  # it began at closes, and settles what is left as unclosed at end of input.
  defp scan(content, pos, _opener, _closer, stack, _in_str, _esc, memo)
       when pos >= byte_size(content) do
    Enum.reduce(stack, memo, &Map.put(&2, &1, :unclosed))
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp scan(content, pos, opener, closer, stack, in_str, esc, memo) do
    byte = :binary.at(content, pos)

    cond do
      in_str and esc ->
        scan(content, pos + 1, opener, closer, stack, true, false, memo)

      in_str and byte == ?\\ ->
        scan(content, pos + 1, opener, closer, stack, true, true, memo)

      in_str and byte == ?" ->
        scan(content, pos + 1, opener, closer, stack, false, false, memo)

      in_str ->
        scan(content, pos + 1, opener, closer, stack, true, false, memo)

      byte == ?" ->
        scan(content, pos + 1, opener, closer, stack, true, false, memo)

      byte == opener ->
        scan(content, pos + 1, opener, closer, [pos | stack], false, false, memo)

      byte == closer ->
        [open | outer] = stack
        memo = Map.put(memo, open, {:closed, pos + 1})

        if outer == [] do
          memo
        else
          scan(content, pos + 1, opener, closer, outer, false, false, memo)
        end

      true ->
        scan(content, pos + 1, opener, closer, stack, false, false, memo)
    end
  end
end
