defmodule Normandy.Context.TokenEstimate do
  @moduledoc false
  # The pure token estimators. AgentMemory computes each entry's `tokens` with these;
  # keeping them out of WindowManager (which aliases Summarizer, an LLM call) keeps the
  # memory data structure out of a runtime cycle with the turn machinery.
  # WindowManager delegates to them.

  @doc false
  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 characters per token
    # More accurate for English text
    max(1, div(String.length(text), 4))
  end

  def estimate_tokens(_), do: 0

  @doc false
  @spec estimate_message_content_tokens(term()) :: non_neg_integer()
  def estimate_message_content_tokens(content) when is_binary(content) do
    estimate_tokens(content)
  end

  # Token estimates for opaque multimodal blocks. Anthropic documents
  # ~1568 tokens for a 1.15-megapixel image (https://docs.anthropic.com/);
  # round up to 1600 so we overcount rather than silently overflow. The
  # document estimate is a conservative guess — document blocks include
  # the full file content at Claude-side, so real costs vary wildly.
  @image_token_estimate 1600
  @document_token_estimate 3000

  # Single ContentBlock structs — delegate to the same heuristic used for
  # list content. Must come before the generic `is_map` clause, since
  # structs are maps in Elixir and would otherwise hit the JSON-size
  # fallback and undercount.
  def estimate_message_content_tokens(%Normandy.Components.ContentBlock.Text{text: text})
      when is_binary(text),
      do: estimate_tokens(text)

  def estimate_message_content_tokens(%Normandy.Components.ContentBlock.Image{}),
    do: @image_token_estimate

  def estimate_message_content_tokens(%Normandy.Components.ContentBlock.Document{}),
    do: @document_token_estimate

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

  defp estimate_block_tokens(%Normandy.Components.ContentBlock.Text{text: text})
       when is_binary(text),
       do: estimate_tokens(text)

  defp estimate_block_tokens(%Normandy.Components.ContentBlock.Image{}),
    do: @image_token_estimate

  defp estimate_block_tokens(%Normandy.Components.ContentBlock.Document{}),
    do: @document_token_estimate

  defp estimate_block_tokens(%{"type" => "text", "text" => text}) when is_binary(text),
    do: estimate_tokens(text)

  defp estimate_block_tokens(%{"type" => "image"}), do: @image_token_estimate
  defp estimate_block_tokens(%{"type" => "document"}), do: @document_token_estimate

  # Unknown / caller-provided shape — estimate from JSON size so we
  # never silently count zero.
  defp estimate_block_tokens(block) when is_map(block) do
    block |> Normandy.JSON.encode!() |> estimate_tokens()
  end

  defp estimate_block_tokens(_), do: 0
end
