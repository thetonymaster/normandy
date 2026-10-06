defmodule Normandy.LLM.Call do
  @moduledoc false
  # The only caller of Normandy.Agents.Model. A wrong return from an implementation
  # (a 1.x bare struct, {:ok, struct}, nil) fails here, naming the implementation,
  # instead of as a MatchError far from the cause.

  alias Normandy.Agents.Model
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLM.{Request, Response}
  alias Normandy.LLMError

  @spec converse(Model.t(), Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, LLMError.t()}
  def converse(client, %Request{} = request, opts) do
    case Model.converse(client, request, opts) do
      # The fields BaseAgent reads: a meta map, and content that is the filled response
      # model or the answer text. Anything else is a wrong return, named here.
      {:ok, %Response{content: content, meta: meta} = response}
      when is_map(meta) and (is_binary(content) or is_struct(content)) ->
        check_stop_reason(response)

      {:error, %LLMError{}} = error ->
        error

      other ->
        raise ArgumentError,
              bad_return(client, :converse, "{:ok, %Normandy.LLM.Response{}}", other)
    end
  end

  @spec stream(Model.t(), Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, LLMError.t()}
  def stream(client, %Request{} = request, opts) do
    case Model.stream(client, request, opts) do
      {:ok, stream} = ok when not is_nil(stream) ->
        if Enumerable.impl_for(stream),
          do: ok,
          else: raise(ArgumentError, bad_return(client, :stream, "{:ok, enumerable}", ok))

      {:error, %LLMError{}} = error ->
        error

      other ->
        raise ArgumentError, bad_return(client, :stream, "{:ok, enumerable}", other)
    end
  end

  @doc false
  # A stop reason as Normandy.LLM.Response's atom (Response.stop_reason/1's closed list:
  # a provider string outside it stays a string); the stream path's final message
  # carries the provider's string.
  @spec stop_reason(term()) :: term()
  def stop_reason(reason) when is_binary(reason), do: Response.stop_reason(reason)
  def stop_reason(reason), do: reason

  @doc false
  # The one gate for an incomplete answer, on converse/3 and on BaseAgent's stream path:
  # cut off (max_tokens, the context window) or refused is an error, whatever the content.
  # `response` is a %Response{} or the streamed message map (:stop_reason, :usage).
  @spec check_stop_reason(map()) :: {:ok, map()} | {:error, LLMError.t()}
  def check_stop_reason(response) when is_map(response) do
    case stop_reason(Map.get(response, :stop_reason)) do
      :max_tokens ->
        {:error,
         incomplete(
           :max_tokens,
           :max_tokens,
           response,
           "the response stopped at max_tokens before it was complete; raise the " <>
             "agent's max_tokens or ask for a shorter answer"
         )}

      :model_context_window_exceeded ->
        {:error,
         incomplete(
           :max_tokens,
           :model_context_window_exceeded,
           response,
           "the response stopped at model_context_window_exceeded: the conversation " <>
             "filled the model's context window; compact or shorten the history"
         )}

      :refusal ->
        {:error,
         incomplete(
           :refusal,
           :refusal,
           response,
           "the model declined to answer (stop_reason refusal)"
         )}

      _ ->
        {:ok, response}
    end
  end

  # Never model text in the error (decision 6): the reason is the stop reason only.
  defp incomplete(type, stop_reason, response, detail) do
    [type: type, retryable?: false, reason: {:stop_reason, stop_reason}, detail: detail]
    |> LLMError.new()
    |> LLMError.with_usage(Map.get(response, :usage))
  end

  defp bad_return(client, fun, expected, got) do
    "#{inspect(Model.impl_for(client))}.#{fun}/3 must return #{expected} or " <>
      "{:error, %Normandy.LLMError{}}, got: #{describe(got)}"
  end

  defp describe({tag, value}) when is_atom(tag), do: "{#{inspect(tag)}, #{describe(value)}}"

  defp describe(%Response{content: content, meta: meta}),
    do: "%Normandy.LLM.Response{content: #{describe(content)}, meta: #{describe(meta)}}"

  defp describe(%module{}), do: "%#{inspect(module)}{}"
  defp describe(other), do: Describe.type_of(other)
end
