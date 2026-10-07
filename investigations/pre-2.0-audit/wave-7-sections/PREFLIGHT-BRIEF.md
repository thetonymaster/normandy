# Brief for Wave 7 preflight agents (integrated probe run)

Each section of `plan-wave-7.md` was prototyped alone on `9131274` (without the other groups). Your job is to
prove the tasks work **stacked in task order**, and to correct the plan text wherever they don't. You own one
phase (named in your dispatch); earlier phases have already been applied and committed on the scratch branch.

## Setup (shared by all phases)
- Scratch worktree: `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-preflight`, branch `w7-preflight`. Phase 1 creates it:
  `git -C /Users/antonio/personal/normandy worktree add -b w7-preflight /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-preflight 5cf6e65`,
  then `mix deps.get` there. Later phases reuse it as they find it. Never remove it (the controller does).
- The plan to apply is `/Users/antonio/personal/normandy/investigations/pre-2.0-audit/plan-wave-7.md` in the MAIN repo
  (read it there, including its header: Global Constraints, Shared interfaces, Rulings R1-R8, Header refinements
  H1-H17, which are binding). The worktree's copy of the plan is stale; ignore it.
- Never touch the main working tree's code, branches, stash or `.git` refs other than `w7-preflight`. The only
  main-tree files you may edit are `investigations/pre-2.0-audit/plan-wave-7.md` (text corrections) and
  `investigations/pre-2.0-audit/wave-7-sections/PREFLIGHT.md` (your log). No `git stash`, no `git reset --hard`,
  no `rm -rf` outside the scratch directory, never create or drop a database, never push, never publish, never
  run `mix e2e` without `--estimate` or anything that calls a paid API.
- Commit each task in the worktree on `w7-preflight` (message `preflight: Task 7.Xy`, no AI attribution).
- Claudio (Task 7.5a, and 7.5b's dependency): do NOT create or change any Claudio branch. Use a detached worktree:
  `git -C /Users/antonio/personal/claudio worktree add --detach /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-claudio feat/add-messages`,
  apply and test there. Phase 4 creates it and leaves it (with 7.5a applied, uncommitted or committed detached);
  phase 5 uses it for 7.5b by pointing the scratch Normandy at it with `{:claudio, path: "<that worktree>"}`
  (record that the real task uses the Hex `~> 0.7.1`), and removes it at the end
  (`git -C /Users/antonio/personal/claudio worktree remove --force <path>`).

## Per task (in the order given in your dispatch)
1. Apply the task's steps exactly as written: tests first, check the "expected failure" really fails as stated,
   then the implementation, then the per-step test runs.
2. Run `mix format` and `mix precommit 2>&1 | tee <scratchpad log>`; the task passes only on ` 0 failures`, exit 0,
   credo and dialyzer clean. Run `mix docs --warnings-as-errors` once per task that touches docs, and once per
   phase otherwise. Run the tagged suites the task names (Redis: `mix test.redis`; Postgres:
   `docker start normandy-test-pg`, then `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`;
   distributed: `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres`).
   Stop `normandy-test-pg` at the end of your phase if you started it. Use `caffeinate -i -s` for long runs.
3. When the text does not work stacked (a before-snippet no longer matches, a test breaks because of an earlier
   task, a name or count differs), fix the **plan text** in `plan-wave-7.md` so an implementer following it would
   succeed, then apply the fixed text. Minimal edits; keep the task's intent and the header's names. If a fix
   needs a design decision the header does not settle, make the smallest choice and record it as a ruling.
4. Append to `investigations/pre-2.0-audit/wave-7-sections/PREFLIGHT.md` a block per task:
   `### Task 7.Xy — PASS|FIXED|PARTIAL` · commit sha · test counts from the precommit log · each text correction
   (task, step, what changed, why) · each ruling (`Ruling: what — why — cost if wrong`).

## Known cross-task items (check, fix in the owning task, record)
- Y1: MIGRATING sections are created in order §43 (7.0b/7.0c), §44 (7.0d), §45 (7.2a; 7.3b/7.3d/7.3e append —
  ruling R8), §46 (7.3h-i), §47 (7.1b); no §48. Every insertion anchor must match the file as earlier tasks left it.
- Y2: 7.0c changes `StubClient`/`ModelMockup` defaults; any later task's new test that relies on `chat_message: nil`
  must be fixed.
- Y3: 7.2b's groups test and 7.3a/7.3f's coverage test must pass after every later task: each new public module
  (7.3b, 7.3d) joins a group and is documented; each new internal one is `@moduledoc false`.
- Y4: 7.3f — the ~85 docs are not written out. Run the enumeration command; if its list differs from the plan's
  (because an earlier task added or removed public functions), correct the plan's counts and `@not_yet_documented`
  list. Apply 7.3f's test with the list as-is (do not write the 85 docs); record PARTIAL.
- Y5: 7.3d rewrites the `use` lines that 7.0b's `TerminalSaveCases` sits beside; the hard-coded contract test
  counts (16/33) must be recounted after 7.0b.
- Y6: 7.3h-v deletes tracked files with `git rm -r`; in the scratch worktree untracked build output may remain —
  leave it, note it.
- Y7: 7.1a's `tools/api_diff` run and 7.1b's "unmatched (0)" end state must hold on the stacked branch (it sees
  7.0-7.3h's changes, which carry their own MIGRATING bullets). Any unmatched item is either a missing bullet in the
  owning earlier task (fix that task's text) or a 7.1b gap.
- Y8: 7.6a-i/ii: run the runner tests and `mix e2e --estimate` only; compile-check scenarios 15/16 (no live run).
  7.6b and the Q steps of 7.5a/7.7 are not applied.

Reply to your dispatcher with ONLY: per task PASS/FIXED/PARTIAL + sha, the number of text corrections and rulings,
and ≤5 lines of risks.
