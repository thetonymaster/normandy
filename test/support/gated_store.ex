defmodule Normandy.Test.GatedStore do
  @moduledoc """
  An InMemory session store whose `history/2` waits at a gate, to prove that session
  loads run concurrently without timing anything.

      store = GatedStore.new()
      GatedStore.arrivals(store)  # history/2 calls that reached the gate so far
      GatedStore.release(store)   # lets every waiting and every later call through

  The gate is a process linked to the caller of `new/0`; a waiting `history/2` blocks in
  a call to it with no timeout.
  """
  use GenServer

  alias Normandy.Behaviours.SessionStore.InMemory

  def new do
    {:ok, gate} = GenServer.start_link(__MODULE__, :ok)
    {InMemory.new(), gate}
  end

  def arrivals({_mem, gate}), do: GenServer.call(gate, :arrivals)
  def release({_mem, gate}), do: GenServer.call(gate, :release)

  def history({mem, gate}, sid) do
    :ok = GenServer.call(gate, :pass, :infinity)
    InMemory.history(mem, sid)
  end

  def append_entry({mem, _}, sid, entry), do: InMemory.append_entry(mem, sid, entry)
  def load_turn_state({mem, _}, sid), do: InMemory.load_turn_state(mem, sid)

  def save_turn_state({mem, _}, sid, term, inflight?),
    do: InMemory.save_turn_state(mem, sid, term, inflight?)

  def load_config_template({mem, _}, sid), do: InMemory.load_config_template(mem, sid)
  def save_config_template({mem, _}, sid, tmpl), do: InMemory.save_config_template(mem, sid, tmpl)
  def list_resumable({mem, _}), do: InMemory.list_resumable(mem)

  @impl true
  def init(:ok), do: {:ok, %{arrived: 0, open?: false, waiting: []}}

  @impl true
  def handle_call(:pass, _from, %{open?: true} = state),
    do: {:reply, :ok, %{state | arrived: state.arrived + 1}}

  def handle_call(:pass, from, state),
    do: {:noreply, %{state | arrived: state.arrived + 1, waiting: [from | state.waiting]}}

  def handle_call(:arrivals, _from, state), do: {:reply, state.arrived, state}

  def handle_call(:release, _from, state) do
    Enum.each(state.waiting, &GenServer.reply(&1, :ok))
    {:reply, :ok, %{state | open?: true, waiting: []}}
  end
end
