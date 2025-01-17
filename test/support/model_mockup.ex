defmodule NormandyTest.Support.ModelMockup do
  use Normandy.Schema

  schema do
    field(:key, :string, default: "stuff")
  end

  defimpl Normandy.Agents.Model, for: __MODULE__ do
    def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model) do
      response_model
    end

    def converse(_config, _model, _temperature, _max_tokens, _messages, response_model) do
      response_model
    end
  end
end
