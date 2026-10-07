# Brief for Wave 7 research agents

You build ONE facts inventory for the Wave 7 implementation plan (docs, release, publish, and the
code leftovers moved into Wave 7) of the Normandy pre-2.0 audit (/Users/antonio/personal/normandy,
branch feat/claudio-0.7-migration, HEAD 0ed6783, Elixir library; 584 commits ahead of `main`). The
plan writer works from your inventory, so it must be exact: every claim carries `file:line` (or a
commit hash, or a command and its output) verified today. The audit reports are weeks old; Waves 1-6
rewrote most of the library. Re-verify every finding before inventorying it. A finding that is
already fixed goes in Surprises.

## Rules
- Write ONLY your output file under `investigations/pre-2.0-audit/wave-7-research/`. Edit no other
  file. No git commands that change state in this repository or in `/Users/antonio/personal/claudio`
  (no commit, checkout, stash, branch, tag, push). Never publish anything (`mix hex.publish`,
  `gh pr create`, `gh release`): those are Q's. Never drop a database, never start/stop Docker
  containers, never run `mix e2e` or anything that calls a paid API (no `ANTHROPIC_API_KEY` use).
  You may run `mix compile`, `mix test <file>` (untagged), `mix docs`, `mix hex.build --unpack -o
  <scratch>`, small `mix run -e` probes, `git log`/`git show`/`git diff`, and read anything. A scratch
  clone or worktree goes under
  `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-<your-group>`
  and you remove any worktree you created (`git worktree remove --force <path>`) before replying.
- Never dispatch subagents.
- Read first: `CLAUDE.md`; `investigations/pre-2.0-audit/plan.md` § "Waves 2–7 — Roadmap" →
  "Wave 7" (the spec for your tasks, including each task's Acceptance), "Global Constraints",
  "Review Focus" and "Finding coverage"; `investigations/pre-2.0-audit/decisions.md` (all decisions,
  especially 2, 3, 4, 14, and the Progress bullets for Waves 1-6, which list items deferred to
  Wave 7); `MIGRATING-2.0.md` (it already exists: 44 `## ` sections and a "Known limits of 2.0"
  list); the findings named in your dispatch in `release.md`, `devex.md`, `perf.md`, `agentx.md`,
  `security.md`, `telemetry.md`, `claudio-gaps.md`.
- Turn logic has THREE interpreters: `Turn.Driver`, `Turn.Inline`, `Turn.Server` (plus the
  BaseAgent sync `run/3` path and `stream/3`). A code change to the loop, dispatch, persistence or
  telemetry must be inventoried for EVERY path. List them all.
- Telemetry: `test/telemetry/catalogue_test.exs` fails when an emitted event is missing from the
  `Normandy.Telemetry` moduledoc. Note every event your proposals add or change.

## Output structure
1. `## 0. Surprises` — where the current code or repository differs from plan.md's Wave 7 text
   (already done, partly done, moved, an acceptance that cannot be checked as written). First.
2. Per item: current state with `file:line` / commit / command output; every place affected (exact
   grep commands and counts); existing tests that pin current behaviour and will need changing;
   helpers that exist. For release items, the exact commands you ran and what they printed.
3. `## Proposed approach` — per item, the smallest change that meets plan.md's acceptance, naming
   exact files, functions and any new public names, and how the acceptance is checked
   deterministically.
4. `## Proposed task split` — sub-tasks (≤ ~400 diff lines each) in dependency order, with the files
   each touches, and which steps need Q (publishing, spending, opening a PR).
5. `## Questions for Q` — decisions the plan cannot settle from decisions.md, each with options,
   your recommendation, and what it costs if wrong. Breaking changes (public API, defaults,
   persisted formats), anything outward-facing and anything that spends money are always a question.

Reply to your dispatcher with ONLY: the output path, and ≤8 lines of the most important surprises.
