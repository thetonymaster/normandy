# Performance & Race-Condition Audit — 2026-07-01

Read-only audit of `lib/` (121 files, ~24.5k lines). Four parallel investigation
tracks: coordination/resilience races, turn/session/store races, runtime hot-path
performance, schema/JSON pipeline performance. All HIGH findings were
independently re-verified against source by the coordinator (marked ✅); MEDIUM/LOW
findings carry agent-cited verbatim evidence but were not all re-read (marked ⚠️ =
agent-verified theory, high confidence).

No files were modified. No fixes applied.

---

## A. Race conditions & correctness

### HIGH

#### A1. AgentPool leaks agents three independent ways ✅
`lib/normandy/coordination/agent_pool.ex:263-275, 402-406` + `agent_supervisor.ex:100-110`

- **Stale waiters:** blocking checkout parks the caller's `from` in a queue with no
  monitor and no expiry. The client's 5s call timeout fires, it leaves; the next
  checkin pops the dead `from`, `GenServer.reply` is discarded, and the agent is
  marked `in_use` with no living holder — leaked forever.
- **No client monitor:** the comment says "Monitor the checking out process" but the
  code monitors the *agent* pid (line 267). A client that crashes while holding an
  agent (including a brutally-killed `transaction/3` caller) leaks it permanently.
- **Double-replacement orphans:** pool agents start under a DynamicSupervisor with
  default `restart: :transient`; on crash the supervisor restarts an untracked pid
  AND the pool's own DOWN handler starts a tracked replacement. Bonus: 4 crashes in
  5s exceed supervisor intensity (`max_restarts: 3`), killing the supervisor, whose
  link kills the pool.

**Fix:** monitor waiting callers + prune on DOWN; monitor checkout clients and
auto-checkin on DOWN; start pool children `restart: :temporary` (pool owns
replacement).

#### A2. CircuitBreaker wedges permanently in half-open ✅
`lib/normandy/resilience/circuit_breaker.ex:318-339, 262-269`

`execute_and_record/2` has `rescue` only — no `catch :exit/:throw`. An `exit`
inside the wrapped fun (exactly what a `GenServer.call` timeout in an LLM client
produces) never sends `record_success/failure`, so the half-open slot
(`half_open_calls`, default max 1) is never released and there is no half-open
lease timeout. Every subsequent call returns `{:error, :open}` until manual
`reset/1`. Separately, admission is check-then-act across two GenServer calls and
`:try_half_open_call` never checks `state.state` — a concurrent open→half-open
cycle re-admits probes while the circuit is open.

**Fix:** `catch kind, reason ->` recording failure; monitor slot holder, release on
DOWN; single atomic `:acquire` callback checking state + counter; half-open lease
timeout.

#### A3. Dangling `tool_use` across a crash wedges the session permanently ✅
`lib/normandy/agents/turn.ex:132-134, 268-280`, `turn/server.ex:176-195, 287-292`

The assistant message containing `tool_use` blocks is durably appended to the
SessionStore BEFORE tools are dispatched; tool results are appended only when the
whole batch resolves. If the server/node dies mid-dispatch, the stored history ends
with `tool_use` and no `tool_result`. No repair logic exists anywhere on
resume/new-turn: the next LLM call replays the broken history → Anthropic 400
(`tool_use` without `tool_result`) → turn `:failed` → every subsequent turn on the
session fails the same way. This violates the batch-completeness contract across
the crash boundary (it holds only in-process).

**Fix:** on resume/new-turn, scan history tail and synthesize `is_error`
tool_results for uncovered tool_use ids; or append assistant+results atomically at
batch resolution.

#### A4. Turn.Server transient restart replays executed work ✅
`lib/normandy/agents/turn/supervisor.ex:20-25`, `turn/server.ex:62-73`, `turn/session.ex:126-127`

`Session.rehydrate_and_start` bakes snapshots of `config` (memory included) and
`turn_state` into child-spec args; `restart: :transient` restarts crashed servers
with those SAME stale args, and `init` prefers opts over the store. A server that
persisted T3 but crashes restarts at T0 and (eager) re-runs already-executed
batches: duplicate LLM calls, duplicate tool executions, duplicate store appends.
Concrete crash triggers exist: no catch-all `:info` clause (`server.ex:207-235` —
any stray message crashes the statem) and store-call 5s timeouts exit the statem
(`session_store/ets.ex:33-36`).

**Fix:** never pass `turn_state`/`config` through restartable child args — load
from store in `init`; add catch-all info clause; wrap store calls in
`try/catch :exit`.

#### A5. ParallelOrchestrator: one slow agent kills the whole orchestration ✅
`lib/normandy/coordination/parallel_orchestrator.ex:130-176`

`Task.async_stream` without `on_timeout: :kill_task` → default `:exit` crashes the
orchestrating process on any single timeout, losing all other results;
HierarchicalCoordinator's `{:ok, _} =` match propagates the crash. The
`{:exit, {agent_id, reason}}` reduce clause is unreachable dead code (and
shape-mismatched — `:kill_task` yields `{:exit, :timeout}` without agent_id).
Also, `execute_agent` rescues exceptions only, and tasks are linked — an exit in
`BaseAgent.run` kills the caller.

**Fix:** `on_timeout: :kill_task`; map exits back to ids via ordered zip; fix the
exit clause shape; catch exits in `execute_agent`.

#### A6. Batch.Processor: same missing `on_timeout` ✅
`lib/normandy/batch/processor.ex:131-136, 249-251`

Advertises partial-failure support, but one slow item (> 300s default) exits the
caller and destroys the whole batch. Its `{:exit, _}` branches are dead code that
only `:kill_task` would make live. `process_batch_chunked`'s `{:ok, _} =` match
crashes the chunked run too.

**Fix:** add `on_timeout: :kill_task` — the existing exit-handling becomes live and
per-item.

#### A7. Inline AgentProcess blocks its GenServer for the entire LLM turn ✅ (call path verified by agent)
`lib/normandy/coordination/agent_process.ex:367-401` + `retry.ex:164`

Default `:inline` engine runs `BaseAgent.run` (multi-second LLM call, plus
`Process.sleep` retry backoff up to tens of seconds) inside `handle_call`. Any
concurrent `AgentSupervisor.list_agents/find_agent` does `get_id(pid)` with a 5s
timeout → the *observer* crashes. `:server` mode already has the non-blocking
machinery.

**Fix:** route inline runs through the same spawn/pending-runs machinery as
`:server` mode.

#### A8. Output schema silently missing / retry path crashes — wrong schema artifact ✅
`lib/normandy/agents/base_agent.ex:241-249`, `lib/normandy/llm/json/retry_feedback.ex:17`

Both encode `__specification__()` — the internal `%{field => type}` map whose
values are terms like `{:array, :string}` — instead of the real JSON Schema
(`__schema__(:specification)` / `get_json_schema/0`, a compile-time literal).
Poison has no tuple encoder:

- In `base_agent.ex` the encode is wrapped in a silent `rescue` → **any output
  schema containing a composite type gets NO "OUTPUT SCHEMA" block in its system
  prompt at all**, silently degrading structured-output quality on the legacy path.
- In `retry_feedback.ex` there is no rescue → **the JSON-validation retry path
  crashes** for composite-typed schemas; simple schemas get the wrong artifact
  (field→type map, not the schema the model is told to match).

**Fix:** use `__schema__(:specification)` in both places.

### MEDIUM ⚠️

- **No single-writer fencing per session** — the cross-cutting theme of the
  turn/session layer. Within one live server and one backend operation, consistency
  is solid (see D below); but nothing prevents a second server writing the same
  session:
  - Native registry: `register_self` discards `{:error, :taken}`
    (`turn/server.ex:95, 397-402`); the losing duplicate runs a full turn
    unregistered, interleaving appends into the same session.
  - Redis registry: liveness = one owner GenServer refreshing every key
    sequentially every ttl/2 (`session_registry/redis.ex:19, 83, 165-171`); a
    starved owner (VM pause, Redis latency × N sessions) lapses keys while servers
    live → split-brain, no fencing token on store writes.
  - Horde registry: AP/CRDT — netsplit partitions each register their own server;
    `save_turn_state` is unconditional last-writer-wins in EVERY backend
    (`session_registry/horde.ex:16-18`, `session_store/postgres.ex:107-120`) →
    durable interleaved damage before Horde heals.
  - **Fix direction:** optimistic version / lease-epoch column on turn_state
    checked at save; treat register-conflict as start failure.
- **Passivation window loses turns** — `Session.run` does whereis→call with no
  `:noproc` retry; the 60s idle passivate stop races arriving calls
  (`turn/session.ex:35-37`, `turn/server.ex:257-259`). Fix: catch `:noproc`, loop
  to `ensure_server` (bounded).
- **ResumeReaper misses** — Horde `whereis` has no liveness check and the reaper
  fires once per `:nodedown` with no re-sweep; during CRDT convergence a dead pid
  looks alive → session never resumed (`session_registry/horde.ex:70-75`,
  `resume_reaper.ex:83-88`). Terminal-state persist is best-effort
  (`turn/server.ex:327-339`): if it fails, the reaper later "resumes" a completed
  turn → duplicate final assistant message.
- **Redis store fork id collision** — `"fork_#{System.unique_integer}"` is
  node-local; two nodes sharing a namespace can mint the same id and interleave two
  forks into one stream. Every other backend uses UUID
  (`session_store/redis.ex:63`). Fix: UUID.
- **Redis pipeline errors swallowed** — `{:ok, _}` match ignores in-band
  `%Redix.Error{}` results (MOVED in cluster mode → eager session never enters the
  resumable set, silently) (`session_store/redis.ex:100-112`).
- **CircuitBreaker per-pool link/leak** — `BaseAgent.init` inside the pool GenServer
  `start_link`s breakers linked to the POOL; overflow-agent termination never stops
  its breaker → unbounded breaker accumulation, and any breaker crash kills the
  pool (`agent_pool.ex:344` + `base_agent.ex:82-88`).
- **AgentPool monitor hygiene** — no `demonitor` on checkin (stacked refs → one
  death fires N DOWNs, each mutating accounting); overflow_count decremented twice
  per terminated overflow agent (checkin + spurious DOWN) → overflow cap bypassed;
  replacement agents handed to waiters are never monitored
  (`agent_pool.ex:393-417, 419-452`).
- **AgentPool checkin doesn't verify membership** — double-checkin (or foreign pid)
  puts the same agent in `available` twice → two clients share one AgentProcess and
  silently corrupt each other's conversation memory (`agent_pool.ex:196-199,
  297-307`).
- **StatefulContext defeats its own design** — every read (`get/has_key?/keys/to_map`)
  does `GenServer.call(:get_table)` before touching ETS, so the documented
  "fast reads via ETS (no GenServer bottleneck)" is false; AND the table is
  `:public` with docs inviting direct writes, which silently break the
  GenServer-serialized `update` read-modify-write (`stateful_context.ex:224-227,
  236-242, 302-325`). Fix: named table or tid via `:persistent_term`; `:protected`.
- **Atom-table leak** — `:"agentprocess_reg_#{System.unique_integer}"` mints an
  uncollectable atom per `:server`-mode AgentProcess start; long-running churn
  eventually hits the 1M atom limit → VM death (`agent_process.ex:301`).
- **Inline async runs lose memory & can hang consumers** — `Task.start` unsupervised,
  `rescue`-only (no `catch :exit`); updated agent discarded so async casts never
  persist conversation; a documented bare `receive` consumer blocks forever when
  the task dies (`agent_process.ex:500-519, 606-617`).
- **Reactive.all discards accumulated results on timeout** — the non-fail-fast exit
  branch continues with a fresh `%{}` instead of the accumulator
  (`reactive.ex:177-183`); `execute_agent` pid-branch has no exit handling, so a
  dead contestant kills the whole race (`reactive.ex:318-321`).
- **AgentSupervisor.list_agents check-then-act** — `which_children` snapshot then
  per-child `get_id` call: dead child → `:noproc` exit; busy inline child → 5s
  timeout exit; either crashes the caller (`agent_supervisor.ex:136-144`).
- **No deadline in `:running`** — `Server.run` blocks `:infinity`, tool dispatch runs
  `timeout: :infinity`; one hung tool pins the session forever (never passivates,
  never reaped) (`turn/server.ex:44, 450-459`). Fix: configurable per-effect
  deadline feeding `{:tool_error, :timeout}`.

### LOW ⚠️ (selected)

- `Retry` jitter crashes for `base_delay < 4` (`:rand.uniform(0)` raises) —
  `retry.ex:260-263`. Trivial fix: `max(1, div(delay, 4))`.
- `SequentialOrchestrator` simple API raises `MatchError` on any agent failure
  instead of returning `{:error, _}` (`sequential_orchestrator.ex:93`).
- Turn effect-task handshake `receive` without `after` → permanent orphan if server
  dies in the spawn window (`turn/server.ex:362-368`; same shape
  `agent_process.ex:528-532`).
- Batch completeness holds only by construction — nothing asserts result-set ids ==
  pending-call ids before the next LLM call; a future classify verdict silently
  produces a partial batch → API 400 far from the cause (`turn.ex:309-318`,
  `turn/server.ex:442-446`). Cheap assertion recommended (this is the load-bearing
  contract from project memory).
- `Reactive.race/some` never drain the mailbox after a winner → stale result tuples
  accumulate in callers (`reactive.ex:92, 342-371`).
- Redis registry `whereis` maps transport errors to `:none` — outage
  indistinguishable from "no session"; `Server.approve` is a cast so approvals can
  vanish silently (`session_registry/redis.ex:128-129`, `turn/session.ex:44-54`).
- HierarchicalCoordinator: manager's updated memory discarded between delegation and
  aggregation; worker errors never inspected (all-workers-failed still "succeeds");
  its SharedContext plumbing is dead code (`hierarchical_coordinator.ex:105-112,
  205, 300-308`).
- SharedContext moduledoc invites cross-process use but it's an immutable struct —
  concurrent `update/4` is lost-update by construction (`shared_context.ex:166-171`).
  Doc fix.
- Pool strategy semantics inverted: `:lifo` behaves FIFO and vice versa
  (`agent_pool.ex:377-391, 410`).

---

## B. Performance

### B1. O(N²) history re-serialization — the big one ✅
`lib/normandy/components/agent_memory.ex:82-89` + `base_agent.ex:231, 254-258, 986-1002`

`AgentMemory.history/1` JSON-encodes the content of EVERY message on EVERY LLM
call (the Map impl also does `Application.get_env` per message), then
`get_response_with_usage` immediately converts the maps back into `%Message{}`
structs. Net: ~5 full O(N) passes + a struct→map→struct round trip per LLM call,
× k tool-loop iterations per turn; cumulative O(N²) encoding work over a
conversation. At 200 messages every turn re-encodes all 200.

**Fix:** encode content once at append time (store serialized form on the Entry),
add a history variant returning `%Message{}` directly, hoist the adapter lookup.

### B2. Full conversation heap copied into workers ✅/⚠️
- `base_agent.ex:596-612, 813-831`: every tool-call worker closure captures the
  whole `%BaseAgentConfig{}` including `memory` + `initial_memory`; spawning
  deep-copies the entire conversation per tool call. Dispatch reads only
  `tool_registry`/`behaviours`/`name` (verified). Several MB of copying per turn at
  long-history + multi-tool scale; pure GC/bandwidth waste.
- `turn/server.ex:356-368`: same pattern — whole `%Data{}` closure-copied into a
  fresh process for every blocking effect (each LLM call, tool batch, compaction).

**Fix:** pass a slimmed struct into workers.

### B3. Invariant work rebuilt on every LLM call ✅
`base_agent.ex:234-252, 269-275` + `system_prompt_generator.ex`

Per call (× tool iterations): full system prompt reassembled (incl. per-tool
parameter docs), output schema re-encoded to pretty JSON, tool schema list rebuilt.
All invariant for a given agent except context-provider sections.
**Fix:** precompute at init; regenerate only the context-provider section.

### B4. Poison + per-call config resolution ⚠️
Default adapter is Poison (2–5× slower than Jason; OTP 27 has native `JSON`);
resolved three inconsistent ways: `compile_env` (schema.ex:337), per-call
`Application.get_env` (base_io_schema.ex:42, json_deserializer.ex:450-452).
**Fix:** default to Jason, resolve once.

### B5. ETS session store copies whole memory per append ⚠️
`session_store/ets.ex:74-89`: full `%AgentMemory{}` copied out of ETS, rebuilt,
copied back per append; every session serialized through one GenServer;
`:private` table makes read concurrency impossible. O(history) per append, shared
mailbox → feeds the 5s-timeout crash in A4.
**Fix:** per-entry rows + head row, or public table with `read_concurrency`.

### B6. Incremental output guardrails are O(R²) ✅ (agent-verified, off by default)
`base_agent.ex:1082-1106`: every 200 streamed bytes, ALL guards re-scan the ENTIRE
accumulated response. **Fix:** re-scan only a tail window.

### B7. Smaller per-call rebuilds ⚠️
- `schema/validator.ex:300-321`: `Regex.compile!` of `pattern:` constraints per
  validation, per array element (format `~r//` sigils are compile-time — fine).
- `llm/json/schema_translator.ex:14-41`: structured-outputs schema translation
  recomputed per LLM call; no memoization anywhere in the LLM/schema layer
  (grep-verified). Fix: `:persistent_term` per module.
- `telemetry/otel_ctx.ex:23-28`: `Code.ensure_loaded?` per capture — round-trips the
  global code server (incl. path search) on every tool batch when OTel is NOT
  installed, in interactive-mode nodes. Fix: probe once into `:persistent_term`.
- `context/window_manager.ex:105-129`: token estimation = `String.length`
  (grapheme walk) over history/1's freshly re-encoded JSON, recomputed from zero
  (twice in `truncate_oldest_first`). Only hot when a real compactor is enabled.
  Fix: `byte_size/1`, running estimate maintained at append.
- `base_agent.ex:1199-1204, 1419-1436`: `completed_iterations` walks/reverses/counts
  the full chain per run-stop purely for a log line, even when :info is filtered.
- `__meta__` serialized into every message's JSON → shipped as prompt tokens every
  turn (`schema.ex:336-341`, no `@derive ... except: [:__meta__]`).
- JSON parse-failure path: unbounded balanced-region rescans + a decode per
  candidate region — O(openers × bytes) on pathological LLM output
  (`content_cleaner.ex:49-68`, `json_deserializer.ex:394-425`). Cap candidates.
- Micro: `executor.ex:127-138` `results ++ [r]` in reduce (utility API);
  double Task spawn per tool (async_stream worker + timeout Task, executor.ex:155);
  `length(x) > 0` instead of `!= []` (system_prompt_generator.ex:242,
  registry.ex:407); `String.length` for a >500 check (retry_feedback.ex:39);
  Redis registry refresh = sequential EVAL per session through one owner + one
  shared Redix connection for registry AND store (`cluster.ex:99`); Postgres
  `fork/3` loads full entry chain with content just to test ancestry
  (`postgres.ex:178-186`).

---

## C. Verified safe (do not re-flag)

- **Schema specs are compile-time literals** — `__specification__/0` and
  `__schema__(:specification)` are `Macro.escape`d literals (schema.ex:289-291,
  443-475); tool `input_schema` likewise. Only *derived* artifacts (translation,
  pattern regexes, JSON encoding of the spec) are rebuilt at runtime.
- **Stream accumulation** — prepend+reverse for events; text accumulation hits the
  ERTS binary-append optimization; content-block list ops are O(#blocks), not
  O(#chunks) (`stream_processor.ex:135-156`, `base_agent.ex:1089, 1126`).
- **Registries are not bottlenecks** — Tools.Registry is a plain struct/map read in
  the calling process; MCP/A2A registries are registration-time only.
- **CircuitBreaker executes the wrapped fun caller-side** — slow LLM calls don't
  block the breaker GenServer; state IS process-shared (one pid per agent config).
  The wedge (A2) is about slot release, not architecture.
- **Retry catches exits correctly** (`retry.ex:188-201`) — unlike the breaker.
- **Per-backend store atomicity** — ETS/InMemory serialize via owner process; Mnesia
  uses transactions (no dirty ops); Postgres uses `ON CONFLICT` + `FOR UPDATE`;
  Redis appends are atomic XADD. The gaps are cross-process (A/MEDIUM), not
  per-operation.
- **Within one live Turn.Server** — single blocking task at a time, ref-tagged
  results, `demonitor(:flush)`, exactly-once batch decrement, fail-closed
  approvals, persist-before-announce at suspend points. Duplicate/stale approval
  casts are dropped. Reaper-vs-resume converges through atomic `:via` registration.
- **No LLM-controlled atom creation in Normandy's own code** — decoded JSON keys
  stay strings end-to-end; the one `String.to_atom` is developer-input-bounded
  (`validate.ex:806-808`). Caveat: Claudio decodes SSE payloads with
  `keys: :atoms` per the adapter's own comment (claudio_adapter.ex:411-419) —
  bounded wire schema in practice, dependency-level fix.
- **`Validate.cast` is O(permitted fields)** — map pattern matches, no O(f×p) scans.
- **`[system_message] ++ history`** — left operand is length 1; correct usage.

## D. Dead / misleading code noted

- `parallel_orchestrator.ex:174-175` — unreachable `{:exit, ...}` clause (A5).
- `batch/processor.ex:249-251, 271-273` — dead `{:exit, _}` branches (A6);
  `process_single` ignores its `_timeout` param.
- `retry.ex:188` — `execute_with_timeout` implements no timeout.
- `hierarchical_coordinator.ex` — SharedContext threading entirely dead.
- `agent_pool.ex:137` — documented `{:error, :pool_exhausted}` never produced.
- `stateful_context.ex:11-12, 82` — moduledoc claims are false (see MEDIUM).

---

## E. Recommended fix order

1. **A8 — wrong schema artifact** (base_agent + retry_feedback). Two-line fix, pure
   correctness, silently degrading every composite-typed schema today.
2. **A2 — circuit breaker wedge.** Small diff (`catch` + monitor + atomic acquire);
   converts a permanent outage mode into designed behavior.
3. **A5/A6 — `on_timeout: :kill_task`** in ParallelOrchestrator and Batch.Processor.
   One-line each; makes existing dead error-handling live and restores advertised
   partial-failure semantics.
4. **A3 — dangling tool_use repair on resume.** Highest-payoff durability fix for
   Turn sessions; pairs with A4 (stop passing state through restart args) and the
   batch-completeness assertion (LOW list).
5. **A1 — pool monitor discipline** (waiters + clients + `:temporary` children).
6. **B1 — encode-at-append for AgentMemory** (+ B2 slimmed worker structs). The main
   scalability item: turns per-turn serialization cost from O(N) re-encoding into
   O(new messages); biggest node-throughput win for long conversations.
7. **B3/B4** — precompute invariant prompt/schema/tool artifacts; switch default
   adapter to Jason. Mechanical, low-risk, constant-factor win on every call.
8. Remaining MEDIUMs as touched: single-writer fencing (version/lease on
   turn_state) is the deepest one — worth its own design pass before any
   multi-node deployment is called supported.

## F. Method note

Findings A1-A8, B1-B3, B6 re-verified by coordinator against source. MEDIUM/LOW
items rest on agent-quoted verbatim evidence from full-file reads; treat any
surprising one as a theory to confirm before acting. Nothing here has been fixed;
no tests were run (read-only audit).
