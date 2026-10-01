# Audit: agents (lib/normandy/agents/**, lib/normandy/dsl/**)

Branch feat/claudio-0.7-migration, HEAD 78ca1ab. Read-only audit; nothing was executed (no mix).
"verified" = I read the code paths; "theory" = plausible, says what would confirm it.

### AGENTS-1. Turn.Server runs raising code inside the gen_statem; a bad user input crashes the session and can take down Turn.Supervisor
- Severity: HIGH
- Category: 4 (contracts / exceptions as control flow), 6 (OTP)
- Location: lib/normandy/agents/turn/server.ex:179-198 (also :286-312, :391); lib/normandy/agents/base_agent.ex:537-554, :1849; lib/normandy/agents/turn/supervisor.ex:20-25
- Evidence:
  ```elixir
  def handle_event({:call, from}, {:turn, user_input}, :idle, data) do
    config = BaseAgent.admit_turn_input(data.config, user_input)   # raises ValidationError / ViolationError
  ```
  `admit_turn_input/2` raises `Normandy.Schema.ValidationError` on schema failure and `run_input_guardrails!` raises `Guardrails.ViolationError` on a block. Same exposure: `emit/3` calls the subscriber fun (`sub.(name, meta)`), and `handlers.append/convert/validate/guard` run synchronously in the server process.
- Why it's a problem: an input rejected by a guardrail or schema is an expected outcome. In the Driver shell it raises to the caller. In the Server shell it crashes the statem instead of replying `{:error, _}`. The caller gets an exit, the child is `restart: :transient` so it is restarted, and the `DynamicSupervisor` default intensity is 3 restarts in 5s. Four rejected inputs across any sessions in 5s terminate `Turn.Supervisor`, which kills every live session. A throwing subscriber callback does the same.
- Fix: in the `{:turn, _}` clause wrap `admit_turn_input` in `try/rescue` and reply `{:error, {:rejected, exception}}`. Wrap `emit` and the sync handler calls so a raise becomes `{:fail, reason}`.
- Confidence: verified (read the code paths; not run)

### AGENTS-2. ConfigTemplate silently drops guardrails, retry, circuit-breaker, MCP and JSON-retry settings on Tier-2 rebuild
- Severity: HIGH
- Category: 1 (silent loss of config), 3 (security control disabled)
- Location: lib/normandy/agents/config_template.ex:18-44, :59-90; consumer lib/normandy/agents/turn/server.ex:115-151
- Evidence: `from_config/2` serialises model, temperature, max_tokens, iterations, concurrency, name, prompt spec, schemas, max_messages and behaviours refs. `rebuild/3` builds a `%BaseAgentConfig{}` from only those. Nothing carries `input_guardrails`, `output_guardrails`, `output_guardrails_streaming_mode`, `output_guardrails_chunk_size`, `retry_options`, `circuit_breaker`, `enable_json_retry`, `json_retry_max_attempts`, `mcp_servers` or `initial_memory`.
- Why it's a problem: an agent configured with input/output guardrails behaves correctly through the Tier 0/1 path (config passed in). Through the thin-start path (`template_provider` set, `Server` has no `:config`) the rebuilt config has `input_guardrails: []`, so the guardrails are disabled with no error or log. Retry and circuit breaker vanish the same way, and `reset_memory/1` on the rebuilt config puts a nil `initial_memory` back. The moduledoc lists only client, registry and hooks as excluded.
- Fix: add the missing serialisable fields to the template (guard specs are `{module, opts}` terms). Have `rebuild/3` fail loudly if a field it cannot persist (the `circuit_breaker` pid) was set. Add a round-trip test, `rebuild(from_config(c)) == c` modulo client, registry and hooks.
- Confidence: verified (read both functions)

### AGENTS-3. Output guardrails are fail-open, and the non-streaming path gives the caller no signal
- Severity: HIGH
- Category: 1 (silent fallback), 3 (security)
- Location: lib/normandy/agents/base_agent.ex:1859-1876 (non-streaming), :1950-1982 (accumulate), :1252-1278 (incremental)
- Evidence:
  ```elixir
  {:error, violations} ->
    emit_guardrail_violation(:output, config, guards, violations)
    IO.warn("Agent output guardrail violation: " <> ...)
    :ok
  ```
- Why it's a problem: a guard that denies (e.g. an SSN regex in the DSL moduledoc example) does not stop the response. The turn continues to `:finalize` and the violating text is returned and persisted to memory. The streaming paths at least tag `:guardrail_violations` on the response. The non-streaming path (`run/2`, `Turn.Server`) returns a plain response, so a caller cannot tell a blocked answer from a clean one except via telemetry. `Normandy.DSL.Agent`'s `guardrails :output` doc does not say this. Input guardrails raise, output guardrails do not.
- Fix: at minimum tag or return the violation in the non-streaming result (parity with streaming). Better, add an `on_violation: :block | :warn` option that defaults to block. Document the current log-and-continue posture on `guardrails/2`.
- Confidence: verified. The code comment calls it deliberate ("log-and-continue"), so this is a design-level HIGH. The cost is that an output "guardrail" does not guard.

### AGENTS-4. Workflow DSL: `transform` and `when_result` cannot be used, and `condition` is never evaluated
- Severity: HIGH
- Category: 8 (docs vs reality), 7 (dead code)
- Location: lib/normandy/dsl/workflow.ex:252-277 (macros), :309 and :316 (`Macro.escape(steps)`), :343-376 (`execute_step`); test/dsl/workflow_transform_integration_test.exs:1-10
- Evidence: steps are stored with real anonymous funs (`transform: fn ...`, `condition: fn result -> case ... end`), then `unquote(Macro.escape(steps))` in `__before_compile__`. `Macro.escape/1` raises on anonymous funs. The repo's own test admits it ("the limitation is only in defining workflows with transforms in test modules due to how Elixir's macro system handles function escaping at compile time"). Separately, `step.condition` is never read in any `execute_step` clause.
- Why it's a problem: the moduledoc's main example (`transform fn ...` and `when_result do ... end`) either fails to compile or, where it compiles, `when_result` does nothing. "Conditional execution" and "Compile-time workflow validation" in the Features list are both untrue. `transform` is also skipped when `input` is nil or a binary (`get_step_input/2` only applies it in the `from:` and fallback branches).
- Fix: store funs as MFA or capture AST and expand it inside the generated `execute` (do not escape them). Implement or delete `when_result`. Correct the moduledoc.
- Confidence: verified by reading the code and the test comment. I did not compile a workflow with a `transform`.

### AGENTS-5. ValidationMiddleware silently turns string-keyed input into an empty struct and can return the blank schema in place of the input
- Severity: MEDIUM
- Category: 1 (silent fallback)
- Location: lib/normandy/agents/validation_middleware.ex:62-66 (`validate_input_map`), :72 (`{:ok, input_schema}`), :137 and :143 (output equivalents)
- Evidence:
  ```elixir
  schema_module == Normandy.Agents.BaseAgentInputSchema ->
    {:ok, struct(schema_module, input_map)}
  ...
  true -> {:ok, input_schema}     # "Schema doesn't support validation, return as-is"
  ```
- Why it's a problem: `struct/2` ignores non-atom keys. `BaseAgent.run(agent, %{"chat_message" => "hi"})` (JSON or Phoenix params) validates "OK" and sends an empty `chat_message: nil` to the LLM. The `true ->` branch returns the agent's own empty `input_schema` template, not the input. `admit_turn_input` then uses `validated || user_input`, which does not recover because the blank struct is truthy. Output has the same shape.
- Fix: cast string keys through the schema (`Validate.cast`) or reject unknown or non-atom keys. In the `true` branch return `{:ok, input}`.
- Confidence: verified for the base-schema string-key case. The `true` branch needs a schema module without `__schema__/1`, which I did not trace.

### AGENTS-6. Fail-open `function_exported?` without `Code.ensure_loaded` skips validation and `prepare_input`
- Severity: MEDIUM
- Category: 1 (silent fallback)
- Location: lib/normandy/agents/validation_middleware.ex:68, :133; lib/normandy/agents/dispatch.ex:93, :120, :129
- Evidence: `function_exported?(schema_module, :__schema__, 1)`, `function_exported?(mod, :validate, 1) and function_exported?(mod, :validate!, 1)`, `function_exported?(tool.__struct__, :prepare_input, 2)`. `BaseAgent.stream_response_from_llm` (base_agent.ex:1164-1169) documents exactly this pitfall and calls `Code.ensure_loaded`; these sites do not.
- Why it's a problem: `function_exported?/3` is false for a module that is not yet loaded (dev and test run in interactive mode, and releases can use lazy-loaded modules). A tool whose module has not been loaded yet is treated as having no `validate/1`, so malformed LLM input skips schema validation and reaches `execute`. A tool with a custom `prepare_input/2` gets the default `struct/2` mapping instead. The input and output schema validators in ValidationMiddleware degrade to pass-through the same way.
- Fix: call `Code.ensure_loaded!/1` (or `Code.ensure_loaded?/1`) before each probe, or use a generated `__info__`-style marker.
- Confidence: theory. Confirm by calling `Dispatch.validate_input/2` in a fresh `iex -S mix` before the tool module is referenced. The stream_converse comment shows the author has been bitten by this.

### AGENTS-7. ConverseResult.normalize catch-all treats any term, including `{:error, _}`, as a model response
- Severity: MEDIUM
- Category: 1 (silent fallback on external data)
- Location: lib/normandy/agents/converse_result.ex:31; lib/normandy/agents/base_agent.ex:364-370
- Evidence: `def normalize(other), do: {other, nil, %{}}`. `call_llm_with_resilience` always wraps the client return as `{:ok, result}`, so a `Model` impl that returns `{:error, reason}` reaches `normalize({:error, reason})`.
- Why it's a problem: the `{:error, reason}` tuple becomes the "response". `call_turn_llm` then does `Map.get(r, :tool_calls)` on a tuple (BadMapError) or, via `Turn.tool_calls/1`, treats it as no tool calls and validates a tuple as the final output. The failure shows up far from the cause, or as a bogus success. The retry and circuit-breaker `{:error, _}` clauses never fire for a client that returns errors as values, because the `{:ok, result}` wrap hides them.
- Fix: normalize only struct, binary and the documented tuple shapes, and raise `ArgumentError` for anything else (consistent with the meta check two clauses up). Treat a returned `{:error, r}` as a failure inside `llm_call` so retry and breaker see it.
- Confidence: verified for the code path. The Model protocol spec does not allow `{:error, _}`, but the built-in adapters were not checked here.

### AGENTS-8. Malformed JSON tool input is silently replaced with `%{}` and the tool still runs
- Severity: MEDIUM
- Category: 1 (silent fallback on external data)
- Location: lib/normandy/agents/dispatch.ex:344-355; used by `classify/3` at :185 and `to_tool_call/1`
- Evidence:
  ```elixir
  {:ok, parsed} when is_map(parsed) -> parsed
  _ -> %{}
  ...
  def normalize_tool_input(_), do: %{}
  ```
- Why it's a problem: an LLM tool call whose `input` is truncated or invalid JSON, a JSON array, or any non-map becomes an empty input. Tools without a generated `validate/1` (hand-rolled tools, tools with `prepare_input/2`) execute with defaults or missing fields. A "delete" tool with an optional filter then runs unfiltered. The model never learns its arguments were discarded. Schema-based tools fail validation, which is the better behaviour.
- Fix: return `{:error, :invalid_tool_input}` from `normalize_tool_input`. `classify/3` should map that to a `{:deny, %ToolResult{is_error: true}}` that tells the model.
- Confidence: verified

### AGENTS-9. `resume_policy: :eager` is dropped on every Session start path, so eager resume is unreachable via Session
- Severity: MEDIUM
- Category: 2 (option handling), 7 (dead code)
- Location: lib/normandy/agents/turn/session.ex:99, :117-128; lib/normandy/agents/config_template.ex:23, :46-49; lib/normandy/agents/turn/server.ex:78-82
- Evidence: Tier 0/1 branch: `Keyword.take([:session_id, :store, :registry, :subscriber, :handlers, :approval_timeout_ms, :idle_timeout_ms])` has no `:resume_policy`, and `Server.init` then uses `Keyword.get(opts, :resume_policy, :lazy)`. Tier-2 branch: the template is written with `ConfigTemplate.from_config/2`, which hardcodes `resume_policy: :lazy`. With no `:config`, `Server.init` takes the policy from the stored template (`template_resume_policy`), overriding the `:resume_policy` opt `Session` just put. `from_config/3` has no caller in lib/.
- Why it's a problem: `Session.run(opts: resume_policy: :eager)` is accepted and ignored. No session created through `Session` can become eager, so `ResumeReaper` and `SessionStore.list_resumable` have nothing to find unless a host writes templates by hand.
- Fix: pass `resume_policy` into `from_config/3` in `Session`, and add `:resume_policy` to the Tier 0/1 `Keyword.take`. Validate the value is `:lazy` or `:eager`.
- Confidence: verified by reading. I did not check whether any store derives "resumable" from something other than the template.

### AGENTS-10. DSL.Agent `max_messages` has no effect, and unknown config and override keys are silently ignored
- Severity: MEDIUM
- Category: 2 (option handling), 8 (docs)
- Location: lib/normandy/dsl/agent.ex:457-463, :466-468; lib/normandy/agents/base_agent.ex:60-135 (no `max_messages` read); also base_agent.ex:411-416
- Evidence: `build_config` does `Map.put(base_config, :max_messages, ...)`. `BaseAgent.init/1` builds memory from `Map.get(config, :memory)` only. `new/1` reduces every override into the map with `Map.put`, with no key check. `run/3` with `stream: true` and no `on_chunk` silently falls back to the non-streaming run.
- Why it's a problem: the documented `max_messages` option leaves conversation memory unbounded, so cost and context-window growth go unnoticed. `MyAgent.new(client: c, temprature: 0.2)` or any typo is accepted. The `:override` merge could even set `:memory` or `:client`. `stream: true` without a callback runs a non-streaming request.
- Fix: in `build_config` set `memory: AgentMemory.new_memory(max_messages)`. Check overrides against an allow-list and raise `ArgumentError` on unknown keys. Raise in `run/3` when `stream: true` has no `:on_chunk`.
- Confidence: verified (`max_messages` grep shows no consumer in base_agent.ex)

### AGENTS-11. Streaming path diverges from non-streaming: no retry or breaker, errors returned as a success value, no input validation, no conversion
- Severity: MEDIUM
- Category: 1, 4, 7 (duplicated logic that drifted)
- Location: lib/normandy/agents/base_agent.ex:853-871 (`run_stream_turn`), :916-951 (`call_stream_llm`), :1160-1206, :893-909 (`streaming_handlers`)
- Evidence:
  ```elixir
  catch
    {:stream_turn_error, error, config_at_failure} ->
      IO.warn("Streaming error: #{inspect(error)}")
      {config_at_failure, %{error: error}}
  ```
- Why it's a problem: (a) A stream failure returns a bare `%{error: error}` map as the "response", where the non-streaming path raises. Callers matching on `{config, response}` cannot tell the two apart. The spec says `struct()` or `map()`. The returned config keeps the user message with no assistant reply. (b) `stream_response_from_llm` bypasses `call_llm_with_resilience`, so `retry_options` and `circuit_breaker` do not apply to streaming. (c) `admit_stream_turn_input` skips schema validation (documented in a comment, not in the public `@doc`). (d) `convert` is identity in streaming, so the final response shape differs from `run/2` with tools. (e) `IO.warn(inspect(error))` can print provider error bodies to stderr.
- Fix: raise or return `{:error, _}` consistently. Route streaming setup (not the stream body) through the retry and breaker wrapper. Document the validation and conversion differences on `stream_response/3`.
- Confidence: verified for (a) to (c) and (e). (d) is verified in the handler code but the downstream shape was not traced.

### AGENTS-12. Turn.Server `dispatch` returns results out of batch order; failure mislabelled `:llm_error`; no run span; "live" turn ids
- Severity: MEDIUM
- Category: 7 (divergence between interpreters), 4
- Location: lib/normandy/agents/turn/server.ex:466-472 (`held = executed ++ denied`), :230-238 (`:DOWN` handler), :418-425 (`turn_id: "live"`); turn.ex:296-312
- Evidence: the non-parked path returns `{:tool_results, executed ++ denied}`. The core comment says results are reordered "to the original tool_use order" but only the approval path calls `reorder/2`. `BaseAgent.dispatch_turn_tools` is `ordered: true` over the original `calls`. The `:DOWN` clause always steps `{:llm_error, {:task_down, reason}}` even when the dead task was `:dispatch_tools`, `:execute_approved` or `:maybe_compact`. `append_to_store` writes every entry with `turn_id: "live"`. `Server` never wraps a turn in `with_agent_run_span`.
- Why it's a problem: with calls `[A (denied), B (executed)]` the tool_result blocks are stored `[B, A]`. Ids still match, so the API accepts it, but the order differs from the Driver shell and from the documented contract. A tool crash is reported as an LLM error in `Turn.State.error` and the caller's reply. After passivation and rehydration `AgentMemory.from_entries` makes `current_turn_id` "live" for the whole history, so `delete_turn/2` and per-turn accounting treat the session as one turn. The Server path emits no `[:normandy, :agent, :run, *]` events although the other shells do.
- Fix: run results through `reorder/2` (or sort by `pending_calls`) in `dispatch/2`. Tag the task kind in `task_ref` state and emit `{:tool_error, _}` for tool tasks. Use the real `memory.current_turn_id` when appending. Wrap the Server turn in the run span.
- Confidence: verified for ordering, labelling and span. "live" turn-id impact is theory (check `AgentMemory.delete_turn` and trimming against `from_entries`).

### AGENTS-13. Server tasks are plain `spawn` (unlinked): a crashed server orphans in-flight LLM and tool work
- Severity: MEDIUM
- Category: 6 (OTP)
- Location: lib/normandy/agents/turn/server.ex:360-378
- Evidence: `spawn(fn -> ref = receive do {:monitor_ref, r} -> r end; send(server, {ref, fun.(handlers, current)}) end)`
- Why it's a problem: with no link, if the statem dies (AGENTS-1, an unhandled event per Known A4, a store exit) the task keeps running. The LLM call finishes, and tool side effects (writes, payments) execute. Its result goes to a dead pid. The restarted server then re-runs the same work (Known A4), so tool side effects can be doubled and the first copy is invisible. The `Task.async_stream` inside `dispatch/2` is linked only to the orphan.
- Fix: start under `Task.Supervisor.async_nolink` owned by a supervisor, or `spawn_link` plus `trap_exit` in the server. Kill the task in `terminate/3`.
- Confidence: verified (spawn without link or terminate callback). Duplicate-execution consequence follows from Known A4.

### AGENTS-14. Server `init` swallows store errors and loads state in `init/1`; Session and Server disagree on the store contract
- Severity: LOW
- Category: 1, 6
- Location: lib/normandy/agents/turn/server.ex:153-165, :115-151; lib/normandy/agents/turn/session.ex:77-81, :101
- Evidence: Server: `case mod.load_turn_state(...) do {:ok, ts} -> ts; _ -> nil end` and `template_resume_policy` has `_ -> default`. Session: `{:ok, term} -> term; :error -> nil` (a `{:error, _}` return is a CaseClauseError) and `:ok = store_mod.save_config_template(...)` (MatchError, not an error tuple, although the history branch two lines later carefully returns `{:error, reason}`).
- Why it's a problem: a transient store error during Server `init` makes the server start fresh with `turn_state: nil`. A session parked in `:awaiting_approval` (or mid-turn, under eager policy) is then ignored, and the next turn overwrites the persisted state. The store lookups plus credential fetch in `reconstruct_config!` all block `init/1`, so the supervisor `start_child` waits.
- Fix: treat `{:error, _}` as an init failure (`{:stop, reason}`); keep `:error` or `{:ok, nil}` as "no state". Normalise the Session/Server pattern, return `{:error, _}` from Session for a template-save failure, and move loads to `handle_continue`.
- Confidence: verified (code); store behaviour's documented return values not checked.

### AGENTS-15. Dead code and doc claims that no longer match
- Severity: LOW
- Category: 7, 8
- Location: lib/normandy/agents/turn.ex:249-252 (`{:tool_error, _}`; grep shows no producer in lib/); lib/normandy/agents/validation_middleware.ex:192-207 (`validation_enabled?/1`, no caller; moduledoc "Optional Enforcement: Can be disabled" has no switch); lib/normandy/dsl/workflow.ex:418-423 (`run_agent/2`); lib/normandy/dsl/agent.ex:52 ("Compile-time validation")
- Evidence: `run_agent` has `{_updated_agent, response} -> {:ok, response}` before `{:error, reason} -> {:error, reason}`. The first clause matches every 2-tuple, so the `{:error, _}` clause is unreachable. `BaseAgent.run/2` raises and never returns `{:error, _}`, so a workflow step failure crashes `execute/1` instead of returning `{:error, {step, reason}}`. DSL.Agent validates `model` at runtime in `build_config` (`raise "model is required..."`), not at compile time. `DSL.Agent.new/1` always returns `{:ok, agent}` and raises otherwise. `Turn.Driver` and `Turn.Inline` have no `:execute_approved` clause (safe today only because neither can park).
- Fix: delete the dead clauses and function. Rescue in `run_agent` to deliver the documented error path. Correct the moduledocs.
- Confidence: verified

## Known (from prior audit)
- A3 (dangling tool_use across crash): still present, turn.ex:134 (append before dispatch) and server.ex:290-292 (store append per effect), no repair on resume.
- A4 (transient restart replays work with stale child args): still present, supervisor.ex:20-25, session.ex:96-129 (bakes `turn_state` and `config`), server.ex:72-76 (opts win over store). No catch-all `:info` clause (server.ex:208-257): still present.
- A8 (output schema block silently dropped): still present, base_agent.ex:258-266 (`__specification__()` + `rescue _ -> system_prompt`).
- CircuitBreaker linked-per-init leak: still present, base_agent.ex:101 (`{:ok, cb} = CircuitBreaker.start_link`); it also starts before `normalize_max_tool_iterations` and `normalize_max_tool_concurrency` raise (base_agent.ex:119-122), contrary to the comment at :61-62.
- `Server.run` `:infinity` and no deadline in `:running`: still present, server.ex:47, :461, :493.
- Handshake `receive` without `after`: still present, server.ex:366-370.
- Terminal-state persist best-effort: still present, server.ex:335 and :341.
- Passivation window / no `:noproc` retry: still present, session.ex:35-37, server.ex:260-262.
- No batch-completeness assertion: still present, turn.ex:296-312.
- Native-registry duplicate server race: still present, server.ex:401-406 (and Session moduledoc admits it).

## Area summary
- Core FSM (`Turn.step/2`) is tight and total. The three interpreters agree on the happy path, but Server diverges on result ordering, error labelling, span coverage and turn ids, and unlike the other two it runs raising code inside the statem (AGENTS-1, AGENTS-12).
- The biggest silent-degradation risks are config that does not survive persistence (AGENTS-2, AGENTS-9), fail-open guardrails and validation (AGENTS-3, AGENTS-5, AGENTS-6), and LLM-supplied input coerced to empty (AGENTS-8).
- The DSLs overpromise: Workflow's `transform` and `when_result` cannot work as documented, and DSL.Agent's `max_messages` is a no-op (AGENTS-4, AGENTS-10); both need tests that exercise the documented examples.
