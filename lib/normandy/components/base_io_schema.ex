defprotocol Normandy.Components.BaseIOSchema do
  @moduledoc """
  Protocol for schema serialization and representation.

  Provides functions for converting schemas to various string formats
  including plain text, rich text, and JSON.
  """

  @dialyzer {:nowarn_function, __protocol__: 1}
  @fallback_to_any ""

  @doc "Converts the struct to a plain string representation"
  @spec __str__(struct()) :: String.t()
  def __str__(struct)

  @doc "Converts the struct to a rich/formatted string representation"
  @spec __rich__(struct()) :: String.t()
  def __rich__(struct)

  @doc "Converts the struct to a JSON string"
  @spec to_json(struct()) :: String.t()
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

defimpl Normandy.Components.BaseIOSchema, for: Any do
  def __str__(_), do: ""
  def __rich__(_), do: ""
  def to_json(_), do: ""
  def get_schema(_struct), do: ""
end
