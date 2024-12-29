defprotocol Normandy.Components.ContextProvider do
  @spec title(struct()) :: String.t()
  def title(context_config)

  @spec get_info(struct()) :: String.t()
  def get_info(context_config)
end
