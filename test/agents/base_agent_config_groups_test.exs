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
        {true, "was removed: circuit_breaker: [] (or the breaker's options) configures a breaker"},
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
    test "nil (the default) configures no breaker" do
      config = init([])

      assert config.circuit_breaker == nil
      assert BaseAgentConfig.circuit_breaker_key(config) == nil
      refute Map.has_key?(config, :circuit_breaker_pid)
    end

    test "a keyword list is kept as the breaker options; init/1 starts no process" do
      opts = [failure_threshold: 1, timeout: 60_000, scope: {__MODULE__, :kept}]
      {:links, links_before} = Process.info(self(), :links)
      config = init(circuit_breaker: opts)

      assert Process.info(self(), :links) == {:links, links_before}
      assert config.circuit_breaker == opts
      assert CircuitBreaker.fetch(BaseAgentConfig.circuit_breaker_key(config)) == :error
    end

    test "[] uses the breaker's defaults" do
      config = init(circuit_breaker: [])

      assert {StubClient, nil, "m", opts} = BaseAgentConfig.circuit_breaker_key(config)
      assert opts[:failure_threshold] == 5
    end

    test "a bad nested value names the option and the expected type" do
      assert_raise ArgumentError,
                   ~r/invalid value for :circuit_breaker option: invalid value for :timeout option: expected positive integer, got: 0/,
                   fn -> init(circuit_breaker: [timeout: 0]) end
    end

    test "a nested map or list value is never echoed" do
      for bad <- [%{secret: "s3cr3t"}, [secret: "s3cr3t"]] do
        error = assert_raise ArgumentError, fn -> init(circuit_breaker: [timeout: bad]) end

        assert error.message =~ ":timeout"
        refute error.message =~ "s3cr3t"
      end
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
