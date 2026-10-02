defmodule Normandy.Agents.Turn.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Turn.Server` processes (one per live session).

  ## Options

    * `:name` - optional registered name
    * `:max_restarts` / `:max_seconds` - restart limit (default 100 in 5 seconds).
      The limit is shared by every session under this supervisor; exceeding it
      stops the supervisor and all of its sessions. The OTP default (3 in 5
      seconds) would let a few unrelated session crashes take every session down.

  A crashed session restarts (`restart: :transient`) and reloads its turn state
  and memory from the store.
  """
  use DynamicSupervisor

  alias Normandy.Agents.Turn.Server

  @default_max_restarts 100
  @default_max_seconds 5

  @doc false
  def default_restart_limit,
    do: [max_restarts: @default_max_restarts, max_seconds: @default_max_seconds]

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: Keyword.get(opts, :max_restarts, @default_max_restarts),
      max_seconds: Keyword.get(opts, :max_seconds, @default_max_seconds)
    )
  end

  @spec start_server(:gen_statem.server_ref() | pid(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_server(sup, server_opts) do
    server_opts = put_child_name(server_opts)

    spec = %{
      id: Server,
      start: {Server, :start_link, [server_opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
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
