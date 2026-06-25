defmodule AutoresumeDemo.ClusterLauncher do
  @moduledoc """
  Observer-side GenServer that spawns worker :peer nodes, boots the demo app on
  each (role :worker), seeds sessions, and exposes kill/restart for the dashboard.
  """
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def nodes, do: GenServer.call(__MODULE__, :nodes)
  def kill(node), do: GenServer.call(__MODULE__, {:kill, node})
  def restart(slot), do: GenServer.call(__MODULE__, {:restart, slot})

  @impl true
  def init(:ok) do
    # Ensure this (observer) node is distributed; iex --sname observer does this.
    count = Application.get_env(:autoresume_demo, :worker_node_count, 3)
    peers = for i <- 1..count, into: %{}, do: {slot(i), start_worker(slot(i))}
    # Seed on the first live worker so Horde distributes children across workers.
    {_slot, %{node: first}} =
      Enum.find(peers, fn {_s, %{node: n}} -> n != :down end) || {nil, %{node: :down}}

    if first != :down do
      :erpc.call(first, AutoresumeDemo.Seeds, :seed, [AutoresumeDemo.Agent.topic(), 5])
    end

    {:ok, %{peers: peers}}
  end

  @impl true
  def handle_call(:nodes, _from, state) do
    list = for {slot, info} <- state.peers, do: {slot, info.node, info.pid}
    {:reply, list, state}
  end

  def handle_call({:kill, node}, _from, state) do
    entry = Enum.find(state.peers, fn {_s, info} -> info.node == node end)

    case entry do
      {slot, %{pid: pid}} when is_pid(pid) ->
        Logger.warning("ClusterLauncher: killing #{node}")
        # Notify the collector (only if it's running) so the dashboard records the
        # reason. Guarded so the launcher does not depend on Task 9 / the observer
        # role having started the collector — kill must work in the bare test too.
        if Process.whereis(AutoresumeDemo.DemoCollector),
          do: AutoresumeDemo.DemoCollector.note_kill(node)

        :peer.stop(pid)
        peers = Map.put(state.peers, slot, %{node: node, pid: :down})
        {:reply, :ok, %{state | peers: peers}}

      _ ->
        {:reply, {:error, :unknown_node}, state}
    end
  end

  def handle_call({:restart, slot}, _from, state) when is_atom(slot) do
    info = start_worker(slot)
    {:reply, :ok, %{state | peers: Map.put(state.peers, slot, info)}}
  end

  defp slot(i), do: :"worker_#{i}"

  defp start_worker(slot) do
    cookie = Atom.to_charlist(:erlang.get_cookie())

    {:ok, pid, node} =
      :peer.start_link(%{
        name: slot,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", cookie]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    # Copy the demo's runtime config + secret onto the peer BEFORE app start.
    for app <- [:autoresume_demo] do
      for {k, v} <- Application.get_all_env(app) do
        :ok = :erpc.call(node, Application, :put_env, [app, k, v])
      end
    end

    :ok = :erpc.call(node, Application, :put_env, [:autoresume_demo, :role, :worker])

    if key = System.get_env("ANTHROPIC_API_KEY"),
      do: :erpc.call(node, System, :put_env, ["ANTHROPIC_API_KEY", key])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:autoresume_demo])

    # Warm the peer BEFORE it can host any session. A freshly-booted node has not
    # lazily loaded every Normandy module, so the struct-field atoms baked into the
    # persisted ConfigTemplate are not yet interned there. Without this, the first
    # Tier-2 `binary_to_term(blob, [:safe])` reconstruct on this peer raises :badarg.
    # Must run on EVERY worker (not just the seed node): Horde may place a child here.
    :ok = :erpc.call(node, AutoresumeDemo.Agent, :warmup, [])

    Logger.info("ClusterLauncher: worker up #{node}")
    %{node: node, pid: pid}
  end
end
