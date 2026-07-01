# Critical-Tier Fixes — Design

**Date:** 2026-07-01
**Source:** `docs/assessments/2026-07-01-framework-workflow-assessment.md` (Critical findings 1–6 and the "Prioritized fix plan" section)
**Status:** approved in brainstorming; implementation plans to follow in `docs/superpowers/plans/`

## Context

A six-subsystem analysis of the framework found six Critical-tier defects. The four load-bearing claims were independently re-verified against source:

1. Mid-tool-dispatch crash bricks a durable session (dangling `tool_use`, no repair path).
2. Eager resume is dead: `ConfigTemplate.from_config/2` hardcodes `resume_policy: :lazy` (`config_template.ex:21`); the only production caller is `session.ex:98` using `/2`.
3. Three truncation paths orphan `tool_result`s from their `tool_use` (window manager, summarizer, `max_messages` cap).
4. Split-brain allows double execution of one session with no store-level fencing.
5. Streamed tool inputs that fail to decode become `%{}` and the tool executes silently.
6. LLM API errors are swallowed into empty response structs.

## Decisions (settled in brainstorming)

| Decision | Choice |
|---|---|
| Packaging | One spec (this document); five staged implementation plans (fixes 1+2 pair, then 3, 4, 5, 6) |
| Fix 5 error contract | Tuples inside (`{:error, %APIError{}}` from `Model.converse`), raise at the public edge (`BaseAgent.run` keeps its raise contract via the Driver's existing `:fail` clause) |
| Fix 6 scope | Fence Postgres + Redis; ETS/InMemory exempt (node-local, fencing meaningless); Mnesia deferred with documented rationale; interim mitigations ship in the same plan |
| Fix 3 resume mode | Always synthesize error `tool_result`s for interrupted calls — fail-closed; tools never re-execute on resume |

## Cross-cutting constraint

Any change to `Turn.step/2` effects must be handled by ALL THREE interpreters — `Turn.Driver`, `Turn.Inline`, `Turn.Server` — or the unwired shell crashes with a `CaseClauseError`. The only new effect usage in this spec is an additional `{:persist, _}` emission (Fix 3), which all three interpreters already handle (Driver/Inline no-op, Server writes).

---

## Fix 1 — Thread `resume_policy` into template persistence

**Defect:** every template persisted through the production path is stamped `:lazy`, so `list_resumable/1` always returns `[]` and the `ResumeReaper` never has anything to recover. Thin restarts after passivation silently downgrade configured-eager sessions.

**Change:**
- `Turn.Session.rehydrate_and_start/1` (`session.ex:98`): call `ConfigTemplate.from_config(config, template_id, resume_policy)`, using the policy already extracted from opts at `session.ex:74`.
- Delete `ConfigTemplate.from_config/2`. Its only production caller is the line above; keeping an arity that silently stamps `:lazy` is the regression vector. All callers (including tests) pass an explicit policy.

**Tests:**
- Rewrite `eager_handoff_distributed_test` to persist the template through the real `Session.run` path instead of hand-building it with `/3` (the hand-built template is what masked this defect).
- Regression test: a session started with `resume_policy: :eager` produces an `:eager` template in the store and appears in `list_resumable/1`.

## Fix 2 — Fail loud on streamed tool-input decode failure

**Defect:** `Dispatch.normalize_tool_input/1` (`dispatch.ex:346-351`) returns `%{}` when `Poison.decode` fails on accumulated streamed `partial_json`; the tool executes with empty arguments and no error.

**Change:**
- `normalize_tool_input/1` returns `{:error, {:invalid_tool_input, raw_preview}}` on decode failure (preview truncated for log/message safety).
- At streamed-block → `ToolCall` conversion (`base_agent.ex:966-973`), a failed decode keeps the call's `id`/`name` and tags the `ToolCall` with the input error.
- `Dispatch.classify` maps input-error-tagged calls directly to an error `ToolResult` (`is_error: true`, message naming the tool and the malformed-payload preview) without executing the tool. Routing through the normal result path preserves batch completeness: every `tool_use` still gets a `tool_result`.

**Tests:** streaming test with truncated `partial_json` asserting (a) the tool is never invoked, (b) an error `tool_result` with the matching `tool_call_id` is produced.

## Fix 3 — Persist at `:tool_dispatch`, batch-completeness assertion, transcript repair

**Defect:** the assistant `tool_use` message is persisted on entering `:tool_dispatch`, but turn-state is not (`turn.ex:132-135`; first persist is at `turn.ex:304` after the batch completes). A crash during tool execution leaves the store with a dangling `tool_use`; rehydration rebuilds the invalid history verbatim and the next LLM call gets a provider 400. First-batch crashes have `turn_state = nil`, so the reaper cannot see them.

**New module — `Normandy.Components.TranscriptIntegrity`:** single owner of the `tool_use`/`tool_result` pairing invariant, shared with Fix 4.
- `dangling_tool_calls(entries) :: [ToolCall.t()]` — detect a trailing assistant `tool_use` whose results are missing.
- `synthesized_error_results(calls, reason) :: [ToolResult.t()]` — one error result per call (`is_error: true`, message "interrupted during tool execution" or caller-supplied reason).
- (Fix 4 adds `snap_cut/2` here.)

**Changes:**
1. **Persist on dispatch entry.** The `:tool_dispatch` transition emits `[{:append_message, "assistant", resp}, {:persist, s'}, {:dispatch_tools, calls}]`. Persisted state now carries `pending_calls` and status `:tool_dispatch` before any tool runs. No interpreter wiring needed (`{:persist}` already handled by all three).
2. **Batch-completeness assertion.** `apply_tool_results/2` compares result `tool_call_id`s against `pending_calls` ids as sets. Mismatch → `{:fail, {:incomplete_batch, %{missing: [...], unexpected: [...]}}}`. This encodes the batch-completeness contract as a loud invariant instead of a by-construction hope.
3. **Resume of persisted `:tool_dispatch`.** New `Turn.resume/1` clause: synthesize error results for `pending_calls` via `TranscriptIntegrity` and feed them through the normal `apply_tool_results` path (the turn continues to `:steering` → persist → compaction; the LLM decides whether to retry the tools). Removes `:tool_dispatch` from the catch-all that forces `:failed` (`turn.ex:277-280`).
4. **Rehydration repair.** `Turn.Session.rehydrate_and_start/1` runs `TranscriptIntegrity` over the rebuilt entries: a dangling trailing `tool_use` with no usable persisted pending state (pre-fix sessions; first-batch crashes) gets synthesized error `tool_result` entries appended — and persisted to the store — before the server starts.

**Fail-closed guarantee:** tools never re-execute on resume, under any path. Re-dispatch was considered and rejected (silently double-executes side-effecting tools).

**Tests:**
- Crash-mid-dispatch simulation: kill the server after the `:tool_dispatch` persist, rehydrate, assert synthesized error results present and the next request produces an API-valid transcript.
- Pre-fix repair: store seeded with a dangling `tool_use` and no turn-state; rehydration appends error results.
- Unit tests for the completeness assertion (missing ids, unexpected ids, exact match).
- `Turn.resume/1` on `:tool_dispatch` state reaches `:steering` with a complete batch.

## Fix 4 — Turn-aware truncation

**Defect:** three truncation paths cut with no awareness of pairing or turn boundaries: `enforce_max_messages` (`agent_memory.ex:241-258`, runs on every `add_message` including mid-tool-loop), `split_to_fit/2` (`context/window_manager.ex:335-352`), and the summarizer's count-based split (`summarizer.ex:263`). Each can leave a surviving history that starts with an orphaned `tool_result`.

**Invariant (owned by `TranscriptIntegrity`):** a cut point is valid only on a turn boundary — the oldest surviving entry must begin a `turn_id`. `snap_cut(entries, desired_cut)` extends the kept set backward until the boundary holds.

**Stage 1 — `enforce_max_messages`:** after taking the newest N chain entries, snap to the turn boundary. The cap becomes "at least N entries, rounded up to a whole turn." Documented edge case: a single turn longer than `max_messages` is kept whole — an orphaned transcript is never the right trade.

**Stage 2 — window manager + summarizer:** both currently operate on `AgentMemory.history/1` output, which drops `turn_id`/role structure and permanently downgrades structs on rebuild.
- Add `AgentMemory.history_entries/1` returning entries with `turn_id` and role intact. `history/1`'s shape is untouched (adapters depend on it).
- `split_to_fit/2` and the summarizer's split point snap to turn boundaries via `TranscriptIntegrity.snap_cut/2`.
- `rebuild_memory/2` and `rebuild_memory_with_summary/4` rebuild from entries rather than serialized history maps — fixing the struct-loss-on-truncation defect as an in-scope side effect.

**Tests:** a generator producing multi-iteration tool-loop conversations, run through all three truncation paths, asserting: no surviving history starts with role `"tool"`; every surviving `tool_result` has its `tool_use` in the surviving history; every surviving `tool_use` has all its results.

## Fix 5 — Error propagation: tuples inside, raise at edge

**Defect:** both adapters convert API/transport failures into a returned empty `response_model` with only `IO.warn` (`claudio_adapter.ex:982-987`; `openai_compatible_adapter.ex:111-118`). Callers cannot distinguish "call failed" from "model returned nothing." Consequence worth stating plainly: the Retry/CircuitBreaker layer almost never triggers today, because adapters swallow errors before the resilience wrapper can see them. This fix is what makes the resilience layer real.

**New exception struct — `Normandy.LLM.APIError`:** fields `type` (`:auth | :rate_limit | :overloaded | :invalid_request | :transport | :unknown`), `status`, `provider`, `message`, `retryable?`.

**Contract:** `Model.converse` returns `struct | {struct, usage} | {:error, APIError.t()}`, documented on the protocol. `ConverseResult.normalize/1` passes `{:error, _}` through unchanged.

**Changes:**
- Both adapters: `handle_error` returns `{:error, %APIError{}}`; `IO.warn` becomes `Logger.error`.
- Driver path: the `call_llm` handler returns `{:llm_error, error}` to the FSM on `{:error, _}`; the FSM's existing transition to `:failed` emits `{:fail, reason}`; the Driver's existing `:fail` clause raises. `BaseAgent.run`'s public contract ({config, response} or raise) is preserved with no special-casing — the raise now carries the `APIError`.
- Inline returns `{:error, reason, state}` and Server replies `{:error, reason}` — both already model this natively.
- `JsonDeserializer` retry loop: `{:error, _}` from a corrective `raw: true` call aborts the retry loop and propagates (it is not content to parse).
- `call_llm_with_resilience`: `retry_if` retries `retryable?: true` errors (rate limit, overloaded, transport) and does not retry auth/invalid-request; `{:error, :open}` from the breaker stays non-retryable.
- Audit and update the remaining `Model.converse` call sites: summarizer, batch processor, coordination modules.

**Tests:** adapter error-mapping units (API error type → `APIError` fields); Driver raises `APIError` through `BaseAgent.run`; Inline/Server return error tuples; integration test that the circuit breaker opens after N adapter failures (verifying the resilience layer now sees them).

## Fix 6 — Split-brain fencing for Postgres + Redis, mitigations elsewhere

**Defect:** Horde registration has no fencing (`session_registry/horde.ex:78-93`) — during a netsplit each partition runs its own server for one session, interleaving writes into the shared store. The Redis registry has a partitioned-but-alive window plus a per-node owner-GenServer SPOF (`session_registry/redis.ex:19, 121-126, 179-193`).

**Epoch design:** a per-session monotonic integer, enforced at the store — the only shared authority.
- New optional `SessionStore` callback: `acquire_epoch(handle, session_id) :: {:ok, non_neg_integer()}` — atomically increments and returns.
- `Turn.Server` acquires an epoch at start (register/rehydrate) when the store supports it, and passes it with every hot-path write (`append_entry`, `save_turn_state`). `save_config_template` is written by `Turn.Session` during bootstrap, before any server (and thus any epoch) exists — it stays unfenced by design; it is config-level, not turn-mutating.
- The store rejects writes with a stale epoch: `{:error, :fenced}`. A fenced server logs and stops `:normal` — a newer claimant owns the session.
- Default for stores without the callback: epoch 0, writes unchecked. ETS/InMemory are node-local (duplicate servers would write to different stores; fencing is meaningless). Mnesia is deferred: its transaction and partition semantics make it the hardest backend for the least production use; documented in the store's moduledoc.

**Postgres:** `epoch` column via a new `MigrationAddEpoch` (following the existing add-column migration pattern; ordering documented alongside the existing migrations). Acquire: `UPDATE … SET epoch = epoch + 1 RETURNING epoch`. Writes compare the epoch inside the existing transaction / `FOR UPDATE` structure.

**Redis:** epoch in a per-session key via `INCR`; writes go through a small Lua script for atomic compare-and-write.

**Mitigations (same plan):**
- Telemetry event on Redis-registry eviction of a live-looking key (split-brain-suspect counter).
- `:running` `state_timeout` on `Turn.Server` (configurable via server opts; default 10 minutes — generous enough for slow LLM calls and long tool runs) feeding a synthetic `{:llm_error, :turn_timeout}` — wedged or duplicate servers eventually surface and terminate instead of hanging forever.
- Documentation section on Horde netsplit behavior and its limits.

**Tests:** contract-test additions (acquire/fence semantics; unfenced default for non-supporting stores); a two-writer test where the second `acquire_epoch` fences the first's subsequent write; Redis Lua compare-and-write unit; `:running` timeout test.

---

## Plan packaging and sequencing

Five implementation plans in `docs/superpowers/plans/`:

| Plan | Contents | Depends on |
|---|---|---|
| 1 | Fixes 1 + 2 (tiny pair) | — |
| 2 | Fix 3 (persist + assertion + repair; introduces `TranscriptIntegrity`) | — |
| 3 | Fix 4 (turn-aware truncation, stages 1+2) | Plan 2 (`TranscriptIntegrity`) |
| 4 | Fix 5 (error propagation) | — |
| 5 | Fix 6 (fencing + mitigations) | — |

Order above is risk-reduction per effort. Plans 4 and 5 are independent of 2/3 and of each other. Per repo convention, `mix format` before tests; all existing tests must pass at each plan's completion.
