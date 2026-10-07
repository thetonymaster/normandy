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

  Normandy does not start Mnesia with the application; this store starts it on
  first use. A release that uses this store must include Mnesia: add `:mnesia`
  to your application's `extra_applications`.
  """
  @behaviour Normandy.Behaviours.SessionStore

  # :mnesia is not a declared application dependency (see the moduledoc).
  @compile {:no_warn_undefined, :mnesia}

  alias Normandy.Behaviours.MnesiaSetup
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Options

  @new_opts_schema NimbleOptions.new!(
                     entries: [type: :atom, doc: "The entries table (default: a unique name)."],
                     sessions: [type: :atom, doc: "The sessions table (default: a unique name)."]
                   )

  @create_tables_opts_schema NimbleOptions.new!(
                               entries: [type: :atom, required: true, doc: "The entries table."],
                               sessions: [type: :atom, required: true, doc: "The sessions table."],
                               copies: [
                                 type: {:in, [:disc_copies, :ram_copies]},
                                 default: :disc_copies,
                                 doc:
                                   "`:disc_copies` converts this node's schema to disc first so " <>
                                     "the tables survive a restart (needs a writable Mnesia dir)."
                               ],
                               nodes: [
                                 type: {:list, :atom},
                                 doc: "The nodes holding copies (default: `[node()]`)."
                               ],
                               wait_timeout: [
                                 type: :timeout,
                                 default: 30_000,
                                 doc:
                                   "How long to wait for the tables to load, in ms; raises on timeout."
                               ]
                             )

  @doc false
  def __opts_schema__(:create_tables), do: @create_tables_opts_schema

  @empty_session %{
    head_id: nil,
    current_turn_id: nil,
    turn_state: nil,
    config_template: nil,
    resume_policy: nil,
    inflight: false
  }

  @doc """
  Test/default handle: fresh uniquely-named `ram_copies` tables on this node.

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(keyword()) :: %{entries: atom(), sessions: atom()}
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
    uid = System.unique_integer([:positive])
    entries = Keyword.get(opts, :entries, :"normandy_entries_#{uid}")
    sessions = Keyword.get(opts, :sessions, :"normandy_sessions_#{uid}")
    :ok = create_tables(entries: entries, sessions: sessions, copies: :ram_copies)
    %{entries: entries, sessions: sessions}
  end

  @doc """
  Creates the two Mnesia tables. A writable Mnesia dir is set with `-mnesia dir` or the
  `:mnesia` app env.

  ## Options

  #{Options.docs(@create_tables_opts_schema)}
  """
  @spec create_tables(keyword()) :: :ok
  def create_tables(opts) do
    opts = Options.validate!(opts, @create_tables_opts_schema, {__MODULE__, :create_tables, 1})
    entries = Keyword.fetch!(opts, :entries)
    sessions = Keyword.fetch!(opts, :sessions)
    copies = Keyword.fetch!(opts, :copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    :ok = MnesiaSetup.ensure_started!()
    if copies == :disc_copies, do: MnesiaSetup.ensure_disc_schema!(nodes)

    :ok = MnesiaSetup.create_table!(entries, [:id, :data], :set, copies, nodes)
    :ok = MnesiaSetup.create_table!(sessions, [:session_id, :data], :set, copies, nodes)

    MnesiaSetup.wait_for_tables!(
      [entries, sessions],
      Keyword.fetch!(opts, :wait_timeout),
      "SessionStore.Mnesia"
    )
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
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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
  def save_turn_state(%{sessions: st}, session_id, term, inflight?) when is_boolean(inflight?) do
    to_ok(
      txn(fn ->
        data = read_session(st, session_id)
        # Map.put, not %{data | ...}: a row written before 2.0 has no :inflight key.
        :mnesia.write(
          {st, session_id, data |> Map.put(:turn_state, term) |> Map.put(:inflight, inflight?)}
        )
      end)
    )
  end

  @impl true
  def load_turn_state(%{sessions: st}, session_id) do
    case txn(fn -> :mnesia.read({st, session_id}) end) do
      {:ok, [{_, ^session_id, %{turn_state: ts}}]} when not is_nil(ts) -> {:ok, ts}
      {:ok, _no_saved_value} -> :error
      {:error, reason} -> {:error, reason}
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
      {:ok, _no_saved_value} -> :error
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_resumable(%{sessions: st}) do
    # A scan of the sessions table that copies out only the matching ids; a row written
    # before 2.0 has no :inflight key and does not match.
    txn(fn -> :mnesia.select(st, [{{st, :"$1", %{inflight: true}}, [], [:"$1"]}]) end)
  end

  @doc """
  Deletes the session's row and the entries of its chain that no other session reaches
  (`c:Normandy.Behaviours.SessionStore.delete_session/2`).

  Forks share ancestor entries here, and an entry's parent link sits inside its data, so
  finding the entries another session still uses scans both tables: O(entries + sessions)
  under a write lock on both, which blocks every other write to the store meanwhile.
  """
  @impl true
  def delete_session(%{entries: et, sessions: st}, session_id) do
    to_ok(
      txn(fn ->
        :mnesia.write_lock_table(st)
        :mnesia.write_lock_table(et)

        case :mnesia.read({st, session_id}) do
          [] ->
            :ok

          [{_, ^session_id, %{head_id: head}}] ->
            et |> unshared_chain(st, session_id, head) |> Enum.each(&:mnesia.delete({et, &1}))
            :mnesia.delete({st, session_id})
        end
      end)
    )
  end

  # --- private ---

  # The ids on the chain from `head`, newest first, up to the first one another session
  # reaches: another session's head, or an entry with a child off this chain. Every
  # ancestor of a reached entry is reached too, so the walk stops there.
  defp unshared_chain(et, st, session_id, head) do
    other_heads =
      :mnesia.foldl(
        fn
          {_, sid, %{head_id: h}}, acc when sid != session_id and h != nil -> MapSet.put(acc, h)
          _, acc -> acc
        end,
        MapSet.new(),
        st
      )

    children =
      :mnesia.foldl(
        fn
          {_, id, %{parent_id: p}}, acc when p != nil -> Map.update(acc, p, [id], &[id | &1])
          _, acc -> acc
        end,
        %{},
        et
      )

    walk_unshared(et, head, nil, other_heads, children, [])
  end

  defp walk_unshared(_et, nil, _child, _heads, _children, acc), do: acc

  defp walk_unshared(et, id, child, heads, children, acc) do
    shared? =
      MapSet.member?(heads, id) or Enum.any?(Map.get(children, id, []), &(&1 != child))

    with false <- shared?,
         [{_, ^id, %{parent_id: parent}}] <- :mnesia.read({et, id}) do
      walk_unshared(et, parent, id, heads, children, [id | acc])
    else
      _stop -> acc
    end
  end

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

      # A missing entry (a table still loading, an unsynced replica) would hand
      # the model a conversation with a hole in it; fail instead.
      [] ->
        :mnesia.abort({:broken_chain, id})
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
end
