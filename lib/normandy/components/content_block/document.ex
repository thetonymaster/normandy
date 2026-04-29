defmodule Normandy.Components.ContentBlock.Document do
  @moduledoc """
  Represents a document content block inside a multimodal message.

  Currently supports documents referenced by a Files-API `file_id`. Base64
  and URL sources can be added later — the library's raw-list fallback in
  the adapter already handles arbitrary pre-shaped block maps.

  ## Cache control

  An optional `cache_control` field carries an Anthropic prompt-cache
  breakpoint annotation that the adapter ships verbatim on the wire.
  Use `with_cache/1` for the default ephemeral type, or `with_cache/2`
  for a custom map (e.g. `%{"type" => "ephemeral", "ttl" => "1h"}`).
  Atom keys are accepted and stringified at serialization time.
  """

  use Normandy.Schema

  alias Normandy.Components.ContentBlock.CacheControl

  @type source :: :file_id

  @type t :: %__MODULE__{
          source: source(),
          file_id: String.t() | nil,
          cache_control: map() | nil
        }

  schema do
    field(:source, :any)
    field(:file_id, :string, default: nil)
    field(:cache_control, :map, default: nil)
  end

  @doc """
  Builds a document block referencing a file uploaded via Anthropic's Files API.
  """
  @spec new_file(String.t()) :: t()
  def new_file(file_id) when is_binary(file_id) do
    %__MODULE__{source: :file_id, file_id: file_id}
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

  Raises `ArgumentError` on an incomplete struct (e.g. `source: :file_id`
  with `nil` `file_id`). The constructor (`new_file/1`) enforces valid
  state, so this only fires when a caller bypasses it.
  """
  @spec to_claudio(t()) :: %{required(String.t()) => term()}
  def to_claudio(%__MODULE__{source: :file_id, file_id: file_id, cache_control: cache_control})
      when is_binary(file_id) and file_id != "" do
    %{
      "type" => "document",
      "source" => %{
        "type" => "file",
        "file_id" => file_id
      }
    }
    |> CacheControl.maybe_attach(cache_control)
  end

  def to_claudio(%__MODULE__{} = block) do
    raise ArgumentError,
          "Normandy.Components.ContentBlock.Document: invalid document — " <>
            "source must be :file_id and file_id a non-empty string. Got: #{inspect(block)}"
  end
end
