# Wave 5 — Agent loop and model-facing correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tool-using agent returns its typed output, stops cleanly on `max_tokens`, `refusal` and `pause_turn`, replays assistant turns and tool results the way the Messages API expects, bounds what tools and memory can grow to, talks to the model in plain, actionable text, and closes the remaining security findings for MCP, guardrails, memory mounts, templates and A2A.

**Architecture:** The pure Turn core (`Normandy.Agents.Turn`) stays the single owner of loop decisions; the three interpreters (`Turn.Driver`, `Turn.Inline`, `Turn.Server`) and the BaseAgent sync and stream shells inherit every new decision from it. Wire-level fidelity moves to the edges: `%Normandy.LLM.Request{}` gains `output_format` and `tool_choice`, `%ToolCallResponse{}` keeps the API-shaped `content_blocks` it was built from, and tool results are coalesced into one user message when a request is built. Caps sit at one boundary each: `Dispatch` for tool results, the `MemoryStore` write for namespaces.

**Tech Stack:** Elixir ~> 1.15, Claudio `~> 0.7.0` (Hex), NimbleOptions (through `Normandy.Options`), `:telemetry`, Jason (`Jason.OrderedObject`), Postgrex/Ecto SQL (Postgres store), Redix (Redis store), ExUnit.

**Spec:** `investigations/pre-2.0-audit/plan.md` § "Wave 5" (Tasks 5.1–5.7) and § "Review Focus", decisions 6, 7, 10, 11, 12a, 12b, 15, 17, 20 and **22** in `investigations/pre-2.0-audit/decisions.md`, findings AX-1, AX-3–AX-11, AX-13–AX-18, AX-21, AX-22, AX-25, AX-28, AX-31, AX-32 in `agentx.md`, SEC-2–SEC-4, SEC-6–SEC-18 in `security.md`, PERF-11 in `perf.md`. Decision 22 is Q's acceptance of every recommendation in `wave-5-research/QUESTIONS.md`; those answers are binding here and listed under "Rulings against plan.md". The facts inventories behind this plan are `wave-5-research/5.1-5.2-loop.md`, `5.3-5.5-replay.md`, `5.4-caps.md`, `5.6-text.md`, `5.7-security.md` (verified against HEAD `0dccd48`).

## Global Constraints

- Elixir `~> 1.15` (no `String.replace_invalid/2`, which is 1.16+); no new dependencies.
- Every public function that takes options validates them with `Normandy.Options.validate!(opts, schema, {Mod, :fun, arity})`; an unknown option raises `ArgumentError` in the house style `"Mod.fun/arity: unknown option :x; supported: ..."`.
- No message, log line, telemetry metadata, tool result or persisted term contains a credential, a stacktrace, or model text in an error `reason` (decision 6). Errors are logged by type (module, `LLMError` type, `:exit`/`:throw` and the exit tag), never with `inspect(error)`.
- Every new telemetry event or metadata key is documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs` enforces it).
- Every user-visible change gets a bullet in `MIGRATING-2.0.md`, in the section its task owns (see "MIGRATING sections" below), placed after `## 31.` and before `## New, non-breaking`; non-breaking additions get a bullet under `## New, non-breaking`.
- A change to the tool loop, stop-reason handling or message construction must hold on **every** path: BaseAgent `run/3` (sync), BaseAgent `stream/3`, `Turn.Driver`, `Turn.Inline`, `Turn.Server`. Put loop decisions in the pure core (`lib/normandy/agents/turn.ex`) so the three interpreters inherit them; a new core effect must be wired into all three interpreters (or it crashes one of them with a `CaseClauseError`). Each task's tests cover the sync path, `stream/3` and `Turn.Server` at minimum.
- The 78 injected `call_llm` handlers in the test suite return structs without new keys: read new response fields with `Map.get(resp, :key)` and treat `nil` as "absent, keep today's behaviour".
- Tests are deterministic: no test depends on two processes racing; never `Process.sleep` to wait for a message (use `assert_receive`, `Normandy.Test.Eventually.wait_until/1` or a synchronous call). Concurrency cases (two writers) start both writers behind a barrier and assert the outcome set, not an order.
- Model-facing strings that a task changes are pinned by golden tests asserting the exact text.
- Run `mix format` before every test run. A task is done only when `mix precommit 2>&1 | tee <log>` shows ` 0 failures` and exit 0, and `mix docs --warnings-as-errors` exits 0. Tasks touching `MemoryStore` backends also run the Postgres and Redis suites (see Task 5.4b).
- Commits: add files individually (`git add <path>`; `git add .`/`-A` forbidden); no AI attribution of any kind in the message (no Co-Authored-By, no "Generated with"); never push.
- Never run a destructive command (dropping a database or table, `rm -rf`, `git reset --hard`) without the controller asking Q first. No step in this plan needs one (decision 23, B4).
- Do not edit `CLAUDE.md`. Proposed CLAUDE.md text goes to the controller in the task report; the wave-gate task collects it for Q.

## Task order

`5.1 → 5.3a → 5.3b → 5.3c → 5.2a → 5.2b → 5.4a → 5.4b → 5.5 → 5.6a → 5.6b → 5.6c → 5.7a → 5.7b → 5.7c → 5.7d → 5.8 (gate)`

5.3 runs before 5.2 (decision 22, 5.1-5.2 Q4): `pause_turn` cannot be replayed before assistant turns keep their server and MCP blocks, and the iteration-cap notice is persisted inside the coalesced tool-result message. Section writers may split or merge the lettered sub-tasks; the order of the numbered tasks is fixed.

## Shared interfaces (exact names; every task uses these)

| Name | Owner | Shape |
|---|---|---|
| `%Normandy.LLM.Request{output_format: nil}` | 5.1 | The output-schema **struct** (not a JSON Schema map) the final answer text must match; set by BaseAgent only on tool-loop calls (`response_model: %ToolCallResponse{}`) whose `config.output_schema` is not the chat schema. Adapters that support constrained decoding translate it (`StructuredOutputs.schema_for/2`); others ignore it. |
| `%Normandy.LLM.Request{tool_choice: nil}` | 5.2b | `nil` (adapter default) or `:none`; ClaudioAdapter maps `:none` to `Claudio.Messages.Request.set_tool_choice(req, :none)`; the OpenAI-compatible adapter ignores it. |
| `ToolCallResponse.content_blocks` | 5.3b | `{:array, :map}`, default `[]`: the string-keyed, API-shaped assistant content, from `Claudio.Messages.Response.to_assistant_content/1` (sync) or the accumulated stream content. `BaseIOSchema.to_json/1` replays it verbatim when non-empty (minus thinking blocks when `thinking == []`); else today's rebuild. Read with `Map.get(r, :content_blocks, [])`. |
| `ToolCallResponse.stop_reason` | 5.3c | Atom or `nil`, default `nil`, never serialized by `to_json/1`; set by `populate_tool_call_response`. |
| `Normandy.Components.AgentMemory.request_messages/1` | 5.3a | Pure: history messages → request messages, each run of consecutive `"tool"` messages merged into one `%Message{role: "tool"}` whose content is the concatenated blocks in order. Used by every request builder (BaseAgent sync, stream, `TokenCounter`). Memory, the store and the Turn core keep one entry per result. |
| `AgentMemory.model_content/1` unwraps `%BaseAgentOutputSchema{chat_message: s}` to `s` | 5.3b | Mirrors the existing input-side unwrap (AX-21). |
| `LLMError` types `:max_tokens`, `:refusal` | 5.2a | `retryable?: false`; `reason` never holds model text; `:model_context_window_exceeded` maps to `:max_tokens` with a detail naming it. |
| `Normandy.LLM.Call.check_stop_reason/1` | 5.2a | `@doc false`; `{:ok, resp} | {:error, %LLMError{type: :max_tokens | :refusal}}`; the one gate used by `Call.converse/3` and the stream path. |
| `LLMError` type `:pause_turn`; `%Turn.State{final_pauses: 0}` | 5.2b | Decision 23: a final call still paused after 3 continuations is `{:error, %LLMError{type: :pause_turn}}` (`retryable?: false`, `reason: {:stop_reason, :pause_turn}`, no model text); `final_pauses` is private to the core and counts the continuations; `iterations_left` never goes below 0. |
| `max_tool_iterations` default `20` | 5.2b | `BaseAgentConfig`, `InitOptions`, the DSL. |
| Cap notice text | 5.2b | `"You have used all available tool calls for this turn. Answer now with what you have, and say what you could not finish."` persisted as a `"user"` memory message before the final call; `request_messages/1` places it as a trailing text block in the preceding tool-result user message. |
| `max_tool_result_chars` (agent) / `max_result_chars` (`Toolset.register/3`) | 5.4a | `pos_integer | nil`, agent default `100_000`; the per-tool value wins, including a per-tool `nil`. Characters = graphemes. Truncation note: `"\n[truncated: #{kept} of #{total} chars shown]"`. Applies to error results too, after all hooks. |
| `Dispatch.finish/3` | 5.4a | `@doc false`; `ensure_encodable/1` then the cap; called at every Dispatch exit and from `ServerGlue`. Invalid UTF-8 binary output becomes an error result here. |
| `[:normandy, :tool, :result_truncated]` | 5.4a | measurements `%{original_chars, kept_chars}`; metadata `tool_name`, `agent_name`, `tool_call_id`, the run/turn ids, `limit_source: :agent | :tool`. |
| `MemoryStore.put/6` | 5.4b | `put(handle, ns, path, content, expected, limits)`, `limits :: [max_bytes: pos_integer | nil, max_documents: pos_integer | nil]`; backends define `limits \\ []`; over a cap → `{:error, {:namespace_full, :bytes | :documents, would_be}}`, checked bytes first, atomically with the write. A write that does not increase bytes or count is always allowed. |
| `Memory` tool option `max_namespace_documents` | 5.4b | `pos_integer | nil`, default `1000`, independent of `max_namespace_bytes`. |
| `Compactor.WindowManager` option `summary_max_tokens` | 5.5 | `pos_integer | nil`; `nil` (default) = the agent's `max_tokens`, else 16_000. |
| `{:maybe_compact, %{..., mid_round: boolean}}` | 5.5 | Core effect payload gains `mid_round`; compaction at a mid-round boundary runs only when over the window, and then strips retained thinking (today's recovery). New `[:normandy, :agent, :compaction]` metadata key `mid_round`. |
| `Normandy.Schema.Wire.encodable/1` and spec key `:property_order` | 5.6c | Spec stays a plain map with `:property_order`; `Wire.encodable/1` builds `Jason.OrderedObject`s at the model-facing boundaries only. |
| `ToolWrapper` `:prefix` (required) | 5.7a | `String.t()` matching `~r/\A[a-zA-Z0-9-]+(?:_[a-zA-Z0-9-]+)*\z/`, ≤ 61 bytes, or `false` (opt-out). Name = `prefix <> "__" <> tool`. A2A `AgentTool.new/3` gets the same required `:prefix`, replacing the fixed `"a2a"`. |
| `Normandy.Guardrails.GuardError` | 5.7b | Public exception, fields `kind`, `reason`; message names the module or exit tag only. |
| `A2A.Server.handle_message/4` | 5.7b | `(config, message, carrier, opts)`; options `max_text_bytes` (default `100_000`, `nil` = off; over → `{:error, :too_large}`) and `tool_context` (plain map, replaces `config.tool_context` for the call). `/2`, `/3` delegate with `[]`. |
| `ConfigTemplate.check_loaded!/1` and supplement `:pinned` | 5.7c | Plain-data and behaviour check on load, called in `Turn.Server` right after loading the template and inside `rebuild/3`; `:pinned` lists fields whose supplement value must equal the template's. |

## MIGRATING sections

`## 32.` Tool loops return the output schema; stop reasons are errors (5.1, 5.2) · `## 33.` Tool calls and assistant turns are replayed as received (5.3) · `## 34.` Tool results and memory namespaces are capped (5.4) · `## 35.` Compaction (5.5, including the Turn.Server persistence note) · `## 36.` Model-facing text and schemas (5.6) · `## 37.` Security hardening (5.7).

## Rulings against plan.md (decision 22)

- **R1 (5.1)** An undecodable final answer is `{:error, %LLMError{type: :invalid_output}}`; `{:error, %Schema.ValidationError{}}` is for text that decodes but breaks the schema. Review Focus #2 reads "a parsed output struct, `LLMError :invalid_output`, or `ValidationError`".
- **R2 (5.1)** `output_format` is sent for non-chat schemas only, and on `stream/3` too. Most of AX-1's fallback half already shipped in Wave 2 (`0df3b46`, `9b66fac`); 5.1 adds the native format and the acceptance tests. AX-19 (schema both in prompt and constraint) stays open.
- **R3 (order)** 5.3 before 5.2; `pause_turn` and "an agent with `mcp_servers` runs the tool-loop response model" belong to 5.3c.
- **R4 (5.2)** A truncated chat answer is a `:max_tokens` error too; `max_tool_iterations` default 5 → 20; the cap notice is persisted (append-only), and the final call keeps tools listed with `tool_choice: :none`.
- **R5 (5.3)** "Byte-equal replay" means equal to `Claudio.Messages.Response.to_assistant_content/1` of the response (Claudio drops `server_name` on `mcp_tool_result` on purpose). Claudio's dropping of `citations` on text blocks is a Claudio 0.7.1 patch, verified live in Task 7.6; it is out of this wave. Tool results coalesce at request build, not in the core. The final answer is unwrapped from `chat_message` in `model_content/1`; storing the raw final response is deferred.
- **R6 (5.5)** plan.md's "a mid-turn compaction keeps the open tool call's thinking" is replaced: a mid-round compaction happens only over the window limit and then strips retained thinking (the API's keep-tail recovery). The summarizer's default budget is the agent's `max_tokens`. Turn.Server's unpersisted compaction gets a MIGRATING note now and a fix in Wave 6.
- **R7 (5.4)** The cap applies to error results and runs after hooks; map/list outputs are truncated as encoded JSON text; invalid-UTF-8 output becomes an error result. Postgres tracks totals in a counter table added to the unreleased migration. A write that shrinks an over-cap namespace is allowed.
- **R8 (5.6)** Tool `{:error, binary}` is sent bare with `is_error: true` for every tool; `pending_approval` is removed from all three sites and `Dispatch.DenialEnvelope` deleted; "next step" sentences go on Dispatch-built results, expiry, rejection, interruption and hook denials, not Executor messages; `denied: true` leaves validation and non-object input errors; MCP non-text content becomes a one-line note; `# EXTRA INFORMATION AND CONTEXT` becomes `# Context`; dropped constraints are appended to the property description (the corrective retry is deferred); an empty final answer is `:invalid_output`; `"$schema"` and `"title"` are dropped at the wire boundary. Deferred to Wave 6 or 2.x and not closed here: AX-12, AX-18's retry, AX-19, AX-20, AX-29, AX-33.
- **R9 (5.7)** SEC-8 = trust-boundary docs + `check_loaded!/1` + `:pinned`; HMAC signing is a known limit. Guardrails catch exits and throws; no per-guard `:timeout`. SEC-7 refuses mounts sharing a namespace with different access. SEC-13 refuses `{`/`}` in session ids. SEC-14 stays in Task 6.5; SEC-15 gets docs, no fingerprint.

## Header refinements from the section writers (accepted by the controller)

- **H1 (5.3c)** `ToolCallResponse.stop_reason` is typed `Normandy.LLM.Response.stop_reason() | nil` (an atom for known reasons, a string passed through otherwise; atoms are never created from provider input). `@doc false Normandy.LLM.Response.stop_reason/1` maps known strings to atoms; the core matches both `:pause_turn` and `"pause_turn"`.
- **H2 (5.1)** A `stream/3` request sets `output_format` whenever the output schema is non-chat, with or without tools (stream requests have `response_model: nil`); `output_format` alone decides whether a request is constrained.
- **H3 (5.2b)** `tool_choice` is left out when the built Claudio request has no tools (MCP toolsets count as tools); it is added in `build_request/3` after `add_mcp_servers/2`.
- **H4 (5.2b)** `request_messages/1` folds any non-empty binary `"user"` message that directly follows a coalesced `"tool"` message into it as a trailing text block (the cap notice, and `after_compact` injections at a mid-round boundary).
- **H5 (5.2b)** The cap notice is appended by `apply_tool_results/2` before `{:persist, _}` and only for a non-empty batch (a `pause_turn` resend gets no extra user message). `max_tool_iterations: 20` also goes into `Turn.new/1` and `%Turn.State{}`; the DSL inherits it from `InitOptions`.
- **H6 (5.2a)** Additional `@doc false` names: `Normandy.LLM.Call.stop_reason/1`, `ClaudioAdapter.__incomplete_response__/2`. `LLMError` `reason` is `{:stop_reason, atom}`; usage is kept.
- **H7 (5.4)** "A write that does not increase bytes or count is always allowed" is read per limit (`MemoryStore.check_limits/3` is the one rule). `result_truncated` metadata carries `Metadata.ids/1` (no run id exists).
- **H8 (5.5)** "Mid-round compaction only over the window" holds by construction for `Compactor.WindowManager`; for custom compactors it is a documented contract (`Compactor` moduledoc "Compacting mid-round"), and `mid_round` is passed in the compactor `ctx`. `compact_turn_memory/3` reads `Map.fetch!(info, :mid_round)`, so every `{:maybe_compact, _}` emitter must set it.
- **H9 (5.6)** R8's bare error covers an exception's message too (non-binary, non-exception reasons keep `%{error: term}`). Task 5.6b is split into 5.6b-i and 5.6b-ii. New `@doc false Dispatch.error_result/3`, the one builder for every error/denial result.
- **H10 (5.7)** `:prefix` is required on all seven MCP/A2A entry points that share the schemas. `GuardError` wraps host code only under `:on_error` `:open`/`:closed`; under `:reraise` the host's exception propagates untouched. `:pinned` is a keyword list `field => value`. Addition: `@doc false ConfigTemplate.check_pinned!/2`, called in `reconstruct_config/2` before the credential provider runs.

## Review Focus

1. **A non-chat `output_schema` whose final answer arrives on the fallback path** (structured outputs off, or the schema rejected with a 400). Expect the parsed struct, `LLMError :invalid_output` (undecodable) or `ValidationError` (decoded, invalid), never a raw `%ToolCallResponse{}`. Test: Task 5.1.
2. **A response cut off at `max_tokens` in the middle of a `tool_use`, under `Turn.Server` and under `stream/3`.** Expect `{:error, %LLMError{type: :max_tokens}}`, no tool run, no assistant row persisted, nothing truncated in memory. Test: Task 5.2a.
3. **A turn that mixes thinking, text with citations, client `tool_use`, `server_tool_use` and `mcp_tool_use`, replayed on the next request.** Expect the assistant message equal to `to_assistant_content/1` and no local dispatch of the MCP call. Test: Task 5.3b.
4. **A tool result over the cap that ends in multibyte UTF-8 (a ZWJ emoji family).** Expect truncation on a grapheme boundary, valid UTF-8, and the note. Test: Task 5.4a.
5. **Two concurrent memory writers whose documents fit alone but not together.** Expect exactly one success and one `{:namespace_full, :bytes, _}` on every backend (Postgres proves less: one sandbox connection). Test: Task 5.4b.

---

### Task 5.1: A tool loop sends the output schema as `output_config.format` (AX-1, decision 11)

Most of AX-1 already shipped in Wave 2 (`0df3b46`, `9b66fac`): the final answer is parsed into
the output schema, and a non-chat schema is shown in the system prompt. This task adds the
missing part, the native format on tool-loop calls and on streams (R2, Q5). It also adds the
acceptance tests for Review Focus #1 (R1: `:invalid_output` when the answer does not decode,
`ValidationError` when it decodes but breaks the schema).

**Files:**
- Modify: `lib/normandy/llm/request.ex` (field `output_format`)
- Modify: `lib/normandy/agents/base_agent.ex` (`get_response_with_usage/3`, `build_stream_request/1`, `call_turn_llm/3`, `call_stream_llm/3`, new `request_output_format/2`)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (moduledoc "Structured Outputs"; `Model.converse/3`, `converse_structured/4`, new `handle_structured/3`; `Model.stream/3` with new `open_stream/2` and `retry_stream_without_format/3`; `__structured_schema_for__/3` → `/2`)
- Modify: `lib/normandy/telemetry/provider.ex` (`request_metadata/2` doc, `structured_output?/2`). This file is also a caller of `__structured_schema_for__/3`.
- Modify: `lib/normandy/agents/model.ex` (moduledoc "Response content")
- Modify: `MIGRATING-2.0.md` (create `## 32.`)
- Create: `test/support/wire_script.ex` (`Normandy.Test.WireScript`, used by 5.3a–c too)
- Test: create `test/agents/tool_loop_output_format_test.exs`; modify `test/llm/claudio_adapter_test.exs` (the routing describe block)

**Interfaces:**
- Consumes: `StructuredOutputs.schema_for/2`, `ClaudioAdapter.__structured_error_action__/1`, `prompt_output_schema/2` (BaseAgent), `ParseFailure.parse_text_output/3` through `convert_final_output/4` (unchanged).
- Produces: `%Normandy.LLM.Request{output_format: nil}` (header); `ClaudioAdapter.__structured_schema_for__(client, %Request{}) :: {:ok, map()} | :skip` (`@doc false`, replaces `/3`); `Provider.request_metadata/2` option `:output_format`; `Normandy.Test.WireScript.client/2`, `message/3`, `block/3`.

- [ ] **Step 1: Write the failing tests**

Create `test/support/wire_script.ex`. Its plug is a closure, so a `Turn.Server` worker (a raw `spawn`, `server.ex:1365`, with no `$callers`) is answered too. A `Req.Test` stub would not be found from that process:

```elixir
defmodule Normandy.Test.WireScript do
  @moduledoc """
  A `Normandy.LLM.ClaudioAdapter` whose HTTP requests are answered in-process, for tests
  that check what goes over the wire.

  `client/2` takes the replies in call order. Every request body is decoded and sent to
  the process that called `client/2` as `{:wire_body, n, body}` (`n` counts from 0). The
  plug is a closure rather than a `Req.Test` stub, so a request made from any process
  (a `Turn.Server` worker) is answered. A request past the last reply raises, naming its
  index.

  A reply is one of:

    * `{:json, content_blocks, stop_reason}` - a Messages API response body
    * `{:sse, events}` - a streamed response; build `events` with `message/3` and `block/3`
    * `{:status, status, body}` - an error response, `body` encoded as JSON
  """

  alias Normandy.LLM.ClaudioAdapter

  @spec client([tuple()], map()) :: ClaudioAdapter.t()
  def client(replies, options \\ %{}) when is_list(replies) and is_map(options) do
    test_pid = self()
    counter = :atomics.new(1, [])
    replies = List.to_tuple(replies)

    plug = fn conn ->
      n = :atomics.add_get(counter, 1, 1) - 1
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire_body, n, Jason.decode!(body)})

      if n >= tuple_size(replies) do
        raise "WireScript: request #{n} has no scripted reply (#{tuple_size(replies)} scripted)"
      end

      respond(conn, n, elem(replies, n))
    end

    %ClaudioAdapter{
      api_key: "k",
      options: Map.merge(%{req_options: [plug: plug, retry: false]}, options)
    }
  end

  @doc "A streamed message: `message_start`, `blocks`, `message_delta` with `stop`, `message_stop`."
  @spec message(String.t(), [map()], String.t()) :: [map()]
  def message(id, blocks, stop) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
        }
      }
    ] ++
      blocks ++
      [
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => stop},
          "usage" => %{"output_tokens" => 1}
        },
        %{"type" => "message_stop"}
      ]
  end

  @doc "One streamed content block at `index`: its start, `deltas`, its stop."
  @spec block(non_neg_integer(), map(), [map()]) :: [map()]
  def block(index, start, deltas) do
    [%{"type" => "content_block_start", "index" => index, "content_block" => start}] ++
      Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
      [%{"type" => "content_block_stop", "index" => index}]
  end

  defp respond(conn, n, {:json, content, stop}) do
    body = %{
      "id" => "msg_#{n}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => content,
      "stop_reason" => stop,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    send_json(conn, 200, body)
  end

  defp respond(conn, _n, {:sse, events}) do
    sse =
      Enum.map_join(events, fn event ->
        "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
      end)

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, sse)
  end

  defp respond(conn, _n, {:status, status, body}), do: send_json(conn, status, body)

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
```

Create `test/agents/tool_loop_output_format_test.exs`:

```elixir
defmodule Normandy.Agents.ToolLoopOutputFormatTest do
  @moduledoc """
  Task 5.1 (AX-1, decision 11): a tool-using agent with a non-chat output schema sends
  that schema as `output_config.format` beside its tools, on `run/3`, `stream/3` and
  under `Turn.Server`, and gets the typed struct back on the structured path and on
  both fallback paths (structured outputs off, the schema refused with a 400).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLM.Request
  alias Normandy.LLMError
  alias Normandy.Schema.ValidationError
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true, enum: ["approve", "deny"])
    end
  end

  @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @rejection %{
    "type" => "error",
    "error" => %{
      "type" => "invalid_request_error",
      "message" => "output_config.format.schema: unsupported keyword"
    }
  }

  defp text(text), do: %{"type" => "text", "text" => text}

  defp agent(client, output_schema \\ %Decision{}) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      output_schema: output_schema,
      toolset: Toolset.new([%FakeTool{}])
    })
  end

  defp server_run(config, session_id) do
    {:ok, srv} =
      Server.start_link(
        session_id: session_id,
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    Server.run(srv, %{chat_message: "decide"})
  end

  defp streamed_text(text) do
    WireScript.message(
      "msg_s",
      WireScript.block(0, text(""), [%{"type" => "text_delta", "text" => text}]),
      "end_turn"
    )
  end

  defp format(body), do: get_in(body, ["output_config", "format"])

  describe "the request" do
    defp stub_agent(output_schema) do
      %StubClient{notify: self(), reply: fn rm -> %{rm | content: ~s({"action": "deny"})} end}
      |> agent(output_schema)
    end

    test "a tool-loop call carries the non-chat output schema as output_format" do
      assert {:ok, _config, %Decision{action: "deny"}} =
               BaseAgent.run(stub_agent(%Decision{}), %{chat_message: "decide"})

      assert_receive {:converse,
                      %Request{response_model: %ToolCallResponse{}, output_format: %Decision{}},
                      _opts}
    end

    test "a chat agent's tool-loop call carries none" do
      assert {:ok, _config, _output} =
               BaseAgent.run(stub_agent(nil), %{chat_message: "hi"})

      assert_receive {:converse, %Request{response_model: %ToolCallResponse{}} = request, _}
      assert request.output_format == nil
    end

    test "a call without tools carries none: its response model is the format" do
      config =
        BaseAgent.init(%{
          client: %StubClient{notify: self(), reply: fn _rm -> %Decision{action: "deny"} end},
          model: "claude-opus-5-5",
          output_schema: %Decision{}
        })

      assert {:ok, _config, %Decision{}} = BaseAgent.run(config, %{chat_message: "decide"})
      assert_receive {:converse, %Request{response_model: %Decision{}} = request, _}
      assert request.output_format == nil
    end

    test "under Turn.Server the tool-loop call carries it too" do
      assert {:ok, %Decision{action: "deny"}} =
               server_run(stub_agent(%Decision{}), "s-output-format")

      assert_receive {:converse, %Request{output_format: %Decision{}}, _opts}
    end
  end

  describe "on the wire" do
    test "run/3 sends output_config.format with the tools on every loop call" do
      client =
        WireScript.client([
          {:json, [@tool_use], "tool_use"},
          {:json, [text(~s({"action": "deny"}))], "end_turn"}
        ])

      assert {:ok, _config, %Decision{action: "deny"}} =
               BaseAgent.run(agent(client), %{chat_message: "decide"})

      for n <- [0, 1] do
        assert_receive {:wire_body, ^n, body}
        assert %{"type" => "json_schema", "schema" => schema} = format(body)
        assert Map.has_key?(schema["properties"], "action")
        assert [%{"name" => "weather"}] = body["tools"]
      end
    end

    test "stream/3 sends it too" do
      client = WireScript.client([{:sse, streamed_text(~s({"action": "approve"}))}])

      assert {:ok, _config, %Decision{action: "approve"}} =
               BaseAgent.stream(agent(client), %{chat_message: "decide"}, fn _ -> :ok end)

      assert_receive {:wire_body, 0, body}
      assert %{"type" => "json_schema"} = format(body)
    end

    test "llm_call start reports structured_output: true for a tool-loop call and a stream" do
      name = "fmt-#{System.unique_integer([:positive])}"
      ref = TelemetryCapture.attach([[:normandy, :agent, :llm_call, :start]], agent_name: name)

      client =
        WireScript.client([
          {:json, [text(~s({"action": "deny"}))], "end_turn"},
          {:sse, streamed_text(~s({"action": "deny"}))}
        ])

      config = %{agent(client) | name: name}
      assert {:ok, config, %Decision{}} = BaseAgent.run(config, %{chat_message: "x"})

      assert {:ok, _, %Decision{}} =
               BaseAgent.stream(config, %{chat_message: "x"}, fn _ -> :ok end)

      assert_received {:telemetry, ^ref, _, %{stream: false, structured_output: true}}
      assert_received {:telemetry, ^ref, _, %{stream: true, structured_output: true}}
    end

    test "a chat agent's stream sends none" do
      client = WireScript.client([{:sse, streamed_text("Hello.")}])

      assert {:ok, _config, %{chat_message: "Hello."}} =
               BaseAgent.stream(agent(client, nil), "hi", fn _ -> :ok end)

      assert_receive {:wire_body, 0, body}
      assert format(body) == nil
    end
  end

  # Review Focus #1: the answer arrives on a fallback path. Each route gives the
  # parsed struct, :invalid_output (undecodable) or ValidationError (decoded, invalid),
  # never a %ToolCallResponse{}.
  describe "the fallback paths" do
    @outcomes [
      {~s({"action": "deny"}), :parsed},
      {"I would deny it.", :invalid_output},
      {~s({"action": "delete_everything"}), :validation_error}
    ]

    # :off has structured outputs switched off; :rejected has the schema refused by a
    # 400, then the same request re-sent without it.
    defp sync_client(:off, answer),
      do: WireScript.client([{:json, [text(answer)], "end_turn"}], %{structured_outputs: false})

    defp sync_client(:rejected, answer),
      do:
        WireScript.client([
          {:status, 400, @rejection},
          {:json, [text(answer)], "end_turn"}
        ])

    defp stream_client(:off, answer),
      do: WireScript.client([{:sse, streamed_text(answer)}], %{structured_outputs: false})

    defp stream_client(:rejected, answer),
      do:
        WireScript.client([
          {:status, 400, @rejection},
          {:sse, streamed_text(answer)}
        ])

    defp assert_outcome(result, :parsed), do: assert({:ok, %Decision{action: "deny"}} = result)

    defp assert_outcome(result, :invalid_output),
      do: assert({:error, %LLMError{type: :invalid_output}} = result)

    defp assert_outcome(result, :validation_error),
      do: assert({:error, %ValidationError{}} = result)

    defp without_config({:ok, _config, output}), do: {:ok, output}
    defp without_config(error), do: error

    for route <- [:off, :rejected], {answer, outcome} <- @outcomes do
      @route route
      @answer answer
      @outcome outcome

      test "run/3, #{route}: #{outcome}" do
        @route
        |> sync_client(@answer)
        |> agent()
        |> BaseAgent.run(%{chat_message: "decide"})
        |> without_config()
        |> assert_outcome(@outcome)

        # The request that produced the answer: the only one, or the re-sent one.
        answered = if @route == :off, do: 0, else: 1
        assert_received {:wire_body, ^answered, body}
        assert format(body) == nil
        assert body["system"] =~ "# OUTPUT SCHEMA"
      end

      test "stream/3, #{route}: #{outcome}" do
        @route
        |> stream_client(@answer)
        |> agent()
        |> BaseAgent.stream(%{chat_message: "decide"}, fn _ -> :ok end)
        |> without_config()
        |> assert_outcome(@outcome)
      end

      test "Turn.Server, #{route}: #{outcome}" do
        @route
        |> sync_client(@answer)
        |> agent()
        |> server_run("s-fallback-#{@route}-#{@outcome}")
        |> assert_outcome(@outcome)
      end
    end

    test "the rejected request carried the format; the re-sent one does not" do
      client = sync_client(:rejected, ~s({"action": "deny"}))
      assert {:ok, _config, %Decision{}} = BaseAgent.run(agent(client), %{chat_message: "x"})

      assert_receive {:wire_body, 0, first}
      assert_receive {:wire_body, 1, second}
      assert %{"type" => "json_schema"} = format(first)
      assert format(second) == nil
      assert Map.delete(first, "output_config") == Map.delete(second, "output_config")
    end
  end
end
```

In `test/llm/claudio_adapter_test.exs`, replace the whole
`describe "structured-vs-legacy routing decision (__structured_schema_for__/3)"` block
(the two tests "uses structured outputs for a compatible schema with no tools" and "skips
structured outputs when tools are present (tool_use needs the legacy loop)") with:

```elixir
  describe "structured-vs-legacy routing decision (__structured_schema_for__/2)" do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.LLM.Json.TestFixtures.MultiField

    defp routed(fields, options \\ %{}) do
      request = struct!(%Normandy.LLM.Request{model: "m", messages: [], max_tokens: 1}, fields)

      ClaudioAdapter.__structured_schema_for__(
        %ClaudioAdapter{api_key: "k", options: options},
        request
      )
    end

    test "uses structured outputs for a compatible schema with no tools" do
      assert {:ok, schema} = routed(response_model: %MultiField{})
      assert is_map(schema)
    end

    test "skips a call with tools whose response model is not the tool loop's" do
      assert :skip = routed(response_model: %MultiField{}, tools: [%{name: "lookup"}])
    end

    test "a tool-loop call is constrained by output_format, beside its tools" do
      assert {:ok, schema} =
               routed(
                 response_model: %ToolCallResponse{},
                 output_format: %MultiField{},
                 tools: [%{name: "lookup"}]
               )

      assert {:ok, ^schema} = routed(response_model: %MultiField{})
    end

    test "a tool-loop call without output_format takes the legacy path" do
      assert :skip = routed(response_model: %ToolCallResponse{}, tools: [%{name: "lookup"}])
    end

    test "a stream (no response model) is constrained by output_format alone" do
      assert {:ok, _schema} = routed(output_format: %MultiField{})
      assert :skip = routed([])
    end

    test "the kill switch skips output_format too" do
      assert :skip =
               routed(
                 [response_model: %ToolCallResponse{}, output_format: %MultiField{}],
                 %{structured_outputs: false}
               )
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/tool_loop_output_format_test.exs test/llm/claudio_adapter_test.exs`
Expected: FAIL. Both files fail to compile: `unknown key :output_format for struct Normandy.LLM.Request`.

- [ ] **Step 3: The request field**

In `lib/normandy/llm/request.ex`, add to the moduledoc list after the `:response_model` bullet:

```
  - `:output_format` - on a tool-loop call (`response_model: %ToolCallResponse{}`) or a
    stream, the output-schema struct the final answer's text must match, or `nil`. An
    adapter that supports constrained decoding sends it (`ClaudioAdapter`, as
    `output_config.format`); others ignore it. Never set for the chat schema.
```

Add `output_format: nil,` after `response_model: nil,` in `defstruct`, and add
`output_format: struct() | nil,` after `response_model: struct() | nil,` in `@type t`.

- [ ] **Step 4: BaseAgent sets it**

In `lib/normandy/agents/base_agent.ex`, after `defp prompt_output_schema(response_model, _config), do: response_model` add:

```elixir
  # The output schema the final answer's text must match, for an adapter that can
  # constrain it (Request.output_format): the schema the system prompt shows on a
  # tool-loop call or a stream, never the chat schema (its answer is plain text). A
  # call whose response model is the output schema itself needs none.
  defp request_output_format(%ToolCallResponse{} = loop, config),
    do: prompt_output_schema(loop, config)

  defp request_output_format(_response_model, _config), do: nil
```

In `get_response_with_usage/3`, inside the `%Normandy.LLM.Request{...}` literal, after
`response_model: response_model,` add `output_format: request_output_format(response_model, config),`.

In `build_stream_request/1`, inside the `%Normandy.LLM.Request{...}` literal, after
`messages: messages,` add `output_format: request_output_format(%ToolCallResponse{}, config),`.

In `call_turn_llm/3`, the `Provider.request_metadata(config, ...)` call becomes:

```elixir
        Provider.request_metadata(config,
          stream: false,
          response_model: response_model || Map.get(config, :output_schema),
          output_format: request_output_format(response_model, config),
          tools?: has_tools?(config)
        )
```

In `call_stream_llm/3`, the `Provider.request_metadata(config, ...)` call becomes:

```elixir
        Provider.request_metadata(config,
          stream: true,
          response_model: nil,
          output_format: request_output_format(%ToolCallResponse{}, config),
          tools?: has_tools?(config)
        )
```

- [ ] **Step 5: The adapter routes on the request and sends the format**

In `lib/normandy/llm/claudio_adapter.ex`:

Replace `__structured_schema_for__/3` (the `@doc false` comment and the function) with:

```elixir
  @doc false
  # Decides structured-vs-legacy for THIS call, returning the JSON Schema to send as
  # output_config.format. A tool-loop call (response_model %ToolCallResponse{}) and a
  # stream (response_model nil) are constrained by request.output_format alone: the
  # format shapes the final answer's text while tool_use stays available. Any other
  # call with tools takes the legacy path; without tools the response model is the
  # format.
  @spec __structured_schema_for__(t(), Request.t()) :: {:ok, map()} | :skip
  def __structured_schema_for__(client, %Request{response_model: model} = request)
      when model == nil or is_struct(model, ToolCallResponse) do
    case request.output_format do
      nil -> :skip
      format -> StructuredOutputs.schema_for(client, format)
    end
  end

  def __structured_schema_for__(client, %Request{tools: [], response_model: model}),
    do: StructuredOutputs.schema_for(client, model)

  def __structured_schema_for__(_client, %Request{}), do: :skip
```

In `Model.converse/3` (second clause), the `case` head becomes
`case ClaudioAdapter.__structured_schema_for__(client, request) do`.

In `converse_structured/4`, the `{:ok, response}` branch's
`case ClaudioAdapter.__handle_structured_response__(response, request.response_model, context) do`
becomes `case handle_structured(response, request.response_model, context) do`. Add after
`converse_structured/4`:

```elixir
    # A tool-loop call's text is the constrained final answer, or text beside tool
    # calls: it stays the ToolCallResponse's content, and the turn parses the final
    # answer into the output schema (BaseAgent.convert_turn_output/3), as on the
    # legacy path.
    defp handle_structured(response, %Normandy.Agents.ToolCallResponse{} = schema, _context),
      do: populate_tool_call_response(schema, ClaudioAdapter.extract_content(response), response)

    defp handle_structured(response, response_model, context),
      do: ClaudioAdapter.__handle_structured_response__(response, response_model, context)
```

Replace `Model.stream/3` (keep its `@doc`) with:

```elixir
    def stream(client, %Request{} = request, _opts) do
      claudio_client = build_claudio_client(client)

      claudio_request =
        client
        |> build_request(request, stream: true)
        |> Claudio.Messages.Request.enable_streaming()

      # request.output_format constrains the streamed text as it does a tool-loop
      # call's. A 400 naming the output format or its schema re-sends the request
      # without it (the system prompt already shows the schema); any other error
      # is returned.
      result =
        case ClaudioAdapter.__structured_schema_for__(client, request) do
          {:ok, json_schema} ->
            claudio_request
            |> Claudio.Messages.Request.set_output_format(json_schema)
            |> open_stream(claudio_client)
            |> retry_stream_without_format(claudio_request, claudio_client)

          :skip ->
            open_stream(claudio_request, claudio_client)
        end

      case result do
        {:ok, stream} -> {:ok, stream}
        {:error, error} -> {:error, ClaudioAdapter.__to_llm_error__(error)}
      end
    end

    defp open_stream(claudio_request, claudio_client) do
      case Claudio.Messages.create(claudio_client, claudio_request) do
        {:ok, %Req.Response{body: stream}} ->
          {:ok,
           stream
           |> Claudio.Messages.Stream.parse_events()
           |> Stream.map(fn
             {:ok, event} -> to_stream_processor_event(event)
             {:error, _} = error -> error
           end)}

        {:error, _error} = error ->
          error
      end
    end

    defp retry_stream_without_format({:ok, _stream} = ok, _claudio_request, _claudio_client),
      do: ok

    defp retry_stream_without_format({:error, error}, claudio_request, claudio_client) do
      case ClaudioAdapter.__structured_error_action__(error) do
        :fallback -> open_stream(claudio_request, claudio_client)
        :propagate -> {:error, error}
      end
    end
```

In the moduledoc's "## Structured Outputs" list, replace the bullet

```
  - The call carries tools — a `stop_reason: :tool_use` response requires the legacy tool-handling
    loop.
```

with

```
  - A tool-loop call (`response_model: %ToolCallResponse{}`) or a stream without
    `request.output_format`. With it, the format (the agent's non-chat output schema) is sent
    as `output_config.format` beside the tools: it constrains the final answer's text, and a
    `tool_use` response is still a tool call. `stream/3` re-sends without the format on a 400
    naming it, as `converse/3` does.
  - Any other call that carries tools.
```

- [ ] **Step 6: Telemetry asks the adapter the same question**

`Normandy.Telemetry.Provider.structured_output?/2` calls `__structured_schema_for__/3`
(`provider.ex:110-117`). In `lib/normandy/telemetry/provider.ex`, replace the
`Options:` and `structured_output` paragraphs of `request_metadata/2`'s doc with:

```
  Options: `:stream` (boolean), `:response_model` (the call's response schema
  struct; `nil` for a stream), `:output_format` (the call's
  `Normandy.LLM.Request` `output_format`), `:tools?` (whether the call carries tools).

  `structured_output` is whether native structured outputs are requested for this
  call: true only for a Claudio client that sends `output_config.format`, that is a
  call without tools whose response schema the translator can express, or a tool-loop
  call or stream whose `output_format` it can express.
```

and replace `structured_output?/2` with:

```elixir
  # The adapter's own routing decision, asked about a request of this call's shape.
  defp structured_output?(config, opts) do
    match?(%ClaudioAdapter{}, config.client) and
      ClaudioAdapter.__structured_schema_for__(config.client, %Normandy.LLM.Request{
        model: "",
        messages: [],
        max_tokens: 1,
        response_model: Keyword.get(opts, :response_model),
        output_format: Keyword.get(opts, :output_format),
        tools: if(Keyword.get(opts, :tools?, false), do: [:tools], else: [])
      }) != :skip
  end
```

Check that no other caller is left: `grep -rn "__structured_schema_for__" lib test` should
return 9 lines: `claudio_adapter.ex` (the `@spec`, 3 definition heads, `converse/3`,
`stream/3`), `provider.ex` (1), `claudio_adapter_test.exs` (the describe name and the
`routed/2` helper).

- [ ] **Step 7: Model protocol doc**

In `lib/normandy/agents/model.ex`, at the end of the "## Response content" section (after
"When `response_model` is `nil`, return the answer text as a binary."), add:

```
  `request.output_format`, when set, is the output schema the final answer's text must
  match on a tool-loop call (`response_model: %ToolCallResponse{}`) or a stream. An
  implementation with constrained decoding may send it; the text still goes in
  `:content` (or the stream), and Normandy parses it. Others ignore it.
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/tool_loop_output_format_test.exs test/llm/claudio_adapter_test.exs test/telemetry/llm_call_request_metadata_test.exs test/agents/base_agent_output_validation_test.exs test/llm/claudio_request_capabilities_test.exs`
Expected: PASS (`tool_loop_output_format_test.exs`: 27 tests).

- [ ] **Step 9: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.1.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.1.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 10: MIGRATING-2.0.md**

Insert after the end of `## 31.` and before `## New, non-breaking`:

```markdown
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
```

- [ ] **Step 11: Commit**

```bash
git add lib/normandy/llm/request.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/llm/claudio_adapter.ex lib/normandy/telemetry/provider.ex \
  lib/normandy/agents/model.ex MIGRATING-2.0.md test/support/wire_script.ex \
  test/agents/tool_loop_output_format_test.exs test/llm/claudio_adapter_test.exs
git commit -m "feat(agents): a tool loop sends the output schema as output_config.format"
```

---

---

### Task 5.3a: One user message per tool-result batch; MCP calls are not dispatched (AX-6, AX-3)

Results are merged when the request is built (Q6, R5). Memory, the session store, the Turn
core and `Turn.unanswered_tool_calls/1` still keep one `"tool"` entry per result. `history/1`
does not change either: `Summarizer.recent_entries/2` and
`WindowManager.truncate_oldest_first` zip it with `entry_chain/1` by count
(`summarizer.ex:416-418`, `window_manager.ex:296-318`).

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (new `request_messages/1`)
- Modify: `lib/normandy/agents/base_agent.ex` (`get_response_with_usage/3`, `build_stream_request/1`)
- Modify: `lib/normandy/context/token_counter.ex` (`build_messages_payload/1`; drop the unused `Message` alias)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`extract_tool_uses/1`)
- Modify: `MIGRATING-2.0.md` (create `## 33.`)
- Test: create `test/agents/tool_result_coalescing_test.exs`; modify `test/context/token_counter_test.exs` (one new describe block)

**Interfaces:**
- Consumes: `AgentMemory.history/1` output; `Normandy.Test.WireScript` (Task 5.1).
- Produces: `AgentMemory.request_messages([%{role:, content:}]) :: [Message.t()]` (header). `ClaudioAdapter.extract_tool_uses/1` now returns `tool_use` blocks only.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/tool_result_coalescing_test.exs`:

```elixir
defmodule Normandy.Agents.ToolResultCoalescingTest do
  @moduledoc """
  Task 5.3a. AX-6: a batch of tool results goes to the model as one user message, on
  `run/3`, `stream/3` and under `Turn.Server`, while memory and the store keep one
  entry per result. AX-3: `mcp_tool_use` and `server_tool_use` blocks, which the API
  ran, are never dispatched as local tools.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Test.FakeTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @weather %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @clock %{"type" => "tool_use", "id" => "t2", "name" => "clock", "input" => %{}}
  @done %{"type" => "text", "text" => "Done."}

  defp agent(client, tools \\ [%FakeTool{}, %FakeTool{name: "clock"}]) do
    BaseAgent.init(%{client: client, model: "claude-opus-5-5", toolset: Toolset.new(tools)})
  end

  defp server(config, session_id, store) do
    {:ok, srv} =
      Server.start_link(
        session_id: session_id,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    srv
  end

  defp streamed(id, tool_uses, stop) do
    blocks =
      tool_uses
      |> Enum.with_index()
      |> Enum.flat_map(fn {tool_use, index} ->
        WireScript.block(index, Map.put(tool_use, "input", %{}), [
          %{"type" => "input_json_delta", "partial_json" => "{}"}
        ])
      end)

    WireScript.message(id, blocks, stop)
  end

  defp streamed_text(id, text) do
    WireScript.message(
      id,
      WireScript.block(0, %{"type" => "text", "text" => ""}, [
        %{"type" => "text_delta", "text" => text}
      ]),
      "end_turn"
    )
  end

  # The second request: the user turn, the assistant's two calls, then ONE user
  # message with both results in tool_use order.
  defp assert_one_result_message do
    assert_received {:wire_body, 1, body}
    assert Enum.map(body["messages"], & &1["role"]) == ["user", "assistant", "user"]

    assert [
             %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "weather in "},
             %{"type" => "tool_result", "tool_use_id" => "t2", "content" => "weather in "}
           ] = List.last(body["messages"])["content"]
  end

  describe "AgentMemory.request_messages/1" do
    test "merges each run of tool messages into one, blocks in order" do
      history = [
        %{role: "user", content: "q"},
        %{role: "assistant", content: [%{type: "tool_use", id: "a"}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "a"}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "b"}]},
        %{role: "assistant", content: [%{type: "tool_use", id: "c"}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "c"}]}
      ]

      assert [
               %Message{role: "user", content: "q"},
               %Message{role: "assistant"},
               %Message{
                 role: "tool",
                 content: [%{tool_use_id: "a"}, %{tool_use_id: "b"}]
               },
               %Message{role: "assistant"},
               %Message{role: "tool", content: [%{tool_use_id: "c"}]}
             ] = AgentMemory.request_messages(history)
    end

    test "a tool message whose content is not a list stays its own message" do
      history = [
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "a"}]},
        %{role: "tool", content: "plain"},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "b"}]}
      ]

      assert [
               %Message{content: [%{tool_use_id: "a"}]},
               %Message{content: "plain"},
               %Message{content: [%{tool_use_id: "b"}]}
             ] = AgentMemory.request_messages(history)
    end

    test "messages of other roles pass through unchanged" do
      history = [%{role: "user", content: "a"}, %{role: "user", content: "b"}]

      assert [%Message{role: "user", content: "a"}, %Message{role: "user", content: "b"}] =
               AgentMemory.request_messages(history)
    end
  end

  describe "a batch of two tool results" do
    test "run/3 sends one user message; memory keeps one entry per result" do
      client =
        WireScript.client([{:json, [@weather, @clock], "tool_use"}, {:json, [@done], "end_turn"}])

      assert {:ok, config, %{chat_message: "Done."}} = BaseAgent.run(agent(client), "go")

      assert_one_result_message()

      assert 2 ==
               config.memory |> AgentMemory.messages() |> Enum.count(&(&1.role == "tool"))
    end

    test "stream/3 sends one user message" do
      client =
        WireScript.client([
          {:sse, streamed("msg_0", [@weather, @clock], "tool_use")},
          {:sse, streamed_text("msg_1", "Done.")}
        ])

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(agent(client), "go", fn _ -> :ok end)

      assert_one_result_message()
    end

    test "Turn.Server sends one user message; the store keeps one entry per result" do
      client =
        WireScript.client([{:json, [@weather, @clock], "tool_use"}, {:json, [@done], "end_turn"}])

      store = InMemory.new()
      srv = server(agent(client), "s-coalesce", store)

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")
      assert_one_result_message()

      assert {:ok, entries} = InMemory.history(store, "s-coalesce")
      assert 2 == Enum.count(entries, &(&1.role == "tool"))
    end
  end

  describe "MCP connector blocks (AX-3)" do
    @mcp_use %{
      "type" => "mcp_tool_use",
      "id" => "mcptoolu_1",
      "name" => "search",
      "server_name" => "docs",
      "input" => %{"q" => "x"}
    }
    @mcp_result %{
      "type" => "mcp_tool_result",
      "tool_use_id" => "mcptoolu_1",
      "server_name" => "docs",
      "is_error" => false,
      "content" => [%{"type" => "text", "text" => "found"}]
    }

    # A local tool with the name the old adapter gave the MCP call.
    defp mcp_agent(client),
      do: agent(client, [%FakeTool{name: "docs__search", notify: self()}])

    test "extract_tool_uses/1 returns only client tool_use blocks" do
      response = %{content: [@mcp_use, @mcp_result, @weather]}

      assert [%ToolCall{id: "t1", name: "weather"}] = ClaudioAdapter.extract_tool_uses(response)
    end

    test "run/3 answers without dispatching the MCP call" do
      client =
        WireScript.client([{:json, [@mcp_use, @mcp_result, @done], "end_turn"}])

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(mcp_agent(client), "go")
      refute_received {:tool_ran, _}
      refute_received {:wire_body, 1, _}
    end

    test "Turn.Server answers without dispatching the MCP call" do
      client =
        WireScript.client([{:json, [@mcp_use, @mcp_result, @done], "end_turn"}])

      srv = server(mcp_agent(client), "s-mcp", InMemory.new())

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")
      refute_received {:tool_ran, _}
      refute_received {:wire_body, 1, _}
    end

    test "stream/3 answers without dispatching the MCP call" do
      events =
        WireScript.message(
          "msg_0",
          WireScript.block(0, %{@mcp_use | "input" => %{}}, [
            %{"type" => "input_json_delta", "partial_json" => ~s({"q": "x"})}
          ]) ++
            WireScript.block(1, @mcp_result, []) ++
            WireScript.block(2, %{"type" => "text", "text" => ""}, [
              %{"type" => "text_delta", "text" => "Done."}
            ]),
          "end_turn"
        )

      client = WireScript.client([{:sse, events}])

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(mcp_agent(client), "go", fn _ -> :ok end)

      refute_received {:tool_ran, _}
      refute_received {:wire_body, 1, _}
    end
  end
end
```

In `test/context/token_counter_test.exs`, add before `describe "count_conversation/2 input checks" do`:

```elixir
  describe "count_conversation/2 payload, parallel tool results" do
    test "a batch of tool results is counted as one user message, as a request sends it" do
      test_pid = self()

      Req.Test.stub(__MODULE__.Batch, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})
        Req.Test.json(conn, %{"input_tokens" => 7})
      end)

      client = %ClaudioAdapter{
        api_key: "k",
        options: %{req_options: [plug: {Req.Test, __MODULE__.Batch}, retry: false]}
      }

      calls =
        for id <- ["t1", "t2"],
            do: %Normandy.Components.ToolCall{id: id, name: "weather", input: %{}}

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "weather?")
        |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
          tool_calls: calls
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t1",
          output: "sunny"
        })
        |> AgentMemory.add_message("tool", %Normandy.Components.ToolResult{
          tool_call_id: "t2",
          output: "rainy"
        })

      agent = %{BaseAgent.init(%{client: client, model: "claude-haiku-4-5"}) | memory: memory}

      assert {:ok, %{"input_tokens" => 7}} = TokenCounter.count_conversation(client, agent)
      assert_received {:payload, payload}

      assert Enum.map(payload["messages"], & &1["role"]) == ["user", "assistant", "user"]

      assert [%{"tool_use_id" => "t1"}, %{"tool_use_id" => "t2"}] =
               List.last(payload["messages"])["content"]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/tool_result_coalescing_test.exs test/context/token_counter_test.exs`
Expected: FAIL.
- The `request_messages/1` tests fail with `UndefinedFunctionError`.
- The three batch tests and the token-counter test fail on the roles: they get `["user", "assistant", "user", "user"]`.
- `extract_tool_uses/1` returns two calls.
- The `run/3` and `Turn.Server` MCP tests fail: `docs__search` runs (`{:tool_ran, "docs__search"}`), and the second request has no scripted reply.
- The `stream/3` MCP test already passes. The stream path never dispatched `mcp_tool_use`, and this test keeps it that way.

- [ ] **Step 3: `AgentMemory.request_messages/1`**

In `lib/normandy/components/agent_memory.ex`, add right after `history/1` (before the
`model_content/1` comment):

```elixir
  @doc """
  The messages of a request, from `history/1`'s output.

  Each run of consecutive `"tool"` messages whose content is a block list becomes one
  `"tool"` message holding their blocks in order, so a batch of tool results reaches the
  model as one user message, as the Messages API expects of parallel tool use. Memory,
  the session store and the turn keep one entry per result; only the request merges
  them. A `"tool"` message whose content is not a list stays a message of its own.
  """
  @spec request_messages([%{role: String.t(), content: term()}]) :: [Message.t()]
  def request_messages(history) when is_list(history) do
    history
    |> Enum.reduce([], &add_request_message/2)
    |> Enum.reverse()
  end

  defp add_request_message(
         %{role: "tool", content: blocks},
         [%Message{role: "tool", content: previous} = last | rest]
       )
       when is_list(blocks) and is_list(previous),
       do: [%{last | content: previous ++ blocks} | rest]

  defp add_request_message(%{role: role, content: content}, acc),
    do: [%Message{role: role, content: content} | acc]
```

- [ ] **Step 4: Every request builder uses it**

`grep -rn 'AgentMemory.history()' lib | grep -v "context/window_manager\|context/summarizer"`
lists the three builders. Make these three changes:

1. `lib/normandy/agents/base_agent.ex`, `get_response_with_usage/3`. In the `%Normandy.LLM.Request{...}` literal, replace
   ```elixir
      messages:
        Enum.map(history, fn %{role: role, content: content} ->
          %Message{role: role, content: content}
        end),
   ```
   with `messages: AgentMemory.request_messages(history),`.
2. `lib/normandy/agents/base_agent.ex`, `build_stream_request/1`. In the `messages =` pipeline, replace
   ```elixir
      |> Enum.map(fn %{role: role, content: content} ->
        %Message{role: role, content: content}
      end)
   ```
   with `|> AgentMemory.request_messages()`. The `Message` alias stays in use elsewhere in `base_agent.ex`.
3. `lib/normandy/context/token_counter.ex`, `build_messages_payload/1`. Replace
   `|> Enum.map(&%Message{role: &1.role, content: &1.content})` with
   `|> AgentMemory.request_messages()`, and delete the now-unused `alias Normandy.Components.Message`
   (otherwise `compile --warnings-as-errors` fails).

`Turn.Server` builds its requests through `BaseAgent.non_streaming_handlers/0` →
`get_response_with_usage/3`. The JSON retry resends `request.messages`, which is already
coalesced. Neither needs a change.

- [ ] **Step 5: Only client `tool_use` blocks are dispatched**

In `lib/normandy/llm/claudio_adapter.ex`, replace `extract_tool_uses/1`'s first clause
(including its `@doc false`) with:

```elixir
  @doc false
  # The client tool calls Normandy runs: `tool_use` blocks after the last fallback.
  # `mcp_tool_use` and `server_tool_use` blocks were run by the API (an MCP connector,
  # a server tool); their results are already in the response, so they are never
  # dispatched here. They reach the next request in `ToolCallResponse.content_blocks`.
  def extract_tool_uses(%{content: content_blocks}) when is_list(content_blocks) do
    content_blocks
    |> content_after_last_fallback()
    |> Enum.filter(fn block ->
      (Map.get(block, :type) || Map.get(block, "type")) in [:tool_use, "tool_use"]
    end)
    |> Enum.map(fn tool_use ->
      %Normandy.Components.ToolCall{
        id: Map.get(tool_use, :id) || Map.get(tool_use, "id"),
        name: Map.get(tool_use, :name) || Map.get(tool_use, "name"),
        input: Map.get(tool_use, :input) || Map.get(tool_use, "input")
      }
    end)
  end
```

(The last sentence of the comment points at Task 5.3b's field. Until 5.3b lands, MCP blocks
are not replayed. That was already true before this task.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/tool_result_coalescing_test.exs test/context/token_counter_test.exs test/agents/base_agent_tool_loop_test.exs test/tools/tool_input_isolation_test.exs test/llm/claudio_adapter_test.exs`
Expected: PASS. Existing tests that read `request.messages` check only that a `"tool"` message is present, or count them as zero. `tool_input_isolation_test.exs:135-139` flattens contents. All of them stay green unchanged (research §1.4).

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.3a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.3a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 8: MIGRATING-2.0.md**

Insert after `## 32.`'s last bullet and before `## New, non-breaking`:

```markdown
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
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/context/token_counter.ex lib/normandy/llm/claudio_adapter.ex MIGRATING-2.0.md \
  test/agents/tool_result_coalescing_test.exs test/context/token_counter_test.exs
git commit -m "fix(agents): one user message per tool-result batch; MCP calls are not dispatched"
```

---

### Task 5.3b: Assistant turns are replayed as received (AX-7, AX-21 unwrap, compaction keeps structs)

R5 defines "byte-equal" as equal to `Claudio.Messages.Response.to_assistant_content/1` of the
response. That function drops `server_name` from a replayed `mcp_tool_result` on purpose.
Claudio 0.7 also drops `citations` from text blocks; the fix is a Claudio 0.7.1 patch, verified
in Task 7.6, outside this wave. Stream content goes through the same Claudio function
(`ToolCallResponse.api_blocks/1`), so the sync and stream paths replay identical blocks and
pick up the Claudio patch together.

**Files:**
- Modify: `lib/normandy/agents/tool_call_response.ex` (field `content_blocks`, `api_blocks/1`, moduledoc, `BaseIOSchema.to_json/1`)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`populate_tool_call_response/3`)
- Modify: `lib/normandy/agents/base_agent.ex` (`build_streaming_assistant_response/2`)
- Modify: `lib/normandy/components/stream_processor.ex` (server/MCP input, `citations_delta`; `content_block_delta` handling moves to `apply_delta/3` so credo's complexity check passes)
- Modify: `lib/normandy/components/agent_memory.ex` (`model_content/1` output-side unwrap)
- Modify: `lib/normandy/context/window_manager.ex` (`rebuild_memory/2`), `lib/normandy/context/summarizer.ex` (`rebuild_memory_with_summary/4`)
- Modify: `lib/normandy/agents/model.ex` (moduledoc "Response content")
- Modify: `MIGRATING-2.0.md` (`## 33.`)
- Test: create `test/agents/assistant_turn_replay_test.exs`; modify `test/agents/tool_call_response_test.exs`, `test/components/stream_processor_test.exs`, `test/context/window_manager_test.exs`, `test/context/summarizer_test.exs`, and three existing assertions (Step 1, last part)

**Interfaces:**
- Consumes: `Claudio.Messages.Response.to_assistant_content/1`, `from_map/1`; `AgentMemory.request_messages/1` (Task 5.3a); `WireScript` (Task 5.1).
- Produces: `ToolCallResponse.content_blocks` (header), `ToolCallResponse.api_blocks([map()]) :: [map()]`, `AgentMemory.model_content/1` output unwrap (header). Compaction rebuilders keep stored structs.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/assistant_turn_replay_test.exs` (Review Focus #3):

```elixir
defmodule Normandy.Agents.AssistantTurnReplayTest do
  @moduledoc """
  Task 5.3b (AX-7, Review Focus #3): an assistant turn that mixes thinking, text with
  citations, a client `tool_use`, a `server_tool_use` and an `mcp_tool_use` goes back
  on the next request as `Claudio.Messages.Response.to_assistant_content/1` makes it,
  on `run/3`, `stream/3` and under `Turn.Server`, and the MCP call is not run locally.
  An earlier chat answer goes back as its plain text (AX-21).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Claudio.Messages.Response, as: ClaudioResponse
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @citation %{
    "type" => "web_search_result_location",
    "url" => "https://example.com/paris",
    "title" => "Paris",
    "encrypted_index" => "eidx",
    "cited_text" => "Paris is sunny."
  }
  @thinking %{"type" => "thinking", "thinking" => "look it up", "signature" => "sig1"}
  @cited %{"type" => "text", "text" => "Paris is sunny.", "citations" => [@citation]}
  @server_use %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_1",
    "name" => "web_search",
    "input" => %{"query" => "paris weather"}
  }
  @search_result %{
    "type" => "web_search_tool_result",
    "tool_use_id" => "srvtoolu_1",
    "content" => [
      %{
        "type" => "web_search_result",
        "url" => "https://example.com/paris",
        "title" => "Paris",
        "encrypted_content" => "enc"
      }
    ]
  }
  @mcp_use %{
    "type" => "mcp_tool_use",
    "id" => "mcptoolu_1",
    "name" => "search",
    "server_name" => "docs",
    "input" => %{"q" => "paris"}
  }
  @mcp_result %{
    "type" => "mcp_tool_result",
    "tool_use_id" => "mcptoolu_1",
    "server_name" => "docs",
    "is_error" => false,
    "content" => [%{"type" => "text", "text" => "found"}]
  }
  @more %{"type" => "text", "text" => "Checking the local tool."}
  @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @turn [@thinking, @cited, @server_use, @search_result, @mcp_use, @mcp_result, @more, @tool_use]
  @done %{"type" => "text", "text" => "Done."}

  # The oracle: what Claudio's canonical replay makes of the response.
  defp expected_replay,
    do:
      %{"content" => @turn}
      |> ClaudioResponse.from_map()
      |> ClaudioResponse.to_assistant_content()

  defp agent(client) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      toolset:
        Toolset.new([
          %FakeTool{notify: self()},
          %FakeTool{name: "docs__search", notify: self()}
        ])
    })
  end

  defp replayed_assistant(n) do
    assert_received {:wire_body, ^n, body}

    assert [_user, %{"role" => "assistant", "content" => content}, %{"role" => "user"}] =
             body["messages"]

    content
  end

  defp assert_replayed_as_received do
    assert replayed_assistant(1) == expected_replay()
    assert_received {:tool_ran, "weather"}
    refute_received {:tool_ran, "docs__search"}
  end

  # The same turn, streamed: thinking and signature deltas, a citations delta, and
  # the server and MCP tool inputs as input_json_delta.
  defp streamed_turn do
    blocks = [
      {%{"type" => "thinking", "thinking" => ""},
       [
         %{"type" => "thinking_delta", "thinking" => "look it up"},
         %{"type" => "signature_delta", "signature" => "sig1"}
       ]},
      {%{"type" => "text", "text" => ""},
       [
         %{"type" => "citations_delta", "citation" => @citation},
         %{"type" => "text_delta", "text" => "Paris is sunny."}
       ]},
      {%{@server_use | "input" => %{}},
       [%{"type" => "input_json_delta", "partial_json" => ~s({"query": "paris weather"})}]},
      {@search_result, []},
      {%{@mcp_use | "input" => %{}},
       [%{"type" => "input_json_delta", "partial_json" => ~s({"q": "paris"})}]},
      {@mcp_result, []},
      {%{"type" => "text", "text" => ""},
       [%{"type" => "text_delta", "text" => "Checking the local tool."}]},
      {@tool_use, [%{"type" => "input_json_delta", "partial_json" => "{}"}]}
    ]

    events =
      blocks
      |> Enum.with_index()
      |> Enum.flat_map(fn {{start, deltas}, index} -> WireScript.block(index, start, deltas) end)

    WireScript.message("msg_0", events, "tool_use")
  end

  defp streamed_done do
    WireScript.message(
      "msg_1",
      WireScript.block(0, %{"type" => "text", "text" => ""}, [
        %{"type" => "text_delta", "text" => "Done."}
      ]),
      "end_turn"
    )
  end

  test "run/3 replays the turn as received" do
    client = WireScript.client([{:json, @turn, "tool_use"}, {:json, [@done], "end_turn"}])

    assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(agent(client), "weather?")
    assert_replayed_as_received()
  end

  test "stream/3 replays the streamed turn in the same shape" do
    client = WireScript.client([{:sse, streamed_turn()}, {:sse, streamed_done()}])

    assert {:ok, _config, %{chat_message: "Done."}} =
             BaseAgent.stream(agent(client), "weather?", fn _ -> :ok end)

    assert_replayed_as_received()
  end

  test "Turn.Server replays the turn as received" do
    client = WireScript.client([{:json, @turn, "tool_use"}, {:json, [@done], "end_turn"}])

    {:ok, srv} =
      Server.start_link(
        session_id: "s-replay",
        config: agent(client),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "weather?")
    assert_replayed_as_received()
  end

  test "an earlier chat answer goes back as its plain text" do
    client =
      WireScript.client([
        {:json, [@done], "end_turn"},
        {:json, [%{"type" => "text", "text" => "Again."}], "end_turn"}
      ])

    {:ok, config, _} = BaseAgent.run(agent(client), "first")
    {:ok, _config, _} = BaseAgent.run(config, "second")

    assert_received {:wire_body, 1, body}

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => "Done."},
             %{"role" => "user"}
           ] = body["messages"]
  end
end
```

In `test/agents/tool_call_response_test.exs`, add
`alias Claudio.Messages.Response, as: ClaudioResponse` above the
`alias Normandy.Agents.ToolCallResponse` line. Change `alias Normandy.Components.{BaseIOSchema, ToolCall}` to
`alias Normandy.Components.{AgentMemory, BaseIOSchema, ToolCall}`. Then add before
`test "to_json does not send prefix_key" do`:

```elixir
  describe "content_blocks" do
    @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}
    @server_use %{
      "type" => "server_tool_use",
      "id" => "s1",
      "name" => "web_search",
      "input" => %{}
    }
    @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}

    test "to_json replays them unchanged, in their order" do
      blocks = [@thinking, %{"type" => "text", "text" => "a"}, @server_use, @tool_use]

      response = %ToolCallResponse{
        content: "a",
        thinking: [@thinking],
        tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}],
        content_blocks: blocks
      }

      assert BaseIOSchema.to_json(response) == blocks
    end

    test "to_json leaves their thinking out once :thinking is dropped" do
      response = %ToolCallResponse{thinking: [@thinking], content_blocks: [@thinking, @tool_use]}

      assert BaseIOSchema.to_json(AgentMemory.drop_thinking(response)) == [@tool_use]
    end

    test "to_json sends a client tool_use input that is not an object as {}" do
      response = %ToolCallResponse{content_blocks: [%{@tool_use | "input" => ~s({"city": "NY)}]}

      assert [%{"type" => "tool_use", "input" => %{}}] = BaseIOSchema.to_json(response)
    end

    test "a response stored before the field existed is rebuilt from its fields" do
      response =
        %ToolCallResponse{content: "hi"}
        |> Map.delete(:content_blocks)

      assert [%{type: "text", text: "hi"}] = BaseIOSchema.to_json(response)
    end

    test "they survive AgentMemory.dump/1 and load/1" do
      response = %ToolCallResponse{content_blocks: [@thinking, @server_use, @tool_use]}
      memory = AgentMemory.add_message(AgentMemory.new_memory(), "assistant", response)

      assert memory |> AgentMemory.dump() |> AgentMemory.load() |> AgentMemory.history() ==
               AgentMemory.history(memory)
    end

    test "api_blocks/1 is Claudio's replay of the blocks" do
      blocks = [@thinking, %{"type" => "text", "text" => "a", "citations" => nil}, @tool_use]

      assert ToolCallResponse.api_blocks(blocks) ==
               %{"content" => blocks}
               |> ClaudioResponse.from_map()
               |> ClaudioResponse.to_assistant_content()
    end
  end
```

In `test/components/stream_processor_test.exs`, inside `describe "content the final message keeps"`,
after the test "thinking text and its signature are accumulated", add:

```elixir
    test "server_tool_use and mcp_tool_use inputs are accumulated and decoded" do
      events =
        for {type, index} <- [{"server_tool_use", 0}, {"mcp_tool_use", 1}],
            event <- [
              %{
                type: "content_block_start",
                content_block: %{"type" => type, "id" => "s#{index}", "input" => %{}},
                index: index
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => ~s({"q":)},
                index: index
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => ~s("x"})},
                index: index
              },
              %{type: "content_block_stop", index: index}
            ],
            do: event

      assert %{
               content: [
                 %{"type" => "server_tool_use", "input" => %{"q" => "x"}},
                 %{"type" => "mcp_tool_use", "input" => %{"q" => "x"}}
               ]
             } = StreamProcessor.build_final_message(events)
    end

    test "citations deltas are kept on their text block, in order" do
      events = [
        %{
          type: "content_block_start",
          content_block: %{"type" => "text", "text" => ""},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "citations_delta", "citation" => %{"cited_text" => "a"}},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "text_delta", "text" => "Sunny."},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "citations_delta", "citation" => %{"cited_text" => "b"}},
          index: 0
        },
        %{type: "content_block_stop", index: 0}
      ]

      assert %{
               content: [
                 %{
                   "type" => "text",
                   "text" => "Sunny.",
                   "citations" => [%{"cited_text" => "a"}, %{"cited_text" => "b"}]
                 }
               ]
             } = StreamProcessor.build_final_message(events)
    end
```

In `test/context/window_manager_test.exs`, add `alias Normandy.Agents.Turn` above
`alias Normandy.Components.AgentMemory`. Then add before `test "removes oldest messages first" do`:

```elixir
    test "kept messages keep their stored structs, so the kept batch is still answered" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)
      agent = %{memory: memory_ending_in_thinking_round(), config: %{}}

      {:ok, truncated} = WindowManager.truncate_conversation(agent, manager)

      messages = AgentMemory.messages(truncated.memory)

      assert [%Normandy.Agents.ToolCallResponse{thinking: []}] =
               for(%{role: "assistant", content: c} <- messages, do: c)

      assert [%Normandy.Components.ToolResult{tool_call_id: "t1"}] =
               for(%{role: "tool", content: c} <- messages, do: c)

      assert Turn.unanswered_tool_calls(messages) == []
    end
```

In `test/context/summarizer_test.exs`, inside `describe "compress_conversation/3"`, add before
`test "the kept messages start at a user message, never an orphan tool result",`:

```elixir
    test "kept messages keep their stored structs", %{client: client} do
      agent = %{memory: memory_ending_in_thinking_round(), model: "test-model", config: %{}}

      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 3)

      messages = AgentMemory.messages(compressed.memory)

      assert [%Normandy.Agents.ToolCallResponse{thinking: []}] =
               for(%{role: "assistant", content: c} <- messages, do: c)

      assert [%Normandy.Components.ToolResult{tool_call_id: "t1"}] =
               for(%{role: "tool", content: c} <- messages, do: c)
    end
```

Three existing tests pin the old shapes. Change them as follows:

1. `test/components/agent_memory_test.exs:97`. Rename the test to
   `"history gives the default chat input and output to the model as their plain text"`, and change
   its expected assistant entry from `%{role: "assistant", content: "{\"chat_message\":\"Noted.\"}"}` to
   `%{role: "assistant", content: "Noted."}`.
2. `test/llm/claudio_adapter_thinking_test.exs:230`, test "thinking from a fallback model is
   not replayed to the requested model" (the third of four identical lines in the file; edit
   only this test's). Replace its last assertion
   `assert [%{"type" => "tool_use", "id" => "t1"}] = assistant["content"]` with:
   ```elixir
      # The turn is replayed as received (Claudio's continuation rules keep the
      # fallback block); the served model's thinking is stale and left out.
      assert [%{"type" => "fallback"}, %{"type" => "tool_use", "id" => "t1"}] =
               assistant["content"]
   ```
3. `test/behaviours/compactor_test.exs:75`, test "a kept message loses its thinking but keeps
   its id, and is not in meta.dropped". Replace
   `assert [%{type: "text", text: "answer"}] = result.memory.entries[last_id].content` with:
   ```elixir
      assert %Normandy.Agents.ToolCallResponse{content: "answer", thinking: []} =
               result.memory.entries[last_id].content
   ```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/assistant_turn_replay_test.exs test/agents/tool_call_response_test.exs test/components/stream_processor_test.exs test/context/window_manager_test.exs test/context/summarizer_test.exs test/components/agent_memory_test.exs test/llm/claudio_adapter_thinking_test.exs test/behaviours/compactor_test.exs`
Expected: FAIL.
- `tool_call_response_test.exs` does not compile: `unknown key :content_blocks`.
- The three replay tests get the rebuilt `[thinking, text, tool_use]`, with no server or MCP blocks.
- "an earlier chat answer" gets `{"chat_message":"Done."}`.
- The stream-processor tests keep inputs as `{}` and have no `"citations"`.
- The window-manager and summarizer struct tests get lists of maps.
- The three changed assertions fail against the old code.

- [ ] **Step 3: The field, and replay from it**

In `lib/normandy/agents/tool_call_response.ex`:

Append to the moduledoc (after the `:prefix_key` paragraph):

```
  `:content_blocks` holds the assistant turn as the API returned it: string-keyed,
  API-shaped blocks in their order (thinking, text with its citations, `tool_use`,
  `server_tool_use`, `mcp_tool_use` and their results), as
  `Claudio.Messages.Response.to_assistant_content/1` makes them. When it is not empty,
  the turn is replayed from it unchanged, so the next request carries exactly what the
  model produced; `:content`, `:tool_calls` and `:thinking` are what Normandy reads.
  A response built without it (by hand, or stored before it existed) is rebuilt from
  those three fields.
```

Add `alias Claudio.Messages.Response, as: ClaudioResponse` above
`alias Normandy.Components.ToolCall` (credo `--strict` flags the nested module calls otherwise;
`ClaudioResponse` keeps `Response` free for Task 5.3c's `Normandy.LLM.Response`). Add
`content_blocks: [map()]` to `@type t` (after `prefix_key:`), add
`field(:content_blocks, {:array, :map}, default: [])` after the `:prefix_key` field, and after
the `schema do ... end` block add:

```elixir
  @doc """
  `:content_blocks` for a response's content blocks given as maps (a streamed message's
  string-keyed blocks): `Claudio.Messages.Response.to_assistant_content/1` of them, so a
  streamed turn is replayed in the same shape as a non-streamed one.
  """
  @spec api_blocks([map()]) :: [map()]
  def api_blocks(blocks) when is_list(blocks) do
    %{"content" => blocks}
    |> ClaudioResponse.from_map()
    |> ClaudioResponse.to_assistant_content()
  end
```

In the `defimpl Normandy.Components.BaseIOSchema` block, replace `to_json/1` and rename the
private `content_blocks/1` to `rebuilt_blocks/1`:

```elixir
  def to_json(%Normandy.Agents.ToolCallResponse{} = response) do
    # Map.get: a response stored before :content_blocks existed has no key.
    case Map.get(response, :content_blocks, []) do
      [] -> response.thinking ++ rebuilt_blocks(response)
      blocks -> replayed_blocks(blocks, response.thinking)
    end
  end

  # The turn as the API returned it. Thinking dropped from the response
  # (AgentMemory.drop_thinking/1 empties :thinking) is left out here too. A client
  # tool_use whose input is not an object goes back as {}: the API requires an
  # object, and Dispatch refused the call and told the model.
  defp replayed_blocks(blocks, thinking) do
    blocks
    |> Enum.reject(&(thinking == [] and thinking_block?(&1)))
    |> Enum.map(&object_input/1)
  end

  defp thinking_block?(%{"type" => type}), do: type in ["thinking", "redacted_thinking"]
  defp thinking_block?(_block), do: false

  defp object_input(%{"type" => "tool_use", "input" => input} = block) when not is_map(input),
    do: %{block | "input" => %{}}

  defp object_input(block), do: block

  # Thinking blocks first, as the API returned them, then the text and tool calls.
  defp rebuilt_blocks(%{content: content, tool_calls: tool_calls}) do
```

(the rest of the old `content_blocks/1` body stays unchanged as `rebuilt_blocks/1`'s body).

`AgentMemory.drop_thinking/1`, `has_thinking?/1` and `drop_stale_thinking/2` need no change.
They work on `:thinking`, and `to_json/1` drops the thinking blocks from `content_blocks`
whenever `:thinking` is `[]`.

- [ ] **Step 4: Both shells fill it**

In `lib/normandy/llm/claudio_adapter.ex`, `populate_tool_call_response/3` ends:

```elixir
      schema
      |> Map.put(:content, content)
      |> Map.put(:tool_calls, tool_calls)
      |> Map.put(:thinking, ClaudioAdapter.extract_thinking(claudio_response))
      |> Map.put(
        :content_blocks,
        Claudio.Messages.Response.to_assistant_content(claudio_response)
      )
```

This covers the legacy path and, after Task 5.1, the structured path through `handle_structured/3`.

In `lib/normandy/agents/base_agent.ex`, in `build_streaming_assistant_response/2`, the struct becomes:

```elixir
    %ToolCallResponse{
      content: if(text == "", do: nil, else: text),
      tool_calls: calls,
      thinking: ToolCallResponse.thinking_blocks(content),
      prefix_key: Map.get(response, :prefix_key),
      content_blocks: ToolCallResponse.api_blocks(content)
    }
```

- [ ] **Step 5: StreamProcessor keeps server and MCP inputs and citations**

In `lib/normandy/components/stream_processor.ex`, after `alias Normandy.LLMError` add:

```elixir
  # Blocks whose input arrives as input_json_delta: client tool calls, and the server
  # and MCP tool calls the API runs (replayed as they streamed).
  @tool_use_types ["tool_use", "server_tool_use", "mcp_tool_use"]
```

Replace the `content_block_delta` clause of `process_event/2` with:

```elixir
  defp process_event(%{type: "content_block_delta", delta: delta, index: index}, acc),
    do: %{acc | content: apply_delta(acc.content || [], index, delta)}
```

and add after `defp process_event(_, acc), do: acc`:

```elixir
  defp apply_delta(content, index, %{"type" => "text_delta", "text" => text}),
    do: append_text_delta(content, index, text)

  defp apply_delta(content, index, %{"type" => "input_json_delta", "partial_json" => json}),
    do: append_json_delta(content, index, json)

  defp apply_delta(content, index, %{"type" => "thinking_delta", "thinking" => text}),
    do: update_block(content, index, "thinking", &((&1 || "") <> text))

  defp apply_delta(content, index, %{"type" => "signature_delta", "signature" => signature}),
    do: update_block(content, index, "signature", fn _ -> signature end)

  # A text block's citations arrive one per delta, in order.
  defp apply_delta(content, index, %{"type" => "citations_delta", "citation" => citation}),
    do: update_block(content, index, "citations", &((&1 || []) ++ [citation]))

  defp apply_delta(content, _index, _delta), do: content
```

In the `content_block_stop` clause, replace the comment and the first `List.update_at` pattern:

```elixir
  # A finished tool_use, server_tool_use or mcp_tool_use block's accumulated JSON is
  # decoded. Input that does not decode to an object stays a string; Dispatch refuses
  # a client tool_use with such input and tells the model.
  defp process_event(%{type: "content_block_stop", index: index}, acc) do
    content =
      List.update_at(acc.content || [], index, fn
        %{"type" => type, "input" => json} = block
        when type in @tool_use_types and is_binary(json) ->
          %{block | "input" => decode_tool_input(json)}
```

In `append_json_delta/3`, the first two patterns become:

```elixir
      %{"type" => type, "input" => existing} = block
      when type in @tool_use_types and is_binary(existing) ->
        %{block | "input" => existing <> partial_json}

      %{"type" => type} = block when type in @tool_use_types ->
        Map.put(block, "input", partial_json)
```

`BaseAgent.extract_tool_calls/1` still filters `"tool_use"`, so a streamed server or MCP call
is never dispatched.

- [ ] **Step 6: The chat answer is replayed as its text (AX-21)**

In `lib/normandy/components/agent_memory.ex`, add between the input-side `model_content/1`
clause and `defp model_content(content), do: BaseIOSchema.to_json(content)`:

```elixir
  # The default chat output, likewise: an earlier answer replayed as
  # {"chat_message": ...} JSON taught the model to answer in JSON (AX-21).
  defp model_content(%Normandy.Agents.BaseAgentOutputSchema{chat_message: text})
       when is_binary(text),
       do: text
```

- [ ] **Step 7: Compaction keeps the stored content**

`lib/normandy/context/window_manager.ex`, `rebuild_memory/2`. Replace the comment and the
`AgentMemory.add_message` line inside the `Enum.reduce`:

```elixir
    # Add messages in chronological order, each under its original turn and entry id
    # (a compactor reports what it dropped by entry id), with their stored content (a
    # %ToolCallResponse{} or %ToolResult{} stays one, so the turn still sees the kept
    # batch). Their thinking was produced after the removed messages, so it no longer
    # applies.
    Enum.reduce(kept, memory, fn {msg, entry}, mem ->
      AgentMemory.add_message(mem, msg.role, AgentMemory.drop_thinking(entry.content),
```

`lib/normandy/context/summarizer.ex`, `rebuild_memory_with_summary/4`. Same edit:

```elixir
    # Add recent messages in chronological order, each under its original turn and
    # entry id, with its stored content (not the serialized history). The summary
    # (added above) takes current_turn_id and a new id. Their thinking was produced
    # before the summary existed, so it no longer applies.
    Enum.reduce(recent_messages, memory, fn {msg, entry}, mem ->
      AgentMemory.add_message(mem, msg.role, AgentMemory.drop_thinking(entry.content),
```

(the `turn_id:`/`id:` options that follow are unchanged in both).

- [ ] **Step 8: Model protocol doc**

In `lib/normandy/agents/model.ex`, "## Response content", replace
"and `%Normandy.Agents.ToolCallResponse{}` gets `:content`, `:tool_calls` and `:thinking`." with:

```
  and `%Normandy.Agents.ToolCallResponse{}` gets `:content`, `:tool_calls`, `:thinking` and
  `:content_blocks` (the assistant turn as string-keyed, API-shaped blocks, replayed unchanged
  on the next request; leave it `[]` and the turn is rebuilt from the other three).
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/assistant_turn_replay_test.exs test/agents/tool_call_response_test.exs test/components/stream_processor_test.exs test/context/ test/components/agent_memory_test.exs test/llm/claudio_adapter_thinking_test.exs test/behaviours/compactor_test.exs test/agents/base_agent_streaming_test.exs`
Expected: PASS.

- [ ] **Step 10: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.3b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.3b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 11: MIGRATING-2.0.md**

Append to `## 33.`:

```markdown
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
```

- [ ] **Step 12: Commit**

```bash
git add lib/normandy/agents/tool_call_response.ex lib/normandy/llm/claudio_adapter.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/components/stream_processor.ex \
  lib/normandy/components/agent_memory.ex lib/normandy/context/window_manager.ex \
  lib/normandy/context/summarizer.ex lib/normandy/agents/model.ex MIGRATING-2.0.md \
  test/agents/assistant_turn_replay_test.exs test/agents/tool_call_response_test.exs \
  test/components/stream_processor_test.exs test/context/window_manager_test.exs \
  test/context/summarizer_test.exs test/components/agent_memory_test.exs \
  test/llm/claudio_adapter_thinking_test.exs test/behaviours/compactor_test.exs
git commit -m "fix(agents): assistant turns are replayed as received"
```

---

### Task 5.3c: `pause_turn` continues the turn; MCP-only agents run the tool loop (R3, Q4, Q7)

The decision lives in the pure core, so `Turn.Driver` (`run/3` and `stream/3`), `Turn.Inline`
and `Turn.Server` all inherit it. No new effect is added: a paused response is a tool batch with
no results. It appends the assistant turn, spends one iteration, persists, passes the steering
boundary and calls the LLM again. No user message is added after the paused turn.

**Files:**
- Modify: `lib/normandy/llm/response.ex` (`@doc false stop_reason/1`)
- Modify: `lib/normandy/agents/tool_call_response.ex` (field `stop_reason`, moduledoc)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`populate_tool_call_response/3`)
- Modify: `lib/normandy/agents/base_agent.ex` (alias `Normandy.LLM.Response`; `turn_response_model/1`; `build_streaming_assistant_response/2`; new `stream_stop_reason/1`)
- Modify: `lib/normandy/agents/turn.ex` (`:assistant_streaming` clause; new `finalize/2`, `continue_paused/2`, `paused?/1`; moduledoc)
- Modify: `lib/normandy/agents/model.ex` (moduledoc "Response content")
- Modify: `MIGRATING-2.0.md` (`## 33.`)
- Test: create `test/agents/pause_turn_test.exs`

**Interfaces:**
- Consumes: `ToolCallResponse.content_blocks` (Task 5.3b: a paused turn's `server_tool_use`/`mcp_tool_use` blocks are replayed). `extract_tool_uses/1` returns `tool_use` only (Task 5.3a: an `mcp_tool_use` in a paused turn is not dispatched). `WireScript` (Task 5.1).
- Produces: `ToolCallResponse.stop_reason` (header; type per Header conflict 1); `Normandy.LLM.Response.stop_reason/1` (`@doc false`); the core continues `stop_reason` `:pause_turn` or `"pause_turn"`, read with `Map.get/2` (the 78 injected `call_llm` handlers return structs without it, which are never paused). `BaseAgent.turn_response_model/1` returns `%ToolCallResponse{}` for `mcp_servers` too.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/pause_turn_test.exs`:

```elixir
defmodule Normandy.Agents.PauseTurnTest do
  @moduledoc """
  Task 5.3c: a `pause_turn` response is sent back as it is, with no user message after
  it, and the model continues the turn; on the pure core, `Turn.Inline`, `run/3`,
  `stream/3` and `Turn.Server`. An agent with MCP servers and no tools of its own runs
  the tool-loop response model, so its connector turns reach the loop.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Claudio.Messages.Response, as: ClaudioResponse
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Inline
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.LLM.Request
  alias Normandy.MCP.ServerConfig
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @search %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_1",
    "name" => "web_search",
    "input" => %{"query" => "paris weather"}
  }
  @searching %{"type" => "text", "text" => "Searching."}
  @paused [@searching, @search]
  @result %{
    "type" => "web_search_tool_result",
    "tool_use_id" => "srvtoolu_1",
    "content" => [
      %{
        "type" => "web_search_result",
        "url" => "https://e.com",
        "title" => "P",
        "encrypted_content" => "e"
      }
    ]
  }
  @sunny %{"type" => "text", "text" => "Sunny."}

  defp paused_replay,
    do:
      %{"content" => @paused}
      |> ClaudioResponse.from_map()
      |> ClaudioResponse.to_assistant_content()

  # The continuation: the user turn, then the paused assistant turn as it came, last.
  defp assert_continued do
    assert_received {:wire_body, 1, body}

    assert [%{"role" => "user"}, %{"role" => "assistant", "content" => content}] =
             body["messages"]

    assert content == paused_replay()
    refute_received {:wire_body, 2, _}
  end

  defp tool_agent(client) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      toolset: Toolset.new([%FakeTool{notify: self()}])
    })
  end

  describe "the core" do
    defp running(max) do
      {s, _} =
        Turn.step(Turn.new(max_iterations: max, response_model: :rm, output_schema: :os), :start)

      {s, _} = Turn.step(s, {:compaction_done, %{compacted: false}})
      s
    end

    for reason <- [:pause_turn, "pause_turn"] do
      test "a #{inspect(reason)} response is appended and the turn goes on" do
        resp = %{content: "Searching.", tool_calls: [], stop_reason: unquote(reason)}
        {s, effects} = Turn.step(running(3), {:llm_response, resp})

        assert s.status == :steering
        assert s.iterations_left == 2

        assert [
                 {:append_message, "assistant", ^resp},
                 {:persist, ^s},
                 {:emit_event, :steering, %{iterations_left: 2}},
                 {:maybe_compact, %{iterations_left: 2}}
               ] = effects

        assert {_s, [_iteration, {:call_llm, %{response_model: :rm, final: false}}]} =
                 Turn.step(s, {:compaction_done, %{compacted: false}})
      end
    end

    test "a response without :stop_reason finishes as before" do
      {s, effects} =
        Turn.step(
          running(3),
          {:llm_response, %ToolCallResponse{content: "hi"} |> Map.delete(:stop_reason)}
        )

      assert s.status == :finalizing
      assert [{:convert_output, _, :os}] = effects
    end

    test "a model that keeps pausing reaches the forced final call" do
      paused = %{tool_calls: [], stop_reason: :pause_turn}
      {s, _} = Turn.step(running(1), {:llm_response, paused})

      assert {_s, [_iteration, {:call_llm, %{response_model: :os, final: true}}]} =
               Turn.step(s, {:compaction_done, %{compacted: false}})
    end

    test "Turn.Inline continues a paused turn" do
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      deps = %{
        call_llm: fn _request ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 -> {:ok, %ToolCallResponse{content: "Searching.", stop_reason: :pause_turn}}
            1 -> {:ok, %ToolCallResponse{content: "Sunny.", stop_reason: :end_turn}}
          end
        end,
        dispatch: fn _calls -> flunk("a paused turn dispatches nothing") end,
        append: fn role, content -> send(test_pid, {:appended, role, content}) end
      }

      state = Turn.new(max_iterations: 3, response_model: :rm, output_schema: :os)
      assert {:ok, final} = Inline.run(state, deps)
      assert %ToolCallResponse{content: "Sunny."} = final.final_response
      assert_received {:appended, "assistant", %ToolCallResponse{stop_reason: :pause_turn}}
    end
  end

  describe "a paused server-tool turn" do
    test "run/3 sends it back unchanged and returns the continued answer" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      assert {:ok, config, %{chat_message: "Sunny."}} =
               BaseAgent.run(tool_agent(client), "weather?")

      assert_continued()
      refute_received {:tool_ran, _}

      assert [%ToolCallResponse{stop_reason: :pause_turn}] =
               for(
                 %{role: "assistant", content: %ToolCallResponse{} = r} <-
                   AgentMemory.messages(config.memory),
                 do: r
               )
    end

    test "stream/3 sends it back unchanged and returns the continued answer" do
      paused =
        WireScript.message(
          "msg_0",
          WireScript.block(0, %{"type" => "text", "text" => ""}, [
            %{"type" => "text_delta", "text" => "Searching."}
          ]) ++
            WireScript.block(1, %{@search | "input" => %{}}, [
              %{"type" => "input_json_delta", "partial_json" => ~s({"query": "paris weather"})}
            ]),
          "pause_turn"
        )

      continued =
        WireScript.message(
          "msg_1",
          WireScript.block(0, @result, []) ++
            WireScript.block(1, %{"type" => "text", "text" => ""}, [
              %{"type" => "text_delta", "text" => "Sunny."}
            ]),
          "end_turn"
        )

      client = WireScript.client([{:sse, paused}, {:sse, continued}])

      assert {:ok, _config, %{chat_message: "Sunny."}} =
               BaseAgent.stream(tool_agent(client), "weather?", fn _ -> :ok end)

      assert_continued()
    end

    test "Turn.Server sends it back unchanged and stores the paused turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-pause",
          config: tool_agent(client),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:ok, %{chat_message: "Sunny."}} = Server.run(srv, "weather?")
      assert_continued()

      assert {:ok, entries} = InMemory.history(store, "s-pause")

      assert [%ToolCallResponse{stop_reason: :pause_turn}, _final] =
               for(%{role: "assistant", content: c} <- entries, do: c)
    end
  end

  describe "an agent with MCP servers and no tools of its own" do
    defp mcp_agent(client) do
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        mcp_servers: [ServerConfig.new("docs", "https://mcp.example.com/sse")]
      })
    end

    test "runs the tool-loop response model" do
      assert %ToolCallResponse{} = BaseAgent.turn_response_model(mcp_agent(%StubClient{}))

      assert %Normandy.Agents.BaseAgentOutputSchema{} =
               BaseAgent.turn_response_model(BaseAgent.init(%{client: %StubClient{}, model: "m"}))
    end

    test "run/3 asks for a ToolCallResponse; a chat agent's prompt shows no output schema" do
      client = %StubClient{notify: self(), reply: fn rm -> %{rm | content: "Hi."} end}

      assert {:ok, _config, %{chat_message: "Hi."}} = BaseAgent.run(mcp_agent(client), "hi")

      assert_receive {:converse, %Request{response_model: %ToolCallResponse{}} = request, _}
      refute request.system =~ "# OUTPUT SCHEMA"
      assert [%ServerConfig{}] = request.mcp_servers
    end

    test "run/3 continues a paused connector turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      assert {:ok, _config, %{chat_message: "Sunny."}} =
               BaseAgent.run(mcp_agent(client), "weather?")

      assert_continued()
    end

    test "Turn.Server continues a paused connector turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      {:ok, srv} =
        Server.start_link(
          session_id: "s-pause-mcp",
          config: mcp_agent(client),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:ok, %{chat_message: "Sunny."}} = Server.run(srv, "weather?")
      assert_continued()
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/pause_turn_test.exs`
Expected: FAIL. The file does not compile: `unknown key :stop_reason for struct Normandy.Agents.ToolCallResponse`.
Without the core change, a paused turn would end with `"Searching."` as the final answer,
because `tool_calls` is `[]`.

- [ ] **Step 3: The stop reason on the response**

In `lib/normandy/llm/response.ex`, after `@type t`, add:

```elixir
  @known_stop_reasons [
    :end_turn,
    :tool_use,
    :max_tokens,
    :stop_sequence,
    :pause_turn,
    :refusal,
    :model_context_window_exceeded,
    :compaction
  ]

  @doc false
  # A stop reason in this struct's form: a streamed one (a string in message_delta)
  # becomes its atom when Normandy knows it; an unknown one stays the provider's string.
  @spec stop_reason(atom() | String.t()) :: stop_reason() | nil
  def stop_reason(reason) when is_atom(reason), do: reason

  def stop_reason(reason) when is_binary(reason),
    do: Enum.find(@known_stop_reasons, reason, &(Atom.to_string(&1) == reason))
```

In `lib/normandy/agents/tool_call_response.ex`, append to the moduledoc:

```
  `:stop_reason` is why the model stopped (`t:Normandy.LLM.Response.stop_reason/0`), or
  `nil` when the client did not say. The turn continues a `:pause_turn` response. It is
  never sent to the API.
```

Add `stop_reason: Normandy.LLM.Response.stop_reason() | nil` to `@type t`, and
`field(:stop_reason, :any, default: nil)` after the `:content_blocks` field. `to_json/1` does
not read the field, so it is never serialized.

In `lib/normandy/llm/claudio_adapter.ex`, `populate_tool_call_response/3`, add after the
`:content_blocks` put: `|> Map.put(:stop_reason, claudio_response.stop_reason)`.

In `lib/normandy/agents/base_agent.ex`, add `alias Normandy.LLM.Response` after
`alias Normandy.LLM.ParseFailure`. In `build_streaming_assistant_response/2`, add
`stop_reason: stream_stop_reason(Map.get(response, :stop_reason))` after `content_blocks:`. After
`defp build_streaming_assistant_response(other, _), do: other` add:

```elixir
  defp stream_stop_reason(nil), do: nil
  defp stream_stop_reason(reason), do: Response.stop_reason(reason)
```

(`%Normandy.LLM.Response{...}` literals elsewhere in `base_agent.ex` stay fully qualified. They
still compile, and credo flags only nested function calls.)

- [ ] **Step 4: The core continues a paused turn**

In `lib/normandy/agents/turn.ex`, replace the `[] ->` branch of
`step(%State{status: :assistant_streaming} = s, {:llm_response, resp})` (the non-final clause)
with:

```elixir
      [] ->
        if paused?(resp), do: continue_paused(s, resp), else: finalize(s, resp)
```

and add after `apply_tool_results/2`:

```elixir
  defp finalize(s, resp) do
    s = %{s | status: :finalizing, last_response: resp, stop_reason: :completed}

    if convert_needed?(s) do
      {s, [{:convert_output, resp, s.output_schema}]}
    else
      {s, [{:validate_output, resp}]}
    end
  end

  # The API paused a long server-tool turn (stop_reason pause_turn). The paused turn is
  # appended as it is and sent back with no user message after it, for the model to
  # continue: a batch with no results, so it spends one iteration (a model that keeps
  # pausing reaches the forced final call) and passes the steering boundary.
  defp continue_paused(s, resp) do
    {s2, effects} = apply_tool_results(%{s | last_response: resp}, [])
    {s2, [{:append_message, "assistant", resp} | effects]}
  end

  # Map.get: the response may be any term a call_llm handler returned, and a struct
  # without :stop_reason (a test double, a pre-2.0 ToolCallResponse) is not paused.
  defp paused?(%{} = resp), do: Map.get(resp, :stop_reason) in [:pause_turn, "pause_turn"]
  defp paused?(_resp), do: false
```

A response with tool calls is dispatched as before, whatever its stop reason. The
`awaiting_final: true` clause (the forced final call) is not changed: a pause there is finalized
like any other final response (see Notes). Append to the Turn moduledoc:

```
  A response whose `stop_reason` is `:pause_turn` (the API paused a long server-tool
  or MCP-connector turn) and that has no tool calls is appended and sent back as it
  is, with no user message after it, for the model to continue; it spends one
  iteration, like a tool batch.
```

The stream path needs no change. The core receives the streamed message map, whose
`:stop_reason` is the string `"pause_turn"`. `append_stream_message/3` stores it as a
`%ToolCallResponse{}` with the atom stop reason and its `content_blocks`.

- [ ] **Step 5: An agent with MCP servers runs the tool loop's response model (Q7)**

In `lib/normandy/agents/base_agent.ex`, replace `turn_response_model/1`:

```elixir
  @doc false
  # The tool-loop response model for an agent with tools or MCP servers: an MCP
  # connector's turn (mcp_tool_use blocks, a pause_turn) needs the loop's response
  # shape and replay even when the agent has no tools of its own.
  def turn_response_model(config) do
    if has_tools?(config) or Map.get(config, :mcp_servers) not in [nil, []] do
      %Normandy.Agents.ToolCallResponse{}
    else
      config.output_schema
    end
  end
```

`Turn.Server.start_turn/5` (`server.ex:918`) calls the same function, so no change is needed
there. Such an agent sends no `tools`. After Task 5.1, its call is constrained by
`output_format` (a non-chat schema) or unconstrained (chat).

- [ ] **Step 6: Model protocol doc**

In `lib/normandy/agents/model.ex`, replace "`:thinking` and `:content_blocks` (" (Task 5.3b's
text) with "`:thinking`, `:stop_reason` (the response's, so a `:pause_turn` is continued) and
`:content_blocks` (".

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/pause_turn_test.exs test/agents/turn_test.exs test/agents/turn_inline_test.exs test/agents/turn_property_test.exs test/agents/turn/server_test.exs test/agents/base_agent_streaming_test.exs`
Expected: PASS (`pause_turn_test.exs`: 12 tests).

- [ ] **Step 8: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.3c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.3c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 9: MIGRATING-2.0.md**

Append to `## 33.`:

```markdown
- A `pause_turn` response (the API paused a long server-tool or MCP-connector turn) is appended
  and sent back as it is, with no user message after it, and the model continues the turn. Each
  continuation spends one of `max_tool_iterations`. The paused turn's partial text used to be
  returned as the final answer. A pause on the forced final call (`max_tool_iterations` spent)
  is not continued.
- `%Normandy.Agents.ToolCallResponse{}` has a new field `stop_reason`
  (`t:Normandy.LLM.Response.stop_reason/0` or `nil`), filled by `ClaudioAdapter` and the stream
  path. It is never sent to the API. A custom `Model` that wants `pause_turn` continued sets it.
- An agent with `mcp_servers` and no tools of its own now runs the tool loop's response model
  (`%ToolCallResponse{}`), so its connector turns are replayed and continued like a tool-using
  agent's. With the chat schema, its system prompt no longer shows an output schema and its
  answer is plain text. It used to be `{"chat_message": ...}` JSON constrained by structured
  outputs.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/llm/response.ex lib/normandy/agents/tool_call_response.ex \
  lib/normandy/llm/claudio_adapter.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/agents/turn.ex lib/normandy/agents/model.ex MIGRATING-2.0.md \
  test/agents/pause_turn_test.exs
git commit -m "feat(agents): continue a pause_turn; MCP-only agents run the tool loop"
```

---

---

### Task 5.2a: `max_tokens` and `refusal` are errors on every path (AX-4, AX-10)

**Files:**
- Modify: `lib/normandy/llm/error.ex` (types `:max_tokens`, `:refusal`; moduledoc)
- Modify: `lib/normandy/llm/call.ex` (`stop_reason/1`, `check_stop_reason/1`, `converse/3` runs the check)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`@incomplete_stop_reasons` and an incomplete clause in `converse_legacy/4` and `converse_structured/4`; `__incomplete_response__/2`; the incomplete clause of `__handle_structured_response__/3`; moduledoc)
- Modify: `lib/normandy/llm/openai_compatible_adapter.ex` (`populate/4`)
- Modify: `lib/normandy/llm/json_deserializer.ex` (a JSON retry's error hands its usage back)
- Modify: `lib/normandy/agents/base_agent.ex` (`stream_llm_attempt/4` gate; `run/3` and `stream/3` docs)
- Modify: `lib/normandy/agents/model.ex` (moduledoc "Response content")
- Modify: `MIGRATING-2.0.md` (`## 32.`, created by Task 5.1)
- Test: create `test/llm/call_stop_reason_test.exs`, `test/agents/stop_reason_test.exs`, `test/llm/claudio_adapter_stop_reason_test.exs`; modify `test/llm/claudio_adapter_test.exs` (describe "structured response interpretation"), `test/llm/openai_compatible_adapter_test.exs`

**Interfaces:**
- Consumes (Task 5.1): `ClaudioAdapter.Model.converse/3` routes tool-bearing calls with `output_format` to `converse_structured/4`. Task 5.1 may restructure the body of the `{:ok, response}` branch in `converse_structured/4` and `converse_legacy/4`. This task only **inserts a clause before** that branch, so it does not depend on the body. (Task 5.3c): the core reads `Map.get(resp, :stop_reason)` for `:pause_turn`. This task makes the streamed message's `:stop_reason` an atom for the known API reasons (through 5.3c's `Response.stop_reason/1`), and a `:pause_turn`/`"pause_turn"` check still matches.
- Produces: `LLMError` types `:max_tokens`, `:refusal` (`retryable?: false`, `reason: {:stop_reason, atom}`, billed `usage`); `Normandy.LLM.Call.check_stop_reason/1 :: {:ok, response} | {:error, LLMError.t()}` and `Call.stop_reason/1` (both `@doc false`). Exact messages:
  - `"LLM call failed: max_tokens: the response stopped at max_tokens before it was complete; raise the agent's max_tokens or ask for a shorter answer"`
  - `"LLM call failed: max_tokens: the response stopped at model_context_window_exceeded: the conversation filled the model's context window; compact or shorten the history"`
  - `"LLM call failed: refusal: the model declined to answer (stop_reason refusal)"`

No new telemetry event or metadata key. `error.type` already reports an `LLMError`'s type (`telemetry.ex:359`), so the new types appear as `max_tokens`/`refusal`.

- [ ] **Step 1: Write the failing tests**

Create `test/llm/call_stop_reason_test.exs`:

```elixir
defmodule Normandy.LLM.CallStopReasonTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.LLM.{Call, Request, Response}
  alias Normandy.LLMError
  alias Normandy.Test.StubClient

  @usage %{"input_tokens" => 10, "output_tokens" => 64}

  defp response(stop_reason),
    do: %Response{content: "cut off mid-sent", stop_reason: stop_reason, usage: @usage}

  describe "check_stop_reason/1" do
    test "max_tokens is a :max_tokens LLMError that keeps the billed usage and no model text" do
      assert {:error, %LLMError{} = error} = Call.check_stop_reason(response(:max_tokens))

      assert error.type == :max_tokens
      assert error.retryable? == false
      assert error.status == nil
      assert error.reason == {:stop_reason, :max_tokens}
      assert error.usage == @usage
      assert error.usage_counts.output_tokens == 64

      assert error.message ==
               "LLM call failed: max_tokens: the response stopped at max_tokens before it " <>
                 "was complete; raise the agent's max_tokens or ask for a shorter answer"

      refute inspect(error) =~ "cut off mid-sent"
    end

    test "model_context_window_exceeded is a :max_tokens LLMError whose detail names it" do
      assert {:error, %LLMError{type: :max_tokens, reason: reason, message: message}} =
               Call.check_stop_reason(response(:model_context_window_exceeded))

      assert reason == {:stop_reason, :model_context_window_exceeded}

      assert message ==
               "LLM call failed: max_tokens: the response stopped at " <>
                 "model_context_window_exceeded: the conversation filled the model's " <>
                 "context window; compact or shorten the history"
    end

    test "refusal is a :refusal LLMError" do
      assert {:error, %LLMError{type: :refusal, retryable?: false} = error} =
               Call.check_stop_reason(response(:refusal))

      assert error.reason == {:stop_reason, :refusal}

      assert error.message ==
               "LLM call failed: refusal: the model declined to answer (stop_reason refusal)"
    end

    test "the streamed string form is checked like the atom" do
      assert {:error, %LLMError{type: :max_tokens}} =
               Call.check_stop_reason(%{stop_reason: "max_tokens", usage: nil})

      assert {:error, %LLMError{type: :refusal, usage: nil}} =
               Call.check_stop_reason(%{stop_reason: "refusal"})
    end

    test "a complete or unknown stop reason passes the response through unchanged" do
      for reason <- [:end_turn, :tool_use, :stop_sequence, :pause_turn, nil, "a_future_reason"] do
        resp = response(reason)
        assert Call.check_stop_reason(resp) == {:ok, resp}
      end
    end
  end

  describe "stop_reason/1" do
    test "maps the API's strings onto Response's atoms and leaves others as strings" do
      assert Call.stop_reason("max_tokens") == :max_tokens
      assert Call.stop_reason("model_context_window_exceeded") == :model_context_window_exceeded
      assert Call.stop_reason("end_turn") == :end_turn
      assert Call.stop_reason("a_future_reason") == "a_future_reason"
      assert Call.stop_reason(:refusal) == :refusal
      assert Call.stop_reason(nil) == nil
    end
  end

  describe "converse/3" do
    test "an adapter's {:ok, response} cut off at max_tokens becomes the error" do
      client = %StubClient{
        reply: fn rm ->
          {:ok,
           %Response{
             content: %{rm | chat_message: "partial"},
             stop_reason: :max_tokens,
             usage: @usage
           }}
        end
      }

      request = %Request{
        model: "m",
        max_tokens: 8,
        messages: [],
        response_model: %BaseAgentOutputSchema{}
      }

      assert {:error, %LLMError{type: :max_tokens, usage: @usage}} =
               Call.converse(client, request, [])
    end
  end
end
```

Create `test/agents/stop_reason_test.exs` (sync, `Turn.Server`, `stream/3`; Review Focus #2):

```elixir
defmodule Normandy.Agents.StopReasonTest do
  @moduledoc """
  A response cut off at max_tokens (or context-window exhaustion) or refused is an
  error on every turn path, before the core sees it: no tool runs, nothing is appended.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Components.ToolCall
  alias Normandy.LLM.Response
  alias Normandy.LLMError
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture

  # The first call's tool_use was cut off mid-input.
  defp cut_off_tool_call(stop_reason) do
    fn
      %ToolCallResponse{} = rm ->
        {:ok,
         %Response{
           content: %{
             rm
             | tool_calls: [%ToolCall{id: "toolu_1", name: "weather", input: %{"city" => "Par"}}]
           },
           stop_reason: stop_reason,
           usage: %{"input_tokens" => 5, "output_tokens" => 7}
         }}
    end
  end

  defp tool_agent(stop_reason, extra \\ %{}) do
    %{
      client: %StubClient{notify: self(), reply: cut_off_tool_call(stop_reason)},
      model: "m",
      max_tokens: 64
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%FakeTool{notify: self()})
  end

  describe "run/3 (sync)" do
    test "a tool_use cut off at max_tokens is an error and the tool never runs" do
      assert {:error, %LLMError{type: :max_tokens, reason: {:stop_reason, :max_tokens}}} =
               BaseAgent.run(tool_agent(:max_tokens), "weather in Paris?")

      assert_received {:converse, _request, _opts}
      refute_received {:converse, _request, _opts}
      refute_received {:tool_ran, _}
    end

    test "context-window exhaustion is the :max_tokens error, naming the reason" do
      assert {:error, %LLMError{type: :max_tokens} = error} =
               BaseAgent.run(tool_agent(:model_context_window_exceeded), "weather?")

      assert error.reason == {:stop_reason, :model_context_window_exceeded}
      refute_received {:tool_ran, _}
    end

    test "a refusal is the :refusal error" do
      assert {:error, %LLMError{type: :refusal}} =
               BaseAgent.run(tool_agent(:refusal), "weather?")

      refute_received {:tool_ran, _}
    end

    test "a truncated chat answer (no tools) is an error, not a partial success" do
      agent =
        BaseAgent.init(%{
          client: %StubClient{
            reply: fn rm ->
              {:ok,
               %Response{content: %{rm | chat_message: "The answer is"}, stop_reason: :max_tokens}}
            end
          },
          model: "m"
        })

      assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "question")
    end

    test "is neither retried nor counted by the circuit breaker" do
      agent =
        tool_agent(:max_tokens, %{
          retry: [max_attempts: 3, base_delay: 0, max_delay: 0, jitter: false],
          circuit_breaker: [failure_threshold: 1, scope: {__MODULE__, :not_counted}]
        })

      assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "a")
      assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "b")

      # One request per run: no retry, and the breaker (threshold 1) never opened.
      assert_received {:converse, _, _}
      assert_received {:converse, _, _}
      refute_received {:converse, _, _}
    end
  end

  describe "Turn.Server" do
    test "replies the bare :max_tokens LLMError and stores no assistant row" do
      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-max-tokens",
          config: tool_agent(:max_tokens),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:error, %LLMError{type: :max_tokens}} = Server.run(srv, %{chat_message: "go"})
      refute_received {:tool_ran, _}

      {:ok, entries} = InMemory.history(store, "s-max-tokens")
      assert Enum.map(entries, & &1.role) == ["user"]
    end
  end

  # Streams a tool_use whose input is cut off, then stops with `stop_reason`.
  defmodule CutOffStream do
    defstruct stop_reason: "max_tokens", options: %{}

    defimpl Normandy.Agents.Model do
      def converse(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}

      def stream(client, _request, _opts) do
        {:ok,
         [
           %{
             type: "message_start",
             message: %{"id" => "msg_1", "model" => "m", "role" => "assistant"}
           },
           %{
             type: "content_block_start",
             index: 0,
             content_block: %{"type" => "text", "text" => ""}
           },
           %{
             type: "content_block_delta",
             index: 0,
             delta: %{"type" => "text_delta", "text" => "Checking"}
           },
           %{type: "content_block_stop", index: 0},
           %{
             type: "content_block_start",
             index: 1,
             content_block: %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "weather",
               "input" => %{}
             }
           },
           %{
             type: "content_block_delta",
             index: 1,
             delta: %{"type" => "input_json_delta", "partial_json" => ~s({"city": "Pa)}
           },
           %{type: "content_block_stop", index: 1},
           %{
             type: "message_delta",
             delta: %{"stop_reason" => client.stop_reason},
             usage: %{"output_tokens" => 64}
           },
           %{type: "message_stop"}
         ]}
      end
    end
  end

  describe "stream/3" do
    test "a streamed tool_use cut off at max_tokens is an error; delivered text stays delivered" do
      agent =
        %{client: %CutOffStream{}, model: "m", max_tokens: 64}
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%FakeTool{notify: self()})

      test_pid = self()

      assert {:error, %LLMError{type: :max_tokens, usage: %{"output_tokens" => 64}}} =
               BaseAgent.stream(agent, "weather?", &send(test_pid, {:event, &1}))

      assert_received {:event, %StreamEvent{type: :text_delta, data: "Checking"}}
      refute_received {:tool_ran, _}
    end

    test "a streamed refusal is the :refusal error" do
      agent = BaseAgent.init(%{client: %CutOffStream{stop_reason: "refusal"}, model: "m"})

      assert {:error, %LLMError{type: :refusal}} =
               BaseAgent.stream(agent, "weather?", fn _ -> :ok end)
    end

    test "the error ends the llm_call span as :exception" do
      agent = BaseAgent.init(%{client: %CutOffStream{}, model: "m"})

      ref =
        TelemetryCapture.attach(
          [[:normandy, :agent, :llm_call, :exception]],
          fn _ -> true end
        )

      BaseAgent.stream(agent, "weather?", fn _ -> :ok end)

      assert_received {:telemetry, ^ref, _, %{reason: %LLMError{type: :max_tokens}}}
    end
  end
end
```

Create `test/llm/claudio_adapter_stop_reason_test.exs` (wire level, AX-10; the last test covers Task 5.1's tool-loop calls routed to `converse_structured/4` with `output_format`, X2):

```elixir
defmodule Normandy.LLM.ClaudioAdapterStopReasonTest do
  @moduledoc """
  AX-10: a response that stopped at max_tokens or refusal is never parsed, re-asked or
  turned into chat_message text; Normandy.LLM.Call makes it the error.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.{Request, Response}
  alias Normandy.LLMError
  alias Normandy.Test.FakeTool

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true)
    end
  end

  # Every request body goes to the test process; every reply is cut off.
  defp stub(name, stop_reason) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [%{"type" => "text", "text" => ~s({"action": "appr)}],
        "stop_reason" => stop_reason,
        "usage" => %{"input_tokens" => 3, "output_tokens" => 64}
      })
    end)
  end

  defp agent(name, options) do
    BaseAgent.init(%{
      client: %ClaudioAdapter{
        api_key: "k",
        options: Map.merge(%{req_options: [plug: {Req.Test, name}, retry: false]}, options)
      },
      model: "claude-opus-5-5",
      output_schema: %Decision{}
    })
  end

  test "structured outputs: max_tokens is the error, with one request and the usage" do
    stub(__MODULE__.Structured, "max_tokens")

    assert {:error, %LLMError{type: :max_tokens, usage_counts: %{output_tokens: 64}}} =
             BaseAgent.run(agent(__MODULE__.Structured, %{}), "decide")

    assert_received {:body, %{"output_config" => %{"format" => _}}}
    refute_received {:body, _}
  end

  test "legacy path: max_tokens is the error, with no JSON retry" do
    stub(__MODULE__.Legacy, "max_tokens")

    assert {:error, %LLMError{type: :max_tokens}} =
             BaseAgent.run(agent(__MODULE__.Legacy, %{structured_outputs: false}), "decide")

    assert_received {:body, _}
    refute_received {:body, _}
  end

  test "refusal under on_parse_failure: :fallback never lands in chat_message" do
    stub(__MODULE__.Refusal, "refusal")

    assert {:error, %LLMError{type: :refusal}} =
             BaseAgent.run(agent(__MODULE__.Refusal, %{on_parse_failure: :fallback}), "decide")
  end

  test "model_context_window_exceeded is the :max_tokens error" do
    stub(__MODULE__.Window, "model_context_window_exceeded")

    assert {:error,
            %LLMError{
              type: :max_tokens,
              reason: {:stop_reason, :model_context_window_exceeded}
            }} = BaseAgent.run(agent(__MODULE__.Window, %{}), "decide")
  end

  test "a JSON retry cut off at max_tokens is the error, with both calls' usage" do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__.Retry, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      n = Agent.get_and_update(calls, &{&1, &1 + 1})

      {text, stop, output} =
        if n == 0,
          do: {"not json", "end_turn", 5},
          else: {~s({"action": "ap), "max_tokens", 64}

      Req.Test.json(conn, %{
        "id" => "msg_#{n}",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => stop,
        "usage" => %{"input_tokens" => 3, "output_tokens" => output}
      })
    end)

    assert {:error, %LLMError{type: :max_tokens, usage_counts: %{output_tokens: 69}}} =
             BaseAgent.run(agent(__MODULE__.Retry, %{structured_outputs: false}), "decide")

    assert_received {:body, _first}
    assert_received {:body, _retry}
    refute_received {:body, _}
  end

  # Task 5.1 routes a tool-loop call with output_format to the structured path; its
  # incomplete clause covers that call too: no tool call or text is kept from it.
  test "a tool-loop call with output_format cut off at max_tokens comes back empty" do
    test_pid = self()

    Req.Test.stub(__MODULE__.ToolLoop, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [
          %{"type" => "text", "text" => "Checking"},
          %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
        ],
        "stop_reason" => "max_tokens",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 64}
      })
    end)

    client = %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, __MODULE__.ToolLoop}, retry: false]}
    }

    request = %Request{
      model: "claude-opus-5-5",
      max_tokens: 64,
      messages: [%Message{role: "user", content: "decide"}],
      tools: [%{name: "weather", description: "w", input_schema: %{type: "object"}}],
      response_model: %ToolCallResponse{},
      output_format: %Decision{}
    }

    assert {:ok, %Response{content: %ToolCallResponse{} = content, stop_reason: :max_tokens}} =
             Model.converse(client, request, [])

    assert content == %ToolCallResponse{}
    assert_received {:body, %{"output_config" => %{"format" => _}, "tools" => [_]}}

    agent =
      %{
        client: client,
        model: "claude-opus-5-5",
        output_schema: %Decision{}
      }
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%FakeTool{notify: self()})

    assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "decide")
    assert_received {:body, %{"output_config" => %{"format" => _}}}
    refute_received {:body, _}
    refute_received {:tool_ran, _}
  end
end
```

In `test/llm/claudio_adapter_test.exs`, describe `"structured response interpretation"`, replace the four tests from `test "refusal routes to the parse-failure policy (default :fallback)"` through `test "string-keyed stop_reason is classified like the atom-keyed form"` (lines 232-275 at `0dccd48`; keep `text_response/2` and the `"normal stop with valid JSON decodes and binds to the schema"` test) with:

```elixir
    # An incomplete answer is never parsed, re-asked or put in chat_message (AX-10):
    # the empty response model comes back, and Normandy.LLM.Call turns the stop
    # reason into the error.
    test "refusal is not parsed: the empty response model comes back" do
      resp = text_response(:refusal, "I can't help with that.")

      assert ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{}) ==
               %MultiField{}
    end

    test "max_tokens is not parsed or put in chat_message" do
      resp = text_response(:max_tokens, ~s({"chat_message": "trunca))

      assert ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{}) ==
               %MultiField{}
    end

    test "an incomplete answer ignores the :on_parse_failure policy" do
      resp = text_response(:model_context_window_exceeded, "nope")

      assert ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
               on_parse_failure: :error
             }) == %MultiField{}
    end

    test "string-keyed stop_reason is classified like the atom-keyed form" do
      resp = %{
        "stop_reason" => "refusal",
        "content" => [%{"type" => "text", "text" => "nope"}],
        "usage" => %{}
      }

      assert ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
               on_parse_failure: :error
             }) == %MultiField{}
    end
```

`claudio_adapter_test.exs:583-616` (adapters **carry** `:max_tokens`/`:refusal` as `{:ok, %Response{}}`) stays as is. It tests `Model.converse/3` directly, below `Call`.

In `test/llm/openai_compatible_adapter_test.exs`, insert before `test "an unknown finish_reason is a nil stop_reason; the string stays in meta"`:

```elixir
    test "a cut-off (length) or filtered answer is not parsed into the response model" do
      for finish_reason <- ["length", "content_filter"] do
        req_options =
          stub(fn conn ->
            Req.Test.json(conn, %{
              "choices" => [
                %{
                  "message" => %{"content" => ~s({"chat_message": "cu)},
                  "finish_reason" => finish_reason
                }
              ]
            })
          end)

        client = %Adapter{
          api_key: "k",
          options: %{req_options: req_options, on_parse_failure: :fallback}
        }

        request = %Request{
          model: "m",
          max_tokens: 8,
          messages: [],
          response_model: %Normandy.Agents.BaseAgentOutputSchema{}
        }

        assert {:ok,
                %Response{content: %Normandy.Agents.BaseAgentOutputSchema{chat_message: nil}}} =
                 Model.converse(client, request, [])
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/llm/call_stop_reason_test.exs test/agents/stop_reason_test.exs test/llm/claudio_adapter_stop_reason_test.exs test/llm/claudio_adapter_test.exs test/llm/openai_compatible_adapter_test.exs`
Expected: FAIL. `UndefinedFunctionError` for `Normandy.LLM.Call.check_stop_reason/1` and `stop_reason/1`. The agent tests get `{:ok, ...}` or a `:tool_ran` message instead of the `:max_tokens` error; the sync tool tests can instead raise `FunctionClauseError` in `cut_off_tool_call/1` (the tool ran on every round, and the old forced-final call asks for `%BaseAgentOutputSchema{}`, which the stub does not match). The structured-interpretation tests get `%MultiField{chat_message: "I can't help with that."}` or `{:error, %LLMError{type: :invalid_output}}`. The OpenAI test gets `chat_message: "{\"chat_message\": \"cu"`. The legacy wire test receives a second `{:body, _}` (the JSON retry).

- [ ] **Step 3: The error types**

In `lib/normandy/llm/error.ex`, add `:max_tokens` and `:refusal` after `:invalid_output` in `@types` and in `@type error_type` (`| :max_tokens` and `| :refusal` after `| :invalid_output`). In the moduledoc, after the paragraph that starts with ``type: :unsupported``, add:

```
  `type: :max_tokens` means the answer stopped before it was complete: the response hit
  the request's `max_tokens`, or the context window (`model_context_window_exceeded`; the
  message names which). `type: :refusal` means the model declined to answer. Both are
  `retryable?: false`; `:reason` is `{:stop_reason, reason}`, never model text, and
  `:usage` is what the call billed. Normandy builds them from the response's
  `stop_reason`, so every client gets them.
```

- [ ] **Step 4: The gate in `Normandy.LLM.Call`**

In `lib/normandy/llm/call.ex`, in `converse/3` replace the first clause:

```elixir
      {:ok, %Response{content: content, meta: meta}} = ok
      when is_map(meta) and (is_binary(content) or is_struct(content)) ->
        ok
```

with:

```elixir
      {:ok, %Response{content: content, meta: meta} = response}
      when is_map(meta) and (is_binary(content) or is_struct(content)) ->
        check_stop_reason(response)
```

Add before `defp bad_return/4`:

```elixir
  @doc false
  # A stop reason as Normandy.LLM.Response's atom (Response.stop_reason/1's closed list:
  # a provider string outside it stays a string); the stream path's final message
  # carries the provider's string.
  @spec stop_reason(term()) :: term()
  def stop_reason(reason) when is_binary(reason), do: Response.stop_reason(reason)
  def stop_reason(reason), do: reason

  @doc false
  # The one gate for an incomplete answer, on converse/3 and on BaseAgent's stream path:
  # cut off (max_tokens, the context window) or refused is an error, whatever the content.
  # `response` is a %Response{} or the streamed message map (:stop_reason, :usage).
  @spec check_stop_reason(map()) :: {:ok, map()} | {:error, LLMError.t()}
  def check_stop_reason(response) when is_map(response) do
    case stop_reason(Map.get(response, :stop_reason)) do
      :max_tokens ->
        {:error,
         incomplete(
           :max_tokens,
           :max_tokens,
           response,
           "the response stopped at max_tokens before it was complete; raise the " <>
             "agent's max_tokens or ask for a shorter answer"
         )}

      :model_context_window_exceeded ->
        {:error,
         incomplete(
           :max_tokens,
           :model_context_window_exceeded,
           response,
           "the response stopped at model_context_window_exceeded: the conversation " <>
             "filled the model's context window; compact or shorten the history"
         )}

      :refusal ->
        {:error,
         incomplete(
           :refusal,
           :refusal,
           response,
           "the model declined to answer (stop_reason refusal)"
         )}

      _ ->
        {:ok, response}
    end
  end

  # Never model text in the error (decision 6): the reason is the stop reason only.
  defp incomplete(type, stop_reason, response, detail) do
    [type: type, retryable?: false, reason: {:stop_reason, stop_reason}, detail: detail]
    |> LLMError.new()
    |> LLMError.with_usage(Map.get(response, :usage))
  end
```

`Call.stop_reason/1` delegates to Task 5.3c's `@doc false Normandy.LLM.Response.stop_reason/1` (H1), which already holds the closed string→atom list; a second list here would drift from it.

`Call.converse/3` is the only caller of `Model.converse/3` (`grep -rn "Call.converse" lib` gives 3 hits: `base_agent.ex` `call_llm_with_resilience/3`, `summarizer.ex`, `json_deserializer.ex`). So BaseAgent sync, `Turn.Server` (same handlers, `server.ex:484`), the summarizer and the JSON retry all get the gate. On the BaseAgent path the error is `retryable?: false`, so `default_retry_if/1` does not retry it and `endpoint_reason?/1` does not count it (`base_agent.ex:351-377`). `raise_llm_call_error/1` raises it inside the llm_call span before the core sees a response, so no tool runs and nothing is appended. `Turn.Server` replies it bare (`turn_error.ex:213-214`).

- [ ] **Step 5: Adapters stop parsing an incomplete answer**

In `lib/normandy/llm/claudio_adapter.ex`, inside `defimpl Normandy.Agents.Model`, after `alias Normandy.LLMError` add:

```elixir
    # Stop reasons whose answer is incomplete: cut off (max_tokens, the context
    # window) or withheld (refusal). Claudio parses each to this atom.
    @incomplete_stop_reasons [:max_tokens, :model_context_window_exceeded, :refusal]
```

In **both** `converse_legacy/4` and `converse_structured/4`, insert this clause as the first clause of the `case create(...) do` (before `{:ok, response} ->`). Leave the existing `{:ok, response}` branch as Task 5.1 left it:

```elixir
        # An answer cut off or refused is never parsed or re-asked: the empty response
        # model goes back with its stop reason, and Normandy.LLM.Call makes the error.
        {:ok, %Claudio.Messages.Response{stop_reason: reason} = response}
        when reason in @incomplete_stop_reasons ->
          {:ok, ClaudioAdapter.__incomplete_response__(request, response)}
```

The structured-path clause runs before the `{:error, error}` 400-fallback clause, so an incomplete structured answer never reaches `converse_legacy(..., :structured_fallback)`. Task 5.1's tool-loop structured path (`response_model: %ToolCallResponse{}` with `output_format`) goes through the same `case`, so it gets the clause too (X2; pinned by the last test of `claudio_adapter_stop_reason_test.exs`, which fails with the structured clause removed).

Add to the outer module, before `def __handle_structured_response__/3`:

```elixir
  @doc false
  # The %Normandy.LLM.Response{} for an incomplete answer: the request's empty response
  # model, the stop reason and the billed usage. Normandy.LLM.Call turns it into the
  # :max_tokens or :refusal LLMError.
  @spec __incomplete_response__(Request.t(), Claudio.Messages.Response.t()) ::
          Normandy.LLM.Response.t()
  def __incomplete_response__(%Request{response_model: response_model}, response),
    do: __response__(response_model, response, extract_usage(response))
```

In `__handle_structured_response__/3`, replace the incomplete clause's body. The clause matching `:refusal`/`"refusal"`/`:max_tokens`/`"max_tokens"`/`:model_context_window_exceeded`/`"model_context_window_exceeded"`; keep the guard list as is. The body changes from

```elixir
        apply_parse_failure(
          response_model,
          content,
          {:structured_output_incomplete, reason},
          context
        )
```

to

```elixir
        response_model
```

and add above the clause:

```elixir
      # Incomplete (cut off or refused): not parsed, whatever the :on_parse_failure
      # policy; converse/3 never gets here with one (its incomplete clause), so this
      # serves direct callers.
```

`converse_raw/3` (`response_model: nil`, the JSON retry's call) needs no change: it parses nothing and returns the text with its `stop_reason`, and `Call` makes the error.

In the moduledoc's `## Structured Outputs` list, delete the bullet

```
  - The model returns `refusal`, `max_tokens`, or context-exceeded — these route through the
    existing `:on_parse_failure` policy and legacy fallback.
```

and add after the list (before the closing `"""`):

```
  A response that stops at `max_tokens`, `model_context_window_exceeded` or `refusal` is
  never parsed, re-asked or passed to `:on_parse_failure`, on either path: `converse/3`
  returns the empty response model with that `stop_reason`, and Normandy turns it into
  `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`.
```

In `lib/normandy/llm/openai_compatible_adapter.ex`, in `converse/3` change `case populate(content, client, request) do` to `case populate(content, client, request, A.stop_reason(resp_body)) do`. Add above the existing `defp populate/3` clauses:

```elixir
    # A cut-off (length) or filtered (content_filter) answer is not parsed: the empty
    # response model goes back with its stop_reason for Normandy.LLM.Call to reject.
    defp populate(content, _client, %Request{response_model: rm}, reason)
         when reason in [:max_tokens, :refusal],
         do: rm || content

    defp populate(content, client, request, _reason), do: populate(content, client, request)
```

- [ ] **Step 6: A JSON retry's error keeps the call's whole usage**

The gate attaches the cut-off retry's own usage to its error. `LLMError.with_usage/2` keeps the first usage, so the adapter's total (first response plus retries) would be dropped. In `lib/normandy/llm/json_deserializer.ex`, in the retry function, replace

```elixir
      # An LLM failure is not a parse failure: stop and hand it back.
      {:error, %LLMError{}} = error ->
        error
```

with

```elixir
      # An LLM failure is not a parse failure: stop and hand it back. A billed failure
      # (a retry cut off at max_tokens) reports its usage like a successful retry, so the
      # adapter attaches the call's total instead of this retry's alone.
      {:error, %LLMError{} = error} ->
        report_retry_usage(opts, error.usage)
        {:error, %{error | usage: nil, usage_counts: nil}}
```

- [ ] **Step 7: The stream path**

In `lib/normandy/agents/base_agent.ex`, `stream_llm_attempt/4`, at the start of the `{:ok, final_message} ->` branch (before `# The prefix this response was produced under`), add:

```elixir
        # The streamed stop reason is the provider's string; as an atom it reads like
        # the sync path's. Cut off or refused raises here, inside the llm_call span, before
        # the core sees the message: no tool runs and nothing is appended. Deltas already
        # delivered to the callback stay delivered.
        final_message = Map.update(final_message, :stop_reason, nil, &Call.stop_reason/1)

        case Call.check_stop_reason(final_message) do
          {:ok, _} -> :ok
          {:error, error} -> raise error
        end
```

`StreamProcessor.build_final_message/1` is unchanged (it keeps the string; its tests stay valid). The request span's outcome (`stream_request_outcome/1`) runs inside `stream_from_llm/5`, before this mapping, and still sees the string. `stream_meta/1`'s `finish_reason/1` already turns an atom back into the string for telemetry.

Docs, same file. In the `run/3` `@doc`, after the sentence ending `... or \`Normandy.TurnError\`.`, add: `` An answer cut off at `max_tokens` (or the context window) or refused is `{:error, %Normandy.LLMError{type: :max_tokens}}` or `type: :refusal`, and no tool call from it runs. `` In the `stream/3` `@doc`, after the paragraph that starts `` `retry` and the circuit breaker apply``, add:

```
  A stream that stops at `max_tokens`, the context window or a refusal returns
  `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`, as `run/3` does: the
  deltas already delivered to `callback` stay delivered, and nothing of that response is
  stored or run.
```

In `lib/normandy/agents/model.ex`, at the end of `## Response content`, add:

```
  An answer that stopped at `:max_tokens`, `:model_context_window_exceeded` or
  `:refusal` need not be parsed: return the empty `response_model` as `content` with that
  `stop_reason`. Normandy turns any response with one of these stop reasons into
  `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`, whatever its content.
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test test/llm/call_stop_reason_test.exs test/agents/stop_reason_test.exs test/llm/claudio_adapter_stop_reason_test.exs test/llm/claudio_adapter_test.exs test/llm/openai_compatible_adapter_test.exs test/context/ test/llm/`
Expected: PASS. (A scratch run of this exact change at `0dccd48`, without Tasks 5.1/5.3, ran the whole suite at 0 failures. The four rewritten `claudio_adapter_test.exs` tests were the only existing tests that changed.)

- [ ] **Step 9: Gate, MIGRATING and commit**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.2a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.2a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

Append to `MIGRATING-2.0.md` under `## 32.` (after Task 5.1's bullets):

```markdown
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
- `Normandy.Context.Summarizer` returns `{:error, %LLMError{type: :max_tokens}}` for a
  summary cut off at its `max_tokens`, instead of the fragment.
- New `Normandy.LLMError` types `:max_tokens` and `:refusal`; telemetry `error.type` reports
  them as `max_tokens` and `refusal`.
```

```bash
git add lib/normandy/llm/error.ex lib/normandy/llm/call.ex lib/normandy/llm/claudio_adapter.ex \
  lib/normandy/llm/openai_compatible_adapter.ex lib/normandy/llm/json_deserializer.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/agents/model.ex MIGRATING-2.0.md \
  test/llm/call_stop_reason_test.exs test/agents/stop_reason_test.exs \
  test/llm/claudio_adapter_stop_reason_test.exs test/llm/claudio_adapter_test.exs \
  test/llm/openai_compatible_adapter_test.exs
git commit -m "fix(llm): max_tokens and refusal stop reasons are errors on every path"
```

---

### Task 5.2b: The iteration cap keeps the loop's prefix (AX-5)

**Files:**
- Modify: `lib/normandy/llm/request.ex` (field `tool_choice`, moduledoc)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`add_tool_choice/2` in `build_request/3`)
- Modify: `lib/normandy/agents/turn.ex` (final call keeps `s.response_model`; `awaiting_final` converts; `cap_notice/2`; `finish_effect/2`; default 20; the paused final call's `final_pauses`, `fail_paused_final/2` and `final_pauses/1` (decision 23); docs and comments)
- Modify: `lib/normandy/llm/error.ex` (type `:pause_turn`, decision 23)
- Modify: `lib/normandy/agents/turn/driver.ex` (`{:fail, %LLMError{}}` raises the error, decision 23)
- Modify: `lib/normandy/agents/base_agent.ex` (`final_call_opts/1`; `call_turn_llm/3`; `get_response_with_usage/3`; `streaming_handlers/1` loses its `final: true` clause; `call_stream_llm/4`; `stream_llm_attempt/5`; comments)
- Modify: `lib/normandy/components/agent_memory.ex` (`request_messages/1` folds a following user text into the tool-result message)
- Modify: `lib/normandy/agents/base_agent/init_options.ex`, `lib/normandy/agents/base_agent_config.ex` (default 20)
- Modify: `lib/normandy/agents/turn/server.ex` (moduledoc `:iteration` line)
- Modify: `MIGRATING-2.0.md` (`## 32.`)
- Test: create `test/agents/iteration_cap_test.exs`, `test/llm/claudio_adapter_tool_choice_test.exs`, `test/components/agent_memory/request_messages_user_text_test.exs`; modify `test/llm/claudio_adapter_thinking_test.exs`, `test/agents/turn_test.exs`, `test/agents/turn_approval_test.exs`, `test/agents/turn_compaction_test.exs`, `test/agents/turn_inline_test.exs`, `test/agents/pause_turn_test.exs` (Task 5.3c's), `test/agents/base_agent_tools_test.exs`, `test/agents/base_agent_guardrails_test.exs`, `test/agents/base_agent_streaming_test.exs` (comment only)

**Interfaces:**
- Consumes: Task 5.1's `Request.output_format`, which BaseAgent sets on every `%ToolCallResponse{}` call with a non-chat schema, so the final call (which now uses that response model) is format-constrained too. Task 5.3a's `AgentMemory.request_messages/1`, which every request builder uses (sync, stream, `TokenCounter`). Task 5.3b's `ToolCallResponse.content_blocks` replay. Task 5.3c's pause path through `apply_tool_results(s, [])`.
- Produces: `%Normandy.LLM.Request{tool_choice: nil | :none}`. The core effect for the last call is `{:call_llm, %{response_model: s.response_model, final: true}}`. The cap notice is `{:append_message, "user", notice}` (exact text from the header), emitted by `apply_tool_results/2` before `{:persist, _}` and only for a non-empty batch. A `pause_turn` on the final call is continued as the final call through 5.3c's `continue_paused/2`, at most 3 times (`@max_final_continuations`, not an option), counted in the private `%Turn.State{}` field `final_pauses` (default `0`; `iterations_left` never goes below 0); a 4th pause fails the turn with `{:fail, %Normandy.LLMError{type: :pause_turn}}` (X1; decision 23, B1/B2): new `LLMError` type `:pause_turn`, `retryable?: false`, `reason: {:stop_reason, :pause_turn}`, no model text, `usage` the paused response's `:usage` when it carries one. `tool_choice` is set in `build_request/3`, which every Claudio path uses, `stream/3` and its format-less re-send included (X3). `max_tool_iterations` defaults to `20`. No new core effect. `Turn.Inline` and `Turn.Server` already return a `{:fail, reason}` (`TurnError.from_reason/1` replies an `LLMError` bare); `Turn.Driver`, which raised a `RuntimeError` for every `:fail` (BaseAgent's sync and stream paths never met one), gains a `{:fail, %LLMError{}}` clause that raises the error, so `run/3` and `stream/3` return it. The shared breaker never counts `:pause_turn` (decision 20): the core builds it after the call returned, outside `CircuitBreaker.run/3`, and BaseAgent's `endpoint_reason?/1` counts only `retryable?: true` or `@endpoint_failure_types` (`:rate_limit`, `:overloaded`, `:server`, `:transport`, `:stream`); no classifier and no other list of `LLMError` types changes (`Normandy.LLMError`'s `@types` and `t:error_type/0` are the only ones).

- [ ] **Step 1: Write the failing tests**

Create `test/agents/iteration_cap_test.exs` (its `describe "a paused final call"` covers X1: a `pause_turn` on the final call is continued as the final call, and a 4th pause is a `:pause_turn` error on `run/3`, `stream/3` and `Turn.Server`, decision 23):

```elixir
defmodule Normandy.Agents.IterationCapTest do
  @moduledoc """
  AX-5: at max_tool_iterations the final call keeps the loop's response model, system
  prompt and tools, sets tool_choice :none, and follows a persisted notice; the core
  converts its answer like any other final answer.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.LLMError
  alias Normandy.Test.FakeTool

  @notice "You have used all available tool calls for this turn. Answer now with what you " <>
            "have, and say what you could not finish."

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true)
    end
  end

  # Calls the weather tool on every request until one carries tool_choice: :none,
  # then answers `final`, after pausing (pause_turn) on the first `final_pauses`
  # final calls. Each request goes to `notify`.
  defmodule CapClient do
    defstruct final: "", final_pauses: 0, notify: nil, options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall
      alias Normandy.LLM.Response

      def converse(client, request, _opts) do
        send(client.notify, {:request, request})

        content =
          case request.tool_choice do
            :none ->
              if pause?(client, request),
                do: %ToolCallResponse{content: "Still searching.", stop_reason: :pause_turn},
                else: %ToolCallResponse{content: client.final}

            nil ->
              %ToolCallResponse{tool_calls: [call(request)]}
          end

        {:ok, %Response{content: content, stop_reason: content.stop_reason || :end_turn}}
      end

      def stream(client, request, _opts) do
        send(client.notify, {:request, request})

        start = %{
          type: "message_start",
          message: %{"id" => "msg", "model" => "m", "role" => "assistant"}
        }

        paused? = request.tool_choice == :none and pause?(client, request)

        stop = [
          %{
            type: "message_delta",
            delta: %{"stop_reason" => if(paused?, do: "pause_turn", else: "end_turn")},
            usage: %{}
          },
          %{type: "message_stop"}
        ]

        text = if paused?, do: "Still searching.", else: client.final

        blocks =
          case request.tool_choice do
            :none ->
              [
                %{
                  type: "content_block_start",
                  index: 0,
                  content_block: %{"type" => "text", "text" => ""}
                },
                %{
                  type: "content_block_delta",
                  index: 0,
                  delta: %{"type" => "text_delta", "text" => text}
                },
                %{type: "content_block_stop", index: 0}
              ]

            nil ->
              %ToolCall{id: id} = call(request)

              [
                %{
                  type: "content_block_start",
                  index: 0,
                  content_block: %{
                    "type" => "tool_use",
                    "id" => id,
                    "name" => "weather",
                    "input" => %{}
                  }
                },
                %{
                  type: "content_block_delta",
                  index: 0,
                  delta: %{"type" => "input_json_delta", "partial_json" => ~s({"city": "Paris"})}
                },
                %{type: "content_block_stop", index: 0}
              ]
          end

        {:ok, [start | blocks] ++ stop}
      end

      # A paused final call goes back with the paused turn last: the trailing
      # assistant messages count the pauses so far.
      defp pause?(client, request) do
        pauses =
          request.messages
          |> Enum.reverse()
          |> Enum.take_while(&(&1.role == "assistant"))
          |> length()

        pauses < client.final_pauses
      end

      # One id per round, so every tool_use in the conversation is distinct.
      defp call(request) do
        round = Enum.count(request.messages, &(&1.role == "assistant"))
        %ToolCall{id: "toolu_#{round}", name: "weather", input: %{"city" => "Paris"}}
      end
    end
  end

  defp agent(final, extra \\ %{}) do
    {pauses, extra} = Map.pop(extra, :final_pauses, 0)
    client = %CapClient{final: final, final_pauses: pauses, notify: self()}

    %{client: client, model: "m", max_tool_iterations: 2}
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%FakeTool{})
  end

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  # The notice travels as the last block of the last batch's tool-result message
  # (request_messages/1), not as a message of its own.
  defp assert_notice_in_tool_message(messages) do
    assert %Message{role: "tool", content: blocks} = List.last(messages)
    assert List.last(blocks) == %{type: "text", text: @notice}
    refute Enum.any?(messages, &(&1.role == "user" and &1.content == @notice))
  end

  describe "run/3 (sync)" do
    test "the final call keeps the loop's model, prompt and tools and sets tool_choice :none" do
      assert {:ok, config, %BaseAgentOutputSchema{chat_message: "Paris: weather in Paris"}} =
               BaseAgent.run(agent("Paris: weather in Paris"), "weather?")

      assert [first, second, final] = requests()
      assert first.tool_choice == nil
      assert second.tool_choice == nil
      assert final.tool_choice == :none
      assert %ToolCallResponse{} = final.response_model
      assert final.system == first.system
      assert final.tools == first.tools
      assert_notice_in_tool_message(final.messages)

      # The notice is persisted after the last batch's results, before the answer.
      roles_and_text =
        config.memory |> AgentMemory.messages() |> Enum.map(&{&1.role, &1.content})

      assert [
               {"user", _input},
               {"assistant", _},
               {"tool", _},
               {"assistant", _},
               {"tool", _},
               {"user", @notice},
               {"assistant", %BaseAgentOutputSchema{chat_message: "Paris: weather in Paris"}}
             ] = roles_and_text
    end

    test "a non-chat output schema's final text is converted by the core" do
      assert {:ok, _config, %Decision{action: "stop"}} =
               BaseAgent.run(agent(~s({"action": "stop"}), %{output_schema: %Decision{}}), "go")

      # Task 5.1: every tool-loop call, the final one included, carries the format.
      assert [_, _, %{tool_choice: :none, output_format: %Decision{}}] = requests()
    end
  end

  describe "stream/3" do
    test "the final streamed call sets tool_choice :none and is converted once" do
      assert {:ok, _config, %Decision{action: "stop"}} =
               BaseAgent.stream(
                 agent(~s({"action": "stop"}), %{output_schema: %Decision{}}),
                 "go",
                 fn _ -> :ok end
               )

      assert [%{tool_choice: nil} = first, %{tool_choice: nil}, %{tool_choice: :none} = final] =
               requests()

      assert final.system == first.system
      assert final.tools == first.tools
      assert_notice_in_tool_message(final.messages)
    end
  end

  describe "Turn.Server" do
    test "persists the notice and the final answer" do
      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-cap",
          config: agent("done"),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
               Server.run(srv, %{chat_message: "go"})

      assert {:ok, entries} = InMemory.history(store, "s-cap")

      assert ["user", "assistant", "tool", "assistant", "tool", "user", "assistant"] =
               Enum.map(entries, & &1.role)

      assert Enum.at(entries, 5).content == @notice
      assert List.last(requests()).tool_choice == :none
    end
  end

  # X1: a pause_turn on the final call is continued as the final call (tool_choice
  # :none, the paused turn sent back last, no user message), at most 3 times; a 4th
  # pause is a :pause_turn LLMError (decision 23).
  describe "a paused final call" do
    defp assert_continued_final(paused_call, continued) do
      assert paused_call.tool_choice == :none
      assert continued.tool_choice == :none
      assert continued.system == paused_call.system
      assert continued.tools == paused_call.tools
      assert %Message{role: "assistant"} = List.last(continued.messages)
      assert_notice_in_tool_message(Enum.drop(continued.messages, -1))
    end

    test "run/3 continues it as the final call and stores the notice once" do
      assert {:ok, config, %BaseAgentOutputSchema{chat_message: "done"}} =
               BaseAgent.run(agent("done", %{final_pauses: 1}), "weather?")

      assert [_, _, paused_call, continued] = requests()
      assert_continued_final(paused_call, continued)

      roles = config.memory |> AgentMemory.messages() |> Enum.map(& &1.role)

      assert roles == [
               "user",
               "assistant",
               "tool",
               "assistant",
               "tool",
               "user",
               "assistant",
               "assistant"
             ]

      assert config.memory |> AgentMemory.messages() |> Enum.count(&(&1.content == @notice)) == 1
    end

    # Two loop calls, then the final call and its 3 continuations, all tool_choice :none.
    defp assert_four_final_calls do
      assert [%{tool_choice: nil}, %{tool_choice: nil} | finals] = requests()
      assert length(finals) == 4
      assert Enum.all?(finals, &(&1.tool_choice == :none))
    end

    defp assert_pause_turn_error(error) do
      assert %LLMError{type: :pause_turn, retryable?: false, reason: {:stop_reason, :pause_turn}} =
               error

      refute error.message =~ "Still searching."
    end

    test "run/3 returns a :pause_turn error after 3 continuations" do
      assert {:error, error} = BaseAgent.run(agent("done", %{final_pauses: 100}), "weather?")
      assert_pause_turn_error(error)
      assert_four_final_calls()
    end

    test "stream/3 returns a :pause_turn error after 3 continuations" do
      assert {:error, error} =
               BaseAgent.stream(agent("done", %{final_pauses: 100}), "weather?", fn _ -> :ok end)

      assert_pause_turn_error(error)
      assert_four_final_calls()
    end

    test "Turn.Server replies with a :pause_turn error after 3 continuations" do
      {:ok, srv} =
        Server.start_link(
          session_id: "s-cap-pause-fail",
          config: agent("done", %{final_pauses: 100}),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:error, error} = Server.run(srv, %{chat_message: "go"})
      assert_pause_turn_error(error)
      assert_four_final_calls()
    end

    test "stream/3 continues it as the final call" do
      assert {:ok, _config, %BaseAgentOutputSchema{chat_message: "done"}} =
               BaseAgent.stream(agent("done", %{final_pauses: 1}), "weather?", fn _ -> :ok end)

      assert [_, _, paused_call, continued] = requests()
      assert_continued_final(paused_call, continued)
    end

    test "Turn.Server stores the paused turn and the answer" do
      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-cap-pause",
          config: agent("done", %{final_pauses: 1}),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
               Server.run(srv, %{chat_message: "go"})

      assert {:ok, entries} = InMemory.history(store, "s-cap-pause")

      assert ["user", "assistant", "tool", "assistant", "tool", "user", "assistant", "assistant"] =
               Enum.map(entries, & &1.role)

      assert [_, _, paused_call, continued] = requests()
      assert_continued_final(paused_call, continued)
    end
  end

  test "max_tool_iterations defaults to 20" do
    assert BaseAgent.init(%{client: %CapClient{notify: self()}, model: "m"}).max_tool_iterations ==
             20
  end
end
```

Create `test/llm/claudio_adapter_tool_choice_test.exs` (the last test pins X3: `stream/3` builds its request with `build_request/3` too):

```elixir
defmodule Normandy.LLM.ClaudioAdapterToolChoiceTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.Request
  alias Normandy.Test.WireScript

  @tool %{name: "weather", description: "w", input_schema: %{type: "object"}}

  defp body_of(name, request) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "m",
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)

    client = %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, name}, retry: false]}
    }

    {:ok, _response} = Model.converse(client, request, [])
    assert_received {:body, body}
    body
  end

  defp request(fields) do
    struct!(
      %Request{model: "m", max_tokens: 16, messages: [%Message{role: "user", content: "hi"}]},
      fields
    )
  end

  test "tool_choice :none is sent as {type: none} next to the tools" do
    body = body_of(__MODULE__.None, request(tools: [@tool], tool_choice: :none))

    assert body["tool_choice"] == %{"type" => "none"}
    assert [%{"name" => "weather"}] = body["tools"]
  end

  test "tool_choice nil leaves it to the API's default" do
    body = body_of(__MODULE__.Default, request(tools: [@tool]))
    refute Map.has_key?(body, "tool_choice")
  end

  test "tool_choice :none without any tool is left out (the API allows it only with tools)" do
    body = body_of(__MODULE__.NoTools, request(tool_choice: :none))
    refute Map.has_key?(body, "tool_choice")
  end

  # The stream request is built by build_request/3 too (X3).
  test "a stream request carries tool_choice :none" do
    client =
      WireScript.client([
        {:sse,
         WireScript.message(
           "msg_s",
           WireScript.block(0, %{"type" => "text", "text" => ""}, [
             %{"type" => "text_delta", "text" => "ok"}
           ]),
           "end_turn"
         )}
      ])

    {:ok, stream} = Model.stream(client, request(tools: [@tool], tool_choice: :none), [])
    Stream.run(stream)

    assert_received {:wire_body, 0, body}
    assert body["tool_choice"] == %{"type" => "none"}
    assert [%{"name" => "weather"}] = body["tools"]
  end
end
```

Create `test/components/agent_memory/request_messages_user_text_test.exs`:

```elixir
defmodule Normandy.Components.AgentMemory.RequestMessagesUserTextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolResult

  defp result(id), do: %ToolResult{tool_call_id: id, output: "ok #{id}", is_error: false}

  defp request_messages(memory),
    do: memory |> AgentMemory.history() |> AgentMemory.request_messages()

  test "a user text after a tool-result run becomes that message's last block" do
    messages =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "hi")
      |> AgentMemory.add_message("tool", result("t1"))
      |> AgentMemory.add_message("tool", result("t2"))
      |> AgentMemory.add_message("user", "notice")
      |> request_messages()

    assert [%Message{role: "user", content: "hi"}, %Message{role: "tool", content: blocks}] =
             messages

    assert [
             %{type: "tool_result", tool_use_id: "t1"},
             %{type: "tool_result", tool_use_id: "t2"},
             %{type: "text", text: "notice"}
           ] = blocks
  end

  test "two user texts after the run both join it, in order" do
    [_user, %Message{role: "tool", content: blocks}] =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "hi")
      |> AgentMemory.add_message("tool", result("t1"))
      |> AgentMemory.add_message("user", "notice")
      |> AgentMemory.add_message("user", "remember: metric")
      |> request_messages()

    assert [_result, %{type: "text", text: "notice"}, %{type: "text", text: "remember: metric"}] =
             blocks
  end

  test "a user text with no tool results before it stays its own message" do
    assert [%Message{role: "user", content: "a"}, %Message{role: "user", content: "b"}] =
             AgentMemory.new_memory()
             |> AgentMemory.add_message("user", "a")
             |> AgentMemory.add_message("user", "b")
             |> request_messages()
  end

  test "an empty user text is not folded (the API rejects an empty text block)" do
    assert [_user, %Message{role: "tool", content: [_result]}, %Message{role: "user", content: ""}] =
             AgentMemory.new_memory()
             |> AgentMemory.add_message("user", "hi")
             |> AgentMemory.add_message("tool", result("t1"))
             |> AgentMemory.add_message("user", "")
             |> request_messages()
  end
end
```

In `test/llm/claudio_adapter_thinking_test.exs`, replace the whole `describe "a changed system prompt" do ... end` block (the one test `"the forced final call at max_tool_iterations does not replay the loop's thinking"`, lines 143-167 at `0dccd48`) with:

```elixir
  describe "the final call at max_tool_iterations" do
    test "keeps the loop's prefix and thinking, and withholds tools with tool_choice none" do
      script(__MODULE__.Forced)

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.Forced),
          model: "claude-opus-5-5",
          toolset: Toolset.new([%FakeTool{}]),
          max_tool_iterations: 1
        })

      BaseAgent.run!(agent, "weather?")

      assert_received {:body, first}
      assert_received {:body, forced}

      # Same system prompt and tools: the thinking prefix key is unchanged, so the
      # loop's thinking goes back intact; only tool_choice differs.
      assert first["system"] == forced["system"]
      assert first["tools"] == forced["tools"]
      refute Map.has_key?(first, "tool_choice")
      assert forced["tool_choice"] == %{"type" => "none"}

      assert [
               %{"role" => "user"},
               %{"role" => "assistant", "content" => assistant},
               %{"role" => "user", "content" => results}
             ] = forced["messages"]

      assert [@thinking, @redacted, %{"type" => "tool_use", "id" => "t1"}] = assistant

      assert [
               %{"type" => "tool_result", "tool_use_id" => "t1"},
               %{
                 "type" => "text",
                 "text" =>
                   "You have used all available tool calls for this turn. Answer now with " <>
                     "what you have, and say what you could not finish."
               }
             ] = results
    end
  end
```

Update the core and default tests (`grep -rn "response_model: :os, final: true" test` gives **5** hits after Task 5.3c, all rewritten to `response_model: :rm, final: true`; the fifth is `pause_turn_test.exs`, below):

- `test/agents/turn_test.exs`
  - Add `alias Normandy.LLMError` after `alias Normandy.Components.ToolResult`, and after the aliases:
    ```elixir
      @cap_notice "You have used all available tool calls for this turn. Answer now with what you " <>
                    "have, and say what you could not finish."
    ```
  - `test "defaults max_iterations to 5"` becomes:
    ```elixir
        test "defaults max_iterations to 20" do
          assert Turn.new().max_iterations == 20
          assert Turn.new().iterations_left == 20
          assert %State{}.max_iterations == 20
        end
    ```
  - In `test "tool_dispatch results that exhaust the cap issue a forced final call"`, the first `assert effects == [...]` becomes the list below, and in `effects2` `{:call_llm, %{response_model: :os, final: true}}` becomes `{:call_llm, %{response_model: :rm, final: true}}`:
    ```elixir
          # The notice follows the batch's results and is persisted with them, before
          # the steering state: a resumed turn does not append it twice.
          assert effects == [
                   {:append_message, "tool", Enum.at(results, 0)},
                   {:append_message, "user", @cap_notice},
                   {:persist, s2},
                   {:emit_event, :steering, %{iterations_left: 0}},
                   {:maybe_compact, %{iterations_left: 0}}
                 ]
    ```
  - `test "the forced final response enters :finalizing as :max_iterations, skipping convert"` is renamed `"the forced final response enters :finalizing as :max_iterations and is converted"`. Its three-line comment becomes the two lines below (wrapped: `credo --strict` refuses lines over 120 columns, true of every one-line comment this step gives), and its last assertion becomes `assert effects == [{:convert_output, resp, :os}]`.
    ```elixir
          # The final call ran under tool_choice :none, so tool calls here are ignored: the
          # answer is converted from its text like any final answer.
    ```
  - Add to `describe "step/2 iteration cap"`:
    ```elixir
        test "a cap-hitting batch is the only one that appends the notice" do
          s = %State{
            status: :tool_dispatch,
            iterations_left: 2,
            max_iterations: 5,
            response_model: :rm,
            output_schema: :os,
            pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]
          }

          results = [%ToolResult{tool_call_id: "c1", output: "x", is_error: false}]
          {_s2, effects} = Turn.step(s, {:tool_results, results})

          refute Enum.any?(effects, &match?({:append_message, "user", _}, &1))
        end

        test "an empty batch at the cap appends no notice" do
          s = %State{
            status: :tool_dispatch,
            iterations_left: 1,
            max_iterations: 5,
            response_model: :rm,
            output_schema: :os,
            pending_calls: []
          }

          {s2, effects} = Turn.step(s, {:tool_results, []})

          assert s2.iterations_left == 0

          assert effects == [
                   {:persist, s2},
                   {:emit_event, :steering, %{iterations_left: 0}},
                   {:maybe_compact, %{iterations_left: 0}}
                 ]
        end
    ```
  - Add to the same describe (X1, the paused final call; Step 4 item 3; decision 23: `final_pauses` counts the continuations, `iterations_left` stays at 0, and a 4th pause fails the turn):
    ```elixir
        test "a paused final call is continued as the final call, with no user message" do
          s = %State{
            status: :assistant_streaming,
            awaiting_final: true,
            iterations_left: 0,
            max_iterations: 5,
            response_model: :rm,
            output_schema: :os
          }

          paused = %{content: "Searching.", tool_calls: [], stop_reason: :pause_turn}
          {s2, effects} = Turn.step(s, {:llm_response, paused})

          # final_pauses counts the continuation; iterations_left stays at 0.
          assert s2.status == :steering
          assert s2.awaiting_final == false
          assert s2.final_pauses == 1
          assert s2.iterations_left == 0

          assert effects == [
                   {:append_message, "assistant", paused},
                   {:persist, s2},
                   {:emit_event, :steering, %{iterations_left: 0}},
                   {:maybe_compact, %{iterations_left: 0}}
                 ]

          {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

          assert s3.awaiting_final == true

          assert effects2 == [
                   {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
                   {:call_llm, %{response_model: :rm, final: true}}
                 ]
        end

        test "a final call still paused after 3 continuations fails the turn with :pause_turn" do
          usage = %{input_tokens: 10, output_tokens: 2}

          paused = %{
            content: "Searching.",
            tool_calls: [],
            stop_reason: :pause_turn,
            usage: usage
          }

          s = %State{
            status: :assistant_streaming,
            awaiting_final: true,
            iterations_left: 0,
            max_iterations: 5,
            response_model: :rm,
            output_schema: :os
          }

          {s, effects, continuations} =
            Enum.reduce_while(1..10, {s, [], 0}, fn _, {s, _effects, n} ->
              case Turn.step(s, {:llm_response, paused}) do
                {%State{status: :steering} = s2, _} ->
                  {s3, _} = Turn.step(s2, {:compaction_done, %{}})
                  {:cont, {s3, [], n + 1}}

                {s2, effects} ->
                  {:halt, {s2, effects, n}}
              end
            end)

          assert continuations == 3
          assert s.status == :failed
          assert s.final_pauses == 3
          assert s.iterations_left == 0
          assert [{:fail, %LLMError{} = error}] = effects
          assert s.error == error

          # No model text in the error; the response's usage is kept.
          assert %LLMError{
                   type: :pause_turn,
                   retryable?: false,
                   reason: {:stop_reason, :pause_turn},
                   usage: ^usage
                 } = error

          refute error.message =~ "Searching."
        end

        test "a paused final call with tool calls is not continued" do
          s = %State{
            status: :assistant_streaming,
            awaiting_final: true,
            iterations_left: 0,
            max_iterations: 5,
            response_model: :rm,
            output_schema: :os
          }

          paused = %{
            content: nil,
            tool_calls: [%ToolCall{id: "z", name: "noop", input: %{}}],
            stop_reason: :pause_turn
          }

          assert {%State{status: :finalizing}, [{:convert_output, ^paused, :os}]} =
                   Turn.step(s, {:llm_response, paused})
        end
    ```
- `test/agents/turn_approval_test.exs`, `test "at the iteration cap, the resolved batch issues the forced-final call"`: the first effects pattern gets `{:append_message, "user", "You have used all available tool calls" <> _},` as its second element (after the `"tool"` append, before `{:persist, ^s2}`), and `response_model: :os` becomes `:rm` in `effects2`.
- `test/agents/turn_compaction_test.exs`, `test "compaction_done at the cap issues the forced-final call"`: `response_model: :os` becomes `:rm`.
- `test/agents/turn_inline_test.exs`, `test "always-tool model stops at the cap with one forced final call"`: `assert_received {:llm_call, %{response_model: :os, final: true}}` becomes `assert_received {:llm_call, %{response_model: :rm, final: true}}`. Its comment becomes:
  ```elixir
        # Three normal calls and one final call, all with the loop's response model (:rm);
        # the final one is marked final: true. assert_received consumes one matching message
        # each; order between distinct patterns does not matter.
  ```
- `test/agents/pause_turn_test.exs` (Task 5.3c), `test "a model that keeps pausing reaches the forced final call"`: `{:call_llm, %{response_model: :os, final: true}}` becomes `{:call_llm, %{response_model: :rm, final: true}}`.
- `test/agents/base_agent_tools_test.exs`, `test "uses default max_tool_iterations when not specified"`: `assert agent.max_tool_iterations == 5` becomes `== 20`.
- `test/agents/base_agent_guardrails_test.exs`: in `MockCapClient.converse/3`, the `else` branch (`request.response_model` with the comment `# Forced-final call: return the output_schema ...`) becomes:
  ```elixir
          else
            # The final call: an answer the output guardrail flags.
            %ToolCallResponse{content: "a leak in the answer", tool_calls: []}
          end
  ```
  The comment above `defmodule MockCapClient`'s second bullet becomes:
  ```elixir
    # - Final call (after a "tool" message exists; tool_choice :none): answers text containing
    #   "leak", which the ForbiddenSubstrings output guardrail flags.
  ```
  **Only** in `test "max-iterations branch still runs output guardrails"`, the option `guardrails: [output: [{RequiredFields, fields: [:chat_message]}], on_violation: :warn]` becomes the block below. The same line appears in `test "with on_violation :warn it logs a warning and does not halt"`; leave that one alone. Anchor the edit on the test name:
  ```elixir
              guardrails: [
                output: [{ForbiddenSubstrings, terms: ["leak"], field: :chat_message}],
                on_violation: :warn
              ]
  ```
  That test's comment becomes:
  ```elixir
        # max_tool_iterations: 1. MockCapClient returns a ToolCall on the first LLM call →
        # NoopTool dispatches → iterations_left hits 0 → Turn FSM makes the final call
        # (tool_choice :none). MockCapClient answers "a leak in the answer", which
        # ForbiddenSubstrings flags. The memory history will contain a "tool" role message,
        # proving the cap path was taken (not the completed path).
  ```
- `test/agents/base_agent_streaming_test.exs`, `test "max iterations forced-final returns a clean response and persists a tool turn"`: the comment `# output schema (the core skips its convert step on this path).` becomes `# output schema by the core's convert step, as on the normal path.`. Assertions unchanged.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/iteration_cap_test.exs test/llm/claudio_adapter_tool_choice_test.exs test/components/agent_memory/request_messages_user_text_test.exs test/llm/claudio_adapter_thinking_test.exs test/agents/turn_test.exs test/agents/turn_approval_test.exs test/agents/turn_compaction_test.exs test/agents/turn_inline_test.exs test/agents/pause_turn_test.exs test/agents/base_agent_tools_test.exs test/agents/base_agent_guardrails_test.exs`
Expected: FAIL (29 failures, measured for decision 23 on Task 5.2a's `lib` with this step's tests; the same measurement of the text before decision 23 gave 27, not the 19 recorded by the preflight). `KeyError`/`struct!` errors for `:tool_choice` on `%Request{}`. The core tests see no notice and `response_model: :os`. The thinking test sees a different `system` and no `tool_choice`. The fold test sees the notice as its own `"user"` message. The guardrail cap test sees no violation (the old path never converted the mock's text). The default tests see 5. The X1 tests fail like the other `iteration_cap_test.exs` tests (`KeyError` for `:tool_choice`), the core X1 tests on `final_pauses` (no such field) and on the paused text being converted instead of failing; `pause_turn_test.exs` sees `response_model: :os`.

- [ ] **Step 3: `Request.tool_choice` and the adapter**

In `lib/normandy/llm/request.ex`, add `tool_choice: nil` as the last `defstruct` field, `tool_choice: :none | nil` as the last `@type t` field, and add this moduledoc bullet after `:task_budget_remaining`:

```
  - `:tool_choice` - `nil` (the provider's default) or `:none`: tools stay listed, but the
    model may not call one. BaseAgent sets `:none` on the call after the last tool round
    (`max_tool_iterations`); a client without tool choice may ignore it
```

In `lib/normandy/llm/claudio_adapter.ex`, `build_request/3`, add `|> add_tool_choice(request.tool_choice)` directly after `|> add_mcp_servers(request.mcp_servers)`. It has to come after that line, because Claudio adds an MCP server's `mcp_toolset` to `tools`. Then add after `build_request/3`:

```elixir
    # tool_choice is valid only next to tools (the agent's, or an MCP server's
    # mcp_toolset), so a request with none leaves it unset.
    defp add_tool_choice(claudio_request, nil), do: claudio_request

    defp add_tool_choice(%Claudio.Messages.Request{tools: tools} = claudio_request, :none)
         when tools in [nil, []],
         do: claudio_request

    defp add_tool_choice(claudio_request, :none),
      do: Claudio.Messages.Request.set_tool_choice(claudio_request, :none)
```

`build_request/3` serves every Claudio path (legacy, structured, raw retry, stream), so the JSON retry, which resends `request` with only `messages` and `response_model` changed, keeps `tool_choice` too. `OpenAICompatibleAdapter` has no tools (`converse/3` raises on any) and ignores the field.

- [ ] **Step 4: The core**

In `lib/normandy/agents/turn.ex`:

1. Add `alias Normandy.LLMError` between `alias Normandy.Components.ToolResult` and `alias Normandy.Options`. After `alias Normandy.Options` add:
   ```elixir
     # Appended after the batch that spends the last tool iteration (decision 22, R4).
     @cap_notice "You have used all available tool calls for this turn. Answer now with " <>
                   "what you have, and say what you could not finish."
   ```
2. `defstruct` in `State`: `max_iterations: 5, iterations_left: 5` becomes `max_iterations: 20, iterations_left: 20`, and `final_pauses: 0` goes after `awaiting_final: false` (decision 23, B2: private to the core, it counts a paused final call's continuations). In `@type t`, `iterations_left: integer(),` becomes `iterations_left: non_neg_integer(),` and `final_pauses: non_neg_integer(),` goes after `awaiting_final: boolean(),`. In `@new_opts_schema`, `max_iterations` gets `default: 20`, and its doc becomes `"Tool-loop iterations before the final call (made with the loop's response model; the shell sends `tool_choice: :none`). Enforces the `pos_integer()` contract on `State.max_iterations` (`BaseAgent.init/1` applies the same check at the shell boundary)."`. The `output_schema` doc becomes `"The schema the final answer is converted into (`{:convert_output, resp, output_schema}`) when it differs from `:response_model`."`.
3. Replace the `awaiting_final: true` `:llm_response` clause. A paused final call (X1: `pause_turn`, no tool calls) goes through Task 5.3c's `continue_paused/2` like a paused loop call: appended, persisted at the steering boundary, no user message (an empty batch gets no notice, item 5). The `:compaction_done` clause for `left <= 0` (item 4) then makes the final call again, so the shells send `tool_choice: :none` again with no change. `final_pauses` counts the continuations (decision 23, B2; `iterations_left` stays at 0, item 5), and a 4th pause fails the turn with a `:pause_turn` `LLMError` (B1):
   ```elixir
     # The final call ran with tool_choice :none, so tool calls in its response are not
     # dispatched: the answer is converted like any final answer. A paused final call (no
     # tool calls) is continued like a paused loop call (continue_paused/2: appended, no
     # user message), and the :compaction_done clause for left <= 0 makes the final call
     # again. final_pauses counts the continuations; one more pause fails the turn.
     def step(%State{status: :assistant_streaming, awaiting_final: true} = s, {:llm_response, resp}) do
       pauses = final_pauses(s)

       cond do
         not (paused?(resp) and tool_calls(resp) == []) ->
           finish_final(s, resp)

         pauses < @max_final_continuations ->
           s
           |> Map.put(:final_pauses, pauses + 1)
           |> Map.put(:awaiting_final, false)
           |> continue_paused(resp)

         true ->
           fail_paused_final(s, resp)
       end
     end
   ```
   Add after the `@cap_notice` attribute (item 1):
   ```elixir
     # How many times a paused final call (pause_turn) is sent back for the model to
     # continue; one more pause fails the turn with a :pause_turn LLMError.
     @max_final_continuations 3
   ```
   Task 5.3c moved the next clause's `[] ->` finalization into `defp finalize/2`. Its body becomes:
   ```elixir
     defp finalize(s, resp) do
       s = %{s | status: :finalizing, last_response: resp, stop_reason: :completed}
       {s, [finish_effect(s, resp)]}
     end
   ```
   and add after it:
   ```elixir
     defp finish_final(s, resp) do
       s = %{
         s
         | status: :finalizing,
           awaiting_final: false,
           last_response: resp,
           stop_reason: :max_iterations
       }

       {s, [finish_effect(s, resp)]}
     end

     # A final call still paused after @max_final_continuations continuations: an
     # incomplete answer is never a success (decision 23). The reason is the stop reason,
     # never model text; usage is the response's own, when it carries any.
     defp fail_paused_final(s, resp) do
       error =
         [
           type: :pause_turn,
           retryable?: false,
           reason: {:stop_reason, :pause_turn},
           detail:
             "the final call after max_tool_iterations was still paused (stop_reason " <>
               "pause_turn) after #{@max_final_continuations} continuations"
         ]
         |> LLMError.new()
         |> LLMError.with_usage(Map.get(resp, :usage))

       {%{s | status: :failed, awaiting_final: false, last_response: resp, error: error},
        [{:fail, error}]}
     end

     # Map.get: a Turn.State persisted before final_pauses existed decodes without it.
     defp final_pauses(s), do: Map.get(s, :final_pauses, 0)
   ```
   A paused final call with tool calls is not continued (its `tool_use` blocks would go back without results): it is converted by `finish_final/2`, like any final call's ignored tool calls. `usage` stays `nil` on BaseAgent's paths: their `call_llm` handlers return the `%ToolCallResponse{}` content, which has no `:usage`; each call's usage is on its `llm_call` span. A custom `Turn.Inline`/`Turn.Driver` handler that returns a map with `:usage` gets it on the error.
   In the moduledoc, the `pause_turn` paragraph's last sentence `it spends one iteration, like a tool batch.` gets: `` A paused final call (after the iteration cap) is continued the same way as the final call, at most three times; a fourth pause fails the turn with `{:error, %Normandy.LLMError{type: :pause_turn}}`. ``
4. In the `:compaction_done` clause guarded by `left <= 0`, `{:call_llm, %{response_model: s.output_schema, final: true}}` becomes `{:call_llm, %{response_model: s.response_model, final: true}}`. Its comment's sentence `At/after the iteration cap, issue the forced-final call (skipping convert, like the old path); otherwise ...` becomes `At/after the iteration cap, issue the final call with the loop's response model (the shell sends tool_choice :none; the notice was appended with the last batch); otherwise ...`.
5. In `apply_tool_results/2`:
   ```elixir
     defp apply_tool_results(%State{} = s, results) do
       # Never below 0: a paused final call's continuation passes here with 0 left.
       new_left = max(s.iterations_left - 1, 0)
       append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
       notice = cap_notice(new_left, results)
       steering = {:emit_event, :steering, %{iterations_left: new_left}}

       s2 = %{
         s
         | status: :steering,
           iterations_left: new_left,
           pending_calls: [],
           parked_calls: [],
           held_results: []
       }

       {s2,
        append_effects ++
          notice ++ [{:persist, s2}, steering, {:maybe_compact, %{iterations_left: new_left}}]}
     end
   ```
   If Task 5.3c changed this function, keep its changes and add only the `notice` line, `notice ++` and the `max(..., 0)` with its comment (decision 23, B2). If Task 5.5 has already changed the `{:maybe_compact, ...}` payload, keep that payload.
6. Replace the `convert_needed?/1` comment's last sentence (`The forced-final (:max_iterations) path skips conversion structurally (see the awaiting_final clause).`) with `The final call after the iteration cap uses the loop's response model too, so it converts the same way.` Add after `convert_needed?/1`:
   ```elixir
     # The iteration-cap notice, after the batch that spent the last iteration. An empty
     # batch (a paused turn's continuation, Task 5.3c) gets none: the API requires its
     # resend to add no user message.
     defp cap_notice(left, [_ | _]) when left <= 0, do: [{:append_message, "user", @cap_notice}]
     defp cap_notice(_left, _results), do: []

     defp finish_effect(s, resp) do
       if convert_needed?(s),
         do: {:convert_output, resp, s.output_schema},
         else: {:validate_output, resp}
     end
   ```

7. (Decision 23, B1.) In `lib/normandy/llm/error.ex`, add `:pause_turn` after `:refusal` in `@types` and in `@type error_type` (`| :pause_turn` after `| :refusal`), and after the moduledoc paragraph that ends `` `stop_reason`, so every client gets them. `` add:
   ```markdown
     `type: :pause_turn` means the final call after `max_tool_iterations` was still paused
     (`stop_reason` `pause_turn`) after three continuations. It is `retryable?: false`;
     `:reason` is `{:stop_reason, :pause_turn}`, never model text, and `:usage` is the paused
     response's own when it carries any (BaseAgent's do not: each call's usage is on its
     `llm_call` span). The turn core builds it, so no circuit breaker counts it.
   ```

No new effect: Driver, Inline and Server already interpret `{:append_message, "user", text}`. `Turn.Server` stores it through `append_to_store/5` like `store_session_start/2`'s user text. `ServerGlue.after_tool_built/3` rewrites only `"tool"` appends.

- [ ] **Step 5: The shells**

In `lib/normandy/agents/base_agent.ex`:

1. After `defp task_budget_call_opts(_config, _state), do: []` add:
   ```elixir
     # The call after the last tool round (the core's final: true) keeps the loop's
     # system prompt, tools and response model, and asks for no more tool calls.
     defp final_call_opts(%{final: true}), do: [tool_choice: :none]
     defp final_call_opts(_request), do: []
   ```
2. `call_turn_llm/3`'s head becomes `defp call_turn_llm(config, state, %{response_model: response_model} = request) do`. Its `get_response_with_usage/3` options become `[request_tracker: tracker] ++ task_budget_call_opts(config, state) ++ final_call_opts(request)`.
3. In `get_response_with_usage/3`'s `%Normandy.LLM.Request{}` literal, add `tool_choice: Keyword.get(extra_opts, :tool_choice)` after `task_budget_remaining: ...`. Leave Task 5.1's `output_format` line as it is. Its comment `(a context provider, a tool change, the forced final call's schema or a model change can change them)` becomes `(a context provider, a tool change or a model change can change them)`.
4. `streaming_handlers/1`: replace the two-clause `call_llm: fn ... end` with
   ```elixir
         call_llm: fn config, state, request -> call_stream_llm(config, state, callback, request) end,
   ```
   and replace the function's comment (`# The forced-final call (max_tool_iterations reached) skips the core's convert step, ...` three lines) with `# The final call after max_tool_iterations streams like any other; the core converts its message (Turn.convert_needed?/1).`
5. `call_stream_llm/3` becomes `call_stream_llm/4` (`defp call_stream_llm(config, state, callback, turn_request) do`), and passes `turn_request` on: `stream_llm_attempt(config, state, callback, llm_metadata, turn_request)`. `stream_llm_attempt/4` becomes `/5` with the extra `turn_request` argument, and its request update becomes:
   ```elixir
       request = %{
         request
         | task_budget_remaining:
             Keyword.get(task_budget_call_opts(config, state), :task_budget_remaining),
           tool_choice: Keyword.get(final_call_opts(turn_request), :tool_choice)
       }
   ```
   `grep -n "call_stream_llm(\|stream_llm_attempt(" lib/normandy/agents/base_agent.ex` gives 2 definitions and 2 call sites after the edit.
6. `convert_final_output/4`'s comment `(the forced-final streamed call included)` becomes `(the final call after the iteration cap included)`.

In `lib/normandy/agents/turn/server.ex` moduledoc, `` `final: true` marks the forced-final call after the budget is spent.`` becomes `` `final: true` marks the last call, made with `tool_choice: :none` after the budget is spent.``.

(Decision 23, B1.) In `lib/normandy/agents/turn/driver.ex`, `run/4`, add before the `{:fail, reason} ->` clause (the one that raises `"Turn FSM reached :failed unexpectedly: ..."`, which `turn_driver_test.exs` still pins for a non-exception reason):

```elixir
      # A turn the core fails with a Normandy error (a final call that keeps pausing,
      # a :pause_turn LLMError) raises it; run/3 and stream/3 return it.
      {:fail, %Normandy.LLMError{} = error} ->
        raise error

```

`run/3` and `stream/3` rescue it into `{:error, error}` (`domain_error/2`); `Turn.Inline` returns `{:error, reason, state}` and `Turn.Server` replies `{:error, error}` already.

- [ ] **Step 6: `request_messages/1` folds a following user text**

In `lib/normandy/components/agent_memory.ex`, rename Task 5.3a's `def request_messages(history)` body into a private `defp coalesce_tool_results(history)`, with the body unchanged. Then define:

```elixir
  @doc """
  The request messages for `history/1`'s output: each run of consecutive `"tool"`
  messages becomes one `"tool"` message holding all their blocks in order, and a
  non-empty text `"user"` message right after such a run (the iteration-cap notice, an
  `after_compact` injection) becomes its last block, as the API expects text sent with
  tool results. Memory keeps one entry per message.
  """
  @spec request_messages([map()]) :: [Message.t()]
  def request_messages(history), do: history |> coalesce_tool_results() |> fold_user_text()

  defp fold_user_text([
         %Message{role: "tool", content: blocks} = tool,
         %Message{role: "user", content: text} | rest
       ])
       when is_list(blocks) and is_binary(text) and text != "" do
    fold_user_text([%{tool | content: blocks ++ [%{type: "text", text: text}]} | rest])
  end

  defp fold_user_text([message | rest]), do: [message | fold_user_text(rest)]
  defp fold_user_text([]), do: []
```

Keep Task 5.3a's `@spec` if it differs (input `history/1` maps, output `[%Message{}]`). Replace its `@doc` with the one above.

- [ ] **Step 7: Default 20**

- `lib/normandy/agents/base_agent/init_options.ex`: `max_tool_iterations: [type: :pos_integer, default: 5, doc: "Tool rounds per turn."]` becomes `max_tool_iterations: [type: :pos_integer, default: 20, doc: "Tool rounds per turn. After the last one the turn stores a notice and makes one more call with `tool_choice: :none`, whose answer is the turn's output."]`.
- `lib/normandy/agents/base_agent_config.ex`: `field(:max_tool_iterations, :integer, default: 5)` becomes `default: 20`.
- `Turn` was done in Step 4. The DSL inherits `init/1`'s default (see Header conflicts). Check: `grep -rn "default: 5" lib/normandy/agents/turn.ex lib/normandy/agents/base_agent/init_options.ex lib/normandy/agents/base_agent_config.ex` gives 0 hits.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/ test/llm/ test/components/ test/hooks/`
Expected: PASS. A scratch run of Steps 3-5 and 7 at `0dccd48` (without Tasks 5.1/5.3; the request-shape assertions were then checked as a separate `"user"` message) left exactly the tests listed in Step 1 failing, and 0 after their edits. The fold (Step 6) was checked by probe over `history/1` output. The `output_format` and coalesced-message assertions depend on Tasks 5.1 and 5.3a and were not run. The preflight run on top of 5.1-5.3c (this text as corrected) gave 1328 tests, 0 failures. Re-run for decision 23 on 5.1-5.3c plus this text: `6 properties, 1338 tests, 0 failures (8 excluded)` (the text before decision 23, measured the same way: 1336), and `mix precommit` `72 doctests, 28 properties, 3199 tests, 0 failures (203 excluded)`, exit 0, credo and dialyzer clean.

- [ ] **Step 9: Gate, MIGRATING and commit**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.2b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.2b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

Append to `MIGRATING-2.0.md` under `## 32.`:

```markdown
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
```

```bash
git add lib/normandy/llm/request.ex lib/normandy/llm/claudio_adapter.ex lib/normandy/agents/turn.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/components/agent_memory.ex \
  lib/normandy/agents/base_agent/init_options.ex lib/normandy/agents/base_agent_config.ex \
  lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/driver.ex lib/normandy/llm/error.ex \
  MIGRATING-2.0.md test/agents/iteration_cap_test.exs test/llm/claudio_adapter_tool_choice_test.exs \
  test/components/agent_memory/request_messages_user_text_test.exs \
  test/llm/claudio_adapter_thinking_test.exs test/agents/turn_test.exs \
  test/agents/turn_approval_test.exs test/agents/turn_compaction_test.exs \
  test/agents/turn_inline_test.exs test/agents/pause_turn_test.exs test/agents/base_agent_tools_test.exs \
  test/agents/base_agent_guardrails_test.exs test/agents/base_agent_streaming_test.exs
git commit -m "fix(turn): the iteration cap keeps the loop's prefix and stores a notice"
```

---

---

### Task 5.4a: Tool results are capped at the chokepoint (SEC-3/AX-8, decision 12a, R7)

**Files:**
- Create: `test/support/return_tool.ex` (`Normandy.Test.ReturnTool`)
- Create: `test/agents/tool_result_cap_test.exs`
- Modify: `lib/normandy/agents/base_agent_config.ex` (field `max_tool_result_chars`, `default_max_tool_result_chars/0`)
- Modify: `lib/normandy/agents/base_agent/init_options.ex` (option `max_tool_result_chars`)
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1` sets the field)
- Modify: `lib/normandy/agents/config_template.ex` (`@data_fields`)
- Modify: `lib/normandy/tools/toolset.ex` (field and register option `max_result_chars`, `max_result_chars/2`, `unregister/2`, both filters)
- Modify: `lib/normandy/components/tool_result.ex` (`render_output/1`, used by the `BaseIOSchema` impl)
- Modify: `lib/normandy/agents/dispatch.ex` (`finish/3`, the cap, invalid UTF-8, moduledoc)
- Modify: `lib/normandy/telemetry/metadata.ex` (`tool_result_truncated/3`)
- Modify: `lib/normandy/telemetry.ex` (catalogue entry)
- Modify: `lib/normandy/hooks/server_glue.ex` (`after_tool/3` and `answer_built/3` call `Dispatch.finish/3`)
- Modify: `MIGRATING-2.0.md` (`## 34.`, `## New, non-breaking`)
- Test: `test/tools/toolset_test.exs`, `test/agents/base_agent_init_options_test.exs`, `test/agents/config_template_test.exs` (new cases appended)

**Interfaces:**
- Consumes: `Dispatch` exits as they are at `0dccd48` (no earlier Wave 5 task changes `dispatch.ex`); `Normandy.Test.TelemetryCapture.attach/2`; `BaseAgent.non_streaming_handlers/0`; `Turn.Server.start_link/1` with `:handlers`.
- Produces: `BaseAgentConfig.max_tool_result_chars` (default `100_000`, `nil` = off) and `BaseAgentConfig.default_max_tool_result_chars/0`; `init/1` and DSL `new/1` option `:max_tool_result_chars`; `Toolset.register/3` option `:max_result_chars` and `Toolset.max_result_chars/2 :: {:ok, pos_integer() | nil} | :error`; `@doc false Dispatch.finish/3` (`ensure_encodable/1` then the cap); `@doc false ToolResult.render_output/1`; `Metadata.tool_result_truncated/3`; the event `[:normandy, :tool, :result_truncated]` (measurements `%{original_chars, kept_chars}`, metadata `tool_name`, `agent_name`, `tool_call_id`, the ids, `limit_source: :agent | :tool`); the truncation note `"\n[truncated: #{kept} of #{total} chars shown]"`; the invalid-UTF-8 error output `%{error: "the tool ran, but its output is not valid UTF-8 text"}`. Task 5.6 later changes the shape of error outputs (R8: a bare string for `{:error, binary}`); the cap tests below assert error results by regex over the rendered text so they hold before and after 5.6, except the invalid-UTF-8 case, which 5.6 updates if it changes Dispatch-built error shapes.

Design notes (why the code is shaped this way):
- **One cap, at the last step.** `ensure_encodable/1` runs twice on the executed path today (inside `answer/4`, then after the after-hooks). The note makes the cap non-idempotent, so `answer/4` is split: `after_tool_slot/4` (the slot only) is used mid-pipeline in `execute/4`, and every exit goes through `finish/3` once. `answer/4` becomes "slot, then `finish/3`" and is used only at exits (`classify/3` deny, budget denial, `execute_approved/3` miss and invalid input, `dispatch_one/3`'s `:needs_approval` collapse). Hooks (`after_tool`, after-hooks) see the whole output (decision 22, 5.4 Q2).
- **Results the server builds.** `ServerGlue.after_tool/3` (interrupted results) and `answer_built/3` (rejected and expired approvals) call `Dispatch.finish/3` where they called `ensure_encodable/1`, so a hook that rewrites them is capped too. With no `after_tool` hook those results are fixed text under 200 characters and are left as they are (not capped), which only matters for a per-tool cap below that length.
- **Partial configs.** Dispatch's callers pass bare maps in tests (`dispatch_test.exs`, `dispatch_split_test.exs`, `turn_inline_test.exs`, `tool_context_test.exs`, `mcp/tool_wrapper_test.exs`, `behaviours/config_test.exs`): `Map.get(config, :max_tool_result_chars, BaseAgentConfig.default_max_tool_result_chars())`, the same convention as `Metadata.tool/3`'s `Map.get(config, :name)`.
- **Characters are graphemes**, with a `byte_size(text) <= limit` fast path (a text's byte size bounds its grapheme count), so the O(n) walk runs only on results whose bytes exceed the cap.

- [ ] **Step 1: Write the failing tests**

Create `test/support/return_tool.ex`:

```elixir
defmodule Normandy.Test.ReturnTool do
  @moduledoc """
  A tool for tests that returns its `:output` unchanged: `{:ok, output}`, or
  `{:error, output}` when `error: true`. It is named by `:name` (default `"big"`) and takes
  an empty object as input.
  """
  use Normandy.Tool, description: "returns its configured output"

  alias Normandy.Tools.Context

  defstruct name: "big", output: "", error: false

  @impl Normandy.Tool
  def name(%__MODULE__{name: name}), do: name

  @impl Normandy.Tool
  def input_schema(_tool), do: %{type: "object", properties: %{}}

  @impl Normandy.Tool
  def run(%__MODULE__{error: true, output: output}, %Context{}), do: {:error, output}
  def run(%__MODULE__{output: output}, %Context{}), do: {:ok, output}
end
```

Create `test/agents/tool_result_cap_test.exs`:

```elixir
defmodule Normandy.Agents.ToolResultCapTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.ServerGlue
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Tools.Toolset

  @truncated [:normandy, :tool, :result_truncated]

  # A response model Turn.Server finalizes on: no tool_calls -> :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Calls the "big" tool once, then answers "done" once the conversation holds a result.
  defmodule BigToolClient do
    defstruct options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall

      def converse(_client, request, _opts) do
        content =
          if Enum.any?(request.messages, &(&1.role == "tool")),
            do: %ToolCallResponse{content: "done", tool_calls: nil},
            else: %ToolCallResponse{
              content: nil,
              tool_calls: [%ToolCall{id: "call_1", name: "big", input: %{}}]
            }

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(_client, request, _opts) do
        events =
          if Enum.any?(request.messages, &(&1.role == "tool")) do
            [
              %{type: "message_start", message: %{"id" => "m2", "role" => "assistant"}},
              %{
                type: "content_block_start",
                content_block: %{"type" => "text", "text" => ""},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => "done"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          else
            [
              %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
              %{
                type: "content_block_start",
                content_block: %{"type" => "tool_use", "id" => "call_1", "name" => "big"},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => "{}"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  defp big_call(id \\ "call_1"), do: %ToolCall{id: id, name: "big", input: %{}}

  defp config(tool, extra \\ %{}) do
    Map.merge(
      %{name: "cap-#{System.unique_integer([:positive])}", toolset: Toolset.new([tool])},
      extra
    )
  end

  defp dispatch(config, call \\ big_call(), pipeline \\ Dispatch.default_pipeline()),
    do: Dispatch.dispatch_one(config, call, pipeline)

  defp note(kept, total), do: "\n[truncated: #{kept} of #{total} chars shown]"

  defp agent(extra) do
    %{
      client: %BigToolClient{},
      model: "m",
      name: "cap-agent-#{System.unique_integer([:positive])}"
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  defp tool_results(memory) do
    for %{role: "tool", content: %ToolResult{} = result} <- AgentMemory.messages(memory),
        do: result
  end

  describe "Dispatch.finish/3 at the chokepoint" do
    test "the agent cap cuts a long result, ends it with the note, and emits the event" do
      cfg = config(%ReturnTool{output: String.duplicate("a", 25)}, %{max_tool_result_chars: 10})
      ref = TelemetryCapture.attach([@truncated], agent_name: cfg.name)

      assert %ToolResult{tool_call_id: "call_1", is_error: false, output: output} = dispatch(cfg)
      assert output == String.duplicate("a", 10) <> note(10, 25)

      assert_received {:telemetry, ^ref, %{original_chars: 25, kept_chars: 10},
                       %{
                         tool_name: "big",
                         tool_call_id: "call_1",
                         limit_source: :agent,
                         agent_name: agent_name
                       }}

      assert agent_name == cfg.name
    end

    test "a result at the cap is unchanged and emits nothing" do
      cfg = config(%ReturnTool{output: String.duplicate("a", 10)}, %{max_tool_result_chars: 10})
      ref = TelemetryCapture.attach([@truncated], agent_name: cfg.name)

      assert %ToolResult{output: "aaaaaaaaaa", is_error: false} = dispatch(cfg)
      refute_received {:telemetry, ^ref, _, _}
    end

    test "a config without the key caps at 100_000" do
      cfg = %{
        name: "bare",
        toolset: Toolset.new([%ReturnTool{output: String.duplicate("b", 100_001)}])
      }

      assert %ToolResult{output: output} = dispatch(cfg)
      assert output == String.duplicate("b", 100_000) <> note(100_000, 100_001)
    end

    test "the tool's max_result_chars wins over the agent's" do
      toolset =
        Toolset.register(Toolset.new(), %ReturnTool{output: "0123456789"}, max_result_chars: 4)

      cfg = %{
        name: "t-#{System.unique_integer([:positive])}",
        toolset: toolset,
        max_tool_result_chars: 8
      }

      ref = TelemetryCapture.attach([@truncated], agent_name: cfg.name)

      assert %ToolResult{output: "0123" <> rest} = dispatch(cfg)
      assert rest == note(4, 10)
      assert_received {:telemetry, ^ref, %{kept_chars: 4}, %{limit_source: :tool}}
    end

    test "a tool registered with max_result_chars: nil is never cut" do
      long = String.duplicate("c", 50)
      toolset = Toolset.register(Toolset.new(), %ReturnTool{output: long}, max_result_chars: nil)

      assert %ToolResult{output: ^long} =
               dispatch(%{name: "a", toolset: toolset, max_tool_result_chars: 10})
    end

    test "an agent cap of nil turns the cap off" do
      long = String.duplicate("c", 200_000)

      assert %ToolResult{output: ^long} =
               dispatch(config(%ReturnTool{output: long}, %{max_tool_result_chars: nil}))
    end

    # Review Focus #4: a cut on a grapheme boundary, multibyte tail included.
    test "the cut keeps a ZWJ emoji family whole and the text valid UTF-8" do
      family = "👨‍👩‍👧"
      text = String.duplicate("a", 9) <> family <> "é" <> "ü"
      cfg = config(%ReturnTool{output: text}, %{max_tool_result_chars: 10})

      assert %ToolResult{output: output} = dispatch(cfg)
      assert output == String.duplicate("a", 9) <> family <> note(10, 12)
      assert String.valid?(output)
      [kept, _note] = String.split(output, "\n[truncated:")
      assert String.length(kept) == 10
      assert String.ends_with?(kept, family)
    end

    test "a text over the cap in bytes but not in characters is unchanged" do
      text = String.duplicate("👨‍👩‍👧", 3)

      assert %ToolResult{output: ^text} =
               dispatch(config(%ReturnTool{output: text}, %{max_tool_result_chars: 3}))
    end

    test "a map output is cut as its JSON text" do
      output = %{"k" => String.duplicate("x", 20)}
      cfg = config(%ReturnTool{output: output}, %{max_tool_result_chars: 10})

      assert %ToolResult{output: text, is_error: false} = dispatch(cfg)
      assert text == ~s({"k":"xxxx) <> note(10, 28)
    end

    test "an error result is capped too" do
      cfg =
        config(%ReturnTool{output: String.duplicate("e", 30), error: true}, %{
          max_tool_result_chars: 10
        })

      assert %ToolResult{is_error: true, output: output} = dispatch(cfg)
      assert output =~ ~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su
    end

    test "a denial built by classify/3 (a toolset miss) is capped" do
      cfg = config(%ReturnTool{}, %{max_tool_result_chars: 10})
      call = %ToolCall{id: "m1", name: "missing", input: %{}}

      assert %ToolResult{tool_call_id: "m1", is_error: true, output: output} = dispatch(cfg, call)
      assert output =~ ~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su
    end

    test "a budget denial is capped" do
      cfg = config(%ReturnTool{}, %{max_tool_result_chars: 10})

      pipeline = %{
        Dispatch.default_pipeline()
        | budget_check_fn: fn _config, _call -> {:error, String.duplicate("r", 40)} end
      }

      assert %ToolResult{is_error: true, output: output} = dispatch(cfg, big_call(), pipeline)
      assert output =~ ~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su
    end

    test "after_tool and the after-hooks see the whole output; the cap runs once, last" do
      test_pid = self()
      cfg = config(%ReturnTool{output: String.duplicate("h", 30)}, %{max_tool_result_chars: 10})

      pipeline = %{
        Dispatch.default_pipeline()
        | after_tool: fn _config, _call, result ->
            send(test_pid, {:after_tool, String.length(result.output)})
            result
          end,
          after_hooks: [
            fn _config, _call, result ->
              send(test_pid, {:after_hook, String.length(result.output)})
              %{result | output: result.output <> "!!"}
            end
          ]
      }

      assert %ToolResult{output: output} = dispatch(cfg, big_call(), pipeline)
      assert_received {:after_tool, 30}
      assert_received {:after_hook, 30}
      assert output == String.duplicate("h", 10) <> note(10, 32)
    end

    test "an output that is not valid UTF-8 becomes an error result" do
      assert %ToolResult{
               is_error: true,
               output: %{error: "the tool ran, but its output is not valid UTF-8 text"}
             } = dispatch(config(%ReturnTool{output: <<"ok", 255, 254>>}))
    end
  end

  describe "every path stores the capped result" do
    test "BaseAgent.run/3 keeps the capped result in memory" do
      config =
        agent(%{max_tool_result_chars: 10})
        |> BaseAgent.register_tool(%ReturnTool{output: String.duplicate("s", 40)})

      assert {:ok, config, _output} = BaseAgent.run(config, %{chat_message: "go"})

      assert [%ToolResult{tool_call_id: "call_1", output: output}] = tool_results(config.memory)
      assert output == String.duplicate("s", 10) <> note(10, 40)
    end

    test "BaseAgent.stream/3 emits and stores the capped result" do
      test_pid = self()

      config =
        agent(%{max_tool_result_chars: 10})
        |> BaseAgent.register_tool(%ReturnTool{output: String.duplicate("s", 40)})

      callback = fn
        %StreamEvent{type: :tool_result, data: result} -> send(test_pid, {:streamed, result})
        _event -> :ok
      end

      assert {:ok, config, _output} = BaseAgent.stream(config, %{chat_message: "go"}, callback)

      expected = String.duplicate("s", 10) <> note(10, 40)
      assert_received {:streamed, %ToolResult{output: ^expected}}
      assert [%ToolResult{output: ^expected}] = tool_results(config.memory)
    end

    test "Turn.Server persists the capped result" do
      store = InMemory.new()
      sid = "cap-#{System.unique_integer([:positive])}"
      calls = :counters.new(1, [])

      call_llm = fn _config, _state, _request ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: %Resp{content: "", tool_calls: [big_call("t1")]},
          else: %Resp{content: "done", tool_calls: nil}
      end

      config = %{
        BaseAgent.init(%{client: %BigToolClient{}, model: "m", max_tool_result_chars: 10})
        | output_schema: %Resp{},
          input_schema: nil,
          toolset: Toolset.new([%ReturnTool{output: String.duplicate("s", 40)}])
      }

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: config,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "go")
      {:ok, entries} = InMemory.history(store, sid)

      assert [%ToolResult{tool_call_id: "t1", output: output}] =
               for(%{role: "tool", content: %ToolResult{} = r} <- entries, do: r)

      assert output == String.duplicate("s", 10) <> note(10, 40)
    end

    test "ServerGlue caps the results it rewrites through after_tool" do
      config =
        BaseAgent.init(%{
          client: %BigToolClient{},
          model: "m",
          max_tool_result_chars: 10,
          toolset: Toolset.new([%ReturnTool{}]),
          behaviours: %Normandy.Behaviours.Config{hooks: [{Normandy.Test.Hooks.Probe, []}]}
        })

      long = %ToolResult{tool_call_id: "t1", output: String.duplicate("i", 30), is_error: true}
      expected = String.duplicate("i", 10) <> note(10, 30)

      assert %ToolResult{tool_call_id: "t1", output: ^expected} =
               ServerGlue.after_tool(config, big_call("t1"), long)

      state = Turn.new(max_iterations: 1)

      assert {_state, [{:append_message, "tool", %ToolResult{output: ^expected}}]} =
               ServerGlue.after_tool_built(
                 config,
                 [big_call("t1")],
                 {state, [{:append_message, "tool", long}]}
               )
    end
  end
end
```

In `test/tools/toolset_test.exs`, at the end of `describe "registration options"` (after the test `"a wrongly typed option raises, naming the key"`), add:

```elixir
    test "max_result_chars: a cap, nil (no cap), or absent (the agent's cap)" do
      toolset =
        Toolset.new()
        |> Toolset.register(%Calculator{}, max_result_chars: 500)
        |> Toolset.register(%StringManipulator{}, max_result_chars: nil)
        |> Toolset.register(%ListProcessor{})

      assert Toolset.max_result_chars(toolset, "calculator") == {:ok, 500}
      assert Toolset.max_result_chars(toolset, "string_manipulator") == {:ok, nil}
      assert Toolset.max_result_chars(toolset, "list_processor") == :error
      assert Toolset.max_result_chars(toolset, "not_registered") == :error
    end

    test "re-registering without max_result_chars drops the old cap" do
      toolset =
        Toolset.new()
        |> Toolset.register(%Calculator{}, max_result_chars: 500)
        |> Toolset.register(%Calculator{}, replace: true)

      assert Toolset.max_result_chars(toolset, "calculator") == :error
    end

    test "unregister/2 and the filters drop the caps of the tools they drop" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, max_result_chars: 500)

      assert Toolset.max_result_chars(Toolset.unregister(toolset, "calculator"), "calculator") ==
               :error

      filtered = Toolset.filter_by_param_type(toolset, "no-such-type")
      assert Toolset.max_result_chars(filtered, "calculator") == :error
    end

    test "a max_result_chars that is not a positive integer or nil raises, naming the key" do
      for bad <- [0, -1, 1.5] do
        error =
          assert_raise ArgumentError, fn ->
            Toolset.register(Toolset.new(), %Calculator{}, max_result_chars: bad)
          end

        assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
        assert error.message =~ "invalid value for :max_result_chars option"
      end
    end
```

In `test/agents/base_agent_init_options_test.exs`, before `test ":session_id is an option"`, add:

```elixir
  test ":max_tool_result_chars defaults to 100_000 and takes nil" do
    assert BaseAgent.init(model: "m", client: client()).max_tool_result_chars == 100_000

    assert BaseAgent.init(model: "m", client: client(), max_tool_result_chars: 5).max_tool_result_chars ==
             5

    assert BaseAgent.init(model: "m", client: client(), max_tool_result_chars: nil).max_tool_result_chars ==
             nil

    for bad <- [0, -3, 1.5] do
      assert_raise ArgumentError,
                   ~r/\ANormandy.Agents.BaseAgent.init\/1: .*invalid value for :max_tool_result_chars option: expected positive integer, got: #{inspect(bad)}/s,
                   fn ->
                     BaseAgent.init(model: "m", client: client(), max_tool_result_chars: bad)
                   end
    end
  end
```

In `test/agents/config_template_test.exs`, after the test `"a template saved before tool_context existed rebuilds with %{}"`, add:

```elixir
    test "max_tool_result_chars travels in the template, nil included" do
      supp = round_trip_supplement()

      for cap <- [2_000, nil] do
        tmpl =
          %{full_config(supp) | max_tool_result_chars: cap} |> ConfigTemplate.from_config("t")

        assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").max_tool_result_chars == cap
      end
    end

    test "a template saved before max_tool_result_chars existed rebuilds with 100_000" do
      supp = round_trip_supplement()

      tmpl =
        full_config(supp)
        |> ConfigTemplate.from_config("t")
        |> Map.delete(:max_tool_result_chars)

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").max_tool_result_chars == 100_000
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/tool_result_cap_test.exs test/tools/toolset_test.exs test/agents/base_agent_init_options_test.exs test/agents/config_template_test.exs`
Expected: FAIL. `init/1` raises `unknown option :max_tool_result_chars`, `Toolset.register/3` raises `unknown option :max_result_chars`, `Toolset.max_result_chars/2` is undefined, the map-config Dispatch cases return the whole output (no note, no event; the three error-result cases fail with `FunctionClauseError` in `Kernel.=~/2`, since the uncapped output is still a `%{error: ...}` map), the invalid-UTF-8 case returns `is_error: false`, and `%{full_config(supp) | max_tool_result_chars: ...}` raises `KeyError`.

- [ ] **Step 3: The agent option**

In `lib/normandy/agents/base_agent_config.ex`, after `def default_max_tokens, do: @default_max_tokens`, add:

```elixir

  @default_max_tool_result_chars 100_000

  @doc """
  The `max_tool_result_chars` a config has when it sets none: #{@default_max_tool_result_chars}
  characters (graphemes).
  """
  @spec default_max_tool_result_chars() :: pos_integer()
  def default_max_tool_result_chars, do: @default_max_tool_result_chars
```

In the `@type t` add `max_tool_result_chars: pos_integer() | nil,` after `max_tool_concurrency: pos_integer(),`, and in `schema do` add after `field(:max_tool_concurrency, :integer, default: 1)`:

```elixir
    field(:max_tool_result_chars, :any, default: @default_max_tool_result_chars)
```

In `lib/normandy/agents/base_agent/init_options.ex`, in `@definition`, after the `max_tool_concurrency:` entry, add:

```elixir
    max_tool_result_chars: [
      type: {:or, [:pos_integer, nil]},
      default: BaseAgentConfig.default_max_tool_result_chars(),
      type_doc: "`t:pos_integer/0` or `nil`",
      doc:
        "The longest tool result, in characters (graphemes), the model sees; a longer one " <>
          "is cut and ends with a note saying how much was shown. `nil` = no cap. A tool's " <>
          "`Normandy.Tools.Toolset.register/3` `:max_result_chars` overrides it."
    ],
```

The DSL's `new/1` reuses `InitOptions.definition/0` without defaults, so it accepts the option with no DSL change.

In `lib/normandy/agents/base_agent.ex`, `init/1`'s `%BaseAgentConfig{...}`, after `max_tool_concurrency: Keyword.fetch!(opts, :max_tool_concurrency),` add:

```elixir
      max_tool_result_chars: Keyword.fetch!(opts, :max_tool_result_chars),
```

In `lib/normandy/agents/config_template.ex`, `@data_fields` becomes (a 1.0 or earlier-2.0 template lacks the key and rebuilds with the struct default, as for `:tool_context`):

```elixir
  @data_fields [
    :initial_memory,
    :retry,
    :circuit_breaker,
    :enable_json_retry,
    :json_retry_max_attempts,
    :guardrails,
    :tool_context,
    :max_tool_result_chars
  ]
```

- [ ] **Step 4: The per-tool option**

In `lib/normandy/tools/toolset.ex`:

Replace the type and struct:

```elixir
  @type t :: %__MODULE__{
          tools: %{String.t() => struct()},
          timeouts: %{String.t() => pos_integer()},
          max_result_chars: %{String.t() => pos_integer() | nil}
        }

  defstruct tools: %{}, timeouts: %{}, max_result_chars: %{}
```

In `@register_schema`, after the `timeout:` entry, add:

```elixir
                     max_result_chars: [
                       type: {:or, [:pos_integer, nil]},
                       type_doc: "`t:pos_integer/0` or `nil`",
                       doc:
                         "The longest result of this tool, in characters (graphemes), the model " <>
                           "sees; `nil` = no cap. Without it, the agent's `:max_tool_result_chars`."
                     ],
```

No `:default`: an absent option must stay absent (`Keyword.fetch/2` → `:error` = inherit the agent's cap), and an explicit `nil` is stored (no cap for this tool).

In `register/3`, change the head to `def register(%__MODULE__{tools: tools} = toolset, tool, opts \\ []) do` and replace the `timeouts = case ...` block and the final map update with:

```elixir
    # An option left out drops what an earlier registration under the name set.
    %{
      toolset
      | tools: Map.put(tools, tool_name, tool),
        timeouts: put_or_delete(toolset.timeouts, tool_name, Keyword.fetch(opts, :timeout)),
        max_result_chars:
          put_or_delete(
            toolset.max_result_chars,
            tool_name,
            Keyword.fetch(opts, :max_result_chars)
          )
    }
  end

  defp put_or_delete(map, key, {:ok, value}), do: Map.put(map, key, value)
  defp put_or_delete(map, key, :error), do: Map.delete(map, key)
```

After `timeout/2`, add:

```elixir

  @doc """
  The `:max_result_chars` `tool_name` was registered with: `{:ok, chars}`, `{:ok, nil}` (no
  cap), or `:error` when it was registered without one (the agent's
  `:max_tool_result_chars` applies) or is not registered.
  """
  @spec max_result_chars(t(), String.t()) :: {:ok, pos_integer() | nil} | :error
  def max_result_chars(%__MODULE__{max_result_chars: caps}, tool_name),
    do: Map.fetch(caps, tool_name)
```

Replace `unregister/2`:

```elixir
  def unregister(%__MODULE__{} = toolset, tool_name) do
    %{
      toolset
      | tools: Map.delete(toolset.tools, tool_name),
        timeouts: Map.delete(toolset.timeouts, tool_name),
        max_result_chars: Map.delete(toolset.max_result_chars, tool_name)
    }
  end
```

In `filter_by_required_params/2` and `filter_by_param_type/2`, replace each closing

```elixir
    %{
      toolset
      | tools: filtered_tools,
        timeouts: Map.take(toolset.timeouts, Map.keys(filtered_tools))
    }
```

with `keep(toolset, filtered_tools)` (2 sites: `grep -c "timeouts: Map.take(toolset.timeouts, Map.keys(filtered_tools))" lib/normandy/tools/toolset.ex` → 2 before, 0 after), and add after `filter_by_param_type/2`:

```elixir

  # The filtered tools, with the registration options of the tools kept.
  defp keep(toolset, tools) do
    names = Map.keys(tools)

    %{
      toolset
      | tools: tools,
        timeouts: Map.take(toolset.timeouts, names),
        max_result_chars: Map.take(toolset.max_result_chars, names)
    }
  end
```

Doc examples (these doctests do not run; `grep -rn "doctest Normandy.Tools.Toolset" test` finds none): in the `unregister/2`, `filter_by_required_params/2` and `filter_by_param_type/2` docs, append `, max_result_chars: %{}` inside each `%Normandy.Tools.Toolset{... timeouts: %{}}` result line (3 lines).

- [ ] **Step 5: `ToolResult.render_output/1`**

In `lib/normandy/components/tool_result.ex`, add to the `ToolResult` module after `schema do ... end`:

```elixir

  @doc false
  # The text the model reads for `output` (BaseIOSchema.to_json/1 below, and the cap in
  # Normandy.Agents.Dispatch.finish/3): a binary as-is, a number as its digits, anything
  # else (a map, a list, an atom, a boolean, nil) as JSON. Dispatch turns an output JSON
  # cannot express into an error result after every hook has run, so this raises only
  # for a ToolResult built outside Dispatch.
  @spec render_output(term()) :: String.t()
  def render_output(output) when is_binary(output), do: output
  def render_output(output) when is_number(output), do: to_string(output)
  def render_output(output), do: Normandy.JSON.encode!(output)
```

In the `defimpl`, replace `content: format_tool_output(result.output),` with `content: Normandy.Components.ToolResult.render_output(result.output),` and delete the three `format_tool_output/1` clauses and their comment (`grep -rn format_tool_output lib test` → 0 after).

- [ ] **Step 6: `Dispatch.finish/3`**

In `lib/normandy/agents/dispatch.ex`:

Moduledoc, `## Telemetry`: replace the last sentence `and emit nothing.` with:

```
  and emit nothing. A result cut by the cap (below) emits
  `[:normandy, :tool, :result_truncated]` (`%{original_chars, kept_chars}`, metadata from
  `Normandy.Telemetry.Metadata.tool_result_truncated/3`).

  ## Result cap

  Every result leaves the chokepoint through `finish/3`, after the `after_tool` slot and
  the after-hooks (which see the whole output): an output JSON cannot express, or a
  binary that is not valid UTF-8, becomes an error result; then a result whose text (what
  the model reads: a binary as-is, a number as its digits, anything else as JSON) is
  longer than the limit is cut to the limit, in characters (graphemes, so a
  multi-codepoint character is never split), and ends with
  `"\n[truncated: <kept> of <total> chars shown]"`. Error results are capped too. The
  limit is the tool's `Normandy.Tools.Toolset.register/3` `:max_result_chars` when it was
  registered with one (`nil` there turns the cap off for that tool), else the agent's
  `:max_tool_result_chars` (default 100_000; `nil` = no cap). A map or list output is cut
  as its JSON text, so the model gets a string.
```

(Do not link `ToolResult.render_output/1` from the moduledoc: it is `@doc false`, and `mix docs --warnings-as-errors` fails on a link to a hidden function.)

Add `alias Normandy.Agents.BaseAgentConfig` first in the alias list.

Replace `answer/4` and the head of `ensure_encodable/1` (from `# Every result the model will see passes the after_tool slot once` down to the first `ensure_encodable/1` clause, inclusive) with:

```elixir
  # Every result the model will see passes the after_tool slot once; the result answers
  # the call's id whatever the slot returns.
  defp after_tool_slot(_config, _call, result, %Pipeline{after_tool: nil}), do: result

  defp after_tool_slot(config, call, result, %Pipeline{after_tool: after_tool}),
    do: %{after_tool.(config, call, result) | tool_call_id: call.id}

  # A result that leaves Dispatch with no after-hooks to run: the slot, then finish/3.
  defp answer(config, call, result, pipeline),
    do: finish(config, call, after_tool_slot(config, call, result, pipeline))

  @doc false
  # The last step of every result that leaves Dispatch, and of the results
  # Normandy.Hooks.ServerGlue rewrites through after_tool (interrupted, rejected and
  # expired results, which skip Dispatch): ensure_encodable/1, then the cap (see the
  # moduledoc's "Result cap"). Runs once per result: the cap's note is not idempotent.
  @spec finish(map(), ToolCall.t(), ToolResult.t()) :: ToolResult.t()
  def finish(config, %ToolCall{} = call, %ToolResult{} = result),
    do: result |> ensure_encodable() |> cap(config, call)

  # Hooks (before-hook halts, after_tool, after_hooks) may build any %ToolResult{},
  # and memory keeps it for every later request. So the encodability check runs on
  # the final result, the last point before it can reach memory.
  @doc false
  @spec ensure_encodable(ToolResult.t()) :: ToolResult.t()
  def ensure_encodable(%ToolResult{output: output} = result) when is_binary(output) do
    if String.valid?(output),
      do: result,
      else: %{result | output: invalid_utf8_output(), is_error: true}
  end

  def ensure_encodable(%ToolResult{output: output} = result) when is_number(output),
    do: result
```

(The second `ensure_encodable/1` clause, the `Normandy.JSON.encode/1` one, stays.)

In `execute/4`, the `:ok ->` branch becomes:

```elixir
      :ok ->
        result = execute_and_wrap(config, call, invocation, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)
        result = config |> after_tool_slot(call, result, pipeline) |> ensure_encodable()

        config
        |> run_after_hooks(call, result, pipeline.after_hooks)
        |> Map.put(:tool_call_id, call.id)
        |> then(&finish(config, call, &1))
```

The other `answer/4` call sites are unchanged and now end in `finish/3`: `grep -n "answer(config" lib/normandy/agents/dispatch.ex` → 6, the `defp answer(config, ...)` head plus 5 call sites (`classify/3`, the budget denial in `execute/4`, two in `execute_approved/3`, `dispatch_one/3`).

Before `defp unencodable_output(exception),` add:

```elixir
  defp invalid_utf8_output,
    do: %{error: "the tool ran, but its output is not valid UTF-8 text"}

  # The tool's registration :max_result_chars wins over the agent's
  # :max_tool_result_chars, including a registered nil. Dispatch's callers pass partial
  # configs (bare maps in tests), so a config without the key has the default cap.
  defp cap(result, config, call) do
    case result_limit(config, call.name) do
      {nil, _source} ->
        result

      {limit, source} ->
        text = ToolResult.render_output(result.output)
        cap_text(result, text, %{limit: limit, source: source}, config, call)
    end
  end

  defp result_limit(config, name) do
    case tool_limit(config, name) do
      {:ok, limit} ->
        {limit, :tool}

      :error ->
        default = BaseAgentConfig.default_max_tool_result_chars()
        {Map.get(config, :max_tool_result_chars, default), :agent}
    end
  end

  defp tool_limit(%{toolset: %Toolset{} = toolset}, name),
    do: Toolset.max_result_chars(toolset, name)

  defp tool_limit(_config, _name), do: :error

  # A text's byte size bounds its grapheme count, so a short text skips the walk.
  defp cap_text(result, text, %{limit: limit}, _config, _call) when byte_size(text) <= limit,
    do: result

  defp cap_text(result, text, %{limit: limit, source: source}, config, call) do
    case String.length(text) do
      total when total <= limit ->
        result

      total ->
        :telemetry.execute(
          [:normandy, :tool, :result_truncated],
          %{original_chars: total, kept_chars: limit},
          Metadata.tool_result_truncated(config, call, source)
        )

        kept = String.slice(text, 0, limit)
        %{result | output: kept <> "\n[truncated: #{limit} of #{total} chars shown]"}
    end
  end
```

`test/json_struct_encoding_test.exs:65` (the unencodable-output message) is unchanged: the cap runs after `ensure_encodable/1` and that message is short.

- [ ] **Step 7: Telemetry metadata and catalogue**

In `lib/normandy/telemetry/metadata.ex`, before `defp tool_type(%ToolWrapper{}), do: :extension`, add:

```elixir
  @doc """
  `[:normandy, :tool, :result_truncated]` metadata: a tool result cut to its cap.
  `limit_source` is `:tool` (the tool's `Toolset.register/3` `:max_result_chars`) or
  `:agent` (the agent's `:max_tool_result_chars`).
  """
  @spec tool_result_truncated(map(), ToolCall.t(), :agent | :tool) :: map()
  def tool_result_truncated(config, %ToolCall{} = call, limit_source) do
    optional =
      %{tool_call_id: call.id}
      |> Map.merge(ids(config))
      |> reject_nil()

    Map.merge(
      %{tool_name: call.name, agent_name: Map.get(config, :name), limit_source: limit_source},
      optional
    )
  end

```

In `lib/normandy/telemetry.ex`, under `## Events`, after the `[:normandy, :tool, :denied]` entry (its last line is `expired approvals, so every denial has one shape.`), add:

```

  ### `[:normandy, :tool, :result_truncated]`

  A tool result longer than its cap, cut by `Normandy.Agents.Dispatch` before it reaches
  memory (error results too). Measurements: `original_chars` (the result's length, in
  characters: graphemes) and `kept_chars` (the cap; the note is added after them).
  Metadata: `tool_name`, `agent_name`, `tool_call_id`, the ids, and `limit_source`
  (`:tool` for a tool's `Toolset.register/3` `:max_result_chars`, `:agent` for the
  agent's `:max_tool_result_chars`). Emitted where the call was dispatched, often a tool
  task, so match on `tool_call_id` or `agent_name` rather than the process.
```

The call site is a literal list, so `test/telemetry/catalogue_test.exs` needs no `@dynamic` entry.

- [ ] **Step 8: `ServerGlue` calls `finish/3`**

In `lib/normandy/hooks/server_glue.ex`, `after_tool/3`'s `if` branch becomes:

```elixir
    if Runner.handles?(config, :after_tool) do
      call = Dispatch.to_tool_call(call)

      Dispatch.finish(config, call, %{
        Runner.after_tool(config, call, result)
        | tool_call_id: call.id
      })
    else
      result
    end
```

and the first `answer_built/3` clause becomes:

```elixir
  defp answer_built(config, by_id, %ToolResult{tool_call_id: id} = result)
       when is_map_key(by_id, id) do
    call = Map.fetch!(by_id, id)
    Dispatch.finish(config, call, %{Runner.after_tool(config, call, result) | tool_call_id: id})
  end
```

`grep -rn "Dispatch.ensure_encodable" lib` → 0 after.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/tool_result_cap_test.exs test/tools/toolset_test.exs test/agents/base_agent_init_options_test.exs test/agents/config_template_test.exs test/telemetry test/json_struct_encoding_test.exs test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs test/hooks`
Expected: PASS (the new file is 18 tests).

- [ ] **Step 10: MIGRATING, gate and commit**

In `MIGRATING-2.0.md`, add after `## 33.` (Task 5.3's section) and before `## New, non-breaking`:

```markdown
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
```

Under `## New, non-breaking`, add: "- `[:normandy, :tool, :result_truncated]` telemetry event (see the `Normandy.Telemetry` catalogue) when a tool result is cut to its cap."

Run: `mix format && mix precommit 2>&1 | tee /tmp/w5-5.4a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.4a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add test/support/return_tool.ex test/agents/tool_result_cap_test.exs \
  lib/normandy/agents/base_agent_config.ex lib/normandy/agents/base_agent/init_options.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/agents/config_template.ex \
  lib/normandy/tools/toolset.ex lib/normandy/components/tool_result.ex \
  lib/normandy/agents/dispatch.ex lib/normandy/telemetry/metadata.ex lib/normandy/telemetry.ex \
  lib/normandy/hooks/server_glue.ex MIGRATING-2.0.md test/tools/toolset_test.exs \
  test/agents/base_agent_init_options_test.exs test/agents/config_template_test.exs
git commit -m "feat(tools): cap tool results at the dispatch chokepoint"
```

---

### Task 5.4b: Memory namespace caps are checked atomically in every store (SEC-6/PERF-11, decision 12b, R7, Review Focus #5)

**Files:**
- Modify: `lib/normandy/behaviours/memory_store.ex` (callback `put/6`, types `limits`/`namespace_full`, `validate_limits!/2`, `check_limits/3`, moduledoc)
- Modify: `lib/normandy/behaviours/memory_store/docs.ex` (`put/5` with limits, `next_version/2`)
- Modify: `lib/normandy/behaviours/memory_store/in_memory.ex`, `ets.ex`, `mnesia.ex` (`put/6`)
- Modify: `lib/normandy/behaviours/memory_store/postgres.ex` (whole file below: every write one transaction behind the namespace counter row)
- Modify: `lib/normandy/behaviours/memory_store/postgres/migration.ex` (table `normandy_memory_namespaces`)
- Modify: `lib/normandy/behaviours/memory_store/redis.ex` (whole file below: byte counter key, limits in `@put`)
- Modify: `lib/normandy/tools/memory.ex` (option `max_namespace_documents`, moduledoc)
- Modify: `lib/normandy/tools/memory/commands.ex` (pass limits, map `:namespace_full`, delete `others_bytes/3` and `within_cap/4`)
- Modify: `.dialyzer_ignore.exs` (the memory migration's `unmatched_return`, same reason as the session store's)
- Modify: `docs/guides/agent-memory.md` (limits table, Postgres and Redis notes)
- Modify: `test/support/memory_stub_stores.ex` (9 stubs → `put/6`; delete `CapListDownStore`)
- Modify: `test/support/memory_store_contract.ex` (`describe "put/6 limits"`, 8 cases)
- Test: `test/tools/memory_test.exs` (3 obsolete cases replaced by 2, 4 added), `test/behaviours/memory_store/docs_test.exs`, `postgres_test.exs`, `redis_test.exs`
- Modify: `MIGRATING-2.0.md` (`## 34.`)

**Interfaces:**
- Consumes: nothing from earlier Wave 5 tasks. The `MemoryStore` behaviour, its Postgres migration and its Redis key layout were never released (`git ls-tree -r v1.3.0` has no `memory_store` file; added `368c3ba`, 2026-10-03), so they change in place with no upgrade path.
- Produces: `@callback put(handle, ns, path, content, version | :new | :any, limits) :: {:ok, version} | {:error, :conflict} | {:error, {:namespace_full, :bytes | :documents, non_neg_integer()}} | {:error, term}`; `MemoryStore.limits` and `MemoryStore.namespace_full` types; `MemoryStore.check_limits/3` (public, documented: the rule); `@doc false MemoryStore.validate_limits!/2` (unknown or mistyped key → `ArgumentError` `"<Impl>.put/6: unknown option :x; supported: :max_bytes, :max_documents"`); every backend `put(h, ns, path, content, expected, limits \\ [])` (so `put/5` = no limits; the 53 test call sites of `put/5` keep working); `Memory` option `max_namespace_documents` (default `1000`, `nil` = off); the model-facing message `"Error: memory is full: creating #{path} would make #{n} files; the limit is #{max}. Delete files first."` (the bytes message is unchanged); Postgres table `normandy_memory_namespaces(namespace text PK, bytes bigint not null default 0, documents integer not null default 0)`; Redis key `#{prefix}:mem:{#{b64(ns)}}:bytes`.

Design notes:
- **The rule lives once.** `MemoryStore.check_limits(limits, {bytes_before, docs_before}, {bytes_after, docs_after})`: bytes first, each limit refuses only a write that raises its total above the limit. InMemory, ETS and Mnesia run `Docs.put/5` inside their serialized writer (Agent call, ETS owner, Mnesia transaction with a `:write` lock on the namespace row), where the whole namespace map is in hand: totals are computed exactly, no counter and no schema change (Mnesia keeps `attributes: [:namespace, :docs]`, pinned by `mnesia_test.exs`).
- **Postgres tracks** (decision 12b, 5.4 Q8): every write (`put`, `delete`, `delete_tree`, `rename`, `delete_namespace`) is one transaction that first upserts-and-locks the namespace's counter row (`INSERT ... ON CONFLICT (namespace) DO UPDATE ... RETURNING bytes, documents`). Writers of one namespace therefore run one at a time and take locks in one order (counter row, then document rows), so the counters cannot drift from the store's own writes and a rename cannot race a put's document count. A refused or conflicting put calls `repo.rollback(reason)` → `{:error, reason}`. `repo.query!` inside the transaction keeps the existing failure contract: `MissingTableRepo`'s `Postgrex.Error` and `ConnectionLostRepo`'s `DBConnection.ConnectionError` still come back as `{:error, exception}` through `backend/1` (verified). `RacingRepo` only intercepts rename's 4-parameter `UPDATE`; the counter `UPDATE` has 3 parameters and the lock is an `INSERT`, so the race test is unchanged (verified). `rename/4` keeps its unique-violation rescue for rows written by other SQL.
- **Redis** keeps the count it already has (`ZCARD idx`) and adds a byte counter key in the same hash tag, declared in `KEYS`; `@put` checks the limits after the version check (`{-2, bytes}` / `{-3, documents}`), `@delete` and `@delete_tree` subtract `HSTRLEN` and drop the counter when the index empties, `@delete_namespace` deletes it. `@rename` is unchanged. Lua's `string.len` counts bytes.
- **The tool** stops listing: `others_bytes/3` and `within_cap/4` go (they read one list page, Surprise 7) and `edit/7` loses its `others` parameter; the store re-checks on every compare-and-set attempt. `fits/3` (per-document bytes) and `create`'s `not_directory`/`not_under_file` checks stay.

- [ ] **Step 1: Write the failing tests**

In `test/support/memory_store_contract.ex`, before `# Review Focus #3: concurrent edits through the memory tool keep every edit.`, add:

```elixir
      describe "put/6 limits" do
        test "the byte and document limits count every document, past the list limit", %{
          handle: h,
          ns: ns
        } do
          limit = MemoryStore.list_limit()

          for i <- 1..(limit + 1) do
            path = "/memories/f#{String.pad_leading("#{i}", 5, "0")}"
            {:ok, 1} = @store.put(h, ns, path, "x", :new, max_documents: nil)
          end

          assert {:error, {:namespace_full, :bytes, 1002}} =
                   @store.put(h, ns, "/memories/g", "y", :new, max_bytes: limit + 1)

          assert {:error, {:namespace_full, :documents, 1002}} =
                   @store.put(h, ns, "/memories/g", "y", :new, max_documents: limit + 1)

          assert {:ok, 1} = @store.put(h, ns, "/memories/g", "y", :new, max_bytes: limit + 2)
        end

        test "a new document past the count is refused and not written; an overwrite is not", %{
          handle: h,
          ns: ns
        } do
          lim = [max_documents: 3]

          for p <- ~w(/memories/a /memories/b /memories/c),
              do: {:ok, 1} = @store.put(h, ns, p, "x", :new, lim)

          assert {:error, {:namespace_full, :documents, 4}} =
                   @store.put(h, ns, "/memories/d", "x", :any, lim)

          assert :not_found = @store.get(h, ns, "/memories/d")
          assert {:ok, 2} = @store.put(h, ns, "/memories/a", "xx", :any, lim)
          assert {:ok, 3} = @store.put(h, ns, "/memories/a", "xxx", 2, lim)
        end

        test "replacing a document counts its old size once", %{handle: h, ns: ns} do
          {:ok, 1} = @store.put(h, ns, "/memories/a", "123456", :new)
          assert {:ok, 2} = @store.put(h, ns, "/memories/a", "1234567890", :any, max_bytes: 10)

          assert {:error, {:namespace_full, :bytes, 11}} =
                   @store.put(h, ns, "/memories/a", "12345678901", 2, max_bytes: 10)

          assert {:ok, %{content: "1234567890", version: 2}} = @store.get(h, ns, "/memories/a")
        end

        test "a write that does not grow the namespace is allowed over a lowered limit", %{
          handle: h,
          ns: ns
        } do
          {:ok, 1} = @store.put(h, ns, "/memories/a", "1234567890", :new)
          {:ok, 1} = @store.put(h, ns, "/memories/b", "12345", :new)
          lim = [max_bytes: 5, max_documents: 1]

          assert {:ok, 2} = @store.put(h, ns, "/memories/a", "123", 1, lim)
          assert {:ok, 3} = @store.put(h, ns, "/memories/a", "123", :any, lim)

          assert {:error, {:namespace_full, :bytes, 9}} =
                   @store.put(h, ns, "/memories/a", "1234", 3, lim)

          assert {:error, {:namespace_full, :documents, 3}} =
                   @store.put(h, ns, "/memories/c", "", :new, lim)
        end

        test "bytes are checked before documents, and a version conflict before both", %{
          handle: h,
          ns: ns
        } do
          {:ok, 1} = @store.put(h, ns, "/memories/a", "12345", :new)
          lim = [max_bytes: 5, max_documents: 1]

          assert {:error, {:namespace_full, :bytes, 6}} =
                   @store.put(h, ns, "/memories/b", "1", :new, lim)

          assert {:error, :conflict} = @store.put(h, ns, "/memories/a", "123456", :new, lim)
          assert {:error, :conflict} = @store.put(h, ns, "/memories/a", "123456", 7, lim)
        end

        # Review Focus #5. On Postgres the sandbox serializes both writers on one
        # connection, so this proves the check, not row-lock contention.
        test "two writers that fit alone but not together: one succeeds, one is full", %{
          handle: h,
          ns: ns
        } do
          parent = self()

          tasks =
            for p <- ["/memories/x", "/memories/y"] do
              Task.async(fn ->
                send(parent, {:ready, self()})

                receive do
                  :go -> @store.put(h, ns, p, "123456", :new, max_bytes: 10)
                end
              end)
            end

          for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
          Enum.each(tasks, &send(&1.pid, :go))
          results = Enum.map(tasks, &Task.await(&1, 5_000))

          assert Enum.sort(results) == [{:error, {:namespace_full, :bytes, 12}}, {:ok, 1}]
          assert {:ok, [_one]} = @store.list(h, ns, "/memories")
        end

        test "delete, delete_tree, rename and delete_namespace keep the totals", %{
          handle: h,
          ns: ns
        } do
          lim = [max_bytes: 10, max_documents: 3]
          {:ok, 1} = @store.put(h, ns, "/memories/a", "12345", :new, lim)
          {:ok, 1} = @store.put(h, ns, "/memories/d/1", "12", :new, lim)
          {:ok, 1} = @store.put(h, ns, "/memories/d/2", "12", :new, lim)

          assert {:error, {:namespace_full, :documents, 4}} =
                   @store.put(h, ns, "/memories/b", "", :new, lim)

          assert :ok = @store.delete(h, ns, "/memories/a", :any)
          assert {:ok, 1} = @store.put(h, ns, "/memories/b", "123456", :new, lim)
          assert {:ok, 2} = @store.rename(h, ns, "/memories/d", "/memories/e")

          assert {:error, {:namespace_full, :bytes, 11}} =
                   @store.put(h, ns, "/memories/c", "1", :new, lim)

          assert {:ok, 2} = @store.delete_tree(h, ns, "/memories/e")
          assert {:ok, 1} = @store.put(h, ns, "/memories/c", "1234", :new, lim)
          assert :ok = @store.delete(h, ns, "/memories/c", 1)
          assert {:ok, 2} = @store.put(h, ns, "/memories/b", "1234567890", 1, lim)

          assert :ok = @store.delete_namespace(h, ns)
          assert {:ok, 1} = @store.put(h, ns, "/memories/z", "1234567890", :new, lim)
          assert {:ok, 1} = @store.put(h, ns, "/memories/y", "", :new, lim)
        end

        test "an unknown limit raises, naming put/6", %{handle: h, ns: ns} do
          assert_raise ArgumentError,
                       "#{inspect(@store)}.put/6: unknown option :max_byte; supported: :max_bytes, :max_documents",
                       fn -> @store.put(h, ns, "/memories/a", "x", :new, max_byte: 1) end
        end
      end
```

In `test/behaviours/memory_store/docs_test.exs`, before `describe "Docs (pure)" do`, add:

```elixir
  test "check_limits/3: bytes first, then documents; a write that does not grow passes" do
    lim = [max_bytes: 10, max_documents: 2]
    assert MemoryStore.check_limits(lim, {5, 1}, {10, 2}) == :ok

    assert MemoryStore.check_limits(lim, {5, 1}, {11, 3}) ==
             {:error, {:namespace_full, :bytes, 11}}

    assert MemoryStore.check_limits(lim, {5, 1}, {6, 3}) ==
             {:error, {:namespace_full, :documents, 3}}

    assert MemoryStore.check_limits(lim, {20, 5}, {19, 5}) == :ok

    assert MemoryStore.check_limits(lim, {20, 5}, {20, 6}) ==
             {:error, {:namespace_full, :documents, 6}}

    assert MemoryStore.check_limits([], {0, 0}, {10_000_000, 10_000}) == :ok
    assert MemoryStore.check_limits([max_bytes: nil, max_documents: nil], {0, 0}, {9, 9}) == :ok
  end
```

and inside `describe "Docs (pure)"`, before `test "delete_tree counts and keeps siblings"`, add:

```elixir
    test "put/5 checks the namespace's totals and writes nothing when full" do
      {{:ok, 1}, d} = Docs.put(%{}, "/memories/a", "12345", :new, max_bytes: 10)

      assert {{:error, {:namespace_full, :bytes, 11}}, ^d} =
               Docs.put(d, "/memories/b", "123456", :new, max_bytes: 10)

      assert {{:error, {:namespace_full, :documents, 2}}, ^d} =
               Docs.put(d, "/memories/b", "", :new, max_documents: 1)

      assert {{:ok, 2}, _d} = Docs.put(d, "/memories/a", "1234567890", :any, max_bytes: 10)
    end
```

In `test/behaviours/memory_store/postgres_test.exs`, before `use Normandy.MemoryStoreContract, ...`, add:

```elixir
  defp totals(ns) do
    %{rows: rows} =
      Normandy.TestRepo.query!(
        "SELECT bytes, documents FROM normandy_memory_namespaces WHERE namespace = $1",
        [ns]
      )

    rows
  end

  test "the namespace counter row follows every write and goes with the namespace" do
    repo = Normandy.TestRepo
    ns = "counters-#{System.unique_integer([:positive])}"

    {:ok, 1} = Postgres.put(repo, ns, "/memories/a", "12345", :new)
    {:ok, 1} = Postgres.put(repo, ns, "/memories/b/c", "日本", :new)
    assert totals(ns) == [[11, 2]]

    {:ok, 2} = Postgres.put(repo, ns, "/memories/a", "1", 1)
    assert totals(ns) == [[7, 2]]

    {:ok, 1} = Postgres.rename(repo, ns, "/memories/b", "/memories/d")
    assert totals(ns) == [[7, 2]]

    :ok = Postgres.delete(repo, ns, "/memories/a", 2)
    assert totals(ns) == [[6, 1]]

    {:ok, 1} = Postgres.delete_tree(repo, ns, "/memories/d")
    assert totals(ns) == [[0, 0]]

    {:ok, 1} = Postgres.put(repo, ns, "/memories/a", "x", :new)
    :ok = Postgres.delete_namespace(repo, ns)
    assert totals(ns) == []
  end

  test "a refused put rolls back: no document and no counter change" do
    repo = Normandy.TestRepo
    ns = "refused-#{System.unique_integer([:positive])}"
    {:ok, 1} = Postgres.put(repo, ns, "/memories/a", "12345", :new)

    assert {:error, {:namespace_full, :bytes, 10}} =
             Postgres.put(repo, ns, "/memories/b", "12345", :new, max_bytes: 9)

    assert {:error, :conflict} = Postgres.put(repo, ns, "/memories/a", "x", :new)
    assert :not_found = Postgres.get(repo, ns, "/memories/b")
    assert totals(ns) == [[5, 1]]
  end
```

In `test/behaviours/memory_store/redis_test.exs`, before `# A separate connection: the test's own may already be gone when on_exit runs.`, add:

```elixir
  test "the byte counter holds the namespace's content bytes and goes with its last document",
       %{handle: {conn, prefix} = h, ns: ns} do
    # the key layout of Redis.bytes_key/2
    bytes_key = "#{prefix}:mem:{#{Base.url_encode64(ns, padding: false)}}:bytes"
    {:ok, 1} = Redis.put(h, ns, "/memories/a", "12345", :new)
    {:ok, 1} = Redis.put(h, ns, "/memories/b/c", "日本", :new)
    assert {:ok, "11"} = Redix.command(conn, ["GET", bytes_key])

    :ok = Redis.delete(h, ns, "/memories/a", :any)
    assert {:ok, "6"} = Redix.command(conn, ["GET", bytes_key])

    {:ok, 1} = Redis.delete_tree(h, ns, "/memories/b")
    assert {:ok, nil} = Redix.command(conn, ["GET", bytes_key])

    {:ok, 1} = Redis.put(h, ns, "/memories/a", "12345", :new)
    :ok = Redis.delete_namespace(h, ns)
    assert {:ok, nil} = Redix.command(conn, ["GET", bytes_key])
  end
```

In `test/support/memory_stub_stores.ex`:
- every `def put(_, _, _, _, _)` becomes `def put(_, _, _, _, _, _)` and `RawErrorStore`'s `def put(reason, _, _, _, _)` becomes `def put(reason, _, _, _, _, _)` (`grep -c "def put(" test/support/memory_stub_stores.ex` → 9 before; after the deletion below, 8);
- delete the whole `defmodule Normandy.Test.CapListDownStore do ... end` (its only test is deleted below; nothing lists the namespace root any more);
- `RecordingStore`: moduledoc `"A MemoryStore whose handle is a pid that is told about every get, list and put (with its limits); nothing is ever stored."`, and its `put` becomes

```elixir
  def put(pid, _, _, _, _, limits) do
    send(pid, {:call, :put, limits})
    {:ok, 1}
  end
```

(`"rename to an equal or shorter path makes no get or list call"` keeps passing: it refutes `{:call, _}`, a 2-tuple, and rename never puts.)
- `CountingStore`: moduledoc `"A MemoryStore (handle: a pid) that reports every list and put (with its limits) and whose writes always conflict."`, and its `put` becomes

```elixir
  def put(pid, _, _, _, _, limits) do
    send(pid, {:put, limits})
    {:error, :conflict}
  end
```

In `test/tools/memory_test.exs`, `describe "deferred batch B"`: remove `CapListDownStore,` from the `alias Normandy.Test.{...}` list, and replace the three tests that pin the list-based cap (`"nil disables the cap and lists nothing"`, `"a list failure during the cap check goes through the backend mapping"` with its `@tag :capture_log`, and `"the cap is listed once for an edit even when it retries"`) with:

```elixir
    test "every write passes the tool's caps to the store, nil included" do
      t = Memory.new(store: {RecordingStore, self()}, max_namespace_bytes: nil)
      assert {:ok, _, _} = create_in(t, "/memories/a", String.duplicate("x", 5_000))
      assert_received {:call, :put, [max_bytes: nil, max_documents: 1000]}
      # the only list is not_directory's, at the document's own path: no cap listing
      assert_received {:call, :list}
      refute_received {:call, :list}

      t = Memory.new(store: {RecordingStore, self()}, max_namespace_documents: nil)
      assert {:ok, _, _} = create_in(t, "/memories/a", "x")
      assert_received {:call, :put, [max_bytes: 1_000_000, max_documents: nil]}
    end

    test "an edit passes the caps on every compare-and-set attempt and lists nothing" do
      t = Memory.new(store: {CountingStore, self()}, max_cas_retries: 2)

      assert {:error, :conflict_exhausted, _} =
               typed(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "alpha",
                 "new_str" => "beta"
               })

      for _attempt <- 1..3,
          do: assert_received({:put, [max_bytes: 1_000_000, max_documents: 1000]})

      refute_received {:put, _}
      refute_received :listed
    end

    test "max_namespace_documents: default, nil, and bad values" do
      assert tool().max_namespace_documents == 1000
      assert tool(max_namespace_documents: nil).max_namespace_documents == nil
      assert tool(max_namespace_documents: 5).max_namespace_documents == 5

      for bad <- [0, -1, 1.5, "x"] do
        assert_raise ArgumentError,
                     ~r/:max_namespace_documents must be a positive integer or nil, got: #{inspect(bad)}/,
                     fn -> tool(max_namespace_documents: bad) end
      end
    end

    test "a create past the document cap is refused; overwriting a file is not" do
      store = InMemory.new()
      t = Memory.new(store: {InMemory, store}, max_namespace_documents: 2)
      assert {:ok, _, _} = create_in(t, "/memories/a", "1")
      assert {:ok, _, _} = create_in(t, "/memories/b", "2")

      assert {:error, :namespace_full,
              "Error: memory is full: creating /memories/c would make 3 files; the limit is 2. Delete files first."} =
               create_in(t, "/memories/c", "3")

      assert InMemory.get(store, "acme/u-1", "/memories/c") == :not_found
      assert {:ok, _, _} = create_in(t, "/memories/b", "two")
    end

    test "the caps are independent: no byte cap still counts documents, and the reverse" do
      store = InMemory.new()

      t =
        Memory.new(
          store: {InMemory, store},
          max_document_bytes: 2_000_000,
          max_namespace_bytes: nil,
          max_namespace_documents: 1
        )

      assert {:ok, _, _} = create_in(t, "/memories/a", String.duplicate("x", 2_000_000))

      assert {:error, :namespace_full, "Error: memory is full: creating /memories/b" <> _} =
               create_in(t, "/memories/b", "x")

      t = Memory.new(store: {InMemory, store}, max_namespace_documents: nil)

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/c would bring it to 2000001 bytes; the limit is 1000000. Delete or shorten files first."} =
               create_in(t, "/memories/c", "x")
    end

    test "a namespace over a lowered cap can still be shortened, not grown" do
      store = InMemory.new()
      create_in(Memory.new(store: {InMemory, store}), "/memories/a", "1234567890")
      t = Memory.new(store: {InMemory, store}, max_namespace_bytes: 5)

      assert {:ok, _, _} =
               typed(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "12345",
                 "new_str" => ""
               })

      assert doc(store, "acme/u-1", "/memories/a") == "67890"

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/a would bring it to 6 bytes; the limit is 5. Delete or shorten files first."} =
               typed(t, %{
                 "command" => "insert",
                 "path" => "/memories/a",
                 "insert_line" => 0,
                 "insert_text" => ""
               })
    end
```

The four existing cap tests (`"a create that would exceed the namespace cap is refused and nothing is written"`, `"str_replace and insert that would exceed the cap are refused, the document is unchanged"`, `"replacing a document does not count its old size twice"`, `"the cap counts the mount's namespace for a mounted path"`) and `"max_namespace_bytes: default, nil, and bad values"` stay as they are: the store returns the would-be total and the tool keeps the same text.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/tools/memory_test.exs test/behaviours/memory_store`
Expected: FAIL. Compile warnings that the stubs do not implement `put/5` (until Step 3), `UndefinedFunctionError` for `InMemory.put/6`, `ETS.put/6`, `Mnesia.put/6` and `MemoryStore.check_limits/3`, `Docs.put/5` undefined, and `Memory.new/1` raising `unknown option :max_namespace_documents`.

- [ ] **Step 3: The behaviour and `Docs`**

In `lib/normandy/behaviours/memory_store.ex`, append to the moduledoc's semantics list (after the `delete_tree/3` and `delete_namespace/2` bullet):

```
    * `put/6` takes `limits`: `:max_bytes` (the namespace's total content bytes) and
      `:max_documents` (its document count), each a positive integer or `nil` (no
      limit); a key left out is `nil`. A `put` that would raise the bytes above
      `:max_bytes`, or the count above `:max_documents`, writes nothing and returns
      `{:error, {:namespace_full, :bytes | :documents, would_be}}` (bytes are checked
      first). The check and the write are one atomic step, so two writers that each fit
      alone but not together get one success and one `:namespace_full`, and the totals
      count every document (no list limit). A `put` that does not raise the bytes, or
      does not raise the count, is never refused for that limit, so a namespace already
      over a lowered limit can still shrink. A version conflict wins over a limit.
      `check_limits/3` is the rule; every backend implements `put/6` with
      `limits \\ []`, so `put/5` writes with no limit.
```

After `@type entry ...` add:

```elixir
  @type limits :: [max_bytes: pos_integer() | nil, max_documents: pos_integer() | nil]
  @type namespace_full :: {:namespace_full, :bytes | :documents, non_neg_integer()}
```

Replace the `put` callback:

```elixir
  @callback put(
              handle(),
              namespace(),
              path(),
              content :: String.t(),
              version() | :new | :any,
              limits()
            ) ::
              {:ok, version()}
              | {:error, :conflict}
              | {:error, namespace_full()}
              | {:error, term()}
```

After `@list_limit 1000` add:

```elixir
  @limits_schema NimbleOptions.new!(
                   max_bytes: [
                     type: {:or, [:pos_integer, nil]},
                     default: nil,
                     doc: "The namespace's most content bytes; `nil` = no limit."
                   ],
                   max_documents: [
                     type: {:or, [:pos_integer, nil]},
                     default: nil,
                     doc: "The namespace's most documents; `nil` = no limit."
                   ]
                 )

  @doc false
  # Every backend's put/6 checks its limits here first; an unknown or mistyped key raises
  # ArgumentError naming `impl.put/6`.
  @spec validate_limits!(term(), module()) :: limits()
  def validate_limits!(limits, impl),
    do: Normandy.Options.validate!(limits, @limits_schema, {impl, :put, 6})

  @doc """
  The limits rule of `put/6`, for a write that takes a namespace from `before` to `after`
  (each `{bytes, documents}`): `{:error, {:namespace_full, :bytes, bytes}}` when it raises
  the bytes above `:max_bytes`, else `{:error, {:namespace_full, :documents, documents}}`
  when it raises the count above `:max_documents`, else `:ok`.
  """
  @spec check_limits(
          limits(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: :ok | {:error, namespace_full()}
  def check_limits(limits, {bytes_before, docs_before}, {bytes_after, docs_after}) do
    cond do
      over?(Keyword.get(limits, :max_bytes), bytes_before, bytes_after) ->
        {:error, {:namespace_full, :bytes, bytes_after}}

      over?(Keyword.get(limits, :max_documents), docs_before, docs_after) ->
        {:error, {:namespace_full, :documents, docs_after}}

      true ->
        :ok
    end
  end

  defp over?(nil, _was, _will_be), do: false
  defp over?(max, was, will_be), do: will_be > was and will_be > max
```

In `lib/normandy/behaviours/memory_store/docs.ex`, replace `put/4` with:

```elixir
  # `limits` are validated (MemoryStore.validate_limits!/2). The whole namespace is in
  # hand, so its totals are exact: no counter to keep.
  def put(docs, path, content, expected, limits \\ []) do
    current = Map.get(docs, path)
    before = totals(docs)

    with {:ok, version} <- next_version(current && current.version, expected),
         :ok <- MemoryStore.check_limits(limits, before, after_put(before, current, content)) do
      write(docs, path, content, version)
    else
      {:error, _reason} = error -> {error, docs}
    end
  end

  @doc false
  # Compare-and-set on a document's current version (`nil` when it is missing). Shared
  # with the Postgres backend.
  @spec next_version(pos_integer() | nil, pos_integer() | :new | :any) ::
          {:ok, pos_integer()} | {:error, :conflict}
  def next_version(nil, expected) when expected in [:new, :any], do: {:ok, 1}
  def next_version(version, :any) when is_integer(version), do: {:ok, version + 1}
  def next_version(version, version) when is_integer(version), do: {:ok, version + 1}
  def next_version(_version, _expected), do: {:error, :conflict}

  defp totals(docs),
    do:
      {Enum.reduce(docs, 0, fn {_path, d}, sum -> sum + byte_size(d.content) end), map_size(docs)}

  defp after_put({bytes, count}, nil, content), do: {bytes + byte_size(content), count + 1}

  defp after_put({bytes, count}, %{content: old}, content),
    do: {bytes - byte_size(old) + byte_size(content), count}
```

`test/behaviours/memory_store/docs_test.exs`'s existing `Docs.put/4` calls keep working through the default.

- [ ] **Step 4: InMemory, ETS and Mnesia**

`lib/normandy/behaviours/memory_store/in_memory.ex`: add `alias Normandy.Behaviours.MemoryStore` before `alias Normandy.Behaviours.MemoryStore.Docs`, and replace `put/5`:

```elixir
  @impl true
  def put(pid, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    update(pid, ns, &Docs.put(&1, path, content, expected, limits))
  end
```

`lib/normandy/behaviours/memory_store/ets.ex`: the same alias, and (validated in the caller, so a bad key raises there, not in the owner):

```elixir
  @impl Normandy.Behaviours.MemoryStore
  def put({pid, _}, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    GenServer.call(pid, {:apply, ns, :put, [path, content, expected, limits]})
  end
```

(`handle_call({:apply, ns, fun, args}, ...)` applies `Docs.put/5` with the extra argument; no other change.)

`lib/normandy/behaviours/memory_store/mnesia.ex`: the same alias, and

```elixir
  @impl true
  def put(table, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    update(table, ns, &Docs.put(&1, path, content, expected, limits))
  end
```

`@impl true` on a function with a default argument covers `put/6`; the compiler emits no warning for the generated `put/5` (verified).

- [ ] **Step 5: Postgres**

In `lib/normandy/behaviours/memory_store/postgres/migration.ex`, replace `up/0` and `down/0`:

```elixir
    def up do
      create table(:normandy_memory_documents, primary_key: false) do
        add(:namespace, :text, primary_key: true)
        add(:path, :text, primary_key: true)
        add(:content, :text, null: false)
        add(:version, :integer, null: false)
        add(:updated_at, :utc_datetime_usec, null: false)
      end

      # Each namespace's content bytes and document count, kept by the store's writes
      # for put/6's limits.
      create table(:normandy_memory_namespaces, primary_key: false) do
        add(:namespace, :text, primary_key: true)
        add(:bytes, :bigint, null: false, default: 0)
        add(:documents, :integer, null: false, default: 0)
      end
    end

    def down do
      drop(table(:normandy_memory_namespaces))
      drop(table(:normandy_memory_documents))
    end
```

Replace `lib/normandy/behaviours/memory_store/postgres.ex` with:

```elixir
if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Normandy.Behaviours.MemoryStore.Postgres do
    @moduledoc """
    Durable, cluster-shared `MemoryStore` over Postgres. The handle is the host's Ecto
    Repo module; run `Normandy.Behaviours.MemoryStore.Postgres.Migration` from a host
    migration.

    Every write (`put`, `delete`, `delete_tree`, `rename`, `delete_namespace`) is one
    transaction that first locks the namespace's row in `normandy_memory_namespaces`,
    which tracks the namespace's content bytes and document count for `put/6`'s limits.
    So the writers of one namespace run one at a time, and compare-and-set, the limits
    check and the counters change atomically with the document. `rename/4` also locks the
    moving rows `FOR UPDATE`. Prefixes match with `starts_with/2` (nothing to escape);
    listing orders by `path COLLATE "C"` (byte order).

    The counters are kept by these functions only: a row written to
    `normandy_memory_documents` by other SQL is not counted, and the limits then count
    wrong for its namespace.
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore
    alias Normandy.Behaviours.MemoryStore.Docs

    @table "normandy_memory_documents"
    @namespaces "normandy_memory_namespaces"

    @doc "Test/default handle: the Repo configured for :normandy."
    @spec new() :: module()
    def new, do: hd(Application.fetch_env!(:normandy, :ecto_repos))

    @impl true
    def list(repo, ns, prefix) do
      backend(fn ->
        sql = """
        SELECT path, octet_length(content), updated_at FROM #{@table}
        WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3))
        ORDER BY path COLLATE "C" LIMIT $4
        """

        with {:ok, %{rows: rows}} <-
               repo.query(sql, [ns, prefix, prefix <> "/", MemoryStore.list_limit()]) do
          {:ok,
           Enum.map(rows, fn [path, size, at] ->
             %{path: path, size: size, updated_at: utc(at)}
           end)}
        end
      end)
    end

    @impl true
    def get(repo, ns, path) do
      backend(fn ->
        case repo.query(
               "SELECT content, version FROM #{@table} WHERE namespace = $1 AND path = $2",
               [
                 ns,
                 path
               ]
             ) do
          {:ok, %{rows: [[content, version]]}} -> {:ok, %{content: content, version: version}}
          {:ok, %{rows: []}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def put(repo, ns, path, content, expected, limits \\ []) do
      limits = MemoryStore.validate_limits!(limits, __MODULE__)

      in_transaction(repo, fn ->
        {bytes, documents} = lock_totals(repo, ns)
        {version, size} = current(repo, ns, path)
        totals = {bytes - size + byte_size(content), documents + if(version, do: 0, else: 1)}

        with {:ok, next} <- Docs.next_version(version, expected),
             :ok <- MemoryStore.check_limits(limits, {bytes, documents}, totals) do
          write(repo, ns, path, content, next)
          set_totals(repo, ns, totals)
          {:ok, next}
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end

    @impl true
    def delete(repo, ns, path, :any) do
      in_transaction(repo, fn ->
        totals = lock_totals(repo, ns)

        case repo.query!(
               "DELETE FROM #{@table} WHERE namespace = $1 AND path = $2 RETURNING octet_length(content)",
               [ns, path]
             ) do
          %{rows: [[size]]} -> release(repo, ns, totals, [size])
          %{rows: []} -> :not_found
        end
      end)
    end

    def delete(repo, ns, path, version) when is_integer(version) do
      # The outer SELECT sees the snapshot before the CTE's DELETE, so its count tells a
      # stale version (conflict) from a missing document; `size` is the deleted bytes.
      sql = """
      WITH d AS (DELETE FROM #{@table} WHERE namespace = $1 AND path = $2 AND version = $3 RETURNING octet_length(content) AS size)
      SELECT (SELECT size FROM d), (SELECT count(*) FROM #{@table} WHERE namespace = $1 AND path = $2)
      """

      in_transaction(repo, fn ->
        totals = lock_totals(repo, ns)

        case repo.query!(sql, [ns, path, version]) do
          %{rows: [[nil, 1]]} -> {:error, :conflict}
          %{rows: [[nil, 0]]} -> :not_found
          %{rows: [[size, _]]} -> release(repo, ns, totals, [size])
        end
      end)
    end

    @impl true
    def delete_tree(repo, ns, prefix) do
      sql =
        "DELETE FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3)) RETURNING octet_length(content)"

      in_transaction(repo, fn ->
        totals = lock_totals(repo, ns)
        %{rows: rows} = repo.query!(sql, [ns, prefix, prefix <> "/"])
        sizes = List.flatten(rows)
        if sizes != [], do: release(repo, ns, totals, sizes)
        {:ok, length(sizes)}
      end)
    end

    @impl true
    def rename(repo, ns, from, to) do
      backend(fn ->
        try do
          repo.transaction(fn -> rename_in_transaction(repo, ns, from, to) end)
          |> case do
            {:ok, reply} -> reply
            {:error, _} = error -> error
          end
        rescue
          # A concurrent put(:new) or rename into `to` created the destination after
          # destination_taken?/3 looked; the UPDATE lost the unique-key race. The
          # transaction has already rolled back.
          e in Postgrex.Error ->
            case e do
              %{postgres: %{code: :unique_violation}} -> {:error, :exists}
              _ -> reraise e, __STACKTRACE__
            end
        end
      end)
    end

    defp rename_in_transaction(repo, ns, from, to) do
      # Moves documents within the namespace: bytes and count stay, but the counter row
      # lock keeps rename and the other writers in one order.
      _totals = lock_totals(repo, ns)
      moving = lock_moving(repo, ns, from)

      cond do
        moving == [] ->
          :not_found

        destination_taken?(repo, ns, to) ->
          {:error, :exists}

        true ->
          %{num_rows: n} =
            repo.query!(
              "UPDATE #{@table} SET path = $3::text || substr(path, length($2::text) + 1) WHERE namespace = $1 AND path = ANY($4::text[])",
              [ns, from, to, moving]
            )

          {:ok, n}
      end
    end

    @impl true
    def delete_namespace(repo, ns) do
      # The counter row goes first: its lock waits for the namespace's writers in flight.
      in_transaction(repo, fn ->
        repo.query!("DELETE FROM #{@namespaces} WHERE namespace = $1", [ns])
        repo.query!("DELETE FROM #{@table} WHERE namespace = $1", [ns])
        :ok
      end)
    end

    # One transaction per write. `repo.rollback(reason)` makes the reply
    # `{:error, reason}`; a raised Postgrex error rolls back and is backend/1's.
    defp in_transaction(repo, fun) do
      backend(fn ->
        case repo.transaction(fun) do
          {:ok, reply} -> reply
          {:error, _reason} = error -> error
        end
      end)
    end

    # Every write locks the namespace's counter row first (creating it on the first write),
    # so the namespace's writers take their locks in one order and the counters match the
    # documents. Returns {bytes, documents} as of the lock.
    defp lock_totals(repo, ns) do
      %{rows: [[bytes, documents]]} =
        repo.query!(
          """
          INSERT INTO #{@namespaces} (namespace, bytes, documents) VALUES ($1, 0, 0)
          ON CONFLICT (namespace) DO UPDATE SET bytes = #{@namespaces}.bytes
          RETURNING bytes, documents
          """,
          [ns]
        )

      {bytes, documents}
    end

    defp set_totals(repo, ns, {bytes, documents}) do
      repo.query!(
        "UPDATE #{@namespaces} SET bytes = $2, documents = $3 WHERE namespace = $1",
        [ns, bytes, documents]
      )
    end

    # Takes the deleted documents' sizes off the totals; the reply of a delete.
    defp release(repo, ns, {bytes, documents}, sizes) do
      set_totals(repo, ns, {bytes - Enum.sum(sizes), documents - length(sizes)})
      :ok
    end

    # {version, content bytes} of the document at `path`, or {nil, 0}.
    defp current(repo, ns, path) do
      case repo.query!(
             "SELECT version, octet_length(content) FROM #{@table} WHERE namespace = $1 AND path = $2",
             [ns, path]
           ) do
        %{rows: [[version, size]]} -> {version, size}
        %{rows: []} -> {nil, 0}
      end
    end

    defp write(repo, ns, path, content, version) do
      repo.query!(
        """
        INSERT INTO #{@table} (namespace, path, content, version, updated_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (namespace, path) DO UPDATE
          SET content = EXCLUDED.content, version = EXCLUDED.version, updated_at = EXCLUDED.updated_at
        """,
        [ns, path, content, version, now()]
      )
    end

    # A document at `from` moves alone; otherwise everything under `from/`.
    defp lock_moving(repo, ns, from) do
      %{rows: own} =
        repo.query!("SELECT path FROM #{@table} WHERE namespace = $1 AND path = $2 FOR UPDATE", [
          ns,
          from
        ])

      case own do
        [[path]] ->
          [path]

        [] ->
          # ORDER BY: overlapping directory renames must take row locks in the same
          # order, or they can deadlock.
          %{rows: rows} =
            repo.query!(
              "SELECT path FROM #{@table} WHERE namespace = $1 AND starts_with(path, $2) ORDER BY path COLLATE \"C\" FOR UPDATE",
              [ns, from <> "/"]
            )

          List.flatten(rows)
      end
    end

    defp destination_taken?(repo, ns, to) do
      %{rows: rows} =
        repo.query!(
          "SELECT 1 FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3)) LIMIT 1",
          [ns, to, to <> "/"]
        )

      rows != []
    end

    defp now, do: NaiveDateTime.utc_now()
    defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

    # A dropped connection or a raised Postgrex error is a backend error, never :not_found.
    defp backend(fun) do
      fun.()
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, e}
    end
  end
end
```

In `.dialyzer_ignore.exs`, after the session-store migration entry (`{"lib/normandy/behaviours/session_store/postgres/migration.ex", :unmatched_return},`), add:

```elixir

  # behaviours/memory_store/postgres/migration.ex up/0 + down/0: the same idiomatic Ecto
  # create/drop calls, two tables (documents and the namespace counters).
  {"lib/normandy/behaviours/memory_store/postgres/migration.ex", :unmatched_return},
```

(Without it `mix dialyzer` reports two `unmatched_return`s: `up/0`'s first `create` and `down/0`'s first `drop` are no longer the last expression.)

- [ ] **Step 6: Redis**

Replace `lib/normandy/behaviours/memory_store/redis.ex` with:

```elixir
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.MemoryStore.Redis do
    @moduledoc """
    Durable `MemoryStore` over Redis. Each document is a hash; each namespace keeps a
    sorted set of its paths (score 0, so lexical order) for listing and prefixes. Every
    write is one Lua script, so compare-and-set, rename and delete_tree are atomic. All of
    a namespace's keys share the `{namespace}` hash tag, so they live in one Redis Cluster
    slot; the scripts derive document keys from the declared index key's prefix.
    A namespace's content bytes live in a counter key beside its index (the document
    count is the index's size), kept by the same scripts, so `put/6`'s limits are checked
    in the write's script.

    The handle is `{conn, prefix}`; the host owns the Redix connection.
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore
    alias Normandy.Options

    @new_opts_schema NimbleOptions.new!(
                       url: [
                         type: :string,
                         type_doc: "`t:String.t/0`",
                         doc: "The Redis URL (default: `config :normandy, :redis_url`)."
                       ],
                       prefix: [type: :string, doc: "The key prefix (default: a unique one)."]
                     )

    # KEYS: index, document, bytes. ARGV: path, content, expected, updated_at, max_bytes,
    # max_documents ('' = no limit). The limits rule is MemoryStore.check_limits/3's.
    @put """
    local cur = redis.call('HGET', KEYS[2], 'version')
    local exp = ARGV[3]
    if exp == 'new' and cur then return -1 end
    if exp ~= 'new' and exp ~= 'any' and cur ~= exp then return -1 end
    local was_bytes = tonumber(redis.call('GET', KEYS[3]) or '0')
    local was_docs = redis.call('ZCARD', KEYS[1])
    local bytes = was_bytes + string.len(ARGV[2])
    local docs = was_docs
    local v = 1
    if cur then
      v = tonumber(cur) + 1
      bytes = bytes - redis.call('HSTRLEN', KEYS[2], 'content')
    else
      docs = docs + 1
    end
    if ARGV[5] ~= '' and bytes > was_bytes and bytes > tonumber(ARGV[5]) then return {-2, bytes} end
    if ARGV[6] ~= '' and docs > was_docs and docs > tonumber(ARGV[6]) then return {-3, docs} end
    redis.call('HSET', KEYS[2], 'content', ARGV[2], 'version', v, 'updated_at', ARGV[4])
    redis.call('ZADD', KEYS[1], 0, ARGV[1])
    redis.call('SET', KEYS[3], bytes)
    return v
    """

    # KEYS: index, document, bytes.
    @delete """
    local cur = redis.call('HGET', KEYS[2], 'version')
    if not cur then return 0 end
    if ARGV[2] ~= 'any' and cur ~= ARGV[2] then return -1 end
    redis.call('DECRBY', KEYS[3], redis.call('HSTRLEN', KEYS[2], 'content'))
    redis.call('DEL', KEYS[2])
    redis.call('ZREM', KEYS[1], ARGV[1])
    if redis.call('ZCARD', KEYS[1]) == 0 then redis.call('DEL', KEYS[3]) end
    return 1
    """

    @list """
    local out = {}
    local function add(p)
      local k = ARGV[1] .. p
      table.insert(out, p)
      table.insert(out, redis.call('HSTRLEN', k, 'content'))
      table.insert(out, redis.call('HGET', k, 'updated_at'))
    end
    if redis.call('ZSCORE', KEYS[1], ARGV[2]) then add(ARGV[2]) end
    local kids = redis.call('ZRANGEBYLEX', KEYS[1], '[' .. ARGV[2] .. '/', '[' .. ARGV[2] .. '/\\255', 'LIMIT', 0, tonumber(ARGV[3]))
    for _, p in ipairs(kids) do add(p) end
    return out
    """

    # KEYS: index, bytes.
    @delete_tree """
    local n = 0
    local freed = 0
    local function del(p)
      local k = ARGV[1] .. p
      freed = freed + redis.call('HSTRLEN', k, 'content')
      redis.call('DEL', k)
      redis.call('ZREM', KEYS[1], p)
      n = n + 1
    end
    if redis.call('ZSCORE', KEYS[1], ARGV[2]) then del(ARGV[2]) end
    for _, p in ipairs(redis.call('ZRANGEBYLEX', KEYS[1], '[' .. ARGV[2] .. '/', '[' .. ARGV[2] .. '/\\255')) do del(p) end
    if n > 0 then redis.call('DECRBY', KEYS[2], freed) end
    if redis.call('ZCARD', KEYS[1]) == 0 then redis.call('DEL', KEYS[2]) end
    return n
    """

    @rename """
    local idx, dp, from, to = KEYS[1], ARGV[1], ARGV[2], ARGV[3]
    local moving
    if redis.call('ZSCORE', idx, from) then
      moving = {from}
    else
      moving = redis.call('ZRANGEBYLEX', idx, '[' .. from .. '/', '[' .. from .. '/\\255')
    end
    if #moving == 0 then return 0 end
    if redis.call('ZSCORE', idx, to) then return -1 end
    if #redis.call('ZRANGEBYLEX', idx, '[' .. to .. '/', '[' .. to .. '/\\255', 'LIMIT', 0, 1) > 0 then return -1 end
    for _, p in ipairs(moving) do
      local np = to .. string.sub(p, #from + 1)
      redis.call('RENAME', dp .. p, dp .. np)
      redis.call('ZREM', idx, p)
      redis.call('ZADD', idx, 0, np)
    end
    return #moving
    """

    # KEYS: index, bytes.
    @delete_namespace """
    for _, p in ipairs(redis.call('ZRANGE', KEYS[1], 0, -1)) do redis.call('DEL', ARGV[1] .. p) end
    redis.call('DEL', KEYS[1], KEYS[2])
    return 1
    """

    @scripts %{
      put: @put,
      delete: @delete,
      list: @list,
      delete_tree: @delete_tree,
      rename: @rename,
      delete_namespace: @delete_namespace
    }
    @shas Map.new(@scripts, fn {k, s} ->
            {k, :crypto.hash(:sha, s) |> Base.encode16(case: :lower)}
          end)

    @doc """
    Test/default handle: a Redix conn to the configured URL and a unique key prefix.

    ## Options

    #{Options.docs(@new_opts_schema)}
    """
    @spec new(keyword()) :: {pid(), String.t()}
    def new(opts \\ []) do
      opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

      url =
        Keyword.get(
          opts,
          :url,
          Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
        )

      {:ok, conn} = Redix.start_link(url)
      {conn, Keyword.get(opts, :prefix, "normandy_test_mem_#{UUID.uuid4()}")}
    end

    @impl true
    def list({conn, _} = h, ns, prefix) do
      with {:ok, flat} <-
             eval(conn, :list, [idx(h, ns)], [doc_prefix(h, ns), prefix, MemoryStore.list_limit()]) do
        entries =
          flat
          |> Enum.chunk_every(3)
          |> Enum.map(fn [path, size, at] ->
            %{path: path, size: size, updated_at: from_micros(at)}
          end)
          |> Enum.take(MemoryStore.list_limit())

        {:ok, entries}
      end
    end

    @impl true
    def get({conn, _} = h, ns, path) do
      case Redix.command(conn, ["HMGET", doc(h, ns, path), "content", "version"]) do
        {:ok, [nil, _]} ->
          :not_found

        {:ok, [content, version]} ->
          {:ok, %{content: content, version: String.to_integer(version)}}

        {:error, _} = error ->
          error
      end
    end

    @impl true
    def put({conn, _} = h, ns, path, content, expected, limits \\ []) do
      limits = MemoryStore.validate_limits!(limits, __MODULE__)

      args = [
        path,
        content,
        expected_arg(expected),
        Integer.to_string(System.os_time(:microsecond)),
        limit_arg(Keyword.fetch!(limits, :max_bytes)),
        limit_arg(Keyword.fetch!(limits, :max_documents))
      ]

      case eval(conn, :put, [idx(h, ns), doc(h, ns, path), bytes_key(h, ns)], args) do
        {:ok, -1} -> {:error, :conflict}
        {:ok, [-2, bytes]} -> {:error, {:namespace_full, :bytes, bytes}}
        {:ok, [-3, documents]} -> {:error, {:namespace_full, :documents, documents}}
        {:ok, version} when is_integer(version) -> {:ok, version}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete({conn, _} = h, ns, path, expected) do
      keys = [idx(h, ns), doc(h, ns, path), bytes_key(h, ns)]

      case eval(conn, :delete, keys, [path, expected_arg(expected)]) do
        {:ok, 1} -> :ok
        {:ok, 0} -> :not_found
        {:ok, -1} -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete_tree({conn, _} = h, ns, prefix),
      do: eval(conn, :delete_tree, [idx(h, ns), bytes_key(h, ns)], [doc_prefix(h, ns), prefix])

    @impl true
    def rename({conn, _} = h, ns, from, to) do
      case eval(conn, :rename, [idx(h, ns)], [doc_prefix(h, ns), from, to]) do
        {:ok, 0} -> :not_found
        {:ok, -1} -> {:error, :exists}
        {:ok, n} -> {:ok, n}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete_namespace({conn, _} = h, ns) do
      with {:ok, 1} <-
             eval(conn, :delete_namespace, [idx(h, ns), bytes_key(h, ns)], [doc_prefix(h, ns)]),
           do: :ok
    end

    # EVALSHA first; on NOSCRIPT (a restarted or flushed server) send the source once.
    defp eval(conn, name, keys, args) do
      args = Enum.map(args, &to_string/1)
      base = [Integer.to_string(length(keys)) | keys ++ args]

      case Redix.command(conn, ["EVALSHA", Map.fetch!(@shas, name) | base]) do
        {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
          Redix.command(conn, ["EVAL", Map.fetch!(@scripts, name) | base])

        other ->
          other
      end
    end

    defp expected_arg(:new), do: "new"
    defp expected_arg(:any), do: "any"
    defp expected_arg(v) when is_integer(v), do: Integer.to_string(v)

    defp limit_arg(nil), do: ""
    defp limit_arg(limit), do: Integer.to_string(limit)

    defp idx({_, prefix}, ns), do: "#{prefix}:mem:{#{enc(ns)}}:idx"
    defp doc_prefix({_, prefix}, ns), do: "#{prefix}:mem:{#{enc(ns)}}:doc:"
    defp bytes_key({_, prefix}, ns), do: "#{prefix}:mem:{#{enc(ns)}}:bytes"

    # URL-safe base64 has no `}` or `:`, so a namespace can never alter the key structure
    # or produce an empty hash tag.
    defp enc(ns), do: Base.url_encode64(ns, padding: false)
    defp doc(h, ns, path), do: doc_prefix(h, ns) <> path

    defp from_micros(at), do: at |> String.to_integer() |> DateTime.from_unix!(:microsecond)
  end
end
```

The script SHAs change, so a server that cached the old scripts gets the new ones through the existing `NOSCRIPT` fallback. The `:bytes` key shares the namespace's hash tag (one cluster slot) and matches `delete_prefix/1`'s `prefix <> "*"` scan in `redis_test.exs`; `"a rename racing a write leaves no orphaned document hash"` scans `tag <> ":doc:*"` and does not see it.

- [ ] **Step 7: The memory tool**

In `lib/normandy/tools/memory.ex`, replace the moduledoc's options and cap paragraphs (from `` `:max_document_bytes` (100_000), `:max_namespace_bytes` (1_000_000), `:max_view_chars` `` through `A mount's cap applies to the mount's namespace.`) with:

```
  `:max_document_bytes` (100_000), `:max_namespace_bytes` (1_000_000),
  `:max_namespace_documents` (1000), `:max_view_chars` (16_000), `:max_cas_retries` (3),
  `:telemetry_include_paths` (false).

  `:max_namespace_bytes` bounds the total content bytes of a namespace's documents and
  `:max_namespace_documents` their number; each is a positive integer, or `nil` for no
  cap, and they apply independently. A `create`, `str_replace` or `insert` that would push
  the namespace past either is refused with error type `:namespace_full` and writes
  nothing. The store checks the caps in the same atomic step as the write
  (`Normandy.Behaviours.MemoryStore` `put/6`), so they hold under concurrent writers and
  count every document. A write that does not grow the namespace is always allowed, so a
  namespace over a lowered cap can still be shortened. A mount's caps apply to the
  mount's namespace.
```

In `defstruct` add `max_namespace_documents: 1000,` after `max_namespace_bytes: 1_000_000,`; in `@type t` add `max_namespace_documents: pos_integer() | nil,` after `max_namespace_bytes: pos_integer() | nil,`; in `@options` add `:max_namespace_documents,` after `:max_namespace_bytes,`. In `new/1`, replace the `check!(:max_namespace_bytes, ...)` call with:

```elixir
    for key <- [:max_namespace_bytes, :max_namespace_documents] do
      value = Map.fetch!(tool, key)

      check!(
        key,
        value,
        is_nil(value) or (is_integer(value) and value > 0),
        "a positive integer or nil"
      )
    end
```

In `lib/normandy/tools/memory/commands.ex`:

`create/3`: drop the two `with` clauses `{:ok, others} <- others_bytes(tool, loc, nil),` and `:ok <- within_cap(tool, loc, others, byte_size(text))` (so the `with` ends at `:ok <- not_under_file(tool, loc) do`), and make the body:

```elixir
      case store(tool, :put, [loc.namespace, loc.path, text, :any, limits(tool)]) do
        {:ok, _version} ->
          {:ok, "File created successfully at: #{loc.model_path}",
           %{bytes_written: byte_size(text)}}

        {:error, {:namespace_full, which, would_be}} ->
          namespace_full(tool, loc, which, would_be)

        {:error, reason} ->
          backend(reason)
      end
```

`edit/7` becomes `edit/6`. Replace its comment and head with:

```elixir
  # Read-modify-write with compare-and-set. A lost race re-reads and re-applies, up to
  # max_cas_retries extra attempts. The store checks the namespace caps on every attempt.
  defp edit(tool, loc, missing, transform, success, attempt \\ 0) do
```

its `with` keeps only `{:ok, updated, info} <- transform.(content),` and `:ok <- fits(tool, loc, updated) do`; the store call becomes `case store(tool, :put, [loc.namespace, loc.path, updated, version, limits(tool)]) do` (keep the `# credo:disable-for-next-line Credo.Check.Refactor.Nesting` above it); the retry becomes `edit(tool, loc, missing, transform, success, attempt + 1)`; and add before the last `{:error, reason} -> backend(reason)` clause:

```elixir
            {:error, {:namespace_full, which, would_be}} ->
              namespace_full(tool, loc, which, would_be)

```

Delete `others_bytes/3` (3 clauses, with its comment) and `within_cap/4` (2 clauses) and add in their place:

```elixir
  # The namespace caps every write passes to the store (MemoryStore put/6).
  defp limits(%Memory{} = tool),
    do: [max_bytes: tool.max_namespace_bytes, max_documents: tool.max_namespace_documents]

  defp namespace_full(tool, loc, :bytes, total),
    do:
      {:error, :namespace_full,
       "Error: memory is full: writing #{loc.model_path} would bring it to #{total} bytes; the limit is #{tool.max_namespace_bytes}. Delete or shorten files first."}

  defp namespace_full(tool, loc, :documents, count),
    do:
      {:error, :namespace_full,
       "Error: memory is full: creating #{loc.model_path} would make #{count} files; the limit is #{tool.max_namespace_documents}. Delete files first."}
```

Checks: `grep -n "others_bytes\|within_cap\|others" lib/normandy/tools/memory/commands.ex` → 0; `grep -n "@root" lib/normandy/tools/memory/commands.ex` still finds its other uses (no unused-attribute warning).

- [ ] **Step 8: The guide**

In `docs/guides/agent-memory.md`:

After the Postgres code block (`store = {MemoryStore.Postgres, MyApp.Repo}` and its closing fence), add:

```markdown

The migration creates two tables: `normandy_memory_documents`, and
`normandy_memory_namespaces`, which holds each namespace's content bytes and document count
for the caps. Every write locks its namespace's row there first, so the writers of one
namespace run one at a time. Write documents only through the store: a row written by other
SQL is not counted.
```

In the Redis paragraph, replace `Documents are hashes and each namespace keeps a sorted set of its paths, written by Lua
scripts so every operation is atomic.` with `Documents are hashes and each namespace keeps a sorted set of its paths and a counter of
its content bytes, written by Lua scripts so every operation is atomic.`

In `## Limits`, after the `max_namespace_bytes` row, add the row:

```markdown
| `max_namespace_documents` | 1000 | `Memory.new/1`; `nil` disables the cap; a `create` that would exceed it returns `Error: memory is full: creating {path} would make {count} files; the limit is {max}. Delete files first.` |
```

and replace the paragraph `` `max_namespace_bytes` is approximate. ... A mount's cap applies to the mount's namespace. `` with:

```markdown
The two namespace caps are independent, and the store checks them in the same atomic
step as the write (`MemoryStore` `put/6`): two concurrent writers cannot exceed a cap
together, and every document counts, not only the first 1,000 a listing shows. A write
that does not grow the namespace (a shorter replacement, an overwrite of the same size) is
always allowed, so a namespace over a lowered cap can still be shortened. A mount's caps
apply to the mount's namespace.
```

- [ ] **Step 9: Run the default suites**

Run: `mix format && mix test test/tools test/behaviours/memory_store test/dsl test/options_coverage_test.exs test/options`
Expected: PASS (InMemory, ETS and Mnesia run the contract; Postgres and Redis are excluded by default).

- [ ] **Step 10: Postgres and Redis**

The local test database already ran `priv/test_repo/migrations/20261003000000_create_memory_store.exs` with the old `Migration.up/0`, and Ecto does not run a migration twice, so `normandy_memory_namespaces` is missing there and every Postgres write would fail with `relation "normandy_memory_namespaces" does not exist`. `mix test.postgres` (`mix.exs` `run_postgres_tests/1`) runs `ecto.setup` (`ecto.create --quiet`, `ecto.migrate --quiet`) and then `mix test --include postgres`; `config/test.exs` reads `POSTGRES_PORT` (default 5432) and names the database `normandy_test#{MIX_TEST_PARTITION}`. CI is unaffected: it starts a fresh `postgres:16-alpine` service each run.

Per decision 23 (Appendix B item B4), run against the partition database `normandy_test_w54probe`, which already has the new migration. Drop nothing: dropping `normandy_test_w54probe` or the stale `normandy_test` needs Q's yes.

```bash
docker start normandy-test-pg
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tee /tmp/w5-5.4b-pg.log
grep -E " [0-9]+ failures" /tmp/w5-5.4b-pg.log
mix test.redis 2>&1 | tee /tmp/w5-5.4b-redis.log
grep -E " [0-9]+ failures" /tmp/w5-5.4b-redis.log
docker stop normandy-test-pg
```

Expected: ` 0 failures` in both logs. The stale `normandy_test` still fails plain `mix test.postgres` (no partition) until Q approves dropping it.

- [ ] **Step 11: MIGRATING, gate and commit**

In `MIGRATING-2.0.md` `## 34.` (created by Task 5.4a), append:

```markdown
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
```

Run: `mix format && mix precommit 2>&1 | tee /tmp/w5-5.4b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.4b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/behaviours/memory_store.ex lib/normandy/behaviours/memory_store/docs.ex \
  lib/normandy/behaviours/memory_store/in_memory.ex lib/normandy/behaviours/memory_store/ets.ex \
  lib/normandy/behaviours/memory_store/mnesia.ex lib/normandy/behaviours/memory_store/postgres.ex \
  lib/normandy/behaviours/memory_store/postgres/migration.ex \
  lib/normandy/behaviours/memory_store/redis.ex lib/normandy/tools/memory.ex \
  lib/normandy/tools/memory/commands.ex .dialyzer_ignore.exs docs/guides/agent-memory.md \
  test/support/memory_stub_stores.ex test/support/memory_store_contract.ex \
  test/tools/memory_test.exs test/behaviours/memory_store/docs_test.exs \
  test/behaviours/memory_store/postgres_test.exs test/behaviours/memory_store/redis_test.exs \
  MIGRATING-2.0.md
git commit -m "feat(memory): exact namespace byte and document caps in every store"
```

---

---

### Task 5.5a: The summarizer reads tool rounds, frames its summary, and gets a real budget (AX-9, AX-28, AX-10's summarizer half)

Runs after Task 5.4b. Task 5.3b already rebuilds the kept messages of both compaction rebuilders from `entry.content` (`WindowManager.rebuild_memory/2`, `Summarizer.rebuild_memory_with_summary/4`); do not touch those `Enum.reduce` bodies. After Task 5.3b, `AgentMemory.history/1` gives a `%BaseAgentOutputSchema{chat_message: s}` as the plain string `s`, and a `%ToolCallResponse{}` with non-empty `content_blocks` as its string-keyed API blocks; a hand-built `%ToolCallResponse{}` (empty `content_blocks`) and every `%ToolResult{}` still serialize atom-keyed. The transcript code below reads both key styles, so its tests hold before and after 5.3b.

**Files:**
- Modify: `lib/normandy/context/summarizer.ex` (`@summary_opts` `:max_tokens`; `summarize_messages/4`; replace `format_messages_for_summary/1` and the four `extract_content/1` clauses; new `summary_message/1`; the summary line in `rebuild_memory_with_summary/4`)
- Modify: `lib/normandy/context/window_manager.ex` (struct field and `new/1` option `:summary_max_tokens`; `truncate_with_summary/2`; new `summary_budget/1`)
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex` (option `:summary_max_tokens`; `checked_manager/3`; moduledoc)
- Modify: `test/context/summarizer_test.exs` (4 assertions on the old summary prefix)
- Modify: `MIGRATING-2.0.md` (§2 bullet; `## 35.` bullets 1-4)
- Test: create `test/context/summarizer_transcript_test.exs`

**Interfaces:**
- Consumes: `AgentMemory.history/1` (after 5.3b: `model_content/1` unwraps `chat_message`; `content_blocks` replayed string-keyed); `BaseAgentConfig.default_max_tokens/0` (16_000); `Normandy.JSON.encode!/1`, `decode/1`.
- Produces: `Compactor.WindowManager` option `summary_max_tokens` (`pos_integer | nil`, default `nil`); `Context.WindowManager.new/1` option and struct field `summary_max_tokens` (same type); `Summarizer` `:max_tokens` default = the agent's `max_tokens`, else 16_000; the summary message text pinned below.

- [ ] **Step 1: Write the failing tests**

Create `test/context/summarizer_transcript_test.exs`:

```elixir
defmodule Normandy.Context.SummarizerTranscriptTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Context.Summarizer
  alias Normandy.Context.WindowManager
  alias Normandy.Test.StubClient

  # Sends each summary request (messages and max_tokens) to `notify`, then answers
  # "summary".
  defmodule RecordingClient do
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:summarize_request, request.messages, request.max_tokens})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "summary"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp recording, do: %RecordingClient{notify: self()}

  defp agent(extra \\ %{}) do
    %{client: recording(), model: "test-model"} |> Map.merge(extra) |> BaseAgent.init()
  end

  # The transcript part of the one summary request (after the prompt).
  defp transcript do
    assert_received {:summarize_request, [%Message{role: "user", content: prompt}], _max}
    [_prompt, transcript] = String.split(prompt, "Conversation to summarize:\n\n\n", parts: 2)
    transcript
  end

  describe "the transcript the summarizer reads (AX-9)" do
    test "a tool round reaches the summary as a call, its result and the answer" do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "weather in Paris?")
        |> AgentMemory.add_message("assistant", %ToolCallResponse{
          content: "Let me check.",
          thinking: [%{"type" => "thinking", "thinking" => "plan", "signature" => "s"}],
          tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{"city" => "Paris"}}]
        })
        |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "t1", output: "sunny, 21C"})
        |> AgentMemory.add_message(
          "assistant",
          %Normandy.Agents.BaseAgentOutputSchema{chat_message: "It is sunny."}
        )

      {:ok, "summary"} =
        Summarizer.summarize_messages(recording(), agent(), AgentMemory.history(memory))

      assert transcript() ==
               """
               User: weather in Paris?

               Assistant: Let me check.
               Assistant called weather({"city":"Paris"})

               Tool result (weather): sunny, 21C

               Assistant: It is sunny.\
               """
    end

    test "string-keyed API blocks read like atom-keyed ones; thinking is left out" do
      messages = [
        %{
          role: "assistant",
          content: [
            %{"type" => "thinking", "thinking" => "secret plan", "signature" => "s"},
            %{"type" => "redacted_thinking", "data" => "xx"},
            %{"type" => "text", "text" => "Checking."},
            %{"type" => "tool_use", "id" => "t1", "name" => "lookup", "input" => %{"q" => "a"}},
            %{
              "type" => "mcp_tool_use",
              "id" => "m1",
              "name" => "search",
              "server_name" => "docs",
              "input" => %{}
            },
            %{
              "type" => "mcp_tool_result",
              "tool_use_id" => "m1",
              "is_error" => false,
              "content" => [%{"type" => "text", "text" => "doc hit"}]
            },
            %{"type" => "web_search_tool_result", "tool_use_id" => "w1", "content" => []}
          ]
        },
        %{
          role: "tool",
          content: [
            %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "found A"}
          ]
        }
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      text = transcript()

      assert text ==
               """
               Assistant: Checking.
               Assistant called lookup({"q":"a"})
               Assistant called search({})
               Tool result (search): doc hit
               Assistant: [web_search_tool_result]

               Tool result (lookup): found A\
               """

      refute text =~ "secret plan"
      refute text =~ "[thinking]"
    end

    test "an error result is marked, and an unknown call id stands in for the name" do
      messages = [
        %{
          role: "tool",
          content: [
            %{type: "tool_result", tool_use_id: "t9", content: "timeout", is_error: true}
          ]
        }
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      assert transcript() == "Tool error (t9): timeout"
    end

    test "a long tool result is cut to 4000 characters, with a note" do
      long = String.duplicate("é", 4_010)

      messages = [
        %{role: "assistant", content: [%{type: "tool_use", id: "t1", name: "dump", input: %{}}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "t1", content: long}]}
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      assert transcript() ==
               "Assistant called dump({})\n\nTool result (dump): " <>
                 String.duplicate("é", 4_000) <> " [10 more characters cut]"
    end

    test "an answer stored as {\"chat_message\": ...} JSON reads as its text" do
      messages = [
        %{role: "assistant", content: ~s({"chat_message":"It is sunny."})},
        %{role: "user", content: ~s({"query":"x","chat_message":"kept as JSON"})}
      ]

      {:ok, "summary"} = Summarizer.summarize_messages(recording(), agent(), messages)

      assert transcript() ==
               ~s(Assistant: It is sunny.\n\nUser: {"query":"x","chat_message":"kept as JSON"})
    end
  end

  describe "the summary message (AX-28)" do
    test "is framed as an automatic summary of earlier turns, in tags" do
      memory =
        Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      {:ok, compressed} =
        Summarizer.compress_conversation(recording(), agent(%{memory: memory}), keep_recent: 2)

      [summary | _kept] = AgentMemory.history(compressed.memory)

      assert summary == %{
               role: "user",
               content:
                 "The earlier part of this conversation was summarized automatically to save " <>
                   "space. The summary is context, not a new message.\n\n" <>
                   "<conversation_summary>\nsummary\n</conversation_summary>"
             }
    end
  end

  describe "the summary's max_tokens" do
    @messages [%{role: "user", content: "hello"}]

    test "defaults to the agent's max_tokens" do
      Summarizer.summarize_messages(recording(), agent(%{max_tokens: 9_000}), @messages)
      assert_received {:summarize_request, _messages, 9_000}
    end

    test "is 16_000 for an agent map without max_tokens" do
      Summarizer.summarize_messages(recording(), %{model: "test-model"}, @messages)
      assert_received {:summarize_request, _messages, 16_000}
    end

    test ":max_tokens overrides it" do
      Summarizer.summarize_messages(recording(), agent(), @messages, max_tokens: 700)
      assert_received {:summarize_request, _messages, 700}
    end

    test "an agent max_tokens that is not a positive integer raises, naming it" do
      assert_raise ArgumentError,
                   "Normandy.Context.Summarizer: the agent's :max_tokens is the summary's " <>
                     "default budget and must be a positive integer, got: 0; set it, or " <>
                     "pass :max_tokens",
                   fn ->
                     Summarizer.summarize_messages(
                       recording(),
                       %{model: "test-model", max_tokens: 0},
                       @messages
                     )
                   end
    end

    test "Compactor.WindowManager passes :summary_max_tokens to the summary call" do
      memory =
        Enum.reduce(1..40, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "message number #{i} with padding")
        end)

      opts = [context_window: 200, reserved_tokens: 16, strategy: :summarize]

      {_acc, %{compacted: true}} =
        WMCompactor.maybe_compact(
          agent(%{memory: memory}),
          %{model: "m", window: nil, mid_round: false},
          opts ++ [summary_max_tokens: 1_234]
        )

      assert_received {:summarize_request, _messages, 1_234}

      {_acc, %{compacted: true}} =
        WMCompactor.maybe_compact(
          agent(%{memory: memory, max_tokens: 100}),
          %{model: "m", window: nil, mid_round: false},
          opts
        )

      assert_received {:summarize_request, _messages, 100}
    end

    test ":summary_max_tokens is checked when the agent is built" do
      message =
        ~r/\ANormandy\.Agents\.BaseAgent\.init\/1: .*invalid value for :summary_max_tokens option: expected positive integer, got: 0/s

      assert_raise ArgumentError, message, fn ->
        BaseAgent.init(%{
          client: %StubClient{},
          model: "m",
          behaviours: %Normandy.Behaviours.Config{
            compactor: {WMCompactor, [context_window: 1_000, summary_max_tokens: 0]}
          }
        })
      end
    end

    test "WindowManager.new/1 takes :summary_max_tokens, nil by default" do
      assert WindowManager.new(max_tokens: 1_000).summary_max_tokens == nil

      assert WindowManager.new(max_tokens: 1_000, summary_max_tokens: 50).summary_max_tokens ==
               50
    end
  end
end
```

(The `mid_round: false` key in the two compactor `ctx` maps is Task 5.5b's; `Compactor.WindowManager` ignores it until then.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/context/summarizer_transcript_test.exs`
Expected: FAIL, 12 of 13. Only `:max_tokens overrides it` passes. The transcript tests see empty `Tool:` lines and no `Assistant called` lines; the summary test sees `Previous conversation summary: summary`; the budget tests receive `500`; `WindowManager.new/1` and the compactor reject `:summary_max_tokens` as an unknown option (`KeyError` on the struct field in the `new/1` test).

- [ ] **Step 3: The summarizer's transcript, summary text and budget**

In `lib/normandy/context/summarizer.ex`:

1. Aliases: replace `alias Normandy.Components.AgentMemory` and `alias Normandy.Components.Message` with:

```elixir
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock
  alias Normandy.Components.Message
```

2. Directly above `@summary_opts [`, add:

```elixir
  @tool_call_types ["tool_use", "server_tool_use", "mcp_tool_use"]
  @tool_result_types ["tool_result", "mcp_tool_result"]
  @max_result_chars 4_000
```

3. In `@summary_opts`, replace

```elixir
    max_tokens: [type: :pos_integer, default: 500, doc: "Maximum tokens for the summary."]
```

with

```elixir
    max_tokens: [
      type: :pos_integer,
      doc:
        "Maximum tokens for the summary call (default: the agent's `max_tokens`, else " <>
          "16_000). Thinking shares this budget, and current models cannot turn it off."
    ]
```

4. In `summarize_messages/4`, replace `max_tokens = Keyword.fetch!(opts, :max_tokens)` with

```elixir
    max_tokens = Keyword.get_lazy(opts, :max_tokens, fn -> agent_max_tokens!(agent) end)
```

(`compress_conversation/3` already forwards `Keyword.take(opts, [:prompt, :model, :max_tokens])`; with no default, an absent `:max_tokens` stays absent and reaches this line.)

5. Replace `format_messages_for_summary/1` and all four `extract_content/1` clauses (from `defp format_messages_for_summary(messages) do` through `defp extract_content(_), do: ""`) with:

```elixir
  # The transcript the summary model reads: one paragraph per message, "Role: text" per
  # text block, and a line of its own for each tool call and tool result, so the facts a
  # tool returned reach the summary. history/1 gives blocks string-keyed (a response's API
  # blocks) or atom-keyed (ToolResult, a rebuilt ToolCallResponse); both read the same.
  # Thinking is left out: it is the model's scratch work, not conversation.
  defp format_messages_for_summary(messages) do
    names = tool_names(messages)

    messages
    |> Enum.map(fn msg -> msg.content |> content_lines(msg.role, names) |> Enum.join("\n") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp content_lines(content, role, _names) when is_binary(content),
    do: [label(role, unwrap_chat_message(content))]

  defp content_lines(content, role, names) when is_list(content),
    do: Enum.flat_map(content, &block_lines(&1, role, names))

  # A struct or map given to summarize_messages/4 directly: its chat_message, else JSON.
  defp content_lines(content, role, _names) when is_map(content) do
    case Map.get(content, :chat_message) do
      nil -> [label(role, Normandy.JSON.encode!(content))]
      message -> [label(role, message)]
    end
  end

  defp content_lines(nil, _role, _names), do: []

  defp block_lines(%ContentBlock.Text{text: text}, role, _names), do: [label(role, text)]
  defp block_lines(%ContentBlock.Image{}, role, _names), do: [label(role, "[image]")]
  defp block_lines(%ContentBlock.Document{}, role, _names), do: [label(role, "[document]")]

  defp block_lines(block, role, names) when is_map(block) do
    case field(block, :type) do
      "text" ->
        [label(role, field(block, :text))]

      type when type in ["thinking", "redacted_thinking"] ->
        []

      type when type in @tool_call_types ->
        input = Normandy.JSON.encode!(field(block, :input) || %{})
        ["Assistant called #{field(block, :name)}(#{input})"]

      type when type in @tool_result_types ->
        id = field(block, :tool_use_id)
        kind = if field(block, :is_error) == true, do: "Tool error", else: "Tool result"
        ["#{kind} (#{Map.get(names, id, id)}): #{cap(result_text(field(block, :content)))}"]

      type when is_binary(type) ->
        [label(role, "[#{type}]")]
    end
  end

  # The name of every call in the messages, by id, so a result names its tool.
  defp tool_names(messages) do
    for %{content: blocks} when is_list(blocks) <- messages,
        block when is_map(block) <- blocks,
        field(block, :type) in @tool_call_types,
        into: %{},
        do: {field(block, :id), field(block, :name)}
  end

  defp result_text(text) when is_binary(text), do: text
  defp result_text(nil), do: ""

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, " ", fn block ->
      case field(block, :type) do
        "text" -> field(block, :text)
        type -> "[#{type}]"
      end
    end)
  end

  # A tool result keeps its first @max_result_chars characters (graphemes) in the
  # transcript; the summary needs its facts, not a whole page.
  defp cap(text) when byte_size(text) <= @max_result_chars, do: text

  defp cap(text) do
    case String.length(text) - @max_result_chars do
      cut when cut > 0 ->
        String.slice(text, 0, @max_result_chars) <> " [#{cut} more characters cut]"

      _fits ->
        text
    end
  end

  # A final answer the structured path stored as {"chat_message": ...} JSON reads as its
  # text. Any other JSON (a custom schema's) stays as it is.
  defp unwrap_chat_message("{" <> _ = text) do
    case Normandy.JSON.decode(text) do
      {:ok, %{"chat_message" => message} = map} when map_size(map) == 1 and is_binary(message) ->
        message

      _not_a_chat_message ->
        text
    end
  end

  defp unwrap_chat_message(text), do: text

  defp label(role, text), do: "#{String.capitalize(role)}: #{text}"

  defp field(block, key), do: Map.get(block, key, Map.get(block, Atom.to_string(key)))

  # Thinking shares max_tokens with the summary text and cannot be turned off on current
  # models, so the summary gets the agent's own answer budget, not a summary-sized one.
  defp agent_max_tokens!(agent) do
    case Map.get(agent, :max_tokens) do
      nil ->
        BaseAgentConfig.default_max_tokens()

      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "Normandy.Context.Summarizer: the agent's :max_tokens is the summary's default " <>
                "budget and must be a positive integer, got: #{inspect(other)}; set it, or " <>
                "pass :max_tokens"
    end
  end
```

A block with no string `type`, and content that is neither a string, a list, a map nor `nil`, now raise (`CaseClauseError` / `FunctionClauseError`) instead of becoming an empty line; neither reaches the summarizer from `AgentMemory.history/1`.

6. In `rebuild_memory_with_summary/4`, replace only the summary line (leave the `Enum.reduce` over the kept messages as Task 5.3b left it):

```elixir
    memory =
      AgentMemory.add_message(memory, summary_role, "Previous conversation summary: " <> summary)
```

becomes

```elixir
    memory = AgentMemory.add_message(memory, summary_role, summary_message(summary))
```

and, directly above `defp recent_entries(memory, count) do` (and its comment), add:

```elixir
  # Framed so the model does not read the summary as something the user just said (AX-28).
  defp summary_message(summary) do
    "The earlier part of this conversation was summarized automatically to save space. " <>
      "The summary is context, not a new message.\n\n" <>
      "<conversation_summary>\n" <> summary <> "\n</conversation_summary>"
  end
```

`estimate_savings/2`'s `summary_tokens: 500` is an estimate input, unrelated; leave it.

- [ ] **Step 4: `:summary_max_tokens` through the window manager and the compactor**

In `lib/normandy/context/window_manager.ex`:

- `@type t` gains `summary_max_tokens: pos_integer() | nil` (after `strategy: strategy()`); `defstruct` gains `summary_max_tokens: nil` (after `strategy: :oldest_first`).
- `@new_opts_schema`, after the `strategy:` entry:

```elixir
                     summary_max_tokens: [
                       type: {:or, [:pos_integer, nil]},
                       default: nil,
                       doc:
                         "`max_tokens` of the `:summarize` strategy's summary call; `nil` is " <>
                           "`Normandy.Context.Summarizer`'s default (the agent's `max_tokens`, " <>
                           "else 16_000)."
                     ]
```

- `new/1`'s struct literal gains `summary_max_tokens: Keyword.fetch!(opts, :summary_max_tokens)`.
- In `truncate_with_summary/2`, replace

```elixir
        # Use summarizer to compress conversation
        Summarizer.compress_conversation(
          client,
          agent,
          keep_recent: keep_messages
        )
```

with

```elixir
        # Use summarizer to compress conversation; a nil budget is the Summarizer's default.
        Summarizer.compress_conversation(
          client,
          agent,
          [keep_recent: keep_messages] ++ summary_budget(manager)
        )
```

and add above `defp estimate_messages_for_tokens(memory, target_tokens) do`:

```elixir
  defp summary_budget(%__MODULE__{summary_max_tokens: nil}), do: []
  defp summary_budget(%__MODULE__{summary_max_tokens: n}), do: [max_tokens: n]
```

In `lib/normandy/behaviours/compactor/window_manager.ex`:

- `@opts_schema`, after the `strategy:` entry:

```elixir
                 summary_max_tokens: [
                   type: {:or, [:pos_integer, nil]},
                   default: nil,
                   doc:
                     "`max_tokens` of the `:summarize` strategy's summary call (default `nil`: " <>
                       "the agent's `max_tokens`, else 16_000). Thinking shares it."
                 ]
```

- `checked_manager/3`'s last expression becomes

```elixir
    WM.new(
      [max_tokens: window, reserved_tokens: reserved] ++
        Keyword.take(opts, [:strategy, :summary_max_tokens])
    )
```

- Moduledoc, the sentence "`:strategy` goes to `WindowManager.new/1`. The 1.x name `:max_tokens` for the pin raises `ArgumentError`." becomes:

```
  at or above the window raises `ArgumentError`; `:strategy` goes to
  `WindowManager.new/1`; `:summary_max_tokens` is the `:summarize` strategy's summary
  budget (default: the agent's `max_tokens`). The 1.x name `:max_tokens` for the pin
  raises `ArgumentError`.
```

`BaseAgent.validate_compaction_config!/2` already runs `validate_opts!/2` at `init/1` and at `ConfigTemplate.rebuild/3`, so the new option is checked there with no further change.

- [ ] **Step 5: Existing tests pinned to the old summary prefix**

`grep -n "Previous conversation summary" test/context/summarizer_test.exs` gives 5 lines at HEAD `0dccd48` (72, 292, 320, 335, 569). Line 72 is a message *given* to the summarizer and stays. Rewrite the other four:

```bash
perl -pi -e 's/=~ "Previous conversation summary"/=~ "<conversation_summary>"/; s/String\.contains\?\(summary_msg\.content, "Previous conversation summary"\)/String.contains?(summary_msg.content, "<conversation_summary>")/; s#~r/\\APrevious conversation summary: /#~r/\\AThe earlier part of this conversation was summarized automatically/#' test/context/summarizer_test.exs
```

Expected after: `grep -c "Previous conversation summary" test/context/summarizer_test.exs` = 1; the two `=~ "<conversation_summary>"` assertions, the `String.contains?(..., "<conversation_summary>")` one, and `assert summary.content =~ ~r/\AThe earlier part of this conversation was summarized automatically/`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/context/ test/behaviours/ test/hooks/`
Expected: PASS, 0 failures (the 13 new tests included).

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.5a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.5a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 8: MIGRATING**

In `MIGRATING-2.0.md` §2, the bullet

```
- A `:summarize` compaction stores its summary as a plain string
  (`"Previous conversation summary: ..."`), not a `BaseAgentOutputSchema`.
```

becomes

```
- A `:summarize` compaction stores its summary as a plain string, inside
  `<conversation_summary>` tags (§35), not a `BaseAgentOutputSchema`.
```

Add the section after `## 34.` (Task 5.4's) and before `## New, non-breaking`:

```
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
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/context/summarizer.ex lib/normandy/context/window_manager.ex \
  lib/normandy/behaviours/compactor/window_manager.ex test/context/summarizer_transcript_test.exs \
  test/context/summarizer_test.exs MIGRATING-2.0.md
git commit -m "fix(summarizer): read tool rounds, frame the summary, budget it like the agent"
```

---

### Task 5.5b: Compaction knows when a tool round is open (AX-22 per ruling R6)

Runs after Task 5.5a. Ruling R6 replaces plan.md's acceptance: a compaction at a mid-round boundary happens only when the conversation is over the window, and then strips the kept messages' thinking (the API's keep-tail recovery; keeping the open round's thinking after a summary or cut is what models that bind thinking to its history reject). Today's code already does that for `Compactor.WindowManager`; this task makes the boundary explicit (`mid_round`) in the core effect, the compactor `ctx` and telemetry, writes the rule into the `Compactor` contract, and pins the behaviour on every path.

Task 5.2b changed `apply_tool_results/2` and the `:compaction_done` clauses for the cap notice, and Task 5.3c added the `pause_turn` continuation. Anchor every edit below on the `{:maybe_compact, ...}` tuples, not on line numbers. `grep -n ":maybe_compact, %{" lib/normandy/agents/turn.ex` gives 3 sites at HEAD `0dccd48` (`step/2` for `:start`, `resume/1` for `:steering`, `apply_tool_results/2`). If an earlier task added a site, it gets `mid_round: true` when it follows a model response of the same turn (the round is open: for example a `pause_turn` continuation) and `false` otherwise; every `{:maybe_compact, info}` the core emits must carry the key, because `BaseAgent.compact_turn_memory/3` reads it with `Map.fetch!/2`.

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (the `{:maybe_compact, ...}` tuples; moduledoc)
- Modify: `lib/normandy/agents/turn/inline.ex` (moduledoc of the `:compact` dep)
- Modify: `lib/normandy/agents/base_agent.ex` (`compact_turn_memory/3` and its comment)
- Modify: `lib/normandy/behaviours/compactor.ex` (`ctx` type and doc; new "Compacting mid-round" section)
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex` (moduledoc)
- Modify: `lib/normandy/telemetry.ex` (`[:normandy, :agent, :compaction]` entry)
- Modify tests: `test/agents/turn_test.exs`, `test/agents/turn_approval_test.exs`, `test/agents/turn_compaction_test.exs`, `test/agents/turn/resume_test.exs`, `test/agents/pause_turn_test.exs` (Task 5.3c's), `test/integration/compaction_turn_test.exs`, `test/agents/base_agent_exposure_test.exs`, `test/agents/base_agent_compaction_telemetry_test.exs`
- Modify: `MIGRATING-2.0.md` (`## 35.` bullets 5-7)
- Test: create `test/agents/mid_round_compaction_test.exs`

**Interfaces:**
- Consumes: Task 5.5a's `Compactor.WindowManager`; Task 5.3b's `drop_thinking/1` covering `content_blocks` and the rebuilders over `entry.content`; `Turn.Driver`, `Turn.Inline` and `Turn.Server` pass `info` through to the compact handler unchanged (`driver.ex` `{:maybe_compact, info}`, `inline.ex` `deps.compact.(info)`, `server.ex` `compact_event/3`), so no interpreter changes.
- Produces: `{:maybe_compact, %{iterations_left: n, mid_round: boolean}}`; compactor `ctx` key `:mid_round`; `[:normandy, :agent, :compaction]` metadata key `mid_round`.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/mid_round_compaction_test.exs`:

```elixir
defmodule Normandy.Agents.MidRoundCompactionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.ContextProbe
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StreamingProbeClient
  alias Normandy.Test.TelemetryCapture

  @thinking %{"type" => "thinking", "thinking" => "plan", "signature" => "sig"}

  # Reports each ctx it is called with; never compacts.
  defmodule RecordingCompactor do
    @behaviour Normandy.Behaviours.Compactor

    @impl true
    def maybe_compact(acc, ctx, opts) do
      send(Keyword.fetch!(opts, :notify), {:compact_ctx, ctx})
      {acc, %{compacted: false}}
    end
  end

  # One tool round (a "weather" call with thinking), then the text answer "done".
  # Sends every request to `notify`.
  defmodule OneRoundClient do
    defstruct [:notify, options: %{}]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:request, request})

        content =
          if Enum.any?(request.messages, &(&1.role == "tool")) do
            %ToolCallResponse{content: "done"}
          else
            %ToolCallResponse{
              thinking: [%{"type" => "thinking", "thinking" => "plan", "signature" => "sig"}],
              tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}]
            }
          end

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp agent(client, compactor) do
    %{
      client: client,
      model: "m",
      name: "mid-round-#{System.unique_integer([:positive])}",
      behaviours: %Config{compactor: compactor}
    }
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%FakeTool{name: "weather"})
  end

  defp recording, do: {RecordingCompactor, [notify: self(), context_window: 200_000]}

  describe "the core marks the boundary" do
    test "turn start is not mid-round; the boundary after a tool batch is" do
      s = Turn.new(max_iterations: 5, response_model: :rm)

      {s, [{:maybe_compact, %{iterations_left: 5, mid_round: false}}]} = Turn.step(s, :start)
      {s, _effects} = Turn.step(s, {:compaction_done, %{}})

      call = %ToolCall{id: "c1", name: "t", input: %{}}
      {s, _effects} = Turn.step(s, {:llm_response, %ToolCallResponse{tool_calls: [call]}})

      {s, effects} =
        Turn.step(s, {:tool_results, [%ToolResult{tool_call_id: "c1", output: "ok"}]})

      assert List.last(effects) == {:maybe_compact, %{iterations_left: 4, mid_round: true}}

      # A persisted :steering state is always a post-batch boundary.
      assert {^s, [{:maybe_compact, %{iterations_left: 4, mid_round: true}}]} = Turn.resume(s)
    end
  end

  describe "every shell hands the compactor ctx.mid_round" do
    test "BaseAgent.run/3, with the telemetry metadata" do
      config = agent(%OneRoundClient{notify: self()}, recording())
      ref = TelemetryCapture.attach([[:normandy, :agent, :compaction]], agent_name: config.name)

      {:ok, _config, _output} = BaseAgent.run(config, %{chat_message: "go"})

      assert_received {:compact_ctx, %{mid_round: false}}
      assert_received {:compact_ctx, %{mid_round: true}}
      refute_received {:compact_ctx, _}

      assert_received {:telemetry, ^ref, _, %{mid_round: false}}
      assert_received {:telemetry, ^ref, _, %{mid_round: true}}
    end

    test "BaseAgent.stream/3" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "m",
          name: "mid-round-stream",
          behaviours: %Config{compactor: recording()}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      {:ok, _config, _output} = BaseAgent.stream(config, %{chat_message: "go"}, fn _ -> :ok end)

      assert_received {:compact_ctx, %{mid_round: false}}
      assert_received {:compact_ctx, %{mid_round: true}}
      refute_received {:compact_ctx, _}
    end

    test "Turn.Server" do
      config = agent(%OneRoundClient{notify: self()}, recording())

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: "mid-round-#{System.unique_integer([:positive])}",
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:ok, _output} = Turn.Server.run(srv, %{chat_message: "go"})

      # The compactor runs in the server's worker tasks: another sender than the reply.
      assert_receive {:compact_ctx, %{mid_round: false}}
      assert_receive {:compact_ctx, %{mid_round: true}}
      refute_received {:compact_ctx, _}
    end
  end

  describe "Compactor.WindowManager at a mid-round boundary" do
    # A tool round whose assistant turn has thinking, after `filler` user messages.
    defp open_round(filler) do
      Enum.reduce(1..filler//1, AgentMemory.new_memory(), fn i, mem ->
        AgentMemory.add_message(mem, "user", "message #{i} with some padding content")
      end)
      |> AgentMemory.add_message("user", "weather?")
      |> AgentMemory.add_message("assistant", %ToolCallResponse{
        thinking: [@thinking],
        tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}]
      })
      |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "t1", output: "sunny"})
    end

    defp assistant_blocks(memory) do
      memory
      |> AgentMemory.history()
      |> Enum.find(&(&1.role == "assistant"))
      |> Map.fetch!(:content)
    end

    test "under the window it leaves memory as it is, thinking included" do
      config = %{agent(%OneRoundClient{notify: self()}, recording()) | memory: open_round(20)}

      {result, meta} =
        WMCompactor.maybe_compact(config, %{model: "m", window: 200_000, mid_round: true}, [])

      assert meta.compacted == false
      assert result.memory == config.memory
      assert @thinking in assistant_blocks(result.memory)
    end

    test "over the window it compacts and strips the kept turns' thinking" do
      config = %{agent(%OneRoundClient{notify: self()}, recording()) | memory: open_round(20)}

      {result, meta} =
        WMCompactor.maybe_compact(
          config,
          %{model: "m", window: 120, mid_round: true},
          reserved_tokens: 16
        )

      assert meta.compacted == true
      blocks = assistant_blocks(result.memory)
      assert Enum.any?(blocks, &match?(%{type: "tool_use"}, &1))
      refute Enum.any?(blocks, &match?(%{"type" => "thinking"}, &1))
    end

    test "the next request of a turn under the window replays the open round's thinking" do
      config =
        agent(%OneRoundClient{notify: self()}, {WMCompactor, [context_window: 200_000]})

      {:ok, _config, _output} = BaseAgent.run(config, %{chat_message: "go"})

      assert_received {:request, _first}
      assert_received {:request, second}

      assistant = Enum.find(second.messages, &(&1.role == "assistant"))
      assert @thinking in assistant.content
    end
  end
end
```

Notes for the implementer: `OneRoundClient` answers with text (`"done"`), not an empty final answer, so the file does not depend on Task 5.6c's empty-answer rule. The coalesced tool-result message of Task 5.3a keeps `role: "tool"`, which `OneRoundClient` and `StreamingProbeClient` look for. The hand-built `%ToolCallResponse{}` has empty `content_blocks`, so `history/1` rebuilds it (atom-keyed `tool_use`, string-keyed thinking) before and after Task 5.3b.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/mid_round_compaction_test.exs`
Expected: FAIL, 4 of 7: the core test (`MatchError`: the effect has no `mid_round`) and the three shell tests (no `{:compact_ctx, %{mid_round: _}}` message). The three `Compactor.WindowManager` tests pass already: they pin today's behaviour, which R6 keeps.

- [ ] **Step 3: The core marks the boundary**

In `lib/normandy/agents/turn.ex`:

- `step(%State{status: :provisioning} = s, :start)`:

```elixir
    {%{s | status: :steering}, [{:maybe_compact, %{iterations_left: s.iterations_left}}]}
```

becomes

```elixir
    {%{s | status: :steering},
     [{:maybe_compact, %{iterations_left: s.iterations_left, mid_round: false}}]}
```

- `resume/1` for `:steering`:

```elixir
  def resume(%State{status: :steering, iterations_left: left} = s) do
    {s, [{:maybe_compact, %{iterations_left: left}}]}
```

becomes

```elixir
  # The core persists :steering only after a tool batch, so a resumed one is mid-round.
  def resume(%State{status: :steering, iterations_left: left} = s) do
    {s, [{:maybe_compact, %{iterations_left: left, mid_round: true}}]}
```

- In `apply_tool_results/2`, the tuple `{:maybe_compact, %{iterations_left: new_left}}` becomes `{:maybe_compact, %{iterations_left: new_left, mid_round: true}}` (leave the effects before it, including any Task 5.2b added, as they are; `mix format` reflows the list). After Tasks 5.2b and 5.3c these three tuples are still the only emitters: a loop `pause_turn` (`continue_paused/2`), the batch that appends the cap notice, and a paused final call (5.2b's X1 continuation, where `iterations_left` stays at 0, decision 23) all go through `apply_tool_results/2`, so all of them are `mid_round: true`.

- Moduledoc: the sentence "which is where context-window compaction (Phase 5) runs in the shell." becomes:

```
  which is where context-window compaction runs in the shell. `info` is
  `%{iterations_left: n, mid_round: boolean}`: `mid_round` is `false` at the start
  of a turn and `true` after a tool batch, while the model's tool round is still
  open (see `Normandy.Behaviours.Compactor`).
```

In `lib/normandy/agents/turn/inline.ex`, the `:compact` dep doc:

```
    * `:compact`  — `fn info -> any end` (optional, defaults to no-op). Invoked at the
                    `:steering` boundary with `%{iterations_left: n, mid_round: boolean}`
                    (see `Normandy.Agents.Turn`); the inline shell does not thread memory, so
                    a real impl must compact external state by side effect.
```

- [ ] **Step 4: The shell hands it to the compactor and to telemetry**

In `lib/normandy/agents/base_agent.ex`, `compact_turn_memory/3`:

- `ctx = %{model: config.model, window: window}` becomes

```elixir
    mid_round = Map.fetch!(info, :mid_round)
    ctx = %{model: config.model, window: window, mid_round: mid_round}
```

- In the `:telemetry.execute` metadata map, after `compacted: Map.get(meta, :compacted) == true,` add `mid_round: mid_round,`.
- In the `log_lifecycle(:debug, "normandy agent compaction", ...)` keyword list, after `iterations_left: Map.get(info, :iterations_left),` add `mid_round: mid_round,`.
- The comment above the function: the lines

```
  # :model, :strategy, :compacted, and the compactor's :error / :reason when it
  # failed or could not size a window), so a compactor that never fires is observable.
```

become

```
  # :model, :strategy, :compacted, :mid_round, and the compactor's :error / :reason when
  # it failed or could not size a window), so a compactor that never fires is observable.
  # `info` is the core's %{iterations_left:, mid_round:}; mid_round reaches the compactor
  # in ctx, so it can leave an open tool round alone while the conversation still fits.
```

In `lib/normandy/telemetry.ex`, the `[:normandy, :agent, :compaction]` entry's metadata sentence becomes:

```
  `tokens_before`, `tokens_after`, `tokens_removed` the compactor reported. Metadata:
  `agent_name`, `model`, `strategy`, `compacted` (boolean), `mid_round` (boolean: `false`
  at the start of a turn, `true` after a tool batch, while the tool round is open),
  `error`, `reason`.
```

- [ ] **Step 5: The compactor contract**

In `lib/normandy/behaviours/compactor.ex`, after the `:window` bullet of the `ctx` list add:

```
    * `:mid_round` — `false` at the start of a turn, `true` at the boundary after a
      tool batch. There the model's tool round is still open: the next request
      continues it, and its assistant turns go back with their thinking.
```

and at the end of the moduledoc, after the paragraph ending "rather than reading the key." and a blank line (so the paragraphs on `meta` and `:dropped` stay outside the new heading), add:

```
  ## Compacting mid-round

  A compactor must leave the memory unchanged at a mid-round boundary while the
  conversation still fits the window. When it does compact there, it strips the
  thinking blocks from every message it keeps
  (`Normandy.Components.AgentMemory.drop_thinking/1`): they were produced with the
  full history in place, and the API can reject them after a summary or a cut (it
  validates replayed thinking against what came before it). The open round loses its
  reasoning; it is the documented recovery for keep-tail compaction.
  `Compactor.WindowManager` does both: it compacts only over the window, at any
  boundary, and its strategies strip the kept messages' thinking.
```

and the type becomes

```elixir
  @type ctx :: %{model: String.t() | nil, window: pos_integer() | nil, mid_round: boolean()}
```

In `lib/normandy/behaviours/compactor/window_manager.ex`, the moduledoc sentence "delegates to `WindowManager.ensure_within_limit/2` — a no-op when already under budget." becomes:

```
  delegates to `WindowManager.ensure_within_limit/2` — a no-op when already under budget,
  so a mid-round boundary (`ctx.mid_round`) leaves the open tool round and its thinking
  alone until the conversation no longer fits; a compaction strips the kept messages'
  thinking (see "Compacting mid-round" in `Normandy.Behaviours.Compactor`).
```

No code change in `Compactor.WindowManager`: `run/2` already compacts only when `WM.within_limit?/2` is false.

- [ ] **Step 6: Existing tests that pin the effect and call the handler**

(a) Core effect assertions. `grep -rn "{:maybe_compact, %{iterations_left: [0-9]\+}}" test | wc -l` = 9 at HEAD `0dccd48` and **12** after Tasks 5.2b/5.3c: `test/agents/turn_test.exs` (5: Task 5.2b adds "an empty batch at the cap appends no notice" and the X1 paused final call, both at `0`; decision 23 keeps `iterations_left` at 0 or above, so no count is negative), `test/agents/turn_approval_test.exs` (4), `test/agents/turn_compaction_test.exs` (1), `test/agents/turn/resume_test.exs` (1), `test/agents/pause_turn_test.exs` (1, Task 5.3c). Apply the rule to every hit. Rule: every one becomes `mid_round: true`, except the `:start` assertion in `turn_test.exs` (test ":start parks in :steering and asks to compact before the first LLM call"), which becomes `mid_round: false`:

```bash
perl -pi -e 's/\{:maybe_compact, %\{iterations_left: (\d+)\}\}/{:maybe_compact, %{iterations_left: $1, mid_round: true}}/g' \
  test/agents/turn_test.exs test/agents/turn_approval_test.exs \
  test/agents/turn_compaction_test.exs test/agents/turn/resume_test.exs \
  test/agents/pause_turn_test.exs
perl -pi -e 's/assert effects == \[\{:maybe_compact, %\{iterations_left: 5, mid_round: true\}\}\]/assert effects == [{:maybe_compact, %{iterations_left: 5, mid_round: false}}]/' \
  test/agents/turn_test.exs
```

Expected: `mid_round: true` occurs 11 times over the five files (`turn_test.exs` 4, including `{:maybe_compact, %{iterations_left: 0, mid_round: true}}` in 5.2b's paused-final-call test; `pause_turn_test.exs` 1, a `pause_turn` continuation), and `turn_test.exs` has `assert effects == [{:maybe_compact, %{iterations_left: 5, mid_round: false}}]`. (`pause_turn_test.exs` matches with `=`, so its old map pattern would still pass; it is rewritten to state the rule.)

(b) Direct `BaseAgent.compact_turn_memory/3` calls. `grep -rc "compact_turn_memory(" test` = 18 at HEAD: `test/integration/compaction_turn_test.exs` 12, `test/agents/base_agent_exposure_test.exs` 2, `test/agents/base_agent_compaction_telemetry_test.exs` 4; in these three files every `%{iterations_left: N}` is such a call's `info` (`grep -c iterations_left` gives the same 12/2/4). Each becomes `%{iterations_left: N, mid_round: false}`:

```bash
perl -0pi -e 's/%\{\s*iterations_left: (\d+)\s*\}/%{iterations_left: $1, mid_round: false}/g' \
  test/integration/compaction_turn_test.exs test/agents/base_agent_exposure_test.exs \
  test/agents/base_agent_compaction_telemetry_test.exs
```

(c) In `test/agents/base_agent_compaction_telemetry_test.exs`, test "a compaction that fired reports token counts and strategy", the exact metadata assertion gains the key:

```elixir
    assert metadata == %{
             agent_name: name,
             model: "m",
             strategy: :summarize,
             compacted: true,
             mid_round: false,
             error: nil,
             reason: nil
           }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/ test/integration/compaction_turn_test.exs test/context/ test/behaviours/ test/hooks/ test/telemetry/`
Expected: PASS, 0 failures (the catalogue test included: no new event, one new documented key).

- [ ] **Step 8: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.5b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.5b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 9: MIGRATING**

Append to `## 35. Compaction` (after Task 5.5a's four bullets):

```
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
- `Turn.Server` does not store compaction. Compaction changes the server's in-memory
  conversation only; the session store keeps every message. A session restored from the
  store (after passivation, a restart or a handoff to another node) starts again from the
  full history and compacts again once it exceeds the window, so a `:summarize` compactor
  pays for a new summary, which can differ from the first. Texts injected by `after_compact`
  hooks are not stored either. Requests after a restore therefore differ from the requests
  before it: the prompt cache misses, and thinking produced after a compaction can be
  replayed after a different history, which models that check replayed thinking can reject.
  This is a known limit of this release; a later 2.0 release stores compaction.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/agents/turn.ex lib/normandy/agents/turn/inline.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/behaviours/compactor.ex \
  lib/normandy/behaviours/compactor/window_manager.ex lib/normandy/telemetry.ex \
  test/agents/mid_round_compaction_test.exs test/agents/turn_test.exs \
  test/agents/turn_approval_test.exs test/agents/turn_compaction_test.exs \
  test/agents/turn/resume_test.exs test/agents/pause_turn_test.exs \
  test/integration/compaction_turn_test.exs test/agents/base_agent_exposure_test.exs test/agents/base_agent_compaction_telemetry_test.exs \
  MIGRATING-2.0.md
git commit -m "feat(compaction): mark mid-round boundaries; compact there only over the window"
```

---

---

### Task 5.6a: Model-facing strings (AX-25, AX-16, AX-26, AX-27, AX-30)

Strings only; no behaviour changes. Golden tests pin each new text.

**Files:**
- Modify: `lib/normandy/components/system_prompt_generator.ex` (`@background`, `@steps`, `@output`, the empty-background default in `generate_prompt/1`, the header in `build_context/2`)
- Modify: `lib/normandy/tools/memory.ex` (`description/1` heredoc)
- Modify: `lib/normandy/agents/io_model.ex` (both `io_schema` descriptions and field descriptions)
- Modify: `lib/normandy/llm/json/retry_feedback.ex` (`build/4` json-parse clause, catch-all clause, `format_json_error/1` catch-all; new `parse_feedback/6`, `describe_failure/1`)
- Modify: `lib/normandy/a2a/agent_tool.ex` (`description/1`, `input_schema/1`, new `self_description/1`, `@max_card_text`)
- Modify: `MIGRATING-2.0.md` (new `## 36. Model-facing text and schemas`)
- Test: modify `test/components/system_prompt_generator_test.exs`, `test/tools/memory_test.exs`, `test/a2a/agent_tool_test.exs`, `test/llm/json/retry_feedback_test.exs`; create `test/agents/io_model_test.exs`

**Interfaces:**
- Consumes: nothing from earlier Wave 5 tasks. (Task 5.5 owns `summarizer.ex`; AX-28's summary framing is not in this task.)
- Produces: the headings `# Role`, `# How to work`, `# Output`, `# Context`; default identity `"You are a helpful assistant."`. `RetryFeedback.build/4`'s signature is unchanged. `AgentTool.input_schema/1` now reads the struct (it ignored it before).

- [ ] **Step 1: Write the failing tests**

Replace the body of `test/components/system_prompt_generator_test.exs` from `test "with empty specification"` through the end of the file with:

```elixir
  test "with empty specification" do
    prompt = """
    # Role
    - You are a helpful assistant.
    """

    spec = %PromptSpecification{}

    result = SystemPromptGenerator.generate_prompt(spec)

    assert String.trim(prompt) == result
  end

  test "write a specification" do
    spec = %PromptSpecification{
      background: ["you are a helpful assistant", "you assist me in assisting"],
      steps: ["step 1", "step 2", "step 3"],
      output_instructions: ["print the result", "as a result"]
    }

    prompt = """
    # Role
    - you are a helpful assistant
    - you assist me in assisting
    # How to work
    - step 1
    - step 2
    - step 3
    # Output
    - print the result
    - as a result
    """

    result = SystemPromptGenerator.generate_prompt(spec)
    assert String.trim(prompt) == result
  end

  test "context providers" do
    context_a = %ContextProvider{title: "title a", some_stuff: "some stuff"}
    context_b = %ContextProvider{title: "title b", some_stuff: "some other stuff"}

    spec = %PromptSpecification{
      background: ["you are a helpful assistant", "you assist me in assisting"],
      steps: ["step 1", "step 2", "step 3"],
      output_instructions: ["print the result", "as a result"],
      context_providers: %{
        "context_a" => context_a,
        "context_b" => context_b
      }
    }

    prompt = """
    # Role
    - you are a helpful assistant
    - you assist me in assisting
    # How to work
    - step 1
    - step 2
    - step 3
    # Output
    - print the result
    - as a result
    # Context
    Use this information where it is relevant to the request.
    ## title a
    some stuff
    ## title b
    some other stuff
    """

    result = SystemPromptGenerator.generate_prompt(spec)
    assert String.trim(prompt) == result
  end

  test "generate_prompt/2 no longer exists (tools go through the API tools parameter)" do
    # function_exported?/3 is false for a module that isn't loaded yet (mix test
    # loads lazily), which would make this pass before the change.
    Code.ensure_loaded!(SystemPromptGenerator)
    refute function_exported?(SystemPromptGenerator, :generate_prompt, 2)
  end

  test "no context line without context providers" do
    result = SystemPromptGenerator.generate_prompt(%PromptSpecification{})
    refute result =~ "# Context"
    refute result =~ "Use this information"
  end
end
```

In `test/tools/memory_test.exs`, test `"Normandy.Tool: name, input schema and description"`, replace

```elixir
    assert Tool.description(t) =~
             "ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE"

    assert Tool.description(t) =~ "/memories/org (read-only)"
```

with

```elixir
    assert Tool.description(t) == """
           Persistent memory that survives across conversations, stored as files under /memories.
           At the start of a task, view /memories to pick up earlier progress. Record durable progress and decisions as you go; your context may be reset.
           Keep the directory organized: rename or delete files that are no longer relevant, and do not create new files unless necessary. Never store secrets.
           Commands: view (a directory listing or a file with line numbers), create (create or overwrite a file), str_replace, insert, delete (a file or a directory), rename (a file or a directory).
           Shared directories: /memories/org (read-only).\
           """

    # No shouted instructions (AX-16): no run of two all-caps words.
    refute Tool.description(t) =~ ~r/\b[A-Z]{2,}\b[ :]+\b[A-Z]{2,}\b/
```

In `test/a2a/agent_tool_test.exs`, `describe "Normandy.Tool callbacks"`, replace the three `tool_description ...` tests and `"input_schema has message field"` with:

```elixir
    test "tool_description without skill", %{tool: tool} do
      assert Tool.description(tool) ==
               "Sends a message to the remote agent Research Agent and returns its reply. " <>
                 "It describes itself as: Helps find information"
    end

    test "tool_description with matching skill", %{card_with_skills: card} do
      tool = AgentTool.new("https://example.com/a2a", card, skill_id: "web_search")

      assert Tool.description(tool) ==
               "Sends a message to the remote agent Research Agent (skill web_search) and " <>
                 "returns its reply. It describes itself as: Search the web"
    end

    test "tool_description with non-matching skill", %{card: card} do
      tool = AgentTool.new("https://example.com/a2a", card, skill_id: "unknown")

      assert Tool.description(tool) ==
               "Sends a message to the remote agent Research Agent (skill unknown) and " <>
                 "returns its reply. It describes itself as: Helps find information"
    end

    test "the card's text is cut to 1_000 characters" do
      card = AgentCard.new("Chatty", String.duplicate("é", 1_200))
      tool = AgentTool.new("https://example.com/a2a", card)

      assert Tool.description(tool) ==
               "Sends a message to the remote agent Chatty and returns its reply. " <>
                 "It describes itself as: " <> String.duplicate("é", 1_000) <> "..."
    end

    test "input_schema has message field", %{tool: tool} do
      schema = Tool.input_schema(tool)
      assert schema["type"] == "object"
      assert schema["properties"]["message"]["type"] == "string"
      assert schema["required"] == ["message"]

      assert schema["properties"]["message"]["description"] ==
               "Message to send to Research Agent. It cannot see this conversation, " <>
                 "so include every detail it needs."
    end
```

Append to `test/llm/json/retry_feedback_test.exs` (before the final `end`):

```elixir
  test "any other failure gets the parse template and the schema, never an Elixir term" do
    too_large =
      RetryFeedback.build(
        {:input_too_large, 2_048, 1_024},
        ~s({"chat_message": "long"}),
        %RequiredField{},
        Normandy.JSON
      )

    assert too_large =~ "# RESPONSE FORMAT ERROR"
    assert too_large =~ "Your previous response could not be used as the answer."

    assert too_large =~
             "The response is 2048 bytes; the limit is 1024 bytes. Give a shorter answer."

    assert too_large =~ "## Required Schema"
    assert too_large =~ "Respond with a single JSON object"
    refute too_large =~ "input_too_large"

    not_object =
      RetryFeedback.build(
        {:unexpected_parse_result, "[1, 2]"},
        "[1, 2]",
        %RequiredField{},
        Normandy.JSON
      )

    assert not_object =~ "The response is valid JSON, but not a JSON object."
    refute not_object =~ "unexpected_parse_result"

    other = RetryFeedback.build({:some, :term}, "x", %RequiredField{}, Normandy.JSON)
    assert other =~ "The response does not match the required format."
    refute other =~ ":some"
  end

  test "a decode exception is shown as its message, never as a struct" do
    {:error, %Jason.DecodeError{} = exception} = Jason.decode("oops")

    feedback =
      RetryFeedback.build(
        {:json_parse_error, exception, "oops"},
        "oops",
        %RequiredField{},
        Normandy.JSON
      )

    assert feedback =~ "Invalid JSON: " <> Exception.message(exception)
    refute feedback =~ "Jason.DecodeError"
  end
```

Create `test/agents/io_model_test.exs`:

```elixir
defmodule Normandy.Agents.IoModelTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentOutputSchema

  test "the default schemas tell the model what the message is (AX-26)" do
    assert %{
             description: "A chat message from the user.",
             properties: %{chat_message: %{description: "The user's message."}}
           } = BaseAgentInputSchema.__schema__(:specification)

    assert %{
             description: "Your reply to the user.",
             properties: %{
               chat_message: %{description: "Your reply to the user, in plain text or Markdown."}
             }
           } = BaseAgentOutputSchema.__schema__(:specification)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/components/system_prompt_generator_test.exs test/tools/memory_test.exs test/a2a/agent_tool_test.exs test/llm/json/retry_feedback_test.exs test/agents/io_model_test.exs`
Expected: FAIL — 3 in `SystemPromptGeneratorTest` (old headings), 1 in `MemoryTest` (the shouted text), 5 in `AgentToolTest` (the three descriptions, the 1_000-character cut, no message hint), 2 in `RetryFeedbackTest` (`input_too_large` is shown; `%Jason.DecodeError{...}` is inspected), 1 in `IoModelTest` (`"base input"`).

- [ ] **Step 3: Implement**

`lib/normandy/components/system_prompt_generator.ex`:

```elixir
  @background "Role"
  @steps "How to work"
  @output "Output"
```

In the first `generate_prompt/1` clause replace
`background: ["This is a conversation with a helpful and friendly AI assistant."]` with
`background: ["You are a helpful assistant."]`. In `build_context/2` replace
`"# EXTRA INFORMATION AND CONTEXT",` with `"# Context",`.

`lib/normandy/tools/memory.ex`, `description/1`: the `base` heredoc becomes (the
`Shared directories:` suffix code after it is unchanged):

```elixir
    base = """
    Persistent memory that survives across conversations, stored as files under /memories.
    At the start of a task, view /memories to pick up earlier progress. Record durable progress and decisions as you go; your context may be reset.
    Keep the directory organized: rename or delete files that are no longer relevant, and do not create new files unless necessary. Never store secrets.
    Commands: view (a directory listing or a file with line numbers), create (create or overwrite a file), str_replace, insert, delete (a file or a directory), rename (a file or a directory).\
    """
```

`lib/normandy/agents/io_model.ex`:

```elixir
  io_schema "A chat message from the user." do
    field(:chat_message, :string, description: "The user's message.")
  end
```

```elixir
  io_schema "Your reply to the user." do
    field(:chat_message, :string,
      description: "Your reply to the user, in plain text or Markdown."
    )
  end
```

`lib/normandy/llm/json/retry_feedback.ex`: replace the `{:json_parse_error, reason, content}`
clause and the catch-all `build(reason, content, _schema, _adapter)` clause with:

```elixir
  def build(
        {:json_parse_error, reason, content},
        _failed_content,
        schema,
        adapter
      ) do
    parse_feedback(
      "JSON DESERIALIZATION ERROR",
      "Your previous response could not be parsed as valid JSON.",
      format_json_error(reason),
      content,
      schema,
      adapter
    )
  end

  # Any other failure (an answer over the size limit, JSON that is not an object) gets
  # the parse-error template with a plain description. The reason is an Elixir term,
  # never text for the model, so it is not shown.
  def build(reason, content, schema, adapter) do
    parse_feedback(
      "RESPONSE FORMAT ERROR",
      "Your previous response could not be used as the answer.",
      describe_failure(reason),
      content,
      schema,
      adapter
    )
  end

  defp parse_feedback(heading, summary, details, content, schema, adapter) do
    schema_json = adapter.encode!(Normandy.Schema.json_schema(schema), pretty: true)

    """
    # #{heading}

    #{summary}

    ## Error Details
    #{details}

    ## Your Previous Response
    ```
    #{String.slice(content, 0, 500)}#{if String.length(content) > 500, do: "...", else: ""}
    ```

    ## Required Schema
    ```json
    #{schema_json}
    ```

    Respond with a single JSON object whose field names match the schema exactly,
    with strings properly escaped. Put the field values at the top level of that
    object rather than encoding another JSON document inside a string field.
    """
  end

  defp describe_failure({:input_too_large, size, limit}),
    do: "The response is #{size} bytes; the limit is #{limit} bytes. Give a shorter answer."

  defp describe_failure({:unexpected_parse_result, _content}),
    do: "The response is valid JSON, but not a JSON object."

  defp describe_failure(_reason), do: "The response does not match the required format."
```

(`describe_failure/1` goes right after `parse_feedback/6`, before `@spec augment_messages`.)
Replace the last `format_json_error/1` clause

```elixir
  defp format_json_error(reason) do
    "JSON parsing failed: #{inspect(reason)}"
  end
```

with

```elixir
  defp format_json_error(%{__exception__: true} = exception),
    do: "Invalid JSON: #{Exception.message(exception)}"

  defp format_json_error(_reason), do: "The response is not valid JSON."
```

The two reasons that reach the catch-all today are `{:input_too_large, size, limit}`
(`Decoder.decode/3`, returned unchanged by `JsonDeserializer.parse_and_populate/4`) and
`{:unexpected_parse_result, content}` (JSON that decodes to a non-map).

`lib/normandy/a2a/agent_tool.ex`: replace `description/1` (both clauses) and `input_schema/1` with:

```elixir
  # The card is the remote side's own text: it is quoted as the agent's self-description,
  # cut to @max_card_text characters, never presented as an instruction of this agent's.
  @max_card_text 1_000

  @impl Normandy.Tool
  def description(%__MODULE__{agent_card: card, skill_id: nil}),
    do:
      "Sends a message to the remote agent #{card.name} and returns its reply." <>
        self_description(card.description)

  def description(%__MODULE__{agent_card: card, skill_id: skill_id}) do
    lead =
      "Sends a message to the remote agent #{card.name} (skill #{skill_id}) and returns its reply."

    case Enum.find(card.skills, fn s -> s.id == skill_id end) do
      nil -> lead <> self_description(card.description)
      skill -> lead <> self_description(skill.description)
    end
  end

  defp self_description(text) when is_binary(text) and text != "" do
    quoted =
      if String.length(text) > @max_card_text,
        do: String.slice(text, 0, @max_card_text) <> "...",
        else: text

    " It describes itself as: " <> quoted
  end

  defp self_description(_text), do: ""

  @impl Normandy.Tool
  def input_schema(%__MODULE__{agent_card: card}) do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{
          "type" => "string",
          "description" =>
            "Message to send to #{card.name}. It cannot see this conversation, " <>
              "so include every detail it needs."
        }
      },
      "required" => ["message"]
    }
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/components/system_prompt_generator_test.exs test/tools/memory_test.exs test/a2a/agent_tool_test.exs test/llm/json/retry_feedback_test.exs test/agents/io_model_test.exs`
Expected: PASS. Then `mix test` — expected ` 0 failures` (in the prototype no other test pinned these strings: `grep -rn "IDENTITY and PURPOSE\|INTERNAL ASSISTANT\|EXTRA INFORMATION\|ALWAYS VIEW\|Remote A2A agent\|base input\|base output\|RESPONSE FORMAT\|JSON parsing failed" test e2e` hits only the files above).

- [ ] **Step 5: MIGRATING-2.0.md**

Add a new section after the last numbered section (Task 5.5's `## 35.`) and before `## New, non-breaking`:

```markdown
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
```

- [ ] **Step 6: Gate and commit**

Run: `mix format && mix precommit 2>&1 | tee /tmp/w5-5.6a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.6a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/components/system_prompt_generator.ex lib/normandy/tools/memory.ex \
  lib/normandy/agents/io_model.ex lib/normandy/llm/json/retry_feedback.ex \
  lib/normandy/a2a/agent_tool.ex MIGRATING-2.0.md \
  test/components/system_prompt_generator_test.exs test/tools/memory_test.exs \
  test/a2a/agent_tool_test.exs test/llm/json/retry_feedback_test.exs \
  test/agents/io_model_test.exs
git commit -m "fix(prompt): plain headings, default identity and tool descriptions the model can act on"
```

---

### Task 5.6b-i: Dispatch result text (AX-13, AX-15, `pending_approval`)

One builder for every result the model gets instead of a tool's output: nil values are
dropped, every message says what to do next, `pending_approval` and `Dispatch.DenialEnvelope`
are gone, a policy deny with a nil reason no longer sends `"error": null`, and a tool's
`{:error, binary}` (or exception) reaches the model as the bare text with `is_error: true`.

**Files:**
- Modify: `lib/normandy/agents/dispatch.ex` (delete `DenialEnvelope`; `route/3`, `decide/4`, `execute_approved/3`, `dispatch_one/3` call sites; `wrap_error/2`; `policy_denial/4`; replace `denial_result/3`, `validation_error_result/2`, `budget_denial_result/2`, `invalid_input_result/1`, `not_found_result/1`; new `error_result/3`, `policy_keys/1`, `available_tools/1`; Task 5.4a's `invalid_utf8_output/0`; `unencodable_output/1` (decision 23, B3); moduledoc section)
- Modify: `lib/normandy/agents/turn.ex` (`rejection_result/1`, `expiry_result/2`, alias)
- Modify: `lib/normandy/agents/turn/server.ex` (`interrupted_result/1`)
- Modify: `lib/normandy/hooks/runner.ex` (`denial/2`, alias)
- Modify: `e2e/13_budget_policy.exs` (the budget assertion's phrase)
- Modify: `MIGRATING-2.0.md` (§36 bullets; correct §12's expiry map)
- Test: modify `test/agents/dispatch_test.exs`, `test/agents/dispatch_split_test.exs`, `test/agents/turn_approval_test.exs`, `test/agents/turn/server_test.exs`, `test/hooks/runner_test.exs`, `test/hooks/tool_hooks_test.exs`, `test/json_struct_encoding_test.exs`, `test/telemetry/tool_telemetry_test.exs`, `test/tools/tool_input_isolation_test.exs`, `test/mcp/tool_wrapper_test.exs`, `test/tools/memory_test.exs`, `test/agents/tool_result_cap_test.exs` (Task 5.4a's invalid-UTF-8 test)

**Interfaces:**
- Consumes (Task 5.4a): `Dispatch.finish/3` runs at every Dispatch exit and in `ServerGlue`; this task changes only what the builders put in `%ToolResult{}`, so every result still passes `finish/3` (encodability, then the cap). Anchor every `dispatch.ex` edit on the function name, not a line number. If 5.4a bounded the `inspect/1` in `wrap_error/2`'s catch-all clause or in `budget_denial_result/2`, keep 5.4a's catch-all clause as it is; `budget_denial_result/2` is replaced whole below (it no longer inspects anything). 5.4a's `ensure_encodable/1` answers a binary that is not valid UTF-8 with `invalid_utf8_output/0`, `%{error: "the tool ran, but its output is not valid UTF-8 text"}`; that text is a message about the tool's output like a tool's `{:error, binary}`, so this task sends it bare too (Step 3 item 4b, and 5.4a's test in `tool_result_cap_test.exs`). `unencodable_output/1` (an output JSON cannot express, from `ensure_encodable/1` and `wrap_output/2`) is the same failure class and is sent bare as well (decision 23, B3; Step 3 item 4c). Consumes (Task 5.3a): `AgentMemory.request_messages/1` coalesces tool results; the cross-path test below reads `role == "tool"` messages and flattens their content, which holds for one coalesced message as for many.
- Produces: `@doc false Dispatch.error_result(call_id, message, extra \\ %{}) :: %ToolResult{}` — `output: %{error: message}` plus every non-nil `extra` key, `is_error: true`. The result keys other code reads keep their names and meaning: `denied`, `expired`, `interrupted`, `validation_errors`, `rule_id`, `rationale`.

**The texts (verbatim):**

| Result | `output` |
|---|---|
| policy deny, reason `r` | `%{error: "This call was blocked by policy (r). Do not retry it; continue without it or tell the user.", denied: true}` + `rule_id`/`rationale` when not nil |
| policy deny, nil/"" reason | `%{error: "This call was blocked by policy. Do not retry it; continue without it or tell the user.", denied: true}` + non-nil `rule_id`/`rationale` |
| sync `:needs_approval` collapse | `%{error: "This action needs human approval, which is not available in this run. Do not retry it; tell the user it requires approval.", denied: true}` + non-nil `rule_id`/`rationale` |
| invalid input | `%{error: "invalid input for <tool>: <Input.message>; the tool was not run. Correct the input and call the tool again.", validation_errors: errors}` (no `denied`) |
| input not an object | `%{error: "tool input is not a JSON object (it may have been cut off); the tool was not run. Send the arguments as a JSON object."}` (no `denied`) |
| budget | `%{error: "The tool budget is used up; the tool was not run. Answer with what you have.", denied: true}`; a binary reason `b` adds ` (b)` after "used up" |
| unknown tool | `%{error: "No tool named 'x'. Available tools: a, b."}` (sorted; >20 → first 20 then `, and N more.`; none → `"No tool named 'x'. This agent has no tools."`) |
| approver rejected | `%{error: "The approver rejected this call; the tool was not run. Do not retry it; tell the user it was rejected.", denied: true}` |
| approval expired | `%{error: "No approver answered within <ms>ms, so the tool was not run. Do not retry it; tell the user the approval did not arrive.", denied: true, expired: true}` |
| interrupted | `%{error: "tool call interrupted: the previous turn ended before a result was recorded; the tool may or may not have run. Check the current state before repeating it.", interrupted: true}` |
| `before_tool` hook halt, reason `r` | `%{error: "This call was blocked by a hook: <r without a trailing period>. Do not retry it; continue without it or tell the user.", denied: true}` |
| tool `{:error, binary}` / exception | `output: binary` (the exception's message), `is_error: true` |
| tool `{:error, other}` | unchanged: `%{error: other}` (or its `inspect/1` text when JSON cannot express it) |

Executor messages (`"Tool execution timeout after Nms"`, ...) are unchanged text (R8); they now arrive bare through the binary clause. `Hooks.Runner.answered/2` (an `after_tool` crash) is unchanged.

- [ ] **Step 1: Write the failing tests**

`test/agents/dispatch_test.exs` — add `alias Normandy.Components.BaseIOSchema` after `alias Normandy.Agents.Dispatch.Pipeline`. Then:

In `describe "dispatch_one/3 registry miss"`, replace the assertion of `"unknown tool → error ToolResult, tool not executed"` and add a test after it:

```elixir
      assert %ToolResult{
               tool_call_id: "c5",
               is_error: true,
               output: %{error: "No tool named 'nope'. This agent has no tools."}
             } = result
    end

    test "the result names the available tools, sorted, at most 20" do
      config = config_with_tools([%FakeTool{name: "weather"}, %FakeTool{name: "billing"}])
      call = %ToolCall{id: "c5b", name: "wether", input: %{}}

      assert Dispatch.dispatch_one(config, call, Dispatch.default_pipeline()).output == %{
               error: "No tool named 'wether'. Available tools: billing, weather."
             }

      name = &"t#{String.pad_leading(Integer.to_string(&1), 2, "0")}"
      many = config_with_tools(Enum.map(23..1//-1, &%FakeTool{name: name.(&1)}))

      assert Dispatch.dispatch_one(many, call, Dispatch.default_pipeline()).output == %{
               error:
                 "No tool named 'wether'. Available tools: " <>
                   Enum.map_join(1..20, ", ", name) <> ", and 3 more."
             }
    end
```

In `"deny → error ToolResult with rationale fed into output, tool not run"`, replace the final
`assert %ToolResult{...} = result` with the following, and add the test after it:

```elixir
      assert %ToolResult{tool_call_id: "c6", is_error: true, output: output} = result

      assert output == %{
               error:
                 "This call was blocked by policy (weather tool blocked). " <>
                   "Do not retry it; continue without it or tell the user.",
               rule_id: "R-7",
               rationale: "shares state with billing",
               denied: true
             }
    end

    # PolicyEngine.Ruleset's default-action deny is %{reason: nil, rule_id: nil,
    # rationale: nil} (policy_engine_test.exs); the model used to see "error": null.
    test "a deny with nil reason, rule_id and rationale sends no null" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c6b", name: "weather", input: %{"city" => "NYC"}}
      deny = fn _config, _call, _inv -> {:deny, %{reason: nil, rule_id: nil, rationale: nil}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert result.output == %{
               error:
                 "This call was blocked by policy. Do not retry it; continue without it or tell the user.",
               denied: true
             }

      assert [%{content: content, is_error: true}] = BaseIOSchema.to_json(result)

      assert Jason.decode!(content) == %{
               "error" =>
                 "This call was blocked by policy. Do not retry it; continue without it or tell the user.",
               "denied" => true
             }
    end
```

Rename `"needs_approval → tagged denial result with pending_approval: true"` to
`"needs_approval → a denial saying approval is not available, no pending_approval"` and replace
its final assertion with:

```elixir
      assert %ToolResult{tool_call_id: "c7", is_error: true, output: output} = result

      assert output == %{
               error:
                 "This action needs human approval, which is not available in this run. " <>
                   "Do not retry it; tell the user it requires approval.",
               rationale: "high-cost op",
               denied: true
             }
```

In `"budget_check_fn returning {:error, reason} denies before executing"`, replace the two
final assertions and add a test after it:

```elixir
      assert %ToolResult{tool_call_id: "c12", is_error: true} = result

      assert result.output == %{
               error:
                 "The tool budget is used up; the tool was not run. Answer with what you have.",
               denied: true
             }

      refute inspect(result.output) =~ "cap_exceeded"
    end

    test "a budget reason that is text is shown; any other term is not" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12b", name: "weather", input: %{"city" => "NYC"}}
      over = fn _config, _call -> {:error, "daily cap of 50 calls reached"} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      assert Dispatch.dispatch_one(config, call, pipeline).output.error ==
               "The tool budget is used up (daily cap of 50 calls reached); " <>
                 "the tool was not run. Answer with what you have."
    end
```

`test/agents/dispatch_split_test.exs`:
- `"input that is not a JSON object is refused and the model is told"`: replace `assert output.error =~ "not a JSON object"` with
  ```elixir
        assert output == %{
                 error:
                   "tool input is not a JSON object (it may have been cut off); " <>
                     "the tool was not run. Send the arguments as a JSON object."
               }
  ```
- `"an enum violation → {:deny, validation error}, never classified to :execute"`: replace `assert result.output.denied == true` with
  ```elixir
      # A fixable mistake is not a denial: the model is told to correct it and retry.
      refute Map.has_key?(result.output, :denied)
  ```
  and the expected error's last string `"the tool was not run"` with `"the tool was not run. Correct the input and call the tool again."`.
- `"unknown keys on a hand-written schema are named in the result"`: same last-string change.
- `"dispatch_one: a malformed call never reaches run/2"`: replace `assert %ToolResult{tool_call_id: "v4", is_error: true, output: %{denied: true}} = result` with `assert %ToolResult{tool_call_id: "v4", is_error: true, output: %{validation_errors: [_]}} = result`.
- `"budget {:error, reason} → budget-denial result, tool not run"`: replace `assert result.output.error =~ "budget check failed"` with `assert result.output.error =~ "The tool budget is used up"`.
- `"the registration timeout bounds the run"`: replace the assertion with
  ```elixir
      # A binary error reason is sent as it is (AX-15), with is_error set.
      assert %ToolResult{is_error: true, output: "Tool execution timeout after 20ms"} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())
  ```
- `"input that no longer validates is answered with the validation result"`: the expected `output:` becomes `%{validation_errors: [%{constraint: :unknown_keys}]}`.
- Rename `"needs_approval still collapses to the interim denial (pending_approval: true)"` to `"needs_approval still collapses to the interim denial"`; replace its assertion with
  ```elixir
      assert %ToolResult{is_error: true, output: %{denied: true} = output} =
               Dispatch.dispatch_one(config, call, pipeline)

      refute Map.has_key?(output, :pending_approval)
      assert output.error =~ "needs human approval, which is not available in this run"
  ```

`test/agents/turn_approval_test.exs`:
- `":continue appends expired results in batch order after the event, then steers"`: the expected `output` becomes
  ```elixir
      assert output == %{
               error:
                 "No approver answered within 50ms, so the tool was not run. " <>
                   "Do not retry it; tell the user the approval did not arrive.",
               denied: true,
               expired: true
             }
  ```
- `"all rejected → applies held + denial results in batch order, decrements once"`: in the effects list replace `%ToolResult{tool_call_id: "p1", is_error: true, output: %{denied: true}}` with `%ToolResult{tool_call_id: "p1", is_error: true, output: rejected}`, and after the `] = effects` add
  ```elixir
      assert rejected == %{
               error:
                 "The approver rejected this call; the tool was not run. " <>
                   "Do not retry it; tell the user it was rejected.",
               denied: true
             }
  ```

`test/agents/turn/server_test.exs`:
- `"default :continue tells the model the approval timed out"`: the matched `output:` becomes
  ```elixir
                     output: %{
                       expired: true,
                       error:
                         "No approver answered within 50ms, so the tool was not run. " <>
                           "Do not retry it; tell the user the approval did not arrive."
                     }
  ```
- `"the next turn closes the unanswered tool_use before the user message"`: the `error:` becomes
  ```elixir
                     error:
                       "tool call interrupted: the previous turn ended before a result was " <>
                         "recorded; the tool may or may not have run. Check the current " <>
                         "state before repeating it."
  ```

`test/hooks/runner_test.exs`:
- `"a before_tool halt with a reason becomes a denial answering the call"`: the expected `output:` becomes
  ```elixir
                  output: %{
                    error:
                      "This call was blocked by a hook: blocked. " <>
                        "Do not retry it; continue without it or tell the user.",
                    denied: true
                  },
  ```
- `":closed halts a haltable event with a reason naming the hook, not the message"`: the last assertion becomes
  ```elixir
      assert msg ==
               "This call was blocked by a hook: hook Normandy.Test.Hooks.Probe crashed: " <>
                 "throw. Do not retry it; continue without it or tell the user."
  ```

`test/hooks/tool_hooks_test.exs`, `"a module halt skips later modules and the function hooks, emitting one denial"`: the expected `output:` becomes the same map as the first runner_test change (`"This call was blocked by a hook: blocked. Do not retry it; continue without it or tell the user."`, `denied: true`).

`test/json_struct_encoding_test.exs`, `"an exception as the error reason is sent as its message"`: the two assertions become
```elixir
      assert %ToolResult{is_error: true, output: "upstream down"} = result
      assert model_content(result) == "upstream down"
```
(`"an error reason JSON cannot express is sent as its text"` — `{:http, 503}` — is unchanged.)

`test/telemetry/tool_telemetry_test.exs`, `"stop carries error_type when the tool failed; the model still sees {:error, msg}"`: `output: %{error: "Cannot divide by zero"}` becomes `output: "Cannot divide by zero"`.

`test/tools/tool_input_isolation_test.exs`, `assert_isolated/0` (runs for `BaseAgent.run/2`, `BaseAgent.stream/3` and `Turn.Server`: this is the cross-path test for this task):
```elixir
    assert output["error"] ==
             ~s(invalid input for lookup: unknown keys "endpoint", "timeout"; ) <>
               ~s(expected only "query"; the tool was not run. ) <>
               "Correct the input and call the tool again."
```
and
```elixir
    # A binary error reason reaches the model bare, with is_error (AX-15).
    assert slow.content == "Tool execution timeout after 50ms"
```

`test/mcp/tool_wrapper_test.exs`, `"a tool with no input schema answers the call with an error result"`:
```elixir
      assert %ToolResult{is_error: true, output: %{error: error}} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert error ==
               "invalid input for search: the tool's input_schema/1 returned nil, " <>
                 "not a JSON Schema map; the tool was not run. Correct the input and call " <>
                 "the tool again."
```

`test/agents/tool_result_cap_test.exs` (Task 5.4a), `"an output that is not valid UTF-8 becomes an error result"`: `output: %{error: "the tool ran, but its output is not valid UTF-8 text"}` becomes `output: "the tool ran, but its output is not valid UTF-8 text"`.

The unencodable-output error is sent bare too (decision 23, B3). Three existing tests change:
- `test/json_struct_encoding_test.exs`, `"a tool output JSON cannot express becomes an error result naming its type"`: the pattern becomes
  ```elixir
      assert %ToolResult{
               is_error: true,
               output: "the tool ran, but its output cannot be sent as JSON: it contains a tuple"
             } = execute({:ok, %{at: {2026, 10, 5}}})
  ```
- `test/agents/turn/server_test.exs`, `"an after_tool output JSON cannot express on a rejected result is an error result; the session goes on"`: `assert [%ToolResult{is_error: true, output: %{error: error}}] =` becomes `assert [%ToolResult{is_error: true, output: error}] =` (the `assert error == ...` line is unchanged).
- `test/hooks/tool_hooks_test.exs`, `describe "a hook-built result JSON cannot express"`, `assert_safe_error/2`: `assert %ToolResult{is_error: true, output: %{error: error}} = result` becomes `assert %ToolResult{is_error: true, output: error} = result` (its three tests change with it).

`test/tools/memory_test.exs`: change `alias Normandy.Tools.{Context, Input, Memory}` to `alias Normandy.Tools.{Context, Input, Memory, Toolset}` and append before the final `end`:

```elixir
  # AX-15: the reference error string reaches the model as it is, not as
  # {"error": "Error: ..."}.
  test "a memory error is sent bare, with is_error, through Dispatch" do
    alias Normandy.Agents.Dispatch
    alias Normandy.Components.{BaseIOSchema, ToolCall, ToolResult}

    config = %{
      name: "a",
      toolset: Toolset.new([tool()]),
      tool_context: %{memory_namespace: "acme/u-1"}
    }

    call = %ToolCall{
      id: "m1",
      name: "memory",
      input: %{"command" => "str_replace", "path" => "/memories/x.md", "old_str" => "a"}
    }

    expected = "Error: The path /memories/x.md does not exist. Please provide a valid path."

    assert %ToolResult{is_error: true, output: ^expected} =
             result = Dispatch.dispatch_one(config, call)

    assert [%{content: ^expected, is_error: true}] = BaseIOSchema.to_json(result)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs test/agents/turn_approval_test.exs test/agents/turn/server_test.exs test/hooks test/json_struct_encoding_test.exs test/telemetry/tool_telemetry_test.exs test/tools/tool_input_isolation_test.exs test/mcp/tool_wrapper_test.exs test/tools/memory_test.exs test/agents/tool_result_cap_test.exs`
Expected: FAIL — stacked on 5.1–5.6a, 33 failures (27 in the files above, the four new tests included, plus 5.4a's invalid-UTF-8 test, plus the five unencodable-output tests of decision 23; measured on 5.6a's `lib` with this step's tests: 33, and 28 for the text before decision 23), e.g. `dispatch_test` "No tool named" vs `"Tool 'nope' not found in registry"`, the default-deny test sees `error: nil`, `tool_input_isolation_test` sees `{"error":"Tool execution timeout after 50ms"}` on all three paths, the memory test sees `%{error: "Error: The path ..."}`.

- [ ] **Step 3: Implement — `lib/normandy/agents/dispatch.ex`**

1. Delete the whole `defmodule DenialEnvelope do ... end` block (dead code: `grep -rn DenialEnvelope lib test` hits only its definition).
2. `route/3`: `{:deny, not_found_result(call)}` → `{:deny, not_found_result(config, call)}`. `execute_approved/3`: `:error -> answer(config, call, not_found_result(call), pipeline)` → `:error -> answer(config, call, not_found_result(config, call), pipeline)` (keep any `finish/3` wrapping 5.4a added around it).
3. `decide/4`: `policy_denial(config, call, info, false)` → `policy_denial(config, call, info, :deny)`. `dispatch_one/3`'s `:needs_approval` arm: `policy_denial(config, call, info, true)` → `policy_denial(config, call, info, :needs_approval)`. `policy_denial/4` becomes:
   ```elixir
  defp policy_denial(config, call, info, verdict) do
    emit_denied(config, call, :policy, Map.get(info, :rule_id))
    denial_result(call, info, verdict)
  end
   ```
4. `wrap_error/2`: replace the comment above it and the exception clause with the following (the catch-all clause after it stays as it is, including any 5.4a bound on its `inspect/1`):
   ```elixir
  # An error reason is a message for the model. A binary is sent as it is (AX-15: the
  # memory tool's reference strings, an Executor timeout), with is_error carrying the
  # flag; an exception as its message (encoding it would send its fields and
  # "__exception__"). Any other term keeps the %{error: term} shape, as its inspect/1
  # text when JSON cannot express it (a tuple such as {:http, 500}).
  defp wrap_error(call, error) when is_binary(error),
    do: %ToolResult{tool_call_id: call.id, output: error, is_error: true}

  defp wrap_error(call, error) when is_exception(error),
    do: %ToolResult{tool_call_id: call.id, output: Exception.message(error), is_error: true}
   ```
   4b. (Task 5.4a, X5.) Replace `invalid_utf8_output/0`
   ```elixir
  defp invalid_utf8_output,
    do: %{error: "the tool ran, but its output is not valid UTF-8 text"}
   ```
   with
   ```elixir
  # Sent bare, like a tool's own {:error, binary} (AX-15).
  defp invalid_utf8_output, do: "the tool ran, but its output is not valid UTF-8 text"
   ```
   4c. (Decision 23, B3.) Replace `unencodable_output/1`
   ```elixir
  defp unencodable_output(exception),
    do: %{
      error: "the tool ran, but its output cannot be sent as JSON: #{unencodable(exception)}"
    }
   ```
   with
   ```elixir
  # Sent bare, like invalid_utf8_output/0 and a tool's own {:error, binary} (AX-15).
  defp unencodable_output(exception),
    do: "the tool ran, but its output cannot be sent as JSON: #{unencodable(exception)}"
   ```
5. Replace `denial_result/3`, `validation_error_result/2`, `budget_denial_result/2`, `invalid_input_result/1` and `not_found_result/1` (everything from `defp denial_result(` up to the `# A JSON object string is decoded.` comment) with:
   ```elixir
  @doc false
  # The one shape of a result answering a call Normandy did not run as asked (Dispatch's
  # denials and errors, Turn's rejection and expiry, Turn.Server's interrupted result,
  # Hooks.Runner's halts): `%{error: message}` plus every extra key whose value is not
  # nil, with is_error set. A nil is never sent as a JSON null.
  @spec error_result(String.t() | nil, String.t(), map()) :: ToolResult.t()
  def error_result(call_id, message, extra \\ %{}) when is_binary(message) and is_map(extra) do
    output =
      for {key, value} <- extra, not is_nil(value), into: %{error: message}, do: {key, value}

    %ToolResult{tool_call_id: call_id, output: output, is_error: true}
  end

  defp denial_result(call, info, :deny) do
    message =
      case Map.get(info, :reason) do
        reason when is_binary(reason) and reason != "" ->
          "This call was blocked by policy (#{reason}). " <>
            "Do not retry it; continue without it or tell the user."

        _none ->
          "This call was blocked by policy. Do not retry it; continue without it or tell the user."
      end

    error_result(call.id, message, policy_keys(info))
  end

  defp denial_result(call, info, :needs_approval) do
    error_result(
      call.id,
      "This action needs human approval, which is not available in this run. " <>
        "Do not retry it; tell the user it requires approval.",
      policy_keys(info)
    )
  end

  defp policy_keys(info),
    do: %{rule_id: Map.get(info, :rule_id), rationale: Map.get(info, :rationale), denied: true}

  defp validation_error_result(call, errors) do
    error_result(
      call.id,
      "invalid input for #{call.name}: #{Input.message(errors)}; the tool was not run. " <>
        "Correct the input and call the tool again.",
      %{validation_errors: errors}
    )
  end

  # The budget tracker's reason is shown only when it is text; any other term is the
  # tracker's own data, not a message for the model.
  defp budget_denial_result(call, reason) do
    detail = if is_binary(reason) and reason != "", do: " (#{reason})", else: ""

    error_result(
      call.id,
      "The tool budget is used up#{detail}; the tool was not run. Answer with what you have.",
      %{denied: true}
    )
  end

  defp invalid_input_result(call) do
    error_result(
      call.id,
      "tool input is not a JSON object (it may have been cut off); the tool was not run. " <>
        "Send the arguments as a JSON object."
    )
  end

  @max_listed_tools 20

  defp not_found_result(config, call),
    do: error_result(call.id, "No tool named '#{call.name}'. #{available_tools(config)}")

  defp available_tools(%{toolset: %Toolset{} = toolset}) do
    case toolset |> Toolset.list_names() |> Enum.sort() do
      [] ->
        "This agent has no tools."

      names when length(names) > @max_listed_tools ->
        {listed, rest} = Enum.split(names, @max_listed_tools)
        "Available tools: #{Enum.join(listed, ", ")}, and #{length(rest)} more."

      names ->
        "Available tools: #{Enum.join(names, ", ")}."
    end
  end

  defp available_tools(_config), do: "This agent has no tools."
   ```
6. Moduledoc: after the `## Telemetry` section add:
   ```
  ## Results the model sees

  A call answered without running its tool as asked gets `is_error: true` and an
  `output` of `%{error: message}` plus only the keys that apply (never a `null`). The
  message says what happened and what to do next. Keys: `denied: true` (a policy deny,
  the synchronous `:needs_approval` collapse, a budget refusal, a before-hook halt, a
  rejected or expired approval), `rule_id` and `rationale` (a policy's, when set),
  `validation_errors` (input that failed the tool's schema: a fixable mistake, so not
  `denied`), `expired: true` and `interrupted: true`. A tool's own `{:error, binary}`,
  or a raised exception, reaches the model as that text alone; any other error term as
  `%{error: term}`.
   ```

- [ ] **Step 4: Implement — Turn, Turn.Server, Hooks.Runner**

`lib/normandy/agents/turn.ex`: add `alias Normandy.Agents.Dispatch` as the first alias (before `alias Normandy.Agents.Turn.State`) and replace `rejection_result/1` and `expiry_result/2`:

```elixir
  # Denial result for a parked call the approver rejected (or never decided).
  defp rejection_result(%ToolCall{id: id}) do
    Dispatch.error_result(
      id,
      "The approver rejected this call; the tool was not run. " <>
        "Do not retry it; tell the user it was rejected.",
      %{denied: true}
    )
  end

  # Result for a parked call whose approval window expired with no decision.
  defp expiry_result(%ToolCall{id: id}, ms) do
    Dispatch.error_result(
      id,
      "No approver answered within #{ms}ms, so the tool was not run. " <>
        "Do not retry it; tell the user the approval did not arrive.",
      %{denied: true, expired: true}
    )
  end
```

(`Dispatch.error_result/3` is pure, so the core stays pure. If `ToolResult` is then unused in
`turn.ex`, `mix compile --warnings-as-errors` says so; at HEAD it is still used elsewhere in the
module.)

`lib/normandy/agents/turn/server.ex` (`Dispatch` is already aliased there):

```elixir
  defp interrupted_result(call) do
    Dispatch.error_result(
      Map.get(call, :id),
      "tool call interrupted: the previous turn ended before a result was recorded; " <>
        "the tool may or may not have run. Check the current state before repeating it.",
      %{interrupted: true}
    )
  end
```

`lib/normandy/hooks/runner.ex`: add `alias Normandy.Agents.Dispatch` before `alias Normandy.Behaviours.Hooks`; replace `denial/2`:

```elixir
  # A before_tool halt answers the call: the hook's reason, then what to do next.
  defp denial(call, reason) do
    Dispatch.error_result(
      call.id,
      "This call was blocked by a hook: #{String.trim_trailing(reason, ".")}. " <>
        "Do not retry it; continue without it or tell the user.",
      %{denied: true}
    )
  end
```

`e2e/13_budget_policy.exs`: in the `"the third lookup was refused by the budget"` assertion replace `S.recalls?(history, "budget check failed")` with `S.recalls?(history, "The tool budget is used up")`. (The `"R-no-drops"` assertion still holds: a non-nil `rule_id` is kept.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs test/agents/turn_approval_test.exs test/agents/turn/server_test.exs test/hooks test/json_struct_encoding_test.exs test/telemetry/tool_telemetry_test.exs test/tools/tool_input_isolation_test.exs test/mcp/tool_wrapper_test.exs test/tools/memory_test.exs test/agents/tool_result_cap_test.exs`, then `mix test`.
Expected: PASS; full suite ` 0 failures`. Leftover check: `grep -rn "pending_approval\|DenialEnvelope\|not found in registry\|budget check failed" lib test e2e` → only the two new tests that name `pending_approval` (`dispatch_test.exs`'s test name, `dispatch_split_test.exs`'s `refute Map.has_key?(output, :pending_approval)`).

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 36.`:

```markdown
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
```

In `## 12.`, replace the sentence

```
Approval expiry: a parked call that nobody approved now gets
`%{error: "approval timed out: no approver responded within <ms>ms", denied: true,
expired: true, pending_approval: false}` instead of `"tool call rejected by approver"`, and an
```

with

```
Approval expiry: a parked call that nobody approved now gets
`%{error: "No approver answered within <ms>ms, so the tool was not run. ...", denied: true,
expired: true}` (see §36) instead of the rejection result, and an
```

- [ ] **Step 7: Gate and commit**

Run: `mix format && mix precommit 2>&1 | tee /tmp/w5-5.6b-i.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.6b-i.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/agents/dispatch.ex lib/normandy/agents/turn.ex \
  lib/normandy/agents/turn/server.ex lib/normandy/hooks/runner.ex \
  e2e/13_budget_policy.exs MIGRATING-2.0.md \
  test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs \
  test/agents/turn_approval_test.exs test/agents/turn/server_test.exs \
  test/hooks/runner_test.exs test/hooks/tool_hooks_test.exs \
  test/json_struct_encoding_test.exs test/telemetry/tool_telemetry_test.exs \
  test/tools/tool_input_isolation_test.exs test/mcp/tool_wrapper_test.exs \
  test/tools/memory_test.exs test/agents/tool_result_cap_test.exs
git commit -m "fix(dispatch): error results say what to do next; tool error text is sent bare"
```

---

### Task 5.6b-ii: MCP `isError` and content (AX-14); an empty final answer is an error (AX-32)

**Files:**
- Modify: `lib/normandy/mcp/tool_wrapper.ex` (`run/2`; new `normalize_result/1`, `content/1`, `error_flag?/1`, `content_result/2`, `blocks_text/1`, `block_text/1`; moduledoc `## Results`)
- Modify: `lib/normandy/agents/base_agent.ex` (the `%{chat_message: _}` clause of `convert_final_text/3` and the comment above it)
- Modify: `test/support/scripted_tool_client.ex` (final answer is text, not the empty response model)
- Modify: `MIGRATING-2.0.md` (§36 bullets)
- Test: modify `test/mcp/tool_wrapper_test.exs`, `test/agents/base_agent_stream_test.exs`, `test/agents/turn/server_test.exs`, `test/tools/tool_input_isolation_test.exs`

**Interfaces:**
- Consumes (5.6b-i): `wrap_error/2` sends `{:error, binary}` bare, so an MCP `isError` result reaches the model as its text with `is_error: true`. Consumes (5.1): `convert_final_text/3`'s non-chat clauses may have been reshaped by 5.1; only the `%{chat_message: _}` clause changes here. Consumes (5.2a): a `max_tokens`/`refusal` final response is an error before conversion, so it never reaches this check. Consumes (5.7a): `ToolWrapper.new/4` requires `:prefix` after 5.7a, which runs later; the new tests build wrappers with `ToolWrapper.new(MockAdapter, client, tool)` like the file's existing setup, so 5.7a's mechanical update of this file covers them.
- Produces: `{:error, %LLMError{type: :invalid_output, retryable?: false}}` with detail `"expected a final answer, got an empty one: the model ended its turn with no text"` from `run/3`, `stream/3`, `Turn.Driver`, `Turn.Inline` and `Turn.Server` when a `:chat_message` output schema's final text is empty or whitespace. Every interpreter builds the final answer through `convert_final_output/4` → `convert_final_text/3`, so no Turn core change.

- [ ] **Step 1: Write the failing tests**

`test/mcp/tool_wrapper_test.exs` — in `MockAdapter`, put this clause first, directly under the `@impl true` that precedes `call_tool(_client, "search", ...)`:

```elixir
    # A client of {:returns, result} answers every call with that CallToolResult.
    def call_tool({:returns, result}, _name, _args, _opts), do: {:ok, result}
```

and add before `describe "dispatch" do`:

```elixir
  # The shapes MCP adapters hand back (see ToolWrapper's normalize_result/1).
  defmodule ExMCPLikeResponse do
    defstruct [:content, :meta, is_error: false]
  end

  defmodule HermesLikeResponse do
    defstruct [:result, is_error: false]
  end

  describe "CallToolResult normalization (AX-14)" do
    defp run_returning(result, tool) do
      wrapper = ToolWrapper.new(MockAdapter, {:returns, result}, tool)
      Tool.run(wrapper, %Context{tool_call_id: "t", input: %{}})
    end

    test "text blocks become the output text; isError: true becomes {:error, text}", %{
      tool: tool
    } do
      text = fn t -> %{"type" => "text", "text" => t} end

      assert run_returning(%{"content" => [text.("a"), text.("b")], "isError" => false}, tool) ==
               {:ok, "a\nb"}

      assert run_returning(%{"content" => [text.("rate limited")], "isError" => true}, tool) ==
               {:error, "rate limited"}
    end

    test "an atom-keyed struct (ExMCP) and a wrapped result (Hermes)", %{tool: tool} do
      ex_mcp = %ExMCPLikeResponse{
        content: [
          %{type: "text", text: "hi", data: nil, annotations: nil},
          %{type: "image", text: nil, data: "iVBORw0KGgo=", annotations: nil}
        ],
        is_error: false
      }

      assert run_returning(ex_mcp, tool) == {:ok, "hi\n[image content omitted]"}

      hermes = %HermesLikeResponse{
        result: %{"content" => [%{"type" => "text", "text" => "no such city"}], "isError" => true},
        is_error: true
      }

      assert run_returning(hermes, tool) == {:error, "no such city"}
    end

    test "an error with no text still says what happened", %{tool: tool} do
      assert run_returning(%{"content" => [], "isError" => true}, tool) ==
               {:error, "The MCP tool reported an error and sent no text."}
    end

    test "a string or a map without content passes through", %{tool: tool} do
      assert run_returning("plain", tool) == {:ok, "plain"}
      assert run_returning(%{"answer" => 42}, tool) == {:ok, %{"answer" => 42}}
    end

    test "through Dispatch an MCP error is an is_error result with the bare text", %{tool: tool} do
      alias Normandy.Agents.Dispatch
      alias Normandy.Components.{BaseIOSchema, ToolCall, ToolResult}

      result = %{"content" => [%{"type" => "text", "text" => "quota exceeded"}], "isError" => true}
      wrapper = ToolWrapper.new(MockAdapter, {:returns, result}, tool)
      config = %{name: "a", toolset: Toolset.new([wrapper])}
      call = %ToolCall{id: "e1", name: "search", input: %{"query" => "x"}}

      assert %ToolResult{is_error: true, output: "quota exceeded"} =
               dispatched = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert [%{content: "quota exceeded", is_error: true}] = BaseIOSchema.to_json(dispatched)
    end
  end
```

(The two shape modules mirror `deps/ex_mcp/lib/ex_mcp/response.ex` — `:content` with atom-keyed
blocks whose `type` is a string, `:is_error` — and Claudio's Hermes adapter, which unwraps
`%{__struct__: _, result: map}`; no dependency on either library.)

`test/agents/base_agent_stream_test.exs` — replace the test `"an empty final answer is \"\" in a chat schema"` with

```elixir
    test "an empty final answer is :invalid_output in a chat schema too (AX-32)" do
      for text <- ["", "  \n"] do
        a = tool_agent(%ToolThenText{text: text})

        assert {:error, %LLMError{type: :invalid_output} = ran} = BaseAgent.run(a, "q")

        assert {:error, %LLMError{type: :invalid_output} = streamed} =
                 BaseAgent.stream(a, "q", collect())

        for error <- [ran, streamed] do
          assert Exception.message(error) =~
                   "expected a final answer, got an empty one: " <>
                     "the model ended its turn with no text"
        end
      end
    end
```

and the test `"an empty answer after a tool loop is \"\", as with the default schema"` with

```elixir
    test "an empty answer after a tool loop is :invalid_output, as with the default schema" do
      a = nil_schema(tool_agent(%ToolThenText{text: ""}))

      assert {:error, %LLMError{type: :invalid_output}} = BaseAgent.run(a, "q")
      assert {:error, %LLMError{type: :invalid_output}} = BaseAgent.stream(a, "q", collect())
    end
```

`test/agents/turn/server_test.exs` — first test inside `describe "failure replies and crashing callbacks (AGENTS-1)" do` (it uses that block's `start_server/3` and `final_handlers/1`):

```elixir
    test "an empty final answer after a tool round is :invalid_output (AX-32)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      call_llm = fn _config, _state, _request ->
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
          %Normandy.Agents.ToolCallResponse{
            content: nil,
            tool_calls: [%ToolCall{id: "w1", name: "weather", input: %{}}]
          }
        else
          %Normandy.Agents.ToolCallResponse{content: "", tool_calls: []}
        end
      end

      config = %{
        base_config_with_tools()
        | output_schema: %Normandy.Agents.BaseAgentOutputSchema{}
      }

      {srv, _store} =
        start_server("s-empty-answer", config, handlers: final_handlers(%{call_llm: call_llm}))

      assert {:error, %Normandy.LLMError{type: :invalid_output}} = Turn.Server.run(srv, "go")
    end
```

(`final_handlers/1` and `start_server/3` are `defp`s defined further down in that describe block;
Elixir allows the call. If Task 5.2a/5.3c added fields to `ToolCallResponse` that the handler
must set, `%ToolCallResponse{}` defaults cover them.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/mcp/tool_wrapper_test.exs test/agents/base_agent_stream_test.exs test/agents/turn/server_test.exs`
Expected: FAIL — the normalization tests get the raw maps/structs back as `{:ok, ...}` (and `is_error: false` through Dispatch); the stream tests get `{:ok, _, %BaseAgentOutputSchema{chat_message: ""}}`; the Server test gets `{:ok, %BaseAgentOutputSchema{chat_message: ""}}`.

- [ ] **Step 3: Implement**

`lib/normandy/mcp/tool_wrapper.ex` — `run/2` and the new private functions:

```elixir
  @impl Normandy.Tool
  def run(%__MODULE__{adapter: adapter, client: client, tool: tool}, %Context{input: input}) do
    case adapter.call_tool(client, tool.name, input, []) do
      {:ok, result} -> normalize_result(result)
      {:error, reason} -> {:error, "MCP tool '#{tool.name}' failed: #{inspect(reason)}"}
    end
  end

  # An MCP CallToolResult as the tool's return: its text blocks joined by newlines, a
  # one-line note for each block of another type, and `isError: true` as {:error, text}
  # (so the model gets is_error). Adapters hand it over as the JSON-RPC result map
  # (string keys), an atom-keyed map or struct (ExMCP.Response: :content, :is_error), or
  # a struct wrapping it under :result (Hermes). A binary, or any other term, is
  # returned as it is.
  defp normalize_result(result) when is_binary(result), do: {:ok, result}

  defp normalize_result(%{} = result) do
    inner = Map.get(result, :result)

    cond do
      is_list(content(result)) ->
        content_result(content(result), error_flag?(result))

      is_map(inner) and is_list(content(inner)) ->
        content_result(content(inner), error_flag?(result) or error_flag?(inner))

      true ->
        {:ok, result}
    end
  end

  defp normalize_result(result), do: {:ok, result}

  defp content(map), do: Map.get(map, "content", Map.get(map, :content))

  defp error_flag?(map),
    do: Enum.any?(["isError", :isError, "is_error", :is_error], &(Map.get(map, &1) == true))

  defp content_result(blocks, true) do
    case blocks_text(blocks) do
      "" -> {:error, "The MCP tool reported an error and sent no text."}
      text -> {:error, text}
    end
  end

  defp content_result(blocks, false), do: {:ok, blocks_text(blocks)}

  defp blocks_text(blocks), do: Enum.map_join(blocks, "\n", &block_text/1)

  defp block_text(%{} = block) do
    case Map.get(block, "type", Map.get(block, :type)) do
      type when type in ["text", :text] ->
        Map.get(block, "text", Map.get(block, :text)) || ""

      type when is_binary(type) or (is_atom(type) and not is_nil(type)) ->
        "[#{type} content omitted]"

      _other ->
        "[content omitted]"
    end
  end

  defp block_text(_block), do: "[content omitted]"
```

(The `{:error, reason}` branch keeps its `inspect/1`; SEC-11 replaces it in Task 5.7.)
Add to the moduledoc, before `## Trace context`:

```
  ## Results

  The server's `CallToolResult` reaches the model as text: its text blocks joined by
  newlines, and a one-line `[<type> content omitted]` note for each image, audio or
  resource block. A result with `isError: true` is an error result (`is_error` on the
  `tool_result`). A result in no known shape (no `content` list) is passed on as it is.
```

`lib/normandy/agents/base_agent.ex` — in the comment above `convert_final_text/3` replace the
bullet `#   * a :chat_message schema gets the unwrapped text, "" for an empty answer;` with

```elixir
  #   * a :chat_message schema gets the unwrapped text; an empty or whitespace-only
  #     answer (the model ended its turn with no text, AX-32) is the :invalid_output
  #     LLMError, never a blank success;
```

and the `%{chat_message: _}` clause with

```elixir
  defp convert_final_text(_config, text, %{chat_message: _} = output_schema) do
    answer = unwrap_llm_content(text)

    if is_binary(answer) and String.trim(answer) == "" do
      raise LLMError.new(
              type: :invalid_output,
              retryable?: false,
              detail:
                "expected a final answer, got an empty one: the model ended its turn with no text"
            )
    end

    Map.put(output_schema, :chat_message, answer)
  end
```

(The raise is caught where the non-chat `:invalid_output` raise already is: `run/3` and
`stream/3` return `{:error, %LLMError{}}`, `Turn.Server.run/2` replies it bare.)

Test clients whose final answer was the empty response model now answer with text:

`test/support/scripted_tool_client.ex`: moduledoc sentence `once one is present it returns the
response model unchanged.` → `once one is present it answers with the text `:answer` (an empty
final answer is an error, AX-32).`; `defstruct calls: [], options: %{}` → `defstruct calls: [],
answer: "done", options: %{}`; and in `converse/3` `do: request.response_model,` →
`do: %ToolCallResponse{content: client.answer, tool_calls: []},`. (If Task 5.1 already gave this
client a final-answer field, keep 5.1's field and make its default the non-empty `"done"`
instead of adding `:answer`.) Users: `test/agents/tool_context_test.exs` (fails with `:invalid_output` before this edit) and
`test/hooks/tool_hooks_test.exs` (its tests call `Dispatch` directly and never reach a final
answer, so it passes either way; stacked run).

`test/tools/tool_input_isolation_test.exs`, `ScriptedClient.converse/3`: `request.response_model`
(the `if answered?(request)` branch) → `%ToolCallResponse{content: "done", tool_calls: []}`
(`ToolCallResponse` is already aliased in that `defimpl`).

X4 (stacked on 5.1–5.5): no test client added or changed by 5.1–5.5 ends a passing turn on an
empty final answer. `WireScript` (5.1) answers only what each test scripts, and every scripted
final answer is text; the `"text" => ""` blocks in those tests are stream `content_block_start`s
followed by deltas, or tool rounds. With this step's two client edits the full suite passes, so
no further client needs changing.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/mcp/tool_wrapper_test.exs test/agents/base_agent_stream_test.exs test/agents/turn/server_test.exs test/agents/tool_context_test.exs test/hooks/tool_hooks_test.exs test/tools/tool_input_isolation_test.exs`, then `mix test`.
Expected: PASS; full suite ` 0 failures`. (Prototype: without the two test-client edits, 3 tests fail — `ToolContextTest` "a BaseAgent turn hands the contextual tool the session's context", `ToolInputIsolationTest` run/2 and Turn.Server — all with `:invalid_output`.)

- [ ] **Step 5: MIGRATING-2.0.md**

Append to `## 36.`:

```markdown
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
  It is not retried. A test model client that answers with an empty response model must
  answer with text.
```

- [ ] **Step 6: Gate and commit**

Run: `mix format && mix precommit 2>&1 | tee /tmp/w5-5.6b-ii.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.6b-ii.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/mcp/tool_wrapper.ex lib/normandy/agents/base_agent.ex \
  test/support/scripted_tool_client.ex MIGRATING-2.0.md \
  test/mcp/tool_wrapper_test.exs test/agents/base_agent_stream_test.exs \
  test/agents/turn/server_test.exs test/tools/tool_input_isolation_test.exs
git commit -m "fix(agent): MCP isError results are errors; an empty final answer is :invalid_output"
```

---

### Task 5.6c: Schemas as the model sees them (AX-11, AX-17, `$schema`/`title`, AX-18)

Declared fields keep their order on the wire (declaration order is generation order), an
undescribed field has no `description` key, `"$schema"` and `"title"` leave the model-facing
copies, and constraints that constrained decoding drops are stated in the property's
description.

**Files:**
- Create: `lib/normandy/schema/wire.ex` (`Normandy.Schema.Wire`: `encodable/1`, `@doc false ordered_entries!/2`)
- Modify: `lib/normandy/schema.ex` (`__schema__/1`: io_schema description guard, `:property_order`; `get_base_type_spec/2`; `inline_nested_schema/1`'s `Map.take`)
- Modify: `lib/normandy/tools/toolset.ex` (`to_tool_schemas/1`, alias)
- Modify: `lib/normandy/agents/base_agent.ex` (`with_output_schema/2`, alias)
- Modify: `lib/normandy/llm/json/retry_feedback.ex` (both `adapter.encode!` calls, alias)
- Modify: `lib/normandy/llm/json/schema_translator.ex` (object node order; `with_description/2` with constraint notes; moduledoc)
- Modify: `mix.exs` (docs group `Core`)
- Modify: `MIGRATING-2.0.md` (§36 bullets, `## New, non-breaking` bullet)
- Test: create `test/schema/wire_test.exs`; modify `test/agents/base_agent_output_schema_prompt_test.exs`, `test/llm/json/schema_translator_test.exs`, `test/schema_test.exs`, `test/schema_nested_test.exs`, `test/tools/toolset_test.exs`, `test/llm/structured_outputs_test.exs`

**Interfaces:**
- Consumes (5.1): `with_output_schema/2` (and whatever 5.1 renamed around it) still encodes the output schema with `Normandy.JSON.encode!(schema, pretty: true)`; this task wraps the schema in `Wire.encodable/1` at that one call. 5.1's `output_format` reaches the adapter as the struct and is translated by `StructuredOutputs.schema_for/2` → `SchemaTranslator.translate/1`, which this task orders. AX-19 (schema in prompt and constraint) stays open (R2).
- Produces: `Normandy.Schema.Wire.encodable/1` and the spec key `:property_order` (header names). `__schema__(:specification)` stays a plain map (all `spec[:properties][name]` / `Map.get` consumers keep working); it gains `:property_order` and loses `description: ""`. `Toolset.to_tool_schemas/1`'s `input_schema` and `SchemaTranslator.translate/1`'s `"properties"` become `Jason.OrderedObject`s for Normandy schemas (Access `["key"]`/`[:key]` works on them; `Map.get/2`, `Map.keys/1` and map patterns do not).
- X9 (checked stacked on 5.1–5.5): no code from 5.1–5.5 reads these as maps. The only consumers are `BaseAgent` (sync and stream request builders), `ClaudioAdapter.convert_tool_schema/1` and `__structured_schema_for__/2` (pass through to Claudio, which only checks `is_map/1` and encodes with Jason), and `ToolCallResponse.prefix_key/3` (`:erlang.phash2/1`, deterministic for an `OrderedObject` built from `:property_order`). 5.1's `tool_loop_output_format_test.exs` and `claudio_adapter_test.exs` read decoded wire bodies (plain maps) or assert `is_map/1`. A raw-body probe through `ClaudioAdapter` (sync, tool + `output_format`) showed both `tools[0].input_schema.properties` and `output_config.format.schema.properties` in declaration order. `Toolset`'s `introspect_schema/2`, `Tools.Input`, `Schema.Validator` and `Schema.Introspection` read the raw spec, which stays a plain map.

- [ ] **Step 1: Write the failing tests**

Create `test/schema/wire_test.exs`:

```elixir
defmodule Normandy.Schema.WireTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.LLM.Json.SchemaTranslator
  alias Normandy.Schema.Wire
  alias Normandy.Tools.Toolset

  # Field names the VM already knows, declared out of both alphabetical and atom-table
  # order: before AX-17 these came out as error, id, name, type, value.
  defmodule Ordered do
    use Normandy.Schema

    io_schema "An answer in declaration order" do
      field(:value, :string, description: "The answer", required: true)
      field(:type, :string)
      field(:name, :string, description: "Who asked")
      field(:id, :integer)
      field(:error, :boolean)
      field(:title, :string, description: "A property named title is kept")
    end
  end

  defmodule Outer do
    use Normandy.Schema

    io_schema "Nests Ordered" do
      field(:zeta, :string, description: "first")
      field(:inner, Ordered, description: "second")
      field(:many, {:array, Ordered}, description: "third")
    end
  end

  defmodule OrderedTool do
    use Normandy.Tool,
      name: "ordered_tool",
      description: "Takes ordered input",
      input: Normandy.Schema.WireTest.Ordered

    defstruct []

    @impl Normandy.Tool
    def run(_tool, _context), do: {:ok, "ok"}
  end

  @order ["value", "type", "name", "id", "error", "title"]

  defp decode(json), do: Jason.decode!(json, objects: :ordered_objects)
  defp keys(%Jason.OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  # Every node of a decoded schema, for whole-tree assertions.
  defp nodes(%Jason.OrderedObject{values: values} = node),
    do: [node | Enum.flat_map(values, fn {_k, v} -> nodes(v) end)]

  defp nodes(list) when is_list(list), do: Enum.flat_map(list, &nodes/1)
  defp nodes(_leaf), do: []

  test "properties are sent in declaration order" do
    encoded = Ordered.__schema__(:specification) |> Wire.encodable() |> Normandy.JSON.encode!()

    assert keys(decode(encoded)["properties"]) == @order
  end

  test "nested and array-item schemas keep their own order" do
    schema = Outer.__schema__(:specification) |> Wire.encodable() |> Normandy.JSON.encode!()
    decoded = decode(schema)

    assert keys(decoded["properties"]) == ["zeta", "inner", "many"]
    assert keys(decoded["properties"]["inner"]["properties"]) == @order
    assert keys(decoded["properties"]["many"]["items"]["properties"]) == @order
  end

  test "$schema, title and :property_order are not sent; a property named title is" do
    decoded =
      Ordered.__schema__(:specification)
      |> Wire.encodable()
      |> Normandy.JSON.encode!()
      |> decode()

    refute "$schema" in keys(decoded)
    refute "title" in keys(decoded)
    refute "property_order" in keys(decoded)
    assert decoded["properties"]["title"]["description"] == "A property named title is kept"
  end

  test "an undescribed field has no description, never \"\" or null (AX-11)" do
    decoded =
      Outer.__schema__(:specification) |> Wire.encodable() |> Normandy.JSON.encode!() |> decode()

    for %Jason.OrderedObject{} = node <- nodes(decoded), {"description", value} <- node.values do
      assert is_binary(value) and value != "", "empty description in #{inspect(node)}"
    end

    refute Map.has_key?(Ordered.__schema__(:specification).properties.type, :description)
  end

  test "a schema without :property_order passes through with its properties as a map" do
    hand_written = %{
      "type" => "object",
      "title" => "Lookup",
      "properties" => %{"query" => %{"type" => "string", "title" => "Query"}}
    }

    assert Wire.encodable(hand_written) == %{
             "type" => "object",
             "properties" => %{"query" => %{"type" => "string"}}
           }

    assert Wire.encodable(nil) == nil
  end

  test "a :property_order that does not name the properties raises, naming both" do
    spec = %{type: :object, properties: %{a: %{type: :string}}, property_order: [:a, :b]}

    assert_raise ArgumentError,
                 "expected :property_order to name each property exactly once, got " <>
                   "[:a, :b] for the properties [:a]",
                 fn -> Wire.encodable(spec) end
  end

  describe "every model-facing boundary sends declaration order" do
    test "tool input_schema (Toolset.to_tool_schemas/1)" do
      [%{input_schema: input_schema}] = Toolset.to_tool_schemas(Toolset.new([%OrderedTool{}]))

      assert keys(decode(Normandy.JSON.encode!(input_schema))["properties"]) == @order
    end

    test "the JSON retry feedback" do
      feedback =
        RetryFeedback.build(
          {:json_parse_error, :invalid, "oops"},
          "oops",
          %Ordered{},
          Normandy.JSON
        )

      [_, json] = Regex.run(~r/## Required Schema\n```json\n(.*)\n```/s, feedback)
      assert keys(decode(json)["properties"]) == @order
    end

    test "the structured-outputs schema (SchemaTranslator)" do
      {:ok, schema} = SchemaTranslator.translate(Ordered.__schema__(:specification))

      assert keys(decode(Jason.encode!(schema))["properties"]) == @order
      assert schema["required"] == ["value"]
    end
  end
end
```

`test/agents/base_agent_output_schema_prompt_test.exs` — the cross-path test (sync, `stream/3`,
`Turn.Server`). Replace the alias block with

```elixir
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.ScriptedTextClient
  alias Normandy.Test.StubClient
```

add before `defp system_prompt(output_schema) do`:

```elixir
  # Declared out of alphabetical and atom-table order (AX-17).
  defmodule Ordered do
    @moduledoc false
    use Normandy.Schema

    io_schema "An answer in declaration order" do
      field(:value, :string, description: "The answer", required: true)
      field(:type, :string)
      field(:name, :string, description: "Who asked")
      field(:id, :integer)
      field(:error, :boolean)
    end
  end

  defp schema_keys(prompt) do
    [_, json] = Regex.run(~r/# OUTPUT SCHEMA\n.*```json\n(.*)\n```/s, prompt)
    properties = Jason.decode!(json, objects: :ordered_objects)["properties"]
    Enum.map(properties.values, &elem(&1, 0))
  end
```

and append before the final `end`:

```elixir
  test "the OUTPUT SCHEMA block keeps declaration order and sends no $schema, title or empty description on every path" do
    order = ["value", "type", "name", "id", "error"]
    stub = %StubClient{notify: self(), reply: fn rm -> %{rm | value: "v"} end}
    agent = BaseAgent.init(%{client: stub, model: "m", output_schema: %Ordered{}})

    assert {:ok, _agent, %Ordered{value: "v"}} = BaseAgent.run(agent, "hi")
    assert_receive {:converse, %Normandy.LLM.Request{system: synced}, _}

    streaming = %ScriptedTextClient{text: ~s({"value":"v"}), notify: self()}

    assert {:ok, _agent, %Ordered{value: "v"}} =
             BaseAgent.stream(%{agent | client: streaming}, "hi", fn _ -> :ok end)

    assert_receive {:stream_request, %Normandy.LLM.Request{system: streamed}}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "wire-#{System.unique_integer([:positive])}",
        config: agent,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, %Ordered{value: "v"}} = Turn.Server.run(srv, "hi")
    assert_receive {:converse, %Normandy.LLM.Request{system: served}, _}

    for prompt <- [synced, streamed, served] do
      assert schema_keys(prompt) == order
      refute prompt =~ "$schema"
      refute prompt =~ ~s("title")
      refute prompt =~ ~s("description": "")
      refute prompt =~ "property_order"
    end
  end
```

(If Task 5.1 stops appending the schema on the structured path for this agent, the sync and
Server prompts still carry it today: R2 leaves AX-19 open. If a later change removes the block on
a path, this test is the one to adjust.)

`test/llm/json/schema_translator_test.exs` — in `"keeps the string formats structured outputs support, drops the others"` replace `assert props["blob"] == %{"type" => "string"}` with

```elixir
    # An unsupported format is stated, not sent (AX-18).
    assert props["blob"] == %{"type" => "string", "description" => "Format: binary."}
```

and append before the final `end`:

```elixir
  test "constraints constrained decoding cannot enforce are stated in the description (AX-18)" do
    spec = %{
      type: :object,
      properties: %{
        zip: %{
          type: :string,
          description: "Postal code",
          pattern: "^[0-9]{5}$",
          minLength: 5,
          maxLength: 5
        },
        qty: %{type: :integer, description: "How many.", minimum: 1, maximum: 100},
        price: %{type: :number, exclusiveMinimum: 0},
        tags: %{
          type: :array,
          items: %{type: :string},
          minItems: 1,
          maxItems: 3,
          uniqueItems: true
        },
        nick: %{type: :string, maxLength: 20}
      },
      required: []
    }

    assert {:ok, %{"properties" => props}} = SchemaTranslator.translate(spec)

    assert props["zip"] == %{
             "type" => "string",
             "description" =>
               "Postal code. Exactly 5 characters. Must match the regular expression ^[0-9]{5}$."
           }

    assert props["qty"]["description"] == "How many. Minimum 1. Maximum 100."
    assert props["price"]["description"] == "Greater than 0."
    assert props["tags"]["description"] == "Between 1 and 3 items. Items must be unique."
    assert props["nick"]["description"] == "At most 20 characters."
    refute Map.has_key?(props["zip"], "pattern")
  end

  defmodule Address do
    use Normandy.Schema

    io_schema "Address information" do
      field(:street, :string, description: "Street address", required: true)
      field(:city, :string, description: "City name", required: true)
      field(:state, :string, description: "State or province")
      field(:postal_code, :string, description: "Postal code", pattern: "^[0-9]{5}$")
    end
  end

  test "an io_schema's field order and constraints reach the constrained schema" do
    {:ok, schema} = SchemaTranslator.translate(Address.__schema__(:specification))

    assert Enum.map(schema["properties"], &elem(&1, 0)) == [
             "street",
             "city",
             "state",
             "postal_code"
           ]

    assert schema["properties"]["postal_code"]["description"] ==
             "Postal code. Must match the regular expression ^[0-9]{5}$."
  end
```

Existing tests that change (the whole-spec `==` assertions — `grep -rn "__schema__(:specification) ==" test` → 2 hits, both in `schema_test.exs`):

- `test/schema_test.exs`, tests `"specification"` and `"specification with description"`: in both expected maps the `properties` entries for `password`, `count`, `map`, `array` lose `description: ""` and a `property_order` key is added before `required`:
  ```elixir
             properties: %{
               name: %{
                 description: "name of the user",
                 type: :string,
                 default: "eric"
               },
               password: %{type: :string},
               count: %{type: :integer},
               map: %{
                 type: :object,
                 default: nil,
                 additionalProperties: %{type: :string}
               },
               array: %{
                 type: :array,
                 items: %{
                   type: :string
                 }
               }
             },
             property_order: [:name, :password, :count, :map, :array],
             required: [:name, :password]
  ```
- `test/schema_test.exs`, `"fields without constraints don't have constraint keys"`: the `count` assertion becomes
  ```elixir
      # AX-11: no description key at all, never "" or null.
      assert spec.properties.count == %{type: :integer}
  ```
- `test/schema_nested_test.exs`, `"JSON schema inlines nested schema specification"`: add `property_order: [:street, :city, :state, :postal_code],` before `required: [:street, :city]` in the expected `address` map.
- `test/tools/toolset_test.exs`, `"generates tool schemas for LLM"`: replace `assert Map.has_key?(schema.input_schema.properties, :operation)` with
  ```elixir
      # Declaration order, through Normandy.Schema.Wire (AX-17).
      assert %Jason.OrderedObject{} = schema.input_schema.properties
      assert %{type: :string} = schema.input_schema.properties[:operation]
      refute Map.has_key?(schema.input_schema, :property_order)
  ```
- `test/llm/structured_outputs_test.exs`, `"schema_for returns {:ok, schema} for a compatible struct"`: replace `assert "chat_message" in Map.keys(schema["properties"])` with
  ```elixir
    assert %Jason.OrderedObject{} = schema["properties"]
    assert Enum.map(schema["properties"], &elem(&1, 0)) == ["chat_message", "count"]
  ```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/schema/wire_test.exs test/agents/base_agent_output_schema_prompt_test.exs test/llm/json/schema_translator_test.exs test/schema_test.exs test/schema_nested_test.exs test/tools/toolset_test.exs test/llm/structured_outputs_test.exs`
Expected: FAIL — 19 failures stacked on 5.1–5.6b-ii: `wire_test.exs` compiles with an "undefined module" warning and its 9 tests fail (`UndefinedFunctionError` for `Normandy.Schema.Wire.encodable/1`, or the boundary tests on order); the other 10 (the 7 existing tests listed above, the prompt test and the 2 new translator tests) fail on order and descriptions. At HEAD the `Ordered` spec iterates as `[:error, :id, :name, :type, :value, :title]` and the translator emits `["error", "id", "name", "title", "type", "value"]` (probed with `mix run`), with `"description": ""` on every undescribed field.

- [ ] **Step 3: Implement `Normandy.Schema.Wire`**

Create `lib/normandy/schema/wire.ex`:

```elixir
defmodule Normandy.Schema.Wire do
  @moduledoc """
  A JSON Schema as the model sees it.

  `Normandy.Schema` keeps a field's declaration order in the specification under
  `:property_order` (a plain map, so `spec[:properties][name]` keeps working). Elixir maps
  do not keep key order, so a specification encoded as it is lists its properties in an
  order unrelated to the declaration. The model reads (and constrained decoding
  generates) properties in the order they are sent, so declaration order is generation
  order: declare `reasoning` before `answer` to have the model reason first.

  `encodable/1` returns the specification ready for `Normandy.JSON`:

    * every `properties` map that has a `:property_order` becomes a
      `Jason.OrderedObject` in that order; `:property_order` itself is removed;
    * `"$schema"` and `"title"` (atom or string keys) are removed from every schema node;
      a property *named* `title` is kept;
    * it recurses into `properties`, `items`, `additionalProperties`, `not`, `if`,
      `then`, `else`, `anyOf`, `oneOf`, `allOf` and `prefixItems`.

  A node without `:property_order` (a hand-written or MCP schema) keeps its `properties`
  as a map. Normandy calls it where a schema leaves for the model: tool `input_schema`
  (`Normandy.Tools.Toolset.to_tool_schemas/1`), the system prompt's `# OUTPUT SCHEMA`
  block and the JSON retry feedback. `__schema__(:specification)` and an io_schema's
  `get_json_schema/0` return the specification unchanged.

  A custom `config :normandy, :adapter` receives `Jason.OrderedObject` structs from these
  call sites; Jason encodes them in order.
  """

  @dropped [:"$schema", "$schema", :title, "title"]
  @schema_keys [:items, "items", :additionalProperties, "additionalProperties", :not, "not"] ++
                 [:if, "if", :then, "then", :else, "else"]
  @schema_list_keys [:anyOf, "anyOf", :oneOf, "oneOf", :allOf, "allOf"] ++
                      [:prefixItems, "prefixItems"]

  @doc "The schema with ordered properties and without `$schema` and `title`."
  @spec encodable(term()) :: term()
  def encodable(%{} = schema) when not is_struct(schema) do
    {order, schema} = Map.pop(schema, :property_order)

    schema
    |> Map.drop(@dropped)
    |> Map.new(fn {key, value} -> {key, child(key, value, order)} end)
  end

  def encodable(other), do: other

  @doc false
  # The `properties` entries in `order`, which must name each property exactly once.
  @spec ordered_entries!(map(), [atom() | String.t()]) :: [{atom() | String.t(), term()}]
  def ordered_entries!(properties, order) when is_map(properties) and is_list(order) do
    if Enum.sort(order) != Enum.sort(Map.keys(properties)) do
      raise ArgumentError,
            "expected :property_order to name each property exactly once, got " <>
              "#{inspect(order)} for the properties #{inspect(Enum.sort(Map.keys(properties)))}"
    end

    Enum.map(order, &{&1, Map.fetch!(properties, &1)})
  end

  defp child(key, %{} = properties, order)
       when key in [:properties, "properties"] and not is_struct(properties) do
    walked = Map.new(properties, fn {name, schema} -> {name, encodable(schema)} end)

    case order do
      nil -> walked
      order -> walked |> ordered_entries!(order) |> Jason.OrderedObject.new()
    end
  end

  defp child(key, schema, _order) when key in @schema_keys, do: encodable(schema)

  defp child(key, schemas, _order) when key in @schema_list_keys and is_list(schemas),
    do: Enum.map(schemas, &encodable/1)

  defp child(_key, value, _order), do: value
end
```

`mix.exs`, `docs` → `groups_for_modules` → `Core`: add `Normandy.Schema.Wire,` after `Normandy.Schema,`.

- [ ] **Step 4: Implement the spec changes and the boundaries**

`lib/normandy/schema.ex`, `__schema__/1`:

```elixir
    specification =
      if is_binary(description) and description != "" do
        Map.put(specification, :description, description)
      else
        specification
      end
```

(replacing `if description != nil do`), and

```elixir
    # :property_order keeps the declaration order a map loses; Normandy.Schema.Wire
    # sends the properties in it (declaration order is generation order, AX-17).
    specification =
      specification
      |> Map.put(:properties, Map.new(properties))
      |> Map.put(:property_order, Enum.map(properties, &elem(&1, 0)))
      |> set_required(required_fields)
```

(`properties` is the comprehension's list, already in declaration order and without the
virtual fields left out of the JSON Schema.) `get_base_type_spec/2` becomes:

```elixir
  # Get base JSON Schema type specification. A field declared without a description has
  # no :description key (AX-11): never "" or null in what the model reads.
  defp get_base_type_spec(type, description) when is_binary(description) and description != "",
    do: Map.put(json_type(type), :description, description)

  defp get_base_type_spec(type, _description), do: json_type(type)
```

`inline_nested_schema/1`: `Map.take(spec, [:type, :properties, :required, :description])` →
`Map.take(spec, [:type, :properties, :property_order, :required, :description])`.

`lib/normandy/tools/toolset.ex`: add `alias Normandy.Schema.Wire` after
`alias Normandy.Schema.Introspection`; in `to_tool_schemas/1`
`input_schema: Tool.input_schema(tool)` → `input_schema: Wire.encodable(Tool.input_schema(tool))`.
(The same line also appears in `build_tool_metadata/1`, so anchor on `to_tool_schemas/1`'s body;
`build_tool_metadata/1` and `introspect_schema/2` keep the raw schema.)

`lib/normandy/agents/base_agent.ex`: add `alias Normandy.Schema.Wire` after
`alias Normandy.Behaviours.Compactor.WindowManager, as: WindowCompactor`; in `with_output_schema/2`
`schema_json = Normandy.JSON.encode!(schema, pretty: true)` →
`schema_json = Normandy.JSON.encode!(Wire.encodable(schema), pretty: true)`.

`lib/normandy/llm/json/retry_feedback.ex`: add `alias Normandy.Schema.Wire` after
`alias Normandy.Components.Message`; both `adapter.encode!(Normandy.Schema.json_schema(schema), pretty: true)`
(the validation-error clause and `parse_feedback/6` from 5.6a; `grep -c` → 2) become
`adapter.encode!(Wire.encodable(Normandy.Schema.json_schema(schema)), pretty: true)`.

`lib/normandy/llm/json/schema_translator.ex`:
- add `alias Normandy.Schema.Wire` above `@max_depth 8`, and move the `@formats` attribute (with its comment, reworded) from above `with_format/2` to just below `@max_depth 8`:
  ```elixir
  # The string formats constrained decoding supports; any other format is left
  # out of the schema and stated in the description (format_note/1).
  @formats ~w(date-time time date duration email hostname uri ipv4 ipv6 uuid)
  ```
- in the `%{type: :object}` node:
  ```elixir
    translated =
      props
      |> property_entries(Map.get(spec, :property_order))
      |> Enum.map(fn {k, v} -> {to_string(k), node(v, depth + 1)} end)
      |> properties(Map.get(spec, :property_order))
  ```
- replace `with_description/2` with the following (after the last `node/2` clause, so the `node/2` clauses stay grouped):
  ```elixir
  # Declaration order (Normandy.Schema's :property_order) is generation order under
  # constrained decoding (AX-17); a spec without it keeps a map.
  defp property_entries(props, nil), do: Map.to_list(props)
  defp property_entries(props, order), do: Wire.ordered_entries!(props, order)

  defp properties(entries, nil), do: Map.new(entries)
  defp properties(entries, _order), do: Jason.OrderedObject.new(entries)

  # The description, then each constraint constrained decoding cannot enforce, stated in
  # words (AX-18): the model still sees them, and Normandy validates them afterwards.
  defp with_description(map, spec) do
    description = Map.get(spec, :description)

    text =
      case Enum.reject(constraint_notes(spec), &is_nil/1) do
        [] -> if is_binary(description), do: description, else: ""
        notes -> Enum.join(Enum.reject([sentence(description) | notes], &is_nil/1), " ")
      end

    if text == "", do: map, else: Map.put(map, "description", text)
  end

  defp constraint_notes(spec) do
    [
      range_note(spec[:minLength], spec[:maxLength], "characters"),
      pattern_note(spec[:pattern]),
      format_note(spec[:format]),
      bound_note("Minimum", spec[:minimum]),
      bound_note("Maximum", spec[:maximum]),
      bound_note("Greater than", spec[:exclusiveMinimum]),
      bound_note("Less than", spec[:exclusiveMaximum]),
      range_note(spec[:minItems], spec[:maxItems], "items"),
      if(spec[:uniqueItems] == true, do: "Items must be unique.")
    ]
  end

  # A description followed by notes ends its own sentence.
  defp sentence(text) when is_binary(text) and text != "" do
    text = String.trim_trailing(text)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp sentence(_text), do: nil

  defp range_note(nil, nil, _unit), do: nil
  defp range_note(same, same, unit), do: "Exactly #{same} #{unit}."
  defp range_note(min, nil, unit), do: "At least #{min} #{unit}."
  defp range_note(nil, max, unit), do: "At most #{max} #{unit}."
  defp range_note(min, max, unit), do: "Between #{min} and #{max} #{unit}."

  defp pattern_note(nil), do: nil
  defp pattern_note(%Regex{} = regex), do: pattern_note(Regex.source(regex))

  defp pattern_note(pattern) when is_binary(pattern),
    do: "Must match the regular expression #{pattern}."

  # A format with_format/2 sends is enforced; any other is stated.
  defp format_note(nil), do: nil

  defp format_note(format) do
    format = if is_atom(format), do: Atom.to_string(format), else: format
    if format in @formats, do: nil, else: "Format: #{format}."
  end

  defp bound_note(_label, nil), do: nil
  defp bound_note(label, value), do: "#{label} #{value}."
  ```
- moduledoc: append the paragraph
  ```
  Properties keep the declaration order recorded in `:property_order` (constrained
  decoding generates them in that order), as a `Jason.OrderedObject`. Constraints it
  cannot send (`pattern`, string lengths, numeric bounds, item counts, `uniqueItems`,
  unsupported formats) are stated at the end of the property's `description`; the
  answer is still validated against the full schema.
  ```

(The constraint keys are the camelCase ones `Normandy.Schema.add_constraints/3` writes:
`minLength`, `maxLength`, `pattern`, `format`, `minimum`, `maximum`, `exclusiveMinimum`,
`exclusiveMaximum`, `minItems`, `maxItems`, `uniqueItems`.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/schema/wire_test.exs test/agents/base_agent_output_schema_prompt_test.exs test/llm/json/schema_translator_test.exs test/schema_test.exs test/schema_nested_test.exs test/tools/toolset_test.exs test/llm/structured_outputs_test.exs`, then `mix test`.
Expected: PASS; full suite ` 0 failures`. (Prototype: exactly the 7 listed existing tests failed before their edits; nothing else read the spec as a whole map.)

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 36.`:

```markdown
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
```

Under `## New, non-breaking`:

```markdown
- `Normandy.Schema.Wire.encodable/1` turns a schema specification into what Normandy sends
  the model: properties in declaration order, no `"$schema"` or `"title"`.
```

- [ ] **Step 7: Gate and commit**

Run: `mix format && mix precommit 2>&1 | tee /tmp/w5-5.6c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.6c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. (Docs: the Wire moduledoc must not name the hidden `Normandy.Schema.json_schema/1`; ExDoc warns "documentation references function ... but it is hidden" — the text above avoids it.)

```bash
git add lib/normandy/schema/wire.ex lib/normandy/schema.ex lib/normandy/tools/toolset.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/llm/json/retry_feedback.ex \
  lib/normandy/llm/json/schema_translator.ex mix.exs MIGRATING-2.0.md \
  test/schema/wire_test.exs test/agents/base_agent_output_schema_prompt_test.exs \
  test/llm/json/schema_translator_test.exs test/schema_test.exs test/schema_nested_test.exs \
  test/tools/toolset_test.exs test/llm/structured_outputs_test.exs
git commit -m "fix(schema): declaration order on the wire, no empty descriptions, stated constraints"
```

---

---

### Task 5.7a: MCP and A2A tool names take a required prefix (SEC-2, SEC-10 docs)

**Files:**
- Modify: `lib/normandy/mcp/tool_wrapper.ex` (moduledoc, `@enforce_keys`, `:prefix` schema, `validate_prefix/1`, `new/4`, `name/1`)
- Modify: `lib/normandy/a2a/agent_tool.ex` (moduledoc, struct, `:prefix` schema, `new/3`, `name/1`)
- Modify: `lib/normandy/mcp/registry.ex`, `lib/normandy/a2a/registry.ex` (moduledoc examples)
- Modify: `lib/normandy/behaviours/policy_engine.ex` (`Ruleset` moduledoc)
- Modify: `e2e/12_mcp_a2a.exs` (one call)
- Modify (mechanical, see Step 5): `test/mcp/tool_wrapper_test.exs`, `test/mcp/registry_test.exs`, `test/a2a/server_test.exs`, `test/telemetry/tool_telemetry_test.exs`, `test/tools/toolset_test.exs`, `test/a2a/agent_tool_test.exs`, `test/a2a/registry_test.exs`, `test/options/integration_options_test.exs`, `test/telemetry/a2a_propagation_test.exs`
- Modify: `MIGRATING-2.0.md` (new `## 37. Security hardening`)
- Test: create `test/mcp/tool_name_prefix_test.exs`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`; `Normandy.Components.ContentBlock.Describe.type_of/1`; `PolicyEngine.Ruleset.check/2`; `Toolset.list_names/1`. Task 5.6 (AX-14, AX-30) has already rewritten `ToolWrapper.run/2`'s success path and `AgentTool.description/1`/`input_schema/1`; this task touches neither (only `name/1`, the struct, the options and the moduledocs).
- Produces: `ToolWrapper` `:prefix` (required; `String.t()` matching `~r/\A[a-zA-Z0-9-]+(?:_[a-zA-Z0-9-]+)*\z/`, ≤ 61 bytes, or `false`); `ToolWrapper.validate_prefix/1` (`@doc false`, the NimbleOptions custom type, also used by `AgentTool`); `AgentTool` `:prefix` (same rule) and struct field `prefix`; `## 37.` in MIGRATING-2.0.md, which Tasks 5.7b-5.7d append to.

- [ ] **Step 1: Write the failing test**

Create `test/mcp/tool_name_prefix_test.exs`:

```elixir
defmodule Normandy.MCP.ToolNamePrefixTest do
  # SEC-2: a remote server or agent chooses its tool names, so every entry point that
  # wraps remote tools takes a required :prefix the host chooses.
  use ExUnit.Case, async: true

  alias Claudio.A2A.AgentCard
  alias Normandy.A2A.AgentTool
  alias Normandy.A2A.Registry, as: A2ARegistry
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Components.ToolCall
  alias Normandy.MCP.Registry, as: MCPRegistry
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tool
  alias Normandy.Tools.Toolset

  defmodule PurgeServer do
    @moduledoc false
    def list_tools(_client, _opts),
      do: {:ok, [%Claudio.MCP.Client.Tool{name: "read_and_purge", input_schema: %{}}]}
  end

  @tool %Claudio.MCP.Client.Tool{name: "read_and_purge", input_schema: %{}}

  describe ":prefix is required" do
    test "on every MCP entry point, named in the error" do
      calls = [
        {"Normandy.MCP.ToolWrapper.new/4", fn -> ToolWrapper.new(PurgeServer, nil, @tool) end},
        {"Normandy.MCP.Registry.discover_and_register/4",
         fn -> MCPRegistry.discover_and_register(Toolset.new(), PurgeServer, nil) end},
        {"Normandy.MCP.Registry.wrap_tools/4",
         fn -> MCPRegistry.wrap_tools(PurgeServer, nil, [@tool]) end},
        {"Normandy.Agents.BaseAgent.register_mcp_tools/4",
         fn -> BaseAgent.register_mcp_tools(%BaseAgentConfig{}, PurgeServer, nil) end}
      ]

      for {mfa, call} <- calls do
        error = assert_raise ArgumentError, call

        assert error.message ==
                 "#{mfa}: required :prefix option not found, received options: []"
      end
    end

    test "on every A2A entry point, named in the error" do
      card = AgentCard.new("Agent", "An agent")

      calls = [
        {"Normandy.A2A.AgentTool.new/3", fn -> AgentTool.new("http://a", card) end},
        {"Normandy.A2A.Registry.from_agent_card/3",
         fn -> A2ARegistry.from_agent_card(card, "http://a") end},
        {"Normandy.A2A.Registry.discover_and_register/3",
         fn -> A2ARegistry.discover_and_register(Toolset.new(), "http://a") end}
      ]

      for {mfa, call} <- calls do
        error = assert_raise ArgumentError, call
        assert error.message =~ "#{mfa}: required :prefix option not found"
      end
    end

    test "a ToolWrapper struct literal without :prefix does not compile" do
      assert_raise ArgumentError, ~r/must also be given.*:prefix/, fn ->
        Code.eval_string("%Normandy.MCP.ToolWrapper{adapter: nil, client: nil, tool: nil}")
      end
    end
  end

  describe "the prefix rule" do
    test "a prefix whose __ would be ambiguous is refused" do
      for bad <- ["a_", "_a", "a__b", "", "a.b", String.duplicate("a", 62)] do
        error =
          assert_raise ArgumentError, fn ->
            ToolWrapper.new(PurgeServer, nil, @tool, prefix: bad)
          end

        assert error.message =~
                 "Normandy.MCP.ToolWrapper.new/4: invalid value for :prefix option: expected " <>
                   "false or a prefix of letters, digits, - and single _ (no __, no _ at " <>
                   "either end), at most 61 bytes"
      end
    end

    test "letters, digits, - and single _ are accepted, up to 61 bytes" do
      for good <- ["srv", "my_server", "a-b_c9", String.duplicate("a", 61)] do
        assert Tool.name(ToolWrapper.new(PurgeServer, nil, @tool, prefix: good)) ==
                 good <> "__read_and_purge"
      end
    end

    test "prefix: false keeps the server's name" do
      assert Tool.name(ToolWrapper.new(PurgeServer, nil, @tool, prefix: false)) ==
               "read_and_purge"
    end

    test "true and nil are not prefixes" do
      for bad <- [true, nil] do
        assert_raise ArgumentError, ~r/invalid value for :prefix option/, fn ->
          ToolWrapper.new(PurgeServer, nil, @tool, prefix: bad)
        end
      end
    end

    test "A2A tools take the same rule; \"a2a\" gives 1.x's names" do
      card = AgentCard.new("Research Agent", "r") |> AgentCard.add_skill("web search", "s")

      assert_raise ArgumentError, ~r/AgentTool.new\/3: invalid value for :prefix option/, fn ->
        AgentTool.new("http://a", card, prefix: "a_")
      end

      assert Tool.name(AgentTool.new("http://a", card, prefix: "a2a")) == "a2a__research_agent"

      assert Tool.name(AgentTool.new("http://a", card, prefix: "res", skill_id: "web search")) ==
               "res__research_agent__web_search"

      assert Tool.name(AgentTool.new("http://a", card, prefix: false)) == "research_agent"
    end
  end

  describe "a server-chosen name no longer matches the host's rule (SEC-2)" do
    @policy [
      rules: [%{match: "read_*", action: :allow}],
      default_action: :require_approval
    ]

    test "read_and_purge from server srv needs approval" do
      {:ok, toolset} =
        MCPRegistry.discover_and_register(Toolset.new(), PurgeServer, nil, prefix: "srv")

      assert Toolset.list_names(toolset) == ["srv__read_and_purge"]

      call = %ToolCall{id: "c1", name: "srv__read_and_purge", input: %{}}
      assert {:needs_approval, _meta} = Ruleset.check(call, %{opts: @policy})
    end

    test "a rule on the prefix matches exactly that server's tools" do
      opts = [rules: [%{match: "srv__*", action: :deny}], default_action: :allow]

      assert {:deny, _} = Ruleset.check(%ToolCall{name: "srv__read_and_purge"}, %{opts: opts})
      assert {:allow, _} = Ruleset.check(%ToolCall{name: "srv2__read_and_purge"}, %{opts: opts})
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix format && mix test test/mcp/tool_name_prefix_test.exs`
Expected: FAIL, 6 of 10 tests (verified at `0dccd48`): the two "required" tests (no raise),
the struct-literal test (it compiles), the ambiguous-prefix test (`"a_"` is accepted),
`prefix: false` (`:prefix` is `type: :string`) and the A2A test (no `:prefix` option). The
two policy tests and "letters, digits..." pass already: they pin the behaviour this task
makes mandatory.

- [ ] **Step 3: `ToolWrapper`**

In `lib/normandy/mcp/tool_wrapper.ex`:

(a) In the moduledoc, replace the example's struct literal and the comment after it:

```elixir
      wrapper = %ToolWrapper{
        adapter: Claudio.MCP.Adapters.ExMCP,
        client: mcp_client_pid,
        tool: mcp_tool,
        prefix: "my_server"
      }

      # Register in agent
      agent = BaseAgent.register_tool(agent, wrapper)
```

with

```elixir
      wrapper = ToolWrapper.new(Claudio.MCP.Adapters.ExMCP, mcp_client_pid, mcp_tool, prefix: "web")

      # The model sees the tool as "web__search".
      agent = BaseAgent.register_tool(agent, wrapper)
```

and insert these two sections right before `  ## Trace context`:

```
  ## Tool names and policy rules

  The server chooses its tools' names, so a name says nothing about what a tool does. A
  `Normandy.Behaviours.PolicyEngine.Ruleset` rule matches the name only: a server that
  names a destructive tool `read_and_purge` matches the rule `"read_*"`. That is why
  `:prefix` is required. The model sees `prefix <> "__" <> name`, so the rule `"web__*"`
  matches exactly the tools of the server you gave the prefix `"web"` (and any local tool
  you chose to name `web__...`).

  A prefix is letters, digits, `-` and single `_` (no `__`, no `_` at either end), at
  most 61 bytes, so the first `__` in a name always ends the prefix. The whole name must
  still be a valid tool name (`^[a-zA-Z0-9_-]{1,64}$`): with a prefix, a server's tool
  name can be at most `62 - byte_size(prefix)` bytes, and a server with a longer or
  dotted name fails registration (`{:error, {:invalid_tool_name, name}}`).

  `prefix: false` keeps the server's own names. Use it only for a server you control, and
  write no name-glob rule such a server could match.

  ## Trust

  An MCP server is outside your trust boundary. Its tool descriptions and input schemas
  are sent to the model on every request, and its results become the model's input: each
  is a prompt-injection channel that Normandy passes through unchanged. Connect servers
  you trust as much as your own tools' code, and gate tools that change state with a
  policy (`:require_approval`) rather than trusting a server's names or descriptions.

```

(b) Add `alias Normandy.Components.ContentBlock.Describe` above `alias Normandy.Options`.

(c) Replace the type's `prefix: String.t() | nil` with `prefix: String.t() | false`, and replace

```elixir
  defstruct [:adapter, :client, :tool, :prefix]

  @new_opts_schema NimbleOptions.new!(
                     prefix: [
                       type: :string,
                       doc: "Namespaces the tool's name as `prefix__name`."
                     ]
                   )
```

with

```elixir
  @enforce_keys [:adapter, :client, :tool, :prefix]
  defstruct [:adapter, :client, :tool, :prefix]

  @prefix_format ~r/\A[a-zA-Z0-9-]+(?:_[a-zA-Z0-9-]+)*\z/
  @max_prefix_bytes 61

  @new_opts_schema NimbleOptions.new!(
                     prefix: [
                       type: {:custom, __MODULE__, :validate_prefix, []},
                       type_doc: "`t:String.t/0` or `false`",
                       required: true,
                       doc:
                         "The server's namespace: the model sees each tool as `prefix__name`. " <>
                           "Letters, digits, `-` and single `_` (no `__`, no `_` at either " <>
                           "end), at most 61 bytes. `false` keeps the server's own names " <>
                           "(see \"Tool names and policy rules\")."
                     ]
                   )
```

(d) After `def __opts_schema__(:new), do: @new_opts_schema`, add:

```elixir

  @doc false
  # The NimbleOptions custom type of :prefix, here and on Normandy.A2A.AgentTool.
  @spec validate_prefix(term()) :: {:ok, String.t() | false} | {:error, String.t()}
  def validate_prefix(false), do: {:ok, false}

  def validate_prefix(prefix) when is_binary(prefix) do
    if byte_size(prefix) <= @max_prefix_bytes and Regex.match?(@prefix_format, prefix),
      do: {:ok, prefix},
      else: {:error, prefix_rule() <> ", got: #{inspect(prefix)}"}
  end

  def validate_prefix(other), do: {:error, prefix_rule() <> ", got: " <> Describe.type_of(other)}

  defp prefix_rule do
    "expected false or a prefix of letters, digits, - and single _ (no __, no _ at either " <>
      "end), at most #{@max_prefix_bytes} bytes"
  end
```

(e) In `new/4`, `prefix: Keyword.get(opts, :prefix)` becomes `prefix: Keyword.fetch!(opts, :prefix)`.
Keep the `opts \\ []` default: a 3-argument call then raises the "required :prefix" message
instead of `UndefinedFunctionError`.

(f) Replace the two `name/1` clauses with:

```elixir
  def name(%__MODULE__{tool: tool, prefix: false}), do: tool.name

  def name(%__MODULE__{tool: tool, prefix: prefix}) when is_binary(prefix),
    do: prefix <> "__" <> tool.name
```

- [ ] **Step 4: `AgentTool`, the registries' docs, `Ruleset` docs, e2e**

In `lib/normandy/a2a/agent_tool.ex`:

(a) Moduledoc: replace

```elixir
      tool = AgentTool.new("https://agent.example.com/a2a", card, auth_token: "bearer-token")

      agent = BaseAgent.register_tool(agent, tool, timeout: 60_000)
```

with

```elixir
      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          prefix: "research",
          auth_token: "bearer-token"
        )

      # The model sees the tool as "research__<the card's name>".
      agent = BaseAgent.register_tool(agent, tool, timeout: 60_000)
```

and append after the paragraph ending `remote agent that works for minutes a longer one.`:

```

  ## Tool names

  The tool's name is `prefix <> "__" <> card name` (plus `"__" <> skill id` for a skill),
  the card name and skill id lowercased with every run of other characters turned into one
  `_`. The remote agent chooses its card, so `:prefix` is required, with the same rule as
  `Normandy.MCP.ToolWrapper`'s (see "Tool names and policy rules" there): a policy rule
  such as `"research__*"` then matches exactly this remote's tools. `prefix: "a2a"` gives
  the names Normandy 1.x used; `prefix: false` gives the bare card name.

  ## Trust

  A remote agent is outside your trust boundary. Its card's name, description and skill
  descriptions are sent to the model as this tool's name and description, and its replies
  become the model's input: each is a prompt-injection channel that Normandy passes through
  unchanged. Register remotes you trust, and gate this tool with a policy when its replies
  can lead the model to act.
```

(b) Type: add `prefix: String.t() | false,` after `agent_card: ...`. Struct: add
`@enforce_keys [:endpoint, :agent_card, :prefix]` between `@derive {Inspect, except: [:auth_token]}`
and `defstruct`, and `:prefix,` after `:agent_card,` in the `defstruct` list.

(c) First entry of `@new_opts_schema`:

```elixir
                     prefix: [
                       type: {:custom, Normandy.MCP.ToolWrapper, :validate_prefix, []},
                       type_doc: "`t:String.t/0` or `false`",
                       required: true,
                       doc:
                         "The remote's namespace: the tool is named `prefix__card_name`. " <>
                           "The rule of `Normandy.MCP.ToolWrapper.new/4`'s `:prefix`; " <>
                           "`\"a2a\"` gives 1.x's names, `false` the bare card name."
                     ],
```

(d) In `new/3`'s struct, add `prefix: Keyword.fetch!(opts, :prefix),` after `agent_card: agent_card,`.

(e) Replace both `name/1` clauses with:

```elixir
  def name(%__MODULE__{prefix: prefix} = tool), do: prefixed(prefix, base_name(tool))

  defp base_name(%__MODULE__{agent_card: card, skill_id: nil}), do: sanitize_name(card.name)

  defp base_name(%__MODULE__{agent_card: card, skill_id: skill_id}),
    do: "#{sanitize_name(card.name)}__#{sanitize_name(skill_id)}"

  defp prefixed(false, name), do: name
  defp prefixed(prefix, name) when is_binary(prefix), do: prefix <> "__" <> name
```

`A2A.Registry`'s schemas are built from `AgentTool.__opts_schema__(:new)`, so
`from_agent_card/3` and `discover_and_register/3` now require `:prefix` with no code change.

In `lib/normandy/mcp/registry.ex`, end the moduledoc (after the example's closing `)`) with:

```

  `:prefix` is required (`false` keeps the server's names): see
  `Normandy.MCP.ToolWrapper`'s "Tool names and policy rules" and "Trust". Every
  description, input schema and result the server sends reaches the model unchanged.
```

In `lib/normandy/a2a/registry.ex`, the moduledoc example gets `prefix: "research",` before
`auth_token: "bearer-token"`, and after the example's closing `)` add:

```

  `:prefix` is required: see `Normandy.A2A.AgentTool`'s "Tool names" and "Trust".
```

In `lib/normandy/behaviours/policy_engine.ex`, `Ruleset`'s moduledoc, insert before the
paragraph that starts `A malformed ruleset raises`:

```
    A rule sees the tool's name only. An MCP server or a remote A2A agent chooses its own
    tools' names, so match those on the prefix you gave them (`"srv__*"`, see
    `Normandy.MCP.ToolWrapper`'s "Tool names and policy rules"), never on a name such as
    `"read_*"` that a server can choose to match.

```

In `e2e/12_mcp_a2a.exs`, `Normandy.A2A.AgentTool.new(base <> "/a2a", card, transport_opts: ...)`
becomes `Normandy.A2A.AgentTool.new(base <> "/a2a", card, prefix: "harbour", transport_opts: ...)`
(its MCP call already passes `prefix: "city"`).

- [ ] **Step 5: Existing call sites (mechanical)**

Rule 1 (MCP): every call in `test/` that builds MCP tools without `:prefix` gets
`prefix: false` as its last option, which keeps every name those tests assert.

`grep -rn "ToolWrapper.new(\|MCPRegistry.discover_and_register(\|MCPRegistry.wrap_tools(" test | grep -v prefix`
gives 20 hits before the change, stacked on Tasks 5.1-5.6 (1 after: the multi-line call in
`two_tool_registry/0`, whose `prefix: false` lands on a later line once `mix format` has run):
`test/mcp/tool_wrapper_test.exs` 7 (the setup's `ToolWrapper.new(MockAdapter, :mock_client, tool)`,
the calls in "tool_description falls back for nil", "run returns error on failure", "a tool with
no input schema ...", "generates tool schemas", and the two `ToolWrapper.new(MockAdapter,
{:returns, result}, tool)` calls Task 5.6b-ii added), `test/mcp/registry_test.exs` 10,
`test/a2a/server_test.exs` 2 (one is the multi-line call in `two_tool_registry/0`: the option
goes after the `%Claudio.MCP.Client.Tool{}` argument), `test/telemetry/tool_telemetry_test.exs` 1. Two assertions in
`test/mcp/tool_wrapper_test.exs` change too:
- "creates wrapper with defaults": `assert wrapper.prefix == nil` becomes `assert wrapper.prefix == false`;
- the test named `"tool_name without prefix"` is renamed `"tool_name with prefix: false"` (body unchanged).

Struct literals: `test/tools/toolset_test.exs` has 3 `%Normandy.MCP.ToolWrapper{tool: ...}`
(`grep -rn "%Normandy.MCP.ToolWrapper{tool:" test` = 3) that no longer compile. Each becomes
`%Normandy.MCP.ToolWrapper{adapter: nil, client: nil, tool: <same>, prefix: false}`.

Rule 2 (A2A): every A2A call in `test/` that must succeed gets `prefix: "a2a"`, which keeps the
`a2a__...` names those tests assert:
- `test/a2a/agent_tool_test.exs`: all 9 `AgentTool.new(` calls, stacked (setup, the
  `skill_id`/`auth_token` test, the `:timeout` test: `prefix: "a2a", timeout: 30_000`, the two
  `skill_id: "web_search"` calls, `skill_id: "unknown"`, the no-skill description test Task 5.6a
  added, and the two `auth_token` tests at the end);
- `test/a2a/registry_test.exs`: `prefix: "a2a",` before `transport_opts: [transport: LongNameTransport]`;
  `opts = [prefix: "a2a", transport_opts: [transport: OkTransport]]`; the four
  `A2ARegistry.from_agent_card(card, "https://example.com/a2a"...)` calls;
- `test/options/integration_options_test.exs`: `AgentTool.new("http://a", nil, %{skill_id: "s"})`
  becomes `AgentTool.new("http://a", nil, %{prefix: "a2a", skill_id: "s"})`;
- `test/telemetry/a2a_propagation_test.exs`, `agent_tool/2`: the third argument `opts` becomes
  `[prefix: "a2a"] ++ opts`.

Left as they are (verified passing): `test/options_coverage_test.exs:277`,
`test/options/integration_options_test.exs:56, 66, 75, 87, 195` and the `@cases` table. They
assert a different error (the `:timeout` message is raised before validation; an invalid
`:auth_token`/`:transport_opts`/`:timeout` value and an unknown option are reported before a
missing required one).

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/mcp test/a2a test/tools/toolset_test.exs test/telemetry test/options`
Expected: PASS.

- [ ] **Step 7: MIGRATING**

In `MIGRATING-2.0.md`, after `## 36.` (Task 5.6) and before `## New, non-breaking`, add:

````markdown
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
````

- [ ] **Step 8: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.7a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.7a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/mcp/tool_wrapper.ex lib/normandy/a2a/agent_tool.ex \
  lib/normandy/mcp/registry.ex lib/normandy/a2a/registry.ex \
  lib/normandy/behaviours/policy_engine.ex e2e/12_mcp_a2a.exs MIGRATING-2.0.md \
  test/mcp/tool_name_prefix_test.exs test/mcp/tool_wrapper_test.exs test/mcp/registry_test.exs \
  test/a2a/server_test.exs test/telemetry/tool_telemetry_test.exs test/tools/toolset_test.exs \
  test/a2a/agent_tool_test.exs test/a2a/registry_test.exs \
  test/options/integration_options_test.exs test/telemetry/a2a_propagation_test.exs
git commit -m "feat(mcp)!: MCP and A2A tools take a required name prefix"
```

### Task 5.7b: Guard crashes, mount namespaces, A2A request limits (SEC-4, SEC-7, SEC-9)

Three independent fixes in one task (about 600 diff lines with tests). Split into commits
per finding if a reviewer prefers; the steps are ordered so each finding's tests pass on
their own.

**Files:**
- Modify: `lib/normandy/components/content_block/describe.ex` (new `reason_tag/1`)
- Create: `lib/normandy/guardrails/guard_error.ex`
- Modify: `lib/normandy/guardrails.ex` (moduledoc "Error handling", `invoke/4`, `on_error_result/3`, new `describe_crash/1`)
- Modify: `lib/normandy/guardrails/builtins/semantic_scope.ex` (moduledoc, `check/3`, `classify/4`, new `call_host/4`)
- Modify: `lib/normandy/tools/memory.ex` (moduledoc, `namespace!/2`, new `not_a_mount!/2`, `validate_mounts!/1`, new `same_access!/1`)
- Modify: `lib/normandy/a2a/server.ex` (moduledoc, `handle_message/2,3`, new `handle_message/4`, `request_span/3`, new `run_text/3`, `too_large?/2`)
- Modify: `lib/normandy/telemetry.ex` (`[:normandy, :a2a, :request]` entry)
- Modify: `MIGRATING-2.0.md` (`## 37.`)
- Test: create `test/guardrails/guard_crash_test.exs`, `test/tools/memory_mount_namespace_test.exs`, `test/a2a/server_limits_test.exs`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `Normandy.Options.plain_map/1`; `Normandy.Test.{StubClient, ScriptedToolClient, ContextProbe, TelemetryCapture}`; `## 37.` from Task 5.7a. Task 5.4b has added `max_namespace_documents` to `Memory.new/1` and rewritten the moduledoc's cap paragraphs, and Task 5.6 has rewritten `Memory.description/1`; this task edits neither, and anchors on `namespace!/2`, `validate_mounts!/1` and the moduledoc's last paragraph (`... Never store secrets in memory.`).
- Produces: `Normandy.Guardrails.GuardError` (public exception, fields `kind :: :error | :exit | :throw`, `reason`; message names the exception module or exit tag only); `Describe.reason_tag/1` (`@moduledoc false` module; Task 5.7d reuses it); `A2A.Server.handle_message/4` with `:max_text_bytes` (default `100_000`, `nil` off, over → `{:error, :too_large}`) and `:tool_context` (plain map, replaces `config.tool_context` for the call); new `error_type: :too_large` on `[:normandy, :a2a, :request, :stop]`.

- [ ] **Step 1: Write the failing tests**

Create `test/guardrails/guard_crash_test.exs`:

```elixir
defmodule Normandy.Guardrails.GuardCrashTest do
  # SEC-4: :on_error covers exits and throws, and a SemanticScope classifier's own
  # KeyError or ArgumentError is host code, not the builtin's configuration.
  use ExUnit.Case, async: true

  alias Normandy.Guardrails
  alias Normandy.Guardrails.Builtins.SemanticScope
  alias Normandy.Guardrails.GuardError

  defmodule ExitsGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: exit({:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}})
  end

  defmodule ThrowsGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: throw({:nope, "SECRET-THROWN"})
  end

  @scope SemanticScope

  defp classifiers do
    %{
      exit: fn _v, _c -> exit({:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}}) end,
      key_error: fn _v, _c -> Map.fetch!(Function.identity(%{token: "SECRET-MAP"}), :missing) end,
      argument_error: fn _v, _c -> raise ArgumentError, "SECRET-MESSAGE" end,
      throw: fn _v, _c -> throw("SECRET-THROWN") end
    }
  end

  @expected %{
    exit: "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code exited: :timeout",
    key_error:
      "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code raised KeyError",
    argument_error:
      "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code raised ArgumentError",
    throw: "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code threw"
  }

  describe "a guard module that exits or throws" do
    test ":open admits" do
      for guard <- [ExitsGuard, ThrowsGuard] do
        assert Guardrails.run([{guard, on_error: :open}], "x") == {:ok, "x"}
      end
    end

    test ":closed is a :guard_error violation naming the exit tag, never its terms" do
      assert {:error, [exited]} = Guardrails.run([{ExitsGuard, on_error: :closed}], "x")
      assert exited.constraint == :guard_error
      assert exited.message == "guard #{inspect(ExitsGuard)} exited: :timeout"

      assert {:error, [threw]} = Guardrails.run([{ThrowsGuard, on_error: :closed}], "x")
      assert threw.message == "guard #{inspect(ThrowsGuard)} threw"

      refute inspect([exited, threw], limit: :infinity, printable_limit: :infinity) =~ "SECRET"
    end

    test ":reraise lets the exit and the throw through, as before" do
      assert catch_exit(Guardrails.run([ExitsGuard], "x")) ==
               {:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}}

      assert catch_throw(Guardrails.run([ThrowsGuard], "x")) == {:nope, "SECRET-THROWN"}
    end
  end

  describe "a SemanticScope classifier that fails" do
    test ":open admits every kind of failure" do
      for {_kind, classifier} <- classifiers() do
        assert Guardrails.run([{@scope, classifier: classifier, on_error: :open}], "q") ==
                 {:ok, "q"}
      end
    end

    test ":closed gives a :guard_error naming the failure's tag only" do
      for {kind, classifier} <- classifiers() do
        assert {:error, [violation]} =
                 Guardrails.run([{@scope, classifier: classifier, on_error: :closed}], "q")

        assert violation.constraint == :guard_error
        assert violation.message == Map.fetch!(@expected, kind)
        refute inspect(violation, limit: :infinity, printable_limit: :infinity) =~ "SECRET"
      end
    end

    test "a failing fast_path is handled the same way" do
      guard =
        {@scope,
         classifier: fn _, _ -> :allow end, fast_path: classifiers().exit, on_error: :closed}

      assert {:error, [%{message: message}]} = Guardrails.run([guard], "q")
      assert message == @expected.exit
    end

    test ":reraise lets the host's own exception through unchanged" do
      assert_raise KeyError, fn ->
        Guardrails.run([{@scope, classifier: classifiers().key_error}], "q")
      end

      assert catch_exit(Guardrails.run([{@scope, classifier: classifiers().exit}], "q")) ==
               {:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}}
    end

    test "the guard's own configuration errors still raise under :open and :closed" do
      for policy <- [:open, :closed] do
        assert_raise KeyError, ~r/key :classifier not found/, fn ->
          Guardrails.run([{@scope, on_error: policy}], "q")
        end

        assert_raise ArgumentError, ~r/:classifier must return/, fn ->
          Guardrails.run([{@scope, classifier: fn _, _ -> :nope end, on_error: policy}], "q")
        end
      end
    end
  end

  test "GuardError's message never shows the reason's terms" do
    for {kind, reason, message} <- [
          {:error, %KeyError{key: :k, term: %{token: "SECRET"}}, "host code raised KeyError"},
          {:exit, {:shutdown, "SECRET"}, "host code exited: :shutdown"},
          {:exit, "SECRET", "host code exited: a string (6 bytes)"},
          {:throw, "SECRET", "host code threw"}
        ] do
      assert Exception.message(%GuardError{kind: kind, reason: reason}) == message
    end
  end
end
```

Create `test/tools/memory_mount_namespace_test.exs`:

```elixir
defmodule Normandy.Tools.MemoryMountNamespaceTest do
  # SEC-7: a session whose namespace is a mount's namespace would write the mount's
  # documents with read-write access, past the mount's :read_only.
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{Context, Memory}

  defp call(tool, input, ns),
    do:
      Memory.run(tool, %Context{tool_call_id: "c", values: %{memory_namespace: ns}, input: input})

  setup do
    store = InMemory.new()
    {:ok, _} = InMemory.put(store, "acme/kb", "/memories/policy.md", "be kind", :new)

    tool =
      Memory.new(store: {InMemory, store}, mounts: %{"/memories/org" => {"acme/kb", :read_only}})

    {:ok, store: store, tool: tool}
  end

  test "a session namespace equal to a mount's is refused before any write", %{
    store: store,
    tool: tool
  } do
    error =
      assert_raise ArgumentError, fn ->
        call(
          tool,
          %{"command" => "create", "path" => "/memories/policy.md", "file_text" => "EVIL"},
          "acme/kb"
        )
      end

    assert error.message ==
             "memory tool: tool_context[:memory_namespace] equals the namespace of mount " <>
               "/memories/org; a session namespace must differ from every mount's"

    refute error.message =~ "acme/kb"

    assert {:ok, %{content: "be kind"}} = InMemory.get(store, "acme/kb", "/memories/policy.md")

    assert {:ok, view} =
             call(tool, %{"command" => "view", "path" => "/memories/org/policy.md"}, "acme/u")

    assert view =~ "be kind"
    refute view =~ "EVIL"
  end

  test "reads from that namespace are refused too, whatever the command", %{tool: tool} do
    assert_raise ArgumentError, ~r/equals the namespace of mount \/memories\/org/, fn ->
      call(tool, %{"command" => "view", "path" => "/memories"}, "acme/kb")
    end
  end

  test "another session namespace is unaffected", %{tool: tool} do
    assert {:ok, _} =
             call(
               tool,
               %{"command" => "create", "path" => "/memories/notes.md", "file_text" => "x"},
               "acme/u"
             )
  end

  test "through dispatch the model gets an error result naming the mount, not the namespace", %{
    tool: tool
  } do
    alias Normandy.Agents.Dispatch
    alias Normandy.Components.{ToolCall, ToolResult}
    alias Normandy.Tools.Toolset

    config = %{
      name: "a",
      toolset: Toolset.new([tool]),
      tool_context: %{memory_namespace: "acme/kb"}
    }

    call = %ToolCall{
      id: "m1",
      name: "memory",
      input: %{"command" => "view", "path" => "/memories"}
    }

    assert %ToolResult{is_error: true} =
             result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

    text = inspect(result.output)
    assert text =~ "equals the namespace of mount /memories/org"
    refute text =~ "acme/kb"
  end

  describe "new/1" do
    test "two mounts of one namespace with different access are refused" do
      error =
        assert_raise ArgumentError, fn ->
          Memory.new(
            store: {InMemory, nil},
            mounts: %{
              "/memories/kb" => {"acme/kb", :read_only},
              "/memories/kb-edit" => {"acme/kb", :read_write}
            }
          )
        end

      assert error.message ==
               "Normandy.Tools.Memory.new/1: :mounts /memories/kb and /memories/kb-edit share a " <>
                 "namespace with different access; give one namespace one access"
    end

    test "two read-only views of one namespace are allowed" do
      assert %Memory{} =
               Memory.new(
                 store: {InMemory, nil},
                 mounts: %{
                   "/memories/a" => {"acme/kb", :read_only},
                   "/memories/b" => {"acme/kb", :read_only}
                 }
               )
    end
  end
end
```

(The dispatch test reads `result.output` through `inspect/1` so it holds whether Task 5.6
sends a tool's `{:error, binary}` bare or wrapped.)

Create `test/a2a/server_limits_test.exs`:

```elixir
defmodule Normandy.A2A.ServerLimitsTest do
  # SEC-9: an A2A caller's text is bounded, and the host can scope tool_context per caller.
  use ExUnit.Case, async: true

  alias Claudio.A2A.{Message, Part}
  alias Normandy.A2A.Server
  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.ToolCall
  alias Normandy.Test.{ContextProbe, ScriptedToolClient, StubClient, TelemetryCapture}
  alias Normandy.Tools.Context

  @request_stop [:normandy, :a2a, :request, :stop]

  defp stub_agent do
    BaseAgent.init(%{
      client: %StubClient{notify: self(), reply: fn model -> %{model | chat_message: "ok"} end},
      model: "test-model",
      name: "limits-agent"
    })
  end

  defp text_message(bytes), do: Message.new(:user, [Part.text(String.duplicate("a", bytes))])

  describe ":max_text_bytes" do
    test "100_000 bytes run; 100_001 are :too_large and never reach the model" do
      assert {:ok, %Claudio.A2A.Task{}} =
               Server.handle_message(stub_agent(), text_message(100_000))

      assert_received {:converse, _request, _opts}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :too_large} = Server.handle_message(stub_agent(), text_message(100_001))
        end)

      refute_received {:converse, _request, _opts}
      refute log =~ "A2A Server"
    end

    test "the limit counts every text part" do
      message =
        Message.new(:user, [
          Part.text(String.duplicate("a", 6)),
          Part.text(String.duplicate("b", 5))
        ])

      assert {:error, :too_large} =
               Server.handle_message(stub_agent(), message, [], max_text_bytes: 10)

      assert {:ok, _task} = Server.handle_message(stub_agent(), message, [], max_text_bytes: 11)
    end

    test "nil sets no limit" do
      assert {:ok, _task} =
               Server.handle_message(stub_agent(), text_message(100_001), [], max_text_bytes: nil)
    end

    test "the request span's stop says :too_large" do
      ref = TelemetryCapture.attach([@request_stop], agent_name: "limits-agent")

      Server.handle_message(stub_agent(), text_message(11), [], max_text_bytes: 10)

      assert_receive {:telemetry, ^ref, _measurements, %{status: :error, error_type: :too_large}}
    end
  end

  describe ":tool_context" do
    defp probe_agent do
      %{
        client: %ScriptedToolClient{calls: [%ToolCall{id: "call_1", name: "probe", input: %{}}]},
        model: "test",
        name: "ctx-agent",
        tool_context: %{memory_namespace: "shared"}
      }
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%ContextProbe{notify: self()})
    end

    test "each call runs with the tool_context it was given, not the config's" do
      config = probe_agent()
      message = Message.new(:user, [Part.text("go")])

      assert {:ok, _} =
               Server.handle_message(config, message, [],
                 tool_context: %{memory_namespace: "a2a/alice"}
               )

      assert_receive {:probe_ctx, %Context{values: %{memory_namespace: "a2a/alice"}}}

      assert {:ok, _} = Server.handle_message(config, message, [], tool_context: %{tenant: "bob"})
      assert_receive {:probe_ctx, %Context{values: values}}
      assert values == %{tenant: "bob"}

      assert {:ok, _} = Server.handle_message(config, message)
      assert_receive {:probe_ctx, %Context{values: %{memory_namespace: "shared"}}}
    end
  end

  describe "options" do
    test "an unknown option raises, naming it" do
      error =
        assert_raise ArgumentError, fn ->
          Server.handle_message(stub_agent(), text_message(1), [], max_bytes: 10)
        end

      assert error.message =~ "Normandy.A2A.Server.handle_message/4: unknown option :max_bytes"
    end

    test ":tool_context must be a plain map" do
      assert_raise ArgumentError,
                   ~r/handle_message\/4: invalid value for :tool_context option/,
                   fn ->
                     Server.handle_message(stub_agent(), text_message(1), [],
                       tool_context: [tenant: "x"]
                     )
                   end
    end
  end
end
```

(`capture_log/1` captures every process's logs, so the size test refutes the A2A Server's own
log line rather than asserting an empty log: other async tests log at the same time.)

- [ ] **Step 2: Run them to verify they fail**

Run: `mix format && mix test test/guardrails/guard_crash_test.exs test/tools/memory_mount_namespace_test.exs test/a2a/server_limits_test.exs`
Expected: FAIL. `guard_crash_test.exs` does not compile (`Normandy.Guardrails.GuardError`
is undefined); in the other two files every test that expects a raise or `:too_large` fails
(the `create` with namespace `"acme/kb"` returns `{:ok, _}` and the KB reads `EVIL`;
`handle_message/4` is undefined), and the "unaffected"/"read-only views" tests pass.

- [ ] **Step 3: `Describe.reason_tag/1` and `GuardError` (SEC-4)**

In `lib/normandy/components/content_block/describe.ex`, after `def type_of(_value), do: "an unsupported term"`, add:

```elixir

  # An error or exit reason by its tag only: the atom, a tagged tuple's tag, or an
  # exception's module. Its terms can carry call arguments, response bodies or secrets.
  @spec reason_tag(term()) :: String.t()
  def reason_tag(%mod{__exception__: true}), do: inspect(mod)

  def reason_tag(reason)
      when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
      do: inspect(elem(reason, 0))

  def reason_tag(reason) when is_atom(reason), do: inspect(reason)
  def reason_tag(reason), do: type_of(reason)
```

Create `lib/normandy/guardrails/guard_error.ex`:

```elixir
defmodule Normandy.Guardrails.GuardError do
  @moduledoc """
  Raised by a guard when host code it calls fails: the `:classifier` or `:fast_path`
  function of `Normandy.Guardrails.Builtins.SemanticScope`, or the same in a guard of your
  own. `Normandy.Guardrails.run/3` handles it under the guard's `:on_error` like any other
  crash, so a guard's own configuration errors (an `ArgumentError` or `KeyError` from a
  built-in guard) stay apart from failures of the code the host injected.

    * `kind` - `:error` (a raise), `:exit` or `:throw`.
    * `reason` - the exception, exit reason or thrown value. It is never shown: the
      message names the exception's module or the exit's tag only.
  """

  alias Normandy.Components.ContentBlock.Describe

  defexception [:kind, :reason]

  @type t :: %__MODULE__{kind: :error | :exit | :throw, reason: term()}

  @impl true
  def message(%__MODULE__{kind: :error, reason: reason}),
    do: "host code raised " <> Describe.reason_tag(reason)

  def message(%__MODULE__{kind: :exit, reason: reason}),
    do: "host code exited: " <> Describe.reason_tag(reason)

  def message(%__MODULE__{kind: :throw}), do: "host code threw"
end
```

- [ ] **Step 4: `Guardrails` catches exits and throws (SEC-4)**

In `lib/normandy/guardrails.ex`:

(a) Moduledoc, `## Error handling (:on_error)`: replace from `Each guard spec may carry` up
to and including `has no fixed keys, so a missing key reads as \`nil\`.` with:

```
  Each guard spec may carry an `:on_error` policy controlling what happens when
  its `check` **crashes**: raises, exits (a `GenServer.call` or `Task.await` timeout
  inside the guard) or throws:

  - `:reraise` (default) — the crash propagates. A configuration bug stays a
    crash, not a silent admit.
  - `:open` — the crash is caught and treated as a pass. Use this for a guard
    that calls an external service so an outage admits instead of taking down
    the whole guard chain.
  - `:closed` — the crash is caught and turned into a `:guard_error` violation
    whose message names the guard and the exception's module, the exit's tag or
    "threw", never the exception's message or the exit's terms.

  Only the guard's `check` call is caught; a malformed return value is a
  contract violation and always raises regardless of `:on_error`. So does a
  built-in guard's configuration error (an `ArgumentError` or `KeyError`, such
  as a `:field` the struct does not have or a missing option). Host code a built-in
  guard calls (`SemanticScope`'s `:classifier` and `:fast_path`) is not configuration:
  its crash reaches `:on_error` as a `Normandy.Guardrails.GuardError`. A guard has no
  timeout of its own: one that blocks without failing blocks the turn, so give the
  service call inside it a timeout. A `:field` on a plain map cannot be checked: a map
  has no fixed keys, so a missing key reads as `nil`.
```

(b) Replace `alias Normandy.Guardrails.Guard` with:

```elixir
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Guardrails.Guard
  alias Normandy.Guardrails.GuardError
```

(c) In the comment above `invoke/4`, `\`:open\` rescues and treats the crash as a pass; \`:closed\` rescues and turns` becomes `\`:open\` catches a raise, exit or throw and treats it as a pass; \`:closed\` turns`, and `Only the \`check\` call is rescued` becomes `Only the \`check\` call is caught`. In `invoke/4`'s `try`, after the last `rescue` clause (`exception -> on_error_result(policy, mod, exception)`), add:

```elixir
        catch
          :exit, reason -> on_error_result(policy, mod, {:exit, reason})
          :throw, value -> on_error_result(policy, mod, {:throw, value})
```

(d) Replace both `on_error_result/3` clauses with:

```elixir
  defp on_error_result(:open, _mod, _crash), do: :ok

  defp on_error_result(:closed, mod, crash) do
    {:error,
     [
       %{
         guard: mod,
         path: [],
         # The module or exit tag only: an exception's message can inspect the guarded
         # value, and this violation reaches the caller, telemetry and the store.
         message: "guard #{inspect(mod)} #{describe_crash(crash)}",
         constraint: :guard_error
       }
     ]}
  end

  defp describe_crash(%GuardError{} = error), do: "crashed: " <> Exception.message(error)
  defp describe_crash({:exit, reason}), do: "exited: " <> Describe.reason_tag(reason)
  defp describe_crash({:throw, _value}), do: "threw"
  defp describe_crash(exception), do: "crashed: " <> inspect(exception.__struct__)
```

The exception message is unchanged (`"guard X crashed: KeyError"`), so
`guardrails_test.exs` ":closed names the crashed guard's exception module" still passes.

- [ ] **Step 5: `SemanticScope` wraps host code (SEC-4)**

In `lib/normandy/guardrails/builtins/semantic_scope.ex`:

(a) Moduledoc: replace the `:on_error` bullet with:

```
  - `:on_error` — handled by `Normandy.Guardrails.run/2,3`. A
    classifier that calls a flaky service should set `on_error: :open` so an
    outage admits rather than crashing the guard chain. See
    `Normandy.Guardrails` for the policy semantics (default `:reraise`). Under
    `:open` or `:closed`, a raise, exit or throw inside `:classifier` or
    `:fast_path` (including a `KeyError` or `ArgumentError`, and a call timeout) is
    raised as a `Normandy.Guardrails.GuardError` and handled by that policy. Under
    `:reraise` it propagates unchanged. A missing `:classifier` or a return value
    of the wrong shape is a configuration error and raises whatever `:on_error` says.

  The functions are closures, so a `SemanticScope` guard cannot be stored in a
  `Turn.Session` template (`ConfigTemplate.from_config/2` refuses functions): use it
  with `BaseAgent.run/3`, `stream/3`, `admit/2,3`, or an inline `AgentProcess`.
```

(b) Add `alias Normandy.Guardrails.GuardError` after `alias Normandy.Guardrails.Builtins.Field`.

(c) In `check/3`, `case fast_path.(value, context) do` becomes
`case call_host(fast_path, value, context, opts) do`, and `classify(classifier, value, context)`
becomes `classify(classifier, value, context, opts)`. `classify/3` becomes `classify/4`
(`defp classify(classifier, value, context, opts) do`), and its
`case classifier.(value, context) do` becomes `case call_host(classifier, value, context, opts) do`.
The two return-shape `raise ArgumentError` clauses stay outside `call_host/4`.

(d) After `classify/4`, add:

```elixir

  # Host code is not this guard's configuration: under :open or :closed its crash is a
  # GuardError, which Guardrails.run/3 hands to the policy (a builtin's own ArgumentError
  # or KeyError always raises). Under :reraise it propagates as it is, stacktrace and all.
  defp call_host(fun, value, context, opts) do
    if Keyword.get(opts, :on_error, :reraise) == :reraise do
      fun.(value, context)
    else
      try do
        fun.(value, context)
      rescue
        exception ->
          reraise GuardError, [kind: :error, reason: exception], __STACKTRACE__
      catch
        kind, reason when kind in [:exit, :throw] ->
          reraise GuardError, [kind: kind, reason: reason], __STACKTRACE__
      end
    end
  end
```

(`reraise` keeps the host's stacktrace on the `GuardError`; credo `--strict` flags a bare
`raise` inside `rescue`.)

Run: `mix format && mix test test/guardrails test/agents/base_agent_admit_test.exs`
Expected: PASS.

- [ ] **Step 6: Memory mounts (SEC-7)**

In `lib/normandy/tools/memory.ex`:

(a) Moduledoc: after the paragraph ending `Never store secrets in memory.`, add:

```

  A mount's access holds only while no session can write its namespace directly, so a
  session namespace equal to a mount's namespace raises (the call fails; the model sees
  the mount path, not the namespace), and two mounts of one namespace with different
  access raise in `new/1`. Never build a namespace from a user-controlled string (a
  username, an org slug) without a fixed prefix that mount namespaces do not use, such as
  `"users/" <> user_id` beside `"shared/org-kb"`.
```

(b) In `namespace!/2`, the success clause `ns when is_binary(ns) and ns != "" -> ns` becomes
`ns when is_binary(ns) and ns != "" -> not_a_mount!(tool, ns)`. Add after `namespace!/2`:

```elixir
  # A session that could write a mount's namespace directly would bypass the mount's
  # :read_only. Names the mount path only: this message reaches the model.
  defp not_a_mount!(%__MODULE__{mounts: mounts, namespace_key: key}, ns) do
    case Enum.find(Enum.sort(mounts), fn {_mount, {mount_ns, _access}} -> mount_ns == ns end) do
      nil ->
        ns

      {mount, _} ->
        raise ArgumentError,
              "memory tool: tool_context[#{inspect(key)}] equals the namespace of mount " <>
                "#{mount}; a session namespace must differ from every mount's"
    end
  end
```

`run/2` calls `namespace!/2` before the telemetry span and before any store call, and the
host can change `tool_context` per session, so `run/2` is the one place that can check it.

(c) In `validate_mounts!/1` (the `is_map` clause), after the `Enum.each` that checks each
entry, add:

```elixir

    mounts
    |> Enum.group_by(fn {_mount, {ns, _access}} -> ns end)
    |> Enum.each(fn {_ns, entries} -> same_access!(Enum.sort(entries)) end)
```

and above `@spec bad_mount!(term()) :: no_return()` add:

```elixir
  # Two mounts of one namespace with different access: the read-write one would write
  # what the read-only one promises not to.
  defp same_access!([{_, {_, access}} | _] = entries) do
    case Enum.find(entries, fn {_mount, {_ns, a}} -> a != access end) do
      nil ->
        :ok

      _ ->
        raise ArgumentError,
              "Normandy.Tools.Memory.new/1: :mounts " <>
                Enum.map_join(entries, " and ", &elem(&1, 0)) <>
                " share a namespace with different access; give one namespace one access"
    end
  end
```

Run: `mix format && mix test test/tools/memory_mount_namespace_test.exs test/tools/memory_test.exs`
Expected: PASS.

- [ ] **Step 7: `A2A.Server.handle_message/4` (SEC-9)**

In `lib/normandy/a2a/server.ex`:

(a) Moduledoc: replace

```elixir
      # Handle incoming message (in your controller)
      {:ok, task} = Normandy.A2A.Server.handle_message(agent_config, a2a_message)

```

with

```elixir
      # Handle incoming message (in your controller), scoped to the caller
      {:ok, task} =
        Normandy.A2A.Server.handle_message(agent_config, a2a_message, conn.req_headers,
          tool_context: %{memory_namespace: "a2a/" <> caller_id}
        )

  ## What the host owns

  This module never sees the HTTP request. Authentication, authorization and the request
  body limit (`Plug.Parsers`' `:length`) belong to your Plug or controller: every caller
  that gets past them reaches the agent and **every tool in `config.toolset`**, whatever
  `build_agent_card/2`'s `:expose_tools` lists (the card only advertises). Expose an agent
  whose tools are safe for every such caller.

  Each call runs on the `config` you pass, so callers share its `tool_context` (and the
  memory namespace in it) unless you pass `handle_message/4`'s `:tool_context` per caller.
  A shared memory namespace lets one caller plant text that every other caller's turns
  read. `:max_text_bytes` (default 100_000) bounds the text a caller can send.
```

(b) After `@build_agent_card_opts_schema`, add:

```elixir

  @handle_message_opts_schema NimbleOptions.new!(
                                max_text_bytes: [
                                  type: {:or, [:pos_integer, {:in, [nil]}]},
                                  default: 100_000,
                                  doc:
                                    "The most bytes of text the message's parts may hold in " <>
                                      "total; more is `{:error, :too_large}` and the agent does " <>
                                      "not run. `nil` sets no limit."
                                ],
                                tool_context: [
                                  type: {:custom, Normandy.Options, :plain_map, []},
                                  type_doc: "`t:map/0`",
                                  doc:
                                    "Replaces `config.tool_context` for this call, so each " <>
                                      "caller gets its own (its memory namespace, say). Not " <>
                                      "merged: a key you leave out is absent. Default: the " <>
                                      "config's own."
                                ]
                              )
```

(c) `handle_message/2`'s body becomes `handle_message(config, message, [], [])`.

(d) In `handle_message/3`'s `@doc`, `(\`:no_text\` or \`:agent_failed\`). No message content is included.`
becomes `(\`:no_text\`, \`:too_large\` or \`:agent_failed\`). No message content is included.`
followed by a blank line and `Same as \`handle_message/4\` with no options.` Replace
`handle_message/3`'s body (from `token =` through the `try ... after ... end`) with
`handle_message(config, message, carrier, [])`, and add after it:

```elixir
  @doc """
  Like `handle_message/3`, with options.

  Returns `{:error, :too_large}` when the message's text parts hold more than
  `:max_text_bytes` bytes in total: the agent does not run, nothing is logged, and the
  request span's stop metadata has `error_type: :too_large`.

  ## Options

  #{Options.docs(@handle_message_opts_schema)}
  """
  @spec handle_message(
          BaseAgentConfig.t(),
          Claudio.A2A.Message.t(),
          [{String.t(), String.t()}],
          keyword()
        ) :: {:ok, Claudio.A2A.Task.t()} | {:error, term()}
  def handle_message(%BaseAgentConfig{} = config, %Claudio.A2A.Message{} = message, carrier, opts)
      when is_list(carrier) do
    opts =
      Options.validate!(opts, @handle_message_opts_schema, {__MODULE__, :handle_message, 4})

    config =
      case Keyword.fetch(opts, :tool_context) do
        {:ok, tool_context} -> %{config | tool_context: tool_context}
        :error -> config
      end

    token =
      carrier
      |> Enum.map(fn {name, value} -> {to_string(name), value} end)
      |> trace_ctx()
      |> OtelCtx.attach()

    try do
      request_span(config, message, Keyword.fetch!(opts, :max_text_bytes))
    after
      OtelCtx.detach(token)
    end
  end
```

(e) Replace `request_span/2`'s head and its `result =` expression:

```elixir
  defp request_span(config, message) do
    ...
      result =
        case message_text(message) do
          "" -> {:error, :no_text}
          text -> run_agent(config, text, task_id)
        end
```

with

```elixir
  defp request_span(config, message, max_text_bytes) do
    ...
      result =
        if too_large?(message, max_text_bytes),
          do: {:error, :too_large},
          else: run_text(config, message_text(message), task_id)
```

(the `...` lines are unchanged) and add above `defp message_text(message) do`:

```elixir
  defp run_text(_config, "", _task_id), do: {:error, :no_text}
  defp run_text(config, text, task_id), do: run_agent(config, text, task_id)

  # Summed per part before anything is joined or copied.
  defp too_large?(_message, nil), do: false

  defp too_large?(message, max_bytes) do
    message.parts
    |> Enum.reduce(0, fn part, total ->
      case Map.get(part, :text) do
        text when is_binary(text) -> total + byte_size(text)
        _ -> total
      end
    end)
    |> Kernel.>(max_bytes)
  end
```

A too-large message never reaches `run_agent/3`, so it is never logged as `agent failed`.

(f) In `lib/normandy/telemetry.ex`, the `[:normandy, :a2a, :request, ...]` entry:
`` `A2A.Server.handle_message/3` handling `` becomes `` `A2A.Server.handle_message/2,3,4` handling ``,
and `` `error_type` (`:no_text` or `:agent_failed`) `` becomes
`` `error_type` (`:no_text`, `:too_large` or `:agent_failed`) `` (re-wrap the line).

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test test/guardrails test/tools test/a2a test/telemetry/catalogue_test.exs test/agents/base_agent_admit_test.exs`
Expected: PASS.

- [ ] **Step 9: MIGRATING**

Append to `## 37. Security hardening` in `MIGRATING-2.0.md`:

```markdown
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
```

- [ ] **Step 10: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.7b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.7b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/components/content_block/describe.ex lib/normandy/guardrails/guard_error.ex \
  lib/normandy/guardrails.ex lib/normandy/guardrails/builtins/semantic_scope.ex \
  lib/normandy/tools/memory.ex lib/normandy/a2a/server.ex lib/normandy/telemetry.ex \
  MIGRATING-2.0.md test/guardrails/guard_crash_test.exs \
  test/tools/memory_mount_namespace_test.exs test/a2a/server_limits_test.exs
git commit -m "fix(security): guard exits, mount namespaces and A2A request limits"
```

### Task 5.7c: Stored templates are checked on load; supplements pin security settings (SEC-8)

Ruling R9: trust-boundary docs (Option A), `ConfigTemplate.check_loaded!/1` and the
supplement's `:pinned` (Option C). HMAC-signed templates (Option B) are a known limit, not
built.

**Files:**
- Modify: `lib/normandy/behaviours/hooks.ex` (`plain_data?/1` becomes public, `@doc false`)
- Modify: `lib/normandy/agents/config_template.ex` (moduledoc "Trust boundary", `storable_fields!/1`, delete `unstorable?/1`, new `check_loaded!/1`, `check_pinned!/2`, `rebuild/3`)
- Modify: `lib/normandy/behaviours/agent_template.ex` (moduledoc, `supplement` type)
- Modify: `lib/normandy/agents/turn/server.ex` (moduledoc "Store unavailable", `start_config/3`, `reconstruct_config/2`, new `check_loaded/1`, `check_pinned/2`, `check_template/1`)
- Modify: `docs/guides/distributed_sessions.md` (new section)
- Modify: `test/agents/config_template_test.exs` (three guard modules, one assertion), `test/agents/turn/server_test.exs` (`FailingCreds`)
- Modify: `MIGRATING-2.0.md` (`## 37.`)
- Test: create `test/agents/config_template_trust_test.exs`

**Interfaces:**
- Consumes: `Hooks.plain_data?/1`; `BaseAgentConfig.default_guardrails/0`; `Describe.type_of/1`; `Normandy.Test.TurnConfig` (fixture), `AgentTemplate.Catalog`, `SessionStore.InMemory`, `SessionRegistry.Native`; `## 37.` from Task 5.7a.
- Produces: `ConfigTemplate.check_loaded!(map) :: :ok` (raises `ArgumentError` naming the field; never a value); `ConfigTemplate.check_pinned!(tmpl, supplement) :: :ok` (`@doc false`); supplement key `:pinned` (`keyword()`, fields `:policy :budget :credential :compactor :model_catalog :hooks :guardrails`); `Turn.Server` start reason `{:invalid_template, message}` (server waits `:unavailable`, `run/2` replies `%TurnError{type: :session_unavailable, reason: {:invalid_template, message}}`).

- [ ] **Step 1: Write the failing test**

Create `test/agents/config_template_trust_test.exs`:

```elixir
defmodule Normandy.Agents.ConfigTemplateTrustTest do
  # SEC-8: a template read from the store is checked before anything in it is used, and a
  # supplement's :pinned fixes the security settings a store writer could swap.
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.PolicyEngine.{AllowAll, Ruleset}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig
  alias Normandy.TurnError

  # Reports each token request to the process registered under opts[:notify].
  defmodule NotifyingCreds do
    @moduledoc false
    @behaviour Normandy.Behaviours.CredentialProvider
    @impl true
    def get_token(_provider, opts) do
      send(Keyword.fetch!(opts, :notify), :token_requested)
      {:ok, "TOKEN"}
    end
  end

  defmodule NotAGuard do
    @moduledoc false
    def check(_value, _opts), do: :ok
  end

  @ruleset {Ruleset,
            rules: [%{match: "srv__*", action: :require_approval}], default_action: :deny}

  defp template(overrides \\ %{}) do
    TurnConfig.build()
    |> Map.merge(overrides)
    |> ConfigTemplate.from_config("kind-a")
  end

  defp supplement(extra \\ %{}) do
    Map.merge(
      %{
        toolset: nil,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn token -> %{api_key: token} end
      },
      extra
    )
  end

  defp message!(fun), do: assert_raise(ArgumentError, fun).message

  describe "check_loaded!/1" do
    test "a template from_config/2 wrote passes" do
      assert ConfigTemplate.check_loaded!(template()) == :ok
    end

    test "a function anywhere is refused, naming the field and never the value" do
      tmpl = Map.put(template(), :tool_context, %{cb: fn x -> {x, "SECRET"} end})

      message = message!(fn -> ConfigTemplate.check_loaded!(tmpl) end)

      assert message ==
               ~s(Normandy.Agents.ConfigTemplate.check_loaded!/1: template "kind-a" :tool_context ) <>
                 "holds a function, pid, reference or port; it is not used (see the Trust " <>
                 "boundary section of Normandy.Agents.ConfigTemplate)"

      refute message =~ "SECRET"
    end

    test "a pid or a reference inside guard opts is refused" do
      for bad <- [self(), make_ref()] do
        tmpl =
          Map.put(template(), :guardrails,
            input: [{Normandy.Guardrails.Builtins.MaxLength, limit: 3, owner: bad}]
          )

        assert message!(fn -> ConfigTemplate.check_loaded!(tmpl) end) =~
                 ~s(template "kind-a" :guardrails holds a function, pid, reference or port)
      end
    end

    test "a behaviours_refs module that does not implement its behaviour is refused" do
      for {slot, mod, behaviour} <- [
            {:policy, String, "Normandy.Behaviours.PolicyEngine"},
            {:budget, Nope.Missing, "Normandy.Behaviours.BudgetTracker"},
            {:credential, AllowAll, "Normandy.Behaviours.CredentialProvider"}
          ] do
        tmpl = put_in(template().behaviours_refs[slot], {mod, []})

        assert message!(fn -> ConfigTemplate.check_loaded!(tmpl) end) ==
                 ~s(Normandy.Agents.ConfigTemplate.check_loaded!/1: template "kind-a" ) <>
                   "behaviours_refs #{inspect(slot)} must be {module, keyword} whose module is " <>
                   "loaded on this node and implements #{behaviour}, got: #{inspect(mod)}; it is " <>
                   "not used (see the Trust boundary section of Normandy.Agents.ConfigTemplate)"
      end
    end

    test "a behaviours_refs slot that is not {module, keyword} is refused without showing it" do
      tmpl = put_in(template().behaviours_refs[:policy], %{api_key: "SECRET"})

      message = message!(fn -> ConfigTemplate.check_loaded!(tmpl) end)
      assert message =~ "behaviours_refs :policy must be {module, keyword}"
      assert message =~ "got: a map;"
      refute message =~ "SECRET"
    end

    test "a guard module that is not a Guard is refused" do
      tmpl = Map.put(template(), :guardrails, output: [NotAGuard])

      assert message!(fn -> ConfigTemplate.check_loaded!(tmpl) end) =~
               ":guardrails :output guard #{inspect(NotAGuard)} is not loaded on this node or " <>
                 "does not implement Normandy.Guardrails.Guard"
    end

    test "rebuild/3 runs the same check first" do
      tmpl = put_in(template().behaviours_refs[:policy], {String, []})

      assert message!(fn -> ConfigTemplate.rebuild(tmpl, supplement(), "T") end) =~
               "check_loaded!/1: template \"kind-a\" behaviours_refs :policy"
    end
  end

  describe "the supplement's :pinned" do
    test "a template whose pinned field differs is refused; an equal one rebuilds" do
      tmpl = template()
      pinned = supplement(%{pinned: [policy: @ruleset]})

      assert message!(fn -> ConfigTemplate.rebuild(tmpl, pinned, "T") end) ==
               ~s(Normandy.Agents.ConfigTemplate.rebuild/3: template "kind-a" has a :policy that ) <>
                 "differs from the one this node's supplement pins; it is not used (see the " <>
                 "Trust boundary section of Normandy.Agents.ConfigTemplate)"

      tmpl = put_in(tmpl.behaviours_refs[:policy], @ruleset)
      assert ConfigTemplate.rebuild(tmpl, pinned, "T").behaviours.policy == @ruleset
    end

    test "guardrails and the credential can be pinned too" do
      tmpl = template()
      guards = [input: [{Normandy.Guardrails.Builtins.MaxLength, limit: 10}]]

      assert_raise ArgumentError, ~r/has a :guardrails that differs/, fn ->
        ConfigTemplate.rebuild(tmpl, supplement(%{pinned: [guardrails: guards]}), "T")
      end

      assert_raise ArgumentError, ~r/has a :credential that differs/, fn ->
        ConfigTemplate.rebuild(
          tmpl,
          supplement(%{pinned: [credential: {NotifyingCreds, []}]}),
          "T"
        )
      end
    end

    test "a field that cannot be pinned is refused, naming it" do
      assert message!(fn ->
               ConfigTemplate.rebuild(template(), supplement(%{pinned: [tool_context: %{}]}), "T")
             end) ==
               "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement pins :tool_context; " <>
                 ":pinned takes :policy, :budget, :credential, :compactor, :model_catalog, " <>
                 ":hooks, :guardrails"
    end
  end

  describe "Turn.Server" do
    defp handlers do
      %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %TurnConfig.Resp{content: "hi", tool_calls: nil} end
      }
    end

    defp thin_start(tmpl, supp) do
      name = :"creds_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      tmpl = put_in(tmpl.behaviours_refs[:credential], {NotifyingCreds, [notify: name]})
      store = InMemory.new()
      sid = "trust-#{System.unique_integer([:positive])}"
      :ok = InMemory.save_config_template(store, sid, tmpl)
      {:ok, cat} = Catalog.start_link([])
      :ok = Catalog.put(cat, "kind-a", supp)

      ExUnit.CaptureLog.capture_log(fn ->
        send(
          self(),
          {:started,
           Turn.Server.start_link(
             session_id: sid,
             store: {InMemory, store},
             registry: {Native, Native.new()},
             template_provider: {Catalog, cat},
             handlers: handlers()
           )}
        )
      end)

      assert_received {:started, {:ok, srv}}
      srv
    end

    test "a template with a function in it is never used, and no token is requested" do
      tmpl = Map.put(template(), :tool_context, %{cb: fn -> :x end})
      srv = thin_start(tmpl, supplement())

      assert {:error,
              %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
               Turn.Server.run(srv, "hello")

      assert message =~ ":tool_context holds a function, pid, reference or port"
      refute_received :token_requested
    end

    test "a swapped policy is refused before the template's credential provider runs" do
      srv = thin_start(template(), supplement(%{pinned: [policy: @ruleset]}))

      assert {:error,
              %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
               Turn.Server.run(srv, "hello")

      assert message =~ "has a :policy that differs from the one this node's supplement pins"
      refute_received :token_requested
    end

    test "a template that passes runs as before" do
      srv =
        thin_start(
          put_in(template().behaviours_refs[:policy], @ruleset),
          supplement(%{pinned: [policy: @ruleset]})
        )

      assert {:ok, _output} = Turn.Server.run(srv, "hello")
      assert_received :token_requested
    end
  end
end
```

`Turn.Server.init/1` loads and checks the template before `start_link/1` returns, so a token
request has either reached the test's mailbox or never will when `refute_received` runs: no
timing involved. The template is saved with a closure directly through `InMemory`, which is
what a store writer can do (Postgres and Redis decode closures with `[:safe]`; inventory
Surprise 7).

- [ ] **Step 2: Run it to verify it fails**

Run: `mix format && mix test test/agents/config_template_trust_test.exs`
Expected: FAIL. `check_loaded!/1` is undefined (every `describe "check_loaded!/1"` test and
"rebuild/3 runs the same check first" fails); `rebuild/3` ignores `:pinned` (the three
pinned tests get a config instead of a raise); the first two `Turn.Server` tests get
`{:ok, _}` (no check) and receive `:token_requested`.

- [ ] **Step 3: One plain-data rule**

In `lib/normandy/behaviours/hooks.ex`, replace the `defp plain_data?` clauses with public
ones (same bodies), headed by:

```elixir
  @doc false
  # Plain data: no function, pid, reference or port anywhere inside. A stored template's
  # rule too (Normandy.Agents.ConfigTemplate).
  @spec plain_data?(term()) :: boolean()
  def plain_data?(value)
      when is_function(value) or is_pid(value) or is_reference(value) or is_port(value),
      do: false
```

and `defp` → `def` on its five other clauses (`[head | tail]`, tuple, struct, map, and the
catch-all).

In `lib/normandy/agents/config_template.ex`, replace `storable_fields!/1` and delete every
`unstorable?/1` clause:

```elixir
  # A function, pid, reference or port would be persisted as a term that only works on
  # this node and this code version, so refuse it here; check_loaded!/1 refuses it on load.
  defp storable_fields!(c) do
    fields = Map.take(Map.from_struct(c), @data_fields)

    Enum.each(fields, fn {key, value} ->
      unless Hooks.plain_data?(value) do
        raise ArgumentError,
              "Normandy.Agents.ConfigTemplate.from_config/2: #{inspect(key)} contains a function, " <>
                "pid, reference or port, which a template cannot store. Keep it to plain data " <>
                "(modules, atoms, numbers, strings, lists, maps)."
      end
    end)

    fields
  end
```

The comment above `storable_hooks!/1` names the deleted function: change its
`as unstorable?/1 does for the fields above.` to `as storable_fields!/1 does for the fields above.`

`from_config/2` now also refuses references and ports, as hook opts already were. The two
existing tests (`~r/from_config\/2.*:retry .*function/`,
`~r/from_config\/2: :guardrails contains a function/`) still match.

- [ ] **Step 4: `check_loaded!/1`, `check_pinned!/2` and `rebuild/3`**

In `lib/normandy/agents/config_template.ex`:

(a) Moduledoc: after the paragraph ending `Templates written by unreleased 2.0 builds are not translated.`, add:

```

  ## Trust boundary

  The session store is as trusted as your code. Whoever can write it (a shared Redis, a
  Postgres role another service uses) decides, on the next rehydrate on any node:

    * the policy, budget, compactor and model catalog modules and their opts, the
      guardrails and the hooks (removing them, or `PolicyEngine.AllowAll`);
    * the credential provider and its opts (`Turn.Server` calls it to get a token);
    * `tool_context`, so another tenant's memory namespace;
    * `template_id`, so which node-local supplement, and so which toolset, is used;
    * the saved server options (`on_approval_timeout`, the timeouts);
    * the turn state, including the input of a call parked for approval, and the
      conversation history.

  Keep the store single-tenant, or give Normandy's role its own database or ACL'd key
  prefix. Postgres and Redis decode stored bytes with `binary_to_term(_, [:safe])`, which
  still builds local functions.

  Normandy checks what it can without keys. `check_loaded!/1` runs on every template
  `Turn.Server` loads, before anything in it is used, and in `rebuild/3`: it refuses a
  function, pid, reference or port anywhere in the template, a behaviour ref whose module
  does not implement its behaviour (`policy` a `Normandy.Behaviours.PolicyEngine`,
  `budget` a `BudgetTracker`, `credential` a `CredentialProvider`, `compactor` a
  `Compactor`, `model_catalog` a `ModelCatalog`) and a guard module that does not
  implement `Normandy.Guardrails.Guard`. A supplement's `:pinned` fixes security settings
  on the node: with `pinned: [policy: ref, guardrails: g, credential: ref]` a template
  whose `policy`, `guardrails` or `credential` differs raises, before the credential
  provider is called. `:pinned` takes `:policy`, `:budget`, `:credential`, `:compactor`,
  `:model_catalog`, `:hooks` and `:guardrails`; `tool_context`, `template_id`, turn
  state and history cannot be pinned. Templates are not signed (a known limit).
```

(b) In `rebuild/3`, replace

```elixir
    tmpl = translate!(tmpl)
    refs = tmpl.behaviours_refs
```

with

```elixir
    :ok = check_loaded!(tmpl)
    tmpl = translate!(tmpl)
    :ok = pinned!(tmpl, supplement)
    refs = tmpl.behaviours_refs
```

(c) Insert right above the comment `# A 1.0 or 2.0 template -> the 2.0 shape; anything else raises naming the field.`:

```elixir
  @refs_behaviours [
    policy: Normandy.Behaviours.PolicyEngine,
    budget: Normandy.Behaviours.BudgetTracker,
    credential: Normandy.Behaviours.CredentialProvider,
    compactor: Normandy.Behaviours.Compactor,
    model_catalog: Normandy.Behaviours.ModelCatalog
  ]

  @pinnable [:policy, :budget, :credential, :compactor, :model_catalog, :hooks, :guardrails]

  @doc """
  Checks a template read from a session store before anything in it is used (see "Trust
  boundary"). `Turn.Server` calls it on every template it loads, and `rebuild/3` calls it
  first.

  Raises `ArgumentError` naming the field for a function, pid, reference or port anywhere
  in the template, a `behaviours_refs` slot that is not `{module, keyword}` or whose module
  is not loaded on this node or does not implement the slot's behaviour, and a guard in
  `guardrails` whose module does not implement `Normandy.Guardrails.Guard`. A missing or
  unknown field or slot is left to `rebuild/3`, which names it. Values are never shown.
  """
  @spec check_loaded!(map()) :: :ok
  def check_loaded!(tmpl) when is_map(tmpl) do
    id = Map.get(tmpl, :template_id)

    case Enum.find(Enum.sort(tmpl), fn {_key, value} -> not Hooks.plain_data?(value) end) do
      nil -> :ok
      {key, _} -> refused!(id, "#{inspect(key)} holds a function, pid, reference or port")
    end

    :ok = check_refs!(Map.get(tmpl, :behaviours_refs), id)
    check_guards!(Map.get(tmpl, :guardrails, []), id)
  end

  def check_loaded!(other) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.check_loaded!/1: expected a template map, got: " <>
            Describe.type_of(other)
  end

  defp check_refs!(refs, id) when is_map(refs) do
    Enum.each(@refs_behaviours, fn {slot, behaviour} ->
      case Map.fetch(refs, slot) do
        :error -> :ok
        {:ok, ref} -> check_ref!(slot, ref, behaviour, id)
      end
    end)
  end

  # Not a map: translate!/1 names it.
  defp check_refs!(_refs, _id), do: :ok

  defp check_ref!(slot, {mod, opts}, behaviour, id) when is_atom(mod) and is_list(opts) do
    unless Keyword.keyword?(opts),
      do: bad_ref!(slot, behaviour, id, "opts that are not a keyword list")

    unless implements?(mod, behaviour),
      do: bad_ref!(slot, behaviour, id, inspect(mod))

    :ok
  end

  defp check_ref!(slot, other, behaviour, id),
    do: bad_ref!(slot, behaviour, id, Describe.type_of(other))

  @spec bad_ref!(atom(), module(), term(), String.t()) :: no_return()
  defp bad_ref!(slot, behaviour, id, got) do
    refused!(
      id,
      "behaviours_refs #{inspect(slot)} must be {module, keyword} whose module is loaded on " <>
        "this node and implements #{inspect(behaviour)}, got: #{got}"
    )
  end

  defp check_guards!(guardrails, id) when is_list(guardrails) do
    for stage <- [:input, :output],
        {^stage, specs} <- guardrails,
        spec <- List.wrap(specs) do
      check_guard!(stage, spec, id)
    end

    :ok
  end

  defp check_guards!(other, id),
    do: refused!(id, ":guardrails must be a keyword list, got: #{Describe.type_of(other)}")

  defp check_guard!(stage, {mod, opts}, id) when is_atom(mod) and is_list(opts),
    do: check_guard!(stage, mod, id)

  defp check_guard!(stage, mod, id) when is_atom(mod) do
    unless implements?(mod, Normandy.Guardrails.Guard),
      do:
        refused!(
          id,
          ":guardrails #{inspect(stage)} guard #{inspect(mod)} is not loaded on this node or " <>
            "does not implement Normandy.Guardrails.Guard"
        )

    :ok
  end

  defp check_guard!(stage, other, id) do
    refused!(
      id,
      ":guardrails #{inspect(stage)} has a guard that is not a module or {module, opts}: " <>
        Describe.type_of(other)
    )
  end

  defp implements?(mod, behaviour) do
    Code.ensure_loaded?(mod) and
      behaviour in (mod.module_info(:attributes)
                    |> Keyword.get_values(:behaviour)
                    |> List.flatten())
  end

  @spec refused!(term(), String.t()) :: no_return()
  defp refused!(id, what) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.check_loaded!/1: template #{inspect(id)} #{what}; " <>
            "it is not used (see the Trust boundary section of Normandy.Agents.ConfigTemplate)"
  end

  @doc false
  # The supplement's :pinned against a template as stored: Turn.Server checks it before it
  # calls the template's credential provider, rebuild/3 again after translation.
  @spec check_pinned!(map(), map()) :: :ok
  def check_pinned!(tmpl, supplement), do: tmpl |> translate!() |> pinned!(supplement)

  defp pinned!(tmpl, supplement) do
    pinned = Map.get(supplement, :pinned, [])

    unless Keyword.keyword?(pinned) do
      raise ArgumentError,
            "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement's :pinned must be a " <>
              "keyword list, got: #{Describe.type_of(pinned)}"
    end

    Enum.each(pinned, fn {field, expected} ->
      unless field in @pinnable do
        raise ArgumentError,
              "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement pins #{inspect(field)}; " <>
                ":pinned takes #{Enum.map_join(@pinnable, ", ", &inspect/1)}"
      end

      if pinned_value(tmpl, field) != expected do
        raise ArgumentError,
              "Normandy.Agents.ConfigTemplate.rebuild/3: template #{inspect(tmpl.template_id)} " <>
                "has a #{inspect(field)} that differs from the one this node's supplement pins; " <>
                "it is not used (see the Trust boundary section of Normandy.Agents.ConfigTemplate)"
      end
    end)
  end

  defp pinned_value(tmpl, :guardrails),
    do: Map.get(tmpl, :guardrails, BaseAgentConfig.default_guardrails())

  defp pinned_value(tmpl, :hooks), do: Map.get(tmpl.behaviours_refs, :hooks, [])
  defp pinned_value(tmpl, slot), do: Map.fetch!(tmpl.behaviours_refs, slot)

```

Notes for the implementer: the plain-data check is per top-level field, so it names the
field (`:tool_context`, `:guardrails`, `:behaviours_refs`) and never the value; 1.x
templates pass (their only refs are Normandy's own behaviour modules, and the 1.x
`session_store`/`session_registry` slots are not in `@refs_behaviours`, so `translate!/1`
drops them as before). A 1.x `max_tokens: nil` and the compactor's `:max_tokens` are
translated before `pinned!/2` compares, so a pin is written in the 2.0 shape.

(d) In `lib/normandy/behaviours/agent_template.ex`, the moduledoc's first paragraph gets, after
`` `ConfigTemplate.rebuild/3` requires it when the original config had it set. ``:

```
  Optionally `:pinned`: the security settings this node fixes for the template,
  `[policy: ref, guardrails: list, credential: ref, ...]`. A stored template whose value
  differs is refused (see `Normandy.Agents.ConfigTemplate`'s "Trust boundary").
```

and the `supplement` type gets `optional(:pinned) => keyword()` after
`optional(:mcp_servers) => [term()]` (add the comma).

- [ ] **Step 5: `Turn.Server` checks before it uses the template**

In `lib/normandy/agents/turn/server.ex`:

(a) Moduledoc, `## Store unavailable`: after the paragraph about `{:invalid_hooks, message}`
(ending `` `:session_unavailable` `TurnError`. ``), append to that paragraph:

```
  So is a stored template that `Normandy.Agents.ConfigTemplate.check_loaded!/1` refuses,
  or whose security settings differ from the supplement's `:pinned`
  (`{:invalid_template, message}`): nothing in it is used, and its credential provider is
  not called.
```

(b) In `start_config/3`, the `with` becomes:

```elixir
        with {:ok, tmpl} <- load_config_template(store, template_provider, session_id),
             :ok <- check_loaded(tmpl),
             {:ok, config} <- reconstruct_config(tmpl, template_provider) do
```

(c) In `reconstruct_config/2`, replace the `with ... else ... end` with:

```elixir
    with {:supplement, {:ok, supplement}} <- {:supplement, tp_mod.fetch(tp_handle, template_id)},
         {:pinned, :ok} <- {:pinned, check_pinned(tmpl, supplement)},
         {:token, {:ok, token}} <- {:token, cred_mod.get_token(token_provider(tmpl), cred_opts)} do
      {:ok, ConfigTemplate.rebuild(tmpl, supplement, token)}
    else
      {:supplement, :error} -> {:error, {:no_template_supplement, template_id}}
      {:pinned, {:error, _} = error} -> error
      {:token, {:error, reason}} -> {:error, {:credential_unavailable, cred_mod, reason}}
    end
  end

  defp check_loaded(tmpl), do: check_template(fn -> ConfigTemplate.check_loaded!(tmpl) end)

  defp check_pinned(tmpl, supplement),
    do: check_template(fn -> ConfigTemplate.check_pinned!(tmpl, supplement) end)

  # A template the checks refuse is reported like a store fault: the server waits
  # :unavailable instead of crashing its start, and nothing in the template is used. The
  # message names fields and modules, never values.
  defp check_template(check) do
    check.()
  rescue
    e in ArgumentError -> {:error, {:invalid_template, Exception.message(e)}}
  end
```

(the `end` that closes `reconstruct_config/2` is the first `end` above). `check_pinned/2`
also runs `translate!/1`, so a template neither 1.0 nor 2.0 now waits `:unavailable` with
`{:invalid_template, message}` instead of raising inside `init/1`. `session_unavailable/1`'s
catch-all clause already wraps the reason as `%TurnError{type: :session_unavailable,
reason: {:invalid_template, message}}`, as it does `{:invalid_hooks, message}`.

- [ ] **Step 6: Existing tests that change**

- `test/agents/config_template_test.exs`: the round-trip `full_config/1` uses guards
  `SomeGuard`, `OtherGuard`, `OutGuard` that are not modules; `rebuild/3` now refuses them
  (the round-trip tests fail with `:guardrails :input guard SomeGuard is not loaded on this
  node ...`). Add after `defmodule OldStyleTool ... end`:

```elixir

  # rebuild/3 checks that a template's guards implement the Guard behaviour.
  defmodule SomeGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: :ok
  end

  defmodule OtherGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: :ok
  end

  defmodule OutGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: :ok
  end
```

  (Inside the test module these names resolve to the nested modules; "from_config refuses a
  function in guardrail options" still raises in `from_config/2`.)
- Same file, "rebuild refuses a template whose hook entries are malformed, naming the hook":
  the pid case is now refused by `check_loaded!/1` first. Replace

```elixir
      assert_raise ArgumentError, ~r/must be plain data/, fn ->
        ConfigTemplate.rebuild(bad.([{Normandy.Test.Hooks.Probe, notify: self()}]), supp, "T")
      end
```

  with

```elixir
      # check_loaded!/1 runs first and refuses the pid for the whole slot.
      assert_raise ArgumentError,
                   ~r/:behaviours_refs holds a function, pid, reference or port/,
                   fn ->
                     ConfigTemplate.rebuild(
                       bad.([{Normandy.Test.Hooks.Probe, notify: self()}]),
                       supp,
                       "T"
                     )
                   end
```

- `test/agents/turn/server_test.exs`, `describe "a thin start that cannot rebuild its config"`:
  `FailingCreds` declares no behaviour, so `check_loaded!/1` refuses it and the test gets
  `{:invalid_template, _}` instead of `{:credential_unavailable, FailingCreds, :vault_sealed}`.
  Make it:

```elixir
    defmodule FailingCreds do
      @behaviour Normandy.Behaviours.CredentialProvider
      @impl true
      def get_token(_provider, _opts), do: {:error, :vault_sealed}
    end
```

Every other behaviour module a test stores in a template already declares its behaviour
(`Normandy.Test.StubCreds`, `KeepLastCompactor`, `server_test.exs`'s `MemoCatalog`, the
`BlockAll` guard in `metadata_test.exs`, `e2e/13_budget_policy.exs`'s `E2E.S13.Budget`).
The 1.0 fixture (`config_template_v1_test.exs`) rebuilds unchanged.

- [ ] **Step 7: Guide**

In `docs/guides/distributed_sessions.md`, insert before `## Eager handoff (\`resume_policy: :eager\`)`:

````markdown
## The session store is a trust boundary

The template is non-secret, but it is not harmless: it names the policy, the guardrails,
the hooks, the credential provider, `tool_context` (the memory namespace) and the
`template_id` that picks the node's supplement and toolset, and the store also holds the
turn state (a call parked for approval, with its input) and the history. **Write access
to the session store is as powerful as a code deploy.** Keep the store single-tenant, or
give Normandy its own database role or ACL'd Redis key prefix; never share it with a
service you trust less than your code.

Every node checks a template before using it (`ConfigTemplate.check_loaded!/1`: plain
data only, behaviour modules that implement their behaviour), and a supplement can pin the
security settings so a tampered store cannot swap them:

```elixir
Catalog.put(cat, "support", %{
  toolset: toolset,
  before_hooks: [],
  after_hooks: [],
  client_builder: &MyApp.LLM.client/1,
  pinned: [
    policy: {Normandy.Behaviours.PolicyEngine.Ruleset, rules: rules, default_action: :deny},
    guardrails: guardrails,
    credential: {MyApp.VaultCreds, []}
  ]
})
```

A template that fails either check is never used: the server stays `:unavailable` and
`run/2` replies `{:error, %TurnError{type: :session_unavailable, reason: {:invalid_template,
message}}}`, without calling the template's credential provider. `tool_context`,
`template_id`, turn state and history cannot be pinned, and templates are not signed.

````

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test test/agents test/hooks test/integration test/telemetry/metadata_test.exs`
Expected: PASS.

- [ ] **Step 9: MIGRATING**

Append to `## 37. Security hardening` in `MIGRATING-2.0.md`:

```markdown
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
- New supplement key `:pinned`: `pinned: [policy: ref, guardrails: g, credential: ref]`
  (also `:budget`, `:compactor`, `:model_catalog`, `:hooks`). A stored template whose value
  differs is refused, before its credential provider runs. Templates are not signed.
```

- [ ] **Step 10: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.7c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.7c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

```bash
git add lib/normandy/behaviours/hooks.ex lib/normandy/agents/config_template.ex \
  lib/normandy/behaviours/agent_template.ex lib/normandy/agents/turn/server.ex \
  docs/guides/distributed_sessions.md MIGRATING-2.0.md \
  test/agents/config_template_trust_test.exs test/agents/config_template_test.exs \
  test/agents/turn/server_test.exs
git commit -m "feat(sessions)!: check stored templates on load; supplements pin security settings"
```

### Task 5.7d: Security LOW findings (SEC-10, SEC-11, SEC-12, SEC-13, SEC-15, SEC-16, SEC-17, SEC-18)

SEC-10's "Trust" sections landed in Task 5.7a (same moduledocs as the prefix docs); this task
pins them with a test. SEC-14 is not closed here: Task 6.5 owns "supervised `run_async`
limits" (`coordination/agent_process.ex:626,658`). SEC-15 gets documentation only, no tool
fingerprint (R9); its missing-tool half is already fixed (`Dispatch.execute_approved/3`
answers `not_found_result`).

**Files:**
- Modify: `lib/normandy/tools/executor.ex` (moduledoc, `execute_with_timeout/3`'s `rescue`, `describe_reason/1`, new `describe_exception/1`) (SEC-11, SEC-17)
- Modify: `lib/normandy/mcp/tool_wrapper.ex` (`run/2`'s error clause), `lib/normandy/a2a/agent_tool.ex` (`poll_for_result/4`, `run/2`) (SEC-11)
- Create: `lib/normandy/llm/client_inspect.ex`; Modify: `lib/normandy/llm/claudio_adapter.ex`, `lib/normandy/llm/openai_compatible_adapter.ex` (SEC-12; `base_url` userinfo, decision 23 B8)
- Modify: `lib/normandy/agents/turn/session.ex` (`:session_id` type, new `validate_session_id/1`) (SEC-13; its error describes the id by type, decision 23 B12)
- Modify: `lib/normandy/guardrails/builtins/semantic_scope.ex` (`check/3` and `classify/4`: a wrong-shaped return described by type, decision 23 B12)
- Modify: `lib/normandy/agents/dispatch.ex` (`execute_approved/3` `@doc`) (SEC-15)
- Modify: `lib/normandy/tools/memory/render.ex` (`file/4`, `cap/2`, new `truncation_note/3`) (SEC-16)
- Modify: `lib/normandy/tools/memory/commands.ex` (`text/3`, new `valid_text/3`) (SEC-18)
- Modify: `test/agents/turn/session_test.exs` (one broken interpolation)
- Modify: `MIGRATING-2.0.md` (`## 37.`)
- Test: create `test/security/low_findings_test.exs`

**Interfaces:**
- Consumes: `Describe.reason_tag/1` (Task 5.7b); the "Trust" moduledoc sections (Task 5.7a); `Turn.Server`'s `@session_types` (`server.ex:208-212`), which takes `:session_id`'s type from `Turn.Session.__opts_schema__(:new)`, so `Turn.Server.start_link/1` gets the new type with no change. Task 5.6 rewrote `ToolWrapper.run/2`'s success path (AX-14) and leaves Executor messages as they are (R8); Task 5.6b rewrote `Dispatch`'s result text; this task edits only `execute_approved/3`'s `@doc`, and in `run/2` only the clause that formats an `{:error, reason}` from `adapter.call_tool/4`.
- Produces: `Normandy.LLM.ClientInspect` (`@moduledoc false`; `base_url` and `options.base_url` printed as scheme, host, port and path, the rule of `CircuitBreaker`'s private `sanitize_url/1`, which is copied rather than reused because it is private; a URL with no scheme or host prints as `"**redacted**"` instead of the breaker's `nil`, so an inspect never reads as "unset"); `Turn.Session.validate_session_id/1` (`@doc false`, NimbleOptions custom type); memory error text ``"Error: `<key>` must not contain NUL characters"``; view truncation note `"[truncated inside line L of N: it is longer than the M-character view limit; use view_range [L+1, -1] to read on]"` (the `; use view_range ...` part only when `L < N`).

- [ ] **Step 1: Write the failing test**

Create `test/security/low_findings_test.exs` (decision 23 adds the SEC-12 `base_url` test, the SEC-13 message test and the `SemanticScope` describe):

```elixir
defmodule Normandy.Security.LowFindingsTest do
  # The security LOW findings closed in Task 5.7d, one describe each (security.md).
  use ExUnit.Case, async: true

  alias Claudio.A2A.AgentCard
  alias Normandy.A2A.AgentTool
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn.{Server, Session}
  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory, as: SessionInMemory
  alias Normandy.Guardrails.Builtins.SemanticScope
  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tool
  alias Normandy.Tools.{Context, Executor, Memory}

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(mod)
    String.replace(doc, ~r/\s+/, " ")
  end

  defp doc(mod, fun, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    Enum.find_value(docs, fn
      {{:function, ^fun, ^arity}, _, _, %{"en" => text}, _} -> String.replace(text, ~r/\s+/, " ")
      _ -> nil
    end)
  end

  describe "SEC-10: remote tools are documented as untrusted" do
    test "ToolWrapper, MCP.Registry and AgentTool say so" do
      assert moduledoc(ToolWrapper) =~ "## Trust"
      assert moduledoc(ToolWrapper) =~ "prompt-injection channel"
      assert moduledoc(AgentTool) =~ "## Trust"
      assert moduledoc(AgentTool) =~ "prompt-injection channel"
      assert moduledoc(Normandy.MCP.Registry) =~ "reaches the model unchanged"
    end
  end

  describe "SEC-11: error text names a reason's tag, never its terms" do
    defmodule BodyAdapter do
      @moduledoc false
      def call_tool(_client, _name, _args, _opts),
        do: {:error, {:unexpected_response, %{body: "SECRET-BODY"}}}
    end

    test "an MCP transport error" do
      wrapper =
        ToolWrapper.new(BodyAdapter, nil, %Claudio.MCP.Client.Tool{name: "t"}, prefix: false)

      assert Tool.run(wrapper, %Context{tool_call_id: "c", input: %{}}) ==
               {:error, "MCP tool 't' failed: :unexpected_response"}
    end

    test "an A2A transport error" do
      card = AgentCard.new("remote", "r")

      tool =
        AgentTool.new("http://127.0.0.1:1/a2a", card,
          prefix: "a2a",
          transport_opts: [transport: __MODULE__.FailingTransport]
        )

      assert Tool.run(tool, %Context{tool_call_id: "c", input: %{"message" => "hi"}}) ==
               {:error, "A2A request failed: :unexpected_response"}
    end

    defmodule FailingTransport do
      @moduledoc false
      def send_message(_endpoint, _message, _opts),
        do: {:error, {:unexpected_response, "SECRET-BODY"}}
    end

    defmodule RaisingTool do
      @moduledoc false
      use Normandy.Tool, name: "raising", description: "raises"
      defstruct [:fun]
      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}
      @impl Normandy.Tool
      def run(%__MODULE__{fun: fun}, _context), do: fun.()
    end

    defp run_raising(fun) do
      Executor.execute_tool(%RaisingTool{fun: fun},
        context: %Context{tool_call_id: "c", input: %{}}
      )
    end

    test "a KeyError names its key, never the map it searched" do
      assert run_raising(fn ->
               Map.fetch!(Function.identity(%{token: "SECRET-TOKEN"}), :missing)
             end) ==
               {:error, "Tool execution failed: KeyError: key :missing not found"}
    end

    test "an exception that inspects its term is named by module" do
      assert run_raising(fn -> {:ok, _} = Function.identity({:error, %{token: "SECRET"}}) end) ==
               {:error, "Tool execution failed: MatchError"}

      assert run_raising(fn -> Enum.count(Function.identity({:token, "SECRET"})) end) ==
               {:error, "Tool execution failed: Protocol.UndefinedError"}
    end

    test "other exceptions keep their message" do
      assert run_raising(fn -> raise ArgumentError, "bad level" end) ==
               {:error, "Tool execution failed: bad level"}
    end
  end

  describe "SEC-12: client inspect hides credential-bearing options" do
    test "req_options and headers are redacted on both adapters, api_key is left out" do
      options = %{
        req_options: [auth: {:bearer, "SECRET-AUTH"}],
        headers: [{"x-key", "SECRET-H"}],
        thinking: :adaptive
      }

      for client <- [
            %ClaudioAdapter{api_key: "SECRET-KEY", options: options},
            %OpenAICompatibleAdapter{api_key: "SECRET-KEY", options: options}
          ] do
        text = inspect(client)
        refute text =~ "SECRET"
        refute text =~ "api_key"
        assert text =~ ~s(req_options: "**redacted**")
        assert text =~ ~s(headers: "**redacted**")
        assert text =~ "thinking: :adaptive"
      end
    end

    # Decision 23 (B8): the userinfo, query and fragment of a base_url, as the shared
    # breaker's key leaves them out.
    test "a base_url prints without its userinfo, query or fragment" do
      url = "https://user:SECRET-PW@llm.example.com:8443/v1?key=SECRET-Q#SECRET-F"

      for client <- [
            %ClaudioAdapter{api_key: "k", base_url: url},
            %OpenAICompatibleAdapter{api_key: "k", base_url: url},
            %ClaudioAdapter{api_key: "k", options: %{base_url: url}}
          ] do
        text = inspect(client)
        refute text =~ "SECRET"
        refute text =~ "user:"
        assert text =~ ~s("https://llm.example.com:8443/v1")
      end

      assert inspect(%ClaudioAdapter{api_key: "k", base_url: "user:SECRET-PW@nohost"}) =~
               ~s(base_url: "**redacted**")
    end
  end

  describe "SEC-13: a session id cannot change the Redis hash tag" do
    defp session_opts(sid) do
      [
        session_id: sid,
        registry: {Native, nil},
        supervisor: self(),
        store: {SessionInMemory, nil},
        config: %BaseAgentConfig{}
      ]
    end

    test "an id with { or }, or an empty one, is refused" do
      for sid <- ["}x", "a{b", "a}b", ""] do
        assert_raise ArgumentError,
                     ~r/Turn.Session.new\/1: invalid value for :session_id option/,
                     fn ->
                       Session.new(session_opts(sid))
                     end
      end

      assert %Session{session_id: "user-42"} = Session.new(session_opts("user-42"))
    end

    # Decision 23 (B12): the refused id is described by type, never echoed.
    test "the error names the id's type, not the id" do
      error = assert_raise ArgumentError, fn -> Session.new(session_opts("SECRET-ID{x}")) end
      refute error.message =~ "SECRET"
      assert error.message =~ "got: a string (12 bytes)"
    end

    test "Turn.Server.start_link/1 takes the same type" do
      assert_raise ArgumentError,
                   ~r/Turn.Server.start_link\/1: invalid value for :session_id option/,
                   fn ->
                     Server.start_link(
                       session_id: "}x",
                       store: {SessionInMemory, nil},
                       registry: {Native, nil}
                     )
                   end
    end
  end

  # Decision 23 (B12): a wrong-shaped host return is described by type, never echoed.
  describe "SemanticScope: a wrong-shaped return is described by type" do
    test "the fast_path's and the classifier's return values are not in the message" do
      fast_path = [classifier: fn _v, _c -> :allow end, fast_path: fn _v, _c -> "SECRET-1" end]
      error = assert_raise ArgumentError, fn -> SemanticScope.check("q", fast_path) end
      refute error.message =~ "SECRET"
      assert error.message =~ "got: a string (8 bytes)"

      classifier = [classifier: fn _v, _c -> {:block, "SECRET-2"} end]
      error = assert_raise ArgumentError, fn -> SemanticScope.check("q", classifier) end
      refute error.message =~ "SECRET"
      assert error.message =~ "got: a tuple"
    end
  end

  describe "SEC-15 and SEC-17: documented limits" do
    test "an approved call runs whatever tool now holds the name" do
      assert doc(Normandy.Agents.Dispatch, :execute_approved, 3) =~
               "the approved call runs whatever tool now holds the name"
    end

    test "Executor says it applies no controls" do
      assert moduledoc(Executor) =~ "## No controls"
      assert moduledoc(Executor) =~ "no policy, no approval, no hooks, no budget"
    end
  end

  describe "SEC-16: max_view_chars is a hard cap" do
    test "a single 100 KB line views in at most max_view_chars plus the note" do
      store = InMemory.new()

      {:ok, _} =
        InMemory.put(store, "ns", "/memories/big.md", String.duplicate("é", 100_000), :new)

      tool = Memory.new(store: {InMemory, store}, max_view_chars: 1_000)

      assert {:ok, text} =
               Memory.run(tool, %Context{
                 tool_call_id: "c",
                 values: %{memory_namespace: "ns"},
                 input: %{"command" => "view", "path" => "/memories/big.md"}
               })

      [header, body, note] = String.split(text, "\n")
      assert header == "Here's the content of /memories/big.md with line numbers:"
      assert String.length(body) == 1_000
      assert String.valid?(body)

      assert note ==
               "[truncated inside line 1 of 1: it is longer than the 1000-character view limit]"
    end

    test "a long first line followed by more lines points at the next one" do
      store = InMemory.new()
      content = String.duplicate("x", 50) <> "\nsecond\n"
      {:ok, _} = InMemory.put(store, "ns", "/memories/two.md", content, :new)
      tool = Memory.new(store: {InMemory, store}, max_view_chars: 20)

      assert {:ok, text} =
               Memory.run(tool, %Context{
                 tool_call_id: "c",
                 values: %{memory_namespace: "ns"},
                 input: %{"command" => "view", "path" => "/memories/two.md"}
               })

      assert text =~
               "\n[truncated inside line 1 of 2: it is longer than the 20-character view " <>
                 "limit; use view_range [2, -1] to read on]"
    end
  end

  describe "SEC-18: NUL in memory content is refused on every backend" do
    test "create, str_replace and insert refuse NUL with :invalid_input" do
      store = InMemory.new()
      tool = Memory.new(store: {InMemory, store})

      ctx = fn input ->
        %Context{tool_call_id: "c", values: %{memory_namespace: "ns"}, input: input}
      end

      assert Memory.run(
               tool,
               ctx.(%{"command" => "create", "path" => "/memories/a", "file_text" => "a\0b"})
             ) ==
               {:error, "Error: `file_text` must not contain NUL characters"}

      {:ok, _} =
        Memory.run(
          tool,
          ctx.(%{"command" => "create", "path" => "/memories/a", "file_text" => "ab"})
        )

      assert Memory.run(
               tool,
               ctx.(%{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "a",
                 "new_str" => "\0"
               })
             ) ==
               {:error, "Error: `new_str` must not contain NUL characters"}

      assert Memory.run(
               tool,
               ctx.(%{
                 "command" => "insert",
                 "path" => "/memories/a",
                 "insert_line" => 0,
                 "insert_text" => "\0"
               })
             ) ==
               {:error, "Error: `insert_text` must not contain NUL characters"}

      assert {:ok, %{content: "ab"}} = InMemory.get(store, "ns", "/memories/a")
    end
  end
end
```

(`Function.identity/1` keeps the compiler's type checker from flagging the deliberately
failing `Map.fetch!`/match, which `mix test --warnings-as-errors` in `mix precommit` would
reject. SEC-18 is tested on `InMemory`: the rule lives in `Commands`, before any store call,
so it holds for every backend.)

- [ ] **Step 2: Run it to verify it fails**

Run: `mix format && mix test test/security/low_findings_test.exs`
Expected: FAIL, 15 of 17 tests (measured for decision 23 on 5.7c's `lib`): SEC-11 (the
reasons are `inspect`ed; the KeyError shows the map), SEC-12 (`SECRET-AUTH` printed; the
`base_url` printed with its userinfo), SEC-13 (the ids are accepted, so no error message
either), SEC-15/SEC-17 (doc text absent), SEC-16 (the 100 KB line comes back whole), SEC-18
(the NUL is stored), `SemanticScope` (the return values are `inspect`ed). SEC-10 passes (Task
5.7a).

- [ ] **Step 3: SEC-11 and SEC-17, `Executor`**

In `lib/normandy/tools/executor.ex`:

(a) Moduledoc: replace the last paragraph (`Error messages reach the model as tool results, ...
message is cut to 500 characters.`) with:

```
  Error messages reach the model as tool results, so an exit or throw is named
  by its tag only (its terms can carry call arguments), an exception whose message
  shows the term it failed on (`KeyError`, `MatchError`, `CaseClauseError`,
  `Protocol.UndefinedError`, ...) is named by its module (a `KeyError` also by its key),
  and any other exception message is cut to 500 characters.

  ## No controls

  `execute_tool/2` and `execute_tool_classified/2` run the tool and nothing else: no
  policy, no approval, no hooks, no budget and no input validation. The agent loop runs
  tools through `Normandy.Agents.Dispatch`, which applies all of them; call these only for
  a tool and an input you have already checked.
```

(b) In `execute_with_timeout/3`, the `rescue` clause becomes:

```elixir
          error ->
            {{:error, "Tool execution failed: #{describe_exception(error)}"}, :exception}
```

(c) Replace the three `describe_reason/1` clauses with:

```elixir
  defp describe_reason(reason), do: Describe.reason_tag(reason)

  # Exceptions whose message inspects the term they failed on, which can be a struct
  # holding a token or the tool's whole input: named by module (and a KeyError's key).
  @term_exceptions [
    BadArityError,
    BadBooleanError,
    BadFunctionError,
    BadMapError,
    BadStructError,
    CaseClauseError,
    MatchError,
    Protocol.UndefinedError,
    TryClauseError,
    WithClauseError
  ]

  defp describe_exception(%KeyError{key: key}),
    do: "KeyError: key #{inspect(key, limit: 5, printable_limit: 50)} not found"

  defp describe_exception(%mod{}) when mod in @term_exceptions, do: inspect(mod)
  defp describe_exception(error), do: error |> Exception.message() |> truncate()
```

`Describe.reason_tag/1` is the old `describe_reason/1` rule plus one clause: an exception
struct thrown or used as an exit reason is now named by its module (`"KeyError"`) rather
than `"a %KeyError{}"`. `FunctionClauseError` stays out of the list: its message names the
function, not the arguments.

- [ ] **Step 4: SEC-11, MCP and A2A reasons**

`lib/normandy/mcp/tool_wrapper.ex` already aliases `Describe` (Task 5.7a). In `run/2`, the
clause that formats an `{:error, reason}` returned by `adapter.call_tool/4` (today
`{:error, reason} -> {:error, "MCP tool '#{tool.name}' failed: #{inspect(reason)}"}`) becomes:

```elixir
      # The reason's tag only: a transport error can carry the response body the server sent.
      {:error, reason} -> {:error, "MCP tool '#{tool.name}' failed: #{Describe.reason_tag(reason)}"}
```

(If Task 5.6 reworded that string, keep its wording and replace only `inspect(reason)`.)

In `lib/normandy/a2a/agent_tool.ex`, add `alias Normandy.Components.ContentBlock.Describe`
above `alias Normandy.Options`; in `poll_for_result/4`,
`{:error, "Failed to get task status: #{inspect(reason)}"}` becomes
`{:error, "Failed to get task status: #{Describe.reason_tag(reason)}"}`; in `run/2`, the
`{:error, reason}` clause becomes:

```elixir
      {:error, reason} ->
        # The reason's tag only: a transport error can carry the body the remote sent.
        {:error, "A2A request failed: #{Describe.reason_tag(reason)}"}
```

Check: `grep -n "inspect(reason)" lib/normandy/mcp/tool_wrapper.ex lib/normandy/a2a/agent_tool.ex` prints nothing.

(Decision 23, B12.) In `lib/normandy/guardrails/builtins/semantic_scope.ex`, add
`alias Normandy.Components.ContentBlock.Describe` above `alias Normandy.Guardrails.Builtins.Field`.
In `check/3`, the `other ->` clause's message becomes

```elixir
              "#{inspect(__MODULE__)} :fast_path must return :admit or :needs_classifier, " <>
                "got: " <> Describe.type_of(other)
```

and in `classify/4`, the `other ->` clause's message becomes

```elixir
              "#{inspect(__MODULE__)} :classifier must return :allow or {:block, reason} " <>
                "(reason an atom), got: " <> Describe.type_of(other)
```

(A host's return can be the classified text or a reason string: `{:block, "..."}` now reads
`got: a tuple`, so the message names the atom rule.) `semantic_scope_test.exs` matches only
`~r/:fast_path/` and `~r/:classifier/` and stays green.

- [ ] **Step 5: SEC-12, client `Inspect`**

Create `lib/normandy/llm/client_inspect.ex` (`url/1` is decision 23's B8):

```elixir
defmodule Normandy.LLM.ClientInspect do
  @moduledoc false
  # The Inspect implementation of Normandy's client structs: `api_key` is left out, and the
  # `options` that can carry credentials (`:req_options`, whose `auth:` and headers go to
  # Req, and `:headers`) are shown as "**redacted**". A `base_url` (the struct field, or
  # `options.base_url`) is shown as scheme, host, port and path only, as
  # Normandy.Resilience.CircuitBreaker keys it: its userinfo, query and fragment can carry
  # a token. A crash report or a log line that inspects a config then shows no credential.

  import Inspect.Algebra

  @redacted_options [:req_options, :headers]

  @spec inspect(struct(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(%mod{} = client, opts) do
    fields = [
      __meta__: client.__meta__,
      base_url: url(client.base_url),
      options: redact(client.options),
      finch: client.finch
    ]

    container_doc("#" <> Kernel.inspect(mod) <> "<", fields, ">", opts, &field/2,
      separator: ",",
      break: :strict
    )
  end

  defp field({key, value}, opts), do: concat([Atom.to_string(key), ": ", to_doc(value, opts)])

  defp redact(options) when is_map(options) do
    Map.new(options, fn
      {key, _value} when key in @redacted_options -> {key, "**redacted**"}
      {:base_url, value} -> {:base_url, url(value)}
      entry -> entry
    end)
  end

  defp redact(options), do: options

  # CircuitBreaker's sanitize_url/1 rule (scheme, host, port, path). A URL with no scheme
  # or host is not shown at all.
  defp url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, path: path}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        port = if port in [nil, URI.default_port(scheme)], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port}#{path}"

      _no_scheme_or_host ->
        "**redacted**"
    end
  end

  defp url(other), do: other
end
```

In both `lib/normandy/llm/claudio_adapter.ex` and `lib/normandy/llm/openai_compatible_adapter.ex`:
delete the line `@derive {Inspect, except: [:api_key]}` above `schema do`, and insert right
before `defimpl Normandy.Agents.Model do`:

```elixir
  # Hides api_key and the credential-bearing options (Normandy.LLM.ClientInspect).
  defimpl Inspect do
    alias Normandy.LLM.ClientInspect

    def inspect(client, opts), do: ClientInspect.inspect(client, opts)
  end

```

The output keeps the derived format (`#Normandy.LLM.ClaudioAdapter<__meta__: ..., base_url: ...,
options: %{req_options: "**redacted**", ...}, finch: nil>`, without the trailing `...`), so
`claudio_adapter_test.exs` "Inspect protocol" still passes.

- [ ] **Step 6: SEC-13, session ids**

In `lib/normandy/agents/turn/session.ex`, the `session_id:` schema entry becomes:

```elixir
            session_id: [
              type: {:custom, __MODULE__, :validate_session_id, []},
              type_doc: "`t:String.t/0`",
              required: true,
              doc:
                "The session's id: its key in the registry and in the store. A non-empty " <>
                  "string without `{` or `}` (the Redis stores put it inside a cluster hash tag)."
            ],
```

and above `@doc false` / `def validate_config(` add:

```elixir
  @doc false
  # Redis keys put the id inside a cluster hash tag ("ns:{id}:stream"): a brace in it, or
  # an empty id, would change which part of the key Redis hashes.
  @spec validate_session_id(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_session_id(id) when is_binary(id) and id != "" do
    if String.contains?(id, ["{", "}"]),
      do: {:error, "expected a session id without { or }, got: " <> Describe.type_of(id)},
      else: {:ok, id}
  end

  def validate_session_id(other),
    do: {:error, "expected a non-empty string, got: " <> Describe.type_of(other)}

```

The Redis key format is unchanged, so no stored session is orphaned.

`test/agents/turn/session_test.exs`, "concurrent ensure-server for one session resolves to a
single pid (Horde via)": its id is the literal `"race-\#{System.unique_integer([:positive])}"`
(an escaped interpolation, so every run used the same id containing `{` and `}`). It becomes
`"race-#{System.unique_integer([:positive])}"`.

- [ ] **Step 7: SEC-15, approvals**

In `lib/normandy/agents/dispatch.ex`, append to `execute_approved/3`'s `@doc` (after the
sentence ending `through the \`after_tool\` slot.`):

```

  The approval covers the call's name and input, not the tool's code: after a redeploy, or
  a supplement that registers another tool under that name, the approved call runs
  whatever tool now holds the name. To bind an approval to one implementation, version
  the tool's name (`"refund_v2"`) when its behaviour changes.
```

- [ ] **Step 8: SEC-16, a hard view cap**

In `lib/normandy/tools/memory/render.ex`:

(a) In `file/4`, replace

```elixir
      note =
        if cut_after,
          do:
            "\n[truncated at line #{cut_after} of #{n}; use view_range [#{cut_after + 1}, -1] to read on]",
          else: ""
```

with `note = truncation_note(cut_after, n, max_chars)`.

(b) Replace `cap/2` with:

```elixir
  # Whole lines while they fit; a first line longer than max_chars is cut on a grapheme
  # boundary, so the view is never longer than max_chars plus the note.
  defp cap(shown, max_chars) do
    Enum.reduce_while(shown, {[], 0, nil}, fn {line, i}, {acc, used, _} ->
      text = numbered(i, line)
      used = used + String.length(text) + 1

      cond do
        used <= max_chars -> {:cont, {[text | acc], used, nil}}
        acc != [] -> {:halt, {acc, used, i - 1}}
        true -> {:halt, {[String.slice(text, 0, max_chars)], used, {:inside, i}}}
      end
    end)
    |> then(fn {acc, _used, cut} -> {acc |> Enum.reverse() |> Enum.join("\n"), cut} end)
  end

  defp truncation_note(nil, _n, _max_chars), do: ""

  defp truncation_note({:inside, line}, n, max_chars) when line < n,
    do:
      "\n[truncated inside line #{line} of #{n}: it is longer than the #{max_chars}-character " <>
        "view limit; use view_range [#{line + 1}, -1] to read on]"

  defp truncation_note({:inside, line}, n, max_chars),
    do:
      "\n[truncated inside line #{line} of #{n}: it is longer than the #{max_chars}-character " <>
        "view limit]"

  defp truncation_note(cut_after, n, _max_chars),
    do:
      "\n[truncated at line #{cut_after} of #{n}; use view_range [#{cut_after + 1}, -1] to read on]"
```

The whole-line note is unchanged (the existing `memory_test.exs` truncation test still
passes). The directory listing stays uncapped here: it is at most `MemoryStore.list_limit()`
(1000) rows two levels deep, and Task 5.4a's tool-result cap bounds every result.

- [ ] **Step 9: SEC-18, NUL in memory content**

In `lib/normandy/tools/memory/commands.ex`, `text/3`'s binary clause
`s when is_binary(s) -> if String.valid?(s), do: {:ok, s}, else: bad_text(key, loc)` becomes
`s when is_binary(s) -> valid_text(s, key, loc)`, and after `text/3` add:

```elixir

  # NUL is valid UTF-8, but a Postgres text column refuses it: every backend refuses it here
  # so the model gets the same answer from all of them, not a backend outage.
  defp valid_text(s, key, loc) do
    cond do
      not String.valid?(s) ->
        bad_text(key, loc)

      String.contains?(s, <<0>>) ->
        {:error, :invalid_input, "Error: `#{key}` must not contain NUL characters"}

      true ->
        {:ok, s}
    end
  end
```

`text/3` reads `file_text`, `old_str`, `new_str` and `insert_text`, all before any store call.
Paths already refuse control characters (`paths.ex:24`).

- [ ] **Step 10: Run the tests to verify they pass**

Run: `mix format && mix test test/security test/tools test/llm test/agents/turn test/mcp test/a2a`
Expected: PASS.

- [ ] **Step 11: MIGRATING**

Append to `## 37. Security hardening` in `MIGRATING-2.0.md`:

```markdown
- `Turn.Session.new/1` and `Turn.Server.start_link/1` refuse an empty `session_id` or one
  containing `{` or `}` (the Redis stores put the id inside a cluster hash tag). Key formats
  are unchanged.
- Tool error text sent to the model no longer quotes remote data or exception terms: an MCP
  or A2A transport error is named by its tag (`"MCP tool 'search' failed:
  :unexpected_response"`), and a tool that raises `KeyError` gives `"Tool execution failed:
  KeyError: key :x not found"` (no map), `MatchError`, `CaseClauseError`,
  `Protocol.UndefinedError` and the other exceptions whose message shows a term give their
  module only.
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
```

- [ ] **Step 12: Gate and commit**

Run: `mix precommit 2>&1 | tee /tmp/w5-5.7d.log; grep -E " [0-9]+ failures|Total errors" /tmp/w5-5.7d.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. (`mix precommit` runs the tests with
`--warnings-as-errors`; keep `Function.identity/1` in the deliberately failing calls.)

```bash
git add lib/normandy/tools/executor.ex lib/normandy/mcp/tool_wrapper.ex \
  lib/normandy/a2a/agent_tool.ex lib/normandy/llm/client_inspect.ex \
  lib/normandy/llm/claudio_adapter.ex lib/normandy/llm/openai_compatible_adapter.ex \
  lib/normandy/agents/turn/session.ex lib/normandy/agents/dispatch.ex \
  lib/normandy/tools/memory/render.ex lib/normandy/tools/memory/commands.ex \
  lib/normandy/guardrails/builtins/semantic_scope.ex \
  MIGRATING-2.0.md test/security/low_findings_test.exs test/agents/turn/session_test.exs
git commit -m "fix(security): bounded error text, redacted client inspect, session ids, view cap"
```

## Findings closed by 5.7 and not closed

- Closed: SEC-2 (5.7a), SEC-4, SEC-7, SEC-9 (5.7b), SEC-8 as ruled in R9 (5.7c), SEC-10
  (docs in 5.7a, test in 5.7d), SEC-11, SEC-12, SEC-13, SEC-15 (docs; the missing-tool case
  was fixed earlier), SEC-16, SEC-17 (docs; the registry-based `execute/3` family was removed
  in Wave 3), SEC-18 (5.7d). The A2A sibling of SEC-2 (remote-chosen card names, inventory
  Surprise 11) is closed in 5.7a.
- Not closed here: SEC-14 (Task 6.5), SEC-8 Option B (HMAC-signed templates: a known limit;
  turn state and history would stay unprotected even with it), SEC-15's tool fingerprint
  (R9), a per-guard `:timeout` (R9), a cap on the memory tool's directory listing (bounded by
  Task 5.4a's result cap).

---

### Task 5.8: Wave gate and records (controller)

**Files:**
- Modify: `test/agents/base_agent_stream_errors_test.exs` (the flake), `.dialyzer_ignore.exs` (reasons check only)
- Modify: `CLAUDE.md` (only with Q's approval of Appendix A's proposed text)
- Modify: `investigations/pre-2.0-audit/decisions.md` (progress bullet)

- [ ] **Step 1: Fix the known flake.** `base_agent_stream_errors_test.exs:149` asserts on captured `[error]` log text, and `capture_log/1` captures logs from every process, so `[error]` lines emitted on purpose by concurrent async tests (`turn_error_test.exs`, an orchestration test using `TaggingClient`) land in its capture. Read the test, then make its assertion independent of other tests' logs: assert on a line that only this test's run can produce (match the test's unique agent name or turn id in the captured text) instead of on the absence or presence of any `[error]` line. Do not make the file `async: false` unless the assertion cannot be made specific; record which fix was used. Verify by running `for i in $(seq 1 5); do mix test test/agents/base_agent_stream_errors_test.exs test/agents/turn_error_test.exs; done` and one full `mix test`, each with ` 0 failures`.
- [ ] **Step 2: Dialyzer ignores.** The stacked preflight ended at 36 skipped (Wave 4: 33). Check each new entry in `.dialyzer_ignore.exs` carries a reason comment (CLAUDE.md rule), and that `Unnecessary Skips: 0`.
- [ ] **Step 3: Full gate on the real branch** (use `caffeinate -i -s`; tee every log):
  - `mix precommit` → ` 0 failures`, credo "found no issues", dialyzer `Unnecessary Skips: 0`.
  - `mix docs --warnings-as-errors` → exit 0.
  - `mix test.redis` → ` 0 failures`.
  - Postgres: `docker start normandy-test-pg`; the database is the partition database `normandy_test_w54probe` (decision 23, Appendix B item B4), with the environment Task 5.4's writer used (Appendix A, "Task 5.4"): `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` → ` 0 failures` (its `ecto.create --quiet`/`ecto.migrate --quiet` find the database existing and migrate it if needed; nothing is dropped); then the distributed suite twice, in CI's form with `epmd` up (`NORMANDY_REDIS=true MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres --only distributed`) → ` 0 failures` both times; `docker stop normandy-test-pg`. Never drop a database here: dropping `normandy_test_w54probe` (or the stale `normandy_test`) needs Q's yes.
  - `mix hex.build --unpack` into the scratchpad → no warnings.
- [ ] **Step 4: CLAUDE.md.** Apply the Appendix A proposals Q approved, merged into one coherent edit per section (5.1, 5.2 and 5.3a each propose a `request_messages/1` line — keep one).
- [ ] **Step 5: Records.** Append a "Wave 5" progress bullet to `decisions.md` (commits, per-task review verdicts, gate numbers, deferred items: AX-12, AX-18 retry, AX-19, AX-20, AX-29, AX-33, SEC-8 HMAC signing, SEC-14 → Task 6.5, Turn.Server compaction persistence → Wave 6, unrepaired `server_tool_use` after a failed pause → Wave 6, Task 7.6 live checks listed in Appendix B item B13). Commit `decisions.md` and `CLAUDE.md` separately, files added individually, no AI attribution.

---

## Appendix B: items for Q's review

Rulings made during the integrated preflight, writer assumptions not covered by `QUESTIONS.md`, and steps that need Q. Each has a recommendation; the plan text implements the **current** behaviour column, so an override is a small edit to the named task. Q decided every item on 2026-10-06 (decision 23); the "Current plan text" column now says where each change was applied.

| # | Item | Current plan text | Recommendation | Cost if wrong |
|---|---|---|---|---|
| B1 | A `pause_turn` on the forced-final call (X1, 5.2b) | **Applied in Task 5.2b** (decision 23): after the 3rd continuation, `{:error, %LLMError{type: :pause_turn}}` on every path | **Change:** after the 3rd, return `{:error, %LLMError{type: :pause_turn}}` (new type, `retryable?: false`), consistent with R4: an incomplete answer is never a success | Keeping it: a partial answer presented as success, rare (needs 4 pauses on one call) |
| B2 | How the 3 final-call continuations are counted (X1) | **Applied in Task 5.2b** (decision 23): private `%Turn.State{}` field `final_pauses`; `iterations_left` never below 0 (Task 5.5b's Step 6(a) adjusted) | **Change:** a private `%Turn.State{}` field `final_pauses` counts them; `iterations_left` never goes below 0 | Keeping it: a public value with a meaning hosts must special-case |
| B3 | Two shapes for "the tool's output could not be sent" (5.6b-i) | **Applied in Task 5.6b-i** (decision 23): both bare | **Change:** both bare (one line in `unencodable_output/1` plus its test) | Keeping it: two shapes for one failure class |
| B4 | Postgres test database for the 5.4b gate | **Partition database `normandy_test_w54probe` (decision 23)**: Task 5.8 Step 3 names it; nothing is dropped without asking Q | Your choice: (a) drop and re-migrate the default `normandy_test` database (stale: no `normandy_memory_namespaces` table; unreleased migration changed in place), or (b) keep using the partition database `normandy_test_w54probe`. Either way, the probe database is dropped after the wave (`MIX_TEST_PARTITION=_w54probe MIX_ENV=test POSTGRES_PORT=55432 mix ecto.drop`) only on your yes | (a) destroys local test data only; (b) leaves plain `mix test.postgres` broken locally until (a) |
| B5 | AX-31 (MCP names vs the API's name limits) | Closed as "refused at registration" (`{:error, {:invalid_tool_name, name}}`), documented in `ToolWrapper` | Keep | Sanitizing would rename tools in ways policy rules can't predict |
| B6 | Summarizer choices (5.5a) | Tool results capped at 4000 graphemes in the transcript; failed results read `Tool error (<name>): ...`; summary framed as "The earlier part of this conversation was summarized automatically to save space. The summary is context, not a new message." inside `<conversation_summary>` tags | Keep | Wording only |
| B7 | Server-built results with no `after_tool` hook skip the cap (5.4a) | Not capped (fixed text < 200 chars) | Keep | Matters only for a per-tool cap under 200 |
| B8 | `Inspect` of a client prints `base_url` userinfo (5.7d) | **Applied in Task 5.7d** (decision 23): userinfo, query and fragment stripped | **Change:** strip userinfo as `CircuitBreaker.sanitize_url/1` already does | Keeping it: a URL-embedded password can reach logs |
| B9 | `request_messages/1` folds **any** user text following tool results (H4) | General rule (also `after_compact` injections) | Keep | Narrowing means `AgentMemory` depends on a Turn constant |
| B10 | The final call's tool calls from a client that ignores `tool_choice: none` (5.2b) | Ignored; the text is converted | Keep | An error would fail turns on non-Claudio clients |
| B11 | First turn after upgrading: schemas change shape (`property_order`, no empty descriptions, ordered properties) so replayed thinking's prefix key differs once (5.6c) | **Applied in Task 5.6c** (decision 23): MIGRATING §36 bullet; thinking stored before the upgrade is left out of requests | Keep, with a MIGRATING §36 line (add it in 5.6c) | Thinking stored before the upgrade is left out of every later request (memory keeps it); the model loses that reasoning for the rest of the session |
| B12 | Existing `SemanticScope` `ArgumentError` inspects a wrong-shaped classifier return; `validate_session_id/1` inspects the rejected id (5.7) | **Applied in Task 5.7d** (decision 23): both described by type | **Change** both to describe by type (`ContentBlock.Describe.type_of/1`), in 5.7d | A host value in an error text |
| B13 | Live checks deferred to Task 7.6 | — | Add to Task 7.6: tools + `output_config.format` with thinking (5.1); paused turn as last message (5.3c); final call with `tool_choice: none`, preserved thinking and the notice block (5.2b); `tool_choice` refused without tools (5.2b); a `tool_use` in history whose name left `tools` after a prefix change (5.7a); real two-connection Postgres cap contention (5.4b) | — |
| B14 | Proposed CLAUDE.md text (Appendix A, per task) | Not applied | Approve per section; Task 5.8 Step 4 applies it | Stale CLAUDE.md lines |
| B15 | The scratch worktree `w5-preflight` (branch `w5-preflight`, 18 commits on `0dccd48`) used to verify this plan | **Approved** (decision 23); the controller removes both before execution | Remove the worktree and delete the branch now (`git worktree remove`, `git branch -D w5-preflight`) | None: every correction is in this plan's text |

**Verified before execution (2026-10-06):** every task's code in this plan was applied in task order to a scratch worktree of `0dccd48` (branch `w5-preflight`, one commit per task, 18 commits) and run. Each task passed `mix precommit` with 0 failures, credo and dialyzer clean, and `mix docs --warnings-as-errors` exit 0; 30 text corrections and 5 rulings from that run are already in this text (record: `wave-5-sections/PREFLIGHT.md`). Final stacked gate on `7b4d9b4`: `mix precommit` 72 doctests, 28 properties, 3356 tests, 0 failures, credo no issues, dialyzer 36 skipped / 0 unnecessary; `mix docs --warnings-as-errors` exit 0; `mix test.redis` 3431 tests, 0 failures; `mix test.postgres` (probe database `normandy_test_w54probe`) 3415 tests, 0 failures; distributed suite 68 tests, 0 failures on two runs; `mix hex.build --unpack` clean. Not run: live API calls (Appendix B item B13).

**Decision 23 amendments verified (2026-10-06):** B1/B2 (Task 5.2b), B3 (5.6b-i), B11 (5.6c), B8 and B12 (5.7d) and the Task 5.5b Step 6(a) adjustment were applied to `w5-preflight` as one commit on `7b4d9b4`, `02d0ac7` ("preflight: decision 23 amendments"). `mix precommit`: 72 doctests, 28 properties, 3361 tests, 0 failures (222 excluded), exit 0, credo "found no issues", dialyzer 36 skipped / 0 unnecessary; `mix docs --warnings-as-errors` exit 0. Position checks on trees exported from the preflight commits: 5.2b's amended text on `564212d` (Step 8 1338 tests, `mix precommit` 3199 tests, both 0 failures; Step 2 29 failures), 5.5b's Step 6(a) perl on that text (12 hits, none negative; the result equals the stacked files), 5.6b-i's on `ab10bb1` (its Step 5 run 373 tests and `mix test` 3279 tests, 0 failures; Step 2 33 failures), 5.7d's Step 2 on 5.7c's `lib` (15 of 17 fail). Redis, Postgres and distributed suites were not re-run for the amendments (no store or backend code changed). Record: `wave-5-sections/PREFLIGHT.md`, "Decision 23 amendments".


## Appendix A: section writers' notes (verbatim)

### Tasks 5.1, 5.3

**What was verified.** All four tasks were applied in order to a scratch worktree at
`0dccd48`. Each task's tests failed for the reason its Step 2 gives and passed after
implementation. One exception: `stream/3`'s MCP test in 5.3a was already passing before the
change, as Step 2 says. With all four applied: `mix precommit` → `72 doctests, 28 properties,
3152 tests, 0 failures (203 excluded)`, credo "found no issues", dialyzer "done (passed
successfully)". `mix docs --warnings-as-errors` exited 0. The worktree was removed. Not run:
Postgres or Redis suites (no `MemoryStore` or `SessionStore` code changed) and live API calls.

**Risks and things not verifiable offline.**
1. **Tools plus `output_config.format` in one live request** is exercised only against the
   scripted plug. Claudio's builder accepts it (`claudio_request_capabilities_test.exs:9-25`),
   but the API's acceptance (Opus 5.5 with thinking, tools and a format) belongs in Task 7.6's
   live run.
2. **A paused turn as the last message.** The `pause_turn` continuation sends the paused
   assistant turn last. That is the documented continuation pattern, but it is unverified
   live with `thinking` on Opus 5.5 / Fable 5.1. Add it to Task 7.6.
3. **A session that fails right after a pause.** The store then ends with a paused assistant
   turn whose `server_tool_use` has no result, followed by the next user message.
   `Turn.unanswered_tool_calls/1` does not cover server blocks. Whether the API rejects that is
   unverified. It is a candidate for Wave 6's repair work.
4. **Stream fallback telemetry.** `stream/3`'s 400-and-resend happens inside one
   `[:normandy, :llm, :request]` span: BaseAgent opens one span per stream attempt, and the
   adapter emits none for streams. The sync path's resend gets its own `:structured_fallback`
   span. This is a known telemetry asymmetry. It is documented nowhere yet, so the gate task
   could add a line to the `Normandy.Telemetry` "known limits".
5. **`structured_output` metadata** now depends on `output_format`. `Telemetry.Provider` builds
   a throwaway `%Request{}` to ask the adapter, so the metadata and the routing cannot diverge.
   Any later task that changes the routing rules changes the metadata with them.

**Interplay with later tasks (for 5.2's writer).**
- 5.2b's forced final call uses the loop's response model. With this section, that call gets
  `output_format` automatically (`request_output_format/2` keys on `%ToolCallResponse{}`).
  `tool_choice: :none` must also reach the `stream/3` path. The adapter's `stream/3` now goes
  through `open_stream/2`, so any request option belongs in `build_request/3`, not in the
  stream function.
- 5.2b's cap notice: `AgentMemory.request_messages/1` is the place to fold a `"user"` text
  message that directly follows a tool run into that run's message as a trailing text block
  (header row "Cap notice text"). Today a `"user"` message after a tool run stays separate.
- The `awaiting_final: true` clause in `turn.ex` does not continue a pause. If 5.2b rewrites
  that clause, it decides whether a final-call pause is finalized (today's behaviour, pinned
  by nothing) or becomes an error.
- 5.2a's stream gate can use `Normandy.LLM.Response.stop_reason/1` to turn the stream's string
  into the atom its `check_stop_reason/1` matches.
- 5.2a's adapter early return for `max_tokens`/`refusal` must also cover the structured
  tool-loop path, which now returns through `handle_structured/3` →
  `populate_tool_call_response/3` without looking at `stop_reason`. A truncated tool-loop
  response there carries `stop_reason: :max_tokens` on the `ToolCallResponse` and on
  `Response.stop_reason`, so `Call.check_stop_reason/1` catches it as planned.

**Proposed CLAUDE.md text (verbatim; for the wave gate).**
- In "## Configuration", replace the `:structured_outputs` bullet's clause "automatic fallback
  also applies for incompatible schemas, tool-bearing calls, refusal/max_tokens, and a 400 that
  names the output format or schema" with: "a tool-loop call or stream sends a non-chat output
  schema as `output_config.format` beside its tools (`Normandy.LLM.Request.output_format`);
  automatic fallback applies for incompatible schemas, refusal/max_tokens, and a 400 that names
  the output format or schema (on `stream/3` too)". 5.2 may rewrite the refusal/max_tokens part
  again.
- In "### Memory & Messages", under `Normandy.Components.AgentMemory`, after the `history/1`
  bullet add: "  - `request_messages/1` - History to request messages; each run of tool results
  becomes one message (one user turn on the wire). Memory keeps one entry per result".
- In "### Agent System", `Normandy.Agents.Model` bullet, after "`converse/3` and `stream/3` over
  `%Normandy.LLM.Request{}`" add: "(`request.output_format`: the non-chat output schema on a
  tool-loop call or stream; `%ToolCallResponse{}` carries `content_blocks`, replayed verbatim, and
  `stop_reason`, `:pause_turn` continues the turn)".

**Questions I would have asked Q (answers assumed).**
1. *Should a stream send `output_format` when the agent has no tools?* Assumed **yes**. R2/Q5
   says "on `stream/3` too", and a stream's system prompt already shows the schema with or
   without tools.
2. *Should the stream path also re-send without the format on a schema 400, as `converse/3`
   does?* Assumed **yes**, for parity. Without it, Review Focus #1's "schema rejected with a 400"
   route would fail on `stream/3`.
3. *Should `object_input` (`{}` for a non-object input) also cover `server_tool_use` and
   `mcp_tool_use` in `content_blocks`?* Assumed **no**: the header names only `tool_use`. A
   non-object server/MCP input can only come from a stream whose JSON did not decode.
4. *Is a `"tool"` message with string content allowed to break a coalesced run?* Assumed
   **yes**, as a separate message. Nothing in the codebase produces one (every `ToolResult`
   serializes to a list), and changing its content would be a silent rewrite.

### Task 5.2

**Verified in a scratch worktree at `0dccd48`** (removed afterwards). I applied 5.2a in full and 5.2b's core, shell, adapter and default changes, without Tasks 5.1/5.3. `mix precommit` exited 0 (3115 tests, 0 failures; credo and dialyzer clean). Every test file above ran green in that form. The two exceptions are the assertions on `output_format` (5.1) and on the coalesced tool-result message (5.3a + Step 6), which cannot run before those tasks. A full-suite run with only the 5.2b core change applied failed exactly the tests listed in 5.2b Step 1 and nothing else. That is how the existing-test list was built. `base_agent_tool_loop_test.exs:123-142` and `base_agent_streaming_test.exs:344-394` stay green unchanged. One more check: with 5.2a's JSON-retry usage fix reverted, the retry-usage test fails (64 instead of 69 output tokens).

**Not verified**
- That the Messages API accepts this exact final request (tool_choice none, preserved thinking, notice text block after the tool_result). That needs Task 7.6's live run.
- That the API rejects `tool_choice` without `tools`. I relied on the API's rule as I know it and did not probe it. The skip is harmless either way.
- (Resolved in the preflight, X1: a pause on the final call is continued as the final call, Step 4 item 3.)
- After 5.3c, `turn_response_model/1` runs the loop for MCP-only agents. Their final call does get `tool_choice: none`, because the `mcp_toolset` is in `tools`.

**Risks**
1. The chat-agent `max_tokens` error (R4) and 5.2a's summarizer gate land before Task 5.5 raises the summarizer's 500-token default. Between 5.2a and 5.5, a compaction whose summary hits 500 tokens is an `{:error, %LLMError{type: :max_tokens}}` where it used to store a fragment. Run 5.5 in the same wave, as planned.
2. The `request_messages/1` fold changes the wire shape of `after_compact` texts at a mid-round boundary (Header conflict 2). If Q prefers it narrow, match `Turn`'s notice text instead.
3. `CapClient` matches `request.tool_choice` with a `case` that has no catch-all, so it crashes on any other value. That is deliberate: a new value must fail the test.

**Proposed CLAUDE.md text** (verbatim; the wave-gate task collects it):
- In the `BaseAgent` `init/1` bullet, after `` `:temperature` is optional ...`` add: `` `:max_tool_iterations` defaults to 20; after the last round the turn stores a notice and makes one more call with `Request.tool_choice: :none` ``
- In the `run/3` bullet, append: ``; an answer cut off at `max_tokens` (or the context window) or refused is `{:error, %LLMError{type: :max_tokens | :refusal}}` on every path (`Normandy.LLM.Call.check_stop_reason/1`), and no tool from it runs``
- `:structured_outputs` line (`CLAUDE.md:215`), replace `refusal/max_tokens, ` and keep Task 5.1's wording for the rest. The tail becomes: `` ... automatic fallback also applies for incompatible schemas and a 400 that names the output format or schema (other 400s are returned without a second request); a response that stops at `max_tokens`, `model_context_window_exceeded` or `refusal` is never parsed or re-asked ``
- In the `Normandy.Components.AgentMemory` list, add: `` `request_messages/1` - history to request messages: consecutive tool results in one message, a following user text as its last block ``. This merges with Task 5.3a's line if that task adds one.

**Questions I would have asked Q (answers assumed)**
- Should the final call's tool calls (from a client that ignores `tool_choice`) be an error rather than ignored? I assumed ignored: the core converts the text, as the 1.x forced-final path did.
- Should the notice also go out when the cap is hit by an approval-expiry `:continue` batch? I assumed yes, since that batch goes through `apply_tool_results/2` like any other.

### Task 5.4

- **Verified** in a scratch worktree of `0dccd48` with both tasks applied: `mix test` 3138 tests, 0 failures; `mix test.redis` 3211 tests, 0 failures (local `normandy-test-redis`); `mix test.postgres` 3195 tests, 0 failures, run against a **fresh partition database** `normandy_test_w54probe` that I created in `normandy-test-pg` (`MIX_TEST_PARTITION=_w54probe`); I did not drop anything. That probe database is still in the container; drop it with Q's go-ahead (`MIX_TEST_PARTITION=_w54probe MIX_ENV=test POSTGRES_PORT=55432 mix ecto.drop`). The container is stopped again. Credo strict, dialyzer (with the new ignore entry) and `mix docs --warnings-as-errors` passed. The worktree is removed.
- **Not verified:** real row-lock contention on Postgres (the sandbox's shared mode serializes both writers on one connection; Review Focus #5 says so). The design argument: every write upserts-and-locks the namespace counter row first, in READ COMMITTED a second writer blocks on that row and then reads the committed totals. A live two-connection test would need a non-sandbox repo; worth a line in Task 7.6 if wanted.
- **Interaction with Task 5.6 (later):** R8 sends tool `{:error, binary}` bare. The 5.4a cap tests assert error results with `~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su`, which holds for both shapes. The invalid-UTF-8 test pins `%{error: "the tool ran, but its output is not valid UTF-8 text"}` (a Dispatch-built error, like `unencodable_output/1`); if 5.6 changes Dispatch-built error shapes it updates this test with `test/json_struct_encoding_test.exs:65`. 5.6 also owns the memory tool's model-facing strings; the new `:documents` message follows the existing `:bytes` message's style.
- **Interaction with Task 5.7c** (`ConfigTemplate.check_loaded!/1`, `:pinned`): `:max_tool_result_chars` is a plain-data field (integer or nil), so it passes a plain-data check.
- **Risk, Postgres write cost:** every write is now a transaction with an upsert on the counter row plus the document statement(s): 3-4 statements instead of 1. Writers of one namespace serialize (they already did on the three in-node backends). Hot single namespaces on Postgres will see it; the guide says so.
- **Risk, a Postgres counter row for a namespace that only ever saw a delete of a missing path:** `lock_totals/2` upserts the row, so such a delete leaves a `(ns, 0, 0)` row until `delete_namespace/2`. Harmless (it is what the next write would create), but visible to a host inspecting the table.
- **Results the server builds without hooks are not capped** (`ServerGlue.after_tool/3` and `after_tool_built/3` return early when no `after_tool` hook is configured). They are fixed text under 200 characters; only a per-tool `max_result_chars` below that would show the difference. Kept as is to leave the no-hook path untouched; say if Q wants `finish/3` on both branches.
- **Proposed CLAUDE.md text** (the "Long-term Memory & Tool Context" section goes stale):
  - Replace the `Normandy.Behaviours.MemoryStore` bullet with: "- **`Normandy.Behaviours.MemoryStore`** - Namespaced, path-addressed document store with compare-and-set versions; `put/6` takes `limits` (`[max_bytes:, max_documents:]`) checked atomically with the write (`check_limits/3`, `{:error, {:namespace_full, :bytes | :documents, n}}`); backends InMemory, ETS, Mnesia, Postgres (counter table `normandy_memory_namespaces`), Redis (`:bytes` key); shared contract in `test/support/memory_store_contract.ex`"
  - In the `Normandy.Tools.Memory` bullet, replace "limits `max_document_bytes`, `max_namespace_bytes` (default 1_000_000, `nil` = no cap), `max_view_chars`, `max_cas_retries`" with "limits `max_document_bytes`, `max_namespace_bytes` (default 1_000_000) and `max_namespace_documents` (default 1000), each namespace cap `nil` = off and enforced by the store, `max_view_chars`, `max_cas_retries`"
  - In the `Normandy.Tools.Toolset` bullet, replace "`register/3` options `:timeout` (the call's timeout; a struct field is never read) and `:replace`" with "`register/3` options `:timeout` (the call's timeout; a struct field is never read), `:max_result_chars` (this tool's result cap; `nil` = none) and `:replace`"
  - In the `BaseAgent` `init/1` bullet or the Agent System section, add: "`max_tool_result_chars` (default 100_000 graphemes, `nil` = off): `Dispatch.finish/3` cuts longer tool results (error results too) after every hook and appends `\n[truncated: N of M chars shown]`; emits `[:normandy, :tool, :result_truncated]`"
- **Questions I would have asked Q (answers assumed):**
  1. Should the per-limit reading of "a write that does not increase bytes or count is always allowed" hold (Header conflicts 1)? Assumed yes.
  2. Validate `limits` keys in every backend's `put/6` (raises `ArgumentError` naming `<Impl>.put/6` for a typo) rather than ignoring unknown keys? Assumed yes, per the Global Constraint on options; the memory tool always passes both keys.
  3. Drop the local `normandy_test` database for the gate (Step 10) or run on a partition? Written as "ask Q", with the partition as the fallback.

### Task 5.5

- **Verified:** every code block in 5.5a and 5.5b was applied together to a scratch worktree of HEAD `0dccd48` (without Tasks 5.1–5.4b) and run. Before the lib changes: 16 of the 20 new tests failed (12/13 in 5.5a, 4/7 in 5.5b), as Steps 2 say. After: `mix precommit` exit 0 (72 doctests, 28 properties, 3104 tests, 0 failures; credo clean; dialyzer 33 skipped / 0 unnecessary) and `mix docs --warnings-as-errors` exit 0. The MIGRATING text went in as written (§35 placed directly before `## New, non-breaking`, because §32–§34 do not exist yet).
- **Not verified:** the interaction with Tasks 5.1–5.4b, which are not written yet. Assumptions: (1) 5.3b's `model_content/1` unwrap and `content_blocks` replay. The transcript code reads both key styles and unwraps `chat_message` JSON itself, so the tests hold either way. (2) 5.2b and 5.3c keep `{:maybe_compact, %{iterations_left: ...}}` as the tuple shape and may add sites. Step 3 and Step 6 give the rule for added sites. (3) 5.3a's coalesced tool message keeps `role: "tool"`.
- **Risk:** the `compact_turn_memory/3` read is `Map.fetch!(info, :mid_round)`, which is strict on purpose: any `{:maybe_compact, info}` an earlier task adds without the key crashes the compact handler (`KeyError`) in every shell. Step 7's run catches that. This is the reason for the rule in the task preamble.
- **Choices made without asking Q** (none in QUESTIONS.md):
  - The tool-result cap in the summary transcript is 4000 graphemes. It is a module attribute, not an option.
  - An error result reads `Tool error (<name>): ...`. AX-9 names only `Tool result`.
  - A result whose call id is unknown names the id.
  - Server and MCP tool calls render like client calls.
  - Other server results (for example `web_search_tool_result`) are a `[type]` placeholder.
  - The `{"chat_message": ...}` unwrap applies only to a JSON object with exactly that one string key.
  - The AX-28 wording is mine: `The earlier part of this conversation was summarized automatically to save space. The summary is context, not a new message.` and then the summary inside `<conversation_summary>` tags. The finding offered a mid-conversation system message "on supported models". It was not taken, because `summary_role` still refuses `"system"` (the adapter sends one system prompt).
  - An agent `max_tokens` that is present but invalid raises. Only `nil` or a missing key falls back to 16_000.
- **Turn.Server note, narrower than the research said.** I analysed it but did not probe it. A restored session's full history is at least as large as the history that triggered the first compaction, so it normally compacts again at its next boundary. That second compaction strips the kept thinking, so a 400 needs an unusual case, for example a larger window or a changed compactor after the restore. The certain costs are a new paid summary (which can differ), lost `after_compact` texts, and a cache miss. The MIGRATING bullet says "can reject", not "will". Wave 6's fix (persist compaction) is unchanged.
- **AX-28 in 5.6:** `5.6-text.md` line 51 assigns AX-28's wording to this task, because 5.5 owns the file. Task 5.6 must not change `summary_message/1` again.
- **CLAUDE.md:** no line goes stale. CLAUDE.md does not describe the summarizer budget, the summary text, or the compactor `ctx`.
- **Question I would have asked Q:** should Normandy skip a custom compactor at a mid-round boundary when the conversation fits? It cannot know the compactor's limit. Assumed answer: no, it is a documented contract (see "Header conflicts").

### Task 5.6

**Findings closed here:** AX-11, AX-13, AX-14, AX-15, AX-16, AX-17, AX-18 (description half),
AX-25 (plus `# Context`), AX-26, AX-27, AX-30 (text and a 1_000-char cap), AX-32, and the
research's surprises 3, 4, 7, 8 (nil default-deny, null keys, dead `DenialEnvelope`, the
three `pending_approval` sites). Not closed here: AX-12, AX-18's corrective retry, AX-19, AX-20,
AX-29, AX-33 (R8); AX-21 (Task 5.3b, `model_content/1`); AX-28 (summary framing; Task 5.5 owns
`summarizer.ex` — if 5.5's section does not change `"Previous conversation summary: "`, it is
unassigned); AX-31 (Task 5.7a); AX-22 (5.5); AX-23/AX-24 already fixed.

**Verified:** all four tasks were applied to a scratch worktree of HEAD `0dccd48` and the full
suite, credo `--strict`, dialyzer and `mix docs --warnings-as-errors` passed; each listed
failing test was seen failing first. **Not verified:** the interplay with 5.1–5.5's code (not
written yet); anchors are function names. A dangling scratch commit (`proto 5.6a`, detached,
unreachable) was created in the shared object store while prototyping; the worktree was
removed. It is harmless and goes with the next `git gc`.

**Risks:**
- 5.6b-ii (AX-32) changes behaviour for every test client whose final answer is an empty
  response model. In the prototype only `ScriptedToolClient` and `tool_input_isolation_test`'s
  client did; 5.1–5.5 may add more (e.g. a 5.1 client returning `request.response_model`).
  Rule: a scripted final answer must carry text.
- 5.6c returns `Jason.OrderedObject` from `Toolset.to_tool_schemas/1`; any code added by 5.1–5.5
  that reads tool schemas with `Map.get`/map patterns breaks (only Access works).
  `ToolCallResponse.prefix_key/3` hashes the schemas with `:erlang.phash2/1` and stays
  deterministic.
- A hand-edited spec whose `:property_order` no longer names its properties now raises
  `ArgumentError` when it is sent. That is deliberate (no silent fallback) but new.
- 5.7a makes `ToolWrapper.new/4`'s `:prefix` required; the new tool_wrapper tests use the
  file's `ToolWrapper.new(MockAdapter, client, tool)` form, so 5.7a's mechanical update must
  include them (3 new call sites in `describe "CallToolResult normalization (AX-14)"`).
- The validation message's "Correct the input and call the tool again." also appears when the
  tool's own `input_schema/1` is broken (returns nil); the model cannot fix that, but it gets
  the same one retry at most before the tool is refused again. Not worth a separate message.

**Assumptions (questions I would have asked Q):**
- An exception reason is sent bare like a binary (see Header conflicts 1). Assumed yes.
- AX-32 applies to whitespace-only answers too, and only to the `:chat_message` schema path
  that `convert_final_text/3` handles (tool loops on every interpreter, and every `stream/3`
  call). A no-tools sync chat call whose adapter returns `{"chat_message": ""}` through
  structured outputs is not checked. Assumed that is acceptable.
- The budget denial drops the tracker's non-binary reason entirely (not even `inspect` with
  limits). Assumed yes: decision 6 and AX-13's "inspect leak".
- An unsupported string `format` counts as a dropped constraint for AX-18. Assumed yes.

**Proposed CLAUDE.md text (verbatim).** Replace the four lines under "Prompt System" →
`SystemPromptGenerator`:

```
    - "Role" (background; an empty one is "You are a helpful assistant.")
    - "How to work" (steps)
    - "Output" (output_instructions; BaseAgent appends the output schema)
    - "Context" (from context providers)
```

Add under "Schema System", after the `Normandy.Schema` bullet group:

```
- **`Normandy.Schema.Wire`** - `encodable/1` is what the model sees of a spec: properties in declaration order (the spec's `:property_order`, sent as `Jason.OrderedObject`), no `$schema`/`title`; used for tool `input_schema`, the `# OUTPUT SCHEMA` block and retry feedback. `SchemaTranslator` keeps the same order and states the constraints structured outputs drop in the property description. Declaration order is generation order
```

### Task 5.7

- **Verified:** every step above was implemented in a scratch worktree at `0dccd48` (Waves
  1-4 only, no Tasks 5.1-5.6) and run: `mix precommit` exit 0 twice in a row (3143 tests, 0
  failures; credo `--strict` no issues; dialyzer passed), `mix docs --warnings-as-errors`
  exit 0. The test counts per file and the "expected failure" lists in each Step 2 were
  observed against `0dccd48`. Postgres, Redis and distributed suites were not run (no task
  here touches a backend; SEC-13 changes no key format).
- **Interaction risks with earlier Wave 5 tasks (not verifiable before they exist):**
  `server_limits_test.exs`'s `:tool_context` test and the existing
  `test/agents/tool_context_test.exs` both rely on `Normandy.Test.ScriptedToolClient`, whose
  final answer is the unchanged response model (`%ToolCallResponse{content: nil}`). If Task
  5.6's AX-32 ("an empty final answer is `:invalid_output`") lands as written, both get an
  error instead of `{:ok, _}` and the 5.6 writer must change `ScriptedToolClient` to answer
  with text; the probe assertions (`assert_receive {:probe_ctx, ...}`) are unaffected.
  *Resolved (integrated preflight, X8):* Task 5.6b-ii gave `ScriptedToolClient` an `:answer`
  field defaulting to `"done"`; 5.7b leaves the client untouched and its `:tool_context`
  test passes on that default.
  `ToolWrapper.run/2` (5.6 AX-14) and `tool_wrapper_test.exs` (5.6) are edited by both 5.6
  and 5.7: 5.7a/5.7d anchor on `name/1`, the struct, the options and the `{:error, reason}`
  clause, and the test rewrite is a grep rule, so it holds whatever 5.6 added.
- **Flake seen once:** `test/agents/turn/server_integration_test.exs:101`
  (`assert_receive {:event, :awaiting_approval, %{parked: 1}}`, 2000 ms) failed once under
  `mix precommit` load and passed on two full reruns and alone. It runs a thin start, which
  now also runs `check_loaded!/1` and `check_pinned!/2` (microseconds). Watch it in 5.7c's gate.
- **Unverified:** whether the Messages API accepts a history `tool_use` block whose name is
  no longer in `tools` (an MCP tool renamed by a new prefix, inventory SEC-2 note (b)). Task
  7.6's live run could probe it; MIGRATING only says parked approvals under old names answer
  "not found".
- **AX-31** (MCP names checked against the API's limits; agentx.md says "sanitize and
  truncate with a hash suffix") is in the header's findings list but not in this dispatch.
  Today `MCP.Registry` already refuses an invalid name as `{:error, {:invalid_tool_name,
  name}}` instead of sending it (`registry.ex:80`), and the prefix shrinks the room by
  `byte_size(prefix) + 2`. Renaming a server's tools would make names the host cannot
  predict when writing policy rules, so I did not add it. Question I would have asked Q:
  "Close AX-31 as 'refused at registration' (documented in `ToolWrapper`'s moduledoc), or
  sanitize names?" Assumed: refuse, as today.
- **Behaviour change beyond the inventory:** a thin start whose template neither 1.0 nor 2.0
  wrote now waits `:unavailable` with `{:invalid_template, message}`
  (`check_pinned!/2` runs `translate!/1`) instead of raising in `init/1`. Covered by the
  existing `Turn.Server` docs paragraph added in 5.7c; no test pinned the old crash.
- **`Inspect` keeps `base_url` as is.** A `base_url` with userinfo (`https://user:pw@...`)
  still prints; SEC-12 named only `:req_options`/`:headers`. The breaker key already strips
  userinfo (`CircuitBreaker.key/3`); the same could be done here if Q wants.
- **Proposed CLAUDE.md text** (the controller collects it for Q):
  - Under "Protocol Support", replace the `Normandy.MCP.ToolWrapper` bullet with:
    "- **`Normandy.MCP.ToolWrapper`** - Interoperate with Model Context Protocol servers. `:prefix` is required on `ToolWrapper.new/4`, `MCP.Registry.discover_and_register/4`/`wrap_tools/4` and `BaseAgent.register_mcp_tools/4` (and on `A2A.AgentTool.new/3` and `A2A.Registry`): letters, digits, `-` and single `_`, at most 61 bytes, or `false`; tools are named `prefix__name`. Policy globs must match remote tools on the prefix"
  - Replace the `Normandy.A2A.Server` bullet with:
    "- **`Normandy.A2A.Server`** - Expose agents for agent-to-agent collaboration; `handle_message/4` takes `:max_text_bytes` (default 100_000, `nil` off; over → `{:error, :too_large}`) and `:tool_context` (replaces the config's for one call). Authentication and body limits are the host's"
  - Under "`Normandy.Agents.Turn.Server`", add: "- A stored template is checked before use (`ConfigTemplate.check_loaded!/1`: plain data, behaviour modules declare their behaviour) and against the supplement's `:pinned` (`[policy:, guardrails:, credential:, ...]`); a refusal is `{:invalid_template, message}` in a `:session_unavailable` `TurnError`"
  - Under "Long-term Memory & Tool Context", `Normandy.Tools.Memory` bullet, add: "a session namespace equal to a mount's raises; mounts sharing a namespace must share its access"
  - Under "Lifecycle Hooks" or a new "Guardrails" line: "- **`Normandy.Guardrails`** - `:on_error` (`:reraise | :open | :closed`) covers raises, exits and throws; host code a builtin calls fails as `Normandy.Guardrails.GuardError`"

