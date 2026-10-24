defmodule Normandy.ReadmeTest do
  @moduledoc """
  Runs the README's quickstart against a stubbed Messages API: if the README stops
  running, this fails.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @client_line ~s|%Normandy.LLM.ClaudioAdapter{api_key: System.get_env("ANTHROPIC_API_KEY")}|

  test "the quickstart prints the answer and sends max_tokens 16_000 to claude-opus-5-5" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [
          %{"type" => "text", "text" => ~s({"chat_message": "Actors share nothing."})}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })
    end)

    assert capture_io(fn -> Code.eval_string(quickstart()) end) == "Actors share nothing.\n"
    assert_received {:request, %{"max_tokens" => 16_000, "model" => "claude-opus-5-5"}}
  end

  test "the quickstart prints the error of a failed turn" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
      })
    end)

    assert capture_io(fn -> Code.eval_string(quickstart()) end) ==
             "Turn failed: LLM call failed: authentication (401): invalid x-api-key\n"
  end

  # The README's Quick Start block, its client pointed at the Req.Test stub.
  defp quickstart do
    [block] =
      Regex.run(~r/## Quick Start.*?```elixir\n(.*?)```/s, File.read!("README.md"),
        capture: :all_but_first
      )

    # The swap below must not silently do nothing if the README changes.
    assert block =~ @client_line

    String.replace(
      block,
      @client_line,
      ~s|%Normandy.LLM.ClaudioAdapter{api_key: "test-key", | <>
        "options: %{req_options: [plug: {Req.Test, #{inspect(__MODULE__)}}, retry: false]}}"
    )
  end
end
