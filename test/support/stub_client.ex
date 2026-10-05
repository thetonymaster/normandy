defmodule Normandy.Test.StubClient do
  @moduledoc """
  A model client for tests. `converse/3` sends `{:converse, request, opts}` (a
  `%Normandy.LLM.Request{}`) to `:notify` when it is set, then returns what `:reply`
  gives:

    * `fn response_model -> reply end`, or
    * `fn response_model, opts -> reply end`

  where `reply` is the response content (a struct or a binary, wrapped as
  `{:ok, %Normandy.LLM.Response{}}`), an `{:ok, %Normandy.LLM.Response{}}`, or
  `{:error, %Normandy.LLMError{}}`; or the function raises. The default returns the
  response model unchanged. Any other tuple (such as a 1.x `{response, usage}` left
  unmigrated) raises `ArgumentError`; any other term is returned as is, for
  `Normandy.LLM.Call` to reject.

  `stream/3` returns `{:error, %Normandy.LLMError{type: :unsupported}}`.
  """
  defstruct reply: &Function.identity/1, notify: nil, options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.Response

    def converse(client, request, opts) do
      if client.notify, do: send(client.notify, {:converse, request, opts})

      reply =
        case client.reply do
          reply when is_function(reply, 1) -> reply.(request.response_model)
          reply when is_function(reply, 2) -> reply.(request.response_model, opts)
        end

      to_result(reply)
    end

    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}

    defp to_result(reply) do
      case reply do
        {:ok, _} = ok ->
          ok

        {:error, _} = error ->
          error

        tuple when is_tuple(tuple) ->
          raise ArgumentError,
                "StubClient: :reply returned a #{tuple_size(tuple)}-tuple, which is not " <>
                  "{:ok, %Normandy.LLM.Response{}} or {:error, %Normandy.LLMError{}}. A 1.x " <>
                  "{response, usage} or {response, usage, meta} reply becomes " <>
                  "{:ok, %Normandy.LLM.Response{content: response, usage: usage, meta: meta}}"

        content when is_struct(content) or is_binary(content) ->
          {:ok, %Response{content: content}}

        other ->
          other
      end
    end
  end
end
