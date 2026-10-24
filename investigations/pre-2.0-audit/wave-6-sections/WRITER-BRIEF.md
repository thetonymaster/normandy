# Brief for Wave 6 plan-section writers

You write ONE group of task sections for `investigations/pre-2.0-audit/plan-wave-6.md` in the Normandy repo
(/Users/antonio/personal/normandy, branch feat/claudio-0.7-migration, HEAD d624fbf + uncommitted plan files, Elixir library).

## Rules
- Edit NO file except your own output file under `investigations/pre-2.0-audit/wave-6-sections/`.
  No git commands that change state. You may run `mix compile`, `mix test <file>`, `mix run -e` probes and read anything.
  If you want to try code, do it in a scratch copy you create with `git worktree add` under
  `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/<your-group>`
  and remove it (`git worktree remove --force <path>`) before you reply. Never touch the main working tree.
- Binding inputs, read first:
  1. `investigations/pre-2.0-audit/plan-wave-6.md` — the header: Global Constraints, Task order, Shared interfaces
     (exact names), MIGRATING sections, Rulings, Review Focus. Use those names exactly. If a header interface or
     ruling cannot work against the current code, do NOT diverge silently: list it under `## Header conflicts`
     at the top of your file with evidence (file:line) and your proposed fix, and write your tasks against the fix.
  2. `investigations/pre-2.0-audit/wave-6-research/QUESTIONS.md` — every recommendation there is accepted by Q
     (decision 24) and binding.
  3. Your research inventory (named in your dispatch). Verify every line you rely on against the current code.
  4. Format example: `investigations/pre-2.0-audit/plan-wave-5.md` Task 5.1 (from line 103). Match it.
- Your tasks run AFTER the earlier tasks in the header's Task order. When an earlier task (written by another
  writer) changes a file you edit, write your edits against the header's description of that earlier change and
  say so explicitly in the step ("after Task 5.3a, `request_messages/1` exists"). Prefer anchoring edits on
  function names over line numbers in files that earlier tasks touch.
- Code-level plan: an engineer with zero context implements each task from your text alone. Every task has
  **Files:** (Create/Modify/Test with paths), **Interfaces:** (Consumes/Produces), then checkbox steps:
  write failing test (full test code) → run it, expected failure → implement (full code or exact before/after
  snippets) → run, expected pass → `mix format` + `mix precommit 2>&1 | tee <log>` expecting ` 0 failures` →
  MIGRATING-2.0.md text (exact bullets, in the header's section for your task) → commit step with every file
  `git add`-ed individually and a conventional message (NO Co-Authored-By / AI attribution lines).
- Cover every path named in the Global Constraints (sync, stream/3, Turn.Server at minimum) in tests when your
  task touches the loop, message construction or tool results.
- No placeholders ("TBD", "update the other callers", "similar to above"). When call sites change mechanically,
  give the exact grep, the rewrite rule and the expected count. List existing tests that must change, with the
  new assertion.
- Error messages say what was expected and what was received. No silent fallbacks.
- Tests: exact messages where the plan promises a message; no vacuous assertions; no sleeps for ordering.
- Keep each task reviewable: split into lettered sub-tasks if one exceeds ~400 lines of diff.
- End your file with `## Notes for the controller`: anything you could not verify, risks, proposed CLAUDE.md
  text (verbatim) if your change makes a CLAUDE.md line stale, and any question you would have asked Q (with the
  answer you assumed).
- Reply to your dispatcher with ONLY: output path, task list with one line each, and ≤5 lines of risks.

## Wave 6 additions
- The header's "Rulings against plan.md (decision 24)" and "Shared interfaces" are binding; the Group content
  list says which sub-tasks you own. The inventory recommendations Q accepted are binding even where the header
  summarizes them.
- Timing: use gates (arrival counters + explicit release) to prove concurrency; the one wall-clock test is 6.2b's.
- Tagged suites: say in each task which of `mix test.redis`,
  `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`, `mix test --only distributed` it runs.
  Never create or drop a database; a new Postgres migration module is applied by the test alias.
- Telemetry: every new event/metadata key gets its exact moduledoc text in the task.
- Never touch `/Users/antonio/personal/claudio` while writing (Task 6.1e's steps act on it at execution time).
