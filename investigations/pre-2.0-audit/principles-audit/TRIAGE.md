# Principles audit triage — 2026-10-23, HEAD 7561497

8 reports in this folder (agents, behaviours, coordination, llm, components, tools, schema, core). 73 findings.
All 8 verdicts: ship with follow-ups. No blocker.
Refuted: behaviours report "dialyzer exit 2" — `MIX_ENV=test mix dialyzer` (precommit's env) exits 0.

## A. One-way doors (break API; 2.0 or 3.0) — Q decides each
A1 behaviours#1  CredentialProvider.FromClient default never yields a token at its call site (known open item) — rec TAKE
A2 behaviours#3  Redis new/1 default namespace normandy_test_<uuid>; Postgres new/0 reads :normandy :ecto_repos — rec TAKE (require :namespace / handle)
A3 components#10 TokenCounter.count_message/3 default model "claude-haiku-4-5-20251001" — rec TAKE (model required)
A4 coordination#2 HierarchicalCoordinator :shared_context accepted, never read — rec TAKE (remove)
A5 coordination#7 Pattern.ok/1, error/1 identity fns — rec TAKE (remove)
A6 tools#4       Toolset.fetch_metadata/2, list_metadata/1, introspect_schema/2 unused — rec TAKE (remove)
A7 components#4  WindowManager :sliding_window = alias of :oldest_first — rec TAKE (remove)
A8 coordination#3 Batch.Processor error shape (stacktraces) differs from the rest — rec TAKE (align)
A9 components#9  :summarize silently falls back to :oldest_first without client — rec TAKE (raise)
A10 schema#1,#2 + components#5  Ecto residue: Type/ParameterizedType DB/embed/query callbacks, %Validate{} fields, Metadata fields — rec Q DECIDES (largest, ~half day)
A11 core#4       config :normandy, :adapter JSON seam (one impl) — rec KEEP
A12 llm#10       truncated-string recovery + [:normandy,:json_deserializer,:recovery] — rec KEEP
A13 components#7 StreamProcessor.accumulate_text/1 public, no caller — rec KEEP (fix doc example only)

## B. Real defects, no API change — rec TAKE
B1 llm#1   JSON region extraction O(n²) on unclosed `{` (240 KB → 30 s, measured)
B2 core#2  application.ex :rest_for_one: breaker crash restarts AgentProcess ScopedRegistry
B3 core#3  retry backoff test asserts nothing when attempt count is off; slow wall-clock tests
B4 tools#3, core#1  Memory.new/1 and Retry validate opts by hand (CLAUDE.md: every entry point via Options) — additive

## C. False doc claims — rec TAKE as one docs commit
agents#4, behaviours#4, coordination#1 (doc part), #4, #10, llm#2, #9, #12, components#5 (doc), #6, #7 (example),
tools#9, schema#3 (error message), #4 (+CLAUDE.md Type bullet: needs Q), #9, core#7, #8, #9

## D. Park for 2.x (internal refactors, no API)
agents#1 (tool-batch runner x4, drifted — highest of these), agents#2 (additive behaviour), #3, #5, #6
behaviours#2 (additive callbacks), #5; coordination#1 structural, #5, #6, #8, #9
llm#3, #4, #5, #6, #7, #8, #11; components#1, #2, #3, #8, #11
tools#1, #2, #5, #6, #7, #8, #10; schema#5, #6, #7, #8; core#5, #6

## E. Reject
schema#10 `@compile inline` with no benchmark — harmless; not worth a change
