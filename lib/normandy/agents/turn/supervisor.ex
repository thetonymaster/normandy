defmodule Normandy.Agents.Turn.Supervisor do
  @moduledoc "DynamicSupervisor for `Turn.Server` processes (one per live session)."
  use DynamicSupervisor

  alias Normandy.Agents.Turn.Server

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_server(:gen_statem.server_ref() | pid(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_server(sup, server_opts) do
    spec = %{
      id: Server,
      start: {Server, :start_link, [server_opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
  end
end
