defmodule Normandy.Agents.BaseAgentStreamErrorLogTest do
  # Sync on purpose: capture_log/2 sees every process's logs, and async tests log
  # `[error]` lines deliberately. Sync modules run after all async ones finish.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError

  defmodule EventsClient do
    defstruct events: [], api_key: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentStreamErrorLogTest.EventsClient do
    def converse(_c, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

    def stream(client, _request, _opts), do: {:ok, client.events}
  end

  def handle_exception(_event, _measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:exception_metadata, metadata})
  end

  test "a failed stream's exception telemetry does not carry the config, and it is not logged" do
    id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :exception],
      &__MODULE__.handle_exception/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)

    agent =
      BaseAgent.init(%{
        client: %EventsClient{
          events: [
            %{type: "message_start", message: %{"id" => "m", "role" => "assistant"}},
            %{
              type: "content_block_start",
              content_block: %{"type" => "text", "text" => ""},
              index: 0
            },
            %{
              type: "content_block_delta",
              delta: %{"type" => "text_delta", "text" => "Hel"},
              index: 0
            },
            %{type: "error", error: %{"type" => "overloaded_error", "message" => "Overloaded"}}
          ],
          api_key: "sk-fv1-secret"
        },
        model: "claude-opus-5-5",
        temperature: nil
      })

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:reason]], fn ->
        send(
          test_pid,
          {:returned, BaseAgent.stream(agent, %{chat_message: "hi"}, fn _ -> :ok end)}
        )
      end)

    assert_received {:returned, {:error, %LLMError{}}}
    assert_received {:exception_metadata, metadata}
    refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ "sk-fv1-secret"
    # A returned Normandy error is recorded by telemetry, not logged.
    refute log =~ "[error]"
    refute log =~ "sk-fv1-secret"
  end
end
