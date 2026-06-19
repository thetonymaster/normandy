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

  @doc "Locate the outermost balanced JSON object/array within surrounding prose. Stub until hardening #3."
  @spec extract_balanced(binary()) :: {:ok, binary()} | :error
  def extract_balanced(content) when is_binary(content), do: :error
  def extract_balanced(_content), do: :error
end
