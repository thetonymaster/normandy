defmodule Normandy.Test.ScriptedToolClient do
  @moduledoc """
  A model client for tests. While the conversation holds no tool result it answers with
  `:calls` as tool calls; once one is present it returns the response model unchanged.
  One tool round per conversation.
  """
  defstruct calls: [], options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.Agents.ToolCallResponse

    def converse(client, request, _opts) do
      content =
        if Enum.any?(request.messages, &(&1.role == "tool")),
          do: request.response_model,
          else: %ToolCallResponse{content: nil, tool_calls: client.calls}

      {:ok, %Normandy.LLM.Response{content: content}}
    end

    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
  end
end
