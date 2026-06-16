# Phase 4 — `:gen_statem` Turn Shell + Suspend/Resume/Approval + Passivation

**Status:** Design approved, ready for planning
**Date:** 2026-06-15
**Parent:** `docs/superpowers/specs/2026-05-29-harness-decomposition-design.md`
**Predecessors:** Phase 1a–1d (dispatch chokepoint, pure Turn FSM, non-streaming +
streaming cutover), Phase 2 (pluggable behaviours), Phase 3 (SessionStore +
branching `AgentMemory`) — merged in PRs #24, #25, #27, #28.

## Goal

Deliver the full virtual-actor turn engine (#3 in the parent design): a
`:gen_statem` process shell (`Turn.Server`) that drives the pure `Turn` FSM core
asynchronously, with **real human-approval parking** (suspend → persist → resume),
**passivation** (terminate on idle, rehydrate on next message), and a **pluggable
session registry** (`session_id → live pid | none`).

`Turn.Server` ships as a **new, opt-in shell**. `BaseAgent.run/2`'s synchronous
inline-`Driver` path is untouched, so the existing end-to-end suite is the parity
oracle for everything except the new modules.

## Non-Goals (this phase)

- **No cutover of `BaseAgent.run/2`.** The inline `Driver` shell remains the
  library/scripted path. `Turn.Server` is additive (parent design's deployment
  table: inline for library runs, `:gen_statem` for interactive/chatbot).
- **No `AgentProcess` integration.** `coordination/agent_process.ex` is untouched;
  wiring it to own/route through `Turn.Server` is **deferred to Phase 6** (now
  registered in the parent design's build order + Out-of-scope).
- **No distributed registry.** Ship `SessionRegistry` + a `Native` (Elixir
  `Registry`) default; Horde/syn impls stay deferred.
- **No Postgres store / no custom serializer.** Turn state persists as an opaque
  Erlang term via the existing `InMemory`/`ETS` stores (which hold terms directly).
  Explicit encode/decode rides along with the deferred Postgres impl.
- **No streaming `Turn.Server`.** This phase's `Turn.Server` interprets the
  **non-streaming** effect set (the streaming shell stays the inline `Driver` +
  `streaming_handlers/1`). A streaming `Turn.Server` is future work.
- **No compaction.** That is Phase 5 at the `:steering` boundary.

## Key Insight

The pure `Turn.step/2` already encodes every turn transition and is property-tested
(`turn_test.exs`, `turn_property_test.exs`). Phase 4 keeps it the **single source
of truth**: `Turn.Server` is a *second interpreter* of the same core — the
asynchronous analog of the synchronous `Driver`. The `Driver`'s own moduledoc
anticipates this: "one driver serve[s] … different handler sets … (and future
shells)."

So the turn **logic** is not duplicated. What `Turn.Server` adds over `Driver` is
exactly the process-shell concerns the parent design names: monitored Tasks for
blocking effects, a mailbox (mid-turn message postponement), `state_timeout`s
(approval expiry, passivation idle), persistence at suspend points, and
rehydration. Its `:gen_statem` states are **coarse lifecycle states** (`:running`,
`:awaiting_approval`, `:idle`) used only to hang timeouts and continuations off of
— they are *not* a re-encoding of the seven `Turn.State` statuses.

Real approval parking requires the shell to learn a tool call's policy verdict
**before** executing it. Phase 1a's chokepoint computes the verdict mid-pipeline
but, on `:needs_approval`, collapses it to a denial `ToolResult` (Phase 2 called
real parking "Phase 4"). Phase 4 splits the chokepoint into `classify` (verdict)
and `execute` (run) so the shell can act on the verdict, while `dispatch_one/3`
stays behaviorally identical (`= classify ➞ execute`) for the inline path.

## Architecture

### Module layout

```
MODIFIED:
  lib/normandy/agents/turn.ex          # +:awaiting_approval clauses, +2 State fields
  lib/normandy/agents/dispatch.ex      # +classify/3, +execute/4; dispatch_one/3 = classify ➞ execute
  lib/normandy/behaviours/config.ex    # +session_registry slot (default {SessionRegistry.Native, []})

NEW:
  lib/normandy/agents/turn/server.ex            # the :gen_statem shell (async interpreter)
  lib/normandy/agents/turn/session.ex           # router: whereis → route | rehydrate
  lib/normandy/agents/turn/supervisor.ex        # DynamicSupervisor for Turn.Server processes
  lib/normandy/behaviours/session_registry.ex   # behaviour: whereis/register/unregister
  lib/normandy/behaviours/session_registry/native.ex   # default, wraps Elixir Registry
```

### Decision 1 — Chokepoint split: `classify` + `execute` (`dispatch.ex`)

`dispatch_one/3` is **re-expressed**, not rewritten — its observable behavior is
byte-identical, with the existing `dispatch_test.exs` as the parity oracle.

```elixir
# classify: registry → before-hooks → policy. No execution.
@spec classify(map(), ToolCall.t() | map(), Pipeline.t()) ::
        {:execute, prepared :: struct(), ToolCall.t()}
        | {:deny, ToolResult.t()}
        | {:needs_approval, prepared :: struct(), ToolCall.t(), info :: map()}
def classify(config, tool_call, pipeline) do
  call = normalize(tool_call)
  case Registry.get(config.tool_registry, call.name) do
    :error -> {:deny, not_found_result(call)}
    {:ok, tool} ->
      case run_before_hooks(config, call, pipeline.before_hooks) do
        {:halt, %ToolResult{} = r} -> {:deny, r}
        {:cont, call} ->
          prepared = prepare_tool(tool, call.input)
          case pipeline.policy_fn.(config, call, prepared) do
            {:allow, _meta}        -> {:execute, prepared, call}
            {:deny, info}          -> {:deny, denial_result(call, info, false)}
            {:needs_approval, info}-> {:needs_approval, prepared, call, info}
          end
      end
  end
end

# execute: budget pre-check → execute → budget record → after-hooks.
@spec execute(map(), prepared :: struct(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
def execute(config, prepared, call, pipeline) do
  case pipeline.budget_check_fn.(config, call) do
    {:error, reason} -> budget_denial_result(call, reason)
    :ok ->
      result = execute_and_wrap(config, call, prepared, pipeline.execute_fn)
      pipeline.budget_record_fn.(config, call, result)
      run_after_hooks(config, call, result, pipeline.after_hooks)
  end
end

# dispatch_one/3 keeps its exact current signature + behavior:
def dispatch_one(config, tool_call, pipeline \\ default_pipeline()) do
  case classify(config, tool_call, pipeline) do
    {:execute, prepared, call}            -> execute(config, prepared, call, pipeline)
    {:deny, %ToolResult{} = result}       -> result
    {:needs_approval, _prepared, call, info} -> denial_result(call, info, true)  # inline can't wait
  end
end
```

- The inline path (`Driver`, `BaseAgent.run/2`) is unchanged: `:needs_approval`
  still collapses to the interim denial result (`pending_approval: true`). Only
  `Turn.Server` consumes `{:needs_approval, …}` to actually park.
- **Fail-closed** lives in the `policy_fn` (Phase 2's pipeline) exactly as today;
  `classify` makes no new fail-open path. A policy timeout/unreachable surfaces as
  `{:deny, …}` (the Phase 2 contract).

### Decision 2 — Pure FSM core: approval transitions (`turn.ex`)

**API contract that forces the shape:** the Claude Messages API requires every
`tool_use` block in an assistant message to be answered by a `tool_result` in the
next user turn — a *partial* batch cannot be sent. So when a batch parks, the
already-executed results are **held** until the whole batch resolves; the turn
advances to the next LLM call only once every call in the batch has a result.

Two new `State` fields (both plain data → free durability):

```elixir
defstruct status: :provisioning,
          # … existing fields …
          parked_calls: [],   # %ToolCall{} list awaiting approval
          held_results: []    # %ToolResult{} already produced for this batch, held
```

One new status is **entered**: `:awaiting_approval`. New events/effects:

| In status | Event (from shell) | → status | Effects (in order; terminal/blocking last) |
|---|---|---|---|
| `:tool_dispatch` | `{:tool_results, results}` | *(unchanged)* | `apply_tool_results/2` (append each, decrement, steering, continue/forced-final) |
| `:tool_dispatch` | `{:needs_approval, held, parked}` | `:awaiting_approval` | `{:emit_event, :awaiting_approval, %{parked: n}}`, `{:persist, state'}` |
| `:awaiting_approval` | `{:approval, decisions}` — all rejected | →results | merge `held ++ rejected_denials`, reorder by `pending_calls`, `apply_tool_results/2` |
| `:awaiting_approval` | `{:approval, decisions}` — some approved | `:awaiting_approval` | stash rejected denials into `held`; `{:execute_approved, approved_calls}` (stays parked until `:approved_results`) |
| `:awaiting_approval` | `{:approved_results, results}` | →results | merge `held ++ results`, reorder by `pending_calls`, `apply_tool_results/2` |

- `decisions` is a map `tool_call_id => :approve | :reject`. Any parked id absent
  from `decisions`, or `:reject`, is treated as rejected (fail-closed default).
- `apply_tool_results/2` is the **existing** `:tool_dispatch` + `{:tool_results}`
  body, factored out and called from both `:tool_dispatch` and the resume paths —
  so iterations decrement exactly once per batch and the forced-final-at-cap path
  is unchanged.
- **Reorder** uses `pending_calls` (the full batch, set when entering
  `:tool_dispatch`) to sort merged results by original `tool_use` order, so the
  next user turn presents `tool_result` blocks in API-correct order.
- `{:execute_approved, calls}` runs `Dispatch.execute/4` directly (no
  re-`classify`) — the human already approved; re-running policy would re-park.
- The inline `Driver` never emits `:needs_approval`/`:approval`/`:approved_results`,
  so its existing transitions and tests are untouched. The new clauses are exercised
  by `Turn.Server` and by new unit/property tests.
- Existing terminal-state guards already cover `:awaiting_approval`:
  `{:llm_error,…}`/`{:tool_error,…}` from any non-terminal status → `:failed`.

### Decision 3 — `Turn.Server` (`:gen_statem`, coarse lifecycle states)

`:gen_statem` in `:handle_event_function` mode. Process **data** carries:
`turn_state :: %Turn.State{}`, `config :: %BaseAgentConfig{}`, `session_id`,
`store :: {module, handle}`, `registry :: {module, handle}`, `task_ref`,
`subscriber` (event callback), and `pending_reply` (the caller awaiting a turn
result, if any).

Three lifecycle states:

- **`:running`** — a monitored `Task` is in flight for the current blocking effect
  (`{:call_llm, …}`, `{:dispatch_tools, …}`, `{:execute_approved, …}`). The task
  sends its outcome to the server; the server feeds the matching event into
  `Turn.step/2`, then interprets the returned effects (spawn the next Task → stay
  `:running`; park → `:awaiting_approval`; finalize → `:idle`). Non-blocking
  effects (`{:convert_output,…}`, `{:validate_output,…}`, `{:guard_output,…}`,
  `{:append_message,…}`, `{:emit_event,…}`, `{:persist,…}`) run synchronously in
  the handler between blocking effects.
- **`:awaiting_approval`** — parked. `state_timeout` = approval expiry (config’d;
  default e.g. 5 min) → fail-closed: feed `{:approval, %{}}` (all rejected). An
  out-of-band `{:approval, decisions}` (cast) feeds the core.
- **`:idle`** — between turns. `state_timeout` = passivation idle (config’d) → the
  final state is already persisted, so `{:stop, :normal, data}`. A new turn request
  → admit input (input guardrails + `AgentMemory.initialize_turn` +
  `add_message("user", …)`, mirroring `admit_turn_input/2`) → `Turn.new/1` →
  `Turn.step(:start)` → interpret effects (→ `:running`).

**Mid-turn messages.** A turn request arriving while `:running` or
`:awaiting_approval` is `postpone`d (gen_statem) and replayed on entering `:idle`
— the parent design's named reason for `:gen_statem`.

**Effect interpretation** reuses the same logical operations as
`BaseAgent.non_streaming_handlers/0`:
- `{:call_llm, req}` → monitored `Task` → `BaseAgent` response helper → `{:llm_response, resp}`.
- `{:dispatch_tools, calls}` → monitored `Task`: `classify` each call; `execute`
  the `:execute` ones (internally concurrent, ordered, mirroring
  `dispatch_turn_tools/2`); collect `held = executed ++ deny_results`; if any
  `:needs_approval` → send `{:needs_approval, held, parked}`, else send
  `{:tool_results, ordered(held)}`.
- `{:execute_approved, calls}` → monitored `Task` running `Dispatch.execute/4` on
  each → `{:approved_results, results}`.
- `{:convert_output,…}`/`{:validate_output,…}`/`{:guard_output,…}` → synchronous
  (`convert_turn_output/3`, `validate_turn_output/2`, `run_output_guardrails/2`).
- `{:append_message, role, content}` → update `config.memory`
  (`AgentMemory.add_message`) **and** `SessionStore.append_entry` so the durable
  conversation tracks the live one.
- `{:emit_event, name, meta}` → invoke `subscriber` and/or telemetry.
- `{:persist, turn_state}` → `SessionStore.save_turn_state(store, session_id,
  turn_state)`. A store-write failure here is a hard failure: the turn does **not**
  advance past a suspend point it cannot durably record (no silent fallback).
- `{:finalize, value}` → emit `agent_end`, reply to `pending_reply`, clear/keep the
  turn state, → `:idle`.
- `{:fail, reason}` → emit, reply error, → `:idle` (terminal turn; server stays up
  for the session).

To reuse `BaseAgent`'s LLM/convert/validate/guard helpers without duplicating
logic, the few needed private functions are exposed as `@doc false` module
functions (visibility-only change; no behavioral change). Exact list is settled in
the plan.

### Decision 4 — Persistence & rehydration (turn state only)

Only `%Turn.State{}` is persisted (`{:persist, …}`); the conversation persists
separately via `append_entry`. The store **never** holds the client/credentials or
config (Decision: "turn state only; caller re-supplies config").

- `Turn.Session.cast(session_id, config, message, opts)` (router):
  `SessionRegistry.whereis(reg, session_id)` →
  - `{:ok, pid}` → forward the message.
  - `:none` → load `turn_state` + memory from the store, start a `Turn.Server`
    under `Turn.Supervisor` with the **caller-supplied** `config` (rehydrating
    `config.memory` from the store's `history`), `register`, then forward.
- `Turn.Server.resume(session_id, config, decisions)` delivers an approval decision
  to a parked (possibly just-rehydrated) session via the same router.
- `Turn.Supervisor` is a `DynamicSupervisor` for `Turn.Server` children
  (`restart: :transient`). `AgentProcess`/`AgentSupervisor` are untouched.

### Decision 5 — `SessionRegistry` behaviour

```elixir
@callback whereis(handle(), session_id()) :: {:ok, pid()} | :none
@callback register(handle(), session_id(), pid()) :: :ok | {:error, :taken}
@callback unregister(handle(), session_id()) :: :ok
```

Default `SessionRegistry.Native` wraps Elixir's built-in `Registry` (`:via` /
`Registry.lookup`, O(1), auto-unregister on process death). Horde/syn distributed
impls stay deferred (parent design Out-of-scope). A `session_registry` slot is
added to `Behaviours.Config` (default `{SessionRegistry.Native, []}`), mirroring
the Phase 3 `session_store` slot; like `session_store`, it is **not** a
dispatch-path concern and is not placed on the `Pipeline`.

## Data flow (one interactive turn with approval + passivation)

1. `Turn.Session.cast(sid, config, user_msg)` → registry `:none` → no prior turn
   state → start `Turn.Server`, register. Server `:idle` receives the request →
   admit input → `Turn.new` → `step(:start)` → `{:call_llm,…}` → spawn Task →
   `:running`.
2. Task returns the assistant response with tool calls → `{:llm_response, resp}` →
   core → `:tool_dispatch`, effects `{:append_message,"assistant",resp}` +
   `{:dispatch_tools, calls}` → append (memory + store) → spawn dispatch Task.
3. Dispatch Task `classify`s: 1 call `:execute` (run → result), 1 call
   `:needs_approval` → returns `{:needs_approval, [result], [parked_call]}`.
4. Core → `:awaiting_approval`, holds `held=[result]`, `parked_calls=[parked]`,
   effects `{:emit_event, :awaiting_approval,…}` + `{:persist, turn_state}` →
   server saves turn state, enters gen_statem `:awaiting_approval` with the expiry
   `state_timeout`.
5. *(Optional passivation while parked is not done — a parked turn keeps its
   process; passivation applies to `:idle`. If the node restarts, the persisted
   turn state + memory let `Turn.Session.resume` rehydrate and continue.)*
6. Out of band: `Turn.Server.resume(sid, config, %{parked_id => :approve})` →
   `{:approval, decisions}` → core: approved non-empty → `{:execute_approved,
   [parked]}` → spawn Task → `{:approved_results, [r2]}` → core merges
   `held ++ [r2]`, reorders by `pending_calls`, `apply_tool_results/2` (append both
   to memory+store, decrement once, steering) → `{:call_llm,…}` → `:running`.
7. LLM returns a final (no tool calls) → finalizing pipeline (convert/validate/
   guard) → `{:finalize, value}` → emit `agent_end`, reply, persist final state →
   `:idle`.
8. No further messages for the idle timeout → `state_timeout` → `{:stop,:normal}`.
   Registry auto-unregisters. Next `Turn.Session.cast` for `sid` → `:none` →
   rehydrate from store → new `Turn.Server` continues the conversation.

## Error handling

- Policy unreachable/timeout → `{:deny, gate_unavailable}` in `classify`
  (fail-closed; inherited from the Phase 2 `policy_fn`).
- Tool Task crash/timeout → error-result envelope into the batch results; the turn
  continues (parity with `unwrap_tool_task_result!/1` semantics).
- LLM call failure inside the Task → `{:llm_error, reason}` → core `:failed` →
  `{:fail, reason}` → server emits, replies error, → `:idle`.
- Approval timeout → all-reject (fail-closed) via `{:approval, %{}}`.
- `SessionStore.save_turn_state` failure at a suspend point → hard failure; the
  turn does not advance past a suspend point it cannot durably record.
- Unexpected `(status, event)` in the core → existing total-function fallback →
  `:failed` with `{:unexpected_event, status, event}` (a shell-sequencing bug).

## Testing strategy

- **Pure core (bulk of correctness):** `turn_test.exs` + `turn_property_test.exs`
  gain every new transition with exact effect-list assertions (existing idiom):
  park (`:tool_dispatch` → `:awaiting_approval`), all-reject resume, partial-approve
  resume, `:approved_results` merge, result **reordering** by `pending_calls`,
  iteration-decrements-once-per-parked-batch, forced-final-at-cap after a parked
  batch.
- **Chokepoint:** table tests for `classify/3` (allow/deny/needs_approval × before-
  hook halt × registry miss) and `execute/4` (budget gate × after-hooks);
  **`dispatch_one/3 == classify ➞ execute` equivalence** is the parity oracle
  (existing `dispatch_test.exs` stays green unchanged).
- **`Turn.Server` (statem):** suspend → persist → passivate (idle timeout) →
  rehydrate → resume; mid-turn message postponement; tool-Task crash isolation;
  approval timeout → deny; resume of a rehydrated parked session.
- **`SessionRegistry`:** a small contract suite (whereis/register/unregister/taken/
  none) run against `Native` (shaped like the Phase 3 `SessionStoreContract`).
- **Integration:** one full approval round-trip via `Turn.Session` +
  `Turn.Server` + `InMemory` store + `Native` registry + a fake LLM client +
  `PolicyEngine.Ruleset` with a `:require_approval` rule.
- **Back-compat:** the full existing suite passes — inline path and existing core
  clauses unchanged.
- **Gates (every Commit):** `mix format` → `mix compile --warnings-as-errors
  --force` (clean) → `mix test` (full suite green).

## Versioning

The current `1.0.0` in `mix.exs` + the `## [1.0.0]` CHANGELOG heading are a
**defect** — no `1.0.0` tag was cut, and `1.0.0` is reserved for the final phase.
Phase 4 corrects this:

- Re-label Phase 3 (a breaking change from `0.7.0`) as **`0.8.0`** (pre-1.0
  breaking = minor bump): fix `mix.exs` and the CHANGELOG heading.
- Phase 4 (additive, back-compat) → **`0.9.0`**.
- `1.0.0` is reserved for the final phase of the milestone.

A migration guide is not required (additive, default-off; the inline path is
unchanged). CHANGELOG note describes `Turn.Server`, the approval contract, the
chokepoint split, `SessionRegistry`, and the version correction.

## Deliverables

1. `Dispatch.classify/3` + `Dispatch.execute/4`; `dispatch_one/3` re-expressed as
   `classify ➞ execute` (behavior identical; `dispatch_test.exs` is the oracle).
2. `Turn` core: `:awaiting_approval` transitions, `parked_calls`/`held_results`
   fields, factored `apply_tool_results/2`, the three new events + two new effects
   (`{:persist,…}`, `{:execute_approved,…}`).
3. `Turn.Server` (`:gen_statem`): `:running`/`:awaiting_approval`/`:idle`, monitored
   Tasks, message postponement, `state_timeout`s, effect interpretation,
   persistence at suspend points.
4. `Turn.Session` router (whereis → route | rehydrate), `Turn.Supervisor`
   (DynamicSupervisor).
5. `SessionRegistry` behaviour + `Native` default; `session_registry` slot on
   `Behaviours.Config`.
6. Tests per the strategy above; full suite green; compile clean.
7. CHANGELOG note + version correction (Phase 3 → `0.8.0`, Phase 4 → `0.9.0`).
