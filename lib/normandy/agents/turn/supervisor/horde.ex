# Compiled only when Horde is available (an `optional` dep) — Tier-2 placement.
if Code.ensure_loaded?(Horde.DynamicSupervisor) do
  defmodule Normandy.Agents.Turn.Supervisor.Horde do
    @moduledoc """
    `Horde.DynamicSupervisor` for `Turn.Server` processes — cluster-wide placement
    and supervision. Children start under the registry's `:via` name (atomic
    registration). `resume_policy` maps to the child `restart` value: `:lazy` →
    `:temporary` (a lost node's session is NOT redistributed; it is rebuilt on the
    next request), `:eager` → `:transient` (Phase 7d; redistributed on node-down).

    `:max_restarts` / `:max_seconds` set the restart limit, with the same default
    as `Normandy.Agents.Turn.Supervisor` (100 in 5 seconds).

    Pass the supervisor's **name** to `start_server/2`, not the pid `start_link/1`
    returns: that pid is Horde's outer `Supervisor`, which would accept the session
    as a plain local child outside Horde's placement and supervision.
    """
    alias Normandy.Agents.Turn.Server
    alias Normandy.Options

    @start_link_opts_schema NimbleOptions.new!(
                              name: [
                                type: :any,
                                default: __MODULE__,
                                doc: "The Horde supervisor's name; pass it to `start_server/2`."
                              ],
                              max_restarts: [
                                type: :non_neg_integer,
                                default:
                                  Normandy.Agents.Turn.Supervisor.default_restart_limit()[
                                    :max_restarts
                                  ],
                                doc: "Restarts allowed within `:max_seconds`."
                              ],
                              max_seconds: [
                                type: :pos_integer,
                                default:
                                  Normandy.Agents.Turn.Supervisor.default_restart_limit()[
                                    :max_seconds
                                  ],
                                doc: "The window for `:max_restarts`, in seconds."
                              ]
                            )

    @doc """
    Starts the Horde supervisor (`members: :auto`).

    ## Options

    #{Options.docs(@start_link_opts_schema)}
    """
    @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

      Horde.DynamicSupervisor.start_link(
        name: Keyword.fetch!(opts, :name),
        strategy: :one_for_one,
        members: :auto,
        max_restarts: Keyword.fetch!(opts, :max_restarts),
        max_seconds: Keyword.fetch!(opts, :max_seconds)
      )
    end

    @doc """
    Starts a `Turn.Server` for a session under the Horde supervisor `sup` (its name).
    `server_opts` are checked in the caller before Horde starts anything.

    ## Options

    The options of `Normandy.Agents.Turn.Server.start_link/1`.
    """
    @spec start_server(term(), keyword()) :: {:ok, pid()} | {:error, term()}
    def start_server(sup, server_opts) do
      server_opts =
        server_opts
        |> Options.validate!(Server.__opts_schema__(:start_link), {__MODULE__, :start_server, 2})
        |> put_child_name()

      restart = restart_for(Keyword.get(server_opts, :resume_policy, :lazy))

      spec = %{
        id: Keyword.fetch!(server_opts, :session_id),
        start: {Server, :start_link, [server_opts]},
        restart: restart,
        type: :worker
      }

      Horde.DynamicSupervisor.start_child(sup, spec)
    end

    defp restart_for(:eager), do: :transient
    defp restart_for(_), do: :temporary

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
end
