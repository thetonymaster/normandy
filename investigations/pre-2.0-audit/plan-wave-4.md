# Wave 4 — Supervised circuit breaker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Breakers that outlive whoever built the agent config, recover by themselves after a killed probe, never count a stale result, are shared per client + endpoint + model, and report their state changes (and Retry's attempts) through telemetry.

**Architecture:** `Normandy.Resilience.CircuitBreaker` keeps its GenServer but admits a call with one atomic `:acquire` that returns a token carrying the breaker's *generation* (bumped on every state change); results tagged with an older generation are ignored, and half-open probes are monitored so a killed probe releases its slot. A new `Normandy.Application` supervises keyed breakers (`Registry` + `DynamicSupervisor`); `BaseAgentConfig` holds only the breaker options, and every LLM call derives the key `{client_module, endpoint, model, options}` and starts the breaker on first use. `init/1` starts no process.

**Tech Stack:** Elixir ~> 1.15, OTP `Registry`/`DynamicSupervisor`, NimbleOptions (through `Normandy.Options`), `:telemetry`, ExUnit.

**Spec:** `investigations/pre-2.0-audit/plan.md` § "Wave 4" (Tasks 4.1, 4.2), decisions 8a and 8b in `investigations/pre-2.0-audit/decisions.md`, findings PERF-1, PERF-2, PERF-5, PERF-9 and A2 in `perf.md`, DX-27 in `devex.md`, TEL-6 in `telemetry.md`. Where this plan departs from `plan.md`'s Wave 4 text, the departure is listed under "Rulings against plan.md" below and in the appendix for Q.

**Verified before execution (2026-10-06):** every Elixir code block in Tasks 4.1a–4.2 was applied to a scratch worktree of `d442951` and run. Per-task test runs passed, and the final `mix precommit` (Tasks 4.1a–4.2 together) gave 72 doctests, 28 properties, 3051 tests, 0 failures, credo "found no issues", dialyzer 34 skipped / 0 unnecessary, and `mix docs --warnings-as-errors` exit 0. Three defects found by that run are already fixed in this text: `Turn.Server` has no `child_spec/1` (the PERF-2 test uses `start_link/1`); credo's `MissingMetadataKeyInLoggerConfig` rejects literal Logger metadata (it is built in a variable, as `BaseAgent.log_lifecycle/3` does); a `%URI{}` literal fails dialyzer's opaque check (`sanitize_url/1` builds the string). Prose edits (moduledocs, MIGRATING) were not run except through `mix docs`.

## Global Constraints

- Elixir `~> 1.15`; no new dependencies (`Registry`, `DynamicSupervisor` and `:telemetry` are already available).
- Every public function that takes options validates them with `Normandy.Options.validate!(opts, schema, {Mod, :fun, arity})`; an unknown option raises `ArgumentError` in the house style `"Mod.fun/arity: unknown option :x; supported: ..."`.
- No message, log line, telemetry metadata or breaker key contains a credential: never the client struct, never an API key, never the userinfo, query or fragment of a URL. Map, list and tuple values are described by type (`Normandy.Components.ContentBlock.Describe.type_of/1`), never `inspect`ed, in error messages.
- Logs describe errors by type (module, `LLMError` type, or `:exit`/`:throw`), never with `inspect(error)` or a stacktrace.
- Every new telemetry event is documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs` enforces it).
- Every breaking change gets a bullet in `MIGRATING-2.0.md`, in a new section `## 31.` placed after `## 30.` and before `## New, non-breaking`.
- Tests: deterministic. No test depends on two processes racing; a `Process.sleep` is allowed only to let a breaker's `:timeout` (set to `1`) elapse, never to "wait for a message to arrive" (use `Normandy.Test.Eventually.wait_until/1`, `assert_receive`, or a synchronous call instead).
- Tests that use keyed breakers set a unique `:scope` (or a unique model) so async tests never share a breaker.
- Run `mix format` before every test run. A task is done only when `mix precommit 2>&1 | tee <log>` shows ` 0 failures` and exit 0, and `mix docs --warnings-as-errors` exits 0.
- Commits: add files individually (`git add <path>`; `git add .`/`-A` forbidden); no AI attribution of any kind in the message; never push.
- Do not edit `CLAUDE.md`. Proposed CLAUDE.md text goes to the controller in the task report (Task 4.3 collects it for Q).

## Design

### Breaker identity (decision 8b)

`CircuitBreaker.key(client, model, opts)` returns

```elixir
{client_module, endpoint, model, normalized_opts}
```

- `client_module`: the client struct's module (`Normandy.LLM.ClaudioAdapter`, ...).
- `endpoint`: the client's `base_url` (struct field, else `client.options[:base_url]` when `options` is a map), reduced to scheme, host, port and path (`URI`), or `nil`. Userinfo, query and fragment are dropped, so a token in a URL never reaches the key.
- `model`: the model string.
- `normalized_opts`: the breaker options with defaults filled in, sorted by key: `failure_threshold`, `half_open_max_calls`, `scope`, `success_threshold`, `timeout`. Two agents share a breaker only when every option matches, so there is no "first one wins" and no mismatch error.
- `:scope` (new option, any plain term, default `nil`) separates breakers that would otherwise share: one per tenant when tenants have their own API keys and rate limits, one per test. The key (and so `:scope`) appears in telemetry and logs; it must not hold a secret.

The API key is never part of the key: two tenants on one endpoint and model share a breaker unless they set `:scope`.

### Ownership (decision 8a, PERF-2, PERF-5, DX-27)

- `Normandy.Application` (new; `mix.exs` gains `mod: {Normandy.Application, []}`) starts, under `Normandy.Supervisor` with `:rest_for_one`:
  1. `{Registry, keys: :unique, name: Normandy.Resilience.CircuitBreaker.Registry}`
  2. `{DynamicSupervisor, strategy: :one_for_one, name: Normandy.Resilience.CircuitBreaker.Supervisor}`
- `CircuitBreaker.ensure_started(key)` returns `{:ok, pid}`, starting the breaker under the DynamicSupervisor (registered `{:via, Registry, {Registry, key}}`) when none runs. Breakers are `restart: :temporary`: a crashed breaker is gone and the next call starts a fresh one (closed), so a crash loop can never exhaust the supervisor's restart intensity.
- `CircuitBreaker.run(key, fun)` = `ensure_started` + admission + `fun` + record. A breaker that stops between `ensure_started` and admission is started again, once.
- `BaseAgentConfig` loses `circuit_breaker_pid`. It keeps `circuit_breaker` (the options or `nil`). `BaseAgentConfig.circuit_breaker_key(config)` derives the key from `config.client`, `config.model` and `config.circuit_breaker` at each LLM call, so a model changed later (`Turn.Session.put_config/2`, `%{config | model: ...}`) uses the new model's breaker.
- `BaseAgent.init/1` starts no process; `check_init!/1` and `init/1` differ only in building the struct. `AgentPool` therefore starts no breaker per agent (PERF-5).
- `ConfigTemplate`: `circuit_breaker_pid` leaves `@node_local_fields`; the template carries the options as before; `rebuild/3` needs nothing from the supplement for the breaker. A template whose `node_local_fields` lists `:circuit_breaker_pid` (written by an unreleased 2.0 build) raises through the existing "lists ... in :node_local_fields" check (decision 17c: unreleased 2.0 templates are not translated).
- Breakers are node-local: a session rebuilt on another node uses that node's breaker for the same key.

### Admission, generations and probes (PERF-1, PERF-9, A2 remainder)

- One call, `GenServer.call(server, :acquire)`, applies the open→half-open timeout and decides:
  - `:closed` → `{:ok, {generation, nil}}`
  - `:open` → `{:error, :open}`
  - `:half_open` with fewer than `half_open_max_calls` probes → monitors the caller, `{:ok, {generation, monitor_ref}}`
  - `:half_open` and full → `{:error, :open}`
- Every state change (`closed→open`, `open→half_open`, `half_open→closed`, `half_open→open`, `reset/1`, `trip/1`) goes through one `transition(state, to, reason)` that bumps `generation`, demonitors and clears all probes, and logs (Task 4.2 adds telemetry there).
- `GenServer.call(server, {:record, token, :success | :failure})` first releases the token's probe (demonitor with `:flush`), then applies the outcome only when the token's generation equals the current one. A stale result changes nothing.
- `{:DOWN, ref, ...}` for a probe: the probe died without recording; remove it and count a failure (`reason: :probe_down`), which reopens the breaker. A killed probe no longer wedges the breaker.
- `record` is synchronous. If the breaker is gone (`:noproc`, `:normal`, `:shutdown`), the caller still gets its function's result; any other exit (a timeout) propagates.
- No half-open lease timer: a probe that is alive but slow keeps its slot until it returns (LLM calls carry HTTP timeouts). See appendix question 6.

### Telemetry (TEL-6)

- `[:normandy, :circuit_breaker, :state_change]` — measurements `%{count: 1, failure_count: n}`; metadata `%{key: key | nil, name: name | nil, from: state, to: state, reason: reason}`, `reason` one of `:failure_threshold | :timeout | :probe_success | :probe_failure | :probe_down | :reset | :trip`.
- `[:normandy, :retry, :attempt]` — emitted when a failed attempt will be retried; measurements `%{attempt: n, max_attempts: m, delay_ms: d}`; metadata `%{error_type: atom}` (an `LLMError`'s `type`, an exception's module, `:exit`, `:throw`, `:unexpected_return`, an atom reason itself, else `:error`).
- Breaker and Retry log lines carry Logger metadata (`circuit_breaker: key`, `from:`, `to:`, `reason:`; `attempt:`, `max_attempts:`, `delay_ms:`, `error_type:`).

## Rulings against plan.md

- **R1** `ensure_started` takes only the key (`ensure_started(key) :: {:ok, pid}`), because the options are part of the key; `plan.md` wrote `ensure_started(key, opts) :: {:ok, key}`.
- **R2** The key is `{client_module, endpoint, model, normalized_opts}`, not `{client_module, endpoint, model}`: options in the identity remove the "two agents, same model, different thresholds" conflict without a runtime error (appendix question 1).
- **R3** "A 1.x template holding a pid rebuilds with a key": no released 1.x template holds a breaker (v1.0.0's `ConfigTemplate.from_config/2` writes no breaker field and no `node_local_fields`), so the acceptance becomes: a v1.0.0 template rebuilds with `circuit_breaker: nil`, and a template listing `:circuit_breaker_pid` raises naming it.
- **R4** The PERF-9 test may `Process.sleep(2)` after setting `timeout: 1` to let the open window elapse; ordering between the stale caller and the transitions is driven by messages (`send`/`assert_receive`), not by timing.

## Review Focus

1. **Async tests sharing a breaker.** Two tests (in Normandy's suite or a user's) that build agents with the same client module, endpoint, model and breaker options now share one breaker; one test's failures open the other's circuit. Expected: `:scope` separates them. Test in Task 4.1b ("different scopes get different breakers") and every keyed-breaker test in this plan sets a unique scope.
2. **A breaker that dies while a call is in flight.** The caller's function finished; recording its outcome hits a dead process. Expected: the caller gets the function's result, no exit. Test in Task 4.1a ("a result recorded after the breaker stopped is still returned").
3. **Model changed after `init/1`.** `%{config | model: "other"}` or `Turn.Session.put_config/2`. Expected: calls use the new model's breaker; the old model's open circuit does not block them. Test in Task 4.1c ("a changed model uses its own breaker").
4. **Many first calls at once.** Twenty concurrent first LLM calls for one key. Expected: exactly one breaker process. Test in Task 4.1b ("concurrent ensure_started starts one breaker").
5. **A base URL with credentials.** `base_url: "https://user:pw@host/v1?key=sk-x"`. Expected: neither `pw` nor `sk-x` appears in the key, telemetry metadata or logs. Tests in Task 4.1b (key) and Task 4.2 (telemetry metadata).

---

### Task 4.1a: Atomic admission, generation tokens and monitored probes (PERF-1, PERF-9, A2)

**Files:**
- Modify: `lib/normandy/resilience/circuit_breaker.ex` (State struct, `call/2`, callbacks, private functions; the public API `start_link/1`, `call/2`, `state/1`, `metrics/1`, `reset/1`, `trip/1` keeps its names and arities)
- Test: `test/resilience/circuit_breaker_test.exs` (new `describe` blocks appended; existing tests must keep passing unchanged)

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 4.1b and 4.2 build on these private pieces, so keep the names):
  - `@type token :: {non_neg_integer(), reference() | nil}`
  - `State` gains `:key` (term, `nil` for `start_link/1` breakers), `:name` (the `:name` option or `nil`), `:generation` (non-neg integer, starts at 0) and `:probes` (`%{reference() => pid()}`); `:half_open_calls` is removed (it is `map_size(probes)`).
  - `defp transition(state, to, reason)` — the only place `state.state` changes.
  - `defp execute_and_record(server, token, fun)` — runs `fun`, records the outcome, returns the result.
  - `metrics/1` adds `generation` and `half_open_calls`.
  - `init/1` reads `Keyword.get(opts, :key)` and `Keyword.get(opts, :name)` (Task 4.1b passes `:key`).

- [ ] **Step 1: Write the failing tests**

Append to `test/resilience/circuit_breaker_test.exs`, before the final `end`:

```elixir
  # The open window is 1 ms; sleeping 2 ms only lets it elapse. Which result lands in
  # which generation is decided by messages, not by timing.
  defp open_then_half_open(cb) do
    :ok = CircuitBreaker.trip(cb)
    Process.sleep(2)
    assert CircuitBreaker.state(cb) == :half_open
  end

  # A caller admitted now whose function blocks until it gets {:finish, result}.
  defp blocked_caller(cb) do
    test_pid = self()

    task =
      Task.async(fn ->
        CircuitBreaker.call(cb, fn ->
          send(test_pid, {:admitted, self()})
          receive do: ({:finish, result} -> result)
        end)
      end)

    assert_receive {:admitted, caller}
    {task, caller}
  end

  describe "a killed half-open probe (PERF-1)" do
    test "frees its slot and reopens the breaker" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, half_open_max_calls: 1)
      open_then_half_open(cb)

      {task, probe} = blocked_caller(cb)
      assert CircuitBreaker.metrics(cb).half_open_calls == 1

      Process.unlink(task.pid)
      Process.exit(probe, :kill)

      assert wait_until(fn -> CircuitBreaker.metrics(cb).half_open_calls == 0 end)
      assert CircuitBreaker.metrics(cb).state == :open

      # The next window admits a new probe, and its success closes the breaker.
      Process.sleep(2)
      assert CircuitBreaker.call(cb, fn -> {:ok, 1} end) == {:ok, 1}
      assert CircuitBreaker.call(cb, fn -> {:ok, 2} end) == {:ok, 2}
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end

    test "a probe that returns normally releases its monitor" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, success_threshold: 1)
      open_then_half_open(cb)

      assert CircuitBreaker.call(cb, fn -> {:ok, :fine} end) == {:ok, :fine}
      assert CircuitBreaker.state(cb) == :closed
      assert {:monitors, []} = Process.info(cb, :monitors)

      GenServer.stop(cb)
    end
  end

  describe "stale results (PERF-9)" do
    test "a success admitted while closed does not count as a probe success" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, success_threshold: 1)

      {task, caller} = blocked_caller(cb)
      open_then_half_open(cb)

      send(caller, {:finish, {:ok, :late}})
      assert Task.await(task) == {:ok, :late}

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.state == :half_open
      assert metrics.success_count == 0

      GenServer.stop(cb)
    end

    test "a failure admitted while closed does not reopen a half-open breaker" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, failure_threshold: 1)

      {task, caller} = blocked_caller(cb)
      open_then_half_open(cb)

      send(caller, {:finish, {:error, :late}})
      assert Task.await(task) == {:error, :late}

      assert CircuitBreaker.state(cb) == :half_open

      GenServer.stop(cb)
    end

    test "a result admitted before reset/1 does not count after it" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)

      {task, caller} = blocked_caller(cb)
      :ok = CircuitBreaker.reset(cb)

      send(caller, {:finish, {:error, :late}})
      assert Task.await(task) == {:error, :late}

      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.metrics(cb).failure_count == 0

      GenServer.stop(cb)
    end

    test "every state change bumps the generation" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, success_threshold: 1)
      assert CircuitBreaker.metrics(cb).generation == 0

      :ok = CircuitBreaker.trip(cb)
      assert CircuitBreaker.metrics(cb).generation == 1

      Process.sleep(2)
      assert CircuitBreaker.state(cb) == :half_open
      assert CircuitBreaker.metrics(cb).generation == 2

      assert CircuitBreaker.call(cb, fn -> {:ok, 1} end) == {:ok, 1}
      assert CircuitBreaker.metrics(cb).generation == 3

      :ok = CircuitBreaker.reset(cb)
      assert CircuitBreaker.metrics(cb).generation == 4

      GenServer.stop(cb)
    end
  end

  describe "admission" do
    test "an open breaker admits nothing, even with no probe running" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 60_000)
      :ok = CircuitBreaker.trip(cb)

      assert CircuitBreaker.call(cb, fn -> flunk("must not run") end) == {:error, :open}
      assert CircuitBreaker.metrics(cb).half_open_calls == 0

      GenServer.stop(cb)
    end

    test "a result recorded after the breaker stopped is still returned" do
      {:ok, cb} = CircuitBreaker.start_link()
      Process.unlink(cb)

      result =
        CircuitBreaker.call(cb, fn ->
          GenServer.stop(cb)
          {:ok, :done}
        end)

      assert result == {:ok, :done}
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/resilience/circuit_breaker_test.exs`
Expected: the new tests FAIL. `half_open_calls` and `generation` are missing from `metrics/1` (a `KeyError`), the killed-probe test sees `state == :open` never reached with a freed slot, and the stale-result tests see `:closed`/`:open`. The pre-existing tests still pass.

- [ ] **Step 3: Rewrite the State struct, admission, recording and transitions**

In `lib/normandy/resilience/circuit_breaker.ex`:

Replace the `State` module with:

```elixir
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
```

Add after `@type circuit_breaker_options`:

```elixir
  # An admission: the generation it was admitted in, and the probe's monitor (half-open
  # only). A result whose generation is not the breaker's current one is ignored.
  @typep token :: {non_neg_integer(), reference() | nil}
```

In `start_link/1`, pass the name into `init/1` as well as to `GenServer.start_link/3` so state-change logs and telemetry can name the breaker:

```elixir
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end
```

Replace `call/2` with:

```elixir
  @spec call(GenServer.server(), function()) :: {:ok, term()} | {:error, term()}
  def call(server, fun) when is_function(fun, 0) do
    case GenServer.call(server, :acquire) do
      {:ok, token} -> execute_and_record(server, token, fun)
      {:error, :open} -> {:error, :open}
    end
  end
```

Replace `init/1` and every `handle_call` clause, and add `handle_info/2`:

```elixir
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
```

Replace every private function below `## Private Functions` with:

```elixir
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
```

Remove the now-unused `transition_to_open/1`.

Update the moduledoc's "Returns" of `call/2` only if it no longer matches; it still does (`{:ok, result}`, `{:error, :open}`, `{:error, reason}`). Add one paragraph to the moduledoc after "## Features":

```
  ## Admission and stale results

  A call is admitted by one atomic request to the breaker, which returns the breaker's
  current *generation*. Every state change starts a new generation, and a result is
  counted only in the generation it was admitted in, so a slow call admitted while
  closed cannot close (or reopen) a half-open breaker. A half-open probe is monitored:
  if its process dies before it returns, its slot is freed and it counts as a failed
  probe, which reopens the breaker.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/resilience/circuit_breaker_test.exs`
Expected: PASS, all tests, old and new.

Then run the other breaker users: `mix test test/agents/base_agent_resilience_test.exs test/agents/base_agent_stream_resilience_test.exs test/agents/base_agent_llm_error_test.exs test/options/coordination_options_test.exs`
Expected: PASS (nothing outside the module changed).

- [ ] **Step 5: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w4-4.1a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w4-4.1a.log` (the controller may substitute its scratchpad for `/tmp`).
Expected: ` 0 failures`, exit 0, credo clean, dialyzer `Unnecessary Skips: 0`.

```bash
git add lib/normandy/resilience/circuit_breaker.ex test/resilience/circuit_breaker_test.exs
git commit -m "fix(circuit_breaker): atomic admission, generation tokens, monitored probes"
```

### Task 4.1b: Keyed breakers under `Normandy.Application` (decisions 8a, 8b)

**Files:**
- Create: `lib/normandy/application.ex`
- Modify: `mix.exs` (`application/0` gains `mod: {Normandy.Application, []}`)
- Modify: `lib/normandy/resilience/circuit_breaker.ex` (key schema, `key/3`, `ensure_started/1`, `fetch/1`, `run/2`, `start_keyed/1`, moduledoc section)
- Modify: `test/options_coverage_test.exs` only if its allowlist or entry-point table needs the new `key/3` (it takes options; see Step 4)
- Test: create `test/resilience/circuit_breaker_keyed_test.exs`

**Interfaces:**
- Consumes (Task 4.1a): `init/1` reads `Keyword.get(opts, :key)`; `execute_and_record/3`; the `:acquire` call.
- Produces (Task 4.1c and 4.2 rely on these exact names):
  - `@type key :: {module(), String.t() | nil, String.t(), keyword()}`
  - `CircuitBreaker.key(client :: struct(), model :: String.t(), opts :: keyword()) :: key()` — validates `opts` with `{CircuitBreaker, :key, 3}`; raises `ArgumentError` otherwise.
  - `CircuitBreaker.ensure_started(key()) :: {:ok, pid()}`
  - `CircuitBreaker.fetch(key()) :: {:ok, pid()} | :error`
  - `CircuitBreaker.run(key(), (-> term())) :: {:ok, term()} | {:error, term()}` (same returns as `call/2`)
  - `CircuitBreaker.__opts_schema__(:key) :: NimbleOptions.t()` — the start_link schema without `:name`, plus `:scope`. `BaseAgent.InitOptions` derives its `:circuit_breaker` check from it in Task 4.1c.
  - Process names: `Normandy.Resilience.CircuitBreaker.Registry` (a `Registry`), `Normandy.Resilience.CircuitBreaker.Supervisor` (a `DynamicSupervisor`), `Normandy.Supervisor` (the application's root).

- [ ] **Step 1: Write the failing tests**

Create `test/resilience/circuit_breaker_keyed_test.exs`:

```elixir
defmodule Normandy.Resilience.CircuitBreakerKeyedTest do
  use ExUnit.Case, async: true

  import Normandy.Test.Eventually

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.OpenAICompatibleAdapter
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  # Every test gets its own scope, so async tests never share a breaker.
  defp scope, do: {__MODULE__, System.unique_integer([:positive])}

  defp stub_key(opts \\ []),
    do: CircuitBreaker.key(%StubClient{}, "m", Keyword.put_new(opts, :scope, scope()))

  describe "key/3" do
    test "is the client module, endpoint, model and the options with defaults, sorted" do
      client = %OpenAICompatibleAdapter{api_key: "sk-secret", base_url: "https://api.example.com/v1"}

      assert CircuitBreaker.key(client, "gpt-x", failure_threshold: 3) ==
               {OpenAICompatibleAdapter, "https://api.example.com/v1", "gpt-x",
                [
                  failure_threshold: 3,
                  half_open_max_calls: 1,
                  scope: nil,
                  success_threshold: 2,
                  timeout: 60_000
                ]}
    end

    test "[] and the explicit defaults are the same key" do
      client = %StubClient{}

      assert CircuitBreaker.key(client, "m", []) ==
               CircuitBreaker.key(client, "m",
                 failure_threshold: 5,
                 success_threshold: 2,
                 timeout: 60_000,
                 half_open_max_calls: 1,
                 scope: nil
               )
    end

    test "never holds a credential: no API key, URL userinfo, query or fragment" do
      client = %OpenAICompatibleAdapter{
        api_key: "sk-secret",
        base_url: "https://user:pw@api.example.com:8443/v1?key=sk-query#frag"
      }

      key = CircuitBreaker.key(client, "m", [])
      shown = inspect(key)

      assert elem(key, 1) == "https://api.example.com:8443/v1"
      refute shown =~ "sk-secret"
      refute shown =~ "pw"
      refute shown =~ "sk-query"
      refute shown =~ "frag"
    end

    test "reads a ClaudioAdapter's base_url from its struct field, else its options" do
      assert {ClaudioAdapter, nil, "m", _} =
               CircuitBreaker.key(%ClaudioAdapter{api_key: "k"}, "m", [])

      assert {ClaudioAdapter, "https://proxy.local", "m", _} =
               CircuitBreaker.key(
                 %ClaudioAdapter{api_key: "k", options: %{base_url: "https://proxy.local"}},
                 "m",
                 []
               )
    end

    test "an unknown option raises in the house style" do
      assert_raise ArgumentError,
                   ~r/^Normandy.Resilience.CircuitBreaker.key\/3: unknown option :failure_treshold; supported: /,
                   fn -> CircuitBreaker.key(%StubClient{}, "m", failure_treshold: 3) end
    end

    test ":name is not a key option" do
      assert_raise ArgumentError, ~r/unknown option :name/, fn ->
        CircuitBreaker.key(%StubClient{}, "m", name: :x)
      end
    end
  end

  describe "ensure_started/1" do
    test "starts a breaker under Normandy's supervisor, once per key" do
      key = stub_key()
      assert CircuitBreaker.fetch(key) == :error

      {:ok, pid} = CircuitBreaker.ensure_started(key)
      assert {:ok, ^pid} = CircuitBreaker.ensure_started(key)
      assert CircuitBreaker.fetch(key) == {:ok, pid}

      children = DynamicSupervisor.which_children(Normandy.Resilience.CircuitBreaker.Supervisor)
      assert Enum.any?(children, &match?({_, ^pid, :worker, _}, &1))
      refute pid in (Process.info(self(), :links) |> elem(1))
    end

    test "the breaker uses the key's options" do
      key = stub_key(failure_threshold: 7, timeout: 1234)
      {:ok, pid} = CircuitBreaker.ensure_started(key)

      assert %{failure_threshold: 7} = CircuitBreaker.metrics(pid)
    end

    test "concurrent ensure_started starts one breaker" do
      key = stub_key()

      pids =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> CircuitBreaker.ensure_started(key) end) end)
        |> Enum.map(&Task.await/1)
        |> Enum.uniq()

      assert [{:ok, _pid}] = pids
    end

    test "different scopes get different breakers" do
      {:ok, a} = CircuitBreaker.ensure_started(stub_key())
      {:ok, b} = CircuitBreaker.ensure_started(stub_key())
      assert a != b
    end

    test "different models get different breakers" do
      s = scope()
      {:ok, a} = CircuitBreaker.ensure_started(CircuitBreaker.key(%StubClient{}, "m1", scope: s))
      {:ok, b} = CircuitBreaker.ensure_started(CircuitBreaker.key(%StubClient{}, "m2", scope: s))
      assert a != b
    end

    test "a breaker outlives the process that started it" do
      key = stub_key()

      {:ok, pid} =
        Task.async(fn -> CircuitBreaker.ensure_started(key) end) |> Task.await()

      assert Process.alive?(pid)
      assert CircuitBreaker.fetch(key) == {:ok, pid}
    end

    test "a crashed breaker is not restarted; the next use starts a fresh, closed one" do
      key = stub_key(failure_threshold: 1)
      {:ok, pid} = CircuitBreaker.ensure_started(key)
      :ok = CircuitBreaker.trip(pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert wait_until(fn -> CircuitBreaker.fetch(key) == :error end)

      assert CircuitBreaker.run(key, fn -> {:ok, :again} end) == {:ok, :again}
      {:ok, new_pid} = CircuitBreaker.fetch(key)
      assert new_pid != pid
      assert CircuitBreaker.state(new_pid) == :closed
    end
  end

  describe "run/2" do
    test "runs the function through the key's breaker" do
      key = stub_key(failure_threshold: 1)

      assert CircuitBreaker.run(key, fn -> {:error, :down} end) == {:error, :down}
      assert CircuitBreaker.run(key, fn -> flunk("must not run") end) == {:error, :open}

      {:ok, pid} = CircuitBreaker.fetch(key)
      assert CircuitBreaker.state(pid) == :open
    end
  end

  test "the application supervises the registry and the breaker supervisor" do
    assert is_pid(Process.whereis(Normandy.Supervisor))
    assert is_pid(Process.whereis(Normandy.Resilience.CircuitBreaker.Registry))
    assert is_pid(Process.whereis(Normandy.Resilience.CircuitBreaker.Supervisor))
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/resilience/circuit_breaker_keyed_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `CircuitBreaker.key/3` (and the application test fails: `Process.whereis(Normandy.Supervisor)` is `nil`).

- [ ] **Step 3: Add the application**

Create `lib/normandy/application.ex`:

```elixir
defmodule Normandy.Application do
  @moduledoc false
  # Normandy's own processes: the keyed circuit breakers (Normandy.Resilience.CircuitBreaker).
  # :rest_for_one, so breakers registered in a crashed Registry are restarted with it.
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Normandy.Resilience.CircuitBreaker.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Normandy.Resilience.CircuitBreaker.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Normandy.Supervisor)
  end
end
```

In `mix.exs`, `application/0` becomes (keep the existing comment above `extra_applications`):

```elixir
  def application do
    [
      mod: {Normandy.Application, []},
      # Not :mnesia for consumers (a dependency builds in :prod): OTP starts every
      # listed application, optional ones too when available, and only
      # SessionStore.Mnesia needs it. Apps that use that store add :mnesia
      # themselves; Normandy's own dev and test builds load it here.
      extra_applications: [:logger] ++ if(Mix.env() in [:dev, :test], do: [:mnesia], else: [])
    ]
  end
```

- [ ] **Step 4: Add the keyed API to `CircuitBreaker`**

In `lib/normandy/resilience/circuit_breaker.ex`, after `@start_link_opts_schema NimbleOptions.new!(...)`:

```elixir
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
```

Replace `__opts_schema__/1` with:

```elixir
  @doc false
  # BaseAgent.InitOptions builds :circuit_breaker's check from the :key schema.
  @spec __opts_schema__(:start_link | :key) :: NimbleOptions.t()
  def __opts_schema__(:start_link), do: @start_link_opts_schema
  def __opts_schema__(:key), do: @key_opts_schema
```

Add after `call/2`:

```elixir
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
  none. The breaker is not linked to the caller, and a breaker that crashed is not
  restarted: the next `ensure_started/1` starts a fresh, closed one.
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
  `call/2` through the shared breaker for `key`, started if needed (`ensure_started/1`).
  Returns what `call/2` returns.
  """
  @spec run(key(), (-> term())) :: {:ok, term()} | {:error, term()}
  def run(key, fun) when is_function(fun, 0) do
    case admit(key) do
      {pid, {:ok, token}} -> execute_and_record(pid, token, fun)
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
```

Add to the moduledoc, after "## Admission and stale results":

```
  ## Shared breakers

  `BaseAgent` agents configured with `circuit_breaker:` use a breaker shared by every
  agent with the same client module, endpoint, model and breaker options (`key/3`).
  Normandy starts it on first use under its own supervisor (`ensure_started/1`), so it
  does not depend on the process that built the agent. Breakers are per node. Set
  `:scope` to give a tenant (or a test) its own breaker.

  `start_link/1` and `call/2` remain for a breaker you start and supervise yourself.
```

`key/3` takes options: run `mix test test/options_coverage_test.exs` after this step. If it fails naming `key/3` (an entry point with options that its table does not list), add `key/3` to that test's table the way `start_link/1` is listed for this module, with a misspelled option (`failure_treshold`).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/resilience/circuit_breaker_keyed_test.exs test/resilience/circuit_breaker_test.exs test/options_coverage_test.exs`
Expected: PASS.

- [ ] **Step 6: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w4-4.1b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w4-4.1b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/application.ex mix.exs lib/normandy/resilience/circuit_breaker.ex test/resilience/circuit_breaker_keyed_test.exs
git commit -m "feat(circuit_breaker): shared breakers keyed by client, endpoint, model and options"
```
(Add `test/options_coverage_test.exs` to the `git add` only if Step 4 changed it.)

### Task 4.1c: Agents use the shared breaker; `init/1` starts nothing (PERF-2, PERF-5, DX-27)

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1`, delete `start_circuit_breaker/1`, `with_resilience/3` and its comment)
- Modify: `lib/normandy/agents/base_agent_config.ex` (drop `circuit_breaker_pid`; add `circuit_breaker_key/1`; moduledoc)
- Modify: `lib/normandy/agents/base_agent/init_options.ex` (`@breaker_schema` from `CircuitBreaker.__opts_schema__(:key)`; the `:circuit_breaker` doc)
- Modify: `lib/normandy/agents/config_template.ex` (`@node_local_fields [:mcp_servers]`; moduledoc and comment)
- Modify: `lib/normandy/behaviours/agent_template.ex` (drop `:circuit_breaker_pid` from the moduledoc and `supplement` type)
- Modify: `e2e/06_resilience.exs` (find the breaker through its key)
- Modify: `MIGRATING-2.0.md` (§22 table row and supplement bullet; new `## 31.`)
- Modify tests: `test/agents/base_agent_resilience_test.exs`, `test/agents/base_agent_config_groups_test.exs`, `test/agents/base_agent_init_options_test.exs`, `test/agents/config_template_test.exs`, `test/agents/config_template_v1_test.exs`
- Create test: `test/agents/base_agent_shared_breaker_test.exs`
- Modify test: `test/coordination/agent_pool_test.exs` (one new test)

**Interfaces:**
- Consumes (Task 4.1b): `CircuitBreaker.key/3`, `CircuitBreaker.run/2`, `CircuitBreaker.fetch/1`, `CircuitBreaker.__opts_schema__(:key)`.
- Produces: `BaseAgentConfig.circuit_breaker_key(BaseAgentConfig.t()) :: CircuitBreaker.key() | nil`. `%BaseAgentConfig{}` has no `circuit_breaker_pid` field.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/base_agent_shared_breaker_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentSharedBreakerTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLMError
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  defp scope, do: {__MODULE__, System.unique_integer([:positive])}

  defp overloaded(_response_model),
    do: {:error, LLMError.new(type: :overloaded, retryable?: true, status: 529)}

  defp agent(scope, opts \\ []) do
    BaseAgent.init(
      Keyword.merge(
        [
          client: %StubClient{},
          model: "m",
          circuit_breaker: [failure_threshold: 2, timeout: 60_000, scope: scope]
        ],
        opts
      )
    )
  end

  defp failing(agent), do: %{agent | client: %StubClient{reply: &overloaded/1}}

  test "init/1 starts no process; the first LLM call starts the breaker" do
    agent = agent(scope())
    key = BaseAgentConfig.circuit_breaker_key(agent)

    assert CircuitBreaker.fetch(key) == :error
    assert {:ok, _agent, _out} = BaseAgent.run(agent, "hi")
    assert {:ok, pid} = CircuitBreaker.fetch(key)
    refute pid in (Process.info(self(), :links) |> elem(1))
  end

  test "no circuit_breaker, no key" do
    assert BaseAgentConfig.circuit_breaker_key(BaseAgent.init(client: %StubClient{}, model: "m")) ==
             nil
  end

  test "a config built by a process that has since exited keeps working (PERF-2)" do
    parent = self()
    s = scope()

    {builder, ref} =
      spawn_monitor(fn ->
        send(parent, {:config, agent(s)})
        exit(:shutdown)
      end)

    assert_receive {:config, config}
    assert_receive {:DOWN, ^ref, :process, ^builder, :shutdown}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "perf2-#{System.unique_integer([:positive])}",
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
    assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "two"})
    assert {:ok, _pid} = CircuitBreaker.fetch(BaseAgentConfig.circuit_breaker_key(config))
  end

  test "two agents with the same client, model and options share one breaker" do
    s = scope()
    a = failing(agent(s))
    b = agent(s)

    assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "1")
    assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "2")

    assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(b, "3")
  end

  test "an agent on another model has its own breaker" do
    s = scope()
    a = failing(agent(s))
    other = agent(s, model: "other")

    assert {:error, _} = BaseAgent.run(a, "1")
    assert {:error, _} = BaseAgent.run(a, "2")

    assert {:ok, _agent, _out} = BaseAgent.run(other, "3")
  end

  test "a changed model uses its own breaker" do
    a = failing(agent(scope()))

    assert {:error, _} = BaseAgent.run(a, "1")
    assert {:error, _} = BaseAgent.run(a, "2")
    assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(a, "3")

    moved = %{a | model: "other", client: %StubClient{}}
    assert {:ok, _agent, _out} = BaseAgent.run(moved, "4")
  end
end
```

Append to `test/coordination/agent_pool_test.exs`, before the final `end` (add `alias Normandy.Agents.BaseAgent`, `alias Normandy.Agents.BaseAgentConfig` and `alias Normandy.Resilience.CircuitBreaker` at the top):

```elixir
  describe "circuit breakers (PERF-5)" do
    test "starting, overflowing and stopping a pool starts no breaker" do
      scope = {__MODULE__, System.unique_integer([:positive])}
      agent_config = Map.put(create_agent_config(), :circuit_breaker, scope: scope)

      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 2)

      agents = for _ <- 1..3, do: elem(AgentPool.checkout(pool), 1)
      Enum.each(agents, &AgentPool.checkin(pool, &1))

      key = BaseAgentConfig.circuit_breaker_key(BaseAgent.init(agent_config))
      assert CircuitBreaker.fetch(key) == :error

      AgentPool.stop(pool)
    end
  end
```

(Three checkouts from a pool of size 1: two are overflow agents. No agent made an LLM call, so no breaker for the key may exist; before this task each agent's `init/1` started one linked to the pool.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/base_agent_shared_breaker_test.exs test/coordination/agent_pool_test.exs`
Expected: FAIL. `BaseAgentConfig.circuit_breaker_key/1` is undefined (`UndefinedFunctionError`), and `init/1` rejects `:scope` until Step 3 (`unknown option :scope`).

- [ ] **Step 3: Wire BaseAgent, the config, init options and templates**

`lib/normandy/agents/base_agent_config.ex`:
- Add `alias Normandy.Resilience.CircuitBreaker`.
- Delete the `circuit_breaker_pid: pid() | nil,` type line and `field(:circuit_breaker_pid, :any, default: nil)`.
- Moduledoc, replace the option-groups sentence's breaker part with: "`circuit_breaker` (`Normandy.Resilience.CircuitBreaker` options or `nil`; the agent uses the breaker shared by every agent with the same client module, endpoint, model and options, see `circuit_breaker_key/1`)".
- Add after `guardrail/2`:

```elixir
  @doc """
  The key of the shared circuit breaker this config's LLM calls go through
  (`Normandy.Resilience.CircuitBreaker.key/3` of its client, model and `circuit_breaker`
  options), or `nil` when `circuit_breaker` is `nil`. Read at each call, so a changed
  model uses that model's breaker. `CircuitBreaker.fetch/1` finds the running breaker.
  """
  @spec circuit_breaker_key(t()) :: CircuitBreaker.key() | nil
  def circuit_breaker_key(%__MODULE__{circuit_breaker: nil}), do: nil

  def circuit_breaker_key(%__MODULE__{circuit_breaker: opts, client: client, model: model}),
    do: CircuitBreaker.key(client, model, opts)
```

`lib/normandy/agents/base_agent.ex`:
- In `init/1`, delete the comment "Every check is in check_init!/1: the breaker starts last, ..." and the line `circuit_breaker_pid = start_circuit_breaker(opts)`, and delete `circuit_breaker_pid: circuit_breaker_pid,` from the struct.
- Delete `defp start_circuit_breaker/1`.
- Replace the comment above `with_resilience` and its breaker branch:

```elixir
  # Retry (config.retry) inside the shared circuit breaker (BaseAgentConfig.circuit_breaker_key/1),
  # each only when configured. `may_retry?` is checked before each retry on top of the
  # retry_if policy; streaming uses it to stop once output reached the caller.
  defp with_resilience(config, call, may_retry? \\ fn -> true end) do
    retryable_call =
      if config.retry do
        retry_opts = retry_options(config.retry, may_retry?)
        fn -> Retry.with_retry(call, retry_opts) end
      else
        call
      end

    case BaseAgentConfig.circuit_breaker_key(config) do
      nil -> retryable_call.()
      key -> CircuitBreaker.run(key, retryable_call)
    end
  end
```

(Check that `BaseAgentConfig` is aliased in `base_agent.ex`; it is used throughout.)

`lib/normandy/agents/base_agent/init_options.ex`:
- Replace the `@breaker_schema` definition with:

```elixir
  @breaker_schema Normandy.Resilience.CircuitBreaker.__opts_schema__(:key).schema
                  |> Enum.map(fn {key, spec} -> {key, Keyword.delete(spec, :default)} end)
                  |> NimbleOptions.new!()
```

- Replace the `:circuit_breaker` option's `doc:` with:

```elixir
      doc:
        "Options of the shared `Normandy.Resilience.CircuitBreaker` this agent's LLM calls " <>
          "go through: `:failure_threshold` (failures before it opens), `:success_threshold` " <>
          "(successes that close it from half-open), `:timeout` (milliseconds open before " <>
          "half-open), `:half_open_max_calls` (calls let through when half-open), `:scope` " <>
          "(any plain term; agents with a different scope get different breakers). Agents with " <>
          "the same client module, endpoint, model and options share one breaker, started on " <>
          "the first call under Normandy's supervisor. `[]` uses the breaker's defaults; `nil` " <>
          "uses none."
```

`lib/normandy/agents/config_template.ex`:
- `@node_local_fields [:mcp_servers]`, with the comment above it changed to: "# Fields a template cannot hold (MCP settings that may carry an authorization token). The template records whether it was set, and `rebuild/3` takes it from the supplement."
- Moduledoc first paragraph: replace "`circuit_breaker_pid` and `mcp_servers` (from the supplement; the template records only that they were set, and `rebuild/3` raises if the supplement lacks one)" with "`mcp_servers` (from the supplement; the template records only that it was set, and `rebuild/3` raises if the supplement lacks it)". Add one sentence to the paragraph that lists what travels: "The `circuit_breaker` options travel; the breaker itself is the node's shared breaker for that key (`BaseAgentConfig.circuit_breaker_key/1`)."
- Nothing else: a template whose `node_local_fields` lists `:circuit_breaker_pid` now raises through the existing check ("lists :circuit_breaker_pid in :node_local_fields").

`lib/normandy/behaviours/agent_template.ex`: moduledoc "Optionally `:circuit_breaker_pid` (a node-local breaker) and `:mcp_servers` (which may carry authorization tokens); `ConfigTemplate.rebuild/3` requires each one the original config had set." becomes "Optionally `:mcp_servers` (which may carry authorization tokens); `ConfigTemplate.rebuild/3` requires it when the original config had it set."; delete `optional(:circuit_breaker_pid) => GenServer.server(),` from the type.

`e2e/06_resilience.exs`: replace `breaker = agent.circuit_breaker_pid` with

```elixir
# The shared breaker starts on the first LLM call; look it up when needed.
breaker = fn ->
  {:ok, pid} = CircuitBreaker.fetch(Normandy.Agents.BaseAgentConfig.circuit_breaker_key(agent))
  pid
end
```

and every later `CircuitBreaker.state(breaker)` / `CircuitBreaker.<fun>(breaker...)` with `breaker.()` in place of `breaker`. Confirm the file still parses: `mix run --no-start -e 'Code.string_to_quoted!(File.read!("e2e/06_resilience.exs"))'` exits 0. (The scenario runs live only in Wave 7.)

- [ ] **Step 4: Update the existing tests**

`test/agents/base_agent_init_options_test.exs`, "an unknown circuit breaker option is named": the expected message's supported list ends `":success_threshold, :timeout, :half_open_max_calls, :scope"`.

`test/agents/base_agent_config_groups_test.exs`: replace the three tests in `describe "circuit_breaker"` that mention `circuit_breaker_pid` with:

```elixir
    test "nil (the default) configures no breaker" do
      config = init([])

      assert config.circuit_breaker == nil
      assert BaseAgentConfig.circuit_breaker_key(config) == nil
      refute Map.has_key?(config, :circuit_breaker_pid)
    end

    test "a keyword list is kept as the breaker options; init/1 starts no process" do
      opts = [failure_threshold: 1, timeout: 60_000, scope: {__MODULE__, :kept}]
      config = init(circuit_breaker: opts)

      assert config.circuit_breaker == opts
      assert CircuitBreaker.fetch(BaseAgentConfig.circuit_breaker_key(config)) == :error
    end

    test "[] uses the breaker's defaults" do
      config = init(circuit_breaker: [])

      assert {StubClient, nil, "m", opts} = BaseAgentConfig.circuit_breaker_key(config)
      assert opts[:failure_threshold] == 5
    end
```

`test/agents/base_agent_resilience_test.exs`:
- Add `alias Normandy.Agents.BaseAgentConfig`.
- Add the helpers:

```elixir
  # Each agent gets its own breaker scope, so async tests never share a breaker.
  defp breaker_opts(opts),
    do: Keyword.put(opts, :scope, {__MODULE__, System.unique_integer([:positive])})

  defp breaker(agent) do
    {:ok, pid} = CircuitBreaker.fetch(BaseAgentConfig.circuit_breaker_key(agent))
    pid
  end
```

- Every `circuit_breaker: [ ... ]` becomes `circuit_breaker: breaker_opts([ ... ])`.
- Every `CircuitBreaker.state(agent.circuit_breaker_pid)` becomes `CircuitBreaker.state(breaker(agent))`.
- Delete every cleanup block `if agent.circuit_breaker_pid do GenServer.stop(agent.circuit_breaker_pid) end` (Normandy supervises the breaker).
- `assert agent.circuit_breaker_pid == nil` becomes `assert BaseAgentConfig.circuit_breaker_key(agent) == nil`.

`test/agents/config_template_test.exs`:
- "the circuit breaker and MCP servers come from the supplement, not the template": rename to "MCP servers come from the supplement, not the template"; delete `cb = spawn(fn -> :ok end)`; the supplement is `round_trip_supplement(%{mcp_servers: servers})` and the config `%{full_config(supp) | mcp_servers: servers}`. Keep the other assertions.
- Replace "rebuild raises when the template had a circuit breaker pid and the supplement has none" with:

```elixir
    test "the breaker options travel in the template and need nothing from the supplement" do
      supp = round_trip_supplement()
      config = %{full_config(supp) | circuit_breaker: [failure_threshold: 3, scope: "tenant-a"]}

      tmpl = ConfigTemplate.from_config(config, "t")
      assert tmpl.node_local_fields == []

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").circuit_breaker ==
               [failure_threshold: 3, scope: "tenant-a"]
    end

    test "a template that lists :circuit_breaker_pid (an earlier 2.0 build) raises naming it" do
      supp = round_trip_supplement()
      tmpl = ConfigTemplate.from_config(full_config(supp), "t")
      tmpl = %{tmpl | node_local_fields: [:circuit_breaker_pid]}

      assert_raise ArgumentError, ~r/lists :circuit_breaker_pid in :node_local_fields/, fn ->
        ConfigTemplate.rebuild(tmpl, supp, "TOKEN")
      end
    end
```

(If `full_config/1` already sets `mcp_servers`, so `node_local_fields` is not `[]`, assert `refute :circuit_breaker_pid in tmpl.node_local_fields` instead of `== []`. Read `full_config/1` first.)

`test/agents/config_template_v1_test.exs`: replace `assert config.circuit_breaker_pid == nil` with `refute Map.has_key?(config, :circuit_breaker_pid)`.

- [ ] **Step 5: MIGRATING**

In `MIGRATING-2.0.md` §22:
- The table row `| \`config.circuit_breaker\` (the pid) | \`config.circuit_breaker_pid\`; \`config.circuit_breaker\` is now the options |` becomes `| \`config.circuit_breaker\` (the pid) | \`config.circuit_breaker\` is now the options; the breaker is shared, see §31 |`.
- The bullet "An `AgentTemplate` supplement names the node-local breaker `:circuit_breaker_pid` (was `:circuit_breaker`). Templates now store ..." becomes "Templates now store the `retry`, `circuit_breaker` and `guardrails` options; a supplement needs nothing for the breaker (§31)."
- The bullet "`circuit_breaker:` accepts `:failure_threshold`, `:success_threshold`, `:timeout` and `:half_open_max_calls`. What the breaker does at runtime is unchanged here." becomes "`circuit_breaker:` accepts `:failure_threshold`, `:success_threshold`, `:timeout`, `:half_open_max_calls` and `:scope` (§31)."

Insert before `## New, non-breaking`:

```markdown
## 31. Circuit breakers are shared and supervised by Normandy

| 1.x | 2.0 |
|---|---|
| `init/1` with a breaker started a `CircuitBreaker` linked to the caller; the config held its pid (`config.circuit_breaker`) | `init/1` starts no process. The first LLM call starts the breaker under Normandy's own supervisor. The config holds only the options |
| One breaker per `init/1` call | One breaker per client module, endpoint (`base_url` without credentials or query), model and breaker options, shared by every agent that matches |
| An `AgentTemplate` supplement could carry the breaker | Not read; the template carries the options and each node uses its own shared breaker |
| — | `BaseAgentConfig.circuit_breaker_key(config)` and `CircuitBreaker.fetch/1` find an agent's breaker; `CircuitBreaker.key/3`, `ensure_started/1` and `run/2` are the shared-breaker API |

- A breaker no longer dies with the process that built the agent (a request process, a
  LiveView, a `Task`), and `AgentPool` no longer starts (and leaks) one per agent.
- Agents that share a breaker share its state: one agent's failures open the circuit for all
  of them. Give each tenant `circuit_breaker: [scope: tenant_id]` when tenants use their own
  API keys and rate limits. The key, scope included, appears in telemetry and logs, so a scope
  must not be a secret. Tests that run agents with a breaker concurrently should give each
  test its own `:scope`.
- `:normandy` now has an application callback (`Normandy.Application`) that supervises the
  breakers. It starts with your application as any dependency does; a script started with
  `mix run --no-start` calls `Application.ensure_all_started(:normandy)` first.
- A half-open probe whose process is killed (a `Task.shutdown(:brutal_kill)`, an
  `on_timeout: :kill_task`) frees its slot and counts as a failed probe. The breaker used to
  stay open until `reset/1`.
- A result from a call admitted before a state change is ignored: a slow call started while
  closed no longer closes (or reopens) a half-open breaker.
- `CircuitBreaker.metrics/1` adds `:generation` and `:half_open_calls`.
- Breakers are per node: a session rebuilt on another node uses that node's breaker.
- A template saved by an earlier 2.0 build with a breaker (`node_local_fields` listing
  `:circuit_breaker_pid`) raises `ArgumentError` in `ConfigTemplate.rebuild/3`; recreate the
  session, as for the other unreleased 2.0 templates (§22).
- `CircuitBreaker.start_link/1` and `call/2` remain for a breaker you start and supervise
  yourself.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/ test/coordination/agent_pool_test.exs test/resilience/ test/options/ test/options_coverage_test.exs`
Expected: PASS.

Run: `grep -rn "circuit_breaker_pid" lib test e2e docs/guides README.md`
Expected: only the two test assertions that it is absent (`refute Map.has_key?(config, :circuit_breaker_pid)`), the template test that names it in `node_local_fields`, and nothing in `lib/`.

- [ ] **Step 7: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w4-4.1c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w4-4.1c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

Report to the controller (do not edit `CLAUDE.md`) this proposed replacement for CLAUDE.md's `BaseAgentConfig` bullet fragment "`circuit_breaker` (breaker options or nil; `circuit_breaker_pid` is the node-local breaker init/1 started)": "`circuit_breaker` (breaker options or nil; calls go through the breaker shared per client module, endpoint, model and options, `BaseAgentConfig.circuit_breaker_key/1`)".

```bash
git add lib/normandy/agents/base_agent.ex lib/normandy/agents/base_agent_config.ex \
  lib/normandy/agents/base_agent/init_options.ex lib/normandy/agents/config_template.ex \
  lib/normandy/behaviours/agent_template.ex e2e/06_resilience.exs MIGRATING-2.0.md \
  test/agents/base_agent_shared_breaker_test.exs test/agents/base_agent_resilience_test.exs \
  test/agents/base_agent_config_groups_test.exs test/agents/base_agent_init_options_test.exs \
  test/agents/config_template_test.exs test/agents/config_template_v1_test.exs \
  test/coordination/agent_pool_test.exs
git commit -m "fix(agents)!: agents share a supervised breaker; init/1 starts no process"
```

### Task 4.2: Breaker and Retry telemetry, structured logs (TEL-6)

**Files:**
- Modify: `lib/normandy/resilience/circuit_breaker.ex` (`transition/3` reports through a new `report_transition/5`; delete `log_transition/4`)
- Modify: `lib/normandy/resilience/retry.ex` (`retry_or_fail/5`, new `error_type/1`)
- Modify: `lib/normandy/telemetry.ex` (two entries under `## Events`)
- Test: create `test/resilience/resilience_telemetry_test.exs`

**Interfaces:**
- Consumes (Task 4.1a/4.1b): `transition/3` is the only place state changes; `State.key`, `State.name`; `CircuitBreaker.key/3`, `run/2`.
- Produces: the events `[:normandy, :circuit_breaker, :state_change]` and `[:normandy, :retry, :attempt]` with exactly the measurements and metadata in the Design section.

- [ ] **Step 1: Write the failing tests**

Create `test/resilience/resilience_telemetry_test.exs`:

```elixir
defmodule Normandy.Resilience.TelemetryTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.OpenAICompatibleAdapter
  alias Normandy.LLMError
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Resilience.Retry
  alias Normandy.Test.TelemetryCapture

  @state_change [:normandy, :circuit_breaker, :state_change]
  @attempt [:normandy, :retry, :attempt]

  defp unique_name, do: :"tel_breaker_#{System.unique_integer([:positive])}"

  # Retry emits in the caller's process; only this test's events are forwarded.
  defp attach_retry do
    test_pid = self()
    TelemetryCapture.attach([@attempt], fn _metadata -> self() == test_pid end)
  end

  describe "[:normandy, :circuit_breaker, :state_change]" do
    test "closed -> open -> half_open -> closed, in order" do
      name = unique_name()
      ref = TelemetryCapture.attach([@state_change], name: name)

      {:ok, cb} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 1,
          success_threshold: 1,
          timeout: 1
        )

      assert CircuitBreaker.call(cb, fn -> {:error, :down} end) == {:error, :down}
      Process.sleep(2)
      assert CircuitBreaker.call(cb, fn -> {:ok, :up} end) == {:ok, :up}

      assert_receive {:telemetry, ^ref, %{count: 1, failure_count: 1},
                      %{from: :closed, to: :open, reason: :failure_threshold, key: nil, name: ^name}}

      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{from: :open, to: :half_open, reason: :timeout}}

      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{from: :half_open, to: :closed, reason: :probe_success}}

      GenServer.stop(cb)
    end

    test "trip/1, reset/1 and a killed probe report their reasons" do
      name = unique_name()
      ref = TelemetryCapture.attach([@state_change], name: name)
      {:ok, cb} = CircuitBreaker.start_link(name: name, timeout: 1)

      :ok = CircuitBreaker.trip(cb)
      assert_receive {:telemetry, ^ref, _, %{from: :closed, to: :open, reason: :trip}}

      Process.sleep(2)
      test_pid = self()

      {probe, probe_ref} =
        spawn_monitor(fn ->
          CircuitBreaker.call(cb, fn ->
            send(test_pid, :admitted)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :admitted
      Process.exit(probe, :kill)
      assert_receive {:DOWN, ^probe_ref, :process, ^probe, :killed}

      assert_receive {:telemetry, ^ref, _, %{from: :half_open, to: :open, reason: :probe_down}}

      :ok = CircuitBreaker.reset(cb)
      assert_receive {:telemetry, ^ref, _, %{from: :open, to: :closed, reason: :reset}}

      GenServer.stop(cb)
    end

    test "a shared breaker's events carry its key, never a credential" do
      client = %OpenAICompatibleAdapter{
        api_key: "sk-secret",
        base_url: "https://user:pw@api.example.com/v1?key=sk-query"
      }

      key =
        CircuitBreaker.key(client, "m",
          failure_threshold: 1,
          scope: {__MODULE__, System.unique_integer([:positive])}
        )

      ref = TelemetryCapture.attach([@state_change], key: key)

      assert CircuitBreaker.run(key, fn -> {:error, :down} end) == {:error, :down}

      assert_receive {:telemetry, ^ref, _, %{key: ^key, to: :open} = metadata}
      refute inspect(metadata) =~ "sk-"
      refute inspect(metadata) =~ "pw"
    end

    test "the state-change log names the breaker and the change" do
      name = unique_name()
      {:ok, cb} = CircuitBreaker.start_link(name: name, failure_threshold: 1)

      log =
        ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
          CircuitBreaker.call(cb, fn -> {:error, :down} end)
        end)

      assert log =~ "Circuit breaker #{inspect(name)} closed -> open (failure_threshold)"

      GenServer.stop(cb)
    end
  end

  describe "[:normandy, :retry, :attempt]" do
    test "one event per retried attempt, with the LLMError's type" do
      ref = attach_retry()
      error = LLMError.new(type: :overloaded, retryable?: true, status: 529)

      assert {:error, {^error, 3, _errors}} =
               Retry.with_retry(fn -> {:error, error} end,
                 max_attempts: 3,
                 base_delay: 0,
                 max_delay: 0,
                 jitter: false,
                 retry_if: fn _ -> true end
               )

      assert_receive {:telemetry, ^ref, %{attempt: 1, max_attempts: 3, delay_ms: 0},
                      %{error_type: :overloaded}}

      assert_receive {:telemetry, ^ref, %{attempt: 2, max_attempts: 3, delay_ms: 0},
                      %{error_type: :overloaded}}

      refute_received {:telemetry, ^ref, %{attempt: 3}, _}
    end

    test "a raise is typed by its module, and the log holds no message or stacktrace" do
      ref = attach_retry()

      log =
        ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
          Retry.with_retry(fn -> raise ArgumentError, "SECRET-in-message" end,
            max_attempts: 2,
            base_delay: 0,
            max_delay: 0,
            jitter: false,
            retry_if: fn _ -> true end
          )
        end)

      assert_receive {:telemetry, ^ref, %{attempt: 1}, %{error_type: ArgumentError}}
      assert log =~ "Retry attempt 1/2 failed: ArgumentError"
      refute log =~ "SECRET-in-message"
      refute log =~ ~r/\.exs?:\d+/
    end

    test "exits, throws and atoms have their own types" do
      ref = attach_retry()
      opts = [max_attempts: 2, base_delay: 0, max_delay: 0, jitter: false, retry_if: fn _ -> true end]

      Retry.with_retry(fn -> exit(:boom) end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :exit}}

      Retry.with_retry(fn -> throw(:ball) end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :throw}}

      Retry.with_retry(fn -> {:error, :timeout} end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :timeout}}

      Retry.with_retry(fn -> {:error, %{detail: "SECRET"}} end, opts)
      assert_receive {:telemetry, ^ref, _, %{error_type: :error}}
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/resilience/resilience_telemetry_test.exs`
Expected: FAIL. No event arrives (`assert_receive` times out), and the breaker log line does not name the breaker yet.

- [ ] **Step 3: Breaker telemetry**

In `lib/normandy/resilience/circuit_breaker.ex`, in `transition/3`, capture the failure count of the state being left, and report instead of logging. Replace `transition/3` and `log_transition/4` with:

```elixir
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
```

The log line now reads `Circuit breaker <key or name> closed -> open (failure_threshold)`.

- [ ] **Step 4: Retry telemetry**

In `lib/normandy/resilience/retry.ex`, replace the retrying branch of `retry_or_fail/5`:

```elixir
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
```

Add after the `describe/1` clauses:

```elixir
  # A failure's type for telemetry and log metadata: never its message or payload.
  defp error_type(%LLMError{type: type}), do: type

  defp error_type({:exception, exception, _stacktrace}) when is_exception(exception),
    do: exception.__struct__

  defp error_type({kind, _payload}) when kind in [:exit, :throw, :unexpected_return], do: kind
  defp error_type(%module{} = exception) when is_exception(exception), do: module
  defp error_type(atom) when is_atom(atom), do: atom
  defp error_type(_error), do: :error
```

- [ ] **Step 5: Catalogue**

In `lib/normandy/telemetry.ex`, under `## Events`, after the `[:normandy, :json_deserializer, :recovery]` entry, add:

```
  ### `[:normandy, :circuit_breaker, :state_change]`

  A circuit breaker changed state. Measurements: `count: 1`, `failure_count` (failures
  counted in the state it left). Metadata: `key` (a shared breaker's
  `Normandy.Resilience.CircuitBreaker.key/3`: client module, endpoint without credentials
  or query, model and breaker options; `nil` for a breaker started with `start_link/1`),
  `name` (`start_link/1`'s `:name`, else `nil`), `from` and `to` (`:closed | :open |
  :half_open`), `reason` (`:failure_threshold | :timeout | :probe_success | :probe_failure
  | :probe_down | :reset | :trip`). Emitted in the breaker's process, so outside the
  caller's trace context; the open-to-half-open change is emitted by the first admission
  (or `state/1`, `metrics/1`) after the open window.

  ### `[:normandy, :retry, :attempt]`

  A failed attempt that `Normandy.Resilience.Retry` will retry, emitted in the caller's
  process before the backoff sleep. Measurements: `attempt` (the attempt that failed,
  from 1), `max_attempts`, `delay_ms`. Metadata: `error_type` (an `LLMError`'s `type`, an
  exception's module, `:exit`, `:throw`, `:unexpected_return`, an atom error itself, else
  `:error`). The last attempt, and an error that is not retried, emit nothing. LLM calls
  also emit one `[:normandy, :llm, :request]` span per attempt.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/resilience/ test/telemetry/catalogue_test.exs test/agents/base_agent_resilience_test.exs`
Expected: PASS.

- [ ] **Step 7: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w4-4.2.log; grep -E " [0-9]+ failures|Total errors" /tmp/w4-4.2.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

Add to `MIGRATING-2.0.md` `## New, non-breaking` one bullet: "- `[:normandy, :circuit_breaker, :state_change]` and `[:normandy, :retry, :attempt]` telemetry events (see the `Normandy.Telemetry` catalogue); breaker and Retry log lines carry structured metadata and name the breaker."

```bash
git add lib/normandy/resilience/circuit_breaker.ex lib/normandy/resilience/retry.ex \
  lib/normandy/telemetry.ex MIGRATING-2.0.md test/resilience/resilience_telemetry_test.exs
git commit -m "feat(telemetry): circuit breaker state changes and retry attempts"
```

### Task 4.3: Wave gate and records (controller)

**Files:**
- Modify: `investigations/pre-2.0-audit/decisions.md` (Wave 4 progress bullet)

- [ ] **Step 1: Full gate on the last Wave 4 commit**

Run, each with `tee` to a log and checked for ` 0 failures` and exit 0 (use `caffeinate -i -s` on macOS so system sleep does not stall the BEAM clock):
- `mix precommit`
- `mix docs --warnings-as-errors`
- `mix test --only redis` (Redis on its default port)
- `mix test.postgres`
- `mix test --only distributed --include postgres`
- `mix hex.build --unpack` (`lib/normandy/application.ex` is in the package)

Expected: every run ` 0 failures`, exit 0.

- [ ] **Step 2: Acceptance greps**

- `grep -rn "circuit_breaker_pid" lib/` → no hits.
- `grep -rn "CircuitBreaker.start_link" lib/` → no hits (agents never start a linked breaker).
- `grep -rn ":telemetry" lib/normandy/resilience/` → the two `execute` calls.

- [ ] **Step 3: Record**

Append a Wave 4 bullet to `## Progress` in `decisions.md`: commit range, gate results (each suite's count line), rulings made during execution, and anything not run. Commit it alone:

```bash
git add investigations/pre-2.0-audit/decisions.md
git commit -m "docs(investigations): record Wave 4"
```

Collect the CLAUDE.md text proposed in Task 4.1c's report for Q; do not apply it.

---

## Appendix: open questions for Q

Each has a recommendation; the plan is written as if every recommendation is accepted.

1. **Breaker identity includes the options.** Agents share a breaker only when client module, endpoint, model *and* breaker options all match. *Recommended.* Alternative: identity `{client_module, endpoint, model}` and the first agent's options win (silent) or a later agent with other options raises at its first call.
2. **Start on first call, not in `init/1`.** `init/1` stays side-effect free; the first LLM call starts the breaker. *Recommended.* Alternative: `init/1` calls `ensure_started/1` (a breaker exists before any call, but `init/1` then touches global state).
3. **No key stored in the config.** `circuit_breaker_pid` goes; the key is derived at each call from client, model and options (`BaseAgentConfig.circuit_breaker_key/1`), so a changed model follows. *Recommended.* Alternative: store the key at `init/1` (decision 8a's wording "config holds a key"); it goes stale when the model changes.
4. **`:scope` option.** Separates breakers for tenants with their own API keys, and for tests. *Recommended.* Alternative: no `:scope`; tenants on one endpoint and model always share.
5. **A killed probe counts as a failure** (reopens the breaker for another window), as PERF-1's fix proposes. *Recommended.* Alternative: free the slot only and stay half-open.
6. **No half-open lease timer.** A live but slow probe holds its slot until it returns. *Recommended* (LLM calls carry HTTP timeouts; the retry budget bounds the rest). Alternative: release the slot after `:timeout` ms.
7. **Breakers are `restart: :temporary`.** A crashed breaker is not restarted; the next call starts a fresh, closed one. *Recommended* (no restart-intensity cascade into the application). Alternative: `:transient` with the supervisor's default intensity.
8. **Keep `start_link/1` and `call/2`** for users who supervise their own breaker. *Recommended.* Alternative: remove them and offer only the keyed API.
9. **plan.md's "a 1.x template holding a pid rebuilds with a key"** is replaced (R3): no released template holds a breaker. *Recommended.*
10. **The orchestrators' per-call `Task.Supervisor` (Wave 3) stays per call**; moving it into the new application tree is not in this wave. *Recommended.* Alternative: move it now (a fourth child of `Normandy.Supervisor`).

---

## Follow-up (decision 20, 2026-10-06)

### Task 4.4: A shared breaker counts only endpoint-health failures (final-review I1)

The final review found that a shared breaker counted every failed call, including failures caused by the caller: a 400 `:invalid_request`, an `:authentication` error, `:invalid_output`, a raise from a stream callback or guardrail. With breakers shared per client module, endpoint, model and options, one conversation's bad requests opened the circuit for every agent on that model. Q chose option (a): count only failures that say the endpoint is unhealthy.

**Files:**
- Modify: `lib/normandy/resilience/circuit_breaker.ex` (`call/3`, `run/3` with a `:failure_if` option; an `:ignore` outcome)
- Modify: `lib/normandy/agents/base_agent.ex` (`with_resilience/3` passes `failure_if: &endpoint_failure?/1`; the classifier)
- Modify: `lib/normandy/agents/base_agent/init_options.ex` (the `:circuit_breaker` doc: one sentence on what counts)
- Modify: `MIGRATING-2.0.md` (§31 bullet; `## New, non-breaking` bullet for `call/3`/`run/3`)
- Test: `test/resilience/circuit_breaker_test.exs`, `test/agents/base_agent_shared_breaker_test.exs`; `test/options_coverage_test.exs` only if it fails for the new option-taking arities

**Interfaces:**
- Produces: `CircuitBreaker.call(server, fun, opts \\ [])`, `CircuitBreaker.run(key, fun, opts \\ [])`; option `failure_if: (({:error, term()}) -> boolean())`; default (no `:failure_if`) counts every failure, as before. Options validated through `Normandy.Options.validate!/3` with `{CircuitBreaker, :call, 3}` / `{CircuitBreaker, :run, 3}`.
- The record outcome `:ignore` (classifier said `false`): releases the probe's slot (demonitor), changes no count and no state.

**Which failures count (BaseAgent's classifier):**
- `%LLMError{}` whose `type` is `:rate_limit`, `:overloaded`, `:server`, `:transport` or `:stream`, or whose `retryable?` is `true`;
- the same `%LLMError{}` when it is the last error of an exhausted Retry (`{last_error, attempts, errors}`) or raised inside the call (`{:exception, %LLMError{}}`, `{:exception, %LLMError{}, stacktrace}`).
- Nothing else counts: `:invalid_request`, `:authentication`, `:permission`, `:not_found`, `:invalid_output`, `:unsupported`, `:unknown` (non-retryable), and any raise, exit, throw or unexpected return that is not an `LLMError` (the caller's own code: a stream callback, a guardrail, a hook).

- [ ] **Step 1: Failing tests**

Append to `test/resilience/circuit_breaker_test.exs` (before the final `end`):

```elixir
  describe "failure_if" do
    test "a failure the classifier rejects is not counted" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)
      not_counted = fn {:error, reason} -> reason != :caller_error end

      assert CircuitBreaker.call(cb, fn -> {:error, :caller_error} end, failure_if: not_counted) ==
               {:error, :caller_error}

      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.metrics(cb).failure_count == 0

      assert CircuitBreaker.call(cb, fn -> {:error, :down} end, failure_if: not_counted) ==
               {:error, :down}

      assert CircuitBreaker.state(cb) == :open

      GenServer.stop(cb)
    end

    test "the classifier sees raises as {:error, {:exception, e}}" do
      {:ok, cb} = CircuitBreaker.start_link(failure_threshold: 1)
      test_pid = self()

      classifier = fn result ->
        send(test_pid, {:classified, result})
        false
      end

      assert {:error, {:exception, %RuntimeError{}}} =
               CircuitBreaker.call(cb, fn -> raise "boom" end, failure_if: classifier)

      assert_received {:classified, {:error, {:exception, %RuntimeError{message: "boom"}}}}
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end

    test "an ignored half-open probe frees its slot and leaves the breaker half-open" do
      {:ok, cb} = CircuitBreaker.start_link(timeout: 1, half_open_max_calls: 1)
      :ok = CircuitBreaker.trip(cb)
      Process.sleep(2)
      assert CircuitBreaker.state(cb) == :half_open

      assert CircuitBreaker.call(cb, fn -> {:error, :caller_error} end,
               failure_if: fn _ -> false end
             ) == {:error, :caller_error}

      metrics = CircuitBreaker.metrics(cb)
      assert metrics.state == :half_open
      assert metrics.half_open_calls == 0
      assert {:monitors, []} = Process.info(cb, :monitors)

      GenServer.stop(cb)
    end

    test "success is never classified" do
      {:ok, cb} = CircuitBreaker.start_link()

      assert CircuitBreaker.call(cb, fn -> {:ok, 1} end, failure_if: fn _ -> flunk("called") end) ==
               {:ok, 1}

      GenServer.stop(cb)
    end

    test "an unknown option raises in the house style" do
      {:ok, cb} = CircuitBreaker.start_link()

      assert_raise ArgumentError,
                   ~r/^Normandy.Resilience.CircuitBreaker.call\/3: unknown option :failure_iff/,
                   fn -> CircuitBreaker.call(cb, fn -> {:ok, 1} end, failure_iff: & &1) end

      GenServer.stop(cb)
    end
  end
```

Append to `test/agents/base_agent_shared_breaker_test.exs` (before the final `end`):

```elixir
  describe "which failures count (decision 20)" do
    defp error_reply(type, retryable? \\ false) do
      fn _response_model -> {:error, LLMError.new(type: type, retryable?: retryable?, status: 400)} end
    end

    for type <- [:invalid_request, :authentication, :permission, :not_found, :invalid_output] do
      test "#{type} does not open a shared breaker" do
        s = scope()
        a = %{agent(s) | client: %StubClient{reply: error_reply(unquote(type))}}
        b = agent(s)

        assert {:error, %LLMError{type: unquote(type)}} = BaseAgent.run(a, "1")
        assert {:error, %LLMError{type: unquote(type)}} = BaseAgent.run(a, "2")
        assert {:error, %LLMError{type: unquote(type)}} = BaseAgent.run(a, "3")

        assert {:ok, _agent, _out} = BaseAgent.run(b, "4")
      end
    end

    test "a retryable error of any type counts" do
      s = scope()
      a = %{agent(s) | client: %StubClient{reply: error_reply(:unknown, true)}}

      assert {:error, _} = BaseAgent.run(a, "1")
      assert {:error, _} = BaseAgent.run(a, "2")
      assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(agent(s), "3")
    end

    test "a failure that exhausted Retry counts by its last error" do
      s = scope()

      a =
        BaseAgent.init(
          client: %StubClient{reply: &overloaded/1},
          model: "m",
          retry: [max_attempts: 2, base_delay: 0, max_delay: 0, jitter: false],
          circuit_breaker: [failure_threshold: 2, timeout: 60_000, scope: s]
        )

      assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "1")
      assert {:error, %LLMError{type: :overloaded}} = BaseAgent.run(a, "2")
      assert {:error, %LLMError{type: :circuit_open}} = BaseAgent.run(agent(s), "3")
    end

    test "a raise from the caller's own code does not count" do
      s = scope()
      a = %{agent(s) | client: %StubClient{reply: fn _ -> raise ArgumentError, "caller bug" end}}

      assert_raise ArgumentError, fn -> BaseAgent.run(a, "1") end
      assert_raise ArgumentError, fn -> BaseAgent.run(a, "2") end

      assert {:ok, _agent, _out} = BaseAgent.run(agent(s), "3")
    end
  end
```

(`agent/2`, `scope/0` and `overloaded/1` already exist in that file. If `BaseAgent.run/2` returns `{:error, _}` instead of raising for a raising client, adjust the last test's two assertions to `assert {:error, _} = ...`, keep the final `{:ok, ...}` assertion, and note it in the report.)

Run: `mix format && mix test test/resilience/circuit_breaker_test.exs test/agents/base_agent_shared_breaker_test.exs`
Expected: FAIL — `call/3` undefined (`UndefinedFunctionError`), and the agent tests see `:circuit_open` on the healthy agent.

- [ ] **Step 2: CircuitBreaker**

After `@key_opts_schema`/`@type key`, add:

```elixir
  @call_opts_schema NimbleOptions.new!(
                      failure_if: [
                        type: {:fun, 1},
                        doc:
                          "Decides whether a failed call counts against the breaker. It gets " <>
                            "the `{:error, reason}` the call returns (a raise, exit or throw " <>
                            "is `{:error, {:exception | :exit | :throw, _}}`); `false` leaves " <>
                            "the counts unchanged and frees a half-open probe's slot. By " <>
                            "default every failure counts."
                      ]
                    )
```

`call/2` becomes `call/3` (keep its existing `@doc`, add an `## Options` section with `#{Options.docs(@call_opts_schema)}`):

```elixir
  @spec call(GenServer.server(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def call(server, fun, opts \\ []) when is_function(fun, 0) do
    opts = Options.validate!(opts, @call_opts_schema, {__MODULE__, :call, 3})

    case GenServer.call(server, :acquire) do
      {:ok, token} -> execute_and_record(server, token, fun, opts[:failure_if])
      {:error, :open} -> {:error, :open}
    end
  end
```

`run/2` becomes `run/3` the same way (`{__MODULE__, :run, 3}`, doc: "Takes `call/3`'s options."):

```elixir
  @spec run(key(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    opts = Options.validate!(opts, @call_opts_schema, {__MODULE__, :run, 3})

    case admit(key) do
      {pid, {:ok, token}} -> execute_and_record(pid, token, fun, opts[:failure_if])
      {_pid, {:error, :open}} -> {:error, :open}
    end
  end
```

`execute_and_record/3` becomes:

```elixir
  defp execute_and_record(server, token, fun, failure_if) do
    {outcome, result} = run_fun(fun)
    :ok = record(server, token, classify(outcome, result, failure_if))
    result
  end

  # A failure the caller's classifier rejects is recorded as :ignore: its probe slot is
  # freed and no count changes.
  defp classify(:failure, result, failure_if) when is_function(failure_if, 1),
    do: if(failure_if.(result), do: :failure, else: :ignore)

  defp classify(outcome, _result, _failure_if), do: outcome
```

In `handle_call({:record, ...})`, add the `:ignore` branch after the generation check:

```elixir
      cond do
        generation != state.generation -> state
        outcome == :ignore -> state
        outcome == :success -> handle_success(state)
        outcome == :failure -> handle_failure(state, :probe_failure)
      end
```

Fix the `@spec`/typespec of `record/3` if it lists outcomes. Moduledoc "## Shared breakers": add "`BaseAgent` counts only failures that say the endpoint is unhealthy (see `BaseAgent.init/1`'s `:circuit_breaker`); `call/3` and `run/3` take the same choice as `:failure_if`."

- [ ] **Step 3: BaseAgent**

In `with_resilience/3`: `key -> CircuitBreaker.run(key, retryable_call, failure_if: &endpoint_failure?/1)`.

Add near `default_retry_if/1`:

```elixir
  # Which failed LLM calls count against the shared circuit breaker: only those that say
  # the endpoint is unhealthy. A request the provider rejected, output that did not parse,
  # or a raise, exit or throw from the caller's own code (a stream callback, a guardrail)
  # must not open a breaker every agent on that model shares (decision 20).
  @endpoint_failure_types [:rate_limit, :overloaded, :server, :transport, :stream]

  defp endpoint_failure?({:error, reason}), do: endpoint_reason?(reason)

  # Retry gave up: {last_error, attempts, errors}.
  defp endpoint_reason?({last_error, attempts, errors})
       when is_integer(attempts) and is_list(errors),
       do: endpoint_reason?(last_error)

  defp endpoint_reason?(%LLMError{type: type, retryable?: retryable?}),
    do: retryable? or type in @endpoint_failure_types

  defp endpoint_reason?({:exception, %LLMError{} = error}), do: endpoint_reason?(error)
  defp endpoint_reason?({:exception, %LLMError{} = error, _stacktrace}), do: endpoint_reason?(error)
  defp endpoint_reason?(_caller_side), do: false
```

`init_options.ex` `:circuit_breaker` doc: append the sentence "Only failures that say the endpoint is unhealthy count: `LLMError` types `:rate_limit`, `:overloaded`, `:server`, `:transport`, `:stream`, or any retryable error; a rejected request, unparseable output or a raise from your own code does not."

- [ ] **Step 4: MIGRATING**

§31, after the bullet about shared state, add:

```
- An agent's breaker counts only failures that say the endpoint is unhealthy: `LLMError`
  types `:rate_limit`, `:overloaded`, `:server`, `:transport` and `:stream`, or any error
  marked `retryable?: true`. A rejected request (`:invalid_request`, `:authentication`,
  `:permission`, `:not_found`), output that did not parse (`:invalid_output`) or a raise
  from your own code (a stream callback, a guardrail) no longer counts, so one caller's bad
  requests cannot open the circuit for every agent that shares it. 1.x counted every failure.
```

`## New, non-breaking`: "- `CircuitBreaker.call/3` and `run/3` take `failure_if:`, a function that decides whether a failed call counts against the breaker."

- [ ] **Step 5: Tests pass, gate, commit**

Run: `mix format && mix test test/resilience/ test/agents/ test/options_coverage_test.exs` → PASS. If `options_coverage_test` fails naming `call/3` or `run/3`, add them to its table the way `key/3` is listed.
Gate: `mix precommit 2>&1 | tee <log>` (" 0 failures", exit 0, credo clean, dialyzer 0 unnecessary) and `mix docs --warnings-as-errors` exit 0.

```bash
git add lib/normandy/resilience/circuit_breaker.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/agents/base_agent/init_options.ex MIGRATING-2.0.md \
  test/resilience/circuit_breaker_test.exs test/agents/base_agent_shared_breaker_test.exs
git commit -m "fix(agents): a shared breaker counts only endpoint-health failures"
```

---

## Follow-up (decision 21, 2026-10-06): Q's "fix before Wave 5" list

### Task 4.5: Idle shared breakers stop themselves (final-review M2)

Keyed breakers (`CircuitBreaker.start_keyed/1`) never stop, so following §31's `scope: tenant_id` advice grows one idle process per tenant × model × options.

**Files:** `lib/normandy/resilience/circuit_breaker.ex`; test `test/resilience/circuit_breaker_keyed_test.exs`; `MIGRATING-2.0.md` §31 (one bullet).

**Behaviour:**
- A keyed breaker (one with a `key`) stops (`{:stop, :normal, state}`) after `@idle_stop_ms 900_000` (15 minutes) with no message, but only while `:closed` with no probes. An `:open` or `:half_open` breaker never idle-stops (its state matters). A breaker started with `start_link/1` never idle-stops (its owner supervises it).
- Mechanism: the GenServer timeout. `State` gains `:idle_timeout` (`@idle_stop_ms` for keyed breakers, `:infinity` otherwise, set in `init/1` from whether `:key` is non-nil). Every `handle_call`/`handle_info` return appends `state.idle_timeout` (one private helper, e.g. `reply(result, state)` / `noreply(state)`, so no clause forgets it); `init/1` returns `{:ok, state, state.idle_timeout}`. `handle_info(:timeout, state)` stops when `state.key != nil and state.state == :closed and state.probes == %{}`, else continues with the timeout.
- A caller racing a stop is already covered: `admit/2` retries once on `:noproc`/`:normal`/`:shutdown`, and `record/3` never exits the caller.
- `ensure_started/1` starts a fresh, closed breaker next time; the failure count of a closed breaker is lost after 15 idle minutes (stale counts carry no signal).

**Tests** (in `circuit_breaker_keyed_test.exs`, deterministic: deliver the GenServer timeout by sending `:timeout` to the pid; monitor and `assert_receive {:DOWN, ...}` / `refute_receive`):
- a closed keyed breaker receiving `:timeout` stops normally and `fetch(key) == :error` afterwards (use `wait_until` for the Registry cleanup); the next `run/3` starts a new, closed one;
- an open keyed breaker (`trip/1`) receiving `:timeout` stays alive and open;
- a half-open keyed breaker with a probe in flight receiving `:timeout` stays alive;
- a `start_link/1` breaker receiving `:timeout` stays alive;
- `:sys.get_state(pid)` shows `idle_timeout: 900_000` for keyed and `:infinity` for `start_link/1` breakers.

**MIGRATING §31 bullet:** "- A shared breaker that has been closed and idle for 15 minutes stops; the next call starts a fresh one. Open and half-open breakers stay."

Commit: `fix(circuit_breaker): an idle closed shared breaker stops itself`.

### Task 4.6: Strings inside an option's container are redacted (Wave 3 residual)

`Normandy.Options.redact_container/2` replaces every map, list and tuple inside a failing value with its type, but NimbleOptions' nested errors also echo a *string* found inside the container: `guardrails: [input: [{Foo, "sk-LEAK"}]]` gives `... expected keyword list, got: "sk-LEAK"`, and `guardrails: [input: ["sk-LEAK2"]]` gives `... expected tuple, got: "sk-LEAK2"`.

**Files:** `lib/normandy/options.ex` (`redact_container/2` and `containers/2`); test: the existing options/redaction tests (find them with `grep -rn "redact_container\|is not shown\|sk-" test/options* test/options/`), plus a BaseAgent `init/1` case.

**Behaviour:** every binary found *inside* a container value (at any depth, including map keys, tuple elements, improper-list tails, struct fields) is replaced in the message by `Describe.type_of/1` (`"a string (N bytes)"`), like containers. A top-level scalar value (a string that is itself the failing value, not inside a container) keeps NimbleOptions' message, as today. Replace longest inspected forms first (an inner string's `inspect` is part of its container's). Do not replace an empty string `""` (its inspect `"\"\""` would hit unrelated text); describe it only via its container.

**Tests (exact):**
- `BaseAgent.init(client: %StubClient{}, model: "m", guardrails: [input: [{Foo, "sk-LEAK"}]])` raises `ArgumentError` whose message does not contain `"sk-LEAK"` and contains `"a string (7 bytes)"`;
- the same for `guardrails: [input: ["sk-LEAK2"]]` and `guardrails: [output: [{Normandy.Guardrails.Builtins.MaxLength, "sk-LEAK3"}]]`;
- a unit test on `Normandy.Options.redact_container/2` with a message containing `inspect(%{a: ["sk-x", {1, "sk-y"}]})` fragments: no `sk-` left;
- a top-level string value for a non-sensitive key is still shown (pick an existing option with a string-or-nil type, e.g. `init(name: 123)` shows `123`; a string example only if one exists).

Commit: `fix(options): strings inside an option's container value are never echoed`.

### Task 4.7: ResumeReaper tolerates Horde's via-registration race (Wave 6 item, pulled forward)

`ResumeReaper.start_session/2` (`lib/normandy/agents/turn/resume_reaper.ex`) calls `supervisor_mod.start_server/2` once and logs `{:error, {:process_not_registered_via, _}}` as a failed resume; under Horde this registration race happens while the registry converges (seen once in the distributed suite: `ResumeReaperIntegrationTest`). `Turn.Session.start_with_retry/7` (`lib/normandy/agents/turn/session.ex` ~380-436) already handles both race shapes.

**Files:** create `lib/normandy/agents/turn/start.ex` (`@moduledoc false`, one public function); modify `session.ex` (use it, delete its private copies: `start_with_retry/7`, `already_started_pid/1`, `via_race?/1`) and `resume_reaper.ex` (use it); tests in `test/agents/turn/resume_reaper_test.exs` (or the existing reaper unit test file — find it) and keep Session's existing race tests passing.

**Interface:** `Normandy.Agents.Turn.Start.start_server(sup_mod, sup, server_opts, {reg_mod, reg_handle}, session_id, retries \\ 20) :: {:ok, pid} | {:error, term()} | other` — exactly Session's current logic moved: `{:ok, pid}`; `already_started` (bare or `{{:already_started, pid}, child}`) → `{:ok, pid}`; via race (bare or nested) with retries left → `whereis` the winner (`{:ok, pid}`), or `:none` → `Process.sleep(10)` and retry, or a lookup error → `{:error, lookup_error}`; anything else returned unchanged. Keep the explanatory comment block.

**Reaper:** `start_session/2` calls `Start.start_server(state.supervisor_mod, state.supervisor, opts, state.registry, sid)`; `{:ok, _}` → `:ok`; `{:error, reason}` → the existing warning; any other result → the existing "unexpected" warning.

**Tests (deterministic, no Horde):** a fake supervisor module (a test module whose `start_server/2` pops scripted replies from an `Agent`) and a fake registry module:
- reaper: two `{:error, {:process_not_registered_via, Horde.Registry}}` then `{:ok, pid}` → the session is started (the fake saw 3 calls) and no "failed to resume" warning is logged (`capture_log`);
- reaper: via race, then `whereis` returns `{:ok, winner}` → no further start call, no warning;
- reaper: nested `{{:process_not_registered_via, _}, child}` shape is retried too;
- reaper: a genuine `{:error, :boom}` is logged once as "failed to resume" (not retried).
Drive the reaper through its public `reap/1` with a hand-built state map (the moduledoc says callers may build it) and a fake store whose `list_resumable/1` returns `{:ok, [sid]}` and `load_turn_state/2` returns a non-terminal `%Turn.State{}`.

Commit: `fix(turn): the resume reaper tolerates the via-registration race`.

### Then (controller)
Gate on the last commit (precommit, docs, redis, postgres, distributed ×2), record in `decisions.md`, then stop the `normandy-test-pg` container (`docker stop normandy-test-pg`; Q asked; `docker start` brings it back) and stop before Wave 5.
