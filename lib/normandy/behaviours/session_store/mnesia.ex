defmodule Normandy.Behaviours.SessionStore.Mnesia do
  @moduledoc """
  Distributed, durable `SessionStore` over OTP-native Mnesia ("distributed ETS").
  `ram_copies` tables are replicated ETS; `:mnesia.transaction/1` serializes per-session
  appends (the FOR-UPDATE equivalent), so concurrent/cross-node appends never lose an
  entry. Mnesia stores Erlang terms natively, so `content` / `turn_state` /
  `config_template` need no `term_to_binary`.

  The `handle` is `%{entries: table, sessions: table}`. The host (or `Normandy.Cluster`)
  calls `create_tables/1` with `copies: :disc_copies` for durable, full-cluster-restart
  survival (the production default); `ram_copies` (test/default `new/0`) is faster but
  only meaningful with ≥2 nodes. Configure via
  `{Normandy.Behaviours.SessionStore.Mnesia, entries: :..., sessions: :...}`.
  """
  @behaviour Normandy.Behaviours.SessionStore

  alias Normandy.Components.AgentMemory.Entry

  @empty_session %{
    head_id: nil,
    current_turn_id: nil,
    turn_state: nil,
    config_template: nil,
    resume_policy: nil
  }

  @doc "Test/default handle: fresh uniquely-named `ram_copies` tables on this node."
  @spec new(keyword()) :: %{entries: atom(), sessions: atom()}
  def new(opts \\ []) do
    uid = System.unique_integer([:positive])
    entries = Keyword.get(opts, :entries, :"normandy_entries_#{uid}")
    sessions = Keyword.get(opts, :sessions, :"normandy_sessions_#{uid}")
    :ok = create_tables(entries: entries, sessions: sessions, copies: :ram_copies)
    %{entries: entries, sessions: sessions}
  end

  @doc """
  Create the two Mnesia tables. Opts: `:entries`/`:sessions` (table-name atoms,
  required), `:copies` (`:disc_copies` default | `:ram_copies`), `:nodes` (default
  `[node()]`). `disc_copies` converts this node's schema to disc first so it survives
  restart (requires a writable Mnesia dir; see `-mnesia dir` / `:mnesia` app env).
  """
  @spec create_tables(keyword()) :: :ok
  def create_tables(opts) do
    entries = Keyword.fetch!(opts, :entries)
    sessions = Keyword.fetch!(opts, :sessions)
    copies = Keyword.get(opts, :copies, :disc_copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    :ok = ensure_started!()
    if copies == :disc_copies, do: ensure_disc_schema!(nodes)

    :ok = create_table(entries, [:id, :data], copies, nodes)
    :ok = create_table(sessions, [:session_id, :data], copies, nodes)
    :ok
  end

  @impl true
  def append_entry(%{entries: et, sessions: st}, session_id, %Entry{} = entry) do
    txn(fn ->
      data = read_session(st, session_id)
      id = entry.id || UUID.uuid4()
      parent = entry.parent_id || data.head_id

      :mnesia.write(
        {et, id,
         %{parent_id: parent, turn_id: entry.turn_id, role: entry.role, content: entry.content}}
      )

      :mnesia.write({st, session_id, %{data | head_id: id, current_turn_id: entry.turn_id}})
      id
    end)
  end

  @impl true
  def history(%{entries: et, sessions: st}, session_id) do
    # txn/1 already returns {:ok, entries} | {:error, reason} — the contract's shape.
    txn(fn ->
      case :mnesia.read({st, session_id}) do
        [{_, ^session_id, %{head_id: head}}] -> chain(et, head, [])
        [] -> []
      end
    end)
  end

  @impl true
  def fork(%{entries: et, sessions: st}, session_id, from_entry_id) do
    txn(fn ->
      case :mnesia.read({st, session_id}) do
        [] ->
          :mnesia.abort(:no_such_session)

        [{_, ^session_id, %{head_id: head}}] ->
          if on_chain?(et, head, from_entry_id) do
            new_id = UUID.uuid4()
            :mnesia.write({st, new_id, %{@empty_session | head_id: from_entry_id}})
            new_id
          else
            :mnesia.abort(:no_such_entry)
          end
      end
    end)
  end

  @impl true
  def save_turn_state(%{sessions: st}, session_id, term) do
    to_ok(
      txn(fn ->
        data = read_session(st, session_id)
        :mnesia.write({st, session_id, %{data | turn_state: term}})
      end)
    )
  end

  @impl true
  def load_turn_state(%{sessions: st}, session_id) do
    case txn(fn -> :mnesia.read({st, session_id}) end) do
      {:ok, [{_, ^session_id, %{turn_state: ts}}]} when not is_nil(ts) -> {:ok, ts}
      _ -> :error
    end
  end

  @impl true
  def save_config_template(%{sessions: st}, session_id, tmpl) do
    rp =
      case tmpl do
        %{resume_policy: v} when is_atom(v) -> v
        _ -> :lazy
      end

    to_ok(
      txn(fn ->
        data = read_session(st, session_id)
        :mnesia.write({st, session_id, %{data | config_template: tmpl, resume_policy: rp}})
      end)
    )
  end

  @impl true
  def load_config_template(%{sessions: st}, session_id) do
    case txn(fn -> :mnesia.read({st, session_id}) end) do
      {:ok, [{_, ^session_id, %{config_template: t}}]} when not is_nil(t) -> {:ok, t}
      _ -> :error
    end
  end

  @impl true
  def list_resumable(%{sessions: st}) do
    txn(fn ->
      :mnesia.foldl(
        fn
          {_, sid, %{resume_policy: :eager}}, acc -> [sid | acc]
          _, acc -> acc
        end,
        [],
        st
      )
    end)
  end

  # --- private ---

  defp read_session(st, session_id) do
    case :mnesia.read({st, session_id}) do
      [{_, ^session_id, data}] -> data
      [] -> @empty_session
    end
  end

  # Walk head -> root, accumulating oldest-first (prepend) => chronological.
  defp chain(_et, nil, acc), do: acc

  defp chain(et, id, acc) do
    case :mnesia.read({et, id}) do
      [{_, ^id, d}] ->
        entry = %Entry{
          id: id,
          parent_id: d.parent_id,
          turn_id: d.turn_id,
          role: d.role,
          content: d.content
        }

        chain(et, d.parent_id, [entry | acc])

      [] ->
        acc
    end
  end

  defp on_chain?(_et, nil, _target), do: false
  defp on_chain?(_et, id, target) when id == target, do: true

  defp on_chain?(et, id, target) do
    case :mnesia.read({et, id}) do
      [{_, ^id, d}] -> on_chain?(et, d.parent_id, target)
      [] -> false
    end
  end

  defp txn(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  # save_* want :ok (not {:ok, :ok}) since :mnesia.write returns :ok.
  defp to_ok({:ok, :ok}), do: :ok
  defp to_ok({:error, _} = e), do: e

  defp ensure_started! do
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      _ -> :mnesia.start()
    end
  end

  defp ensure_disc_schema!(nodes) do
    Enum.each(nodes, fn n ->
      case :mnesia.change_table_copy_type(:schema, n, :disc_copies) do
        {:atomic, :ok} ->
          :ok

        {:aborted, {:already_exists, :schema, _, :disc_copies}} ->
          :ok

        {:aborted, reason} ->
          raise "Mnesia disc schema setup failed on #{inspect(n)}: #{inspect(reason)}"
      end
    end)
  end

  defp create_table(name, attrs, copies, nodes) do
    case :mnesia.create_table(name, [{:attributes, attrs}, {:type, :set}, {copies, nodes}]) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^name}} ->
        :ok

      {:aborted, reason} ->
        raise "Mnesia create_table #{inspect(name)} failed: #{inspect(reason)}"
    end
  end
end
