# Compiled only when Redix is available (an `optional` dep).
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionRegistry.Redis do
    @moduledoc """
    Distributed `SessionRegistry` using Redis as the shared `session_id → pid` name
    table, with cross-node routing over **Erlang distribution** (Redis replaces Horde's
    CRDT, not distribution). A per-node owner GenServer holds the Redix connection,
    monitors locally-registered pids (clearing the key on `:DOWN`), and refreshes key
    TTLs so a crashed node's keys lapse on their own.

    The `handle` is the owner's registered name. Registration is atomic via `SET … NX`
    (no read-modify-write), so a concurrent start cluster-wide yields one winner; the
    losers route to it. Use as a `:via` registry through `child_name/2` to get
    atomic, supervisor-driven starts (closes the start race), exactly like the Horde impl.
    """
    @behaviour Normandy.Behaviours.SessionRegistry
    use GenServer

    @default_ttl_ms 60_000

    # Compare-and-delete: remove the key only if it still holds OUR value, so a
    # node never evicts a key another node re-claimed after a TTL lapse.
    @del_if_owner ~S{if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end}

    @pexpire_if_owner ~S{if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("PEXPIRE", KEYS[1], ARGV[2]) else return 0 end}

    # --- behaviour API (handle = owner name) ---

    @impl Normandy.Behaviours.SessionRegistry
    def whereis(owner, session_id), do: GenServer.call(owner, {:whereis, session_id})

    @impl Normandy.Behaviours.SessionRegistry
    def register(owner, session_id, pid), do: GenServer.call(owner, {:register, session_id, pid})

    @impl Normandy.Behaviours.SessionRegistry
    def unregister(owner, session_id), do: GenServer.call(owner, {:unregister, session_id})

    @impl Normandy.Behaviours.SessionRegistry
    def child_name(owner, session_id),
      do: {:via, Normandy.Behaviours.SessionRegistry.Redis.Via, {owner, session_id}}

    # --- lifecycle ---

    @doc "Test/default handle: start a Redix conn + owner GenServer; return the owner name."
    @spec new(keyword()) :: atom()
    def new(opts \\ []) do
      name =
        Keyword.get_lazy(opts, :name, fn ->
          :"redis_registry_#{System.unique_integer([:positive])}"
        end)

      url =
        Keyword.get(
          opts,
          :url,
          Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
        )

      ns = Keyword.get(opts, :namespace, "normandy_reg_#{UUID.uuid4()}")
      {:ok, _pid} = start_link(name: name, url: url, namespace: ns)
      name
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl GenServer
    def init(opts) do
      conn =
        case Keyword.get(opts, :conn) do
          nil ->
            {:ok, c} = Redix.start_link(Keyword.fetch!(opts, :url))
            c

          supplied ->
            supplied
        end

      ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
      {:ok, _ref} = :timer.send_interval(div(ttl, 2), :refresh)

      {:ok, %{conn: conn, ns: Keyword.fetch!(opts, :namespace), ttl: ttl, mons: %{}, sids: %{}}}
    end

    @impl GenServer
    def handle_call({:register, sid, pid}, _from, s) do
      cmd = ["SET", reg_key(s.ns, sid), :erlang.term_to_binary(pid), "NX", "PX", to_string(s.ttl)]

      case Redix.command(s.conn, cmd) do
        {:ok, "OK"} ->
          s = drop_existing(s, sid)
          ref = Process.monitor(pid)

          {:reply, :ok,
           %{s | mons: Map.put(s.mons, ref, sid), sids: Map.put(s.sids, sid, {pid, ref})}}

        {:ok, nil} ->
          {:reply, {:error, :taken}, s}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    end

    def handle_call({:whereis, sid}, _from, s) do
      reply =
        case Redix.command(s.conn, ["GET", reg_key(s.ns, sid)]) do
          {:ok, nil} ->
            :none

          {:ok, blob} when is_binary(blob) ->
            # Stored values are this registry's own routing pids (trusted, not user data),
            # so plain binary_to_term is used. `[:safe]` blocks creating NEW atoms while
            # decoding; a pid embeds its node atom, so `[:safe]` would raise only for a pid
            # from a node whose atom isn't already known locally — which we must still route.
            pid = :erlang.binary_to_term(blob)

            if alive?(pid) do
              {:ok, pid}
            else
              _ = del_if_owner(s.conn, reg_key(s.ns, sid), blob)
              :none
            end

          {:error, _} ->
            :none
        end

      {:reply, reply, s}
    end

    def handle_call({:unregister, sid}, _from, s) do
      s =
        case Map.pop(s.sids, sid) do
          {{pid, ref}, sids} ->
            Process.demonitor(ref, [:flush])
            _ = del_if_owner(s.conn, reg_key(s.ns, sid), :erlang.term_to_binary(pid))
            %{s | sids: sids, mons: Map.delete(s.mons, ref)}

          {nil, _} ->
            s
        end

      {:reply, :ok, s}
    end

    @impl GenServer
    def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
      s =
        case Map.pop(s.mons, ref) do
          {nil, _} ->
            s

          {sid, mons} ->
            _ = del_if_owner(s.conn, reg_key(s.ns, sid), :erlang.term_to_binary(pid))
            %{s | mons: mons, sids: Map.delete(s.sids, sid)}
        end

      {:noreply, s}
    end

    def handle_info(:refresh, s) do
      Enum.each(s.sids, fn {sid, {pid, _ref}} ->
        pexpire_if_owner(s.conn, reg_key(s.ns, sid), :erlang.term_to_binary(pid), s.ttl)
      end)

      {:noreply, s}
    end

    def handle_info(_msg, s), do: {:noreply, s}

    # A pid is routable iff it lives on this node (and is alive) or on a connected node.
    # A pid on a node no longer in the cluster is treated as dead → triggers rehydrate.
    defp alive?(pid) do
      cond do
        node(pid) == node() -> Process.alive?(pid)
        node(pid) in Node.list() -> true
        true -> false
      end
    end

    defp reg_key(ns, sid), do: "#{ns}:reg:{#{sid}}"

    defp del_if_owner(conn, key, value) do
      Redix.command(conn, ["EVAL", @del_if_owner, "1", key, value])
    end

    defp pexpire_if_owner(conn, key, value, ttl) do
      Redix.command(conn, ["EVAL", @pexpire_if_owner, "1", key, value, to_string(ttl)])
    end

    defp drop_existing(s, sid) do
      case Map.pop(s.sids, sid) do
        {{_pid, ref}, sids} ->
          Process.demonitor(ref, [:flush])
          %{s | sids: sids, mons: Map.delete(s.mons, ref)}

        {nil, _} ->
          s
      end
    end
  end
end
