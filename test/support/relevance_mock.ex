defmodule NormandyTest.Support.RelevanceMock do
  @moduledoc """
  A `Normandy.Agents.Model` mock for relevance-guard tests.

  When asked to classify (the `response_model` carries an `:on_topic` field) it
  returns the configured `:response` verbatim — which may be a bare `Decision`
  struct or a `{Decision, usage}` tuple, exercising the guard's unwrap path — and,
  if `:notify` is set, forwards the messages to that pid. For any other
  `response_model` (e.g. a normal agent turn) it behaves like `ModelMockup` and
  returns the `response_model` unchanged, so the same mock can back `BaseAgent.run/2`.
  """

  use Normandy.Schema

  schema do
    field(:response, :any, default: nil)
    field(:notify, :any, default: nil)
  end

  defimpl Normandy.Agents.Model do
    def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts \\ []) do
      if is_struct(response_model) and Map.has_key?(response_model, :on_topic) do
        if client.notify, do: send(client.notify, {:classify_messages, messages})
        client.response
      else
        response_model
      end
    end
  end
end
