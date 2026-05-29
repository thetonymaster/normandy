# Harness Decomposition for Normandy — Design

- **Date:** 2026-05-29
- **Status:** Approved (design); pending implementation plan
- **Author:** Q
- **Origin:** Comparison of Normandy's agent harness against the iii worker-bus
  architecture (Mike Piccolo, "build your own agent harness").

## Motivation

A production agent harness has ~15 jobs. Frameworks bundle them into one block and
ship one version of each; the cost lands a year in, when the policy engine / approval
surface / credential store / budget tracker you need is not the one the framework
shipped, and replacing it means replacing the harness.

Today Normandy bundles those jobs into a ~1962-line `BaseAgent` recursive loop with
**no injection points** for the production-safety tier. Against the 15-job checklist
Normandy solidly has 4 (system-prompt assembly, streaming, event callbacks, OTel
tracing), has the pieces for 2 more but never wires them (compaction, memory schema),
and is **absent** on: policy checks, human approval, budget tracking, before/after
hooks, durable/branching sessions, skill registry, model catalog.

The lesson taken from iii is **not** "build a WebSocket bus" — the BEAM already gives
us processes, behaviours, registries, and supervision in-process, without the
serialization/latency/failure-domain tax a bus imposes (iii's own latency wins, e.g.
"subscriber-presence cache removes ~500ms," are costs the bus created in the first
place). The lesson is the **decomposition discipline**: every harness layer should be
reachable through a single seam and replaceable behind a contract.

This milestone restructures Normandy's turn into that shape and delivers five
improvements (#1–#5 below) as one coherent architecture.

## Constraints / decisions

- **Scope:** one design (this doc), implementation sequenced into phases.
- **Backward compatibility:** breaking changes are acceptable; cut a new major
  version with a migration guide. `BaseAgent.run/2`, `BaseAgentConfig`, and
  `AgentMemory` may change shape.
- **Turn model:** full virtual-actor — pure FSM core + `:gen_statem` shell +
  passivation + pluggable session registry. This intentionally couples #3
  (suspendable turn) to #5 (persistence): suspended and passivated state live in the
  session store.
- **Default-off principle:** every new behaviour ships a default impl that preserves
  *current* behavior, so the "everything off" path is observably identical to today
  even though the internals are restructured.

## Architecture (the spine)

One restructuring unifies all five features: **the turn becomes a pure FSM core with
one dispatch chokepoint, driven by a swappable process shell, against a set of
pluggable behaviours, over a persisted branching session store.**

```
            ┌──────────────────── shell (swappable) ─────────────────────┐
            │  inline (sync)  │  :gen_statem (interactive/chatbot, passivating)  │
            └──────────────────────────────┬─────────────────────────────┘
                                            │ drives
                               ┌────────────▼─────────────┐
                               │   PURE FSM CORE           │  Turn.step(state, event)
                               │   %TurnState{} (data)     │    -> {state', [effect]}
                               │   7 states                │
                               └────────────┬─────────────┘
                                            │ every tool call flows through
                               ┌────────────▼─────────────┐
                               │   DISPATCH CHOKEPOINT     │  #1
                               │  before→policy→budget→    │
                               │  exec→budget→after        │
                               └────────────┬─────────────┘
                     consults behaviours (#2)│        persists via (#5)
   ┌───────────────┬───────────────┬─────────┴─────┬───────────────┬──────────────┐
CredentialProvider PolicyEngine BudgetTracker  Hooks(before/after) ModelCatalog SessionStore
```

The FSM core is plain data + a `step/2` function — testable without processes,
serializable, restart-safe. The shell is a thin container that owns the mailbox, runs
effects, and (for the gen_statem shell) decides when to passivate. **Durability comes
from persisting `%TurnState{}`, independent of which shell runs it.**

### Why FSM and process are layered, not chosen

FSM (a computation model: states + transitions + effects) and GenServer/process (a
runtime container: mailbox + heap + callbacks) are orthogonal. The real axis is *where
the half-finished turn lives while it waits*: as plain data, or inside a process. The
virtual-actor pattern uses **both** — a pure core (source of truth, serializable) and a
thin process shell (an optimization for the active window). This lets the shell be
chosen per deployment without rewriting turn logic:

| Deployment | Shell |
|---|---|
| Library / scripted run | inline, synchronous |
| Single interactive agent | one `:gen_statem` per turn |
| Chatbot at scale | passivating process per session, state in `SessionStore` |
| Distributed | same shell behind a sharded registry (Registry/Horde/syn) |

`:gen_statem` is the default process shell (over a hand-rolled GenServer) because it
provides, built-in, exactly this shape's needs: **state timeouts** (approval expiry,
5s policy timeout, `max_turns`), **event postponing** (a second user message arriving
mid-turn is queued until a state can handle it), and **state-enter callbacks**
(provisioning/teardown).

## Component designs

### #1 — Dispatch chokepoint

Both current dispatch paths — `execute_one_tool_call/2` (`base_agent.ex:1374`,
non-streaming) and `execute_one_streaming_tool_call/2` (`:1419`, streaming) — collapse
into **one** `dispatch/2` seam. Per tool call, in order:

1. resolve tool (registry miss → denial result)
2. **before-hooks** (may rewrite input or short-circuit)
3. **policy check** → `{:allow, meta} | {:deny, %{reason, rule_id, rationale}} |
   {:needs_approval, %{reason, rationale}}`
   - **deny** → `DenialEnvelope` whose `rationale` is fed back into the model context,
     not just a boolean. (The model learns *why* a constraint exists, so it stops
     reasoning around it as "the exception.")
   - **needs_approval** → park this call; the rest of the batch keeps dispatching.
   - **allow** → proceed.
4. **budget pre-check** (optional gate before spend)
5. **execute** (monitored task)
6. **budget record** (actual usage)
7. **after-hooks** (may redact/transform result)

Events are emitted throughout for the UI/subscriber stream.

**Fail-closed by construction:** if the policy engine times out or is unreachable, the
call is denied with a `gate_unavailable` envelope.

### #2 — Pluggable behaviours

Elixir `@behaviour`s. Each default impl preserves current behavior.

| Behaviour | Callbacks | Default impl |
|---|---|---|
| `Normandy.Behaviours.CredentialProvider` | `get_token(provider, opts)` | static/env; extracts `api_key` out of `ClaudioAdapter` struct |
| `Normandy.Behaviours.PolicyEngine` | `check(call, ctx)` | **allow-all** (back-compat); optional YAML-ruleset impl shipped |
| `Normandy.Behaviours.BudgetTracker` | `check(scope, est)`, `record(scope, usage)` | **no-op** |
| `Normandy.Behaviours.ModelCatalog` | `get/1`, `supports?/2`, `context_window/1` | static catalog absorbing `WindowManager`'s hardcoded limits |

Behaviour selection is **explicit via config** (not implicit last-registration-wins as
in iii's bus) — safer to test and reason about.

### #3 — Suspendable turn (FSM core + shell)

Seven states, mirroring iii's 11→7 collapse:

`:provisioning` → `:assistant_streaming` → `:tool_dispatch` → (`:awaiting_approval`)
→ `:steering` → `:stopped` / `:failed`

- `step(state, event) -> {state', effects}` is pure. Effects are data the shell
  interprets: `{:call_llm, …}`, `{:execute_tool, …}`, `{:emit_event, …}`,
  `{:needs_approval, calls}`, `{:persist, turn_state}`. The core never does I/O.
- **Tools run as monitored tasks**, not blocking `Task.async_stream` + `Enum.map`
  (`base_agent.ex:622-634`). The statem stays responsive while tools run — enabling
  abort and mid-turn messages.
- **Suspend:** core emits `{:needs_approval, calls}`; shell persists `%TurnState{}`
  via `SessionStore` and parks. **Resume:** `step(state, {:approval, decisions})`. The
  non-approved calls in the same batch keep dispatching.
- **Passivation:** the gen_statem shell terminates on idle after persisting state, and
  rehydrates from `SessionStore` on the next message. A pluggable session registry
  maps session_id → live pid (or none).

`AgentProcess` (`coordination/agent_process.ex`) stays as the **session** supervisor;
the new statem is the **turn** engine beneath it.

### #4 — Compaction

`Normandy.Behaviours.Compactor` wraps the existing `WindowManager` strategies
(`:oldest_first | :sliding_window | :summarize`). The FSM invokes it at the
`:steering` turn boundary when `TokenCounter` exceeds
`ModelCatalog.context_window(model)`. Emits a compaction event. This wires up code that
exists today but is never called by the turn loop.

### #5 — Persisted branching session

- `Normandy.Behaviours.SessionStore` callbacks: `append_entry`, `history`,
  `fork(from_entry_id)`, `save_turn_state`, `load_turn_state`.
- `AgentMemory` becomes a **struct** of **parent-linked entries** (`id` + `parent_id`),
  enabling branching / forks / resume instead of a linear prepend list
  (`agent_memory.ex:10-14`).
- Default store: **ETS** (fast, in-node) plus a pure in-memory store for tests;
  **Postgres as a reference impl**. This same store holds suspended-turn and
  passivated-session state for #3.

## Data flow (one turn, with approval)

1. Shell receives turn request → core enters `:provisioning` (assemble system prompt,
   init `%TurnState{}`, persist).
2. `:assistant_streaming` — effect `{:call_llm, …}`; provider streams tokens; shell
   drains and emits `message_update` events.
3. Tool calls present → `:tool_dispatch`; each call runs through the chokepoint (#1).
   `allow` executes as a monitored task; `deny` yields a `DenialEnvelope` with
   rationale; `needs_approval` parks the call.
4. If any call parked → `:awaiting_approval`; shell persists state and (gen_statem
   shell) may passivate. Out of band, a decision arrives → `step(state, {:approval, …})`.
5. Batch complete → `:steering` decides continue / stop / `max_turns`; compaction (#4)
   runs here if the context window is exceeded.
6. continue → back to `:assistant_streaming`; stop/max → `:stopped`
   (emit `agent_end`, free resources). Unexpected throw → `:failed`.

## Error handling

- Policy unreachable/timeout → deny (fail-closed).
- Tool task crash/timeout → error result envelope into memory; turn continues.
- LLM call failure → existing `Retry` + `CircuitBreaker` resilience, unchanged.
- Unexpected handler throw → `:failed` terminal state, surfaces stop reason to the UI.
- Store write failure at a persist point → treated as a hard failure (no silent
  fallback); turn does not proceed past a suspend point it cannot durably record.

## Testing strategy

- **Pure core:** property/unit tests on `Turn.step/2` — every state transition and
  effect list, with no processes. This is the bulk of correctness coverage.
- **Chokepoint:** table-driven tests over allow/deny/needs_approval × hooks × budget,
  including fail-closed timeout behavior.
- **Behaviours:** contract tests each default impl must pass; a fake impl per behaviour
  for injection in turn tests.
- **Shell (gen_statem):** suspend → persist → passivate → rehydrate → resume; mid-turn
  message postponement; tool-task crash isolation.
- **SessionStore:** the same contract test suite run against in-memory, ETS, and
  Postgres impls (branch/fork/resume).
- **Back-compat:** with all behaviours at defaults, existing end-to-end agent tests
  pass unchanged in observable output.

## Phased build order

Dependency-respecting:

1. **Phase 1** — pure FSM core + dispatch chokepoint; inline shell. Behaviours stubbed
   to current behavior.
2. **Phase 2** — the four behaviours with real default impls + before/after hooks.
3. **Phase 3** — `SessionStore` + branching `AgentMemory` struct (#5).
4. **Phase 4** — `:gen_statem` shell + suspend/resume/approval + passivation +
   pluggable registry (#3 full).
5. **Phase 5** — compaction wiring (#4).

## Out of scope (this milestone)

- A skill/prompt registry (iii's `directory::skills::*` on-demand fetch) — noted as an
  absent job but not part of #1–#5.
- A WebSocket/network bus or polyglot workers — explicitly rejected in favor of
  in-process BEAM primitives.
- Distributed multi-node session registry implementation (the registry is *pluggable*;
  shipping a Horde/syn-backed impl is deferred).

## Open questions

- Default `SessionStore` for production: ETS is in-node only; teams wanting
  cross-node/durable sessions need the Postgres reference impl or their own. Confirm ETS
  is an acceptable default vs. shipping Postgres as the default.
- Exact `%TurnState{}` serialization format for persistence (term vs. explicit
  encode/decode) — to be settled in Phase 3/4 planning.
