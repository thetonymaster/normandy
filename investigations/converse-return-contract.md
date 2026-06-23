# Investigation: `Model.converse/7` return-contract inconsistency

**Date:** 2026-06-19
**Trigger:** While gathering interfaces to plan the Phase 2 `mix normandy.json_smoke` harness, the JSON feedback-retry loop was found non-functional with the real `ClaudioAdapter`.

## Summary (one line)

`Normandy.Agents.Model.converse/7` has an ambiguous return contract — `struct()` **or** `{struct(), usage}` — and `ClaudioAdapter` returns the tuple form, but 2 of 3 in-repo callers only handle the bare-struct form. Every test uses mock clients that return bare structs, so the gap was never caught.

## FACTS (verified)

- **F1.** Protocol `@spec` (`lib/normandy/agents/model.ex`): `converse(...) :: struct() | {struct(), map() | nil}`. The contract is explicitly dual-shaped.
- **F2.** `ClaudioAdapter.converse/7` returns the TUPLE form on success: `{normalized_response, extract_usage(response)}` (`lib/normandy/llm/claudio_adapter.ex:129`).
- **F3.** The deserializer retry loop accepts ONLY `response when is_struct(response)`, else `{:error, :llm_call_failed}` (`lib/normandy/llm/json_deserializer.ex:316,335`). A 2-tuple is not a struct.
- **F4 (probe-verified).** Driving `deserialize_with_retry` with two mock clients carrying identical valid-JSON payloads — one returning a bare struct, one returning `{struct, usage}`:
  - bare struct → `{:ok, ...}` (retry recovers)
  - `{struct, usage}` → `{:error, :llm_call_failed}` (retry dies)
  Same payload; the only difference is the tuple wrapper.
- **F5.** `summarizer.ex:203` matches `%{chat_message: summary} when is_binary(summary)` and routes anything else to `{:error, {:unexpected_response, other}}` (`lib/normandy/context/summarizer.ex:203-207`). ClaudioAdapter's tuple hits the `other` branch → summarization errors with the real adapter. (Code-verified; same mechanism as F3/F4.)
- **F6.** `base_agent.ex` IS tuple-aware: `call_llm_with_resilience/4` is typed `:: {struct(), map() | nil}` and passes the result through (`lib/normandy/agents/base_agent.ex:289-305`). This is the only caller consistent with F2.
- **F7.** Both test mock clients return BARE STRUCTS, never tuples: `ModelMockup.converse` → `response_model` (`test/support/model_mockup.ex:22`); `MockSummarizerClient.converse` → `%{response_model | chat_message: summary}` (`test/support/mock_summarizer_client.ex:42`). This is why F3/F5 were never caught by the suite.
- **F8 (nesting).** `ClaudioAdapter.converse` is NOT a raw-completion call. It runs the full pipeline: `Claudio.Messages.create` → `convert_response_to_normandy` (claudio_adapter.ex:733) → `populate_standard_schema` (821) → `deserialize_with_retry(content, schema, client=self, ...)` (836). So when the deserializer retry loop calls `converse`, the adapter RE-ENTERS `deserialize_with_retry`, returning an already-*parsed* struct wrapped in the tuple. The retry loop, however, was written to expect RAW content it can re-parse (`extract_content_from_response/1`). Two retry layers, mismatched.

## Production impact (high-confidence inference from F1-F8; not live-verified)

- **B1.** When an agent's first LLM output is malformed JSON, the deserializer makes the corrective (feedback-bearing) API call, then discards the response on the `is_struct` tuple mismatch → `{:error, :llm_call_failed}` → silent raw-text fallback (the one Task 10 made observable). The self-correction loop never succeeds with the real adapter.
- **B2.** Conversation summarization (`summarizer.ex`) returns `{:error, {:unexpected_response, {struct, usage}}}` with the real adapter.
- **B3.** Phase 2's premise (measure/tune retry-success-rate against live models) is unmeasurable until B1 is fixed — every retry reports `:llm_call_failed` regardless of prompt wording.

## Competing fix THEORIES

- **T1 — Unwrap the tuple in the retry loop only (minimal).** Add `{response, _usage} when is_struct(response)` alongside the bare-struct clause. *Fixes F3 crash but NOT F8:* the unwrapped `response` is an already-parsed struct, so `extract_content_from_response` yields parsed prose, and re-parsing it as JSON fails. Band-aid; leaves summarizer (F5) broken.
- **T2 — Retry loop unwraps AND returns the already-parsed struct as `{:ok, struct}`.** Trusts ClaudioAdapter's nested parse. *Works for the happy correction, but* masks failure: on inner parse failure `populate_standard_schema` returns a fallback *struct* (raw text in `:chat_message`), which the outer loop would accept as `{:ok}`. Also leaves summarizer broken and keeps the double-retry nesting.
- **T3 — Normalize the contract to ALWAYS `{struct(), usage}`.** Update protocol, both mocks, and the two bare-struct callers (retry loop + summarizer) to destructure. *Fixes F3+F5 crashes and de-ambiguates the protocol.* Still leaves the retry-loop semantic redundancy (F8) — but combined with a decision on T5/T6 it's clean. Touches 5 files.
- **T4 — Normalize the contract to ALWAYS bare `struct()`; carry usage out-of-band** (telemetry / a separate `last_usage` accessor). *Fixes F3+F5 by making one shape.* base_agent must get usage elsewhere. Doesn't fix F8.
- **T5 — Give the retry loop a RAW-completion path** (new optional protocol callback `raw_complete/…`, or a `raw: true` opt that makes `ClaudioAdapter.converse` skip `populate_standard_schema` and return raw text). The deserializer becomes the single parse+retry authority; converse-for-retry returns raw content as designed. *Fixes F8 properly; eliminates double nesting.* Moderate: adds protocol surface + mock updates.
- **T6 — Make the deserializer NOT re-enter via the parsing client.** `populate_standard_schema` should not pass `client=self` (a full-pipeline client) into `deserialize_with_retry`. Restructure so retry calls a low-level completion. Overlaps T5; bigger.
- **T7 — Do nothing; accept raw-text fallback as the de-facto behavior.** Rejected: B1+B2 are real correctness regressions; the entire retry-feedback subsystem and summarization are dead with the real adapter.

## Tests run

- **Probe (F4):** *What:* drove `deserialize_with_retry("not json", %MultiField{}, client, …, max_retries: 1)` with a bare-struct mock vs a `{struct, usage}` mock, identical inner JSON. *Why:* deterministically separate "tuple wrapper" from payload as the cause. *Found:* bare → `{:ok}`, tuple → `{:error, :llm_call_failed}`. *Means:* F3 is the live cause; the tuple wrapper alone breaks recovery. (Temp test; removed.)

## Recommendation

The defect is a **systemic contract inconsistency**, not a one-line bug:
1. **De-ambiguate `Model.converse`'s return** — pick ONE shape (recommend **always `{struct(), usage}`**, matching the production-proven `base_agent` path, F6) and fix the two bare-struct callers (retry loop F3, summarizer F5) plus both mocks (F7). This alone clears the two crash bugs (B1 partial, B2).
2. **Resolve the retry-loop nesting (F8)** — the harder architectural call: give the deserializer retry loop a raw-completion path (T5) so it owns parse+retry cleanly, rather than re-entering the full adapter pipeline and trusting/duplicating its result.

Because this is two production bugs + a protocol-contract change + a retry-architecture decision (touching the `Model` protocol, `ClaudioAdapter`, the deserializer, `summarizer`, and the test mocks), it warrants its own **brainstorm → plan → execute** effort BEFORE the Phase 2 harness — which depends on a working retry path. This is the "harden with live examples" payoff, surfaced by reading rather than by live calls.
