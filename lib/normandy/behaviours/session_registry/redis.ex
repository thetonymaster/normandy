# Compiled only when Redix is available (an `optional` dep).
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionRegistry.Redis do
    @moduledoc """
    Distributed `SessionRegistry` using Redis as the shared `session_id → pid` name
    table, with cross-node routing over **Erlang distribution** (Redis replaces Horde's
    CRDT, not distribution). A per-node owner GenServer monitors locally registered pids
    (clearing the key on `:DOWN`) and refreshes key TTLs so a crashed node's keys lapse on
    their own.

    The handle is a `Normandy.Behaviours.SessionRegistry.Redis.Handle`,
    `%Handle{owner:, conn:, namespace:}`: the owner's
    registered name, the Redix connection and the key namespace. `new/1` returns one;
    build one with `handle/1` from the values given to `start_link/1`, or with
    `fetch_handle/1` for an owner that opened its own connection from `:url`.
    `whereis/2` runs in the caller, on the handle's connection: a lookup never waits on
    the owner. `register/3` and `unregister/2` go through the owner, which monitors the
    pids. An owner started with `:url` registers its connection as
    `Module.concat(name, Redix)`, so a handle keeps working across owner restarts; that
    name is reserved for it, and an owner whose derived name another process holds fails
    to start with `{:error, {:connection_name_taken, name}}` (pass `:conn` or rename the
    owner). A handle is meant for the node its owner runs on: on another node, a lookup
    reaches the connection over distribution.

    Registration is atomic via `SET … NX` (no read-modify-write), so a concurrent start
    cluster-wide yields one winner; the losers route to it. Use as a `:via` registry
    through `child_name/2` (the via term is `{handle, session_id}`) to get atomic,
    supervisor-driven starts (closes the start race), exactly like the Horde impl.

    ## Refresh and lost ownership

    Every `ttl_ms / 2` the owner extends the TTL of each key it holds, in pipelines of
    1,000 `EVALSHA` calls. A key that lapsed (a late refresh, an eviction) is
    claimed again with `SET … NX`. A key another node now holds means two servers for
    one session: the owner stops its local process with exit reason
    `{:shutdown, :registration_lost}`, logs a warning and emits
    `[:normandy, :session_registry, :ownership_lost]`. A `Turn.Server` stopped this way
    is not restarted (`restart: :transient`); its session goes on where the key points.
    The stop is an exit signal: a registered process that traps exits receives it as a
    message and must stop itself; the owner no longer monitors it either way.
    """
    @behaviour Normandy.Behaviours.SessionRegistry
    use GenServer

    alias Normandy.Components.ContentBlock.Describe
    alias Normandy.Options

    require Logger

    @default_ttl_ms 60_000
    @refresh_chunk 1_000
    # How long a :url owner waits for a previous incarnation's connection to release
    # Module.concat(name, Redix) before refusing to start.
    @conn_name_wait_ms 5_000

    defmodule Handle do
      @moduledoc """
      A `SessionRegistry.Redis` handle: the owner's registered name, the Redix connection
      the caller looks keys up on, and the key namespace. Build it with
      `Normandy.Behaviours.SessionRegistry.Redis.handle/1`.
      """
      @enforce_keys [:owner, :conn, :namespace]
      defstruct [:owner, :conn, :namespace]

      @type t :: %__MODULE__{owner: atom(), conn: GenServer.server(), namespace: String.t()}
    end

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

    @handle_opts_schema NimbleOptions.new!(
                          owner: [
                            type: :atom,
                            required: true,
                            doc: "The owner's registered name (`start_link/1`'s `:name`)."
                          ],
                          conn: [
                            type: {:custom, __MODULE__, :conn, []},
                            type_doc: "`t:GenServer.server/0`",
                            required: true,
                            doc: "The Redix connection the owner uses (pid or name)."
                          ],
                          namespace: [
                            type: :string,
                            required: true,
                            doc: "The key namespace (`start_link/1`'s `:namespace`)."
                          ]
                        )

    @start_link_opts_schema NimbleOptions.new!(
                              name: [
                                type: :atom,
                                required: true,
                                doc: "The owner's registered name (the handle's `:owner`)."
                              ],
                              conn: [
                                type: {:custom, __MODULE__, :conn, []},
                                type_doc: "`t:GenServer.server/0`",
                                doc: "A started Redix connection (pid or name)."
                              ],
                              url: [
                                type: :string,
                                type_doc: "`t:String.t/0`",
                                doc:
                                  "A Redis URL to connect to when `:conn` is not given; the " <>
                                    "owner starts that connection linked, registered as " <>
                                    "`Module.concat(name, Redix)`, a name no other process " <>
                                    "may hold (the start fails with " <>
                                    "`{:error, {:connection_name_taken, name}}`)."
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

    @del_if_owner_sha :crypto.hash(:sha, @del_if_owner) |> Base.encode16(case: :lower)
    @pexpire_if_owner_sha :crypto.hash(:sha, @pexpire_if_owner) |> Base.encode16(case: :lower)

    # --- behaviour API (handle = %Handle{}) ---

    # In the caller, on the handle's connection: no owner hop, so a lookup never queues
    # behind a registration or a refresh. A stale value is deleted here too
    # (compare-and-delete, so a key another node re-claimed survives).
    @impl Normandy.Behaviours.SessionRegistry
    def whereis(%Handle{conn: conn, namespace: ns}, session_id) do
      key = reg_key(ns, session_id)

      case redis(conn, &Redix.command(&1, ["GET", key])) do
        {:ok, nil} ->
          :none

        {:ok, blob} when is_binary(blob) ->
          case decode_pid(blob) do
            {:ok, pid} -> {:ok, pid}
            :stale -> stale(conn, key, blob)
          end

        # An outage is not "no session": that would start a duplicate server.
        {:error, reason} ->
          {:error, reason}
      end
    end

    def whereis(other, _session_id), do: raise(ArgumentError, not_a_handle(:whereis, 2, other))

    @impl Normandy.Behaviours.SessionRegistry
    def register(%Handle{owner: owner}, session_id, pid),
      do: GenServer.call(owner, {:register, session_id, pid})

    def register(other, _session_id, _pid),
      do: raise(ArgumentError, not_a_handle(:register, 3, other))

    @impl Normandy.Behaviours.SessionRegistry
    def unregister(%Handle{owner: owner}, session_id),
      do: GenServer.call(owner, {:unregister, session_id})

    def unregister(other, _session_id),
      do: raise(ArgumentError, not_a_handle(:unregister, 2, other))

    @impl Normandy.Behaviours.SessionRegistry
    def child_name(%Handle{} = handle, session_id),
      do: {:via, Normandy.Behaviours.SessionRegistry.Redis.Via, {handle, session_id}}

    def child_name(other, _session_id),
      do: raise(ArgumentError, not_a_handle(:child_name, 2, other))

    # A 1.x handle was the owner's name: say what replaced it.
    defp not_a_handle(fun, arity, other) do
      "#{inspect(__MODULE__)}.#{fun}/#{arity}: expected a " <>
        "%#{inspect(Handle)}{} (build it with #{inspect(__MODULE__)}.handle/1), got: " <>
        Describe.type_of(other)
    end

    # --- lifecycle ---

    @doc """
    Test/default handle: starts an owner GenServer with its own Redix connection and
    returns its handle.

    ## Options

    #{Options.docs(@new_opts_schema)}
    """
    @spec new(keyword()) :: Handle.t()
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
      fetch_handle(name)
    end

    @doc """
    Builds the handle of an owner started with `start_link/1`'s `:name`, `:conn` and
    `:namespace`. Starts and calls nothing.

    ## Options

    #{Options.docs(@handle_opts_schema)}
    """
    @spec handle(keyword()) :: Handle.t()
    def handle(opts) do
      opts = Options.validate!(opts, @handle_opts_schema, {__MODULE__, :handle, 1})

      %Handle{
        owner: Keyword.fetch!(opts, :owner),
        conn: Keyword.fetch!(opts, :conn),
        namespace: Keyword.fetch!(opts, :namespace)
      }
    end

    @doc """
    The handle of a running owner, asked of it once: for an owner started with `:url`,
    whose connection only the owner knows. Keep the result; a lookup with it never calls
    the owner. The handle names the owner's connection (`Module.concat(owner, Redix)`
    for a `:url` owner, else the `:conn` given), so it stays valid when the owner
    restarts under the same name, as long as a `:conn` given by name is restarted too.
    """
    @spec fetch_handle(atom()) :: Handle.t()
    def fetch_handle(owner) when is_atom(owner), do: GenServer.call(owner, :handle)

    @doc """
    Starts the per-node owner GenServer. Build the handle with `handle/1` from the same
    `:name`, `:conn` and `:namespace`, or with `fetch_handle/1` when the owner connects
    from `:url`.

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
           Describe.type_of(other)}

    @impl GenServer
    def init(opts) do
      name = Keyword.fetch!(opts, :name)

      case Keyword.get(opts, :conn) do
        nil ->
          case start_own_conn(Keyword.fetch!(opts, :url), conn_name(name)) do
            {:ok, conn} -> init_state(opts, conn, true)
            {:error, reason} -> {:stop, reason}
          end

        supplied ->
          init_state(opts, supplied, false)
      end
    end

    defp init_state(opts, conn, own_conn?) do
      name = Keyword.fetch!(opts, :name)
      ttl = Keyword.fetch!(opts, :ttl_ms)
      {:ok, _ref} = :timer.send_interval(div(ttl, 2), :refresh)

      {:ok,
       %{
         name: name,
         conn: conn,
         own_conn?: own_conn?,
         ns: Keyword.fetch!(opts, :namespace),
         ttl: ttl,
         mons: %{},
         sids: %{}
       }}
    end

    # The name is derived from the owner's registered name (host configuration, one
    # atom per owner), never from input, so a handle fetched once names the connection
    # of every later incarnation of the owner.
    defp conn_name(owner), do: Module.concat(owner, Redix)

    # The connection is linked to the owner and terminate/2 stops it on a callback stop,
    # so a previous incarnation's connection is dead or still exiting (its exit signal can
    # land after the supervisor restarted us): wait for it, bounded. A holder still alive
    # after that is not ours (a host process under the same name) and is never touched.
    defp start_own_conn(url, name, retry? \\ true) do
      case Redix.start_link(url, name: name) do
        {:ok, conn} ->
          {:ok, conn}

        {:error, {:already_started, holder}} when retry? ->
          if exited?(holder), do: start_own_conn(url, name, false), else: name_taken(name)

        {:error, {:already_started, _holder}} ->
          name_taken(name)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp exited?(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> true
      after
        @conn_name_wait_ms ->
          Process.demonitor(ref, [:flush])
          false
      end
    end

    defp name_taken(name) do
      Logger.error(
        "SessionRegistry.Redis could not start its Redis connection: the name " <>
          "#{inspect(name)} is in use by another process. Pass the owner a started " <>
          "connection with :conn, or give the owner a :name whose " <>
          "Module.concat(name, Redix) is free"
      )

      {:error, {:connection_name_taken, name}}
    end

    @impl GenServer
    def terminate(_reason, %{own_conn?: true, conn: conn}) do
      # Only callback-initiated stops get here (the owner does not trap exits); a
      # linked connection would survive a :normal stop.
      Process.exit(conn, :shutdown)
      :ok
    end

    def terminate(_reason, _s), do: :ok

    @impl GenServer
    def handle_call({:register, sid, pid}, _from, s) do
      cmd = ["SET", reg_key(s.ns, sid), :erlang.term_to_binary(pid), "NX", "PX", to_string(s.ttl)]

      case redis(s.conn, &Redix.command(&1, cmd)) do
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

    def handle_call(:handle, _from, s),
      do: {:reply, %Handle{owner: s.name, conn: handle_conn(s), namespace: s.ns}, s}

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
      s = s.sids |> Enum.chunk_every(@refresh_chunk) |> Enum.reduce(s, &refresh_chunk/2)
      {:noreply, s}
    end

    def handle_info(_msg, s), do: {:noreply, s}

    # An owned connection is named (see conn_name/1): the handle carries the name, which
    # outlives this process; a supplied :conn is passed through as given.
    defp handle_conn(%{own_conn?: true, name: name}), do: conn_name(name)
    defp handle_conn(%{conn: conn}), do: conn

    # A pid is routable iff it is alive, on this node or on a connected node.
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

    defp stale(conn, key, blob) do
      _ = del_if_owner(conn, key, blob)
      :none
    end

    # A remote pid is asked on its own node, as Horde's lookup does: a server that just
    # stopped (passivated) on a connected node is stale at once, not only after that
    # node's owner sees its :DOWN and deletes the key. A node that is not connected, or
    # that disconnects during the call, holds no live session.
    defp alive?(pid) when node(pid) == node(), do: Process.alive?(pid)

    defp alive?(pid) do
      node = node(pid)
      node in Node.list() and :erpc.call(node, Process, :alive?, [pid])
    catch
      :error, {:erpc, :noconnection} -> false
    end

    defp reg_key(ns, sid), do: "#{ns}:reg:{#{sid}}"

    defp del_if_owner(conn, key, value) do
      redis(conn, fn c ->
        case Redix.command(c, ["EVALSHA", @del_if_owner_sha, "1", key, value]) do
          {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
            Redix.command(c, ["EVAL", @del_if_owner, "1", key, value])

          other ->
            other
        end
      end)
    end

    # One pipeline of compare-and-PEXPIRE per chunk. 1: still ours, TTL extended.
    # 0: the key lapsed or another node holds it (reclaim/4 tells which).
    defp refresh_chunk(chunk, s) do
      case pexpire_chunk(s, chunk) do
        {:ok, results} ->
          chunk
          |> Enum.zip(results)
          |> Enum.reduce(s, fn {{sid, {pid, ref}}, result}, s ->
            refreshed(s, sid, pid, ref, result)
          end)

        {:error, reason} ->
          Logger.warning(
            "SessionRegistry.Redis #{inspect(s.name)} could not refresh " <>
              "#{length(chunk)} registrations (#{Describe.reason_tag(reason)}); " <>
              "retrying at the next refresh"
          )

          s
      end
    end

    defp pexpire_chunk(s, chunk) do
      cmds =
        Enum.map(chunk, fn {sid, {pid, _ref}} ->
          ["EVALSHA", @pexpire_if_owner_sha, "1", reg_key(s.ns, sid)] ++
            [:erlang.term_to_binary(pid), Integer.to_string(s.ttl)]
        end)

      redis(s.conn, &pexpire_pipeline(&1, cmds))
    end

    defp pexpire_pipeline(conn, cmds) do
      with {:ok, results} <- Redix.pipeline(conn, cmds) do
        if Enum.any?(results, &noscript?/1),
          do: reload_and_retry(conn, cmds),
          else: {:ok, results}
      end
    end

    # A restarted or flushed server forgot the script: load it, send the chunk again
    # (PEXPIRE is idempotent).
    defp reload_and_retry(conn, cmds) do
      with {:ok, _sha} <- Redix.command(conn, ["SCRIPT", "LOAD", @pexpire_if_owner]),
           do: Redix.pipeline(conn, cmds)
    end

    defp noscript?(%Redix.Error{message: "NOSCRIPT" <> _}), do: true
    defp noscript?(_result), do: false

    defp refreshed(s, _sid, _pid, _ref, 1), do: s
    defp refreshed(s, sid, pid, ref, 0), do: reclaim(s, sid, pid, ref)

    defp refreshed(s, sid, _pid, _ref, %Redix.Error{} = error) do
      Logger.warning(
        "SessionRegistry.Redis #{inspect(s.name)} could not refresh session " <>
          "#{inspect(sid)} (#{Describe.reason_tag(error)}); retrying at the next refresh"
      )

      s
    end

    # The key is not ours any more. If it lapsed, SET NX takes it back. If another node
    # holds it, two processes claim one session: stop ours.
    defp reclaim(s, sid, pid, ref) do
      cmd = ["SET", reg_key(s.ns, sid), :erlang.term_to_binary(pid), "NX", "PX"]

      case redis(s.conn, &Redix.command(&1, cmd ++ [Integer.to_string(s.ttl)])) do
        {:ok, "OK"} ->
          s

        {:ok, nil} ->
          fence(s, sid, pid, ref)

        {:error, reason} ->
          Logger.warning(
            "SessionRegistry.Redis #{inspect(s.name)} could not re-claim session " <>
              "#{inspect(sid)} (#{Describe.reason_tag(reason)}); retrying at the next refresh"
          )

          s
      end
    end

    defp fence(s, sid, pid, ref) do
      Process.demonitor(ref, [:flush])

      Logger.warning(
        "SessionRegistry.Redis #{inspect(s.name)}: session #{inspect(sid)} is registered " <>
          "by another process; stopping the local one"
      )

      :telemetry.execute(
        [:normandy, :session_registry, :ownership_lost],
        %{count: 1},
        %{session_id: sid, registry: s.name}
      )

      Process.exit(pid, {:shutdown, :registration_lost})
      %{s | mons: Map.delete(s.mons, ref), sids: Map.delete(s.sids, sid)}
    end

    # A Redix call that cannot exit or raise: a connection that is not running is
    # {:error, :noproc}, one that dies mid-call {:error, {:exit, tag}}.
    defp redis(conn, fun) do
      case GenServer.whereis(conn) do
        nil -> {:error, :noproc}
        server -> fun.(server)
      end
    catch
      :exit, reason -> {:error, {:exit, exit_tag(reason)}}
    end

    defp exit_tag(reason) when is_atom(reason), do: reason

    defp exit_tag(reason)
         when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
         do: elem(reason, 0)

    defp exit_tag(_reason), do: :unknown

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
