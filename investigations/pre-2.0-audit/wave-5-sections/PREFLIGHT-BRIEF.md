# Brief for Wave 5 preflight agents (integrated probe run)

Each section of `plan-wave-5.md` was prototyped alone on `0dccd48`. Your job is to prove the sections work
**stacked in task order**, and to correct the plan text wherever they don't. You own one phase (named in your
dispatch); earlier phases have already been applied and committed on the scratch branch.

## Setup (shared by all phases)
- Scratch worktree: `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w5-preflight`,
  branch `w5-preflight`. Phase 1 creates it: `git -C /Users/antonio/personal/normandy worktree add -b w5-preflight <path> 0dccd48`,
  then `mix deps.get` there. Later phases reuse it as they find it. Never remove it (the controller does).
- Never touch the main working tree's code, branches, stash or `.git` refs other than `w5-preflight`. No `git stash`.
  No `git reset --hard`, no `rm -rf` outside the worktree, never drop any database.
- Commit each task in the worktree on `w5-preflight` (message `preflight: Task 5.Xy`, no AI attribution).

## Per task (in the order given in your dispatch)
1. Apply the task's steps from its section file in `investigations/pre-2.0-audit/wave-5-sections/` (main repo
   path, read-only except for corrections below) exactly as written: tests first, check the "expected failure"
   really fails as stated, then the implementation, then the per-step test runs.
2. Run `mix format` and `mix precommit 2>&1 | tee <scratchpad log>`; the task passes only on ` 0 failures`, exit 0,
   credo and dialyzer clean. Run `mix docs --warnings-as-errors` once per phase.
3. When the text does not work stacked (a before-snippet no longer matches, a test breaks because of an earlier
   task, a name differs), fix the **section file text** in the main repo so an implementer following it would
   succeed, then apply the fixed text. Minimal edits; keep the task's intent and the header's names
   (`plan-wave-5.md` header incl. "Header refinements" H1-H10 is binding). If a fix needs a design decision the
   header does not settle, make the smallest choice, and record it as a ruling.
4. Append to `investigations/pre-2.0-audit/wave-5-sections/PREFLIGHT.md` a block per task:
   `### Task 5.Xy — PASS|FIXED` · commit sha · test counts from the precommit log · each text correction
   (section file, step, what changed, why) · each ruling (`Ruling: what — why — cost if wrong`).

## Known cross-task items (check, fix in the owning section, record)
- X1 (5.2b): a `pause_turn` on the forced-final call is not continued by either section. Make it continue as the
  final call (same `tool_choice: :none`, no new user message), bounded, no new public option; test it.
- X2 (5.2a): the incomplete-answer clause must also cover `converse_structured` for tool-loop calls that 5.1
  routes there with `output_format`.
- X3 (5.2b): `tool_choice` goes in `build_request/3`, not in the stream functions 5.1 restructured.
- X4 (5.6b-ii): AX-32 makes an empty final answer `:invalid_output`; every test client added or changed in
  5.1–5.5 whose final answer is empty must answer with text.
- X5 (5.6b-i): 5.4a's invalid-UTF-8 test pins `%{error: ...}`; update it to the bare shape.
- X6 (5.7a): `ToolWrapper.new` / `AgentTool.new` call sites added by earlier tasks need `:prefix`.
- X7 (5.5b): every `{:maybe_compact, _}` emitter added by 5.2b/5.3c must set `mid_round`.
- X8: `ScriptedToolClient` / `WireScript` changes from 5.1, 5.6b-ii and 5.7b must compose.
- X9 (5.6c): `properties` become `Jason.OrderedObject`; any code or test from 5.1–5.5 that reads them as a map.

## Postgres / Redis (phase with Task 5.4b, and the final phase)
- `docker start normandy-test-pg` (port 55432). Use the existing probe database `normandy_test_w54probe` (created
  by the 5.4 writer) — never drop or recreate the default test database; if you need a fresh one, create a new
  uniquely named database and list it in PREFLIGHT.md for the controller. Stop the container when done.
- Redis: `mix test.redis` as the repo's alias defines it.

Reply to your dispatcher with ONLY: per task PASS/FIXED + sha, the number of text corrections and rulings, and
≤5 lines of risks.
