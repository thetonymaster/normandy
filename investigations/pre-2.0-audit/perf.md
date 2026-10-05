# Normandy 2.0 — Performance & Concurrency Audit (2026-10-04)

Branch `feat/claudio-0.7-migration` @ f7991a9. Read-only: grep/read only, no mix, no tests run.
Baseline: `investigations/performance-race-audit.md` (2026-07-01). 358 commits since 2026-07-15.

Legend: VERIFIED = the code path was read end to end and the failure follows from it.
PLAUSIBLE = mechanism read, but trigger frequency or runtime behaviour not observed.

---

## A. Status of prior HIGH findings (A1–A8) and the big perf items (B1–B3, B5)

| ID | Prior finding | Status | Evidence (current code) |
|---|---|---|---|
| A1 | AgentPool leaks agents (stale waiters, no client monitor, double replacement) | **FIXED** | Waiters monitored and dropped on DOWN (`agent_pool.ex:294-298, 440-445`); checkout clients monitored, auto-checkin on DOWN (`:404-407, 434-437`); agents `restart: :temporary` (`:382-389`); client `GenServer.call(..., :infinity)` with server-side timer (`:196`, `:556-559`); checkin verifies the holder (`:409-421`). Leftover: breakers leak, see PERF-5. |
| A2 | CircuitBreaker wedges in half-open | **PARTIALLY FIXED** | `catch :exit / throw` now records failure (`circuit_breaker.ex:340-349`, commit 2981593). Still missing: (a) no monitor or lease on the half-open slot, so a probe caller **killed** (`:kill`, `Task.shutdown(:brutal_kill)`, `on_timeout: :kill_task`) never releases it, a permanent wedge (PERF-1); (b) admission is still two calls (`:get_state` then `:try_half_open_call`, `:150-166`), and `:try_half_open_call` never checks `state.state` (`:264-271`); (c) no generation tag, so results of calls admitted while closed get counted as probe outcomes (PERF-9). |
| A3 | Dangling `tool_use` across a crash wedges the session | **FIXED** (Turn.Server) | A new turn repairs unanswered calls before admission (`turn/server.ex:559-565`, `Turn.unanswered_tool_calls/1` at `turn.ex:345`). A resume from `:steering` closes the batch (`server.ex:994-1006`) and gives each call an `interrupted: true` error result (`:1010-1021`). |
| A4 | Transient restart replays executed work (stale child args) | **FIXED** | `init/1` always loads memory and turn state from the store (`server.ex:237-265`, `with_stored_memory` at `:443-455`). There is now a catch-all `:info` clause (`:726`), and a store fault at start puts the server in `:unavailable` with retry instead of crashing (`:250-254`). Tier-0/1 still puts `:config` in child args (`session.ex:117-121`), but memory is replaced from the store. Leftover: store **exits** during a turn still crash the statem, see PERF-7. |
| A5 | ParallelOrchestrator: one slow agent kills the orchestration | **FIXED** | `on_timeout: :kill_task, zip_input_on_exit: true` (`parallel_orchestrator.ex:162-175, 295-317`); the exit clause shape now matches (`:189`); `execute_agent` catches exits (`:347-354`). |
| A6 | Batch.Processor missing `on_timeout` | **FIXED** | `processor.ex:143-152` with `:kill_task` + `zip_input_on_exit`; `process_single` catches `:exit` (`:276-281`). |
| A7 | Inline AgentProcess blocks its GenServer for the whole LLM turn | **PARTIALLY FIXED** | The observer crash is fixed: `AgentSupervisor.list_agents` reads the process dictionary instead of calling the agent (`agent_supervisor.ex:136-148`, `agent_process.ex:190-201`). The root cause is unchanged: `:inline` (still the default) runs `BaseAgent.run` inside `handle_call` (`agent_process.ex:397-436`). Retry `Process.sleep` backoff runs there too. `get_agent/get_stats/update_agent/approve` from other processes time out at 5s during a run, and concurrent `run` callers queue behind it. |
| A8 | Wrong schema artifact (`__specification__` encoded) | **FIXED** | Both sites use `Normandy.Schema.json_schema/1` → `__schema__(:specification)` (`schema.ex:264-272`; `base_agent.ex:1383-1394`; `retry_feedback.ex:17, 57`). An encoding failure now raises instead of being silently dropped. |
| B1 | O(N²) history re-serialization | **STILL PRESENT** | On every LLM call: `drop_stale_thinking` walks the full chain (`agent_memory.ex:186-201`), then `history/1` walks it again and runs `BaseIOSchema.to_json` on every message (`:98-113`). That means `Application.get_env` plus a Poison encode for each Map, io_schema and tool-result map/list (`base_io_schema.ex:39-43`, `schema.ex:410-417`, `tool_result.ex:51`). The maps are then rebuilt into `%Message{}` (`base_agent.ex:305-318`). The only change: `BaseAgentInputSchema` chat text is now passed raw (`agent_memory.ex:109-113`). See PERF-3. |
| B2 | Full conversation heap copied into workers | **STILL PRESENT** | `spawn_task` captures `current = data` (whole `%Data{}`: config with `memory` and `initial_memory`, plus `start_opts`, which still holds the caller's original config in Tier 0/1) (`server.ex:1220-1243`). Each tool task in `dispatch/2` and `execute_approved/2` captures `config` again (`:1452-1516`). Same in `BaseAgent.dispatch_turn_tools/2` and `dispatch_stream_tools/3` (`base_agent.ex:752-768, 1183-1200`). |
| B3 | Invariant prompt, schema and tool artifacts rebuilt per call | **STILL PRESENT** | `SystemPromptGenerator.generate_prompt`, `with_output_schema` (pretty JSON encode), `Registry.to_tool_schemas` and now a `phash2` of `{prompt, sorted tools, model}` for `prefix_key`, all on every call (`base_agent.ex:291-303, 1403-1408`; `tool_call_response.ex:43-45`). Structured-output schema translation is still not memoized (`schema_translator.ex:14`). |
| B5 | ETS SessionStore copies the whole memory per append | **STILL PRESENT** | `session_store/ets.ex:77-84`: lookup of the full `%AgentMemory{}`, rebuild, `:ets.insert`, all through one GenServer with a `:private` table. |

Other prior MEDIUM/LOW items re-checked in passing:
- **Fixed:** Retry jitter crash (`retry.ex:292-301`). `Reactive.all` keeps its accumulator (`reactive.ex:206-222`). AgentPool double-checkin, monitor stacking and overflow double-decrement (see A1).
- **Still present:** atom per `:server`-mode AgentProcess (`agent_process.ex:327`). Inline `run_async` (`Task.start`, rescue only, updated memory discarded; `:539-555, 645-655`). Redis fork id `"fork_#{System.unique_integer}"` (`session_store/redis.ex:88`). Redis pipeline in-band errors ignored (`:142-145`). `register_self` discards `{:error, :taken}` (`server.ex:1393-1398`). Passivation window: `Session.run` has no `:noproc` retry (`session.ex:55-57`). No tool deadline (`timeout: :infinity`, `server.ex:1477, 1511`). StatefulContext `get_table` call before every read (`stateful_context.ex:224-227`). `OtelCtx` calls `Code.ensure_loaded?` on each capture/attach (`otel_ctx.ex:43, 69`). Incremental guardrails O(R²) (`base_agent.ex:1580-1596`). `Reactive.race/some` linked `Task.async`, no exit catch on the pid branch, no mailbox drain (`reactive.ex:104-124, 395-407`).

---

## B. New findings

### PERF-1 — HIGH — A killed half-open probe wedges the circuit breaker permanently. VERIFIED
`lib/normandy/resilience/circuit_breaker.ex:150-166, 264-271, 320-350`
```elixir
:half_open ->
  case GenServer.call(server, :try_half_open_call) do
    :allowed -> execute_and_record(server, fun)
...
def handle_call(:try_half_open_call, _from, state) do
  if state.half_open_calls < state.half_open_max_calls do
    {:reply, :allowed, %{state | half_open_calls: state.half_open_calls + 1}}
```
The new `catch` covers exits *raised in* the caller. It does nothing when the caller process is
**killed**. Several paths in the library kill the process that holds the slot:
- `Batch.Processor` and `ParallelOrchestrator` use `on_timeout: :kill_task` (`processor.ex:150`, `parallel_orchestrator.ex:172`).
- `Reactive.race/some` call `Task.shutdown(task, :brutal_kill)` on losers (`reactive.ex:395-403`).
- `Turn.Server` `run_while_server_alive` calls `Process.exit(worker, :kill)` when the server dies (`server.ex:1258`).

The slot counter only resets in `transition_to_open`, in `handle_success/failure` and on manual
`reset/1`. `maybe_transition_to_half_open` only acts from `:open`. Once `half_open_calls ==
half_open_max_calls` (default 1) with no holder alive, every call returns `{:error, :open}`
forever.

**Scenario:** a batch of 500 items runs on one agent, so all items share one breaker. During a
provider outage the breaker opens. After `timeout` the first item becomes the half-open probe.
The provider is still slow, the probe exceeds the per-item timeout (300s default) and is
killed. All remaining items, and every later use of that agent, fail with `:open` until someone
calls `reset/1`. The breaker meant to give automatic recovery instead stays down until a human
intervenes.

**Fix:** `:try_half_open_call` monitors the caller pid and stores `{ref => pid}`; on `:DOWN`,
release the slot (treat it as a failure). Also add a half-open lease timeout. Merge
`:get_state` and `:try_half_open_call` into one atomic `:acquire` that checks `state.state`
(see PERF-9).

### PERF-2 — HIGH (BLOCKER-shaped for 2.0: the fix changes breaker ownership) — Breaker is linked to whichever process called `BaseAgent.init/1`. VERIFIED
`lib/normandy/agents/base_agent.ex:135-143`
```elixir
circuit_breaker =
  if Map.get(config, :enable_circuit_breaker, false) do
    {:ok, cb} = CircuitBreaker.start_link(cb_opts)
```
The breaker is unsupervised and linked to the init caller. Its pid then lives in the config,
which outlives that caller:
- It goes into `Turn.Session` opts and `Turn.Server` `Data.config`.
- The Tier-2 supplement keeps it as a node-local field (`config_template.ex:45`).
- It also travels into `AgentProcess` and DSL agents.

Failure modes:
1. **Init caller exits first.** Example: a Phoenix request or LiveView builds the config and
   starts the session. When that process ends, the breaker dies. Every later LLM call does
   `GenServer.call(dead_pid, :get_state)`. That exits inside the worker, the turn fails with
   `{:task_down, {:noproc, _}}` (`server.ex:633-647`), and **every following turn of that
   session fails the same way** until the server restarts with a fresh config.
2. **Breaker crashes.** It takes the init caller down with it. Inside AgentPool that caller is
   the pool (see PERF-5).

**Fix:** have the library supervise breakers (a DynamicSupervisor plus a Registry keyed by agent
name or model). Store a name in the config, not a pid. Alternatively, keep breaker state in
`:atomics` or ETS with no process at all. Because this changes what `circuit_breaker` holds in
the config and the template, 2.0 is the cheapest time to do it.

### PERF-3 — HIGH — O(N²) conversation re-encoding (prior B1), now also amplified by compaction. VERIFIED
`agent_memory.ex:98-113, 186-201`; `base_io_schema.ex:39-43`; `tool_result.ex:51-60`; `base_agent.ex:291-318`; `behaviours/compactor/window_manager.ex:44-60`; `context/window_manager.ex:110-131, 280-310`
```elixir
def history(%__MODULE__{} = memory) do
  memory |> messages() |> Enum.map(fn %Message{role: role, content: content} ->
    %{role: role, content: model_content(content)} end)   # to_json per message, every call
```
Each LLM call (×k tool iterations per turn) re-encodes every message: tool-result maps and
lists through Poison, and io_schema structs through `__serializable__` plus encode. The
compactor, which now runs before each turn's first call as well as after every tool batch
(commit a873b15), adds more passes:
- `estimate_conversation_tokens` runs `history/1` again, plus `String.length`, which walks
  graphemes over the re-encoded text.
- This happens ≥3 times per boundary: before, inside `ensure_within_limit`, and after.
- Plus two `entry_chain` walks in `dropped_entries`.

**Magnitude (estimate):** take a 300-message session with search tools returning ~5 KB JSON
each (~1.5 MB of content), 5 tool iterations per turn and a compactor enabled. That is
5 × (1 + 3) full encodes ≈ 30 MB of JSON encoding and grapheme scanning per turn, per session.
On Poison that is roughly 100-300 ms of CPU per turn. The cost grows linearly per turn, so
quadratically over a conversation. The LLM call takes seconds, so latency barely moves; the
real cost is node CPU and throughput with many concurrent sessions.

**Fix:** encode content once at append time and cache it on `Entry`. Add a `history` variant
that returns `%Message{}` directly. Keep a running token estimate on the memory, using
`byte_size/1` instead of `String.length`. Resolve the adapter once.

### PERF-4 — HIGH (cluster failover) — `Turn.Server.init/1` does store, network and credential I/O inside the DynamicSupervisor's start_child. VERIFIED
`lib/normandy/agents/turn/server.ex:237-265, 443-455`; `turn/supervisor.ex:41-53`; `turn/resume_reaper.ex:86-106`
```elixir
def init(opts) do
  ...
  case load_session(opts, store, session_id) do   # template load, credential get_token,
                                                  # full history fetch, turn_state load
```
`DynamicSupervisor.start_child` is a synchronous call into one supervisor process, which waits
for `init/1` to return. As a result every session start on a node is serialized behind:
- the template load and the supplement fetch;
- `cred_mod.get_token` (possibly a vault or HTTP call);
- the full `history/2` (XRANGE or SELECT of the whole conversation);
- `load_turn_state`.

The moduledoc already moved `on_session_start` out of init for this exact reason
(`server.ex:367-369`), but loading still happens in init.

**Scenario:** a node dies holding 5,000 eager sessions. Every survivor's `ResumeReaper`, plus
every lazy caller, funnels into `start_child`. At 10-30 ms per init (Postgres or Redis history
plus token fetch), that is a 50-150 s serialized start queue on each node. Callers sit inside
`DynamicSupervisor.start_child` (`:infinity`), so `Session.run` latency spikes for every
session on the node, including healthy new ones. A slow credential provider (2 s) multiplies
this.

**Fix:** return from `init/1` at once in a `:loading` state with `{:next_event, :internal,
:load}`, and postpone `{:turn, _}` calls until the load finishes. The existing `:unavailable`
retry machinery already has this shape.

### PERF-5 — MEDIUM — AgentPool leaks one circuit breaker per overflow agent; a breaker crash kills the pool. VERIFIED
`lib/normandy/coordination/agent_pool.ex:385-400` with `base_agent.ex:135-143`
`start_agent/1` calls `BaseAgent.init(state.agent_config)` **inside the pool process**, so with
`enable_circuit_breaker: true` each breaker is `start_link`ed to the pool. `stop_agent/2`
terminates the AgentProcess but never the breaker.

**Scenario:** a pool with `max_overflow: 5` under bursty load creates and destroys overflow
agents continuously. Each cycle leaks one GenServer (a few KB plus an idle process). At one
overflow cycle per second that is ~86k leaked processes per day, against the default
262,144-process limit. Separately, any breaker crash exits the pool through the link.

**Fix:** PERF-2's supervised breakers, or stop the agent's breaker in `stop_agent/2` and
`handle_agent_death/2`.

### PERF-6 — MEDIUM — Redis SessionRegistry: one GenServer per node on the hot path, with synchronous Redis I/O and sequential refresh. VERIFIED
`lib/normandy/behaviours/session_registry/redis.ex:29-35, 89-128, 158-163`
```elixir
def whereis(owner, session_id), do: GenServer.call(owner, {:whereis, session_id})   # default 5s
...
def handle_info(:refresh, s) do
  Enum.each(s.sids, fn {sid, {pid, _ref}} -> pexpire_if_owner(...) end)   # one EVAL per session
```
Every `Turn.Session.run` and `approve` calls `whereis`, which goes through this single process
doing a blocking Redis round trip. Every `ttl/2` (30 s), the same process sends one `EVAL` per
live session, sequentially, with the full script text each time (no EVALSHA). While refresh
runs, all `whereis` calls queue.

**Magnitude:** with 10k live sessions at a 0.5 ms RTT, refresh blocks for about 5 s, which
equals the default `GenServer.call` timeout. `whereis` callers then exit, so `Session.run`
crashes in the caller. Above about 60k sessions the refresh outlasts the TTL, keys lapse, and
duplicate servers start (the split-brain item from the prior MEDIUM list). Routing throughput
is capped at about 1/RTT per node, roughly 2k lookups/s, and the connection is shared with the
session store (`cluster.ex:76-90`).

**Fix:** do `whereis` in the caller: a direct `GET` on a shared or pooled Redix connection, plus
pid decoding. Refresh with one pipelined or Lua batch (or a TTL'd hash per node), using
EVALSHA. Act on a `0` return from `pexpire_if_owner`, which means ownership was lost.

### PERF-7 — MEDIUM — Store exits (timeouts) inside Turn.Server callbacks are not caught. VERIFIED (path) / PLAUSIBLE (frequency)
`lib/normandy/agents/turn/server.ex:1083-1095, 1097-1101, 1150-1158, 1406-1424`
`append_to_store/5` and `persist_turn_state/2` call the store directly. Only the *handler*
part of `{:append_message, ...}` runs under `call_handler`. ETS and InMemory stores are
`GenServer.call`/`Agent` with a 5 s default timeout; Redis is `Redix.command` with a 5 s
default.

A timeout exits the gen_statem in the middle of a turn. The caller gets an exit out of
`:gen_statem.call(..., :infinity)` instead of `{:error, {:persist_failed, _}}`. The server
transient-restarts, which is safe since A4 was fixed, but restarts count against the
supervisor limit shared by all sessions (100 in 5 s, `supervisor.ex:19-20`). A store stall long
enough to time out 100 sessions within 5 s takes down **every session** on the supervisor.

**Fix:** wrap the store calls in `try ... catch :exit, r -> {:error, {:store_exit, r}}`. That
feeds the existing `fail(data, {:persist_failed, _})` path. (The MemoryStore tool already does
this, `commands.ex:451-458`.)

### PERF-8 — MEDIUM — The eager-resume set and session data grow forever; every `:nodedown` scans all eager sessions ever created. VERIFIED
`resume_reaper.ex:86-106`; `session_store/redis.ex:131-139, 160-166`; `session_store/postgres.ex:181-189`; `session_store/ets.ex:145-156`; behaviour `session_store.ex:35-55` (no delete or expiry callback)

`list_resumable` returns every session whose template was saved `:eager`. Nothing removes a
session from that set when its turn ends. Redis `SREM` only happens when a template is
re-saved as lazy, and there is no session delete callback in the behaviour at all. On each
`:nodedown`, every surviving node's reaper does a sequential `whereis` plus `load_turn_state`
for **each** id, inside its single GenServer. On Redis the `SMEMBERS` reply itself is O(N)
and blocking.

**Magnitude:** after 1M eager sessions over a few months, one node loss means about 2M store
round trips per surviving node (minutes of work) to find the few hundred sessions that were
actually in flight. Meanwhile ETS, InMemory and Mnesia SessionStores keep every conversation
in RAM forever.

**Fix:** remove a session from the resumable index when it reaches a terminal state, or index
only non-terminal sessions. Add `delete_session/2` (retention/erasure) to the behaviour.
Parallelize or batch the reap.

### PERF-9 — MEDIUM — Breaker admission races and stale results. VERIFIED
`circuit_breaker.ex:150-166, 264-271, 352-416`
1. `call/2` reads `:half_open` and then calls `:try_half_open_call`. In between, another
   caller's failure can reopen the breaker, which resets `half_open_calls` to 0. The admission
   then succeeds while the state is `:open`, so a call goes through an open circuit.
2. A call admitted while `:closed` that finishes after the breaker went open and then half-open
   is counted as a probe result. `handle_success` in `:half_open` decrements the slot it never
   took and can close the circuit off one pre-outage success. A late failure reopens it.

The effect is flapping under concurrency: with N concurrent slow calls during an outage, up to
N stale outcomes land in half-open.

**Fix:** a single atomic `:acquire` returning `{:ok, token}`, where the token carries the state
generation (a counter bumped on every transition). `record_*` ignores results whose generation
no longer matches.

### PERF-10 — MEDIUM — MemoryStore ETS/Mnesia keep one row per namespace, so every read and write copies the whole namespace. VERIFIED
`behaviours/memory_store/ets.ex:19-24, 50-54, 61-66`; `behaviours/memory_store/mnesia.ex:56-87`
```elixir
def get({_pid, table}, ns, path), do: Docs.get(docs(table, ns), path)   # copies ALL docs out of ETS
```
`:ets.lookup` copies the whole `%{path => doc}` map, contents included, into the caller to
read one document. A `create` command does about 4 + depth store calls (`not_directory` list,
one `get` per ancestor, `others_bytes` list, then the put). Each copies the namespace; the
put copies it in and out of the owner and back into ETS. Mnesia `disc_copies` writes the
**entire namespace** to the transaction log, and replicates it to every replica, on each
`str_replace`.

**Magnitude:** at the default 1 MB cap, one `create` at depth 3 copies about 7 MB on ETS. On
Mnesia, each edit is a 1 MB disc-log write per replica, so 100 edits per minute is about
100 MB/min of log on each replica. With `max_namespace_bytes: nil` there is no upper bound.

**Fix:** use one row per `{namespace, path}` (ETS `:ordered_set` gives prefix scans for
`list`). In Mnesia, use a `{ns, path}` key with a namespace index, or a `bag`.

### PERF-11 — MEDIUM — The memory tool's namespace byte cap is bypassable and racy. VERIFIED
`lib/normandy/tools/memory/commands.ex:432-455, 102-122, 219-247`; `memory_store.ex:46-50`
```elixir
defp others_bytes(tool, loc, nil) do
  case store(tool, :list, [loc.namespace, @root]) do          # list/3 returns at most 1000 entries
    {:ok, entries} -> {:ok, entries |> Enum.reject(...) |> Enum.map(& &1.size) |> Enum.sum()}
```
1. **Undercount.** `list/3` is capped at `list_limit/0` = 1000 entries, sorted by path. Once a
   namespace holds more than 1000 documents, the bytes of documents past the page are never
   counted. A model, or a prompt-injected tool loop, that writes many small files grows the
   namespace without bound. That feeds PERF-10's whole-namespace copies and Redis Lua
   `delete_namespace`/`delete_tree` loops that block the Redis server for their whole duration.
2. **Check-then-act.** The cap check, `not_directory`/`not_under_file` and the put are separate
   store calls. Concurrent writers (`max_tool_concurrency > 1`, or two sessions sharing a
   per-user namespace) can each pass the cap and together exceed it. They can also leave a file
   and a directory at the same path. Lower impact.

**Fix:** maintain a per-namespace byte counter that the store updates atomically inside the
write (in the Lua script, the SQL statement or the owner process). Make the cap a store-side
precondition of `put`.

### PERF-12 — MEDIUM — Redis SessionStore `WAIT` stalls the shared connection for every session. VERIFIED (Redis semantics: WAIT blocks the issuing client)
`lib/normandy/behaviours/session_store/redis.ex:56-68, 187-210`; `cluster.ex:76-90` (one Redix connection for store and registry)

With `wait: {n, t}` configured, each `append_entry`, `save_turn_state` and template save issues
`WAIT n t` on the single shared connection. Redis blocks that client until the replicas
acknowledge or `t` expires, and all later pipelined commands queue behind it: other sessions'
appends, and the registry's `whereis`/refresh (PERF-6). The code guards against `t = 0` but not
against a positive `t`.

**Magnitude:** with a lagging replica and `t = 100 ms`, the node-wide ceiling drops to about
10 appends/s. Registry calls queue past 5 s and `Session.run` calls exit.

**Fix:** issue `WAIT` on a dedicated connection pool, or batch it once per boundary instead of
once per append. Document that `wait:` needs a non-shared connection.

### PERF-13 — LOW — `AgentProcess.run` default 60 s call timeout is shorter than realistic turns. VERIFIED
`agent_process.ex:117-119` (`timeout` default 60_000)

A multi-tool turn with retries (`max_delay` 32 s) or extended thinking easily goes past 60 s.
The caller exits while the agent keeps working, and in `:inline` mode it also blocks every
queued caller (A7). Reactive/Workflow pid branches inherit this (`reactive.ex:415-418`).

**Fix:** default to `:infinity` with an explicit turn deadline, or route inline runs through
`spawn_run` like `:server` mode (this also fixes A7).

### PERF-14 — LOW — Reactive race/some: a dead contestant kills the caller; stale results stay in the caller's mailbox. VERIFIED
`reactive.ex:104-124, 395-418`

`Task.async` is linked. On the pid branch, `AgentProcess.run` exits (timeout or `:noproc`) and
the exit is not caught. On the struct branch, `BaseAgent.run` is rescued but exits are not
caught. Either way the task dies and its link kills the caller, so one dead contestant aborts
the whole race. `{ref, agent_id, result}` messages sent by losers before `Task.shutdown` are
never drained, so they pile up in a long-lived caller. The brutal kill of losers is also one of
the PERF-1 triggers when contestants share a breaker.

**Fix:** use `Task.Supervisor.async_nolink`, or `catch :exit` in `execute_agent`. After the
loop, flush `{^ref, _, _}` messages.

### PERF-15 — LOW — `AgentMemory.delete_turn/2` is O(N × depth). VERIFIED
`agent_memory.ex:157-173`: `after_deleted?/3` recurses to the root for every entry, which is
O(N²) on a linear chain. That is about 1M steps at 1,000 entries. Rare operation; mention only.

### PERF-16 — LOW — `OtelCtx` probes the code server on every capture and attach when OTel is absent (prior B7, now ~38 call sites). PLAUSIBLE
`telemetry/otel_ctx.ex:43, 69, 89, 109, 135`

`Code.ensure_loaded?(OpenTelemetry.Ctx)` with no OTel installed is a `code_server` call each
time; in interactive mode it also searches the code path. It runs on every run, tool batch,
Turn.Server task spawn, Reactive/Batch fan-out and A2A call, all funnelling into one
node-wide singleton.

**Fix:** probe once into `:persistent_term` at first use.

### Items checked and found OK (do not re-flag)
- **Hooks runner:** pure, runs in the caller, `Code.ensure_loaded?` on already-loaded modules takes the fast path, and `Hooks.Context` carries no memory or config. In Turn.Server, `before_llm`/`after_compact` run in the worker task. `on_prompt`/`on_turn_end`/`on_passivate` run in the statem with no timeout, which is the documented design; a slow hook stalls only its own session.
- **Turn.Server batching:** `Turn.State` is bounded and does not grow with history. Tool `Task.async_stream` uses `:kill_task`. The worker is killed when the server dies (`server.ex:1250-1260`).
- **Postgres MemoryStore:** CAS by conditional UPDATE, rename locks rows in a stable order (`postgres.ex:190-212`), and `list` returns sizes only (`octet_length`), not contents.
- **Redis MemoryStore:** all writes are atomic Lua scripts, namespaces are base64-encoded into the hash tag, and `list` uses `HSTRLEN` instead of shipping content.
- **KilledRun marks** use `:atomics`, which are GC'd, so there is no ETS leak. No new `:telemetry.attach` in `lib/` (only a doc example). No new LLM-controlled `String.to_atom`; the remaining calls are bounded by developer input (`hierarchical_coordinator.ex:295`, `workflow.ex:558`, registry `unique_name`).

---

## C. Suggested order for 2.0
1. **PERF-2 + PERF-1 + PERF-9:** supervised, monitored breaker with atomic acquire and generation tags. This is one redesign, and the API shape changes, so it belongs in 2.0.
2. **PERF-4:** async load in `Turn.Server` (`:loading` state). Small and contained, with a large failover win.
3. **PERF-7:** catch store exits (a few lines).
4. **PERF-3 (B1) + B2:** encode at append, slim worker closures. The main throughput item.
5. **PERF-8, PERF-6, PERF-12:** cluster-scale hygiene (resumable pruning, caller-side Redis lookups, no WAIT on the shared connection).
6. **PERF-10/11:** memory store row layout plus an atomic byte counter (row layout is a storage-format change, so cheaper before 2.0 ships durable Mnesia data).
7. **A7 / PERF-13**, then the LOWs.
