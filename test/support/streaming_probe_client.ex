defmodule Normandy.Test.StreamingProbeClient do
  @moduledoc ~S(Streams a tool_use of the "probe" tool until the conversation holds a tool result, then streams the text "done".)
  defstruct options: %{}

  defimpl Normandy.Agents.Model do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model
    def converse(_c, _m, _t, _mt, _msgs, response_model, _opts), do: response_model

    def stream_converse(_c, _m, _t, _mt, messages, _response_model, _opts) do
      events =
        if Enum.any?(messages, &(Map.get(&1, :role) == "tool")) do
          [
            %{type: "message_start", message: %{"id" => "m2", "role" => "assistant"}},
            %{
              type: "content_block_start",
              content_block: %{"type" => "text", "text" => ""},
              index: 0
            },
            %{
              type: "content_block_delta",
              delta: %{"type" => "text_delta", "text" => "done"},
              index: 0
            },
            %{type: "message_stop"}
          ]
        else
          [
            %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
            %{
              type: "content_block_start",
              content_block: %{"type" => "tool_use", "id" => "call_1", "name" => "probe"},
              index: 0
            },
            %{
              type: "content_block_delta",
              delta: %{"type" => "input_json_delta", "partial_json" => "{}"},
              index: 0
            },
            %{type: "message_stop"}
          ]
        end

      {:ok, Stream.map(events, & &1)}
    end
  end
end
