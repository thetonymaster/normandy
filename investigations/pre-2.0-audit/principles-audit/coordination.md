## Principles audit: lib/normandy/coordination/**/*.ex + lib/normandy/batch/*.ex (14 files, 5,189 lines, whole modules)

Verdict: ship with follow-ups. No structural blocker, but three items touch public API and 2.0 is the cheap time to settle them: the unused `shared_context` option (#2), Batch.Processor's error shape (#3) and Pattern's identity functions (#8). The docs make two claims that are false (#1, #4).

### Findings (ranked)

1. [measure-first · false-claim] lib/normandy/coordination/stateful_context.ex:11-12 (also :78-79) — the docs say "a read never waits behind a write's work" and "reads are fast via ETS". Every read first makes `GenServer.call(server, :get_table)` (:104, :137, :164, :194, :241), and `update/4` runs the caller's fun inside the server (:328). A read therefore queues behind any slow update.
   Evidence: measured with `mix run --no-start`. An idle `fetch` took 8 µs. A `fetch` issued 20 ms into a 500 ms `update` took 480,183 µs. Because of the per-read call, the `:protected` ETS table with `read_concurrency: true` (:252-257) gives no concurrency over keeping a map in the server state. No benchmark exists (`bench/` absent, no Benchee anywhere).
   Fix: smallest, with no API change: correct the two doc passages to say reads are serialized with writes, including `update/4`'s fun. Structural fix: either give readers the tid once (cache it in the caller) or drop ETS. `get_table/1` is public, so dropping ETS changes public API.

2. [composition · over / false-claim] lib/normandy/coordination/hierarchical_coordinator.ex:73-76, :79-82 — `:shared_context` is accepted by `new/1`, `execute/3` and `execute_with_tasks/3`, stored on the struct (:52, :58, :128) and passed through `run_hierarchy`/`run_tasks` (:163, :170, :185, :230, :251). Nothing reads it.
   Evidence: both receivers discard it: `defp execute_manager(manager, input, _context)` (:301) and `defp aggregate_with_manager(manager, worker_results, _context)` (:447). The option doc says "The context the agents share" (:75), and the moduledoc example passes it (:35).
   Fix: either remove the option and the struct field (changes public API; record it in MIGRATING-2.0.md), or wire it into the manager and worker input and say how. Keeping it as a no-op is the one choice the principles rule out.

3. [composition · under] "Run one agent and turn a raise, exit or throw into an error" is written four times, and the input unwrap three times. One copy, Batch.Processor, returns a different public shape.
   Evidence:
   - Run-and-classify copies: orchestration.ex:107-116 (`run_agent`), reactive.ex:466-473 (`execute_agent`), hierarchical_coordinator.ex:310-320 (`run_manager`), agent_process.ex:905-916 (`inline_turn`).
   - `prepare_input` byte-identical in orchestration.ex:188-193, reactive.ex:485-490 and agent_process.ex:938-946 (`grep 'Map.get(input, "chat_message")'` → 3 hits).
   - batch/processor.ex:338-350 returns `{:error, {:exception, e, __STACKTRACE__}}`, `{:exit, r}` or `{:throw, v}`. Its doc confirms this at :154-155. Every other coordinator returns a bare exception or a `:task_down` `TurnError` and never a stacktrace (hierarchical_coordinator.ex:14-18; orchestration.ex:100-103).
   Fix: make `Orchestration.run_agent/3` the one implementation (add a pid clause for Reactive and a label argument) and call it from Reactive and HierarchicalCoordinator. For the internal copies this changes no API. Moving Batch.Processor onto it changes `process_batch/3`'s public error shape; decide that before 2.0.

4. [false-claim] lib/normandy/coordination/agent_process.ex:133-135 — the `:turn_engine` doc says "`:inline` runs `BaseAgent.run/2` in this process". Line :52 calls it "the default synchronous `:inline` `BaseAgent.run/2` path".
   Evidence: `start_turn/5` (:815-826) runs the turn in `WatchedWorker.start/2`, which does `spawn_monitor` (lib/normandy/watched_worker.ex:25). The module's own "Inline turns" section (:28-37) says the process "never waits on a turn". `BaseAgent.run` is arity 3 (base_agent.ex:447), and the moduledoc says `update_agent/2` (:30, :63, :72) while the function is `update_agent/3`.
   Fix: correct the doc strings. No API change.

5. [flat-code · under] lib/normandy/coordination/agent_pool.ex:582-613 (`handle_agent_death`, depth 4, inline `credo:disable` at :602) and lib/normandy/coordination/reactive.ex:219-240 (the `reduce_while` reducer nested inside two anonymous fns, `credo:disable` at :234).
   Evidence: `nesting_depth.py --max 3` → `agent_pool.ex:603: handle_agent_death: depth 4`. The script missed the reactive.ex case; it was found by reading the code. The inner `if` at agent_pool.ex:603-607 ("idle agent: a waiter gets it, else it goes to `available`") repeats the first two `cond` arms of `do_checkin/2` (:566-573).
   Fix: in AgentPool, extract `offer(agent_pid, state)` (waiter-or-available) and use it in both places, which removes a level and the disable. In Reactive, extract the reducer as a named `collect_outcome/3`. The project's CLAUDE.md allows inline disables, so these comply locally. No API change.

6. [composition · under] lib/normandy/coordination/agent_process.ex:472-494 — one GenServer state map carries both engines' fields, and the engine choice is dispatched at 9 sites.
   Evidence: dispatch sites at :496, :631, :664, :674, :692, :738, :749 and :778, plus the inline-only `handle_info` clauses at :727 and :732 that match on `running`. Fields: `session`, `owned` and `pending_runs` are server-only; `running` and `queue` are inline-only. The module is 989 lines. Both engines exist today, so this is a real second implementation.
   Fix (follow-up, ~half a day): move each engine's admit/finish/get_agent/update functions and state into two internal modules, and keep AgentProcess as the GenServer shell. No API change.

7. [composition · over / false-claim] lib/normandy/coordination/pattern.ex:88-89, :132-133 — `ok/1` and `error/1` are `def ok(result), do: result` and `def error(result), do: result`, identity functions documented as "Extracts the value…" (:76) and "Extracts the error reason…" (:120).
   Evidence: the moduledoc promises "helper functions and macros" (:5); the module defines no macros. `ok!/2` and `error!/2` never raise (:110-117, :154-161), against Elixir's `!` convention. Nothing in `lib/` calls Pattern (grep: 0 hits outside pattern.ex).
   Fix: deprecate or remove `ok/1` and `error/1`, and fix the moduledoc (no API change for the doc). Renaming the `!` functions changes public API.

8. [flat-code · under] lib/normandy/coordination/reactive.ex:283-304 — `else` after `raise` in `some/3` puts the whole body one level deeper.
   Fix: raise as a guard (`if count > length(agents), do: raise …`) and continue at top level. No API change.

9. [composition · under, low] Small duplicated helpers:
   - `run_callbacks/3` is identical in sequential_orchestrator.ex:96-101 and parallel_orchestrator.ex:287-291.
   - `normalize_key/1` is identical in shared_context.ex:196-200 and stateful_context.ex:368-372.
   - The race/some skeleton (start, await, shutdown, drain) is duplicated in reactive.ex:132-147 and :288-303.
   - `report_kill/4` has 3 variants (parallel_orchestrator.ex:266, reactive.ex:453, batch/processor.ex:358).
   Fix: move `run_callbacks` into Orchestration, and parameterise race/some by their await function. No API change.

10. [false-claim, low] lib/normandy/coordination/agent_supervisor.ex:12 says "Configurable restart strategies", but `:strategy` accepts only `[:one_for_one]` (:44). lib/normandy/batch/processor.ex:5 says "rate limiting", but the only throttle is a fixed `chunk_delay` between chunks (:309).
   Fix: change the doc wording. No API change.

### Survived scrutiny
- `AgentProcess.ScopedRegistry` implements the `@behaviour SessionRegistry`. The behaviour has 4 implementations: horde.ex, native.ex, redis.ex and scoped_registry.ex.
- `Orchestration` as a shared internal module: `with_task_supervisor`/`guard`/`run_agent` are called from Sequential, Parallel and Reactive (3 callers), and the module is `@doc false` per its moduledoc.
- AgentProcess's `:server` infrastructure (agent_process.ex:524-551): store, registry and supervisor are injected through `start_link` and default to owned in-memory instances, built at one edge (`init/1`). Right DI. `@session_types` (:95-97) derives option types from `Turn.Session`'s schema, so there is one source of truth.
- `Process.put(@agent_id_key, …)` (agent_process.ex:468) is not shared mutable state. Only the process writes it, and it lets `AgentSupervisor.list_agents/1` list a busy agent without a call.
- No globals in scope: no `name: __MODULE__`, no `Application.*_env`, no `:persistent_term` (grep: 0 hits). The only named process, the scoped Registry, is started by `Normandy.Application`.
- The OTP<25 `format_status/2` branch (agent_process.ex:578-591) is live code: `elixir: "~> 1.15"` (mix.exs:10) still supports OTP 24.
- AgentPool's O(n) list operations (`available ++ [pid]` :443, `List.last`/`Enum.drop(-1)` for `:fifo` :547, `Enum.find` over clients :478) operate on lists bounded by `size + max_overflow` (default 15).
- Batch.Processor's `merge_stats` (:381-383) is quadratic in the number of chunks, but every item is an LLM call (seconds each), so the list appends can never dominate. Not worth optimising without a measurement.
- The `HierarchicalCoordinator` delegation strategies are a closed `{:in, …}` option dispatched by one `case` (:330-339), not a registry. The simplest fitting form.

### Not checked
- Scope was whole modules (no diff base) for the 14 `.ex` files under lib/normandy/coordination/ and lib/normandy/batch/.
- `mix credo --strict <files>` ran: 0 issues, but only because of the two inline disables in #5. `mix xref` and `mix dialyzer` were not run.
- Tests were not run: the audit was read-only. The only measurement is the StatefulContext timing in #1.
- I did not read whether the coordination tests patch or inject. The repo-wide grep for `Application.put_env|:meck|Mimic` hits 6 files, none under test/coordination or test/batch. test/coordination/agent_process_registry_test.exs is `async: false`; I did not check why.
- `nesting_depth.py` is a heuristic and missed the anonymous-fn nesting in reactive.ex:219-240. Other anonymous-fn nesting may exist that I did not spot by reading.
- No benchmarks exist (no `bench/`, no Benchee), so no performance claim could be checked against numbers.
- Out of principles scope, not reported as findings:
  - `create_round_robin_specs/2` raises MatchError with an empty `workers` list (hierarchical_coordinator.ex:359).
  - StatefulContext never monitors its subscribers.
  - `execute_with_messages/3` runs agents in the caller, not in an unlinked task (sequential_orchestrator.ex:150).
