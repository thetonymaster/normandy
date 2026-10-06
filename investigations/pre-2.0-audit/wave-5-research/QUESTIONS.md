# Wave 5 — questions for Q (consolidated from the research inventories, 2026-10-06)

Each block is copied verbatim from its inventory; numbering is per inventory (5.1-5.2 Q1..Q9, 5.3-5.5 Q1..Q6, 5.4 1..10, 5.6 1..9, 5.7 1..8).

## Tasks 5.1-5.2 (tool loop, stop_reason) — 5.1-5.2-loop.md

**Q1. Unparseable final answer: `ValidationError` or `LLMError :invalid_output`?** Plan, Review Focus #2: ValidationError. Code and tests: `:invalid_output` (decode failure) vs ValidationError (decoded but invalid).
(a) Keep the split and fix the plan text. (b) Make all of it `ValidationError`.
Recommend **(a)**: it matches the no-tools path, where the adapter's `ParseFailure` already returns `:invalid_output`, and the `:on_parse_failure` policy. Cost if wrong: (b) later is a breaking change to one error type in one path.

**Q2. Send `output_config.format` on tool-loop calls for the default chat schema too?**
(a) Non-chat schemas only. (b) Always.
Recommend **(a)**: a chat agent would otherwise answer `{"chat_message": ...}` JSON, which is then stored and replayed (AX-21). Cost if wrong: chat agents miss a guarantee they never needed.

**Q3. `Request.output_format` type.**
(a) The output-schema struct; the adapter translates via `StructuredOutputs.schema_for/2`. (b) A ready JSON Schema map; BaseAgent translates.
Recommend **(a)**: the kill switch and translator are per-client, and adapters own wire format. Cost if wrong: an internal refactor before 2.0 ships.

**Q4. Ship `pause_turn` in 5.2, or move it after 5.3?** It cannot replay server/MCP blocks before 5.3, and AX-3 dispatches `mcp_tool_use` locally today.
Recommend **moving the `pause_turn` item and its test to 5.3** (or doing 5.3 before 5.2). `max_tokens`, `refusal` and the cap stay in 5.2. Cost if wrong: a 5.2 test that passes with fakes while the live path still breaks.

**Q5. Streaming and `output_format` (AX-24).** `stream/3` with a non-chat schema could send the format too, with a one-line change in `build_stream_request/1`.
Recommend **yes**, in 5.1: same fields, same adapter builder. Cost: one more test.

**Q6. `:model_context_window_exceeded`** (today treated like `max_tokens` on the structured path).
(a) Same `:max_tokens` error, detail naming the reason. (b) Its own `:context_window_exceeded` type.
Recommend **(a)** for a minimal surface. Cost if wrong: callers can't tell "raise max_tokens" from "compact" without reading the detail.

**Q7. Should an agent with `mcp_servers` but no local tools run the tool-loop response model?** Today it doesn't, so MCP-connector `pause_turn` and `mcp_tool_use` never reach the loop.
Recommend **yes** (`turn_response_model/1` checks `mcp_servers` too), together with 5.3. Cost: one more path in every loop test matrix.

**Q8. The iteration-cap notice: wording, and whether it is persisted.** The API's append-only rule says persist, and keep it in later replays.
Recommend the AX-5 sentence, persisted as a text block in the batch's tool-result user message (after 5.3), with a separate `"user"` message as the interim form. Also: raise the default `max_tool_iterations` from 5 to 20 (AX-5)? That is a breaking default. Recommend yes, with a MIGRATING line. Cost if wrong: a request-only notice causes a messages-cache miss and invalidates thinking blocks on Opus 5.5 and Fable 5.1 every turn that hits the cap.

**Q9. A truncated plain-prose answer (chat schema, `max_tokens`): error, or return it?** The plan specifies the `tool_use` and structured cases only.
Recommend **error** (`:max_tokens`), consistently. A truncated answer presented as success is the AX-4 bug, and callers can raise `max_tokens`. Cost if wrong: chat agents near the cap now fail instead of returning partial text. This lands with the 16_000 default (decision 10), so it should be rare.

## Tasks 5.3, 5.5 (replay, compaction) — 5.3-5.5-replay.md

**Q1. Mid-turn compaction and the open round's thinking (Surprise 1).**
- (a) Keep the open round's thinking after a keep-tail compaction, as plan.md says. Per the skill, a 400 on accounts created on/after 2026-08-31 (Opus 5.5, Fable 5.1), unless every later request sets `prefix_mismatch_behavior: "drop_block"`, which then drops it anyway.
- (b) Keep stripping (today's behaviour, the documented keep-tail recovery), and compact mid-round only when over the limit; change the acceptance.
- (c) (b) plus send `thinking.block_binding.prefix_mismatch_behavior: "drop_block"` after any compaction.
- Recommend (b). If wrong: (a) ships a 400 to every new account that compacts mid-round; (b) costs one round of lost reasoning only when the window is actually full.

**Q2. Does 5.3's "replayed as received" cover the final answer?** Today it is stored as the output-schema struct (`turn.ex:164-166`) and replays as `{"chat_message": ...}`, with its thinking discarded. Options: (a) leave it (AX-21 stays open); (b) unwrap a `chat_message` schema to its text in `AgentMemory.model_content/1`, the input-side precedent (`agent_memory.ex:125-130`); (c) append the raw response (`last_response` with `content_blocks`) instead of the struct, which changes what callers find in memory. Recommend (b) in 5.3 (small, consistent with how the input is unwrapped) and (c) deferred. If wrong: (a) keeps teaching models to answer in JSON; (c) breaks anyone who reads `AgentMemory.messages/1` for the output struct.

**Q3. Claudio drops `citations` from replayed text blocks** (`response.ex` `block_to_api` text clause). Options: patch Claudio (0.7.1) to keep `citations`; or store Normandy's own string-keyed copy of the raw HTTP blocks (needs Claudio to expose them; it doesn't keep the raw map for text). Recommend a Claudio patch, verified in Task 7.6's live run. If wrong (citations must be replayed and aren't): replayed turns with citations differ from what the model produced — a possible preserved-thinking edit only for citation users.

**Q4. Summarizer `max_tokens` default:** (a) the agent's `max_tokens` (default 16_000); (b) a fixed 16_000; (c) 4_096. Also: expose `summary_max_tokens:` on `Compactor.WindowManager`? Recommend (a) and yes. If too low: a truncated summary becomes `{:error, ...}` and compaction is skipped every boundary; if too high: only a non-streaming timeout risk, which 16_000 avoids per the skill.

**Q5. Turn.Server compaction is not persisted (Surprise 3).** A rehydrated session replays full history, so post-compaction thinking is replayed after a different prefix. Options: (a) document and leave for Wave 6; (b) persist a compaction marker entry (needs a SessionStore format change across 5 backends); (c) skip compaction on Server sessions. Recommend (a) with a MIGRATING note now; it is not in Wave 5's text. If wrong: enforced accounts using Turn.Server + a compactor get a 400 after a passivate/rehydrate cycle.

**Q6. Where to coalesce tool results.** Request build (proposed: no store or core change, all shells covered) vs Turn core (one `{:append_message, "tool", [results]}`: changes the store format, `unanswered_tool_calls/1`, `ServerGlue.after_tool_built/3`, ~21 test sites). Recommend request build. If wrong: nothing breaks; memory keeps one entry per result, which only matters to code that reads memory.

## Task 5.4 (size caps) — 5.4-caps.md

1. **Does the cap apply to `is_error` results?** Options: (a) yes, every result the model sees;
   (b) only successful outputs. Recommend (a): error text is where the unbounded `inspect/1`s
   live (Surprise 1). If wrong: a huge error string still fills the context.
2. **Do the hooks see the full output?** Options: (a) cap last, after `after_tool` and the
   after-hooks (hooks see the full output; the StreamEvent and memory get the capped one);
   (b) cap before the hooks. Recommend (a): a hook can summarize a big result itself before the
   blunt cut. If wrong: a hook that logs results logs megabytes (it already does today).
3. **Map and list outputs**: truncate the encoded JSON text (the output becomes a string that is
   cut-off JSON plus the note) vs. turn an oversize structured output into an error result.
   Recommend truncation (decision 12a says truncate; the note tells the model). Cost if wrong:
   the model may try to parse broken JSON. The note should say so: e.g.
   `[truncated: N of M chars shown]` is decision text, so keep it verbatim.
4. **Invalid UTF-8 binary output** (Surprise 3): (a) make it an error result in
   `ensure_encodable/1` ("the tool ran, but its output is not valid UTF-8"); (b) scrub invalid
   bytes (no `String.replace_invalid/2` on 1.15; hand-rolled); (c) leave it out of 5.4.
   Recommend (a), in 5.4: same pattern as the unencodable-term case, a few lines, and the cap
   test touches this code anyway. If not fixed: a session can wedge on a later request.
5. **Per-tool option name**: `Toolset.register/3` `:max_result_chars` (scoped by the call) vs.
   the agent's name `:max_tool_result_chars`. Recommend `:max_result_chars`, documented next to
   `:timeout`. Cheap either way.
6. **"chars" = graphemes** (`String.length/1`), which is what "grapheme boundary" implies, vs.
   codepoints. Recommend graphemes, plus the `byte_size` fast path. Cost: an O(n) walk only on
   results whose byte size exceeds the cap.
7. **Store API shape**: (a) `put/6` with a `limits` keyword (impls default `\\ []`); (b) keep
   `put/5` and add a separate `put_capped/6` callback; (c) pass limits through the handle.
   Recommend (a): one write path, so no backend can forget the counters. Cost: 9 stub modules
   edited.
8. **Postgres**: counter table (tracks, O(1), schema change in the unreleased migration) vs.
   advisory lock + `SUM`/`count` (computes, O(n), no schema). Recommend the counter table,
   matching decision 12b's "track". Cost if wrong: one more table to document, and counters
   drift if a host writes rows directly (document it).
9. **A write that shrinks a namespace already over the cap** (for example after the host lowered
   it): today it is refused if the new total > cap (`commands.ex:416`). Options: keep strict, or
   allow any write that does not increase bytes or count. Recommend allowing it, so a model can
   repair an over-full namespace by shortening files. Cost if wrong: an over-cap namespace can
   only be fixed by deletes.
10. **`max_namespace_documents` when the caller passes `max_namespace_bytes: nil`**: independent
    caps (each `nil`-able). Recommend independent, both default on. No real cost.

## Task 5.6 (model-facing text) — 5.6-text.md

1. **AX-15 scope.** Options: (a) global: any `{:error, binary}` from any tool is sent as the bare string with `is_error: true` (also the `Executor` timeout/crash messages); (b) memory-only, via a tool-returned marker (e.g. `{:error, {:text, bin}}`) that `wrap_error` sends bare, everything else keeps `%{error: bin}`. Recommend (a): `is_error` already carries the error flag, the JSON wrapper adds nothing, and it matches AX-15's own fix text. Cost if wrong: changes ~6 test assertions (`json_struct_encoding_test.exs:84-85`, `tool_telemetry_test.exs:108`, `dispatch_split_test.exs:285`, `tool_input_isolation_test.exs:153`, plus the memory ones) and the shape any downstream log/parser sees for tool errors; reversible by one clause.
2. **How far does "next step" go?** Dispatch-built results are clearly in. Executor messages (timeout, crash, invalid result), hook denials and the interrupted result are the grey zone. Also: drop `denied: true` from input-fixable errors (validation, non-object)? Recommend yes for those two and no change to policy/budget/hook denials; add the next-step sentence to Dispatch, expiry, rejection, interrupted, hook denial; leave Executor messages as they are (they already say what failed). Cost if wrong: a few more string edits and tests.
3. **MCP non-text content.** Image/resource blocks in an MCP result: (a) text only, others become a one-line note like `"[image omitted]"`; (b) pass the content-block list through (Claude accepts image blocks in `tool_result`, but `ToolResult.output`/`format_tool_output` sends non-binary as JSON text, so this needs a `ToolResult` change). Recommend (a) for 5.6. Cost: images from MCP tools are dropped until a later task.
4. **Rename `# EXTRA INFORMATION AND CONTEXT`?** AX-25 names only three headers; the fourth is the same dated style. Recommend `# Context`. Cost if wrong: one more golden-test line.
5. **AX-21 (earlier answers replayed as `{"chat_message": …}` in tool mode).** Task 5.3 replays assistant turns "as received", which fixes it for tool-loop turns, but a memory restored from before or the structured-output path still stores `BaseAgentOutputSchema`. Options: (a) leave to 5.3; (b) also unwrap `%BaseAgentOutputSchema{chat_message: text}` in `AgentMemory.model_content/1` (`agent_memory.ex:128-132`) like the input side. Recommend (b), three lines, mirrors the input fix. Cost: if a user relied on the JSON-wrapped history, the model sees plain text instead.
6. **AX-18 remainder** (append dropped constraints, `pattern`, `min/max`, to the property description in `SchemaTranslator`; corrective retry on the structured path). The description-append is cheap and safe; the retry is new behaviour. Recommend: include the description-append in 5.6 (it is model-facing text), defer the retry to Q's call. Cost if wrong: schema tests for the translator change.
7. **AX-32 (empty final answer is `""` success).** Options: (a) leave and document; (b) one re-prompt ("Please give your final answer to the user."); (c) `{:error, %LLMError{type: :invalid_output}}`. Recommend (c) for consistency with the non-chat branch (`base_agent.ex:798-810`), but this is a behaviour change in the agent loop (all three Turn interpreters plus streaming build the final answer through `convert_final_output/4`, `base_agent.ex:786-796`, so one edit covers them). Cost if wrong: a turn that ends on tool results with no text now errors instead of returning blank.
8. **`$schema` / `title` in model-facing schemas** (AX-11 "consider"). They are in tool `input_schema` and the legacy OUTPUT SCHEMA; `Wire.encodable/1` could drop them. Recommend dropping `"$schema"` and `"title"` at the wire boundary only (the raw spec keeps them for `Validator`/`Introspection`). Cost if wrong: none functional; changes prompt-cache keys once (system prompt text changes anyway with AX-25).
9. **Deferred rows.** AX-12, AX-18's retry half, AX-19 (do with 5.1), AX-20, AX-29, AX-33: confirm they stay out of 5.6 (Wave 6 or 2.x). The plan's consolidated map sends all agentx Tier 3-4 to 5.6, so each one left out needs your explicit nod (plan.md "A finding a wave can't close goes back to Q").

## Task 5.7 (security) — 5.7-security.md

1. **SEC-2: required prefix or opt-out.** There is no server name to default to (Surprise 1).
   - (a) `:prefix` required, with `prefix: false` as an explicit opt-out.
   - (b) Required, with no opt-out.
   - (c) Optional, defaulting to `"mcp"`. That gives a namespace, but two servers then collide
     (`{:tool_name_taken, _}`) and `"mcp__*"` covers every server.

   **Recommend (a).** Every upgrading host has to make a choice and so sees Surprise 2.
   **If wrong:** (a) costs one keyword per call site for hosts that never use policy rules.
2. **A2A tool names** come from the remote card (Surprise 11). Should `A2A.Registry` get the
   same required `:prefix`, in this task or in a follow-up? **Recommend** recording it as a
   SEC-2 sibling and adding `:prefix` to `AgentTool.new/3` (replacing the fixed `"a2a"`) in this
   task, since 2.0 is the breaking window. **If wrong:** A2A keeps the hole SEC-2 closes for MCP.
3. **SEC-4 "timeouts".** Catching exits covers a timeout *raised inside* a guard. Should
   guardrails also get an optional per-guard `:timeout` that runs the check in a task?
   **Recommend:** catch exits and throws now; add `:timeout` only if Q wants it. It has no
   default, but costs a process per guard when set, and context and `$callers` crossing.
   **If wrong:** a guard that blocks without its own timeout still hangs the turn.
4. **SEC-8: A, B or C.** **Recommend A + C** (with the supplement `:pinned`); B is deferred and
   recorded in Known limits. B adds about 2-3 days and still leaves turn state and history
   unprotected unless it is extended to the store contract.
5. **SEC-9 defaults.** Should `max_text_bytes` default to `100_000` (to match decision 12a) or
   to `nil`, which means off and so is not a breaking change? And should `:tool_context`
   replace or merge? **Recommend `100_000`, replace.** Replace is explicit and doesn't leak a
   shared namespace key the host forgot to override. **If wrong:** a host that relies on
   >100 KB A2A prompts gets `:too_large`.
6. **SEC-7 mounts.** Should every pair of mounts with the same namespace be refused, or only
   pairs with different access? **Recommend refusing different access only.** Two read-only
   views of one KB are legitimate.
7. **SEC-13.** Should we refuse `{`/`}` in session ids (non-breaking for normal ids), or
   base64-encode inside the Redis tag (a key-format change that orphans live Redis sessions
   unless migrated)? **Recommend refusing.**
8. **SEC-15 fingerprint and SEC-14.** **Recommend** no fingerprint (document it instead), and
   SEC-14 stays in Task 6.5. Confirm both, so plan-wave-5 lists them as not closed here with
   that reason.
