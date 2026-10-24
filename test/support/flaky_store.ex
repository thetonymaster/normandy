defmodule Normandy.Test.FlakyStore do
  @moduledoc """
  An InMemory session store whose loads can be switched to fail, to stand in for a
  backend outage. Writes always go through.

      store = FlakyStore.new()
      FlakyStore.down(store)   # history/load_turn_state/load_config_template fail
      FlakyStore.up(store)
  """
  alias Normandy.Behaviours.SessionStore.InMemory

  def new, do: {InMemory.new(), :atomics.new(1, [])}

  def down({_mem, flag}), do: :atomics.put(flag, 1, 1)
  def up({_mem, flag}), do: :atomics.put(flag, 1, 0)

  defp down?({_mem, flag}), do: :atomics.get(flag, 1) == 1

  def history(store, sid), do: unless_down(store, fn mem -> InMemory.history(mem, sid) end)

  def load_turn_state(store, sid),
    do: unless_down(store, fn mem -> InMemory.load_turn_state(mem, sid) end)

  def load_config_template(store, sid),
    do: unless_down(store, fn mem -> InMemory.load_config_template(mem, sid) end)

  def append_entry({mem, _}, sid, entry), do: InMemory.append_entry(mem, sid, entry)

  def save_turn_state({mem, _}, sid, term, inflight?),
    do: InMemory.save_turn_state(mem, sid, term, inflight?)

  def save_config_template({mem, _}, sid, tmpl), do: InMemory.save_config_template(mem, sid, tmpl)
  def list_resumable({mem, _}), do: InMemory.list_resumable(mem)

  defp unless_down({mem, _} = store, fun),
    do: if(down?(store), do: {:error, :store_down}, else: fun.(mem))
end
