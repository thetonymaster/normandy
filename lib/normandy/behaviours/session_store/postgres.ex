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
  def append_entry(_repo, _session_id, _entry), do: {:error, :not_implemented}

  @impl true
  def history(_repo, _session_id), do: {:ok, []}

  @impl true
  def fork(_repo, _session_id, _from_entry_id), do: {:error, :not_implemented}

  @impl true
  def save_turn_state(_repo, _session_id, _term), do: {:error, :not_implemented}

  @impl true
  def load_turn_state(_repo, _session_id), do: :error
end
