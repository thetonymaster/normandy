# Phase 6 — `AgentProcess` → Durable Turn Engine Integration

**Status:** Design approved, ready for planning
**Date:** 2026-06-17
**Parent:** `docs/superpowers/specs/2026-05-29-harness-decomposition-design.md`
**Predecessors:** Phase 1a–1d, Phase 2 (pluggable behaviours), Phase 3 (SessionStore +
branching `AgentMemory`), Phase 4a/4b (`:gen_statem` `Turn.Server` + suspend/resume/
approval + passivation + `SessionRegistry`), Phase 5 (compaction wiring) — merged in
PRs #24, #25, #27, #28, #29, #30, #31, #32.

## Goal

Close the milestone's final gap (#6 in the parent design's build order): make the
**coordination layer route through the durable turn engine**. `AgentProcess` gains an
opt-in `:server` mode that drives turns through `Turn.Session`/`Turn.Server` — gaining
approval parking, passivation, and persistence — while its default `:inline` mode
(`BaseAgent.run/2`) stays **byte-for-byte unchanged**.

This realizes the parent design's end-state phrasing — *"`AgentProcess` stays as the
session supervisor; the new statem is the turn engine beneath it"* — without a forced
cutover.

## Non-Goals (this phase)

- **No cutover.** `:inline` remains the default. `coordination/agent_process.ex`'s
  current `BaseAgent.run/2` path is preserved verbatim; the existing
  `test/coordination/agent_process_test.exs` is the parity oracle.
- **No changes to `AgentPool` / `Reactive` / `AgentSupervisor`.** They construct
  `AgentProcess` without `:turn_engine`, so they get `:inline` and are untouched. They
  may opt in later by passing `turn_engine: :server` + infra opts.
- **No streaming `Turn.Server`.** Still deferred (Phase 4 Non-Goal). `:server` mode is
  non-streaming — which matches `AgentProcess`'s current non-streaming `run` (it
  extracts the final `chat_message` and exposes no subscriber), so the observable
  contract is preserved.
- **No new `Turn.Server`/`Turn.Session`/core behaviour.** Phase 6 is a coordination-layer
  adapter over the Phase 4b engine. The pure `Turn` core, `Dispatch`, the chokepoint,
  and the session machinery are consumed as-is, not modified.
- **No distributed registry / no Postgres store.** Inherited deferrals; `:server` mode
  uses the shipped `Native` registry + `InMemory`/`ETS` stores.

## Key Insight

Phase 4b already built the durable engine *and its router*. `Turn.Session.run/2` does
`whereis → route | rehydrate-and-start-under-supervisor`, and `Turn.Session.approve/2`
delivers out-of-band approval decisions. So Phase 6 adds **no engine code** — it makes
`AgentProcess` a thin, stateful façade in front of that router:

- `AgentProcess` is the **stable session identity** (a long-lived, named, supervised
  GenServer with `agent_id`, stats, and the run/cast/approve API).
- `Turn.Server` is the **turn engine beneath it** — started on demand by the router,
  passivated between turns, rehydrated from the store on the next message.

The single non-trivial mechanical change is that **`run` must stop blocking the
GenServer**. Today `handle_call({:run, …})` runs the turn synchronously inside the
callback. In `:server` mode a turn can *park* (suspend awaiting human approval); if the
GenServer blocked on it, it could neither answer `approve` nor any other call until the
approval timeout fired. So `:server`-mode `run` delegates the turn to a `Task` and
replies via `GenServer.reply/2` when the Task returns — keeping the GenServer responsive
while a turn is parked.

## How approval + non-blocking `run` compose

This is the load-bearing interaction, so it is stated explicitly:

1. `:server`-mode `run` spawns a `Task` that calls `Turn.Session.run(opts, input)`
   (a synchronous `:gen_statem.call` with `:infinity` timeout). The Task blocks there;
   the AgentProcess GenServer returns `{:noreply, …}` and stays responsive.
2. If a tool call's policy verdict is `:needs_approval`, `Turn.Server` parks in
   `:awaiting_approval`. The Task's `Turn.Session.run` call is **still suspended** —
   `Turn.Server.run/2` only replies when the turn finalizes or fails.
3. A separate `AgentProcess.approve(pid, decisions)` call reaches the GenServer (it is
   free), which forwards to `Turn.Session.approve(opts, decisions)`. The router resolves
   the **same** `Turn.Server` pid via the registry and casts the decisions to it.
4. `Turn.Server` resumes, runs the approved calls, and eventually finalizes → replies to
   the held `Turn.Session.run` call → the Task returns its result → AgentProcess's
   `handle_info` replies to the original `run` caller via the stashed `from`.

With the default allow-all policy nothing ever parks, so the Task simply runs to
completion and replies — observably identical to a synchronous run.

## Architecture

### Module layout

```
MODIFIED:
  lib/normandy/coordination/agent_process.ex   # +:turn_engine mode, +approve/2,
                                               #   non-blocking :server run/cast,
                                               #   store-authoritative get_agent/update_agent

NEW:
  (none — Phase 6 reuses Turn.Session / Turn.Server / Turn.Supervisor /
   SessionRegistry.Native / SessionStore.{InMemory,ETS} unchanged)
```

No new modules. All new surface lands in `agent_process.ex` plus its test file.

### Decision 1 — Mode selection (`:turn_engine`, default-off)

`start_link/1` accepts `:turn_engine` ∈ `{:inline, :server}`, default `:inline`,
stored in state. Every `:server` behaviour is gated behind this flag via a second
`handle_call`/`handle_cast` clause; the `:inline` clauses are the **current code,
unchanged**. A caller that passes no `:turn_engine` gets today's behavior exactly.

### Decision 2 — `:server`-mode state & wiring

`:server` mode routes through `Turn.Session`, which needs `session_id`, `config`,
`store`, `registry`, `supervisor`. AgentProcess state gains (all `nil`/empty in
`:inline`):

| State field | Meaning in `:server` mode |
|---|---|
| `turn_engine` | `:inline \| :server` |
| `agent` | the `%BaseAgentConfig{}` **template** (client/model/behaviours/tools/`memory` cap). Re-supplied to `Turn.Session` each turn. **Not** the live-memory source of truth. |
| `agent_id` | reused as `session_id` (no new identity; UUID default or caller-supplied) |
| `store` | `{module, handle}` — supplied via opts, or owned (see below) |
| `registry` | `{module, handle}` — supplied via opts, or owned |
| `supervisor` | `Turn.Supervisor` ref — supplied via opts, or owned |
| `pending_runs` | `%{task_ref => from}` — outstanding non-blocking `run` callers awaiting `GenServer.reply` |

`session_opts(state)` builds the keyword list `Turn.Session.run/approve` expect:
`[session_id: agent_id, config: agent, store: store, registry: registry, supervisor: supervisor]`.

**Infra ownership.** The library ships no application supervision tree (callers wire
their own), and `SessionRegistry.Native.new/0`, `SessionStore.InMemory.new/0`, and
`Turn.Supervisor.start_link/1` each start a process. So in `:server` mode:

- If `:store`/`:registry`/`:supervisor` are passed to `start_link`, AgentProcess uses
  them (shared/production deployments, ETS/Postgres, a shared supervisor).
- If any are **omitted**, AgentProcess **starts and owns** the defaults at `init`
  (`InMemory` store, `Native` registry, a `Turn.Supervisor`), **linked** to itself, so a
  self-contained durable agent works out of the box and the owned infra terminates with
  the process. A start failure at `init` is a hard `{:stop, reason}` — no silent
  fallback (per the milestone's "no silent fallbacks" rule).

### Decision 3 — API behaviour by mode

| Function | `:inline` (unchanged) | `:server` |
|---|---|---|
| `run/3` | blocks in `handle_call`; replies inline | **non-blocking**: spawn a monitored `Task` → `Turn.Session.run`; stash `task_ref → from` in `pending_runs`; `handle_info({ref, result}, …)` updates stats and `GenServer.reply(from, result)`. A `:DOWN` for the ref replies `{:error, {:task_down, reason}}`. |
| `cast/3` | `Task.start` → `BaseAgent.run` → `reply_to` | `Task.start` → `Turn.Session.run` → `reply_to` (branch inside the async runner only) |
| `approve/2` **(new)** | `{:error, :inline_mode}` | `Turn.Session.approve(session_opts, decisions)` → `:ok \| {:error, :no_session}` |
| `get_agent/1` | returns `state.agent` | **store-authoritative reconstruct**: read `SessionStore.history(store, agent_id)`, rebuild `%{AgentMemory.from_entries(entries) \| max_messages: state.agent.memory.max_messages}`, return `%{state.agent \| memory: rebuilt}`. A `{:error, _}` from `history` → `Logger.warning` + return the template unchanged (memory not refreshed). |
| `update_agent/2` | applies fn to `state.agent` | applies fn to the **template**; if the result's `memory` differs from the current template's, the memory change is **discarded + warned** (the store is authoritative); the rest of the config takes effect on the next turn |
| `get_id/1`, `get_stats/1`, `stop/1` | unchanged | unchanged (stats still tracked: `run_count`, `last_run`, `total_runtime_ms`) |

`run/3`'s caller-facing return shape is preserved: `{:ok, result} | {:error, reason}`,
where `:server` errors are `Turn.Session`'s `{:error, reason}` tuples (same `{:error, _}`
family as `:inline`'s `{:error, {:exception, …}}`).

### Decision 4 — Policy spectrum (configured by the caller, not AgentProcess)

Policy lives at `config.behaviours.policy` (a `{module, opts}` ref; default
`{PolicyEngine.AllowAll, []}`, and `behaviours: nil` also yields the allow-all
pipeline). It is consumed at the chokepoint via `BaseAgent.base_agent_pipeline/1 →
Behaviours.Config.to_pipeline/1`. In `:server` mode AgentProcess re-supplies that same
`config` template each turn, so the caller's policy flows through **unchanged** —
AgentProcess is policy-agnostic. The two ends that matter for Phase 6:

- **No policy / allow-all** (default): nothing ever returns `:needs_approval` → no turn
  parks → `:server` behaves like `:inline` for ordinary callers.
- **Always-approval**: `{PolicyEngine.Ruleset, [rules: [%{match: "*", action:
  :require_approval, …}]]}` (or `[default_action: :require_approval]`) → every tool call
  parks. This is the configuration the approval test uses.

## Data flow

### A — `:server` turn, no approval (default policy)

1. `AgentProcess.run(pid, input)` → `handle_call({:run, input}, from, %{turn_engine:
   :server})` → spawn `Task` (`Turn.Session.run(session_opts, input)`); stash
   `ref → from`; `{:noreply, …}`.
2. Router: registry `:none` → rehydrate (no prior state) → start `Turn.Server` under
   the supervisor → register → run the turn (LLM, tool dispatch through the chokepoint,
   all allowed) → finalize → reply to the Task.
3. Task returns `{:ok, result}` → `handle_info({ref, …})` → update stats →
   `GenServer.reply(from, {:ok, result})`. The GenServer was responsive throughout.

### B — `:server` turn with approval (always-approval policy)

1–2. As above, but a tool call's verdict is `:needs_approval` → `Turn.Server` parks
   (`:awaiting_approval`), persists `%Turn.State{}`, holds already-run results. The
   Task's `Turn.Session.run` call stays suspended.
3. Out of band: `AgentProcess.approve(pid, %{call_id => :approve})` →
   `handle_call({:approve, …})` (GenServer is free) → `Turn.Session.approve` → registry
   resolves the live `Turn.Server` pid → cast decisions.
4. `Turn.Server` resumes → runs approved calls → merges/reorders results → continues to
   the next LLM call → finalizes → replies to the held `Turn.Session.run` call → Task
   returns → AgentProcess replies to the original `run` caller.

### C — passivation between turns

After a turn finalizes, `Turn.Server` is idle; on its idle timeout it persists final
state and `{:stop, :normal}` (the registry auto-unregisters). The AgentProcess keeps
living (it is the durable identity). The next `run` → router `:none` → rehydrate turn
state + memory from the store with the **caller-supplied** `config` → continue the
conversation.

## Error handling

- **Infra start failure** (`:server`, owned infra) at `init` → `{:stop, reason}`.
- **`Turn.Session.run` `{:error, reason}`** → `run` returns `{:error, reason}`.
- **Run `Task` crash** → monitored; `:DOWN` → reply `{:error, {:task_down, reason}}` to
  the stashed `from` (parity with `:inline`'s rescue-to-`{:error, …}`).
- **Parked turn → approval timeout** → `Turn.Server` fail-closed all-reject →
  finalizes/returns that result as the `run` result.
- **`approve` with no live session** → `{:error, :no_session}` (`Turn.Session`'s
  existing contract). **`approve` in `:inline`** → `{:error, :inline_mode}`.
- **`get_agent` store fault** → log + return the template (memory not refreshed); does
  not crash the GenServer.
- **`update_agent` memory mutation in `:server`** → discarded + warned (store is
  authoritative).

## Testing strategy

- **Back-compat (the oracle):** the full existing suite passes; `agent_process_test.exs`
  (`:inline`) is unchanged — proves default-off is byte-identical.
- **`:server` round-trip:** `run` through `Turn.Session` + `InMemory` store + `Native`
  registry + a fake LLM client; assert `{:ok, result}`, stats incremented, and
  `get_agent` reflects the conversation (memory reconstructed from the store) after the
  turn.
- **`update_agent` semantics:** a non-memory change (e.g. `temperature`) takes effect on
  the next turn; a memory mutation is discarded + warned.
- **`cast` (async):** result delivered to `reply_to` as `{:agent_result, agent_id,
  result}`.
- **Approval round-trip:** `config.behaviours.policy = {PolicyEngine.Ruleset, [rules:
  [%{match: "*", action: :require_approval}]]}` → `run` parks; assert the GenServer
  stays responsive (`get_stats` returns while parked); `approve(pid, %{id => :approve})`
  resumes; the original `run` caller receives the final `{:ok, result}`.
- **Self-contained infra:** `:server` with no infra opts starts+owns store/registry/
  supervisor; assert they are alive while the process runs and terminate when it stops.
- **Gates (every commit):** `mix format` → `mix compile --warnings-as-errors --force`
  (clean) → `mix test` (full suite green).

## Versioning

Phase 6 is the milestone's **final phase**, and the Phase 4 design reserved `1.0.0` for
it. Phase 6 cuts **`1.0.0`** with a CHANGELOG note describing `:server` mode, `approve/2`,
the non-blocking `run`, and store-authoritative `get_agent`/`update_agent`. The change is
additive and default-off, so no breaking-migration is required; the CHANGELOG includes a
short "opting into the durable turn engine via `AgentProcess`" guide.

> **Verify during planning (do not assert):** `mix.exs` is `0.9.0` even though Phase 5
> (compaction, #32) shipped. Either Phase 5 omitted a bump (a defect to correct) or it
> folded into `0.9.0`. Reconcile this before tagging `1.0.0`.

## Deliverables

1. `agent_process.ex`: `:turn_engine` mode (`:inline` default); `:server` state fields +
   `session_opts/1`; owned-vs-supplied infra at `init` with hard-fail on start error.
2. Non-blocking `:server` `run/3` (Task + `pending_runs` + `handle_info` reply + `:DOWN`
   handling); `:server` `cast/3`; new `approve/2` (`:server` pass-through, `:inline`
   error).
3. Store-authoritative `get_agent/1` (reconstruct from `SessionStore.history`);
   `update_agent/2` template-only with memory-mutation discard+warn.
4. Tests per the strategy above; full suite green; compile clean (`--warnings-as-errors`).
5. CHANGELOG note + `1.0.0` version cut (after reconciling the `0.9.0`/Phase-5 gap).
