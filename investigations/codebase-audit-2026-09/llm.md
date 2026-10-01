# Audit: `llm` area (lib/normandy/llm/**, context/**, components/**, telemetry/**)

Branch feat/claudio-0.7-migration @ 78ca1ab. Read-only audit; nothing was run. "verified" means I read
every code path named; "theory" says what would confirm it.

Secret-in-error-message rule (client value must never be inspected): checked every `inspect(` in scope.
No site inspects a client struct, `client.api_key`, or `client.options` as a whole. `ClaudioAdapter` and
`OpenAICompatibleAdapter` both `@derive {Inspect, except: [:api_key]}`. Residual near-misses are LLM-13.

---

### LLM-1. API and transport failures are turned into an empty "successful" response (Retry/CircuitBreaker never fire)
- Severity: HIGH
- Category: 1 (silent fallback), 4 (contract)
- Location: lib/normandy/llm/claudio_adapter.ex:920-925 (`handle_error`), :220-221, :281-283;
  lib/normandy/llm/openai_compatible_adapter.ex:113-119; consumer lib/normandy/context/summarizer.ex:196-217;
  lib/normandy/agents/base_agent.ex:314-326 (`{:ok, result}` wrap)
- Evidence:
  ```elixir
  defp handle_error(error, response_model) do
    IO.warn("Claudio API error: #{inspect(error)}")
    response_model
  end
  # openai:
  {:ok, %Req.Response{status: status, body: resp_body}} ->
    IO.warn("OpenAI-compatible API error #{status}: #{inspect(resp_body)}")
    {response_model, nil}
  ```
- Why it's a problem: a 401 (missing/wrong key), 429, 529, or a timeout makes `converse/7` return the
  caller's blank `response_model` as if the model had answered. Consequences, each read in the code:
  (a) `BaseAgent.call_llm_with_resilience` wraps whatever comes back in `{:ok, result}`, so `Resilience.Retry`
  and `CircuitBreaker` only ever see raises, never API errors; (b) the agent run "succeeds" with an empty
  `chat_message`; (c) `Summarizer.call_llm_for_summary` builds `%BaseAgentOutputSchema{chat_message: ""}`,
  gets it back unchanged, matches `%{chat_message: summary} when is_binary(summary)`, and returns `{:ok, ""}`;
  `compress_conversation` then replaces all old history with "Previous conversation summary: " (data loss).
  (d) the legacy path returns a bare struct while the structured path returns `{struct, nil}`: two shapes for
  the same failure. (e) `IO.warn` writes to stderr with a stacktrace instead of Logger/telemetry.
  (f) `__structured_error_action__` falls back to a second full request on any `:invalid_request_error`
  (also "prompt too long", bad model id), doubling cost before swallowing the same error.
- Fix: return `{:error, error}` from `converse/7` (and `{:error, ...}` through `ConverseResult.normalize`),
  have `call_llm_with_resilience` treat `{:error, _}` as a retryable failure, and make `Summarizer` match
  `{:error, _}`. Replace `IO.warn` with `Logger` + `[:normandy, :llm, :error]` telemetry. Restrict the
  structured to legacy fallback to errors that mention `output_format`/schema.
- Confidence: verified (adapter, Summarizer and BaseAgent wrapper read; API-error behaviour of Claudio
  confirmed in /Users/antonio/personal/Claudio/lib/claudio/messages.ex `{:error, APIError}`).

### LLM-2. Summarizer's default `summary_role: "system"` overwrites the agent's real system prompt
- Severity: HIGH
- Category: 4 (contract) / wrong output
- Location: lib/normandy/context/summarizer.ex:84-86 (default), :232-250 (`rebuild_memory_with_summary`);
  lib/normandy/context/window_manager.ex:306 (only caller, no `summary_role`);
  lib/normandy/llm/claudio_adapter.ex:572-580; Claudio `Request.set_system/2` (claudio/messages/request.ex:394)
- Evidence:
  ```elixir
  summary_role = Keyword.get(opts, :summary_role, "system")
  ...
  memory = AgentMemory.add_message(memory, summary_role, summary_content)
  # adapter: system messages REPLACE
  def add_single_message(request, %Message{role: "system", content: content}, enable_caching) when is_binary(content) do
    ... Claudio.Messages.Request.set_system(request, content)
  ```
- Why it's a problem: `BaseAgent` builds `[system_prompt_msg | history]`. A system-role summary in history is
  processed after the real prompt and `set_system` replaces it. The history entry content is the
  `BaseAgentOutputSchema` struct, which `AgentMemory.history/1` serializes with `to_json` to
  `{"chat_message":"Previous conversation summary: ..."}`. So after one `:summarize` compaction the model's
  system prompt (identity, steps, output instructions, context providers, OUTPUT SCHEMA) is replaced by a JSON
  blob of the summary. Silent, and only with `strategy: :summarize`.
- Fix: default `summary_role` to `"user"` (or store the summary as a user/assistant pair, which the API
  requires for alternation anyway) and make the adapter raise or merge when a "system" message is not first.
- Confidence: verified by reading (adapter, Claudio setter, BaseAgent message assembly at base_agent.ex:262-276).
  Not run.

### LLM-3. `SchemaBinder` renames `text`/`message`/`response` to `chat_message` for every schema
- Severity: HIGH
- Category: 1 (silent fallback) / wrong output
- Location: lib/normandy/llm/json/schema_binder.ex:107-120 (used by :20, :98); both legacy and structured paths
  (claudio_adapter.ex:1260-1262)
- Evidence:
  ```elixir
  "response" -> "chat_message"
  "message" -> "chat_message"
  "text" -> "chat_message"
  ```
- Why it's a problem: the alias is applied regardless of the target schema. A user `io_schema` with a
  `:text`, `:message` or `:response` field (very common names) gets the model's value moved to a key that is
  not in `permitted_fields`, so `Validate.cast` drops it and `validate_required` fails (or the field is silently
  nil). With structured outputs the model is constrained to emit exactly `{"text": ...}` and the result is still
  rejected, then routed through `on_parse_failure: :fallback`, which stores the raw JSON in `chat_message`.
  If a payload has both `"text"` and `"chat_message"`, `Map.put` order (map iteration) decides which wins.
- Fix: only alias when the schema has `chat_message` and lacks the source key; never overwrite an existing
  key; skip the whole step on the structured-output path (the schema is already enforced).
- Confidence: verified by reading; no test run. A test with `io_schema do field :text, :string, required: true end`
  would confirm.

### LLM-4. Mid-stream `error` events and `{:error, _}` stream items are dropped; a truncated message is returned as `{:ok, final_message}`
- Severity: HIGH
- Category: 1 (silent fallback)
- Location: lib/normandy/components/stream_processor.ex:90-95 (`process_event(_, acc)` catch-all) and :196;
  lib/normandy/llm/claudio_adapter.ex:392-393, 489-491; lib/normandy/agents/base_agent.ex:1196-1197, 1267
- Evidence:
  ```elixir
  defp process_event(%{type: "message_stop"}, acc), do: acc
  defp process_event(_, acc), do: acc
  ```
  The adapter emits `%{type: "error", error: ...}` and passes `{:error, _}` through; nothing in
  `build_final_message/1` or `BaseAgent` inspects them.
- Why it's a problem: Anthropic sends `event: error` (`overloaded_error`) in the middle of a stream; Claudio
  `parse_events` can also yield `{:error, _}`. `Enum.to_list(stream)` then `build_final_message` ignores both,
  so the caller gets partial text with `stop_reason: nil` as a successful response, and a half-streamed
  `tool_use` block (partial JSON string input) can be executed.
- Fix: `build_final_message` returns `{:error, reason}` (or sets `:error`) on an error event/tuple;
  `BaseAgent` propagates it; also treat a stream that ends without `message_stop`/`stop_reason` as an error.
- Confidence: verified (stream_processor, adapter, BaseAgent call sites read).

### LLM-5. `BaseIOSchema` `Any` fallback silently turns unsupported content into `""`; `history/1` feeds it to the model
- Severity: MEDIUM
- Category: 1 (silent fallback), 8 (docs vs reality)
- Location: lib/normandy/components/base_io_schema.ex:56-61, `@fallback_to_any ""` (:9);
  lib/normandy/components/agent_memory.ex:89-96; lib/normandy/components/message.ex:4-15 (doc);
  lib/normandy/context/window_manager.ex:206-219 (dead clauses), :330-345 (rebuild)
- Evidence:
  ```elixir
  def to_json(_), do: ""      # defimpl ... for: Any
  ...
  |> Enum.map(fn %Message{role: role, content: content} ->
       %{role: role, content: BaseIOSchema.to_json(content)}
  ```
- Why it's a problem: `Message` documents "a single `struct()`" content and the adapter has a clause for a
  single `%Image{}`/`%Text{}`/`%Document{}`, but `BaseAgent` always goes through `AgentMemory.history/1`,
  which maps every content through `to_json`. The ContentBlock structs have no `BaseIOSchema` impl (they use
  `use Normandy.Schema` without `io_schema`), so a single block becomes `""` and an empty message is sent
  (400 or silently dropped); integers, atoms, `nil` and tuples do the same. The adapter's single-block clause and
  `WindowManager.estimate_message_content_tokens(%Image{})` are unreachable through the agent path, and
  `WindowManager.rebuild_memory`/`Summarizer` re-add the `to_json`ed content, so compaction makes the loss
  permanent. `@fallback_to_any ""` also relies on truthiness (`true` is the documented value).
- Fix: drop the Any impl (let it raise `Protocol.UndefinedError`) or have `history/1` pass ContentBlock
  structs/lists through; `@fallback_to_any true`. Add a `ContentBlock` impl returning `[to_claudio(block)]`.
- Confidence: verified by reading; a test `add_message(mem, "user", %Image{...}) |> history` would confirm.

### LLM-6. `enable_json_retry` / `json_retry_max_attempts` are dead config; retries are hardcoded and their usage is dropped
- Severity: MEDIUM
- Category: 2 (option handling), 8 (docs vs reality)
- Location: lib/normandy/llm/claudio_adapter.ex:894 (`max_retries: 2`); lib/normandy/llm/json_deserializer.ex:24-29
  (moduledoc), :328 (`{response, _usage, _meta}`);
  lib/normandy/agents/base_agent.ex:125-126, base_agent_config.ex:62-63
- Evidence: `opts = if tools != [], do: [tools: tools, max_retries: 2], else: [max_retries: 2]`;
  `grep json_retry lib` finds only the struct field definitions, the init copy and the moduledoc/guardrails
  comment, no reader.
- Why it's a problem: setting `enable_json_retry: false` (the default) or `json_retry_max_attempts: 0` has no
  effect: every parse failure still triggers up to 2 extra paid LLM calls. Those retry calls' token usage is
  discarded (`_usage`), so `{response, usage}` under-reports spend and budget logic (`task_budget_remaining`)
  is wrong. The moduledoc example is therefore false.
- Fix: thread `config.enable_json_retry`/`json_retry_max_attempts` into `converse` opts
  (`max_retries: 0` when disabled), sum retry usage into the returned usage, or delete the fields and fix docs.
- Confidence: verified (grep over lib/ plus both code sites).

### LLM-7. Documented `:timeout`/`:base_url` client options are never read; unknown or bad option values are silently accepted
- Severity: MEDIUM
- Category: 2 (option handling), 8 (docs vs reality)
- Location: lib/normandy/llm/claudio_adapter.ex:40, 59 (docs), :1064-1079 (`to_claudio_client`), :1114-1125
  (`validate_options!`); lib/normandy/llm/structured_outputs.ex:16-27
- Evidence: moduledoc "`:timeout` - Request timeout in milliseconds (default: 30_000)", "`:base_url`" under
  `options`; `to_claudio_client` builds `config = %{token: client.api_key, version: "2023-06-01"}` and only
  `req_options` is merged. `grep ':timeout' lib/normandy/llm` finds only the doc line (OpenAICompatible reads
  `:timeout`, Claudio adapter does not).
- Why it's a problem: `options: %{timeout: 600_000}` for a long thinking call has no effect; Claudio's
  `timeout`/`recv_timeout` (claudio/client.ex) are unreachable except via `req_options`. A typo
  (`:thinkin`, `:enable_cacheing`) is ignored with no error although `validate_options!` exists to catch
  misconfiguration. `StructuredOutputs.enabled?` returns any non-nil override, and the caller then does
  `true <- enabled?`, so `structured_outputs: "false"`/`:off` silently disables it; `is_list(opts)` is accepted
  there but every other `Map.get(client.options, ...)` would crash on a keyword list. `api_key: nil` is also not
  validated (`required: true` is not enforced on struct literals) and surfaces only as a swallowed 401 (LLM-1).
- Fix: in `validate_options!` reject keys outside the documented set, require boolean `:enable_caching` /
  `:structured_outputs`, a binary `api_key`; pass `:timeout`/`:recv_timeout` to `Claudio.Client.new` or delete
  the doc lines.
- Confidence: verified (grep + code).

### LLM-8. JSON retry crashes when the system message content is a list (multimodal system prompt)
- Severity: MEDIUM
- Category: 4 (contract)
- Location: lib/normandy/llm/json/retry_feedback.ex:99-111
- Evidence: `%Message{role: "system", content: content} = message -> %Message{message | content: content <> "\n\n" <> feedback}`
- Why it's a problem: `ClaudioAdapter.add_single_message/3` explicitly supports list-form system content
  (ContentBlock list with cache annotations). On any parse failure, `augment_messages` does `list <> binary`
  and raises `ArgumentError` mid-turn, after an LLM call has already been paid for. Also the failed model
  output (first 500 chars, untrusted) is appended into the *system* prompt, which lets a prompt-injected
  response steer the retry.
- Fix: append a `TextBlock` when content is a list; put the feedback in a user message instead of the system
  prompt.
- Confidence: verified (code); crash is by construction of `<>`.

### LLM-9. `AgentMemory.dump/load` is lossy for multimodal content and instantiates arbitrary existing structs
- Severity: MEDIUM
- Category: 3 (security), 4 (contract)
- Location: lib/normandy/components/agent_memory.ex:162-213, 295-315
- Evidence:
  ```elixir
  defp encode_content(content) when is_struct(content), do: %{type: to_string(content.__struct__), data: content}
  defp encode_content(content), do: %{type: "raw", data: content}
  ...
  mod = String.to_existing_atom(type)
  struct(mod, atomize_struct_fields(data))
  ```
- Why it's a problem: (a) a list of `%Image{source: :base64}` blocks is stored as "raw", comes back as plain
  string-keyed maps without `"type"` (and with `"source" => "base64"` and nil fields); `block_to_claudio/1`
  passes plain maps through, so the next request is malformed (400). A single struct comes back with
  `source: "base64"` (string), and `Image.to_claudio/1` then raises "unsupported image source". Atoms in any
  struct field become strings; tuples make `Poison.encode!` raise. (b) A hostile dump can set `type` to any
  already-loaded atom, e.g. `"Elixir.Some.Struct"`; `struct/2` builds it with attacker-chosen fields (no atom
  leak, but no allow-list either). (c) `version` is written and never checked.
- Fix: serialize via an explicit per-type codec (`to_claudio`/`from_claudio` for ContentBlock), allow-list the
  struct modules accepted by `load`, validate `version`.
- Confidence: (a) theory from reading, confirm with `dump |> load |> messages` on an `%Image{}` list;
  (b)(c) verified.

### LLM-10. History trimming can orphan `tool_result` messages or empty the memory
- Severity: MEDIUM
- Category: 4 (contract), 7 (design)
- Location: lib/normandy/components/agent_memory.ex:243-266 (`enforce_max_messages`);
  lib/normandy/context/window_manager.ex:264-282 (`split_to_fit`), :241-243 (`:sliding_window` is an alias of
  `:oldest_first`)
- Evidence: `kept = Enum.take(chain, max)` / `{:cont, {[msg | keep], tokens + msg_tokens}}` with no check on role
  or tool_use/tool_result pairing.
- Why it's a problem: Anthropic rejects a conversation that starts with an assistant turn or that has a
  `tool_result` whose `tool_use` was trimmed away. `max_messages: N` or an oversized window can cut exactly
  there, so the agent wedges with a 400 on every later call (which LLM-1 then hides as an empty answer).
  If the newest message alone exceeds the target, `keep = []` and the entire memory is replaced by an empty one.
  `:sliding_window` is documented as a separate strategy ("keep most recent N") but just calls
  `truncate_oldest_first`. `enforce_max_messages` also walks the whole chain on every `add_message` (O(n)).
- Fix: after computing `kept`, drop leading non-user entries and leading tool_result entries; never return
  an empty keep set (keep the last user message, or return an error).
- Confidence: theory (API pairing rule is documented; confirm with a memory of
  user, assistant(tool_use), tool_result, assistant and `max_messages: 3`).

### LLM-11. `StreamProcessor.process_with_callback/2` rescues everything; callback results ignored; thinking and tool input not accumulated
- Severity: MEDIUM
- Category: 1 (silent fallback), 4 (contract)
- Location: lib/normandy/components/stream_processor.ex:73-77, 91-130, 178-185
- Evidence: `rescue error -> {:error, error}`; `process_event` has no `thinking_delta`/`signature_delta`
  clause; `append_json_delta` keeps `"input"` as a raw JSON string.
- Why it's a problem: a bug in the caller's callback (or a `FunctionClauseError` in the processor) is returned as
  `{:error, exception}` with the stacktrace discarded. The docs say callbacks "should return `:ok` or
  `{:error, reason}"` but the return is thrown away. The final message never decodes tool input (a
  `tool_use` block keeps `"input" => "{\"a\":1}"`, not a map) and drops thinking text and signatures, which
  must be echoed back with tool results on thinking models.
- Fix: remove the `rescue` (or reraise with `__STACKTRACE__`), honour `{:error, _}` from the callback, decode
  accumulated `partial_json` on `content_block_stop`, keep thinking/signature deltas.
- Confidence: verified for the rescue/callback/input string; theory for the thinking-signature consequence
  (needs a thinking + tool streaming run).

### LLM-12. Parse-failure path: unvalidated policy, unreachable per-call override, whole model output logged and sent as telemetry metadata
- Severity: LOW
- Category: 2 (option handling), 3 (security/PII), 8
- Location: lib/normandy/llm/claudio_adapter.ex:928-960, :1250-1255, :1266-1270
- Evidence:
  ```elixir
  Logger.warning("JSON parse failed; falling back to raw text. reason=#{inspect(reason)}")
  :telemetry.execute([:normandy, :json_deserializer, :fallback], %{count: 1}, %{reason: reason})
  ```
  `reason` is e.g. `{:structured_output_unparseable, content}` or `{:max_retries_reached, {:json_parse_error, _, content}}`.
- Why it's a problem: the full (up to 10 MB) model output, which may contain user PII, goes to the log and to
  every telemetry handler. `:on_parse_failure` is read from `context[:on_parse_failure]`, which nothing sets, so
  only the global env works; an invalid value (`:raise`) is a `CaseClauseError` after the paid call. Docs say
  `:fallback` "returns the raw LLM text as-is"; it returns the schema with `chat_message` set (or the unchanged
  schema for non-binary content). Default `:fallback` means a schema-invalid answer is presented as a chat
  message, which is itself a silent downgrade.
- Fix: log `elem(reason, 0)` plus byte size, truncate content in metadata, validate the policy in
  `validate_options!`, accept `client.options[:on_parse_failure]`, fix the moduledoc.
- Confidence: verified.

### LLM-13. Error messages embed full block structs (base64 payloads) and an arbitrary `req_options` value
- Severity: LOW
- Category: 3 (security)
- Location: lib/normandy/components/content_block/image.ex:111, document.ex:86, cache_control.ex:22/48;
  lib/normandy/llm/claudio_adapter.ex:734, :1093
- Evidence: `"... data and media_type must be non-empty strings. Got: #{inspect(block)}"`;
  `"... got: #{inspect(other)}"` for `options[:req_options]`.
- Why it's a problem: a missing `media_type` makes the exception message contain the entire base64 image
  (megabytes, user data) and it then flows into logs/crash reports. `req_options` may legitimately hold
  `headers: [{"x-api-key", ...}]`; if a caller passes it wrongly shaped (a map), `inspect(other)` prints the
  credential. This is the nearest violation of the "never inspect a client value" rule in scope.
- Fix: print `block.__struct__`, `block.source`, and `byte_size(data)`; for req_options print only
  `inspect(other, limit: 0)` or the type name.
- Confidence: verified.

### LLM-14. Duplicated request pipeline and silent catch-alls in `ClaudioAdapter`
- Severity: LOW
- Category: 7 (design), 1
- Location: lib/normandy/llm/claudio_adapter.ex:186-199, 235-248, 291-303, 357-373 (four copies of the
  builder), :205-213 vs :252-260 (context map twice); :653 (`add_single_message(request, _msg, _)` returns the
  request untouched); :125-129 (`completitions` returns `response_model`); json_deserializer.ex:458,
  agent_memory.ex:164/188, base_io_schema.ex:42 (adapter read via `Application.get_env` at runtime) vs
  schema.ex:338 (`compile_env`)
- Why it's a problem: a fix to option handling (e.g. `mcp_servers`, which `stream_converse` never adds, so
  MCP servers are silently ignored when streaming) must be made in four places and already drifted. A
  non-`Message` entry or `role: nil` is dropped silently, which the neighbouring clause explicitly calls
  unacceptable for typos. The JSON adapter is chosen at compile time for io_schema structs and at runtime for
  maps/memory, so changing `:adapter` at runtime yields mixed encoders. The "Retry" loop's second branch
  `{:error, reason} -> {:error, reason}` (json_deserializer.ex:293) is unreachable (attempt >= max is caught by
  clause 1).
- Fix: one private `build_request(client, model, temp, max_tokens, messages, opts)`; make the catch-all raise;
  read the JSON adapter in one function.
- Confidence: verified (duplication, catch-all); the MCP-in-stream drop is verified in the adapter, whether
  BaseAgent passes `mcp_servers` on the stream path is theory.

### LLM-15. `TokenCounter`/`ToolResult` hide wrong inputs behind defaults and catch-alls
- Severity: LOW
- Category: 1 (silent fallback), 4 (contract)
- Location: lib/normandy/context/token_counter.ex:44-46, 77, 93-96, 190; lib/normandy/components/tool_result.ex:19,
  37-47; lib/normandy/context/window_manager.ex:96-107 (specs)
- Evidence: `Map.get(agent, :model, "claude-haiku-4-5-20251001")`; `rescue e -> {:error, {:malformed_agent, e}}`
  around the whole count including the network call; `defp format_content(_), do: ""`;
  `field(:output, :map)` while `format_tool_output/1` handles binaries/numbers and uses `inspect/1` for lists.
- Why it's a problem: an agent without `:model` is counted against Haiku (tokenizers differ between model
  generations), a non-agent crash in `count_tokens` is reported as "malformed agent", unknown content counts as
  empty. `ToolResult` output that is a list (typical for search tools) is sent to the model as Elixir `inspect`
  syntax, and `Poison.encode!` is hardcoded instead of the configured adapter. `estimate_conversation_tokens`/
  `estimate_tokens` are specced `pos_integer()` but return 0.
- Fix: require `:model` (raise like `Summarizer.get_model`), narrow the `rescue` to the payload build, encode
  lists/maps via the adapter, correct specs to `non_neg_integer()`.
- Confidence: verified.

---

## Known (from prior audit)
- Known: A8 (RetryFeedback encodes `__specification__()`, which breaks on composite types) — still present? yes,
  lib/normandy/llm/json/retry_feedback.ex:17 and :58 (the `rescue` half lives in agents/base_agent.ex, out of scope).
- Known: noted in prior audit under "Atom-table leak"/"Caveat": Claudio decodes SSE with `keys: :atoms`;
  claudio_adapter.ex:445-451 comment still describes it, bounded wire schema, dependency-level. Not re-flagged.

## Area summary
- The Claudio 0.7 request-building side (option validation, cache breakpoints, content blocks) is careful, but
  the failure side is not: API errors become empty successful responses (LLM-1), which cascades into the
  summarizer, retry and circuit breaker.
- Wrong-output bugs hide in "helpful" normalization: the `text`/`message`/`response` alias (LLM-3), the `Any`
  to `""` protocol fallback (LLM-5), and a system-role summary that replaces the system prompt (LLM-2).
- Several documented options (`:timeout`, `enable_json_retry`, `json_retry_max_attempts`, `:sliding_window`) do
  nothing; no `inspect` of a client or API key was found anywhere in scope.
