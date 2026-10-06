defmodule Normandy.Resilience.CircuitBreaker do
  @moduledoc """
  Circuit Breaker pattern implementation to prevent cascading failures.

  The circuit breaker monitors failures and can transition between three states:
  - **Closed**: Normal operation, requests pass through
  - **Open**: Failures exceeded threshold, requests fail fast
  - **Half-Open**: Testing if service recovered, limited requests allowed

  ## States

  ```
  Closed ──(failures > threshold)──> Open
    ↑                                   │
    │                                   │
    └──(success)── Half-Open ←─(timeout)┘
  ```

  ## Features

  - Automatic state transitions based on failure rates
  - Configurable failure threshold and timeout
  - Half-open state for gradual recovery
  - Thread-safe using GenServer
  - Metrics and monitoring support

  ## Example

      # Start a circuit breaker
      {:ok, cb} = CircuitBreaker.start_link(
        name: :api_breaker,
        failure_threshold: 5,
        timeout: 60_000
      )

      # Execute protected call
      case CircuitBreaker.call(cb, fn ->
        MyAPI.risky_operation()
      end) do
        {:ok, result} -> handle_success(result)
        {:error, :open} -> handle_circuit_open()
        {:error, reason} -> handle_failure(reason)
      end

      # Check state
      CircuitBreaker.state(cb)  # :closed | :open | :half_open
  """

  use GenServer
  require Logger

  alias Normandy.Options

  @type state :: :closed | :open | :half_open
  @type circuit_breaker_option ::
          {:name, atom()}
          | {:failure_threshold, pos_integer()}
          | {:success_threshold, pos_integer()}
          | {:timeout, pos_integer()}
          | {:half_open_max_calls, pos_integer()}

  @type circuit_breaker_options :: [circuit_breaker_option()]

  defmodule State do
    @moduledoc false
    defstruct [
      :state,
      :failure_count,
      :success_count,
      :failure_threshold,
      :success_threshold,
      :timeout,
      :half_open_max_calls,
      :half_open_calls,
      :opened_at,
      :last_failure_time
    ]

    @type t :: %__MODULE__{
            state: :closed | :open | :half_open,
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            failure_threshold: pos_integer(),
            success_threshold: pos_integer(),
            timeout: pos_integer(),
            half_open_max_calls: pos_integer(),
            half_open_calls: non_neg_integer(),
            opened_at: integer() | nil,
            last_failure_time: integer() | nil
          }
  end

  ## Client API

  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the breaker."],
                            failure_threshold: [
                              type: :pos_integer,
                              default: 5,
                              doc: "Failures that open the breaker."
                            ],
                            success_threshold: [
                              type: :pos_integer,
                              default: 2,
                              doc: "Successes while half-open that close it again."
                            ],
                            timeout: [
                              type: :pos_integer,
                              default: 60_000,
                              doc:
                                "Milliseconds the breaker stays open before it lets probe " <>
                                  "calls through (half-open). Not a call timeout."
                            ],
                            half_open_max_calls: [
                              type: :pos_integer,
                              default: 1,
                              doc: "Probe calls allowed at once while half-open."
                            ]
                          )

  @doc false
  # BaseAgent.InitOptions builds :circuit_breaker's check from it (one list of keys).
  @spec __opts_schema__(:start_link) :: NimbleOptions.t()
  def __opts_schema__(:start_link), do: @start_link_opts_schema

  @doc """
  Start a circuit breaker GenServer.

  ## Options

  #{Options.docs(@start_link_opts_schema)}

  ## Examples

      {:ok, cb} = CircuitBreaker.start_link(name: :my_breaker)
      {:ok, cb} = CircuitBreaker.start_link(
        name: :api_breaker,
        failure_threshold: 10,
        timeout: 30_000
      )
  """
  @spec start_link(circuit_breaker_options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Execute a function protected by the circuit breaker.

  ## Returns

  - `{:ok, result}` - Function executed successfully
  - `{:error, :open}` - Circuit is open, request blocked
  - `{:error, reason}` - Function failed with reason; a raise is
    `{:error, {:exception, e}}`, an exit `{:error, {:exit, reason}}` and a throw
    `{:error, {:throw, value}}`, each recorded as a failure

  ## Examples

      CircuitBreaker.call(breaker, fn ->
        {:ok, MyAPI.call()}
      end)

      # With explicit error handling
      CircuitBreaker.call(breaker, fn ->
        case MyAPI.call() do
          {:ok, result} -> {:ok, result}
          {:error, _} = error -> error
        end
      end)
  """
  @spec call(GenServer.server(), function()) :: {:ok, term()} | {:error, term()}
  def call(server, fun) when is_function(fun, 0) do
    case GenServer.call(server, :get_state) do
      :open ->
        {:error, :open}

      :half_open ->
        # Try to acquire a slot in half-open state
        case GenServer.call(server, :try_half_open_call) do
          :allowed ->
            execute_and_record(server, fun)

          :rejected ->
            {:error, :open}
        end

      :closed ->
        execute_and_record(server, fun)
    end
  end

  @doc """
  Get the current state of the circuit breaker.

  ## Returns

  - `:closed` - Normal operation
  - `:open` - Circuit is open, failing fast
  - `:half_open` - Testing recovery

  ## Examples

      CircuitBreaker.state(breaker)
      #=> :closed
  """
  @spec state(GenServer.server()) :: state()
  def state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Get detailed metrics about the circuit breaker.

  ## Returns

  Map with current state and statistics

  ## Examples

      CircuitBreaker.metrics(breaker)
      #=> %{
        state: :closed,
        failure_count: 2,
        success_count: 100,
        opened_at: nil
      }
  """
  @spec metrics(GenServer.server()) :: map()
  def metrics(server) do
    GenServer.call(server, :get_metrics)
  end

  @doc """
  Manually reset the circuit breaker to closed state.

  ## Examples

      CircuitBreaker.reset(breaker)
      #=> :ok
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Manually open the circuit breaker (for testing or maintenance).

  ## Examples

      CircuitBreaker.trip(breaker)
      #=> :ok
  """
  @spec trip(GenServer.server()) :: :ok
  def trip(server) do
    GenServer.call(server, :trip)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    state = %State{
      state: :closed,
      failure_count: 0,
      success_count: 0,
      failure_threshold: Keyword.fetch!(opts, :failure_threshold),
      success_threshold: Keyword.fetch!(opts, :success_threshold),
      timeout: Keyword.fetch!(opts, :timeout),
      half_open_max_calls: Keyword.fetch!(opts, :half_open_max_calls),
      half_open_calls: 0,
      opened_at: nil,
      last_failure_time: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # Check if we should transition from open to half-open
    new_state = maybe_transition_to_half_open(state)
    {:reply, new_state.state, new_state}
  end

  def handle_call(:try_half_open_call, _from, state) do
    if state.half_open_calls < state.half_open_max_calls do
      new_state = %{state | half_open_calls: state.half_open_calls + 1}
      {:reply, :allowed, new_state}
    else
      {:reply, :rejected, state}
    end
  end

  def handle_call(:get_metrics, _from, state) do
    metrics = %{
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      failure_threshold: state.failure_threshold,
      success_threshold: state.success_threshold,
      opened_at: state.opened_at,
      last_failure_time: state.last_failure_time
    }

    {:reply, metrics, state}
  end

  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        half_open_calls: 0,
        opened_at: nil,
        last_failure_time: nil
    }

    Logger.info("Circuit breaker manually reset to closed state")
    {:reply, :ok, new_state}
  end

  def handle_call(:trip, _from, state) do
    new_state = transition_to_open(state)
    Logger.warning("Circuit breaker manually tripped to open state")
    {:reply, :ok, new_state}
  end

  def handle_call({:record_success}, _from, state) do
    new_state = handle_success(state)
    {:reply, :ok, new_state}
  end

  def handle_call({:record_failure}, _from, state) do
    new_state = handle_failure(state)
    {:reply, :ok, new_state}
  end

  ## Private Functions

  defp execute_and_record(server, fun) do
    case fun.() do
      {:ok, _result} = success ->
        GenServer.call(server, {:record_success})
        success

      {:error, _reason} = error ->
        GenServer.call(server, {:record_failure})
        error

      # Neither {:ok, _} nor {:error, _}: a failure, as Retry treats it, so
      # composing the two cannot change the outcome.
      other ->
        GenServer.call(server, {:record_failure})
        {:error, {:unexpected_return, other}}
    end
  rescue
    error ->
      GenServer.call(server, {:record_failure})
      {:error, {:exception, error}}
  catch
    # An exit or throw is a failure too (as Retry treats it); otherwise a call
    # that exits in half-open would leave its slot taken and the breaker stuck.
    :exit, reason ->
      GenServer.call(server, {:record_failure})
      {:error, {:exit, reason}}

    thrown ->
      GenServer.call(server, {:record_failure})
      {:error, {:throw, thrown}}
  end

  defp handle_success(state) do
    case state.state do
      :closed ->
        %{state | success_count: state.success_count + 1, failure_count: 0}

      :half_open ->
        new_success_count = state.success_count + 1
        new_half_open_calls = max(0, state.half_open_calls - 1)

        if new_success_count >= state.success_threshold do
          Logger.info("Circuit breaker recovered, transitioning to closed")

          %{
            state
            | state: :closed,
              success_count: 0,
              failure_count: 0,
              half_open_calls: 0,
              opened_at: nil
          }
        else
          %{
            state
            | success_count: new_success_count,
              half_open_calls: new_half_open_calls
          }
        end

      :open ->
        state
    end
  end

  defp handle_failure(state) do
    now = System.monotonic_time(:millisecond)

    case state.state do
      :closed ->
        new_failure_count = state.failure_count + 1

        if new_failure_count >= state.failure_threshold do
          Logger.warning(
            "Circuit breaker threshold reached (#{new_failure_count}/#{state.failure_threshold}), opening circuit"
          )

          transition_to_open(%{state | failure_count: new_failure_count, last_failure_time: now})
        else
          %{state | failure_count: new_failure_count, last_failure_time: now}
        end

      :half_open ->
        Logger.warning("Failure in half-open state, reopening circuit")

        transition_to_open(%{
          state
          | failure_count: state.failure_count + 1,
            success_count: 0,
            half_open_calls: 0,
            last_failure_time: now
        })

      :open ->
        %{state | last_failure_time: now}
    end
  end

  defp transition_to_open(state) do
    %{
      state
      | state: :open,
        opened_at: System.monotonic_time(:millisecond),
        half_open_calls: 0
    }
  end

  defp maybe_transition_to_half_open(state) do
    if state.state == :open do
      now = System.monotonic_time(:millisecond)
      time_open = now - state.opened_at

      if time_open >= state.timeout do
        Logger.info("Circuit breaker timeout elapsed, transitioning to half-open")

        %{
          state
          | state: :half_open,
            success_count: 0,
            failure_count: 0,
            half_open_calls: 0
        }
      else
        state
      end
    else
      state
    end
  end
end
