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
