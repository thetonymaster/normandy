defmodule Normandy.Components.ContentBlock.Text do
  @moduledoc """
  Represents a text content block inside a multimodal message.

  Used as part of a list of content blocks in `Normandy.Components.Message`
  when a message mixes text with images or documents.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          text: String.t()
        }

  schema do
    field(:text, :string)
  end

  @doc """
  Builds a text content block from a string.
  """
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text) do
    %__MODULE__{text: text}
  end

  @doc """
  Converts the block into the Anthropic/Claudio content-block map shape
  (string keys).
  """
  @spec to_claudio(t()) :: %{required(String.t()) => String.t()}
  def to_claudio(%__MODULE__{text: text}) do
    %{"type" => "text", "text" => text}
  end
end
