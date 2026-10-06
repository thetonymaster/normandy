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

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLMError
  alias Normandy.TurnError

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

  An unknown option or a bad value raises `ArgumentError`.

  ## Returns

  - `{:ok, result}` - Success after 1 or more attempts
  - `{:error, {reason, attempts, errors}}` - every failure: `reason` is the last
    error, `attempts` how many were made (1 for a non-retryable error), and
    `errors` all of them in order. A return that is neither `{:ok, _}` nor
    `{:error, _}` is the error `{:unexpected_return, value}`.

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
    do_retry(fun, retry_config!(opts), 1, [])
  end

  @option_defaults [
    max_attempts: @default_max_attempts,
    base_delay: @default_base_delay,
    max_delay: @default_max_delay,
    backoff_factor: @default_backoff_factor,
    jitter: @default_jitter,
    retry_on: @default_retry_on,
    retry_if: nil
  ]

  @doc """
  Checks retry options without running anything, raising `ArgumentError` on an
  unknown option or a bad value. `BaseAgent.init/1` calls it for
  `:retry`, so a mistake surfaces when the agent is built.
  """
  @spec validate_options!(retry_options()) :: :ok
  def validate_options!(opts) do
    _ = retry_config!(opts)
    :ok
  end

  # An unknown option or a bad value raises: a typo such as max_attemps: must
  # not silently fall back to the default.
  defp retry_config!(opts) do
    case Keyword.keys(opts) -- Keyword.keys(@option_defaults) do
      [] ->
        :ok

      [key | _] ->
        raise ArgumentError,
              "Retry.with_retry/2: unknown option #{inspect(key)}; supported: " <>
                Enum.map_join(Keyword.keys(@option_defaults), ", ", &inspect/1)
    end

    config = Map.new(Keyword.merge(@option_defaults, opts))

    check_option!(config, :max_attempts, &(is_integer(&1) and &1 > 0), "a positive integer")
    check_option!(config, :base_delay, &(is_integer(&1) and &1 >= 0), "a non-negative integer")
    check_option!(config, :max_delay, &(is_integer(&1) and &1 >= 0), "a non-negative integer")
    check_option!(config, :backoff_factor, &(is_number(&1) and &1 >= 1), "a number >= 1")
    check_option!(config, :jitter, &is_boolean/1, "a boolean")

    check_option!(
      config,
      :retry_on,
      &(is_list(&1) and Enum.all?(&1, fn a -> is_atom(a) end)),
      "a list of atoms"
    )

    check_option!(config, :retry_if, &(is_nil(&1) or is_function(&1, 1)), "a 1-arity function")

    config
  end

  defp check_option!(config, key, valid?, expected) do
    value = Map.fetch!(config, key)

    unless valid?.(value) do
      raise ArgumentError,
            "Retry.with_retry/2: #{inspect(key)} must be #{expected}, got: #{shown(value)}"
    end
  end

  # A map, list or tuple can hold a secret, so only its type is shown.
  defp shown(value) when is_map(value) or is_list(value) or is_tuple(value),
    do: Describe.type_of(value)

  defp shown(value), do: inspect(value)

  # Private retry loop (retry_or_fail/5 only re-enters below max_attempts)
  defp do_retry(fun, config, attempt, errors) do
    case execute_safely(fun) do
      {:ok, result} ->
        if attempt > 1 do
          Logger.info("Retry succeeded on attempt #{attempt}")
        end

        {:ok, result}

      {:error, error} ->
        retry_or_fail(fun, config, attempt, errors, error)

      # A value that is neither {:ok, _} nor {:error, _} is a failure like any
      # other (CircuitBreaker treats it the same way).
      other ->
        retry_or_fail(fun, config, attempt, errors, {:unexpected_return, other})
    end
  end

  # Every failure returns {:error, {last_error, attempts_made, errors}}.
  defp retry_or_fail(fun, config, attempt, errors, error) do
    if attempt < config.max_attempts and retryable?(error, config) do
      delay = calculate_delay(attempt, config)
      type = error_type(error)

      :telemetry.execute(
        [:normandy, :retry, :attempt],
        %{attempt: attempt, max_attempts: config.max_attempts, delay_ms: delay},
        %{error_type: type}
      )

      # Metadata for the host's log formatter, built apart from the call as BaseAgent's
      # lifecycle logs do (Normandy configures no Logger metadata keys of its own).
      metadata = [
        attempt: attempt,
        max_attempts: config.max_attempts,
        delay_ms: delay,
        error_type: type
      ]

      Logger.warning(
        "Retry attempt #{attempt}/#{config.max_attempts} failed: #{describe(error)}. " <>
          "Retrying in #{delay}ms...",
        metadata
      )

      Process.sleep(delay)
      do_retry(fun, config, attempt + 1, [error | errors])
    else
      if attempt < config.max_attempts do
        metadata = [error_type: error_type(error)]
        Logger.warning("Non-retryable error: #{describe(error)}", metadata)
      end

      {:error, {error, attempt, Enum.reverse([error | errors])}}
    end
  end

  # A failure for a warning: its module or kind, and an LLMError's type; never its
  # message, payload or stacktrace arguments, which can hold the value it failed on (an
  # LLMError's detail carries the provider's response body).
  defp describe({:exception, exception, stacktrace}),
    do: TurnError.describe_raised(:error, exception, stacktrace)

  defp describe({kind, _payload}) when kind in [:exit, :throw],
    do: TurnError.describe_raised(kind, nil, [])

  defp describe(%LLMError{type: type}), do: "#{inspect(LLMError)} (#{type})"
  defp describe(%module{} = exception) when is_exception(exception), do: inspect(module)
  defp describe(atom) when is_atom(atom), do: inspect(atom)

  defp describe(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
    do: "{#{inspect(elem(tuple, 0))}, ...}"

  defp describe(_error), do: "a returned error"

  # A failure's type for telemetry and log metadata: never its message or payload.
  defp error_type(%LLMError{type: type}), do: type

  defp error_type({:exception, exception, _stacktrace}) when is_exception(exception),
    do: exception.__struct__

  defp error_type({kind, _payload}) when kind in [:exit, :throw, :unexpected_return], do: kind
  defp error_type(%module{} = exception) when is_exception(exception), do: module
  defp error_type(atom) when is_atom(atom), do: atom
  defp error_type(_error), do: :error

  # Runs the function, turning a raise, exit or throw into an error value.
  defp execute_safely(fun) do
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

  # Determine if error is retryable
  defp retryable?(error, config) do
    # Check custom retry condition first
    if config.retry_if do
      config.retry_if.({:error, error})
    else
      # Check if error type is in retry_on list
      retryable_error?(error, config.retry_on)
    end
  end

  # Check if error matches retryable types
  defp retryable_error?(error, retry_on) do
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
        retryable_error?(reason, retry_on)

      # Exception struct
      # Exception struct, matched by its underscored name (no atom is created)
      %{__exception__: true, __struct__: module} ->
        name = module |> Module.split() |> List.last() |> Macro.underscore()
        Enum.any?(retry_on, &(Atom.to_string(&1) == name))

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

  # Add random jitter (±25% of delay). Below 4ms the range rounds to 0, and
  # :rand.uniform/1 rejects 0, so the delay is returned unchanged.
  @doc false
  @spec add_jitter(non_neg_integer()) :: non_neg_integer()
  def add_jitter(delay) when delay < 4, do: delay

  def add_jitter(delay) do
    jitter_range = div(delay, 4)
    delay + :rand.uniform(jitter_range * 2 + 1) - 1 - jitter_range
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

  def preset(other) do
    raise ArgumentError,
          "Retry.preset/1: unknown preset #{inspect(other)}; expected :quick, :standard, " <>
            ":persistent or :patient"
  end
end
