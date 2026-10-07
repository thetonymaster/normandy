defmodule Normandy.Behaviours.MemoryStore.Rows do
  @moduledoc false
  # The MemoryStore rules over a table with one row per document and one totals row per
  # namespace:
  #
  #   * `{namespace, path}` → `%{content, version, updated_at}`
  #   * `{namespace, 0}`    → `{bytes, documents}` (absent while the namespace is empty)
  #
  # The integer 0 sorts before every binary path, so in an ordered table a namespace's
  # rows stay contiguous and its totals row comes first. ETS and Mnesia implement the
  # row access below. The caller makes each function here atomic: the ETS owner runs it
  # in its single process, Mnesia inside one transaction. Every write reads the totals
  # row first; on Mnesia that takes the namespace's write lock, so a namespace's writers
  # run one at a time, as with the old one-row-per-namespace layout. The functions that
  # read a range (list, rename, delete_tree, delete_namespace) are not per namespace on
  # Mnesia: its range/2 is a select, which locks the whole table (see
  # MemoryStore.Mnesia.Table.range/2).

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore.Docs

  @typedoc "A row-access module and its argument (the ETS table, or Mnesia's `{table, lock}`)."
  @type access :: {module(), term()}
  @type key :: {MemoryStore.namespace(), MemoryStore.path() | 0}

  @doc "The value under `key`, or `:error`."
  @callback fetch(arg :: term(), key()) :: {:ok, term()} | :error
  @doc "Writes `value` under `key`."
  @callback put(arg :: term(), key(), value :: term()) :: :ok
  @doc "Removes `key`; a missing key is `:ok`."
  @callback delete(arg :: term(), key()) :: :ok
  @doc "The document rows of `namespace` whose path starts with `prefix` (bytes), by path."
  @callback range(arg :: term(), {MemoryStore.namespace(), MemoryStore.path()}) ::
              [{MemoryStore.path(), map()}]

  @spec get(access(), MemoryStore.namespace(), MemoryStore.path()) ::
          {:ok, %{content: String.t(), version: pos_integer()}} | :not_found
  def get(access, ns, path) do
    case doc(access, ns, path) do
      nil -> :not_found
      d -> {:ok, %{content: d.content, version: d.version}}
    end
  end

  @spec list(access(), MemoryStore.namespace(), MemoryStore.path()) ::
          {:ok, [MemoryStore.entry()]}
  def list(access, ns, prefix) do
    entries =
      access
      |> under(ns, prefix, &MemoryStore.at_or_under?/2)
      |> Enum.take(MemoryStore.list_limit())
      |> Enum.map(fn {path, d} ->
        %{path: path, size: byte_size(d.content), updated_at: d.updated_at}
      end)

    {:ok, entries}
  end

  @spec put(
          access(),
          MemoryStore.namespace(),
          MemoryStore.path(),
          String.t(),
          pos_integer() | :new | :any,
          MemoryStore.limits()
        ) :: {:ok, pos_integer()} | {:error, :conflict | MemoryStore.namespace_full()}
  def put({mod, arg} = access, ns, path, content, expected, limits) do
    before = totals(access, ns)
    current = doc(access, ns, path)

    with {:ok, version} <- Docs.next_version(current && current.version, expected),
         totals = after_put(before, current, content),
         :ok <- MemoryStore.check_limits(limits, before, totals) do
      doc = %{content: content, version: version, updated_at: DateTime.utc_now()}
      :ok = mod.put(arg, {ns, path}, doc)
      :ok = put_totals(access, ns, totals)
      {:ok, version}
    end
  end

  @spec delete(access(), MemoryStore.namespace(), MemoryStore.path(), pos_integer() | :any) ::
          :ok | :not_found | {:error, :conflict}
  def delete(access, ns, path, expected) do
    before = totals(access, ns)

    case {doc(access, ns, path), expected} do
      {nil, _expected} ->
        :not_found

      {%{version: v} = d, expected} when expected == :any or expected == v ->
        1 = drop(access, ns, [{path, d}], before)
        :ok

      _stale ->
        {:error, :conflict}
    end
  end

  @spec delete_tree(access(), MemoryStore.namespace(), MemoryStore.path()) ::
          {:ok, non_neg_integer()}
  def delete_tree(access, ns, prefix) do
    before = totals(access, ns)
    {:ok, drop(access, ns, under(access, ns, prefix, &MemoryStore.at_or_under?/2), before)}
  end

  # A rename moves rows but keeps the namespace's totals; the totals row is still read
  # first, for its lock.
  @spec rename(access(), MemoryStore.namespace(), MemoryStore.path(), MemoryStore.path()) ::
          {:ok, pos_integer()} | :not_found | {:error, :exists}
  def rename({mod, arg} = access, ns, from, to) do
    _totals = totals(access, ns)

    moving =
      case doc(access, ns, from) do
        nil -> under(access, ns, from, &MemoryStore.under?/2)
        d -> [{from, d}]
      end

    cond do
      moving == [] ->
        :not_found

      under(access, ns, to, &MemoryStore.at_or_under?/2) != [] ->
        {:error, :exists}

      true ->
        # Destination rows first: a reader outside the table's owner (ETS `get/3`) sees
        # the document at its old path, its new path or both, never neither. No
        # destination path is a source path (the destination was empty above).
        Enum.each(moving, fn {path, d} ->
          :ok = mod.put(arg, {ns, MemoryStore.reparent(path, from, to)}, d)
        end)

        Enum.each(moving, fn {path, _d} -> :ok = mod.delete(arg, {ns, path}) end)

        {:ok, length(moving)}
    end
  end

  @spec delete_namespace(access(), MemoryStore.namespace()) :: :ok
  def delete_namespace({mod, arg} = access, ns) do
    _totals = totals(access, ns)
    Enum.each(mod.range(arg, {ns, ""}), fn {path, _d} -> :ok = mod.delete(arg, {ns, path}) end)
    mod.delete(arg, {ns, 0})
  end

  defp doc({mod, arg}, ns, path) do
    case mod.fetch(arg, {ns, path}) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp totals({mod, arg}, ns) do
    case mod.fetch(arg, {ns, 0}) do
      {:ok, {bytes, count}} -> {bytes, count}
      :error -> {0, 0}
    end
  end

  defp put_totals({mod, arg}, ns, {0, 0}), do: mod.delete(arg, {ns, 0})
  defp put_totals({mod, arg}, ns, totals), do: mod.put(arg, {ns, 0}, totals)

  defp under({mod, arg}, ns, prefix, keep?) do
    arg
    |> mod.range({ns, prefix})
    |> Enum.filter(fn {path, _d} -> keep?.(path, prefix) end)
  end

  # Removes `rows` and their bytes and count from the totals; returns how many.
  defp drop({mod, arg} = access, ns, rows, {bytes, count}) do
    Enum.each(rows, fn {path, _d} -> :ok = mod.delete(arg, {ns, path}) end)
    gone = Enum.reduce(rows, 0, fn {_path, d}, sum -> sum + byte_size(d.content) end)
    :ok = put_totals(access, ns, {bytes - gone, count - length(rows)})
    length(rows)
  end

  defp after_put({bytes, count}, nil, content), do: {bytes + byte_size(content), count + 1}

  defp after_put({bytes, count}, %{content: old}, content),
    do: {bytes - byte_size(old) + byte_size(content), count}
end
