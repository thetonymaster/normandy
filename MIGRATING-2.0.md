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
  every run. With a client that isn't a `ClaudioAdapter` and no pinned `:max_tokens`, that
  lookup fails and `run/2` returns `{:error, %Normandy.ModelCatalogError{}}` (`run!/2` raises
  it) before the first LLM call, where
  1.x silently never compacted. Pin `:max_tokens` (see below).
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
    compactor: {Normandy.Behaviours.Compactor.WindowManager, [max_tokens: 200_000]}
  }
  ```

  Pinning `:max_tokens` also skips the lookup entirely (offline use).

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
  `retry_options` multiplies attempts, because Claudio retries HTTP failures before Normandy sees
  them.
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
  `tool_registry:` or `register_tool/2`) and `max_messages:` (use
  `memory: AgentMemory.new_memory(n)`) used to be dropped silently.
- A missing `:model` raises `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"` (1.x:
  `KeyError`); a missing `:client` raises `ArgumentError` (1.x: `KeyError`).
- Values are checked: `:client` must be a struct, `:input_schema`/`:output_schema` a struct or
  `nil`, `:memory` an `AgentMemory` or `nil`, `:prompt_specification`, `:tool_registry` and
  `:behaviours` their structs or `nil`, `:tool_context` a map, `:name`/`:session_id` strings or
  `nil`, `:json_retry_max_attempts` a positive integer, guard lists `module | {module, opts}`.
- `:circuit_breaker_options` accepts `:failure_threshold`, `:success_threshold`, `:timeout` and
  `:half_open_max_calls` only. `:name` is gone: a registered breaker name made a second
  `init/1` with the same options crash.
- A bad option raises before the circuit breaker starts, so it no longer leaves a linked
  breaker process behind.
- The value of a credential-carrying option (`:client`, `:mcp_servers`) never appears in the
  message.
- `run/3` and `run!/3` name themselves in their option error, and options that are not a
  keyword list raise `ArgumentError` instead of `FunctionClauseError`.
- A DSL agent's `new/1` returns the agent (`agent = MyAgent.new(client: c)`); it returned
  `{:ok, agent}` and never `{:error, _}`. It takes the same options as `BaseAgent.init/1`
  (top level or under `:override`) plus `:memory_store` and `:max_messages`, checks them the
  same way, and its errors name `MyAgent.new/1`. A missing `:client` raises `ArgumentError`
  (1.x: `KeyError`); an agent that declares no model and is given none in `new/1` raises `ArgumentError`
  `"MyAgent.new/1: requires :model (a string), got none"` (1.x: `RuntimeError`
  `"model is required in agent definition"`).

## New, non-breaking

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
