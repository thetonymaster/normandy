defmodule Normandy.Components.ContentBlock.Image do
  @moduledoc """
  Represents an image content block inside a multimodal message.

  Supports two source types:

    * `:base64` — inline base64-encoded image data with a media type.
    * `:url` — hosted image referenced by URL.

  Use alongside `Normandy.Components.ContentBlock.Text` in a list assigned to
  a message's `:content` field to send an image to a Claude model.

  ## Cache control

  An optional `cache_control` field carries an Anthropic prompt-cache
  breakpoint annotation that the adapter ships verbatim on the wire.
  Use `with_cache/1` for the default ephemeral type, or `with_cache/2`
  for a custom map (e.g. `%{"type" => "ephemeral", "ttl" => "1h"}`).
  Atom keys are accepted and stringified at serialization time.
  """

  use Normandy.Schema

  alias Normandy.Components.ContentBlock.CacheControl

  @type source :: :base64 | :url

  @type t :: %__MODULE__{
          source: source(),
          data: String.t() | nil,
          media_type: String.t() | nil,
          url: String.t() | nil,
          cache_control: map() | nil
        }

  schema do
    field(:source, :any)
    field(:data, :string, default: nil)
    field(:media_type, :string, default: nil)
    field(:url, :string, default: nil)
    field(:cache_control, :map, default: nil)
  end

  @doc """
  Builds a base64-sourced image block. `media_type` (e.g. `"image/png"`,
  `"image/jpeg"`) is required and positional — matching the Anthropic API,
  where the server cannot infer the format from the raw bytes.
  """
  @spec new_base64(String.t(), String.t()) :: t()
  def new_base64(data, media_type) when is_binary(data) and is_binary(media_type) do
    %__MODULE__{source: :base64, data: data, media_type: media_type}
  end

  @doc """
  Builds a URL-sourced image block.
  """
  @spec new_url(String.t()) :: t()
  def new_url(url) when is_binary(url) do
    %__MODULE__{source: :url, url: url}
  end

  @doc """
  Annotates this block with an ephemeral cache breakpoint.
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

  Raises `ArgumentError` when the struct is in an incomplete state (e.g.
  `source: :base64` with `nil` data, or `source: :url` with `nil` url).
  The constructors (`new_base64/2`, `new_url/1`) enforce valid state, so
  this only fires when a caller bypasses them.
  """
  @spec to_claudio(t()) :: %{required(String.t()) => term()}
  def to_claudio(%__MODULE__{
        source: :base64,
        data: data,
        media_type: media_type,
        cache_control: cache_control
      })
      when is_binary(data) and data != "" and is_binary(media_type) and media_type != "" do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => media_type,
        "data" => data
      }
    }
    |> CacheControl.maybe_attach(cache_control)
  end

  def to_claudio(%__MODULE__{source: :base64} = block) do
    raise ArgumentError,
          "Normandy.Components.ContentBlock.Image: invalid base64 image — " <>
            "data and media_type must be non-empty strings. Got: #{inspect(block)}"
  end

  def to_claudio(%__MODULE__{source: :url, url: url, cache_control: cache_control})
      when is_binary(url) and url != "" do
    %{
      "type" => "image",
      "source" => %{
        "type" => "url",
        "url" => url
      }
    }
    |> CacheControl.maybe_attach(cache_control)
  end

  def to_claudio(%__MODULE__{source: :url} = block) do
    raise ArgumentError,
          "Normandy.Components.ContentBlock.Image: invalid url image — " <>
            "url must be a non-empty string. Got: #{inspect(block)}"
  end

  def to_claudio(%__MODULE__{source: source}) do
    raise ArgumentError,
          "Normandy.Components.ContentBlock.Image: unsupported image source #{inspect(source)}. " <>
            "Expected :base64 or :url."
  end
end
