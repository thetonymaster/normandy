defmodule Normandy.Components.ContentBlock.Text do
  @moduledoc """
  Represents a text content block inside a multimodal message.

  Used as part of a list of content blocks in `Normandy.Components.Message`
  when a message mixes text with images or documents.

  ## Cache control

  An optional `cache_control` field carries an Anthropic prompt-cache
  breakpoint annotation that the adapter ships verbatim on the wire.
  Use `with_cache/1` for the default ephemeral type, or `with_cache/2`
  for a custom map (e.g. `%{"type" => "ephemeral", "ttl" => "1h"}`).
  Atom keys are accepted and stringified at serialization time.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          text: String.t(),
          cache_control: map() | nil
        }

  schema do
    field(:text, :string)
    field(:cache_control, :map, default: nil)
  end

  @doc """
  Builds a text content block from a string.
  """
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text) do
    %__MODULE__{text: text}
  end

  @doc """
  Annotates this block with an ephemeral cache breakpoint.

  Equivalent to `with_cache(block, %{"type" => "ephemeral"})`.
  """
  @spec with_cache(t()) :: t()
  def with_cache(%__MODULE__{} = block) do
    %{block | cache_control: %{"type" => "ephemeral"}}
  end

  @doc """
  Annotates this block with a caller-supplied cache_control map.

  Atom keys are accepted; they are stringified when serialized.
  """
  @spec with_cache(t(), map()) :: t()
  def with_cache(%__MODULE__{} = block, %{} = cache_control) do
    %{block | cache_control: cache_control}
  end

  @doc """
  Converts the block into the Anthropic/Claudio content-block map shape
  (string keys). Includes `cache_control` only when set.
  """
  @spec to_claudio(t()) :: %{required(String.t()) => term()}
  def to_claudio(%__MODULE__{text: text, cache_control: cache_control}) do
    base = %{"type" => "text", "text" => text}
    Normandy.Components.ContentBlock.CacheControl.maybe_attach(base, cache_control)
  end
end
