defmodule Normandy.Agents.BaseAgentRunResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, BaseAgentOutputSchema}
  alias Normandy.Components.AgentMemory
  alias Normandy.LLMError
  alias Normandy.Test.StubClient

  defp agent(reply), do: BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})

  defp rate_limited(_rm),
    do: {:error, LLMError.new(type: :rate_limit, retryable?: true, status: 429)}

  test "run/2 returns {:ok, config, output}" do
    agent = agent(fn rm -> %{rm | chat_message: "hi"} end)

    assert {:ok, %BaseAgentConfig{} = config, %BaseAgentOutputSchema{chat_message: "hi"}} =
             BaseAgent.run(agent, %{chat_message: "hello"})

    # The returned config carries the turn.
    assert length(AgentMemory.history(config.memory)) == 2
  end

  test "run/2 returns an LLM failure as {:error, %LLMError{}}" do
    assert {:error, %LLMError{type: :rate_limit, status: 429}} =
             BaseAgent.run(agent(&rate_limited/1), %{chat_message: "hello"})
  end

  test "run/3 with stream: true returns a stream failure as {:error, %LLMError{}}" do
    # StubClient.stream/3 answers {:error, %LLMError{type: :unsupported}}.
    assert {:error, %LLMError{type: :unsupported}} =
             BaseAgent.run(agent(& &1), %{chat_message: "hello"},
               stream: true,
               on_chunk: fn _ -> :ok end
             )
  end

  test "run/2 returns invalid input as {:error, %ValidationError{}}" do
    assert {:error, %Normandy.Schema.ValidationError{}} =
             BaseAgent.run(agent(& &1), %{chat_mesage: "typo"})
  end

  test "run!/2 returns {config, output} and raises the same exception" do
    assert {_config, %BaseAgentOutputSchema{}} =
             BaseAgent.run!(agent(& &1), %{chat_message: "x"})

    assert_raise LLMError, ~r/rate_limit/, fn ->
      BaseAgent.run!(agent(&rate_limited/1), %{chat_message: "hello"})
    end
  end

  test "a bug in a client still raises from run/2" do
    agent = agent(fn _rm -> raise "client bug" end)

    assert_raise RuntimeError, "client bug", fn ->
      BaseAgent.run(agent, %{chat_message: "x"})
    end
  end

  # Decision 6: a stacktrace is logged only, never emitted in telemetry.
  test "the run and llm_call :exception events fire for a returned error, with no stacktrace" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:normandy, :agent, :run, :exception],
        [:normandy, :agent, :llm_call, :exception]
      ])

    assert {:error, %LLMError{}} = BaseAgent.run(agent(&rate_limited/1), %{chat_message: "hello"})

    assert_received {[:normandy, :agent, :run, :exception], ^ref, %{duration: _},
                     %{kind: :error, reason: %LLMError{type: :rate_limit}, stacktrace: []}}

    assert_received {[:normandy, :agent, :llm_call, :exception], ^ref, %{duration: _},
                     %{kind: :error, reason: %LLMError{type: :rate_limit}, stacktrace: []}}
  end

  test "a raised bug's run and llm_call :exception events carry no stacktrace either" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:normandy, :agent, :run, :exception],
        [:normandy, :agent, :llm_call, :exception]
      ])

    agent = agent(fn _rm -> raise "client bug 2" end)
    assert_raise RuntimeError, fn -> BaseAgent.run(agent, %{chat_message: "x"}) end

    assert_received {[:normandy, :agent, :run, :exception], ^ref, _,
                     %{
                       kind: :error,
                       reason: %RuntimeError{message: "client bug 2"},
                       stacktrace: []
                     }}

    assert_received {[:normandy, :agent, :llm_call, :exception], ^ref, _,
                     %{
                       kind: :error,
                       reason: %RuntimeError{message: "client bug 2"},
                       stacktrace: []
                     }}
  end
end
