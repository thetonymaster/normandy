# GenAI telemetry fix plan — 2026-10-02

Spec: `investigations/genai-telemetry-audit.md` (finding numbers `#N` refer to it).
Branch: `feat/claudio-0.7-migration`. Executed task-by-task, one commit (or a few) per task.

## Global Constraints

- **Additive only.** Existing event names, measurement keys and metadata keys keep
  their names and meanings. In particular the raw `usage` map on llm_call stop stays
  exactly as today; normalized token keys are added beside it.
- **OTel stays a soft dependency.** `opentelemetry`/`opentelemetry_api` remain
  `only: :test`. Library code touches OTel only through `Normandy.Telemetry.OtelCtx`
  (or a sibling module in `lib/normandy/telemetry/`) using `Code.ensure_loaded?` +
  `apply/3`, and must be a no-op when OTel is absent.
- **Three Turn interpreters.** Any new Turn core effect must be wired into
  `Turn.Driver`, `Turn.Inline` and `Turn.Server`, or a shell crashes.
- **Gate:** run `mix format`, then `mix precommit` (compile --warnings-as-errors,
  deps.unlock --check-unused, format, credo --strict, dialyzer, test) green before
  every commit. Failing tests anywhere must be fixed, even unrelated ones.
- **TDD:** write the failing test first, watch it fail for the right reason, then fix.
  No skipped tests.
- **Commits:** conventional style matching history (`fix(scope): …`, `feat(telemetry): …`,
  `test(...)`, `docs(...)`). `git add` files individually (never `git add .`).
  **No AI attribution** of any kind in commit messages (no Co-Authored-By, no
  "Generated with"). Do not push.
- **Credo:** complexity/nesting findings get an inline `# credo:disable-for-next-line`,
  never a config change. Dialyzer accepted warnings go in `.dialyzer_ignore.exs` with a reason.
- **Telemetry metadata must never carry message/prompt/output content.**
- Metadata key naming: snake_case atoms, Normandy-flavoured (e.g. `provider`,
  `response_id`, `finish_reason`, `tool_call_id`), not dotted semconv names. Task 16
  documents the semconv mapping.
- Decisions already made by Q:
  - Approval park: keep the run span as one span; add an `approval_wait` stop
    measurement and a separate `[:normandy, :turn, :approval, :start|:stop]` span.
  - Killed tasks: the coordinator emits a synthetic `[:normandy, :agent, :run, :exception]`
    with `reason: :killed` for each run it kills; inner llm_call/tool spans left open is
    documented, not fixed.
  - W3C: change `../Claudio` too (header pass-through), left **uncommitted** in that repo.

---

### Task 1: Turn.Server stray-message crash and terminate (#5c, #5d)

`lib/normandy/agents/turn/server.ex` has no catch-all `:info` clause (all clauses at
~426-460 match only `:running` + the current `task_ref` or its `:DOWN`) and no
`terminate/3`. A stray or late message (e.g. a result from a task whose ref was
already cleared, an unrelated `:DOWN`, any `send/2`) raises FunctionClauseError and
crashes/restarts the server.

- Add a catch-all `handle_event(:info, msg, state, _data)` that logs at debug/warning
  (message summarised with `inspect/2` limited, plus the state) and returns
  `:keep_state_and_data`. Late `{ref, _}` results from stale tasks must be demonitored
  /flushed safely.
- Add `terminate/3`: when the server stops while a run span is in flight (between the
  hand-emitted run `:start` and its `:stop`/`:exception`), emit
  `[:normandy, :agent, :run, :exception]` with `kind: :exit`, `reason: <terminate reason>`,
  `stacktrace: []`, and the same metadata shape as the existing hand-emitted run
  exception, with `duration` measurement. Track "run span in flight" explicitly in
  `Data` (e.g. a `run_started_at` monotonic time or nil) if not already tracked.
  `terminate/3` only runs when trapping exits or on normal stop paths — determine
  whether the server traps exits; if it doesn't, document what is covered (normal
  stop / passivation / supervisor shutdown) in the moduledoc rather than adding
  exit trapping unless trapping is clearly safe.
- Tests in `test/agents/turn/server_test.exs`: stray message in each state does not
  crash (server still answers the next `run/2`); stopping a server mid-turn emits
  run `:exception`.

### Task 2: Span-hierarchy test harness (#14, #21)

No test asserts OTel parent/child relationships. Build the harness the later tasks use.

- `test/support/otel_span_bridge.ex`: a minimal test-only bridge that attaches
  `:telemetry` handlers for `[:normandy, :agent, :run]`, `[:normandy, :agent, :llm_call]`,
  `[:normandy, :tool, :execute]` start/stop/exception and creates/ends real OTel spans
  (`:otel_tracer.start_span` with the current ctx as parent, set current on start; end
  and restore previous ctx on stop/exception — keyed per process, since start and stop
  fire in the same process). Expose `attach/0`, `detach/0`.
- Collect finished spans with `:otel_simple_processor` + `:otel_exporter_pid` (or the
  SDK's documented test exporter) so a test receives `{:span, span_record}` messages;
  provide helpers returning `[%{name, span_id, parent_span_id, trace_id}]`.
- `config/test.exs`: `config :opentelemetry, traces_exporter: :none` (silence the
  "opentelemetry_exporter not found" log) — but make sure the harness's processor still
  receives spans (configure per test via `:otel_batch_processor`/`:otel_simple_processor`
  setup as the SDK requires; verify by observation).
- `test/telemetry/span_hierarchy_test.exs` (async: false): with a caller span active,
  `BaseAgent.run/2` with a stub client that issues one tool call produces
  caller → run → llm_call and run → tool (same trace_id, correct parents). This test
  must pass today. Later tasks add Turn.Server / coordination cases to this file.

### Task 3: Turn.Server trace-context propagation (#1, #20)

`Turn.Server.run/2` (`server.ex:132`) sends `{:turn, user_input}` with no ctx;
`spawn_task` (~785) spawns workers without restoring ctx; the captures at ~989/~1033
run inside the worker and snapshot an empty ctx.

- `OtelCtx`: add token-returning `attach/1` and `detach/1` (soft, no-op when absent);
  keep `capture/0`/`restore/1` behaviour for existing Task call sites; document that
  `restore/1` is for short-lived processes only.
- `run/2` captures the caller ctx and sends it with the turn (keep accepting the old
  `{:turn, input}` message shape for in-flight/durable compatibility if any persisted
  or remote caller could send it). In `:idle`, attach it before the hand-emitted run
  `:start`, store it in `Data`; detach and clear after run `:stop`/`:exception`
  (including Task 1's terminate path).
- The run span ctx must reach workers: with a bridge, the run span is current in the
  server process after run `:start`, so capture in the server process inside
  `spawn_task` *before* spawning and `OtelCtx.restore/1` at the top of the worker. Both
  the outer `spawn` and the inner `spawn_link` worker need it if spans can fire in either.
- Tests: add Turn.Server cases to `test/telemetry/span_hierarchy_test.exs`: caller →
  run → llm_call and run → tool. Write them first; they must fail before the fix.

### Task 4: Coordination fan-out ctx propagation (#6)

No `OtelCtx` in `coordination/`, `dsl/`, `batch/`. Capture in the caller, restore at the
top of each spawned closure, exactly like `base_agent.ex:669`:

- `coordination/reactive.ex` (~87, ~157, ~240), `coordination/parallel_orchestrator.ex`
  (~136, ~242), `batch/processor.ex` (~130), `coordination/agent_process.ex`
  (GenServer.call from caller ~118 — carry ctx in the call message and attach/detach
  around the inline run in `handle_call`; `Task.start`/spawn sites ~498, ~528, ~553).
- Grep `lib/` for any other `Task.async`, `Task.async_stream`, `Task.start`, `spawn`
  that runs agent/tool/LLM work and isn't covered; fix those too and list them in the
  report.
- Tests: span_hierarchy cases for `Reactive.all`, `ParallelOrchestrator`, `Batch.Processor`
  and `AgentProcess.run` — caller → run under the caller's trace. Fail first.

### Task 5: Synthetic run :exception for killed tasks (#5a, #5b)

`Reactive.race` brutal-kills losers (`reactive.ex` ~103, ~256; workflow `race` uses it);
`on_timeout: :kill_task` in `batch/processor.ex` ~130, `parallel_orchestrator.ex`
~142/~253, `reactive.ex` ~166 kills `BaseAgent.run` mid-span.

- When the coordinator kills (or async_stream kill_task times out) a task that was
  running an agent run, emit `[:normandy, :agent, :run, :exception]` from the
  coordinator with measurements `%{duration: native}` (from the task's start), metadata
  `%{model, agent_name, kind: :exit, reason: :killed, stacktrace: []}` plus whatever
  run metadata is available for that agent. Only for runs whose `:start` was actually
  emitted — if that can't be known from the coordinator, emit it whenever the task was
  started and document the possible duplicate-free guarantee you chose.
- With Task 4's ctx in place, attach the killed task's captured ctx while emitting so a
  bridge can end the right span — determine whether a bridge can actually close a span
  from another process (opentelemetry_telemetry keys by process); if not, document the
  limitation in the moduledoc and in Task 16's catalogue note.
- Document in each affected moduledoc that inner llm_call/tool spans of a killed run are
  left open.
- Tests: race loser and kill_task timeout each emit exactly one run `:exception` with
  `reason: :killed`.

### Task 6: Streaming usage and normalized token counts (#2, #3)

- `stream_meta/1` (`base_agent.ex` ~1004) must include `usage` from the final streamed
  message, so streaming llm_call stop carries `usage` like non-streaming.
- On llm_call stop (streaming and non-streaming) add normalized keys next to the raw
  `usage`: `input_tokens` = input + cache_read + cache_creation (sum), `output_tokens`,
  `cache_read_input_tokens`, `cache_write_input_tokens` (from Anthropic
  `cache_creation_input_tokens`). When usage carries `iterations` (Claudio refusal
  fallbacks; see Claudio `response.ex` ~172-180 typedoc), sum across iterations for the
  billed totals. Absent counts → key omitted (not 0, not nil) — except when the provider
  reports nothing at all, omit all normalized keys.
- One pure function (e.g. `Normandy.Telemetry.Usage.normalize/1`) with unit tests over
  struct and map usage, string/atom keys if both occur, iterations, missing fields.
- Log line at ~1547 should use the same normalized values so logs and telemetry agree.
- Tests: streaming stop carries `usage` and normalized keys; cached tokens summed.

### Task 7: Usage on failed LLM calls (#4)

`claudio_adapter.ex` ~244 discards `collect_retry_usage(ref, nil)` on the
`{:error, %LLMError{}}` path, losing paid JSON-parse retries; llm_call `:exception`
metadata has no usage.

- Carry accumulated usage on the error (add an optional `usage` field to
  `Normandy.LLMError` if it has none — additive) and put normalized (Task 6) plus raw
  usage into the llm_call `:exception` path. `:telemetry.span` exception metadata is
  fixed (kind/reason/stacktrace + start metadata), so the usage is reachable via
  `reason.usage`; document that, and additionally emit nothing new unless needed.
- Also ensure the structured-outputs 400 → legacy fallback and retries sum usage the
  same way.
- Tests: a failing call after N JSON parse retries exposes summed usage on the
  exception's `reason`.

### Task 8: llm_call request/response metadata (#11, #17, #18 server.address)

- Start metadata (streaming and non-streaming): `provider` (`:anthropic` for the
  Claudio adapter, a sensible atom for any other adapter in `lib/normandy/llm/`;
  source it from the client struct or an optional `Model` protocol function with a
  fallback — do not break existing third-party `Model` impls), `stream` (boolean),
  `max_tokens`, `temperature` (only when non-nil), `effort` (when set in
  `client.options`), `structured_output` (boolean, whether native structured outputs
  are requested for this call), `server_address` (host from client base URL, only when
  readily available — omit otherwise).
- Stop metadata: `response_id`, `finish_reason` (the provider stop_reason, atom or
  string as provided — document) from `response_meta/1` (`claudio_adapter.ex`
  ~1056-1079) and `stream_meta/1`; whitelist them in the `Map.take` at
  `base_agent.ex` ~662.
- Streaming stop: `time_to_first_chunk` measured from the llm_call start to the first
  content delta, in native time units, as a **measurement** on stop? `:telemetry.span`
  stop measurements are fixed to `duration`/`monotonic_time`; put it in stop metadata as
  `time_to_first_chunk` (native units) and document.
- Tests for each key, streaming and non-streaming.

### Task 9: Shared run metadata, ids on every span, rejection parity (#12, #18 conversation id)

- One builder (e.g. `Normandy.Telemetry.Metadata.run/2`) used by both BaseAgent
  (`base_agent.ex` ~407) and Turn.Server's hand-emitted run span (~557): `model`,
  `agent_name`, `provider`, `session_id` (Turn.Server; nil/omitted in BaseAgent),
  `turn_id` (memory turn id when available), `conversation_id` (session id when
  present, else omit).
- llm_call and tool metadata carry `turn_id` and `session_id`/`conversation_id` when
  available.
- Rejected input parity: Turn.Server currently replies `{:error, {:rejected, e}}`
  without a span (~399-403) while BaseAgent emits run `:exception`. Make Turn.Server
  emit run start + `:exception` (reason `{:rejected, e}`) for rejected input, matching
  BaseAgent — without changing the `run/2` return value.
- Tests for parity and ids.

### Task 10: Tool span metadata and denied-call event (#10, #16 denied)

- Pass the `%ToolCall{}` (or its id) to `execute_fn` (`dispatch.ex` ~271 calls it with
  `(config, prepared, call.name)`; `base_agent.ex` ~1634 `span_execute/3`). Keep arity
  compatibility for any custom `execute_fn` users can supply (check `Config.to_pipeline`
  and behaviours docs) — if the arity is public API, accept both arities.
- Tool span start/stop metadata adds `tool_call_id`, `tool_description` (from
  `BaseTool.tool_description/1` when implemented), `tool_type` (`:function` for local
  tools, `:extension` for MCP-wrapped tools). Stop adds `error_type` when status is
  `:error`: `:timeout | :exception | :exit | :tool_error | :invalid_result` — Executor
  currently collapses these into `{:error, msg}`; carry the classification without
  changing the `{:error, msg}` result tools/LLM see.
- New event `[:normandy, :tool, :denied]` (`%{count: 1}`, metadata `tool_name`,
  `tool_call_id`, `reason` (`:policy | :budget | :hook_halt | :approval_expired |
  :approval_rejected`), `rule_id` when available, `agent_name`, `session_id`) for
  calls answered without execution — in all three Turn interpreters if the denial
  logic lives in the Turn core.
- Tests.

### Task 11: Per-attempt LLM request span (#7)

Retries (`base_agent.ex` ~336-363), JSON parse retries, and the structured-outputs
400 → legacy second request all hide inside one llm_call span.

- New span `[:normandy, :llm, :request, :start|:stop|:exception]` around each actual
  provider request (each `Claudio.Messages.create` / stream request in
  `claudio_adapter.ex`), metadata: `model`, `provider`, `attempt` (1-based within the
  llm_call), `kind` (`:initial | :retry | :json_retry | :structured_fallback`), `stream`;
  stop adds `response_id`, `finish_reason`, normalized usage for that request, and
  `status`; exception carries the LLMError as reason (`error.type` = `reason.type`).
- llm_call stop adds `attempts`, `json_retries`, `structured_fallback` (boolean).
- Runs in the caller's process, so it nests under llm_call with a bridge — verify with a
  span_hierarchy case: llm_call → request ×N on a retried call.
- Tests.

### Task 12: Approval wait span and measurement (#8)

Turn.Server keeps the run span open in `:awaiting_approval` (~542, ~672).

- On park, emit `[:normandy, :turn, :approval, :start]` (`%{system_time, monotonic_time}`,
  metadata `session_id`, `tool_names`, `count`); on resume (approval received) or expiry,
  `[:normandy, :turn, :approval, :stop]` with `duration` and metadata adding `outcome`
  (`:approved | :rejected | :mixed | :expired`). The existing
  `[:normandy, :turn, :approval, :expired]` event stays.
- Run stop/exception measurements add `approval_wait` (native units, sum over all parks
  in the turn; 0 when never parked). Additive measurement key on the hand-emitted run
  events only; BaseAgent run (no approval) needn't add it — but document.
- Tests: park 100ms → approval span duration ≈ wait, run stop has `approval_wait`.

### Task 13: Durable resume and approve/2 lineage (#9)

- At turn start, inject the current OTel ctx as a W3C text-map carrier (soft:
  `:otel_propagator_text_map.inject/1` via a `Normandy.Telemetry` helper; `[]` when OTel
  absent) and persist it with the turn state so it survives restart.
- On durable resume (the path at `server.ex` ~555 that today emits no run `:start`),
  emit run `:start` with `resumed: true` and, when a carrier exists, extract it and make
  it the parent ctx (attach before the start event) — document parent vs link choice
  (a bridge can only express parenting via current ctx; links need bridge support).
- `approve/2` carries the approver's ctx in the cast; attach around the approval
  handling so the approval `:stop` event can be correlated (do not reparent the run).
- Tests: resume emits run start with `resumed: true` under the original trace id
  (span_hierarchy case using a restarted server with a persisted store).

### Task 14: W3C propagation across services (#13)

- `../Claudio` (separate repo, leave changes **uncommitted**): let A2A HTTP transport
  (`lib/claudio/a2a/transport/http.ex` ~136-141) accept extra `:headers` via
  `transport_opts` and merge them into the request. Add a Claudio test. Run that repo's
  own `mix test` (and `mix format`).
- Normandy A2A client side (`AgentTool.run` or wherever transport opts are built):
  when OTel is loaded, inject `traceparent`/`tracestate` via the soft helper into those
  headers.
- `A2A.Server`: add `handle_message/3` accepting carrier headers (keep `/2` delegating
  with `[]`); extract and attach ctx around handling, detach after; emit a
  `[:normandy, :a2a, :request]` span (metadata `task_id`, `agent_name`).
- MCP: inject where Normandy builds the request to the MCP adapter if the adapter API
  allows metadata/headers; otherwise document why not.
- Tests: carrier round-trip (inject on client → extract on server → same trace id).

### Task 15: Workflow span, direct streaming run span, coverage notes (#15, #16, #19)

- `[:normandy, :workflow, :run]` span around workflow execution in
  `lib/normandy/dsl/workflow.ex` (and the orchestrators' top-level entry points if they
  are a distinct public entry — Sequential/Parallel/Hierarchical/Reactive), metadata
  `workflow_name` / `orchestrator`, `step_count`.
- Direct `stream_response/3` / `stream_with_tools/3` (`base_agent.ex` ~1101, ~1155) go
  straight to `run_stream_turn` with no run span — wrap them in the same run span as
  `run/3 stream: true` (check no double span when reached via `run/3`).
- Turn.Inline emits no telemetry because callers supply deps: document in its
  moduledoc that telemetry comes from the deps it's given (no code change unless the
  default deps BaseAgent passes skip spans — verify).
- json_deserializer events (#19): add `model`/`agent_name` only if available without
  hidden globals (no process-dictionary state); otherwise document that correlation is
  via the enclosing llm_call span (same process).
- Span-hierarchy case: workflow → run.

### Task 16: Telemetry event catalogue and docs (#22)

- New `lib/normandy/telemetry.ex` (`Normandy.Telemetry`, moduledoc only, or alongside
  existing helpers): every event Normandy emits after Tasks 1-15, with measurements,
  metadata keys + types, when it fires, and a table mapping to OTel GenAI semconv
  attributes (`gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.*`,
  `gen_ai.response.*`, `gen_ai.usage.*`, `gen_ai.tool.*`, `gen_ai.agent.*`,
  `gen_ai.conversation.id`, `error.type`, `server.address`), plus known limits (killed
  inner spans, cross-process bridging, parked runs, semconv stability = Development).
  Include a short example bridge snippet.
- Fix `CHANGELOG.md:626` (`[:normandy, :llm, :call, *]` → the real event) and add
  CHANGELOG entries for the new events/keys; update `MIGRATING-2.0.md` if it references
  telemetry; point CLAUDE.md's Observability section at the catalogue.
- Test `test/telemetry/catalogue_test.exs`: scan `lib/**/*.ex` for
  `:telemetry.execute(`/`:telemetry.span(` event-name literals and assert each appears
  in the `Normandy.Telemetry` moduledoc (`Code.fetch_docs/1`), and vice versa.
