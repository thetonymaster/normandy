defmodule Normandy.LLM.Json.ContentCleaner do
  @moduledoc """
  Cleans raw LLM output into a parseable JSON string: strips markdown code
  fences and trims. `extract_balanced/1` is the prose-extraction fallback
  (implemented in the hardening phase).
  """

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

  @doc "Locate the outermost balanced JSON object/array within surrounding prose."
  @spec extract_balanced(binary()) :: {:ok, binary()} | :error
  def extract_balanced(content) when is_binary(content) do
    case :binary.match(content, ["{", "["]) do
      {start, 1} ->
        opener = :binary.at(content, start)
        closer = if opener == ?{, do: ?}, else: ?]
        scan_balanced(content, start + 1, opener, closer, 1, false, false, start)

      :nomatch ->
        :error
    end
  end

  def extract_balanced(_content), do: :error

  # scan(content, pos, opener, closer, depth, in_string?, escape?, start)
  defp scan_balanced(content, pos, _opener, _closer, 0, _in_str, _esc, start) do
    {:ok, binary_part(content, start, pos - start)}
  end

  defp scan_balanced(content, pos, opener, closer, depth, in_str, esc, start)
       when pos < byte_size(content) do
    byte = :binary.at(content, pos)

    cond do
      in_str and esc ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, false, start)

      in_str and byte == ?\\ ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, true, start)

      in_str and byte == ?" ->
        scan_balanced(content, pos + 1, opener, closer, depth, false, false, start)

      in_str ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, false, start)

      byte == ?" ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, false, start)

      byte == opener ->
        scan_balanced(content, pos + 1, opener, closer, depth + 1, false, false, start)

      byte == closer ->
        scan_balanced(content, pos + 1, opener, closer, depth - 1, false, false, start)

      true ->
        scan_balanced(content, pos + 1, opener, closer, depth, false, false, start)
    end
  end

  defp scan_balanced(_content, _pos, _opener, _closer, _depth, _in_str, _esc, _start), do: :error
end
