defmodule Normandy.Behaviours.MemoryStore.Mnesia do
  @moduledoc """
  Distributed, durable `MemoryStore` over Mnesia, in an `:ordered_set` table with
  attributes `[:key, :value]`: one row per document (`{namespace, path}` → the document)
  plus one totals row per namespace (`{namespace, 0}` → `{bytes, documents}`). Every
  operation is one `:mnesia.transaction/1`. A write first takes the write lock on its
  namespace's totals row, so a namespace's writers run one at a time and compare-and-set,
  rename, delete_tree and the `put/6` limits are atomic across the cluster. `get/3` reads
  one row. `list/3`, `delete_tree/3`, `rename/4` and `delete_namespace/2` select the
  namespace's rows, which locks the whole table for the transaction (a read lock for
  `list/3`): a rename or tree delete in one namespace briefly holds writes in the others.

  The handle is the table name. Create it with `create_tables/1` (`copies: :disc_copies`
  by default, for durability; `:table` defaults to `:normandy_memory_documents`); `new/1`
  makes a uniquely named `ram_copies` table for tests. A release using this store must
  include `:mnesia` in `extra_applications`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  # :mnesia is not a declared application dependency (see the moduledoc).
  @compile {:no_warn_undefined, :mnesia}

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore.Rows
  alias Normandy.Behaviours.MnesiaSetup
  alias Normandy.Options

  @new_opts_schema NimbleOptions.new!(
                     table: [type: :atom, doc: "The table (default: a unique name)."]
                   )

  @create_tables_opts_schema NimbleOptions.new!(
                               table: [
                                 type: :atom,
                                 default: :normandy_memory_documents,
                                 doc: "The table."
                               ],
                               copies: [
                                 type: {:in, [:disc_copies, :ram_copies]},
                                 default: :disc_copies,
                                 doc: "Disc or RAM copies."
                               ],
                               nodes: [
                                 type: {:list, :atom},
                                 doc: "The nodes holding copies (default: `[node()]`)."
                               ],
                               wait_timeout: [
                                 type: :timeout,
                                 default: 30_000,
                                 doc: "How long to wait for the table to load, in ms."
                               ]
                             )

  @doc """
  Test/default handle: a fresh uniquely named `ram_copies` table on this node.

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
    table = Keyword.get(opts, :table, :"normandy_memory_#{System.unique_integer([:positive])}")
    :ok = create_tables(table: table, copies: :ram_copies)
    table
  end

  @doc """
  Creates the memory table.

  ## Options

  #{Options.docs(@create_tables_opts_schema)}
  """
  @spec create_tables(keyword()) :: :ok
  def create_tables(opts \\ []) do
    opts = Options.validate!(opts, @create_tables_opts_schema, {__MODULE__, :create_tables, 1})
    table = Keyword.fetch!(opts, :table)
    copies = Keyword.fetch!(opts, :copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    :ok = MnesiaSetup.ensure_started!()
    if copies == :disc_copies, do: MnesiaSetup.ensure_disc_schema!(nodes)
    :ok = MnesiaSetup.create_table!(table, [:key, :value], :ordered_set, copies, nodes)

    MnesiaSetup.wait_for_tables!(
      [table],
      Keyword.fetch!(opts, :wait_timeout),
      "MemoryStore.Mnesia"
    )
  end

  @impl true
  def list(table, ns, prefix),
    do: txn(fn -> Rows.list({__MODULE__.Table, {table, :read}}, ns, prefix) end)

  @impl true
  def get(table, ns, path),
    do: txn(fn -> Rows.get({__MODULE__.Table, {table, :read}}, ns, path) end)

  @impl true
  def put(table, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    write(table, :put, [ns, path, content, expected, limits])
  end

  @impl true
  def delete(table, ns, path, expected), do: write(table, :delete, [ns, path, expected])

  @impl true
  def delete_tree(table, ns, prefix), do: write(table, :delete_tree, [ns, prefix])

  @impl true
  def rename(table, ns, from, to), do: write(table, :rename, [ns, from, to])

  @impl true
  def delete_namespace(table, ns), do: write(table, :delete_namespace, [ns])

  defp write(table, fun, args),
    do: txn(fn -> apply(Rows, fun, [{__MODULE__.Table, {table, :write}} | args]) end)

  # The transaction's own value is the reply; an abort is a backend error.
  defp txn(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, reply} -> reply
      {:aborted, reason} -> {:error, reason}
    end
  end

  defmodule Table do
    @moduledoc false
    # MemoryStore.Rows' row access inside a transaction: records `{table, key, value}`,
    # every read and select under the transaction's `lock` (`:read` or `:write`).
    @behaviour Normandy.Behaviours.MemoryStore.Rows

    @compile {:no_warn_undefined, :mnesia}

    @impl true
    def fetch({table, lock}, key) do
      case :mnesia.read(table, key, lock) do
        [{^table, ^key, value}] -> {:ok, value}
        [] -> :error
      end
    end

    @impl true
    def put({table, _lock}, key, value), do: :mnesia.write(table, {table, key, value}, :write)

    @impl true
    def delete({table, _lock}, key), do: :mnesia.delete(table, key, :write)

    # A select on the namespace's document keys (the binary paths; the totals row's key
    # is the integer 0), filtered to the prefix and sorted by path: a select inside a
    # transaction does not promise key order.
    @impl true
    def range({table, lock}, {ns, prefix}) do
      spec = [{{table, {ns, :"$1"}, :"$2"}, [{:is_binary, :"$1"}], [{{:"$1", :"$2"}}]}]

      table
      |> :mnesia.select(spec, lock)
      |> Enum.filter(fn {path, _doc} -> String.starts_with?(path, prefix) end)
      |> Enum.sort_by(&elem(&1, 0))
    end
  end
end
