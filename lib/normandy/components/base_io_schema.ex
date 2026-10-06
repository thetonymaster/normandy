defprotocol Normandy.Components.BaseIOSchema do
  @moduledoc """
  How a value goes to the model: `to_json/1` encodes it (a string, or a list of content
  blocks), and `get_schema/1` returns its schema. Implemented for strings, maps, lists,
  content blocks and every `io_schema` struct.
  """

  @dialyzer {:nowarn_function, __protocol__: 1}

  @doc "Converts the struct to a JSON string"
  @spec to_json(struct()) :: String.t() | list()
  def to_json(struct)

  @doc "Returns the schema definition for the struct"
  @spec get_schema(struct()) :: term()
  def get_schema(struct)
end

defimpl Normandy.Components.BaseIOSchema, for: BitString do
  def to_json(str), do: str
  def get_schema(_), do: %{}
end

defimpl Normandy.Components.BaseIOSchema, for: Map do
  def to_json(map), do: Normandy.JSON.encode!(map)

  def get_schema(_map), do: %{}
end

defimpl Normandy.Components.BaseIOSchema, for: List do
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
  def to_json(block), do: [block]
  def get_schema(_block), do: %{}
end
