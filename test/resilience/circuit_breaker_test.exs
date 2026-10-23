defmodule Normandy.Resilience.CircuitBreakerTest do
  use ExUnit.Case, async: true

  import Normandy.Test.Eventually

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
      # A unique name, so no other test can hold it.
      name = :"test_breaker_#{System.unique_integer([:positive])}"

      {:ok, cb} = CircuitBreaker.start_link(name: name)
      assert CircuitBreaker.state(name) == :closed
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

    test "an exit or a throw is a recorded failure, returned as an error" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 2)

      assert {:error, {:exit, :boom}} = CircuitBreaker.call(cb, fn -> exit(:boom) end)
      assert CircuitBreaker.metrics(cb).failure_count == 1

      assert {:error, {:throw, :nope}} = CircuitBreaker.call(cb, fn -> throw(:nope) end)
      assert CircuitBreaker.state(cb) == :open
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
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 2, timeout: 1)

      # Trigger open state
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)

      # Wait for timeout
      Process.sleep(5)

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

      assert wait_until(fn -> CircuitBreaker.state(cb) == :half_open end)

      # First call is allowed, and holds the only half-open slot until released
      test_pid = self()

      task1 =
        Task.async(fn ->
          CircuitBreaker.call(cb, fn ->
            send(test_pid, {:first_running, self()})
            receive do: (:release -> {:ok, "first"})
          end)
        end)

      assert_receive {:first_running, first}

      # Second call should be rejected (circuit is half-open with max 1 call)
      result2 =
        CircuitBreaker.call(cb, fn ->
          {:ok, "second"}
        end)

      assert result2 == {:error, :open}

      send(first, :release)
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

  describe "a non-tuple return" do
    test "counts as a failure, as Retry treats it" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 5)

      assert {:error, {:unexpected_return, :weird}} = CircuitBreaker.call(cb, fn -> :weird end)
      assert %{failure_count: 1} = CircuitBreaker.metrics(cb)
    end
  end

  # The open window is 1 ms; sleeping 2 ms only lets it elapse. Which result lands in
  # which generation is decided by messages, not by timing.
  defp open_then_half_open(cb) do
    :ok = CircuitBreaker.trip(cb)
    Process.sleep(2)
    assert CircuitBreaker.state(cb) == :half_open
  end

  # A caller admitted now whose function blocks until it gets {:finish, result}.
  defp blocked_caller(cb) do
    test_pid = self()

    task =
      Task.async(fn ->
        CircuitBreaker.call(cb, fn ->
          send(test_pid, {:admitted, self()})
          receive do: ({:finish, result} -> result)
        end)
      end)

    assert_receive {:admitted, caller}
    {task, caller}
  end

  describe "a killed half-open probe (PERF-1)" do
    test "frees its slot and reopens the breaker" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, half_open_max_calls: 1)
      open_then_half_open(cb)

      {task, probe} = blocked_caller(cb)
      assert CircuitBreaker.metrics(cb).half_open_calls == 1

      Process.unlink(task.pid)
      Process.exit(probe, :kill)

      assert wait_until(fn -> CircuitBreaker.metrics(cb).half_open_calls == 0 end)
      assert CircuitBreaker.metrics(cb).state == :open

      # The next window admits a new probe, and its success closes the breaker.
      Process.sleep(2)
      assert CircuitBreaker.call(cb, fn -> {:ok, 1} end) == {:ok, 1}
      assert CircuitBreaker.call(cb, fn -> {:ok, 2} end) == {:ok, 2}
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end

    test "a probe that returns normally releases its monitor" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, success_threshold: 2)
      open_then_half_open(cb)

      assert CircuitBreaker.call(cb, fn -> {:ok, :fine} end) == {:ok, :fine}

      # One of two successes: still half-open, so only release_probe/2 can have freed the slot.
      metrics = CircuitBreaker.metrics(cb)
      assert metrics.state == :half_open
      assert metrics.half_open_calls == 0
      assert {:monitors, []} = Process.info(cb, :monitors)

      GenServer.stop(cb)
    end
  end

  describe "a breaker that dies while the function runs" do
    test "the caller still gets the function's result and one warning is logged" do
      {:ok, cb} = CircuitBreaker.start_link()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert CircuitBreaker.call(cb, fn ->
                   Process.unlink(cb)
                   ref = Process.monitor(cb)
                   Process.exit(cb, :kill)
                   assert_receive {:DOWN, ^ref, :process, _, :killed}
                   {:ok, :done}
                 end) == {:ok, :done}
        end)

      assert log =~ "Circuit breaker did not record a call's outcome (exit: noproc)"
    end
  end

  describe "stale results (PERF-9)" do
    test "a success admitted while closed does not count as a probe success" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, success_threshold: 1)

      {task, caller} = blocked_caller(cb)
      open_then_half_open(cb)

      send(caller, {:finish, {:ok, :late}})
      assert Task.await(task) == {:ok, :late}

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.state == :half_open
      assert metrics.success_count == 0

      GenServer.stop(cb)
    end

    test "a failure admitted while closed does not reopen a half-open breaker" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, failure_threshold: 1)

      {task, caller} = blocked_caller(cb)
      open_then_half_open(cb)

      send(caller, {:finish, {:error, :late}})
      assert Task.await(task) == {:error, :late}

      assert CircuitBreaker.state(cb) == :half_open

      GenServer.stop(cb)
    end

    test "a result admitted before reset/1 does not count after it" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)

      {task, caller} = blocked_caller(cb)
      :ok = CircuitBreaker.reset(cb)

      send(caller, {:finish, {:error, :late}})
      assert Task.await(task) == {:error, :late}

      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.metrics(cb).failure_count == 0

      GenServer.stop(cb)
    end

    test "every state change bumps the generation" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, success_threshold: 1)
      assert CircuitBreaker.metrics(cb).generation == 0

      :ok = CircuitBreaker.trip(cb)
      assert CircuitBreaker.metrics(cb).generation == 1

      Process.sleep(2)
      assert CircuitBreaker.state(cb) == :half_open
      assert CircuitBreaker.metrics(cb).generation == 2

      assert CircuitBreaker.call(cb, fn -> {:ok, 1} end) == {:ok, 1}
      assert CircuitBreaker.metrics(cb).generation == 3

      :ok = CircuitBreaker.reset(cb)
      assert CircuitBreaker.metrics(cb).generation == 4

      GenServer.stop(cb)
    end
  end

  describe "admission" do
    test "an open breaker admits nothing, even with no probe running" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 60_000)
      :ok = CircuitBreaker.trip(cb)

      assert CircuitBreaker.call(cb, fn -> flunk("must not run") end) == {:error, :open}
      assert CircuitBreaker.metrics(cb).half_open_calls == 0

      GenServer.stop(cb)
    end

    test "a result recorded after the breaker stopped is still returned" do
      {:ok, cb} = CircuitBreaker.start_link()
      Process.unlink(cb)

      result =
        CircuitBreaker.call(cb, fn ->
          GenServer.stop(cb)
          {:ok, :done}
        end)

      assert result == {:ok, :done}
    end
  end

  describe "failure_if" do
    test "a failure the classifier rejects is not counted" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)
      not_counted = fn {:error, reason} -> reason != :caller_error end

      assert CircuitBreaker.call(cb, fn -> {:error, :caller_error} end, failure_if: not_counted) ==
               {:error, :caller_error}

      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.metrics(cb).failure_count == 0

      assert CircuitBreaker.call(cb, fn -> {:error, :down} end, failure_if: not_counted) ==
               {:error, :down}

      assert CircuitBreaker.state(cb) == :open

      GenServer.stop(cb)
    end

    test "the classifier sees raises as {:error, {:exception, e}}" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)
      test_pid = self()

      classifier = fn result ->
        send(test_pid, {:classified, result})
        false
      end

      assert {:error, {:exception, %RuntimeError{}}} =
               CircuitBreaker.call(cb, fn -> raise "boom" end, failure_if: classifier)

      assert_received {:classified, {:error, {:exception, %RuntimeError{message: "boom"}}}}
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end

    test "an ignored half-open probe frees its slot and leaves the breaker half-open" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, half_open_max_calls: 1)
      :ok = CircuitBreaker.trip(cb)
      Process.sleep(2)
      assert CircuitBreaker.state(cb) == :half_open

      assert CircuitBreaker.call(cb, fn -> {:error, :caller_error} end,
               failure_if: fn _ -> false end
             ) == {:error, :caller_error}

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.state == :half_open
      assert metrics.half_open_calls == 0
      assert {:monitors, []} = Process.info(cb, :monitors)

      GenServer.stop(cb)
    end

    test "a classifier that raises counts the failure and frees the probe slot" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, half_open_max_calls: 1)
      :ok = CircuitBreaker.trip(cb)
      Process.sleep(5)
      assert CircuitBreaker.state(cb) == :half_open

      assert CircuitBreaker.call(cb, fn -> {:error, :down} end,
               failure_if: fn _ -> raise "classifier bug" end
             ) == {:error, :down}

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.half_open_calls == 0
      assert {:monitors, []} = Process.info(cb, :monitors)
      assert metrics.state == :open

      GenServer.stop(cb)
    end

    test "success is never classified" do
      {:ok, cb} = CircuitBreaker.start_link()

      assert CircuitBreaker.call(cb, fn -> {:ok, 1} end, failure_if: fn _ -> flunk("called") end) ==
               {:ok, 1}

      GenServer.stop(cb)
    end

    test "an unknown option raises in the house style" do
      {:ok, cb} = CircuitBreaker.start_link()

      assert_raise ArgumentError,
                   ~r/^Normandy.Resilience.CircuitBreaker.call\/3: unknown option :failure_iff/,
                   fn -> CircuitBreaker.call(cb, fn -> {:ok, 1} end, failure_iff: & &1) end

      GenServer.stop(cb)
    end
  end
end
