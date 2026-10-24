# Brief for Wave 6 preflight agents (integrated probe run)

Each section of `plan-wave-6.md` was prototyped alone on `d624fbf` (without the other groups). Your job is to
prove the sections work **stacked in task order**, and to correct the section text wherever they don't. You own
one phase (named in your dispatch); earlier phases have already been applied and committed on the scratch branch.

## Setup (shared by all phases)
- Scratch worktree: `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w6-preflight`, branch `w6-preflight`. Phase 1 creates it:
  `git -C /Users/antonio/personal/normandy worktree add -b w6-preflight /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w6-preflight d624fbf`,
  then `mix deps.get` there. Later phases reuse it as they find it. Never remove it (the controller does).
- Never touch the main working tree's code, branches, stash or `.git` refs other than `w6-preflight`. No
  `git stash`, no `git reset --hard`, no `rm -rf` outside the worktree, never create or drop a database.
- Commit each task in the worktree on `w6-preflight` (message `preflight: Task 6.Xy`, no AI attribution).
- Task 6.1e Part B (Claudio): do NOT create the `feat/add-messages` branch. Use a detached worktree:
  `git -C /Users/antonio/personal/claudio worktree add --detach /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w6-claudio 005c51d`, apply and test there,
  then `git -C /Users/antonio/personal/claudio worktree remove --force /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w6-claudio` before you reply.

## Per task (in the order given in your dispatch)
1. Apply the task's steps from its section file in `investigations/pre-2.0-audit/wave-6-sections/` (main repo path,
   read-only except for corrections below) exactly as written: tests first, check the "expected failure" really
   fails as stated, then the implementation, then the per-step test runs.
2. Run `mix format` and `mix precommit 2>&1 | tee <scratchpad log>`; the task passes only on ` 0 failures`,
   exit 0, credo and dialyzer clean. Run `mix docs --warnings-as-errors` once per phase. Run the tagged suites the
   task names (Redis: `mix test.redis`; Postgres: `docker start normandy-test-pg`, then
   `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`; distributed: `mix test --only distributed`
   — add `--include postgres` with the same env when Postgres is up). Stop `normandy-test-pg` at the end of
   your phase if you started it. Use `caffeinate -i -s` for long runs.
3. When the text does not work stacked (a before-snippet no longer matches, a test breaks because of an earlier
   task, a name differs), fix the **section file text** in the main repo so an implementer following it would
   succeed, then apply the fixed text. Minimal edits; keep the task's intent and the header's names
   (`plan-wave-6.md` header incl. "Header refinements" H1-H10 is binding). If a fix needs a design decision the
   header does not settle, make the smallest choice and record it as a ruling.
4. Append to `investigations/pre-2.0-audit/wave-6-sections/PREFLIGHT.md` a block per task:
   `### Task 6.Xy — PASS|FIXED` · commit sha · test counts from the precommit log · each text correction
   (section file, step, what changed, why) · each ruling (`Ruling: what — why — cost if wrong`).

## Known cross-task items (check, fix in the owning section, record)
- X1 (6.2d): apply H8 — passivation stops with `{:shutdown, :passivated}`; `Session.run/2` retries only that and
  `:noproc`, not `:normal`. Rewrite the section text and its tests.
- X2 (6.4c): 6.2a's `Describe.reason_term/1` exists; drop 6.4c's fallback definition and reuse it.
- X3 (6.4e vs 6.2f): 6.4e's `reap/1`/`maybe_start/2` replacement must be rewritten as a diff against 6.2f's code.
- X4 (6.2g, 6.5b, 6.3d): code written against 6.1a's `put_content/2` / Entry cache must compile and pass on the real
  6.1a code; 6.2g's snapshot entries must fill the cache via `from_entries/1`.
- X5 (6.3g): its tests use 6.3c's `save_turn_state/4`.
- X6 (6.3b/c/d): 6.2g's snapshot contract rule must pass on ETS (B5 rows), and the delete rules must hold with snapshot
  entries; run the contract on all five backends (Postgres and Redis included).
- X7 (6.5f, H9): `HierarchicalCoordinator` `String.to_atom(worker.id)`: verify; if it creates an atom per
  user-supplied id, add a step replacing it (no atom from input) with a test; record it.
- X8 (6.1a): every test double added by 6.2–6.5 that ends up in memory must be encodable (encode-at-append, H4).
- X9 (6.4a): every turn exit added by 6.2 (loading/unavailable paths, passivation, load crash) must call
  `release_turn_ctx/1` where a turn context was attached; extend 6.4a's regression test if needed.
- X10: MIGRATING sections `## 38.`-`## 42.` are created in order; later tasks append to the right one.
- X11 (6.3c/6.3a): the Postgres SQL in 6.3a, 6.3c, 6.3d was never run — run those Postgres steps first in that phase.

Reply to your dispatcher with ONLY: per task PASS/FIXED + sha, the number of text corrections and rulings, and
≤5 lines of risks.
