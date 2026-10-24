## Principles audit: lib/normandy/components/**, lib/normandy/context/**, lib/normandy/telemetry/**, lib/normandy/telemetry.ex, lib/normandy/metadata.ex (31 files, whole modules, branch feat/claudio-0.7-migration @ 7561497)

Verdict: ship with follow-ups. Nothing here blocks 2.0. The heaviest structural debt is one content-block type switch copied into six files and a pure token estimator that pulls AgentMemory into a runtime cycle with the LLM/turn stack. Three findings (4, 5, 10) are public-API decisions, and 2.0 is the cheap time to make them.

### Findings (ranked)

1. [composition · under] lib/normandy/context/window_manager.ex:183-220 (and 5 more files): the closed set Text | Image | Document is switched on by struct pattern in every consumer. Adding a block type or source touches about 7 files.
   Evidence: references to the block structs outside content_block/ (grep, comments and aliases excluded): window_manager.ex 6 (single-struct clauses 183-191, duplicated by estimate_block_tokens 206-220 in the same file), token_counter.ex 6 (block_to_claudio_map 219-228, which duplicates ClaudioAdapter's block_to_claudio at claudio_adapter.ex:645-646; get_content_preview 273-279), summarizer.ex 3 (block_lines 267-269), base_io_schema.ex 3 (defimpl `for:` list 38-43), agent_memory.ex 2 (@atom_field_values 1105-1108). Three implementations already exist, so a protocol earns its keep.
   Fix: a `ContentBlock` protocol (to_claudio/1, estimate_tokens/1, label/1), implemented in each block module; the consumers call it. Public API: additive only, no break.

2. [composition · under] lib/normandy/components/agent_memory.ex:521: the memory data structure calls `WindowManager.estimate_message_content_tokens/1`. WindowManager also aliases Summarizer (the LLM call, telemetry), so the core component sits in a runtime cycle with the turn machinery.
   Evidence: `mix xref graph --format cycles` → "Cycle of length 6 (1 export): agents/dispatch.ex, agents/turn.ex, components/agent_memory.ex, context/summarizer.ex, context/window_manager.ex, telemetry/metadata.ex (export)". AgentMemory also hardwires agent-layer types: `Normandy.Agents.BaseAgentInputSchema` / `BaseAgentOutputSchema` (503-511) and `ToolCallResponse` (21, 449-461, 686-707). There are no compile-connected cycles in scope (`--label compile-connected` showed none touching these files).
   Fix: move the pure estimators (estimate_tokens/1, estimate_message_content_tokens/1) into a pure module with no IO dependencies; keep `defdelegate`s in WindowManager. Public API: none broken.

3. [composition · under] lib/normandy/telemetry/span.ex:34-70, lib/normandy/telemetry/request.ex:110-151, lib/normandy/context/summarizer.ex:431-482: three hand-written start/try/stop/exception emitters. Two of them separately re-implement "a returned `{:error, %LLMError{}}` ends the span in `:exception` without raising", because `Span.span/3` cannot express it.
   Evidence: `System.system_time()` start events at span.ex:41, request.ex:123, summarizer.ex:437 (plus turn/server.ex:1318, 1407, which are out of scope). The Summarizer comment at 426-430 says why Span.span was not usable ("the returned {:error, %LLMError{}} must end it in :exception without being raised"). Request.span has the same `outcome` branch at 136-148.
   Fix: give `Span.span` an outcome variant (`span/4` taking `result -> {:ok, stop_meta} | {:error, LLMError.t()}`) and build Request.span and the summary llm_call span on it. Public API: additive (Span is a documented module).

4. [composition · over] lib/normandy/context/window_manager.ex:32-33, 326-329: the strategy `:sliding_window` is a public option value with no behaviour of its own.
   Evidence: `defp truncate_sliding_window(agent, manager), do: truncate_oldest_first(agent, manager)` (body at 327-328). The moduledoc says "Same as `:oldest_first`". It is still listed in the NimbleOptions `{:in, ...}` (74), in behaviours/compactor/window_manager.ex:4 and in tests (window_manager_test.exs:42, 349).
   Fix: drop it from the `:in` list and name it in MIGRATING-2.0.md, or keep it as a documented deprecated alias. Public API: removing it is a breaking change, so 2.0 is the window for it.

5. [composition · over + false-claim] lib/normandy/metadata.ex:2-11: `Normandy.Metadata` is Ecto residue that nothing reads, and its moduledoc claims a lifecycle the code does not have.
   Evidence: the moduledoc says "Used internally by the Schema system to manage struct lifecycle". Writes: schema.ex:501-505 (`state: :built`, `context:`, `schema:`) and schema.ex:529 (`state: :loaded`). Reads of `__meta__` fields: none (`grep -rnE "__meta__(\.|:| =>)" lib test` finds only type specs, struct construction and `Map.delete(:__meta__)`). `:source` is never set. `@schema_context` is read (schema.ex:499) but never assigned anywhere in lib. `:deleted` (metadata.ex:11) is never assigned. `@type t` omits `:source`.
   Fix (smallest): correct the moduledoc to "carried for compatibility; not read". Fix (2.0): drop `source`, `context` and `:deleted`, or drop `__meta__`. Public API: the doc fix breaks nothing. Removing fields changes the struct shape of every io_schema value and the public `Normandy.Metadata.t()`, which is a breaking change.

6. [false-claim] lib/normandy/context/window_manager.ex:126: `estimate_tokens/1` docs say "For accurate counts, use count_tokens_api/2". No such function exists.
   Evidence: `grep -rn count_tokens_api lib` → only window_manager.ex:126. The real API is `Normandy.Context.TokenCounter.count_message/3` / `count_conversation/2`.
   Fix: point the doc at TokenCounter. Public API: none (docs only).

7. [false-claim] lib/normandy/components/stream_processor.ex:59-62: the `accumulate_text/1` doc example pipes through `parse_stream_events()`, which does not exist. The function itself has no caller in lib.
   Evidence: `grep -rn parse_stream_events lib` → only stream_processor.ex:60. `accumulate_text` callers are only test/components/stream_processor_test.exs:14, 27, 33. BaseAgent uses only `stream_error/1` and `build_final_message/1`.
   Fix: fix the example. For 2.0, consider whether `accumulate_text/1` should stay public at all. Public API: the doc fix breaks nothing; removing the function is a breaking change.

8. [flat-code · over] lib/normandy/context/summarizer.ex:519-570: `do_compress_conversation/7` is a one-use two-clause helper that threads seven arguments through to replace one guard (`total_messages <= keep_recent`). Three of the arguments (`_client`, `_history`, `_summary_role`) go unused in the first clause.
   Evidence: called once (summarizer.ex:183-191). The comment at 519-520 says it exists "to avoid dialyzer warnings about unreachable branches"; this audit did not verify that claim (see Not checked).
   Fix: an early `if total_messages <= keep, do: {:ok, agent}` (or a `with`) inside compress_conversation/3, then the existing body. Public API: none (private).

9. [dependency-injection · under] lib/normandy/context/window_manager.ex:343-356: the `:summarize` strategy reads its LLM client from the agent with `Map.get(agent, :client)`. When the client is nil it silently runs `:oldest_first` instead.
   Evidence: `if client do Summarizer.compress_conversation(...) else # Fall back to oldest-first ... truncate_oldest_first(agent, manager)`. Neither the moduledoc (29-34) nor the truncate_conversation/2 doc mentions the fallback. A `%BaseAgentConfig{}` always has `:client` (required by `init/1`), so the branch is reachable only from a hand-built agent map.
   Fix: raise `ArgumentError` naming the missing `:client`, or document the fallback. Public API: behaviour change only for non-BaseAgentConfig callers that relied on the fallback.

10. [dependency-injection · under] lib/normandy/context/token_counter.ex:42: `count_message/3` hardwires a default model, `"claude-haiku-4-5-20251001"`, contradicting the library's own stated rule.
    Evidence: summarizer.ex:372-373: "there is no default; a hard-coded model goes stale". TokenCounter's count_conversation/2 takes the agent's model (100-102) for the same reason ("Tokenizers differ between model generations").
    Fix: make `model` required. Public API: a breaking change (`count_message/2` goes away), so it belongs in 2.0 with a MIGRATING line.

11. [composition · under, low] lib/normandy/context/summarizer.ex:335-345 vs lib/normandy/components/agent_memory.ex:470-477: two rules for unwrapping a `{"chat_message": ...}` final text. AgentMemory unwraps any object that has the key; Summarizer unwraps only a single-key object.
    Evidence: agent_memory.ex:465-468 calls its rule the one "shared by BaseAgent's final-text conversion and last_tool_round/2". Summarizer's copy has `when map_size(map) == 1`. A custom schema `{"chat_message": "x", "score": 1}` is unwrapped by one rule and not by the other.
    Fix: if the difference is intended, say why in one of the two comments. If not, have Summarizer call AgentMemory.unwrap_llm_content/1. Public API: none.

### Survived scrutiny
- Entry `wire`/`tokens` cache and `AgentMemory.request_messages_for/2` (agent_memory.ex:315-328), an optimisation. It has measurement behind it: investigations/pre-2.0-audit/wave-6-research/6.1-history.md:123-137 gives history/1 at 5.74 ms for 1200 messages, quadratic per turn, against a projected 243 µs. A property test pins its equivalence to the composed form (test/components/agent_memory/request_messages_for_test.exs:105-115), and an encode-count test covers the rest (lines 140-148).
- OtelCtx `:persistent_term` probe cache (otel_ctx.ex:49-61), an optimisation. Measured at 24.6 µs per `capture/0` without OTel (wave-6-research/6.5-process.md:30, PERF-16). The cost (OTel loaded later is not seen) is documented at 12-15.
- `BaseIOSchema` protocol: 7 defimpls in scope (BitString, Map, List, the 3 blocks, ToolResult) plus one per io_schema.
- `ContextProvider` protocol: one implementation in lib (DateTimeProvider), but it is a documented user extension point; there are 8 defimpls across lib and test.
- `RunUsage` and `Telemetry.Request` trackers are explicit `:counters` values carried on the request, not process state. That is injection, and it works across Turn.Server's worker processes.
- `Provider.provider/1` hard-codes the two bundled adapters (provider.ex:37-43). This is a documented choice not to grow the third-party `Model` protocol, with `options.provider` as the escape hatch. `structured_output?/2` (112-122) asks the adapter's own routing function instead of copying it.
- TokenCounter.build_messages_payload/1 (187-197) reuses the adapter's `add_messages/3`, so there is one wire conversion rather than two.
- Nesting: `nesting_depth.py --max 3` over all 31 files reports nothing (exit 0, script confirmed working). At `--max 2`, 13 functions are at depth 3, all within the limit. The one Credo nesting disable (agent_memory.ex:939, chain_newest_first) is at depth 3.
- Loops over input: `answer_once/1`'s per-answer walk stops at the first entry of another turn (agent_memory.ex:433). `enforce_max_messages/1` walks the chain on each append only when `max_messages` is set, so the chain is bounded by it. StreamProcessor's per-delta `List.update_at` is bounded by the block count.
- `async: false` in 7 test/telemetry files: :telemetry handlers and the OTel propagator are global (span_test.exs:2, otel_ctx_test.exs:2-3). These are not patching seams.
- `mix credo --strict` on the 31 files: "446 mods/funs, found no issues".

### Not checked
- Summarizer's claim that the 7-arg helper avoids Dialyzer warnings (summarizer.ex:519-520). Testing it means editing the file; this audit is read-only.
- Benchmarks were not re-run. The 6.1 and 6.5 probe scripts live in a past session's scratchpad, not in the repo, so the cited numbers cannot be reproduced from the repository.
- `mix test` and `mix dialyzer` were not run. TokenCounter's `@tag :integration` tests need the live API, and network access was excluded.
- lib/normandy/telemetry.ex is documentation only (one example module, at 475-553). Its event claims were not checked one by one; test/telemetry/catalogue_test.exs covers that the events are listed.
- Out of scope: turn/server.ex's own hand-emitted spans (1318, 1407) and BaseAgent's with_llm_call_span, except where cited as evidence.
