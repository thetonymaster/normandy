defmodule Normandy.Agents.BaseAgentConfigGroupsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Guardrails.Builtins.MaxLength
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  defp init(opts), do: BaseAgent.init([model: "m", client: %StubClient{}] ++ opts)

  describe "1.x option names" do
    @renamed [
      retry_options: {[max_attempts: 2], "was renamed to :retry"},
      enable_circuit_breaker:
        {true, "was removed: circuit_breaker: [] (or the breaker's options) starts a breaker"},
      circuit_breaker_options: {[timeout: 10], "was renamed to :circuit_breaker"},
      input_guardrails: {[MaxLength], "moved to guardrails: [input: ...]"},
      output_guardrails: {[MaxLength], "moved to guardrails: [output: ...]"},
      output_guardrails_streaming_mode:
        {:incremental, "moved to guardrails: [streaming_mode: ...]"},
      output_guardrails_chunk_size: {10, "moved to guardrails: [chunk_size: ...]"},
      output_guardrails_on_violation: {:warn, "moved to guardrails: [on_violation: ...]"}
    ]

    for {key, {value, change}} <- @renamed do
      test "#{key} raises, naming its 2.0 home" do
        assert_raise ArgumentError,
                     "Normandy.Agents.BaseAgent.init/1: #{inspect(unquote(key))} " <>
                       "#{unquote(change)} in 2.0; see MIGRATING-2.0.md §22",
                     fn -> init([{unquote(key), unquote(Macro.escape(value))}]) end
      end
    end
  end

  describe "retry" do
    test "is kept on the config, nil by default" do
      assert init([]).retry == nil
      assert init(retry: [max_attempts: 2]).retry == [max_attempts: 2]
    end

    test "a bad retry option raises naming :retry" do
      assert_raise ArgumentError, ~r/invalid value for :retry option: .*:max_attemps/, fn ->
        init(retry: [max_attemps: 2])
      end
    end
  end

  describe "circuit_breaker" do
    test "nil (the default) starts no breaker" do
      config = init([])

      assert config.circuit_breaker == nil
      assert config.circuit_breaker_pid == nil
    end

    test "a keyword list starts a breaker with those options" do
      config = init(circuit_breaker: [failure_threshold: 1, timeout: 60_000])

      assert config.circuit_breaker == [failure_threshold: 1, timeout: 60_000]
      assert is_pid(config.circuit_breaker_pid)
      assert CircuitBreaker.state(config.circuit_breaker_pid) == :closed
      GenServer.stop(config.circuit_breaker_pid)
    end

    test "[] starts a breaker with its defaults" do
      config = init(circuit_breaker: [])

      assert is_pid(config.circuit_breaker_pid)
      GenServer.stop(config.circuit_breaker_pid)
    end

    test "true is not a breaker option list" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: invalid value for :circuit_breaker " <>
                     "option: expected a keyword list or nil, got true",
                   fn -> init(circuit_breaker: true) end
    end
  end

  describe "guardrails" do
    test "every key has its default" do
      assert Enum.sort(init([]).guardrails) == Enum.sort(BaseAgentConfig.default_guardrails())
    end

    test "a partial list is completed with the defaults" do
      guardrails = init(guardrails: [input: [MaxLength], on_violation: :warn]).guardrails

      assert guardrails[:input] == [MaxLength]
      assert guardrails[:on_violation] == :warn
      assert guardrails[:output] == []
      assert guardrails[:streaming_mode] == :accumulate
      assert guardrails[:chunk_size] == 200
    end

    test "an unknown guardrails key is named with the supported ones" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :inptu in :guardrails; " <>
                     "supported: :input, :output, :streaming_mode, :chunk_size, :on_violation",
                   fn -> init(guardrails: [inptu: []]) end
    end

    test "guardrail/2 reads a key a hand-built list left out as its default" do
      config = %BaseAgentConfig{guardrails: [output: [MaxLength]]}

      assert BaseAgentConfig.guardrail(config, :output) == [MaxLength]
      assert BaseAgentConfig.guardrail(config, :input) == []
      assert BaseAgentConfig.guardrail(config, :chunk_size) == 200
    end
  end
end
