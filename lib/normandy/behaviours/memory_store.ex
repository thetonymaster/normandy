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
  """

  @type handle :: term()
  @type namespace :: String.t()
  @type path :: String.t()
  @type version :: pos_integer()
  @type entry :: %{path: path(), size: non_neg_integer(), updated_at: DateTime.t()}

  @callback list(handle(), namespace(), prefix :: path()) :: {:ok, [entry()]} | {:error, term()}
  @callback get(handle(), namespace(), path()) ::
              {:ok, %{content: String.t(), version: version()}} | :not_found | {:error, term()}
  @callback put(handle(), namespace(), path(), content :: String.t(), version() | :new | :any) ::
              {:ok, version()} | {:error, :conflict} | {:error, term()}
  @callback delete(handle(), namespace(), path(), version() | :any) ::
              :ok | :not_found | {:error, :conflict} | {:error, term()}
  @callback delete_tree(handle(), namespace(), prefix :: path()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback rename(handle(), namespace(), from :: path(), to :: path()) ::
              {:ok, pos_integer()} | :not_found | {:error, :exists} | {:error, term()}
  @callback delete_namespace(handle(), namespace()) :: :ok | {:error, term()}

  @list_limit 1000

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
