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

    alias Normandy.Options

    @default_ttl_ms 60_000

    @new_opts_schema NimbleOptions.new!(
                       name: [type: :atom, doc: "The owner's name (default: a unique one)."],
                       url: [
                         type: :string,
                         type_doc: "`t:String.t/0`",
                         doc: "The Redis URL (default: `config :normandy, :redis_url`)."
                       ],
                       namespace: [
                         type: :string,
                         doc: "The key namespace (default: a unique one)."
                       ]
                     )

    @start_link_opts_schema NimbleOptions.new!(
                              name: [
                                type: :atom,
                                required: true,
                                doc: "The owner's registered name, which is also the handle."
                              ],
                              conn: [
                                type: {:custom, __MODULE__, :conn, []},
                                type_doc: "`t:GenServer.server/0`",
                                doc: "A started Redix connection (pid or name)."
                              ],
                              url: [
                                type: :string,
                                type_doc: "`t:String.t/0`",
                                doc: "A Redis URL to connect to when `:conn` is not given."
                              ],
                              namespace: [
                                type: :string,
                                required: true,
                                doc: "The key namespace."
                              ],
                              ttl_ms: [
                                type: :pos_integer,
                                default: @default_ttl_ms,
                                doc:
                                  "Registration TTL in ms, refreshed every `ttl_ms / 2`; a dead " <>
                                    "node's keys lapse after it."
                              ]
                            )

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

    @doc """
    Test/default handle: start a Redix conn + owner GenServer; return the owner name.

    ## Options

    #{Options.docs(@new_opts_schema)}
    """
    @spec new(keyword()) :: atom()
    def new(opts \\ []) do
      opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

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

    @doc """
    Starts the per-node owner GenServer, which holds the Redix connection.

    ## Options

    #{Options.docs(@start_link_opts_schema)}
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

      unless Keyword.has_key?(opts, :conn) or Keyword.has_key?(opts, :url) do
        raise ArgumentError,
              "Normandy.Behaviours.SessionRegistry.Redis.start_link/1: requires :conn (a Redix " <>
                "connection) or :url"
      end

      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @doc false
    # A NimbleOptions custom type: a pid or a registered name, never nil (a nil :conn
    # would pass the :conn-or-:url check and then fail in init/1).
    @spec conn(term()) :: {:ok, GenServer.server()} | {:error, String.t()}
    def conn(conn) when is_pid(conn), do: {:ok, conn}
    def conn(conn) when is_atom(conn) and conn != nil, do: {:ok, conn}
    def conn({:global, _name} = conn), do: {:ok, conn}
    def conn({:via, mod, _name} = conn) when is_atom(mod), do: {:ok, conn}
    def conn({name, node} = conn) when is_atom(name) and is_atom(node), do: {:ok, conn}

    def conn(other),
      do:
        {:error,
         "expected a Redix connection (a pid or a registered name), got: " <>
           Normandy.Components.ContentBlock.Describe.type_of(other)}

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

      ttl = Keyword.fetch!(opts, :ttl_ms)
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
            case decode_pid(blob) do
              {:ok, pid} -> {:ok, pid}
              :stale -> stale(s, sid, blob)
            end

          # An outage is not "no session": that would start a duplicate server.
          {:error, reason} ->
            {:error, reason}
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
    # The keyspace is shared, so another client may have written the value.
    # `[:safe]` creates no atoms; it refuses a pid only when its node atom is
    # unknown here, and such a node is not connected, so the pid is not live
    # anyway (see alive?/1). A value that is not a pid is no session either.
    defp decode_pid(blob) do
      case :erlang.binary_to_term(blob, [:safe]) do
        pid when is_pid(pid) -> if alive?(pid), do: {:ok, pid}, else: :stale
        _other -> :stale
      end
    rescue
      ArgumentError -> :stale
    end

    defp stale(s, sid, blob) do
      _ = del_if_owner(s.conn, reg_key(s.ns, sid), blob)
      :none
    end

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
