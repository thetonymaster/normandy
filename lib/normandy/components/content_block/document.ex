defmodule Normandy.Components.ContentBlock.Document do
  @moduledoc """
  Represents a document content block inside a multimodal message.

  Currently supports documents referenced by a Files-API `file_id`. Base64
  and URL sources can be added later — the library's raw-list fallback in
  the adapter already handles arbitrary pre-shaped block maps.
  """

  use Normandy.Schema

  @type source :: :file_id

  @type t :: %__MODULE__{
          source: source(),
          file_id: String.t() | nil
        }

  schema do
    field(:source, :any)
    field(:file_id, :string, default: nil)
  end

  @doc """
  Builds a document block referencing a file uploaded via Anthropic's Files API.
  """
  @spec new_file(String.t()) :: t()
  def new_file(file_id) when is_binary(file_id) do
    %__MODULE__{source: :file_id, file_id: file_id}
  end

  @doc """
  Converts the block into the Anthropic/Claudio content-block map shape
  (string keys).
  """
  @spec to_claudio(t()) :: %{required(String.t()) => term()}
  def to_claudio(%__MODULE__{source: :file_id, file_id: file_id}) do
    %{
      "type" => "document",
      "source" => %{
        "type" => "file",
        "file_id" => file_id
      }
    }
  end
end
