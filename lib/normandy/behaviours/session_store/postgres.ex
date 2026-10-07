# Compiled only when Ecto/Postgrex are available (they are `optional` deps). Tier-0
# users who omit them simply don't get this module; Tier-1/2 users add the deps.
if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Normandy.Behaviours.SessionStore.Postgres do
    @moduledoc """
    Durable, cluster-shared `SessionStore` over Postgres (Ecto). The `handle` is the
    host's Ecto Repo module. Conversation `content` and opaque `turn_state` are stored
    as Erlang terms (`term_to_binary`). Entries are a global parent-linked forest, so
    `fork/3` shares ancestors instead of copying.

    Configure via `{Normandy.Behaviours.SessionStore.Postgres, repo: MyApp.Repo}` and
    run `Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`,
    `MigrationAddResumePolicy` and `MigrationAddInflight` from a host migration.
    """
    @behaviour Normandy.Behaviours.SessionStore

    import Ecto.Query
    alias Ecto.Adapters.SQL
    alias Normandy.Behaviours.SessionStore.Codec
    alias Normandy.Behaviours.SessionStore.Postgres.Schemas.{Entry, Session}
    alias Normandy.Components.AgentMemory

    @doc "Test/default handle: the Repo configured for :normandy. Returns the Repo module."
    @spec new() :: module()
    def new, do: hd(Application.fetch_env!(:normandy, :ecto_repos))

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
      do: backend(fn -> do_history(repo, session_id) end)

    defp do_history(repo, session_id) do
      case repo.get(Session, session_id) do
        nil ->
          {:ok, []}

        %Session{head_id: nil} ->
          {:ok, []}

        %Session{head_id: head_id} ->
          {:ok, chain(repo, head_id)}
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
            _ = delete_unshared_chain(repo, session_id, head_id)
            {_count, _} = repo.delete_all(where(Session, [s], s.session_id == ^session_id))
            :ok
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp delete_unshared_chain(_repo, _session_id, nil), do: :ok

    defp delete_unshared_chain(repo, session_id, head_id) do
      chain = chain_ids(repo, head_id)
      ids = Enum.map(chain, fn {id, _parent} -> id end)

      %{rows: head_rows} =
        SQL.query!(
          repo,
          "SELECT head_id FROM normandy_sessions WHERE head_id = ANY($1::uuid[]) AND session_id <> $2",
          [ids, session_id]
        )

      %{rows: child_rows} =
        SQL.query!(
          repo,
          "SELECT parent_id, id FROM normandy_session_entries WHERE parent_id = ANY($1::uuid[])",
          [ids]
        )

      other_heads = MapSet.new(head_rows, fn [id] -> id end)
      children = Enum.group_by(child_rows, fn [parent, _id] -> parent end, fn [_p, id] -> id end)

      case unshared_prefix(chain, other_heads, children) do
        [] ->
          :ok

        doomed ->
          SQL.query!(repo, "DELETE FROM normandy_session_entries WHERE id = ANY($1::uuid[])", [
            doomed
          ])
      end
    end

    # The ids from the head down to the first entry another session reaches: another
    # session's head, or an entry with a child off this chain. Every ancestor of a reached
    # entry is reached too.
    defp unshared_prefix(chain, other_heads, children) do
      chain
      |> Enum.reduce_while({nil, []}, fn {id, _parent}, {child, acc} ->
        shared? =
          MapSet.member?(other_heads, id) or
            Enum.any?(Map.get(children, id, []), &(&1 != child))

        if shared?, do: {:halt, {child, acc}}, else: {:cont, {id, [id | acc]}}
      end)
      |> elem(1)
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

    # Walk parent_id from head -> root via a recursive CTE; return chronological.
    defp chain(repo, head_id) do
      sql = """
      WITH RECURSIVE branch(id, parent_id, turn_id, role, content, depth) AS (
        SELECT id, parent_id, turn_id, role, content, 0
        FROM normandy_session_entries WHERE id = $1
        UNION ALL
        SELECT e.id, e.parent_id, e.turn_id, e.role, e.content, b.depth + 1
        FROM normandy_session_entries e
        JOIN branch b ON e.id = b.parent_id
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
