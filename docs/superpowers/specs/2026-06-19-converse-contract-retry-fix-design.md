# Model.converse Contract + Retry-Architecture Fix — Design

**Date:** 2026-06-19
**Background investigation:** `investigations/converse-return-contract.md` (FACTS, nesting trace, competing theories, probe evidence).

## 1. Overview

`Normandy.Agents.Model.converse/7` has a dual-shaped return contract — `struct()` **or** `{struct(), usage}`. `ClaudioAdapter` (the production client) returns the tuple form, but two of the three in-repo callers only handle the bare-struct form, so they break against the real adapter:

- **`JsonDeserializer` feedback-retry loop** (`json_deserializer.ex:316`) accepts only `is_struct(response)`; ClaudioAdapter's tuple falls to `{:error, :llm_call_failed}` → silent raw-text fallback. The JSON self-correction loop is dead in production.
- **`Summarizer`** (`summarizer.ex:203`) matches `%{chat_message: summary}`; the tuple falls to `{:error, {:unexpected_response, …}}` → summarization fails with the real adapter.

Every test mock returns a bare struct, so the gap was never caught. There is also a deeper layering defect: `ClaudioAdapter.converse` is not a raw completion — it re-enters its own `deserialize_with_retry`, so the retry loop's corrective call gets an already-*parsed* struct rather than raw content to re-parse. Two retry layers, mismatched.

This design fixes both crash bugs by de-ambiguating the return contract at the consumption points (non-breaking), and removes the redundant nesting by giving the retry loop a raw-completion path so the deserializer is the single parse+retry authority.

### Goals
- The JSON feedback-retry loop self-corrects correctly when driven by the real `ClaudioAdapter`.
- `Summarizer` works with the real `ClaudioAdapter`.
- Exactly one `deserialize_with_retry` runs per top-level `converse` (no nested retry).
- No breaking change to the `Model` protocol or to `JsonDeserializer`'s public API (v1.1.0 semver preserved).

### Non-goals
- Changing `Model` protocol signatures or `@spec` shape, or adding a required callback.
- Relocating the retry loop out of the deserializer (Approach C, rejected — keeps retry client-agnostic where it lives today).
- The Phase 2 `mix normandy.json_smoke` live harness — a separate effort, unblocked once this lands.

## 2. Constraints

- **Non-breaking:** external `Model` implementations (the public extension point per CLAUDE.md) must keep working without code changes. No new required protocol callback; `raw` is an opt non-raw clients ignore.
- **Public API frozen:** `JsonDeserializer.parse_and_validate/3` and `deserialize_with_retry/8` keep their signatures and all current return shapes (`{:ok, struct}`, `{:error, {:json_parse_error, …}}`, `{:error, {:validation_error, …}}`, `{:error, {:max_retries_reached, …}}`, `{:error, :llm_call_failed}`, `{:error, {:unexpected_parse_result, …}}`, `{:error, {:input_too_large, …}}`).
- **Full suite green** at every checkpoint; `mix format` before test runs (project CLAUDE.md).
- **Default adapter** is `Poison`; the offline/Poison parsing path is unchanged.

## 3. Chosen approach — Approach A (`raw: true` opt)

Two layers:

**Part 1 — de-ambiguate the contract (non-breaking).** Flatten the dual-shaped `converse` return at the consumption points via a shared normalizer, so no caller assumes one shape.

**Part 2 — `raw: true` completion path (single retry authority).** The retry loop asks the client for raw output; `ClaudioAdapter` honors it by returning raw text without re-entering its parse pipeline.

## 4. Components

### 4.1 New: `Normandy.Agents.ConverseResult`
File: `lib/normandy/agents/converse_result.ex`. One pure function:

```elixir
@spec normalize(term()) :: {term(), map() | nil}
def normalize({response, usage}) when is_struct(response) or is_binary(response), do: {response, usage}
def normalize(response) when is_struct(response) or is_binary(response), do: {response, nil}
def normalize(other), do: {other, nil}
```

The single place the dual-shaped protocol return is flattened. Pure, fully unit-testable. (`base_agent.ex` already destructures the tuple directly and is left as-is; it may optionally adopt `normalize/1` for consistency, but that is not required for correctness.)

### 4.2 `Normandy.Context.Summarizer` (`summarizer.ex:194-208`)
Normalize before matching:

```elixir
{response, _usage} = Normandy.Agents.ConverseResult.normalize(
  Normandy.Agents.Model.converse(client, model, temperature, max_tokens, messages, response_model, [])
)

case response do
  %{chat_message: summary} when is_binary(summary) -> {:ok, summary}
  other -> {:error, {:unexpected_response, other}}
end
```

Part 1 only — summarizer never needs raw output.

### 4.3 `Normandy.LLM.JsonDeserializer` (`retry_with_feedback/12`)
Pass `raw: true`, normalize, and derive the next content:

```elixir
llm_opts = [raw: true | (if tools != [], do: [tools: tools], else: [])]

{response, _usage} =
  Normandy.Agents.ConverseResult.normalize(
    Normandy.Agents.Model.converse(client, model, temperature, max_tokens, augmented_messages, schema, llm_opts)
  )

cond do
  is_binary(response) ->
    deserialize_loop(response, schema, client, model, temperature, max_tokens, messages, opts, adapter, attempt, max_retries)

  is_struct(response) ->
    deserialize_loop(extract_content_from_response(response), schema, client, model, temperature, max_tokens, messages, opts, adapter, attempt, max_retries)

  true ->
    {:error, :llm_call_failed}
end
```

A binary (ClaudioAdapter raw mode) is used directly as content; a struct (external clients that ignore `raw`, or mocks) goes through the existing `extract_content_from_response/1`, preserving today's behavior; anything else → `:llm_call_failed`.

### 4.4 `Normandy.LLM.ClaudioAdapter` (`converse/7`)
Add an early raw branch; the normal path is unchanged:

```elixir
def converse(client, model, temperature, max_tokens, messages, response_model, opts \\ []) do
  if Keyword.get(opts, :raw, false) do
    converse_raw(client, model, temperature, max_tokens, messages, opts)
  else
    # ... existing body, unchanged ...
  end
end

defp converse_raw(client, model, temperature, max_tokens, messages, opts) do
  claudio_client = build_claudio_client(client)
  enable_caching = Map.get(client.options, :enable_caching, false)
  tools = Keyword.get(opts, :tools, [])
  mcp_servers = Keyword.get(opts, :mcp_servers, nil)

  request =
    Claudio.Messages.Request.new(model)
    |> add_temperature(temperature)
    |> add_max_tokens(max_tokens)
    |> add_messages(messages, enable_caching)
    |> add_tools(tools, enable_caching)
    |> add_mcp_servers(mcp_servers)
    |> add_client_options(client.options)

  case Claudio.Messages.create(claudio_client, request) do
    {:ok, response} -> {extract_content(response), extract_usage(response)}
    {:error, error} -> {:error, error}
  end
end
```

Raw mode returns `{raw_text, usage}` — skipping `convert_response_to_normandy` → `populate_standard_schema` → the nested `deserialize_with_retry`. On a Claudio API error it returns `{:error, error}` (it must **not** fabricate an empty struct), which the retry loop maps to `:llm_call_failed` via `normalize/1` + the `cond` guard.

### 4.5 Test mocks (`test/support/`)
Add a mock `Model` client whose `converse/7`, under `raw: true`, returns valid raw JSON text and records that it received `raw: true` (the malformed *initial* content is supplied as the deserializer's first argument, not by the mock). Existing bare-struct mocks (`ModelMockup`, `MockSummarizerClient`) are unchanged — they now flow through `normalize/1` cleanly.

## 5. Data flow (before → after)

**Before:** corrective `converse` re-enters `populate_standard_schema` → nested `deserialize_with_retry`, returning `{struct, usage}`; the retry loop's `is_struct` guard rejects the tuple → `:llm_call_failed` → silent fallback.

**After:** corrective `converse(…, raw: true)` returns `{raw_text, usage}` directly (no nesting); the retry loop normalizes, sees a binary, and re-parses it. Exactly one `deserialize_with_retry` per top-level `converse`. `base_agent` still receives `{parsed_struct, usage}` and is unchanged.

## 6. Error handling & backward-compat

- `normalize/1` never raises; unexpected shapes return `{other, nil}` and the retry loop's `cond` maps non-struct/non-binary responses to the frozen `{:error, :llm_call_failed}`.
- Protocol signatures/`@spec` untouched; `raw` is an opt non-raw clients ignore; both legacy return shapes are accepted by `normalize/1`. No external impl breaks.
- `deserialize_with_retry/8` keeps its frozen signature and return shapes; only its internal corrective call changes.

## 7. Testing strategy

- **Unit — `ConverseResult.normalize/1`:** struct-tuple, bare struct, bare binary, binary-tuple, and an "other" shape.
- **Key regression (offline):** drive `deserialize_with_retry` with a mock that returns malformed initial content and, under `raw: true`, valid raw JSON → assert `{:ok, struct}` recovers AND the mock received `raw: true` (proves the opt is threaded). This is the permanent form of the bug-proving probe.
- **Normalize-tuple regression:** a mock returning a `{struct, usage}` tuple of valid raw JSON also recovers (proves `normalize` handles tuples without `raw`).
- **Summarizer regression:** a mock returning `{struct, usage}` → `{:ok, summary}`.
- **ClaudioAdapter raw branch:** see Open Question 8.1 — either stub `Claudio.Messages.create` (if the existing tests already do) or unit-test `converse_raw`'s request-build + return mapping behind a seam, with live HTTP covered by the Phase 2 harness.
- Full suite green; `mix format` before runs.

## 8. Open questions / risks

- **8.1 ClaudioAdapter raw-branch offline testability.** `converse_raw` calls the real `Claudio.Messages.create` (network). To resolve when writing the plan: check how `claudio_adapter_test.exs` currently exercises `converse` (does it stub Claudio?). If stubbable, add an offline raw-branch test; otherwise extract the Claudio-call seam so the raw branch's logic is unit-testable and defer the HTTP path to the Phase 2 live harness. Either way, do not leave the raw branch entirely unexercised offline.
- **8.2 External `Model` implementations.** Confirm no documented external extension points rely on a specific single return shape before relying on the non-breaking claim; the normalizer accepts both shapes regardless, so risk is low.
- **8.3 Double-API-call cost was already incurred** by the broken code (it made the corrective call then discarded it); the fix makes that call productive rather than adding cost.

## 9. Execution sequence (each line a checkpoint; batch ≤3 then verify)

| # | Step | Gate |
|---|---|---|
| 1 | `ConverseResult.normalize/1` + unit tests | green |
| 2 | Summarizer normalizes converse result (+ regression test with tuple-returning mock) | green |
| 3 | Retry loop: `raw: true` + normalize + content `cond` (+ raw-recovery regression test with a raw-returning mock; + tuple-recovery test) | green |
| 4 | ClaudioAdapter `raw` branch (`converse_raw`) + offline test per 8.1 | green |
| 5 | Full-suite verification + remove any temp scaffolding | green |
