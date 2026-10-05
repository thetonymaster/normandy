# Wave 3 reconcile log

Controller pass over the five section files, then assembly into `../plan-wave-3.md`.
Backups of the pre-reconcile files were kept in the session scratchpad (not in the repo).

| # | File | Task | Edit | Why |
|---|---|---|---|---|
| 1 | 3.3.md | 3.3b | **Files**/**Interfaces**: dropped "17 test files" and the `Normandy.Test.Tools.*` rename rule; the four fixtures keep `Normandy.Tools.Examples.*`; only Weather is renamed (`MyApp.Tools.Weather`) | C1 |
| 2 | 3.3.md | 3.3b Step 1–2 | Rewrote the test: `refute Code.ensure_loaded?` would fail for same-named fixtures compiled from `test/support`; now asserts each fixture's compile source is under `test/support/tools/` and that `Weather` is not loaded; updated the expected failure text | C1 consequence (the original test could never pass) |
| 3 | 3.3.md | 3.3b Step 4 | Replaced the perl rename + Credo alias reordering with a grep check (`Tools.Examples` in `lib` → only `base_agent.ex:2015`; no `Tools.Examples.Weather` left) | C1 |
| 4 | 3.3.md | 3.3b Step 9 | `git add` list reduced to the files the task still edits (17 renamed test files removed) | C1 |
| 5 | 3.3.md | 3.3a Step 10, 3.3b Step 8 | MIGRATING sections numbered §23 and §24; removed "(Replace `N` ...)" lines | C6 |
| 6 | 3.4.md | 3.4a Files + Step 1 | Explicit check of what rule (b) does to `BaseAgent.InitOptions` (the `toolset:` entry, the `:tools` hint text) and to the 3.1b hint test; note that 3.1c deleted `@override_keys` | C5 (3.1-3.2 notes hand-off) |
| 7 | 3.4.md | 3.4a Step 1 | Hand fix of MIGRATING §21's two `tool_registry` mentions (not in rule (b)'s paths), with a grep check | C5; §21 would name a removed option |
| 8 | 3.4.md | 3.4a Step 6, 3.4d Steps 1/3 | MIGRATING tools section numbered §25; the Ruling 5 message/test text `see MIGRATING-2.0.md, section "Tools: ..."` → `see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour)` (5 places: 3 test assertions, `@migration`, `@tools_section`) | C6 |
| 9 | 3.4.md | 3.4b Steps 1/3 | `use Normandy.Tool` unknown-option message: one key is `unknown option :nam` (was `unknown options [:nam]`), several stay a list; test updated | Consistency with 3.1a's house style |
| 10 | 3.4.md | 3.4c Step 4a | States that `execute_and_wrap/4` keeps 3.3a's `wrap_output/2` / `wrap_error/2` / `unencodable/1` | C8 |
| 11 | 3.4.md | 3.4c Files, new Step 7k, Step 9 | `test/json_struct_encoding_test.exs` (3.3a) calls `Dispatch.execute/4` with a tool struct; rewritten to pass a `%Dispatch.Invocation{}`; added to Files and to Step 9's run list (four → five files) | C8; the test would not compile against 3.4c's `execute/4` |
| 12 | 3.4.md | 3.4d Files, Step 3f, Step 7 | `normandy_integration_helper.ex`'s `struct(MyApp.Tools.Weather, city: "")` → `struct(MyApp.Tools.Weather)` once Weather has no `:city` field; file added to Files and `git add` | 3.3b × 3.4d interaction (`struct/2` would drop the key silently) |
| 13 | 3.4.md | 3.4d Step 1c | `{:ok, agent} = ToolAgent.new(...)` → `agent = ToolAgent.new(...)` | C4 |
| 14 | 3.4.md | header | `## Header conflicts` block replaced by a one-line pointer (its "Split vs. the dispatch brief" note moved to the writer-notes appendix) | C7 |
| 15 | 3.5-3.6.md | 3.5a, 3.5b, 3.5c, 3.5d, 3.6a, 3.6b, 3.6c | MIGRATING sections numbered §26 (Session), §27 (orchestrators; 3.5c/3.5d append to "§27"), §28 (lookups; 3.6b appends), §29 (BaseIOSchema) | C6 |
| 16 | 3.5-3.6.md | 3.6a | `BaseAgentConfig.tool_registry` → `toolset` in Consumes, the `fetch_tool!` test and `toolset_of/1` | C5 |
| 17 | 3.5-3.6.md | 3.6b | Removed the `Toolset.get_metadata/2` rename: scan-table row says "done in 3.4a", Files/Test/Produces lines, the conditional perl step (now a grep check), the MIGRATING row, the `toolset.ex` and `fetch_metadata` `git add`s, and the commit message clause | C2 |
| 18 | 3.5-3.6.md | 3.6c Step 3 item 6 | `app_env_config_test.exs` lines shift after 3.3a's `TaggingJson` rewrite: added a grep to find them; named the two clauses 3.3a left | 3.3a × 3.6c line drift |
| 19 | 3.7-3.8.md | 3.7a Step 6; 3.7b/c/d MIGRATING steps | MIGRATING section numbered §30; "Append to Task 3.7a's section (§30)" | C6 |
| 20 | 3.7-3.8.md | Conventions | Deleted Convention 3's example "precedence chain (`Tools.Executor`'s `:timeout`...)": after 3.4c the executor's `:timeout` has a schema default | C3 |
| 21 | 3.7-3.8.md | 3.7c Files/Interfaces/Step 0 | Executor no longer modified; `executor_test.exs` no longer modified; Interfaces list what 3.4 already validated (`execute_tool/2`, `execute_tool_classified/2`, `Toolset.register/3`, `AgentTool.new/3`'s `:timeout`); Step 0 expectations describe the post-3.4c `AgentTool`/`A2A.Registry` keys | C3 |
| 22 | 3.7-3.8.md | 3.7c Step 1 | Removed the five `Executor` rows from `@cases` (three functions no longer exist; `execute_tool_classified/2`'s doc has no `## Options`) and the now-unused `Executor`/`Memory` aliases | C3 |
| 23 | 3.7-3.8.md | 3.7c Step 3b | `AgentTool.new/3`: schema without `:timeout`; body keeps 3.4c's `:timeout` raise before `Options.validate!/3`; struct literal without `timeout:`. `A2A.Registry`: separate schemas for `from_agent_card/3` (`:auth_token`, `:transport_opts`) and `discover_and_register/3` (+ `:timeout`, default 60_000, the registration timeout 3.4c introduced); body passes `timeout:` to 3.4c's `register_all/3` | C3; the written step re-added the struct field and default 3.4c removed |
| 24 | 3.7-3.8.md | 3.7c Step 3f | Replaced-expression text now quotes 3.2a's `WM.new([...] ++ Keyword.drop(...))`; `validate_opts!/1` call placed after 3.2a's `:max_tokens` rename check so 3.2a's exact-message test still passes | 3.2a × 3.7c ordering conflict |
| 25 | 3.7-3.8.md | 3.7c Step 3g | Replaced the executor schema step with "already done by Task 3.4c" plus a grep check | C3 |
| 26 | 3.7-3.8.md | 3.7c Steps 5/7 | Dropped the MIGRATING bullet about Executor messages; `from_agent_card/3` bullet mentions `:timeout`; `git add` drops `executor.ex`/`executor_test.exs`; commit message drops "executor" | C3 |
| 27 | 3.7-3.8.md | 3.7d Step 3 | Timeouts table: `Toolset.register/3`/`register_tool/3`/DSL `tool` row, `Executor.execute_tool/2` row (30_000), `A2A.Registry.discover_and_register/3` row (60_000); removed the `AgentTool.new/3` 60_000 row and the conditional paragraph | C3 |
| 28 | 3.7-3.8.md | 3.7d Step 5 | Coverage test: `lib/normandy/dsl/agent.ex` moved from `@internal` (stale reason `validate_overrides!/2`; after 3.1c it calls `Options.validate!` and no longer reads `Keyword.get(opts`, so the "still reads" test would fail) to `@validated`; DSL test renamed to Task 3.1c; describe comment lists what 3.1/3.4/3.5 validated; added Executor and `AgentTool.new/3 :timeout` cross-checks | C3, C4 |
| 29 | 3.7-3.8.md | 3.7d Step 5 | Added `lib/normandy/agents/base_agent/init_options.ex` to `@validated` (3.1b's `model_missing?/1` reads `Keyword.get(opts`) and `lib/normandy/tool.ex` to `@internal` (3.4b's `__use_options__!/2` reads `Keyword.get(opts`) | Ruling 6 test would fail on files created by 3.1b/3.4b |
| 30 | 3.7-3.8.md | Notes | Corrected note 4 about the DSL `new/1` | C4 |
| 31 | 3.1-3.2.md | 3.2b Step 8 | Also rewrites §21's `:circuit_breaker_options` bullet to `circuit_breaker:` | §21 named an option 3.2b removes |
| 32 | all five | header blocks | Each `## Header conflicts` block replaced by a one-line pointer to the header | C7 |
| 33 | ../plan-wave-3.md | header | Architecture/numbering: 3.7a–3.7d; Global Constraints: MIGRATING §21–§30 assignment and the `§NN` pointer style; Shared interfaces rewritten: `Options` message shapes, `sensitive_keys/0`, `plain_map/1` (3.7a), `OptionsAssertions` (3.7a), missing-`:model` message without prefix, DSL `new/1` return, `JSON` `opts \\ []` and Dispatch check, 3.3b names, `Normandy.Tool` functions, `Tools.Input.validate/2`/`message/1`, `Toolset.fetch_metadata/2`/`timeout/2`, `toolset` field, `BaseAgent.register_tool/3`, `Dispatch.Invocation`, Executor, `Session.run/2`/`approve/2`/`put_config/2`, `OrchestrationError`, 3.6b fetches; Ruling 4 (names kept), Ruling 5 (§25, `:tool_registry` supplement), Ruling 7 (both `start_server/2`) | C1, C6, C7 |
| 34 | ../plan-wave-3.md | assembly | Appended the task bodies (3.1a … 3.8, with 3.7's Conventions block) in execution order, then the two appendices | Assembly |

Creator-first check (C7): `sensitive_keys/0` is created by 3.1a (first use 3.1b); `Options.plain_map/1`
is created by 3.7a and first used by 3.7a–d; no task before 3.7a calls it (3.1b uses its own
`InitOptions.plain_map/1`), so nothing moved to 3.1a. `Normandy.Test.OptionsAssertions` is created by
3.7a and used only by 3.7a–d.

## Decision 18

Q's 2026-10-05 answers to "Appendix: open questions for Q" (`decisions.md` row 18), applied to
`../plan-wave-3.md` only (the section files are not updated). Line numbers drift; anchors are
task and step.

| # | Task | Edit | Item |
|---|---|---|---|
| D1 | header, Shared interfaces | `Normandy.Options.plain_map/1` is Task 3.1a's, the one custom type (InitOptions' `:tool_context` and 3.7a–d), exact message `"expected a plain map (not a struct), got: <Describe.type_of/1>"`; removed "Task 3.7a adds" and "InitOptions keeps its own" | #26 |
| D2 | header, Shared interfaces | Missing-`:model` line: "the one message without the Mod.fun/n prefix (plan.md text, kept verbatim)" reversed; now `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"` | #2 |
| D3 | header, Shared interfaces | Task 3.1c line: a DSL agent with no declared model raises `"MyAgent.new/1: requires :model (a string), got none"` | #2 |
| D4 | header, Shared interfaces | Comment under `Tools.Input.message/1`: no `properties` ⇒ open; `properties` without/with `false` `additionalProperties` ⇒ strict; `true` ⇒ open | #9 |
| D5 | 3.1a Interfaces | Produces `plain_map/1` (`@doc false`), its exact message and why that message was picked over "expected a map of plain data, got ..." | #26 |
| D6 | 3.1a Step 2 | `test/options_test.exs` gains `"plain_map/1 accepts a plain map and names the type of anything else"` (moved from 3.7a, plus a string case) | #26 |
| D7 | 3.1a Step 4 | `plain_map/1` added to `lib/normandy/options.ex` after `docs/1` (3.7a's code; comment notes it never names the value) | #26 |
| D8 | 3.1a Steps 5, 6 | 18 → 19 tests; suite total note: rehearsed 2710 predates decision 18, expect 2711, later rehearsed totals +1 (+2 from 3.1c) | #26, #2 |
| D9 | 3.1b Interfaces | Consumes `plain_map/1` (Task 3.1a); exact missing-`:model` message with prefix (was "Header conflict 1") | #26, #2 |
| D10 | 3.1b Step 1 | Test renamed `"a missing or nil :model raises, naming init/1"`, asserts the prefixed message | #2 |
| D11 | 3.1b Step 3 (InitOptions) | `validate!/1` raises `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"` (two lines, as `mix format` wraps it) | #2 |
| D12 | 3.1b Step 3 (InitOptions) | `:tool_context` type → `{:custom, Normandy.Options, :plain_map, []}`; `InitOptions.plain_map/1` (both clauses) deleted | #26 |
| D13 | 3.1b Step 6 table | `tool_context_test.exs:22` and `agent_memory_test.exs:112` rewrites assert `expected a plain map \(not a struct\), got: a list` / `got: a string \(4 bytes\)` | #26 |
| D14 | 3.1b MIGRATING §21 | Missing-`:model` bullet quotes the prefixed message | #2 |
| D15 | 3.1c Interfaces | Produces: no declared model raises `"MyAgent.new/1: requires :model (a string), got none"` (1.x `RuntimeError` `"model is required in agent definition"`) | #2 |
| D16 | 3.1c Step 1 | `NoModelAgent` fixture after `LimitedMemoryAgent`; test `"an agent that declares no model raises, naming new/1"` | #2 |
| D17 | 3.1c Step 2 | Expected failures list the `RuntimeError` for `NoModelAgent` | #2 |
| D18 | 3.1c Step 3 item 4 | `base_config/0`'s check raises `ArgumentError, "#{inspect(__MODULE__)}.new/1: requires :model (a string), got none"`; item text says so | #2 |
| D19 | 3.1c Step 7 | MIGRATING §21 DSL bullet adds the no-model `ArgumentError` (1.x `RuntimeError`) | #2 |
| D20 | 3.4b Step 3 (`Tools.Input` moduledoc) | Hand-written map rule: `properties` ⇒ closed (absent `additionalProperties` = `false`); no `properties` ⇒ any key; unknown-key sentence scoped accordingly | #9 |
| D21 | 3.4b Step 3 (`validate_map/2`) | `open? = not has?(schema, :properties) or get(schema, :additionalProperties, false) not in [false, nil]`; new `has?/2` (atom or string key) | #9 |
| D22 | 3.4b Step 1 (`input_test.exs`) | `SchemaTool` fixture (schema given as a field, default `%{"type" => "object"}`); tests: no `properties` accepts `%{"anything" => 1}`; no `properties` still checks `required`; `properties` without `additionalProperties` rejects `"extra"` naming it (`unknown key "extra"; expected only "q"`); no `properties` still wants an object | #9 |
| D23 | 3.4b Step 5 | Commit body: except a hand-written schema with no properties | #9 |
| D24 | 3.4c `MCP.ToolWrapper` | `input_schema/1` comment: no `properties` accepts any keys | #9 |
| D25 | 3.4c MIGRATING §25 | Input bullet (hand-written map rule) and the MCP sentence rewritten to the new rule | #9 |
| D26 | 3.4c commit | Body: the no-`properties` exception | #9 |
| D27 | 3.4d Step 5b (CLAUDE.md) | `Normandy.Tool` bullet: "unknown keys refused, except under a hand-written schema with no `properties`" | #9 |
| D28 | 3.7a Files, Interfaces | `options.ex` change is only `:config` in `@sensitive_keys`; Consumes `plain_map/1` (Task 3.1a); Produces no longer lists it | #26 |
| D29 | 3.7a Step 1 | `turn_options_test.exs`: `describe "Options.plain_map/1"` and the now-unused `alias Normandy.Options` removed | #26 |
| D30 | 3.7a Steps 2, 3a | Expected failure no longer cites `plain_map/1`; Step 3a is "`:config` is a sensitive key" and states `plain_map/1` exists since 3.1a | #26 |
| D31 | 3.7b Interfaces | Consumes attributes `plain_map/1` to Task 3.1a | #26 |
| D32 | Appendix: open questions | List header replaced by the decision 18 note; #2, #9, #26 carry their outcome; other entries kept as the record | all |

Creator-first check after D1–D31: `Normandy.Options.plain_map/1` is created by 3.1a and first used
by 3.1b (`:tool_context`); no task creates it again. Neither old missing-`:model` string nor
"map of plain data" survives outside the appendix's record of #2/#26 and the 1.x "Old" column.
