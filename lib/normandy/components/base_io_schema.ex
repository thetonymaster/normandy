# defprotocol Normandy.Components.BaseIOSchema do
#   @dialyzer {:nowarn_function, __protocol__: 1}
#   @fallback_to_any ""
#   @spec to_json(Normandy.Components.BaseIOSchema.t()) :: String.t()
#   def to_json(struct)
#   def
# end

# defimpl Normandy.Components.BaseIOSchema, for: Any do
#   def to_json(_) do
#     ""
#   end
# end
