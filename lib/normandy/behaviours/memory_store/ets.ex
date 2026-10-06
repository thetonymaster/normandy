defmodule Normandy.Behaviours.MemoryStore.ETS do
  @moduledoc """
  ETS-backed `MemoryStore`, in-node. One row per namespace, `{namespace, docs}`. A
  GenServer owns the `:protected` table and serializes every write, so compare-and-set
  and rename are atomic; reads go to the table directly. The handle is `{pid, table}`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  use GenServer

  alias Normandy.Behaviours.MemoryStore.Docs
  alias Normandy.Options

  @no_opts_schema NimbleOptions.new!([])

  @doc """
  Starts a fresh store; returns its handle `{owner_pid, table}`.

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec new(keyword()) :: {pid(), :ets.tid()}
  def new(opts \\ []) do
    [] = Options.validate!(opts, @no_opts_schema, {__MODULE__, :new, 1})
    {:ok, pid} = GenServer.start_link(__MODULE__, [])
    {pid, GenServer.call(pid, :table)}
  end

  @impl Normandy.Behaviours.MemoryStore
  def list({_pid, table}, ns, prefix), do: {:ok, Docs.list(docs(table, ns), prefix)}

  @impl Normandy.Behaviours.MemoryStore
  def get({_pid, table}, ns, path), do: Docs.get(docs(table, ns), path)

  @impl Normandy.Behaviours.MemoryStore
  def put({pid, _}, ns, path, content, expected),
    do: GenServer.call(pid, {:apply, ns, :put, [path, content, expected]})

  @impl Normandy.Behaviours.MemoryStore
  def delete({pid, _}, ns, path, expected),
    do: GenServer.call(pid, {:apply, ns, :delete, [path, expected]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_tree({pid, _}, ns, prefix),
    do: GenServer.call(pid, {:apply, ns, :delete_tree, [prefix]})

  @impl Normandy.Behaviours.MemoryStore
  def rename({pid, _}, ns, from, to), do: GenServer.call(pid, {:apply, ns, :rename, [from, to]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_namespace({pid, _}, ns), do: GenServer.call(pid, {:delete_namespace, ns})

  @impl GenServer
  def init(_opts),
    do: {:ok, :ets.new(:normandy_memory_store, [:set, :protected, read_concurrency: true])}

  @impl GenServer
  def handle_call(:table, _from, table), do: {:reply, table, table}

  def handle_call({:apply, ns, fun, args}, _from, table) do
    {reply, docs} = apply(Docs, fun, [docs(table, ns) | args])
    if docs == %{}, do: :ets.delete(table, ns), else: :ets.insert(table, {ns, docs})
    {:reply, reply, table}
  end

  def handle_call({:delete_namespace, ns}, _from, table) do
    :ets.delete(table, ns)
    {:reply, :ok, table}
  end

  defp docs(table, ns) do
    case :ets.lookup(table, ns) do
      [{^ns, docs}] -> docs
      [] -> %{}
    end
  end
end
