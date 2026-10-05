defmodule Normandy.Resilience.RetryTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Resilience.Retry

  describe "with_retry/2" do
    test "returns success on first attempt" do
      {:ok, result} =
        Retry.with_retry(fn ->
          {:ok, "success"}
        end)

      assert result == "success"
    end

    test "retries on failure and succeeds" do
      # Create agent to track attempts
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, result} =
        Retry.with_retry(
          fn ->
            attempts = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

            if attempts < 3 do
              {:error, :network_error}
            else
              {:ok, "success after #{attempts} attempts"}
            end
          end,
          max_attempts: 5,
          base_delay: 10
        )

      assert result == "success after 3 attempts"
      Agent.stop(agent)
    end

    test "fails after max attempts" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:error, {error, attempts, errors}} =
        Retry.with_retry(
          fn ->
            Agent.update(agent, &(&1 + 1))
            {:error, :network_error}
          end,
          max_attempts: 3,
          base_delay: 10
        )

      assert error == :network_error
      assert attempts == 3
      assert length(errors) == 3
      assert Agent.get(agent, & &1) == 3
      Agent.stop(agent)
    end

    test "respects retry_on list" do
      # Should retry network_error
      {:error, {error, attempts, _}} =
        Retry.with_retry(
          fn -> {:error, :network_error} end,
          max_attempts: 3,
          base_delay: 10,
          retry_on: [:network_error, :timeout]
        )

      assert error == :network_error
      assert attempts == 3

      # Should not retry validation_error; the failure has the same shape
      {:error, {:validation_error, 1, [:validation_error]}} =
        Retry.with_retry(
          fn -> {:error, :validation_error} end,
          max_attempts: 3,
          base_delay: 10,
          retry_on: [:network_error, :timeout]
        )
    end

    test "uses custom retry_if function" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, result} =
        Retry.with_retry(
          fn ->
            attempts = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

            if attempts < 2 do
              {:error, %{status: 500}}
            else
              {:ok, "success"}
            end
          end,
          max_attempts: 5,
          base_delay: 10,
          retry_if: fn
            {:error, %{status: status}} when status >= 500 -> true
            _ -> false
          end
        )

      assert result == "success"
      Agent.stop(agent)
    end

    test "does not retry on non-retryable error with custom retry_if" do
      {:error, {%{status: 400}, 1, [%{status: 400}]}} =
        Retry.with_retry(
          fn -> {:error, %{status: 400}} end,
          max_attempts: 3,
          base_delay: 10,
          retry_if: fn
            {:error, %{status: status}} when status >= 500 -> true
            _ -> false
          end
        )
    end

    test "handles tuple errors with retry_on" do
      {:error, {{:network_error, "connection refused"}, 3, _}} =
        Retry.with_retry(
          fn -> {:error, {:network_error, "connection refused"}} end,
          max_attempts: 3,
          base_delay: 10,
          retry_on: [:network_error]
        )
    end

    test "handles map errors with type field" do
      {:error, {%{type: :timeout, details: "slow"}, 2, _}} =
        Retry.with_retry(
          fn -> {:error, %{type: :timeout, details: "slow"}} end,
          max_attempts: 2,
          base_delay: 10,
          retry_on: [:timeout]
        )
    end

    test "handles exceptions" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, result} =
        Retry.with_retry(
          fn ->
            attempts = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

            if attempts < 2 do
              raise "temporary error"
            else
              {:ok, "recovered"}
            end
          end,
          max_attempts: 3,
          base_delay: 10,
          retry_if: fn
            {:error, {:exception, _, _}} -> true
            _ -> false
          end
        )

      assert result == "recovered"
      Agent.stop(agent)
    end

    test "calculates exponential backoff delays" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      Retry.with_retry(
        fn ->
          Agent.update(agent, fn times -> [System.monotonic_time(:millisecond) | times] end)
          {:error, :network_error}
        end,
        max_attempts: 3,
        base_delay: 100,
        backoff_factor: 2.0,
        jitter: false
      )

      times = Agent.get(agent, & &1) |> Enum.reverse()

      # First attempt is immediate
      # Second attempt after ~100ms
      # Third attempt after ~200ms (100 * 2^1)
      if length(times) == 3 do
        delay1 = Enum.at(times, 1) - Enum.at(times, 0)
        delay2 = Enum.at(times, 2) - Enum.at(times, 1)

        # Allow some tolerance for timing
        assert delay1 >= 80 and delay1 <= 300
        assert delay2 >= 160 and delay2 <= 600
      end

      Agent.stop(agent)
    end
  end

  describe "preset/1" do
    test "quick preset has correct values" do
      opts = Retry.preset(:quick)
      assert opts[:max_attempts] == 2
      assert opts[:base_delay] == 100
    end

    test "standard preset has correct values" do
      opts = Retry.preset(:standard)
      assert opts[:max_attempts] == 3
      assert opts[:base_delay] == 1_000
    end

    test "persistent preset has correct values" do
      opts = Retry.preset(:persistent)
      assert opts[:max_attempts] == 5
      assert opts[:base_delay] == 1_000
    end

    test "patient preset has correct values" do
      opts = Retry.preset(:patient)
      assert opts[:max_attempts] == 10
      assert opts[:base_delay] == 2_000
    end

    test "an unknown preset raises instead of becoming :standard" do
      assert_raise ArgumentError, ~r/unknown preset :persistant/, fn ->
        Retry.preset(:persistant)
      end
    end

    test "can use preset in with_retry" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, _result} =
        Retry.with_retry(
          fn ->
            attempts = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

            if attempts < 2 do
              {:error, :network_error}
            else
              {:ok, "success"}
            end
          end,
          Retry.preset(:quick)
        )

      assert Agent.get(agent, & &1) == 2
      Agent.stop(agent)
    end
  end

  describe "jitter" do
    test "adds randomness to delays when enabled" do
      {:ok, delay_agent} = Agent.start_link(fn -> [] end)

      for _ <- 1..5 do
        {:ok, agent} = Agent.start_link(fn -> [] end)

        Retry.with_retry(
          fn ->
            Agent.update(agent, fn times -> [System.monotonic_time(:millisecond) | times] end)
            {:error, :network_error}
          end,
          max_attempts: 2,
          base_delay: 100,
          jitter: true
        )

        times = Agent.get(agent, & &1) |> Enum.reverse()
        delay = if length(times) == 2, do: Enum.at(times, 1) - Enum.at(times, 0), else: 0
        Agent.update(delay_agent, fn delays -> [delay | delays] end)
        Agent.stop(agent)
      end

      delays = Agent.get(delay_agent, & &1)

      # With jitter, delays should vary
      unique_delays = Enum.uniq(delays)
      assert length(unique_delays) > 1
      Agent.stop(delay_agent)
    end

    test "retries with a delay under 4ms when enabled" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      result =
        Retry.with_retry(
          fn ->
            case Agent.get_and_update(agent, &{&1, &1 + 1}) do
              0 -> {:error, :network_error}
              _ -> {:ok, :done}
            end
          end,
          max_attempts: 2,
          base_delay: 1,
          jitter: true
        )

      assert result == {:ok, :done}
      Agent.stop(agent)
    end
  end

  describe "add_jitter/1" do
    use ExUnitProperties

    property "stays within ±25% of the delay" do
      check all(delay <- integer(0..100_000)) do
        range = div(delay, 4)
        jittered = Retry.add_jitter(delay)
        assert jittered >= delay - range
        assert jittered <= delay + range
      end
    end

    test "reaches both ends of the range" do
      results = MapSet.new(1..2_000, fn _ -> Retry.add_jitter(8) end)
      assert results == MapSet.new(6..10)
    end
  end

  describe "option checks" do
    test "an unknown option raises, naming it" do
      assert_raise ArgumentError, ~r/Retry.with_retry\/2: unknown option :max_attemps/, fn ->
        Retry.with_retry(fn -> {:ok, 1} end, max_attemps: 5)
      end
    end

    test "BaseAgent.init checks :retry when the agent is built" do
      assert_raise ArgumentError, ~r/unknown option :max_attemps/, fn ->
        BaseAgent.init(%{
          client: %NormandyTest.Support.ModelMockup{},
          model: "m",
          retry: [max_attemps: 3]
        })
      end
    end

    test "an invalid value raises, naming the option and value" do
      assert_raise ArgumentError, ~r/:max_attempts must be a positive integer, got: 0/, fn ->
        Retry.with_retry(fn -> {:ok, 1} end, max_attempts: 0)
      end

      assert_raise ArgumentError, ~r/:base_delay must be a non-negative integer, got: -1/, fn ->
        Retry.with_retry(fn -> {:ok, 1} end, base_delay: -1)
      end
    end
  end

  describe "return shapes" do
    test "a non-tuple return is a failure in the same {reason, attempts, errors} shape" do
      assert {:error, {{:unexpected_return, :weird}, 1, [{:unexpected_return, :weird}]}} =
               Retry.with_retry(fn -> :weird end, max_attempts: 3, base_delay: 1)
    end
  end
end
