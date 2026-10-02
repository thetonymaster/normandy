# Compiled only when Redix is available (an `optional` dep). Tier-0 users who omit it
# simply don't get this module.
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionStore.Redis do
    @moduledoc """
    Durable `SessionStore` over Redis, modelled on Redis Streams. The conversation is an
    append-only stream (`XADD`/`XRANGE`) so appends are atomic and O(1) with no
    read-modify-write — concurrent appends never lose an entry. Session metadata
    (turn state, config template, resume policy) lives in a hash; eager session_ids live
    in a SET for `list_resumable/1`.

    The `handle` is `{conn, namespace}` or `{conn, namespace, wait}` (the host owns the
    Redix connection, Oban-style).
    All of a session's keys share a `{sid}` hash-tag so multi-key reads/forks stay in one
    Redis Cluster slot. Opaque values use `term_to_binary` / `binary_to_term(_, [:safe])`.

    Durability is the operator's Redis config (AOF recommended). For the fail-closed
    invariant, set `wait: {numreplicas, timeout_ms}` (`new/1` option, or the third
    handle element): every write (entry appends, turn state, config template) then
    blocks on replica acknowledgement and returns `{:error, {:wait_unmet, acked, n}}`
    if unmet. Without it, `config :normandy, :redis_wait, {n, timeout_ms}` applies;
    the default `{0, 0}` does not wait. With replicas, `timeout_ms` must be positive:
    Redis treats 0 as wait forever, which would stall the shared connection.
    """
    @behaviour Normandy.Behaviours.SessionStore

    alias Normandy.Behaviours.SessionStore.Codec
    alias Normandy.Components.AgentMemory.Entry

    @doc "Test/default handle: a Redix conn to the configured URL + a unique namespace."
    @spec new(keyword()) ::
            {pid(), binary()} | {pid(), binary(), {non_neg_integer(), non_neg_integer()}}
    def new(opts \\ []) do
      url =
        Keyword.get(
          opts,
          :url,
          Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
        )

      # Checked before connecting, so a bad setting starts nothing.
      _ =
        with {:ok, wait} <- Keyword.fetch(opts, :wait),
             do: check_wait!(wait, "SessionStore.Redis.new/1: :wait")

      {:ok, conn} = Redix.start_link(url)
      ns = Keyword.get(opts, :namespace, "normandy_test_#{UUID.uuid4()}")

      case Keyword.fetch(opts, :wait) do
        {:ok, wait} -> {conn, ns, check_wait!(wait, "SessionStore.Redis.new/1: :wait")}
        :error -> {conn, ns}
      end
    end

    @impl true
    def append_entry(handle, session_id, %Entry{} = entry) do
      {conn, ns} = conn_ns(handle)
      wait = wait_setting!(handle)
      fields = encode_entry_fields(entry)

      with {:ok, id} <- Redix.command(conn, ["XADD", stream_key(ns, session_id), "*" | fields]),
           :ok <- wait(conn, wait) do
        {:ok, id}
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

    @impl true
    def fork(handle, session_id, from_entry_id) do
      {conn, ns} = conn_ns(handle)

      with {:ok, [_ | _] = raw} <-
             Redix.command(conn, ["XRANGE", stream_key(ns, session_id), "-", "+"]),
           true <- Enum.any?(raw, fn [id, _fields] -> id == from_entry_id end) do
        prefix = take_through(raw, from_entry_id)
        new_id = "fork_#{System.unique_integer([:positive])}"

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
    def save_turn_state(handle, session_id, term) do
      {conn, ns} = conn_ns(handle)
      wait = wait_setting!(handle)

      with {:ok, _} <-
             Redix.command(conn, ["HSET", meta_key(ns, session_id), "turn_state", encode(term)]) do
        wait(conn, wait)
      end
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
      {conn, ns} = conn_ns(handle)
      wait = wait_setting!(handle)

      rp =
        case tmpl do
          %{resume_policy: v} when is_atom(v) or is_binary(v) -> to_string(v)
          _ -> "lazy"
        end

      cmds = [
        ["HSET", meta_key(ns, session_id), "config_template", encode(tmpl), "resume_policy", rp],
        if(rp == "eager",
          do: ["SADD", resumable_key(ns), session_id],
          else: ["SREM", resumable_key(ns), session_id]
        )
      ]

      case Redix.pipeline(conn, cmds) do
        {:ok, _} -> wait(conn, wait)
        {:error, reason} -> {:error, reason}
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

      case Redix.command(conn, ["SMEMBERS", resumable_key(ns)]) do
        {:ok, ids} -> {:ok, ids}
        {:error, reason} -> {:error, reason}
      end
    end

    # --- private ---

    # Fail-closed: block on replica ack at boundary writes when `wait:` is configured.
    # Default {0, 0} is a no-op (single Redis); >0 fails if the ack target is unmet.
    defp conn_ns({conn, ns}), do: {conn, ns}
    defp conn_ns({conn, ns, _wait}), do: {conn, ns}

    # The handle's wait setting, else the :redis_wait app env, else no wait. Read
    # before a write, so a bad setting fails the write instead of following it.
    defp wait_setting!({_conn, _ns, wait}), do: wait

    defp wait_setting!({_conn, _ns}),
      do:
        check_wait!(
          Application.get_env(:normandy, :redis_wait, {0, 0}),
          "SessionStore.Redis: the :redis_wait app env"
        )

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

        entry = %Entry{
          id: stream_id,
          parent_id: prev_id,
          turn_id: blank_to_nil(m["turn_id"]),
          role: m["role"],
          content: decode(m["content"])
        }

        {stream_id, [entry | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
    end

    defp copy_prefix(conn, dest_stream, prefix) do
      Enum.reduce_while(prefix, :ok, fn [_old_id, kv], :ok ->
        case Redix.command(conn, ["XADD", dest_stream, "*" | kv]) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp take_through(raw, target_id) do
      raw
      |> Enum.reduce_while([], fn [id, _] = item, acc ->
        if id == target_id, do: {:halt, Enum.reverse([item | acc])}, else: {:cont, [item | acc]}
      end)
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
    defp resumable_key(ns), do: "#{ns}:resumable"

    defp encode(term), do: Codec.encode(term)
    defp decode(bin) when is_binary(bin), do: Codec.decode(bin)
  end
end
