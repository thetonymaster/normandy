defmodule Normandy.Test.StubClient do
  @moduledoc """
  A model client for tests. `converse/7` sends `{:converse, messages, opts}`
  to `:notify` when it is set, then returns what `:reply` gives:

    * `fn response_model -> reply end`, or
    * `fn response_model, opts -> reply end`

  where `reply` is anything `converse/7` may return (a response,
  `{response, usage}`, `{response, usage, meta}`, `{:error, %LLMError{}}`),
  or the function raises. The default returns the response model unchanged.

  It does not implement `stream_converse/7`, so streaming calls get the
  "client does not stream" error.
  """
  defstruct reply: &Function.identity/1, notify: nil, options: %{}

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(client, _model, _temperature, _max_tokens, messages, response_model, opts) do
      if client.notify, do: send(client.notify, {:converse, messages, opts})

      case client.reply do
        reply when is_function(reply, 1) -> reply.(response_model)
        reply when is_function(reply, 2) -> reply.(response_model, opts)
      end
    end
  end
end
