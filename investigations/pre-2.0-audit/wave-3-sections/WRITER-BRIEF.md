# Brief for Wave 3 plan-section writers

You write ONE group of task sections for `investigations/pre-2.0-audit/plan-wave-3.md` in the Normandy repo
(/Users/antonio/personal/normandy, branch feat/claudio-0.7-migration, Elixir library).

## Rules
- Edit NO file except your own output file under `investigations/pre-2.0-audit/wave-3-sections/`.
  Do not run git commands that change state. You may run `mix compile`, `mix test <file>` and read anything.
- Binding inputs, read first:
  1. `investigations/pre-2.0-audit/plan-wave-3.md` — header: Global Constraints, Shared interfaces (exact names),
     Rulings, Review Focus. Your tasks must use those names exactly. If you find a header interface or ruling
     that cannot work against the current code, do NOT diverge silently: list it under a `## Header conflicts`
     heading at the top of your file with evidence (file:line) and your proposed fix, and write your tasks
     against your proposed fix.
  2. `investigations/pre-2.0-audit/decisions.md` (decisions 1, 7, 9, 17).
  3. Your research inventory (named in your dispatch). It was written by a research agent; verify any line you
     rely on against the current code — line numbers may be off.
  4. Format example: `investigations/pre-2.0-audit/plan-wave-2.md` lines 2485-2603 (Task 2.7). Match it.
- Code-level plan: an engineer with zero context implements each task from your text alone. Every task has
  **Files:** (Create/Modify/Test with paths, and line ranges where useful), **Interfaces:** (Consumes/Produces),
  then checkbox steps: write failing test (full test code) → run it, expected failure → implement (full code or
  exact before/after snippets for edits) → run, expected pass → `mix format` + full `mix test` expecting
  ` 0 failures` → MIGRATING-2.0.md text (exact paragraph) when user-visible → commit step with every file
  `git add`-ed individually and a conventional message (NO Co-Authored-By / AI attribution lines).
- No placeholders ("TBD", "update the other callers", "similar to above"). When many call sites change
  mechanically, give the exact grep that finds them, the exact rewrite rule, and the expected count.
- Error messages say what was expected and what was received. No silent fallbacks.
- Tests: assert exact messages where the plan promises a message; no vacuous assertions; no sleeps for ordering.
- Keep each task reviewable: a reviewer must be able to reject it without rejecting its neighbour.
  Split a task into lettered sub-tasks if it exceeds ~400 lines of diff.
- End your file with `## Notes for the controller`: anything you could not verify, any risk, any open
  question for Q (each with your recommended answer).
- Reply to your dispatcher with ONLY: output path, task list with one line each, and ≤5 lines of risks.
