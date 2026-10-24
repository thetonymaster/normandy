defmodule Normandy.Agents.BaseAgentResilienceTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Resilience.Retry

  # Each agent gets its own breaker scope, so async tests never share a breaker.
  defp breaker_opts(opts),
    do: Keyword.put(opts, :scope, {__MODULE__, System.unique_integer([:positive])})

  defp breaker(agent) do
    {:ok, pid} = CircuitBreaker.fetch(BaseAgentConfig.circuit_breaker_key(agent))
    pid
  end

  # Mock client that fails then succeeds (for retry testing)
  defmodule RetryableClient do
    use Normandy.Schema

    # `attempts` is an Agent counting calls (a pid, not a registered name, so
    # tests cannot collide).
    schema do
      field(:failure_count, :integer, default: 0)
      field(:attempts, :any)
    end

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        # Simulate failures on first attempts
        current_count = Agent.get_and_update(client.attempts, fn count -> {count, count + 1} end)

        if current_count < client.failure_count do
          # Simulate a transient endpoint failure (counts against a breaker)
          {:error, Normandy.LLMError.new(type: :server, retryable?: true, status: 503)}
        else
          # Success after retries
          {:ok,
           %Normandy.LLM.Response{
             content: %{
               request.response_model
               | chat_message: "Success after #{current_count + 1} attempts"
             }
           }}
        end
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  # Mock client for circuit breaker testing
  defmodule CircuitBreakerClient do
    use Normandy.Schema

    schema do
      field(:should_fail, :boolean, default: true)
    end

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        if client.should_fail do
          {:error, Normandy.LLMError.new(type: :server, retryable?: true, status: 503)}
        else
          {:ok,
           %Normandy.LLM.Response{content: %{request.response_model | chat_message: "Success"}}}
        end
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  describe "retry integration" do
    test "automatically retries failed LLM calls" do
      attempts = start_supervised!({Agent, fn -> 0 end})

      # Configure agent with retry (fail first attempt only)
      client = %RetryableClient{failure_count: 1, attempts: attempts}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry: Retry.preset(:quick)
        })

      # This should succeed after retries
      {_agent, response} = BaseAgent.run!(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 2 attempts"
    end

    test "works without retry configuration" do
      attempts = start_supervised!({Agent, fn -> 0 end})

      client = %RetryableClient{failure_count: 0, attempts: attempts}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      # Should work on first try
      {_agent, response} = BaseAgent.run!(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 1 attempts"
    end

    test "uses custom retry options" do
      attempts = start_supervised!({Agent, fn -> 0 end})

      client = %RetryableClient{failure_count: 1, attempts: attempts}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry: [
            max_attempts: 3,
            base_delay: 10,
            retry_on: [:network_error],
            retry_if: fn
              {:error, %Normandy.LLMError{type: :server}} -> true
              _ -> false
            end
          ]
        })

      {_agent, response} = BaseAgent.run!(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 2 attempts"
    end
  end

  describe "circuit breaker integration" do
    test "opens circuit after threshold failures" do
      client = %CircuitBreakerClient{should_fail: true}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          circuit_breaker:
            breaker_opts(
              failure_threshold: 2,
              timeout: 60_000
            )
        })

      # First two calls should fail and open circuit
      assert_raise Normandy.LLMError, ~r/server/, fn ->
        BaseAgent.run!(agent, %{chat_message: "test1"})
      end

      assert_raise Normandy.LLMError, ~r/server/, fn ->
        BaseAgent.run!(agent, %{chat_message: "test2"})
      end

      # Circuit should be open
      assert CircuitBreaker.state(breaker(agent)) == :open

      # Third call should fail fast
      assert_raise Normandy.LLMError,
                   "LLM call failed: circuit_open: circuit breaker is open",
                   fn ->
                     BaseAgent.run!(agent, %{chat_message: "test3"})
                   end
    end

    test "recovers after timeout in half-open state" do
      {:ok, client_ref} =
        Agent.start_link(fn -> %CircuitBreakerClient{should_fail: true} end)

      client = Agent.get(client_ref, & &1)

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          circuit_breaker:
            breaker_opts(
              failure_threshold: 1,
              success_threshold: 1,
              timeout: 500
            )
        })

      # Open circuit
      assert_raise Normandy.LLMError, ~r/server/, fn ->
        BaseAgent.run!(agent, %{chat_message: "fail"})
      end

      assert CircuitBreaker.state(breaker(agent)) == :open

      # Wait for half-open
      Process.sleep(600)

      # Fix the client
      Agent.update(client_ref, fn _ -> %CircuitBreakerClient{should_fail: false} end)
      updated_client = Agent.get(client_ref, & &1)
      agent = %{agent | client: updated_client}

      # Should transition to half-open and succeed
      {agent, response} = BaseAgent.run!(agent, %{chat_message: "test"})

      assert response.chat_message == "Success"
      assert CircuitBreaker.state(breaker(agent)) == :closed

      # Clean up
      Agent.stop(client_ref)
    end

    test "works without circuit breaker enabled" do
      attempts = start_supervised!({Agent, fn -> 0 end})

      client = %RetryableClient{failure_count: 0, attempts: attempts}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      assert BaseAgentConfig.circuit_breaker_key(agent) == nil

      {_agent, response} = BaseAgent.run!(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 1 attempts"
    end
  end

  describe "combined retry and circuit breaker" do
    test "retries within circuit breaker" do
      attempts = start_supervised!({Agent, fn -> 0 end})

      # Client that fails once then succeeds (works with :quick preset's 2 max attempts)
      client = %RetryableClient{failure_count: 1, attempts: attempts}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry: [max_attempts: 3, base_delay: 10],
          circuit_breaker: breaker_opts(failure_threshold: 5)
        })

      # Should retry and succeed without opening circuit
      {agent, response} = BaseAgent.run!(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 2 attempts"
      assert CircuitBreaker.state(breaker(agent)) == :closed
    end

    test "circuit breaker prevents excessive retries" do
      attempts = start_supervised!({Agent, fn -> 0 end})

      # Client that always fails
      client = %RetryableClient{failure_count: 1000, attempts: attempts}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry: [max_attempts: 10, base_delay: 10, max_delay: 20],
          circuit_breaker:
            breaker_opts(
              failure_threshold: 3,
              timeout: 60_000
            )
        })

      # First few calls will retry and fail
      assert_raise Normandy.LLMError, ~r/server/, fn ->
        BaseAgent.run!(agent, %{chat_message: "test1"})
      end

      assert_raise Normandy.LLMError, ~r/server/, fn ->
        BaseAgent.run!(agent, %{chat_message: "test2"})
      end

      assert_raise Normandy.LLMError, ~r/server/, fn ->
        BaseAgent.run!(agent, %{chat_message: "test3"})
      end

      # Circuit should be open now
      assert CircuitBreaker.state(breaker(agent)) == :open

      # Next call should fail fast (no retries due to open circuit)
      attempt_count_before = Agent.get(attempts, & &1)

      assert_raise Normandy.LLMError,
                   "LLM call failed: circuit_open: circuit breaker is open",
                   fn ->
                     BaseAgent.run!(agent, %{chat_message: "test4"})
                   end

      attempt_count_after = Agent.get(attempts, & &1)

      # Should not have retried (circuit is open)
      assert attempt_count_after == attempt_count_before
    end
  end
end
