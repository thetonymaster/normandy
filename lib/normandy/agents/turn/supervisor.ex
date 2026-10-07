defmodule Normandy.Agents.Turn.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Turn.Server` processes (one per live session).

  A crashed session restarts (`restart: :transient`) and reloads its turn state
  and memory from the store. See `start_link/1` for options.
  """
  use DynamicSupervisor

  alias Normandy.Agents.Turn.Server
  alias Normandy.Options

  @default_max_restarts 100
  @default_max_seconds 5

  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the supervisor."],
                            max_restarts: [
                              type: :non_neg_integer,
                              default: @default_max_restarts,
                              doc:
                                "Restarts allowed within `:max_seconds`. The limit is shared by " <>
                                  "every session under this supervisor; exceeding it stops the " <>
                                  "supervisor and all of its sessions. The OTP default (3 in 5 " <>
                                  "seconds) would let a few unrelated session crashes take every " <>
                                  "session down."
                            ],
                            max_seconds: [
                              type: :pos_integer,
                              default: @default_max_seconds,
                              doc: "The window for `:max_restarts`, in seconds."
                            ]
                          )

  @doc false
  def default_restart_limit,
    do: [max_restarts: @default_max_restarts, max_seconds: @default_max_seconds]

  @doc """
  Starts the supervisor.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
    name = Keyword.get(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: Keyword.fetch!(opts, :max_restarts),
      max_seconds: Keyword.fetch!(opts, :max_seconds)
    )
  end

  @doc """
  Starts a `Turn.Server` for a session under `sup`, named through the registry's
  `child_name/2` when it has one.

  `server_opts` are checked here, in the caller, before the supervisor starts anything:
  a bad option raises `ArgumentError` instead of coming back as the supervisor's
  `{:error, {exception, stacktrace}}`.

  Returns `{:ok, pid}`, or:

    * `{:error, {:already_started, pid}}`: a server for the session is already registered
      (under a `:via` name, or found by a self-registering server); route to `pid`.
    * `{:error, :registration_race}`: a self-registering server found the session taken,
      but the holder died before its lookup; start again.
    * `{:error, reason}`: the registry could not answer that lookup, or the supervisor
      refused the child.

  The session is loaded after the start returns, so a store or template failure is not a
  start error (the server waits `:unavailable`).

  ## Options

  The options of `Normandy.Agents.Turn.Server.start_link/1`.
  """
  @spec start_server(:gen_statem.server_ref() | pid(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_server(sup, server_opts) do
    server_opts =
      server_opts
      |> Options.validate!(Server.__opts_schema__(:start_link), {__MODULE__, :start_server, 2})
      |> reject_name!()
      |> put_child_name()

    spec = %{
      id: Server,
      start: {Server, :start_link, [server_opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
  end

  @doc """
  Stops the session server `pid`, a child of `sup`, without a restart. Returns
  `{:error, :not_found}` when `pid` is not a child of `sup` (it already exited, or another
  supervisor started it). Used by `Normandy.Agents.Turn.Session.delete/1`.
  """
  @spec stop_server(:gen_statem.server_ref() | pid(), pid()) :: :ok | {:error, :not_found}
  def stop_server(sup, pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(sup, pid)

  # Turn.Server.start_link/1 takes :name, but here the registry names the server; a
  # caller's :name would be replaced (or, with a self-registering registry, used instead).
  defp reject_name!(opts) do
    if Keyword.has_key?(opts, :name) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.start_server/2: :name is not an option here; the " <>
              "supervisor names the server through the registry's child_name/2"
    end

    opts
  end

  defp put_child_name(opts) do
    {mod, handle} = Keyword.fetch!(opts, :registry)
    sid = Keyword.fetch!(opts, :session_id)

    name =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :child_name, 2),
        do: mod.child_name(handle, sid),
        else: :self_register

    case name do
      :self_register -> opts
      via -> Keyword.put(opts, :name, via)
    end
  end
end
