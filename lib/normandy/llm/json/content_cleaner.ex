defmodule Normandy.LLM.Json.ContentCleaner do
  @moduledoc false
  # Cleans raw LLM output into a parseable JSON string: strips markdown code
  # fences and trims. `balanced_regions/1` is the prose-extraction fallback.

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

  @doc """
  Locates the first balanced JSON object/array at or after byte offset `from`, within
  surrounding prose, and returns it with the byte offset where it started.
  """
  @spec extract_balanced(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | :error
  def extract_balanced(content, from)
      when is_binary(content) and is_integer(from) and from >= 0 do
    case next_region(content, from, new_state(content)) do
      {{region, start}, _state} -> {:ok, region, start}
      nil -> :error
    end
  end

  def extract_balanced(_content, _from), do: :error

  @doc """
  Every balanced `{...}`/`[...]` region of `content`, in order of the byte offset
  it starts at, as `{region, start}`. A region nested in an earlier one is
  yielded too, so a caller that rejects an outer region still sees the inner
  ones. Lazy.

  The guarantee: the scans together read at most `8 * byte_size(content) + 1024` bytes,
  whatever the input, so the time is linear in the size. Scans share work: a scan that
  starts at an opener settles every same-kind opener it passes outside a string, and
  stops at a marked lexer state (where the state or depth changed) that an earlier scan
  of that kind recorded, when the outcome there is known (that scan closed its first
  opener with the same number pending, or never closed it with no more pending). Prose, nested code and repeated escaped-quote
  shapes (`{ word `, `{ \\"`, `printf("{\\"id\\": %d}")` lines) stay far under the budget.
  Some inputs still need more than it allows; then the stream ends early, and the
  regions yielded are always a prefix of the full list in start order: a later region
  can be missed, a wrong one never returned.
  """
  @spec balanced_regions(binary()) :: Enumerable.t()
  def balanced_regions(content) when is_binary(content) do
    Stream.unfold({0, new_state(content)}, fn {from, st} -> next_region(content, from, st) end)
  end

  # `memo`: offset of an opener already settled by a scan => `{:closed, stop}` or
  # `:unclosed`. `seen`: `{opener, pos, in_string?, escape?}` => the fewest openers pending
  # when a scan that never closed its first opener recorded that (marked) state. `done`:
  # `{state, depth}` => where the opener of the scan that recorded it closed. `work`:
  # bytes the scans may still read.
  defp new_state(content),
    do: %{memo: %{}, seen: %{}, done: %{}, work: 8 * byte_size(content) + 1024}

  # The next balanced region at or after `from`, or nil. An opener whose region never
  # closes is skipped, so a stray brace in prose doesn't hide a valid region later in
  # the string.
  defp next_region(content, from, _st) when from >= byte_size(content), do: nil

  defp next_region(content, from, st) do
    rest = binary_part(content, from, byte_size(content) - from)

    case :binary.match(rest, ["{", "["]) do
      {rel, 1} -> settled_region(content, from + rel, st)
      :nomatch -> nil
    end
  end

  defp settled_region(content, start, st) do
    case settle(content, start, st) do
      {:ok, st} -> region_at(content, start, st)
      :exhausted -> nil
    end
  end

  defp region_at(content, start, st) do
    case Map.fetch!(st.memo, start) do
      {:closed, stop} -> {{binary_part(content, start, stop - start), start}, {start + 1, st}}
      :unclosed -> next_region(content, start + 1, st)
    end
  end

  defp settle(_content, start, %{memo: memo} = st) when is_map_key(memo, start),
    do: {:ok, st}

  defp settle(content, start, st) do
    opener = :binary.at(content, start)
    closer = if opener == ?{, do: ?}, else: ?]
    scan(content, start + 1, {opener, closer, start}, [start], 1, {false, false, true}, [], st)
  end

  # scan(content, pos, {opener, closer}, open_stack, depth, {in_string?, escape?, mark?},
  #      trail, st)
  # `open_stack` holds the offsets of the openers still unclosed, innermost first, and
  # `depth` its length. Each closer settles the innermost one; the scan stops when the
  # opener it began at closes, or reaches end of input (everything pending is unclosed).
  # `trail` is the marked `{state, depth}` pairs crossed, kept for `done` or `seen`.
  #
  # Only marked states are looked up in `done`/`seen` and kept in `trail`: a scan's first
  # byte and every byte its lexer state or depth changed at. Every entry recorded is one
  # recording every byte would also make, so skipping the rest only drops shortcuts: the
  # regions are unchanged. The cost: between marks the state only moves forward over
  # plain bytes, and two scans on one path change state at the same bytes, so a scan
  # joining an earlier one reads at most one run of plain bytes to the next mark (or to
  # where that scan ended). Recording every byte instead made one stray opener in prose
  # cost a map entry per byte to the end of the input (investigations/json-region-240kb.md).
  defp scan(content, pos, _kind, stack, _depth, _lex, trail, st) when pos >= byte_size(content),
    do: {:ok, unclosed(stack, trail, st)}

  defp scan(_content, _pos, _kind, _stack, _depth, _lex, _trail, %{work: work})
       when work <= 0,
       do: :exhausted

  defp scan(content, pos, kind, stack, depth, {_, _, false} = lex, trail, st),
    do: step(content, pos, kind, stack, depth, lex, trail, %{st | work: st.work - 1})

  defp scan(
         content,
         pos,
         {opener, _, start} = kind,
         stack,
         depth,
         {in_str, esc, _} = lex,
         trail,
         st
       ) do
    key = {opener, pos, in_str, esc}

    case st do
      # An earlier scan of this kind crossed this state with this many openers pending
      # and closed its first opener at `stop`; so does this one.
      %{done: %{{^key, ^depth} => stop}} ->
        {:ok, closed(start, stop, trail, st)}

      _ ->
        scan_seen(content, pos, kind, stack, depth, lex, trail, st)
    end
  end

  defp scan_seen(content, pos, kind, stack, depth, {in_str, esc, _} = lex, trail, st) do
    key = {elem(kind, 0), pos, in_str, esc}

    case Map.get(st.seen, key) do
      # An earlier unclosed scan crossed this state with `min` openers pending, so
      # an opener with `min` or more pending at this point never closes.
      min when is_integer(min) and depth >= min ->
        {:ok, unclosed(Enum.drop(stack, min - 1), trail, st)}

      _ ->
        st = %{st | work: st.work - 1}
        step(content, pos, kind, stack, depth, lex, [{key, depth} | trail], st)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp step(
         content,
         pos,
         {opener, closer, start} = kind,
         stack,
         depth,
         {in_str, esc, _},
         trail,
         st
       ) do
    byte = :binary.at(content, pos)
    next = pos + 1

    cond do
      in_str and esc ->
        scan(content, next, kind, stack, depth, {true, false, true}, trail, st)

      in_str and byte == ?\\ ->
        scan(content, next, kind, stack, depth, {true, true, true}, trail, st)

      in_str and byte == ?" ->
        scan(content, next, kind, stack, depth, {false, false, true}, trail, st)

      in_str ->
        scan(content, next, kind, stack, depth, {true, false, false}, trail, st)

      byte == ?" ->
        scan(content, next, kind, stack, depth, {true, false, true}, trail, st)

      byte == opener ->
        scan(content, next, kind, [pos | stack], depth + 1, {false, false, true}, trail, st)

      byte == closer ->
        [open | outer] = stack
        st = %{st | memo: Map.put(st.memo, open, {:closed, next})}

        if outer == [],
          do: {:ok, closed(start, next, trail, st)},
          else: scan(content, next, kind, outer, depth - 1, {false, false, true}, trail, st)

      true ->
        scan(content, next, kind, stack, depth, {false, false, false}, trail, st)
    end
  end

  # The scan's first opener closed at `stop`: remember the states crossed with the
  # depth they were crossed at. (`start` is settled by the caller's memo already
  # when the scan closed on its own.)
  defp closed(start, stop, trail, st) do
    done = Enum.reduce(trail, st.done, fn {key, d}, acc -> Map.put(acc, {key, d}, stop) end)
    %{st | done: done, memo: Map.put(st.memo, start, {:closed, stop})}
  end

  # The scan's first opener never closed: settle the openers known unclosed and
  # remember the states crossed.
  defp unclosed(stack, trail, st) do
    memo = Enum.reduce(stack, st.memo, &Map.put(&2, &1, :unclosed))

    seen =
      Enum.reduce(trail, st.seen, fn {key, d}, acc -> Map.update(acc, key, d, &min(&1, d)) end)

    %{st | memo: memo, seen: seen}
  end
end
