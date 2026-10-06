defmodule Normandy.Coordination.AgentSupervisor do
  @moduledoc """
  Dynamic supervisor for managing agent processes.

  AgentSupervisor provides fault-tolerant supervision of agent processes,
  enabling automatic restarts on failures and dynamic agent pool management.

  ## Features

  - Dynamic agent spawning
  - Automatic restart on failure
  - Configurable restart strategies
  - Agent process discovery

  ## Example

      # Start supervisor
      {:ok, sup_pid} = AgentSupervisor.start_link(
        name: :agent_supervisor,
        strategy: :one_for_one
      )

      # Start an agent under supervision
      {:ok, agent_pid} = AgentSupervisor.start_agent(
        sup_pid,
        agent: my_agent,
        agent_id: "research_agent"
      )

      # List all supervised agents
      agents = AgentSupervisor.list_agents(sup_pid)
  """

  use DynamicSupervisor
  require Logger

  alias Normandy.Coordination.AgentProcess
  alias Normandy.Options

  # Client API

  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the supervisor."],
                            strategy: [
                              type: {:in, [:one_for_one]},
                              default: :one_for_one,
                              doc: "`DynamicSupervisor` supports only `:one_for_one`."
                            ],
                            max_restarts: [
                              type: :non_neg_integer,
                              default: 3,
                              doc: "Restarts allowed within `:max_seconds`."
                            ],
                            max_seconds: [
                              type: :pos_integer,
                              default: 5,
                              doc: "The window for `:max_restarts`, in seconds."
                            ]
                          )

  # The agent process's own options plus :restart, which stays here for the child spec.
  @start_agent_opts_schema NimbleOptions.new!(
                             AgentProcess.__opts_schema__(:start_link).schema ++
                               [
                                 restart: [
                                   type: {:in, [:permanent, :temporary, :transient]},
                                   default: :transient,
                                   doc:
                                     "The child's restart value. Not passed to the agent process."
                                 ]
                               ]
                           )

  @doc """
  Starts the agent supervisor.

  ## Options

  #{Options.docs(@start_link_opts_schema)}

  ## Example

      {:ok, pid} = AgentSupervisor.start_link(name: :my_supervisor)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.pop(opts, :name) do
      {nil, sup_opts} -> DynamicSupervisor.start_link(__MODULE__, sup_opts)
      {name, sup_opts} -> DynamicSupervisor.start_link(__MODULE__, sup_opts, name: name)
    end
  end

  @doc """
  Starts an agent process under supervision.

  ## Options

  `AgentProcess.start_link/1`'s options, plus `:restart`:

  #{Options.docs(@start_agent_opts_schema)}

  ## Example

      {:ok, pid} = AgentSupervisor.start_agent(
        supervisor,
        agent: my_agent,
        agent_id: "agent_1",
        name: :research_agent
      )
  """
  @spec start_agent(Supervisor.supervisor(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_agent(supervisor, opts) do
    opts = Options.validate!(opts, @start_agent_opts_schema, {__MODULE__, :start_agent, 2})
    {restart, process_opts} = Keyword.pop!(opts, :restart)

    child_spec = %{
      id: AgentProcess,
      start: {AgentProcess, :start_link, [process_opts]},
      restart: restart,
      shutdown: 5000,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Terminates an agent process.

  ## Example

      :ok = AgentSupervisor.terminate_agent(supervisor, agent_pid)
  """
  @spec terminate_agent(Supervisor.supervisor(), pid()) :: :ok | {:error, :not_found}
  def terminate_agent(supervisor, agent_pid) do
    DynamicSupervisor.terminate_child(supervisor, agent_pid)
  end

  @doc """
  Lists all supervised agent processes.

  Returns list of `{pid, agent_id}` tuples.

  ## Example

      agents = AgentSupervisor.list_agents(supervisor)
      #=> [{#PID<0.123.0>, "agent_1"}, {#PID<0.124.0>, "agent_2"}]
  """
  @spec list_agents(Supervisor.supervisor()) :: [{pid(), String.t()}]
  def list_agents(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
      # Read without calling the agent, so one busy in a long call is still listed.
      # A child that exited after which_children/1 is no longer an agent to list.
      case AgentProcess.agent_id_of(pid) do
        {:ok, id} -> [{pid, id}]
        :error -> []
      end
    end)
  end

  @doc """
  Returns count of supervised agents.

  ## Example

      count = AgentSupervisor.count_agents(supervisor)
      #=> 5
  """
  @spec count_agents(Supervisor.supervisor()) :: non_neg_integer()
  def count_agents(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> length()
  end

  @doc """
  Looks up a running agent by its agent_id: `{:ok, pid}` or `:error`.

  ## Example

      {:ok, pid} = AgentSupervisor.fetch_agent(supervisor, "agent_1")
  """
  @spec fetch_agent(Supervisor.supervisor(), String.t()) :: {:ok, pid()} | :error
  def fetch_agent(supervisor, agent_id) do
    case Enum.find(list_agents(supervisor), fn {_pid, id} -> id == agent_id end) do
      {pid, _id} -> {:ok, pid}
      nil -> :error
    end
  end

  @doc """
  Terminates all supervised agents.

  ## Example

      :ok = AgentSupervisor.terminate_all(supervisor)
  """
  @spec terminate_all(Supervisor.supervisor()) :: :ok
  def terminate_all(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      if is_pid(pid) do
        DynamicSupervisor.terminate_child(supervisor, pid)
      end
    end)

    :ok
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    DynamicSupervisor.init(opts)
  end
end
