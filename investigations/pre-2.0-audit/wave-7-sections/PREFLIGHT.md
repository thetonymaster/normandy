# Wave 7 preflight log (integrated probe run on branch `w7-preflight`, from `5cf6e65`)

### Task 7.0a — FIXED
- Commit `3f13ca5`. Precommit: 74 doctests, 33 properties, 3643 tests, 0 failures (253 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0.
- Step 2 expected failures matched exactly (16 failures: counts 5/2, 40/16, 12/6; 2 `UndefinedFunctionError`; UTF-8 message text).
- Text correction: Step 4 "Check" — `grep -rn render_output lib` also hits a comment in `lib/normandy/json.ex:133` ("Callers: ToolResult.render_output/1 and ..."), which stays true; the check text now says so. No code change.

### Task 7.0b — FIXED
- Commit `b5a7bae`. Precommit (rerun after the fix): 74 doctests, 33 properties, 3656 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0. Tagged: `mix test.redis` 3755 tests, 0 failures; `mix test.postgres` (`_w54probe`, port 55432) 3725 tests, 0 failures; distributed 79 tests, 0 failures. `--trace` confirms the two new cases ran on Redis and Postgres. Step 7 file run 3x green (179 tests); `terminal_save_test.exs` alone 3x green (9 tests).
- Step 2 expected failures matched (8 of 9 in `terminal_save_test.exs`, ETS and Mnesia the same two cases; the paused-turn guard passes).
- Text correction: Step 1, `terminal_save_test.exs` "whose history ends in a paused turn calls the model": `assert_receive {:converse, _request, _opts}` → `assert_receive {:converse, _request, _opts}, 5_000` with a comment. Why: the first `mix test.redis` run (seed 984098) failed it with "no matching message after 100ms"; it reproduced with the same seed and passed with the longer timeout (the eager load, resume and the call's task run before the message; the full suite under Redis is slower than 100 ms).
- Note (not corrected): Step 9.1's replacement line in §39 is ~125 chars, longer than the file's wrap width; applied as written.

### Task 7.0c — FIXED
- Commit `086bd30`. Precommit: 74 doctests, 33 properties, 3661 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0. Step 7: `blank_answer_test.exs` 9, `summarizer_test.exs` 30, `test/dsl` 109 (all as stated); the step's full command 576 tests + 42 doctests, 0 failures; `test_load_filters` grep 1 → 0.
- Verified Step 1 item 5's claim: with Steps 3-5 applied and the item-5 edits reverted, exactly 25 tests fail in the 8 listed files (HierarchicalCoordinator 12, BaseAgentGuardrails 4, AgentProcess 3, BaseAgents 2, one each in RunResult, AgentSupervisor, Reactive, DSL AgentGuardrails).
- Text correction 1: Step 1 item 4, `stub_client.ex` before-snippet did not match — the sentence "...response model unchanged." continues on the same line ("Any other tuple (such as a 1.x ..."). Before/after now cover the whole four lines through "`Normandy.LLM.Call` to reject."
- Text correction 2: Step 2, the moduledoc test's expected failure. On Elixir 1.19.5 it fails first at `assert stderr == ""` (the "clause will never match {:error, reason}" warning in `ResearchWorkflow.after_step/2`), not with `Protocol.UndefinedError`; the text now names both (the latter on a compiler that does not warn).
- Text correction 3: Step 5.1, the `:final_review` transform: `"\nQuality: "` inside the plain `@moduledoc` heredoc renders as a real newline (verified with `Code.fetch_docs`: the example's string broke across two lines). Now `"\\nQuality: "` in the source, rendering `"\nQuality: "`, with a one-line note under Step 5. Test still passes (the compiled example holds a newline either way).

### Task 7.0b — follow-up FIXED (found during 7.0d's gate)
- Commit `985cd75`. The 7.0d precommit (seed 411278) failed `terminal_save_test.exs` "is saved by the retry timer with no turn request": `left: {:save, :stopped, false, :refused}`. Cause: `TerminalSaveStore.save_turn_state/4` records an `:ok` save after the wrapped store's write, so `wait_until(list_resumable == {:ok, []})` can return before the record. Not a server bug.
- Text correction: Task 7.0b Step 1, that test now waits on the recorded op (`wait_until(fn -> List.last(TerminalSaveStore.ops(ctx.store)) == {:save, :stopped, false, :ok} end, 300)`), then asserts `list_resumable` and `load_turn_state`. File 3x green; precommit rerun green.

### Task 7.0d — PASS
- Commit `c2c743e`. Precommit (rerun after the 7.0b follow-up): 74 doctests, 33 properties, 3661 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0; distributed (`_w54probe`, port 55432) 79 tests, 0 failures. Step 2: 23 tests, 0 failures. Step 3 grep output identical to the plan's list. Step 4: `mix.lock` unchanged, `deps.unlock --check-unused` exit 0. MIGRATING §43 then §44 then Known limits (Y1 holds so far).
- No text corrections.

Phase 1 end: `normandy-test-pg` stopped (started in this phase).

## Phase 2 (7.2a, 7.2b, 7.3a, 7.3b, 7.3c)

### Task 7.2a — PASS
- Commit `cd0f1a1`. Precommit (seed 220353): 74 doctests, 33 properties, 3663 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0 (dev and default env).
- Step 2 failed as stated (1 of 2, all 18 listed). Step 3 script: 18 files changed; the three over-long comment lines were exactly the ones the step names (other >120-byte lines in `runner.ex` are pre-existing box-drawing separators, under 120 chars). Every Step 4 before-snippet matched once. Step 5: 207 tests + 4 doctests green; `docs_groups_test.exs` 2, `guide_examples_test.exs` 3; dev docs 0 warnings. §45 inserted before Known limits, after §44 (Y1 holds).
- Not re-observed: the intermediate "19 hidden-reference warnings" count before Step 4 (Step 4 was applied before the first docs build).
- No text corrections.

### Task 7.2b — FIXED
- Commit `ac47b20`. Precommit (seed 713981): 74 doctests, 33 properties, 3665 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0. Step 4: 4 tests; sidebar check `0` ungrouped modules, no `"Exceptions"` group, extras `Guides: 3`, `Upgrading and changes: 2`, `"": 4`.
- Step 2: the ungrouped list was exactly the 72 modules Step 3 adds (no module added by 7.0a-7.2a). The `mix.exs` replacement anchors (`# groups_for_extras: [` … `# Old entries name functions since removed`) matched.
- Text correction: Step 2, the README test's expected failure. It reads the groups in today's `mix.exs`, so it reports `[:Components, :"Batch Processing", :Errors, :Telemetry]`, not the ten-group list (which named groups Step 3 has not added yet). Now says so.

### Task 7.3a — PASS
- Commit `82b83bd`. Precommit (seed 393804): 74 doctests, 33 properties, 3667 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; docs exit 0.
- Step 2 failed exactly as stated (2 of 2, the three functions in the stated order). The three `@spec` anchors matched once each (7.0c's edits did not touch them). Step 5: 2 tests.
- No text corrections.

### Task 7.3b — PASS
- Commit `a769a28`. Precommit (seed 749641): 74 doctests, 33 properties, 3691 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; docs exit 0.
- Step 2 failures as stated (the compile error naming `ScriptExhaustedError.__struct__/1`; `assert Normandy.Test.FakeClient in shipped`). Step 6: 44 tests (`fake_client_test.exs` 23, run 4x green; `shipped_names_test.exs` 1). `@validated` anchor `"lib/normandy/resilience/circuit_breaker.ex",` matched; `Testing: []` replaced by the two modules (Y3 holds). §45 append after 7.2a's bullets (Y1/R8 hold). Y2: no FakeClient test relies on a `nil` `chat_message`.
- No text corrections.

### Task 7.3c — FIXED
- Commit `0ab1fad`. Precommit (seed 24477): 74 doctests, 33 properties, 3691 tests, 0 failures (257 excluded) — same total as after 7.3b (no test added or removed); credo no issues; dialyzer passed; docs exit 0. Step 1 grep: exactly the ten files. Step 2 compile error as stated. Step 5: 108 tests, 0 failures; grep prints nothing.
- Text correction 1: Step 4, the `blank_answer_test.exs` hunk did not apply (`git apply`: patch failed at line 12): Task 7.0c added `alias Normandy.Test.ReturnTool` and `alias Normandy.Test.StubClient` around the `ScriptedTextClient` alias. The hunk is now written against the file as 7.0c leaves it (`@@ -14,14 +14,14 @@`, `FakeClient` inserted before `ReturnTool`), and the lead-in says so. Verified: the corrected hunk reverse-applies on `0ab1fad`. The other nine hunks applied cleanly with `git apply`.
- Text correction 2: Step 5's expected count is now exact: 108 tests (106 at `9131274` + 7.0c's 2 in `blank_answer_test.exs`).

Phase 2 notes: `terminal_save_test.exs` did not fail in any phase-2 gate (seeds 220353, 713981, 393804, 749641, 24477). No tagged suite run (none named by 7.2a-7.3c). `normandy-test-pg` not started in this phase.

## Phase 3 (7.3d, 7.3e, 7.3f, 7.3g1, 7.3g2)

### Task 7.3d — FIXED
- Commit `91ddf36`. Precommit (rerun, seed 110946): 74 doctests, 33 properties, 3752 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0. Tagged: `mix test.redis` (seed 525812) 3851 tests, 0 failures; `mix test.postgres` (`_w54probe`, port 55432, seed 213044) 3821 tests, 0 failures; distributed (seed 146201) 79 tests, 0 failures. `terminal_save_test.exs` did not fail in any of these runs.
- Step 2 failed as stated (`module Normandy.Test.SessionStoreContract is not loaded and could not be found`). Y5: contract counts still 16/33 after 7.0b (`TerminalSaveCases` is a separate `use` in the backend files, not part of the contract). Step 10: 351 tests across the three dirs; `contracts_test.exs` 61. Every before-snippet in Steps 4-5 and 8 matched once. MIGRATING §45 append after 7.3b's FakeClient bullet (Y1/R8 hold). Y3: the three contracts appended to `Testing:` after the two FakeClient modules.
- First precommit (seed 606572) failed 1 test outside this task: `session_delete_test.exs:170` "through the Horde supervisor too" — `FunctionClauseError` in `Horde.DynamicSupervisorImpl.handle_info/2` (horde 0.10.0, `dynamic_supervisor_impl.ex:355`) on `{:EXIT, #PID<..>, :normal}` during `start_child`. Not reproduced: same seed full suite green, file 3x green. The impl traps exits and has no `:EXIT` clause; a linked process exiting `:normal` crashes it. Not caused by 7.3d (no runtime code touched). Not investigated further; flagged as a risk.
- Text correction 1: Step 7, the `# 13` count of `use Normandy.Test.*Contract` lines is 15 (Step 1's `contracts_test.exs` holds two). Comment now says so.
- Text correction 2: Step 9, the `Testing:` list holds `FakeClient` and `FakeClient.ScriptExhaustedError` after 7.3b; text says to add a comma after the latter and append.
- Text correction 3: Step 12, the distributed run now carries `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432` (as the Global Constraints and brief run it).
- Text correction 4: Step 14, `git status` shows two `renamed:` entries; the rewritten registry contract appears as `deleted:` + `new file:` (rename detection fails on a full rewrite).

### Task 7.3e — FIXED
- Commit `98b9938`. Precommit (seed 105179): 74 doctests, 33 properties, 3761 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0 (0 warnings), `doc/testing.html` exists.
- Step 2 failed as stated (`File.Error`, 9 invalid). Step 5: 9 tests, 0 failures, plain and `--trace`. `groups_for_extras` matches guides by regex (`~r{docs/guides/.*}`), so no path added. README anchor matched once. §45 append after 7.3d's bullets (Y1/R8 hold).
- Text correction: Step 3, the guide's "Hooks" section named `Normandy.Hooks.Runner` in backticks; Task 7.2a hides that module (H7), so `mix docs --warnings-as-errors` failed ("documentation references module \"Normandy.Hooks.Runner\" but it is hidden", `testing.md:283`). The paragraph now says to run the hook through an agent (`BaseAgent.run/3` on a config whose `behaviours` lists it), matching 7.2a's MIGRATING bullet and the hooks guide's "Testing a hook".

### Task 7.3f — PARTIAL
- Commit `46bda7a`. Precommit (seed 873354): 74 doctests, 33 properties, 3761 tests, 0 failures (257 excluded); credo no issues; dialyzer passed. Docs: test-only change; covered by the phase-end `mix docs` run.
- Y4: enumeration command (dev build) prints **87**, and the set is identical to the plan's: the 69 lines of `@not_yet_documented` plus the 18 7.3f1 entries of the table. No module added by 7.3b/7.3d/7.3e shows up (their docs are complete; Y3 holds). No list or count correction needed.
- 7.3f1 Step 1 applied verbatim; Step 2 failed exactly as stated (`expected @doc on:` the 18 7.3f1 entries, incl. `BaseAgentInputSchema:function:get_json_schema/0`, `Model:callback:converse/3`).
- Not applied (per brief Y4): the 87 docs of 7.3f1-f4. To keep the gate green, the committed test carries the 18 7.3f1 entries at the top of `@not_yet_documented` under a `# PREFLIGHT ONLY` comment (87 entries total). The real 7.3f1 removes them by writing the docs.
- No text corrections.

### Task 7.3g1 — PASS
- Commit `965b4fe`. Precommit (seed 480575): 75 doctests (+1), 33 properties, 3762 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0 (0 warnings).
- Step 2 failed exactly as stated (the seven files, same order); `input_test.exs` 1 doctest, 20 tests green. Step 3: `grep -rc "iex>" lib` left exactly `type.ex:63`, `tools/input.ex:1`, `coordination/pattern.ex:58`, `telemetry/usage.ex:4`; the `guardrails.ex` result matches the plan's sample; the toolset struct grep prints 0; moduledoc anchor matched once. No new lib file from 7.3b/7.3d/7.3e holds `iex>`. Step 4: 1 doctest, 75 tests, 0 failures.
- No text corrections.

### Task 7.3g2 — FIXED
- Commit `d541015`. Precommit (seed 893953): 75 doctests, 33 properties, 3770 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0 (0 warnings).
- Step 2 failed exactly as stated (10 failures: DX-34 list identical — 7.3e's `testing.md` adds no other id; DX-35; DX-20 ×3; field options ×3, the duplicate one a `RuntimeError`; readme ×2). Every Step 3-6 before-snippet matched once; `check_options!` grep shows the call plus three clauses. Step 5: 7 replacements (README 1, hooks 2, agent-memory 3, `dsl/agent.ex` 1), `claude-sonnet` grep 0; README Documentation list: distributed, hooks, memory, then 7.3e's testing line. Step 7: 127 tests green; `devex_docs_test.exs` + `readme_test.exs` 8; `mix hex.build --unpack` lists `MIGRATING-2.0.md` (built into the scratch dir, removed after). Step 9 appended at the end of `## New, non-breaking`.
- Text correction: Step 1's note `grep -rn "invalid option\|schema already defined" test` also matches two unrelated test names ("invalid options" in `config_template_test.exs:525`, `base_agent_compaction_config_test.exs:101`); the grep is now `"invalid option :\|..."` with a sentence naming the two.

Phase 3 end: `normandy-test-pg` stopped (started in this phase for 7.3d). Flakes seen this phase: one Horde `session_delete_test.exs:170` failure (seed 606572, not reproduced; see 7.3d). `terminal_save_test.exs` did not fail in any phase-3 run (precommit seeds 606572, 110946, 105179, 873354, 480575, 893953; Redis 525812; Postgres 213044; distributed 146201).

## Phase 4 (7.3h-i, 7.3h-ii, 7.3h-iii, 7.3h-iv, 7.3h-v, 7.5a, 7.1a)

### Task 7.3h-i — FIXED
- Commit `34efe4f`. Precommit (seed 640388): 75 doctests, 33 properties, 3770 tests, 0 failures (257 excluded) — same total as after 7.3g2 (two tests replaced by two); credo no issues; dialyzer passed; `mix docs --warnings-as-errors` exit 0.
- Step 2 failed exactly as stated (2 failures, both `Expected exception ArgumentError but nothing was raised`). Every before-snippet in Steps 1, 3-5 and 8 matched once (the `behaviours`/`put_declared_hooks` anchors untouched by earlier tasks). §46 created after §45, before Known limits (Y1 holds).
- Text correction: Step 6, "108 tests on HEAD `9131274` plus the probe" → exact stacked count, 109 tests (Task 7.0c brings `test/dsl` to 109; this task replaces two by two).
- Steps that belong to the **missing-model half** (plan Appendix A2 / H12; drop these if Q keeps the "model given to `new/1`" path):
  - Step 1: deleting the `NoModelAgent` module; replacing `"an agent that declares no model raises, naming new/1"` and `"a model given to new/1 serves an agent that declares none"` by `"an agent block without a model does not compile"` (the mixed-prompt test is the other half and is simply added); the `NoModelAgent` → `TestAgent` edit in `"a misspelled :model is named, not reported missing"` (needed only because the module goes); the Step 1 `grep` check.
  - Step 2: one of the two expected failures (with the half dropped: 1 failure).
  - Step 3: the first `if` of `check_declarations!/1` (the no-model raise) and its message in **Interfaces → Produces**.
  - Step 4 entirely (the runtime `requires :model` check stays).
  - Step 5: the "without `model`" clause of the Features bullet (keep "`new/1` raises without a model" and add only the mixed-prompt sentence).
  - Step 6 count: 110 instead of 109 (the two old tests stay, one test added).
  - Step 8: the `## 21.` replacement and the first `## 46.` bullet (§46 then opens with the mixed-prompt bullet).
  - The task title and intro sentence "without a model or" and the commit subject.

### Task 7.3h-ii — PASS
- Commit `f7499e6`. Precommit (seed 47417): 75 doctests, 33 properties, 3770 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; docs exit 0.
- Step 2 failed as stated (1 failure). Step 3 every edit matched; `grep -n "context" lib/normandy/dsl/workflow.ex` → no output. Step 4: 62 tests (as stated). Step 6's `## 30.` sentence matched once; §46 append after 7.3h-i's bullets.
- Notes (no correction): the intro's line numbers (`dsl/workflow.ex:156-161`, `:454`, …) are now `:162-167`, `:475`, `:483`, `:501`, `:504` (Task 7.0c's `__after_condition__/3` shifted them); the steps anchor on text, so nothing fails. In `## 30.` the shortened sentence leaves `` `HierarchicalCoordinator.execute/3`'s `` at the end of one line and `` `:manager_prompt` is a string. `` alone on the next (wrap only).

### Task 7.3h-iii — FIXED
- Commit `a40364c`. Precommit (seed 877814): 75 doctests, 33 properties, 3761 tests, 0 failures (257 excluded) — 9 fewer (−9 filter tests, −1 "no properties" test, +1 "filters are gone"); credo no issues; dialyzer passed; docs exit 0.
- Step 1 grep check → the three `refute` lines only. Step 3: the deletions left `list_metadata/1` followed by `introspect_schema/2`'s `@doc` and `get_schema_introspection/1` by `valid_name?/1`'s; grep check no output; `mix compile --warnings-as-errors` exit 0. Step 4: 48 tests (as stated). `doc_coverage_test.exs` names none of the removed functions.
- Text correction: Step 2's failure message is `Expected false or nil, got true` (what ExUnit prints for a failed `refute`), not `Expected truthy, got false`.

### Task 7.3h-iv — PASS
- Commit `9738d65`. Precommit (seed 164752): 75 doctests, 33 properties, 3763 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; docs exit 0.
- Step 2 failed exactly as stated (2 failures, `warned_key/0 is undefined or private`). Step 4: 31 tests (as stated). Every anchor matched once; note `    behaviours = Keyword.fetch!(opts, :behaviours)` occurs twice in `base_agent.ex` (`init/1` and `check_init!/1`); the text says "In `init/1`", which disambiguates.
- Note (no correction): dialyzer's skipped count rises 42 → 43: `warned_key/0`'s `@spec warned_key() :: term()` is a `contract_supertype` (`model_catalog.ex:88`), suppressed by the existing `~r"is a supertype of the success typing"` filter. `@spec warned_key() :: {module(), :deprecation_warned}` would avoid it; left as written.

### Task 7.3h-v — FIXED
- Commit `d9c6a94`. Precommit (seed 540475): 75 doctests, 33 properties, 3765 tests, 0 failures (257 excluded); credo no issues; dialyzer passed; docs exit 0.
- Step 3: 51 `D` lines; `git ls-files examples` → `examples/README.md`, `examples/tools/weather.ex`. Y6: the scratch worktree is a fresh checkout, so no ignored `_build/`, `deps/`, `reports/` leftovers existed and no `??` line appeared (on Q's main tree they will, as the task says). Step 4 check: `use Normandy.Tool` 1 hit; the module is `MyApp.Tools.Weather` and uses Open-Meteo, as the README says. Step 5: 2 tests. Commit: 51 `D` + `M examples/README.md`.
- Text correction: Step 2's messages are `Expected false or nil, got true` (first `refute File.exists?`) and `Refute with =~ failed` (`refute text =~ "customer_support_app"`).

### Task 7.5a — PASS (Claudio worktree, detached)
- Worktree `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-claudio`, detached from `feat/add-messages` (`1490b75`); commits `dce2fd3` (fix) and `81c8d4e` (`chore(release): 0.7.1`), no branch created; `git log --oneline main..HEAD` → the 4 expected commits. Claudio's `feat/add-messages` (`1490b75`) and `main` (`005c51d`) unchanged; its main tree still shows only `?? .claude/worktrees/`, `?? Claudio`. Left in place for phase 5.
- Step 1 replaced by the brief's worktree (not `git switch`). Step 3: exactly the 3 stated failures, each a `left:` without `"citations"`; the "without the key" test passed. Step 5: 180 tests, 0 failures. Claudio precommit (its CLAUDE.md `mix precommit`; integration tests stay excluded, no API key used) seed 543361: 867 tests, 0 failures (52 excluded); credo no issues; dialyzer 0 errors; `mix docs --warnings-as-errors` exit 0.
- Every anchor matched (`:266`, `:344`, `block_to_api/1`, `@version "0.7.0"`, `## [Unreleased]`, CLAUDE.md `:138`). The `to_assistant_content/1` doc sentence ends mid-line (" Unknown block types are passed" follows on the same line); the substring replacement still applies cleanly.
- No text corrections.

### Task 7.1a — FIXED
- Commit `8f621c7`. Precommit (seed 477599): 75 doctests, 33 properties, 3769 tests, 0 failures (257 excluded) (+4); credo no issues; dialyzer passed; docs exit 0; `mix hex.build --unpack` → `tools/ not packaged` (package: CHANGELOG.md, LICENSE, MIGRATING-2.0.md, README.md, lib, mix.exs).
- Step 2 failed as stated (`Code.LoadError ... enoent`). Step 4: 4 tests, 0 failures. `mix format` leaves `api_diff.exs` and `cli.exs` byte-identical to the plan.
- Step 6 (`tools/api_diff/run.sh main`, exit 1; report `scratchpad/normandy-api-diff.IZUssZ/report.txt`, log `scratchpad/w7p4-7.1a-apidiff.log`): `changed_specs (32)`, `removed_fields (20)`, `removed_functions (50)`, `removed_modules (23)`, **`unmatched (18)`** = the plan's 10 (U1–U6) + 8 hidden modules: `Normandy.Agents.ValidationMiddleware`, `Normandy.LLM.Json.{ContentCleaner, Decoder, RetryFeedback, Scanner, SchemaBinder, SchemaTranslator}`, `Normandy.Telemetry.OtelCtx`. `Turn.Driver`, `Turn.Inline` and `SessionRegistry.Redis.Via` are in `removed_modules` but matched by existing sections. No item from 7.0a-7.3h-v is unmatched (Y7 holds: `Toolset` is new since `main`, so its removed filters are not in the diff; `:context` is an option, not an API item). Changed specs 32 vs the prototype's 33.
- Text correction 1: Step 1, the test's last `refute Enum.any?(snapshot.modules, &String.starts_with?(...))` is 99 chars; `mix format` splits it over four lines. The plan now shows the formatted form.
- Text correction 2: Step 6's expected output now lists the exact 18 unmatched items and the section counts, says which hidden modules are already matched, and why Wave 7's own removals do not appear.

Phase 4 end: `normandy-test-pg` not started (no tagged suite named by 7.3h-i..v, 7.5a, 7.1a). `terminal_save_test.exs` and the Horde `session_delete_test.exs:170` flake did not fail in any phase-4 run (precommit seeds 640388, 47417, 877814, 164752, 540475, 477599).

### Controller correction after phase 4
- 7.3h-iv Step 3: `@spec warned_key() :: term()` → `{module(), :deprecation_warned}` (phase 4 saw dialyzer's skipped count go 42 → 43 from the over-wide spec; the exact spec removes the hidden warning). Phase 5 re-applies it on the stacked branch.

## Phase 5 (controller correction, 7.1b, 7.1c, 7.4a, 7.5b, 7.6a-i, 7.6a-ii, 7.4b, 7.7)

### Controller correction (7.3h-iv warned_key spec) — FIXED
- Commit `5134200`. Precommit (seed of `w7p5-ctrl2.log`): 75 doctests, 33 properties, 3769 tests, 0 failures (257 excluded); credo no issues; dialyzer passed, **Total errors 42, Skipped 42** (back to the pre-7.3h-iv count).
- The controller's `{module(), :deprecation_warned}` did not restore 42 under `mix precommit` (MIX_ENV=test): it stayed 43, the warning still `contract_supertype` at `model_catalog.ex:88` (listed with an empty ignore file). `module()` is `atom()`, wider than the success typing's literal module. (Plain `mix dialyzer`, dev env, printed 42 with it — the phase-4 "42 → 43" was the test-env count.)
- Text correction: 7.3h-iv Step 3, `@spec warned_key() :: {__MODULE__, :deprecation_warned}` (the literal module). Test env 42, dev env 41.

### Task 7.1b — FIXED
- Commit `885daca`. Precommit (seed 381103): 75 doctests, 33 properties, 3774 tests, 0 failures (257 excluded) (+5); credo no issues; dialyzer passed (42 skipped); `mix docs --warnings-as-errors` exit 0 (after correction 2).
- Step 1 (`w7p5-7.1b-apidiff1.log`): exit 1, `changed_specs (32)`, `removed_fields (20)`, `removed_functions (50)`, `removed_modules (23)`, `unmatched (18)` — the same 18 items as 7.1a recorded (U1-U6 = 10 items + 8 hidden modules). `removed_modules` minus the 12 deleted 1.x modules = 11 (`Turn.Driver`, `Turn.Inline`, `ValidationMiddleware`, `Redis.Via`, the six `LLM.Json.*`, `OtelCtx`), all already in §45's first bullet (Task 7.2a). No item from an earlier Wave 7 task unmatched (Y7 holds).
- Step 3 failed exactly as stated (3 failures, two `MatchError`). Step 5: 5 tests, 0 failures; api_diff `## unmatched (0)`, exit 0 (section counts unchanged: 32/20/50/23). Every Step 4 anchor matched once except (b) (correction 1). Y1: §47 after §46, before Known limits; no §48; numbered 1..47.
- Text correction 1: Step 4 (b), the §5 anchor. Task 7.3h-iv extended the `ModelCatalog.Static` bullet, so it no longer ends "which is why it stays."; the text now anchors on the bullet as 7.3h-iv left it (ends "persisted templates to silence it.").
- Text correction 2: Step 4 (l), the §45 pointers. Written as given, `mix docs --warnings-as-errors` failed with 7 warnings: "documentation references module \"Normandy.Agents.Turn.Driver\" but it is hidden" (and Turn.Inline, ValidationMiddleware, LLM.Json.ContentCleaner, Telemetry.OtelCtx, SessionRegistry.Redis.Via), and "references function \"Normandy.hello/0\" but it is undefined or private" (§47). The pointers now use short code spans (`Turn.Driver`, `ValidationMiddleware`, `Json.ContentCleaner`, `OtelCtx`, `Redis.Via` — no link, still matched by api_diff's last-segment rule), and §47 says "`Normandy`'s generated placeholder `hello/0` is gone." (matched by the `name` + module-in-section rule). The block also now shows its exact placement: a blank line, an indented "If you called one directly:" paragraph, then a two-space-indented sub-list under the first bullet (the old text said "headed" without showing the heading).
- Note: the commit body quotes the Step 1 unmatched list and the final counts as Step 7 says (`/tmp` paths in Steps 6-7 replaced by the scratchpad).

### Task 7.1c — FIXED
- Commit `96b60f4`. Precommit (seed 789226): 75 doctests, 33 properties, 3774 tests, 0 failures (257 excluded); credo no issues; dialyzer passed (42); `mix docs --warnings-as-errors` exit 0. Step 1: 119 lines (as stated). Step 3: `119 rows` (order identical to the list); `migrating_test.exs` 5 tests, 0 failures; api_diff `## unmatched (0)`, exit 0.
- Triage done by four parallel read-only subagents (30/30/30/29 commits), each row checked against the diff and `git show main:<path>`; spot-checked by hand: `telemetry` `~> 1.0` on main vs `~> 1.3`, main's `validate_number/3`, main's `Tools.Registry.register/2` (silent replace). Classes: 71 `§N`, 1 `§New, non-breaking` (b853f67), 17 gaps, 27 pre-release, 3 internal.
- Gaps written (17): §18 92abfd2; §19 ca08503, e22c4f6, 02906c8; §25 3beee8b, 72b8490; §27 930e62c; §30 0d01d04; §32 5e7bbe3; §33 fa7411c; §37 b2a115f; §38 c9157ec; §40 448419f, 7b72fcc; §42 951077d; §44 f52dce7; New, non-breaking 641bd80 (`:thinking_block_binding`). Each is one bullet appended at the end of its section (wording from the triage, not reviewed line by line by Q).
- Text correction: Step 2 now says where a non-breaking gap goes and lists the 17 gaps found, noting that four (0d01d04, 72b8490, fa7411c, 930e62c) are ones 7.1b's REL-4 mapping calls "already covered" — the existing bullets state only part of each.
- Ruling: a user-visible non-breaking addition found by the triage is `gap → New, non-breaking` — the class list had no target for it — cost if wrong: one bullet moves to a numbered section.
- Follow-ups for the controller (not changed; outside the task's class set): MIGRATING §40 (`:wait_connections` with `:redis_wait`) and §41 (inbound A2A `baggage` dropped) describe pre-release behaviour a 1.3.0 user never had; "New, non-breaking" says `served_by` is reported on non-streaming calls only, out of date since ef51378 (streamed calls too); 8747a71 also makes `CircuitBreaker` count a non-tuple return as a failure (`{:unexpected_return, v}`), not in §11; 875d014's `max_messages` trim dropping thinking is not named in §33; 0473ec6's `append_entry/3` return change (entry id, not stream id) is not named in §16.

### Task 7.4a — PASS
- Commit `ea48111`. Precommit (seed 221579): 75 doctests, 33 properties, 3777 tests, 0 failures (257 excluded) (+3); credo no issues; dialyzer passed (42); `mix docs --warnings-as-errors` exit 0.
- Step 2 failed as stated (3 failures, status 127). The "Determine next version" block matched once; README replaced from `### Jobs` to `### Caching Strategy`. Step 4: 3 tests, 0 failures. Step 5 on a scratch clone of the main repo (tag `v9.9.9` on `main` in the clone only), running the **worktree's** script (the main tree has none yet): `release=false` / `No releasable commits since the last tag (cog: Pre-Hooks and Post-Hooks have been skipped.); skipping release.`, exit 0. `mktemp -d` landed in `/var/folders/.../T/` (outside every repository). Script committed mode 100755.
- Note (no correction): after the README replacement, `### Caching Strategy` (about CI) sits under the new `## Release workflow (release.yml)` heading.
- No text corrections.

### Task 7.5b — FIXED (Claudio by path, not Hex)
- Commit `d1911e0`. Precommit (seed 635316): 75 doctests, 33 properties, 3778 tests, 0 failures (257 excluded) (+1) — `wire_identity_test.exs` inside it green, no fixture rewritten; credo no issues; dialyzer passed (42); `mix docs --warnings-as-errors` exit 0.
- **Dependency, preflight only:** `{:claudio, path: ".../scratchpad/w7-claudio", override: true}` (the 7.5a worktree, `@version "0.7.1"`, commits `dce2fd3` + `81c8d4e`) instead of the task's Hex `{:claudio, "~> 0.7.1"}` + `mix deps.update claudio` (0.7.1 is not published). Side effects that the real task will not have: `mix deps.get` unlocks the path dep's children and moved `req` 0.7.4 → 0.7.5 in `mix.lock` (restoring the lock and re-running did the same); the stale `claudio` 0.7.0 lock entry stays (`deps.unlock --check-unused` exit 0). Step 7's `mix hex.build` fails by design ("Dependencies excluded from the package (only Hex packages can be dependencies): claudio"), so the `~> 0.7.1` package requirement was not checked.
- Step 2: the three replay tests failed exactly as stated (`assert Enum.at(content, 1) == @cited`). The add_messages test failed with **an empty mailbox**, not 2_000 `add_message` traces: on OTP 28 a process tracing its own calls receives nothing (verified with plain `erl`: `erlang:trace(self(), true, [call])` + `lists:seq/2` → no message; tracing a spawned process → `{trace,<pid>,call,{lists,seq,[1,2]}}`). Written as given, the test could never pass.
- Text correction: Step 1, the add_messages test now builds the request in a spawned child traced by the test process, waits for `{:built, request}`, then `:erlang.trace_delivered/1` before asserting on the traces. Verified red on the old adapter (with 0.7.1 by path: "Showing 10 of 2000 messages in the mailbox", fails at `assert_received ... :add_messages`) and green after Step 4. Step 2's wording notes ExUnit's mailbox line.
- Steps 4-6: every anchor matched once (`add_messages/3` body, the five `add_single_message/3` clauses, the dispatch comment and four clauses, the multimodal comment, §33's three lines, the claudio-gaps title). `grep -n dispatch_multimodal lib` → 0. Step 5: 5 tests, then 115 tests, 0 failures; `git status --short test/fixtures/wire_identity` empty. §44's two bullets follow 7.0d's Horde bullet and 7.1c's telemetry bullet.
- Note: claudio-gaps.md's table is followed by a paragraph; the two rows go after the table's last row.

### Task 7.6a-i — PASS
- Commit `296fae4`. Precommit (seed 7359): 75 doctests, 33 properties, 3786 tests, 0 failures (257 excluded) (+8); credo no issues; dialyzer passed (42); `mix docs --warnings-as-errors` exit 0.
- Step 2 failed exactly as stated (10 of 25: the 4 prices tests `UndefinedFunctionError`; preflight, summary, the three `parse_result` usage tests, estimate). Every anchor in `e2e/support.exs` and `runner.ex` matched once (`@model` and `def model` are separated by `@probe_events`; the `@model` line took the whole block and `def model` was dropped from its old place). Step 6: 25 tests, 0 failures (4 + 17 + 4). `e2e/support.exs` compiles without warnings (`Code.compile_file`; `model/1`, `count_remote_call/1` exported).
- Y8: `mix e2e --estimate` with no API key in the environment, before 15/16 exist: 14 rows, `estimate: $1.06 expected, $1.26 upper bound` (exit 0) — the plan's 01–14 figures. No scenario run.
- No text corrections.

### Task 7.6a-ii — PASS
- Commit `ea767f8`. Precommit (seed 574647): 75 doctests, 33 properties, 3786 tests, 0 failures (257 excluded) (no test added); credo no issues; dialyzer passed (42); `mix docs --warnings-as-errors` exit 0.
- Y8, Step 3 (no API call): both files parse; `discover` ends `{"15_preserved_thinking", 8}`, `{"16_mcp_pause", 8}`; `mix run e2e/run.exs --estimate` (no key in env) → `estimate: $1.92 expected, $2.24 upper bound (every scenario at its cap)`, rows 15 `0.58 | 0.64` and 16 `0.28 | 0.34` as stated. The 12-function check: all `true`.
- Compile check beyond the plan (`scratchpad/w7p5/compile_scenario.exs`): after `Code.compile_file("e2e/support.exs")`, each scenario's `defmodule`s compiled and every other top-level form compiled inside a probe `def run` (never called). Both files: no warning (undefined functions, unused variables). Negative control: a file calling `BaseAgent.nope(1)` printed "Normandy.Agents.BaseAgent.nope/1 is undefined or private".
- Step 4: every README anchor matched once. Note: `e2e/` is outside `.formatter.exs` inputs; both new files are not `mix format`-clean (long lines), like the existing scenarios (`03_tool_loop.exs` fails `--check-formatted` too). Not a gate item.
- No text corrections. 7.6b not applied (per brief).

### Task 7.4b — FIXED
- Commits `8c1f6ff` (as written) and `58fd53e` (layout test corrected). Precommit after the fix (seed 565260): 75 doctests, 33 properties, 3789 tests, 0 failures (257 excluded) (+3); first run (seed 63930) same totals; credo no issues; dialyzer passed (42); `mix docs --warnings-as-errors` exit 0.
- 7.6b made no fix commits here (not applied), so no extra `### Fixed` bullets. Every CHANGELOG anchor matched (`## [Unreleased]` once; the first `### Changed`/`### Fixed` after the notes are the former Unreleased block's).
- Step 2: 3 failures, but not the stated kinds (correction 2).
- Step 5 rehearsal on a scratch clone of the main repo (`/var/folders/.../T/tmp.CurSxEIzKU/r`): squash-merged **`origin/w7-preflight`** (the stacked branch; the plan's `feat/claudio-0.7-migration` lacks Wave 7) onto `main`, committed `feat!: Normandy 2.0 (#99)`, `cog bump --auto` → `Bumped version: v1.3.0 -> v2.0.0`, commit `chore(version): v2.0.0`, tag `v2.0.0`, `@version "2.0.0"`, one `## [v2.0.0]`, order `- - -` / `## [v2.0.0]` / `- - -` / (blank) / `## Normandy 2.0 release notes` / … / `- - -` / `## [v1.3.0]`. cog's v2.0.0 section also lists `main`'s untagged docs/ci commits since v1.3.0 (12b3440, ffbd389, 1b7336e, 922c35c, 3a2d65b, cf8fd08).
- **Finding, text correction 1:** the layout test as written fails on the bumped CHANGELOG (`assert notes == separator + 1`: the first `- - -` becomes cog's, above `## [v2.0.0]`, and a blank line precedes the notes) — verified by running the test on the clone's bumped CHANGELOG: 1 failure. Merged as written, CI on `main` goes red right after the 2.0 release. The test now asserts: the last non-blank line above the notes is `- - -`, only cog's `## [vN…]` headings sit above them, no heading before the first separator, notes before `## [v1.3.0]`, which has `- - -` above it. Verified: green on the pre-bump CHANGELOG, green on the bumped one, 3 failures on the old `[Unreleased]` CHANGELOG. Moduledoc reworded.
- Text correction 2: Step 2's expected errors are `FunctionClauseError` (`Enum.take/2` with `nil`) in the second test and `ArgumentError` (range `nil..64`) in the third, not `ArithmeticError`/`Enum.slice`.
- Text correction 3: Step 5's `grep -c 'Unreleased'` prints `1`, not `0`: a pre-existing bullet in an older section says "added in the Unreleased section". Now `grep -c '^## \[Unreleased\]'` (→ 0). Step 5's expected order now mentions the blank line.

### Task 7.7 — PASS (file only)
- Commit `b4d51d5`. Precommit (seed 193769): 75 doctests, 33 properties, 3789 tests, 0 failures (257 excluded); dialyzer passed (42); `mix docs --warnings-as-errors` exit 0.
- `release-pr.md` written verbatim from Step 1. Step 2: the squash body prints 7 lines; `cog verify` exit 0 (read as `BREAKING CHANGE`, type `feat`); AI-trailer grep `0`. Version rehearsal on a scratch clone (`/var/folders/.../T/tmp.ltiLJniedm/r`): `main` + squash of `origin/w7-preflight`, committed with the exact title + body → `cog bump --auto --dry-run | tail -n1` = `v2.0.0`. Job names in Step 3 of the merge steps match `ci.yml` (`Postgres session store tests`, `Redis session store and registry tests`, `Distributed (multi-node) tests`, `All Checks Passed`) and `pr-title.yml` exists.
- Step 4 (Q) not applied. No text corrections.

### Phase 5 end — final gate on `b4d51d5`
- Order deviation: the full gate ran **before** removing the Claudio worktree (the scratch Normandy depends on it by path; removing it first would leave `mix compile` without Claudio).
- `mix precommit` (seed 525724): 75 doctests, 33 properties, 3789 tests, 0 failures (257 excluded); credo no issues; dialyzer 42/42 skipped; `mix docs --warnings-as-errors` exit 0.
- `mix test.redis` (seed 298212): 3888 tests, 0 failures (158 excluded). `mix test.postgres` (`_w54probe`, port 55432, seed 600581): 3858 tests, 0 failures (188 excluded). Distributed (seed 147429): 79 tests, 0 failures.
- `normandy-test-pg` stopped (started in this phase). Claudio worktree removed (`git worktree remove --force`, exit 0); Claudio `main` `005c51d` and `feat/add-messages` `1490b75` unchanged, main tree still `?? .claude/worktrees/`, `?? Claudio`. The detached 7.5a commits `dce2fd3`/`81c8d4e` are now unreferenced (the real 7.5a redoes them from the plan text).
- Flakes this phase: none (`terminal_save_test.exs` and the Horde `session_delete_test.exs:170` did not fail in any run: precommit seeds 675006, 17630, 381103, 789226, 221579, 635316, 7359, 574647, 63930, 565260, 193769, 525724; Redis 298212; Postgres 600581; distributed 147429).
