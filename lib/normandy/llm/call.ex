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
      {:ok, %Response{}} = ok ->
        ok

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

  defp bad_return(client, fun, expected, got) do
    "#{inspect(Model.impl_for(client))}.#{fun}/3 must return #{expected} or " <>
      "{:error, %Normandy.LLMError{}}, got: #{describe(got)}"
  end

  defp describe({tag, value}) when is_atom(tag), do: "{#{inspect(tag)}, #{describe(value)}}"
  defp describe(%module{}), do: "%#{inspect(module)}{}"
  defp describe(other), do: Describe.type_of(other)
end
