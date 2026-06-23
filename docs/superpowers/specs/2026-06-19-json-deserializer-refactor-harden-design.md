# JsonDeserializer — Refactor & Harden Design

**Date:** 2026-06-19
**Status:** Draft — awaiting review
**Target:** `lib/normandy/llm/json_deserializer.ex` (`Normandy.LLM.JsonDeserializer`)
**Library version at design time:** v1.1.0 (published)

## 1. Overview

`Normandy.LLM.JsonDeserializer` parses JSON out of raw LLM output and binds/validates
it against a Normandy schema. Today it is a single 825-line module carrying ~9 distinct
responsibilities, grown by accretion (tool-use unwrap in #22, truncated-string recovery
in #23).

This effort does two things at once:

1. **Restructure** the god-module into focused, independently-testable units.
2. **Harden** four concrete robustness gaps found during exploration.

It then adds a **live smoke-test + prompt-tuning workstream** to tune the retry-feedback
prompt against real Haiku/Sonnet/Opus output and convert interesting live failures into
deterministic offline regression fixtures.

### Goals

- Decompose `JsonDeserializer` into a thin facade plus five focused units with clear
  boundaries, each understandable and testable in isolation.
- Fix four hardening targets (adapter inconsistency, silent fallback, prose-wrapped JSON,
  resource guards) — each off the happy path so the default behavior is byte-identical.
- Tune the retry-feedback prompt with live model output, measured by retry-success-rate.
- Capture real malformed-output failure modes as permanent deterministic fixtures.

### Non-goals

- No public API changes (see Constraints).
- No broadening of the truncated-string recovery beyond its current, single failure mode
  (unclosed top-level string at depth 1) except where prose-extraction (#3) adds a
  *separate, fallback-only* path.
- No refactoring of unrelated modules (`claudio_adapter.ex` is touched only at the one
  fallback call site).

## 2. Constraints

- **Public API is frozen.** `parse_and_validate/3` and `deserialize_with_retry/8` keep
  their exact signatures and all current return shapes:
  `{:ok, struct}`, `{:error, {:json_parse_error, reason, content}}`,
  `{:error, {:validation_error, changeset, content}}`,
  `{:error, {:max_retries_reached, reason}}`, `{:error, :llm_call_failed}`,
  `{:error, {:unexpected_parse_result, content}}`.
  Restructuring is internal-only; new capabilities are additive (new opts / new modules).
- **Published library (v1.1.0).** Internals may move into new modules under a new
  `Normandy.LLM.Json.*` namespace; anyone reaching into private functions breaks, but
  documented-API callers are unaffected.
- **Configured adapter is `Poison`** in dev and test (the only JSON dependency). Hardening
  #1 must keep the Poison path byte-identical.
- **Per project CLAUDE.md:** `mix format` before each test run; pre-existing test failures
  must be fixed even if outside the immediate change.

## 3. Target module layout

New namespace `lib/normandy/llm/json/`. Dependency flow is strictly layered — leaf units
have zero project dependencies.

```
JsonDeserializer  (facade — PUBLIC API unchanged)
   parse_and_validate/3, deserialize_with_retry/8
   owns: retry orchestration loop, adapter resolution
        │
        ├─► Json.ContentCleaner   clean fences + (new) extract JSON from prose      [pure: str→str]
        ├─► Json.Decoder          adapter.decode + optional recovery + size guard   [→ Scanner, adapter]
        │      └─► Json.Scanner   truncated-string byte-scanner (recover/scan/build) [pure: binary→{:ok,_}|:error]
        ├─► Json.SchemaBinder     cast + normalize_field_names + unwrap "arguments"  [→ Normandy.Validate]
        └─► Json.RetryFeedback    build error feedback + augment messages           [→ Validate, Message, adapter]
```

| Unit | Module | Absorbs (current private fns) | Why isolate |
|---|---|---|---|
| Scanner | `Normandy.LLM.Json.Scanner` | `recover_truncated_string`, `scan/7`, `build_closers` | Gnarliest, fully self-contained byte logic — 0 deps; biggest unit-test win |
| ContentCleaner | `Normandy.LLM.Json.ContentCleaner` | `clean_content` (+ new prose extraction) | Pure string→string; home for hardening #3 |
| Decoder | `Normandy.LLM.Json.Decoder` | `decode_with_optional_recovery`, `top_level_object?`, recovery telemetry | Wraps adapter + Scanner; home for hardening #4 (size guard) |
| SchemaBinder | `Normandy.LLM.Json.SchemaBinder` | `cast_map`, `maybe_unwrap_arguments` + helpers, `normalize_field_names`, `get_permitted_fields`, `get_required_fields` | The "parsed-map → validated struct" mapping |
| RetryFeedback | `Normandy.LLM.Json.RetryFeedback` | `build_error_feedback`, `format_validation_errors`, `format_json_error`, `augment_messages_with_error` | Home for hardening #1 (adapter-consistent encode) |
| Facade | `Normandy.LLM.JsonDeserializer` | `parse_and_validate`, `deserialize_with_retry`, `deserialize_loop`, `retry_with_feedback`, `extract_content_from_response` | Public API + orchestration only |

### Data flow for `parse_and_validate`

```
content
  → ContentCleaner.clean (+ prose-extract fallback)   # hardening #3
  → Decoder.decode (size guard + optional recovery)   # hardening #4, wraps Scanner
  → SchemaBinder.bind (cast + normalize + unwrap)
  → {:ok, struct} | {:error, reason}
```

`deserialize_with_retry` is the retry loop in the facade around that pipeline; on error it
calls `RetryFeedback` to build feedback + augment messages, calls `Normandy.Agents.Model.converse`,
and repeats up to `:max_retries`.

## 4. Hardening changes

Each lands in exactly one unit and is **off the happy path**, so the default (Poison)
behavior is byte-identical — characterization tests stay green; new tests cover new behavior.

### #1 — Adapter consistency (RetryFeedback)

`build_error_feedback` currently hardcodes `Poison.encode!(spec, pretty: true)` at two
sites (current lines 668, 715), bypassing the configurable `:adapter`. With Poison
configured the output is identical; the fix only changes behavior when a caller swaps the
adapter (today that silently still used Poison, even potentially as a non-dependency).

**Change:** thread the resolved `adapter` (already used for `decode`) into RetryFeedback and
encode via `adapter.encode!(spec, pretty: true)`. Pure correctness; zero risk to the Poison
default path.

### #2 — Configurable parse-failure policy (claudio_adapter.ex:850)

Today, when parsing fails after all retries, `populate_standard_schema` silently does
`Map.put(schema, :chat_message, raw_text)` — converting a hard failure into possibly-corrupt
data with no signal (violates "No Silent Fallbacks").

**Change:** add `:on_parse_failure` (`:fallback | :error`), read from app config with an
optional per-call override, **default `:fallback`** (preserves current behavior):

- `:fallback` — still returns a usable schema (text → `:chat_message`) so the agent loop
  doesn't crash, but first emits `Logger.warning` + `[:normandy, :json_deserializer, :fallback]`
  telemetry. No longer silent.
- `:error` — propagate `{:error, reason}`; the caller decides. Changes the contract of
  `populate_standard_schema` (which currently always returns a schema), so this path is
  opt-in only.

This is the one change at the integration boundary (outside the deserializer proper).

### #3 — Robust content extraction (ContentCleaner)

`clean_content` currently strips ` ```json ` / ` ``` ` fences only at the exact start/end and
trims. It misses prose-wrapped output like `Here's the JSON:\n```json\n{…}\n```\nHope that helps!`.

**Change — strictly a fallback:** the current fence-strip + trim path runs first, unchanged.
Only if the cleaned content still fails a strict decode do we attempt to locate the outermost
balanced `{…}` / `[…]` substring (string- and escape-aware, reusing the Scanner's byte-walk
discipline) within surrounding prose. The happy path is untouched; risk is bounded because
extraction only fires after a strict-parse failure.

### #4 — Resource / input guard (Decoder)

No max-input-size limit today; the byte-scanner and adapter run unbounded on untrusted LLM
output.

**Change:** a configurable `:max_input_bytes` checked before any scan/decode. Over the limit →
`{:error, {:input_too_large, size, limit}}`. Default set generously (proposed **10 MB**, high
enough that real vision `page_text` payloads never trip it) and overridable per call. Normal
sizes: no behavior change.

## 5. Testing strategy

- **Characterization pass first.** Extend the existing 574-line suite
  (`test/llm/json_deserializer_test.exs`) to pin *every* current return shape and edge path
  (all six error tuples, the unwrap matrix, the recovery cases, the normalize cases)
  **before touching any code**. This is the net that proves extraction changes nothing.
- **RetryFeedback characterization tests assert structural invariants, not verbatim text**
  — the feedback string *contains* the schema, the specific error, and correction
  instructions — so the prompt can be tuned (step 14) without rewriting tests.
- **Per extraction:** move code → run full suite → green = checkpoint. No behavior change
  permitted in an extraction step.
- **Per hardening change:** TDD — write the failing test for the new behavior first,
  implement, green — *plus* a test asserting the Poison/default path is unchanged.
- **Per new unit:** Scanner, ContentCleaner, Decoder, SchemaBinder, RetryFeedback each get a
  focused unit-test file (now possible because they're isolated).
- `mix format` before every test run. Any pre-existing failures get fixed.

## 6. Live smoke-test + prompt-tuning harness

A new **`mix normandy.json_smoke`** task — a tool, not a test. No assertions; non-determinism
stays out of `mix test`.

- **Key resolution:** reads `System.get_env("API_KEY") || System.get_env("ANTHROPIC_API_KEY")`
  and builds `%Normandy.LLM.ClaudioAdapter{api_key: key}` explicitly. Fails loudly with a
  clear message if neither is set (no silent fallback). This bridges the gap that the key is
  in `API_KEY` while `claudio_adapter.ex:21` reads `ANTHROPIC_API_KEY`.
- **Model IDs** (from the `claude-api` reference, current as of 2026-06): Haiku
  `claude-haiku-4-5`, Sonnet `claude-sonnet-4-6`, Opus `claude-opus-4-8`. No date suffixes.
- **Battery** — a fixed set of (prompt, schema) scenarios engineered to elicit each
  malformed-output failure mode:
  - prose-wrapped / fenced JSON,
  - double-nested / tool-use-envelope output,
  - near-`max_tokens` truncation (exercises the recovery path),
  - tricky string content (newlines, unicode, escaped quotes).
- **Metric — retry-success-rate.** Per (model, scenario): does the deserializer yield a valid,
  schema-conforming struct within N retries? Record attempts-to-success (0 = first shot,
  1–2 = needed feedback, ✗ = never). Aggregate into a per-model correction-rate table.
- **Tuning loop** (operator-driven): run → read table → edit `RetryFeedback` wording → re-run
  → keep what raises correction-rate. **Tiered:** Haiku + Sonnet while tuning; Opus only to
  validate the final prompt.
- **Fixture capture:** interesting *new* failure modes get written to
  `test/support/fixtures/json/` (mirroring the existing Nemotron-VL fixture) and become
  deterministic offline regression tests — the durable "harden with live examples" payoff.
- **Cost visibility:** tally Claudio's reported token usage per model and print estimated
  spend at $1/$5 (Haiku), $3/$15 (Sonnet), $5/$25 (Opus) per MTok each run.

## 7. Execution sequence (each line is a checkpoint; batch ≤3 then verify)

| # | Step | Gate |
|---|---|---|
| 1 | Characterization tests extended (incl. RetryFeedback structural invariants) | full suite green |
| 2 | Extract **Scanner** | green |
| 3 | Extract **ContentCleaner** | green |
| 4 | Extract **Decoder** (wraps Scanner) | green |
| 5 | Extract **SchemaBinder** | green |
| 6 | Extract **RetryFeedback** | green |
| 7 | Facade now thin — verify | green |
| 8 | Harden #1 adapter-consistent encode | green + default unchanged |
| 9 | Harden #4 input size guard | green + default unchanged |
| 10 | Harden #3 robust prose extraction | green + happy path unchanged |
| 11 | Harden #2 configurable `:on_parse_failure` | green + default `:fallback` unchanged |
| 12 | Build `mix normandy.json_smoke` (key resolution, battery, report, cost tally) | runs end-to-end vs Haiku on a tiny battery |
| 13 | Baseline run (Haiku + Sonnet) with current RetryFeedback prompt | report captured |
| 14 | Tuning loop: tweak RetryFeedback wording → re-run → keep improvements; validate on Opus | correction-rate ≥ baseline |
| 15 | Capture interesting live failures → fixtures + deterministic offline tests | full `mix test` green |

## 8. Open questions / risks

- **`adapter.encode!/2` arity** (#1): assumes the configured adapter exposes `encode!/2`
  with a `pretty: true` option (Poison and Jason both do). If a future adapter doesn't, the
  encode falls back to non-pretty; to be confirmed when implementing.
- **`:max_input_bytes` default** (#4): proposed 10 MB. To be validated against the largest
  real `page_text` payloads before locking in.
- **Prose-extraction ambiguity** (#3): a payload with multiple top-level `{…}` regions could
  extract the wrong one. Mitigated by firing only after a strict-parse failure and by
  string/escape-aware balanced scanning; edge cases to be covered by tests.
