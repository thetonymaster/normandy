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
      case {located, status} do
        # Unreadable turn state (store error / not found) always reads offline,
        # regardless of whether the registry located the session.
        {{:located, n}, "unreadable"} -> {n, "offline"}
        {:unlocated, "unreadable"} -> {nil, "offline"}
        {{:located, n}, _} -> {n, if(status == "done", do: "done", else: "running")}
        {:unlocated, _} -> {nil, if(status == "done", do: "done", else: "offline")}
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
        _ -> nil
      end

    {"active", step, total, tool}
  end

  defp derive(_), do: {"unreadable", nil, nil, nil}

  # ---- GenServer ----
  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    state = %{agents: [], nodes: %{}, events: [], prev_nodes: %{}}
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_cast({:note_kill, node}, state) do
    {:noreply, add_event(state, "kill", "#{node} killed (manual)")}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)

    # A poll touches the Horde registry ETS table and the store — both can be
    # transiently unavailable (e.g. registry membership churns during a node
    # kill, exactly when the dashboard is polling). A single bad cycle must skip
    # and KEEP the last good state, never crash the collector (the dashboard's
    # only data source).
    new_state =
      try do
        do_poll(state)
      rescue
        _ -> state
      catch
        _, _ -> state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodeup, node}, state),
    do: {:noreply, state |> put_node(node, "up") |> add_event("nodeup", "#{node} up")}

  @impl true
  def handle_info({:nodedown, node}, state),
    do: {:noreply, state |> put_node(node, "down") |> add_event("nodedown", "#{node} down")}

  # The work of one poll cycle. Touches the registry/store and can raise on
  # transient unavailability; handle_info(:poll, _) wraps it so a bad cycle is
  # skipped (last good state retained) rather than crashing the collector.
  defp do_poll(state) do
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

    %{state | agents: agents, prev_nodes: prev_nodes, events: events}
  end

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
