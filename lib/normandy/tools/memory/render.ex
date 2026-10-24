defmodule Normandy.Tools.Memory.Render do
  @moduledoc false
  # The model-facing text of the memory tool, matching Anthropic's memory-tool reference.

  @max_lines 999_999

  def directory(dir, docs) do
    visible = Enum.reject(docs, &hidden?(rel(&1.path, dir)))

    rows =
      visible
      |> Enum.flat_map(fn %{path: path, size: size} ->
        segs = rel(path, dir)
        depth = length(segs)

        dirs =
          for d <- 1..min(depth - 1, 2)//1, do: {Enum.join([dir | Enum.take(segs, d)], "/"), size}

        if depth <= 2, do: dirs ++ [{path, size}], else: dirs
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {path, sizes} -> {path, Enum.sum(sizes)} end)
      |> Enum.sort()

    total = visible |> Enum.map(& &1.size) |> Enum.sum()

    header =
      "Here're the files and directories up to 2 levels deep in #{dir}, excluding hidden items and node_modules:"

    Enum.join(
      [header, "#{human(total)}\t#{dir}" | Enum.map(rows, fn {p, s} -> "#{human(s)}\t#{p}" end)],
      "\n"
    )
  end

  def file(path, content, range, max_chars) do
    lines = content |> String.trim_trailing("\n") |> String.split("\n")
    n = length(lines)

    with :ok <- line_limit(path, n),
         {:ok, first, last} <- range(range, n) do
      shown = lines |> Enum.with_index(1) |> Enum.slice((first - 1)..(last - 1)//1)
      {body, cut_after} = cap(shown, max_chars)

      note = truncation_note(cut_after, n, max_chars)

      {:ok, "Here's the content of #{path} with line numbers:\n" <> body <> note}
    end
  end

  def snippet(content, first, last) do
    lines = String.split(content, "\n")
    from = max(first - 4, 1)
    to = min(last + 4, length(lines))

    lines
    |> Enum.with_index(1)
    |> Enum.slice((from - 1)..(to - 1)//1)
    |> Enum.map_join("\n", fn {line, i} -> numbered(i, line) end)
  end

  def human(bytes) when bytes < 1024, do: "#{bytes}B"
  def human(bytes) when bytes < 1024 * 1024, do: one_decimal(bytes / 1024) <> "K"
  def human(bytes), do: one_decimal(bytes / (1024 * 1024)) <> "M"

  defp one_decimal(x), do: :erlang.float_to_binary(x, decimals: 1)

  defp numbered(i, line), do: String.pad_leading(Integer.to_string(i), 6) <> "\t" <> line

  # Whole lines while they fit; a first line longer than max_chars is cut on a grapheme
  # boundary, so the view is never longer than max_chars plus the note.
  defp cap(shown, max_chars) do
    Enum.reduce_while(shown, {[], 0, nil}, fn {line, i}, {acc, used, _} ->
      text = numbered(i, line)
      used = used + String.length(text) + 1

      cond do
        used <= max_chars -> {:cont, {[text | acc], used, nil}}
        acc != [] -> {:halt, {acc, used, i - 1}}
        true -> {:halt, {[String.slice(text, 0, max_chars)], used, {:inside, i}}}
      end
    end)
    |> then(fn {acc, _used, cut} -> {acc |> Enum.reverse() |> Enum.join("\n"), cut} end)
  end

  defp truncation_note(nil, _n, _max_chars), do: ""

  defp truncation_note({:inside, line}, n, max_chars) when line < n,
    do:
      "\n[truncated inside line #{line} of #{n}: it is longer than the #{max_chars}-character " <>
        "view limit; use view_range [#{line + 1}, -1] to read on]"

  defp truncation_note({:inside, line}, n, max_chars),
    do:
      "\n[truncated inside line #{line} of #{n}: it is longer than the #{max_chars}-character " <>
        "view limit]"

  defp truncation_note(cut_after, n, _max_chars),
    do:
      "\n[truncated at line #{cut_after} of #{n}; use view_range [#{cut_after + 1}, -1] to read on]"

  defp range(nil, n), do: {:ok, 1, n}

  defp range([first, -1], n) when is_integer(first) and first >= 1 and first <= n,
    do: {:ok, first, n}

  defp range([first, last], n)
       when is_integer(first) and is_integer(last) and first >= 1 and first <= last and last <= n,
       do: {:ok, first, last}

  defp range(other, n),
    do:
      {:error, :invalid_line,
       "Error: Invalid `view_range` parameter: #{inspect(other)}. It should be within the range of lines of the file: [1, #{n}]"}

  defp line_limit(path, n) when n > @max_lines,
    do: {:error, :invalid_line, "File #{path} exceeds maximum line limit of 999,999 lines."}

  defp line_limit(_path, _n), do: :ok

  defp rel(path, dir), do: path |> String.replace_prefix(dir <> "/", "") |> String.split("/")

  defp hidden?(segs),
    do: Enum.any?(segs, &(String.starts_with?(&1, ".") or &1 == "node_modules"))
end
