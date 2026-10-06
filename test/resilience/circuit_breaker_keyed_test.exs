defmodule Normandy.Resilience.CircuitBreakerKeyedTest do
  use ExUnit.Case, async: true

  import Normandy.Test.Eventually

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.OpenAICompatibleAdapter
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  # Every test gets its own scope, so async tests never share a breaker.
  defp scope, do: {__MODULE__, System.unique_integer([:positive])}

  defp stub_key(opts \\ []),
    do: CircuitBreaker.key(%StubClient{}, "m", Keyword.put_new(opts, :scope, scope()))

  describe "key/3" do
    test "is the client module, endpoint, model and the options with defaults, sorted" do
      client = %OpenAICompatibleAdapter{
        api_key: "sk-secret",
        base_url: "https://api.example.com/v1"
      }

      assert CircuitBreaker.key(client, "gpt-x", failure_threshold: 3) ==
               {OpenAICompatibleAdapter, "https://api.example.com/v1", "gpt-x",
                [
                  failure_threshold: 3,
                  half_open_max_calls: 1,
                  scope: nil,
                  success_threshold: 2,
                  timeout: 60_000
                ]}
    end

    test "[] and the explicit defaults are the same key" do
      client = %StubClient{}

      assert CircuitBreaker.key(client, "m", []) ==
               CircuitBreaker.key(client, "m",
                 failure_threshold: 5,
                 success_threshold: 2,
                 timeout: 60_000,
                 half_open_max_calls: 1,
                 scope: nil
               )
    end

    test "never holds a credential: no API key, URL userinfo, query or fragment" do
      client = %OpenAICompatibleAdapter{
        api_key: "sk-secret",
        base_url: "https://user:pw@api.example.com:8443/v1?key=sk-query#frag"
      }

      key = CircuitBreaker.key(client, "m", [])
      shown = inspect(key)

      assert elem(key, 1) == "https://api.example.com:8443/v1"
      refute shown =~ "sk-secret"
      refute shown =~ "pw"
      refute shown =~ "sk-query"
      refute shown =~ "frag"
    end

    test "reads a ClaudioAdapter's base_url from its struct field, else its options" do
      assert {ClaudioAdapter, nil, "m", _} =
               CircuitBreaker.key(%ClaudioAdapter{api_key: "k"}, "m", [])

      assert {ClaudioAdapter, "https://proxy.local", "m", _} =
               CircuitBreaker.key(
                 %ClaudioAdapter{api_key: "k", options: %{base_url: "https://proxy.local"}},
                 "m",
                 []
               )
    end

    test "an unknown option raises in the house style" do
      assert_raise ArgumentError,
                   ~r/^Normandy.Resilience.CircuitBreaker.key\/3: unknown option :failure_treshold; supported: /,
                   fn -> CircuitBreaker.key(%StubClient{}, "m", failure_treshold: 3) end
    end

    test ":name is not a key option" do
      assert_raise ArgumentError, ~r/unknown option :name/, fn ->
        CircuitBreaker.key(%StubClient{}, "m", name: :x)
      end
    end
  end

  describe "ensure_started/1" do
    test "starts a breaker under Normandy's supervisor, once per key" do
      key = stub_key()
      assert CircuitBreaker.fetch(key) == :error

      {:ok, pid} = CircuitBreaker.ensure_started(key)
      assert {:ok, ^pid} = CircuitBreaker.ensure_started(key)
      assert CircuitBreaker.fetch(key) == {:ok, pid}

      children = DynamicSupervisor.which_children(Normandy.Resilience.CircuitBreaker.Supervisor)
      assert Enum.any?(children, &match?({_, ^pid, :worker, _}, &1))
      refute pid in (Process.info(self(), :links) |> elem(1))
    end

    test "the breaker uses the key's options" do
      key = stub_key(failure_threshold: 7, timeout: 1234)
      {:ok, pid} = CircuitBreaker.ensure_started(key)

      assert %{failure_threshold: 7} = CircuitBreaker.metrics(pid)
    end

    test "concurrent ensure_started starts one breaker" do
      key = stub_key()

      pids =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> CircuitBreaker.ensure_started(key) end) end)
        |> Enum.map(&Task.await/1)
        |> Enum.uniq()

      assert [{:ok, _pid}] = pids
    end

    test "different scopes get different breakers" do
      {:ok, a} = CircuitBreaker.ensure_started(stub_key())
      {:ok, b} = CircuitBreaker.ensure_started(stub_key())
      assert a != b
    end

    test "different models get different breakers" do
      s = scope()
      {:ok, a} = CircuitBreaker.ensure_started(CircuitBreaker.key(%StubClient{}, "m1", scope: s))
      {:ok, b} = CircuitBreaker.ensure_started(CircuitBreaker.key(%StubClient{}, "m2", scope: s))
      assert a != b
    end

    test "a breaker outlives the process that started it" do
      key = stub_key()

      {:ok, pid} =
        Task.async(fn -> CircuitBreaker.ensure_started(key) end) |> Task.await()

      assert Process.alive?(pid)
      assert CircuitBreaker.fetch(key) == {:ok, pid}
    end

    test "a crashed breaker is not restarted; the next use starts a fresh, closed one" do
      key = stub_key(failure_threshold: 1)
      {:ok, pid} = CircuitBreaker.ensure_started(key)
      :ok = CircuitBreaker.trip(pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert wait_until(fn -> CircuitBreaker.fetch(key) == :error end)

      assert CircuitBreaker.run(key, fn -> {:ok, :again} end) == {:ok, :again}
      {:ok, new_pid} = CircuitBreaker.fetch(key)
      assert new_pid != pid
      assert CircuitBreaker.state(new_pid) == :closed
    end
  end

  describe "run/2" do
    test "runs the function through the key's breaker" do
      key = stub_key(failure_threshold: 1)

      assert CircuitBreaker.run(key, fn -> {:error, :down} end) == {:error, :down}
      assert CircuitBreaker.run(key, fn -> flunk("must not run") end) == {:error, :open}

      {:ok, pid} = CircuitBreaker.fetch(key)
      assert CircuitBreaker.state(pid) == :open
    end
  end

  describe "idle stop" do
    test "a closed keyed breaker stops on :timeout; the next run starts a fresh, closed one" do
      key = stub_key()
      {:ok, pid} = CircuitBreaker.ensure_started(key)
      ref = Process.monitor(pid)

      send(pid, :timeout)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert wait_until(fn -> CircuitBreaker.fetch(key) == :error end)

      assert CircuitBreaker.run(key, fn -> {:ok, :again} end) == {:ok, :again}
      {:ok, new_pid} = CircuitBreaker.fetch(key)
      assert new_pid != pid
      assert CircuitBreaker.state(new_pid) == :closed
    end

    test "an open keyed breaker stays alive and open" do
      {:ok, pid} = CircuitBreaker.ensure_started(stub_key())
      :ok = CircuitBreaker.trip(pid)
      ref = Process.monitor(pid)

      send(pid, :timeout)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50
      assert CircuitBreaker.state(pid) == :open
    end

    test "a half-open keyed breaker with a probe in flight stays alive" do
      {:ok, pid} = CircuitBreaker.ensure_started(stub_key(timeout: 1))
      :ok = CircuitBreaker.trip(pid)
      Process.sleep(5)
      assert {:ok, {_generation, probe}} = GenServer.call(pid, :acquire)
      assert is_reference(probe)
      assert CircuitBreaker.state(pid) == :half_open
      ref = Process.monitor(pid)

      send(pid, :timeout)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50
      assert Process.alive?(pid)
    end

    test "a start_link/1 breaker never idle-stops" do
      {:ok, pid} = CircuitBreaker.start_link()
      ref = Process.monitor(pid)

      send(pid, :timeout)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50
      assert CircuitBreaker.state(pid) == :closed
    end

    test "the GenServer timeout is 15 minutes for keyed breakers, :infinity otherwise" do
      {:ok, keyed} = CircuitBreaker.ensure_started(stub_key())
      {:ok, owned} = CircuitBreaker.start_link()

      assert %{idle_timeout: 900_000} = :sys.get_state(keyed)
      assert %{idle_timeout: :infinity} = :sys.get_state(owned)
    end
  end

  test "the application supervises the registry and the breaker supervisor" do
    assert is_pid(Process.whereis(Normandy.Supervisor))
    assert is_pid(Process.whereis(Normandy.Resilience.CircuitBreaker.Registry))
    assert is_pid(Process.whereis(Normandy.Resilience.CircuitBreaker.Supervisor))
  end
end
