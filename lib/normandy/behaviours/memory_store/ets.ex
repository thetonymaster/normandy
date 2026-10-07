defmodule Normandy.Behaviours.MemoryStore.ETS do
  @moduledoc """
  ETS-backed `MemoryStore`, in-node. One row per document, `{{namespace, path}, doc}`,
  plus one totals row per namespace, `{{namespace, 0}, {bytes, documents}}`, in an
  `:ordered_set`, so an operation costs what it touches, not the namespace's size. A
  GenServer owns the `:protected` table and runs every write and every `list/3`, so
  compare-and-set, rename and the `put/6` limits are atomic and a listing never sees half
  of a rename. `get/3` reads the table directly. The handle is `{pid, table}`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  use GenServer

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore.Rows
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
  def list({pid, _table}, ns, prefix), do: GenServer.call(pid, {:rows, :list, [ns, prefix]})

  @impl Normandy.Behaviours.MemoryStore
  def get({_pid, table}, ns, path), do: Rows.get({__MODULE__.Table, table}, ns, path)

  @impl Normandy.Behaviours.MemoryStore
  def put({pid, _table}, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    GenServer.call(pid, {:rows, :put, [ns, path, content, expected, limits]})
  end

  @impl Normandy.Behaviours.MemoryStore
  def delete({pid, _table}, ns, path, expected),
    do: GenServer.call(pid, {:rows, :delete, [ns, path, expected]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_tree({pid, _table}, ns, prefix),
    do: GenServer.call(pid, {:rows, :delete_tree, [ns, prefix]})

  @impl Normandy.Behaviours.MemoryStore
  def rename({pid, _table}, ns, from, to),
    do: GenServer.call(pid, {:rows, :rename, [ns, from, to]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_namespace({pid, _table}, ns),
    do: GenServer.call(pid, {:rows, :delete_namespace, [ns]})

  @impl GenServer
  def init(_opts),
    do:
      {:ok, :ets.new(:normandy_memory_store, [:ordered_set, :protected, read_concurrency: true])}

  @impl GenServer
  def handle_call(:table, _from, table), do: {:reply, table, table}

  def handle_call({:rows, fun, args}, _from, table),
    do: {:reply, apply(Rows, fun, [{__MODULE__.Table, table} | args]), table}

  defmodule Table do
    @moduledoc false
    # MemoryStore.Rows' row access over the store's ordered_set: `{key, value}` rows.
    @behaviour Normandy.Behaviours.MemoryStore.Rows

    @impl true
    def fetch(table, key) do
      case :ets.lookup(table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :error
      end
    end

    @impl true
    def put(table, key, value) do
      true = :ets.insert(table, {key, value})
      :ok
    end

    @impl true
    def delete(table, key) do
      true = :ets.delete(table, key)
      :ok
    end

    # Walks the ordered keys from `{ns, prefix}` and stops at the first key that is not
    # a path of `ns` starting with `prefix`: the cost is the rows in range, not the
    # namespace. `{ns, 0}` sorts before `{ns, prefix}`, so the totals row is never seen.
    @impl true
    def range(table, {ns, prefix} = first) do
      acc =
        case :ets.lookup(table, first) do
          [{^first, doc}] -> [{prefix, doc}]
          [] -> []
        end

      walk(table, :ets.next(table, first), ns, prefix, acc)
    end

    defp walk(table, {ns, path} = key, ns, prefix, acc) when is_binary(path) do
      if String.starts_with?(path, prefix) do
        [{^key, doc}] = :ets.lookup(table, key)
        walk(table, :ets.next(table, key), ns, prefix, [{path, doc} | acc])
      else
        Enum.reverse(acc)
      end
    end

    defp walk(_table, _end_or_other_namespace, _ns, _prefix, acc), do: Enum.reverse(acc)
  end
end
