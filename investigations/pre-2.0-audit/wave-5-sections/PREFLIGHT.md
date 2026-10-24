# Wave 5 preflight: integrated probe run

Worktree `scratchpad/w5-preflight`, branch `w5-preflight`, from `0dccd48`. Dialyzer PLTs were
copied from the main tree's `_build/plts` (no rebuild).

## Phase 1 (5.1, 5.3a, 5.3b, 5.3c)

`mix docs --warnings-as-errors` exited 0 after 5.1 and again after 5.3c.

### Task 5.1 — PASS
- Commit `0b7f845`.
- Precommit: `72 doctests, 28 properties, 3115 tests, 0 failures (203 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)".
- Step 2 failed as stated (`unknown key :output_format for struct Normandy.LLM.Request`).
  Step 8: 110 tests across the five files; `tool_loop_output_format_test.exs` 27 tests.
  The Step 6 grep gives 9 lines, as stated.
- Text corrections: none.

### Task 5.3a — PASS
- Commit `191e711`.
- Precommit: `72 doctests, 28 properties, 3126 tests, 0 failures (203 excluded)`, exit 0, credo
  and dialyzer clean.
- Step 2 failed as stated (10 failures: `request_messages/1` undefined, roles
  `["user", "assistant", "user", "user"]`, two calls from `extract_tool_uses/1`, the run/3 and
  Turn.Server MCP tests requesting a second reply). The stream/3 MCP test already passed.
- Text corrections: none.

### Task 5.3b — FIXED
- Commit `0ad4af0`.
- Precommit: `72 doctests, 28 properties, 3140 tests, 0 failures (203 excluded)`, exit 0, credo
  and dialyzer clean (after the correction below).
- Step 2 failed as stated: `tool_call_response_test.exs` does not compile; the other files gave
  the 11 listed failures.
- Text correction: 5.1-5.3.md, Task 5.3b Step 3. `credo --strict` failed with two
  `Credo.Check.Design.AliasUsage` findings ("Nested modules could be aliased") at
  `tool_call_response.ex` `api_blocks/1` (`Claudio.Messages.Response.from_map/1`,
  `to_assistant_content/1`). The step now adds `alias Claudio.Messages.Response, as: ClaudioResponse`
  above `alias Normandy.Components.ToolCall`, and the `api_blocks/1` snippet calls
  `ClaudioResponse.from_map/1` and `ClaudioResponse.to_assistant_content/1`. The `as:` name keeps
  `Response` free in that module, since Task 5.3c types `stop_reason` there as
  `Normandy.LLM.Response.stop_reason()`. The section's claim that credo passed with the original text
  did not hold in this run.

### Task 5.3c — PASS
- Commit `a18814a`.
- Precommit: `72 doctests, 28 properties, 3152 tests, 0 failures (203 excluded)`, exit 0, credo
  and dialyzer clean. That matches the section's all-four total.
- Step 2 failed as stated (`key :stop_reason not found` expanding `ToolCallResponse`).
  Step 7: 148 tests and 6 properties pass; `pause_turn_test.exs` 12 tests.
- Text corrections: none. The model.ex Step 6 replacement leaves a line longer than the
  doc's width; I rewrapped the paragraph without changing its wording. 5.3b's Step 8 paragraph
  was rewrapped the same way.

### Cross-task items seen in this phase (owned by later sections; not fixed here)
- X4: no test client added in 5.1–5.3c ends on an empty final answer. Every scripted final answer
  is non-empty text (`"Done."`, `"Sunny."`, `{"action": ...}`, `"Hi."`).
- X9: 5.1's `tool_loop_output_format_test.exs` reads `schema["properties"]` from the decoded
  wire body, which is a plain map after `Jason.decode!`, so it is unaffected. The routing test in
  `claudio_adapter_test.exs` asserts only `is_map(schema)`, which an `OrderedObject` struct also
  satisfies.
- X7: 5.3c adds no new `{:maybe_compact, _}` emitter. `continue_paused/2` goes through
  `apply_tool_results/2`, so 5.5b's change to that function covers it.

## Phase 2 (5.2a, 5.2b; X1, X2, X3)

`mix docs --warnings-as-errors` exited 0 after 5.2a (after the correction below) and after 5.2b.

### Task 5.2a — FIXED
- Commit `0dfa950`.
- Precommit: `72 doctests, 28 properties, 3175 tests, 0 failures (203 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)". The first precommit run had 1 failure,
  not from this task: `base_agent_stream_errors_test.exs:149` ("a failed stream's exception
  telemetry ... is not logged") is `async: true` and its `capture_log` caught
  `[error] Agent a1 raised MatchError`, which `turn_error_test.exs:163` logs on purpose from a
  concurrent test. The rerun was clean. It is an existing cross-test log leak.
- Step 2 failed as stated (26 failures). The sync tool tests in `stop_reason_test.exs` failed with
  `FunctionClauseError` in `cut_off_tool_call/1` rather than `{:ok, _}`/`:tool_ran`: the tool ran
  each round, and the old forced-final call asked for `%BaseAgentOutputSchema{}`. Step 8: 446 tests,
  0 failures.
- Text corrections (5.2.md):
  - Step 4: `Call.stop_reason/1` no longer holds its own `@stop_reasons` map. It delegates binaries
    to Task 5.3c's `@doc false Normandy.LLM.Response.stop_reason/1` (H1), which already holds the same
    closed list. The Header-conflicts additions line and the Interfaces "Consumes (5.3c)" line say so.
  - Step 3: the `LLMError` moduledoc sentence named `Normandy.LLM.Call`, which is `@moduledoc false`.
    `mix docs --warnings-as-errors` failed ("documentation references module Normandy.LLM.Call but it
    is hidden"). It now reads "Normandy builds them from the response's `stop_reason`".
  - Step 2: the expected failure now also names the `FunctionClauseError` form.
  - X2: `claudio_adapter_stop_reason_test.exs` gets a sixth test. A tool-loop request with
    `output_format` (5.1 routes it to `converse_structured/4`) that stops at `max_tokens` with text and
    a `tool_use` comes back as `%ToolCallResponse{}` (empty), `stop_reason: :max_tokens`. Through
    `BaseAgent.run/3` it is the `:max_tokens` error, with one request and no tool run. The Step 5
    sentence on 5.1's path points at it. Checked: with the structured-path clause removed, that test
    fails.
- Ruling: `Call.stop_reason/1` delegates to `Response.stop_reason/1`. Reason: two closed
  string→atom lists would drift, and H1 already put the list in `Response`. Cost if wrong: none
  functional, since both lists were identical. H6's name is kept.

### Task 5.2b — FIXED
- Commit `564212d`.
- Precommit: `72 doctests, 28 properties, 3197 tests, 0 failures (203 excluded)`, exit 0, credo
  and dialyzer clean, after the comment wrapping below. The first run failed credo with 4 × "Line is
  too long".
- Step 2 failed as stated (19 failures). Step 8: 1328 tests, 0 failures.
- Text corrections (5.2.md):
  - Step 1 / Files / commit: `grep -rn "response_model: :os, final: true" test` gives **5** hits, not
    4. Task 5.3c's `pause_turn_test.exs` ("a model that keeps pausing reaches the forced final call")
    is the fifth. A bullet now rewrites it to `:rm`, and the file is added to Files, Step 2's run and
    the `git add`.
  - Step 1: the one-line replacement comments in `turn_test.exs`, `turn_inline_test.exs` and
    `base_agent_guardrails_test.exs` (two) are 144-377 columns. `credo --strict`
    (`Readability.MaxLineLength`, 120) refused them, and `mix format` does not wrap comments. The
    section now gives each one as a wrapped comment block.
  - Step 4 item 3: Task 5.3c moved the `[] ->` finalization into `defp finalize/2`, so the
    before-snippet no longer matched. The step now rewrites `finalize/2`'s body to use
    `finish_effect/2`. The `awaiting_final` clause is replaced by the X1 form below.
  - X1 (Step 4 item 3; tests): a paused final call (`pause_turn`, no tool calls) goes through 5.3c's
    `continue_paused/2`: the response is appended, the state persisted at the steering boundary, no
    user message added, one iteration spent. Then the existing `:compaction_done` clause for
    `left <= 0` makes the final call again, so the shells send `tool_choice: :none` again with no shell
    change. The continuations are bounded by `@max_final_continuations 3` (`iterations_left` going
    -1, -2, -3), and after that the paused text is the answer. Supporting changes: new
    `finish_final/2` and `continue_final?/2`, one Turn moduledoc sentence, and one MIGRATING bullet.
    Tests: 3 core tests in `turn_test.exs` (continued without a user message; answered after 3; not
    continued when it has tool calls), and 4 in `iteration_cap_test.exs` (sync, sync at the bound,
    `stream/3`, `Turn.Server`). For these, `CapClient` gains `final_pauses`, counted from trailing
    assistant messages. Checked: with the continuation disabled, exactly those 6 non-trivial tests
    fail. The "Not verified" note on the 5.3c/`awaiting_final` interaction is marked resolved.
  - X3: `tool_choice` was already in `build_request/3` (Step 3). Verified that 5.1's `stream/3` and
    its format-less re-send build from it. A fourth test in `claudio_adapter_tool_choice_test.exs`
    pins a stream body carrying `{"type": "none"}` next to the tools. Interfaces "Produces" names
    X1 and X3.
- Ruling: the X1 bound is a module constant of 3 continuations, counted by letting `iterations_left`
  go below 0, with no new State field and no option. Reason: the brief says "bounded, no new public
  option". Reusing `continue_paused/2` gives persistence and compaction at the boundary, as for a
  loop pause, and adds no new effect, so the three interpreters are untouched. Cost if wrong:
  `:iteration`/`:steering` events and `before_llm` hooks can see a negative `iterations_left`
  (documented in MIGRATING), and a constant would need replacing if Q wants it configurable.
- Ruling: at the bound, the paused response is converted as the answer (like a final call's ignored
  tool calls), not turned into an error. Cost if wrong: a schema agent gets `:invalid_output` from
  partial text; after X4 (AX-32), an empty paused text is `:invalid_output` anyway.

### Cross-task items seen in this phase (owned elsewhere; not fixed here)
- X4: every test client added in 5.2a/5.2b answers non-empty text on its final call (`"done"`,
  `"Paris: weather in Paris"`, `{"action": "stop"}`, `"Still searching."`, `"a leak in the answer"`,
  `"ok"`). The `StopReasonTest`/`ClaudioAdapterStopReasonTest` stubs end in errors, never in an answer.
- X7: 5.2b adds no `{:maybe_compact, _}` emitter. Both the cap notice and the X1 continuation go
  through `apply_tool_results/2`, so 5.5b's change there covers them. A continued final call reaches
  `:maybe_compact` with `iterations_left` ≤ 0, and 5.5b's `mid_round` must treat that boundary like a
  loop pause's.
- Flake: the `base_agent_stream_errors_test.exs` / `turn_error_test.exs` log leak above can fail any
  phase's precommit at random.

## Phase 3 (5.4a, 5.4b)

`mix docs --warnings-as-errors` exited 0 after 5.4a and again after 5.4b.

### Task 5.4a — FIXED
- Commit `3d81a56`.
- Precommit: `72 doctests, 28 properties, 3222 tests, 0 failures (203 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)" (34 skipped). No flake this run.
- Step 2 failed as stated: `init/1` and `Toolset.register/3` unknown-option errors, `KeyError` in
  the template tests, invalid UTF-8 `is_error: false`, map-config cases uncapped (22 failures).
  Step 9: 2 doctests, 403 tests, 0 failures; `tool_result_cap_test.exs` has 18 tests, as stated.
- Checked, holds stacked: no task before 5.4a touches `dispatch.ex`, `toolset.ex`,
  `tool_result.ex`, `server_glue.ex`, `metadata.ex`, `telemetry.ex` or `config_template.ex`
  (`git diff 0dccd48 564212d`). Earlier tasks only touch `base_agent.ex`, `init_options.ex` and
  `base_agent_config.ex`, and the option-name anchors still matched. No `doctest Normandy.Tools.Toolset`.
  The server-built results (interrupted, rejected, expired) are under 200 characters as JSON.
- Text corrections (5.4.md):
  - Step 6: `grep -n "answer(config" lib/normandy/agents/dispatch.ex` gives **6**, not 5. The grep
    also matches the `defp answer(config, call, result, pipeline),` head. The text now says
    "6, the `defp answer(config, ...)` head plus 5 call sites".
  - Step 2: the three error-result cases (error result, classify/3 miss, budget denial) fail with
    `FunctionClauseError` in `Kernel.=~/2` because the uncapped output is still a `%{error: ...}`
    map. The Expected line now says this.
- Rulings: none.

### Task 5.4b — PASS
- Commit `935bbd5`.
- Precommit: `72 doctests, 28 properties, 3251 tests, 0 failures (222 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)". Dialyzer skipped 36, 2 more than
  5.4a. That matches the claim that the new ignore entry covers two `unmatched_return`s.
- Step 2 failed as stated. There were `put/5 required by behaviour ... is not implemented`
  warnings for all 8 stubs, an `UndefinedFunctionError` for `InMemory/ETS/Mnesia.put/6` and
  `MemoryStore.check_limits/3`, `Docs.put/5` undefined, and `Memory.new/1` raising
  `unknown option :max_namespace_documents` (32 failures). After Step 4, the in-node backends
  compile with no warning for `@impl true` on the defaulted `put/6`, as claimed.
  `grep -c "def put("` on the stubs gives 9 before and 8 after. Step 7's grep gives 0, and
  `@root` is still used. Step 9 ran 549 tests with 0 failures.
- Postgres: I ran `docker start normandy-test-pg` and used the existing probe database
  `normandy_test_w54probe`. It already has `normandy_memory_namespaces` with the section's
  columns, and `schema_migrations` lists 4 versions. I did not create, drop or migrate any
  database. `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` gave
  `72 doctests, 28 properties, 3310 tests, 0 failures`, exit 0 (`postgres_test.exs` alone: 38
  tests, 0 failures). A read-only `\dt` on `normandy_test` confirms Step 10's premise: it has
  `normandy_memory_documents` but no `normandy_memory_namespaces`. The section's `ecto.drop` was
  **not** run; it is still the controller's question for Q. The container is stopped again.
- Redis: `mix test.redis` gave `72 doctests, 28 properties, 3326 tests, 0 failures`, exit 0.
- Text corrections: none. One cosmetic point I did not change: Step 8's Redis sentence replacement
  leaves one guide line about 117 columns wide. Markdown is not linted.
- Rulings: none.

### Cross-task items seen in this phase (owned elsewhere; not fixed here)
- X5 (5.6b-i): `tool_result_cap_test.exs` "an output that is not valid UTF-8 becomes an error
  result" pins `output: %{error: "the tool ran, but its output is not valid UTF-8 text"}`.
  `Dispatch.invalid_utf8_output/0` builds that output. 5.6b-i must update both.
- X4: 5.4a's `BigToolClient` and the Turn.Server `call_llm` both answer `"done"`. Nothing in
  5.4b answers the model.
- X7: 5.4a/5.4b add no `{:maybe_compact, _}` emitter.

## Phase 4 (5.5a, 5.5b; X7)

`mix docs --warnings-as-errors` exited 0 after 5.5b.

### Task 5.5a — PASS
- Commit `6d431f0`.
- Precommit: `72 doctests, 28 properties, 3264 tests, 0 failures (222 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)" (36 skipped, 0 unnecessary). No flake.
- Step 2 failed as stated: 12 of 13, only `:max_tokens overrides it` passed. Stacked on 5.3b the
  first transcript test shows `Assistant: [thinking]` and an empty `Tool:` line, as the section
  says. Step 6: 437 tests, 0 failures.
- Checked, holds stacked: 5.3b left both rebuilders reading `entry.content` (`drop_thinking(entry.content)`
  in `rebuild_memory_with_summary/4`); `compress_conversation/3` forwards
  `Keyword.take(opts, [:prompt, :model, :max_tokens])`; every before-snippet in Steps 3, 4 and 8
  matched once. Step 5's perl leaves 1 `Previous conversation summary` line, as stated. The
  line numbers it quotes are 0dccd48's (stacked: 72, 306, 334, 349, 583, after 5.3b's 14 added
  lines); the perl is text-anchored, so nothing changes.
- Text corrections: none. Rulings: none.

### Task 5.5b — FIXED
- Commit `7a979bf`.
- Precommit: `72 doctests, 28 properties, 3271 tests, 0 failures (222 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)". No flake. Step 7: 2 doctests,
  6 properties, 1323 tests, 0 failures.
- Step 2 failed as stated: 4 of 7 (the core test with `MatchError`, the three shell tests with no
  `{:compact_ctx, _}`); the three `Compactor.WindowManager` tests passed. Compiling the test before
  Step 3 also gives a type-checker "pattern will never match" warning for the core test; it goes
  away with Step 3.
- X7 verified. `grep -rn maybe_compact lib` shows the core emits only the three tuples the section
  names (`step/2` `:start`, `resume/1` `:steering`, `apply_tool_results/2`); the shells only pass
  `info` on (`driver.ex`, `inline.ex`, `server.ex`). 5.2b and 5.3c added no emitter. A loop
  `pause_turn` (`continue_paused/2`), the batch that appends the cap notice, and phase 2's X1
  paused final call (`iterations_left` 0, -1, -2, ...) all go through `apply_tool_results/2`,
  so all of them now carry `mid_round: true`. `resume/1` `:steering` → `true` is right: the core's
  only `{:persist, _}` for `:steering` is in `apply_tool_results/2`. `compact_turn_memory/3`'s
  `Map.fetch!(info, :mid_round)` did not raise anywhere in the suite, including phase 2's
  four X1 shell tests in `iteration_cap_test.exs` (sync, sync at the bound, `stream/3`,
  `Turn.Server`). The core assertion for X1 is `turn_test.exs`'s paused-final-call test, which now
  pins `{:maybe_compact, %{iterations_left: -1, mid_round: true}}`.
- Text corrections (5.5.md):
  - Step 6(a): stacked, the grep gives **12** hits, not 9 (`turn_test.exs` 5: 5.2b's "an empty
    batch at the cap appends no notice" at `0` and the X1 test at `-1`; `pause_turn_test.exs` 1,
    from 5.3c). The section's perl matched `(\d+)` over four files, so it missed the `-1` hit
    (an exact `==` list; checked: that test fails with the original perl) and
    `pause_turn_test.exs` (a `=` map pattern, so it would still pass, but it no longer stated the
    rule). The regex is now `(-?\d+)`, `pause_turn_test.exs` is added to the perl, to Files and to
    Step 10's `git add`, and the Expected count is 11 `mid_round: true` over five files.
  - Step 3: the `apply_tool_results/2` bullet now says why the three tuples cover the 5.2b/5.3c
    paths (X7), including the final-call pause with `iterations_left` ≤ 0.
  - Step 5: the text added the `## Compacting mid-round` heading directly after the `:window`
    bullet. That put the existing paragraphs on `meta` and `:dropped` under the new heading.
    The bullet stays after `:window`; the section now goes at the end of the moduledoc, after
    "...rather than reading the key.". The wording is unchanged.
- Rulings: none.

### Cross-task items seen in this phase (owned elsewhere; not fixed here)
- X4: `OneRoundClient` answers `"done"` and `RecordingClient` answers `"summary"`; 5.5 adds no
  client with an empty final answer. `StreamingProbeClient` is an existing support client.
- X9: the 5.5 tests read no tool `properties`.
- `Compactor` moduledoc's first paragraph still says "After each tool batch the FSM core ... emits
  `{:maybe_compact, info}`"; since the `:start` boundary it also does so at turn start. This predates
  wave 5 and is not changed here.

## Phase 5 (5.6a, 5.6b-i, 5.6b-ii, 5.6c; X4, X5, X8, X9)

`mix docs --warnings-as-errors` exited 0 after 5.6c. Every precommit log also carries the existing
`test/fixtures/templates/generate_v1_0_0.exs` "does not match any :test_load_filters" warning (present
before this phase; not a failure).

### Task 5.6a — FIXED
- Commit `008e96e`.
- Precommit: `72 doctests, 28 properties, 3275 tests, 0 failures (222 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)" (36 skipped).
- Checked, holds stacked: of the five lib files only `memory.ex` was touched before (5.4b), and not
  in `description/1`'s heredoc; 5.5a did not touch `retry_feedback.ex` or the summarizer framing
  (5.6a does not touch it either). Step 4's grep: the only hits left outside the edited files are
  two test *names* in `validation_middleware_test.exs` ("the base input schema ...") and the new
  `"RESPONSE FORMAT ERROR"` heading; no assertion pins old text.
- Step 2 gave 12 failures, not 11.
- Text correction (5.6.md, 5.6a Step 2): `AgentToolTest` fails **5**, not 4: the three description
  tests, the new 1_000-character test and the `input_schema` hint test. The old non-matching-skill
  test only checked `=~ "skill: unknown"`, but its replacement is an exact `==`, so it fails too.
- Rulings: none.

### Task 5.6b-i — FIXED
- Commit `ab10bb1`.
- Precommit: `72 doctests, 28 properties, 3279 tests, 0 failures (222 excluded)`, exit 0, credo and
  dialyzer clean.
- Step 2 gave 27 failures in the section's file list. With 5.4a's file added it gives 28. I checked
  this by putting back the four lib files at `008e96e` and rerunning: 373 tests, 28 failures. Every
  edited dispatch builder was anchored by function name. 5.4a's `finish/3` / `answer/4` wrapping is
  untouched. `wrap_error/2`'s catch-all is 0dccd48's (5.4a did not bound it) and is kept.
- Text corrections (5.6.md, 5.6b-i):
  - X5: Files, Interfaces (Consumes 5.4a), Step 1 (new bullet for `tool_result_cap_test.exs`), Step 3
    (new item 4b: `invalid_utf8_output/0` returns the bare binary), Step 2/5 runs and Step 7's `git add`
    now include 5.4a's invalid-UTF-8 test and `invalid_utf8_output/0`. The last §36 MIGRATING bullet
    names "the invalid-UTF-8 error (§34)" among the texts sent bare.
  - Step 2: the expected count is now "28 stacked (27 + 5.4a's test)", not "23 at HEAD".
  - Step 5: the leftover grep is not "no hits". It hits the two new tests that name `pending_approval`
    (a test name in `dispatch_test.exs`, a `refute Map.has_key?` in `dispatch_split_test.exs`). The
    text now says so.
  - Step 6 MIGRATING: "the exact texts are in the `Dispatch` moduledoc" was not true, because the
    moduledoc section describes the keys, not the texts. It now says "the keys are described in".
- Ruling: Task 5.4a's invalid-UTF-8 output is sent bare (`output: "the tool ran, but its output is
  not valid UTF-8 text"`, `is_error: true`). Reason: it is a message about the tool's output, like a
  tool's `{:error, binary}` (R8/AX-15), and the brief's X5 asks for it. Cost if wrong: one test line
  and one function body to revert.
- Ruling: `unencodable_output/1` (0dccd48, "cannot be sent as JSON") keeps `%{error: ...}`. Reason:
  X5 and the section name only the UTF-8 case, and the moduledoc's "Results the model sees" lists
  `%{error: term}` for other Normandy-built errors. Cost if wrong: there are two shapes for "the
  output could not be sent". A one-line follow-up in 5.6b-i would make them one.

### Task 5.6b-ii — FIXED
- Commit `9affe7d`.
- Precommit: `72 doctests, 28 properties, 3285 tests, 0 failures (222 excluded)`, exit 0, credo and
  dialyzer clean.
- Step 2 failed as stated (7: 4 normalization tests, 2 stream tests, 1 Server test). With the lib
  change in place and before the test-client edits, the full suite had exactly the 3 failures that
  Step 4 names (`ToolContextTest`, `ToolInputIsolationTest` run/2 and Turn.Server).
- X4 verified: no test client added or changed by 5.1–5.5 ends a passing turn on an empty final
  answer. The full suite with AX-32 in place fails only on the two pre-5.1 clients that the section
  already edits. The `"text" => ""` hits in 5.1–5.5 tests are stream `content_block_start`s followed
  by deltas, or tool rounds. `WireScript` answers only what each test scripts.
- X8: `ScriptedToolClient` was untouched by 5.1–5.5 (`git diff 0dccd48 7a979bf` shows no change).
  `WireScript` (5.1) needs no change here. 5.6b-ii's `:answer` field is the only change so far, so
  5.7b must keep `answer: "done"` when it edits the client.
- Text corrections (5.6.md, 5.6b-ii):
  - Step 3: the "Users" sentence said `tool_hooks_test.exs` also failed before the client edit. It
    does not: its tests call `Dispatch` directly and never reach a final answer. Reworded.
  - Step 3: added an X4 paragraph that records the stacked check above.
- Rulings: none.

### Task 5.6c — FIXED
- Commit `0fcdf12`.
- Precommit: the first run had 1 failure, the known flake `base_agent_stream_errors_test.exs:149`.
  This time its `capture_log` caught `[error] Agent "a" raised RuntimeError` from a concurrent
  orchestration test (`TaggingClient`), so a second test also leaks into it, not only
  `turn_error_test.exs:163`. The rerun gave `72 doctests, 28 properties, 3297 tests, 0 failures
  (222 excluded)`, exit 0, credo and dialyzer clean. `mix docs --warnings-as-errors` exit 0.
- Step 2: 19 failures stacked. `wire_test.exs` compiles with an undefined-module warning (Elixir 1.19)
  and its 9 tests fail at runtime; it is not a compile error as stated.
- X9 verified: (a) The suite passes. (b) `grep` shows no 5.1–5.5 lib code that reads tool schemas
  or the translated `properties` as a map. The consumers pass them through to Claudio
  (`Request.add_tool/3` only guards `is_map/1`; `set_output_config/2` stores the map) or hash them
  (`prefix_key/3`). (c) I ran a throwaway raw-body probe through `ClaudioAdapter` + Req plug, with a
  tool whose input is an io_schema and with `output_format`, then deleted it. It showed
  `tools[0].input_schema.properties` and `output_config.format.schema.properties` both as
  `["value","type","name","id","error"]` on the wire. (d) `Introspection.get_field_metadata/2`
  returns `description: nil` for an undescribed field, as MIGRATING claims (checked with `mix run`).
- Text corrections (5.6.md, 5.6c):
  - Step 2: the expected failure is now the stacked 19 (9 Wire + 10 others), not "does not compile".
  - Step 4 (toolset): `input_schema: Tool.input_schema(tool)` occurs twice in `toolset.ex` (also in
    `build_tool_metadata/1`). The text now says to anchor on `to_tool_schemas/1`'s body.
  - Interfaces: added the X9 record above.
- Rulings: none.

### Notes for the controller (phase 5)
- `ToolCallResponse.prefix_key/3` hashes the tool schemas. After upgrading, every schema changes
  shape: Normandy schemas become `OrderedObject`s, and `title`/`$schema` are dropped from
  hand-written ones too. So a `prefix_key` stored before the upgrade will not match once, and
  replayed thinking may be dropped on the first post-upgrade turn. This is the same one-time cost
  as the prompt-cache miss that §36 already mentions.
- The section's proposed CLAUDE.md text (new prompt headings, `Normandy.Schema.Wire`) still stands.
  CLAUDE.md's "Prompt System" bullets name the old headings.

## Phase 6 (5.7a, 5.7b, 5.7c, 5.7d; X6, X8) and the final gate

`mix docs --warnings-as-errors` exited 0 after each of the four tasks. Logs are in the scratchpad
(`w5-5.7a.log` ... `w5-5.7d.log`, `w5-final-*.log`). No flake in any phase 6 run.

### Task 5.7a — FIXED
- Commit `60a4968`.
- Precommit: `72 doctests, 28 properties, 3307 tests, 0 failures (222 excluded)`, exit 0, credo
  "found no issues", dialyzer "done (passed successfully)" (36 skipped).
- Step 2 failed as stated (6 of 10). Step 6: 2 doctests, 367 tests, 0 failures. Every lib anchor
  matched once stacked. 5.6 added a `## Results` section to `ToolWrapper`'s moduledoc, and the new
  sections still go right before `## Trace context`.
- X6 verified. `git diff 0dccd48 0fcdf12` shows 5.1–5.6 added three constructions: 5.6a's
  `AgentTool.new("https://example.com/a2a", card)` (no-skill description test) and 5.6b-ii's two
  `ToolWrapper.new(MockAdapter, {:returns, result}, tool)` calls. All three now pass `:prefix`
  (`"a2a"` / `false`), like the rest. After the change the grep finds only multi-line calls whose
  `:prefix` sits on a later line, plus the calls in `options_coverage_test.exs` and
  `integration_options_test.exs` that assert a different error on purpose.
- Text corrections (5.7.md, 5.7a Step 5):
  - MCP grep: stacked it gives **20** hits, not 18. `tool_wrapper_test.exs` has 7, not 5, because of
    5.6b-ii's two calls. After the change it gives **1**, not 0: `two_tool_registry/0`'s multi-line
    call, where `mix format` puts `prefix: false` on its own line. This was true at 0dccd48 too.
  - `agent_tool_test.exs`: **9** `AgentTool.new(` calls, not 8. The section listed them by line
    number at 0dccd48; they are now listed by test, including 5.6a's.
- Rulings: none.

### Task 5.7b — PASS
- Commit `6c3ac08`.
- Precommit: `72 doctests, 28 properties, 3329 tests, 0 failures (222 excluded)`, exit 0, credo and
  dialyzer clean.
- Step 2 failed as stated. `guard_crash_test.exs` does not compile (GuardError undefined). In the
  other two files, 11 of 13 fail and the "unaffected" and "read-only views" tests pass. Step 5:
  94 tests. Step 6: 61. Step 8: 356. All passed.
- Checked, holds stacked: 5.4b's `max_namespace_documents` and 5.6's `Memory.description/1` are
  untouched. The `namespace!/2`, `validate_mounts!/1` and "Never store secrets in memory."
  anchors matched. The dispatch test passes against 5.6b-i's bare error output.
- X8 verified: 5.7b does not edit `ScriptedToolClient` (`git diff 0fcdf12 6c3ac08 --
  test/support/scripted_tool_client.ex` is empty). The `:tool_context` test in
  `server_limits_test.exs` relies on 5.6b-ii's `answer: "done"` default and passes.
  `WireScript` is untouched. 5.7.md's "Notes for the controller" warned about this interaction;
  that note is now marked resolved.
- Text corrections: one, in Notes for the controller (the X8 note above). None in the steps.
- Rulings: none.

### Task 5.7c — FIXED
- Commit `eebab5b`.
- Precommit: `72 doctests, 28 properties, 3342 tests, 0 failures (222 excluded)`, exit 0, credo and
  dialyzer clean. The `server_integration_test.exs:101` flake that the section warned about did not
  occur.
- Step 2 failed as stated (12 of 13; "a template that passes runs as before" passes). Step 8:
  6 properties, 891 tests, 0 failures. Fields added to the template by 5.4a
  (`max_tool_result_chars`) and 5.5 are plain data, so `check_loaded!/1` accepts them.
  `E2E.S13.Budget` declares its behaviour, as claimed.
- Text correction (5.7.md, 5.7c Step 3): after `unstorable?/1` is deleted, the comment above
  `storable_hooks!/1` still says "as unstorable?/1 does for the fields above". The step now says to
  change it to `storable_fields!/1`. Neither the compiler nor credo catches this.
- Rulings: none.

### Task 5.7d — PASS
- Commit `7b4d9b4`.
- Precommit: `72 doctests, 28 properties, 3356 tests, 0 failures (222 excluded)`, exit 0, credo and
  dialyzer clean.
- Step 2 failed as stated (12 of 14; SEC-10 and "other exceptions keep their message" pass).
  Step 10: 853 tests, 0 failures. Step 4's `inspect(reason)` grep prints nothing. 5.6 had not
  reworded `ToolWrapper.run/2`'s error clause, so only `inspect(reason)` changed. The
  `claudio_adapter_test.exs` "Inspect protocol" test still passes.
- Text corrections: none. Rulings: none.

### Final gate
On `w5-preflight` at `7b4d9b4` (0dccd48 + Tasks 5.1–5.7d, 18 commits).
- `mix precommit 2>&1 | tee w5-final-precommit.log`: `72 doctests, 28 properties, 3356 tests,
  0 failures (222 excluded)`, exit 0, credo "found no issues", dialyzer "done (passed
  successfully)" (36 skipped, 0 unnecessary). The log also carries the existing
  `generate_v1_0_0.exs` `:test_load_filters` warning (not a failure).
- `mix docs --warnings-as-errors`: exit 0.
- `mix test.redis` (container `normandy-test-redis`, already up): `72 doctests, 28 properties,
  3431 tests, 0 failures (147 excluded)`, exit 0.
- Postgres: `docker start normandy-test-pg`, then `MIX_TEST_PARTITION=_w54probe
  POSTGRES_PORT=55432 mix test.postgres` against `normandy_test_w54probe`: `72 doctests,
  28 properties, 3415 tests, 0 failures (163 excluded)`, exit 0. No database was created or
  dropped. The alias's `ecto.create --quiet`/`ecto.migrate --quiet` found the probe database
  existing and current.
- Distributed (CI's form: `epmd` up, `NORMANDY_REDIS=true MIX_TEST_PARTITION=_w54probe
  POSTGRES_PORT=55432 mix test.postgres --only distributed`), run twice: `68 tests, 0 failures
  (3610 excluded)` both times, exit 0.
- Postgres container stopped again (`Exited (0)`). Redis left running, as it was found.
- `mix hex.build --unpack -o <scratchpad>/w5-hexbuild`: exit 0, no warnings. The package
  includes the new `lib/normandy/guardrails/guard_error.ex` and `lib/normandy/llm/client_inspect.ex`.

### Decision 23 amendments
On `w5-preflight`: one commit `02d0ac7` ("preflight: decision 23 amendments") on `7b4d9b4`. The
worktree is left in place.
- `mix precommit 2>&1 | tee <scratchpad>/w5-d23-precommit.log`: `72 doctests, 28 properties,
  3361 tests, 0 failures (222 excluded)`, exit 0, credo "found no issues", dialyzer "done
  (passed successfully)" (36 skipped, 0 unnecessary). +5 tests over `7b4d9b4`: X1's one
  "answered after 3" shell test became three error tests (run/3, stream/3, Turn.Server), and
  `low_findings_test.exs` gained three. Run twice (before and after a MIGRATING-only amend of
  the commit), both identical. `mix docs --warnings-as-errors`: exit 0. The known
  `base_agent_stream_errors_test.exs:149` flake did not fire in either run.
- B1/B2 (Task 5.2b): `%Turn.State{}` gains `final_pauses: 0` (type `non_neg_integer()`;
  `iterations_left` becomes `non_neg_integer()`); `apply_tool_results/2` uses
  `max(s.iterations_left - 1, 0)`; the `awaiting_final` clause continues while
  `final_pauses < 3`, then `fail_paused_final/2` emits `{:fail, %LLMError{type: :pause_turn}}`
  (`retryable?: false`, `reason: {:stop_reason, :pause_turn}`, usage from the response's
  `:usage`). `final_pauses` is read with `Map.get(s, :final_pauses, 0)` (a pre-2.0 persisted
  state decodes without it, like `tokens_compacted`). New `LLMError` type `:pause_turn`.
  Finding: `Turn.Driver` raised `RuntimeError "Turn FSM reached :failed unexpectedly"` for
  every `{:fail, _}`, so BaseAgent's sync and stream paths would have crashed instead of
  returning the error; a `{:fail, %LLMError{}}` clause now raises the error, which
  `run/3`/`stream/3` return. `Turn.Inline` and `Turn.Server` needed no change
  (`TurnError.from_reason/1` replies an `LLMError` bare). Breaker (decision 20): no change;
  the error is built by the core outside `CircuitBreaker.run/3`, and `endpoint_reason?/1`
  counts only `retryable?` or `@endpoint_failure_types`. `LLMError.@types`/`error_type` are the
  only lists of types in `lib`.
- "Usage kept" holds only where the paused response carries `:usage`: BaseAgent's handlers
  return `%ToolCallResponse{}` (no usage field), so the error's `usage` is `nil` on run/3,
  stream/3 and Turn.Server; each call's usage stays on its `llm_call` span. Documented in the
  `LLMError` moduledoc and the plan. Not changed: carrying usage would need a response
  wrapper through all three interpreters.
- Position check, Task 5.2b (tree exported from `564212d`, amended text applied in its
  pre-5.5b form): Step 8 `6 properties, 1338 tests, 0 failures (8 excluded)` (unamended
  1336); `mix precommit` `72 doctests, 28 properties, 3199 tests, 0 failures (203
  excluded)`, exit 0, credo/dialyzer clean (33 skipped). Step 2 on 5.2a's `lib`: 29 failures
  (unamended text: 27; the preflight had recorded 19, which this measurement does not
  reproduce; the plan now states 29 and both measurements).
- Task 5.5b Step 6(a): with no negative count, the perl regex is back to `(\d+)` and the grep
  to `[0-9]\+`; on the amended 5.2b test text: 12 hits, 11 `mid_round: true` after the perl,
  and `turn_test.exs`, `turn_compaction_test.exs`, `pause_turn_test.exs`,
  `turn/resume_test.exs` equal the stacked files byte for byte (`turn_approval_test.exs`
  differs only by Task 5.6b-i's later edits).
- B3 (Task 5.6b-i): `unencodable_output/1` returns the bare string; three existing tests
  (`json_struct_encoding_test.exs`, `turn/server_test.exs` "an after_tool output JSON cannot
  express on a rejected result ...", `tool_hooks_test.exs` `assert_safe_error/2`, 3 tests)
  match the binary. Position check on `ab10bb1`: Step 5 run 373 tests, 0 failures; `mix test`
  3279 tests, 0 failures. Step 2 on 5.6a's `lib`: 33 failures (unamended 28, as recorded).
- B11 (Task 5.6c): MIGRATING §36 bullet. Correction to the brief: `drop_stale_thinking/2`
  runs per request on a copy and never edits memory, so pre-upgrade thinking is left out of
  every request after the upgrade (not "once"); thinking produced after the upgrade replays
  normally. 5.6a's heading change alone already changes the prefix key.
- B8 (Task 5.7d): `CircuitBreaker.sanitize_url/1` is private, so `ClientInspect.url/1` copies
  its rule (scheme, host, port, path) for `base_url` and `options.base_url`; a URL with no
  scheme or host prints `"**redacted**"` (the breaker uses `nil`). Test: userinfo, query and
  fragment absent on both adapters and via `options.base_url`.
- B12 (Task 5.7d): `SemanticScope.check/3`/`classify/4` and
  `Turn.Session.validate_session_id/1` use `Describe.type_of/1`; the classifier message also
  says "(reason an atom)", since `{:block, "text"}` now reads `got: a tuple`. Tests assert a
  `SECRET-` value is absent. Step 2 on 5.7c's `lib`: 15 of 17 tests fail.
- Not re-run: Redis, Postgres, distributed suites (no store or backend code changed).
