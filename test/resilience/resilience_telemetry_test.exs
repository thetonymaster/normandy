defmodule Normandy.Resilience.TelemetryTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.OpenAICompatibleAdapter
  alias Normandy.LLMError
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Resilience.Retry
  alias Normandy.Test.OwnLog
  alias Normandy.Test.TelemetryCapture

  @state_change [:normandy, :circuit_breaker, :state_change]
  @attempt [:normandy, :retry, :attempt]

  defp unique_name, do: :"tel_breaker_#{System.unique_integer([:positive])}"

  # Retry emits in the caller's process; only this test's events are forwarded.
  defp attach_retry do
    test_pid = self()
    TelemetryCapture.attach([@attempt], fn _metadata -> self() == test_pid end)
  end

  describe "[:normandy, :circuit_breaker, :state_change]" do
    test "closed -> open -> half_open -> closed, in order" do
      name = unique_name()
      ref = TelemetryCapture.attach([@state_change], name: name)

      {:ok, cb} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 1,
          success_threshold: 1,
          timeout: 1
        )

      assert CircuitBreaker.call(cb, fn -> {:error, :down} end) == {:error, :down}
      Process.sleep(2)
      assert CircuitBreaker.call(cb, fn -> {:ok, :up} end) == {:ok, :up}

      assert_receive {:telemetry, ^ref, %{count: 1, failure_count: 1},
                      %{
                        from: :closed,
                        to: :open,
                        reason: :failure_threshold,
                        key: nil,
                        name: ^name
                      }}

      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{from: :open, to: :half_open, reason: :timeout}}

      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{from: :half_open, to: :closed, reason: :probe_success}}

      GenServer.stop(cb)
    end

    test "trip/1, reset/1 and a killed probe report their reasons" do
      name = unique_name()
      ref = TelemetryCapture.attach([@state_change], name: name)
      {:ok, cb} = CircuitBreaker.start_link(name: name, timeout: 1)

      :ok = CircuitBreaker.trip(cb)
      assert_receive {:telemetry, ^ref, _, %{from: :closed, to: :open, reason: :trip}}

      Process.sleep(2)
      test_pid = self()

      {probe, probe_ref} =
        spawn_monitor(fn ->
          CircuitBreaker.call(cb, fn ->
            send(test_pid, :admitted)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :admitted
      Process.exit(probe, :kill)
      assert_receive {:DOWN, ^probe_ref, :process, ^probe, :killed}

      assert_receive {:telemetry, ^ref, _, %{from: :half_open, to: :open, reason: :probe_down}}

      :ok = CircuitBreaker.reset(cb)
      assert_receive {:telemetry, ^ref, _, %{from: :open, to: :closed, reason: :reset}}

      GenServer.stop(cb)
    end

    test "a shared breaker's events carry its key, never a credential" do
      client = %OpenAICompatibleAdapter{
        api_key: "sk-secret",
        base_url: "https://user:pw@api.example.com/v1?key=sk-query"
      }

      key =
        CircuitBreaker.key(client, "m",
          failure_threshold: 1,
          scope: {__MODULE__, System.unique_integer([:positive])}
        )

      ref = TelemetryCapture.attach([@state_change], key: key)

      assert CircuitBreaker.run(key, fn -> {:error, :down} end) == {:error, :down}

      assert_receive {:telemetry, ^ref, _, %{key: ^key, to: :open} = metadata}
      refute inspect(metadata) =~ "sk-"
      refute inspect(metadata) =~ "pw"
    end

    test "the state-change log names the breaker and the change" do
      name = unique_name()
      {:ok, cb} = CircuitBreaker.start_link(name: name, failure_threshold: 1)

      log =
        ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
          CircuitBreaker.call(cb, fn -> {:error, :down} end)
        end)

      assert log =~ "Circuit breaker #{inspect(name)} closed -> open (failure_threshold)"

      GenServer.stop(cb)
    end
  end

  describe "[:normandy, :retry, :attempt]" do
    test "one event per retried attempt, with the LLMError's type" do
      ref = attach_retry()
      error = LLMError.new(type: :overloaded, retryable?: true, status: 529)

      assert {:error, {^error, 3, _errors}} =
               Retry.with_retry(fn -> {:error, error} end,
                 max_attempts: 3,
                 base_delay: 0,
                 max_delay: 0,
                 jitter: false,
                 retry_if: fn _ -> true end
               )

      assert_receive {:telemetry, ^ref, %{attempt: 1, max_attempts: 3, delay_ms: 0},
                      %{error_type: :overloaded}}

      assert_receive {:telemetry, ^ref, %{attempt: 2, max_attempts: 3, delay_ms: 0},
                      %{error_type: :overloaded}}

      refute_received {:telemetry, ^ref, %{attempt: 3}, _}
    end

    test "a raise is typed by its module, and the log holds no message or stacktrace" do
      ref = attach_retry()

      # Retry logs in the caller; only this process's events are kept, since an
      # async capture also sees other tests' crash reports and their stack frames.
      log =
        OwnLog.capture([metadata: :all], fn ->
          Retry.with_retry(fn -> raise ArgumentError, "SECRET-in-message" end,
            max_attempts: 2,
            base_delay: 0,
            max_delay: 0,
            jitter: false,
            retry_if: fn _ -> true end
          )
        end)

      assert_receive {:telemetry, ^ref, %{attempt: 1}, %{error_type: ArgumentError}}
      assert log =~ "Retry attempt 1/2 failed: ArgumentError"
      refute log =~ "SECRET-in-message"
      refute log =~ ~r/\.exs?:\d+/
    end

    test "exits, throws and atoms have their own types" do
      ref = attach_retry()

      opts = [
        max_attempts: 2,
        base_delay: 0,
        max_delay: 0,
        jitter: false,
        retry_if: fn _ -> true end
      ]

      Retry.with_retry(fn -> exit(:boom) end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :exit}}

      Retry.with_retry(fn -> throw(:ball) end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :throw}}

      Retry.with_retry(fn -> {:error, :timeout} end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :timeout}}

      Retry.with_retry(fn -> {:error, %{detail: "SECRET"}} end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :error}}
    end
  end
end
