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

## 4. `Model.converse/7` may return `{response, usage, meta}`

`ClaudioAdapter` now returns a 3-tuple (`meta` carries `:served_by` after a server-side
fallback), and `Normandy.Agents.ConverseResult.normalize/1` always returns one.

- Implementations returning a bare response or `{response, usage}` keep working.
- Code that calls `ClaudioAdapter` directly, or wraps it (a decorator, logger or test double)
  and matches `{response, usage} = ...`, must accept the 3-tuple.
- A 3-tuple whose third element isn't a map raises `ArgumentError`.

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
  lookup fails and `run/2` raises `Normandy.ModelCatalogError` before the first LLM call, where
  1.x silently never compacted. Pin `:max_tokens` (see below).
- **Compaction makes a network call:** one Models API request per model per agent config.
  Coordinators that discard the config `BaseAgent.run/2` returns (batch, orchestrators, agent
  processes) repeat it on every run.
- **A failed lookup fails the turn** with `Normandy.ModelCatalogError`. Under `Turn.Server` it
  arrives as `{:error, {:task_down, {%Normandy.ModelCatalogError{}, stack}}}`.
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

## 11. LLM failures raise `Normandy.LLMError`

- `Model.converse/7` may now return `{:error, %Normandy.LLMError{}}`. Code that calls
  `converse/7` directly must handle it; `ConverseResult.normalize/1` now returns
  `{:ok, {response, usage, meta}}` or `{:error, %Normandy.LLMError{}}`.
- `BaseAgent.run/2` and the DSL's `run/1-3` raise `Normandy.LLMError` when a returned
  failure (`{:error, _}` from `converse/7`) is final, and when the circuit is open
  (`type: :circuit_open`). Rescue `Normandy.LLMError` for these.
- An exception raised by `converse/7` is re-raised with its original type. With a circuit
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
  response. They now return `{:error, %Normandy.LLMError{}}` from the adapter and raise from
  `run/2`. `on_parse_failure: :error` returns `type: :invalid_output`.
- `stream_response/3` and `stream_with_tools/3` raise `Normandy.LLMError` when the stream
  fails. They used to return `{config, %{error: reason}}`. A stream that ends without
  `message_stop` is now a failure, not a complete message.

## 12. `Turn.Server` failure replies and approval expiry

`Turn.Server.run/2` (and `Turn.Session.run/2`, `AgentProcess.run/2` with
`turn_engine: :server`) now replies where it used to crash the session:

| Reply | Before |
|---|---|
| `{:error, {:rejected, exception}}` — input failed its schema or an input guardrail | the server crashed; the caller got an exit |
| `{:error, {:handler_crashed, name, exception_or_term}}` — a handler raised, exited or threw | the server crashed |
| `{:error, {:approval_timeout, ids}}` — only with `on_approval_timeout: :fail` | n/a |

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
- New replies from `Turn.Server.run/2`: `{:error, {:rejected, %Normandy.HookHaltError{}}}`
  (an `on_prompt` hook halted the input), `{:error, {:hook_halted,
  %Normandy.HookHaltError{}}}` (a `before_llm` hook halted the turn),
  `{:error, {:handler_crashed, :admit | :after_tool | :before_llm | :after_compact |
  :on_session_start, e}}` and `{:error, {:invalid_hooks, message}}` (a hook module missing
  on this node). `BaseAgent` raises `Normandy.HookHaltError` for both halts.
  (`:on_session_start` is no `run/2` reply: it leaves the server `:unavailable`.) A
  `before_tool` or `after_tool` hook crashing under `on_error: :reraise` inside the tool
  dispatch replies `{:error, {:task_down, {e, stacktrace}}}`; the server stays alive and
  the turn fails.
- **Behaviour change:** in `Turn.Server`, an admission that raises something other than a
  rejection (an input guardrail crashing, for example) now replies `{:error,
  {:handler_crashed, :admit, e}}` instead of crashing the session.
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
