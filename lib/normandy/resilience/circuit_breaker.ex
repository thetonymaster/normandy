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

  ## Admission and stale results

  A call is admitted by one atomic request to the breaker, which returns the breaker's
  current *generation*. Every state change starts a new generation, and a result is
  counted only in the generation it was admitted in, so a slow call admitted while
  closed cannot close (or reopen) a half-open breaker. A half-open probe is monitored:
  if its process dies before it returns, its slot is freed and it counts as a failed
  probe, which reopens the breaker.

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

  # An admission: the generation it was admitted in, and the probe's monitor (half-open
  # only). A result whose generation is not the breaker's current one is ignored.
  @typep token :: {non_neg_integer(), reference() | nil}

  defmodule State do
    @moduledoc false
    defstruct [
      :key,
      :name,
      :state,
      :generation,
      :failure_count,
      :success_count,
      :failure_threshold,
      :success_threshold,
      :timeout,
      :half_open_max_calls,
      :probes,
      :opened_at,
      :last_failure_time
    ]

    @type t :: %__MODULE__{
            key: term(),
            name: term(),
            state: :closed | :open | :half_open,
            generation: non_neg_integer(),
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            failure_threshold: pos_integer(),
            success_threshold: pos_integer(),
            timeout: pos_integer(),
            half_open_max_calls: pos_integer(),
            probes: %{reference() => pid()},
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

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
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
    case GenServer.call(server, :acquire) do
      {:ok, token} -> execute_and_record(server, token, fun)
      {:error, :open} -> {:error, :open}
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
      key: Keyword.get(opts, :key),
      name: Keyword.get(opts, :name),
      state: :closed,
      generation: 0,
      failure_count: 0,
      success_count: 0,
      failure_threshold: Keyword.fetch!(opts, :failure_threshold),
      success_threshold: Keyword.fetch!(opts, :success_threshold),
      timeout: Keyword.fetch!(opts, :timeout),
      half_open_max_calls: Keyword.fetch!(opts, :half_open_max_calls),
      probes: %{},
      opened_at: nil,
      last_failure_time: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state = maybe_transition_to_half_open(state)
    {:reply, state.state, state}
  end

  # One call decides admission, so no state change can slip in between a state check
  # and taking a half-open slot (PERF-9). A half-open probe is monitored: if it dies
  # without recording, :DOWN frees its slot (PERF-1).
  def handle_call(:acquire, {caller, _tag}, state) do
    state = maybe_transition_to_half_open(state)

    case state.state do
      :closed ->
        {:reply, {:ok, {state.generation, nil}}, state}

      :half_open when map_size(state.probes) < state.half_open_max_calls ->
        ref = Process.monitor(caller)
        probes = Map.put(state.probes, ref, caller)
        {:reply, {:ok, {state.generation, ref}}, %{state | probes: probes}}

      _open_or_full ->
        {:reply, {:error, :open}, state}
    end
  end

  def handle_call({:record, {generation, ref}, outcome}, _from, state) do
    state = release_probe(state, ref)

    state =
      cond do
        generation != state.generation -> state
        outcome == :success -> handle_success(state)
        outcome == :failure -> handle_failure(state, :probe_failure)
      end

    {:reply, :ok, state}
  end

  def handle_call(:get_metrics, _from, state) do
    metrics = %{
      state: state.state,
      generation: state.generation,
      failure_count: state.failure_count,
      success_count: state.success_count,
      failure_threshold: state.failure_threshold,
      success_threshold: state.success_threshold,
      half_open_calls: map_size(state.probes),
      opened_at: state.opened_at,
      last_failure_time: state.last_failure_time
    }

    {:reply, metrics, state}
  end

  def handle_call(:reset, _from, state) do
    state = transition(state, :closed, :reset)
    {:reply, :ok, %{state | last_failure_time: nil}}
  end

  def handle_call(:trip, _from, state) do
    {:reply, :ok, transition(state, :open, :trip)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.probes, ref) do
      # A probe died without recording a result: its slot is free and it counts as a
      # failed probe.
      state = %{state | probes: Map.delete(state.probes, ref)}
      {:noreply, handle_failure(state, :probe_down)}
    else
      {:noreply, state}
    end
  end

  ## Private Functions

  @spec execute_and_record(GenServer.server(), token(), (-> term())) ::
          {:ok, term()} | {:error, term()}
  defp execute_and_record(server, token, fun) do
    {outcome, result} = run_fun(fun)
    :ok = record(server, token, outcome)
    result
  end

  defp run_fun(fun) do
    case fun.() do
      {:ok, _result} = success ->
        {:success, success}

      {:error, _reason} = error ->
        {:failure, error}

      # Neither {:ok, _} nor {:error, _}: a failure, as Retry treats it, so
      # composing the two cannot change the outcome.
      other ->
        {:failure, {:error, {:unexpected_return, other}}}
    end
  rescue
    error -> {:failure, {:error, {:exception, error}}}
  catch
    # An exit or throw is a failure too (as Retry treats it).
    :exit, reason -> {:failure, {:error, {:exit, reason}}}
    thrown -> {:failure, {:error, {:throw, thrown}}}
  end

  # The function already ran; a breaker that has stopped since has nothing left to
  # count, so the caller still gets its result. Any other exit (a timeout) propagates.
  defp record(server, token, outcome) do
    GenServer.call(server, {:record, token, outcome})
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
    :exit, {{:shutdown, _}, _call} -> :ok
  end

  defp release_probe(state, nil), do: state

  defp release_probe(state, ref) do
    Process.demonitor(ref, [:flush])
    %{state | probes: Map.delete(state.probes, ref)}
  end

  defp handle_success(state) do
    case state.state do
      :closed ->
        %{state | success_count: state.success_count + 1, failure_count: 0}

      :half_open ->
        state = %{state | success_count: state.success_count + 1}

        if state.success_count >= state.success_threshold,
          do: transition(state, :closed, :probe_success),
          else: state

      :open ->
        state
    end
  end

  defp handle_failure(state, half_open_reason) do
    now = System.monotonic_time(:millisecond)
    state = %{state | failure_count: state.failure_count + 1, last_failure_time: now}

    case state.state do
      :closed when state.failure_count >= state.failure_threshold ->
        transition(state, :open, :failure_threshold)

      :half_open ->
        transition(state, :open, half_open_reason)

      _closed_below_threshold_or_open ->
        state
    end
  end

  defp maybe_transition_to_half_open(%State{state: :open} = state) do
    if System.monotonic_time(:millisecond) - state.opened_at >= state.timeout,
      do: transition(state, :half_open, :timeout),
      else: state
  end

  defp maybe_transition_to_half_open(state), do: state

  # The only place the breaker's state changes. Every change starts a new generation,
  # so a result admitted before it is ignored, and drops every probe (their late
  # results are stale; their monitors would otherwise free slots of the new window).
  defp transition(state, to, reason) do
    from = state.state

    Enum.each(state.probes, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)

    state = %{
      state
      | state: to,
        generation: state.generation + 1,
        success_count: 0,
        probes: %{}
    }

    state =
      case to do
        :open -> %{state | opened_at: System.monotonic_time(:millisecond)}
        :half_open -> %{state | failure_count: 0}
        :closed -> %{state | failure_count: 0, opened_at: nil}
      end

    log_transition(state, from, to, reason)
    state
  end

  defp log_transition(_state, from, to, reason) do
    level = if to == :open, do: :warning, else: :info
    Logger.log(level, "Circuit breaker #{from} -> #{to} (#{reason})")
  end
end
