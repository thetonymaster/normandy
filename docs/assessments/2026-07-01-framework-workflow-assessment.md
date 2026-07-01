# Normandy Framework Workflow Assessment

**Date:** 2026-07-01
**Scope:** read-only analysis of all major workflows: turn execution (FSM + three interpreters), LLM integration, schema/validation, memory/context, sessions/persistence/clustering, coordination/DSL/tools/guardrails.
**Method:** six parallel subsystem explorations with file:line evidence; the four load-bearing Critical claims were independently re-verified against source (marked ✅ below). Other claims carry the exploring agent's citations and were not independently re-read.

## TL;DR

The architecture is sound — a pure FSM turn core with pluggable interpreters, behaviour-based persistence, and a single policy chokepoint for tools. The defects cluster into four systemic themes rather than isolated bugs:

1. **Transcript integrity has no guardian.** At least four independent paths can produce a `tool_use` with no matching `tool_result` — a transcript the Anthropic API rejects with a 400.
2. **Silent degradation.** Errors, denials, and parse failures routinely become empty structs or `%{}` instead of loud failures.
3. **Cost blindness.** Retries, cache tokens, and budgets are unaccounted; hidden API amplification reaches 6× per logical step.
4. **Drift between parallel implementations.** Three turn interpreters, two validators, two orchestration systems, and two tool-execution APIs — each pair already diverging.

Also: `CLAUDE.md` predates the Turn FSM, sessions, guardrails, coordination, and clustering layers entirely.

## Workflow map

| Workflow | Path | Shape |
|---|---|---|
| Turn execution | `BaseAgent.run` → admission → pure `Turn.step/2` → interpreter | Effects interpreted by `Driver` (sync), `Inline` (scripted), or `Server` (durable `gen_statem`). Iteration cap is structurally sound — no infinite tool loop possible (`turn.ex:159-163, 289-305`). |
| LLM conversation | `Model.converse` → `ClaudioAdapter` | Native structured outputs (tools force legacy) with fallback to legacy clean→decode→bind parse pipeline (2 corrective retries). |
| Memory/context | `AgentMemory` entry graph + `Compactor` at `:steering` | Heuristic token estimation; Anthropic prompt caching; summarizer strategy. |
| Sessions | `SessionStore` (ETS/Mnesia/Postgres/Redis) + `SessionRegistry` (Native/Horde/Redis) + `ResumeReaper` | Secret-free `ConfigTemplate` rebuilt node-locally; lazy and (intended) eager resume. |
| Tools | `Dispatch` chokepoint: hooks → schema validation → policy → budget → execute | Executor isolates tool-body crashes; HITL approval modeled in FSM (Server only). |
| Multi-agent | `coordination/*` orchestrators + `DSL.Workflow` | Workflow DSL partially reimplements the coordination layer. |

## Points of failure

### Critical

1. ✅ **Mid-dispatch crash bricks a durable session.** The assistant `tool_use` message is persisted immediately on entering `:tool_dispatch`, but no `{:persist, turn_state}` effect is emitted there — turn-state persists only after the batch completes (`turn.ex:132-135, 304`; `server.ex:286-292`). A crash during tool execution leaves the store with a dangling `tool_use`; rehydration rebuilds the invalid history verbatim (no repair logic exists), the next LLM call gets a provider 400, and for a first-batch crash `turn_state` is `nil` so the reaper never sees it as resumable (`resume_reaper.ex:98-103`).

2. ✅ **Eager resume is dead on the production path.** `ConfigTemplate.from_config/2` hardcodes `resume_policy: :lazy` (`config_template.ex:21`); the `/3` arity that threads the real policy has no caller in `lib/` — the only production call site is `session.ex:98`, using `/2`. Every store's `list_resumable` filters on stored `:eager`, so `ResumeReaper.reap` always gets `[]`. The distributed eager-handoff test persists the template by hand with `/3`, masking the defect (`test/agents/turn/eager_handoff_distributed_test.exs:131-134`). Thin restarts after passivation also silently downgrade configured-eager sessions to `:lazy`.

3. ✅ **Truncation/compaction orphans tool results — three independent paths.** Token-budget truncation (`context/window_manager.ex:335-352`), the summarizer's count-based split (`summarizer.ex:263`), and the `max_messages` cap (`agent_memory.ex:241-258`, runs on every `add_message`, including mid-tool-loop) all cut with no awareness of `tool_use`/`tool_result` pairing or turn boundaries. Compaction fires at `:steering` — immediately after tool results, the worst possible cut point. No test covers orphan avoidance.

4. **Split-brain double execution.** Horde registration has no fencing token (`session_registry/horde.ex:78-93`); during a netsplit each partition runs its own server for the same session, interleaving writes into the shared store and double-billing. The Redis registry has a narrower window: a partitioned-but-alive node keeps executing after its key is stolen, and the per-node owner GenServer is a SPOF whose death lapses every key in ~60s (`session_registry/redis.ex:19, 121-126, 179-193`).

5. **Silent empty-input tool execution under streaming.** A truncated streamed `input_json_delta` fails `Poison.decode` and becomes `%{}` — the tool executes with empty arguments and no error (`dispatch.ex:346-351`).

6. **API errors swallowed into empty response structs.** Both adapters convert transport/API failures into a returned empty `response_model` with only `IO.warn` (`claudio_adapter.ex:982-987`; `openai_compatible_adapter.ex:111-118`). Callers cannot distinguish "call failed" from "model returned nothing."

### High

7. **No timeout on `:running`.** Tool streams use `timeout: :infinity`, `Model.converse` has no wrapper, and the Server's `:running` state has no `state_timeout` — a hung provider wedges the session and its caller (blocked on `:gen_statem.call(…, :infinity)`) forever (`server.ex:44, 373`).
8. **No versioning on persisted blobs.** `%Turn.State{}`, templates, and entries are raw `term_to_binary`; adding a struct field breaks resume with `KeyError`, and `[:safe]` decoding raises on removed modules (`postgres.ex:225-226`). The one versioned format (`AgentMemory.dump/1`) is never used by the stores.
9. **Retry amplification × cost blindness.** CircuitBreaker → resilience Retry (3) → JSON retry (2) = up to 6 HTTP calls per logical step, invisible to the breaker (`base_agent.ex:309-340`; `claudio_adapter.ex:964`). Retry-call usage is discarded (`json_deserializer.ex:321`), cache tokens are never read (`base_agent.ex:1359-1367`), `BudgetTracker` is a NoOp that never sees LLM spend, and a crash between billing and persist double-bills (no idempotency key anywhere).
10. **Same config, three approval behaviors.** `Dispatch.dispatch_one` collapses `:needs_approval` into a denial under Driver/Inline (`dispatch.ex:252`); only the Server parks for a human. Neither Driver nor Inline handles `{:execute_approved}` (no catch-all); a parked turn under the Driver would return `nil` silently (`driver.ex:49-93`).
11. **Nested schema casting crashes.** Schema modules define no `cast/1`, so any field typed `{:array, MySchema}` routed through `Validate`/`SchemaBinder` raises `UndefinedFunctionError` (`type.ex:708-713`). Latent only because production response models are flat single-string schemas (`agents/io_model.ex:11-28`).
12. **Prompt caching is self-defeating.** `DateTimeProvider` injects a microsecond timestamp into the system prompt every call, busting the cache (`date_time_provider.ex:37-40`); the conversation breakpoint anchors on the last `"user"`-role message, which in a tool loop is the original input — the entire tool exchange re-processes uncached each iteration (`claudio_adapter.ex:724-738`).
13. **`admit_turn_input` raises inside the Server** unrescued, crashing the `gen_statem` on a validation/guardrail failure instead of replying `{:error, …}` (`server.ex:177`).

### Medium (condensed)

- Turn ids collapse to `"live"` on persistence, losing turn structure across restarts (`server.ex:413-418`).
- Retry feedback is dropped when messages lack a system entry — retries reproduce the same failure (`retry_feedback.ex:124-133`).
- Structured-outputs path gets zero corrective retries; legacy gets two (`claudio_adapter.ex:1082-1104`).
- Guardrails never see tool arguments or tool results — only user input and final output (`base_agent.ex:532, 1707-1713`).
- `Reactive.race/some` spawn uncapped tasks, leak still-running pid-based agents after brutal-kill, and leave stray mailbox messages (`reactive.ex:82-101, 244-253`).
- The reaper fires once on `:nodedown` with no registry-convergence retry; missed sessions are never retried (`resume_reaper.ex:60-88`).
- Redis store appends are not replica-acked while turn-state writes are (`session_store/redis.ex:40-47`).
- Workflow DSL `when_result` is stored but never applied — dead configuration (`workflow.ex:340-373`); its `{:error, reason}` clause on `BaseAgent.run` is dead code and it has no rescue, so a raising agent crashes the whole workflow (`workflow.ex:415-420`).
- Memory is unbounded by default (nil `max_messages` + NoOp compactor); compaction triggers use a chars/4 heuristic that excludes system prompt and tool schemas while the accurate `TokenCounter` sits unused (`context/window_manager.ex:105-128, 213-219`).
- Two validators disagree on "required" (`Validate` rejects nil/""; `Schema.Validator` checks key presence only — `validator.ex:193-210`).
- Server's non-approval dispatch returns results executed-first/denied-last, not `tool_use` order — unlike the other two interpreters (`server.ex:462-468`).
- A2A inbound has no auth/rate limit (`a2a/server.ex:87-135`); A2A card hardcodes protocol version `"0.3"`; `HierarchicalCoordinator` calls `String.to_atom` on dynamic ids (atom-table exhaustion, `hierarchical_coordinator.ex:279`).
- Session store has no delete/TTL/listing/encryption/tenancy; the eager-resumable set is never pruned; `list_resumable` does an unbounded O(n) scan on every nodedown.

## Improvements (design-level)

1. **Transcript-integrity module.** One owner of the `tool_use`/`tool_result` pairing invariant, used by all truncation paths (snap cuts to turn boundaries — `turn_id` already exists in the entry graph), by rehydration (repair dangling `tool_use`), and asserted in `apply_tool_results` (result ids == pending ids). Addresses Critical 1 and 3 plus the `max_messages` orphaning in one design.
2. **Unify effect interpretation.** A shared effect-dispatch table with per-interpreter blocking hooks makes effect coverage exhaustive; the "wire every new effect into all three interpreters" rule stops being tribal knowledge.
3. **`Provider` behaviour for LLM adapters** — request building, content/usage extraction, capability flags. Kills `function_exported?` reflection, the request pipeline built three times inside `ClaudioAdapter` (`:165-172, 210-217, 265-272`), and unlocks structured outputs/streaming for the OpenAI adapter.
4. **Fail loud.** Errors become `{:error, …}` or typed raises, not empty structs; streamed-input decode failure becomes an error `tool_result`; structured-output skips get telemetry; Driver/Inline reject approval-requiring config instead of silently denying.
5. **Persist turn-state at `:tool_dispatch` entry + idempotency key per LLM call.** Closes the bricked-session and double-billing windows together.
6. **Consolidate duplicate pairs:** two validators; `DSL.Workflow`'s inline sequential loop beside `coordination/*`; 7-8 copies of `prepare_input`/`extract_result`; the unused registry-based `Executor.execute` API that bypasses policy/budget/hooks.
7. **Session store hardening:** versioned blobs with decode shim, per-session lease/epoch checked on writes (fences split-brain at the store — the only shared authority), `wait` on Redis appends, lifecycle telemetry (create/rehydrate/passivate/reap).
8. **Update CLAUDE.md** to cover Turn FSM, sessions, guardrails, coordination, clustering.

## New feature candidates (by leverage)

1. **Real cost accounting + budget enforcement** — aggregate usage across retries/fallbacks/turns (incl. cache tokens), price it, feed the existing `BudgetTracker` seam; per-workflow and per-session budgets fall out naturally.
2. **Streaming under the durable Server engine** — currently streaming exists only on the synchronous path.
3. **Session operations API** — list/query/delete, TTL/retention, encryption at rest, tenant scoping.
4. **Long-term memory layer** — `MemoryStore` behaviour + retrieval context provider (embeddings, cross-session recall, durable summaries). Nothing of the kind exists today.
5. **Turn cancellation + approval ergonomics** — cancel/abort in-flight turns, list pending approvals, expiry callbacks.
6. **Anthropic Message Batches API** — `Batch.Processor` is client-side fan-out only; the discounted async endpoint is untouched.
7. **Constraint-carrying structured outputs** — the translator strips everything except type/enum/required (`schema_translator.ex:50-57`); pass through what the API supports, retry the rest.

## Prioritized fix plan — Critical tier

Ordered by risk-reduction per unit effort. Any change to `Turn.step/2` effects must be wired into all three interpreters (Driver, Inline, Server) or the unwired shell crashes.

### Fix 1 — Thread `resume_policy` into template persistence (tiny)
- `turn/session.ex:98`: call `ConfigTemplate.from_config(config, template_id, resume_policy)` with the policy already read from opts at `session.ex:74`.
- Fix the masking test: make `eager_handoff_distributed_test` persist through the real `Session.run` path instead of hand-building the template.
- Consider deleting the now-redundant `/2` arity or making it delegate with an explicit policy argument, so this cannot regress silently.

### Fix 2 — Fail loud on streamed tool-input decode failure (tiny)
- `dispatch.ex:346-351`: on `Poison.decode` failure return an error `ToolResult` (`is_error: true`, message naming the tool and the malformed payload) instead of `%{}`.

### Fix 3 — Persist at `:tool_dispatch` + batch-completeness assertion + rehydration repair (medium)
- `turn.ex:132-135`: add `{:persist, s'}` to the `:tool_dispatch` transition effects (`:persist` is already handled by all three interpreters: Driver/Inline no-op, Server writes).
- `turn.ex` `apply_tool_results/2`: assert `MapSet.new(result ids) == MapSet.new(pending_calls ids)`; on mismatch emit `{:fail, {:incomplete_batch, missing}}` — turns silent API rejection into a loud, attributable failure.
- Rehydration repair (fail-closed default): when rebuilt history ends in an assistant `tool_use` with no matching results, synthesize error `tool_result`s ("interrupted during tool execution") and resume via the normal `apply_tool_results` path. Re-dispatching instead requires idempotent tools — do not default to it.
- Extend `Turn.resume/1` to handle the now-persistable `:tool_dispatch` status (currently forced to `:failed` by the catch-all at `turn.ex:277-280`).

### Fix 4 — Turn-aware truncation (medium, staged)
- Stage 1: `agent_memory.ex` `enforce_max_messages/1` — extend the kept set until the oldest kept entry is not role `"tool"` and does not orphan a pair; cheapest correct rule is "never cut inside a `turn_id`".
- Stage 2: `context/window_manager.ex` `split_to_fit/2` and `summarizer.ex:263` — same invariant. Requires `history/1` (or a sibling) to carry `turn_id`/role, which `agent_memory.ex:82-89` currently drops.
- Add a test generating multi-iteration tool loops and asserting, for every truncation path, that no surviving history begins with an orphaned `tool_result`.

### Fix 5 — Error propagation contract (medium, needs a decision)
- Replace empty-struct swallowing in both adapters with a typed error the Turn core's existing `{:llm_error, reason}` handling can consume. Open decision: raise (Driver semantics today) vs return `{:error, …}` through `Model.converse` (Inline/Server semantics) — pick one and standardize; this is a public-contract change.

### Fix 6 — Split-brain fencing (large, design first)
- Per-session epoch/lease column in the store, checked on every write; stale writer receives `{:error, :fenced}` and terminates. Interim mitigations: telemetry counter on Redis `del_if_owner` evictions; document the Horde netsplit behavior; add a `:running` `state_timeout` (High 7) so wedged duplicates eventually surface.

