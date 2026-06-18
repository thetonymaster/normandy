defmodule Normandy.Agents.Turn.Supervisor.Horde do
  @moduledoc """
  `Horde.DynamicSupervisor` for `Turn.Server` processes — cluster-wide placement
  and supervision. Children start under the registry's `:via` name (atomic
  registration). `resume_policy` maps to the child `restart` value: `:lazy` →
  `:temporary` (a lost node's session is NOT redistributed; it is rebuilt on the
  next request), `:eager` → `:transient` (Phase 7d; redistributed on node-down).
  """
  alias Normandy.Agents.Turn.Server

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one, members: :auto)
  end

  @spec start_server(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_server(sup, server_opts) do
    server_opts = put_child_name(server_opts)
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
      if function_exported?(mod, :child_name, 2),
        do: mod.child_name(handle, sid),
        else: :self_register

    case name do
      :self_register -> opts
      via -> Keyword.put(opts, :name, via)
    end
  end
end
