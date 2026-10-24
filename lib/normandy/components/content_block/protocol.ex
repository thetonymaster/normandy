defprotocol Normandy.Components.ContentBlock.Protocol do
  @moduledoc """
  What every consumer needs from a content block, answered by the block itself.

  `Normandy.Components.ContentBlock.Text`, `Image` and `Document` implement it, so
  the adapter, the token counter, the window manager and the summarizer call the
  protocol instead of switching on the block structs. A new block type implements
  the three functions and every consumer handles it.

  Raw Anthropic block maps (`%{"type" => "text", ...}`) are not blocks in this
  sense; consumers pass them through or read them as data.
  """

  @fallback_to_any false

  @doc """
  The block as the Anthropic/Claudio content-block map (string keys).

  Raises `ArgumentError` for a block that cannot be sent (for example a document
  whose source is not `:file_id`).
  """
  @spec to_claudio(t()) :: %{required(String.t()) => term()}
  def to_claudio(block)

  @doc """
  An estimate of the tokens the block adds to a request, never below zero.
  """
  @spec estimate_tokens(t()) :: non_neg_integer()
  def estimate_tokens(block)

  @doc """
  A short human-readable line for the block: its text, or a placeholder such as
  `"[image]"`. Used in summaries and debug previews.
  """
  @spec label(t()) :: String.t()
  def label(block)
end
