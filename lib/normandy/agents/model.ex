defprotocol Normandy.Agents.Model do
  @spec completitions(
          t(),
          String.t(),
          float(),
          integer(),
          binary(),
          struct()
        ) :: struct()
  def completitions(config, model, temperature, max_tokens, messages, response_model)

  @spec converse(t(), String.t(), float(), integer(), list(), struct()) :: struct()
  def converse(config, model, temperature, max_tokens, messages, response_model)
end
