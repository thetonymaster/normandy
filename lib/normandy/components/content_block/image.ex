defmodule Normandy.Components.ContentBlock.Image do
  @moduledoc """
  Represents an image content block inside a multimodal message.

  Supports two source types:

    * `:base64` — inline base64-encoded image data with a media type.
    * `:url` — hosted image referenced by URL.

  Use alongside `Normandy.Components.ContentBlock.Text` in a list assigned to
  a message's `:content` field to send an image to a Claude model.
  """

  use Normandy.Schema

  @type source :: :base64 | :url

  @type t :: %__MODULE__{
          source: source(),
          data: String.t() | nil,
          media_type: String.t() | nil,
          url: String.t() | nil
        }

  schema do
    field(:source, :any)
    field(:data, :string, default: nil)
    field(:media_type, :string, default: nil)
    field(:url, :string, default: nil)
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
  Converts the block into the Anthropic/Claudio content-block map shape
  (string keys).
  """
  @spec to_claudio(t()) :: %{required(String.t()) => term()}
  def to_claudio(%__MODULE__{source: :base64, data: data, media_type: media_type}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => media_type,
        "data" => data
      }
    }
  end

  def to_claudio(%__MODULE__{source: :url, url: url}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "url",
        "url" => url
      }
    }
  end
end
