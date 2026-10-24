defmodule Normandy.Test.WireScript do
  @moduledoc """
  A `Normandy.LLM.ClaudioAdapter` whose HTTP requests are answered in-process, for tests
  that check what goes over the wire.

  `client/2` takes the replies in call order. Every request body is decoded and sent to
  the process that called `client/2` as `{:wire_body, n, body}` (`n` counts from 0). The
  plug is a closure rather than a `Req.Test` stub, so a request made from any process
  (a `Turn.Server` worker) is answered. A request past the last reply raises, naming its
  index.

  A reply is one of:

    * `{:json, content_blocks, stop_reason}` (or with a fourth element, its `usage`) - a Messages API response body
    * `{:sse, events}` - a streamed response; build `events` with `message/3` and `block/3`
    * `{:status, status, body}` - an error response, `body` encoded as JSON
  """

  alias Normandy.LLM.ClaudioAdapter

  @spec client([tuple()], map()) :: ClaudioAdapter.t()
  def client(replies, options \\ %{}) when is_list(replies) and is_map(options) do
    test_pid = self()
    counter = :atomics.new(1, [])
    replies = List.to_tuple(replies)

    plug = fn conn ->
      n = :atomics.add_get(counter, 1, 1) - 1
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire_body, n, Jason.decode!(body)})

      if n >= tuple_size(replies) do
        raise "WireScript: request #{n} has no scripted reply (#{tuple_size(replies)} scripted)"
      end

      respond(conn, n, elem(replies, n))
    end

    %ClaudioAdapter{
      api_key: "k",
      options: Map.merge(%{req_options: [plug: plug, retry: false]}, options)
    }
  end

  @doc """
  A streamed message: `message_start` (with `usage`), `blocks`, `message_delta` with
  `stop`, `message_stop`.
  """
  @spec message(String.t(), [map()], String.t(), map()) :: [map()]
  def message(id, blocks, stop, usage \\ %{"input_tokens" => 1, "output_tokens" => 0}) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [],
          "usage" => usage
        }
      }
    ] ++
      blocks ++
      [
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => stop},
          "usage" => %{"output_tokens" => 1}
        },
        %{"type" => "message_stop"}
      ]
  end

  @doc "One streamed content block at `index`: its start, `deltas`, its stop."
  @spec block(non_neg_integer(), map(), [map()]) :: [map()]
  def block(index, start, deltas) do
    [%{"type" => "content_block_start", "index" => index, "content_block" => start}] ++
      Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
      [%{"type" => "content_block_stop", "index" => index}]
  end

  defp respond(conn, n, {:json, content, stop}),
    do: respond(conn, n, {:json, content, stop, %{"input_tokens" => 1, "output_tokens" => 1}})

  defp respond(conn, n, {:json, content, stop, usage}) do
    body = %{
      "id" => "msg_#{n}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => content,
      "stop_reason" => stop,
      "usage" => usage
    }

    send_json(conn, 200, body)
  end

  defp respond(conn, _n, {:sse, events}) do
    sse =
      Enum.map_join(events, fn event ->
        "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
      end)

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, sse)
  end

  defp respond(conn, _n, {:status, status, body}), do: send_json(conn, status, body)

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
