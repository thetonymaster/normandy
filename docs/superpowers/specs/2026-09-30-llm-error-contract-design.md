# LLM error contract — design

Date: 2026-09-30. Branch: `feat/claudio-0.7-migration` (Normandy 2.0).
Source: `investigations/codebase-audit-2026-09/` theme 1 — LLM-1, LLM-4, AGENTS-7 (+ the
streaming half of AGENTS-11's "errors returned as a success value").

## Problem

A failed LLM call looks like a successful one.

- `ClaudioAdapter.handle_error/2` (`claudio_adapter.ex:920`) does `IO.warn` and returns the
  caller's blank `response_model`. Any `{:error, %Claudio.APIError{}}` — 401, 403, 404, 400,
  429, 529, 5xx — and any transport error becomes an empty reply.
- `OpenAICompatibleAdapter.converse/7` does the same (`{response_model, nil}` after `IO.warn`).
- `BaseAgent.call_llm_with_resilience/4` wraps whatever `Model.converse/7` returns in
  `{:ok, result}`, so `Retry` and `CircuitBreaker` only ever see raised exceptions. They never
  fire on API errors.
- `ConverseResult.normalize/1` treats any term, including `{:error, _}`, as a model response.
- `Summarizer.call_llm_for_summary/5` receives the blank `chat_message: ""`, returns
  `{:ok, ""}`, and compaction replaces old history with an empty summary (data loss).
- Streaming: a mid-stream `error` event or an `{:error, _}` stream item is dropped by
  `StreamProcessor.build_final_message/1`; a stream that ends early is returned as a complete
  message. A failed `stream_converse` is turned into `{config, %{error: error}}` plus `IO.warn`
  by `run_stream_turn/3`.

What already works and is kept: a *raised* exception from `converse/7` is retried by `Retry`
(when configured), counted by `CircuitBreaker`, and re-raised by `raise_llm_call_error/1`, so
`BaseAgent.run/2` fails loudly for exceptions today.

## Decisions (approved by Q)

1. When an LLM call fails for good, `BaseAgent.run/2` and the DSL-generated `run/1-3`
   **raise a typed `Normandy.LLMError`** (replacing today's `RuntimeError` built from
   `inspect(reason)`; API errors, previously silent, now raise).
2. **Retry when the adapter says so**: adapters classify each failure with a `retryable?`
   flag; the default `retry_if` retries exactly those.
3. **Approach A**: `Model.converse/7` gains an additive `{:error, %LLMError{}}` return.
   Errors are values inside the library; the raise happens once, at the `BaseAgent` edge.
4. **Streaming raises too**: `stream_response/3` and `stream_with_tools/3` raise
   `LLMError` instead of returning `{config, %{error: _}}`.

## Design

### 1. `Normandy.LLMError` — `lib/normandy/llm/error.ex`

```elixir
defexception [:type, :status, :retryable?, :message, :reason]
```

| Field | Type | Meaning |
|---|---|---|
| `type` | atom, one of the table below | failure class |
| `status` | `non_neg_integer() \| nil` | HTTP status when there was one |
| `retryable?` | `boolean()` | whether a retry can help; set by the adapter |
| `message` | `String.t()` | `"LLM call failed: <type> (<status>): <provider message>"`, status part omitted when nil |
| `reason` | `term()` | the original provider error (e.g. `%Claudio.APIError{}`, `%Req.TransportError{}`) for debugging |

Types: `:rate_limit`, `:overloaded`, `:server`, `:transport`, `:authentication`,
`:permission`, `:not_found`, `:invalid_request`, `:invalid_output`, `:stream`,
`:circuit_open`, `:unknown`.

Amendment (found while planning): under `on_parse_failure: :error`,
`ClaudioAdapter.apply_parse_failure/4` already returns `{:error, reason}` from `converse/7`
for model output that failed to parse or a structured reply that stopped early (refusal,
max_tokens). It becomes `{:error, %LLMError{type: :invalid_output, retryable?: false,
reason: reason}}` (the deserializer already retried; a refusal is not fixed by resending).
Today that `{:error, _}` is nested inside the `{response, usage, meta}` triple; the adapter
returns it at the top level instead.

Rule (project-wide): neither `message` nor any log line built from an `LLMError` inspects a
client struct, `client.options`, or `req_options` (they may hold an API key or auth header).
The provider message comes from the provider's error body (`APIError.message`), not from
inspecting the request.

### 2. Classification

`ClaudioAdapter` (from `%Claudio.APIError{type, status_code}` or a transport error):

| Input | `type` | `retryable?` |
|---|---|---|
| `:rate_limit_error` (429) | `:rate_limit` | true |
| `:overloaded_error` (529) | `:overloaded` | true |
| `:api_error` with `status_code >= 500`, `== 408`, or nil | `:server` | true |
| `:authentication_error` (401) | `:authentication` | false |
| `:permission_error` (403) | `:permission` | false |
| `:not_found_error` (404) | `:not_found` | false |
| `:invalid_request_error` (400, 413, …) | `:invalid_request` | false |
| `%Req.TransportError{}` / Mint transport errors (timeout, closed, econnrefused) | `:transport` | true |
| anything else | `:unknown` | false |

`OpenAICompatibleAdapter` (from `%Req.Response{status: s}` with `s` outside 200..299, or
`{:error, exception}` from `Req.post/2`): 429 → `:rate_limit`/true; 408 and 500..599 →
`:server`/true; 401 → `:authentication`/false; 403 → `:permission`/false; 404 →
`:not_found`/false; other 4xx → `:invalid_request`/false; transport → `:transport`/true.
Provider message from `body["error"]["message"]` when present, else `"HTTP <status>"`.

One shared helper builds the struct (`Normandy.LLMError.new/1` or per-adapter private
functions — implementation's choice); each adapter owns its own classification table.

### 3. Non-streaming call path

- **Adapters.** `ClaudioAdapter.handle_error/2` (both call sites, `:221` legacy and `:282`
  structured) returns `{:error, %LLMError{}}`. `OpenAICompatibleAdapter`'s two error branches
  return `{:error, %LLMError{}}`. All `IO.warn` calls on these paths are removed.
- **`Model` protocol docs.** `converse/7` may return a bare response, `{response, usage}`,
  `{response, usage, meta}`, or `{:error, %Normandy.LLMError{}}`. Additive: implementations
  that never return an error are unaffected.
- **`ConverseResult.normalize/1`** returns `{:ok, {response, usage, meta}}` or
  `{:error, %LLMError{}}`.
  - `{:error, %LLMError{} = e}` → `{:error, e}`.
  - `{:error, other}` (third-party `Model`) → `{:error, %LLMError{type: :unknown,
    retryable?: false, reason: other, message: "LLM call failed: unknown"}}`.
  - Bare response, 2-tuple and 3-tuple → `{:ok, ...}` exactly as today.
  - All callers updated: `BaseAgent`, `Summarizer`, `JsonDeserializer`, and any other match
    on its old return.
- **`BaseAgent.call_llm_with_resilience/4`.** The retried function returns `{:error, e}` as
  is (instead of `{:ok, {:error, e}}`) and `{:ok, normalized}` on success. The default
  `retry_if` gains, first: `{:error, %LLMError{retryable?: r}} -> r`. A user-supplied
  `retry_if` receives the same `{:error, %LLMError{}}` term. `CircuitBreaker` already records
  `{:error, _}` as a failure (`circuit_breaker.ex` `execute_and_record/2`) — no change there.
  Final unwrap:
  - `{:error, {%LLMError{} = e, _attempts, _errors}}` / `{:error, %LLMError{} = e}` → `raise e`
  - `{:error, :open}` (breaker) → raise `%LLMError{type: :circuit_open, retryable?: false}`
  - exceptions → re-raised as today (`reraise` with the original stacktrace)
  - any other reason → raise `%LLMError{type: :unknown, reason: reason}` (replaces the
    `RuntimeError` with `inspect(reason)`)
- **`JsonDeserializer` parse-retry loop** (`json_deserializer.ex:330`): on `{:error, e}`
  from `normalize`, stop retrying and return the error so the adapter's `converse/7` returns
  `{:error, e}`. An LLM failure is never treated as a parse failure.
- **`Summarizer.call_llm_for_summary/5`**: `{:error, e}` → `{:error, e}`; a `chat_message`
  that is not a non-empty binary → `{:error, :empty_summary}`. The existing chain
  (`compress_conversation` → `WindowManager.truncate_conversation/ensure_within_limit` →
  `Compactor.WindowManager.run/2`) then leaves memory unchanged and reports
  `%{compacted: false, error: reason}`. Fix `WindowManager.ensure_within_limit/2` and
  `truncate_conversation/2` specs to `{:ok, struct()} | {:error, term()}`, and remove the
  `.dialyzer_ignore.exs` entry for `behaviours/compactor/window_manager.ex` (`:pattern_match`),
  which becomes reachable.
- **Turn interpreters.** No new Turn effect. `Turn.Driver`/`Turn.Inline` let the raise from
  `call_turn_llm/3` propagate (as exceptions do today); `Turn.Server` already converts a crashed
  LLM task into `{:llm_error, {:task_down, reason}}` and an `{:error, _}` reply.

### 4. Streaming

- **`StreamProcessor.stream_error/1`** (new, public): `[event] -> nil | %LLMError{}`.
  Returns `%LLMError{type: :stream, retryable?: false}` when the events contain
  `%{type: "error"}` (message from its `error` payload), an `{:error, reason}` item, or no
  `%{type: "message_stop"}` event (message `"stream ended before message_stop"`).
  `build_final_message/1` is unchanged.
- **`BaseAgent.stream_response_from_llm`**: after collecting events in both consumers (the
  accumulate path and `consume_stream_with_incremental_guards/3`), call `stream_error/1`; on
  an error return `{:error, e}`. A connection-time `{:error, reason}` from `stream_converse/7`
  is classified into an `LLMError` the same way (Claudio errors via the §2 table).
- **`run_stream_turn/3`**: the `{:stream_turn_error, error, config}` catch raises the
  `LLMError` (wrapping a non-`LLMError` reason as `:unknown`) instead of `IO.warn` +
  `{config, %{error: error}}`.
- Streams are not retried (callbacks have already received partial output). Streaming
  retry/breaker (AGENTS-11) is out of scope.
- An incremental-guard halt (deliberate early stop on a guardrail violation) is not an error:
  that path skips the missing-`message_stop` check.

## Testing

`Req.Test` stubs through `client.options[:req_options]` (Bypass only for transport tests
already using it). Each test is seen failing before the fix.

- **ClaudioAdapter**: one test per §2 row — 401, 403, 404, 400, 429, 529, 500, 408, and a
  transport error (`Req.Test.transport_error/2`) — asserting `{:error, %LLMError{type, status,
  retryable?}}`, and that the message contains no API key (assert the test key string is
  absent). Both legacy and structured paths.
- **OpenAICompatibleAdapter**: the same matrix by status.
- **ConverseResult.normalize/1**: the four input shapes.
- **BaseAgent**: with `retry_options`, a retryable error is attempted `max_attempts` times
  then raises `LLMError`; a non-retryable error is attempted once then raises; without
  `retry_options` the error raises on the first call; with a circuit breaker, repeated
  failures open it and the next call raises `type: :circuit_open`.
- **Summarizer / compaction**: an LLM error leaves memory unchanged and the compactor meta
  carries the error; an empty summary is an error, not a wipe.
- **JsonDeserializer**: an LLM error during a parse retry surfaces as `{:error, e}`, with no
  further attempts.
- **Streaming**: a mid-stream `error` event, an `{:error, _}` item, and a stream without
  `message_stop` each make `stream_response/3` raise `LLMError{type: :stream}`; an
  incremental-guard halt does not. Update the existing "handles streaming errors gracefully"
  test to `assert_raise`.
- Gate: `mix precommit` (compile --warnings-as-errors, credo --strict, dialyzer, tests),
  plus `mix test.postgres` and `mix test.redis`.

## Docs

- `MIGRATING-2.0.md`, new section: `Model.converse/7` may return `{:error, %LLMError{}}`
  (custom callers of `converse/7` must handle it); `run/2` and the streaming functions raise
  `Normandy.LLMError` (code that rescued `RuntimeError` must rescue `Normandy.LLMError`); API
  errors used to return an empty response and now raise; `stream_response/3` /
  `stream_with_tools/3` no longer return `%{error: _}`; the default `retry_if` retries
  `retryable?` errors, and enabling Claudio's client-level `retry:` too multiplies attempts.
- `Model` moduledoc, `ClaudioAdapter` / `OpenAICompatibleAdapter` moduledocs, and the
  `stream_response/3` docs ("Returns") updated.
- Commit type `feat(llm)!:` with a `BREAKING CHANGE:` footer. No `CHANGELOG.md` / `@version`
  edits (cocogitto).

## Out of scope

- LLM-1(f): narrowing the structured→legacy fallback on `:invalid_request_error`.
- AGENTS-11: retry/breaker for streaming.
- OTP-1, OTP-4, OTP-6, AGENTS-8 (other "errors become data" items in non-LLM modules).
- LLM-2 (Summarizer `summary_role`) — next item in the audit's order.
