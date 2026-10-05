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

  test "run/2 accepts text for the default schema and sends it as the user message" do
    client = %StubClient{notify: self()}
    agent = BaseAgent.init(%{client: client, model: "m"})

    assert {:ok, _config, _output} = BaseAgent.run(agent, "hello")

    assert_receive {:converse, %Normandy.LLM.Request{messages: messages}, _}
    assert [%{role: "user", content: content}] = messages
    # Memory renders a default-schema input as its chat_message text.
    assert content == "hello"
  end

  test "run/2 returns an LLM failure as {:error, %LLMError{}}" do
    assert {:error, %LLMError{type: :rate_limit, status: 429}} =
             BaseAgent.run(agent(&rate_limited/1), %{chat_message: "hello"})
  end

  test "stream/3 returns a stream failure as {:error, %LLMError{}}" do
    # StubClient.stream/3 answers {:error, %LLMError{type: :unsupported}}.
    assert {:error, %LLMError{type: :unsupported}} =
             BaseAgent.stream(agent(& &1), %{chat_message: "hello"}, fn _ -> :ok end)
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

  # A non-config used to loop forever in run!/3 (its old opts clause re-entered itself).
  @tag timeout: 5_000
  test "run!/2 and run/2 raise FunctionClauseError for a non-config" do
    assert_raise FunctionClauseError, fn -> BaseAgent.run!(%{}, nil) end
    assert_raise FunctionClauseError, fn -> BaseAgent.run(%{}, nil) end
    assert_raise FunctionClauseError, fn -> BaseAgent.run({:ok, %{}}, %{chat_message: "x"}) end
  end

  test "run/2 returns an output guardrail violation as {:error, %ViolationError{}}" do
    agent =
      BaseAgent.init(%{
        client: %StubClient{reply: fn rm -> %{rm | chat_message: "my ssn is 123-45-6789"} end},
        model: "m",
        guardrails: [
          output: [
            {Normandy.Guardrails.Builtins.RegexGuard,
             patterns: [~r/\d{3}-\d{2}-\d{4}/], mode: :deny, field: :chat_message}
          ]
        ]
      })

    assert {:error, %Normandy.Guardrails.ViolationError{}} =
             BaseAgent.run(agent, %{chat_message: "hello"})
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

  # A bug's reason is redacted to its module (TurnError.redact/1); the raise is whole.
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
                       reason: %Normandy.TurnError{
                         type: :task_down,
                         reason: %{exception: RuntimeError}
                       },
                       stacktrace: []
                     }}

    assert_received {[:normandy, :agent, :llm_call, :exception], ^ref, _,
                     %{
                       kind: :error,
                       reason: %Normandy.TurnError{
                         type: :task_down,
                         reason: %{exception: RuntimeError}
                       },
                       stacktrace: []
                     }}
  end
end
