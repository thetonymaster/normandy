defmodule Normandy.Agents.Turn.ServerStartTest do
  @moduledoc """
  Task 6.2b (PERF-4): a session loads after `init/1` returns, so
  `Turn.Supervisor.start_server/2` does not wait for the store and sessions load
  concurrently. The gated test proves the concurrency; the wall-clock test is the plan's
  acceptance ("50 starts against a 200 ms store under 1 s"), with 5x headroom over the
  ~200 ms parallel floor. `async: false` keeps the 50 extra processes off schedulers that
  async suites share.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.{GatedStore, StubClient}

  # InMemory whose history/2 takes 200 ms, like a slow backend.
  defmodule SlowStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def history(mem, sid) do
      Process.sleep(200)
      InMemory.history(mem, sid)
    end

    defdelegate append_entry(mem, sid, entry), to: InMemory
    defdelegate load_turn_state(mem, sid), to: InMemory
    defdelegate save_turn_state(mem, sid, term, inflight?), to: InMemory
  end

  @sessions 50

  defp server_opts(store, reg, sid) do
    [
      session_id: sid,
      config: BaseAgent.init(%{client: %StubClient{}, model: "m"}),
      store: store,
      registry: {Native, reg}
    ]
  end

  test "50 starts return before any load finishes, and the 50 loads wait at once" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    store = GatedStore.new()

    # Each start must return while every load is held at the gate. Before Task 6.2b the
    # first start blocked in init/1 for good; the 1 s await turns that into a failure.
    pids =
      for i <- 1..@sessions do
        task =
          Task.async(fn ->
            Turn.Supervisor.start_server(sup, server_opts({GatedStore, store}, reg, "gated-#{i}"))
          end)

        {:ok, pid} = Task.await(task, 1_000)
        pid
      end

    assert wait_until(fn -> GatedStore.arrivals(store) == @sessions end)

    :ok = GatedStore.release(store)

    # :sys.get_state/1 is answered after the load event: every server is :idle.
    for pid <- pids, do: assert({:idle, _} = :sys.get_state(pid))
  end

  test "a run/2 sent during the load waits for it and is answered" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    store = GatedStore.new()

    opts = server_opts({GatedStore, store}, Native.new(), "gated-run")
    start = Task.async(fn -> Turn.Supervisor.start_server(sup, opts) end)
    {:ok, srv} = Task.await(start, 1_000)

    assert wait_until(fn -> GatedStore.arrivals(store) == 1 end)
    caller = Task.async(fn -> Turn.Server.run(srv, %{chat_message: "hi"}) end)

    # The server is blocked in its load: the call waits in its mailbox.
    assert wait_until(fn -> Process.info(srv, :message_queue_len) == {:message_queue_len, 1} end)
    :ok = GatedStore.release(store)
    assert {:ok, _} = Task.await(caller, 5_000)
  end

  test "50 concurrent starts and turns against a 200 ms store finish under 1 s" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    mem = InMemory.new()

    started = System.monotonic_time(:millisecond)

    results =
      1..@sessions
      |> Enum.map(fn i ->
        Task.async(fn ->
          {:ok, pid} =
            Turn.Supervisor.start_server(sup, server_opts({SlowStore, mem}, reg, "slow-#{i}"))

          Turn.Server.run(pid, %{chat_message: "hi"})
        end)
      end)
      |> Task.await_many(30_000)

    elapsed = System.monotonic_time(:millisecond) - started

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert elapsed < 3_000, "50 starts and turns took #{elapsed} ms (serialized: ~10 000 ms)"
  end
end
