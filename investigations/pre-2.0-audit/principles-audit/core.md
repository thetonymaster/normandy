## Principles audit: lib/normandy/test/*.ex, lib/normandy/resilience/*.ex, lib/normandy/{application,cluster,exceptions,json,options,orchestration_error,turn_error,watched_worker}.ex (whole modules, branch feat/claudio-0.7-migration @ 7561497)

Verdict: ship with follow-ups — the findings are one hand-written option validator that disagrees with `Normandy.Options`, two coupling and duplication issues, a tested timing seam, one public seam with only one working implementation (decide before 2.0) and three small doc claims that the code contradicts. None blocks release, but 4 is a one-way door for 2.0.

Mechanical pass (bash -c, 14 files): `mix credo --strict <files>` → "308 mods/funs, found no issues" (exit 0). `nesting_depth.py --max 3` → 1 lead (memory_store_contract.ex:341). Greps: 3 `defmacro __using__` (the contracts), 0 `defoverridable`, 0 `@callback`/`@behaviour`, `Application.get_env` in json.ex:101 and cluster.ex:29 (doc example), `:ets.new` in fake_client.ex:152. `mix test test/resilience --slowest 5` → "Result: 90 passed", exit 0.

### Findings (ranked)

1. [composition · under] lib/normandy/resilience/retry.ex:147 — `Retry` validates options with its own code beside `Normandy.Options`, and the two behave differently. CLAUDE.md says Options handles "every public entry point".
   Evidence: probe via `mix run --no-start`:
   `%{max_attempts: 2} -> FunctionClauseError: no function clause matching in Keyword.keys/1` (Options accepts maps);
   `[max_attempts: 2, max_attempts: 3] -> ArgumentError: Retry.with_retry/2: unknown option :max_attempts; supported: :max_attempts, ...` (wrong message: `--` leaves the duplicate behind; Options says "given more than once");
   `InitOptions.retry([max_attemps: 2])` -> `{:error, "Retry.with_retry/2: unknown option ..."}`: init/1's error names the wrong function. `grep -rln Options.validate! lib/` = 51 files, 98 call sites. Retry is the exception.
   Fix: a NimbleOptions schema for Retry (`{:custom, ...}` types for `:retry_on` and `:retry_if`) checked through `Options.validate!/3` in `with_retry/2` and `validate_options!/1`. Delete `retry_config!/check_option!/shown`.
   Public API: no signature change. Error message text changes, and maps become accepted (an addition).

2. [composition · under] lib/normandy/application.ex:13 — `:rest_for_one` puts the AgentProcess `ScopedRegistry` after the two breaker children. A crash of the breaker Registry or DynamicSupervisor therefore also restarts the ScopedRegistry and drops every `:server`-mode AgentProcess registration. The module comment says only "The AgentProcess registry is last: its crash stops nothing else".
   Evidence: `children = [{Registry, ... CircuitBreaker.Registry}, {DynamicSupervisor, ... CircuitBreaker.Supervisor}, {Registry, ... ScopedRegistry.registry_name()}]` with `strategy: :rest_for_one`. Under OTP rest_for_one semantics, a crash of child 1 or 2 restarts child 3. This is a hidden ordering coupling between two unrelated subsystems. I did not run it; what happens to a live AgentProcess that loses its name is unverified.
   Fix: put the breaker Registry and DynamicSupervisor under their own `rest_for_one` supervisor, and make the top level `one_for_one`. Public API: none.

3. [dependency-injection · under] lib/normandy/resilience/retry.ex:240 — `Process.sleep(delay)` is hardwired, so the backoff tests measure wall time. One of them passes without asserting anything.
   Evidence: test/resilience/retry_test.exs:189 `if length(times) == 3 do ... assert delay1 >= 80 and delay1 <= 300` (it asserts nothing if the count differs). :256 asserts `length(Enum.uniq(delays)) > 1` over 5 wall-clock samples. `--slowest 5`: "jitter adds randomness" 478.6 ms, "calculates exponential backoff" 303.0 ms, "can use preset" 121.6 ms, of 1.8 s total. The breaker tests do the same with `System.monotonic_time` (circuit_breaker.ex:659,675,701): circuit_breaker_test.exs:119 (150.7 ms, `timeout: 100` + `sleep(150)`) and :616 (110.6 ms). Other tests in the same file already use `timeout: 1` + `sleep(2)`.
   Fix (tests only): assert on the `[:normandy, :retry, :attempt]` telemetry `delay_ms`, which is already emitted with the computed delay, using `base_delay: 1`. Drop the `if length(times) == 3` guard. Use `timeout: 1` in the two slow breaker tests. Injecting a clock or sleep function is not needed. Public API: none.

4. [composition · over] lib/normandy/json.ex:7 (read at :100) — the `config :normandy, :adapter` seam has one working implementation. Jason is still a hard dependency, and any adapter has to understand Jason's own structs.
   Evidence: mix.exs:289 `{:jason, "~> 1.4"}` (not optional). json.ex:150 builds `Jason.OrderedObject` and :165 checks `Jason.Encoder.impl_for`, whatever the adapter. The stdlib `JSON` on Elixir 1.20.4, the obvious second implementation, does not fit the contract: `JSON.encode!(%{a: 1}, [])` -> `%BadFunctionError{term: []}`, and `JSON.encode!(Jason.OrderedObject.new(...))` -> `UndefinedFunctionError`. The only other implementations are test modules (test/app_env_config_test.exs:61-130, `async: false` because of `Application.put_env`).
   Fix: decide for 2.0. Either remove `:adapter` and call Jason directly, or keep it and name a real second adapter in the moduledoc and a test.
   Public API: yes. Removing it drops a documented config key, so it needs a MIGRATING-2.0.md entry. It is a one-way door, so Q decides.

5. [flat-code · over] lib/normandy/test/fake_client.ex:468 — `bad!/2` changes its message by looking for a phrase in the caller's `where` text (`String.contains?(where, "returned an item")`) and string-replacing part of `@shape`. The same shape text exists twice (`@return_shape` :126, `@shape` :388).
   Evidence: lines 469-477. The caller at :212 must phrase `where` exactly for the rewrite to fire. A rewording at :212 silently brings back "or a 1-arity function" in the error for a function's return value.
   Fix: give `check_item!/2` the expected-shape string (or a `functions_allowed?` boolean) as an argument and keep one shape constant. Public API: none (private functions; the error text stays the same).

6. [composition · under] lib/normandy/watched_worker.ex:19 — the comment says it: "Turn.Server's run_while_server_alive/3 has the same shape; it is meant to move here." The watcher, linked worker and `$callers` logic exist twice.
   Evidence: lib/normandy/agents/turn/server.ex:1826-1843 (`Process.monitor(server)`, `trap_exit`, `spawn_link` + `$callers`, the same three-arm `receive`) against watched_worker.ex:28-45.
   Fix: have Turn.Server use `WatchedWorker` (Turn.Server would key the result by watcher pid rather than `ref`), then delete the private copy. Public API: none (both are internal).

7. [false-claim] lib/normandy/cluster.ex:177 — "When `config :normandy, :redis_wait` asks for replicas (read here, once)". In fact one `redis_child_specs/1` call reads the app env twice and computes the store plan twice.
   Evidence: `build_redis_handles` → `store_handle` (:244, `store_plan` + `store_wait!`) and `store_conn_specs` (:253, `store_plan` + `store_wait!` again), both reached from :197 and :200. The handles and the WAIT-pool child specs come from separate reads.
   Fix: compute `{plan, wait}` once in `redis_child_specs/1` and pass it to both helpers. Public API: none.

8. [false-claim] lib/normandy/resilience/circuit_breaker.ex:13 — the moduledoc diagram says `Closed ──(failures > threshold)──> Open`, but the breaker opens at `>=`.
   Evidence: :663 `:closed when state.failure_count >= state.failure_threshold`. The option doc at :139 ("Failures that open the breaker") matches the code. The diagram does not.
   Fix: change the diagram to `>=`. Public API: none (doc only).

9. [false-claim] lib/normandy/resilience/retry.ex:367 — `preset(:standard)` is documented as the "Default configuration", but its `max_delay: 10_000` (:389) differs from `with_retry/2`'s default `@default_max_delay 32_000` (:59). The preset also does not set `jitter`/`retry_on`.
   Fix: set the preset's `max_delay` to the default, or drop the word "Default". Public API: changing the value changes behaviour for preset users. Changing the doc does not.

### Survived scrutiny
- Named Registry and DynamicSupervisor for shared breakers (application.ex, circuit_breaker.ex:174-175): the per-node singleton is the feature (one breaker per client/endpoint/model/options). `:scope` isolates tenants and tests (circuit_breaker_keyed_test.exs is `async: true` with a scope per test), and `start_link/1` + `call/3` remain for a breaker the caller owns.
- CircuitBreaker generation/token admission and the single `transition/3`: every state change goes through one function (:685). The moduledoc claim that a dead half-open probe reopens the breaker holds: `:DOWN` → `handle_failure(:probe_down)` → `transition(:open)`, and `transition` demonitors with `:flush`, so no stale `:DOWN` frees a slot in a later window.
- CircuitBreaker `run_fun` vs Retry `execute_safely`, two catch-alls: kept separate because they return different, documented shapes. The claim "composing the two cannot change the outcome" (circuit_breaker.ex:603) holds for the composition BaseAgent uses (base_agent.ex:366-379, Retry inside the breaker).
- The three contract `use` macros (lib/normandy/test/*_contract.ex): `use` is the only way to share ExUnit tests across modules. Each has real implementers. SessionRegistry: Native, Horde, Redis. SessionStore: InMemory, ETS, Mnesia, Postgres, Redis. MemoryStore: InMemory, ETS, Mnesia, Postgres, Redis (grep of `use Normandy.Test.*Contract` in test/). This matches the moduledoc claims "Native, Horde and Redis" and "five backends". Test counts are 16 and 33, as CLAUDE.md states.
- memory_store_contract.ex:341, depth 4: the depth comes from the test DSL (quote → describe → test → `for` → `Task.async` → `receive`), not from conditions the reader must hold.
- `Normandy.Options` as the shared validator: 51 files and 98 `validate!` call sites. Its redaction walk only covers option values, which are bounded.
- FakeClient's `:atomics` counter + public ETS table: needed for correctness (several processes take script items and record requests). It is not an unmeasured speed optimisation.
- `Normandy.Cluster.child_specs/1` hardwires the Horde modules: it is the Horde convenience. `redis_child_specs/1` is the second combination, so nothing else needs a seam.
- `TurnError.from_reason/1` and `redact/1`: one mapping, with a loud `ArgumentError` for an unknown reason (:245). No fallback.
- Measure first: none of the scoped modules adds an optimisation. Loops run over bounded inputs (options, exit reasons, script items). `JSON.sort_keys/1` walks each tool result once.

### Not checked
- `mix dialyzer` and `mix xref graph --label compile-connected`: not run.
- The contract suites against Postgres and Redis: not run (the brief excludes them). Only `test/resilience` ran (90 passed).
- Finding 2's runtime effect on a live `:server` AgentProcess: inferred from OTP `rest_for_one` semantics, not reproduced.
- Options moduledoc timeout table: spot-checked Reactive 60_000, ParallelOrchestrator 300_000, Batch.Processor 300_000, Executor 30_000 and AgentProcess `:infinity`, all of which match. AgentPool 5_000 and Turn.Server's `_ms` defaults were not verified.
- turn_error.ex:270 ("Every log line Normandy writes for a raise, exit or throw uses it"): checked by grep only. The `Exception.message` log calls found (e.g. agent_process.ex:984) are for rescued `ArgumentError`s whose messages are documented as value-free, not raise logs. An exhaustive check was not done.
- No benchmarks run: no performance claims found in scope.
- Base: whole modules, no diff range (as the brief asked).
