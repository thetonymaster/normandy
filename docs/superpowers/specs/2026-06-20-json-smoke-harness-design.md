# JSON / Structured-Outputs Live Smoke Harness — Design

**Date:** 2026-06-20
**Status:** Approved (brainstorming)
**Builds on:** the structured-outputs effort (`docs/superpowers/specs/2026-06-19-structured-outputs-design.md`, shipped on `worktree-refactor-library`, PR #44). This is "Phase 2", the live-API verification deferred by that effort.

## 1. Overview

The structured-outputs effort left one surface unverified offline: `ClaudioAdapter.converse_structured/8`'s live request-building (`set_output_format` → `Claudio.Messages.create`) and the gate's routing against the **real** Anthropic API. The offline suite makes zero network calls, so "does a real Anthropic structured-outputs call return schema-valid JSON that decodes and binds to a populated struct?" is unanswered.

This design adds a **live smoke** — `verify/json_smoke_live.exs` — that drives a small, fixed set of real Haiku calls through the production path and asserts the structured-vs-legacy invariants, closing that gap. It follows the repo's existing `verify/*.exs` smoke pattern exactly.

### Goals
- Verify, against the live API, that the **structured** path returns schema-valid, correctly-typed, bound structs.
- Verify that the **legacy** path still works live, and that the **kill-switch** and **incompatible-schema fallback** route to it correctly.
- Reuse the existing `Smoke.Support` scaffolding (Haiku, call cap, stub mode, assert-or-exit, call report) — no new harness infrastructure.
- Bounded, observable cost: ≤ ~4 live Haiku calls, inside the shared 15-call hard cap; a free stubbed dry-run before any spend.

### Non-goals
- A first-class `mix normandy.json_smoke` Mix task (rejected in favor of the established `verify/*.exs` convention — zero new infra, reuses `Smoke.Support`).
- Tool-use and refusal scenarios (the tools-gate routing decision is already offline-tested; tool-use is hard to assert observably without instrumentation, and refusals are nondeterministic).
- Any change to product code under `lib/` (the harness only consumes the existing public path). The single shared-scaffolding change is an additive option on `Smoke.Support.client/1`.

## 2. Constraints

- **Live calls are billed.** `API_KEY` (fallback `ANTHROPIC_API_KEY`) is read via `System.fetch_env!`; the key value is NEVER printed/logged — only scenario labels and the `LIVE CALLS USED: N` total are emitted. Full model responses are not dumped (assert on shape, print only the invariant label).
- **Hard call cap.** Every live call goes through `Smoke.Support.record_call!`, which halts (exit 2) if the cumulative count exceeds 15. `json_smoke_live.exs` budgets ≤ 4.
- **Runs under `MIX_ENV=test`** (per the existing smokes) so stub mode, protocol-consolidation-off, and the `test/support` fixtures (`Normandy.LLM.Json.TestFixtures`) are available.
- **Invariant-or-exit.** A broken invariant prints `INVARIANT FAILED: <label> — <msg>` and exits non-zero, so a re-run catches regressions. A clean run exits 0 and prints `LIVE CALLS USED: N`.
- **Free dry-run.** With `NORMANDY_SMOKE_STUB=true`, `Smoke.Support.client/0` returns the stub (`ModelMockup`) and `record_call!` is a no-op; the script must run end-to-end clean against the stub before a paid run.

## 3. Architecture

A single script, `verify/json_smoke_live.exs`, structured like `guardrails_live.exs`:

1. `Code.require_file("support.exs", __DIR__)` then `Smoke.Support.start()`.
2. For each scenario: build a `BaseAgent` via `BaseAgent.init/1` with the scenario's `output_schema` (and, for the kill-switch scenario, a client carrying `structured_outputs: false`), `record_call!`, run `BaseAgent.run(agent, prompt)`, and assert the returned struct's shape with `Smoke.Support.assert!`.
3. `Smoke.Support.report()`.

**Why drive through `BaseAgent` (not raw `Model.converse`):** it is the realistic end-to-end path a user hits, and — critically — its `SystemPromptGenerator` injects the JSON-schema instructions the **legacy** scenarios need (a raw `Model.converse` call would send no schema instructions, so the legacy model wouldn't know to emit matching JSON). The structured path needs no prompt instructions (constrained decoding handles it), but routing through `BaseAgent` exercises both uniformly. `BaseAgent.init/1` accepts `optional(:output_schema) => struct()` (base_agent.ex:32) and `BaseAgent.run/2` returns `{config, populated_output_schema_struct}`.

## 4. Components

### 4.1 `verify/json_smoke_live.exs` (new)
The smoke script. Owns the four scenarios and their assertions. Defines the open-`:map` schema inline (`defmodule … do use Normandy.Schema; io_schema … end`), reuses `Normandy.LLM.Json.TestFixtures.{MultiField, RecoveryFixture}` for the others.

### 4.2 `Smoke.Support.client/1` (additive change to `verify/support.exs`)
Extend the existing `client/0` to `client(extra_options \\ %{})` that merges `extra_options` into the live client's `options` map (and is ignored for the stub). Used by the kill-switch scenario to pass `%{structured_outputs: false}`. Backward-compatible: `client()` keeps its current behavior; the two existing smokes are untouched.

### 4.3 Schemas used
- `MultiField` — `chat_message :string`, `count :integer` (default 0). Happy-path + a typed scalar.
- `RecoveryFixture` — `page_text :string`, `facts {:array, :string}`. Array + typed-field assertion.
- Inline `OpenMapField` — `io_schema` with a single `field :meta, :map`. Produces a `{:incompatible, {:unsupported_type, :map}}` translation → gate `:skip` → legacy.

## 5. Scenarios & invariants

| # | Scenario | Setup | Invariant (`assert!`) | Calls |
|---|----------|-------|-----------------------|-------|
| 1 | Structured happy path | `output_schema: %MultiField{}`, structured on (default) | response is `%MultiField{chat_message: m}` with `is_binary(m)` and `count` an integer | 1 |
| 2 | Structured typed fields | `output_schema: %RecoveryFixture{}` | response is `%RecoveryFixture{page_text: p, facts: f}` with `is_binary(p)`, `is_list(f)`, every element of `f` a binary; plus a live-only `length(f) >= 1` (skipped under stub, see §6) | 1 |
| 3 | Legacy via kill-switch | `client(%{structured_outputs: false})`, `output_schema: %MultiField{}` | response is `%MultiField{chat_message: m}` with `is_binary(m)` | 1 |
| 4 | Incompatible-schema fallback | `output_schema: %OpenMapField{}` (open `:map`) | response is `%OpenMapField{}` (legacy populated the struct; the call did not crash and degraded to legacy) | 1 |

Prompts are short, deterministic-leaning instructions (temperature 0.0) that give the model content to fill the schema, e.g. scenario 1: `"Reply with a friendly one-line greeting."` The assertions check **shape and types**, not exact content (the model's wording is free).

## 6. Stub dry-run behavior

Under `NORMANDY_SMOKE_STUB=true` the client is `ModelMockup`, whose own `Model` protocol impl returns a canned response (the structured gate lives only in the `ClaudioAdapter` impl, so the stub never exercises it — by design; the stub validates **script flow**, the live run validates **behavior**).

All **type/shape** assertions are written to hold in both modes: a struct returned by `BaseAgent.run` is always the `output_schema` type with its fields at their defaults unless populated (`count` default `0` is an integer; `facts` default `[]` is a list; `page_text`/`chat_message` populate from any model's content). The per-element check `Enum.all?(facts, &is_binary/1)` is vacuously true on the stub's empty list and strict on real elements — so it needs no guard. The **only** stub-incompatible assertion is scenario 2's non-empty check (`length(facts) >= 1`), which proves the array actually round-tripped real data; it is guarded to run live-only (prints `skipped (stub)` under `NORMANDY_SMOKE_STUB`). This keeps the dry-run green while keeping the live run strict.

## 7. Error handling & safety

- `API_KEY`/`ANTHROPIC_API_KEY` resolved by `Smoke.Support.client/0` via `System.fetch_env!("API_KEY")` — a missing key raises before any spend; the value is never echoed.
- Hard 15-call cap enforced centrally by `record_call!`; `json_smoke_live.exs` adds ≤ 4.
- Any invariant failure → `System.halt(2)` after printing `INVARIANT FAILED`. Network/API exceptions propagate (non-zero exit), which is the correct signal for a smoke.
- No full-response logging; only labels + the call total.

## 8. Testing strategy

The smoke is self-verifying (assert-or-exit). Verification ladder:
1. `NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run verify/json_smoke_live.exs` → runs clean (flow), `LIVE CALLS USED: 0`.
2. `MIX_ENV=test mix run verify/json_smoke_live.exs` (with `API_KEY`) → all four invariants `ok`, `LIVE CALLS USED: 4`, exit 0.
The existing unit suite (`1413 tests, 0 failures`) is unaffected — this adds no `lib/` code and no unit tests.

## 9. Runbook integration

Add one line to `docs/release/1.0.0-e2e-runbook.md` (step 5, live smokes) listing `verify/json_smoke_live.exs` alongside `guardrails_live.exs` / `durable_server_live.exs`, and note its ≤ 4-call budget so the shared 15-cap accounting stays honest.

## 10. Open questions / risks

- **10.1 Stub-mode strictness (resolved):** every type/shape assertion holds in both modes (defaults make them vacuously true on the stub; the per-element binary check is vacuous on an empty list). The single live-only assertion is scenario-2's non-empty `length(facts) >= 1`, guarded to skip under `NORMANDY_SMOKE_STUB` (prints `skipped (stub)`), per §6.
- **10.2 Model nondeterminism:** assertions are shape/type-only, never exact content, so a free-wording Haiku response still passes. Temperature 0.0 reduces variance further.
- **10.3 `count`/`facts` population on the legacy path:** for the structured scenarios the schema is enforced by constrained decoding; for any legacy scenario that asserts a non-`chat_message` field, the model is instructed (via the system prompt) to fill it, but the assertion for legacy scenarios (3) is limited to `chat_message` to avoid coupling to legacy-prompt-following fidelity. Structured scenarios (1, 2) assert the richer fields because constrained decoding guarantees them.
