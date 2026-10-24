# Normandy 2.0 audit — agent ergonomics (AX)

Scope: what the model sees, and whether the framework sets the model up to succeed. This was a read-only audit: I used grep and read code, and ran no mix commands. Branch `feat/claudio-0.7-migration` at f7991a9. API facts come from the claude-api skill (cached 2026-09-25), including the preserved-thinking rules in `shared/model-migration.md`.

Legend: **VERIFIED** means I traced it in the code (file:line given). **PLAUSIBLE** means the code path is confirmed, but the API-side outcome comes from documented behaviour and was not reproduced live.

---

## 0. Status of the 2026-09-25 prompt audit

The memory file calls that audit "UNAPPLIED". **That is stale.** Nearly every finding is now fixed in code:

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | `temperature` default 0.9; summarizer used 0.3 | FIXED | `base_agent_config.ex:58` `default: nil`; `summarizer.ex:73` `temperature = nil` |
| 2 | thinking only through `budget_tokens`; no effort setting | FIXED | `claudio_adapter.ex:49-63` `:thinking`, `:thinking_display`, `:effort`, `:thinking_block_binding` |
| 3 | "Always respond using the proper JSON schema." | FIXED (removed) | `system_prompt_generator.ex` no longer has `extend_output` |
| 4 | retired `claude-3-5-sonnet-20241022` in examples | FIXED | grep for `claude-3`/`20241022` in lib, examples and README: 0 hits |
| 5 | CLAUDE.md said "private git dependency" | FIXED | CLAUDE.md Dependencies |
| 6/7 | shouted "MUST / Do NOT" retry feedback | FIXED | `retry_feedback.ex:47-48, 78-80` |
| 8 | shouted OUTPUT SCHEMA text | FIXED | `base_agent.ex:1393` |
| 9 | "Always use the available additional information…" | FIXED | now one line under the context heading, `system_prompt_generator.ex:74` |
| 10 | `# AVAILABLE TOOLS` prose duplicating `tools` | FIXED | `generate_prompt/1`, `system_prompt_generator.ex:17` |
| 11 | `DateTime.utc_now()` in the system prompt | FIXED | `date_time_provider.ex:40-42` (date only) |
| flag 1 | summarizer fell back to a retired model | FIXED | `summarizer.ex:210-216` raises without a model |
| flag 2 | the model catalog listed only Claude 3 | FIXED | `model_catalog.ex` now uses the Models API |
| flag 4 | retry rewrote the system prompt | FIXED | `retry_feedback.ex:99-112` (user message) |
| flag 5 | `IDENTITY and PURPOSE` / `INTERNAL ASSISTANT STEPS` headers | **OPEN** | `system_prompt_generator.ex:9-10`, see AX-25 |
| flag 6 | CLAUDE.md doesn't mention OpenAICompatibleAdapter | OPEN (outside this domain) | `grep -c OpenAICompatible CLAUDE.md` = 0 |

Recommendation: update `prompt-audit-2026-09.md` to say "applied, except the section-header flag".

---

## BLOCKER for 2.0

### AX-1 BLOCKER — A tool-using agent never shows, enforces or returns its custom `output_schema`
- **Files:** `lib/normandy/agents/base_agent.ex:577-584` (`turn_response_model`), `:1376-1381` (`with_output_schema` skips `ToolCallResponse`), `:777-789` (`convert_turn_output`), `lib/normandy/llm/claudio_adapter.ex:1563-1568` (structured outputs are skipped whenever tools are present).
- **Problem:** When tools are registered, every normal call uses `%ToolCallResponse{}` as the response model:
  - The system prompt gets no OUTPUT SCHEMA.
  - Native structured outputs are skipped because tools are present.
  - When the model ends without tool calls, `convert_turn_output` only handles schemas that have a `chat_message` field. For any other schema it returns the raw `%ToolCallResponse{}`:
    ```elixir
    case output_schema do
      %{chat_message: _} -> Map.put(output_schema, :chat_message, unwrap_llm_content(raw.content))
      _ -> raw
    end
    ```
  - `validate_turn_output` then only `IO.warn`s.

  So "typed agent output" (the library's headline feature) silently does nothing once a tool is added. The model is never told the shape, and the caller receives a different struct type. The schema shows up only in the forced-final call at the iteration cap (AX-5). No doc (README, MIGRATING-2.0) mentions this.
- **Fix:**
  - When `output_schema` is not the default chat schema and tools exist, either:
    - (a) send the native `output_config.format` alongside tools (the API supports structured outputs plus tools: the final text turn is constrained), or
    - (b) after the loop ends, make one final call with the schema, no new tools and `tool_choice: none`, or
    - (c) expose a synthetic `final_answer` tool whose `input_schema` is the output schema (with `strict: true`), and treat calling it as the end of the turn.
  - Option (a) is the cheapest. At minimum, append the OUTPUT SCHEMA to tool-loop prompts too, and make `convert_turn_output` parse JSON into the schema instead of returning `raw`.
- **VERIFIED** (code path).

### AX-2 BLOCKER — The default config sends no `max_tokens`, so the quickstart gets a 400 on its first call
- **Files:** `lib/normandy/agents/base_agent.ex:154` (`max_tokens: Map.get(config, :max_tokens, nil)`), `lib/normandy/agents/base_agent_config.ex:59` (`default: nil`), `lib/normandy/llm/claudio_adapter.ex:573` (`add_max_tokens(request, nil), do: request`), `../Claudio/lib/claudio/messages/request.ex:1936` (`maybe_put("max_tokens", …)` drops nil).
- **Evidence:** `README.md:62-65` and the `claudio_adapter.ex:30-33` moduledoc both build the agent like this:
  ```elixir
  Normandy.Agents.BaseAgent.init(%{client: client, model: "claude-sonnet-4-6"})
  ```
  That config has no `max_tokens`. The Messages API requires `max_tokens`. Every e2e scenario passes `max_tokens` explicitly (e.g. `e2e/01_long_conversation.exs:39`), so live tests never hit this.
- **Fix:** Default `max_tokens` in `BaseAgent.init/1`, following the skill's guidance: about 16_000 for non-streaming calls and about 64_000 for streaming. Or raise in `init/1` with a message that names the option. Document it next to `:temperature` in CLAUDE.md.
- **VERIFIED** (code). That the API returns 400 is documented API behaviour; I did not reproduce it.

---

## HIGH

### AX-3 HIGH — MCP-connector `mcp_tool_use` blocks are dispatched as client tool calls
- **Files:** `lib/normandy/llm/claudio_adapter.ex:1134-1168` (`extract_tool_uses` keeps `:mcp_tool_use` and renames it `"#{server_name}__#{tool_name}"`), `lib/normandy/agents/tool_call_response.ex:97-112` (replayed as `type: "tool_use"`).
- **Problem:** With `mcp_servers` set, Anthropic runs the MCP tool server-side and returns `mcp_tool_use` plus `mcp_tool_result` in the same response. Normandy instead:
  - turns each `mcp_tool_use` into a `%ToolCall{}`;
  - dispatches it locally, which gives `"Tool 'srv__x' not found in registry"`, or runs it a second time if the user also registered a `ToolWrapper` with the same prefix;
  - drops the `mcp_tool_result`;
  - replays a fabricated client `tool_use` (id `mcptoolu_…`, a name not in `tools`) followed by a `tool_result` for it. The next request is likely rejected.

  No test or e2e exercises the connector path (`e2e/12_mcp_a2a.exs` uses stdio plus `ToolWrapper`).
- **Fix:** Treat `mcp_tool_use`, `mcp_tool_result` and `server_tool_use`/`*_tool_result` as opaque assistant content. Never dispatch them. Replay them verbatim (see AX-7).
- **VERIFIED** (code path). The API rejection is **PLAUSIBLE**.

### AX-4 HIGH — The tool loop ignores `stop_reason` (`max_tokens`, `pause_turn`, `refusal`)
- **Files:** `lib/normandy/llm/claudio_adapter.ex:968-976` (`populate_tool_call_response` reads only content, tool_uses and thinking), `lib/normandy/agents/turn.ex:124-138` (no tool calls means final). Grep for `pause_turn` in lib: 0 hits.
- **Problem:**
  - **`max_tokens` mid-`tool_use`:** the truncated call is executed. `Dispatch.invalid_input_result` catches only input that is not an object; a cut-off object with missing keys still runs.
  - **`max_tokens` mid-answer:** the truncated text is returned as a completed answer.
  - **`pause_turn`** (server tools or the MCP connector): treated as the final answer instead of re-sending to continue.
  - **`refusal`:** the partial or refusal text becomes `chat_message`, and the caller gets no signal.

  Only the structured no-tools path checks `stop_reason` (`claudio_adapter.ex:1576-1591`).
- **Fix:**
  - Carry `stop_reason` on `%ToolCallResponse{}`.
  - On `max_tokens` with a `tool_use`: don't execute; retry with a higher `max_tokens`, or return an error result telling the model its call was cut off.
  - On `max_tokens` with text: surface `finish_reason` and/or raise or flag.
  - On `pause_turn`: append the assistant content and call again.
  - On `refusal`: return a typed error, or route through `:fallbacks`.
- **VERIFIED**.

### AX-5 HIGH — The forced-final call at the iteration cap is set up to fail
- **Files:** `lib/normandy/agents/turn.ex:163-168` (`{:call_llm, %{response_model: s.output_schema, final: true}}`), `:114-122`, `lib/normandy/agents/base_agent.ex:295-296, 314` (tools are still sent: `if has_tools?(config), do: [tools: tool_schemas]`), `base_agent_config.ex:61` (`max_tool_iterations` default 5).
- **Problem:** When the cap is hit:
  - Nothing tells the model it is out of tool budget.
  - Tools are still offered.
  - The system prompt suddenly gains `# OUTPUT SCHEMA`. That is a cache miss, and `drop_stale_thinking` drops every thinking block in history, because the prefix key changes.
  - Because tools are present, structured outputs are skipped, so this goes down the legacy parse path.

  If the model calls a tool (the natural move mid-task), the text content is `""`. The JSON retry then says "Your previous response could not be parsed as valid JSON" and quotes an empty response. Five iterations is low for agentic work, so this path is common.
- **Fix:**
  - Keep the system prompt and tools byte-identical: no schema swap, and the schema as `output_config.format`.
  - Send `tool_choice: {"type": "none"}`, which is still allowed on every model.
  - Append a user text block after the tool results, e.g.: "You have used all available tool calls for this turn. Answer now with what you have, and say what you could not finish."
  - Raise the default cap (e.g. 20), or document it prominently.
- **VERIFIED**.

### AX-6 HIGH — Parallel tool results go out as N separate user messages
- **Files:** `lib/normandy/agents/turn.ex:371-373` (`Enum.map(results, fn r -> {:append_message, "tool", r} end)`), `lib/normandy/components/agent_memory.ex:98-104` (no merge), `lib/normandy/llm/claudio_adapter.ex:675-685` (each `"tool"` message becomes its own `add_message(:user, …)`), Claudio `request.ex:145-152` (no merge).
- **Problem:** The Claude API docs and the skill say to return all `tool_result` blocks for one assistant turn in a single user message. Splitting them "silently trains Claude to stop making parallel calls". The API tolerates it by merging, so nothing errors; tool parallelism just degrades.
- **Fix:** In `AgentMemory.history/1`, or in the adapter's `add_messages`, coalesce consecutive `"tool"` messages into one user message whose content is the concatenated `tool_result` blocks, in `tool_use` order. `reorder/2` already guarantees that order.
- **VERIFIED**.

### AX-7 HIGH — Assistant turns are rebuilt instead of replayed verbatim, which risks the preserved-thinking history check on Opus 5.5 / Fable 5.1
- **Files:** `lib/normandy/agents/tool_call_response.ex:84-118` (to_json = `thinking ++ [text] ++ tool_uses`), `lib/normandy/llm/claudio_adapter.ex:1043-1053` (all text blocks `map_join("\n")` into one string).
- **Problem:** The stored assistant message is reconstructed:
  - multiple `text` blocks are merged into one;
  - all thinking blocks are hoisted to the front;
  - text is placed before every `tool_use`;
  - `fallback`, compaction, advisor, `mcp_*` and `server_tool_*` blocks are dropped, along with citations.

  Opus 5.5 returns between-tool text as progress-update `thinking` blocks, e.g. `[thinking, tool_use, thinking, tool_use]`. Normandy would replay that as `[thinking, thinking, tool_use, tool_use]`.

  Per the migration guide, "editing, reordering, or removing an earlier turn" invalidates every later thinking block. On accounts created on or after 2026-08-31 (every new Normandy user) the default is a 400. `:thinking_block_binding` defaults to unset. `drop_stale_thinking` only tracks system, tools and model, not message edits.
- **Fix:** Store the response's raw content blocks (string-keyed, in order) on `%ToolCallResponse{}`, e.g. `raw_content`. Replay that unchanged, and derive `content`/`tool_calls` from it for Elixir callers. Add a CI e2e run with `thinking_block_binding: :error` on Opus 5.5 / Fable 5.1 to prove the history is append-only, which is the guide's three-step check.
- **PLAUSIBLE.** The code edits are VERIFIED; whether the API emits multi-block orderings that trip the check needs a live probe.

### AX-8 HIGH — Tool result size is unbounded
- **Files:** `lib/normandy/components/tool_result.ex:45-61` (`format_tool_output` sends any binary, or the full JSON encoding, verbatim), `lib/normandy/agents/dispatch.ex:346-353`. Grep for any cap or truncation outside the memory tool: none.
- **Problem:** A tool that returns a 2 MB page or a big query result puts all of it into the context. It also stays in memory, so every later request carries it. With the default `Compactor.NoOp`, the session can reach "prompt is too long" and stay stuck there. Only the memory tool caps its output (`max_view_chars` 16_000).
- **Fix:** Add a per-agent `max_tool_result_chars` (default e.g. 50_000) applied in `ToolResult`/`Dispatch`. Make the truncation model-visible: "[output truncated at 50,000 of 812,344 characters; ask for a narrower query or a specific range]". Offer a per-tool override.
- **VERIFIED**.

### AX-9 HIGH — The compaction summarizer never sees tool results or the assistant text of tool turns
- **Files:** `lib/normandy/context/summarizer.ex:171-208` (`extract_content` only matches string-keyed `%{"type" => …}` maps; anything else becomes `""`), with `agent_memory.ex:113` (history content = `BaseIOSchema.to_json`), `tool_result.ex:31-43` (atom keys: `%{type: "tool_result", …}`), `tool_call_response.ex:97-112` (atom keys: `%{type: "text"}`, `%{type: "tool_use"}`).
- **Problem:** Summaries are built from `AgentMemory.history/1`. Tool results and the assistant's text and tool_use blocks are atom-keyed, so they fall through to `_ -> ""` and are rejected. Thinking blocks (string keys) show up as `[thinking]` placeholders. For a tool-heavy agent, the summary that "replaces it in the assistant's memory, so anything you leave out is forgotten" (`summarizer.ex:31-32`) is built without any of the facts the tools returned.
- **Fix:**
  - Normalize keys before matching.
  - Render `tool_use` as `Assistant called <name>(<json input>)` and `tool_result` as `Tool result (<name>): <content, capped>`.
  - Drop thinking placeholders.
  - Add a summarizer test whose input includes a tool turn.
- **VERIFIED**.

### AX-10 HIGH — Hitting `max_tokens` or a refusal on the structured path stores raw, truncated JSON as the answer
- **Files:** `lib/normandy/llm/claudio_adapter.ex:1576-1591` (`max_tokens`, `refusal` and context-exceeded go straight to `apply_parse_failure`), `lib/normandy/llm/parse_failure.ex` (`:fallback` does `Map.put(schema, :chat_message, content)`).
- **Problem:** On the default chat schema, a truncated constrained response like `{"chat_message": "Here is the plan: 1. …` becomes the user-visible `chat_message`. It is then appended to memory and replayed next turn as `{"chat_message":"{\"chat_message\": \"Here is…"}`: double-nested JSON that teaches the model the wrong format. This hits the summarizer in particular. Its default `max_tokens` is 500 (`summarizer.ex:66`), and on Opus 5.5 thinking cannot be turned off, so thinking eats into those 500 tokens. The result is a truncated or empty summary, which either becomes `{:error, :empty_summary}` or a raw JSON fragment saved as the conversation summary.
- **Fix:**
  - On `max_tokens`, try the existing truncated-string recovery (`Json.Scanner`) before falling back. If that fails, return a typed `:max_tokens` error rather than raw JSON.
  - On `refusal`, return a typed refusal.
  - Raise the summarizer default to about 4_000, or derive it from the agent's `max_tokens`.
- **VERIFIED** (code). The interaction with thinking on Opus 5.5 is **PLAUSIBLE**.

### AX-11 HIGH — Tool `input_schema` and the OUTPUT SCHEMA carry `"description": null` for undocumented fields
- **Files:** `lib/normandy/schema.ex:581-583`:
  ```elixir
  defp get_base_type_spec(type, description) do
    Map.put(json_type(type), :description, description)
  end
  ```
  The tool schema is `__schema__(:specification)` (`schema_base_tool.ex:171-174`). Claudio does not strip nested nils (`request.ex:1931+`).
- **Problem:** Any field declared without `description:` produces `"description": null`. The library's own docs example has such a field: `schema_base_tool.ex:85`, `field(:operation, :string, required: true, enum: [...])`. JSON Schema draft 2020-12 types `description` as a string, and the spec declares `"$schema": "https://json-schema.org/draft/2020-12/schema"`. If the API validates against the metaschema, the request is rejected. If not, the model still sees `"description": null` noise in the OUTPUT SCHEMA. Every e2e tool field happens to have a description, so this has never run live.
- **Fix:** Only put `:description` when it is a non-empty binary, as `SchemaTranslator.with_description/2` already does. Consider dropping `"$schema"` and `"title"` from model-facing schemas too.
- **VERIFIED** (emitted). The 400 is **PLAUSIBLE**; one live call with the calculator example tool settles it.

---

## MEDIUM

### AX-12 MEDIUM — Context budgeting undercounts the real prompt
- **Files:** `lib/normandy/context/window_manager.ex:110-113` (chars/4), `:126-133` (memory only), `:53, :93` (`reserved_tokens: 4096`).
- **Problem:**
  - The estimate ignores the system prompt and the `tools` definitions entirely.
  - `reserved_tokens` is a fixed 4096, even when `config.max_tokens` is 16k–64k, or when thinking is on.
  - chars/4 underestimates JSON, code, and the Opus 4.7+ tokenizer (about 1–1.35x more tokens).
  - The real `usage.input_tokens` from the last response is available (it rides on telemetry) but is never used as the trigger.

  The compactor therefore fires late, and "prompt is too long" 400s remain possible.
- **Fix:**
  - Trigger on the previous call's `usage.input_tokens + cache_read + cache_creation`, plus an estimate of the new messages.
  - Set the reserve to `max(config.max_tokens, 4096)`.
  - Include the system prompt and tool JSON in the estimate.
  - Optionally use `count_tokens`.
- **VERIFIED**.

### AX-13 MEDIUM — Error and denial tool_results don't tell the model what to do next
- **Files:** `lib/normandy/agents/dispatch.ex:405-458`, `:336-337`, `lib/normandy/agents/turn.ex:424-445`, `lib/normandy/agents/turn/server.ex:1009-1018`.
- **Evidence (what the model sees, as JSON strings):**
  - `{"error":"denied by policy","rationale":null,"rule_id":null,"denied":true,"pending_approval":true}` on the synchronous path (`dispatch_one/3` collapses `:needs_approval`). It claims approval is pending, but nothing will ever approve it in this turn.
  - `{"error":"Tool 'x' not found in registry"}`: internal jargon, and it doesn't list the available tools.
  - `{"error":"budget check failed: {:exceeded, %{…}}"}`: an Elixir `inspect/1` leak.
  - `{"error":"tool input failed schema validation","validation_errors":[…],"denied":true}`: a fixable input mistake labelled "denied", which discourages a corrected retry.
  - `"approval timed out: no approver responded within 300000ms"`: no guidance on whether to retry or tell the user.
  - `"tool call interrupted … the tool may or may not have run"`: good. It is the only one that explains state, but it still gives no next step.
- **Fix:** Drop null keys. Give each error a short "next step" sentence, for example:
  - not found: "No tool named 'x'. Available tools: a, b, c."
  - validation: "The input did not match the tool's schema: <errors>. Correct the input and call the tool again."
  - policy denied: "This call was blocked by policy (<rationale>). Do not retry it; continue without it or tell the user."
  - sync needs_approval: "This action needs human approval, which is not available in this run. Do not retry; tell the user it requires approval."
  - budget: "Tool budget exhausted for this turn; answer with what you have."
- **VERIFIED**.

### AX-14 MEDIUM — The MCP `ToolWrapper` ignores the MCP `isError` flag and passes raw result terms
- **Files:** `lib/normandy/mcp/tool_wrapper.ex:99-106`. `Claudio.MCP.Client.call_tool/4` returns `{:ok, term()}` (`deps/claudio/lib/claudio/mcp/client.ex:75-76`).
- **Problem:** A `CallToolResult` with `isError: true` is returned as `{:ok, result}`, so the API gets `is_error: false`. The model sees the whole envelope (`{"content":[{"type":"text","text":"…"}],"isError":true}`) instead of the text. If the adapter returns a struct (e.g. Hermes), `ToolResult` encodes it with JSON or `inspect/1`, which dumps an Elixir struct.
- **Fix:** Map `content[*].text` and image blocks to `tool_result` content blocks, and map `isError` to `{:error, text}`.
- **VERIFIED** (pass-through). The struct shape is **PLAUSIBLE**.

### AX-15 MEDIUM — Memory tool errors are double-wrapped, breaking the reference format
- **Files:** `lib/normandy/agents/dispatch.ex:350-352` (`output: %{error: error}`), with every `"Error: …"` string in `lib/normandy/tools/memory/commands.ex` (e.g. `:86, :133, :243, :256, :421`).
- **Problem:** `Render` deliberately matches Anthropic's memory-tool reference text (`render.ex:3`), but errors reach the model as `{"error":"Error: The path /memories/x does not exist. Please provide a valid path."}`: JSON-wrapped and with "Error" twice. The model was trained on the bare reference strings.
- **Fix:** When an error reason is a binary, send it as plain `tool_result` content with `is_error: true`. Reserve the map shape for structured denials.
- **VERIFIED**.

### AX-16 MEDIUM — The memory tool description forces a `view` before anything else, every turn, at full volume
- **Files:** `lib/normandy/tools/memory.ex:193-202`.
- **Evidence:** "IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE." and "ASSUME INTERRUPTION: …"
- **Problem:** This sits in the tool definition and is resent every request. It drives one extra `view` round trip at the start of every user turn, which takes one of the default 5 tool iterations. It is also the shouted-instruction pattern that the prompt audit removed elsewhere.
- **Fix:** Use a normal-volume version: "At the start of a task, view /memories to pick up earlier progress. Record durable progress and decisions as you go; your context may be reset." Or let the integrator choose between the native `memory_20250818` declaration (the model's trained behaviour; the API supplies its own instruction) and the custom definition.
- **VERIFIED** (text). The cost is **PLAUSIBLE**.

### AX-17 MEDIUM — Schema properties are alphabetized, so "reasoning before answer" is impossible
- **Files:** `lib/normandy/schema.ex:536-538` (`Map.put(:properties, Map.new(properties))`), `lib/normandy/llm/json/schema_translator.ex:29-32` (`Map.new`).
- **Problem:** Elixir maps with 32 or fewer keys iterate in sorted key order, so a schema declared `reasoning, answer` is sent as `answer, reasoning`. Constrained decoding emits properties in schema order, which forces the answer to be generated before the reasoning. The legacy OUTPUT SCHEMA shows the same order.
- **Fix:** Build `properties` as an ordered structure, e.g. a Jason.OrderedObject or a list encoded in order, preserving declaration order. Document that declaration order is generation order.
- **VERIFIED** (ordering). The quality effect is **PLAUSIBLE**.

### AX-18 MEDIUM — Structured outputs silently drop field constraints, and the structured path has no corrective retry
- **Files:** `lib/normandy/llm/json/schema_translator.ex:50-58` (scalars keep only type, description, enum and format), `lib/normandy/llm/json/schema_binder.ex` (cast plus required only).
- **Problem:** `pattern`, `min_length`/`max_length`, `minimum`/`maximum` and `min_items`/`max_items` are removed from the constrained schema. They are not restated anywhere, so the model never learns them. A violation then only `IO.warn`s (`base_agent.ex:792-803`). The legacy path would at least have quoted them in the OUTPUT SCHEMA and retried with feedback.
- **Fix:** As the SDKs do, append unsupported constraints to the property's description (e.g. "Must match ^[0-9]{5}$; 1–100."). Optionally run validation after binding and reuse `RetryFeedback` once.
- **VERIFIED**.

### AX-19 MEDIUM — With structured outputs active, the output schema is sent twice
- **Files:** `lib/normandy/agents/base_agent.ex:1383-1395` (always appends `# OUTPUT SCHEMA` JSON to the system prompt), `claudio_adapter.ex:288-289` (also sends `output_config.format`).
- **Problem:** The schema is in both the prompt and the constraint. That costs tokens on every call, and the prompt copy also carries the `null` descriptions, `$schema` and `title` that the constrained copy omits (AX-11).
- **Fix:** When the structured path will be used, append only a one-line pointer (or nothing). Keep the full schema only for the legacy fallback. Decide once per call, because the fallback is a separate request.
- **VERIFIED**.

### AX-20 MEDIUM — Volatile context sits inside the single cached system block, and caching is off by default
- **Files:** `lib/normandy/components/system_prompt_generator.ex:45-47, 64-77` (providers are rendered into the one system string), `base_agent.ex:1393` (the schema is appended after them), `claudio_adapter.ex:43-48` (`enable_caching` default false; one breakpoint on the whole system string).
- **Problem:**
  - Any provider change (e.g. the date rolling over, or per-user data) invalidates the system prompt and everything after it. The OUTPUT SCHEMA sits after the providers, so it is re-written too.
  - Every system change also drops all replayed thinking (`drop_stale_thinking`).
  - In tool loops, caching off means each iteration re-pays the full prefix.
- **Fix:**
  - Send the system prompt as two blocks: a stable block (background, steps, output instructions, schema) with `cache_control`, then a provider block.
  - Better: on models that support mid-conversation `role: "system"` messages (Opus 4.8+, Fable 5.x, Sonnet 5.5), append provider updates there and keep the top-level system frozen.
  - Consider defaulting `enable_caching: true`.
- **VERIFIED**.

### AX-21 MEDIUM — Earlier final answers in tool mode are replayed as `{"chat_message": …}` JSON
- **Files:** `lib/normandy/agents/turn.ex:150-151` (appends the output-schema struct), `lib/normandy/components/agent_memory.ex:109-113` (only the *input* schema is unwrapped to plain text), `lib/normandy/schema.ex:412`.
- **Problem:** In tool mode the model is never asked for JSON and answers in prose. The history then shows each of its earlier answers as `{"chat_message":"…"}`. That teaches it to write JSON as prose, which is why `unwrap_llm_content` exists. The input side was fixed for the same reason (the e2e memory notes record a 0/3 vs 3/3 recall A/B).
- **Fix:** Unwrap `BaseAgentOutputSchema` the same way `BaseAgentInputSchema` is unwrapped (`model_content/1`). Better still, replay the assistant's original content verbatim (AX-7).
- **VERIFIED**.

### AX-22 MEDIUM — Mid-turn compaction strips the thinking from the in-flight `tool_use` message
- **Files:** `lib/normandy/context/window_manager.ex:396-400`, `lib/normandy/context/summarizer.ex:348-353` (`drop_thinking` on every kept message), compaction at every `:steering` boundary (`turn.ex:163-175`).
- **Problem:** When compaction runs between tool iterations, the current turn's assistant `tool_use` message loses its thinking. The docs require the last assistant turn's thinking during tool use, and the skill warns that stripping thinking blocks can trigger ordering or signature 400s.
- **Fix:** Keep thinking on messages of the current (open) turn. Removing a *leading* run of thinking is allowed; removing it from the tail is not.
- **PLAUSIBLE**.

### AX-23 MEDIUM — The DSL's `max_tokens` default of 4096 is tight for always-on thinking
- **Files:** `lib/normandy/dsl/agent.ex:105, 472`.
- **Problem:** Thinking cannot be disabled on Opus 5.5, the documented default model. A 4096-token cap is shared between thinking and output, so `stop_reason: max_tokens` becomes likely. Combined with AX-4 and AX-10, that means a silently truncated answer.
- **Fix:** Default 16_000 for non-streaming calls, the same as in AX-2.
- **PLAUSIBLE**.

---

## LOW

### AX-24 LOW — Streaming ignores `output_schema` entirely
- **Files:** `claudio_adapter.ex:391-398` (`_response_model`), `base_agent.ex:1403-1419` (no schema in the prompt).
- **Fix:** Document it, or apply AX-1 option (a) to streaming too. This was partly covered in the prior audit (AGENTS-11).
- **VERIFIED**.

### AX-25 LOW — Dated section headers and a third-person default identity
- **Files:** `system_prompt_generator.ex:9-11, 33`.
- **Evidence:** `# IDENTITY and PURPOSE`, `# INTERNAL ASSISTANT STEPS`, "This is a conversation with a helpful and friendly AI assistant."
- **Fix:** Use `# Role`, `# How to work`, `# Output`, and the default "You are a helpful assistant." These were prompt-audit flag 5 and are still open.
- **VERIFIED**.

### AX-26 LOW — Weak default field descriptions are what the model reads as its answer instruction
- **Files:** `lib/normandy/agents/io_model.ex:13, 27`.
- **Evidence:** "base input", "an input chat message from user", "base output", "a result chat message".
- **Fix:** Use "Your reply to the user, in plain text or Markdown." for the output and "The user's message." for the input.
- **VERIFIED**.

### AX-27 LOW — The catch-all `RetryFeedback` clause leaks Elixir terms and gives a vague instruction
- **Files:** `lib/normandy/llm/json/retry_feedback.ex:84-97`.
- **Evidence:** `"Error: #{inspect(reason)}"` … `"Please provide a valid JSON response."`
- **Problem:** Unlike the other two clauses, this one shows no schema. The other clauses also embed the raw spec (with `$schema`, `title` and `null` descriptions).
- **Fix:** Reuse the parse-error template, and render the cleaned schema through `SchemaTranslator`.
- **VERIFIED**.

### AX-28 LOW — The summary reaches the model as if the user had said it
- **Files:** `summarizer.ex:343`.
- **Evidence:** `"Previous conversation summary: " <> summary` as a user message.
- **Fix:** Frame it explicitly, e.g. `<conversation_summary>…</conversation_summary>` with a line saying it was written automatically from earlier turns. On supported models, use a mid-conversation system message.
- **VERIFIED**.

### AX-29 LOW — A custom input schema reaches the model as bare JSON with no explanation
- **Files:** `agent_memory.ex:113`.
- **Problem:** Input like `{"query":"…","max_results":10}` arrives with nothing in the system prompt describing those fields.
- **Fix:** Add an optional `# INPUT FORMAT` section built from the input schema's descriptions, or render the input as labelled fields.
- **PLAUSIBLE**.

### AX-30 LOW — A2A tool: untrusted card text in the definition, and no hint that the remote side lacks context
- **Files:** `lib/normandy/a2a/agent_tool.ex:191-215`.
- **Problem:** The remote agent's self-description is placed verbatim in the tool description, which is an injection surface. The `message` description doesn't say the remote agent can't see this conversation.
- **Fix:** Use "Message to send to <name>. It cannot see this conversation, so include every detail it needs." Cap or sanitize the card text.
- **PLAUSIBLE**.

### AX-31 LOW — MCP tool names are not checked against the API's name limits
- **Files:** `mcp/tool_wrapper.ex:85-89`.
- **Problem:** `"#{prefix}__#{tool.name}"` is not checked against `^[a-zA-Z0-9_-]{1,64}$`. A2A names are sanitized; MCP names are not.
- **Fix:** Sanitize and truncate with a hash suffix.
- **PLAUSIBLE**.

### AX-32 LOW — An empty final text silently returns a blank output schema
- **Files:** `base_agent.ex:778-788`.
- **Problem:** If the model ends its turn with no text (which happens after tool results), the caller gets `%BaseAgentOutputSchema{chat_message: nil}` as success.
- **Fix:** Re-prompt once ("Please give your final answer to the user."), or flag it.
- **VERIFIED**.

### AX-33 LOW — The memory tool is a custom tool, not the native `memory_20250818` type
- **Files:** `tools/memory.ex:308-310`.
- **Problem:** The schema matches the reference, but a custom definition doesn't use the model's trained tool binding or the API-supplied instruction.
- **Fix:** Add an option to declare the native type, keeping execution client-side.
- **PLAUSIBLE** (benefit).

---

## Things checked and found sound
- The system prompt is deterministic: no timestamps or UUIDs. Provider and mount iteration is sorted or stable. Tools are sent from `Map.values` of a name-keyed map, which is deterministic. Prompt-cache breakpoint layout (system, last tool, automatic) is correct.
- Retry feedback goes in a user message after the conversation, never into the system prompt (`retry_feedback.ex:99-112`). It is quoted at 500 characters and uses normal volume.
- Batch completeness: `Turn.unanswered_tool_calls/1` and the Server's interrupted results close every `tool_use`. `reorder/2` keeps results in `tool_use` order. Non-object input is refused with a clear message (`dispatch.ex:440-449`).
- `drop_stale_thinking` correctly drops thinking when system, tools or model change. The gap is message-content edits (AX-7).
- Memory tool `Render` output matches the reference text, and `view` truncation tells the model how to continue (`render.ex:45-49`).
- Thinking, effort, fallbacks, task budget and inference-geo options exist and are validated up front. Temperature is optional.
