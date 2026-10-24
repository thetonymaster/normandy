## Principles audit: lib/normandy/llm/**, lib/normandy/mcp/**, lib/normandy/a2a/** (22 .ex files, 4839 lines, branch feat/claudio-0.7-migration @ 7561497)

Verdict: ship with follow-ups. Nothing here blocks 2.0. The most serious finding (#1) is a quadratic parse that only pathological model output triggers. Two finds are false documentation claims (#2, #9), fixable in minutes. Only #10 is a public-API decision.

Findings by principle: composition 8 (2 of them false claims), flat code 2, dependency injection 1, measure first 1. Total 12.

### Findings (ranked)

1. [measure-first · under] lib/normandy/llm/json_deserializer.ex:347 (with lib/normandy/llm/json/content_cleaner.ex:48-66): prose-region extraction is O(n^2) on model output with unclosed `{`/`[`
   Evidence: when an opener never closes, `find_balanced_from/2` scans to EOF and then retries from `start + 1`. Timed with `mix run` calling `JsonDeserializer.parse_and_validate/2` on `String.duplicate("{\"a\": ", n)`:
   30 KB 451 ms · 60 KB 1857 ms · 120 KB 7481 ms · 240 KB 30551 ms. Each doubling of input costs 4x the time.
   Control: 176 KB of balanced code in prose took 10 ms, so ordinary output stays linear. The only bound is `:max_input_bytes` (10 MB, decoder.ex:7). The parse runs once per JSON attempt (up to 3 by default) in the caller's process.
   Fix: find the regions in one stack-based pass, or stop trying openers after the first one that reaches EOF unclosed (or after N attempts). Private code, no public API change.

2. [composition · false-claim] lib/normandy/llm/json_deserializer.ex:13: the moduledoc claims "Support for nested/double-encoded JSON"
   Evidence: `parse_and_validate(Jason.encode!(Jason.encode!(%{chat_message: "hi"})), %BaseAgentOutputSchema{})` returns `{:error, {:unexpected_parse_result, "\"{\\\"chat_message\\\":\\\"hi\\\"}\""}}`. A decoded binary falls through to the `_ ->` clause at :338. There is no unwrap step and no test for it (the grep for "double" in test/ finds only an unrelated schema field).
   Fix: delete the bullet. The alternative is to decode one more level when the result is a binary. Doc-only change, no API change.

3. [composition · under] lib/normandy/llm/claudio_adapter.ex:853-858 and :1015-1083: JSON-retry usage reaches the response through the caller's mailbox, and the adapter keeps a second copy of the usage-shape rules
   Evidence: `on_retry_usage: fn usage -> if ref, do: send(owner, {ref, :retry_usage, usage}) end` pairs with `collect_retry_usage/2`, which does `receive ... after 0`. Both run in the same process, so the mailbox serves as hidden mutable state between two calls.
   `add_usage/2`, `iterations_of/1`, `side_iterations/1` and `to_usage_map/1` (~60 lines) re-encode the `iterations`/atom-vs-string key rules that `Normandy.Telemetry.Usage` (usage.ex:24-27, :95) already owns.
   `if ref` and `Map.get(context, :json_retries, 2)` are dead defaults: the only caller (`converse_legacy`, :220-226) always sets both.
   Fix: have `deserialize_with_retry` return the summed retry usage (or fold it in an accumulator the caller owns), and move the summing into `Telemetry.Usage`. `:on_retry_usage` is a documented `JsonDeserializer` option and can stay, so no public API change is required.

4. [flat-code · under] lib/normandy/llm/json_deserializer.ex:203-305 and :347-389: invariant arguments threaded positionally through the retry loop
   Evidence: `deserialize_loop/8`, `retry_with_feedback/9` and `continue_after_retry/8` all carry the same arguments. Only `content` and `attempt` change; `schema, client, request, opts, adapter, max_retries` never do. Credo's arity check is silenced at :246 (`# credo:disable-for-next-line Credo.Check.Refactor.FunctionArity`).
   `try_extracted_regions/7` threads 6 invariants and hits depth 4: `nesting_depth.py` reports "json_deserializer.ex:353: try_extracted_regions: depth 4", and Credo Nesting is disabled at :352.
   Fix: bundle the invariants in one private struct or map built in `deserialize_with_retry/5`, and bind `with {:ok, region, start} <- ..., {:ok, parsed} when is_map(parsed) <- ...` to drop a level. Private, no API change.

5. [flat-code · over] lib/normandy/a2a/agent_tool.ex:180-198: the `deadline` parameter of `poll_for_result/4` is only finite in a test, yet it creates the depth-4 nesting
   Evidence: the only production call is :313 `poll_for_result(tool.endpoint, task.id, opts, :infinity)`. The only finite deadline is test/a2a/agent_tool_test.exs:216 (a deadline already in the past). `nesting_depth.py`: "agent_tool.ex:187: poll_for_result: depth 4", with Credo Nesting disabled at :186. The comment at :178 confirms the executor timeout is the real bound.
   Fix: drop `deadline` and the if/else; the function becomes `case get_task` plus a terminal check (depth 2). The function is `@doc false`, so no public API change.

6. [dependency-injection · under] lib/normandy/a2a/agent_tool.ex:55 and :190: the poll interval is a hard-wired `@poll_interval 1_000` plus `Process.sleep`, and the polling path has no test
   Evidence: `grep -rn ':working\|"working"\|get_task\|tasks/get' test` gives 0 hits. The non-terminal → `Client.get_task` → sleep → retry path never runs in the suite. Any test of it would sleep at least 1 s per round. The transport is already injectable (`transport_opts[:transport]`, used in test/a2a/registry_test.exs:22); only the interval is not.
   Fix: make the interval a `new/3` option (default 1_000) stored on the struct, then add a test with a transport that answers `working` and then `completed`. Additive option, so no breaking API change.

7. [composition · under] lib/normandy/a2a/agent_tool.ex:206, :212, :228, :316: four copies of the "parts to text" join
   Evidence: `Enum.map_join(parts, "\n", fn p -> Map.get(p, :text, "") end)` appears four times. The copy at :212 sits at the depth that needed the second Credo Nesting disable (:211).
   Fix: one `defp parts_text(parts)`. A `case`/multi-clause head on `task.artifacts`/`task.status` then removes the disable. Private, no API change.

8. [composition · under] Rules duplicated across modules, each kept in sync only by a comment:
   - lib/normandy/mcp/registry.ex:79-88 and lib/normandy/a2a/registry.ex:119-128: identical `register_all` (`valid_name?`, then `has_tool?`, then `register`). The only difference is the register opts.
   - lib/normandy/llm/client_inspect.ex:41-52 copies `sanitize_url/1` from lib/normandy/resilience/circuit_breaker.ex:363-373; the comment at :41 says so. This is a credential-redaction rule, so drift would leak a token in one of the two places.
   - HTTP status classification exists twice: claudio_adapter.ex:1371-1380 vs openai_compatible_adapter.ex:221-228 (the copies already differ on 529 and `nil`). The transport-error clause is identical in both (claudio_adapter.ex:1356-1359, openai_compatible_adapter.ex:193-196).
   Fix: `Toolset.register_new/3` returning `{:ok, t} | {:error, {:invalid_tool_name | :tool_name_taken, name}}`, one shared URL sanitizer, and `LLMError.classify_status/1` plus `LLMError.transport/1`. All of these are internal, so no public API change.

9. [composition · false-claim] lib/normandy/llm/openai_compatible_adapter.ex:7-8: "Structured output + prose fallback reuse the same `Normandy.LLM.JsonDeserializer` path as `Normandy.LLM.ClaudioAdapter`"
   Evidence: the adapter calls `ParseFailure.parse_text_output/3` (:326). That function does one `parse_and_validate`, with no retry (parse_failure.ex:47-53), and the file itself says "No extra LLM round-trips" (:314-316). ClaudioAdapter instead uses native structured outputs or `deserialize_with_retry` (claudio_adapter.ex:862). As a result `enable_json_retry`/`json_retry_max_attempts` silently have no effect on this client, and init_options.ex:110-115 does not say so.
   Fix: reword the moduledoc ("one-shot parse, no JSON retry; `:on_parse_failure` applies") and note the exception on the two init options. Doc-only.

10. [composition · over] lib/normandy/llm/json/scanner.ex (129 lines), lib/normandy/llm/json/decoder.ex:33-41, `[:normandy, :json_deserializer, :recovery]`: truncated-string recovery has no in-library consumer
    Evidence: `grep -rn recover_truncated_strings lib` hits only json_deserializer.ex/decoder.ex, so no adapter, BaseAgent or init option passes it. Its stated use case ("payloads that exhaust max_tokens mid-string", json_deserializer.ex:127-129) is refused before any parse on every agent path: claudio_adapter.ex:214-216 and :262-264, openai_compatible_adapter.ex:319-321, `Call.check_stop_reason/1`. It is reachable only by a direct `parse_and_validate(text, schema, recover_truncated_strings: true)`.
    Fix: decide for 2.0. Either keep it as a documented standalone helper and say it is unreachable from agents, or remove it. Removal changes PUBLIC API (a documented option of a public module plus a catalogued telemetry event; MIGRATING-2.0.md would need an entry).

11. [composition · over] Dual atom/string-key reads for response shapes Claudio 0.7.1 no longer produces: lib/normandy/llm/claudio_adapter.ex:456-462 (comment "Claudio historically mixes atom-keyed and string-keyed"), :891-894, :920, :999-1005, :1087, :1434-1448
    Evidence: mix.lock pins claudio 0.7.1. deps/claudio/lib/claudio/messages/stream.ex:649-654 decodes SSE data with string keys only, and deps/claudio/lib/claudio/messages/response.ex:464-499 turns every content block into atom keys and an atom `type:`. The only producer of the string-keyed `%{"stop_reason" => ...}` shape is test/llm/claudio_adapter_test.exs:285, a test written to pin that shape. Every production call passes `%Claudio.Messages.Response{}`.
    Fix: read the one shape Claudio emits (atom keys for responses, string keys for stream data) and drop the test at :285. All of these are `@doc false`, so no public API change.

12. [composition · false-claim, minor] Stale or inaccurate comments:
    - lib/normandy/llm/json/content_cleaner.ex:4-5 says "`extract_balanced/1` is the prose-extraction fallback (implemented in the hardening phase)". The fallback actually uses `extract_balanced/2` (json_deserializer.ex:348); `/1` has no lib caller, only test/llm/json/content_cleaner_test.exs:21-46.
    - lib/normandy/llm/structured_outputs.ex:4-5 says "per-call via `client.options[:structured_outputs]`". It is per-client, and the keyword-list branch at :23-27 is unreachable for a validated ClaudioAdapter (claudio_adapter.ex:1229-1233 raises on non-map options).
    Fix: correct both comments and delete `extract_balanced/1` and the keyword branch. `StructuredOutputs.enabled?/1` is public; dropping keyword-list support only narrows inputs nothing in lib passes.

### Survived scrutiny
- `Normandy.Agents.Model` protocol has 2 implementations in lib (ClaudioAdapter, OpenAICompatibleAdapter) plus `Normandy.Test.FakeClient`. `Normandy.LLM.Call` is its single caller and checks return shapes (call.ex:13-28).
- `MCP.ToolWrapper` takes the MCP adapter module as an argument. Several adapters exist (Claudio ExMCP, Hermes, test fakes). Its dual-key `normalize_result` is justified because those adapters hand over different documented shapes (tool_wrapper.ex:183-188).
- A2A transport is injected via `transport_opts[:transport]` (Claudio a2a/client.ex:105) and used by tests. Both adapters accept a `req_options` `plug:` for tests, so no monkeypatching was found.
- App env `:structured_outputs`/`:on_parse_failure` are global fallbacks behind per-client options. One `async: false` test (test/app_env_config_test.exs:7) exercises the fallback itself; nothing else patches them.
- `ParseFailure` is one policy shared by both adapters and BaseAgent.
- `append_messages/2`'s performance claim (claudio_adapter.ex:518-519) holds: Claudio's `add_message/3` does `messages ++ [message]` (deps/claudio/lib/claudio/messages/request.ex:166), so per-message appends are quadratic. The batch call is also simpler, so no readability was spent.
- Option schemas shared at compile time (MCP.Registry ← ToolWrapper, A2A.Registry ← AgentTool) are the "one source" design. `mix xref graph --label compile-connected` lists these files as expected from `use Normandy.Tool`/`Normandy.Schema`.
- Credo-silenced complexity checked: `scan_balanced/8` (content_cleaner.ex:74) and `validate_option_combinations!/2` (claudio_adapter.ex:1264) are flat dispatch, one rule per branch, so they keep the suppression.
- `mix credo --strict` on all 22 files: "428 mods/funs, found no issues".

### Not checked
- `mix dialyzer` and the test suite were not run (read-only audit, time). Nothing here is claimed as tested beyond the grep counts cited.
- Streaming (`stream/3`) and the live HTTP paths were not exercised: no network, by instruction. The finding #1 timings come from one `mix run` per size (MIX_ENV=test, no Benchee, no repeats), so treat them as order-of-magnitude.
- Usage-merging behaviour (#3) was judged by reading the code. The refactor's effect on telemetry totals was not run.
- Files outside the scope (BaseAgent, Telemetry.Usage, CircuitBreaker) were read only to verify a cross-reference.
