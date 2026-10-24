defmodule Normandy.Agents.Turn.SessionPassivationTest do
  @moduledoc """
  Task 6.2d (July leftover, H8): a `Turn.Session.run/2` whose call reaches a server that
  passivated (stopped `{:shutdown, :passivated}`, or already gone) routes the turn to a
  fresh server instead of exiting the caller. Any other stop, `:normal` included,
  propagates. Each registry below hands out a scripted pid first, so every case is
  deterministic.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.StubClient
  alias Normandy.TurnError

  # Native, except that whereis/2 first answers with the scripted pids, in order (a
  # pid, or :always to answer it forever), and counts its calls.
  defmodule ScriptedRegistry do
    @moduledoc false
    alias Normandy.Behaviours.SessionRegistry.Native

    def new(script) do
      {:ok, agent} = Agent.start_link(fn -> %{script: script, calls: 0} end)
      {Native.new(), agent}
    end

    def calls({_reg, agent}), do: Agent.get(agent, & &1.calls)

    def whereis({reg, agent}, sid) do
      Agent.get_and_update(agent, fn
        %{script: [{:always, pid}]} = s -> {{:ok, pid}, %{s | calls: s.calls + 1}}
        %{script: [pid | rest]} = s -> {{:ok, pid}, %{s | script: rest, calls: s.calls + 1}}
        %{script: []} = s -> {:native, %{s | calls: s.calls + 1}}
      end)
      |> case do
        :native -> Native.whereis(reg, sid)
        found -> found
      end
    end

    def register({reg, _}, sid, pid), do: Native.register(reg, sid, pid)
    def unregister({reg, _}, sid), do: Native.unregister(reg, sid)
    def child_name(_handle, _sid), do: :self_register
  end

  # Answers a turn call by stopping with `reason`, without replying: the caller's call
  # exits with {reason, {:gen_statem, :call, _}}, as it does against a server that
  # stopped with the call in its mailbox.
  defmodule StopsOnCall do
    @moduledoc false
    use GenServer

    def start(reason), do: GenServer.start(__MODULE__, reason)

    @impl true
    def init(reason), do: {:ok, reason}

    @impl true
    def handle_call(_request, _from, reason), do: {:stop, reason, reason}
  end

  defp session(registry) do
    {:ok, sup} = Turn.Supervisor.start_link([])

    Turn.Session.new(
      session_id: "s-#{System.unique_integer([:positive])}",
      registry: registry,
      supervisor: sup,
      store: {InMemory, InMemory.new()},
      config: BaseAgent.init(%{client: %StubClient{}, model: "m"})
    )
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    pid
  end

  test "a call to a server that is already gone is routed to a fresh server" do
    registry = ScriptedRegistry.new([dead_pid()])

    assert {:ok, _} =
             Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})

    assert ScriptedRegistry.calls(registry) == 2
  end

  test "a call that a passivating server never answered is routed to a fresh server" do
    {:ok, passivating} = StopsOnCall.start({:shutdown, :passivated})
    registry = ScriptedRegistry.new([passivating])

    assert {:ok, _} =
             Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})

    refute Process.alive?(passivating)
    assert ScriptedRegistry.calls(registry) == 2
  end

  test "after three servers that passivated, run/2 returns :passivated" do
    registry = ScriptedRegistry.new([{:always, dead_pid()}])

    assert {:error, %TurnError{type: :session_unavailable, reason: :passivated}} =
             Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})

    assert ScriptedRegistry.calls(registry) == 3
  end

  # :normal is not passivation (H8): a host's :gen_statem.stop/1 mid-turn exits the
  # call :normal after the turn may have run tools.
  for reason <- [:normal, :boom] do
    test "a server that stops #{inspect(reason)} under the call propagates: the turn may have run" do
      {:ok, stopping} = StopsOnCall.start(unquote(reason))
      registry = ScriptedRegistry.new([stopping])

      assert {unquote(reason), {:gen_statem, :call, _}} =
               catch_exit(
                 Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})
               )

      assert ScriptedRegistry.calls(registry) == 1
    end
  end
end
