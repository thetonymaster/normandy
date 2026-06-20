# Anthropic Structured Outputs — Design

**Date:** 2026-06-19
**Related:** memory `structured-outputs-direction`; depends on the shipped converse-contract-retry fix (`docs/superpowers/specs/2026-06-19-converse-contract-retry-fix-design.md`) which made the legacy/fallback path correct.

## 1. Overview

Normandy currently obtains JSON from models by prompting for it and parsing the text, retrying with feedback on failure (the legacy `JsonDeserializer` path). Anthropic now offers **native structured outputs** — constrained decoding against a JSON Schema that *guarantees* schema-valid JSON. This design adopts structured outputs as the **primary** path for `ClaudioAdapter`, keeping the legacy prompt-parse-retry path as an automatic **fallback** for the cases structured outputs can't cover.

The result: agent JSON I/O is valid-by-construction by default, with no retry round-trips on the happy path, while still working for incompatible schemas and the refusal/truncation exceptions.

### Goals
- `ClaudioAdapter` uses Anthropic structured outputs by default for every supported model, producing schema-valid output without the parse-retry loop.
- Automatic, transparent fallback to the legacy path when structured outputs don't apply (incompatible schema, kill-switch off) or don't hold (refusal / max_tokens / API rejection).
- No breaking change to the `Model` protocol or to `JsonDeserializer`'s public API.

### Non-goals
- Provider-agnostic structured-output abstraction beyond keeping the `Model` protocol as the seam (OpenAI etc. are future work; the `Model` protocol stays the extension point).
- Exhaustively mirroring Anthropic's evolving schema-complexity limits in the translator (we detect the cheap blockers and rely on API-rejection fallback for the rest — see §4).
- The Phase 2 live `mix normandy.json_smoke` harness (separate; exercises the live wiring).

## 2. Constraints

- **Non-breaking:** no `Model` protocol signature/`@spec` change. `JsonDeserializer.parse_and_validate/3` and `deserialize_with_retry/8` keep signatures and all return shapes.
- **Default-on with kill-switch:** structured outputs are used by default; disable via `Application.get_env(:normandy, :structured_outputs, true)` or per-client `client.options[:structured_outputs]` (per-client overrides global).
- **Normal-path behavior is replaced *only* through the gate** — when the gate skips (disabled/incompatible), behavior is byte-identical to today's legacy path.
- **Full suite green** at every checkpoint; `mix format` before tests; never `git add .`; no AI-authorship attribution.
- **Claudio** dependency upgraded `~> 0.5.0` → `~> 0.6.0` (provides `Claudio.Messages.Request.set_output_format/2`).
- Default JSON adapter is `Poison`.

## 3. Architecture & components

Two new pure/provider-agnostic units, Claudio-specific wiring in the adapter, and reuse of the Phase-1 `Json.*` units.

### 3.1 `Normandy.LLM.Json.SchemaTranslator` (new, pure leaf, zero project deps)
`translate(spec_map) :: {:ok, map()} | {:incompatible, term()}` — Normandy's JSON-schema form → a constrained-decoding-ready JSON Schema. Detail in §4.

### 3.2 `Normandy.LLM.StructuredOutputs` (new) — the gate
- `enabled?(client) :: boolean()` — `client.options[:structured_outputs]` when set, else `Application.get_env(:normandy, :structured_outputs, true)`.
- `schema_for(client, response_model) :: {:ok, map()} | :skip` — `:skip` when disabled OR when the response_model is not a struct OR when `SchemaTranslator.translate/1` returns `{:incompatible, _}`; otherwise `{:ok, json_schema}`. Single routing decision point.

### 3.3 `Normandy.LLM.ClaudioAdapter` (changed) — Claudio wiring
The normal (non-raw) path (`do_converse/7`) routes via `StructuredOutputs.schema_for/2`:
- `{:ok, json_schema}` → `converse_structured/8` (§5).
- `:skip` → the existing legacy body (unchanged).

`converse_structured/8` builds the usual request **plus** `Claudio.Messages.Request.set_output_format(json_schema)`, calls `Claudio.Messages.create/2`, and interprets the result (§5). The `:on_parse_failure` policy application is extracted from `populate_standard_schema/3` into a shared `apply_parse_failure/4` reused by both paths.

### 3.4 Reuse of Phase-1 units
The structured response is valid JSON → decode + bind via `Normandy.LLM.Json.Decoder.decode/3` and `Normandy.LLM.Json.SchemaBinder.bind/3` — no `deserialize_with_retry`, no `RetryFeedback`.

### 3.5 `base_agent.ex` normalizer consolidation (must-verify)
Replace the duplicate `base_agent.ex` `normalize_model_response/1` (~line 1346) with `Normandy.Agents.ConverseResult.normalize/1` so there is a single normalization authority. The implementer must confirm behavior-equivalence against `base_agent`'s tests before swapping (extend `ConverseResult` if a gap exists; do not narrow `base_agent`). If not a clean drop-in → stop and flag.

### 3.6 Claudio upgrade
`mix.exs`: `{:claudio, "~> 0.6.0"}`; `mix deps.update claudio`. `Request.set_output_format(schema_map)` sets `output_config.format = {type: "json_schema", schema: schema_map}`.

## 4. SchemaTranslator detail

Input: the response_model's JSON-schema form via `response_model.__struct__.get_json_schema/0` (equivalently `__schema__(:specification)`), e.g. `%{type: :object, title: "Out", "$schema": "...", properties: %{...}, required: [:chat_message]}`.

`translate/1` walks it recursively:
- **String keys:** all map keys → strings; atom `type` values → strings (`:string`→`"string"`, `:object`→`"object"`, etc.).
- **`additionalProperties: false`** added to every object node.
- **Keep:** `type`, `properties`, `items`, `enum`, `description`, `required`.
- **Strip (unsupported):** `title`, `$schema`, `default`, and length/numeric constraints (`min_length`, `minLength`, `minimum`, `maximum`, `multipleOf`, `maxLength`, `minItems` when > 1).
- **`required`:** `[:chat_message]` → `["chat_message"]` (Anthropic permits optional fields; keep the schema's own required list, not "all keys"). Recurse into `properties` values and array `items`.

**Incompatibility detection (cheap blockers → `{:incompatible, reason}`):**
- **Open object** — `type: :object` with no/empty `properties` (a Normandy `:map` field): constrained decoding can't express an arbitrary-key object under `additionalProperties: false`. → `{:incompatible, {:open_object, key}}`.
- **Runaway nesting** — a depth guard (limit ~8) → `{:incompatible, :too_deep}`, which also defends against any pathological self-reference without explicit cycle tracking.

Everything beyond these (param-count/union limits) is left to the API-rejection fallback (§5).

## 5. Adapter routing & response handling

`do_converse/7`:
```
case StructuredOutputs.schema_for(client, response_model) do
  {:ok, json_schema} -> converse_structured(client, model, temperature, max_tokens, messages, response_model, opts, json_schema)
  :skip              -> <existing legacy body unchanged>
end
```

`converse_structured/8` builds `request |> ... |> Claudio.Messages.Request.set_output_format(json_schema)`, calls `Claudio.Messages.create/2`, and returns the full `{response, usage}` tuple itself — `{interpreted_response, extract_usage(resp)}` on a `{:ok, resp}` (success or refusal/max_tokens), or the legacy path's own `{response, usage}` on the `{:error, _}` fallback (so usage reflects whichever call actually produced the response). `converse/7` returns that tuple directly for the structured route. Interpretation (`handle_structured_response/3`, made offline-testable per §7):

| Claudio result | stop_reason | Action |
|---|---|---|
| `{:ok, resp}` | normal / `end_turn` | `extract_content(resp)` → `Json.Decoder.decode(content, adapter, [])` → `Json.SchemaBinder.bind(parsed, response_model, content)` → **bound struct** |
| `{:ok, resp}` | `refusal` / `max_tokens` | `apply_parse_failure(response_model, extract_content(resp), {:structured_output_incomplete, reason}, context)` — policy applied directly, **no retry** |
| `{:ok, resp}` | normal but decode/bind fails | defensive: `apply_parse_failure(...)` |
| `{:error, _}` | — (request rejected: schema too complex / transient) | **fall back to the legacy path** (re-run without `output_config`) |

`stop_reason` is matched against both atom and string forms.

`apply_parse_failure/4` (extracted from `populate_standard_schema/3`): emits `Logger.warning` + `[:normandy, :json_deserializer, :fallback]` telemetry, then returns the policy result (`:fallback` → `Map.put(response_model, :chat_message, content)` when content is binary, else `response_model`; `:error` → `{:error, reason}`) using the existing `__on_parse_failure_policy__/1` resolver. Both the legacy fallback and the structured refusal/max_tokens path call it — one observability/semantics authority.

## 6. Error handling & backward-compat

- A structured **API error** (rejected request) → legacy path (one full legacy attempt, no `output_config`). A structured **success that refuses/truncates** → policy directly (no legacy re-run) — the deliberate "surface, don't silently re-run" distinction.
- A malformed translator output just yields a Claudio/API rejection → legacy fallback; never a crash.
- `Model` protocol unchanged; `JsonDeserializer` public API unchanged. Disabling the kill-switch reproduces today's behavior exactly.

## 7. Testing strategy

- **`SchemaTranslator`** (riskiest pure unit) — thorough: string-key/type conversion, recursive `additionalProperties:false`, nested objects + arrays, the strip-list, `open-object → :incompatible`, `depth-guard → :incompatible`, and a realistic end-to-end translate of a `BaseAgentOutputSchema`-style spec.
- **`StructuredOutputs`** — `enabled?` (default-true, per-client `false` override, global `false`), `schema_for` (`{:ok, schema}` for a compatible model, `:skip` for incompatible / disabled / non-struct).
- **Structured response handling, offline** — `handle_structured_response/3` made callable on a *fabricated* Claudio response map (the `__raw_completion__` pattern from the retry fix): normal→bound struct; `refusal`→policy; `max_tokens`→policy; malformed-content→policy. The live `set_output_format`+`create` wiring is exercised by the Phase 2 harness.
- **`base_agent` consolidation** — existing `base_agent` tests stay green after the `ConverseResult.normalize/1` swap (the verification gate in §3.5).
- **Default-on safety** — confirm the unit suite drives mock `Model` clients (not `ClaudioAdapter.converse` against real Claudio), so default-on doesn't perturb it; confirm no existing test stubs `Claudio.Messages.create`.
- Full suite green; `mix format` before runs.

## 8. Execution sequence (each line a checkpoint; batch ≤3 then verify)

| # | Step | Gate |
|---|---|---|
| 1 | Claudio `~> 0.6.0` upgrade (`mix.exs` + `deps.update`); confirm `set_output_format/2` + Response `stop_reason` values | compiles; suite green |
| 2 | `SchemaTranslator.translate/1` + thorough unit tests | green |
| 3 | `StructuredOutputs` gate (`enabled?`, `schema_for`) + tests | green |
| 4 | Extract `apply_parse_failure/4` from `populate_standard_schema/3` (legacy path behavior unchanged) | green |
| 5 | `converse_structured/8` + `handle_structured_response/3` + offline response-handling tests; route `do_converse/7` via the gate | green |
| 6 | `base_agent` normalizer consolidation onto `ConverseResult.normalize/1` (verify base_agent tests) | green |
| 7 | Final verification + moduledoc/docs for the structured path and the kill-switch | green |

## 9. Open questions / risks (resolve at plan time)

- **9.1 Schema accessor:** confirm `get_json_schema/0` vs `__schema__(:specification)` is the right source and that nested-schema fields expand inline (so translator recursion sees them). Verify against `lib/normandy/schema.ex`.
- **9.2 Claudio 0.6.0 response shape:** confirm the exact `stop_reason` values (atom vs string) and that `set_output_format/2` serializes `output_config.format` as expected. Verify against the upgraded dep.
- **9.3 Default-on blast radius:** confirm no existing offline test exercises `ClaudioAdapter.converse` with a stubbed Claudio that would now take the structured branch; if one exists, it must set `structured_outputs: false` or be updated.
- **9.4 `:map`/open-object frequency:** if common agent schemas rely on open `:map` fields, they always fall back to legacy — acceptable by design, but worth noting which real schemas are affected.
- **9.5 base_agent consolidation:** if `ConverseResult.normalize/1` is not a clean drop-in for `normalize_model_response/1`, defer the consolidation rather than force it (it's hygiene, not core to this feature).
