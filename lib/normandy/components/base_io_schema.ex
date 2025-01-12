defprotocol Normandy.Components.BaseIOSchema do
  @dialyzer {:nowarn_function, __protocol__: 1}
  @fallback_to_any ""
  @spec __str__(struct()) :: String.t()
  def __str__(struct)
  @spec __rich__(struct()) :: String.t()
  def __rich__(struct)
  @spec to_json(struct()) :: String.t()
  def to_json(struct)
  def get_schema(struct)
end

defimpl Normandy.Components.BaseIOSchema, for: Any do
  def __str__(_), do: ""
  def __rich__(_), do: ""
  def to_json(_), do: ""
  def get_schema(_struct), do: ""
end
