# Audit: test suite (area `tests`)

Scope: test/** (149 files, ~1594 `test` blocks by regex), test/support/**, test/test_helper.exs, CI
workflow. Read-only; `mix` not run. Compile warnings were NOT enumerated (no fresh compile output; the
`/tmp/*.log` files contain no `warning:` lines), so item 7 is partial (see TESTS-12).

## Inventory facts (verified by grep)

- `async: false`: 41 of 149 files. Clusters (a file can be in two):
  - Live-API integration (`test/integration/*`, `test/normandy_integration/*`): 11 files. Blocker: shared
    real API quota, and `basic_agent_test.exs:22` does `Application.put_env(:claudio, Claudio.Client, ...)`
    with no `on_exit` restore. Legitimately serial (and never run by default).
  - Distributed / Postgres / Redis / Mnesia / Horde-cluster: about 13 files (`session_store/{mnesia,
    concurrent_append_mnesia,mnesia_distributed,concurrent_append_redis,postgres_contract}`,
    `session_registry/{horde,redis_distributed}`, `turn/{horde_distributed,horde_redistribution,
    eager_handoff_distributed,lazy_recovery_distributed,server_postgres_e2e}`). Blocker: node-global Mnesia
    schema, `:peer` nodes, a shared Repo. Legitimate.
  - Global `:telemetry` handlers: `base_agent_{admit,run_span,served_by,guardrails,streaming_guardrails}_test`.
    Only `run_span` documents why (exact-count `refute_receive` on a global event). Fixable, see TESTS-6.
  - Logger capture: `base_agent_logging_test`, `agent_process_server_test`, `turn/server_test`. `capture_log`
    is per-process-safe only when no other test logs concurrently. Weak blocker.
  - Horde "cluster of one" (`session_test`, `supervisor_horde_test`, `tier2_integration`, `eager_resume`,
    `server_integration`, `resume_reaper_*`): these already use `:"name_#{System.unique_integer([:positive])}"`
    (e.g. `tier2_integration_test.exs:16`), so the blocker is not the name.
  - No blocker found at all: `llm/structured_outputs_test.exs`, `llm/json_deserializer_retry_test.exs`,
    `agents/turn/resume_reaper_test.exs` (uses fake supervisor + Native registry + InMemory store, see
    lines 10-36), `agents/turn/eager_resume_test.exs`. None call `Application.put_env`.
- `Application.put_env` in the whole test tree: only `normandy_integration/basic_agent_test.exs:22` and
  `support/cluster_case.ex:118-119` (the latter runs on a peer node). So no unit test mutates app env; the
  lib's env reads (`:adapter`, `:structured_outputs`, `:on_parse_failure`, `:redis_wait`) are never toggled
  per test, which also means the `false` / non-default branches are untested (see TESTS-13).
- Excluded by default (`test_helper.exs`): `:integration`, `:normandy_integration`, `:postgres`,
  `:distributed`, `:redis`. By moduletag regex: ~9 integration files (57 tests), 2 normandy_integration (5),
  4 postgres (11), 5 redis (6), 6 distributed (8), plus 4 `@moduletag skip:` gated on API key.
- `start_link(` in tests: 215 call sites; `start_supervised` used once.
- 26 `defimpl Normandy.Agents.Model` in 17 test files; 6 separate `defmodule FakeTool` copies.

---

### TESTS-1. CI never runs the Postgres, Redis, Mnesia-distributed or Horde-distributed suites
- Severity: HIGH
- Category: skipped/excluded tests
- Location: `.github/workflows/ci.yml` (jobs `test`, `unlocked-deps`: `run: mix test`), `test/test_helper.exs:15-26`
- Evidence:
  ```
  base_exclude = [:integration, :normandy_integration, :postgres, :distributed, :redis]
  ...
  - name: Run unit tests
    run: mix test
  ```
  ci.yml has no `services:` block (no Postgres/Redis), no `mix test.postgres`, `mix test.redis`, or
  `--include distributed` step. The only extra test step is `mix test --only integration --only normandy_integration`
  (main pushes with API key).
- Why it's a problem: the durable-store contracts (`postgres_contract_test`, `postgres_test`,
  `concurrent_append_{redis,mnesia}`), Redis registry/store, and every `*_distributed_test` (handoff, lazy
  recovery, Horde redistribution, Mnesia distributed) are the persistence and concurrency risk of this library
  and they have zero CI signal. A regression in `SessionStore.Postgres`/`Redis` or in cross-node handoff merges green.
  The `raise "Normandy.TestRepo not started; run with: mix test --include distributed --include postgres"` in
  `eager_handoff_distributed_test.exs:77` confirms they need manual orchestration.
- Fix: add a CI job with `services: postgres, redis` running `mix test.postgres` and `mix test.redis`, and a
  job (or step in it) running `mix test --include distributed --include postgres --include redis`.
- Confidence: verified (read ci.yml fully and test_helper)

### TESTS-2. Sequential/Parallel/Hierarchical orchestrators, SharedContext and AgentMessage have no default-run test
- Severity: HIGH
- Category: coverage gaps
- Location: `lib/normandy/coordination/{sequential_orchestrator,parallel_orchestrator,hierarchical_coordinator,shared_context,agent_message}.ex` (260 + 313 + 319 + 206 + 109 lines)
- Evidence: grep of `SequentialOrchestrator|ParallelOrchestrator` in test/ hits only
  `integration/multi_agent_workflows_test.exs`, `integration/end_to_end_scenarios_test.exs`,
  `normandy_integration/multi_agent_test.exs` (all `@moduletag :integration`, real Anthropic API).
  `HierarchicalCoordinator`, `SharedContext` (new/get/put/update/merge/delete/keys/to_map/has_key?),
  `AgentMessage`: zero references anywhere in test/.
- Why it's a problem: public API with concurrency (parallel fan-out, worker add/remove, `Task` handling) is
  verified only by live-LLM tests that run on pushes to main when a secret exists. `execute_with_messages`
  (`sequential_orchestrator.ex:189`) ignores its `_context` and is never exercised. Nothing here needs a real
  LLM: `test/support/model_mockup.ex` would do.
- Fix: unit tests with `ModelMockup`/fake `Model` impl for each orchestrator (ordering, error short-circuit,
  parallel timeout, worker add/remove); a pure test module for `SharedContext` and `AgentMessage`.
- Confidence: verified (grep + read of the integration files' tags)

### TESTS-3. Schema `compute:` test never runs the compute function; the feature is not implemented in lib
- Severity: MEDIUM
- Category: compile warnings that mean the test is not testing what it claims; weak assertions
- Location: `test/schema_virtual_fields_test.exs:76-150`, `lib/normandy/schema.ex:158-166` (moduledoc example), `schema.ex:864-865`
- Evidence:
  ```
  defp compute_total(%{price: price, tax_rate: rate}) do ... end
  field(:total_price, :float, virtual: true, compute: &__MODULE__.compute_total/1)
  ...
  assert [{:total_price, compute_fn}] = computed_fields
  assert is_function(compute_fn, 1)
  schema = %ComputedFields{price: 100.0, tax_rate: 0.2, total_price: 120.0}   # value set by hand
  ```
  `grep computed_fields lib` shows it is only registered (`schema.ex:266,422,479,865`); nothing evaluates it.
- Why it's a problem: (a) `&__MODULE__.compute_total/1` is a remote capture of a `defp`, so it emits the
  "undefined function compute_total/1" / "unused function" warnings and calling it would raise
  `UndefinedFunctionError`; (b) the tests only assert the capture is a 1-arity function and then hand-set
  `total_price: 120.0`, so the "computed" behaviour is never exercised; (c) the schema moduledoc teaches the same
  broken pattern; (d) users who write `compute:` get a field that is never computed.
- Fix: decide: either implement evaluation (e.g. in `Normandy.Validate.apply_changes` or a `Schema.compute/1`) and
  test `compute_fn.(struct) == 120.0` with a public function, or delete `:compute`/docs/tests and raise on the option.
- Confidence: verified (read test, schema.ex grep); the exact warning text is inferred from Elixir semantics (theory)

### TESTS-4. `ValidationMiddleware` and `SessionRegistry.Redis.Via` have no test; `ValidationMiddleware` appears unused
- Severity: MEDIUM
- Category: coverage gaps / dead code
- Location: `lib/normandy/agents/validation_middleware.ex` (233 lines), `lib/normandy/behaviours/session_registry/redis/via.ex` (47 lines)
- Evidence: `grep -rn ValidationMiddleware lib` outside its own file returns only doc mentions in
  `lib/normandy/guardrails/guard.ex:11,13`; no caller. `Redis.Via` (`register_name/2`, `whereis_name/1`,
  `unregister_name/1`, `send/2`) is referenced by name nowhere in test/; it is only reachable indirectly through
  the excluded `:redis` tests.
- Why it's a problem: a 233-line public module with 0 callers and 0 tests is either dead or an untested public
  API; `Via` is the `{:via, ...}` contract OTP calls with exact return conventions (`:yes | :no`, `:undefined`)
  that a unit test can pin without Redis by injecting a fake registry.
- Fix: delete `ValidationMiddleware` (and fix `guard.ex` docs) or test it; unit test `Via` against the `Native`
  registry or a fake.
- Confidence: verified for no tests/callers (grep); "dead" is theory if consumers call it from outside the repo

### TESTS-5. Sleep-for-synchronization in coordination tests (flaky under load)
- Severity: MEDIUM
- Category: timing-based tests
- Location: `test/coordination/agent_pool_test.exs:324,414,435,461,491,500,531,545`; `agent_supervisor_test.exs:107,203,231,251,269,336`; `agent_process_test.exs:109,160,205`; `stateful_context_test.exs:253,291`; `agents/turn/server_test.exs:355`; `agents/base_agent_resilience_test.exs:194`
- Evidence:
  ```
  AgentProcess.cast(pid, "Test 1"); AgentProcess.cast(pid, "Test 2")
  # Give tasks time to complete
  Process.sleep(50)
  assert stats.run_count == 2
  ---
  Process.exit(pid, :kill); Process.sleep(50)
  {:ok, new_pid} = AgentSupervisor.find_agent(sup, "restartable")
  ---
  Process.sleep(5)   # then start task2 so it queues second; later Process.sleep(10) before checkin
  ```
  The FIFO-waiter test (`agent_pool_test.exs:485-500`) uses 5ms/10ms sleeps to force arrival order of two
  `Task.async` checkouts.
- Why it's a problem: all of these wait for async work with a fixed delay. On a loaded CI runner the cast has not
  finished at 50ms (`run_count == 1`), the supervisor has not restarted (`find_agent` returns old/none), or task2
  arrives before task1 and the ordering assertion flips. `terminate_agent` then `sleep(10)` then `refute alive?`
  (`agent_supervisor_test.exs:107`) has the same shape. 55 sleep sites in 25 files; the OK ones are the
  time-behaviour tests (`circuit_breaker_test.exs` 50/100ms timeouts, `mock_summarizer_client` delay, `:infinity`
  parked processes), though the circuit-breaker `timeout: 50` + `Process.sleep(10)` race
  (`circuit_breaker_test.exs:198-219`) is tight.
- Fix: replace with monitors (`Process.monitor` + `assert_receive {:DOWN, ...}`), `Normandy.Test.Eventually.wait_until/2`,
  or have the fake client `send(parent, :done)` and `assert_receive`. For ordering, wait on a `:waiting` message
  from the pool (or poll `stats.waiting == 1`) instead of sleeping.
- Confidence: verified (read the contexts); flakiness is theory (not reproduced)

### TESTS-6. `async: false` is unjustified in several files; telemetry/log "blockers" are fixable
- Severity: MEDIUM
- Category: async: false
- Location: `llm/structured_outputs_test.exs:2`, `llm/json_deserializer_retry_test.exs:42`, `agents/turn/resume_reaper_test.exs:2`, `agents/turn/eager_resume_test.exs:3`; telemetry cluster `agents/base_agent_{admit,guardrails,streaming_guardrails,served_by,run_span}_test.exs`
- Evidence: the first four contain no `put_env`, named process, telemetry attach, or capture_log. For the
  telemetry cluster, `base_agent_admit_test.exs:118` already attaches with a per-test `handler_id`; the stated
  reason (`base_agent_run_span_test.exs:12`) is that other tests' events contaminate exact-count assertions.
- Why it's a problem: 41/149 files serial slows the suite and hides genuine isolation bugs. The telemetry blockers
  are removable: every event carries `agent name`/`model` metadata, so the handler can filter on a unique agent
  name (`name: "span-#{unique}"`) and ignore other agents' events; then `refute_receive` is exact for this run.
  `capture_log` blockers: set `Logger` metadata per test or assert on telemetry instead.
- Fix: flip the four no-blocker files to `async: true` and run the suite 3x; give the telemetry tests a unique
  agent name and filter in the handler; keep distributed/Mnesia/Postgres/live-API serial.
- Confidence: verified for "no blocker visible" in the four files; theory that flipping is safe (run suite to confirm)

### TESTS-7. Telemetry test in an `async: true` module uses a fixed global handler id and a vacuous match
- Severity: MEDIUM
- Category: weak assertions / async
- Location: `test/agents/base_agent_test.exs:164-180`
- Evidence:
  ```
  :telemetry.attach_many("test-handler", events, handler, nil)
  ...
  assert_receive {^ref, [:normandy, :agent, :run, :start], _ms, %{model: _}}
  assert_receive {^ref, [:normandy, :agent, :llm_call, :stop], %{duration: _},
                  %{model: _, iteration: 1, has_tool_calls: false, tool_call_count: 0}}
  ```
- Why it's a problem: `[:normandy, :agent, :run, :*]` events are global. While this test runs, every concurrent
  async test calling `BaseAgent.run` also fires the handler, and `^ref` only identifies the *handler*, not the run.
  The assertions (`%{model: _}`, `iteration: 1`, `has_tool_calls: false`) can be satisfied by another test's
  event, so the test could pass even if this agent emitted nothing. The fixed id `"test-handler"` also returns
  `{:error, :already_exists}` if any second test attaches it.
- Fix: unique handler id (`"test-#{inspect(ref)}"`), unique agent `name` in the config, match `%{agent_name: ^name}`
  (use whatever metadata key the event carries), or move to the serial telemetry cluster.
- Confidence: verified (read the code); cross-test contamination is theory (needs a concurrent run to observe)

### TESTS-8. `assert_raise` without message where the cause is the contract
- Severity: MEDIUM
- Category: weak assertions
- Location: `test/agents/base_agent_resilience_test.exs:289-299`; `llm/openai_compatible_adapter_test.exs:22`; `llm/claudio_adapter_test.exs:306`; `guardrails/builtins/{semantic_scope_test.exs:71,max_length_test.exs:57}`; `agents/turn_driver_test.exs:150`; `tools/schema_base_tool_test.exs:125`; `agents/base_agent_guardrails_test.exs:147`
- Evidence:
  ```
  assert_raise RuntimeError, fn -> BaseAgent.run(agent, %{chat_message: "test1"}) end   # x3
  assert CircuitBreaker.state(agent.circuit_breaker) == :open
  ---
  assert_raise ArgumentError, fn -> Adapter.convert_messages([%Message{role: "user", content: [%{}]}]) end
  ```
  Stats: 30 `assert_raise Mod, fn` (no message) vs 90 with a message/regex.
- Why it's a problem: the resilience test passes for any `RuntimeError` (a bug in retry plumbing, a missing
  client field wrapped as RuntimeError) as long as the breaker later opens; the adapter test passes for any
  `ArgumentError` (including a function-clause-style failure) rather than "text-only v1". The compaction/options
  tests in the same repo (`base_agent_compaction_config_test.exs:25`) show the better pattern.
- Fix: match the message (`~r/non-string content/`, the retry-exhausted message) on each; for the three
  resilience calls assert the specific failure text.
- Confidence: verified

### TESTS-9. Tests with no real assertion
- Severity: LOW
- Category: weak assertions
- Location: `test/coordination/agent_pool_test.exs:263-276` ("respects timeout on checkout"); `test/agents/base_agent_guardrails_test.exs:79-82` ("empty guard list is a no-op"); `test/resilience/retry_test.exs:108-139` (three tests, match-only)
- Evidence:
  ```
  catch_exit(AgentPool.checkout(pool, timeout: 50, block: true))
  AgentPool.stop(pool)
  ---
  {_updated, _response} = BaseAgent.run(agent, "anything")
  ---
  {:error, %{status: 400}} = Retry.with_retry(fn -> {:error, %{status: 400}} end, max_attempts: 3, ...)
  ```
- Why it's a problem: the pool test passes if checkout exits for any reason and does not check the waiter was removed
  (stats afterwards: `waiting`, `available`). The "no-op" test passes if run returns anything; it never checks that no
  guardrail telemetry fired or the response is unchanged. The retry tests never count invocations, so
  "does not retry" is untested (a function that retried 3 times and returned the same error also matches).
- Fix: assert `{:timeout, _} = catch_exit(...)` plus `AgentPool.stats(pool).waiting == 0`; count calls with an
  `Agent`/`:counters` in the retry tests and assert `== 1`; assert response content in the no-op test.
- Confidence: verified

### TESTS-10. Duplicated helpers/fixtures that belong in `test/support`
- Severity: LOW
- Category: duplicated fixtures
- Location: private `wait_until`/`eventually` in `agents/turn/server_test.exs:582`, `server_postgres_e2e_test.exs:83`, `resume_reaper_integration_test.exs:85`, `behaviours/session_registry/redis_distributed_test.exs:80` (versus `test/support/eventually.ex`, used by only 5 files); `defmodule FakeTool` (+ `defimpl BaseTool`) copied in `coordination/agent_process_server_test.exs`, `behaviours/config_test.exs`, `agents/dispatch_test.exs`, `agents/dispatch_split_test.exs`, `agents/turn/server_integration_test.exs`, `agents/turn/server_test.exs`; 26 ad-hoc `defimpl Normandy.Agents.Model` across 17 files (`*Client` stubs: RetryableClient, OptsClient, SpyClient, StreamingClient, ...)
- Evidence: `server_test.exs:582: defp wait_until(fun, retries \\ 200)` is identical in shape to `Normandy.Test.Eventually.wait_until/2`.
- Why it's a problem: four slightly different polling helpers (different budgets, return values: `true`/raises) drift
  apart; fixing flakiness means editing all of them. The `FakeTool` copies have diverged field sets (`notify`, etc.).
- Fix: one `Normandy.Test.FakeTool` and a configurable `Normandy.Test.StubClient` (script of replies/errors, records
  opts) in `test/support`; make `Eventually` take `timeout_ms` and replace the private copies.
- Confidence: verified

### TESTS-11. Processes started with `start_link` and fixed global names instead of `start_supervised`
- Severity: LOW
- Category: test doubles / isolation
- Location: 215 `start_link(` vs 1 `start_supervised` (`agents/base_agent_tool_loop_test.exs:480`); fixed names `:retry_agent` (`base_agent_resilience_test.exs:61,82,101,216,238,270`), `:test_pool`, `:test_supervisor`, `:test_agent`, `:test_context`, `:test_breaker`, `SleepyProbe` `name: __MODULE__` (`base_agent_tool_loop_test.exs:9`)
- Evidence: `{:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_agent)` repeated in six consecutive tests.
- Why it's a problem: `start_link` ties lifetime to the test process but not ordering: the next test can start
  while the previous named process is still terminating (`{:error, {:already_started, _}}`). Each name is currently
  used once per async module so it works today; adding a second test or a second file with the same atom collides.
  `start_supervised` guarantees stop-before-next-test.
- Fix: `start_supervised!({Agent, fn -> 0 end})` returning the pid, no registered names (pass pids); or
  `:"name_#{System.unique_integer()}"`.
- Confidence: verified for the pattern; collision is theory

### TESTS-12. Compile-warning triage is incomplete; only one warning cluster verified as meaningful
- Severity: LOW
- Category: compile warnings
- Location: `test/schema_virtual_fields_test.exs:81,119` (see TESTS-3); remainder unverified
- Evidence: a heuristic scan for a catch-all (`_ ->` / `_name ->`) followed by another clause at the same indent in
  any test file found no hits; `/tmp/*.log` held no `warning:` text, so the ~85 warnings could not be listed
  without running `mix`.
- Why it's a problem: `mix compile --warnings-as-errors` covers lib only (ci.yml), so test warnings never fail CI
  and new "unused variable"/"cannot match" warnings accumulate.
- Fix: run `mix test --warnings-as-errors` once locally to dump them (the coordinator can do this), fix, and add
  `--warnings-as-errors` to the CI test step.
- Confidence: theory for anything beyond TESTS-3 (needs `mix compile` output)

### TESTS-13. Option/env branches that need `Application.put_env` are never exercised
- Severity: LOW
- Category: coverage gaps
- Location: lib reads `Application.get_env(:normandy, :structured_outputs, true)` (`llm/structured_outputs.ex:23`), `:on_parse_failure` (`llm/claudio_adapter.ex:960`), `:redis_wait` (`behaviours/session_store/redis.ex:135`), `:adapter` (`json_deserializer.ex:458`, `agent_memory.ex:164,188`, `base_io_schema.ex:42`); tests have no `put_env` for them
- Evidence: `grep -rn "put_env" test` lists only `normandy_integration/basic_agent_test.exs:22` and `support/cluster_case.ex:118-119`.
- Why it's a problem: the global `structured_outputs: false` path and `on_parse_failure` modes are documented in
  CLAUDE.md as configuration but tested only through per-client options (if at all); adding such tests today would
  force `async: false` (which is the correct pressure to make lib take the value as an option, see the lib audit).
- Fix: either add `put_env` tests with `on_exit` restore in a small sync module, or inject the setting via opts and
  test purely.
- Confidence: theory (did not trace every option path for an indirect test)

### TESTS-14. Bypass used where Req.Test would do
- Severity: LOW
- Category: test doubles
- Location: `test/llm/claudio_adapter_test.exs:264-281`, `test/context/token_counter_test.exs:249-263`
- Evidence: `bypass = Bypass.open()` ... `base_url: "http://localhost:#{bypass.port}/"`; elsewhere the same file uses
  `Req.Test.stub` with `req_options: [plug: {Req.Test, name}]` (e.g. `claudio_adapter_test.exs:283-291`).
- Why it's a problem: both Bypass tests assert only that the request reached `base_url` with the right header/path.
  That is genuine transport routing (Req.Test plugs skip the base URL), so this is acceptable; but it costs a real
  socket and a port per test, and `async` safety relies on Bypass's ephemeral ports. Low priority.
- Fix: none required; if desired, assert the resolved `base_url` on the built Claudio client and use Req.Test.
- Confidence: verified

### TESTS-15. Test doubles are protocol impls defined at file load time, with a shared global impl for lib-owned structs risk
- Severity: LOW
- Category: test doubles
- Location: `test/support/tool_mockup.ex` (`defimpl BaseTool, for: __MODULE__`), top-level `defimpl Normandy.Agents.Model, for: Normandy.Test.*Client` in `llm/json_deserializer_retry_test.exs:1-39`, `context/summarizer_test.exs:8`, `behaviours/compactor_test.exs:11`
- Evidence: all `for:` targets are test-owned structs (`Normandy.Test.RawRecoveryClient`, etc.), none override
  a lib struct's impl.
- Why it's a problem: with `consolidate_protocols: false` the impls are global for the run; today they target
  unique test structs so no leakage across files was found. Risk is only that `Normandy.Test.*` structs at top level
  (not nested in the test module) are reachable by every file; a name reuse would raise a redefinition warning.
- Fix: none now; fold into the shared `StubClient` from TESTS-10 to remove 26 impls.
- Confidence: verified (checked `for:` targets via grep)

---

## Known (from prior audit)
None rediscovered (prior audit was lib races/perf; this area did not trace those).

## Area summary
- The default `mix test` run is fast and broad (~1594 tests) but the high-risk persistence and cluster suites
  (Postgres, Redis, distributed Horde/Mnesia) and all multi-agent orchestrators are excluded or live-API-only, so CI
  gives almost no signal for them (TESTS-1, TESTS-2).
- Main quality debt is timing: ~25 `Process.sleep` waits-for-async in coordination tests, plus an async telemetry test
  that can pass vacuously; assertions are generally good (90/120 `assert_raise` pin the message) with a few
  pass-for-any-reason exceptions.
- `schema compute:` is a registered-but-never-evaluated feature whose test only checks `is_function/2` (TESTS-3).
