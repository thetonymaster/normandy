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
  telemetry event reports every compactor run (token counts, strategy, whether it compacted).
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
