defmodule Normandy.Behaviours.MemoryStore.InMemory do
  @moduledoc """
  Process-backed in-memory `MemoryStore`, for tests and single-node runs. One `Agent`
  holds every namespace; each operation is one Agent call, so it is atomic. The handle
  is the pid.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  alias Normandy.Behaviours.MemoryStore.Docs
  alias Normandy.Options

  @no_opts_schema NimbleOptions.new!([])

  @doc """
  Starts a fresh store and returns its handle (a pid).

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    [] = Options.validate!(opts, @no_opts_schema, {__MODULE__, :new, 1})
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    pid
  end

  @impl true
  def list(pid, ns, prefix), do: {:ok, Agent.get(pid, &Docs.list(Map.get(&1, ns, %{}), prefix))}

  @impl true
  def get(pid, ns, path), do: Agent.get(pid, &Docs.get(Map.get(&1, ns, %{}), path))

  @impl true
  def put(pid, ns, path, content, expected),
    do: update(pid, ns, &Docs.put(&1, path, content, expected))

  @impl true
  def delete(pid, ns, path, expected), do: update(pid, ns, &Docs.delete(&1, path, expected))

  @impl true
  def delete_tree(pid, ns, prefix), do: update(pid, ns, &Docs.delete_tree(&1, prefix))

  @impl true
  def rename(pid, ns, from, to), do: update(pid, ns, &Docs.rename(&1, from, to))

  @impl true
  def delete_namespace(pid, ns), do: Agent.update(pid, &Map.delete(&1, ns))

  defp update(pid, ns, fun) do
    Agent.get_and_update(pid, fn state ->
      {reply, docs} = fun.(Map.get(state, ns, %{}))
      {reply, if(docs == %{}, do: Map.delete(state, ns), else: Map.put(state, ns, docs))}
    end)
  end
end
