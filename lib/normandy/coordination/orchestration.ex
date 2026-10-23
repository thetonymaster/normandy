defmodule Normandy.Coordination.Orchestration do
  @moduledoc """
  The types shared by the orchestrators (`Normandy.Coordination.SequentialOrchestrator` and
  `Normandy.Coordination.ParallelOrchestrator`): an agent, an agent spec and the result
  shape. Its functions are internal to the orchestrators and not part of the public API.
  """

  require Logger

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig}
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Coordination.AgentProcess
  alias Normandy.OrchestrationError
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.TurnError

  @typedoc "An agent with its id and optional `:input` and `:transform`."
  @type spec :: %{
          required(:id) => String.t(),
          required(:agent) => BaseAgentConfig.t(),
          optional(:input) => term(),
          optional(:transform) => (term() -> term())
        }

  @typedoc "A bare agent config (id `\"agent_<index>\"`) or a spec."
  @type agent :: BaseAgentConfig.t() | spec()

  @typedoc "Outputs keyed by agent id, or an `Normandy.OrchestrationError` carrying results and errors."
  @type result ::
          {:ok, %{String.t() => term()}} | {:error, OrchestrationError.t()}

  # The agents as specs, in list order. A bare %BaseAgentConfig{} gets the id
  # "agent_<index>". A spec key outside `allowed`, a repeated id or anything that is not
  # an agent raises: results are keyed by id, so a repeated id would hide an output.
  @doc false
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
        :ok = check_transform!(spec, caller)
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

  # A :transform that is not a 1-arity function would fail every run of that agent
  # (BadFunctionError, BadArityError); it raises here instead, before any agent runs.
  defp check_transform!(%{transform: transform} = spec, caller)
       when not is_function(transform, 1) do
    raise ArgumentError,
          "#{caller}: :transform for #{inspect(spec.id)} must be a 1-arity function, got: " <>
            describe_fun(transform)
  end

  defp check_transform!(_spec, _caller), do: :ok

  defp describe_fun(fun) when is_function(fun),
    do: "a function of arity #{Function.info(fun, :arity) |> elem(1)}"

  defp describe_fun(other), do: Describe.type_of(other)

  # The one run-and-classify. `fun` returns `{:ok, _, ...}` or `{:error, exception}` and
  # that is passed through (a Normandy error comes back from BaseAgent.run/3 as is). A
  # raise (a bug) is logged with its stacktrace (arities only) and returned bare; an exit
  # (a timed-out GenServer.call, a client that exits) or a throw is logged and is a
  # :task_down TurnError. Never a stacktrace. `who` names the caller in the log line.
  @doc false
  @spec classify(String.t(), (-> {:error, Exception.t()} | tuple())) ::
          {:error, Exception.t()} | tuple()
  def classify(who, fun) do
    fun.()
  rescue
    e -> TurnError.log_raised(who, e, __STACKTRACE__)
  catch
    kind, reason ->
      Logger.error("#{who} raised " <> TurnError.format_raised(kind, reason, __STACKTRACE__))
      {:error, caught(kind, reason)}
  end

  # One agent's run: {:ok, output} or {:error, exception}, as classify/2. The agent is a
  # config, run in this process, or the pid of an `AgentProcess` (no call timeout of its
  # own: a caller's timeout bounds it). `who` names the agent in the log line.
  @doc false
  @spec run_agent(String.t(), BaseAgentConfig.t() | pid(), term()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_agent(who, agent_or_pid, input) do
    classify(who, fn -> run_one(agent_or_pid, input) end)
  end

  defp run_one(pid, input) when is_pid(pid),
    do: AgentProcess.run(pid, input, timeout: :infinity)

  defp run_one(%BaseAgentConfig{} = agent, input) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _agent, output} -> {:ok, output}
      {:error, exception} -> {:error, exception}
    end
  end

  # Tasks started under this supervisor are not linked to the caller: a crash in a
  # process an agent linked to (which kills its task) arrives as an {:exit, reason}
  # outcome, not as an exit of the caller. There is no application supervision tree to
  # hang them on, so each call starts a Task.Supervisor and stops it however the call ends.
  # It is unlinked before it stops, and an exit signal that arrived first is flushed, so a
  # caller that traps exits finds no {:EXIT, supervisor, _} message after the call.
  @doc false
  @spec with_task_supervisor((Supervisor.supervisor() -> result)) :: result when result: term()
  def with_task_supervisor(fun) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      fun.(supervisor)
    after
      true = Process.unlink(supervisor)
      :ok = Supervisor.stop(supervisor)

      receive do
        {:EXIT, ^supervisor, _reason} -> :ok
      after
        0 -> :ok
      end
    end
  end

  # run_agent/3 in an unlinked task under `supervisor`, the caller's OTel context restored
  # in it. A task that dies (a crash in a process the agent linked to) is that agent's
  # :task_down TurnError, as in run_agent/3.
  @doc false
  @spec run_agent_isolated(Supervisor.supervisor(), String.t(), BaseAgentConfig.t(), term()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_agent_isolated(supervisor, id, %BaseAgentConfig{} = agent, input) do
    parent_otel_ctx = OtelCtx.capture()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OtelCtx.restore(parent_otel_ctx)
        run_agent("Agent #{inspect(id)}", agent, input)
      end)

    case Task.yield(task, :infinity) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:error, TurnError.from_reason({:task_down, reason})}
    end
  end

  # A spec's callback (:transform, :on_agent_complete) run where a crash would take the
  # caller down (a linked task): a raise or an exit becomes that agent's error, as in
  # run_agent/3.
  @doc false
  @spec guard(String.t(), (-> term())) :: {:ok, term()} | {:error, Exception.t()}
  def guard(id, fun) do
    classify("Agent #{inspect(id)} callback", fn -> {:ok, fun.()} end)
  end

  # An exit is the exit reason; a throw nobody caught is {:nocatch, value}, as in an
  # uncaught throw's exit reason.
  defp caught(:exit, reason), do: TurnError.from_reason({:task_down, reason})
  defp caught(:throw, value), do: TurnError.from_reason({:task_down, {:nocatch, value}})

  @doc false
  @spec result(%{String.t() => term()}, %{String.t() => Exception.t()}) :: result()
  def result(results, errors) when map_size(errors) == 0, do: {:ok, results}
  def result(results, errors), do: {:error, %OrchestrationError{results: results, errors: errors}}

  # A string or a map with a chat_message is the chat message; a struct goes as is.
  @doc false
  @spec prepare_input(term()) :: term()
  def prepare_input(input) when is_binary(input), do: %{chat_message: input}

  def prepare_input(input) when is_map(input) and not is_struct(input),
    do: Map.get(input, :chat_message) || Map.get(input, "chat_message") || input

  def prepare_input(input), do: input
end
