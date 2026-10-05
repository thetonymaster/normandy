# Normandy 2.0 audit: OpenTelemetry and telemetry

Branch `feat/claudio-0.7-migration` @ f7991a9, 2026-10-04. Read-only: grep and read only, no mix run.
Prior work read first: `investigations/genai-telemetry-audit.md` (22 findings), `genai-telemetry-fix-plan.md`,
`fix-verification-2026-10.md`, and the perf/race audit. Nothing here repeats those. The perf audit's
`OtelCtx` `Code.ensure_loaded?` cost (perf audit line 302) is known and left out.

Labels: **VERIFIED** means I read the code path end to end. **PLAUSIBLE** means the code supports it
but some step depends on runtime behaviour I did not observe.

## 0. Spot-check of the 2026-10-03 fixes

I checked six of the 22. All six are in the code:

| Prior # | What was asked | Where it is now |
|---|---|---|
| #1 | Turn.Server carries the caller's ctx and restores it in workers | `turn/server.ex:220` `{:turn, user_input, OtelCtx.capture()}`; `:828` attach before run `:start`; `:1224/:1234` capture and restore in `spawn_task` |
| #2 | Streaming llm_call stop carries usage | `base_agent.ex:1101` `put_usage(Map.get(final_message, :usage))` plus normalized counts via `merge_normalized_usage` |
| #5c | Catch-all `:info` and `terminate/3` | `turn/server.ex:726` catch-all with bounded `inspect`; `:749` `terminate/3` stops the approval and run spans |
| #10 | Tool span gets `tool_call_id` | `base_agent.ex:1872` `span_execute/4` takes `%ToolCall{}`; `Metadata.tool/3` adds `tool_call_id`, `tool_type`, `tool_description` |
| #13 | A2A W3C injection and extraction | `a2a/agent_tool.ex:93` `put_trace_headers/1`; `a2a/server.ex:130-150` carrier extract and attach |
| #22 | CHANGELOG `[:normandy, :llm, :call]` fixed; catalogue test | `CHANGELOG.md:682` corrected; `test/telemetry/catalogue_test.exs` scans literal and dynamic call sites |

The catalogue matches the code in both directions. Every emitted event appears in the `Normandy.Telemetry`
moduledoc, and every documented event is emitted. That covers literal sites, the 3 dynamic sites in
`telemetry/request.ex` and the 1 in `turn/server.ex`. The Turn core `:emit_event` effects
(`:iteration`, `:steering`, `:awaiting_approval`, `:approval_expired`) go to handler callbacks and
subscribers, not to `:telemetry`, so the catalogue rightly leaves them out.

---

## HIGH

### TEL-1 (HIGH): the dependency range allows a telemetry version that breaks every memory tool command
- **Where:** `mix.exs:165`; `lib/normandy/tools/memory.ex:136-150`
- **What is wrong:** the memory tool's span function returns the 3-tuple
  `{result, extra_measurements, stop_metadata}`:
  ```elixir
  :telemetry.span([:normandy, :memory, :command], meta, fn ->
    ...
    {:ok, text, stats} -> {{:ok, text}, measurements(stats), Map.put(stop_meta, :status, :ok)}
  ```
  `:telemetry.span/3` accepts that shape only from **1.3.0** on (`deps/telemetry/CHANGELOG.md`, section 1.3.0:
  "Ability to return extra measurements from `telemetry:span/3`"). The dependency is `{:telemetry, "~> 1.0"}`.
- **Failure scenario:** an app whose lock pins telemetry 1.0 to 1.2.x resolves fine. 1.2.1 was locked
  by many Phoenix apps for a long time. On such a lock, every memory command fails a match inside the span:
  the span emits `:exception` and re-raises, and Executor turns that into `"Tool execution failed: ..."`.
  The `memory` tool cannot work at all, and nothing at compile time says why. Our own lock is 1.4.2, so
  the tests never see it.
- **Fix:** require `{:telemetry, "~> 1.3"}`, or return `{result, stop_metadata}` and send the byte and
  CAS counts as stop metadata. Add a CHANGELOG/MIGRATING note if the minimum is raised.
- **VERIFIED.** The code and the telemetry changelog were read. No run on telemetry 1.2.

---

## MEDIUM

### TEL-2 (MEDIUM): Turn.Server's run `:exception` reason is `{:task_down, {exception, stacktrace}}`
- **Where:** `turn/server.ex:636-645` (`:DOWN`, which makes `{:llm_error, {:task_down, reason}}`);
  `:1157-1159` (`{:fail, reason}` emits run `:exception` with `reason: reason, stacktrace: []`);
  `:1248-1257` (the watcher does `exit(reason)` with the worker's crash reason). The documentation at
  `:128` confirms the shape.
- **What is wrong:**
  1. BaseAgent's run `:exception` has `reason: %LLMError{type: :rate_limit}`. When Turn.Server's LLM worker
     raises that same `LLMError`, its run `:exception` has
     `reason: {:task_down, {%LLMError{}, stacktrace}}` and `kind: :error`. The catalogue's own rule for
     `error.type` (`telemetry.ex:327`: "an LLMError's type, else the exception module or the term's tag")
     gives `"task_down"` for every LLM, tool-task and compactor failure in Turn.Server. Dashboards that
     split by error.type see one bucket for durable sessions, while BaseAgent gets `rate_limit`,
     `overloaded` and so on.
  2. The raw OTP crash stacktrace sits inside `reason`, while `stacktrace` is `[]`. For BIF errors and
     `FunctionClauseError`, the top frame holds the real **arguments**: config, messages, the client.
     Turn.Server takes care to keep these out of its logs (`describe_crash/3`, `arity_only/1` at
     `:1352-1384`, with the comment "never its values"). Telemetry gets the raw term anyway. The catalogue's
     example bridge does `Tracer.set_status(:error, inspect(meta[:reason]))` (`telemetry.ex:374`), which
     prints the arguments. The client's Inspect redacts `api_key`, but message history, which is user
     content, is not redacted.
- **Failure scenario:** a durable session hits a 429. The run span's error.type is `task_down`, and its
  status description holds an inspected stacktrace that can include the conversation.
- **Fix:** in the `{:fail, reason}` clause, unwrap `{:task_down, {exception, st}}` when `exception` is an
  exception struct. Emit `reason: exception` and `stacktrace: st` with the args removed (the same
  `arity_only/1`), and `kind: :error`. Keep the reply value unchanged. Add a parity test against BaseAgent's
  run `:exception` for the same `LLMError`.
- **VERIFIED** (the path from `call_llm_event` through worker crash, watcher exit, `:DOWN`, `Turn.step`
  and `{:fail, _}` to the emit). Whether a given crash has args in its top frame depends on the error type.

### TEL-3 (MEDIUM): in Turn.Server, admission and `on_turn_end` run outside the caller's trace
- **Where:** `turn/server.ex:558-579`. `admit/2` (on_prompt hooks, input schema validation, input
  guardrails) and `close_batch/2` run **before** `start_turn` → `start_run_span` (`:827-828`), which is the
  first place the caller's ctx is attached. `turn_end/4` runs **after** `stop_run_span` has detached it
  (`:1151-1153`, `:1159-1161`, `:572`).
- **What is wrong:** while these run, the server process has no OTel ctx. So the `[:normandy, :hook]` spans
  for `on_prompt` and `on_turn_end`, the `[:normandy, :agent, :guardrail, :decision|:violation]` events, and
  any spans a guard opens become **root spans of new traces**. A guard can open real spans: a
  `SemanticScope` classifier is often an LLM call. In BaseAgent, admission runs inside the run span, and
  `on_turn_end` runs in the caller's ctx, so both stay in the caller's trace. The Turn.Server moduledoc
  promises only that the run span nests; this gap is not documented.
- **Failure scenario:** an on_prompt moderation hook that calls an LLM shows up as a separate orphan
  trace for every durable turn. Its latency cannot be tied to the user request.
- **Fix:** attach `caller_ctx` with a token at the top of the `{:turn, input, caller_ctx}` clause and
  detach it on every exit path: the reject, crash and persist-failure replies, and after `turn_end` in
  `{:finalize}`/`{:fail}`. The simplest version keeps the token in `Data`, next to `run_span`. Add
  span-hierarchy cases for an on_prompt hook and on_turn_end in Turn.Server.
- **VERIFIED.**

### TEL-4 (MEDIUM): a failed output validation prints the whole model output to stderr through `IO.warn`
- **Where:** `base_agent.ex:801`
  ```elixir
  IO.warn("Agent output validation failed: #{error_msg}\nReceived: #{inspect(value)}")
  ```
  This sits on the hot path of every turn (`validate_turn_output/2`, a Driver/Turn.Server handler).
  `:2324` and `:2420` also `IO.warn` on output guardrail violations; AGENTS-3 in the 2026-09 audit noted
  that pattern, but not `:801`.
- **What is wrong:** the model output is content. It can be PII, or text that a guardrail just flagged.
  It goes to stderr with a stacktrace, outside Logger. Logger levels, filters, metadata and redaction
  cannot control it, and there is no telemetry event for a failed output validation. The catalogue's rule
  "never message, prompt or output content" covers metadata only, but this is the same leak by another
  channel.
- **Failure scenario:** a model returns JSON that does not fit the schema. The full answer lands in the
  production stderr log on every occurrence, unfilterable.
- **Fix:** use `Logger.warning` with the error summary only (field paths and constraints, never `value`).
  Add a `[:normandy, :agent, :output_validation, :failed]` event (count, agent_name, ids, error count),
  and catalogue it. Make the same `IO.warn` → Logger change at `:2324` and `:2420`.
- **VERIFIED.**

### TEL-5 (MEDIUM): hook contract errors put hook data into the exception reason and the error log
- **Where:** `hooks/runner.ex:363-367`
  ```elixir
  raise ArgumentError, "expected #{inspect(mod)}.#{event}/... to return ..., got: #{inspect(ret)}"
  ```
  This is raised from `classify` **outside** `guarded/2`, so it propagates through
  `:telemetry.span([:normandy, :hook], ...)` (`:293`). Turn.Server's `describe_crash/3`
  (`turn/server.ex:1352-1356`) then logs the **full** message of any ArgumentError, untruncated.
- **What is wrong:** `ret` is the hook's return value. For `on_prompt` it is the user input, for
  `before_tool` the tool arguments, for `after_tool` the tool result. A hook that returns the wrong shape
  (`{:ok, input}` instead of `{:cont, input}`, say) puts that content into the hook `:exception` metadata
  `reason` and into Turn.Server's `Logger.error`. Both `runner.ex:371-374` and the Turn.Server comment
  assume an ArgumentError message is "author-written text", but this one is Normandy's and embeds data.
  Related: Turn.Server's rejected-run `reason: {:rejected, %Normandy.Schema.ValidationError{}}` carries raw
  input params when the schema audit's ValidationError issue applies (see the 2026-09 schema audit).
- **Failure scenario:** a buggy on_prompt hook leaks every user prompt into error logs and into hook span
  status descriptions until it is fixed.
- **Fix:** in `contract!/3`, describe `ret` by shape only (`Describe.type_of/1`, already used in the
  adapter), for example "got a 2-tuple tagged :ok".
- **VERIFIED.**

### TEL-6 (MEDIUM): the circuit breaker and Retry emit no telemetry; their logs are unstructured and anonymous
- **Where:** `resilience/circuit_breaker.ex:298, 304, 362, 393, 403, 433`; `resilience/retry.ex:188, 208, 217`
- **What is wrong:** the breaker's state changes (closed→open, open→half_open, half_open→closed or open)
  are only interpolated `Logger` strings, with no breaker name or pid and no metadata. No `:telemetry`
  event exists, so open-circuit alerts cannot be built. For Retry, LLM retries do show up as
  `[:normandy, :llm, :request]` with `request_kind: :retry`, but nothing records the backoff delay. Retry
  used outside BaseAgent emits nothing. `retry.ex:208` logs `inspect(error)` at warning on every attempt,
  and that term can be `{:exception, e, __STACKTRACE__}` (`retry.ex:228`), with args in the top frame
  (see TEL-2).
- **Fix:** emit `[:normandy, :circuit_breaker, :state_change]` (from, to, name, failure_count) and
  `[:normandy, :retry, :attempt]` (attempt, max_attempts, delay_ms, error_type). Catalogue both. Log with
  structured metadata (`breaker:`, `from:`, `to:`) and describe errors by type and class, not by `inspect`.
- **VERIFIED** (grep finds no `:telemetry` call in `resilience/`).

### TEL-7 (MEDIUM): the run (`invoke_agent`) stop has no total usage, iteration count or outcome
- **Where:** `base_agent.ex:451, 535-536, 1267-1268, 1326-1327` (stop metadata is just the start
  metadata); `turn/server.ex:872-881`
- **What is wrong:** semconv-genai `gen-ai-agent-spans.md` lists `gen_ai.usage.input_tokens`,
  `gen_ai.usage.output_tokens` and `gen_ai.response.finish_reasons` on `invoke_agent` as **Recommended**
  (fetched 2026-10-04). Normandy's run stop has none of them, and no `iterations` either. The log line
  does report `iterations: completed_iterations(result)` (`base_agent.ex:1742`), so logs and telemetry
  disagree, the same kind of drift as prior #2. A bridge would have to sum child llm_call spans, which
  breaks across processes and for killed children.
- **Fix:** carry a per-run usage accumulator through the Driver acc / Turn.Server `Data`, and put on run
  stop `input_tokens`, `output_tokens`, `cache_*`, `llm_calls`, `iterations`, and the last
  `finish_reason`. Document them in the catalogue's mapping table.
- **VERIFIED** for the code. The semconv text was fetched and read.

---

## LOW

### TEL-8 (LOW): every run, LLM call and tool call logs at `:info`
- **Where:** `base_agent.ex:1727, 1742, 1771, 1806, 1829, 1841` (`log_lifecycle(:info, ...)`)
- A one-tool turn logs at least 6 info lines; a 10-tool loop logs dozens. That is high for a library's
  default. Under the default console formatter (`metadata: []`) the messages read as
  "normandy llm call stop" with no data, because the facts are in metadata. `Batch.Processor` also logs
  each chunk at info (`batch/processor.ex:132, 165, 229, 239`).
- **Fix:** start/stop to `:debug`, keep exceptions at `:error`, and put the key facts (agent, model,
  duration_ms, tokens) into the message text or document the metadata keys to enable.
- **VERIFIED.**

### TEL-9 (LOW): a tool timeout leaves spans inside the tool open, with no synthetic end
- **Where:** `tools/executor.ex:221-245` (`Task.yield(task, timeout) || Task.shutdown(task)`)
- Shutting down the tool task leaves any span opened inside it unended: a `[:normandy, :memory, :command]`
  span (a slow Postgres/Redis store), or the run, llm_call and tool spans of a user tool that runs a
  sub-agent in-process. Unlike the coordinators (`KilledRun`), nothing emits a synthetic
  `:exception`, and the catalogue's "Known limits" does not mention this case. The outer tool span
  correctly stops with `error_type: :timeout`.
- **Fix:** document it under Known limits, or emit a synthetic memory `:exception` for the memory tool.
- **VERIFIED.**

### TEL-10 (LOW): `usage: nil` appears in llm_call stop metadata
- **Where:** `base_agent.ex:703` (non-streaming: `usage: usage` always), `context/summarizer.ex:290`
  (`Map.put(:usage, usage)`). Streaming uses `put_usage/2`, which leaves the key out (`base_agent.ex:1946`).
- This breaks the catalogue rule "keys with no value are left out", and the two paths differ for the same
  case (a `converse/7` that returns a bare response).
- **Fix:** use `put_usage/2` in both places.
- **VERIFIED.**

### TEL-11 (LOW): public `get_response/2` makes provider requests with no llm_call span
- **Where:** `base_agent.ex:224-227` → `get_response_with_usage` (comment at `:337`: "get_response/2 has
  no llm_call span"). Its request spans have no llm_call parent. Its tokens appear in no llm_call stop and
  in no run, so cost dashboards built on llm_call miss them. The catalogue says request spans are "inside
  an llm_call".
- **Fix:** wrap it in `with_llm_call_span` (with `iteration` absent), or document the exception.
- **VERIFIED.**

### TEL-12 (LOW): Turn.Server parity gaps in run spans
- **Where:** `turn/server.ex:575-578` (`{:crashed, reason}` from admission: reply, no run span);
  `:813-817` (persist failure at turn start: reply, no run span). BaseAgent admits inside its run span,
  so the same admission crash there emits run `:exception`. Prior #12 fixed only the `{:rejected, _}` case.
- **Fix:** route both through the same start/exception pair `emit_rejected_run/3` uses.
- **VERIFIED.**

### TEL-13 (LOW): the workflow run stop does not say whether the workflow failed
- **Where:** `telemetry/workflow_span.ex:19` (`fn -> {fun.(), metadata} end`). Workflows and orchestrators
  report failure by **return value** (`{:error, _}`, `success: false`), so a failed workflow emits `:stop`
  that looks the same as a success.
- **Fix:** let callers pass a classifier, or add `status: :ok | :error` from `{:error, _}` /
  `%{success: false}`.
- **VERIFIED** for the span helper. I did not trace every orchestrator's return shape.

### TEL-14 (LOW): the catalogue does not map the memory command span to the semconv memory operations
- **Where:** `telemetry.ex:303-329`. semconv-genai now defines the `gen_ai.operation.name` values
  `create_memory`, `update_memory`, `delete_memory` and `search_memory` (fetched 2026-10-04). The memory
  span has no mapping row: `view` maps to `search_memory`, `create`/`str_replace`/`insert`/`rename` to
  `update_memory`, `delete` to `delete_memory`.
- **Fix:** add the rows. No code change is needed.
- **VERIFIED.**

### TEL-15 (LOW): A2A Server attaches the remote caller's baggage as well as its trace parent
- **Where:** `a2a/server.ex:146-150` → `OtelCtx.extract/1` (`otel_ctx.ex:111-118`), which uses the
  global propagator. That propagator usually includes `baggage`.
- An untrusted remote caller can put arbitrary baggage into this node's ctx. `AgentTool` then forwards
  it downstream (`inject` writes baggage too, `otel_ctx.ex:80-82`), and some bridges copy it into span
  attributes. OTel guidance is to treat inbound baggage as untrusted.
- **Fix:** extract with a trace-context-only propagator in `handle_message/3`, or document it.
- **PLAUSIBLE.** It depends on the app's configured propagators.

### TEL-16 (LOW): several 2.0 features have no telemetry, only Logger strings
- `Batch.Processor`: no batch span and no progress event (Logger.info only). `AgentPool`: no
  checkout-wait or checkout-timeout event, no overflow event (`agent_pool.ex:328, 392, 527` are logs).
  `ResumeReaper`: no event for scanned, resumed or failed sessions (`resume_reaper.ex:105-173` are logs).
  Turn.Server `:unavailable` and store faults: no event (`turn/server.ex:275`, `:535`). Compaction,
  approvals, guardrails, denials and hooks are covered.
- **Fix:** add at least `[:normandy, :turn, :unavailable]`, `[:normandy, :resume_reaper, :sweep]` and
  `[:normandy, :pool, :checkout]` (wait duration, outcome).
- **VERIFIED** (grep: no `:telemetry` in those files).

### TEL-17 (LOW): guardrail `:guard_error` violations embed a crashed guard's exception message
- **Where:** `guardrails.ex:220-227` (`message: "guard #{inspect(mod)} crashed: #{Exception.message(exception)}"`)
- This lands in `[:normandy, :agent, :guardrail, :violation|:decision]` metadata `violations`. A custom
  guard's exception message can quote the checked text (for example `raise "bad value #{v}"`). That
  contradicts the catalogue line "they do not include the offending text" (`telemetry.ex:221-222`).
- **Fix:** keep only the exception module, the way `Hooks.Runner.describe/3` does.
- **PLAUSIBLE.** It depends on user guard code.

## Summary table

| ID | Sev | One line |
|---|---|---|
| TEL-1 | HIGH | `~> 1.0` permits telemetry < 1.3; the memory tool's 3-tuple span return crashes every command |
| TEL-2 | MED | Turn.Server run `:exception` reason is `{:task_down, {exc, st}}`: error.type is always task_down, and stacktrace args leak |
| TEL-3 | MED | Turn.Server admission (on_prompt, guardrails) and on_turn_end run with no caller ctx → orphan traces |
| TEL-4 | MED | `IO.warn` prints the full model output on validation failure (`base_agent.ex:801`) |
| TEL-5 | MED | Hook `contract!` inspects the hook's return (prompt or tool data) into the exception reason and the error log |
| TEL-6 | MED | No telemetry for circuit-breaker state changes or Retry; anonymous string logs |
| TEL-7 | MED | invoke_agent stop has no total usage, iterations or finish reason (semconv Recommended) |
| TEL-8 | LOW | Info-level logs on every run, LLM call and tool call; no data in the default format |
| TEL-9 | LOW | Tool timeout leaves inner (memory, sub-agent) spans open; undocumented |
| TEL-10 | LOW | `usage: nil` in llm_call stop (non-streaming, summarizer) |
| TEL-11 | LOW | `get_response/2` requests have no llm_call span; tokens uncounted |
| TEL-12 | LOW | Turn.Server: admission crash and start persist failure emit no run span |
| TEL-13 | LOW | Workflow stop has no success/failure status |
| TEL-14 | LOW | Catalogue lacks the semconv memory-operation mapping |
| TEL-15 | LOW | A2A Server attaches untrusted inbound baggage |
| TEL-16 | LOW | No telemetry for Batch, AgentPool, ResumeReaper, Turn.Server unavailable |
| TEL-17 | LOW | `:guard_error` violation text embeds the guard's exception message |
