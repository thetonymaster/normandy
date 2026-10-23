defmodule Normandy.Resilience.CircuitBreaker do
  @moduledoc """
  Circuit Breaker pattern implementation to prevent cascading failures.

  The circuit breaker monitors failures and can transition between three states:
  - **Closed**: Normal operation, requests pass through
  - **Open**: Failures exceeded threshold, requests fail fast
  - **Half-Open**: Testing if service recovered, limited requests allowed

  ## States

  ```
  Closed ──(failures >= threshold)──> Open
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

  ## Shared breakers

  `BaseAgent` agents configured with `circuit_breaker:` use a breaker shared by every
  agent with the same client module, endpoint, model and breaker options (`key/3`).
  Normandy starts it on first use under its own supervisor (`ensure_started/1`), so it
  does not depend on the process that built the agent. Breakers are per node. Set
  `:scope` to give a tenant (or a test) its own breaker.

  `BaseAgent` counts only failures that say the endpoint is unhealthy (see
  `BaseAgent.init/1`'s `:circuit_breaker`); `call/3` and `run/3` take the same choice as
  `:failure_if`.

  `start_link/1` and `call/3` remain for a breaker you start and supervise yourself.

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

  # A keyed (shared) breaker that has been closed with no probes and received no
  # message for this long stops itself; the next use starts a fresh one.
  @idle_stop_ms 900_000

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
      :last_failure_time,
      :idle_timeout
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
            last_failure_time: integer() | nil,
            idle_timeout: pos_integer() | :infinity
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

  @key_opts_schema NimbleOptions.new!(
                     Keyword.delete(@start_link_opts_schema.schema, :name) ++
                       [
                         scope: [
                           type: :any,
                           default: nil,
                           doc:
                             "Any plain term that separates breakers which would otherwise " <>
                               "share one (one per tenant, one per test). It appears in " <>
                               "telemetry and logs: never put a secret in it."
                         ]
                       ]
                   )

  @registry Normandy.Resilience.CircuitBreaker.Registry
  @supervisor Normandy.Resilience.CircuitBreaker.Supervisor

  @typedoc """
  A shared breaker's identity: the client's module, its endpoint (scheme, host, port and
  path of its `base_url`, or `nil`), the model, and the breaker options with their
  defaults, sorted. Never a credential.
  """
  @type key :: {module(), String.t() | nil, String.t(), keyword()}

  @call_opts_schema NimbleOptions.new!(
                      failure_if: [
                        type: {:fun, 1},
                        doc:
                          "Decides whether a failed call counts against the breaker. It gets " <>
                            "the `{:error, reason}` the call returns (a raise, exit or throw " <>
                            "is `{:error, {:exception | :exit | :throw, _}}`, a return that is neither " <>
                            "`{:ok, _}` nor `{:error, _}` is `{:error, {:unexpected_return, value}}`); " <>
                            "`false` leaves the counts unchanged and frees a half-open probe's " <>
                            "slot. It must return a boolean; one that raises or returns anything " <>
                            "else counts the failure. By default every failure counts."
                      ]
                    )

  @doc false
  # BaseAgent.InitOptions builds :circuit_breaker's check from the :key schema.
  @spec __opts_schema__(:start_link | :key) :: NimbleOptions.t()
  def __opts_schema__(:start_link), do: @start_link_opts_schema
  def __opts_schema__(:key), do: @key_opts_schema

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

  ## Options

  #{Options.docs(@call_opts_schema)}
  """
  @spec call(GenServer.server(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def call(server, fun, opts \\ []) when is_function(fun, 0) do
    opts = Options.validate!(opts, @call_opts_schema, {__MODULE__, :call, 3})

    case GenServer.call(server, :acquire) do
      {:ok, token} -> execute_and_record(server, token, fun, opts[:failure_if])
      {:error, :open} -> {:error, :open}
    end
  end

  @doc """
  The key of the shared breaker for `client`, `model` and the breaker options `opts`.

  Agents whose client module, endpoint, model and options are all equal share one
  breaker. The endpoint is the client's `base_url` (its struct field, else
  `client.options[:base_url]`) reduced to scheme, host, port and path; credentials,
  query and fragment are dropped.

  ## Options

  #{Options.docs(@key_opts_schema)}
  """
  @spec key(struct(), String.t(), keyword()) :: key()
  def key(%client_module{} = client, model, opts) when is_binary(model) do
    opts = Options.validate!(opts, @key_opts_schema, {__MODULE__, :key, 3})
    {client_module, endpoint(client), model, Enum.sort(opts)}
  end

  @doc """
  The running breaker for `key`, starting it under Normandy's supervisor when there is
  none. The breaker is not linked to the caller, and a breaker that crashed, or that
  stopped itself after being idle, is not running and is not restarted: the next
  `ensure_started/1` starts a fresh, closed one.
  """
  @spec ensure_started(key()) :: {:ok, pid()}
  def ensure_started(key) do
    case fetch(key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        spec = %{id: __MODULE__, start: {__MODULE__, :start_keyed, [key]}, restart: :temporary}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc "The running breaker for `key`, or `:error` when none runs."
  @spec fetch(key()) :: {:ok, pid()} | :error
  def fetch(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  `call/3` through the shared breaker for `key`, started if needed (`ensure_started/1`).
  Returns what `call/3` returns. Takes `call/3`'s options.
  """
  @spec run(key(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    opts = Options.validate!(opts, @call_opts_schema, {__MODULE__, :run, 3})

    case admit(key) do
      {pid, {:ok, token}} -> execute_and_record(pid, token, fun, opts[:failure_if])
      {_pid, {:error, :open}} -> {:error, :open}
    end
  end

  @doc false
  # The DynamicSupervisor's start function for a keyed breaker.
  @spec start_keyed(key()) :: GenServer.on_start()
  def start_keyed({_module, _endpoint, _model, opts} = key) do
    GenServer.start_link(__MODULE__, [{:key, key} | Keyword.delete(opts, :scope)],
      name: {:via, Registry, {@registry, key}}
    )
  end

  # A breaker that stopped between ensure_started/1 and the admission is started
  # again, once.
  defp admit(key, retries \\ 1) do
    {:ok, pid} = ensure_started(key)
    {pid, GenServer.call(pid, :acquire)}
  catch
    :exit, {reason, _call} when retries > 0 and reason in [:noproc, :normal, :shutdown] ->
      admit(key, retries - 1)
  end

  defp endpoint(client) do
    case Map.get(client, :base_url) || options_base_url(client) do
      url when is_binary(url) -> sanitize_url(url)
      _none -> nil
    end
  end

  defp options_base_url(%{options: %{base_url: url}}), do: url
  defp options_base_url(_client), do: nil

  # Scheme, host, port and path only: userinfo, query and fragment can carry a token. A
  # base_url with no scheme or host (a misconfiguration) gives nil rather than its text.
  defp sanitize_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, path: path}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        port = if port in [nil, URI.default_port(scheme)], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port}#{path}"

      _no_scheme_or_host ->
        nil
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
        generation: 0,
        failure_count: 2,
        success_count: 100,
        failure_threshold: 5,
        success_threshold: 2,
        half_open_calls: 0,
        opened_at: nil,
        last_failure_time: nil
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
    key = Keyword.get(opts, :key)

    state = %State{
      key: key,
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
      last_failure_time: nil,
      idle_timeout: if(key == nil, do: :infinity, else: @idle_stop_ms)
    }

    {:ok, state, state.idle_timeout}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state = maybe_transition_to_half_open(state)
    reply(state.state, state)
  end

  # One call decides admission, so no state change can slip in between a state check
  # and taking a half-open slot (PERF-9). A half-open probe is monitored: if it dies
  # without recording, :DOWN frees its slot (PERF-1).
  def handle_call(:acquire, {caller, _tag}, state) do
    state = maybe_transition_to_half_open(state)

    case state.state do
      :closed ->
        reply({:ok, {state.generation, nil}}, state)

      :half_open when map_size(state.probes) < state.half_open_max_calls ->
        ref = Process.monitor(caller)
        probes = Map.put(state.probes, ref, caller)
        reply({:ok, {state.generation, ref}}, %{state | probes: probes})

      _open_or_full ->
        reply({:error, :open}, state)
    end
  end

  def handle_call({:record, {generation, ref}, outcome}, _from, state) do
    state = release_probe(state, ref)

    state =
      cond do
        generation != state.generation -> state
        outcome == :ignore -> state
        outcome == :success -> handle_success(state)
        outcome == :failure -> handle_failure(state, :probe_failure)
      end

    reply(:ok, state)
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

    reply(metrics, state)
  end

  def handle_call(:reset, _from, state) do
    state = transition(state, :closed, :reset)
    reply(:ok, %{state | last_failure_time: nil})
  end

  def handle_call(:trip, _from, state) do
    reply(:ok, transition(state, :open, :trip))
  end

  @impl true
  def handle_info(:timeout, %State{key: key, state: :closed, probes: probes} = state)
      when key != nil and probes == %{} do
    {:stop, :normal, state}
  end

  def handle_info(:timeout, state), do: noreply(state)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.probes, ref) do
      # A probe died without recording a result: its slot is free and it counts as a
      # failed probe.
      state = %{state | probes: Map.delete(state.probes, ref)}
      noreply(handle_failure(state, :probe_down))
    else
      noreply(state)
    end
  end

  # Every callback returns through reply/2 or noreply/1, so none can forget to re-arm
  # the idle timeout.
  defp reply(result, %State{} = state), do: {:reply, result, state, state.idle_timeout}
  defp noreply(%State{} = state), do: {:noreply, state, state.idle_timeout}

  ## Private Functions

  @spec execute_and_record(
          GenServer.server(),
          token(),
          (-> term()),
          ({:error, term()} -> boolean()) | nil
        ) ::
          {:ok, term()} | {:error, term()}
  defp execute_and_record(server, token, fun, failure_if) do
    {outcome, result} = run_fun(fun)
    :ok = record(server, token, classify(outcome, result, failure_if))
    result
  end

  # A failure the caller's classifier rejects is recorded as :ignore: its probe slot is
  # freed and no count changes.
  defp classify(:failure, result, failure_if) when is_function(failure_if, 1),
    do: if(counts_failure?(failure_if, result), do: :failure, else: :ignore)

  defp classify(outcome, _result, _failure_if), do: outcome

  # A classifier that raises, exits, throws or returns a non-boolean counts the failure:
  # the caller still gets its result and a half-open probe's slot is always released.
  defp counts_failure?(failure_if, result) do
    case failure_if.(result) do
      false -> false
      _true_or_invalid -> true
    end
  catch
    _kind, _reason -> true
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

  # The function already ran, so nothing that goes wrong recording its outcome (a breaker
  # that stopped or was killed, a call timeout) may take the caller down with it: the caller
  # still gets its result. The failure is logged by kind only, never the reason's payload.
  defp record(server, token, outcome) do
    GenServer.call(server, {:record, token, outcome})
  catch
    :exit, reason ->
      kind =
        case reason do
          {kind, _call} when is_atom(kind) -> kind
          kind when is_atom(kind) -> kind
          _other -> :exit
        end

      Logger.warning("Circuit breaker did not record a call's outcome (exit: #{kind})")
      :ok
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
    failures = state.failure_count

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

    report_transition(state, from, to, reason, failures)
    state
  end

  # The key (or name) is safe to show: key/3 keeps no credential in it.
  defp report_transition(state, from, to, reason, failures) do
    :telemetry.execute(
      [:normandy, :circuit_breaker, :state_change],
      %{count: 1, failure_count: failures},
      %{key: state.key, name: state.name, from: from, to: to, reason: reason}
    )

    level = if to == :open, do: :warning, else: :info
    breaker = inspect(state.key || state.name)

    # Metadata for the host's log formatter, built apart from the call as BaseAgent's
    # lifecycle logs do (Normandy configures no Logger metadata keys of its own).
    metadata = [circuit_breaker: breaker, from: from, to: to, reason: reason]
    Logger.log(level, "Circuit breaker #{breaker} #{from} -> #{to} (#{reason})", metadata)
  end
end
