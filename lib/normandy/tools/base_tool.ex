defprotocol Normandy.Tools.BaseTool do
  @spec tool_name(struct()) :: String.t()
  def tool_name(config)

  @spec tool_description(struct()) :: String.t()
  def tool_description(config)

  @spec run(struct()) :: any()
  def run(config)
end
