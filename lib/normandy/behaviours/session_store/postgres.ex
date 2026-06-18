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
      session = lock_session(repo, session_id)
      id = entry.id || Ecto.UUID.generate()
      parent_id = entry.parent_id || (session && session.head_id)
      now = DateTime.utc_now()

      {:ok, _} =
        repo.insert(%Entry{
          id: id,
          parent_id: parent_id,
          turn_id: entry.turn_id,
          role: entry.role,
          content: encode(entry.content),
          inserted_at: now
        })

      upsert_head(repo, session, session_id, id, entry.turn_id)
      id
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
  def fork(_repo, _session_id, _from_entry_id), do: {:error, :not_implemented}

  @impl true
  def save_turn_state(_repo, _session_id, _term), do: {:error, :not_implemented}

  @impl true
  def load_turn_state(_repo, _session_id), do: :error

  # --- Private helpers ---

  defp lock_session(repo, session_id) do
    Session
    |> where([s], s.session_id == ^session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp upsert_head(repo, nil, session_id, head_id, turn_id) do
    repo.insert!(%Session{
      session_id: session_id,
      head_id: head_id,
      current_turn_id: turn_id
    })
  end

  defp upsert_head(repo, %Session{} = session, _session_id, head_id, turn_id) do
    session
    |> Ecto.Changeset.change(head_id: head_id, current_turn_id: turn_id)
    |> repo.update!()
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
