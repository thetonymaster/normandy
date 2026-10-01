defprotocol Normandy.Components.BaseIOSchema do
  @moduledoc """
  Protocol for schema serialization and representation.

  Provides functions for converting schemas to various string formats
  including plain text, rich text, and JSON.
  """

  @dialyzer {:nowarn_function, __protocol__: 1}

  @doc "Converts the struct to a plain string representation"
  @spec __str__(struct()) :: String.t()
  def __str__(struct)

  @doc "Converts the struct to a rich/formatted string representation"
  @spec __rich__(struct()) :: String.t()
  def __rich__(struct)

  @doc "Converts the struct to a JSON string"
  @spec to_json(struct()) :: String.t() | list()
  def to_json(struct)

  @doc "Returns the schema definition for the struct"
  @spec get_schema(struct()) :: term()
  def get_schema(struct)
end

defimpl Normandy.Components.BaseIOSchema, for: BitString do
  def __str__(str), do: str
  def __rich__(str), do: str
  def to_json(str), do: str
  def get_schema(_), do: %{}
end

defimpl Normandy.Components.BaseIOSchema, for: Map do
  def __str__(map), do: inspect(map)
  def __rich__(map), do: inspect(map)

  def to_json(map) do
    # Convert map to JSON string using the configured JSON adapter
    adapter = Application.get_env(:normandy, :adapter, Poison)
    adapter.encode!(map)
  end

  def get_schema(_map), do: %{}
end

defimpl Normandy.Components.BaseIOSchema, for: List do
  def __str__(list), do: inspect(list)
  def __rich__(list), do: inspect(list)
  def to_json(list), do: list
  def get_schema(_list), do: %{}
end

# A single content block is sent as a one-block list, the same shape as
# multimodal list content, which the adapter turns into wire blocks.
defimpl Normandy.Components.BaseIOSchema,
  for: [
    Normandy.Components.ContentBlock.Text,
    Normandy.Components.ContentBlock.Image,
    Normandy.Components.ContentBlock.Document
  ] do
  def __str__(block), do: inspect(block.__struct__)
  def __rich__(block), do: inspect(block.__struct__)
  def to_json(block), do: [block]
  def get_schema(_block), do: %{}
end
