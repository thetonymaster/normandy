defmodule Normandy.Components.ContentBlock do
  @moduledoc false
  # The shared facts about content blocks: whether a term is one, and the token
  # figures every estimate uses. Kept here (not in Context) so the blocks stay free
  # of context dependencies; TokenEstimate reads them from here.

  alias Normandy.Components.ContentBlock.Protocol

  # Anthropic documents ~1568 tokens for a 1.15-megapixel image
  # (https://docs.anthropic.com/); rounded up so we overcount rather than
  # silently overflow.
  @image_tokens 1600
  # A conservative guess: the document's full file content counts at Claude's
  # side, so real costs vary wildly.
  @document_tokens 3000

  @doc false
  @spec block?(term()) :: boolean()
  def block?(term), do: is_struct(term) and Protocol.impl_for(term) != nil

  @doc false
  @spec image_tokens() :: pos_integer()
  def image_tokens, do: @image_tokens

  @doc false
  @spec document_tokens() :: pos_integer()
  def document_tokens, do: @document_tokens

  @doc false
  # Rough estimate: ~4 characters per token, more accurate for English text.
  @spec text_tokens(String.t()) :: pos_integer()
  def text_tokens(text) when is_binary(text), do: max(1, div(String.length(text), 4))
end
