# Phase 1d — Streaming Cutover onto the Turn FSM

**Status:** Design approved, ready for planning
**Date:** 2026-05-29
**Parent:** `docs/superpowers/specs/2026-05-29-harness-decomposition-design.md`
**Predecessor:** Phase 1c (non-streaming cutover) — merged in PR #24

## Goal

Cut `BaseAgent`'s streaming turn over to run on the pure `Normandy.Agents.Turn`
FSM, mirroring what Phase 1c did for the non-streaming turn. The streaming test
suite stays 100% green and behavior stays at parity. This is the streaming
analog of 1c: a refactor driven by the existing streaming suite as the parity
oracle, not red→green TDD.

In scope (the streaming turn):

- `stream_response/3` — the no-tools streaming entry
- `stream_with_tools/3` — the streaming tool loop
- `execute_streaming_tool_loop/3` — the loop body (to be retired)
- `consume_stream_with_incremental_guards/3` — mid-stream guard consumption
- supporting helpers: `stream_response_from_llm/3`, `extract_tool_calls/1`,
  `build_streaming_assistant_response/2`, `run_streaming_output_guardrails/3`

## Non-Goals

- **No Turn FSM changes.** The pure core (`turn.ex`) is frozen; streaming maps
  at the existing LLM-call boundary.
- **No new behaviours/phases.** Phases 2 (pluggable policy/budget/hooks),
  3 (SessionStore / branching memory), 4 (`:gen_statem` shell / suspend /
  approval / passivation), and 5 (compaction) remain out of scope.
- **No public signature changes** to `stream_response/3`, `stream_with_tools/3`,
  `run/3`, `BaseAgentConfig`, or `AgentMemory`.
- **The dispatch pipeline stays at its no-op defaults** (allow-all policy, no-op
  budget/hooks) via `base_agent_pipeline/0`.

## Key Insight

The Turn FSM already supports streaming without modification. Streaming differs
from non-streaming only inside the effect handlers, not in the state machine:

- A mid-stream `:incremental` guardrail violation already collapses to "no tool
  calls" in the current code, because `strip_partial_tool_use/1` removes the
  partial `tool_use` blocks before `extract_tool_calls/1` runs. So the loop
  naturally finalizes on violation. Incremental guarding can therefore stay
  fully **encapsulated inside the `call_llm` handler** — the FSM never observes
  individual stream deltas.
- Streaming's finalize pipeline is **guard-only** (no schema convert/validate).
  The FSM still emits `convert → validate → guard`, but the streaming handler
  set wires `convert` and `validate` to identity, so the pipeline collapses to
  guard-only with no FSM change.

## Architecture

### Decision 1 — FSM granularity: LLM-call boundary (FSM unchanged)

The `:call_llm` effect is interpreted by a streaming-aware handler that consumes
the entire stream (including incremental mid-stream guarding) and returns one
final response — exactly the granularity 1c uses. `step/2` is pure and untouched.
Stream deltas and the callback live inside the handler, invisible to the FSM.

Rejected alternative: modeling deltas as FSM events/effects
(`{:stream_delta, text}`, mid-stream guard as an effect). That would expand the
pure core, risk parity drift, and duplicate incremental-guard logic that already
works.

### Decision 2 — One injected-handler driver, executed refactor-first

Today there are three interpreters of the FSM: `Turn.Inline` (deps-injected,
test/library), the 1c production driver `run_turn_effects/3` (hardcoded
handlers), and — after this phase — streaming. Rather than add a second hardcoded
production driver, generalize the production driver to dispatch effects through
an injected handler set (the pattern `Turn.Inline` already proves), and have both
non-streaming and streaming supply their own handler sets.

This is executed in two checkpoints to keep the just-merged non-streaming path
provably frozen:

- **Commit A (pure refactor, no streaming):** extract `run_turn_effects/3` into a
  driver parameterized by a handler set (a `%Turn.Driver.Handlers{}` struct).
  Move the existing non-streaming handlers behind it **unchanged**. The
  non-streaming suite (the 1c parity oracle) must stay 100% green. Because this
  commit adds no streaming, a green non-streaming suite proves the driver
  generalization is behavior-preserving *before* streaming exists — any later
  non-streaming regression cannot be blamed on the refactor.
- **Commit B (streaming):** add the streaming handler set and wire the streaming
  entry points to the shared driver. The streaming suite must stay 100% green.

Rejected alternative: a separate, second hardcoded streaming driver ("unify
later"). It duplicates the ~40-line effect-dispatch skeleton permanently if the
"unify later" step never happens, and exposes no injection seam for the Phase 4
`:gen_statem` shell. The chosen approach banks the maintainability and the
extensible driver API now, and the refactor-first sequencing neutralizes its only
real risk (regressing merged code).

### The handler-set seam

A `%Turn.Driver.Handlers{}` struct carries the side-effecting functions the
driver consults, analogous to `Turn.Inline`'s `deps` map and
`Dispatch.Pipeline`. The driver owns the `{config, state}` threading (memory
accumulation); handlers that mutate memory return the updated `config`.

Handlers (one function per injectable effect):

- `call_llm.(config, state, request) -> response`
- `dispatch_tools.(config, calls) -> [result]`
- `convert.(config, raw, output_schema) -> converted`
- `validate.(config, value) -> validated`
- `guard.(config, value) -> :ok` (side-effecting)
- `append.(config, role, content) -> config'` (threads memory)
- `emit.(config, name, meta) -> any` (side-effecting)

`:finalize` and `:fail` remain control flow owned by the driver, not injected.

The streaming handler set is **constructed per run with the `callback` closed
over**, so `call_llm`, `dispatch_tools`, and `guard` can reach it without
threading it through every signature.

### The two handler sets

| Effect | Non-streaming (move behind seam, unchanged) | Streaming (new) |
|---|---|---|
| `call_llm` | `get_response_with_usage` + tool_calls strip when `!has_tools?` + LLM span | `stream_response_from_llm` (incl. incremental-guard consumption when configured) + `build_streaming_assistant_response` + tool_calls strip when `!has_tools?` + LLM span |
| `dispatch_tools` | `dispatch_turn_tools` (Task.async_stream) | same + per-tool `callback.(:tool_result, result)` |
| `convert` | `convert_turn_output` | identity (`fn _c, raw, _os -> raw end`) |
| `validate` | `validate_turn_output` | identity (`fn _c, v -> v end`) |
| `guard` | `run_output_guardrails` | `run_streaming_output_guardrails` (emits `:guardrail_violation` callback event) |
| `append` | `AgentMemory.add_message` | `build_streaming_assistant_response` + `Map.delete(:guardrail_violations)`, then `AgentMemory.add_message` |
| `emit` | iteration debug log (gated on `has_tools?`) | same |

### Entry wiring

`run/2` with `stream: true` already dispatches symmetrically to the
non-streaming path: `if has_tools? -> stream_with_tools else -> stream_response`.

- `stream_with_tools/3` → `run_stream_turn(config, user_input, callback)` — the
  loop. The forced-final at the iteration cap is handled by the FSM's
  `awaiting_final` path (a streaming `call_llm` against the output schema), **not**
  by a recursive `stream_response(config, nil, callback)` call. This matches how
  1c replaced the old recursive forced-final.
- `stream_response/3` → the no-tools streaming path (see Open Question).

`run_stream_turn/3` mirrors `run_turn/2`: admission control (input guardrails +
memory init — streaming does *not* schema-validate input, matching current
behavior) before `Turn.step(:start)`, then drive to a stop, returning
`{config, final_response}`.

## Open Question (resolved against the parity oracle during planning)

`stream_response/3` is **public and tools-capable**: a caller can invoke it
directly on a tools-agent, and today it streams a single turn and returns
*unexecuted* `tool_use` blocks (it has no loop). Routing it through the loop FSM
would either dispatch those tools or strip the blocks — a behavior change for
that narrow direct-call case.

Resolution rule (decide by inspecting the streaming suite, do not guess):

- **If a test pins the current "return unexecuted `tool_use`" behavior**, keep
  `stream_response/3` as a single-shot streamed call that reuses the streaming
  handlers (`call_llm` for one streamed call, `guard`, `append`) **outside** the
  loop FSM. No tool dispatch.
- **If nothing pins it**, route `stream_response/3` through `run_stream_turn/3`
  with no-tools semantics (response_model = output_schema, tool_calls stripped),
  for full symmetry with 1c's `run_without_tools`.

Either way, no public signature changes and the no-tools streaming behavior
reached via `run/2` is preserved.

## Parity Oracle & Verification

- **Oracle:** the existing streaming test suite — `stream_response/3`,
  `stream_with_tools/3`, incremental and accumulate output-guardrail modes,
  per-tool `:tool_result` callbacks, and the iteration-cap forced-final. It must
  stay 100% green throughout both commits.
- **Commit A gate:** full suite green with the non-streaming handlers moved
  behind the new seam and **no streaming code added**.
- **Commit B gate:** full suite green with streaming routed through the shared
  driver; `execute_streaming_tool_loop/3` retired.
- `mix compile --warnings-as-errors --force` clean.
- The non-streaming production behavior is byte-for-byte preserved (handlers moved
  unchanged); the FSM core is unchanged.

## Risks & Mitigations

- **Regressing merged 1c production code (Commit A).** Mitigated by the
  refactor-first checkpoint: Commit A adds no streaming, so a green non-streaming
  suite proves the generalization safe in isolation.
- **Callback ordering / process identity under concurrent tool dispatch.** The
  current streaming loop documents that at concurrency > 1 the `:tool_result`
  callback fires in completion order and runs in a worker process. The streaming
  `dispatch_tools` handler preserves the existing `Task.async_stream` shape and
  `OtelCtx` capture/restore exactly.
- **Incremental-guard tail check and partial-tool-use stripping.** These live in
  `consume_stream_with_incremental_guards/3` and are moved into the streaming
  `call_llm` handler unchanged, so the existing guard tests continue to exercise
  them.

## Deliverables

1. `%Turn.Driver.Handlers{}` (or equivalent) handler-set struct + a driver
   parameterized by it; non-streaming handlers moved behind it (Commit A).
2. Streaming handler set + `run_stream_turn/3` + entry wiring; retire
   `execute_streaming_tool_loop/3` (Commit B).
3. Resolution of the `stream_response/3` open question per the oracle.
4. Streaming and non-streaming suites green; compile clean.
