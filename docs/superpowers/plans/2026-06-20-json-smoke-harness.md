# JSON / Structured-Outputs Live Smoke Harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `verify/json_smoke_live.exs`, a live-API smoke that verifies the structured-outputs + legacy JSON pipeline against the real Anthropic API (the surface not covered by the offline suite).

**Architecture:** A new `verify/*.exs` smoke following the existing pattern (`guardrails_live.exs`), reusing `Smoke.Support` (Haiku, stub/live client from `API_KEY`, 15-call cap, assert-or-exit, call report). It drives four scenarios through `BaseAgent.init/1` + `BaseAgent.run/2` (the realistic path; the legacy scenarios get their JSON-schema system prompt for free). Struct-type assertions run in both stub and live modes; field-value assertions are live-only.

**Tech Stack:** Elixir, `mix run` scripts under `MIX_ENV=test`, Claudio (live), `Normandy.LLM.Json.TestFixtures`.

**Reference:** `docs/superpowers/specs/2026-06-20-json-smoke-harness-design.md`.

## Global Constraints

- **No `lib/` product-code changes.** Only `verify/support.exs` (additive helpers), the new `verify/json_smoke_live.exs`, and one runbook line.
- **API key never logged.** `API_KEY` (fallback `ANTHROPIC_API_KEY`) is read only via `System.fetch_env!` inside `Smoke.Support.client/1`; never print the key or full model responses — only scenario labels and `LIVE CALLS USED: N`.
- **Live calls are billed and capped.** Every live call goes through `Smoke.Support.record_call!` (hard cap 15, shared across all smokes). This smoke budgets exactly 4. Implementer verification uses the FREE stub dry-run only; the live run is a separate manual acceptance step (see end of plan) — **implementers must NOT make live/billed calls.**
- **Runs under `MIX_ENV=test`** so stub mode and `test/support` fixtures are available.
- **Stub vs live split:** struct-type assertions (`match?(%Schema{}, resp)`) run both modes; field-value assertions are gated by `Smoke.Support.live?/0` (the stub `ModelMockup.converse` returns the seed `output_schema` unchanged, so its fields are at defaults).
- **`mix format`** is not required for `.exs` scripts in `verify/` (they are excluded from the formatter's inputs); still, keep them clean. Never `git add .` — add files individually. No AI-authorship attribution in commits.

---

### Task 1: `Smoke.Support` additive helpers (`client/1`, `live?/0`)

**Files:**
- Modify: `verify/support.exs` (the `client/0` function, ~lines 15-24; add `live?/0`)

**Interfaces:**
- Produces:
  - `Smoke.Support.client(extra_options \\ %{}) :: struct()` — stub (`ModelMockup`) under `NORMANDY_SMOKE_STUB=true`; else `%Normandy.LLM.ClaudioAdapter{}` whose `options` is `Map.merge(%{timeout: 60_000, max_retries: 1}, extra_options)`. `client()` (no arg) is unchanged behavior.
  - `Smoke.Support.live?() :: boolean()` — `System.get_env("NORMANDY_SMOKE_STUB") != "true"`.
- Consumes: nothing.

- [ ] **Step 1: Replace `client/0` with `client/1` and add `live?/0`**

In `verify/support.exs`, replace the existing `client/0` function:

```elixir
  @doc "Stub client when NORMANDY_SMOKE_STUB=true (free), else the live Claudio adapter."
  def client do
    if System.get_env("NORMANDY_SMOKE_STUB") == "true" do
      %NormandyTest.Support.ModelMockup{}
    else
      %Normandy.LLM.ClaudioAdapter{
        api_key: System.fetch_env!("API_KEY"),
        options: %{timeout: 60_000, max_retries: 1}
      }
    end
  end
```

with:

```elixir
  @doc """
  Stub client when NORMANDY_SMOKE_STUB=true (free), else the live Claudio adapter.
  `extra_options` is merged into the live client's options (ignored for the stub),
  e.g. `client(%{structured_outputs: false})` to force the legacy path.
  """
  def client(extra_options \\ %{}) do
    if System.get_env("NORMANDY_SMOKE_STUB") == "true" do
      %NormandyTest.Support.ModelMockup{}
    else
      %Normandy.LLM.ClaudioAdapter{
        api_key: System.fetch_env!("API_KEY"),
        options: Map.merge(%{timeout: 60_000, max_retries: 1}, extra_options)
      }
    end
  end

  @doc "True for a real (paid) run, false under NORMANDY_SMOKE_STUB=true."
  def live?, do: System.get_env("NORMANDY_SMOKE_STUB") != "true"
```

- [ ] **Step 2: Verify `live?/0` + stub branch of `client/1` (free)**

Run:
```bash
NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run -e 'Code.require_file("verify/support.exs"); IO.inspect({Smoke.Support.live?(), Smoke.Support.client(%{structured_outputs: false}).__struct__})'
```
Expected (ignore any OTLP/exporter log noise): the tuple `{false, NormandyTest.Support.ModelMockup}` — `live?` is `false` under stub, and `client/1` accepts the extra-options arg and returns the stub struct.

- [ ] **Step 3: Verify the live-branch option merge (free — no API call, dummy key)**

Run:
```bash
API_KEY=dummy MIX_ENV=test mix run -e 'Code.require_file("verify/support.exs"); c = Smoke.Support.client(%{structured_outputs: false}); true = c.options.structured_outputs == false; true = c.options.timeout == 60_000; IO.puts("MERGE OK")'
```
Expected: prints `MERGE OK`. This constructs the live `ClaudioAdapter` struct (no network call) and asserts `structured_outputs: false` merged in while the existing `timeout` is preserved. (If `API_KEY` is unset the script raises on `fetch_env!`; the dummy value is only used to build the struct.)

- [ ] **Step 4: Confirm the two existing smokes still load (backward compat)**

Run:
```bash
NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run verify/guardrails_live.exs 2>&1 | tail -3
```
Expected: the guardrails smoke runs against the stub and prints `LIVE CALLS USED: 0` (its `client()` no-arg calls still work — `client/1`'s default arg preserves the old behavior). It is fine if guardrails prints its own scenario output; the point is it does not crash on a `client/0` arity error.

- [ ] **Step 5: Commit**

```bash
git add verify/support.exs
git commit -m "test(verify): add Smoke.Support.client/1 options merge and live?/0"
```

---

### Task 2: `verify/json_smoke_live.exs` smoke + runbook entry

**Files:**
- Create: `verify/json_smoke_live.exs`
- Modify: `docs/release/1.0.0-e2e-runbook.md` (step 5, the live-smokes list)

**Interfaces:**
- Consumes: `Smoke.Support.{start/0, client/1, model/0, record_call!/0, assert!/3, live?/0, report/0}` (Task 1); `Normandy.Agents.BaseAgent.{init/1, run/2}`; `Normandy.LLM.Json.TestFixtures.{MultiField, RecoveryFixture}`.
- Produces: nothing (a runnable script).

- [ ] **Step 1: Write the smoke script**

Create `verify/json_smoke_live.exs`:

```elixir
# verify/json_smoke_live.exs — live smoke for the JSON / structured-outputs pipeline.
# Run under MIX_ENV=test (stub mode + test fixtures need it).
#   Free dry-run:  NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run verify/json_smoke_live.exs
#   Live (PAID):   MIX_ENV=test mix run verify/json_smoke_live.exs   # needs API_KEY, uses 4 Haiku calls
#
# Verifies (live): structured outputs return schema-valid, correctly-typed, bound
# structs; the kill-switch and an incompatible (open :map) schema both fall back to
# the legacy path. Struct-type checks run in both modes; field-value checks are live-only.
Code.require_file("support.exs", __DIR__)

alias Normandy.Agents.BaseAgent
alias Normandy.LLM.Json.TestFixtures.MultiField
alias Normandy.LLM.Json.TestFixtures.RecoveryFixture

defmodule JsonSmoke.OpenMapField do
  use Normandy.Schema

  io_schema "open-map field — incompatible with structured outputs, forces legacy fallback" do
    field(:meta, :map, description: "free-form metadata")
  end
end

Smoke.Support.start()
live? = Smoke.Support.live?()

run = fn output_schema, client, prompt ->
  Smoke.Support.record_call!()

  agent =
    BaseAgent.init(%{
      client: client,
      model: Smoke.Support.model(),
      temperature: 0.0,
      max_tokens: 256,
      output_schema: output_schema
    })

  {_cfg, response} = BaseAgent.run(agent, prompt)
  response
end

skip = fn label -> IO.puts("  #{label}: skipped (stub)") end

# --- Scenario 1: structured happy path (default structured-on) ---
IO.puts("scenario 1: structured happy path")
r1 = run.(%MultiField{}, Smoke.Support.client(), "Reply with a friendly one-line greeting and the number 3.")
Smoke.Support.assert!("s1 returns a MultiField struct", match?(%MultiField{}, r1), inspect(r1))

if live? do
  Smoke.Support.assert!("s1 chat_message is a string", is_binary(r1.chat_message), inspect(r1))
  Smoke.Support.assert!("s1 count is an integer", is_integer(r1.count), inspect(r1))
else
  skip.("s1 field values")
end

# --- Scenario 2: structured typed fields, incl. a string array ---
IO.puts("scenario 2: structured typed fields")
r2 =
  run.(
    %RecoveryFixture{},
    Smoke.Support.client(),
    "Set page_text to a one-sentence summary about the ocean, and put three short ocean facts in facts."
  )

Smoke.Support.assert!("s2 returns a RecoveryFixture struct", match?(%RecoveryFixture{}, r2), inspect(r2))

if live? do
  Smoke.Support.assert!("s2 page_text is a string", is_binary(r2.page_text), inspect(r2))
  Smoke.Support.assert!("s2 facts is a list", is_list(r2.facts), inspect(r2))
  Smoke.Support.assert!("s2 facts elements are strings", Enum.all?(r2.facts, &is_binary/1), inspect(r2))
  Smoke.Support.assert!("s2 facts is non-empty", length(r2.facts) >= 1, inspect(r2))
else
  skip.("s2 field values")
end

# --- Scenario 3: legacy path via per-client kill-switch ---
IO.puts("scenario 3: legacy via kill-switch")
r3 =
  run.(
    %MultiField{},
    Smoke.Support.client(%{structured_outputs: false}),
    "Reply with a friendly one-line greeting and the number 3."
  )

Smoke.Support.assert!("s3 returns a MultiField struct", match?(%MultiField{}, r3), inspect(r3))

if live? do
  Smoke.Support.assert!("s3 chat_message is a string", is_binary(r3.chat_message), inspect(r3))
else
  skip.("s3 field values")
end

# --- Scenario 4: incompatible (open :map) schema → gate :skip → legacy ---
IO.puts("scenario 4: incompatible-schema fallback")
r4 =
  run.(
    %JsonSmoke.OpenMapField{},
    Smoke.Support.client(),
    "Return a small piece of free-form metadata about yourself in the meta field."
  )

Smoke.Support.assert!(
  "s4 incompatible schema degrades to legacy and returns the struct",
  match?(%JsonSmoke.OpenMapField{}, r4),
  inspect(r4)
)

Smoke.Support.report()
```

- [ ] **Step 2: Stub dry-run (free) — must be green**

Run:
```bash
NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run verify/json_smoke_live.exs 2>&1 | grep -vE "OTLP|opentelemetry|normandy (agent|llm)" | tail -25
```
Expected: each scenario prints its `ok: s* returns a … struct` line and `s* field values: skipped (stub)`, ending with `LIVE CALLS USED: 0`. No `INVARIANT FAILED`. Exit code 0.

If any struct-type assertion fails here, the script's call/return wiring is wrong — fix it (this is the dry-run's job) before moving on. (OTLP/opentelemetry exporter warnings and `normandy agent/llm` info lines are expected noise, filtered above.)

- [ ] **Step 3: Add the runbook entry**

In `docs/release/1.0.0-e2e-runbook.md`, in section `## 5. Live smokes (PAID …)`, add a third line alongside the two existing `mix run verify/*.exs` commands:

```bash
MIX_ENV=test mix run verify/json_smoke_live.exs 2>&1 | tee evidence/10-json-smoke-live.txt
```

and update that section's note to read that the JSON smoke adds **≤ 4** Haiku calls (so the shared ≤ 15 total still holds).

- [ ] **Step 4: Re-run the stub dry-run after the edit (free) — still green**

Run:
```bash
NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run verify/json_smoke_live.exs 2>&1 | tail -3
```
Expected: unchanged — ends with `LIVE CALLS USED: 0`, exit 0. (The runbook edit is docs-only; this just confirms nothing in the script regressed.)

- [ ] **Step 5: Commit**

```bash
git add verify/json_smoke_live.exs docs/release/1.0.0-e2e-runbook.md
git commit -m "test(verify): add live JSON/structured-outputs smoke (json_smoke_live)"
```

---

## Live acceptance (manual — runs after both tasks, NOT a subagent step)

The implementer subagents verify only the FREE stub dry-run. The paid live run is run once, deliberately, by the controller/human with `API_KEY` set:

```bash
export API_KEY=<anthropic key>          # never echoed; consumed by System.fetch_env!
MIX_ENV=test mix run verify/json_smoke_live.exs 2>&1 | tee evidence/10-json-smoke-live.txt
```

Acceptance: every `ok:` line present (struct-type + all live field-value assertions), `LIVE CALLS USED: 4`, exit 0, no `INVARIANT FAILED`. A non-zero exit or any `INVARIANT FAILED` line is a real finding about the live structured-outputs path.

---

## Self-Review

**Spec coverage:** §3 architecture (verify/*.exs + Smoke.Support + BaseAgent + MIX_ENV=test) → Tasks 1-2. §4.1 smoke script → Task 2. §4.2 `client/1` + `live?/0` → Task 1. §4.3 schemas (MultiField, RecoveryFixture, inline OpenMapField) → Task 2 Step 1. §5 four scenarios + invariants → Task 2 Step 1 (struct-type both modes; field-value live-gated). §6 stub behavior (struct-type both, field-value live-only) → Task 2 Step 1 `if live?`. §7 safety (fetch_env!, cap, exit codes) → Global Constraints + reused `Smoke.Support`. §8 testing ladder (stub dry-run then live) → Task 2 Step 2 + Live acceptance. §9 runbook → Task 2 Step 3.

**Placeholder scan:** all code is complete; commands have expected output; no TBD/TODO.

**Type consistency:** `client/1` (Task 1) consumed as `Smoke.Support.client()` / `client(%{structured_outputs: false})` (Task 2); `live?/0` (Task 1) consumed as `Smoke.Support.live?()` (Task 2). Schema names `MultiField`/`RecoveryFixture` match `Normandy.LLM.Json.TestFixtures`; `JsonSmoke.OpenMapField` defined inline before use. Assertion shapes match §5.
