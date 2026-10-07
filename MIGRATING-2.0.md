# Migrating from Normandy 1.x to 2.0

Normandy 2.0 moves to Claudio 0.7 and makes its defaults work on Claude Opus 4.7 and later,
which reject sampling parameters and `budget_tokens` thinking. Each breaking change below
says what to do.

## 1. `temperature` is unset by default

`BaseAgentConfig`, `BaseAgent.init/1`, the `agent do ... end` DSL and the summarizer no longer
send a temperature (they defaulted to 0.9, 0.7 and 0.3). Pass one explicitly only for models
that accept it:

```elixir
BaseAgent.init(%{client: client, model: "claude-haiku-4-5", temperature: 0.7})
```

- **Custom `Model` implementations** now receive `temperature: nil`. Omit the field from the
  request; don't send JSON `null`, which many OpenAI-compatible servers reject.
- **Persisted session templates** stored the old default `temperature: 0.9` and restore it on
  resume. Re-save them with `temperature: nil`, or resumed sessions on Opus 4.7+ get a 400.

## 2. Prompt changes

`SystemPromptGenerator.generate_prompt/2` is now `/1`. Drop the second argument:

```elixir
SystemPromptGenerator.generate_prompt(spec)
```

- The `# AVAILABLE TOOLS` section is gone: adapters send tools through the API `tools`
  parameter. A custom `Model` that does prompt-based tool calling must describe the tools
  itself from `opts[:tools]`.
- The prompt text changed: the two "Always ..." lines are removed, an empty
  `# OUTPUT INSTRUCTIONS` heading is no longer emitted, the context section adds "Use this
  information where it is relevant to the request.", and the output-schema and
  retry-feedback wording changed. Update prompt snapshot tests.
- Agents with tools no longer get an `# OUTPUT SCHEMA` block on tool-loop calls. 1.x showed
  the model the internal tool-call field map there. Their system prompt changes, so the first
  request after upgrading misses the prompt cache.
- User turns given as the default chat input (`%{chat_message: ...}` or a
  `BaseAgentInputSchema`) reach the model as their plain text, not `{"chat_message": ...}`
  JSON. As JSON, Haiku 4.5 often denied remembering earlier turns. Custom input schemas are
  still sent as JSON.
- A `:summarize` compaction stores its summary as a plain string, inside
  `<conversation_summary>` tags (§35), not a `BaseAgentOutputSchema`.
- The default summarization prompt changed. It tells the model to keep facts the user stated
  word for word and to carry an earlier summary's facts forward; the 1.x prompt asked for a
  concise summary and lost such facts after a few rounds. Direct `Summarizer` callers can
  pass `:prompt`; the `:summarize` compactor always uses the default.
- `Turn.Server` stores the admitted user input (a map cast to the input schema), the value
  memory holds, instead of the raw argument to `run/2`.

## 3. MCP tool allowlists take exact names

`Normandy.MCP.ServerConfig.allow_tools/2` raises `ArgumentError` on `*` or `?`. The connector
matches names literally, so a glob never enabled anything. The struct field
`:tool_configuration` is now `:allowed_tools`.

```elixir
ServerConfig.allow_tools(server, ["search_events", "fetch_data"])
```

## 4. The `Model` protocol is `converse/3` + `stream/3`

`Normandy.Agents.Model` has two functions, both taking a `%Normandy.LLM.Request{}`:

| 1.x | 2.0 |
|---|---|
| `completitions/6` | removed: delete your implementation |
| `converse(client, model, temperature, max_tokens, messages, response_model, opts)` | `converse(client, %Request{model:, system:, messages:, response_model:, temperature:, max_tokens:, tools:, mcp_servers:, task_budget_remaining:}, opts)` |
| returns `response`, `{response, usage}` or `{response, usage, meta}` | returns `{:ok, %Normandy.LLM.Response{content:, stop_reason:, usage:, meta:}}` |
| `{:error, %LLMError{}}` | unchanged |
| `stream_converse/7` (optional, found by `function_exported?`) | `stream(client, %Request{}, opts)`, required; return `{:error, %LLMError{type: :unsupported}}` if you can't stream |
| `opts[:raw]` | `request.response_model == nil`: return the answer text |
| `opts[:tools]`, `opts[:mcp_servers]`, `opts[:task_budget_remaining]` | `request.tools`, `request.mcp_servers`, `request.task_budget_remaining` |
| the system prompt as the first `"system"` message | `request.system`; `request.messages` holds no system message |
| your `stream_converse/7` called `opts[:callback]` | `stream/3` returns events only; Normandy calls the callback |

`Normandy.Agents.ConverseResult` is gone. Any other return from `converse/3` raises
`ArgumentError` naming your implementation. `JsonDeserializer.deserialize_with_retry/5`
takes `(content, schema, client, %Request{}, opts)` instead of eight arguments.

Streaming (`BaseAgent.stream/3`, see §20) with a client that
can't stream fails with `Normandy.LLMError` `type: :unsupported` (the client's own
error); in 1.x it was `type: :unknown`.

## 5. Model catalog and compaction

- The `ModelCatalog` behaviour has one callback:

  ```elixir
  @callback context_window(model, opts) :: {:ok, pos_integer()} | {:error, term()}
  ```

  `get/1` and `supports?/2` are gone.
- `ModelCatalog.ModelsAPI` is the default. It reads `max_input_tokens` from the Anthropic
  Models API through the agent's `ClaudioAdapter`.
- `ModelCatalog.Static` is deprecated. It delegates to `ModelsAPI` and will be removed in 3.0.
  Its static model table is gone. Templates persisted by 1.x name it, which is why it stays.
- **Compaction now runs on current models.** Before, the static table didn't know them, so
  a real compactor silently did nothing. Now memory gets truncated, and the `:summarize`
  strategy makes extra paid LLM calls.
- **Compaction runs at the start of every turn,** before the first LLM call, as well as after
  each tool batch. In 1.x it ran only after tool batches, so an agent that never called a tool
  never compacted and its memory grew without bound. A `[:normandy, :agent, :compaction]`
  telemetry event reports every compactor run (token counts, strategy, whether it compacted,
  and the compactor's `:error` / `:reason` when it failed).
  Consequence: an agent with no tools and a real compactor now resolves its context window on
  every run. With a client that isn't a `ClaudioAdapter` and no pinned `:context_window`, that
  lookup fails and `run/2` returns `{:error, %Normandy.ModelCatalogError{}}` (`run!/2` raises
  it) before the first LLM call, where
  1.x silently never compacted. Pin `:context_window` (see below).
- **Compaction makes a network call:** one Models API request per model per agent config.
  Coordinators that discard the config `BaseAgent.run/2` returns (batch, orchestrators, agent
  processes) repeat it on every run.
- **A failed lookup fails the turn** with `Normandy.ModelCatalogError`. Under `Turn.Server` it
  arrives the same way, as `{:error, %Normandy.ModelCatalogError{}}` (see §12).
- **Non-Claude clients:** a non-`NoOp` compactor with a client that isn't a `ClaudioAdapter`
  must pin the window, or `BaseAgent.init/1` and `ConfigTemplate.rebuild/3` raise
  `ArgumentError`:

  ```elixir
  behaviours: %Normandy.Behaviours.Config{
    compactor: {Normandy.Behaviours.Compactor.WindowManager, [context_window: 200_000]}
  }
  ```

  Pinning `:context_window` also skips the lookup entirely (offline use). It was `:max_tokens` in 1.x (see §22).

## 6. `WindowManager.new/1` requires `:max_tokens`

`WindowManager.for_model/2` and the `:model_limits` field are removed. Pass the window:

```elixir
WindowManager.new(max_tokens: 200_000, strategy: :sliding_window)
```

## 7. The summarizer requires a model

`Summarizer` raises `ArgumentError` unless `opts[:model]` or the agent's top-level `:model` is
set. Its fallback named a retired model.

## 8. Caching and `DateTimeProvider`

- `DateTimeProvider` returns today's date (`"2026-09-30"`) titled "Current Date", instead of
  a microsecond timestamp that changed on every call and broke prompt caching.
- With `enable_caching: true`, Normandy no longer marks the last user message. Requests carry
  the API's top-level automatic `cache_control`, which also caches tool loops. Breakpoints:
  system prompt, last tool, automatic. That is 3 of the API's 4, so callers who add their own
  `cache_control` markers can add at most one more, or the API rejects the request.
- Keep context-provider output stable across calls, or caching stops at the system prompt.
- The API returns 400 if your own `with_cache/1` markers fill all four breakpoint slots, or
  mark the last block with a TTL different from the automatic one's.
- A `base_url` gateway that doesn't support top-level `cache_control` rejects it; set
  `enable_caching: false` there.

## 9. Usage maps

Claudio 0.7's `Response.usage` adds keys and returns `nil` for absent documented fields. The
usage maps in telemetry and those returned to callers change shape.

## 10. Postgrex 0.22.4 or later

If your app uses the optional Postgres session store, Normandy now requires `postgrex`
`>= 0.22.4` (was `~> 0.19`). Earlier releases carry EEF-CVE-2026-66838 and
EEF-CVE-2026-58225. Run `mix deps.update postgrex`.

## 11. LLM failures are `Normandy.LLMError`; `run` returns tuples

- `Model.converse/3` returns `{:error, %Normandy.LLMError{}}` on failure (see §4). Code
  that calls `converse/3` directly must handle it.
- `BaseAgent.run/2,3` (and a DSL agent's `run/2,3`) return `{:ok, config, response}` or
  `{:error, exception}`, where the exception is a `Normandy.LLMError`,
  `Schema.ValidationError`, `Guardrails.ViolationError`, `HookHaltError`,
  `ModelCatalogError` or `TurnError`. Other exceptions (bugs) still raise.
  `run!/2,3` keeps 1.x's shape: `{config, response}`, raising the same exceptions. The
  quickest migration is `run(` → `run!(`.
- `AgentProcess.run/3`, `Reactive` results and workflow step errors are `{:error, exception}`
  (was `{:error, {:exception, exception, stacktrace}}`); the stacktrace is logged.
- Returned errors are no longer logged: `run/2,3`, `stream/3` and `AgentProcess` used to log
  an `LLMError` or a rejected input at `:error` level (`normandy agent exception`,
  `normandy llm call exception`, `Agent <id> failed: ...`). Alert on the
  `[:normandy, :agent, :run, :exception]` telemetry event instead. A bug (an exception
  that is not Normandy's own, an exit or a throw) is no longer logged by `run/2,3` or
  `stream/3` either: it is raised to the caller. It is logged once, where Normandy turns it
  into a value (`AgentProcess`, `Reactive`, a workflow step, `Turn.Server`, the A2A server),
  and that line, like every Normandy crash log (hooks, `Retry`), names the exception module
  or the kind only: never the exception's message, a thrown term or an exit reason, and
  stacktrace frames keep arities, never arguments.
- A final returned LLM failure (`{:error, _}` from `converse/3`) and an open circuit
  (`type: :circuit_open`) are a `Normandy.LLMError`: `{:error, %Normandy.LLMError{}}` from
  `run/2,3`, raised by `run!/2,3`.
- An exception raised by `converse/3` is re-raised with its original type. With a circuit
  breaker enabled it used to arrive wrapped as `RuntimeError "LLM call failed: <msg>"`; that
  wrapper is gone, so rescue the original exception type (it is not an `LLMError`).
- With a circuit breaker enabled, every returned LLM failure counts as a breaker failure,
  including non-retryable ones such as `:authentication` or `:invalid_request`, so a
  persistently bad request can open the circuit.
- Enabling Claudio's client-level `retry:` (in `req_options` or the client config) together with
  the agent's `retry` options multiplies attempts, because Claudio retries HTTP failures before
  Normandy sees them.
- The default `retry_if` retries errors whose `retryable?` is true. A custom `retry_if`
  receives `{:error, %Normandy.LLMError{}}` for returned failures.
- API errors (401, 429, 529, 5xx, ...) and transport errors used to come back as an empty
  response. They now return `{:error, %Normandy.LLMError{}}` from the adapter and from
  `run/2` (`run!/2` raises it). `on_parse_failure: :error` returns `type: :invalid_output`.
- `stream/3` returns `{:error, %Normandy.LLMError{}}` when the stream fails (see §20). 1.x's
  `stream_response/3` and `stream_with_tools/3` returned `{config, %{error: reason}}`. A
  stream that ends without `message_stop` is now a failure, not a complete message.

## 12. `Turn.Server` failure replies and approval expiry

`Turn.Server.run/2` (and `Turn.Session.run/2`, `AgentProcess.run/3` with
`turn_engine: :server`) replies `{:error, exception}` where it used to crash the session,
and never a tagged tuple or a stacktrace. Normandy's own exceptions (`LLMError`,
`Schema.ValidationError`, `Guardrails.ViolationError`, `HookHaltError`,
`ModelCatalogError`) are replied bare; any other failure is a `Normandy.TurnError` whose
`:type` says what failed. In 1.x a rejected input or a crashing handler crashed the server
(the caller got an exit); the Wave 1 builds replied the tagged tuples on the left:

| 1.x / Wave 1 reply | 2.0 reply |
|---|---|
| `{:error, {:rejected, e}}` | `{:error, e}` (`ValidationError`, `ViolationError` or `HookHaltError{event: :on_prompt}`) |
| `{:error, {:hook_halted, e}}` | `{:error, e}` (`HookHaltError{event: :before_llm}`) |
| `{:error, {:task_down, {%LLMError{} = e, stacktrace}}}` | `{:error, e}` |
| `{:error, {:task_down, {other_exception, stacktrace}}}` | `{:error, %TurnError{type: :task_down, reason: other_exception}}` |
| `{:error, {:task_down, exit_reason}}` | `{:error, %TurnError{type: :task_down, reason: exit_reason}}` |
| `{:error, {:handler_crashed, name, e}}` | `{:error, %TurnError{type: :handler_crashed, handler: name, reason: e}}` |
| `{:error, {:persist_failed, r}}` | `{:error, %TurnError{type: :persist_failed, reason: r}}` |
| `{:error, {:approval_timeout, ids}}` (only with `on_approval_timeout: :fail`) | `{:error, %TurnError{type: :approval_timeout, reason: ids}}` |
| `{:error, {:unexpected_event, ...} = r}` | `{:error, %TurnError{type: :unexpected_event, reason: r}}` |
| `{:error, {:unresumable_state, status}}` | `{:error, %TurnError{type: :unresumable_state, reason: status}}` |
| `{:error, store_or_template_reason}` (session couldn't start) | `{:error, %TurnError{type: :session_unavailable, reason: store_or_template_reason}}` |

Any domain exception the turn's worker raises is replied bare like the `LLMError` row (a
`ModelCatalogError` from compaction, for example). A `{reason, stacktrace}` pair in an
exit reason, at the top or nested in tuples, loses its stacktrace (a throw's
`{{:nocatch, value}, stacktrace}` becomes `{:nocatch, value}`, a `GenServer.call` exit's
`{{e, stacktrace}, {GenServer, :call, args}}` becomes `{e, {GenServer, :call, args}}`);
lists, maps and structs inside the reason are kept as they are. A session that cannot start because an `on_session_start` hook
crashed or its injection could not be stored replies a `:session_unavailable` `TurnError`
whose `:reason` is the `:handler_crashed` or `:persist_failed` `TurnError`. The run
`:exception` telemetry event carries the same exception as `reason`, with `stacktrace: []`
(rejected input included, which was `reason: {:rejected, e}`), except that a non-Normandy
exception in it is reduced to `%{exception: module}` (see §14).

`on_turn_end` hooks receive `{:error, exception}` too; a `before_llm` halt is
`{:error, %HookHaltError{}}`, not `{:error, {:hook_halted, e}}`.

A failed turn's saved `Turn.State.error` is now the exception the turn failed with (the
one replied, so `{:approval_timeout, ids}` is saved as
`%TurnError{type: :approval_timeout, reason: ids}`), not the core's failure tuple, and a
non-Normandy exception in it is saved as `%{exception: module}` only: its fields and
message can hold the value it failed on. Nothing reads the field back.

Persisted sessions cannot be downgraded: a failed turn's saved `Turn.State.error` may now
hold a `%Normandy.TurnError{}`, an atom pre-2.0 code does not have, so its
`:erlang.binary_to_term(bin, [:safe])` rejects the saved turn state.

A `:subscriber` that raises, exits or throws no longer crashes the session: it is logged and reported as
`[:normandy, :turn, :subscriber, :exception]`, and the turn continues.

Approval expiry: a parked call that nobody approved now gets
`%{error: "No approver answered within <ms>ms, so the tool was not run. ...", denied: true,
expired: true}` (see §36) instead of the rejection result, and an
`:approval_expired` event plus `[:normandy, :turn, :approval, :expired]` telemetry
are emitted. Pass `on_approval_timeout: :fail` to end the turn instead of continuing.

Event meta additions: `:iteration` gains `final` (and the forced-final call is now
announced), `:awaiting_approval` gains `resumed`. `:steering` is emitted after the
turn state is persisted.

A turn that failed after the assistant's `tool_use` no longer leaves the session
unusable: the next turn appends an `interrupted: true` tool result for each
unanswered call.

## 13. Rolling deploys

`Turn.Server.run/2` now sends `{:turn, input, ctx}` and `Turn.Server.approve/2` casts
`{:approval, decisions, ctx}`; `AgentProcess.run/3` sends `{:run, input, ctx}` and
`AgentProcess.cast/3` sends `{:run_async, input, reply_to, ctx}`. `ctx` is the caller's
OpenTelemetry context, so the run nests under the caller's span. New servers still accept the
old shapes. An old-version server that receives a new shape has no matching clause and
crashes. When callers and servers run on different nodes, upgrade the nodes that host
`Turn.Server` and `AgentProcess` before the nodes that call or approve them.

On the Postgres and Redis session stores there is a second constraint, which that order does not
cover: a pre-2.0 node cannot load a session that a 2.0 node has run a turn for.

- The persisted `Turn.State` gains two fields, `tokens_compacted` and `trace_carrier`.
- `Turn.Server` persists the state at every suspend point and at the end of every turn
  (`:stopped` or `:failed`), and never deletes it. So every session a 2.0 node has served holds a
  2.0 state, whether its last turn finished or not.
- The pre-2.0 Postgres and Redis stores decode with `binary_to_term(bin, [:safe])`, which raises
  `ArgumentError` for an atom the node does not know. A pre-2.0 node knows neither field name.
- A pre-2.0 `Turn.Server` loads the turn state in `init/1`, so starting such a session on a
  pre-2.0 node crashes, lazy or eager.

So, on Postgres or Redis:

- Do not let pre-2.0 and 2.0 nodes host sessions from the same store at the same time. Move
  every session-hosting node to 2.0 together (stop the old ones before the new ones take
  sessions), rather than one node at a time.
- Rolling back to a pre-2.0 release after 2.0 has served sessions fails the same way for those
  sessions.

Other terms 2.0 writes (memory entries, config templates) may name atoms a pre-2.0 node lacks
too; only `Turn.State` was checked. ETS, Mnesia and InMemory keep terms as they are, so an old node
loads a 2.0 state and ignores the extra keys. In the other direction, a 2.0 node loads a pre-2.0
state: `Turn.Server` reads both new fields with `Map.get/3`. This section comes from reading the
1.3.0 and 2.0 code, not from running a mixed cluster.

## 14. Telemetry additions

The telemetry events are catalogued in `Normandy.Telemetry`. Existing events, measurements and
metadata keys keep their names and meanings; keys and events were added. Two things to know
if you attach handlers: `[:normandy, :agent, :run, :exception]` can be synthetic
(`reason: :killed`) and arrive without a matching `:start`, and the `[:normandy, :llm, :call, *]`
event named in old changelog entries never existed (the LLM call span is
`[:normandy, :agent, :llm_call, *]`; `[:normandy, :llm, :request, *]` is new).

The `stacktrace` of every Normandy `:exception` event (agent run, llm_call, tool execute,
hook, memory command, A2A request, workflow run, LLM request, `Turn.Server`) is now always
`[]` (1.x passed the real one, as `:telemetry.span/3` does). A stacktrace can hold call
arguments such as the config, so Normandy logs it and never emits it.

For the same reason, an `:exception` `reason` that is not one of Normandy's own exceptions (a
bug: a `KeyError` from a client, a tool or a hook) is emitted as
`%Normandy.TurnError{type: :task_down, reason: %{exception: KeyError}}`, and a `TurnError`'s
non-Normandy `:reason` as `%{exception: module}`; a raw Erlang error (`{:badkey, k, map}`) is
normalized to its exception first. Inside an exit reason or a thrown term, such an exception is
reduced at any depth of its tuples and lists, every `{reason, stacktrace}` pair loses its
stacktrace, and a call (`{reason, {GenServer, :call, [server, message, timeout]}}`) keeps its
arity in place of its arguments (`{GenServer, :call, 3}`), since the message can hold the
caller's data; the term's other values are kept. A failed turn's saved `Turn.State.error` is
reduced the same way. The raise, and the exception replied to the caller,
keep it whole. `error.type` for such a run is now `task_down`, not the exception module.

## 15. Agent memory and tool context

- `BaseAgentConfig` gains `tool_context` (default `%{}`), plain per-session data handed to
  tools that implement `Normandy.Tools.ContextualTool`. It is stored in the config
  template: templates saved before 2.0 rebuild with `%{}`, and `from_config/2` raises on a
  function or pid inside it. Never put secrets in it.
- `Dispatch.default_pipeline/0` and `Behaviours.Config.to_pipeline/1` now build a 4-arity
  `execute_fn` that passes the call's context. A custom 3-arity `execute_fn` still works
  for ordinary tools; a contextual tool run through it returns
  "<name> requires tool context".
- To use `Normandy.Tools.Memory` with Postgres, add a host migration calling
  `Normandy.Behaviours.MemoryStore.Postgres.Migration.up/0`; with Mnesia, call
  `Normandy.Behaviours.MemoryStore.Mnesia.create_tables/1`. See
  `docs/guides/agent-memory.md`.

## 16. Lifecycle hooks

- New: `Normandy.Behaviours.Hooks` modules on `Behaviours.Config.hooks` (see
  `docs/guides/hooks.md`). Nothing changes for an agent that sets none. Config templates
  gain `behaviours_refs.hooks`; templates saved earlier rebuild with `[]`.
- New replies from `Turn.Server.run/2` (shapes in §12): `{:error, %Normandy.HookHaltError{}}`
  (an `on_prompt` hook halted the input, or a `before_llm` hook halted the turn;
  `:event` tells which), `{:error, %Normandy.TurnError{type: :handler_crashed, handler:
  :admit | :after_tool | :before_llm | :after_compact}}`, and a `:session_unavailable`
  `TurnError` whose `:reason` is `{:invalid_hooks, message}` (a hook module missing on
  this node) or, while an `on_session_start` crash leaves the server `:unavailable`, the
  `:handler_crashed` `TurnError` (handler `:on_session_start`). `BaseAgent.run/2,3`
  returns `{:error, %Normandy.HookHaltError{}}` for both halts (`run!/2,3` raises it). A
  `before_tool` or `after_tool` hook crashing under `on_error: :reraise` inside the tool
  dispatch replies `{:error, %TurnError{type: :task_down, reason: e}}`; the server stays
  alive and the turn fails.
- **Behaviour change:** in `Turn.Server`, an admission that raises something other than a
  rejection (an input guardrail crashing, for example) now replies a `:handler_crashed`
  `TurnError` (handler `:admit`) instead of crashing the session.
- **Behaviour change:** `Turn.Server` now admits a turn's input before it repairs an
  interrupted tool batch; a rejected input repairs nothing (it stored nothing before too).
- **Behaviour change:** compaction keeps each kept message's entry id, and `Turn.Server`
  stores each message under the id its memory gave it, on every session store.
  `SessionStore.Redis.history/2` now returns the id an entry was written with (the stream id
  for entries written without one), and `fork/3` accepts either. Code that relied on
  compaction minting new ids, or on store-assigned ids, must not.
- `Normandy.Behaviours.Compactor` meta may carry `:dropped` (the removed entries);
  `Compactor.WindowManager` fills it. A custom compactor fills it to trigger
  `after_compact` hooks. `AgentMemory.add_message/4` accepts `:id`.
- `Dispatch.Pipeline` gains `after_tool` (default `nil`). The function `after_hooks` are
  unchanged: they still see only results of tools that ran.

## 17. `max_tokens` defaults to 16_000

`BaseAgent.init/1`, the DSL and `ConfigTemplate.rebuild/3` now always send `max_tokens`
(the Messages API requires it): 16_000 unless you set it. In 1.x `init/1` left it unset and
the DSL defaulted to 4096.

- An explicit `max_tokens: nil` (for example `max_tokens: opts[:max_tokens]`) now raises
  `ArgumentError`. Leave the key out to get the default.
- `Compactor.WindowManager` now reserves the agent's `max_tokens` for the answer (it was a
  fixed 4096), so it keeps less history. Pass `:reserved_tokens` in the compactor opts to
  choose; a reserve as large as the context window raises.
- `OpenAICompatibleAdapter` sends `max_tokens` on every request too. For OpenAI reasoning
  models set `options: %{max_tokens_param: :max_completion_tokens}`; `:omit` sends neither
  key and leaves the limit to the server.

## 18. The default input schema rejects what it used to drop

With the default `BaseAgentInputSchema`, input must be `%{chat_message: string}`. An unknown
key (`%{chat_mesage: "hi"}`), a missing or `nil` `chat_message`, or a non-string one now
fails validation (`Normandy.Schema.ValidationError`) instead of sending an empty user turn.

This also reaches input you don't build by hand:
- `SequentialOrchestrator`, `ParallelOrchestrator`, `AgentProcess` and `Reactive` pass an
  agent's output to the next agent. An agent with a custom output struct feeding a
  default-schema agent now fails; add a transform that produces `%{chat_message: text}`.
- An `on_prompt` hook that rewrites the input to another map is validated the same way.
- A previous agent's reply whose `chat_message` is `nil` no longer becomes an empty turn.
- `run(agent, "text")` is `run(agent, %{chat_message: "text"})` for the default schema. With
  a custom input schema, input that isn't a map or the schema's struct (a string, a number)
  is now a `ValidationError`; in 1.x it was sent as is.
- A `%BaseAgentInputSchema{}` struct is validated too: `chat_message: nil` is rejected.
- A list of content blocks still passes through the default schema unvalidated.
- Input guardrails see a validated `%BaseAgentInputSchema{}` for string and map input alike.
  Built-in guards without a `:field` option check its `chat_message` text; custom guards
  receive the struct.

## 19. An output that breaks its schema is an error

When the model's answer doesn't satisfy the agent's `output_schema` (a required field
missing, a value outside its allowed set), `run/2` returns
`{:error, %Normandy.Schema.ValidationError{}}` and `Turn.Server.run/2` replies it. The
answer is not saved. In 1.x it was returned as if valid, and the whole value was printed to
stderr. An output already of the schema's struct is now validated too.

A tool-using agent with a custom output schema (one without `:chat_message`) is now told
that schema in its system prompt, and its final text is parsed into it. In 1.x the raw
`%Normandy.Agents.ToolCallResponse{}` came back instead. Text that is not JSON for the
schema returns `{:error, %Normandy.LLMError{type: :invalid_output}}` (under both
`on_parse_failure` policies: such a schema has no `:chat_message` to fall back to), from
`run/2` and from `Turn.Server.run/2`.

`run/2` after a tool loop and `stream/3` convert the final answer the same way. An empty
final answer is `{:error, %Normandy.LLMError{type: :invalid_output}}` for a non-chat schema
(1.x returned the empty schema struct as success) and `chat_message: ""` for a chat schema.
A schema with no JSON Schema and no `:chat_message` (a plain `defstruct`) has nothing to
parse the answer into, so it is `:invalid_output` too: define it with `io_schema`. A final
response that is already a struct of the output schema's own module (a client that fills
the response model itself) is returned as is, then validated.

An `output_schema` set to `nil` after `init/1` (or saved as `nil` in a hand-built config
template) is the default chat schema, as `init/1` makes it: `run/2`, `stream/3` and
`Turn.Server.run/2` return `%BaseAgentOutputSchema{}`. Before, `run/2` and `Turn.Server.run/2`
raised on a non-empty answer, and `stream/3` returned the raw streamed message map.

A tool-using agent whose custom output schema has a `:chat_message` field gets only that
field filled from the final text; its other fields stay unset, so any of them marked
`required: true` now fails validation (`{:error, %Normandy.Schema.ValidationError{}}`).
Make them optional, or drop `:chat_message` so the text is parsed as JSON into the schema.

The OpenAI-compatible adapter parses its text the same way: its `:invalid_output`
`LLMError.reason` is the parse failure itself, no longer `{:max_retries_reached, reason}`,
and the `[:normandy, :json_deserializer, :fallback]` metadata `reason` is the failure's tag
(it was `:max_retries_reached`).

## 20. Entry points: `run/3`, `run!/3`, `stream/3`

| 1.x | 2.0 |
|---|---|
| `run(agent, input)` → `{agent, response}` | `run(agent, input)` → `{:ok, agent, response}` / `{:error, e}`, or `run!(agent, input)` → `{agent, response}` |
| `run_with_tools(agent, input)` | `run(agent, input)`: it runs the tool loop when tools are registered |
| `stream_response(agent, input, fn event, data -> ... end)` | `stream(agent, input, fn %StreamEvent{type: event, data: data} -> ... end)` |
| `stream_with_tools(agent, input, callback)` | `stream(agent, input, callback)` |
| `run(agent, input, stream: true, on_chunk: f)` | `stream(agent, input, f)` (raises `ArgumentError` otherwise) |
| DSL `MyAgent.run_with_tools/2` | `MyAgent.run/2`; streaming is `MyAgent.stream/3` |

- `stream/3` returns the answer converted to the output schema, like `run/3` (1.x returned
  the raw message map with its content blocks).
- Callbacks take one argument, a `%Normandy.Components.StreamEvent{type, data}`; the old
  `StreamEvent` (an SSE event with `:delta`, `:content_block`, ...) is gone. `:tool_use_start`
  data is `%{id:, name:}`, not the raw string-keyed block.
- The streamed response no longer has `:guardrail_violations`; violations arrive as a
  `:guardrail_violation` event and `[:normandy, :agent, :guardrail, :violation]` telemetry.
- A client that can't stream gives `{:error, %LLMError{type: :unsupported}}`.
- `stream/3` parses the answer into a non-chat output schema once: `enable_json_retry`
  doesn't re-ask the model, as for `run/3`'s answer after a tool loop (a `run/3` without
  tools still re-asks).
- `StreamProcessor.process_with_callback/2` (arity-2 callbacks) is gone; `stream/3` is the
  one streaming path.

## 21. `BaseAgent.init/1` and DSL `new/1` check their options

`BaseAgent.init/1` takes a keyword list or a map, and checks every option before it starts
anything. In 1.x it took only a map and ignored any key it did not know.

- An unknown option raises `ArgumentError` naming it and listing the supported ones:
  `temprature:`, `system_prompt:` (use `prompt_specification:`), `tools:` (use
  `toolset:` or `register_tool/3`) and `max_messages:` (use
  `memory: AgentMemory.new_memory(n)`) used to be dropped silently.
- A missing `:model` raises
  `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"` (1.x:
  `KeyError`); a missing `:client` raises `ArgumentError` (1.x: `KeyError`).
- Values are checked: `:client` must be a struct whose module implements
  `Normandy.Agents.Model` (one that does not used to fail at the first LLM call),
  `:input_schema`/`:output_schema` a struct or `nil`, `:memory` an `AgentMemory` or `nil`,
  `:prompt_specification`, `:toolset` and `:behaviours` their structs or `nil`,
  `:tool_context` a plain map (not a struct), `:name`/`:session_id` strings or
  `nil`, `:json_retry_max_attempts` a positive integer, guard lists `module | {module, opts}`.
- `circuit_breaker:` (1.x `:circuit_breaker_options`, see §22) accepts `:failure_threshold`,
  `:success_threshold`, `:timeout` and `:half_open_max_calls` only. `:name` is gone: a
  registered breaker name made a second `init/1` with the same options crash.
- A bad option raises before anything else happens; `init/1` starts no process at all (the
  circuit breaker is shared and started on the first LLM call, §31).
- The value of a credential-carrying option (`:client`, `:mcp_servers`) never appears in the
  message.
- `run/3` and `run!/3` name themselves in their option error, and options that are not a
  keyword list raise `ArgumentError` instead of `FunctionClauseError`.
- A DSL agent's `new/1` returns the agent (`agent = MyAgent.new(client: c)`); it returned
  `{:ok, agent}` and never `{:error, _}`. It takes the same options as `BaseAgent.init/1`
  (top level or under `:override`, so `:session_id` too) plus `:memory_store` and
  `:max_messages`, checks them the same way, and its errors name `MyAgent.new/1`. `:client`
  goes at the top level only; under `:override` it raises, as in 1.x. A missing `:client`
  raises `ArgumentError` (1.x: `KeyError`); an agent that declares no model and is given none
  in `new/1` raises `ArgumentError` `"MyAgent.new/1: requires :model (a string), got none"`
  (1.x: `RuntimeError` `"model is required in agent definition"`).

## 22. Config groups, the compactor's window pin, and 1.0 session templates

`BaseAgent.init/1` (and DSL `new/1`) group the resilience and guardrail options. Passing a
1.x name raises `ArgumentError` naming its 2.0 home.

| 1.x option / `BaseAgentConfig` field | 2.0 |
|---|---|
| `retry_options: opts` | `retry: opts` |
| `enable_circuit_breaker: true, circuit_breaker_options: opts` | `circuit_breaker: opts` (`[]` for the defaults; `nil`, the default, uses none) |
| `config.circuit_breaker` (the pid) | `config.circuit_breaker` is now the options; the breaker is shared, see §31 |
| `input_guardrails: specs` | `guardrails: [input: specs]` |
| `output_guardrails: specs` | `guardrails: [output: specs]` |
| `output_guardrails_streaming_mode: m` | `guardrails: [streaming_mode: m]` |
| `output_guardrails_chunk_size: n` | `guardrails: [chunk_size: n]` |
| `output_guardrails_on_violation: v` | `guardrails: [on_violation: v]` |

- Keys left out of `guardrails:` keep their defaults; read one setting with
  `BaseAgentConfig.guardrail(config, :output)`. A `guardrails:` given to a DSL agent's `new/1`
  changes only the keys it gives.
- The DSL's `config/0` returns `guardrails: [...]` in place of the five `*_guardrails*` keys.
- `circuit_breaker:` accepts `:failure_threshold`, `:success_threshold`, `:timeout`,
  `:half_open_max_calls` and `:scope` (§31).
- Templates now store the `retry`, `circuit_breaker` and `guardrails` options; a supplement
  needs nothing for the breaker (§31).
- The window pin of a compactor is `:context_window`; 1.x called it `:max_tokens`, the name
  the agent also uses for the answer's limit. `Compactor.WindowManager` with `:max_tokens`
  raises `ArgumentError` at `init/1` (and when it runs). `BaseAgent` reads `:context_window`
  as the pin for any compactor, so a custom compactor that was pinned with `:max_tokens` must
  rename it too; a custom compactor's own `:max_tokens` option is left alone.
- `Compactor.WindowManager` raises `ArgumentError` naming the field for a pin that is not a
  positive integer, and for an agent config without a positive `max_tokens` when no
  `:reserved_tokens` is given (it gave a misleading reserve error or a `KeyError`).
- `Normandy.Behaviours.Config` no longer has `session_store` or `session_registry`. Nothing read
  them; `Turn.Server` takes `:store` and `:registry` (and `Normandy.Cluster`'s child specs pass
  them). Drop the two keys from any `%Config{}` you build.
- **Session templates saved by Normandy 1.0.0 rebuild under 2.0.** `ConfigTemplate.rebuild/3`
  gives `max_tokens: nil` the 2.0 default (16_000), drops the two session slots, and renames a
  `Compactor.WindowManager` window pin from `:max_tokens` to `:context_window` (a custom
  compactor's opts are left alone). Fields 2.0 added (`retry`, `circuit_breaker`, `guardrails`,
  `tool_context`, hooks, ...) get their defaults, as a 1.0 agent behaved.
- `rebuild/3` raises `ArgumentError` naming the field for anything else it cannot read: a field
  neither 1.0 nor 2.0 writes (templates saved by unreleased 2.0 builds, which have
  `retry_options` or `input_guardrails`, are not translated: recreate those sessions), a missing
  required field, an unknown `behaviours_refs` slot, or a `max_tokens` that is neither `nil` nor
  a positive integer (a stored `0` or `false` used to pass through).

## 23. JSON goes through `Normandy.JSON`; Jason is the default and Poison is gone

- Normandy no longer depends on Poison. `config :normandy, :adapter` is optional and
  defaults to `Jason`. Remove `adapter: Poison` from your config, or keep it and add
  `{:poison, "~> 6.0"}` to your own deps.
- An adapter is any module with `encode!(term, opts)` (opts is `[]` or `[pretty: true]`)
  and `decode(json)` returning `{:ok, term}` or `{:error, exception}`. Normandy calls
  nothing else. A `decode/1` that returns `{:error, reason}` with a reason that is not an
  exception raises `ArgumentError`.
- Structs: a struct with its own `Jason.Encoder` implementation is encoded by it; any
  other struct is encoded as its map without `:__struct__` and `:__meta__`, at any depth.
  Normandy no longer looks at `Poison.Encoder`: replace `@derive {Poison.Encoder, ...}`
  with `@derive {Jason.Encoder, ...}`. On an `io_schema`, a derived encoder that lists a
  `redact: true` field encodes it as `null`, and a bare `@derive Jason.Encoder` encodes
  `"__meta__": null`; derive with `only:` (or `except: [:__meta__]`).
- Tool results: an atom, a boolean or `nil` output reaches the model as JSON (`"ok"`,
  `true`, `null`), not as `inspect/1` text (`:ok`, `nil`). An output JSON cannot express
  (a tuple, a pid) is now an `is_error: true` result, "the tool ran, but its output
  cannot be sent as JSON: it contains a tuple", instead of its `inspect/1` text; that
  includes a keyword list (`{:ok, [count: 3]}` is a list of tuples): return a map. An
  error reason JSON cannot express (`{:error, {:http, 503}}`) is still sent as its
  `inspect/1` text; an exception as the reason (`{:error, %RuntimeError{}}`) is sent as its
  `Exception.message/1`.
- `get_json_adapter/0` (removed from `Normandy.LLM.JsonDeserializer`) is gone. The `:adapter` option
  of `parse_and_validate/3` and `deserialize_with_retry/5` defaults to `Normandy.JSON`.

## 24. The example tools are no longer in the package

`Normandy.Tools.Examples.Calculator`, `EnhancedCalculator`, `ListProcessor`,
`StringManipulator` and `Weather` are removed from the library. They were test
fixtures, and `Weather` made live HTTP calls. If you used one, copy it from the
1.x source into your application. The weather tool is in the repository at
`examples/tools/weather.ex` (as `MyApp.Tools.Weather`).

## 25. Tools: one `Normandy.Tool` behaviour

### The toolset

| 1.x | 2.0 |
|---|---|
| `Normandy.Tools.Registry` | `Normandy.Tools.Toolset` (same functions unless listed here) |
| `Registry.get(registry, name)` | `Toolset.fetch(toolset, name)` → `{:ok, tool}` / `:error` |
| `Registry.get!(registry, name)` (raised `RuntimeError`) | `Toolset.fetch!(toolset, name)` (raises `Normandy.ToolNotFoundError`, which names the registered tools) |
| `Registry.get_metadata(registry, name)` | `Toolset.fetch_metadata(toolset, name)` |
| `BaseAgentConfig.tool_registry`, `init(%{tool_registry: ...})`, DSL `new(override: [tool_registry: ...])` | `toolset` |
| `AgentTemplate` supplement key `:tool_registry` | `:toolset` |
| `BaseAgent.register_tool(agent, tool)` | unchanged; `register_tool(agent, tool, opts)` passes `opts` to `Toolset.register/3` |

- `Toolset.register/3` raises `ArgumentError` on an unknown or mistyped option (1.x ignored
  them).

### Writing a tool

`Normandy.Tools.BaseTool`, `Normandy.Tools.SchemaBaseTool` and `Normandy.Tools.ContextualTool`
are gone. A tool is a struct whose module implements `Normandy.Tool`: `name/1`,
`description/1`, `input_schema/1` and `run(tool, context)`. The struct holds configuration
only. The model's input is validated against the input schema and passed as
`context.input`; it is never merged into the struct (1.x copied any input key that matched
a struct field into the struct, including fields such as `:endpoint` or `:timeout`).

| 1.x | 2.0 |
|---|---|
| `use Normandy.Tools.SchemaBaseTool` + `tool_schema "n", "d" do fields end` | an input module (`use Normandy.Schema` + `io_schema "d" do fields end`) and `use Normandy.Tool, name: "n", description: "d", input: Input` |
| `def execute(%__MODULE__{a: a})` | `def run(_tool, %Normandy.Tools.Context{input: %Input{a: a}})` |
| `defimpl Normandy.Tools.BaseTool` with `tool_name/1`, `tool_description/1`, `input_schema/1`, `run/1` | `use Normandy.Tool` and the callbacks `name/1`, `description/1`, `input_schema/1`, `run/2` in the module |
| `run(%{field: value})` reading input from the struct | `run(tool, %Context{input: %{"field" => value}})`: with a hand-written schema the input is a string-keyed map |
| `defimpl Normandy.Tools.ContextualTool`, `run(tool, ctx)` | every tool gets the context: `run(tool, ctx)`; `ctx.values` is still `tool_context` |
| `prepare_input/2` on the tool | gone; validation is the dispatcher's |
| `Tool.validate/1`, `validate!/1` (generated) | `Normandy.Tools.Input.validate(tool, input)` |
| `BaseTool.tool_name(t)` / `tool_description(t)` / `input_schema(t)` / `run(t)` | `Normandy.Tool.name(t)` / `description(t)` / `input_schema(t)` / `run(t, context)` |
| a `:timeout` field on the tool struct | `register_tool(agent, tool, timeout: ms)` / `Toolset.register(t, tool, timeout: ms)`; a struct field is not read |

- Input is checked before the tool runs. An unknown key, a missing required key or a wrong
  type answers the call with an `is_error: true` tool result naming the keys
  (`"invalid input for lookup: unknown keys \"endpoint\", \"timeout\"; expected only \"query\"; the tool was not run"`);
  the turn goes on. With `input: Schema` every schema constraint applies and nothing is
  coerced; with a hand-written map, required keys and basic JSON types are checked, and
  unknown keys are rejected when the map declares `properties` (unless
  `additionalProperties` is `true`; an absent `additionalProperties` counts as `false`). A
  map with no `properties` key accepts any keys. 1.x validated `SchemaBaseTool` tools only
  and dropped unknown keys silently.
- `Normandy.A2A.AgentTool` and `Normandy.MCP.ToolWrapper` lose their `:input` field;
  `AgentTool` loses `:timeout` and `AgentTool.new/3` raises on it: pass `timeout:` when
  registering (default 30 s; `A2A.Registry.discover_and_register/3` registers with its
  `:timeout`, default 60 s as before). An MCP tool's server schema is checked the same way:
  one with no `properties` key accepts any input keys; one that lists `properties` rejects
  other keys unless the server sets `additionalProperties: true`.
- `Normandy.Tools.Memory`'s `:command` field and `prepare_input/2` are gone.
- `Normandy.Tools.Executor`: `execute_tool/2` and `execute_tool_classified/2` take
  `context:` (required, carrying the input) and `timeout:`; any other option raises.
  `execute/3`, `execute_parallel/3`, `execute_sequential/3` and `:max_retries` are removed:
  they ran tools whose input lived in the struct. Run a tool through an agent, or validate
  the raw input with `Normandy.Tools.Input.validate(tool, raw)` and pass what it returns:
  `{:ok, input} = Input.validate(tool, raw)`, then
  `Executor.execute_tool(tool, context: %Normandy.Tools.Context{tool_call_id: id, input: input})`.
  The executor does not validate: a tool declared with `input: Schema` expects that
  schema's struct, and a raw map fails in its `run/2`.
- Custom pipelines: `Dispatch.classify/3` verdicts carry a `%Dispatch.Invocation{tool, input, timeout}`
  where they carried the input-merged struct; `execute/4`, `policy_fn` and `execute_fn`
  receive it. `Dispatch.prepare_tool/2` and `validate_input/2` are gone;
  `Dispatch.execute_approved/3` runs an approved call. A `PolicyEngine` sees the registered
  tool as `ctx.tool` and the validated input as `ctx.input`.
- `Context.build/2` is `Context.build(config, call, input)`.

### Rolling upgrades and templates

- Config templates hold no tools: `ConfigTemplate.rebuild/3` takes the toolset from the
  `AgentTemplate` supplement registered on each node. Rename its `:tool_registry` key to
  `:toolset`; `rebuild/3` raises `ArgumentError` on the old key, on a `:toolset` that is not a
  `%Normandy.Tools.Toolset{}` or `nil`, and on a tool whose module does not implement
  `Normandy.Tool`. `Toolset.register/3` (and `BaseAgent.register_tool/3`) raise the same
  error for a 1.x tool. Each names what it found (the 1.x key, the type it got, or the
  tool's module); the old-key and 1.x-tool errors also point at this section.
- A session parked on an approval under 1.x resumes under 2.0: the parked call's input is
  validated again when it is approved, and a call whose tool is gone or whose input no
  longer validates is answered with an error result instead of crashing the server.
- DSL: `tool MyTool, timeout: 60_000` passes registration options. `tool MyTool` builds
  `%MyTool{}` with `struct!/1`: a tool with enforced keys raises at `new/1`; register it with
  `BaseAgent.register_tool/3` after `new/1` instead.

## 26. `Turn.Session` is a handle built once

`Turn.Session.run/2` and `Turn.Session.approve/2` take a `%Turn.Session{}` from
`Turn.Session.new/1` instead of the option list. `new/1` checks the options once: an
unknown or misspelled key, a missing `:session_id`, `:registry`, `:supervisor` or `:store`,
a value of the wrong type, or neither `:config` nor `:template_provider` raises
`ArgumentError` naming the key. `:session_id` must be a string.

```elixir
# 1.x
Turn.Session.run([session_id: sid, config: config, store: store, registry: reg, supervisor: sup], input)
:ok = Turn.Session.approve([session_id: sid, registry: reg], decisions)

# 2.0
session = Turn.Session.new(session_id: sid, config: config, store: store, registry: reg, supervisor: sup)
{:ok, output} = Turn.Session.run(session, input)
:ok = Turn.Session.approve(session, decisions)
```

- `approve/2` takes the same handle as `run/2` (1.x read only `:session_id` and `:registry`).
- With no live server, `approve/2` returns `{:error, %Normandy.TurnError{type:
  :session_unavailable, reason: :no_session}}` (was `{:error, :no_session}`); a registry that
  cannot answer gives the same `TurnError` with the registry's reason (was the bare reason).
  `AgentProcess.approve/2` returns what `Turn.Session.approve/2` returns.
- `Turn.Session.put_config/2` sets the config a later server start uses. A live server keeps
  the config it started with, as before.
- A `:resume_policy` other than `:lazy` or `:eager` raises in `new/1`, not in `run/2`.
- `AgentProcess` in `:server` mode builds its session in `start_link/1`: an invalid
  `:template_provider`, `:resume_policy`, `:approval_timeout_ms` ... stops the process at
  start instead of failing the first turn.
- `AgentProcess.update_agent/2` raises `ArgumentError` in the caller when its function
  returns anything but a `%BaseAgentConfig{}`; the process keeps its config (1.x stored the
  value, and the next run failed).

## 27. Orchestrators: `execute(agents, input, opts)` and one result shape

`ParallelOrchestrator.execute/3` (and `SequentialOrchestrator.execute/3`, see below) take the
agents, one input and options, and return:

- `{:ok, %{agent_id => output}}` when every agent succeeded; `output` is the agent's response
  after its spec's `:transform`;
- `{:error, %Normandy.OrchestrationError{results: %{agent_id => output}, errors: %{agent_id
  => exception}}}` when any agent failed.

| 1.x | 2.0 |
|---|---|
| `ParallelOrchestrator.execute(specs, opts)` | `ParallelOrchestrator.execute(specs, nil, opts)` (each spec keeps its `:input`); the 1.x call raises `ArgumentError` when every key of `opts` is an option name (wrap a real keyword-list input whose keys are all option names, e.g. `%{input: kw}`) |
| `ParallelOrchestrator.execute(agents, input)` → `{:ok, [{:ok, r} \| {:error, e}]}` | `{:ok, %{"agent_0" => r, ...}}` or `{:error, %OrchestrationError{}}` |
| `ParallelOrchestrator.execute_same_input(specs, input, opts)` | `ParallelOrchestrator.execute(specs, input, opts)` |
| `{:ok, %{success: true, results: results, errors: %{}, context: ctx, aggregated: a}}` | `{:ok, results}` |
| `{:ok, %{success: false, results: r, errors: e}}` | `{:error, %OrchestrationError{results: r, errors: e}}` |
| an agent's error `{:exception, e, stacktrace}` | `e` (logged with its stacktrace where it was raised) |
| an agent's error `{:exit, reason}` (an exit, or `:timeout`) | `%Normandy.TurnError{type: :task_down, reason: reason}` |
| `:shared_context`, `:aggregate`, `:ordered` | removed (rejected by name): aggregate `results` yourself |

- `agents` holds `%BaseAgentConfig{}` structs, keyed `"agent_0"`, `"agent_1"`, ..., or specs
  `%{id: string, agent: %BaseAgentConfig{}}` with optional `:transform` and, for
  `ParallelOrchestrator`, `:input`, which replaces `input` for that agent. Any other spec key,
  a repeated id, or anything else in `agents` raises `ArgumentError`. An unknown option raises
  `ArgumentError`.
- A spec's `:transform` must be a 1-arity function: `transform: nil` (accepted by 1.x, then a
  `BadFunctionError` for that agent) or another arity raises `ArgumentError` before any agent
  runs.
- A `:transform` or `:on_agent_complete` that raises, exits or throws is that agent's error in
  both orchestrators; `SequentialOrchestrator` used to let it raise in the caller.
- `Reactive.race/3` and `some/3` no longer leave in the caller's mailbox the results of
  agents that finished after the outcome was decided.
- A struct input (`%BaseAgentInputSchema{}`) reaches every agent; 1.x dropped it, and with bare
  agents raised a `KeyError` in a linked task.
- `ParallelOrchestrator.execute/3`'s `:timeout` also takes `:infinity`.
- `ParallelOrchestrator.execute_stream/2` yields `{:ok, {:error, {id, exception}}}` for a failed
  agent (was `{id, {:exception, e, stacktrace}}` or `{id, {:exit, reason}}`).
- `HierarchicalCoordinator` keeps its shapes; its aggregation prompt names a failed worker
  with the exception's message.
- `SequentialOrchestrator.execute/3` has the same shape. 1.x returned
  `{:ok, %{success: _, results: [...], errors: [...], context: ctx}}`, `{:error, %{...}}` on
  `on_error: :stop`, and `{:ok, last_result}` for bare agents; 2.0 returns `{:ok, %{id =>
  output}}` (the pipeline's output is the last agent's, `results["agent_<n-1>"]` for bare
  agents) or `{:error, %OrchestrationError{}}`, also after `on_error: :continue` with a
  failure. With `:stop` the agents after the failure are in neither map.
- `on_agent_complete` takes `fn id, output -> ... end` (1.x: `fn id, result, ctx -> ... end`).
  `:shared_context` and `:store_intermediate` are removed.
- `SequentialOrchestrator.execute_with_messages/3` rejects options (it ignored
  `:shared_context`) and checks its specs like `execute/3` (`:id` and `:agent` only; a bad
  one raised a `KeyError` or `FunctionClauseError`); an error message's `payload.error` is the exception's message (was
  `inspect/1` of `{:exception, e, stacktrace}`).
- `Reactive` keeps its shapes (`race/3` → `{:ok, output}`, `all/3` → `{:ok, %{id => {:ok,
  output} | {:error, e}}}`, `some/3` → `{:ok, %{id => output}}`, and `{:error, :all_failed |
  :timeout | :insufficient_successes}`). An agent that exits or runs past `:timeout` is
  `{:error, %Normandy.TurnError{type: :task_down}}` (was `{:error, {:exit, reason}}`). An
  agent that exits, throws or crashes a process it linked to, or an `:on_complete` that raises
  or throws, no longer takes down the caller of `race/3`, `all/3` or `some/3` (they run the
  agents in unlinked tasks): it is that agent's `:task_down` `TurnError` (or exception).
- `Reactive.race/3` and `some/3` accept `timeout: :infinity` (it raised `ArithmeticError`).
- `Reactive.all([], input)` returns `{:ok, %{}}` (it raised `Task.async_stream`'s
  `:max_concurrency` error).
- `Reactive.some/3` with `count:` above the number of agents raises `ArgumentError` (was
  `{:error, :count_exceeds_agent_count}`).

## 28. Lookups are `fetch_*`; two exceptions renamed

A lookup returns `{:ok, value}` or `:error`; its `!` variant returns the value or raises.

| 1.x | 2.0 |
|---|---|
| `BaseAgent.get_tool(agent, name)` → `{:ok, tool} \| :error` | `BaseAgent.fetch_tool(agent, name)` (same result); `fetch_tool!/2` returns the tool or raises `Normandy.ToolNotFoundError` |
| `BaseAgent.get_context_provider(agent, name)` → the provider, or raises `Normandy.NonExistentContextProvider` | `BaseAgent.fetch_context_provider(agent, name)` → `{:ok, provider} \| :error`; `fetch_context_provider!/2` returns it or raises `Normandy.ContextProviderNotFoundError` |
| `AgentMemory.get_entry(memory, id)` → the entry or `nil` | `AgentMemory.fetch_entry(memory, id)` → `{:ok, entry} \| :error`; `fetch_entry!/2` returns it or raises `KeyError` |
| `rescue Normandy.NonExistentTurn` (`AgentMemory.delete_turn/2`) | `rescue Normandy.TurnNotFoundError`; field `:turn_id` (was `:value`) |
| `rescue Normandy.NonExistentContextProvider` | `rescue Normandy.ContextProviderNotFoundError`; fields `:name` and `:registered` (was `:value`) |
| `SharedContext.get(ctx, key)` → `{:ok, v} \| {:error, :not_found}` | `SharedContext.fetch(ctx, key)` → `{:ok, v} \| :error`; `get/3` with a default is unchanged |
| `StatefulContext.get(pid, key)` → `{:ok, v} \| {:error, :not_found}` | `StatefulContext.fetch(pid, key)` → `{:ok, v} \| :error`; `get/3` is unchanged |
| `AgentSupervisor.find_agent(sup, id)` → `{:ok, pid} \| {:error, :not_found}` | `AgentSupervisor.fetch_agent(sup, id)` → `{:ok, pid} \| :error` |

The renamed exceptions build their own message and take no `:message` option.

## 29. `BaseIOSchema` drops `__str__/1` and `__rich__/1`

`Normandy.Components.BaseIOSchema` is `to_json/1` and `get_schema/1`; nothing in Normandy
called the other two. Delete `def __str__/1` and `def __rich__/1` from your own `defimpl
Normandy.Components.BaseIOSchema` blocks (left in, they are dead code, not an error), and
call `BaseIOSchema.to_json/1` where you called `__str__/1`: it leaves out `redact: true`
fields, as `__str__/1` did.

## 30. Every option is checked

Every public function that takes a keyword list of options validates it. A misspelled or
unsupported key, a missing required key or a value of the wrong type raises `ArgumentError`
in the caller, naming the function and the key:

    Normandy.Agents.Turn.Server.start_link/1: unknown option :approval_timout_ms; supported: :session_id, :store, ...

In 1.x most of these keys were ignored, so a typo silently kept the default. Each function's
`## Options` docs list its keys, types and defaults.

- `Turn.Supervisor.start_server/2` and `Turn.Supervisor.Horde.start_server/2` reject
  `:name`: the supervisor names the server through the registry's `child_name/2` (a caller's
  `:name` was replaced, or used as is with a registry without `child_name/2`).
- `Turn.Server.start_link/1`, `Turn.Supervisor.start_server/2` and
  `Turn.Supervisor.Horde.start_server/2` raise in the caller. A missing `:store`, `:registry`
  or `:session_id` used to crash `Turn.Server.init/1` with a `KeyError`, which came back as the
  supervisor's `{:error, {%KeyError{}, stacktrace}}`. `Turn.ResumeReaper.start_link/1`
  likewise raises for a missing `:store`, `:registry`, `:supervisor` or `:template_provider`.
- The messages for a bad `:on_approval_timeout` and a bad `Turn.new/1` `:max_iterations`
  changed: `...: invalid value for :on_approval_timeout option: expected one of
  [:continue, :fail], got: :sometimes`.
- `Turn.Server.start_link/1` takes the keys a session passes on with `Turn.Session.new/1`'s
  types: `:handlers` must be a `Turn.Driver.Handlers` struct or `nil` (a plain map is
  rejected), and `:template_provider` a `{module, handle}` tuple with a module (1.x took any
  pair, or `nil`). `:approval_timeout_ms` and `:idle_timeout_ms` take ms or `:infinity`.
  `Turn.ResumeReaper.start_link/1` forwards `:template_provider`, `:subscriber` and
  `:handlers` to every session it restarts, so it takes them with the same types.
- A server option `Turn.Server` rejects, reaching `Turn.Session.run/2` through a hand-edited
  `%Turn.Session{}`, raises `ArgumentError` in the caller (it returned a `:session_unavailable`
  `TurnError`).
- A saved template's invalid `:on_approval_timeout` is reported as
  `Normandy.Agents.Turn.Server: the saved template's :on_approval_timeout must be :continue
  or :fail, got: ...`.
- `AgentProcess.start_link/1` raises for a `:turn_engine` other than `:inline` or `:server`
  (it used to crash `init/1` with a `CaseClauseError`), and `AgentPool.start_link/1` for a
  missing `:agent_config` (a `KeyError` exit from `init/1`).
- `AgentSupervisor.start_link/1`'s `:strategy` accepts only `:one_for_one`, the only strategy
  `DynamicSupervisor` has (any other value crashed `init/1`).
- `Batch.Processor.process_batch_with_stats/3` and `BaseAgent.process_batch_with_stats/3`
  reject `:ordered`; it was overridden to `false`.
- `HierarchicalCoordinator.new/1`'s `:delegation_strategy` must be `:round_robin`,
  `:broadcast` or `:conditional`.
- `CircuitBreaker.start_link/1` raises for an unknown key (it ignored it).
- `AgentProcess.start_link/1` checks `:agent` (a `%BaseAgentConfig{}`) and, in `:server` mode,
  every session key with `Turn.Session.new/1`'s types, in the caller: `:handlers` a
  `Turn.Driver.Handlers` struct or `nil` (a plain map is rejected), `:store`/`:registry`/
  `:template_provider` a `{module, handle}` with a module, `:supervisor` a pid or a name. A value
  `Turn.Session.new/1` rejects used to stop the process in `init/1` (an exit in the caller).
- `HierarchicalCoordinator.new/1` takes `:workers` only as a list of `%{id: ..., agent: ...}`
  maps; bare agents (`workers: [agent1, agent2]`) raise.
- `Reactive.some/3` raises for `count: 0` (`:count` is a positive integer).
- `AgentPool.checkout/2`'s message for a bad `:timeout` is now `...: invalid value for :timeout
  option: expected non-negative integer or :infinity, got: -1`.
- A workflow's `execute/1` raises for a missing `:agents` or `:initial_input` (it raised
  `KeyError`) and for an unknown key.
- Value types that are now checked: `AgentProcess.start_link/1`'s and
  `AgentSupervisor.start_agent/2`'s `:agent_id` is a string (1.x took any term, such as
  `:researcher`); their `:context_pid` and `AgentProcess.cast/3`'s `:reply_to` are a pid or a
  registered name (`{name, node}` and `{:via, ...}` are rejected); `AgentPool.start_link/1`'s
  `:size` is a positive integer, and a bad `:agent_config` (anything `BaseAgent.init/1`
  rejects: an unknown or misspelled option, a bad value, a compactor that cannot size its
  window, bad client, policy or hook options) raises in the caller as
  `...AgentPool.start_link/1: invalid :agent_config: ...` instead of crashing the pool's
  `init/1`; `HierarchicalCoordinator.execute/3`'s
  `:manager_prompt` is a string; a workflow's `execute/1` `:context` is a plain map.
- `Context.Summarizer.compress_conversation/3` documented `:max_summary_tokens` but never read
  it; the summary size is `:max_tokens`, as in `summarize_messages/4`, and
  `:max_summary_tokens` now raises. `:summary_role` must be `"user"` or `"assistant"`.
- `A2A.Registry.from_agent_card/3` used to drop keys it did not use (including `:timeout`,
  which only `discover_and_register/3` reads, as the registration timeout); they now raise.
- `Context.WindowManager.new/1`: `:strategy` must be `:oldest_first`, `:sliding_window` or
  `:summarize`, and `:reserved_tokens` a non-negative integer. A
  `Compactor.WindowManager` compactor's opts (`:context_window`, `:reserved_tokens`,
  `:strategy`) are checked when the agent is built and when its template is rebuilt; the error
  starts with `Normandy.Agents.BaseAgent.init/1: ` or, during a rebuild,
  `Normandy.Agents.ConfigTemplate.rebuild/3: ` (as do the other compactor checks there).
- `AgentMessage.new/1` raises for a missing `:from` or `:to` with `ArgumentError` (was
  `KeyError`), for a `:from`, `:to` or `:type` that is not a string or an atom, or is `nil`
  (a `nil` `:type` was stored as `""`), and a `:metadata` that is not a plain map (each was
  stored as given).
- `AgentMemory.add_message/4`'s message for an unknown option now names the function.
- `Coordination.Pattern.ok!/2` and `error!/2` check their options on every call, including
  when the result matches.
- More value types that are now checked: `A2A.AgentTool.new/3`'s and the A2A registry's
  `:auth_token` and `:skill_id` are strings and `:transport_opts` a keyword list;
  `A2A.Registry.discover_and_register/3`'s `:timeout` a positive integer;
  `A2A.Server.build_agent_card/2`'s `:name`, `:description`, `:url`, `:version`,
  `:provider_url` and `:provider_org` are strings and `:expose_tools` a list of strings or
  `:all`; the MCP `:prefix` (`MCP.ToolWrapper.new/4`, `MCP.Registry`,
  `BaseAgent.register_mcp_tools/4`) a string; `Context.Summarizer`'s `:prompt` and `:model`
  are strings, `:max_tokens` a positive integer, and `:keep_recent` and `:summary_tokens`
  non-negative integers; `StatefulContext.start_link/1`'s `:notify_on_change` a boolean;
  `AgentMemory.add_message/4`'s `:turn_id` and `:id` strings or `nil`; a
  `Compactor.WindowManager` compactor's `:context_window` a positive integer (a `nil` or a
  string such as `"200000"` used to raise only mid-turn).
- `SessionStore.InMemory.new/1` and `start_link/1`, `MemoryStore.InMemory.new/1` and
  `MemoryStore.ETS.new/1` take no options; a key raises (it was ignored).
- `SessionRegistry.Redis.start_link/1` raises without `:conn` or `:url`, or with `conn: nil`
  (it crashed `init/1` with a `KeyError`); `:conn` is a pid or a registered name.
  `Cluster.child_specs/1` and `redis_child_specs/1` raise for a missing or misspelled key; a
  `:redix` list without `:name` raises `ArgumentError` naming it.
- The session and memory stores' Mnesia `create_tables/1`: `:copies` must be `:disc_copies` or
  `:ram_copies`.
- `Normandy.Options`' docs list every timeout option and its default in one table.
- More value types that are now checked: the registries' and stores' `:name`, the Mnesia
  table names (`:entries`, `:sessions`, `:table`) are atoms and `:nodes` a list of atoms;
  `:wait_timeout` is ms or `:infinity`; the Redis `:url`, `:namespace` and `:prefix` are
  strings, `SessionRegistry.Redis`'s `:ttl_ms` a positive integer and `SessionStore.Redis`'s
  `:wait` a `{replicas, timeout_ms}` tuple of non-negative integers;
  `AgentTemplate.Catalog.start_link/1`'s `:templates` a plain map; `Cluster`'s `:registry`
  and `:supervisor` are atoms, `:store` and `:template_provider` `{module, handle}` tuples (as
  `Turn.Session.new/1` takes them), and `:topologies` and `:redix` keyword lists.

## 31. Circuit breakers are shared and supervised by Normandy

| 1.x | 2.0 |
|---|---|
| `init/1` with a breaker started a `CircuitBreaker` linked to the caller; the config held its pid (`config.circuit_breaker`) | `init/1` starts no process. The first LLM call starts the breaker under Normandy's own supervisor. The config holds only the options |
| One breaker per `init/1` call | One breaker per client module, endpoint (`base_url` without credentials or query), model and breaker options, shared by every agent that matches |
| An `AgentTemplate` supplement could carry the breaker | Not read; the template carries the options and each node uses its own shared breaker |
| — | `BaseAgentConfig.circuit_breaker_key(config)` and `CircuitBreaker.fetch/1` find an agent's breaker; `CircuitBreaker.key/3`, `ensure_started/1` and `run/3` are the shared-breaker API |

- A breaker no longer dies with the process that built the agent (a request process, a
  LiveView, a `Task`), and `AgentPool` no longer starts (and leaks) one per agent.
- Agents that share a breaker share its state: one agent's endpoint failures (see the next bullet) open the circuit for all
  of them. Give each tenant `circuit_breaker: [scope: tenant_id]` when tenants use their own
  API keys and rate limits. The key, scope included, appears in telemetry and logs, so a scope
  must not be a secret. Tests that run agents with a breaker concurrently should give each
  test its own `:scope`.
- An agent's breaker counts only failures that say the endpoint is unhealthy: `LLMError`
  types `:rate_limit`, `:overloaded`, `:server`, `:transport` and `:stream`, or any error
  marked `retryable?: true`. A rejected request (`:invalid_request`, `:authentication`,
  `:permission`, `:not_found`), output that did not parse (`:invalid_output`) or a raise
  from your own code (a stream callback, a guardrail) no longer counts, so one caller's bad
  requests cannot open the circuit for every agent that shares it. 1.x counted every failure.
- `:normandy` now has an application callback that supervises the
  breakers. It starts with your application as any dependency does; a script started with
  `mix run --no-start` calls `Application.ensure_all_started(:normandy)` first.
- A half-open probe whose process is killed (a `Task.shutdown(:brutal_kill)`, an
  `on_timeout: :kill_task`) frees its slot and counts as a failed probe. The breaker used to
  stay open until `reset/1`.
- A result from a call admitted before a state change is ignored: a slow call started while
  closed no longer closes (or reopens) a half-open breaker.
- `CircuitBreaker.metrics/1` adds `:generation` and `:half_open_calls`.
- Breakers are per node: a session rebuilt on another node uses that node's breaker.
- A template saved by an earlier 2.0 build with a breaker (`node_local_fields` listing
  `:circuit_breaker_pid`) raises `ArgumentError` in `ConfigTemplate.rebuild/3`; recreate the
  session, as for the other unreleased 2.0 templates (§22).
- `CircuitBreaker.start_link/1` and `call/3` remain for a breaker you start and supervise
  yourself.
- A shared breaker that has been closed and idle for 15 minutes stops; the next call starts a fresh one. Open and half-open breakers stay.

## 32. Tool loops return the output schema; stop reasons are errors

- A tool-using agent whose `output_schema` is not the chat schema sends that schema as
  `output_config.format` on every tool-loop call, beside its tools, on `run/3`, `stream/3` and
  under `Turn.Server`, so the model's final answer is constrained to it. Structured outputs used
  to be skipped on any call that carried tools. A chat agent sends none: its answer stays
  plain text.
- `stream/3` with a non-chat output schema sends it too, with or without tools. A 400 that
  names the output format or schema re-sends the stream request without it, as `run/3` does.
- A custom `Normandy.Agents.Model` receives the schema as the new `Normandy.LLM.Request` field
  `output_format` (the output-schema struct). An implementation without constrained decoding
  can ignore it.
- A tool loop's final answer that does not decode is
  `{:error, %Normandy.LLMError{type: :invalid_output}}`; one that decodes but breaks the schema
  is `{:error, %Normandy.Schema.ValidationError{}}`. Neither is ever returned as a
  `%ToolCallResponse{}`.
- `[:normandy, :agent, :llm_call, :start]` metadata `structured_output` is now `true` for these
  calls and streams.
- A response that stopped at `max_tokens` or `model_context_window_exceeded` is
  `{:error, %Normandy.LLMError{type: :max_tokens}}` (the message names which), and a
  refusal is `{:error, %Normandy.LLMError{type: :refusal}}`, on `run/3`, `stream/3`,
  `Turn.Server` and `Turn.Session`. 1.x returned the cut-off text as the answer, ran a
  cut-off `tool_use` with its partial input, and on the structured-output path put the
  truncated JSON or the refusal text in `chat_message` (under `on_parse_failure: :fallback`)
  or JSON-retried it. Both types are `retryable?: false`: neither retried nor counted by
  the circuit breaker. `:reason` is `{:stop_reason, reason}`; `:usage` is what the call billed.
- A chat agent whose plain answer reaches `max_tokens` now gets the error, not the partial
  text. Raise `max_tokens` (default 16_000) for long answers.
- `stream/3`: text deltas delivered before the stop stay delivered; the turn returns the
  error, runs no tool from that response and stores nothing of it.
- `ClaudioAdapter` and `OpenAICompatibleAdapter` no longer parse, JSON-retry or apply
  `:on_parse_failure` to an incomplete answer: `Model.converse/3` returns
  `{:ok, %Response{content: <the empty response model>, stop_reason: ...}}`, and Normandy
  makes the error. A custom `Normandy.Agents.Model` only reports `Response.stop_reason`.
- `JsonDeserializer.deserialize_with_retry/5`: a retry call that fails (a `:max_tokens`
  cut-off included) is returned as its `LLMError`, with the usage that call billed. Given an
  `:on_retry_usage` callback, the usage goes to the callback instead and the returned error
  has `usage: nil`, so an adapter that sums retry usage does not count it twice.
- `Normandy.Context.Summarizer` returns `{:error, %LLMError{type: :max_tokens}}` for a
  summary cut off at its `max_tokens`, instead of the fragment.
- New `Normandy.LLMError` types `:max_tokens` and `:refusal`; telemetry `error.type` reports
  them as `max_tokens` and `refusal`.
- `max_tool_iterations` defaults to 20 (was 5) in `BaseAgent.init/1`, `BaseAgentConfig`,
  the DSL and `Turn.new/1`. Set it to 5 to keep the old budget.
- After the last tool round, the turn makes one more call that keeps the loop's system
  prompt, tools and response model and sends `tool_choice: none` (new
  `Normandy.LLM.Request.tool_choice`, `nil | :none`). 1.x switched the system prompt to the
  output schema for that call, which changed the prompt-cache prefix and dropped the loop's
  thinking. The answer is converted to the output schema like any final answer.
- Before that call the turn stores a `"user"` message, "You have used all available tool
  calls for this turn. Answer now with what you have, and say what you could not finish.",
  in memory and in the `Turn.Server` session store. Requests send it as a text block after
  the last tool results. Code that walks `AgentMemory.messages/1` sees it.
- Requests now send any plain-text `"user"` message that directly follows tool results (an
  `after_compact` injection too) as a text block in the tool-result message. Memory is
  unchanged.
- Custom `Turn.Inline` or `Turn.Driver` handlers: the final `{:call_llm, %{final: true}}`
  carries the loop's `response_model` (for example `%ToolCallResponse{}`), not the output
  schema, and the core then emits `{:convert_output, response, output_schema}`. A `call_llm`
  that answered the output schema on `final: true` answers the loop's response model now.
- A custom `Normandy.Agents.Model` may honour `request.tool_choice`; one that ignores it may
  return tool calls on the final call, and they are not run.
- A final call that stops at `pause_turn` is sent back as the final call (`tool_choice: none`,
  the paused turn last, no new user message), at most three times. `iterations_left` stays
  at 0 in the `:iteration` and `:steering` events while it is continued.
- A final call still paused after those three continuations is
  `{:error, %Normandy.LLMError{type: :pause_turn}}` (new type) on `run/3`, `stream/3`,
  `Turn.Server` and `Turn.Session`, never the paused text as the answer. It is
  `retryable?: false`, not counted by the circuit breaker, and its `:reason` is
  `{:stop_reason, :pause_turn}`. `Turn.Server` keeps the paused turns it stored.

## 33. Tool calls and assistant turns are replayed as received

- Parallel tool results go to the model as one user message, with one `tool_result` block per
  call in call order. They used to go as one user message per result. Memory
  (`AgentMemory.messages/1`), session stores and the turn still keep one `"tool"` entry per
  result. `AgentMemory.request_messages/1` does the conversion: a custom request builder that
  sends `AgentMemory.history/1` should pass it through that function.
  `Normandy.Context.TokenCounter` counts the same shape.
- `mcp_tool_use` (MCP connector) and `server_tool_use` blocks are no longer returned as tool
  calls. The API ran them and put their results in the same response, so Normandy does not
  dispatch them. Before, an `mcp_tool_use` was run as a local tool named
  `"<server_name>__<tool>"` (or answered "not found"), and a second, client `tool_result` for
  it was sent to the API. A local tool registered under such a name is no longer called for
  connector calls.
- `%Normandy.Agents.ToolCallResponse{}` has a new field `content_blocks`: the assistant turn as
  the API returned it, as string-keyed blocks (`Claudio.Messages.Response.to_assistant_content/1`;
  `ToolCallResponse.api_blocks/1` for a streamed message's blocks). The next request replays it
  unchanged: thinking, text, `tool_use`, `server_tool_use`, `mcp_tool_use` and their results, in
  their order. It used to be rebuilt as `thinking ++ [text] ++ tool_use`, which merged the text
  blocks, moved all thinking first, and dropped server and MCP blocks. A response stored before
  this field existed, or built by hand with `content_blocks: []`, is rebuilt as before. Claudio
  0.7 leaves `citations` out of replayed text blocks, and `server_name` out of a replayed
  `mcp_tool_result` (the API rejects it there).
- After a server-side fallback, the replayed turn keeps the `fallback` block (the API's
  continuation rules). Only the blocks after it used to be replayed.
- A streamed turn's `server_tool_use` and `mcp_tool_use` inputs and its text `citations` are now
  accumulated by `StreamProcessor.build_final_message/1`. They used to be dropped: inputs stayed
  `{}` and citations were lost.
- An earlier chat answer (`%BaseAgentOutputSchema{chat_message: text}` in memory) goes back to
  the model as `text`, not as `{"chat_message": ...}` JSON. The chat input already did this.
- After compaction (`Normandy.Context.WindowManager`, `Summarizer.compress_conversation/3`,
  `Normandy.Behaviours.Compactor.WindowManager`), kept messages keep their stored content
  (`%ToolCallResponse{}`, `%ToolResult{}`, ...) minus thinking. They used to be replaced by
  their serialized blocks, which hid a kept tool batch from `Turn.unanswered_tool_calls/1`.
- A `pause_turn` response (the API paused a long server-tool or MCP-connector turn) is appended
  and sent back as it is, with no user message after it, and the model continues the turn. Each
  continuation spends one of `max_tool_iterations`. The paused turn's partial text used to be
  returned as the final answer. A pause on the forced final call (`max_tool_iterations` spent)
  is continued too, at most three times, then fails with `:pause_turn` (§32).
- `%Normandy.Agents.ToolCallResponse{}` has a new field `stop_reason`
  (`t:Normandy.LLM.Response.stop_reason/0` or `nil`), filled by `ClaudioAdapter` and the stream
  path. It is never sent to the API. A custom `Model` that wants `pause_turn` continued sets it.
- An agent with `mcp_servers` and no tools of its own now runs the tool loop's response model
  (`%ToolCallResponse{}`), so its connector turns are replayed and continued like a tool-using
  agent's. With the chat schema, its system prompt no longer shows an output schema and its
  answer is plain text. It used to be `{"chat_message": ...}` JSON constrained by structured
  outputs.

## 34. Tool results and memory namespaces are capped

- A tool result longer than 100_000 characters (graphemes) is cut to 100_000 and ends with
  `"\n[truncated: <kept> of <total> chars shown]"` before it reaches memory and the model.
  Error results are capped too. A map or list output over the cap reaches the model as its
  JSON text, cut, so it is a string. Set `max_tool_result_chars:` on `BaseAgent.init/1` or
  the DSL's `new/1` (`nil` = no cap), or per tool with `Toolset.register/3`'s
  `max_result_chars:` (`nil` = no cap for that tool; it wins over the agent's). The cap is
  saved in session templates. `after_tool` and after-hooks still see the whole output; the
  `:tool_result` stream event, memory and the session store hold the cut one.
- A tool that returns a binary that is not valid UTF-8 gets an error result
  (`"the tool ran, but its output is not valid UTF-8 text"`); 1.x stored the bytes, and every
  later request of the session failed to encode.
- The memory tool's namespace caps are exact. `max_namespace_bytes` (default 1_000_000)
  is checked by the store in the same atomic step as the write, so concurrent writers can
  no longer exceed it together, and it counts every document (it used to sum only the first
  1,000 a listing returned). A new `max_namespace_documents` (default 1000, `nil` = no cap)
  caps the number of files; a `create` past it returns
  `Error: memory is full: creating <path> would make <n> files; the limit is <max>. Delete files first.`
  A write that does not grow the namespace is always allowed, so a namespace over a
  lowered cap can be shortened.
- `Normandy.Behaviours.MemoryStore` (new in 2.0): `put` takes a sixth argument, `limits`
  (`[max_bytes:, max_documents:]`), and returns `{:error, {:namespace_full, :bytes |
  :documents, would_be}}` when a write would exceed one; `MemoryStore.check_limits/3` is
  the rule. A custom store written against a 2.0 pre-release implements `put/6`. The
  Postgres migration adds the table `normandy_memory_namespaces` (each namespace's bytes
  and document count); a database migrated by a pre-release drops and re-runs the memory
  migration. Write memory documents only through the store: a row written by other SQL is
  not counted. Redis keeps a `:bytes` counter key beside each namespace's index.

## 35. Compaction

- The summarizer now reads tool rounds. Its transcript holds the assistant's text, a line
  `Assistant called <name>(<input as JSON>)` for each tool call (client, server and MCP
  tools), and a line `Tool result (<name>): <text>` for each result (`Tool error (<name>): ...`
  for an error result), cut to 4000 characters. Thinking is left out. Before, tool results
  and the text of tool-turn assistant messages were dropped (their blocks have atom keys,
  which the summarizer did not read), so a tool-heavy conversation was summarized without the
  facts its tools returned. A final answer stored as `{"chat_message": ...}` JSON reads as its
  text.
- The summary message reads `The earlier part of this conversation was summarized
  automatically to save space. The summary is context, not a new message.`, a blank line,
  then the summary between `<conversation_summary>` and `</conversation_summary>` lines. It
  was `Previous conversation summary: <summary>`, which the model could take for something
  the user had just said. Code or tests that match the old prefix must change.
- `Context.Summarizer`'s `:max_tokens` now defaults to the agent's `max_tokens` (16_000 when
  the agent has none), not 500. Thinking shares that budget and current models cannot turn it
  off, so 500 left little or nothing for the summary. An agent `max_tokens` that is not a
  positive integer raises `ArgumentError`; pass `:max_tokens` to choose another budget.
- `Compactor.WindowManager` takes `:summary_max_tokens` (a positive integer, or `nil`, the
  default, for the summarizer's default above): the `:summarize` strategy's summary budget.
  `Context.WindowManager.new/1` takes the same option and the struct has the field. Before,
  compaction always summarized with 500.
- The compactor `ctx` has `:mid_round`: `false` at the start of a turn, `true` at the
  boundary after a tool batch, while the model's tool round is still open. The Turn core's
  `{:maybe_compact, info}` effect carries the same key (a `Turn.Inline` `:compact` dep sees
  it), and `[:normandy, :agent, :compaction]` has `mid_round` in its metadata. A custom
  `Compactor` should leave memory unchanged at a mid-round boundary unless the conversation
  no longer fits the window, and strip the thinking of every message it keeps when it
  compacts there (see "Compacting mid-round" in `Normandy.Behaviours.Compactor`).
  `Compactor.WindowManager` already does both.
- A compaction after a tool batch still strips the open round's thinking, as it does for
  every kept message: thinking replayed after a summary or a cut no longer matches the
  history it was produced with, and models that check replayed thinking reject it. It happens
  only when the conversation no longer fits the window.
- `Turn.Server` stores each compaction, and a restored session starts from the compacted
  conversation; see section 39.

## 36. Model-facing text and schemas

- The system prompt's headings changed: `# IDENTITY and PURPOSE` is `# Role`,
  `# INTERNAL ASSISTANT STEPS` is `# How to work`, `# OUTPUT INSTRUCTIONS` is `# Output`, and
  `# EXTRA INFORMATION AND CONTEXT` is `# Context`. An empty `background` now gives
  `- You are a helpful assistant.` instead of "This is a conversation with a helpful and
  friendly AI assistant.". Update prompt snapshot tests; the first request after upgrading
  misses the prompt cache.
- The memory tool's description no longer says "IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY
  BEFORE DOING ANYTHING ELSE" or "ASSUME INTERRUPTION"; it asks the model to view `/memories`
  at the start of a task. Expect fewer `view` calls at the start of each turn.
- `BaseAgentInputSchema` and `BaseAgentOutputSchema` describe their field to the model:
  "The user's message." and "Your reply to the user, in plain text or Markdown." (were
  "an input chat message from user" and "a result chat message").
- JSON retry feedback for a failure other than invalid JSON or a validation error (an
  answer over `:max_input_bytes`, JSON that is not an object) now uses the parse-error
  template with the required schema, and no longer shows the Elixir reason term. A decode
  error reads `Invalid JSON: <decoder message>` instead of the inspected exception.
- `Normandy.A2A.AgentTool`'s description reads "Sends a message to the remote agent <name>
  and returns its reply. It describes itself as: <card or skill description>", with the
  card's text cut to 1_000 characters; the `message` input says the remote agent cannot see
  this conversation.
- Results the model gets instead of a tool's output (policy and budget denials, unknown
  tools, invalid input, approval rejections and expiries, interrupted calls, `before_tool`
  hook halts) now say what to do next, and carry no `null` keys. Each is still
  `%{error: message, ...}` with `is_error: true`; the keys are described in the
  `Normandy.Agents.Dispatch` moduledoc ("Results the model sees").
- `pending_approval` is gone from every result, and `Normandy.Agents.Dispatch.DenialEnvelope`
  is deleted. The synchronous path's `:needs_approval` result says approval is not available
  in this run.
- A policy deny whose reason is `nil` (a `PolicyEngine.Ruleset` default-action deny) sent
  `"error": null`; it now has a message.
- Input that fails the tool's schema, or is not a JSON object, is no longer marked
  `denied: true` (it is a mistake the model can fix); `validation_errors` stays.
- A budget refusal no longer shows the budget tracker's reason term (`inspect/1`); a binary
  reason is shown in parentheses.
- An unknown tool's result lists the available tool names (sorted, at most 20) instead of
  `"Tool 'x' not found in registry"`.
- A tool's `{:error, binary}`, a raised exception, the Executor's timeout and crash
  messages, the invalid-UTF-8 error (§34) and the error for an output JSON cannot express
  (§23, "the tool ran, but its output cannot be sent as JSON: ...") reach the model as that
  text with `is_error: true`, not as `{"error": "..."}`.
  `%ToolResult{}.output` is that binary. Code that matched `output: %{error: msg}` for these
  must match the binary. Other error terms keep `%{error: term}`.
- `Normandy.MCP.ToolWrapper` honours the MCP `isError` flag: such a result is an error
  result (`is_error: true`) whose text is the server's message. Any `CallToolResult` (a
  string-keyed map, an `ExMCP.Response` struct, a Hermes response) reaches the model as its
  text blocks joined by newlines, not as the JSON or `inspect/1` of the envelope. Image,
  audio and resource blocks become a one-line `[<type> content omitted]` note; they are not
  sent to the model yet.
- A turn whose final answer is empty or only whitespace (the model ended its turn with no
  text, usually right after tool results) now returns
  `{:error, %Normandy.LLMError{type: :invalid_output}}` for a `chat_message` output schema,
  on `run/3`, `stream/3` and `Turn.Server`, instead of `%BaseAgentOutputSchema{chat_message: ""}`.
  This holds for a chat agent with no tools too, and for a structured-output answer whose
  `chat_message` is blank. It is not retried. A test model client that answers with an empty response model must
  answer with text.

- Schema properties reach the model in declaration order, in tool `input_schema`, the
  `# OUTPUT SCHEMA` block, JSON retry feedback and the structured-outputs schema (which was
  alphabetical). Declaration order is generation order: declare `reasoning` before `answer`
  to have the model reason first.
- `__schema__(:specification)` (and `get_json_schema/0`) gains `:property_order`, the field
  names in declaration order, at the top and in every inlined nested schema. A test that
  compares a whole specification with `==` must add it.
- A field declared without `description:` no longer has `description: ""` in the
  specification (the model saw `"description": ""`); the key is absent.
  `Normandy.Schema.Introspection.get_field_metadata/2` returns `description: nil` for it.
- `Normandy.Tools.Toolset.to_tool_schemas/1` returns `input_schema` without `"$schema"` and
  `"title"`, and a Normandy schema's `properties` as a `Jason.OrderedObject` (use
  `properties[:name]`, not `Map.get/2`). The `# OUTPUT SCHEMA` block and retry feedback drop
  `"$schema"` and `"title"` too. A custom `config :normandy, :adapter` receives
  `Jason.OrderedObject` structs from these call sites.
- Because the system prompt's headings (above), tool `input_schema`s and the
  `# OUTPUT SCHEMA` block change shape (declaration order, no empty descriptions, no
  `"$schema"` or `"title"`), thinking stored before the upgrade no longer matches its
  prefix key: from the first request after upgrading, requests leave it out of the
  replayed history (`AgentMemory.drop_stale_thinking/2`; memory keeps it). Thinking
  produced after the upgrade is replayed as before, and responses stored without a prefix
  key are unaffected.
- With structured outputs, constraints the API cannot enforce (`pattern`, `min_length`,
  `max_length`, `minimum`, `maximum`, `exclusive_minimum`, `exclusive_maximum`, `min_items`,
  `max_items`, `unique_items`, an unsupported `format`) are stated at the end of the
  property's description (for example "Postal code. Must match the regular expression
  ^[0-9]{5}$."). The answer is still validated against them.

## 37. Security hardening

| 1.x | 2.0 |
|---|---|
| `MCP.ToolWrapper.new/4`, `MCP.Registry.discover_and_register/4`, `MCP.Registry.wrap_tools/4`, `BaseAgent.register_mcp_tools/4`: `:prefix` optional; without it the model saw the server's own names | `:prefix` required: a string of letters, digits, `-` and single `_` (no `__`, no `_` at either end, at most 61 bytes), or `false` to keep the server's names. Tools are named `prefix__name` |
| `A2A.AgentTool.new/3`, `A2A.Registry.from_agent_card/3`, `A2A.Registry.discover_and_register/3`: tools named `a2a__<card>[__<skill>]` | `:prefix` required, same rule. `prefix: "a2a"` gives the 1.x names; `false` gives `<card>[__<skill>]` |
| `%MCP.ToolWrapper{...}` built without `:prefix` | Does not compile (`@enforce_keys`); use `ToolWrapper.new/4` |

```elixir
{:ok, agent} = BaseAgent.register_mcp_tools(agent, Claudio.MCP.Adapters.ExMCP, client, prefix: "docs")
tool = Normandy.A2A.AgentTool.new(url, card, prefix: "a2a")
```

- **Check your policy rules before you upgrade.** `PolicyEngine.Ruleset` matches tool names,
  and rules are stored with each session's template. With a prefix, an MCP tool that was
  `delete_file` is `docs__delete_file`: a rule `"delete_*"` no longer matches it. Under
  `default_action: :allow` a `:deny` rule that stops matching **lets the call through**;
  under a stricter default an `:allow` rule that stops matching makes calls need approval or
  be denied. Rewrite such rules on the prefix (`"docs__*"`, `"docs__delete_*"`), or pass
  `prefix: false` for that server (and `prefix: "a2a"` for A2A tools) to keep the old names.
  A server chooses its own tool names, so a rule like `"read_*"` matches any server tool that
  calls itself `read_...`, whatever it does: match remote tools on their prefix only.
- Names are matched elsewhere too: `A2A.Server.build_agent_card/2`'s `:expose_tools`, your
  hooks and budget code that read `call.name`, and approvals parked under an old name (they
  are answered "not found" after the upgrade, so approve or reject parked calls before you
  deploy).
- A prefix plus `__` takes room from the 64-character tool name limit: a server whose tool
  name is longer than `62 - byte_size(prefix)` bytes fails registration with
  `{:error, {:invalid_tool_name, name}}`, as a dotted name already does.
- MCP and A2A tool descriptions, schemas and results come from outside your trust boundary
  and reach the model unchanged. See "Trust" in the `ToolWrapper` and `AgentTool` docs.
- A guard with `on_error: :open` or `:closed` now handles a guard that **exits or throws**
  (a `GenServer.call` or `Task.await` timeout inside it), not only one that raises. Before,
  the exit crashed the turn or `admit/2` whatever `:on_error` said. Under `:closed` the
  violation names the exit's tag (`"guard MyGuard exited: :timeout"`) or says
  `"guard MyGuard threw"`. `:reraise` (the default) is unchanged. A guard still has no
  timeout of its own: put one on the call inside it.
- `SemanticScope` under `:open`/`:closed`: a raise, exit or throw in your `:classifier` or
  `:fast_path`, a `KeyError` or `ArgumentError` included, now goes to that policy as a
  `Normandy.Guardrails.GuardError` (`"guard ...SemanticScope crashed: host code raised
  KeyError"`). It was re-raised as if it were the guard's own configuration error.
- The memory tool refuses a session whose `tool_context` namespace equals a mount's
  namespace (the call fails with `ArgumentError`; it used to read and write the mount's
  documents read-write), and `Memory.new/1` refuses two mounts of one namespace with
  different access. Two read-only mounts of one namespace are still allowed. Build session
  namespaces under a fixed prefix your mounts do not use.
- `A2A.Server.handle_message/2,3` refuse a message whose text parts hold more than
  100_000 bytes: `{:error, :too_large}`, the agent does not run. Pass
  `handle_message(config, message, carrier, max_text_bytes: n)` (or `nil` for no limit)
  to change it. `handle_message/4`'s `:tool_context` replaces the config's `tool_context`
  for one call: give each caller its own memory namespace. Authentication and the HTTP body
  limit stay with your Plug, and every caller that gets through can reach every tool in the
  config's toolset.
- `A2A.Server.handle_message` returns `{:error, :invalid_message}` for a text part whose
  `text` is neither a string nor `nil` (a decoded JSON list, say), before any model call;
  `error_type: :invalid_message` on the request span's stop. The text size limit counts
  the same normalised text the agent receives.
- **The session store is a trust boundary.** Write access to it decides the policy,
  guardrails, hooks, credential provider, `tool_context` and toolset of every session it
  holds (see "Trust boundary" in `Normandy.Agents.ConfigTemplate`). Keep it single-tenant.
- `Turn.Server` checks every template it loads (`ConfigTemplate.check_loaded!/1`, also run
  by `rebuild/3`): a function, pid, reference or port anywhere in it, a `behaviours_refs`
  module that does not declare its behaviour (`@behaviour Normandy.Behaviours.PolicyEngine`,
  `BudgetTracker`, `CredentialProvider`, `Compactor`, `ModelCatalog`), or a guard module that
  does not declare `@behaviour Normandy.Guardrails.Guard`, and the template is not used:
  the server waits `:unavailable` and `run/2` replies
  `%TurnError{type: :session_unavailable, reason: {:invalid_template, message}}`. **Add the
  `@behaviour` line to your own policy, budget, credential, compactor, catalog and guard
  modules** if they lack it. `from_config/2` now refuses references and ports too.
- A stored template that lacks `:template_id` or the `behaviours_refs` `:credential` slot,
  or whose `behaviours_refs` is not a map, is refused the same way (`{:invalid_template,
  message}`, the message naming the field or slot). It used to crash the server's start into
  a supervisor restart loop whose crash report showed the stored refs, credential provider
  opts included.
- New supplement key `:pinned`: `pinned: [policy: ref, guardrails: g, credential: ref]`
  (also `:budget`, `:compactor`, `:model_catalog`, `:hooks`). A stored template whose value
  differs is refused, before its credential provider runs. Templates are not signed.
- `Turn.Session.new/1` and `Turn.Server.start_link/1` refuse an empty `session_id` or one
  containing `{` or `}` (the Redis stores put the id inside a cluster hash tag). Key formats
  are unchanged. `AgentProcess.start_link/1` (and so `AgentSupervisor.start_agent/3`) applies
  the same rule to `agent_id` under `turn_engine: :server`, where it is the session id, and
  raises `ArgumentError` before any process starts; other engines accept any string.
- Tool error text sent to the model no longer quotes remote data or exception terms: an MCP
  or A2A transport error is named by its tag (`"MCP tool 'search' failed:
  :unexpected_response"`), and a tool that raises `KeyError` gives `"Tool execution failed:
  KeyError: key :x not found"` (no map), `MatchError`, `CaseClauseError`,
  `Protocol.UndefinedError` and the other exceptions whose message shows a term give their
  module only. A tool that calls `:erlang.error({:boom, data})` gives
  `"Tool execution failed: ErlangError: :boom"` (the tag only; it used to quote the term).
- Log lines name an error reason by its tag (the atom, a tagged tuple's tag or an exception's
  module), not its `inspect/1`: `Turn.Server`'s "could not start session" and "dropped an
  approval" warnings (a credential provider failure reads `credential provider
  MyCreds failed: :vault_denied`), `Turn.ResumeReaper`'s missed-reap warnings,
  `AgentProcess.get_agent` store faults and `AgentPool` start failures. A refused template's
  or hook list's message is still logged in full (it names fields and modules only). Log
  matchers that looked for a reason's inner terms must match its tag.
- `inspect/1` of a `ClaudioAdapter` or `OpenAICompatibleAdapter` shows
  `options[:req_options]` and `options[:headers]` as `"**redacted**"`, and its `base_url`
  (and `options[:base_url]`) as scheme, host, port and path only, like the shared breaker's
  key: `"https://user:pw@host/v1?key=k"` prints as `"https://host/v1"`, and a URL with no
  scheme or host as `"**redacted**"`.
- `SemanticScope`'s `ArgumentError` for a `:classifier` or `:fast_path` return of the wrong
  shape, and `Turn.Session.new/1`'s error for a session id with `{` or `}`, name the value's
  type (`got: a string (12 bytes)`, `got: a tuple`) instead of showing it.
- The memory tool's `view` never returns more than `max_view_chars` characters plus a note:
  a longer first line is cut, with `[truncated inside line L of N: ...]`. Text containing a
  NUL character is refused (`` Error: `file_text` must not contain NUL characters ``) on every
  backend; Postgres used to report it as "memory store unavailable".
- `Tools.Executor.execute_tool/2` and `execute_tool_classified/2` run a tool with no policy,
  approval, hooks, budget or input validation (now documented); the agent loop uses
  `Normandy.Agents.Dispatch`. An approved call runs whatever tool holds its name when the
  approval arrives: version a tool's name when its behaviour changes.

## 38. History, encoding and caching

- Memory encodes a message once, when it is stored: `AgentMemory.add_message/4`,
  `from_entries/1` and `load/1` call `BaseIOSchema.to_json/1` and keep the result on the entry,
  and every request, token estimate and compaction reads it. A conversation of N turns costs N
  encodings instead of N². Request bodies are unchanged.
- Content that cannot be encoded (a struct with no `BaseIOSchema` implementation, a tuple or a
  pid in an `:any` field) raises when it is stored, from `run/3` or `stream/3`, instead of at the
  next LLM call. Under `Turn.Server` the turn fails with
  `%Normandy.TurnError{type: :handler_crashed, handler: :append}` before the store holds the
  message, the turn's input included; it used to fail as `:task_down` from the LLM worker, after
  the store held it. A test double used as an output schema needs a `BaseIOSchema`
  implementation.
- `%Normandy.Components.AgentMemory.Entry{}` has two derived fields, `wire` (what the model is
  sent for the message) and `tokens` (its estimate). They are never persisted: a session store
  returns entries with both `nil`, `from_entries/1` fills them, and a config template stores
  `initial_memory` without them. A hand-built entry with `nil` fields still works (it is encoded
  each time it is read). Compare entries from a memory with entries from a store on `id`,
  `role`, `turn_id` and `content`, not as whole structs.
- `AgentMemory.load/1` raises `ArgumentError` naming the entry
  (`AgentMemory.load/1: entry "e1" has content that cannot be encoded for the model (KeyError)`)
  for a dump whose content cannot be sent, such as a 1.x dump whose tool calls were stored as
  plain maps. Such a dump used to load and fail at the next request.
- A memory holds each message's encoding beside its content: histories heavy in JSON tool
  results take up to about twice the memory they did.
- `Compactor.WindowManager`'s `tokens_removed` sums the dropped messages' cached estimates, the
  same estimate `tokens_before` and `tokens_after` sum, instead of estimating each message's
  `BaseIOSchema.to_json/1`. For the default chat schemas the model is sent the text, not
  `{"chat_message": ...}` JSON, so `tokens_removed` is a few tokens lower per such message and,
  when no summary is added, equals `tokens_before - tokens_after`. With `:task_budget`, the
  `remaining` sent after a compaction moves with it.
- Compaction keeps each kept message's encoding; only a message whose thinking it strips is
  encoded again.

- Prompt caching is on by default: `Normandy.LLM.ClaudioAdapter`'s `options[:enable_caching]`
  defaults to `true` (it was `false`). Requests carry the breakpoints listed in §8 (system
  prompt, last tool, the API's automatic one), and the system prompt goes out as one text block
  instead of a string. A cache write costs 1.25 times the input price and a cache read 0.1
  times: an agent that makes one call per conversation pays more; a tool loop, which re-sends
  its whole prefix on every iteration, pays less. Set `enable_caching: false` to opt out, and
  on a `base_url` gateway that rejects top-level `cache_control`.

- The JSON text Normandy writes for the model from a plain map (a tool's map or list output in
  its `tool_result`, a map given as message content) lists every map's keys sorted by their
  text, at any depth. On OTP 26+ a small atom-keyed map iterates its keys in atom-creation
  order, so the same tool result could be different text on two nodes or after a restart, and
  miss the prompt cache. Values and list order are unchanged. A struct without its own
  `Jason.Encoder` is written as its fields, sorted like a map; one with its own encoder is
  encoded by that encoder, unchanged. A `Jason.OrderedObject` keeps its
  order: return one from a tool whose key order means something to the model. A custom
  `config :normandy, :adapter` now receives `Jason.OrderedObject` structs in this text and must
  encode them in order, as Jason does.

## 39. Turn.Server start, store failures and compaction persistence

- A session store call that exits (a `GenServer` or `Agent` call timeout, a dead store
  process or connection) no longer crashes `Turn.Server`. During a turn the write fails like
  a store's `{:error, reason}`: `run/2` returns `{:error, %Normandy.TurnError{type:
  :persist_failed, reason: {:store_exit, exit_reason}}}` and the same server takes the next
  turn. The terminal-state save after a successful turn is best-effort, so its exit leaves the
  reply `{:ok, _}`. `exit_reason` carries no stacktrace, and a call's arguments are replaced by
  their count (`{:timeout, {GenServer, :call, 3}}`). A store that raises mid-turn is a bug and
  still crashes the server.
- Anything the session load raises, exits or throws (the store, the template or credential
  provider, `ConfigTemplate.rebuild/3`, a supplement's `client_builder`) leaves the server
  `:unavailable` and retrying, instead of crashing it into a supervisor restart. `run/2`
  replies `:session_unavailable` with the exception as `:reason` (an exit's or a throw's
  reason for those). A saved template whose `:on_approval_timeout` is not `:continue` or
  `:fail` is refused as `{:invalid_template, message}`.
- A session store's error reaches `run/2` reduced to its tags: atoms and integers are kept,
  tuples are walked, an exception becomes its module (`{Postgrex.Error, code}` for a Postgres
  error with a SQLSTATE), and any other term becomes a description of its type (`"a map"`,
  `"a string (23 bytes)"`). `{:error, :store_down}` is replied unchanged;
  `{:error, {:query_failed, %{...}}}` becomes `{:query_failed, "a map"}`. `Turn.Session.run/2`
  reduces a store's template read or save error the same way. Match on the tags.
- `Turn.Server` implements `format_status`: crash reports, `:sys.get_status/1` and the
  observer show the session id, turn status, task kind and resume policy, and the length of
  each event queue, never the config, the conversation or a queued user input.
- The Turn core fails a turn whose tool batch comes back without a result for every tool
  call, before the next LLM call. The results that arrived are appended, then the turn fails
  with `{:unexpected_event, status, {:incomplete_batch, tool_call_ids}}`: `Turn.Server` replies
  an `:unexpected_event` `TurnError`, `Turn.Driver` raises, `Turn.Inline` returns
  `{:error, reason, state}`. A custom `Turn.Driver.Handlers` `dispatch_tools` or a
  `Turn.Inline` `:dispatch` dep must return one result per call, carrying its
  `tool_call_id`.
- `Turn.Server` loads its session after `init/1` returns, in its first event:
  `Turn.Supervisor.start_server/2` and `Turn.Server.start_link/1` return before the store and
  the template and credential providers are read, so session starts no longer wait for each
  other in the supervisor. A `run/2` sent meanwhile waits for the load. Code that inspected
  the load's effects right after a start (a log line, the server's state) must first make a
  call to the server (`run/2`, or `:sys.get_state/1` in tests). A start with neither
  `:config` nor `:template_provider` still raises `ArgumentError` in the start.
- A second `Turn.Supervisor.start_server/2` (or `Turn.Server.start_link/1`) for a session that
  a self-registering registry (`SessionRegistry.Native`) already holds returns
  `{:error, {:already_started, pid}}` and stops before loading anything. It used to start a
  second server that ran unregistered next to the first and wrote to the same session.
  `Turn.Session`, `ResumeReaper` and `AgentProcess` already treat it as a successful start;
  code that calls `start_server/2` directly and matched only `{:ok, pid}` must handle it. A
  start that found the session taken by a server that died before it could be looked up
  returns `{:error, :registration_race}`, which `Turn.Session` and `ResumeReaper` retry.
- `Turn.Server` passivation (no call for `:idle_timeout_ms`) stops the server with reason
  `{:shutdown, :passivated}` instead of `:normal`. Supervisors and crash reports treat it as a
  normal exit (a `:transient` child is not restarted, nothing is logged); code that monitors a
  session's server and matched `:normal` must match `{:shutdown, :passivated}`. Unlike
  `:normal`, the exit reaches linked processes: a process that started a server with
  `Turn.Server.start_link/1` outside a supervisor and does not trap exits now exits with it at
  passivation. Start servers under `Turn.Supervisor` (as `Turn.Session` does) or trap exits.
- `Turn.Session.run/2` routes a turn again when the server it found passivated before running
  it (the call exits `{:shutdown, :passivated}` or `:noproc`), to a fresh server, up to three
  servers in all; then it returns `{:error, %Normandy.TurnError{type: :session_unavailable,
  reason: :passivated}}`. It used to exit the caller. `AgentProcess` in `:server` mode inherits
  this. Any other exit of the server (a crash mid-turn, `{:nodedown, _}`, a host's `:normal`
  stop) still propagates, since the turn may have run.
- Under `Turn.Server`, a tool's execution, budget, `after_tool` and function `after_hooks` run
  with a config whose `memory` holds no entries (`head`, `current_turn_id` and `max_messages`
  are kept), so a tool batch no longer copies the conversation into every tool task. Policy
  engines and `before_hooks` still see the whole conversation. An after-hook that read
  messages from `config.memory` under `Turn.Server` must get them another way.
  `BaseAgent.run/3`, `stream/3`, `Turn.Driver` and `Turn.Inline` are unchanged.
- `ResumeReaper.reap/1` checks and starts a sweep's sessions concurrently, 16 at a time, and
  still returns after the sweep. A session whose check or start raises, exits or throws is
  logged by the failure's type (`ResumeReaper: resuming "sid" crashed: ArgumentError`) and
  skipped; it used to stop the sweep and crash the reaper.
- `Turn.Server` stores each compaction. After a compaction that changed memory it appends a
  history entry with role `"compaction"` whose content is `%{version: 1, entries: [%{id:,
  turn_id:, role:, content:}]}`: the whole conversation the compaction left (the summary, the
  kept messages with their thinking stripped, `after_compact` injections). Every message stays
  stored as before. `AgentMemory.from_entries/1`, which `Turn.Server` and `AgentProcess` in
  `:server` mode use to rebuild memory, applies the last such entry: the memory is its
  conversation followed by the entries stored after it. A session restored after
  passivation, a restart or a handoff therefore continues from the compacted conversation: the
  prompt cache keeps hitting, a `:summarize` compactor does not pay for a new summary, and
  `after_compact` does not report the same messages twice.
- Code that reads `SessionStore.history/2` itself sees these entries; pass the list to
  `AgentMemory.from_entries/1`, or skip entries whose role is `"compaction"`. A `"compaction"`
  entry of another version raises `ArgumentError` in `from_entries/1` (`Turn.Server` then
  waits `:unavailable`). Forking a session at an entry before a compaction gives the
  uncompacted conversation up to that entry.
- If the store refuses the compaction entry, the turn goes on and the failure is logged
  (`Turn.Server could not store a compaction (session "sid"): <tag>; a restart rebuilds the
  uncompacted conversation`); a restart then rebuilds the full conversation, as in 1.x.

## 40. Session stores, registry and memory stores

`SessionStore` and `SessionRegistry.Redis` are released behaviours and modules: a store or host
code you wrote against 1.x must follow the changes below.

| 1.x | 2.0 |
|---|---|
| `SessionStore.Redis.fork/3` named the new session `"fork_<n>"`, an integer unique only on the node that forked | A UUID, as every other store returns |
| `@callback save_turn_state(handle, session_id, state)` | `@callback save_turn_state(handle, session_id, state, inflight?)`. `Turn.Server` passes `inflight?: true` while an `:eager` session's turn has not ended (status other than `:stopped`/`:failed`); the store writes it with the state |
| `list_resumable/1`: every session whose config template is `:eager`, whatever its turn state | The sessions whose last `save_turn_state/4` had `inflight?: true`. A template alone no longer lists a session |
| `SessionStore.Redis`: the eager set `"<namespace>:resumable"`, filled by `save_config_template/3` and never emptied | `"<namespace>:inflight"`, kept by `save_turn_state/4`. `"<namespace>:resumable"` is no longer read; delete it after the upgrade |
| `SessionStore.Postgres`: `Migration`, `MigrationAddTemplate`, `MigrationAddResumePolicy` | Also run `MigrationAddInflight` (column `inflight`, a partial index on it, an index on `head_id`) before 2.0 serves traffic |
| No store could delete a session | `@callback delete_session(handle, session_id) :: :ok \| {:error, term}`: removes the turn state, the template, the in-flight index membership and the history no other session reaches; `:ok` for a missing session. Every built-in store implements it; implement it in your own store |
| `SessionStore.InMemory.fork/3` and `SessionStore.ETS.fork/3` kept every entry of the parent in the fork | Only the history up to the fork point (what the fork's `history/2` returned anyway) |

- `SessionStore.Redis`: a pipelined write whose command fails inside Redis (a `WRONGTYPE`, an
  out-of-memory error) returns `{:error, %Redix.Error{}}`. 1.x returned `:ok` and dropped the error.
- `SessionStore.Redis.fork/3` copies the history in pipelines of 1,000 entries instead of one round
  trip per entry. If a pipeline fails, the partial copy is deleted and `fork/3` returns the error.
- `SessionStore.Postgres.fork/3` checks that the fork point is on the session's chain by ids; it no
  longer reads and decodes every entry's content.
- **Your own `SessionStore`.** Implement `save_turn_state/4` and write `inflight?` in the same write
  as the state. If your backend cannot, add the session to the index before writing the state and
  remove it after, so a crash leaves an extra member (the reaper re-checks the turn state), never
  a missing one. `list_resumable/1` returns the sessions saved with `inflight?: true`. Duck-typed
  test stores that define `save_turn_state/3` must take the fourth argument.
- **Drain eager sessions before upgrading.** No store backfills the new index: the turn state is an
  opaque term, and Postgres cannot read it in SQL. A session whose turn is in flight when you
  upgrade is not in the index until `Turn.Server` saves its turn state again, so a node lost in
  that window is not resumed by `ResumeReaper` (the session still recovers on its next caller,
  through the lazy path). Before upgrading, let eager turns finish and approve or reject parked
  calls. Together with §13 (2.0 and 1.x nodes must not host sessions from one Postgres or Redis
  store at the same time), upgrade all session-hosting nodes at once after the drain.
- `SessionStore.Mnesia`: a session row written by 1.x has no `:inflight` key and is not listed until
  its next turn-state save. ETS and InMemory stores do not outlive the node.
- Forks and deletes: on Postgres and Mnesia a fork shares the parent's entries up to the fork point,
  so `delete_session/2` keeps every entry another session's history still reaches; on InMemory, ETS
  and Redis a fork has its own copy. `SessionStore.Postgres.fork/3` now takes the source session's
  row `FOR SHARE`, so a fork and a delete of the same session do not interleave.
- `SessionStore.Mnesia.delete_session/2` scans both tables under a write lock on both
  (O(entries + sessions)); writes to the store wait for it.
- `SessionRegistry.Redis`'s handle is `%Normandy.Behaviours.SessionRegistry.Redis.Handle{owner:,
  conn:, namespace:}`, not the owner's registered name. `new/1` returns one. For an owner you
  start yourself, build it with `SessionRegistry.Redis.handle(owner: MyApp.SessionRegistry,
  conn: MyApp.SessionRedix, namespace: "normandy")` (the `:name`, `:conn` and `:namespace` you
  gave `start_link/1`), or call `SessionRegistry.Redis.fetch_handle(MyApp.SessionRegistry)` once
  for an owner started with `:url`. Such an owner now registers its Redix connection as
  `Module.concat(name, Redix)` (1.x left it unnamed) and the handle names it, so a fetched handle
  keeps working after the owner restarts; stopping the owner also stops that connection. The
  name is reserved: if another process holds it, the owner waits up to 5 s for it to exit,
  then fails to start with `{:error, {:connection_name_taken, name}}` (pass `:conn` or rename
  the owner); the other process is never stopped. Pass
  `{SessionRegistry.Redis, handle}` where you passed `{SessionRegistry.Redis,
  MyApp.SessionRegistry}`; the old form raises `ArgumentError` naming the struct. The `:via` name is `{handle, session_id}`. With the Redis combo,
  `Normandy.Cluster.redis_handles/1` (the options of `redis_child_specs/1`) returns the
  registry and the store to give `Turn.Session.new/1`.
- `SessionRegistry.Redis.whereis/2` runs in the caller on the handle's Redix connection
  instead of calling the owner, so a lookup no longer queues behind registrations and the TTL
  refresh. A connection that is not running returns `{:error, :noproc}`, one that dies during
  the call `{:error, {:exit, tag}}`; 1.x exited the caller when the owner was down.
- The registry's TTL refresh sends one pipeline of `EVALSHA` per 1,000 sessions instead of one
  `EVAL` per session. A key that lapsed is claimed again. A key another process now holds (two
  servers for one session, after a partition or a Redis failover) stops the local process with
  exit reason `{:shutdown, :registration_lost}`, logs a warning and emits
  `[:normandy, :session_registry, :ownership_lost]`. A `Turn.Server` stopped this way is not
  restarted, and a caller waiting in its `run/2` exits with that reason, as for any server
  that stops mid-turn (`Turn.Session.run/2` routes a turn again only after
  `{:shutdown, :passivated}` or `:noproc`, see `## 39.`); the session goes on where the key
  points.
- `SessionStore.Redis.new/1` with a `:wait` of one replica or more opens `:wait_connections`
  (default 4) more Redix connections and returns the four-element handle
  `{conn, namespace, wait, wait_conns}`. Each session's waited writes and their `WAIT` run on
  one of them (`:erlang.phash2(session_id, k)`), so a `WAIT` no longer stalls reads, other
  sessions or a registry sharing `conn`. Handles you build as `{conn, namespace}` or
  `{conn, namespace, wait}` still work and still wait on `conn`. `:wait_connections` without
  such a `:wait` raises `ArgumentError`.
- `Normandy.Cluster.redis_child_specs/1`: when `config :normandy, :redis_wait` asks for
  replicas (read when the specs are built), it also starts `:wait_connections` (new option,
  default 4) Redix connections named `:"<redix name>.wait.<i>"` (the `:redix` `:name` must then
  be an atom) and gives the store that pool. The new option `:store_redix` (Redix options with
  `:name`) gives the store a connection of its own for every command and every `WAIT` instead;
  it cannot be combined with `:wait_connections`. Build the handles for `Turn.Session.new/1`
  with `Cluster.redis_handles/1`, not by hand: the store's handle depends on these options and
  the app env. The guide's old advice to "pass a separate `:conn`" was not possible and is
  gone.
- `MemoryStore.ETS` and `MemoryStore.Mnesia` (new in 2.0) keep one row per document plus one
  totals row per namespace, so a `get` or `put` no longer copies the whole namespace. The
  Mnesia table is an `:ordered_set` with attributes `[:key, :value]`. A Mnesia memory table
  created by a 2.0 pre-release has the old layout: `MemoryStore.Mnesia.create_tables/1` now
  raises, naming both layouts; delete it (`:mnesia.delete_table/1`) and create it again. The
  same check applies to the session store's Mnesia tables, whose layout is unchanged.

## 41. Telemetry and logs

- `Turn.Server` keeps the caller's OpenTelemetry context current for the whole turn, from
  admission to `on_turn_end`. Hook spans the server runs outside the run (`on_prompt`, the
  `after_tool` of an interrupted batch's results, `on_turn_end`) are now children of the
  caller's span, in its trace; they used to be roots of new traces. They are siblings of
  the run span, not its children (`BaseAgent` keeps `on_prompt` inside its run).
- A `Turn.Server` turn that crashes before it begins (`:handler_crashed` with `handler:
  :admit`; `handler: :after_tool` while closing an interrupted batch; `handler: :append`
  for an input that cannot be encoded) or whose first messages cannot be written
  (`:persist_failed`) now emits a run `:start` and `:exception` carrying the replied
  error, as rejected input already did. Dashboards that count runs see these turns.
- `[:normandy, :agent, :llm_call, :stop]` no longer carries `usage: nil` when the provider
  reported no usage (non-streaming and summary calls); the key is absent, as it already was
  for streams. Read it with `Map.get(meta, :usage)`.
- The `normandy agent run stop` log line's `iterations` now counts the tool rounds the turn
  completed (the run `:stop`'s `iterations`), not the assistant messages of the last turn: a
  one-round tool turn logs `1`, not `2`.
- `BaseAgent.get_response/2` now emits an `[:normandy, :agent, :llm_call]` span (no
  `iteration`, no run around it).
- On a resumed durable turn, the run `:stop`'s `llm_calls` and token totals count only the
  calls made after the resume, while `iterations`, `stop_reason` and `finish_reason` describe
  the whole turn.
- The lifecycle log lines `normandy agent run start|stop`, `normandy llm call start|stop` and
  `normandy tool execute start|stop`, `Batch.Processor`'s progress lines and `Retry`'s
  "Retry succeeded on attempt N" are now `:debug` (they were `:info`). Set the `Logger` level
  to `:debug` to keep them, or use the telemetry events, which carry the same facts.
- An output guardrail with `on_violation: :warn` now logs `Logger.warning("Agent output
  guardrail violation: ...")` instead of printing with `IO.warn` to stderr. Tests that
  captured it with `capture_io(:stderr, ...)` use `capture_log/1`.
- A hook or guard that returns a value outside its contract still raises `ArgumentError`, but
  the message describes the value's shape instead of showing it: `got: {:inject, a string (10
  bytes)}` instead of `got: {:inject, "not a list"}`. Atoms are still shown (`got: :yes`).
- The memory tool's "memory store unavailable" text, and the `memory store failure` log line,
  show the store reason only when it is made of atoms and integers (`:timeout`,
  `{:exit, :noproc}`); an exception is its module (`Postgrex.Error (:unique_violation)` adds
  the SQLSTATE name), anything else its tag (`:http_error`, `a string (500 bytes)`). The log
  no longer holds the full reason (a `Postgrex.Error`'s SQL and row values), and the
  200-character cut is gone.
- A credential provider's failure reaches `run/2`'s `:session_unavailable` `TurnError` as
  `{:credential_unavailable, provider_module, reason}`, where `reason` is reduced as session
  store load reasons are (`## 39.`): atoms and integers kept, tuples walked, an exception
  its module, any other term its type (`{:http_error, %{"token" => ...}}` becomes
  `{:http_error, "a map"}`); the provider's data (a response body, a token) is dropped. Log
  the detail in the provider if you need it.
- A session store's own `{:error, reason}` from a write during a `Turn.Server` turn (the user
  message, a turn's append, a turn-state save) reaches the `:persist_failed` `TurnError` with
  `reason` reduced the same way (`{:sql, "SELECT ..."}` becomes `{:sql, "a string (N
  bytes)"}`; a `Postgrex.Error` becomes `{Postgrex.Error, sqlstate}`), in the reply, the
  persisted turn state, the log and telemetry. `{:store_exit, exit_reason}` keeps its shape.
- `A2A.Server.handle_message/3,4` reads only `traceparent` and `tracestate` from the carrier;
  an inbound `baggage` header is dropped, so a remote caller can no longer set baggage
  entries that your outbound calls would forward. Outbound A2A calls (`AgentTool`) still send
  your own baggage. If you relied on inbound baggage, extract it yourself from the request
  headers.

## New, non-breaking

- `[:normandy, :workflow, :run, :stop]` carries `status: :ok | :error` (`:error` when the
  orchestrator or workflow returned `{:error, _}`).
- `[:normandy, :tool, :result_truncated]` telemetry event (see the `Normandy.Telemetry` catalogue) when a tool result is cut to its cap.
- `CircuitBreaker.call/3` and `run/3` take `failure_if:`, a function that decides whether a failed call counts against the breaker.
- `[:normandy, :circuit_breaker, :state_change]` and `[:normandy, :retry, :attempt]` telemetry events (see the `Normandy.Telemetry` catalogue); breaker and Retry log lines carry structured metadata and name the breaker.
- `client.options` on `Normandy.LLM.ClaudioAdapter` accepts `:thinking`
  (`:adaptive | :disabled`), `:thinking_display`, `:effort`, `:speed`, `:inference_geo`,
  `:fallbacks` and `:task_budget`. Nothing is sent unless set. See the adapter's moduledoc.
- `:fallbacks` is rejected on streaming calls: partial output from a declining model would
  already have reached the stream callback.
- `BaseAgent.init/1` and `ConfigTemplate.rebuild/3` now raise on an invalid
  `ClaudioAdapter` `client.options` combination instead of failing on the first call (after
  any retries). `ClaudioAdapter.validate_options!/1` is the public check.
- With `:task_budget`, Normandy sends the total and, after in-turn compaction, a fixed
  `remaining` that subtracts the tokens compaction removed from the current turn.
- `:req_options` is merged into the Req client, as on `OpenAICompatibleAdapter`.
- `served_by` appears in `[:normandy, :agent, :llm_call, :stop]` telemetry and the
  `normandy llm call stop` log line after a server-side fallback (non-streaming calls;
  streaming rejects `:fallbacks`, so the serving model is always the requested one).
- Compaction keeps each message's turn id, so `AgentMemory.delete_turn/2` works after a
  compaction.
- `Normandy.Schema.Wire.encodable/1` turns a schema specification into what Normandy sends
  the model: properties in declaration order, no `"$schema"` or `"title"`.
- `SessionStore.ETS` keeps one row per entry: an append writes two rows instead of copying the
  session's whole history (B5), and a fork copies only the history up to the fork point. The
  handle and every return value are unchanged.
- `Turn.Session.delete/1` stops a session's live server and deletes it from the store
  (`SessionStore.delete_session/2`). `Turn.Supervisor.stop_server/2` and
  `Turn.Supervisor.Horde.stop_server/2` stop one server without a restart; a custom
  `:supervisor_mod` needs `stop_server/2` only for `delete/1`. A store that refuses the
  delete, or whose call exits, is `{:error, %TurnError{type: :persist_failed}}` (an exit as
  `reason: {:store_exit, tag}`); a store that raises raises.
- `[:normandy, :agent, :run, :stop]` carries the run's totals: `llm_calls`, `input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens` (each only when a
  call reported it), `iterations`, `stop_reason` and `finish_reason` (see "Run totals" in the
  `Normandy.Telemetry` catalogue). Compaction summary calls are not in the totals.
- New telemetry events (see the `Normandy.Telemetry` catalogue):
  `[:normandy, :turn, :unavailable]` (a `Turn.Server` whose session could not be loaded or
  started; `phase` and the reduced reason), `[:normandy, :resume_reaper, :sweep]` (one per
  `ResumeReaper.reap/1`: sessions scanned, started, skipped, failed) and
  `[:normandy, :agent_pool, :checkout]` (one per answered `AgentPool.checkout/2`: `wait`,
  `outcome`, `overflow`).
