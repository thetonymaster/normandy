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

### 4.2 `Smoke.Support` additive changes (to `verify/support.exs`)
Two additive, backward-compatible additions (the two existing smokes are untouched):
- `client(extra_options \\ %{})` — extends `client/0` to merge `extra_options` into the **live** client's `options` map (ignored for the stub). Used by the kill-switch scenario to pass `%{structured_outputs: false}`.
- `live?/0` — returns `System.get_env("NORMANDY_SMOKE_STUB") != "true"`. The canonical stub/live check, used by the smoke to gate field-value assertions (see §6).

### 4.3 Schemas used
- `MultiField` — `chat_message :string`, `count :integer` (default 0). Happy-path + a typed scalar.
- `RecoveryFixture` — `page_text :string`, `facts {:array, :string}`. Array + typed-field assertion.
- Inline `OpenMapField` — `io_schema` with a single `field :meta, :map`. Produces a `{:incompatible, {:unsupported_type, :map}}` translation → gate `:skip` → legacy.

## 5. Scenarios & invariants

Every scenario asserts the response **struct type** in both modes (proves `run/2` returned the right struct and the script flow works). The **field-value** assertions run **live-only** (`Smoke.Support.live?/0`), because the stub (`ModelMockup`) returns the seed `output_schema` with fields at their defaults — see §6.

| # | Scenario | Setup | Struct-type invariant (both modes) | Field-value invariants (live-only) | Calls |
|---|----------|-------|-----------------------|-----------------------|-------|
| 1 | Structured happy path | `output_schema: %MultiField{}`, structured on (default) | `match?(%MultiField{}, resp)` | `is_binary(resp.chat_message)`; `is_integer(resp.count)` | 1 |
| 2 | Structured typed fields | `output_schema: %RecoveryFixture{}` | `match?(%RecoveryFixture{}, resp)` | `is_binary(resp.page_text)`; `is_list(resp.facts)`; `Enum.all?(resp.facts, &is_binary/1)`; `length(resp.facts) >= 1` | 1 |
| 3 | Legacy via kill-switch | `client(%{structured_outputs: false})`, `output_schema: %MultiField{}` | `match?(%MultiField{}, resp)` | `is_binary(resp.chat_message)` | 1 |
| 4 | Incompatible-schema fallback | `output_schema: %OpenMapField{}` (open `:map`) | `match?(%OpenMapField{}, resp)` (legacy populated the struct; the call did not crash and degraded to legacy) | — (struct-type is the invariant; the `:map` field's contents are free) | 1 |

Prompts are short, deterministic-leaning instructions (temperature 0.0) that give the model content to fill the schema, e.g. scenario 1: `"Reply with a friendly one-line greeting and the number 3."` The assertions check **shape and types**, not exact content (the model's wording is free).

## 6. Stub dry-run behavior

Under `NORMANDY_SMOKE_STUB=true` the client is `ModelMockup`, whose `Model` protocol impl returns the `response_model` **unchanged** (verified: `test/support/model_mockup.ex` `converse/7` → `response_model`). So in stub mode `BaseAgent.run` returns the **seed** `output_schema` with every field at its default (`%MultiField{chat_message: nil, count: 0}`, `%RecoveryFixture{page_text: "", facts: []}`). The structured gate lives only in the `ClaudioAdapter` impl, so the stub never exercises it — by design: **the stub validates script flow + struct type; the live run validates field values/behavior.**

Therefore each scenario splits its assertions:
- **Struct-type assertion** (`match?(%Schema{}, resp)`) runs in **both** modes — it is the dry-run's real check (the script executed and `run/2` returned the correct struct).
- **Field-value assertions** (binary `chat_message`/`page_text`, integer `count`, non-empty list-of-binaries `facts`) run **live-only**, gated by `Smoke.Support.live?/0`. Under stub they are not asserted; the smoke prints `<label>: skipped (stub)` so the dry-run stays green while the live run stays strict. (We do not rely on default values coincidentally satisfying a check — all field-value checks are uniformly live-gated, which is simpler and honest.)

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

- **10.1 Stub-mode strictness (resolved, empirically grounded):** `ModelMockup.converse` returns the seed `output_schema` unchanged (verified by probe), so the stub cannot satisfy field-value checks. Resolution: struct-type assertions run in both modes; ALL field-value assertions are live-gated via `Smoke.Support.live?/0` (print `skipped (stub)` under `NORMANDY_SMOKE_STUB`), per §6. The dry-run proves flow + struct type for free; the live run proves the field values.
- **10.2 Model nondeterminism:** assertions are shape/type-only, never exact content (no wording is asserted); temperature 0.0 reduces variance. **One exception:** scenario 2 asserts `length(facts) >= 1` — a stronger end-to-end check that a typed array actually round-trips real data, not just an empty list. Constrained decoding does NOT guarantee non-emptiness (the translator strips `minItems`), so this is mitigated by a forceful, facts-first prompt ("List exactly three short, distinct facts about the ocean, putting each fact as its own separate string in the `facts` array (the `facts` array must contain three items)…"). **Residual risk (accepted):** a model run that still returns an empty `facts` fails the smoke; that is the intended strict behavior — a re-run is the remedy, not a code change. (Observed live: the original weak prompt yielded `facts: []`; the forceful prompt is the fix.)
- **10.3 `count`/`facts` population on the legacy path:** for the structured scenarios the schema is enforced by constrained decoding; for any legacy scenario that asserts a non-`chat_message` field, the model is instructed (via the system prompt) to fill it, but the assertion for legacy scenarios (3) is limited to `chat_message` to avoid coupling to legacy-prompt-following fidelity. Structured scenarios (1, 2) assert the richer fields because constrained decoding guarantees the shape (scenario 2's non-empty `facts` is the prompt-dependent exception per §10.2).
