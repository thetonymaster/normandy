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

    The `handle` is `{conn, namespace}` (the host owns the Redix connection, Oban-style).
    All of a session's keys share a `{sid}` hash-tag so multi-key reads/forks stay in one
    Redis Cluster slot. Opaque values use `term_to_binary` / `binary_to_term(_, [:safe])`.

    Durability is the operator's Redis config (AOF recommended). For the fail-closed
    invariant, pass `wait: {numreplicas, timeout_ms}` so boundary writes block on
    replica acknowledgement and fail the turn if unmet.
    """
    @behaviour Normandy.Behaviours.SessionStore

    alias Normandy.Components.AgentMemory.Entry

    @doc "Test/default handle: a Redix conn to the configured URL + a unique namespace."
    @spec new(keyword()) :: {pid(), binary()}
    def new(opts \\ []) do
      url =
        Keyword.get(
          opts,
          :url,
          Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
        )

      {:ok, conn} = Redix.start_link(url)
      ns = Keyword.get(opts, :namespace, "normandy_test_#{System.unique_integer([:positive])}")
      {conn, ns}
    end

    @impl true
    def append_entry({conn, ns}, session_id, %Entry{} = entry) do
      fields = encode_entry_fields(entry)

      case Redix.command(conn, ["XADD", stream_key(ns, session_id), "*" | fields]) do
        {:ok, id} -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def history({conn, ns}, session_id) do
      case Redix.command(conn, ["XRANGE", stream_key(ns, session_id), "-", "+"]) do
        {:ok, raw} -> {:ok, decode_stream(raw)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def fork({conn, ns}, session_id, from_entry_id) do
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
    def save_turn_state({conn, ns} = handle, session_id, term) do
      with {:ok, _} <-
             Redix.command(conn, ["HSET", meta_key(ns, session_id), "turn_state", encode(term)]) do
        wait(handle)
      end
    end

    @impl true
    def load_turn_state({conn, ns}, session_id) do
      case Redix.command(conn, ["HGET", meta_key(ns, session_id), "turn_state"]) do
        {:ok, blob} when is_binary(blob) -> {:ok, decode(blob)}
        _ -> :error
      end
    end

    @impl true
    def save_config_template({conn, ns} = handle, session_id, tmpl) do
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
        {:ok, _} -> wait(handle)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def load_config_template({conn, ns}, session_id) do
      case Redix.command(conn, ["HGET", meta_key(ns, session_id), "config_template"]) do
        {:ok, blob} when is_binary(blob) -> {:ok, decode(blob)}
        _ -> :error
      end
    end

    @impl true
    def list_resumable({conn, ns}) do
      case Redix.command(conn, ["SMEMBERS", resumable_key(ns)]) do
        {:ok, ids} -> {:ok, ids}
        {:error, reason} -> {:error, reason}
      end
    end

    # --- private ---

    # Fail-closed: block on replica ack at boundary writes when `wait:` is configured.
    # Default {0, 0} is a no-op (single Redis); >0 fails if the ack target is unmet.
    defp wait({conn, _ns}, num \\ nil, timeout \\ nil) do
      {n, t} = Application.get_env(:normandy, :redis_wait, {0, 0})
      n = num || n
      t = timeout || t

      if n > 0 do
        case Redix.command(conn, ["WAIT", Integer.to_string(n), Integer.to_string(t)]) do
          {:ok, acked} when acked >= n -> :ok
          {:ok, acked} -> {:error, {:wait_unmet, acked, n}}
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
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

    defp encode(term), do: :erlang.term_to_binary(term)
    defp decode(bin) when is_binary(bin), do: :erlang.binary_to_term(bin, [:safe])
  end
end
