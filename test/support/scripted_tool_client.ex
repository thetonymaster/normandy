defmodule Normandy.Test.ScriptedToolClient do
  @moduledoc """
  A model client for tests. While the conversation holds no tool result it answers with
  `:calls` as tool calls; once one is present it returns the response model unchanged.
  One tool round per conversation.
  """
  defstruct calls: [], options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.Agents.ToolCallResponse

    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts) do
      if Enum.any?(messages, &(Map.get(&1, :role) == "tool")),
        do: response_model,
        else: %ToolCallResponse{content: nil, tool_calls: client.calls}
    end
  end
end
