defmodule Normandy.Telemetry.OperationalEventsTest do
  @moduledoc """
  Task 6.4e (TEL-16): `[:normandy, :turn, :unavailable]`,
  `[:normandy, :resume_reaper, :sweep]` and `[:normandy, :agent_pool, :checkout]`.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Coordination.AgentPool
  alias Normandy.Test.FlakyStore
  alias Normandy.Test.TelemetryCapture
  alias Normandy.TurnError

  describe "[:normandy, :turn, :unavailable]" do
    test "a failed load at start, on a request and on the retry timer, each by its phase" do
      sid = "s-unavailable-#{System.unique_integer([:positive])}"
      ref = TelemetryCapture.attach([[:normandy, :turn, :unavailable]], session_id: sid)
      store = FlakyStore.new()
      FlakyStore.down(store)

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}),
          store: {FlakyStore, store},
          registry: {Native, Native.new()}
        )

      # The load runs after start_link/1 returns (the :loading state), so wait for it.
      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{session_id: ^sid, phase: :start, reason: :store_down}},
                     1_000

      assert {:error, %TurnError{type: :session_unavailable}} = Turn.Server.run(srv, "hi")

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{session_id: ^sid, phase: :request, reason: :store_down}}

      # The first retry fires after the initial backoff (200 ms).
      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{session_id: ^sid, phase: :retry, reason: :store_down}},
                     2_000
    end
  end

  describe "[:normandy, :resume_reaper, :sweep]" do
    defmodule SweepStore do
      @moduledoc false
      alias Normandy.Agents.Turn.State
      def list_resumable(:down), do: {:error, {:store_down, "detail"}}

      def list_resumable(_handle),
        do: {:ok, ["s-start", "s-live", "s-done", "s-fault", "s-refused", "s-raise"]}

      def load_turn_state(_handle, "s-done"), do: {:ok, %State{status: :stopped}}
      def load_turn_state(_handle, "s-fault"), do: {:error, :timeout}
      def load_turn_state(_handle, _sid), do: {:ok, %State{status: :steering}}
    end

    defmodule SweepSup do
      @moduledoc false
      @behaviour Normandy.Agents.Turn.ServerSupervisor

      def start_server(_handle, opts) do
        case Keyword.fetch!(opts, :session_id) do
          "s-refused" -> {:error, :refused}
          "s-raise" -> raise ArgumentError, "sup bug"
          _sid -> {:ok, spawn(fn -> :ok end)}
        end
      end

      def stop_server(_sup, _pid), do: {:error, :not_found}
    end

    defp sweep_state(store_handle) do
      reg = Native.new()
      :ok = Native.register(reg, "s-live", self())

      %{
        store: {SweepStore, store_handle},
        registry: {Native, reg},
        supervisor: nil,
        supervisor_mod: SweepSup,
        template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, nil},
        host_server_opts: []
      }
    end

    # s-start starts; s-live (registered) and s-done (terminal) are skipped; s-fault (load
    # error), s-refused (start error) and s-raise (a raising start, caught per session) fail.
    test "one event per reap, counting what each session's start returned" do
      ref = TelemetryCapture.attach([[:normandy, :resume_reaper, :sweep]], store: SweepStore)

      assert :ok = ResumeReaper.reap(sweep_state(:up))

      assert_received {:telemetry, ^ref, measurements, %{status: :ok}}

      assert %{scanned: 6, started: 1, skipped: 2, failed: 3, duration: duration} = measurements
      assert is_integer(duration) and duration >= 0
      refute_received {:telemetry, ^ref, _, _}
    end

    test "a failed listing is a sweep with status :error and the reason reduced" do
      ref = TelemetryCapture.attach([[:normandy, :resume_reaper, :sweep]], store: SweepStore)

      assert :ok = ResumeReaper.reap(sweep_state(:down))

      assert_received {:telemetry, ^ref, %{scanned: 0, started: 0, skipped: 0, failed: 0},
                       %{status: :error, reason: {:store_down, "a string (6 bytes)"}} = meta}

      refute inspect(meta) =~ "detail"
    end
  end

  describe "[:normandy, :agent_pool, :checkout]" do
    defp pool(opts) do
      {:ok, pool} =
        AgentPool.start_link(
          Keyword.merge(
            [
              agent_config: %{client: %NormandyTest.Support.ModelMockup{}, model: "m"},
              size: 1,
              max_overflow: 0
            ],
            opts
          )
        )

      ref = TelemetryCapture.attach([[:normandy, :agent_pool, :checkout]], pool: pool)
      {pool, ref}
    end

    test "an immediate checkout, a refused one and a timed-out one" do
      {pool, ref} = pool([])

      assert {:ok, _agent} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, %{wait: 0}, %{outcome: :ok, overflow: false}}

      assert {:error, :no_agents} = AgentPool.checkout(pool, block: false)
      assert_received {:telemetry, ^ref, %{wait: 0}, %{outcome: :no_agents, overflow: false}}

      # The one agent is never returned, so this checkout can only time out.
      assert {:error, :timeout} = AgentPool.checkout(pool, timeout: 50)
      assert_received {:telemetry, ^ref, %{wait: wait}, %{outcome: :timeout, overflow: false}}
      assert wait > 0
    end

    test "a waiter served by a checkin reports its wait" do
      {pool, ref} = pool([])
      assert {:ok, agent} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, _, %{outcome: :ok}}

      waiter = Task.async(fn -> AgentPool.checkout(pool, timeout: :infinity) end)
      wait_until(fn -> AgentPool.stats(pool).waiting == 1 end)

      :ok = AgentPool.checkin(pool, agent)

      assert {:ok, ^agent} = Task.await(waiter)
      # Emitted by the pool before it replies to the waiter, which then replies here:
      # two senders, so wait for it rather than assume the order.
      assert_receive {:telemetry, ^ref, %{wait: wait}, %{outcome: :ok, overflow: false}}
      assert wait > 0
    end

    test "a checkout that starts an overflow agent says so" do
      {pool, ref} = pool(max_overflow: 1)

      assert {:ok, _first} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, _, %{outcome: :ok, overflow: false}}

      assert {:ok, _second} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, %{wait: 0}, %{outcome: :ok, overflow: true}}
    end
  end
end
