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

  # Client API

  @doc """
  Starts the agent supervisor.

  ## Options

  - `:name` - Register supervisor with a name (optional)
  - `:strategy` - Supervision strategy (default: :one_for_one)
  - `:max_restarts` - Max restarts allowed (default: 3)
  - `:max_seconds` - Time window for max_restarts (default: 5)

  ## Example

      {:ok, pid} = AgentSupervisor.start_link(name: :my_supervisor)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    strategy = Keyword.get(opts, :strategy, :one_for_one)
    max_restarts = Keyword.get(opts, :max_restarts, 3)
    max_seconds = Keyword.get(opts, :max_seconds, 5)

    sup_opts = [
      strategy: strategy,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    ]

    if name do
      DynamicSupervisor.start_link(__MODULE__, sup_opts, name: name)
    else
      DynamicSupervisor.start_link(__MODULE__, sup_opts)
    end
  end

  @doc """
  Starts an agent process under supervision.

  ## Options

  - `:agent` - BaseAgent struct (required)
  - `:agent_id` - Unique identifier (default: UUID)
  - `:name` - Register agent process with name (optional)
  - `:context_pid` - StatefulContext to use (optional)
  - `:restart` - Restart strategy: :permanent, :temporary, :transient (default: :transient)

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
    # Validate that :agent key exists (will raise if missing)
    _agent = Keyword.fetch!(opts, :agent)
    restart = Keyword.get(opts, :restart, :transient)

    child_spec = %{
      id: AgentProcess,
      start: {AgentProcess, :start_link, [opts]},
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
    |> Enum.map(fn {_id, pid, _type, _modules} ->
      agent_id = AgentProcess.get_id(pid)
      {pid, agent_id}
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
  Finds an agent by its agent_id.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.

  ## Example

      {:ok, pid} = AgentSupervisor.find_agent(supervisor, "agent_1")
  """
  @spec find_agent(Supervisor.supervisor(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find_agent(supervisor, agent_id) do
    case Enum.find(list_agents(supervisor), fn {_pid, id} -> id == agent_id end) do
      {pid, _id} -> {:ok, pid}
      nil -> {:error, :not_found}
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
