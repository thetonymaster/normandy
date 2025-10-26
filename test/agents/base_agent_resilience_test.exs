defmodule Normandy.Agents.BaseAgentResilienceTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Resilience.Retry

  # Mock client that fails then succeeds (for retry testing)
  defmodule RetryableClient do
    use Normandy.Schema

    schema do
      field(:failure_count, :integer, default: 0)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        # Simulate failures on first attempts
        current_count = Agent.get_and_update(:retry_agent, fn count -> {count, count + 1} end)

        if current_count < client.failure_count do
          # Simulate transient error
          raise "Temporary network error"
        else
          # Success after retries
          %{response_model | chat_message: "Success after #{current_count + 1} attempts"}
        end
      end
    end
  end

  # Mock client for circuit breaker testing
  defmodule CircuitBreakerClient do
    use Normandy.Schema

    schema do
      field(:should_fail, :boolean, default: true)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        if client.should_fail do
          raise "Service unavailable"
        else
          %{response_model | chat_message: "Success"}
        end
      end
    end
  end

  describe "retry integration" do
    test "automatically retries failed LLM calls" do
      {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)

      # Configure agent with retry (fail first attempt only)
      client = %RetryableClient{failure_count: 1}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry_options: Retry.preset(:quick)
        })

      # This should succeed after retries
      {_agent, response} = BaseAgent.run(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 2 attempts"
      Agent.stop(:retry_agent)
    end

    test "works without retry configuration" do
      {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)

      client = %RetryableClient{failure_count: 0}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      # Should work on first try
      {_agent, response} = BaseAgent.run(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 1 attempts"
      Agent.stop(:retry_agent)
    end

    test "uses custom retry options" do
      {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)

      client = %RetryableClient{failure_count: 1}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry_options: [
            max_attempts: 3,
            base_delay: 10,
            retry_on: [:network_error],
            retry_if: fn
              {:error, {:exception, _, _}} -> true
              _ -> false
            end
          ]
        })

      {_agent, response} = BaseAgent.run(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 2 attempts"
      Agent.stop(:retry_agent)
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
          enable_circuit_breaker: true,
          circuit_breaker_options: [
            failure_threshold: 2,
            timeout: 100
          ]
        })

      # First two calls should fail and open circuit
      {agent, _} = BaseAgent.run(agent, %{chat_message: "test1"})
      {agent, _} = BaseAgent.run(agent, %{chat_message: "test2"})

      # Circuit should be open
      assert Normandy.Resilience.CircuitBreaker.state(agent.circuit_breaker) == :open

      # Third call should fail fast
      {_agent, response} = BaseAgent.run(agent, %{chat_message: "test3"})

      # Should return empty response (circuit open)
      assert response.chat_message == nil

      # Clean up
      if agent.circuit_breaker do
        GenServer.stop(agent.circuit_breaker)
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
          enable_circuit_breaker: true,
          circuit_breaker_options: [
            failure_threshold: 1,
            success_threshold: 1,
            timeout: 50
          ]
        })

      # Open circuit
      {agent, _} = BaseAgent.run(agent, %{chat_message: "fail"})
      assert Normandy.Resilience.CircuitBreaker.state(agent.circuit_breaker) == :open

      # Wait for half-open
      Process.sleep(100)

      # Fix the client
      Agent.update(client_ref, fn _ -> %CircuitBreakerClient{should_fail: false} end)
      updated_client = Agent.get(client_ref, & &1)
      agent = %{agent | client: updated_client}

      # Should transition to half-open and succeed
      {agent, response} = BaseAgent.run(agent, %{chat_message: "test"})

      assert response.chat_message == "Success"
      assert Normandy.Resilience.CircuitBreaker.state(agent.circuit_breaker) == :closed

      # Clean up
      Agent.stop(client_ref)

      if agent.circuit_breaker do
        GenServer.stop(agent.circuit_breaker)
      end
    end

    test "works without circuit breaker enabled" do
      {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)

      client = %RetryableClient{failure_count: 0}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      assert agent.circuit_breaker == nil

      {_agent, response} = BaseAgent.run(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 1 attempts"
      Agent.stop(:retry_agent)
    end
  end

  describe "combined retry and circuit breaker" do
    test "retries within circuit breaker" do
      {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)

      # Client that fails once then succeeds (works with :quick preset's 2 max attempts)
      client = %RetryableClient{failure_count: 1}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry_options: [max_attempts: 3, base_delay: 10],
          enable_circuit_breaker: true,
          circuit_breaker_options: [
            failure_threshold: 5
          ]
        })

      # Should retry and succeed without opening circuit
      {agent, response} = BaseAgent.run(agent, %{chat_message: "test"})

      assert response.chat_message == "Success after 2 attempts"
      assert Normandy.Resilience.CircuitBreaker.state(agent.circuit_breaker) == :closed

      # Clean up
      Agent.stop(:retry_agent)

      if agent.circuit_breaker do
        GenServer.stop(agent.circuit_breaker)
      end
    end

    test "circuit breaker prevents excessive retries" do
      {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)

      # Client that always fails
      client = %RetryableClient{failure_count: 1000}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          retry_options: [max_attempts: 10, base_delay: 1],
          enable_circuit_breaker: true,
          circuit_breaker_options: [
            failure_threshold: 3,
            timeout: 100
          ]
        })

      # First few calls will retry and fail
      {agent, _} = BaseAgent.run(agent, %{chat_message: "test1"})
      {agent, _} = BaseAgent.run(agent, %{chat_message: "test2"})
      {agent, _} = BaseAgent.run(agent, %{chat_message: "test3"})

      # Circuit should be open now
      assert Normandy.Resilience.CircuitBreaker.state(agent.circuit_breaker) == :open

      # Next call should fail fast (no retries due to open circuit)
      attempt_count_before = Agent.get(:retry_agent, & &1)
      {_agent, _} = BaseAgent.run(agent, %{chat_message: "test4"})
      attempt_count_after = Agent.get(:retry_agent, & &1)

      # Should not have retried (circuit is open)
      assert attempt_count_after == attempt_count_before

      # Clean up
      Agent.stop(:retry_agent)

      if agent.circuit_breaker do
        GenServer.stop(agent.circuit_breaker)
      end
    end
  end
end
