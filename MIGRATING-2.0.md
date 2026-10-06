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
- A `:summarize` compaction stores its summary as a plain string
  (`"Previous conversation summary: ..."`), not a `BaseAgentOutputSchema`.
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
`%{error: "approval timed out: no approver responded within <ms>ms", denied: true,
expired: true, pending_approval: false}` instead of `"tool call rejected by approver"`, and an
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

## New, non-breaking

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
