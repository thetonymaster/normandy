defmodule NormandyTest.Support.ModelMockup do
  @moduledoc false
  use Normandy.Schema

  schema do
    field(:key, :string, default: "stuff")
  end

  defimpl Normandy.Agents.Model, for: __MODULE__ do
    alias Normandy.Test.StubClient

    # The response model, a nil :chat_message filled in (a nil answer is an error,
    # decision 27 A3).
    def converse(_config, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: StubClient.answer(request.response_model)}}

    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
  end
end
