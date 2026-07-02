# Coordination-Layer Reliability — Design

**Date:** 2026-07-01
**Source:** `investigations/performance-race-audit.md` (findings A1, A2, A5, A6, A7, A8 and the coordination-layer MEDIUM/LOW items), gap-checked against `docs/superpowers/specs/2026-07-01-critical-fixes-design.md` — none of the defects below are covered by critical fixes 1–6.
**Status:** approved in brainstorming; implementation plans to follow in `docs/superpowers/plans/`.

## Context

A four-track audit of `lib/` found the coordination layer (`AgentPool`,
`AgentProcess`, `AgentSupervisor`, orchestrators, `Reactive`, `StatefulContext`)
and the `CircuitBreaker` carry the highest density of unfixed race/leak defects,
none documented in existing specs or plans. All HIGH findings were re-verified
against source. This spec packages them plus one small correctness bug (A8) that
fits no other cluster.

Decisions settled in brainstorming:

| Decision | Choice |
|---|---|
| Packaging | Per-cluster specs; this is the coordination cluster. Turn/session wave-2 waits for fixes 3/6; performance waits for fix 4 |
| Posture | Fix + targeted pruning: behavior-preserving fixes for load-bearing modules; API/doc changes where design contradicts documentation (StatefulContext, SharedContext) |
| Tier scope | HIGHs + coordination MEDIUMs + trivial LOWs |
| Strategy | Targeted repair per module (consolidation refactor explicitly deferred — see Non-scope) |

## Fix 0 — Correct schema artifact in prompts and retry feedback

**Defect:** `base_agent.ex:242` and `retry_feedback.ex:17` JSON-encode
`__specification__()` — the internal `%{field => type}` map whose values include
tuples like `{:array, :string}` — instead of the real JSON Schema. Poison has no
tuple encoder, so any composite-typed output schema silently loses its OUTPUT
SCHEMA prompt block (swallowed `rescue` in `base_agent.ex`) and crashes the
JSON-validation retry path (no rescue in `retry_feedback.ex`).

**Change:** both sites switch to `__schema__(:specification)` (via the existing
`get_json_schema/0`), a compile-time literal guaranteed encodable. The silent
`rescue` in `base_agent.ex:240-249` is removed — a failure there is a programming
error and should crash.

**Tests:** a schema with an `{:array, :string}` field produces an OUTPUT SCHEMA
block containing real JSON Schema; the validation-retry path with the same schema
completes without raising.

## Fix C1 — AgentPool ownership and monitor discipline

**Defects (audit A1 + mediums):** blocking checkout queues bare `from` with no
monitor or expiry (agents handed to dead callers, leaked as `in_use`); clients
are never monitored (client crash leaks its agent permanently — the code comment
claims otherwise); pool children default `restart: :transient` so the supervisor
and the pool BOTH replace crashed agents (untracked orphans; 4 crashes in 5s
kills the supervisor and, via link, the pool); monitors stack per checkout and
are never demonitored; overflow accounting decrements twice per terminated
overflow agent; checkin never verifies membership (double-checkin → two clients
share one agent's conversation memory); `:lifo`/`:fifo` strategies are inverted;
`BaseAgent.init` `start_link`s circuit breakers into whatever process calls it —
for pools, breakers link to (and can kill) the pool and leak on overflow churn.

**Design — the pool is sole owner of agent lifecycle, monitoring both directions:**

1. Children start with `restart: :temporary`; only the pool replaces dead agents.
2. Checkout monitors the client (`elem(from, 0)`); state tracks
   `holders: %{agent_pid => {client_pid, client_ref}}`. Client DOWN → automatic
   checkin of its agent.
3. Agents are monitored once at start (not per checkout); agent DOWN → single
   cleanup + replacement path.
4. Waiters are stored as `{from, client_ref, deadline}`; waiter clients are
   monitored and pruned on DOWN; expired entries (deadline = enqueue time +
   caller timeout) are skipped at pop time.
5. Checkin is membership-guarded (`holders` lookup; foreign/double checkin is
   logged and ignored) and demonitors with `[:flush]`.
6. Terminations demonitor before `terminate_agent` so overflow accounting
   decrements exactly once.
7. `:lifo` takes from the head; `:fifo` uses `:queue`.
8. Breaker ownership moves to `AgentProcess.init` (linked to the process that
   lives and dies with the agent); pool-held configs no longer start breakers in
   the pool process. Direct `BaseAgent.init` callers keep today's behavior with
   ownership documented. (Implementation rides in plan W2-C with the other
   AgentProcess changes.)

**Tests:** kill a holding client → capacity recovers; kill a waiting client →
its queue entry is pruned and the next checkin serves a live waiter; timed-out
waiter never receives an agent; double-checkin is a no-op; overflow count stays
correct across terminate + DOWN; crash 5 agents rapidly → pool survives and
replaces exactly 5.

## Fix C2 — CircuitBreaker probe safety

**Defects (audit A2):** `execute_and_record/2` has `rescue` only — an `exit`
inside the wrapped fun (a `GenServer.call` timeout in an LLM client is exactly
this) never reports, so the half-open slot (default max 1) is never released and
there is no lease timeout: the breaker wedges permanently in `:half_open`,
rejecting all traffic until manual `reset/1`. Admission is also check-then-act
across two `GenServer.call`s, and `:try_half_open_call` never checks
`state.state` — concurrent open→half-open cycles admit probes while open.

**Design:**

1. A single atomic `:acquire` call replaces `get_state` + `try_half_open_call`:
   checks state and slot counter in one callback, performs the open→half-open
   transition internally, returns `:allowed | {:allowed, lease_ref} |
   {:rejected, :open}`.
2. Half-open leases: the breaker monitors the probing caller
   (`{lease_ref, monitor_ref}`). Caller DOWN before reporting → slot released,
   failure recorded. A configurable `half_open_lease_timeout_ms` (default 60_000)
   expires abandoned leases the same way. Every acquired slot has three exit
   paths: report, DOWN, lease expiry — the wedge becomes structurally impossible.
3. `execute_and_record` gains `catch kind, reason ->` that records the failure
   and re-raises with `:erlang.raise(kind, reason, __STACKTRACE__)` — accounting
   fixed, caller-visible propagation semantics preserved exactly.

**Tests:** probe fun exits → next `:acquire` is allowed once the DOWN is
processed; short-lease expiry releases the slot and reopens; concurrent acquire
storm at the open→half-open boundary admits at most `half_open_max_calls`;
`catch` path records failure and re-raises the original exit.

## Fix C3 — Orchestrator and batch partial-failure semantics

**Defects (audit A5, A6 + mediums/lows):** `ParallelOrchestrator` and
`Batch.Processor` call `Task.async_stream` without `on_timeout: :kill_task`, so
one slow item exits the orchestrating process and destroys all results; both
carry dead `{:exit, _}` handling that only `:kill_task` would make live (the
orchestrator's clause is also shape-mismatched). `Reactive.all/3`'s timeout
branch replaces the accumulator with a fresh `%{}`; `Reactive.execute_agent`'s
pid branch has no exit handling (a dead contestant kills the race);
`race/some` leave straggler messages in the caller's mailbox.
`SequentialOrchestrator`'s simple API crash-matches `{:ok, _} =` on a path that
returns `{:error, _}`. `Retry.add_jitter` crashes for `base_delay < 4`
(`:rand.uniform(0)`); `execute_with_timeout` implements no timeout.

**Design:**

- ParallelOrchestrator: `on_timeout: :kill_task`; internally `ordered: true`,
  zipped with input specs so exits map to their `agent_id`; the exit clause
  becomes a real `{agent_id, {:error, {:exit, reason}}}` path; `execute_agent`'s
  pid branch catches exits. Caller-facing `ordered:` semantics preserved
  (results are keyed by `agent_id`).
- Batch.Processor: `on_timeout: :kill_task` (existing exit branches become live
  per-item handling — the advertised partial-failure support becomes true);
  `process_batch_chunked` replaces its crash-match with a `case`; the unordered
  chunked path returns errors alongside successes instead of discarding them;
  progress callback documented as item-index, not completion count.
- Reactive: `all/3` continues with the accumulator and records the timeout as an
  error entry; pid branch catches exits; `race/some` drain `{ref, _, _}`
  stragglers after selection (`after 0` flush loop).
- SequentialOrchestrator: `case` instead of `=` match, `{:error, _}` propagates;
  reduce accumulation becomes prepend + reverse.
- Retry: `max(1, div(delay, 4))` jitter guard; `execute_with_timeout` renamed to
  `execute_protected` (private; the name promised a timeout that never existed).

**Tests:** N agents with one sleeping past timeout → N−1 results survive, exit
keyed to the right agent id (orchestrator and batch both); chunked batch with a
failing chunk returns errors instead of crashing; `Reactive.all` with one
timeout returns the other results plus an error entry; race with one dead pid
still returns the winner and leaves no `{ref, _, _}` in the caller's mailbox;
`with_retry(fun, base_delay: 2)` retries instead of crashing.

## Fix C4 — AgentProcess responsiveness and hygiene

**Defects (audit A7 + mediums):** the default `:inline` engine runs
`BaseAgent.run` (multi-second LLM call plus `Process.sleep` retry backoff)
inside `handle_call`, blocking the GenServer; any concurrent
`get_id`/`list_agents`/`find_agent` times out and crashes the observer. The
async cast path uses unsupervised `Task.start` with `rescue`-only error handling
(consumers hang forever on an exit), and discards the updated agent (async runs
never persist conversation memory). Every `:server`-mode start without a
supplied registry mints an uncollectable atom
(`:"agentprocess_reg_#{System.unique_integer}"`). `AgentSupervisor.list_agents`
is a which_children snapshot followed by per-child 5s calls — dead or busy
children crash the caller. The worker handshake `receive` has no `after`.

**Design:**

1. Inline `{:run, _}` routes through the existing `spawn_run`/`pending_runs`
   worker machinery used by `:server` mode, replying via `GenServer.reply` on
   result arrival. Caller semantics unchanged (blocking call, same timeout); the
   GenServer stays responsive throughout the turn. Retry backoff moves to the
   worker with it.
2. Async casts reuse the same worker protocol with the `:server`-mode
   `catch kind, reason` guarantee — `reply_to` always hears back. The updated
   agent from a completed async run is applied to server state on arrival;
   concurrent casts still snapshot state at dispatch, and that ordering caveat
   is documented instead of hidden.
3. One application-level named `Registry`
   (`Normandy.Coordination.ProcessRegistry`, `keys: :unique`, term keys)
   replaces per-start atom minting.
4. `AgentSupervisor.list_agents/find_agent`: `get_id` wrapped in
   `try/catch :exit` (dead/busy children skipped); `find_agent` reads the
   Registry directly — O(1), no serialized calls.
5. Worker handshake `receive` gains `after 5_000 -> exit(:normal)`.

**Tests:** `get_id` answers during an in-flight inline run; async cast whose run
exits still delivers `{:agent_result, _, {:error, _}}` to `reply_to`; async run
updates conversation memory visible to a subsequent sync run; `list_agents`
with one dead and one busy child returns the rest; repeated `:server`-mode
starts do not grow the atom table (assert via `:erlang.system_info(:atom_count)`
delta).

## Fix C5 — Context pruning

**Defects (audit mediums/lows):** `StatefulContext` documents "fast reads via
ETS (no GenServer bottleneck)" but every read does `GenServer.call(:get_table)`
first; the table is `:public` and the docs invite direct writes that silently
break `update/4`'s GenServer-serialized read-modify-write; subscribers are never
monitored (dead pids accumulate). `SharedContext`'s moduledoc claims cross-agent
sharing but it is an immutable struct — concurrent use is lost-update by
construction. `HierarchicalCoordinator` discards the manager's updated memory
between delegation and aggregation, never inspects worker errors (all-failed
still "succeeds" with an empty map), and threads a SharedContext that nothing
reads.

**Design:**

- StatefulContext: table created `:protected` with `read_concurrency: true`; tid
  published via `:persistent_term` keyed by server pid (erased in `terminate`);
  `get/has_key?/keys/to_map` read ETS directly with zero GenServer calls;
  `get_table/1` deprecated, documented read-only; subscribers monitored and
  pruned on DOWN. **Breaking change:** direct table writes (previously
  documented) stop working — changelog + moduledoc migration note (writes go
  through `put/update`). This is deliberate: the old API invited silent state
  corruption.
- SharedContext: moduledoc rewritten — single-process threading semantics,
  pointer to StatefulContext for cross-process use. No code change.
- HierarchicalCoordinator: `updated_manager` threaded from delegation into
  aggregation; `worker_results.errors` inspected — all workers failed returns
  `{:error, {:all_workers_failed, errors}}`, partial failures are passed to the
  manager alongside results; dead SharedContext plumbing deleted; `@spec`s gain
  their missing success types.

**Tests:** StatefulContext reads succeed while the server is suspended
(`:sys.suspend/1`); subscriber death prunes the set; hierarchical run with all
workers failing returns an error; manager aggregation sees its own delegation
exchange in memory.

## Testing conventions

Deterministic, no arbitrary sleeps: process-death scenarios use monitors and
killed helper processes; slow agents are fakes sleeping past explicit short
timeouts; suspension via `:sys.suspend/1`. Per repo convention: `mix format`
before tests; all existing tests must pass at each plan's completion.

## Plan packaging and sequencing

| Plan | Contents | Depends on |
|---|---|---|
| W2-A | Fix 0 + one-liners (`on_timeout` ×2, jitter guard, Sequential crash-match, lifo/fifo) | — |
| W2-B | C1 pool internals + C2 breaker | — |
| W2-C | C4 AgentProcess + ProcessRegistry + AgentSupervisor; C1's breaker-ownership move | W2-B |
| W2-D | C3 remainder (Reactive, chunked batch, mailbox drain) + C5 pruning | — |

Independent of critical-fixes plans 1–6: no shared files except coordination
`rescue` sites that fix-5's plan explicitly marks "no change".

## Non-scope

- The consolidation refactor (DSL.Workflow inline loop + `coordination/*` merge,
  assessment rec #6) — right long-term shape, wrong sequencing while fixes 1–6
  are in flight. Revisit after both waves land.
- Turn/session wave-2 cluster (stale restart args, passivation window, reaper
  misses, Redis fork id/pipeline errors, ETS store timeouts) — separate spec,
  after fixes 3/6.
- Performance cluster (O(N²) history re-encoding, worker heap copies, invariant
  rebuilds, Poison default) — separate spec, after fix 4.
- Mnesia backend changes of any kind.

## Review note

Brainstorming approvals on record: packaging (per-cluster, coordination first),
posture (fix + targeted pruning), tier scope (HIGH + MEDIUM + trivial LOW),
approach (targeted repair), design parts 1–3 (Fix 0, C1–C5, testing, plan
packaging).
