defmodule Normandy.Agents.BaseAgentSharedBreakerTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLMError
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  defp scope, do: {__MODULE__, System.unique_integer([:positive])}

  defp overloaded(_response_model),
    do: {:error, LLMError.new(type: :overloaded, retryable?: true, status: 529)}

  defp agent(scope, opts \\ []) do
    BaseAgent.init(
      Keyword.merge(
        [
          client: %StubClient{},
          model: "m",
          circuit_breaker: [failure_threshold: 2, timeout: 60_000, scope: scope]
        ],
        opts
      )
    )
  end

  defp failing(agent), do: %{agent | client: %StubClient{reply: &overloaded/1}}

  test "init/1 starts no process; the first LLM call starts the breaker" do
    {:links, links_before} = Process.info(self(), :links)
    agent = agent(scope())
    key = BaseAgentConfig.circuit_breaker_key(agent)

    assert Process.info(self(), :links) == {:links, links_before}
    assert CircuitBreaker.fetch(key) == :error
    assert {:ok, _agent, _out} = BaseAgent.run(agent, "hi")
    assert {:ok, pid} = CircuitBreaker.fetch(key)
    refute pid in (Process.info(self(), :links) |> elem(1))
  end

  test "no circuit_breaker, no key" do
    assert BaseAgentConfig.circuit_breaker_key(BaseAgent.init(client: %StubClient{}, model: "m")) ==
             nil
  end

  test "a config built by a process that has since exited keeps working (PERF-2)" do
    parent = self()
    s = scope()

    {builder, ref} =
      spawn_monitor(fn ->
        send(parent, {:config, agent(s)})
        exit(:shutdown)
      end)

    assert_receive {:config, config}
    assert_receive {:DOWN, ^ref, :process, ^builder, :shutdown}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "perf2-#{System.unique_integer([:positive])}",
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
    assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "two"})
    assert {:ok, _pid} = CircuitBreaker.fetch(BaseAgentConfig.circuit_breaker_key(config))
  end

  test "two agents with the same client, model and options share one breaker" do
    s = scope()
    a = failing(agent(s))
    b = agent(s)

    assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "1")
    assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "2")

    assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(b, "3")
  end

  test "an agent on another model has its own breaker" do
    s = scope()
    a = failing(agent(s))
    other = agent(s, model: "other")

    assert {:error, _} = BaseAgent.run(a, "1")
    assert {:error, _} = BaseAgent.run(a, "2")

    assert {:ok, _agent, _out} = BaseAgent.run(other, "3")
  end

  test "a changed model uses its own breaker" do
    a = failing(agent(scope()))

    assert {:error, _} = BaseAgent.run(a, "1")
    assert {:error, _} = BaseAgent.run(a, "2")
    assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(a, "3")

    moved = %{a | model: "other", client: %StubClient{}}
    assert {:ok, _agent, _out} = BaseAgent.run(moved, "4")
  end

  describe "which failures count (decision 20)" do
    defp error_reply(type, retryable? \\ false) do
      fn _response_model ->
        {:error, LLMError.new(type: type, retryable?: retryable?, status: 400)}
      end
    end

    for type <- [:invalid_request, :authentication, :permission, :not_found, :invalid_output] do
      test "#{type} does not open a shared breaker" do
        s = scope()
        a = %{agent(s) | client: %StubClient{reply: error_reply(unquote(type))}}
        b = agent(s)

        assert {:error, %LLMError{type: unquote(type)}} = BaseAgent.run(a, "1")
        assert {:error, %LLMError{type: unquote(type)}} = BaseAgent.run(a, "2")
        assert {:error, %LLMError{type: unquote(type)}} = BaseAgent.run(a, "3")

        assert {:ok, _agent, _out} = BaseAgent.run(b, "4")
      end
    end

    test "a retryable error of any type counts" do
      s = scope()
      a = %{agent(s) | client: %StubClient{reply: error_reply(:unknown, true)}}

      assert {:error, _} = BaseAgent.run(a, "1")
      assert {:error, _} = BaseAgent.run(a, "2")
      assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(agent(s), "3")
    end

    test "a failure that exhausted Retry counts by its last error" do
      s = scope()

      a =
        BaseAgent.init(
          client: %StubClient{reply: &overloaded/1},
          model: "m",
          retry: [max_attempts: 2, base_delay: 0, max_delay: 0, jitter: false],
          circuit_breaker: [failure_threshold: 2, timeout: 60_000, scope: s]
        )

      assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "1")
      assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "2")
      assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(agent(s), "3")
    end

    test "a raise from the caller's own code does not count" do
      s = scope()
      a = %{agent(s) | client: %StubClient{reply: fn _ -> raise ArgumentError, "caller bug" end}}

      assert_raise ArgumentError, fn -> BaseAgent.run(a, "1") end
      assert_raise ArgumentError, fn -> BaseAgent.run(a, "2") end

      assert {:ok, _agent, _out} = BaseAgent.run(agent(s), "3")
    end
  end
end
