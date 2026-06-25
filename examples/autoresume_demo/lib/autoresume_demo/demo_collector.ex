defmodule AutoresumeDemo.DemoCollector do
  @moduledoc """
  Observer-side authoritative view of the cluster. Polls the SAME durable state
  the resume mechanism uses (Postgres turn states) plus the Horde registry (which
  node each session is on) and monitors node up/down. Pure derivation lives in
  agent_view/4 so it is unit-testable.
  """
  use GenServer
  require Logger

  alias AutoresumeDemo.Topology
  alias Normandy.Agents.Turn

  @poll_ms 500
  @max_events 50

  # ---- public API ----
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def note_kill(node), do: GenServer.cast(__MODULE__, {:note_kill, node})

  # ---- pure derivation (unit tested) ----
  @doc false
  def agent_view(sid, located, turn_state_result, prev_nodes) do
    {status, step, total, tool} = derive(turn_state_result)

    {node, status} =
      case located do
        {:located, n} -> {n, if(status == "done", do: "done", else: "running")}
        :unlocated -> {nil, if(status == "done", do: "done", else: "offline")}
      end

    resumed_from =
      case {Map.get(prev_nodes, sid), node} do
        {prev, cur} when not is_nil(prev) and not is_nil(cur) and prev != cur -> prev
        _ -> nil
      end

    %{
      id: sid,
      node: node,
      status: status,
      step: step,
      total: total,
      current_tool: tool,
      resumed_from: resumed_from
    }
  end

  defp derive({:ok, %Turn.State{status: :stopped}}), do: {"done", nil, nil, nil}
  defp derive({:ok, %Turn.State{status: :failed}}), do: {"done", nil, nil, nil}

  defp derive({:ok, %Turn.State{} = ts}) do
    total = ts.max_iterations
    step = if total, do: total - (ts.iterations_left || 0), else: nil

    tool =
      case ts.pending_calls do
        [%{name: n} | _] -> n
        _ -> Atom.to_string(ts.status)
      end

    {"active", step, total, tool}
  end

  defp derive(_), do: {"unknown", nil, nil, nil}

  # ---- GenServer ----
  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    state = %{agents: [], nodes: %{}, events: [], prev_nodes: %{}, killed: MapSet.new()}
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_cast({:note_kill, node}, state) do
    {:noreply,
     %{state | killed: MapSet.put(state.killed, node)}
     |> add_event("kill", "#{node} killed (manual)")}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {store_mod, store_handle} = Topology.store()
    {reg_mod, reg_handle} = Topology.registry_handle()

    sids =
      case store_mod.list_resumable(store_handle) do
        {:ok, list} -> list
        _ -> []
      end

    agents =
      for sid <- sids do
        located =
          case reg_mod.whereis(reg_handle, sid) do
            {:ok, pid} -> {:located, node(pid)}
            _ -> :unlocated
          end

        agent_view(sid, located, store_mod.load_turn_state(store_handle, sid), state.prev_nodes)
      end

    prev_nodes =
      for %{id: id, node: n} <- agents, not is_nil(n), into: %{}, do: {id, n}

    events =
      agents
      |> Enum.filter(& &1.resumed_from)
      |> Enum.reduce(state.events, fn a, evs ->
        prepend_event(evs, "resume", "#{a.id} resumed on #{a.node} (was #{a.resumed_from})")
      end)

    {:noreply, %{state | agents: agents, prev_nodes: prev_nodes, events: events}}
  end

  def handle_info({:nodeup, node}, state),
    do: {:noreply, state |> put_node(node, "up") |> add_event("nodeup", "#{node} up")}

  def handle_info({:nodedown, node}, state),
    do: {:noreply, state |> put_node(node, "down") |> add_event("nodedown", "#{node} down")}

  defp put_node(state, node, status),
    do: %{state | nodes: Map.put(state.nodes, node, status)}

  defp add_event(state, kind, text),
    do: %{state | events: prepend_event(state.events, kind, text)}

  defp prepend_event(events, kind, text),
    do:
      Enum.take(
        [%{ts: System.system_time(:millisecond), kind: kind, text: text} | events],
        @max_events
      )

  defp build_snapshot(state) do
    %{
      ts: System.system_time(:millisecond),
      nodes: for({name, status} <- state.nodes, do: %{name: to_string(name), status: status}),
      agents: state.agents,
      events: state.events
    }
  end
end
