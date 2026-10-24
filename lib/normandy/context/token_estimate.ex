defmodule Normandy.Context.TokenEstimate do
  @moduledoc false
  # The pure token estimators. AgentMemory computes each entry's `tokens` with these;
  # keeping them out of WindowManager (which aliases Summarizer, an LLM call) keeps the
  # memory data structure out of a runtime cycle with the turn machinery.
  # WindowManager delegates to them.

  alias Normandy.Components.ContentBlock
  alias Normandy.Components.ContentBlock.Protocol

  @doc false
  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 characters per token
    # More accurate for English text
    ContentBlock.text_tokens(text)
  end

  def estimate_tokens(_), do: 0

  @doc false
  @spec estimate_message_content_tokens(term()) :: non_neg_integer()
  def estimate_message_content_tokens(content) when is_binary(content) do
    estimate_tokens(content)
  end

  # Token estimates for the opaque raw-map blocks below; the block structs answer
  # through `ContentBlock.Protocol`. Same figures as the structs' implementations.
  # A single ContentBlock struct. Must come before the generic `is_map` clause,
  # since structs are maps in Elixir and would otherwise hit the JSON-size
  # fallback and undercount.
  def estimate_message_content_tokens(content) when is_struct(content), do: struct_tokens(content)

  def estimate_message_content_tokens(content) when is_list(content) do
    Enum.reduce(content, 0, fn block, acc -> acc + estimate_block_tokens(block) end)
  end

  def estimate_message_content_tokens(content) when is_map(content) do
    # For structured content, estimate based on its JSON (structs as their maps).
    content
    |> Normandy.JSON.encode!()
    |> estimate_tokens()
  end

  def estimate_message_content_tokens(_), do: 0

  defp estimate_block_tokens(block) when is_struct(block), do: struct_tokens(block)

  defp estimate_block_tokens(%{"type" => "text", "text" => text}) when is_binary(text),
    do: estimate_tokens(text)

  defp estimate_block_tokens(%{"type" => "image"}), do: ContentBlock.image_tokens()
  defp estimate_block_tokens(%{"type" => "document"}), do: ContentBlock.document_tokens()

  # Unknown / caller-provided shape — estimate from JSON size so we
  # never silently count zero.
  defp estimate_block_tokens(block) when is_map(block) do
    block |> Normandy.JSON.encode!() |> estimate_tokens()
  end

  defp estimate_block_tokens(_), do: 0

  defp struct_tokens(struct) do
    if ContentBlock.block?(struct),
      do: Protocol.estimate_tokens(struct),
      else: struct |> Normandy.JSON.encode!() |> estimate_tokens()
  end
end
