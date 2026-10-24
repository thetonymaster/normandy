defmodule Normandy.Agents.Turn.SelfRegisterRaceTest do
  @moduledoc """
  Task 6.2c (July leftover): a second start for a session that a self-registering
  registry (Native) already holds stops in `init/1` with `{:already_started, winner}`,
  before it loads anything, instead of running unregistered next to the winner.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Agents.Turn.Start
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Test.StubClient

  # Native, except that whereis/2 answers :none to its first `misses` calls: a caller
  # that looked the session up before the winner registered.
  defmodule LateRegistry do
    @moduledoc false
    alias Normandy.Behaviours.SessionRegistry.Native

    def new(misses) do
      {:ok, left} = Agent.start_link(fn -> misses end)
      {Native.new(), left}
    end

    def whereis({reg, left}, sid) do
      if Agent.get_and_update(left, &{&1, max(&1 - 1, 0)}) > 0,
        do: :none,
        else: Native.whereis(reg, sid)
    end

    def register({reg, _}, sid, pid), do: Native.register(reg, sid, pid)
    def unregister({reg, _}, sid), do: Native.unregister(reg, sid)
    def child_name(_handle, _sid), do: :self_register
  end

  # register/3 answers :taken to its first call while whereis/2 finds nobody (the
  # registered server died in between); afterwards it registers for real.
  defmodule VanishingWinnerRegistry do
    @moduledoc false
    alias Normandy.Behaviours.SessionRegistry.Native

    def new do
      {:ok, taken?} = Agent.start_link(fn -> true end)
      {Native.new(), taken?}
    end

    def register({reg, taken?}, sid, pid) do
      if Agent.get_and_update(taken?, &{&1, false}),
        do: {:error, :taken},
        else: Native.register(reg, sid, pid)
    end

    def whereis({reg, _}, sid), do: Native.whereis(reg, sid)
    def unregister({reg, _}, sid), do: Native.unregister(reg, sid)
    def child_name(_handle, _sid), do: :self_register
  end

  defp opts(sid, store, registry) do
    [
      session_id: sid,
      config: BaseAgent.init(%{client: %StubClient{}, model: "m"}),
      store: store,
      registry: registry
    ]
  end

  test "a second start of a registered session returns {:error, {:already_started, winner}}" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    store = {InMemory, InMemory.new()}

    {:ok, winner} = Turn.Supervisor.start_server(sup, opts("dup", store, {Native, reg}))

    assert {:error, {:already_started, ^winner}} =
             Turn.Supervisor.start_server(sup, opts("dup", store, {Native, reg}))

    assert %{active: 1} = DynamicSupervisor.count_children(sup)
    assert Native.whereis(reg, "dup") == {:ok, winner}
  end

  test "Turn.Session.run/2 from a caller that missed the winner runs on the winner" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    {reg, _} = late = LateRegistry.new(1)
    store = {InMemory, InMemory.new()}

    {:ok, winner} = Turn.Supervisor.start_server(sup, opts("late", store, {LateRegistry, late}))

    session =
      Turn.Session.new(
        session_id: "late",
        registry: {LateRegistry, late},
        supervisor: sup,
        store: store,
        config: BaseAgent.init(%{client: %StubClient{}, model: "m"})
      )

    assert {:ok, _} = Turn.Session.run(session, %{chat_message: "hi"})

    assert %{active: 1} = DynamicSupervisor.count_children(sup)
    assert Native.whereis(reg, "late") == {:ok, winner}
    {:idle, data} = :sys.get_state(winner)
    assert length(AgentMemory.messages(data.config.memory)) == 2
  end

  test "a winner that died before the lookup is :registration_race, which Turn.Start retries" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    vanishing = VanishingWinnerRegistry.new()
    server_opts = opts("vanish", {InMemory, InMemory.new()}, {VanishingWinnerRegistry, vanishing})

    assert {:error, :registration_race} = Turn.Supervisor.start_server(sup, server_opts)

    # The first register answered :taken; the retry registers.
    vanishing2 = VanishingWinnerRegistry.new()
    registry = {VanishingWinnerRegistry, vanishing2}
    server_opts = Keyword.put(server_opts, :registry, registry)

    assert {:ok, pid} =
             Start.start_server(Turn.Supervisor, sup, server_opts, registry, "vanish")

    assert VanishingWinnerRegistry.whereis(vanishing2, "vanish") == {:ok, pid}
  end
end
