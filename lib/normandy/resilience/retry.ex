defmodule Normandy.Resilience.Retry do
  @moduledoc """
  Retry mechanism with exponential backoff for handling transient failures.

  Provides configurable retry logic for operations that may fail temporarily,
  such as network requests, API calls, or resource access.

  ## Features

  - Exponential backoff with jitter
  - Configurable retry limits
  - Custom retry conditions
  - Detailed error tracking

  ## Example

      # Basic retry with defaults
      Retry.with_retry(fn ->
        MyAPI.call()
      end)

      # Custom retry configuration
      Retry.with_retry(
        fn -> MyAPI.call() end,
        max_attempts: 5,
        base_delay: 1000,
        max_delay: 30_000,
        retry_on: [:network_error, :rate_limit]
      )

      # With custom retry condition
      Retry.with_retry(
        fn -> MyAPI.call() end,
        retry_if: fn error ->
          match?({:error, :temporary}, error)
        end
      )
  """

  require Logger

  @type retry_option ::
          {:max_attempts, pos_integer()}
          | {:base_delay, pos_integer()}
          | {:max_delay, pos_integer()}
          | {:backoff_factor, float()}
          | {:jitter, boolean()}
          | {:retry_on, [atom()]}
          | {:retry_if, (term() -> boolean())}

  @type retry_options :: [retry_option()]

  @default_max_attempts 3
  @default_base_delay 1000
  @default_max_delay 32_000
  @default_backoff_factor 2.0
  @default_jitter true

  # Default retryable error types
  @default_retry_on [
    :network_error,
    :timeout,
    :rate_limit,
    :service_unavailable,
    :internal_server_error
  ]

  @doc """
  Execute a function with retry logic.

  ## Options

  - `:max_attempts` - Maximum number of attempts (default: #{@default_max_attempts})
  - `:base_delay` - Initial delay in milliseconds (default: #{@default_base_delay}ms)
  - `:max_delay` - Maximum delay in milliseconds (default: #{@default_max_delay}ms)
  - `:backoff_factor` - Exponential backoff multiplier (default: #{@default_backoff_factor})
  - `:jitter` - Add randomness to delays (default: #{@default_jitter})
  - `:retry_on` - List of error types to retry on (default: network errors, timeouts, rate limits)
  - `:retry_if` - Custom retry condition function

  ## Returns

  - `{:ok, result}` - Success after 1 or more attempts
  - `{:error, {reason, attempts, errors}}` - Failed after all attempts

  ## Examples

      # Retry with defaults
      {:ok, result} = Retry.with_retry(fn ->
        {:ok, perform_operation()}
      end)

      # Custom configuration
      {:ok, result} = Retry.with_retry(
        fn -> risky_operation() end,
        max_attempts: 5,
        base_delay: 500
      )

      # Custom retry condition
      Retry.with_retry(
        fn -> custom_call() end,
        retry_if: fn
          {:error, %{status: status}} when status >= 500 -> true
          _ -> false
        end
      )
  """
  @spec with_retry(function(), retry_options()) ::
          {:ok, term()} | {:error, {term(), pos_integer(), [term()]}}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)
    backoff_factor = Keyword.get(opts, :backoff_factor, @default_backoff_factor)
    jitter = Keyword.get(opts, :jitter, @default_jitter)
    retry_on = Keyword.get(opts, :retry_on, @default_retry_on)
    retry_if = Keyword.get(opts, :retry_if)

    retry_config = %{
      max_attempts: max_attempts,
      base_delay: base_delay,
      max_delay: max_delay,
      backoff_factor: backoff_factor,
      jitter: jitter,
      retry_on: retry_on,
      retry_if: retry_if
    }

    do_retry(fun, retry_config, 1, [])
  end

  # Private retry loop
  defp do_retry(_fun, config, attempt, errors) when attempt > config.max_attempts do
    # Max attempts reached
    last_error = List.first(errors) || :unknown_error

    Logger.warning(
      "Retry failed after #{config.max_attempts} attempts. Last error: #{inspect(last_error)}"
    )

    {:error, {last_error, config.max_attempts, Enum.reverse(errors)}}
  end

  defp do_retry(fun, config, attempt, errors) do
    case execute_with_timeout(fun) do
      {:ok, result} ->
        if attempt > 1 do
          Logger.info("Retry succeeded on attempt #{attempt}")
        end

        {:ok, result}

      {:error, error} ->
        # Check if we should retry (and haven't exceeded max attempts)
        if attempt < config.max_attempts and is_retryable?(error, config) do
          delay = calculate_delay(attempt, config)

          Logger.warning(
            "Retry attempt #{attempt}/#{config.max_attempts} failed: #{inspect(error)}. " <>
              "Retrying in #{delay}ms..."
          )

          Process.sleep(delay)
          do_retry(fun, config, attempt + 1, [error | errors])
        else
          # Either non-retryable or max attempts reached
          if attempt >= config.max_attempts do
            # Return the accumulated errors
            {:error, {error, config.max_attempts, Enum.reverse([error | errors])}}
          else
            Logger.warning("Non-retryable error: #{inspect(error)}")
            {:error, error}
          end
        end

      other ->
        # Unexpected return value, treat as error
        Logger.warning(
          "Unexpected return value (expected {:ok, _} or {:error, _}): #{inspect(other)}"
        )

        {:error, {:unexpected_return, other}}
    end
  end

  # Execute function with safety wrapper
  defp execute_with_timeout(fun) do
    try do
      fun.()
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

  # Determine if error is retryable
  defp is_retryable?(error, config) do
    # Check custom retry condition first
    if config.retry_if do
      config.retry_if.({:error, error})
    else
      # Check if error type is in retry_on list
      is_retryable_error?(error, config.retry_on)
    end
  end

  # Check if error matches retryable types
  defp is_retryable_error?(error, retry_on) do
    case error do
      # Atom error types
      error_type when is_atom(error_type) ->
        error_type in retry_on

      # Tuple errors like {:network_error, details}
      {error_type, _details} when is_atom(error_type) ->
        error_type in retry_on

      # Map errors with :type or :reason field
      %{type: error_type} ->
        error_type in retry_on

      %{reason: reason} ->
        is_retryable_error?(reason, retry_on)

      # Exception struct
      %{__exception__: true, __struct__: module} ->
        error_type =
          module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

        error_type in retry_on

      _ ->
        false
    end
  end

  # Calculate delay with exponential backoff and optional jitter
  defp calculate_delay(attempt, config) do
    # Exponential backoff: base_delay * (backoff_factor ^ (attempt - 1))
    delay =
      (config.base_delay * :math.pow(config.backoff_factor, attempt - 1))
      |> round()
      |> min(config.max_delay)

    if config.jitter do
      add_jitter(delay)
    else
      delay
    end
  end

  # Add random jitter (±25% of delay)
  defp add_jitter(delay) do
    jitter_range = div(delay, 4)
    delay + :rand.uniform(jitter_range * 2) - jitter_range
  end

  @doc """
  Create a retry configuration for common scenarios.

  ## Presets

  - `:quick` - Fast retries for quick operations (2 attempts, 100ms base)
  - `:standard` - Default configuration (3 attempts, 1s base)
  - `:persistent` - More aggressive retries (5 attempts, 1s base)
  - `:patient` - Long-running retries (10 attempts, 2s base)

  ## Examples

      Retry.with_retry(fn -> api_call() end, Retry.preset(:persistent))
  """
  @spec preset(atom()) :: retry_options()
  def preset(:quick) do
    [
      max_attempts: 2,
      base_delay: 100,
      max_delay: 1_000,
      backoff_factor: 2.0
    ]
  end

  def preset(:standard) do
    [
      max_attempts: 3,
      base_delay: 1_000,
      max_delay: 10_000,
      backoff_factor: 2.0
    ]
  end

  def preset(:persistent) do
    [
      max_attempts: 5,
      base_delay: 1_000,
      max_delay: 30_000,
      backoff_factor: 2.0
    ]
  end

  def preset(:patient) do
    [
      max_attempts: 10,
      base_delay: 2_000,
      max_delay: 60_000,
      backoff_factor: 1.5
    ]
  end

  def preset(_), do: preset(:standard)
end
