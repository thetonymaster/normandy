defmodule Normandy.Agents.BaseAgentServedByTest do
  # async: false — one test sets the global Logger level to :info.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.StubClient

  # Answers "hi" with usage, plus `meta` as the third element when it is set.
  defp meta_client(meta) do
    usage = %{input_tokens: 1, output_tokens: 1}

    %StubClient{
      reply: fn response_model ->
        response = Map.put(response_model, :chat_message, "hi")
        if meta, do: {response, usage, meta}, else: {response, usage}
      end
    }
  end

  def forward_stop(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:stop, metadata})

  # Returns {stop_metadata, captured_log}. Logs are captured so the run stays quiet.
  defp run_and_capture_stop(client) do
    test_pid = self()
    id = "served-by-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :stop],
      &__MODULE__.forward_stop/4,
      test_pid
    )

    try do
      agent = BaseAgent.init(%{client: client, model: "claude-opus-5-5", temperature: nil})

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:served_by]], fn ->
          BaseAgent.run(agent, "hello")
        end)

      assert_receive {:stop, metadata}
      {metadata, log}
    after
      :telemetry.detach(id)
    end
  end

  test "llm_call stop metadata carries served_by when the model reports it" do
    {metadata, _log} = run_and_capture_stop(meta_client(%{served_by: "claude-opus-5"}))
    assert metadata.served_by == "claude-opus-5"
  end

  test "llm_call stop metadata has no served_by when the model reports none" do
    {metadata, _log} = run_and_capture_stop(meta_client(nil))
    refute Map.has_key?(metadata, :served_by)
  end

  test "the llm call stop log line carries served_by" do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    {_metadata, log} = run_and_capture_stop(meta_client(%{served_by: "claude-opus-5"}))

    assert log =~ "normandy llm call stop"
    assert log =~ "served_by=claude-opus-5"
  end
end
