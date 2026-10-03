if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Normandy.Behaviours.MemoryStore.Postgres do
    @moduledoc """
    Durable, cluster-shared `MemoryStore` over Postgres. The handle is the host's Ecto
    Repo module; run `Normandy.Behaviours.MemoryStore.Postgres.Migration` from a host
    migration.

    Compare-and-set is a conditional `UPDATE … WHERE version = $v`; `:new` is
    `INSERT … ON CONFLICT DO NOTHING`. `rename/4` locks the moving rows `FOR UPDATE` in
    one transaction. Prefixes match with `starts_with/2` (nothing to escape); listing
    orders by `path COLLATE "C"` (byte order).
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore

    @table "normandy_memory_documents"

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
    def put(repo, ns, path, content, :new) do
      sql = "INSERT INTO #{@table} VALUES ($1, $2, $3, 1, $4) ON CONFLICT DO NOTHING"
      backend(fn -> repo.query(sql, [ns, path, content, now()]) |> one_row(1) end)
    end

    def put(repo, ns, path, content, :any) do
      sql = """
      INSERT INTO #{@table} VALUES ($1, $2, $3, 1, $4)
      ON CONFLICT (namespace, path) DO UPDATE
        SET content = EXCLUDED.content, version = #{@table}.version + 1, updated_at = EXCLUDED.updated_at
      RETURNING version
      """

      backend(fn -> repo.query(sql, [ns, path, content, now()]) |> returned_version() end)
    end

    def put(repo, ns, path, content, version) when is_integer(version) do
      sql = """
      UPDATE #{@table} SET content = $3, version = version + 1, updated_at = $5
      WHERE namespace = $1 AND path = $2 AND version = $4
      RETURNING version
      """

      backend(fn ->
        repo.query(sql, [ns, path, content, version, now()]) |> returned_version()
      end)
    end

    @impl true
    def delete(repo, ns, path, :any) do
      backend(fn ->
        case repo.query("DELETE FROM #{@table} WHERE namespace = $1 AND path = $2", [ns, path]) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, %{num_rows: 0}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    def delete(repo, ns, path, version) when is_integer(version) do
      # The outer SELECT sees the snapshot before the CTE's DELETE, so `existed` tells a
      # stale version (conflict) from a missing document.
      sql = """
      WITH d AS (DELETE FROM #{@table} WHERE namespace = $1 AND path = $2 AND version = $3 RETURNING 1)
      SELECT (SELECT count(*) FROM d), (SELECT count(*) FROM #{@table} WHERE namespace = $1 AND path = $2)
      """

      backend(fn ->
        case repo.query(sql, [ns, path, version]) do
          {:ok, %{rows: [[1, _]]}} -> :ok
          {:ok, %{rows: [[0, 1]]}} -> {:error, :conflict}
          {:ok, %{rows: [[0, 0]]}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def delete_tree(repo, ns, prefix) do
      sql = "DELETE FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3))"

      backend(fn ->
        with {:ok, %{num_rows: n}} <- repo.query(sql, [ns, prefix, prefix <> "/"]), do: {:ok, n}
      end)
    end

    @impl true
    def rename(repo, ns, from, to) do
      backend(fn ->
        repo.transaction(fn ->
          moving = lock_moving(repo, ns, from)

          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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
        end)
        |> case do
          {:ok, reply} -> reply
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def delete_namespace(repo, ns) do
      backend(fn ->
        with {:ok, _} <- repo.query("DELETE FROM #{@table} WHERE namespace = $1", [ns]), do: :ok
      end)
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
          %{rows: rows} =
            repo.query!(
              "SELECT path FROM #{@table} WHERE namespace = $1 AND starts_with(path, $2) FOR UPDATE",
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

    defp one_row({:ok, %{num_rows: 1}}, version), do: {:ok, version}
    defp one_row({:ok, %{num_rows: 0}}, _version), do: {:error, :conflict}
    defp one_row({:error, _} = error, _version), do: error

    defp returned_version({:ok, %{rows: [[version]]}}), do: {:ok, version}
    defp returned_version({:ok, %{rows: []}}), do: {:error, :conflict}
    defp returned_version({:error, _} = error), do: error

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
