# Compiled only when Redix is available (an `optional` dep). Tier-0 users who omit it
# simply don't get this module.
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionStore.Redis do
    @moduledoc """
    Durable `SessionStore` over Redis, modelled on Redis Streams. The conversation is an
    append-only stream (`XADD`/`XRANGE`) so appends are atomic and O(1) with no
    read-modify-write — concurrent appends never lose an entry. Session metadata
    (turn state, config template, resume policy) lives in a hash; the ids of the sessions
    with a turn in flight live in the SET `"<namespace>:inflight"` for `list_resumable/1`.

    The `handle` is `{conn, namespace}`, `{conn, namespace, wait}` or
    `{conn, namespace, wait, wait_conns}` (the host owns the Redix connections,
    Oban-style; `new/1` opens its own).
    All of a session's keys share a `{sid}` hash-tag so multi-key reads/forks stay in one
    Redis Cluster slot. Opaque values use `term_to_binary` / `binary_to_term(_, [:safe])`.

    Durability is the operator's Redis config (AOF recommended). For the fail-closed
    invariant, set `wait: {numreplicas, timeout_ms}` (`new/1` option, or the third
    handle element): every write (entry appends, turn state, config template) then
    blocks on replica acknowledgement and returns `{:error, {:wait_unmet, acked, n}}`
    if unmet. Without it, `config :normandy, :redis_wait, {n, timeout_ms}` applies;
    the default `{0, 0}` does not wait. With replicas, `timeout_ms` must be positive:
    Redis treats 0 as wait forever.

    ## Waited writes and connections

    `WAIT` blocks the connection it runs on until the replicas acknowledge that
    connection's own earlier writes, so a write and its `WAIT` must share a connection,
    and every command queued behind them on it waits too. `wait_conns` is a tuple of
    Redix connections used for nothing else: a session's waited writes and their `WAIT`
    run on `elem(wait_conns, :erlang.phash2(session_id, tuple_size(wait_conns)))`, so one
    session's writes stay in order and other sessions, reads and a registry sharing
    `conn` do not queue behind its `WAIT`. `new/1` with a replica `:wait` opens
    `:wait_connections` of them. A handle without `wait_conns` runs waited writes on
    `conn`.
    """
    @behaviour Normandy.Behaviours.SessionStore

    alias Normandy.Behaviours.SessionStore.Codec
    alias Normandy.Components.AgentMemory.Entry
    alias Normandy.Components.ContentBlock.Describe
    alias Normandy.Options

    # Entries copied per pipeline by fork/3.
    @copy_chunk 1_000
    # Entries per XREVRANGE page of history_since_compaction/2.
    @since_page 200

    @default_wait_connections 4

    @new_opts_schema NimbleOptions.new!(
                       url: [
                         type: :string,
                         type_doc: "`t:String.t/0`",
                         required: true,
                         doc: "The Redis URL."
                       ],
                       wait: [
                         type: {:tuple, [:non_neg_integer, :non_neg_integer]},
                         doc:
                           "`{replicas, timeout_ms}` for `WAIT` after each write (default: " <>
                             "`config :normandy, :redis_wait`). With replicas, `timeout_ms` " <>
                             "must be positive."
                       ],
                       wait_connections: [
                         type: :pos_integer,
                         doc:
                           "How many connections waited writes run on (default `4`); only " <>
                             "with a `:wait` of one replica or more."
                       ],
                       namespace: [
                         type: :string,
                         required: true,
                         doc: "The key namespace."
                       ]
                     )

    @doc """
    Opens a Redix connection to `:url` and returns the store's handle: `{conn, namespace}`,
    plus the wait settings (and the `WAIT` connections) when `:wait` asks for replicas.
    `:url` and `:namespace` are required: a host passes its own, and `Normandy.Cluster`
    builds the handle of the Redis combo.

    ## Options

    #{Options.docs(@new_opts_schema)}
    """
    @spec new(keyword()) ::
            {pid(), binary()}
            | {pid(), binary(), {non_neg_integer(), non_neg_integer()}}
            | {pid(), binary(), {pos_integer(), pos_integer()}, tuple()}
    def new(opts) do
      opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
      check_wait_connections!(opts)

      url = Keyword.fetch!(opts, :url)

      # Checked before connecting, so a bad setting starts nothing.
      _ =
        with {:ok, wait} <- Keyword.fetch(opts, :wait),
             do: check_wait!(wait, "SessionStore.Redis.new/1: :wait")

      {:ok, conn} = Redix.start_link(url)
      ns = Keyword.fetch!(opts, :namespace)

      case Keyword.fetch(opts, :wait) do
        {:ok, {0, _timeout} = wait} ->
          {conn, ns, wait}

        {:ok, wait} ->
          k = Keyword.get(opts, :wait_connections, @default_wait_connections)

          wait_conns =
            for _ <- 1..k do
              {:ok, wait_conn} = Redix.start_link(url)
              wait_conn
            end

          {conn, ns, wait, List.to_tuple(wait_conns)}

        :error ->
          {conn, ns}
      end
    end

    defp check_wait_connections!(opts) do
      case {Keyword.fetch(opts, :wait_connections), Keyword.get(opts, :wait, {0, 0})} do
        {{:ok, _k}, {0, _timeout}} ->
          raise ArgumentError,
                "Normandy.Behaviours.SessionStore.Redis.new/1: :wait_connections needs a " <>
                  ":wait of one replica or more, got: " <>
                  if(Keyword.has_key?(opts, :wait), do: "a :wait of 0 replicas", else: "no :wait")

        _ ->
          :ok
      end
    end

    @doc false
    # The `config :normandy, :redis_wait` setting, checked: `Normandy.Cluster` reads it
    # once when it builds the Redis combo's specs and handles.
    @spec app_env_wait!() :: {non_neg_integer(), non_neg_integer()}
    def app_env_wait!,
      do:
        check_wait!(
          Application.get_env(:normandy, :redis_wait, {0, 0}),
          "SessionStore.Redis: the :redis_wait app env"
        )

    @impl true
    def append_entry(handle, session_id, %Entry{} = entry) do
      {conn, ns, wait} = write_target!(handle, session_id)
      fields = encode_entry_fields(entry)

      with {:ok, stream_id} <-
             Redix.command(conn, ["XADD", stream_key(ns, session_id), "*" | fields]),
           :ok <- wait(conn, wait) do
        # The id history/2 will return for this entry: the one it was written with, else
        # the stream id (the other stores return entry.id).
        {:ok, blank_to_nil(entry.id) || stream_id}
      end
    end

    @impl true
    def history(handle, session_id) do
      {conn, ns} = conn_ns(handle)

      case Redix.command(conn, ["XRANGE", stream_key(ns, session_id), "-", "+"]) do
        {:ok, raw} -> {:ok, decode_stream(raw)}
        {:error, reason} -> {:error, reason}
      end
    end

    # Reads the stream newest first, a page at a time, down to the last "compaction"
    # entry; only the entries from it on are decoded.
    @impl true
    def history_since_compaction(handle, session_id) do
      {conn, ns} = conn_ns(handle)

      case since_compaction(conn, stream_key(ns, session_id), "+", []) do
        {:ok, raw} -> {:ok, decode_stream(raw)}
        {:error, reason} -> {:error, reason}
      end
    end

    # `acc` holds the entries already read, chronological. `from` is "+" or an exclusive
    # "(id" below the last page.
    defp since_compaction(conn, key, from, acc) do
      case Redix.command(conn, ["XREVRANGE", key, from, "-", "COUNT", @since_page]) do
        {:ok, page} ->
          case Enum.split_while(page, &(not compaction_raw?(&1))) do
            {newer, [snapshot | _]} ->
              {:ok, [snapshot | Enum.reverse(newer, acc)]}

            {newer, []} when length(page) < @since_page ->
              {:ok, Enum.reverse(newer, acc)}

            {newer, []} ->
              [oldest_id, _kv] = List.last(page)
              since_compaction(conn, key, "(" <> oldest_id, Enum.reverse(newer, acc))
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp compaction_raw?([_stream_id, kv]), do: kv_to_map(kv)["role"] == "compaction"

    @impl true
    def fork(handle, session_id, from_entry_id) do
      {conn, ns} = conn_ns(handle)

      with {:ok, [_ | _] = raw} <-
             Redix.command(conn, ["XRANGE", stream_key(ns, session_id), "-", "+"]),
           true <- Enum.any?(raw, &entry_matches?(&1, from_entry_id)) do
        prefix = take_through(raw, from_entry_id)
        new_id = UUID.uuid4()

        case copy_prefix(conn, stream_key(ns, new_id), prefix) do
          :ok -> {:ok, new_id}
          {:error, _reason} = err -> err
        end
      else
        {:ok, []} -> {:error, :no_such_session}
        false -> {:error, :no_such_entry}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def save_turn_state(handle, session_id, term, inflight?) when is_boolean(inflight?) do
      {conn, ns, wait} = write_target!(handle, session_id)
      hset = ["HSET", meta_key(ns, session_id), "turn_state", encode(term)]

      # Not a MULTI: the index key is in another cluster slot. Ordered so a Redis crash
      # between the two leaves the index with an extra member (the reaper re-checks the
      # turn state), never without one: added before the state, removed after it.
      cmds =
        if inflight?,
          do: [["SADD", inflight_key(ns), session_id], hset],
          else: [hset, ["SREM", inflight_key(ns), session_id]]

      with {:ok, _} <- pipeline_ok(Redix.pipeline(conn, cmds)), do: wait(conn, wait)
    end

    @impl true
    def load_turn_state(handle, session_id) do
      {conn, ns} = conn_ns(handle)

      case Redix.command(conn, ["HGET", meta_key(ns, session_id), "turn_state"]) do
        {:ok, blob} when is_binary(blob) -> {:ok, decode(blob)}
        {:ok, nil} -> :error
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def save_config_template(handle, session_id, tmpl) do
      {conn, ns, wait} = write_target!(handle, session_id)

      rp =
        case tmpl do
          %{resume_policy: v} when is_atom(v) or is_binary(v) -> to_string(v)
          _ -> "lazy"
        end

      with {:ok, _} <-
             Redix.command(conn, [
               "HSET",
               meta_key(ns, session_id),
               "config_template",
               encode(tmpl),
               "resume_policy",
               rp
             ]) do
        wait(conn, wait)
      end
    end

    @impl true
    def load_config_template(handle, session_id) do
      {conn, ns} = conn_ns(handle)

      case Redix.command(conn, ["HGET", meta_key(ns, session_id), "config_template"]) do
        {:ok, blob} when is_binary(blob) -> {:ok, decode(blob)}
        {:ok, nil} -> :error
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def list_resumable(handle) do
      {conn, ns} = conn_ns(handle)

      case Redix.command(conn, ["SMEMBERS", inflight_key(ns)]) do
        {:ok, ids} -> {:ok, ids}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def delete_session(handle, session_id) do
      {conn, ns, wait} = write_target!(handle, session_id)

      # A fork copies its prefix into its own stream, so the session's keys are all its
      # own. The index entry goes last: a crash in between leaves an extra member whose
      # turn state is gone, which the reaper skips.
      cmds = [
        ["DEL", stream_key(ns, session_id), meta_key(ns, session_id)],
        ["SREM", inflight_key(ns), session_id]
      ]

      with {:ok, _} <- pipeline_ok(Redix.pipeline(conn, cmds)), do: wait(conn, wait)
    end

    # --- private ---

    # Fail-closed: block on replica ack at boundary writes when `wait:` is configured.
    # Default {0, 0} is a no-op (single Redis); >0 fails if the ack target is unmet.
    defp conn_ns({conn, ns}), do: {conn, ns}
    defp conn_ns({conn, ns, _wait}), do: {conn, ns}
    defp conn_ns({conn, ns, _wait, _wait_conns}), do: {conn, ns}

    # The connection a session's write and its WAIT run on, the namespace and the wait.
    # WAIT waits for the earlier writes of its own connection, so both share one; with
    # wait_conns a session always gets the same one, so its writes stay in order. A
    # handle with no wait of its own reads the :redis_wait app env before the write, so
    # a bad setting fails the write instead of following it.
    defp write_target!({conn, ns}, _session_id), do: {conn, ns, app_env_wait!()}
    defp write_target!({conn, ns, wait}, _session_id), do: {conn, ns, wait}

    defp write_target!({_conn, ns, wait, wait_conns}, session_id)
         when is_tuple(wait_conns) and tuple_size(wait_conns) > 0,
         do: {elem(wait_conns, :erlang.phash2(session_id, tuple_size(wait_conns))), ns, wait}

    defp write_target!({_conn, _ns, _wait, wait_conns}, _session_id) do
      raise ArgumentError,
            "Normandy.Behaviours.SessionStore.Redis: the handle's wait_conns must be a " <>
              "non-empty tuple of Redix connections, got: " <> Describe.type_of(wait_conns)
    end

    # WAIT with a 0 timeout blocks until the replicas answer, possibly forever, and
    # the connection is shared, so every later command would queue behind it.
    defp check_wait!({0, timeout} = wait, _what) when is_integer(timeout) and timeout >= 0,
      do: wait

    defp check_wait!({n, timeout} = wait, _what)
         when is_integer(n) and n > 0 and is_integer(timeout) and timeout > 0,
         do: wait

    defp check_wait!(other, what) do
      raise ArgumentError,
            "#{what} must be {numreplicas, timeout_ms} (non-negative " <>
              "integers; with replicas, timeout_ms must be positive), got: #{inspect(other)}"
    end

    defp wait(_conn, {0, _t}), do: :ok

    defp wait(conn, {n, t}) do
      case Redix.command(conn, ["WAIT", Integer.to_string(n), Integer.to_string(t)]) do
        {:ok, acked} when acked >= n -> :ok
        {:ok, acked} -> {:error, {:wait_unmet, acked, n}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp encode_entry_fields(%Entry{} = e) do
      [
        "id",
        e.id || "",
        "turn_id",
        e.turn_id || "",
        "role",
        e.role || "",
        "content",
        encode(e.content)
      ]
    end

    # XRANGE is chronological; reconstruct the linear parent chain so a rehydrated
    # `AgentMemory.from_entries/1` walks head -> parent_id back to the root (the
    # store models a single linear stream, not a parent graph). Without this, the
    # chain walk stops at the first nil parent and truncates history to the head.
    defp decode_stream(raw) do
      raw
      |> Enum.reduce({nil, []}, fn [stream_id, kv], {prev_id, acc} ->
        m = kv_to_map(kv)
        # The id the writer gave the entry (Turn.Server writes memory's), else the stream id
        # (entries written without one, including every entry before 2.0).
        id = blank_to_nil(m["id"]) || stream_id

        entry = %Entry{
          id: id,
          parent_id: prev_id,
          turn_id: blank_to_nil(m["turn_id"]),
          role: m["role"],
          content: decode(m["content"])
        }

        {id, [entry | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
    end

    # One pipeline per @copy_chunk entries. A failure part-way deletes the partial stream
    # (best effort: the fork's id was never returned, so nothing refers to it) and returns
    # the failure.
    defp copy_prefix(conn, dest_stream, prefix) do
      prefix
      |> Enum.chunk_every(@copy_chunk)
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        cmds = Enum.map(chunk, fn [_old_id, kv] -> ["XADD", dest_stream, "*" | kv] end)

        case pipeline_ok(Redix.pipeline(conn, cmds)) do
          {:ok, _} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        :ok ->
          :ok

        {:error, _reason} = error ->
          _ = Redix.command(conn, ["DEL", dest_stream])
          error
      end
    end

    # Redix returns a command's Redis error inside {:ok, results}: the first one fails the
    # whole write instead of being dropped.
    defp pipeline_ok({:ok, results}) do
      case Enum.find(results, &match?(%Redix.Error{}, &1)) do
        nil -> {:ok, results}
        %Redix.Error{} = error -> {:error, error}
      end
    end

    defp pipeline_ok({:error, _reason} = error), do: error

    defp take_through(raw, target_id) do
      raw
      |> Enum.reduce_while([], fn item, acc ->
        if entry_matches?(item, target_id),
          do: {:halt, Enum.reverse([item | acc])},
          else: {:cont, [item | acc]}
      end)
    end

    # An entry is addressed by the id history/2 returned: the stored `id` field, else the
    # stream id.
    # A blank or nil target matches nothing (a blank stored `id` field is not an address).
    defp entry_matches?([stream_id, kv], target_id) do
      case blank_to_nil(target_id) do
        target when is_binary(target) ->
          stream_id == target or blank_to_nil(kv_to_map(kv)["id"]) == target

        _ ->
          false
      end
    end

    defp kv_to_map(kv) do
      kv |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    end

    defp blank_to_nil(""), do: nil
    defp blank_to_nil(v), do: v

    defp stream_key(ns, sid), do: "#{ns}:{#{sid}}:stream"
    defp meta_key(ns, sid), do: "#{ns}:{#{sid}}:meta"

    # Intentionally a namespace-level (not per-session) key: no `{sid}` hash-tag, so it
    # lives in a different Redis Cluster slot than the session keys. This is safe because
    # it is never combined with session keys in a MULTI; the code uses pipelines, not
    # transactions.
    defp inflight_key(ns), do: "#{ns}:inflight"

    defp encode(term), do: Codec.encode(term)
    defp decode(bin) when is_binary(bin), do: Codec.decode(bin)
  end
end
