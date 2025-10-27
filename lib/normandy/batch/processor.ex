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
  """

  require Logger

  @type batch_option ::
          {:max_concurrency, pos_integer()}
          | {:ordered, boolean()}
          | {:timeout, pos_integer()}
          | {:on_progress, progress_callback()}
          | {:on_error, error_callback()}

  @type batch_options :: [batch_option()]

  @type progress_callback :: (pos_integer(), pos_integer() -> any())
  @type error_callback :: (term(), term() -> any())

  @type batch_result :: %{
          success: [term()],
          errors: [{term(), term()}],
          total: pos_integer(),
          success_count: pos_integer(),
          error_count: pos_integer()
        }

  @default_max_concurrency 10
  @default_timeout 300_000

  @doc """
  Process a batch of inputs through an agent concurrently.

  ## Options

  - `:max_concurrency` - Maximum concurrent tasks (default: #{@default_max_concurrency})
  - `:ordered` - Preserve input order in results (default: true)
  - `:timeout` - Timeout per task in milliseconds (default: #{@default_timeout}ms)
  - `:on_progress` - Callback function called after each completion: `(completed, total -> any)`
  - `:on_error` - Callback function called on each error: `(input, error -> any)`

  ## Returns

  - `{:ok, results}` - List of results (or batch_result map if unordered)
  - `{:error, reason}` - Fatal error during batch processing

  ## Examples

      # Simple batch
      {:ok, results} = Processor.process_batch(agent, inputs)

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
          {:ok, [term()] | batch_result()} | {:error, term()}
  def process_batch(agent, inputs, opts \\ []) when is_list(inputs) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    ordered = Keyword.get(opts, :ordered, true)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    on_progress = Keyword.get(opts, :on_progress)
    on_error = Keyword.get(opts, :on_error)

    total = length(inputs)

    Logger.info("Starting batch processing: #{total} items with concurrency #{max_concurrency}")

    # Process with Task.async_stream
    results =
      inputs
      |> Stream.with_index()
      |> Task.async_stream(
        fn {input, index} ->
          # Process the input
          result = process_single(agent, input, timeout)

          # Progress callback
          if on_progress, do: on_progress.(index + 1, total)

          # Error callback
          case result do
            {:error, error} ->
              if on_error, do: on_error.(input, error)
              result

            _ ->
              result
          end
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: ordered
      )
      |> Enum.to_list()

    Logger.info("Batch processing complete")

    # Process results
    process_results(results, ordered)
  end

  @doc """
  Process a batch and return detailed statistics.

  Returns a map with separate success/error lists and counts.

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
          {:ok, batch_result()} | {:error, term()}
  def process_batch_with_stats(agent, inputs, opts \\ []) do
    opts = Keyword.put(opts, :ordered, false)

    case process_batch(agent, inputs, opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, results} when is_list(results) -> {:ok, results_to_stats(results)}
      error -> error
    end
  end

  @doc """
  Process a batch in chunks with a delay between chunks.

  Useful for very large batches or strict rate limiting requirements.

  ## Options

  All options from `process_batch/3` plus:
  - `:chunk_size` - Number of items per chunk (default: 100)
  - `:chunk_delay` - Milliseconds to wait between chunks (default: 0)

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
          {:ok, [term()]} | {:error, term()}
  def process_batch_chunked(agent, inputs, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 100)
    chunk_delay = Keyword.get(opts, :chunk_delay, 0)
    opts = Keyword.drop(opts, [:chunk_size, :chunk_delay])

    total = length(inputs)
    Logger.info("Processing #{total} items in chunks of #{chunk_size}")

    results =
      inputs
      |> Enum.chunk_every(chunk_size)
      |> Enum.with_index()
      |> Enum.flat_map(fn {chunk, index} ->
        Logger.info("Processing chunk #{index + 1}")

        {:ok, chunk_results} = process_batch(agent, chunk, opts)

        # Wait between chunks (except after last chunk)
        if chunk_delay > 0 and index < div(total, chunk_size) do
          Process.sleep(chunk_delay)
        end

        if is_list(chunk_results), do: chunk_results, else: chunk_results.success
      end)

    {:ok, results}
  end

  ## Private Functions

  # Process a single input through the agent
  defp process_single(agent, input, _timeout) do
    try do
      {_updated_agent, response} = Normandy.Agents.BaseAgent.run(agent, input)
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
  end

  # Process async_stream results
  defp process_results(results, ordered) do
    if ordered do
      # Ordered results - return list
      processed =
        results
        |> Enum.map(fn
          {:ok, {:ok, result}} -> result
          {:ok, {:error, _error}} -> nil
          {:exit, _reason} -> nil
        end)

      {:ok, processed}
    else
      # Unordered - return stats
      stats = results_to_stats(results)
      {:ok, stats}
    end
  end

  # Convert results to statistics map
  defp results_to_stats(results) do
    {success, errors} =
      results
      |> Enum.reduce({[], []}, fn
        {:ok, {:ok, result}}, {succ, err} ->
          {[result | succ], err}

        {:ok, {:error, error}}, {succ, err} ->
          {succ, [error | err]}

        {:exit, reason}, {succ, err} ->
          {succ, [{:exit, reason} | err]}
      end)

    success = Enum.reverse(success)
    errors = Enum.reverse(errors)

    %{
      success: success,
      errors: errors,
      total: length(success) + length(errors),
      success_count: length(success),
      error_count: length(errors)
    }
  end
end
