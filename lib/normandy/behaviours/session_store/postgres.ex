# Compiled only when Ecto/Postgrex are available (they are `optional` deps). Tier-0
# users who omit them simply don't get this module; Tier-1/2 users add the deps.
if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Normandy.Behaviours.SessionStore.Postgres do
    @moduledoc """
    Durable, cluster-shared `SessionStore` over Postgres (Ecto). The `handle` is the
    host's Ecto Repo module. Conversation `content` and opaque `turn_state` are stored
    as Erlang terms (`term_to_binary`). Entries are a global parent-linked forest, so
    `fork/3` shares ancestors instead of copying.

    Pass it as `{Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo}` (the handle is
    the Repo module itself), for example as `Turn.Session.new/1`'s `:store`. Its tables
    come from four migrations: call the `up/0` of
    `Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`,
    `MigrationAddResumePolicy` and `MigrationAddInflight`, in that order, from one host
    migration, and their `down/0` in the reverse order (the distributed sessions guide
    has the migration module).
    """
    @behaviour Normandy.Behaviours.SessionStore

    import Ecto.Query
    alias Ecto.Adapters.SQL
    alias Normandy.Behaviours.SessionStore.Codec
    alias Normandy.Behaviours.SessionStore.Postgres.Schemas.{Entry, Session}
    alias Normandy.Components.AgentMemory

    @impl true
    def append_entry(repo, session_id, %{__struct__: _} = entry),
      do: backend(fn -> do_append_entry(repo, session_id, entry) end)

    defp do_append_entry(repo, session_id, entry) do
      repo.transaction(fn ->
        # Ensure the session row exists so the FOR UPDATE below always locks a real
        # row. This serializes concurrent first-appends to a new session: two callers
        # cannot both create the row and lose an entry (the standard get-or-create-
        # with-lock idiom — INSERT ON CONFLICT DO NOTHING, then SELECT FOR UPDATE).
        repo.insert(%Session{session_id: session_id},
          on_conflict: :nothing,
          conflict_target: :session_id
        )

        session = lock_session(repo, session_id)
        id = entry.id || Ecto.UUID.generate()
        parent_id = entry.parent_id || session.head_id
        now = DateTime.utc_now()

        # Abort the transaction with {:error, reason} on a DB failure rather than
        # raising into the caller — the store contract returns error tuples, and the
        # server's fail/2 path depends on that to fail gracefully instead of crashing.
        with {:ok, _} <-
               repo.insert(%Entry{
                 id: id,
                 parent_id: parent_id,
                 turn_id: entry.turn_id,
                 role: entry.role,
                 content: encode(entry.content),
                 inserted_at: now
               }),
             {:ok, _} <-
               session
               |> Ecto.Changeset.change(head_id: id, current_turn_id: entry.turn_id)
               |> repo.update() do
          id
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, id} -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def history(repo, session_id),
      do: backend(fn -> do_history(repo, session_id, :all) end)

    @impl true
    def history_since_compaction(repo, session_id),
      do: backend(fn -> do_history(repo, session_id, :since_compaction) end)

    defp do_history(repo, session_id, until) do
      case repo.get(Session, session_id) do
        nil ->
          {:ok, []}

        %Session{head_id: nil} ->
          {:ok, []}

        %Session{head_id: head_id} ->
          {:ok, chain(repo, head_id, until)}
      end
    end

    @impl true
    def fork(repo, session_id, from_entry_id),
      do: backend(fn -> do_fork(repo, session_id, from_entry_id) end)

    defp do_fork(repo, session_id, from_entry_id) do
      repo.transaction(fn ->
        cond do
          # FOR SHARE: a concurrent delete_session/2 of this session waits for the fork
          # (and then keeps the entries the fork reaches), or the fork sees no session.
          share_lock_session(repo, session_id) == nil ->
            repo.rollback(:no_such_session)

          not ancestor_of_head?(repo, session_id, from_entry_id) ->
            repo.rollback(:no_such_entry)

          true ->
            new_id = Ecto.UUID.generate()

            repo.insert!(%Session{
              session_id: new_id,
              head_id: from_entry_id,
              current_turn_id: nil
            })

            new_id
        end
      end)
    end

    @impl true
    def save_turn_state(repo, session_id, term, inflight?) when is_boolean(inflight?),
      do: backend(fn -> do_save_turn_state(repo, session_id, term, inflight?) end)

    defp do_save_turn_state(repo, session_id, term, inflight?) do
      blob = encode(term)

      %Session{session_id: session_id}
      |> Ecto.Changeset.change(turn_state: blob, inflight: inflight?)
      |> repo.insert(
        on_conflict: [
          set: [turn_state: blob, inflight: inflight?, updated_at: DateTime.utc_now()]
        ],
        conflict_target: :session_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def load_turn_state(repo, session_id),
      do: backend(fn -> do_load_turn_state(repo, session_id) end)

    defp do_load_turn_state(repo, session_id) do
      case repo.get(Session, session_id) do
        %Session{turn_state: blob} when is_binary(blob) -> {:ok, decode(blob)}
        _ -> :error
      end
    end

    @impl true
    def save_config_template(repo, session_id, tmpl),
      do: backend(fn -> do_save_config_template(repo, session_id, tmpl) end)

    defp do_save_config_template(repo, session_id, tmpl) do
      blob = encode(tmpl)
      # Mirror resume_policy into a queryable column so list_resumable/1 can filter
      # without decoding every opaque template blob. The template is an opaque term
      # (behaviour: `term()`), so guard non-map terms (and non-atom/binary policies)
      # instead of assuming a map — matches the is_map guards in the ETS/InMemory stores.
      rp =
        case tmpl do
          %{resume_policy: v} when is_atom(v) or is_binary(v) -> to_string(v)
          _ -> "lazy"
        end

      %Session{session_id: session_id}
      |> Ecto.Changeset.change(config_template: blob, resume_policy: rp)
      |> repo.insert(
        on_conflict: [
          set: [config_template: blob, resume_policy: rp, updated_at: DateTime.utc_now()]
        ],
        conflict_target: :session_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def list_resumable(repo),
      do: backend(fn -> do_list_resumable(repo) end)

    defp do_list_resumable(repo) do
      ids =
        Session
        # Served by the partial index normandy_sessions_inflight_index.
        |> where([s], s.inflight == true)
        |> select([s], s.session_id)
        |> repo.all()

      {:ok, ids}
    end

    @impl true
    def load_config_template(repo, session_id),
      do: backend(fn -> do_load_config_template(repo, session_id) end)

    defp do_load_config_template(repo, session_id) do
      case repo.get(Session, session_id) do
        %Session{config_template: blob} when is_binary(blob) -> {:ok, decode(blob)}
        _ -> :error
      end
    end

    @impl true
    def delete_session(repo, session_id),
      do: backend(fn -> do_delete_session(repo, session_id) end)

    # One transaction holding the session row: a concurrent fork of this session (which
    # takes the row FOR SHARE) runs wholly before or after it. Entries another session
    # reaches stay: forks share ancestors here.
    defp do_delete_session(repo, session_id) do
      repo.transaction(fn ->
        case lock_session(repo, session_id) do
          nil ->
            :ok

          %Session{head_id: head_id} ->
            _ = delete_unreached(repo, session_id, head_id)
            {_count, _} = repo.delete_all(where(Session, [s], s.session_id == ^session_id))
            :ok
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp delete_unreached(_repo, _session_id, nil), do: :ok

    # Deletes every entry of the head's tree that no other session's head reaches: the
    # session's chain and any branch it left with an explicit parent_id. Sessions sharing
    # entries share the tree's root, so a lock on the root serialises their deletes: under
    # READ COMMITTED, two deletes that each saw the other's head would both keep the
    # entries only the two of them reached. Taken before the query, so it sees the other
    # delete's commit.
    defp delete_unreached(repo, session_id, head_id) do
      {root, _parent} = repo |> chain_ids(head_id) |> List.last()

      _ =
        SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtextextended($1::uuid::text, 0))", [
          root
        ])

      sql = """
      WITH RECURSIVE tree(id) AS (
        SELECT id FROM normandy_session_entries WHERE id = $1
        UNION ALL
        SELECT e.id FROM normandy_session_entries e JOIN tree t ON e.parent_id = t.id
      ),
      reached(id, parent_id) AS (
        SELECT e.id, e.parent_id
        FROM normandy_sessions s JOIN normandy_session_entries e ON e.id = s.head_id
        WHERE s.session_id <> $2 AND e.id IN (SELECT id FROM tree)
        UNION
        SELECT e.id, e.parent_id FROM normandy_session_entries e JOIN reached r ON e.id = r.parent_id
      )
      DELETE FROM normandy_session_entries
      WHERE id IN (SELECT id FROM tree) AND id NOT IN (SELECT id FROM reached)
      """

      SQL.query!(repo, sql, [root, session_id])
    end

    # --- Private helpers ---

    # An unreachable or failing database raises out of Ecto; the store contract
    # reports a backend failure as {:error, reason}.
    defp backend(fun) do
      fun.()
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, e}
    end

    # Ids only: the fork check never decodes a content blob.
    defp ancestor_of_head?(repo, session_id, entry_id) do
      with %Session{head_id: head_id} when not is_nil(head_id) <- repo.get(Session, session_id),
           {:ok, target} <- Ecto.UUID.dump(entry_id) do
        repo |> chain_ids(head_id) |> Enum.any?(fn {id, _parent} -> id == target end)
      else
        _ -> false
      end
    end

    defp lock_session(repo, session_id) do
      Session
      |> where([s], s.session_id == ^session_id)
      |> lock("FOR UPDATE")
      |> repo.one()
    end

    defp share_lock_session(repo, session_id) do
      Session
      |> where([s], s.session_id == ^session_id)
      |> lock("FOR SHARE")
      |> repo.one()
    end

    # Walk parent_id from head -> root via a recursive CTE; return chronological. With
    # :since_compaction the walk stops after the first "compaction" row: the rows before
    # it are neither read nor decoded.
    defp chain(repo, head_id, until) do
      stop =
        if until == :since_compaction, do: "WHERE b.role IS DISTINCT FROM 'compaction'", else: ""

      sql = """
      WITH RECURSIVE branch(id, parent_id, turn_id, role, content, depth) AS (
        SELECT id, parent_id, turn_id, role, content, 0
        FROM normandy_session_entries WHERE id = $1
        UNION ALL
        SELECT e.id, e.parent_id, e.turn_id, e.role, e.content, b.depth + 1
        FROM normandy_session_entries e
        JOIN branch b ON e.id = b.parent_id
        #{stop}
      )
      SELECT id, parent_id, turn_id, role, content FROM branch ORDER BY depth DESC
      """

      %{rows: rows} = SQL.query!(repo, sql, [Ecto.UUID.dump!(head_id)])

      Enum.map(rows, fn [id, parent_id, turn_id, role, content] ->
        %AgentMemory.Entry{
          id: load_uuid(id),
          parent_id: load_uuid(parent_id),
          turn_id: turn_id,
          role: role,
          content: decode(content)
        }
      end)
    end

    # The chain from head_id to the root as raw {id, parent_id} pairs, newest first.
    defp chain_ids(repo, head_id) do
      sql = """
      WITH RECURSIVE branch(id, parent_id, depth) AS (
        SELECT id, parent_id, 0 FROM normandy_session_entries WHERE id = $1
        UNION ALL
        SELECT e.id, e.parent_id, b.depth + 1
        FROM normandy_session_entries e
        JOIN branch b ON e.id = b.parent_id
      )
      SELECT id, parent_id FROM branch ORDER BY depth
      """

      %{rows: rows} = SQL.query!(repo, sql, [Ecto.UUID.dump!(head_id)])
      Enum.map(rows, fn [id, parent_id] -> {id, parent_id} end)
    end

    defp load_uuid(nil), do: nil
    defp load_uuid(bin) when is_binary(bin), do: Ecto.UUID.load!(bin)

    defp encode(term), do: Codec.encode(term)
    defp decode(bin) when is_binary(bin), do: Codec.decode(bin)
  end
end
