defmodule Normandy.Coordination.Orchestration do
  @moduledoc false
  # What SequentialOrchestrator and ParallelOrchestrator share: the agent list's normal
  # form, one agent's run, and the {:ok, results} | {:error, OrchestrationError} shape.

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig}
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.OrchestrationError
  alias Normandy.TurnError

  @type spec :: %{
          required(:id) => String.t(),
          required(:agent) => BaseAgentConfig.t(),
          optional(:input) => term(),
          optional(:transform) => (term() -> term())
        }

  @type agent :: BaseAgentConfig.t() | spec()

  @type result ::
          {:ok, %{String.t() => term()}} | {:error, OrchestrationError.t()}

  # The agents as specs, in list order. A bare %BaseAgentConfig{} gets the id
  # "agent_<index>". A spec key outside `allowed`, a repeated id or anything that is not
  # an agent raises: results are keyed by id, so a repeated id would hide an output.
  @spec specs!(term(), [atom()], String.t()) :: [spec()]
  def specs!(agents, allowed, caller) when is_list(agents) do
    specs =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} -> spec!(agent, idx, allowed, caller) end)

    repeated =
      specs
      |> Enum.frequencies_by(& &1.id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)
      |> Enum.sort()

    if repeated != [] do
      raise ArgumentError,
            "#{caller}: agent ids must be unique, got #{inspect(repeated)} more than once"
    end

    specs
  end

  def specs!(other, _allowed, caller) do
    raise ArgumentError,
          "#{caller}: expected a list of agents, got: " <> Describe.type_of(other)
  end

  defp spec!(%BaseAgentConfig{} = agent, idx, _allowed, _caller),
    do: %{id: "agent_#{idx}", agent: agent}

  defp spec!(%{id: id, agent: %BaseAgentConfig{}} = spec, _idx, allowed, caller)
       when is_binary(id) and not is_struct(spec) do
    case spec |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] ->
        spec

      unknown ->
        raise ArgumentError,
              "#{caller}: unknown agent spec keys #{inspect(Enum.sort(unknown))} " <>
                "for #{inspect(id)}, supported: #{inspect(allowed)}"
    end
  end

  defp spec!(other, idx, allowed, caller) do
    raise ArgumentError,
          "#{caller}: agent #{idx} must be a %Normandy.Agents.BaseAgentConfig{} or a spec " <>
            "with keys #{inspect(allowed)} (:id a string, :agent a " <>
            "%Normandy.Agents.BaseAgentConfig{}), got: " <> Describe.type_of(other)
  end

  # One agent's run: {:ok, output} or {:error, exception}, never a stacktrace. Normandy's
  # own errors come back from BaseAgent.run/2; a raise (a bug) is logged with its
  # stacktrace (arities only) and returned; an exit (a timed-out GenServer.call, a client
  # that exits) is a :task_down TurnError.
  @spec run_agent(String.t(), BaseAgentConfig.t(), term()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_agent(id, %BaseAgentConfig{} = agent, input) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _agent, output} -> {:ok, output}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> TurnError.log_raised("Agent #{inspect(id)}", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
  end

  # A spec's callback (:transform, :on_agent_complete) run where a crash would take the
  # caller down (a linked task): a raise or an exit becomes that agent's error, as in
  # run_agent/3.
  @spec guard(String.t(), (-> term())) :: {:ok, term()} | {:error, Exception.t()}
  def guard(id, fun) do
    {:ok, fun.()}
  rescue
    e -> TurnError.log_raised("Agent #{inspect(id)} callback", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
  end

  @spec result(%{String.t() => term()}, %{String.t() => Exception.t()}) :: result()
  def result(results, errors) when map_size(errors) == 0, do: {:ok, results}
  def result(results, errors), do: {:error, %OrchestrationError{results: results, errors: errors}}

  # A string or a map with a chat_message is the chat message; a struct goes as is.
  defp prepare_input(input) when is_binary(input), do: %{chat_message: input}

  defp prepare_input(input) when is_map(input) and not is_struct(input),
    do: Map.get(input, :chat_message) || Map.get(input, "chat_message") || input

  defp prepare_input(input), do: input
end
