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
    run `Normandy.Behaviours.SessionStore.Postgres.Migration` from a host migration.
    """
    @behaviour Normandy.Behaviours.SessionStore

    import Ecto.Query
    alias Normandy.Behaviours.SessionStore.Postgres.Schemas.{Entry, Session}
    alias Normandy.Components.AgentMemory

    @doc "Test/default handle: the Repo configured for :normandy. Returns the Repo module."
    @spec new() :: module()
    def new, do: hd(Application.fetch_env!(:normandy, :ecto_repos))

    @impl true
    def append_entry(repo, session_id, %{__struct__: _} = entry) do
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
    def history(repo, session_id) do
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
    def fork(repo, session_id, from_entry_id) do
      repo.transaction(fn ->
        cond do
          repo.get(Session, session_id) == nil ->
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
    def save_turn_state(repo, session_id, term) do
      blob = encode(term)

      %Session{session_id: session_id}
      |> Ecto.Changeset.change(turn_state: blob)
      |> repo.insert(
        on_conflict: [set: [turn_state: blob, updated_at: DateTime.utc_now()]],
        conflict_target: :session_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def load_turn_state(repo, session_id) do
      case repo.get(Session, session_id) do
        %Session{turn_state: blob} when is_binary(blob) -> {:ok, decode(blob)}
        _ -> :error
      end
    end

    @impl true
    def save_config_template(repo, session_id, tmpl) do
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
    def list_resumable(repo) do
      ids =
        Session
        |> where([s], s.resume_policy == "eager")
        |> select([s], s.session_id)
        |> repo.all()

      {:ok, ids}
    end

    @impl true
    def load_config_template(repo, session_id) do
      case repo.get(Session, session_id) do
        %Session{config_template: blob} when is_binary(blob) -> {:ok, decode(blob)}
        _ -> :error
      end
    end

    # --- Private helpers ---

    defp ancestor_of_head?(repo, session_id, entry_id) do
      case repo.get(Session, session_id) do
        %Session{head_id: head_id} when not is_nil(head_id) ->
          chain(repo, head_id) |> Enum.any?(&(&1.id == entry_id))

        _ ->
          false
      end
    end

    defp lock_session(repo, session_id) do
      Session
      |> where([s], s.session_id == ^session_id)
      |> lock("FOR UPDATE")
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

      %{rows: rows} = Ecto.Adapters.SQL.query!(repo, sql, [Ecto.UUID.dump!(head_id)])

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

    defp load_uuid(nil), do: nil
    defp load_uuid(bin) when is_binary(bin), do: Ecto.UUID.load!(bin)

    defp encode(term), do: :erlang.term_to_binary(term)
    defp decode(bin) when is_binary(bin), do: :erlang.binary_to_term(bin, [:safe])
  end
end
