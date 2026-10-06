defmodule Normandy.Behaviours.MemoryStore do
  @moduledoc """
  Contract for agent long-term memory: path-addressed UTF-8 documents grouped in
  namespaces, with optimistic versioning.

  A namespace is an opaque string the application chooses (per user, per tenant, per
  agent: Normandy gives it no meaning). Paths are validated by `Normandy.Tools.Memory`
  before they reach a store. Directories exist only as path prefixes.

  Semantics every impl must pass (`Normandy.MemoryStoreContract`):

    * A missing document is `:not_found`, a value. A backend failure (timeout, lost
      connection, aborted transaction) is always `{:error, reason}`, so a timeout is never
      read as "no memory yet".
    * Versions count per document from 1. `put(…, :new)` conflicts when the path exists;
      `put(…, v)` conflicts unless the stored version is `v`; `put(…, :any)` always writes.
    * `list/3` and `delete_tree/3` match the prefix itself or on a `/` boundary, so
      `/memories/a` never matches `/memories/ab`. `list/3` returns at most `list_limit/0`
      entries, sorted by path (byte order).
    * `rename/4` is atomic: a document at `from` moves alone; otherwise every document
      under `from/` moves, keeping relative paths and versions. `{:error, :exists}` when
      `to` is a document or has documents under it.
    * `delete_tree/3` and `delete_namespace/2` are atomic; `delete_namespace/2` is
      idempotent and exists for erasure (the memory tool never calls it).
    * `put/6` takes `limits`: `:max_bytes` (the namespace's total content bytes) and
      `:max_documents` (its document count), each a positive integer or `nil` (no
      limit); a key left out is `nil`. A `put` that would raise the bytes above
      `:max_bytes`, or the count above `:max_documents`, writes nothing and returns
      `{:error, {:namespace_full, :bytes | :documents, would_be}}` (bytes are checked
      first). The check and the write are one atomic step, so two writers that each fit
      alone but not together get one success and one `:namespace_full`, and the totals
      count every document (no list limit). A `put` that does not raise the bytes, or
      does not raise the count, is never refused for that limit, so a namespace already
      over a lowered limit can still shrink. A version conflict wins over a limit.
      `check_limits/3` is the rule; every backend implements `put/6` with
      `limits \\ []`, so `put/5` writes with no limit.
  """

  @type handle :: term()
  @type namespace :: String.t()
  @type path :: String.t()
  @type version :: pos_integer()
  @type entry :: %{path: path(), size: non_neg_integer(), updated_at: DateTime.t()}
  @type limits :: [max_bytes: pos_integer() | nil, max_documents: pos_integer() | nil]
  @type namespace_full :: {:namespace_full, :bytes | :documents, non_neg_integer()}

  @callback list(handle(), namespace(), prefix :: path()) :: {:ok, [entry()]} | {:error, term()}
  @callback get(handle(), namespace(), path()) ::
              {:ok, %{content: String.t(), version: version()}} | :not_found | {:error, term()}
  @callback put(
              handle(),
              namespace(),
              path(),
              content :: String.t(),
              version() | :new | :any,
              limits()
            ) ::
              {:ok, version()}
              | {:error, :conflict}
              | {:error, namespace_full()}
              | {:error, term()}
  @callback delete(handle(), namespace(), path(), version() | :any) ::
              :ok | :not_found | {:error, :conflict} | {:error, term()}
  @callback delete_tree(handle(), namespace(), prefix :: path()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback rename(handle(), namespace(), from :: path(), to :: path()) ::
              {:ok, pos_integer()} | :not_found | {:error, :exists} | {:error, term()}
  @callback delete_namespace(handle(), namespace()) :: :ok | {:error, term()}

  @list_limit 1000

  @limits_schema NimbleOptions.new!(
                   max_bytes: [
                     type: {:or, [:pos_integer, nil]},
                     default: nil,
                     doc: "The namespace's most content bytes; `nil` = no limit."
                   ],
                   max_documents: [
                     type: {:or, [:pos_integer, nil]},
                     default: nil,
                     doc: "The namespace's most documents; `nil` = no limit."
                   ]
                 )

  @doc false
  # Every backend's put/6 checks its limits here first; an unknown or mistyped key raises
  # ArgumentError naming `impl.put/6`.
  @spec validate_limits!(term(), module()) :: limits()
  def validate_limits!(limits, impl),
    do: Normandy.Options.validate!(limits, @limits_schema, {impl, :put, 6})

  @doc """
  The limits rule of `put/6`, for a write that takes a namespace from `before` to `after`
  (each `{bytes, documents}`): `{:error, {:namespace_full, :bytes, bytes}}` when it raises
  the bytes above `:max_bytes`, else `{:error, {:namespace_full, :documents, documents}}`
  when it raises the count above `:max_documents`, else `:ok`.
  """
  @spec check_limits(
          limits(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: :ok | {:error, namespace_full()}
  def check_limits(limits, {bytes_before, docs_before}, {bytes_after, docs_after}) do
    cond do
      over?(Keyword.get(limits, :max_bytes), bytes_before, bytes_after) ->
        {:error, {:namespace_full, :bytes, bytes_after}}

      over?(Keyword.get(limits, :max_documents), docs_before, docs_after) ->
        {:error, {:namespace_full, :documents, docs_after}}

      true ->
        :ok
    end
  end

  defp over?(nil, _was, _will_be), do: false
  defp over?(max, was, will_be), do: will_be > was and will_be > max

  @doc "The most entries `list/3` returns."
  @spec list_limit() :: pos_integer()
  def list_limit, do: @list_limit

  @doc "True when `path` is `prefix` or lies below it on a `/` boundary."
  @spec at_or_under?(path(), path()) :: boolean()
  def at_or_under?(path, prefix), do: path == prefix or under?(path, prefix)

  @doc "True when `path` lies strictly below `prefix` on a `/` boundary."
  @spec under?(path(), path()) :: boolean()
  def under?(path, prefix), do: String.starts_with?(path, prefix <> "/")

  @doc "Moves `path` from below `from` to the same place below `to`."
  @spec reparent(path(), path(), path()) :: path()
  def reparent(path, from, to), do: to <> String.replace_prefix(path, from, "")
end
