if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Normandy.Behaviours.MemoryStore.Postgres do
    @moduledoc """
    Durable, cluster-shared `MemoryStore` over Postgres. The handle is the host's Ecto
    Repo module; run `Normandy.Behaviours.MemoryStore.Postgres.Migration` from a host
    migration.

    Every write (`put`, `delete`, `delete_tree`, `rename`, `delete_namespace`) is one
    transaction that first locks the namespace's row in `normandy_memory_namespaces`,
    which tracks the namespace's content bytes and document count for `put/6`'s limits.
    So the writers of one namespace run one at a time, and compare-and-set, the limits
    check and the counters change atomically with the document. `rename/4` also locks the
    moving rows `FOR UPDATE`. Prefixes match with `starts_with/2` (nothing to escape);
    listing orders by `path COLLATE "C"` (byte order).

    The counters are kept by these functions only: a row written to
    `normandy_memory_documents` by other SQL is not counted, and the limits then count
    wrong for its namespace.
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore
    alias Normandy.Behaviours.MemoryStore.Docs

    @table "normandy_memory_documents"
    @namespaces "normandy_memory_namespaces"

    @doc "Test/default handle: the Repo configured for :normandy."
    @spec new() :: module()
    def new, do: hd(Application.fetch_env!(:normandy, :ecto_repos))

    @impl true
    def list(repo, ns, prefix) do
      backend(fn ->
        sql = """
        SELECT path, octet_length(content), updated_at FROM #{@table}
        WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3))
        ORDER BY path COLLATE "C" LIMIT $4
        """

        with {:ok, %{rows: rows}} <-
               repo.query(sql, [ns, prefix, prefix <> "/", MemoryStore.list_limit()]) do
          {:ok,
           Enum.map(rows, fn [path, size, at] ->
             %{path: path, size: size, updated_at: utc(at)}
           end)}
        end
      end)
    end

    @impl true
    def get(repo, ns, path) do
      backend(fn ->
        case repo.query(
               "SELECT content, version FROM #{@table} WHERE namespace = $1 AND path = $2",
               [
                 ns,
                 path
               ]
             ) do
          {:ok, %{rows: [[content, version]]}} -> {:ok, %{content: content, version: version}}
          {:ok, %{rows: []}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def put(repo, ns, path, content, expected, limits \\ []) do
      limits = MemoryStore.validate_limits!(limits, __MODULE__)

      in_transaction(repo, fn ->
        {bytes, documents} = lock_totals(repo, ns)
        {version, size} = current(repo, ns, path)
        totals = {bytes - size + byte_size(content), documents + if(version, do: 0, else: 1)}

        with {:ok, next} <- Docs.next_version(version, expected),
             :ok <- MemoryStore.check_limits(limits, {bytes, documents}, totals) do
          write(repo, ns, path, content, next)
          set_totals(repo, ns, totals)
          {:ok, next}
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end

    @impl true
    def delete(repo, ns, path, :any) do
      in_transaction(repo, fn ->
        totals = lock_totals(repo, ns)

        case repo.query!(
               "DELETE FROM #{@table} WHERE namespace = $1 AND path = $2 RETURNING octet_length(content)",
               [ns, path]
             ) do
          %{rows: [[size]]} -> release(repo, ns, totals, [size])
          %{rows: []} -> :not_found
        end
      end)
    end

    def delete(repo, ns, path, version) when is_integer(version) do
      # The outer SELECT sees the snapshot before the CTE's DELETE, so its count tells a
      # stale version (conflict) from a missing document; `size` is the deleted bytes.
      sql = """
      WITH d AS (DELETE FROM #{@table} WHERE namespace = $1 AND path = $2 AND version = $3 RETURNING octet_length(content) AS size)
      SELECT (SELECT size FROM d), (SELECT count(*) FROM #{@table} WHERE namespace = $1 AND path = $2)
      """

      in_transaction(repo, fn ->
        totals = lock_totals(repo, ns)

        case repo.query!(sql, [ns, path, version]) do
          %{rows: [[nil, 1]]} -> {:error, :conflict}
          %{rows: [[nil, 0]]} -> :not_found
          %{rows: [[size, _]]} -> release(repo, ns, totals, [size])
        end
      end)
    end

    @impl true
    def delete_tree(repo, ns, prefix) do
      sql =
        "DELETE FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3)) RETURNING octet_length(content)"

      in_transaction(repo, fn ->
        totals = lock_totals(repo, ns)
        %{rows: rows} = repo.query!(sql, [ns, prefix, prefix <> "/"])
        sizes = List.flatten(rows)
        if sizes != [], do: release(repo, ns, totals, sizes)
        {:ok, length(sizes)}
      end)
    end

    @impl true
    def rename(repo, ns, from, to) do
      backend(fn ->
        try do
          repo.transaction(fn -> rename_in_transaction(repo, ns, from, to) end)
          |> case do
            {:ok, reply} -> reply
            {:error, _} = error -> error
          end
        rescue
          # A concurrent put(:new) or rename into `to` created the destination after
          # destination_taken?/3 looked; the UPDATE lost the unique-key race. The
          # transaction has already rolled back.
          e in Postgrex.Error ->
            case e do
              %{postgres: %{code: :unique_violation}} -> {:error, :exists}
              _ -> reraise e, __STACKTRACE__
            end
        end
      end)
    end

    defp rename_in_transaction(repo, ns, from, to) do
      # Moves documents within the namespace: bytes and count stay, but the counter row
      # lock keeps rename and the other writers in one order.
      _totals = lock_totals(repo, ns)
      moving = lock_moving(repo, ns, from)

      cond do
        moving == [] ->
          :not_found

        destination_taken?(repo, ns, to) ->
          {:error, :exists}

        true ->
          %{num_rows: n} =
            repo.query!(
              "UPDATE #{@table} SET path = $3::text || substr(path, length($2::text) + 1) WHERE namespace = $1 AND path = ANY($4::text[])",
              [ns, from, to, moving]
            )

          {:ok, n}
      end
    end

    @impl true
    def delete_namespace(repo, ns) do
      # Lock (creating if absent) the counter row first: that waits for the namespace's
      # writers in flight, and a writer arriving later waits for this transaction. Then
      # the documents go, then the counter row.
      in_transaction(repo, fn ->
        _totals = lock_totals(repo, ns)
        repo.query!("DELETE FROM #{@table} WHERE namespace = $1", [ns])
        repo.query!("DELETE FROM #{@namespaces} WHERE namespace = $1", [ns])
        :ok
      end)
    end

    # One transaction per write. `repo.rollback(reason)` makes the reply
    # `{:error, reason}`; a raised Postgrex error rolls back and is backend/1's.
    defp in_transaction(repo, fun) do
      backend(fn ->
        case repo.transaction(fun) do
          {:ok, reply} -> reply
          {:error, _reason} = error -> error
        end
      end)
    end

    # Every write locks the namespace's counter row first (creating it on the first write),
    # so the namespace's writers take their locks in one order and the counters match the
    # documents. Returns {bytes, documents} as of the lock.
    defp lock_totals(repo, ns) do
      %{rows: [[bytes, documents]]} =
        repo.query!(
          """
          INSERT INTO #{@namespaces} (namespace, bytes, documents) VALUES ($1, 0, 0)
          ON CONFLICT (namespace) DO UPDATE SET bytes = #{@namespaces}.bytes
          RETURNING bytes, documents
          """,
          [ns]
        )

      {bytes, documents}
    end

    defp set_totals(repo, ns, {bytes, documents}) do
      repo.query!(
        "UPDATE #{@namespaces} SET bytes = $2, documents = $3 WHERE namespace = $1",
        [ns, bytes, documents]
      )
    end

    # Takes the deleted documents' sizes off the totals; the reply of a delete.
    defp release(repo, ns, {bytes, documents}, sizes) do
      set_totals(repo, ns, {bytes - Enum.sum(sizes), documents - length(sizes)})
      :ok
    end

    # {version, content bytes} of the document at `path`, or {nil, 0}.
    defp current(repo, ns, path) do
      case repo.query!(
             "SELECT version, octet_length(content) FROM #{@table} WHERE namespace = $1 AND path = $2",
             [ns, path]
           ) do
        %{rows: [[version, size]]} -> {version, size}
        %{rows: []} -> {nil, 0}
      end
    end

    defp write(repo, ns, path, content, version) do
      repo.query!(
        """
        INSERT INTO #{@table} (namespace, path, content, version, updated_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (namespace, path) DO UPDATE
          SET content = EXCLUDED.content, version = EXCLUDED.version, updated_at = EXCLUDED.updated_at
        """,
        [ns, path, content, version, now()]
      )
    end

    # A document at `from` moves alone; otherwise everything under `from/`.
    defp lock_moving(repo, ns, from) do
      %{rows: own} =
        repo.query!("SELECT path FROM #{@table} WHERE namespace = $1 AND path = $2 FOR UPDATE", [
          ns,
          from
        ])

      case own do
        [[path]] ->
          [path]

        [] ->
          # ORDER BY: overlapping directory renames must take row locks in the same
          # order, or they can deadlock.
          %{rows: rows} =
            repo.query!(
              "SELECT path FROM #{@table} WHERE namespace = $1 AND starts_with(path, $2) ORDER BY path COLLATE \"C\" FOR UPDATE",
              [ns, from <> "/"]
            )

          List.flatten(rows)
      end
    end

    defp destination_taken?(repo, ns, to) do
      %{rows: rows} =
        repo.query!(
          "SELECT 1 FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3)) LIMIT 1",
          [ns, to, to <> "/"]
        )

      rows != []
    end

    defp now, do: NaiveDateTime.utc_now()
    defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

    # A dropped connection or a raised Postgrex error is a backend error, never :not_found.
    defp backend(fun) do
      fun.()
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, e}
    end
  end
end
