defmodule Normandy.Coordination.ParallelOrchestrator do
  alias Normandy.Coordination.Orchestration
  alias Normandy.Telemetry.KilledRun
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Telemetry.WorkflowSpan
  alias Normandy.TurnError

  @opts_schema NimbleOptions.new!(
                 max_concurrency: [
                   type: :pos_integer,
                   default: 10,
                   doc: "How many agents run at once."
                 ],
                 timeout: [
                   type: :timeout,
                   default: 300_000,
                   doc:
                     "Each agent's limit in ms, or `:infinity`. An agent past it is stopped " <>
                       "and fails with `%Normandy.TurnError{type: :task_down, reason: :timeout}`."
                 ],
                 on_agent_complete: [
                   type: {:fun, 2},
                   doc:
                     "`fn agent_id, output -> any end`, called in the agent's task after it " <>
                       "succeeds (after `:transform`). A raise in it is that agent's error."
                 ]
               )

  @spec_keys [:id, :agent, :input, :transform]

  @moduledoc """
  Runs agents concurrently on one input.

      {:ok, results} =
        ParallelOrchestrator.execute(
          [%{id: "pros", agent: pros_agent}, %{id: "cons", agent: cons_agent}],
          %{chat_message: "Should we adopt Elixir?"},
          max_concurrency: 2
        )

      results["pros"].chat_message

  `agents` holds `%Normandy.Agents.BaseAgentConfig{}` structs (keyed `"agent_0"`,
  `"agent_1"`, ... in list order) or specs `%{id: id, agent: config}` with an optional
  `:transform` (`fn output -> term end`, applied to the agent's output) and an optional
  `:input`, which replaces `input` for that agent:

      ParallelOrchestrator.execute(
        [%{id: "a", agent: agent, input: query_a}, %{id: "b", agent: agent, input: query_b}],
        nil
      )

  ## Results

  `{:ok, %{id => output}}` when every agent succeeded; otherwise
  `{:error, %Normandy.OrchestrationError{results: %{id => output}, errors: %{id =>
  exception}}}`, with every agent in one of the two maps. A failure never stops the other
  agents or exits the caller. See `Normandy.OrchestrationError` for what the exceptions
  are.

  ## Telemetry

  An agent that runs past `:timeout` is killed mid-run, so its
  `[:normandy, :agent, :run]` span never closes on its own. `execute/3` and
  `execute_stream/2` emit a synthetic `[:normandy, :agent, :run, :exception]`
  with `reason: :killed` for it (`execute_stream/2` when the timed-out element
  is consumed) unless its run had already returned and the timeout hit its
  `:transform` or `:on_agent_complete` callback, possibly without a matching `:start`;
  the `llm_call`/`tool` spans open inside it stay open. See `Normandy.Telemetry.KilledRun`.
  """

  @doc """
  Runs `agents` concurrently, each on `input` or its spec's `:input`; see "Results".

  ## Options

  #{Normandy.Options.docs(@opts_schema)}
  """
  @spec execute([Orchestration.agent()], term(), keyword()) :: Orchestration.result()
  def execute(agents, input, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute, 3})
    :ok = check_input!(input)
    specs = Orchestration.specs!(agents, @spec_keys, "#{inspect(__MODULE__)}.execute/3")

    WorkflowSpan.span(:parallel, %{step_count: length(specs)}, fn ->
      run_specs(specs, input, opts)
    end)
  end

  # Options of execute/3, in 2.0 and in 1.x.
  @option_keys Keyword.keys(@opts_schema.schema) ++ [:shared_context, :aggregate, :ordered]

  # The 1.x form execute(specs, opts) still compiles: the options bind as the input and
  # would be ignored. Refuse a non-empty keyword list whose keys are all option names
  # (decision 9, ruling P3); a real keyword-list input with such keys must be wrapped.
  defp check_input!(input) do
    if input != [] and Keyword.keyword?(input) and
         Enum.all?(Keyword.keys(input), &(&1 in @option_keys)) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.execute/3: the second argument is the input, got a " <>
              "keyword list of options #{inspect(Keyword.keys(input))}; options go third, " <>
              "execute(agents, input, opts) (see MIGRATING-2.0.md §27)"
    end

    :ok
  end

  # Runs specs without opening a workflow span, for HierarchicalCoordinator, which already
  # holds one so a call yields exactly one span. Every spec carries its own :input.
  @doc false
  @spec execute_specs([Orchestration.spec()], keyword()) :: Orchestration.result()
  def execute_specs(specs, opts) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute_specs, 2})

    specs
    |> Orchestration.specs!(@spec_keys, "#{inspect(__MODULE__)}.execute_specs/2")
    |> run_specs(nil, opts)
  end

  defp run_specs(specs, input, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    on_complete = opts[:on_agent_complete]
    parent_otel_ctx = OtelCtx.capture()
    run_marks = KilledRun.new_run_marks(length(specs))

    outcomes =
      specs
      |> Enum.with_index()
      |> Task.async_stream(
        fn {spec, idx} ->
          OtelCtx.restore(parent_otel_ctx)
          on_run_done = fn -> KilledRun.mark_run_done(run_marks, idx) end
          {spec.id, run_spec(spec, input, on_complete, on_run_done)}
        end,
        max_concurrency: Keyword.fetch!(opts, :max_concurrency),
        timeout: timeout,
        # A slow agent fails on its own instead of exiting the caller.
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.to_list()

    Enum.each(outcomes, &report_kill(&1, run_marks, timeout, parent_otel_ctx))

    {results, errors} =
      Enum.reduce(outcomes, {%{}, %{}}, fn
        {:ok, {id, {:ok, output}}}, {ok, failed} ->
          {Map.put(ok, id, output), failed}

        {:ok, {id, {:error, exception}}}, {ok, failed} ->
          {ok, Map.put(failed, id, exception)}

        # Killed past :timeout (reason :timeout), or the task died.
        {:exit, {{%{id: id}, _idx}, reason}}, {ok, failed} ->
          {ok, Map.put(failed, id, TurnError.from_reason({:task_down, reason}))}
      end)

    Orchestration.result(results, errors)
  end

  @doc """
  Runs agent specs and yields each result as its agent finishes. Each element is one of:

  - `{:ok, {:ok, {agent_id, output}}}` - the agent finished
  - `{:ok, {:error, {agent_id, exception}}}` - the agent failed (exceptions as in
    `Normandy.OrchestrationError`)
  - `{:exit, {agent_id, :timeout}}` - the agent ran past `:timeout` and was stopped

  Emits no `[:normandy, :workflow, :run]` span: the stream is lazy, so it has no
  defined start and end (a current limitation).

  ## Example

      stream = ParallelOrchestrator.execute_stream(specs, timeout: 60_000)

      stream
      |> Stream.each(fn
        {:ok, {:ok, {agent_id, output}}} -> IO.puts("Agent \#{agent_id}: \#{inspect(output)}")
        {:ok, {:error, {agent_id, e}}} -> IO.puts("Agent \#{agent_id} failed: \#{Exception.message(e)}")
        {:exit, {agent_id, :timeout}} -> IO.puts("Agent \#{agent_id} timed out")
      end)
      |> Stream.run()
  """
  @spec execute_stream([Orchestration.spec()], keyword()) :: Enumerable.t()
  def execute_stream(agent_specs, opts \\ []) do
    specs =
      Orchestration.specs!(agent_specs, @spec_keys, "#{inspect(__MODULE__)}.execute_stream/2")

    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 300_000)

    parent_otel_ctx = OtelCtx.capture()

    # Run marks are per enumeration, so they're made when the stream runs.
    Stream.flat_map([specs], fn specs ->
      stream_specs(specs, max_concurrency, timeout, parent_otel_ctx)
    end)
  end

  defp stream_specs(specs, max_concurrency, timeout, parent_otel_ctx) do
    run_marks = KilledRun.new_run_marks(length(specs))

    Task.async_stream(
      Enum.with_index(specs),
      fn {spec, idx} ->
        OtelCtx.restore(parent_otel_ctx)
        on_run_done = fn -> KilledRun.mark_run_done(run_marks, idx) end

        case run_spec(spec, nil, nil, on_run_done) do
          {:ok, output} -> {:ok, {spec.id, output}}
          {:error, exception} -> {:error, {spec.id, exception}}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      # A slow agent fails on its own instead of exiting the caller.
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: false
    )
    |> Stream.map(fn
      {:exit, {{%{id: agent_id}, _idx}, reason}} = exit ->
        :ok = report_kill(exit, run_marks, timeout, parent_otel_ctx)
        {:exit, {agent_id, reason}}

      other ->
        other
    end)
  end

  # An agent killed past the timeout before its run returned left its run span
  # open: report it.
  defp report_kill({:exit, {{%{agent: agent}, idx}, :timeout}}, run_marks, timeout, otel_ctx) do
    if KilledRun.run_done?(run_marks, idx),
      do: :ok,
      else: KilledRun.emit_timeout(agent, timeout, otel_ctx)
  end

  defp report_kill(_result, _run_marks, _timeout, _otel_ctx), do: :ok

  # Runs one spec's agent, then its :transform and the :on_agent_complete callback.
  # The callbacks run in the agent's task, so they are guarded: a crash would take
  # the caller down through the task's link.
  # `on_run_done` runs as soon as the agent's run returns, before the callbacks.
  defp run_spec(spec, input, on_complete, on_run_done) do
    outcome = Orchestration.run_agent(spec.id, spec.agent, Map.get(spec, :input, input))
    :ok = on_run_done.()

    with {:ok, output} <- outcome do
      Orchestration.guard(spec.id, fn -> run_callbacks(spec, output, on_complete) end)
    end
  end

  defp run_callbacks(spec, output, on_complete) do
    transformed = Map.get(spec, :transform, &Function.identity/1).(output)
    if on_complete, do: on_complete.(spec.id, transformed)
    transformed
  end
end
