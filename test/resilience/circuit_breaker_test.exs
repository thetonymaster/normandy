defmodule Normandy.Resilience.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Normandy.Resilience.CircuitBreaker

  describe "start_link/1" do
    test "starts with default options" do
      {:ok, cb} = CircuitBreaker.start_link()
      assert CircuitBreaker.state(cb) == :closed
      GenServer.stop(cb)
    end

    test "starts with custom options" do
      {:ok, cb} =
        CircuitBreaker.start_link(
          failure_threshold: 10,
          timeout: 30_000
        )

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.failure_threshold == 10
      GenServer.stop(cb)
    end

    test "can be started with a name" do
      {:ok, cb} = CircuitBreaker.start_link(name: :test_breaker)
      assert CircuitBreaker.state(:test_breaker) == :closed
      GenServer.stop(cb)
    end
  end

  describe "call/2 in closed state" do
    test "executes function and returns success" do
      {:ok, cb} = CircuitBreaker.start_link()

      result =
        CircuitBreaker.call(cb, fn ->
          {:ok, "success"}
        end)

      assert result == {:ok, "success"}
      assert CircuitBreaker.state(cb) == :closed
      GenServer.stop(cb)
    end

    test "handles function errors" do
      {:ok, cb} = CircuitBreaker.start_link()

      result =
        CircuitBreaker.call(cb, fn ->
          {:error, :some_error}
        end)

      assert result == {:error, :some_error}
      assert CircuitBreaker.state(cb) == :closed
      GenServer.stop(cb)
    end

    test "increments failure count on errors" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 3)

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      metrics = CircuitBreaker.metrics(cb)
      assert metrics.failure_count == 1

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      metrics = CircuitBreaker.metrics(cb)
      assert metrics.failure_count == 2

      GenServer.stop(cb)
    end

    test "resets failure count on success" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 5)

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.metrics(cb).failure_count == 2

      CircuitBreaker.call(cb, fn -> {:ok, "success"} end)
      assert CircuitBreaker.metrics(cb).failure_count == 0

      GenServer.stop(cb)
    end
  end

  describe "state transitions" do
    test "transitions from closed to open after threshold failures" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 3)

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :closed

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :closed

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      GenServer.stop(cb)
    end

    test "transitions from open to half-open after timeout" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 2, timeout: 100)

      # Trigger open state
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      # Wait for timeout
      Process.sleep(150)

      # Next state check should transition to half-open
      assert CircuitBreaker.state(cb) == :half_open

      GenServer.stop(cb)
    end

    test "transitions from half-open to closed after success threshold" do
      {:ok, cb} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          success_threshold: 2,
          timeout: 50
        )

      # Open the circuit
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      # Wait for half-open
      Process.sleep(100)
      assert CircuitBreaker.state(cb) == :half_open

      # First success
      CircuitBreaker.call(cb, fn -> {:ok, "success"} end)
      assert CircuitBreaker.state(cb) == :half_open

      # Second success should close circuit
      CircuitBreaker.call(cb, fn -> {:ok, "success"} end)
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end

    test "transitions from half-open back to open on failure" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 2, timeout: 50)

      # Open the circuit
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      # Wait for half-open
      Process.sleep(100)
      assert CircuitBreaker.state(cb) == :half_open

      # Failure should reopen
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      GenServer.stop(cb)
    end
  end

  describe "call/2 in open state" do
    test "fails fast without executing function" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)

      # Open the circuit
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      # Function should not be called
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      result =
        CircuitBreaker.call(cb, fn ->
          Agent.update(agent, &(&1 + 1))
          {:ok, "should not execute"}
        end)

      assert result == {:error, :open}
      assert Agent.get(agent, & &1) == 0

      Agent.stop(agent)
      GenServer.stop(cb)
    end
  end

  describe "call/2 in half-open state" do
    test "limits concurrent calls" do
      {:ok, cb} =
        CircuitBreaker.start_link(
          failure_threshold: 1,
          timeout: 50,
          half_open_max_calls: 1
        )

      # Open the circuit
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)

      # Wait for half-open
      Process.sleep(100)
      assert CircuitBreaker.state(cb) == :half_open

      # First call should be allowed
      task1 =
        Task.async(fn ->
          CircuitBreaker.call(cb, fn ->
            Process.sleep(50)
            {:ok, "first"}
          end)
        end)

      # Give first task time to start
      Process.sleep(10)

      # Second call should be rejected (circuit is half-open with max 1 call)
      result2 =
        CircuitBreaker.call(cb, fn ->
          {:ok, "second"}
        end)

      assert result2 == {:error, :open}

      # Wait for first task
      assert Task.await(task1) == {:ok, "first"}

      GenServer.stop(cb)
    end
  end

  describe "metrics/1" do
    test "returns current metrics" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 5)

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      CircuitBreaker.call(cb, fn -> {:ok, "success"} end)

      metrics = CircuitBreaker.metrics(cb)

      assert metrics.state == :closed
      assert metrics.failure_count == 0
      assert metrics.success_count == 1
      assert metrics.failure_threshold == 5

      GenServer.stop(cb)
    end

    test "includes opened_at timestamp when open" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)

      CircuitBreaker.call(cb, fn -> {:error, :fail} end)

      metrics = CircuitBreaker.metrics(cb)

      assert metrics.state == :open
      assert is_integer(metrics.opened_at)

      GenServer.stop(cb)
    end
  end

  describe "reset/1" do
    test "manually resets circuit to closed state" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)

      # Open the circuit
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      assert CircuitBreaker.state(cb) == :open

      # Reset
      CircuitBreaker.reset(cb)
      assert CircuitBreaker.state(cb) == :closed

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.failure_count == 0
      assert metrics.success_count == 0

      GenServer.stop(cb)
    end
  end

  describe "trip/1" do
    test "manually opens the circuit" do
      {:ok, cb} = CircuitBreaker.start_link()

      assert CircuitBreaker.state(cb) == :closed

      CircuitBreaker.trip(cb)
      assert CircuitBreaker.state(cb) == :open

      # Calls should fail fast
      result = CircuitBreaker.call(cb, fn -> {:ok, "test"} end)
      assert result == {:error, :open}

      GenServer.stop(cb)
    end
  end

  describe "exception handling" do
    test "treats exceptions as failures" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 2)

      result =
        CircuitBreaker.call(cb, fn ->
          raise "error"
        end)

      assert {:error, {:exception, %RuntimeError{}}} = result

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.failure_count == 1

      GenServer.stop(cb)
    end

    test "opens circuit after exception threshold" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 2)

      CircuitBreaker.call(cb, fn -> raise "error1" end)
      assert CircuitBreaker.state(cb) == :closed

      CircuitBreaker.call(cb, fn -> raise "error2" end)
      assert CircuitBreaker.state(cb) == :open

      GenServer.stop(cb)
    end
  end

  describe "concurrent access" do
    test "handles concurrent calls correctly" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 10)

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            CircuitBreaker.call(cb, fn ->
              if rem(i, 3) == 0 do
                {:error, :fail}
              else
                {:ok, i}
              end
            end)
          end)
        end

      results = Task.await_many(tasks)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, :fail}, &1))

      assert successes + failures == 20
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end
  end
end
