defmodule Normandy.Behaviours.MemoryStore.Mnesia do
  @moduledoc """
  Distributed, durable `MemoryStore` over Mnesia. One row per namespace,
  `{table, namespace, docs}`; every operation is one `:mnesia.transaction/1` that takes a
  write lock on the namespace row, so compare-and-set, rename and delete_tree are atomic
  across the cluster.

  The handle is the table name. Create it with `create_tables/1` (`copies: :disc_copies`
  by default, for durability; `:table` defaults to `:normandy_memory_documents`); `new/1`
  makes a uniquely named `ram_copies` table for tests. A release using this store must
  include `:mnesia` in `extra_applications`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  # :mnesia is not a declared application dependency (see the moduledoc).
  @compile {:no_warn_undefined, :mnesia}

  alias Normandy.Behaviours.MemoryStore.Docs
  alias Normandy.Behaviours.MnesiaSetup

  @doc "Test/default handle: a fresh uniquely named `ram_copies` table on this node."
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    table = Keyword.get(opts, :table, :"normandy_memory_#{System.unique_integer([:positive])}")
    :ok = create_tables(table: table, copies: :ram_copies)
    table
  end

  @doc """
  Creates the memory table. Opts: `:table` (default `:normandy_memory_documents`),
  `:copies` (`:disc_copies` default | `:ram_copies`), `:nodes` (default `[node()]`),
  `:wait_timeout` (ms, default 30_000).
  """
  @spec create_tables(keyword()) :: :ok
  def create_tables(opts \\ []) do
    table = Keyword.get(opts, :table, :normandy_memory_documents)
    copies = Keyword.get(opts, :copies, :disc_copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    :ok = MnesiaSetup.ensure_started!()
    if copies == :disc_copies, do: MnesiaSetup.ensure_disc_schema!(nodes)
    :ok = MnesiaSetup.create_table!(table, [:namespace, :docs], copies, nodes)

    MnesiaSetup.wait_for_tables!(
      [table],
      Keyword.get(opts, :wait_timeout, 30_000),
      "MemoryStore.Mnesia"
    )
  end

  @impl true
  def list(table, ns, prefix), do: read(table, ns, &{:ok, Docs.list(&1, prefix)})

  @impl true
  def get(table, ns, path), do: read(table, ns, &Docs.get(&1, path))

  @impl true
  def put(table, ns, path, content, expected),
    do: update(table, ns, &Docs.put(&1, path, content, expected))

  @impl true
  def delete(table, ns, path, expected), do: update(table, ns, &Docs.delete(&1, path, expected))

  @impl true
  def delete_tree(table, ns, prefix), do: update(table, ns, &Docs.delete_tree(&1, prefix))

  @impl true
  def rename(table, ns, from, to), do: update(table, ns, &Docs.rename(&1, from, to))

  @impl true
  def delete_namespace(table, ns), do: txn(fn -> :mnesia.delete({table, ns}) end)

  defp read(table, ns, fun), do: txn(fn -> fun.(docs(table, ns, :read)) end)

  defp update(table, ns, fun) do
    txn(fn ->
      {reply, docs} = fun.(docs(table, ns, :write))
      if docs == %{}, do: :mnesia.delete({table, ns}), else: :mnesia.write({table, ns, docs})
      reply
    end)
  end

  defp docs(table, ns, lock) do
    case :mnesia.read(table, ns, lock) do
      [{^table, ^ns, docs}] -> docs
      [] -> %{}
    end
  end

  # The transaction's own value is the reply; an abort is a backend error.
  defp txn(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, reply} -> reply
      {:aborted, reason} -> {:error, reason}
    end
  end
end
