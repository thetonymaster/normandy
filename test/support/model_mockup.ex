defmodule NormandyTest.Support.ModelMockup do
  @moduledoc false
  use Normandy.Schema

  schema do
    field(:key, :string, default: "stuff")
  end

  defimpl Normandy.Agents.Model, for: __MODULE__ do
    def converse(_config, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
  end
end
