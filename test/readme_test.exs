defmodule Normandy.ReadmeTest do
  @moduledoc """
  Runs the README's quickstart against a stubbed Messages API: if the README stops
  running, this fails.
  """
  use ExUnit.Case, async: true

  @client_line ~s|%Normandy.LLM.ClaudioAdapter{api_key: System.get_env("ANTHROPIC_API_KEY")}|

  test "the quickstart runs and sends max_tokens 16_000" do
    [block] =
      Regex.run(~r/## Quick Start.*?```elixir\n(.*?)```/s, File.read!("README.md"),
        capture: :all_but_first
      )

    # The swap below must not silently do nothing if the README changes.
    assert block =~ @client_line

    source =
      String.replace(
        block,
        @client_line,
        ~s|%Normandy.LLM.ClaudioAdapter{api_key: "test-key", | <>
          "options: %{req_options: [plug: {Req.Test, #{inspect(__MODULE__)}}, retry: false]}}"
      )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-6",
        "content" => [
          %{"type" => "text", "text" => ~s({"chat_message": "Actors share nothing."})}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })
    end)

    {_value, binding} = Code.eval_string(source)

    assert %Normandy.Agents.BaseAgentOutputSchema{chat_message: "Actors share nothing."} =
             binding[:response]

    assert_received {:request, %{"max_tokens" => 16_000}}
  end
end
