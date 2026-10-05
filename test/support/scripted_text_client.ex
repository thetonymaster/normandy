defmodule Normandy.Test.ScriptedTextClient do
  @moduledoc """
  A model client for tests that answers every request with `:text`.

  `converse/3` fills the response model the way an adapter does: `:chat_message` gets
  the text, any other schema gets the text decoded as JSON. `stream/3` streams the same
  text as two text deltas. With `fail_after_first_delta: true`, the stream ends in a
  transport error after its first delta. `:calls`, a `:counters` ref, counts `stream/3`
  calls. With `:notify`, `stream/3` sends `{:stream_request, request}` to that pid.
  """
  defstruct text: "", fail_after_first_delta: false, calls: nil, notify: nil, options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.Response

    def converse(client, request, _opts),
      do:
        {:ok,
         %Response{content: fill(request.response_model, client.text), stop_reason: :end_turn}}

    def stream(client, request, _opts) do
      if client.calls, do: :counters.add(client.calls, 1, 1)
      if client.notify, do: send(client.notify, {:stream_request, request})
      {first, rest} = String.split_at(client.text, div(String.length(client.text), 2))

      head = [
        %{
          type: "message_start",
          message: %{"id" => "msg_1", "model" => "m", "role" => "assistant"}
        },
        %{
          type: "content_block_start",
          index: 0,
          content_block: %{"type" => "text", "text" => ""}
        },
        delta(first)
      ]

      tail =
        if client.fail_after_first_delta do
          [{:error, :closed}]
        else
          [
            delta(rest),
            %{type: "content_block_stop", index: 0},
            %{
              type: "message_delta",
              delta: %{"stop_reason" => "end_turn"},
              usage: %{"output_tokens" => 2}
            },
            %{type: "message_stop"}
          ]
        end

      {:ok, head ++ tail}
    end

    defp delta(text),
      do: %{
        type: "content_block_delta",
        index: 0,
        delta: %{"type" => "text_delta", "text" => text}
      }

    defp fill(nil, text), do: text

    defp fill(%{chat_message: _} = response_model, text),
      do: %{response_model | chat_message: text}

    defp fill(%module{}, text), do: struct(module, Jason.decode!(text, keys: :atoms))
  end
end
