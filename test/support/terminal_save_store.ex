defmodule Normandy.Test.TerminalSaveStore do
  @moduledoc """
  A session store for tests that wraps another (`{module, handle}`) and refuses
  terminal turn-state saves (`:stopped`, `:failed`) while its switch is on, as a store
  in an outage does. Every other call goes to the wrapped store.

  `new/1` takes the wrapped `{module, handle}` and returns this store's handle.
  `fail_terminal/2` flips the switch. `ops/1` returns every `save_turn_state/4` and
  `append_entry/3` in call order: `{:save, status, inflight?, :ok | :refused}` and
  `{:append, role}`. A refused save writes nothing and returns `{:error, :store_down}`.
  """

  alias Normandy.Agents.Turn

  defstruct [:inner, :agent]

  @type t :: %__MODULE__{inner: {module(), term()}, agent: pid()}

  @spec new({module(), term()}) :: t()
  def new({mod, _handle} = inner) when is_atom(mod) do
    {:ok, agent} = Agent.start_link(fn -> %{fail?: false, ops: []} end)
    %__MODULE__{inner: inner, agent: agent}
  end

  @spec fail_terminal(t(), boolean()) :: :ok
  def fail_terminal(%__MODULE__{agent: agent}, fail?) when is_boolean(fail?),
    do: Agent.update(agent, &%{&1 | fail?: fail?})

  @spec ops(t()) :: [tuple()]
  def ops(%__MODULE__{agent: agent}), do: agent |> Agent.get(& &1.ops) |> Enum.reverse()

  def append_entry(%__MODULE__{inner: {mod, h}} = store, sid, entry) do
    record(store, {:append, entry.role})
    mod.append_entry(h, sid, entry)
  end

  def history(%__MODULE__{inner: {mod, h}}, sid), do: mod.history(h, sid)
  def load_turn_state(%__MODULE__{inner: {mod, h}}, sid), do: mod.load_turn_state(h, sid)
  def list_resumable(%__MODULE__{inner: {mod, h}}), do: mod.list_resumable(h)

  def save_turn_state(%__MODULE__{inner: {mod, h}} = store, sid, %Turn.State{} = ts, inflight?) do
    if ts.status in [:stopped, :failed] and Agent.get(store.agent, & &1.fail?) do
      record(store, {:save, ts.status, inflight?, :refused})
      {:error, :store_down}
    else
      result = mod.save_turn_state(h, sid, ts, inflight?)
      record(store, {:save, ts.status, inflight?, :ok})
      result
    end
  end

  defp record(%__MODULE__{agent: agent}, op),
    do: Agent.update(agent, &%{&1 | ops: [op | &1.ops]})
end
