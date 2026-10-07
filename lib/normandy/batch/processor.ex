defmodule Normandy.Batch.Processor do
  @moduledoc """
  Batch processing utilities for handling multiple agent requests concurrently.

  Provides efficient batch processing with configurable concurrency, rate limiting,
  and result aggregation for AI agent operations.

  ## Features

  - Concurrent request processing with Task.async_stream
  - Configurable concurrency limits
  - Ordered and unordered result collection
  - Error handling and partial failure support
  - Progress tracking callbacks

  ## Example

      # Basic batch processing
      inputs = [
        %{chat_message: "Hello"},
        %{chat_message: "How are you?"},
        %{chat_message: "Goodbye"}
      ]

      {:ok, results} = Normandy.Batch.Processor.process_batch(
        agent,
        inputs,
        max_concurrency: 5
      )

      # With progress callback
      {:ok, results} = Normandy.Batch.Processor.process_batch(
        agent,
        inputs,
        on_progress: fn completed, total ->
          IO.puts("Progress: \#{completed}/\#{total}")
        end
      )

  ## Telemetry

  An item that runs past `:timeout` is killed mid-run, so its
  `[:normandy, :agent, :run]` span never closes on its own. The processor
  emits a synthetic `[:normandy, :agent, :run, :exception]` with
  `reason: :killed` for it, possibly without a matching `:start`; the
  `llm_call`/`tool` spans open inside it stay open. See
  `Normandy.Telemetry.KilledRun`.
  """

  require Logger

  alias Normandy.Agents.BaseAgent
  alias Normandy.Options
  alias Normandy.Telemetry.KilledRun
  alias Normandy.Telemetry.OtelCtx

  @type batch_option ::
          {:max_concurrency, pos_integer()}
          | {:ordered, boolean()}
          | {:timeout, timeout()}
          | {:on_progress, progress_callback()}
          | {:on_error, error_callback()}
          | {:chunk_size, pos_integer()}
          | {:chunk_delay, non_neg_integer()}

  @type batch_options :: [batch_option()]

  @type progress_callback :: (pos_integer(), pos_integer() -> any())
  @type error_callback :: (term(), term() -> any())

  @type item_result :: {:ok, term()} | {:error, term()}

  @type batch_result :: %{
          success: [term()],
          errors: [{term(), term()}],
          total: non_neg_integer(),
          success_count: non_neg_integer(),
          error_count: non_neg_integer()
        }

  @default_max_concurrency 10
  @default_timeout 300_000

  # Keys every batch entry point takes. process_batch_with_stats/3 takes only these: it
  # always returns the stats map, so an :ordered option would be ignored.
  @batch_opts [
    max_concurrency: [
      type: :pos_integer,
      default: @default_max_concurrency,
      doc: "Items processed at once."
    ],
    timeout: [
      type: :timeout,
      default: @default_timeout,
      doc:
        "Timeout per item, in ms. An item that runs past it is stopped and fails with " <>
          "`{:exit, :timeout}`; the other items carry on."
    ],
    on_progress: [
      type: {:fun, 2},
      doc: "Called in the caller after each item completes: `(completed, total -> any)`."
    ],
    on_error: [
      type: {:fun, 2},
      doc: "Called in the caller for each failed item: `(input, error -> any)`."
    ]
  ]
  @ordered_opt [
    ordered: [
      type: :boolean,
      default: true,
      doc: "`true`: one result per input, in input order. `false`: a `batch_result` map."
    ]
  ]

  @process_batch_opts_schema NimbleOptions.new!(@batch_opts ++ @ordered_opt)
  @process_batch_with_stats_opts_schema NimbleOptions.new!(@batch_opts)
  @process_batch_chunked_opts_schema NimbleOptions.new!(
                                       @batch_opts ++
                                         @ordered_opt ++
                                         [
                                           chunk_size: [
                                             type: :pos_integer,
                                             default: 100,
                                             doc: "Items per chunk."
                                           ],
                                           chunk_delay: [
                                             type: :non_neg_integer,
                                             default: 0,
                                             doc: "Milliseconds to wait between chunks."
                                           ]
                                         ]
                                     )

  @doc false
  @spec __opts_schema__(:process_batch | :process_batch_with_stats) :: NimbleOptions.t()
  def __opts_schema__(:process_batch), do: @process_batch_opts_schema
  def __opts_schema__(:process_batch_with_stats), do: @process_batch_with_stats_opts_schema

  @doc """
  Process a batch of inputs through an agent concurrently.

  ## Options

  #{Options.docs(@process_batch_opts_schema)}

  ## Returns

  - With `ordered: true`: `{:ok, [{:ok, response} | {:error, error}]}`, one per
    input, in input order.
  - With `ordered: false`: `{:ok, batch_result}`. `errors` pairs each error
    with its input, `{input, error}`; both lists are in completion order.

  An error is `{:exception, exception, stacktrace}`, `{:exit, reason}` or
  `{:throw, value}`.

  ## Examples

      # Simple batch
      {:ok, [{:ok, first} | _]} = Processor.process_batch(agent, inputs)

      # With configuration
      {:ok, results} = Processor.process_batch(
        agent,
        inputs,
        max_concurrency: 5,
        on_progress: fn completed, total ->
          IO.puts("Progress: \#{completed}/\#{total}")
        end
      )
  """
  @spec process_batch(agent :: struct(), inputs :: [term()], batch_options()) ::
          {:ok, [item_result()] | batch_result()}
  def process_batch(agent, inputs, opts \\ []) when is_list(inputs) do
    opts = Options.validate!(opts, @process_batch_opts_schema, {__MODULE__, :process_batch, 3})
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)
    ordered = Keyword.fetch!(opts, :ordered)
    timeout = Keyword.fetch!(opts, :timeout)
    on_progress = Keyword.get(opts, :on_progress)
    on_error = Keyword.get(opts, :on_error)

    total = length(inputs)

    Logger.debug("Starting batch processing: #{total} items with concurrency #{max_concurrency}")

    # Results arrive as items complete. Each carries its index and input (an
    # exit carries them via zip_input_on_exit), so the callbacks run here in
    # the caller with a true completion count, and ordered results can be
    # put back in input order.
    parent_otel_ctx = OtelCtx.capture()

    {outcomes, _completed} =
      inputs
      |> Stream.with_index()
      |> Task.async_stream(
        fn {input, index} ->
          OtelCtx.restore(parent_otel_ctx)
          {index, input, process_single(agent, input)}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        ordered: false
      )
      |> Enum.map_reduce(0, fn result, completed ->
        {index, input, outcome} = item_outcome(result)
        :ok = report_kill(result, agent, timeout, parent_otel_ctx)
        completed = completed + 1

        if on_progress, do: on_progress.(completed, total)
        if on_error, do: report_error(on_error, input, outcome)

        {{index, input, outcome}, completed}
      end)

    Logger.debug("Batch processing complete")

    if ordered do
      {:ok, outcomes |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 2))}
    else
      {:ok, results_to_stats(outcomes)}
    end
  end

  @doc """
  Process a batch and return detailed statistics.

  Returns a map with separate success/error lists and counts.

  ## Options

  #{Options.docs(@process_batch_with_stats_opts_schema)}

  ## Example

      result = Processor.process_batch_with_stats(agent, inputs)
      #=> %{
        success: [result1, result2],
        errors: [{input3, error}],
        total: 3,
        success_count: 2,
        error_count: 1
      }
  """
  @spec process_batch_with_stats(agent :: struct(), inputs :: [term()], batch_options()) ::
          {:ok, batch_result()}
  def process_batch_with_stats(agent, inputs, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @process_batch_with_stats_opts_schema,
        {__MODULE__, :process_batch_with_stats, 3}
      )

    process_batch(agent, inputs, Keyword.put(opts, :ordered, false))
  end

  @doc """
  Process a batch in chunks with a delay between chunks.

  Useful for very large batches or strict rate limiting requirements.

  ## Options

  #{Options.docs(@process_batch_chunked_opts_schema)}

  Returns the same shape as `process_batch/3` for the same `:ordered` option,
  covering all chunks.

  ## Example

      {:ok, results} = Processor.process_batch_chunked(
        agent,
        large_input_list,
        chunk_size: 50,
        chunk_delay: 1000,  # 1 second between chunks
        max_concurrency: 5
      )
  """
  @spec process_batch_chunked(agent :: struct(), inputs :: [term()], batch_options()) ::
          {:ok, [item_result()] | batch_result()}
  def process_batch_chunked(agent, inputs, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @process_batch_chunked_opts_schema,
        {__MODULE__, :process_batch_chunked, 3}
      )

    {chunk_size, opts} = Keyword.pop!(opts, :chunk_size)
    {chunk_delay, opts} = Keyword.pop!(opts, :chunk_delay)

    Logger.debug("Processing #{length(inputs)} items in chunks of #{chunk_size}")

    chunks = Enum.chunk_every(inputs, chunk_size)
    last_index = length(chunks) - 1
    total = length(inputs)

    chunk_results =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        Logger.debug("Processing chunk #{index + 1}")

        chunk_opts = chunk_progress(opts, index * chunk_size, total)
        {:ok, chunk_result} = process_batch(agent, chunk, chunk_opts)

        if chunk_delay > 0 and index < last_index, do: Process.sleep(chunk_delay)

        chunk_result
      end)

    if Keyword.fetch!(opts, :ordered) do
      {:ok, Enum.concat(chunk_results)}
    else
      {:ok, Enum.reduce(chunk_results, empty_stats(), &merge_stats(&2, &1))}
    end
  end

  ## Private Functions

  # on_progress counts against the whole batch, not the chunk.
  defp chunk_progress(opts, done_before, total) do
    case Keyword.get(opts, :on_progress) do
      nil ->
        opts

      on_progress ->
        Keyword.put(opts, :on_progress, fn completed, _chunk_total ->
          on_progress.(done_before + completed, total)
        end)
    end
  end

  # Process a single input through the agent. The per-item timeout is applied
  # by Task.async_stream, which kills a task that runs past it.
  defp process_single(agent, input) do
    {_updated_agent, response} = BaseAgent.run!(agent, input)
    {:ok, response}
  rescue
    error ->
      {:error, {:exception, error, __STACKTRACE__}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}

    thrown_value ->
      {:error, {:throw, thrown_value}}
  end

  defp item_outcome({:ok, {index, input, outcome}}), do: {index, input, outcome}

  defp item_outcome({:exit, {{input, index}, reason}}),
    do: {index, input, {:error, {:exit, reason}}}

  # A task past the timeout was killed mid-run, so its run span never closed.
  defp report_kill({:exit, {_input_and_index, :timeout}}, agent, timeout, otel_ctx),
    do: KilledRun.emit_timeout(agent, timeout, otel_ctx)

  defp report_kill(_result, _agent, _timeout, _otel_ctx), do: :ok

  defp report_error(on_error, input, {:error, error}), do: on_error.(input, error)
  defp report_error(_on_error, _input, {:ok, _}), do: :ok

  defp results_to_stats(outcomes) do
    {success, errors} =
      Enum.reduce(outcomes, {[], []}, fn
        {_index, _input, {:ok, result}}, {succ, err} -> {[result | succ], err}
        {_index, input, {:error, error}}, {succ, err} -> {succ, [{input, error} | err]}
      end)

    merge_stats(empty_stats(), %{
      success: Enum.reverse(success),
      errors: Enum.reverse(errors)
    })
  end

  defp empty_stats, do: %{success: [], errors: [], total: 0, success_count: 0, error_count: 0}

  defp merge_stats(acc, %{success: success, errors: errors}) do
    success = acc.success ++ success
    errors = acc.errors ++ errors

    %{
      success: success,
      errors: errors,
      total: length(success) + length(errors),
      success_count: length(success),
      error_count: length(errors)
    }
  end
end
