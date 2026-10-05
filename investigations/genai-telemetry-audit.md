# GenAI telemetry & OTel audit — 2026-10-02

Branch `feat/claudio-0.7-migration` @ 68aed61. Read-only audit, three parallel
agents (LLM call span; agent/tool coverage; context propagation), spot-checked
against code by the coordinator. Probes live in the session scratchpad, not the repo.

Spec: OTel GenAI semconv, now at `github.com/open-telemetry/semantic-conventions-genai`
(main). All `gen_ai.*` attributes are **Development** stability; `error.type` and
`server.*` are Stable. Recent renames: `gen_ai.usage.cache_write.input_tokens`
(was cache_creation), `gen_ai.response.time_to_first_chunk`.

Normandy emits only `:telemetry` events; `opentelemetry` is test-only. Users bridge.
The audit asks: (1) does metadata carry what semconv needs, (2) do all paths emit,
(3) does trace context survive process hops so bridged spans nest.

Legend: **V** = verified (probe output or code read by coordinator), **C** = code
read by an agent only, **B** = believed.

## A. Ranked findings

### HIGH

1. **Turn.Server turns are orphan traces.** V
   `run/2` sends `{:turn, user_input}` with no ctx (`turn/server.ex:132`);
   `spawn_task` (`:785`) spawns workers with no `OtelCtx.restore`. Probe: run-start
   handler and `call_llm` both see no caller ctx. The captures at `:989`/`:1033`
   run inside the worker and snapshot an empty ctx. Run, llm_call, tool spans each
   become separate roots.
   Fix: carry `OtelCtx.capture()` in the `:turn` call; attach in `:idle` before the
   run span, store in `Data`; restore at top of `spawn_task` worker; detach after
   run stop/exception (long-lived process → needs token-returning restore + detach).

2. **Streaming llm_call stop metadata has no usage.** V
   `stream_meta/1` (`base_agent.ex:1004`) returns only `served_by` /
   `input_transformations`. Log line still prints tokens via fallback at `:1547`, so
   logs and telemetry disagree. `gen_ai.client.token.usage` not derivable for streams.
   Fix: put `final_message.usage` into stop metadata; test in `base_agent_served_by_test.exs`.

3. **`usage.input_tokens` excludes cached tokens.** V
   Raw Anthropic usage forwarded (`claudio_adapter.ex:1151`). Semconv anthropic.md:
   cache read + write MUST be added to input_tokens. A naive bridge reports 10 for 1010.
   Also: refusal-fallback `usage.iterations` not summed (Claudio `response.ex:172-180`). C
   Fix: keep raw `usage`; add normalized `input_tokens` (sum), `output_tokens`,
   `cache_read_input_tokens`, `cache_write_input_tokens`; document semantics.

4. **Failed calls lose billed usage.** V
   `{:error, %LLMError{}}` path discards `collect_retry_usage(ref, nil)`
   (`claudio_adapter.ex:244`), including paid JSON-parse retries. `:exception` metadata
   has no usage.
   Fix: carry accumulated usage on `LLMError` (or meta) into exception metadata.

5. **Spans that start and never stop.** C (c is V)
   a. `Reactive.race` brutal-kills losers (`reactive.ex:103, 256`); workflow `race` uses it.
   b. `on_timeout: :kill_task` in `batch/processor.ex:130`,
      `parallel_orchestrator.ex:142, 253`, `reactive.ex:166` kills BaseAgent.run mid-span.
   c. Turn.Server has no `terminate/3` and **no catch-all `:info` clause** — every
      `:info` clause matches `:running` + current `task_ref` or `:DOWN` for it
      (`server.ex:426-460`). Any stray/late message crashes the server
      (FunctionClauseError, hit by the probe). Robustness bug beyond telemetry.
   d. Workers killed with the server leave llm_call/tool spans open.
   Fix: catch-all `:info` that logs; `terminate/3` closes in-flight run span;
   synthetic `:exception` with `reason: :killed` for killed tasks, or graceful shutdown.

### MED

6. **Coordination fan-out drops ctx.** V (Reactive.all probe), C (rest)
   Reactive `:87, :157, :240`; ParallelOrchestrator `:136, :242`; Batch.Processor `:130`;
   AgentProcess `:118` (inline engine), `:498, :528, :553`. No `OtelCtx` in
   `coordination/`, `dsl/`, `batch/`. Fix: capture/restore as in `base_agent.ex:669`.

7. **Individual LLM attempts invisible.** V
   3 retry attempts → 1 span (`base_agent.ex:336-363`); JSON parse retries and the
   structured-outputs 400 → legacy second request also hidden. Duration includes
   backoff sleeps; per-attempt `error.type` lost.
   Fix: `[:normandy, :llm, :request, *]` span per HTTP attempt (semconv CLIENT
   span); at minimum `attempts`, `json_retries`, `structured_fallback` on stop.

8. **Approval wait inside the run span.** V (probe: 500 ms wait → 501 ms run)
   Default `approval_timeout_ms` 300 000. Mixes human think-time into agent latency.
   Fix: end run span `status: :parked` on park; linked continuation on resume; or
   `[:normandy, :turn, :approval, :start|:stop]`.

9. **Durable resume and `approve/2` lose lineage.** C
   Resumed turn emits no run `:start` (`server.ex:555` comment); no trace ctx
   persisted. `approve/2` cast carries no ctx (`:136`).
   Fix: inject W3C carrier into persisted turn state; on resume start run span with
   link + `resumed: true`.

10. **Tool span metadata too thin.** V
    `span_execute` (`base_agent.ex:1634`) sends `%{tool_name, agent_name}` + `status`.
    `execute_fn` gets `(config, prepared, call.name)` (`dispatch.ex:271`) so
    `gen_ai.tool.call.id` is unreachable. Missing `tool.type`, `tool.description`,
    `error.type` (timeout vs crash vs `{:error,_}` all collapse to `status: :error`).
    Fix: pass `%ToolCall{}` to `execute_fn`; add `tool_call_id`, `tool_description`,
    `tool_type`, `error_type`; opt-in args/result.

11. **llm_call missing finish reason, response id, request params, provider.** V/C
    `response_meta/1` (`claudio_adapter.ex:1056-1079`) drops `stop_reason` and `id`.
    Start metadata is `%{model, agent_name, iteration}`: no temperature, max_tokens,
    stream, effort, structured-output flag. No provider key (`gen_ai.provider.name`
    is Required; adapter is pluggable so it can't be inferred).

12. **Run metadata minimal and path-dependent.** C
    BaseAgent `%{model, agent_name}` (`base_agent.ex:407`); Turn.Server adds
    `session_id`. No turn/session id on llm_call or tool spans. `agent_name` nil by
    default. Rejected input: Turn.Server replies with no span; BaseAgent emits run
    `:exception`. Fix: shared `run_metadata/2` used by both shells.

13. **No cross-service W3C propagation.** V (grep: no `traceparent` in lib/ or Claudio)
    A2A client sends only `authorization`; `transport_opts` can't add headers.
    `A2A.Server.handle_message/2` never sees headers. MCP not injected.

14. **No span-hierarchy tests.** V
    Executor OTel tests (19/0 pass) assert a ctx *value* reaches the task, not
    parent/child spans. Fix: SDK-backed test (`otel_simple_processor` +
    `otel_exporter_pid` + tiny bridge) asserting caller → run → llm_call/tool for
    BaseAgent.run, Turn.Server.run, Reactive.all (last two fail today).

15. **No workflow/orchestration span** (`invoke_workflow` SHOULD). C

### LOW

16. Coverage gaps: direct `stream_response/3` / `stream_with_tools/3` have no run
    span (`base_agent.ex:1101, 1155`); Turn.Inline emits nothing; denied /
    budget-denied / expired tool calls get no span. C
17. No time-to-first-chunk for streaming. C
18. No `gen_ai.conversation.id`, `server.address`. B (availability unchecked)
19. json_deserializer events carry no model/agent (correlatable via process ctx). C
20. `OtelCtx.restore/1` discards the attach token — fine only in short-lived Tasks. C
21. Test env logs "OTLP exporter module opentelemetry_exporter not found";
    `config :opentelemetry, traces_exporter: :none` in test.exs. V (agent run)
22. Docs: no user-facing event catalogue. CHANGELOG.md:626 documents
    `[:normandy, :llm, :call, *]`, never emitted (real: `[:normandy, :agent, :llm_call, *]`). V
    Compaction event documented only in a `@doc false` comment and MIGRATING-2.0.md.

### Holds (verified)

- `:telemetry.span` emits `:exception` for raise/throw/exit, including streaming
  errors; `{:error, %LLMError{}}` becomes `:exception` with `reason.type` usable as
  `error.type`.
- No prompt/system/output/user content in default metadata (no leak; also no opt-in
  capture path). Guardrail violations include configured terms/patterns, not user text.
- `OtelCtx` copies the whole ctx (span + baggage), is a no-op without OTel.

## B. Attribute map (llm_call)

| GenAI attribute | Normandy |
|---|---|
| operation.name (Req) | implicit in event name |
| provider.name (Req) | MISSING |
| request.model | `model` |
| response.model | `served_by` (when reported) |
| request.temperature / max_tokens / top_p / stop_sequences | MISSING |
| request.stream (CR) | MISSING |
| request.reasoning.level | MISSING (`effort` exists in options) |
| output.type (CR) | MISSING |
| response.id / finish_reasons | MISSING (available, dropped) |
| usage.input_tokens | `usage.input_tokens`, wrong semantics; absent on stream/error |
| usage.output_tokens | non-streaming success only |
| usage.cache_read / cache_write | raw Anthropic keys (old name for write) |
| response.time_to_first_chunk | MISSING |
| error.type | `:exception` `reason.type` |
| conversation.id, server.address | MISSING |
| content (Opt-In) | absent, no opt-in |

## C. Suggested fix order

1. Turn.Server catch-all `:info` + `terminate/3` (#5c) — crash bug, smallest change.
2. Hierarchy test harness (#14) — makes #1, #6 provable before fixing them.
3. Turn.Server ctx propagation (#1), coordination ctx (#6).
4. Usage correctness: streaming usage (#2), normalized tokens (#3), error usage (#4).
5. Metadata enrichment (#10, #11, #12) behind one shared metadata builder.
6. Event catalogue doc + CHANGELOG fix (#22), with a test that every call site is listed.
7. Larger design items: per-attempt spans (#7), approval park (#8), resume lineage
   (#9), W3C cross-service (#13), workflow span (#15).
