# Wave 7 — Docs, release, publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Normandy 2.0 is ready to merge: the last code defects found in Waves 4-6 are fixed (H10, A4, the parked minors), every public module is grouped and documented, users get a shipped test client and store contracts, MIGRATING covers every breaking change, the release machinery produces one `v2.0.0`, and one live e2e run (with an Opus preserved-thinking probe and an MCP pause scenario) passes before Q opens the release PR.

**Architecture:** No new subsystems. `Turn.Server` holds an unsaved terminal turn state and retries it; Dispatch renders a tool output once; `Normandy.Test.FakeClient` and the store/registry contracts move into `lib/` under `Normandy.Test.*`; internals get `@moduledoc false` and a `Code.fetch_docs` test pins groups and doc coverage; `tools/api_diff/` checks MIGRATING against `main`; release.yml stops treating "nothing to bump" as releasable. Claudio 0.7.1 (`add_messages/2` + citations replay) is prepared on a local branch for Q to publish; the adapter switches to it afterwards.

**Tech Stack:** Elixir ~> 1.15 / OTP ≥ 24, Claudio `~> 0.7.0` → `~> 0.7.1` (Hex, after Q publishes), NimbleOptions (through `Normandy.Options`), ExDoc, ExUnit, cocogitto 7 (`cog`), GitHub Actions.

**Spec:** `investigations/pre-2.0-audit/plan.md` § "Wave 7" (Tasks 7.1–7.7), "Global Constraints", "Review Focus", "Finding coverage"; decisions 2, 3, 4, 14, 25 (A4, A10), 26, **27** (Q's answers to `wave-7-research/QUESTIONS.md`, binding) and **28** (Q's answers to this plan's Appendix A, binding) in `investigations/pre-2.0-audit/decisions.md`; findings REL-1, REL-3–5, REL-7, REL-9 (`release.md`), DX-8, DX-10, DX-13, DX-20, DX-23, DX-24, DX-29, DX-31–35 (`devex.md`). The facts inventories behind this plan are `wave-7-research/7.0-code-leftovers.md`, `7.1-release-docs.md`, `7.3-api-docs-testing.md`, `7.5-release-mechanics.md` (verified against HEAD `0ed6783`). Section writers read the inventory for their group in full.

## Finding IDs closed by this wave

REL-1 (rest), REL-3, REL-4, REL-5, REL-7, REL-9, DX-8, DX-10, DX-13, DX-20 (docs), DX-23, DX-24, DX-29, DX-31, DX-32, DX-33, DX-34, DX-35; decision 25 A4 and A10 (H10); the parked minors classified "W7" in `7.0-code-leftovers.md` §"parked minors" (rows 1-12); new: the silent terminal save (row 3), the `%Duration{}` compile error on Elixir 1.15/1.16, release.yml's no-bump republish, Horde floor, the Horde supervisor `{:EXIT, pid, :normal}` test flake (7.0e). Stay known limits / 2.x (listed in MIGRATING): rows 17-26 of that table, AX-12, AX-18 retry, AX-19, AX-20, AX-29, AX-33, SEC-8, conservative session deletion, compaction snapshot growth. Dropped as invalid or obsolete: rows 23, 25, 27, 28, 29 (recorded in the inventory). Already fixed (no task): row 31.

## Global Constraints

- Elixir `~> 1.15` / OTP ≥ 24 stays the declared floor (decision 27 B1); no new runtime dependencies. Code that uses a 1.17+ module (`Duration`) is guarded with `Code.ensure_loaded?/1` like `lib/normandy/type.ex:799`.
- Every public function that takes options validates them with `Normandy.Options.validate!(opts, schema, {Mod, :fun, arity})`; an unknown option raises `ArgumentError` in the house style.
- No message, log line, telemetry metadata, tool result or persisted term contains a credential, a stacktrace, conversation content, SQL text or model text in an error `reason` (decision 6). Errors are logged by tag (`Describe.reason_term/1`), never with `inspect(error)`.
- Every new telemetry event or metadata key is documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs`). Decision 27 A2: Wave 7 adds **no** event.
- A change to the loop, dispatch, tool results or persistence holds on **every** path: BaseAgent `run/3`, `stream/3`, `Turn.Driver`, `Turn.Inline`, `Turn.Server`. Tests cover sync, `stream/3` and `Turn.Server` at minimum.
- **Wire bytes do not change** in Wave 7 except where a task says so: `test/agents/wire_identity_test.exs` stays green after every task (Task 7.0a's single rendering and Task 7.5b's `add_messages/2` switch included).
- Every user-visible change gets a bullet in `MIGRATING-2.0.md` in the section its task owns (see "MIGRATING sections"); non-breaking additions go under `## New, non-breaking`.
- Shipped test modules live under `lib/normandy/test/` with names `Normandy.Test.*` (decision 27 D1). `test/support/` never defines a module name that `lib/` ships; Task 7.3b adds a test asserting it.
- Store backend changes keep the contracts passing on every backend; after Task 7.3d the contracts are `Normandy.Test.SessionStoreContract`, `Normandy.Test.MemoryStoreContract`, `Normandy.Test.SessionRegistryContract`.
- Tests are deterministic: no `Process.sleep` to wait for a message (use `assert_receive`, `Normandy.Test.Eventually.wait_until/1`, `:sys.get_state/1` or a synchronous call); concurrency is proven with gates, not timing.
- Run `mix format` before every test run. A task is done only when `mix precommit 2>&1 | tee <log>` shows ` 0 failures` and exit 0, and `mix docs --warnings-as-errors` exits 0. Tasks that touch a store backend, `Turn.Server` persistence, the registry or the reaper also run `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` (after `docker start normandy-test-pg`; the controller stops it afterwards) and `mix test --only distributed --include postgres`; the task text names which.
- Commits: add files individually (`git add <path>`; `git add .`/`-A` forbidden); no AI attribution of any kind in the message (no Co-Authored-By, no "Generated with"); never push. Deleting tracked files uses `git rm <path>` per file or `git rm -r examples/<app>` (Task 7.3h only), never `rm -rf`.
- Never run a destructive command, never create or drop a database, never change a GitHub repository setting. Postgres runs use the existing partition DB `normandy_test_w54probe`.
- **Outward-facing steps are Q's** and every task marks them `**Q:**`: publishing Claudio 0.7.1 to Hex, pushing any branch, opening the release PR, merging it, and spending on live API calls (Task 7.6b asks Q with a cost estimate first). The Claudio repository (`/Users/antonio/personal/claudio`) is changed only on the local branch `feat/add-messages`, never pushed by us, `@version` bumped to `0.7.1` there (decision 27 B3).
- Do not edit `CLAUDE.md`. Proposed CLAUDE.md text goes to the controller in the task report; Task 7.8 collects it for Q.

## Task order

`7.0a → 7.0b → 7.0c → 7.0d → 7.0e → 7.2a → 7.2b → 7.3a → 7.3b → 7.3c → 7.3d → 7.3e → 7.3f → 7.3g → 7.3h → 7.5a → 7.1a → 7.1b → 7.1c → 7.4a → [Q publishes Claudio 0.7.1] → 7.5b → 7.6a → 7.6b [Q approves spend] → 7.4b → 7.8 (gate) → 7.7 [Q pushes, opens and merges the PR]`

7.1b (MIGRATING gaps) runs after every code task so its API diff sees the final surface; 7.4b (CHANGELOG) runs after 7.6b so it summarizes fixes from the live run. Files touched by several tasks, in order: `turn/server.ex` (7.0b only), `agents/dispatch.ex` + `components/tool_result.ex` (7.0a), `agents/base_agent.ex` (7.0c A3, 7.3a docs, 7.3h DX-33), `mix.exs` (7.0c `test_load_filters`, 7.0d Horde, 7.2b groups, 7.3b/7.3e groups and extras, 7.3g `files:`, 7.5b Claudio), `MIGRATING-2.0.md` (each code task its own bullets; 7.1b the gaps, index and restructure last), `lib/normandy/llm/claudio_adapter.ex` (7.5b only), `test/support/*` (7.3c deletes 3 clients, 7.3d moves the contracts). Anchor edits on function names, not line numbers.

### Group content

- **7.0a** A4: Dispatch renders a tool output once (`ToolResult.render_output/1` result carried through truncation, `after_tool` and the result struct); row 11 `unencodable_output/1` stops quoting `Exception.message` (tag only). Counting test: 2 encodings per tool result on run, stream, Turn.Server and Turn.Inline (`linear_history_test.exs:46` updated). **7.0b** H10 (decision 27 A1, A2): `persist_turn_state/2` failure at a terminal state is logged by tag (row 3); the server keeps the unsaved terminal state, retries it (on the next event and on a timer), refuses `run` with `%TurnError{type: :persist_failed}` until it lands, and defers passivation; resume of an in-flight state whose answer is already in history makes no model call. Known-limits bullet reduced to process death during a store outage. Store tests on all five backends via the tagged suites. **7.0c** Rows 6-10 and 12: Workflow moduledoc example, `test_load_filters`, Summarizer no-`type` block and escaped summary tag, `chat_message: nil` is blank on every path (decision 27 A3; MIGRATING), Known-limits blank line. **7.0d** `%Duration{}` guard in `schema/validator.ex` (decision 27 B1) and its test guards; Horde `~> 0.10` (B2; MIGRATING, `mix.lock` unchanged). **7.0e** (decision 28 A6) The Horde `{:EXIT, pid, :normal}` flake: ExUnit's capture-log handler links a `Task` to `Horde.DynamicSupervisorImpl` from its `init/1` `:info` log, before it traps exits; `test/test_helper.exs` sets that module's log level to `:warning`, and `test/agents/turn/horde_init_log_test.exs` pins both halves. Test environment only, no MIGRATING bullet.
- **7.2a** Hide the internals of decision 27 C1 (`@moduledoc false`) and un-backtick every public reference (`mix docs --warnings-as-errors` clean). **7.2b** `groups_for_modules` for every visible module (Errors group kept, a "Testing" group for `Normandy.Test.*`), `groups_for_extras`, `test/docs/docs_groups_test.exs` (every module with docs in exactly one group).
- **7.3a** `@doc` for `BaseAgent.reset_memory/1`, `register_context_provider/3`, `delete_context_provider/2`; the DX-10 decision table in the `Normandy` moduledoc; `test/docs/doc_coverage_test.exs` scoped to BaseAgent and Turn.Session. **7.3b** `Normandy.Test.FakeClient` (scripted text / structured / tool-call / error replies, streaming, captured requests, owner pid + atomics, works on every path) + tests + the name-clash test. **7.3c** Migrate the 3 scripted clients' 11 test files to FakeClient and delete those clients (D2). **7.3d** `Normandy.Test.SessionStoreContract`, `MemoryStoreContract`, `SessionRegistryContract` in `lib/` with `:new` (`{m, f, a}`), optional `:stored_entry_ids` (D3). **7.3e** `docs/guides/testing.md` + `test/docs/testing_guide_test.exs` + extras + README link. **7.3f** Widen the doc-coverage test to every visible module, functions, macros and callbacks (C5); write the ~100 docs, split by area. **7.3g** Non-breaking devex: DX-20 migration docs, DX-31, DX-32, DX-34 (`claude-opus-5-5` everywhere, README quickstart reads `chat_message` and shows the error tuple), DX-35 `MIGRATING-2.0.md` in `package.files`. **7.3h** Breaking devex (MIGRATING each): DX-23 the DSL compile-time error for `system_prompt` beside `background`/`steps`/`output_instructions` (decision 28 A2: an `agent` block without `model` still compiles and `new/1` given `:model` serves it; MIGRATING §21 unchanged), DX-24 remove Workflow `:context`, DX-33 `ModelCatalog.Static` deprecation warning once per VM, DX-35 remove the 3 Toolset filters, DX-29 delete both `examples/` apps (README pointer kept; right after the `git rm -r` the implementer reports the untracked/ignored leftovers and Q runs the `rm -rf` of both directories; `marketing/demo-1.0/agent-horde-script.md` gets a one-line "written for Normandy 1.0" note, decision 28 A4).
- **7.5a** Claudio local branch `feat/add-messages`: citations replay patch (`response.ex` keeps `citations` on text blocks and `to_assistant_content/1` replays them), `@version "0.7.1"`, Claudio CHANGELOG entry, Claudio's own tests green; **Q:** push, tag, `mix hex.publish`. **7.1a** `tools/api_diff/` scripts (C4), excluded from the package, README on how to run. **7.1b** MIGRATING: the uncovered API and REL-4 changes (from a fresh `tools/api_diff` run against `main`), tables/samples only where a shape changes (C2), the two misfiled bullets moved, "Who is affected" index (C3), Known limits refreshed. **7.1c** Triage of keyword-flagged commits; the mapping table recorded in the commit body. **7.4a** release.yml: release only when `cog bump --auto --dry-run`'s last line is a version (F1); `.github/workflows/README.md` matrix text.
- **7.5b** (after Q publishes) `{:claudio, "~> 0.7.1"}`, `mix.lock`, `claudio_adapter.ex` `add_messages/3` → `Claudio.Messages.Request.add_messages/2`, wire identity unchanged, `claudio-gaps.md` closed, citations replay test. **7.6a** e2e: usage/cost totals printed by the runner; scenario 15 AX-7 preserved-thinking replay on `claude-opus-5-5` with `thinking_block_binding: :error`; scenario 16 MCP-connector `server_tool_use` pause → crash → new input (F3, through a public MCP server the writer names, with a fallback if none is reachable); runner tests. **7.6b** **Q:** approve spend (estimate printed first); one full `mix e2e`; fixes as separate commits; rerun only failed scenarios; log saved to `investigations/pre-2.0-audit/e2e-2.0.log`; Known limits updated from the probes' results. **7.4b** CHANGELOG 2.0 block after the first `- - -` (C6), rehearsed on a scratch clone. **7.8** Gate (controller). **7.7** Squash body text written to `investigations/pre-2.0-audit/release-pr.md` (title `feat!: Normandy 2.0`, body ending `BREAKING CHANGE: see MIGRATING-2.0.md`, no AI trailers); **Q:** push, open the PR, CI green on the whole matrix, squash-merge with the edited body (F2).

## Shared interfaces (exact names; every task uses these)

| Name | Owner | Shape |
|---|---|---|
| `Turn.Server` data field `unsaved_terminal` | 7.0b | `nil` or the terminal turn state that failed to save; while set: `run` replies `{:error, %TurnError{type: :persist_failed, reason: {:terminal_unsaved, tag}}}`, passivation is deferred, the save is retried on every event and on a `{:timeout, :retry_terminal_save}` generic timeout (1_000 ms, doubling to 30_000 ms). Cleared on a successful save. |
| Log line for a failed terminal save | 7.0b | `Logger.warning` with metadata `session_id`, `reason: Describe.reason_term(reason)`; text "turn state not saved; retrying" — no event (decision 27 A2). |
| Resume guard | 7.0b | On load, an in-flight state whose last history entry is the turn's final assistant answer is marked finished and saved without a model call. Exact predicate in Task 7.0b. |
| `Normandy.Test.FakeClient` | 7.3b | `FakeClient.new(script, opts \\ [])` → struct implementing `Normandy.Agents.Model`; `script` items `{:text, binary}`, `{:structured, map}`, `{:tool_calls, [{name, input}]}`, `{:error, %LLMError{}}`, optional `stop_reason:`/`usage:`; `FakeClient.requests(client) :: [%Normandy.LLM.Request{}]`; an exhausted script raises `Normandy.Test.FakeClient.ScriptExhaustedError`. Exact API fixed by Task 7.3b from the inventory prototype. |
| `Normandy.Test.SessionStoreContract`, `MemoryStoreContract`, `SessionRegistryContract` | 7.3d | `use Normandy.Test.SessionStoreContract, new: {m, f, a}, stored_entry_ids: {m, f, a} \| nil` (`async:` passthrough as today). |
| `tools/api_diff/` | 7.1a | Scripts that dump public functions/macros/callbacks (docs not `false`), specs and struct fields for a ref; README with the `main..HEAD` command. Not in `package.files`. |
| Docs groups test | 7.2b | `test/docs/docs_groups_test.exs`: every `lib/` module whose `Code.fetch_docs/1` moduledoc is not `:hidden` appears in exactly one `groups_for_modules` group. |
| Doc coverage test | 7.3a, widened 7.3f | `test/docs/doc_coverage_test.exs`: no function, macro or callback with `:none` docs in a visible module (protocol impl modules skipped). |
| e2e usage total | 7.6a | The runner prints `usage: input=N output=N cache_read=N cache_write=N est_cost=$X.XX` per scenario and in total (prices in `e2e/support.exs`, stated as of 2026-10). |

## MIGRATING sections

`## 43.` Turn.Server terminal saves and blank answers (7.0b, 7.0c) · `## 44.` Dependencies and platform (7.0d Horde; 7.5b Claudio 0.7.1) · `## 45.` Testing support and docs (7.3b-e: new `Normandy.Test.*`, contracts moved out of `test/support`) · `## 46.` DSL, Workflow and Toolset (7.3h) · Task 7.1b adds sections `## 47.`+ for earlier waves' uncovered changes only where no existing section fits (otherwise it adds to the fitting one), adds the index at the top, and refreshes `## Known limits of 2.0`.

## Rulings against plan.md (decision 27)

- **R1 (7.5)** Claudio 0.7.0 is already on Hex and locked (Wave 3); 7.5 is Claudio 0.7.1 (`add_messages/2` + citations replay) and the adapter switch. `@version` stays `1.3.0`; cog writes `2.0.0` (B4). plan.md 7.5's "set version: 2.0.0" is withdrawn.
- **R2 (7.3)** plan.md's "mix docs lists no public function without docs" is checked by a `Code.fetch_docs` test (ExDoc renders an empty `@doc` without warning), scoped to every visible module (C5).
- **R3 (7.1)** "every commit … matched to a MIGRATING section" is checked by an API diff of compiled docs/specs between `main` and HEAD (`tools/api_diff/`) plus a triage of keyword-flagged commits, not by walking 584 commits. Tables/samples only where a shape changes (C2).
- **R4 (7.6)** The live run adds scenario 15 (AX-7 on Opus 5.5, F4) and scenario 16 (MCP connector pause, F3: a full Normandy scenario). Normandy cannot declare server tools (`claudio_adapter.ex:838`), so 16 runs through Claudio's MCP connector support as configured by Normandy; if Normandy cannot express the MCP connector, Task 7.6a's writer lists it under Header conflicts and the controller asks Q.
- **R5 (7.7)** PR body and squash message are written to a file; Q edits the squash body at merge (F2); "Rebase and merge" stays enabled (F2b), so the release instructions say to choose "Squash and merge".
- **R6 (7.4)** release.yml gets the no-bump guard (F1) before the release PR, so the 2.0 merge and every later merge behave.
- **R7 (7.3h)** E1: both example apps are deleted; `examples/README.md` points at the guides. E6 (controller): one `Logger.warning` per VM (`:persistent_term` flag) when a config uses `ModelCatalog.Static`, at `init/1` and `ConfigTemplate.rebuild/3`.

- **R8 (controller, MIGRATING §45)** Task 7.2a creates `## 45. Testing support and docs` with the hidden-module bullets; Tasks 7.3b, 7.3d, 7.3e append to it. Task 7.1b adds no §48: its hidden-module pointers go into §45, and every hidden module its API diff reports must be named there.

## Header refinements from the section writers (accepted by the controller)

- **H1 (7.0b)** The failed-terminal-save log names the session and the reason term in its text (`Turn.Server session "sid": turn state not saved; retrying (:store_down)`); metadata is passed as a variable list through `Logger.log/3` (the default formatter drops tuple metadata; credo flags literal metadata keys). Still no event.
- **H2 (7.0b)** The unsaved terminal state is retried on the three events that act on the session in `:idle` (turn request, passivation timeout, the `{:timeout, :retry_terminal_save}` timer); dropped casts and stray messages stay no-ops. `{:terminal_unsaved, reason}` carries `Describe.reason_term/1`'s term. A refused turn request still fires `on_turn_end` with `{:error, exception}`. The resume guard covers `:steering` turns whose last stored message is the answer (`Turn.answered?/1`, public), not `:awaiting_approval`.
- **H3 (7.0b)** `Normandy.Test.TerminalSaveCases` / `TerminalSaveStore` stay in `test/support/`; the backend tests gain one `use` line that Task 7.3d keeps.
- **H4 (7.0a)** Row 11's model-facing text change goes into the existing `## 36.`; `ToolResult.render/1` is the new single renderer.
- **H5 (7.0c, decision 27 A3)** `StubClient`'s default reply and `ModelMockup` fill a `nil` `chat_message` with `"stub answer"`; 25 tests in 8 files change (listed in 7.0c). A native structured-output answer that omits the optional `chat_message` becomes `:invalid_output` (Appendix A1).
- **H6 (7.0c)** The Workflow example needs `Normandy.DSL.Workflow.__after_condition__/3` (`@doc false`) so `when_result` stops making the compiler warn in user modules on Elixir 1.19.
- **H7 (7.2a)** 18 modules are hidden (list in 7.2a); `Hooks.Runner` among them, so the hooks guide tests a hook through `BaseAgent.run/3` (Appendix A3). Hidden names are written unbackticked in extras.
- **H8 (7.2b)** `Testing: []` starts empty; Tasks 7.3b and 7.3d add their modules to it.
- **H9 (7.3f, 7.3g)** 7.3f runs as 7.3f1-f4 (87 gaps, a shrinking `@not_yet_documented` list); 7.3g as 7.3g1-g2.
- **H10 (7.3b)** FakeClient's API extends the header row (chunked text, `%ToolCall{}` calls, function items, `stream_error_after:`, `remaining/1`, `:options`); capture is atomics + an ETS table owned by the creating process. An exhausted script under `Turn.Server` is `:task_down`.
- **H11 (7.3d)** Contracts take `impl:` (required), `new:` (default `{impl, :new, []}`) and `stored_entry_ids:` (`{m, f, a}` called with the handle appended); no `async:` option.
- **H12 (7.3h)** E3 is only the `system_prompt`-conflict compile error: the "model given to `new/1`" path for agents that declare none stays, with its runtime `requires :model` check and MIGRATING §21 (decision 28 A2). The DX-33 bullet edits §5, not §46.
- **H13 (7.6a)** The MCP connector is the agent option `mcp_servers:` (already supported), so scenario 16 is a full Normandy scenario; whether the connector returns `pause_turn` live is unknown, and the scenario falls back to a rebuilt paused-turn shape (Appendix A5). Scenario 16 part B checks citations replay live (decision 27 B3). Prices live in `test/support/e2e/prices.ex`; the runner's suite cap rises from 140 to 150; `mix e2e --estimate` prints $1.92 expected / $2.24 upper.
- **H14 (7.6b)** The run uses partition `_w54probe` (never `mix ecto.setup`). **H15 (7.4a)** A failing `cog` fails the Release job. **H16 (7.1b)** Row 26 gets no MIGRATING bullet (not observable). **H17 (7.1c)** The triage table goes to `wave-7-migrating-triage.md` and the commit body.

## Review Focus

1. **A terminal save that fails, then the store recovers, or the node restarts the session eagerly.** Expect exactly one answer in history, no second model call, the session out of the in-flight index once saved, and `run` refused with `:persist_failed` meanwhile — on every session-store backend. Tests: Task 7.0b (InMemory unit, the five backends through the tagged suites).
2. **A user who copies `docs/guides/testing.md`.** Expect every example to run against `FakeClient` on `run/3`, `stream/3` and `Turn.Session`, and a misspelled script item to raise a message naming it. Tests: Tasks 7.3b, 7.3e.
3. **A third-party store author who passes only `new:` to a shipped contract.** Expect every contract test to run (delete tests via the public API). Test: Task 7.3d (a contract run against InMemory with `stored_entry_ids: nil`).
4. **A user on Elixir 1.15 or 1.16.** Expect the library to compile. Tests: Task 7.0d (the guard), Task 7.7 (the CI matrix legs 1.15/26 and 1.16/26).
5. **A user upgrading from 1.3 who reads only MIGRATING's index.** Expect every removed or changed public function in `tools/api_diff` output to appear in a section the index sends them to. Test: Task 7.1b (the diff run recorded in the commit body, zero unmatched items).

---

### Task 7.0a: Dispatch renders a tool output once (A4, row 11)

Dispatch encodes a map or list tool output four times (`wrap_output/2`'s encodability check,
`execute/4`'s and `finish/3`'s `ensure_encodable/1`, and the cap's `render_output/1`), and memory
encodes it a fifth time when the result is appended (inventory §1.2). This task renders it once
in Dispatch, with the function memory uses, and carries `{output, text}` through `after_tool`,
the encodability checks and the cap; a hook that replaces the output costs one more rendering.
Memory's encoding is unchanged, so the wire bytes are unchanged (`wire_identity_test.exs` stays
green). Row 11: an output whose encoding raised is described by the exception's module, never
by `Exception.message/1` (a `Jason.EncodeError` quotes the output's bytes).

**Files:**
- Modify: `lib/normandy/components/tool_result.ex` (new `render/1`; `render_output/1` built on it)
- Modify: `lib/normandy/agents/dispatch.ex` (`finish/3` → `finish/4`; `ensure_encodable/1` → private `encodable/2`; `execute/4`, `wrap_output/2`, `wrap_error/2`, `cap/3` → `cap/4`, `unencodable/1`)
- Modify: `MIGRATING-2.0.md` (`## 36.`, one bullet)
- Test: modify `test/agents/linear_history_test.exs`; create `test/agents/dispatch_render_test.exs`

**Interfaces:**
- Consumes: `Normandy.JSON.sort_keys/1`, `Normandy.JSON.encode/2` (non-raising, rescues the adapter's exception; a misconfigured `:adapter` still raises), `Describe.type_of/1`.
- Produces: `ToolResult.render(term) :: {:ok, String.t()} | {:error, Exception.t()}` (`@doc false`); `ToolResult.render_output/1` unchanged in contract (raises the exception `render/1` returns). `Dispatch.ensure_encodable/1` (`@doc false`, no caller outside `dispatch.ex`: `grep -rn ensure_encodable lib test` → only `dispatch.ex`) is removed. `Dispatch.finish/3` keeps its contract (ServerGlue).

- [ ] **Step 1: Write the failing tests**

In `test/agents/linear_history_test.exs`:

Replace the moduledoc's last paragraph

```elixir
  Counted: `BaseIOSchema.to_json/1` of `Normandy.Test.CountingContent` (memory content)
  and `Jason.Encoder.encode/2` of `CountingOutput` (a tool's output: Dispatch encodes it
  four times, in `execute/4`'s and `finish/3`'s encodability checks, `wrap_output/2` and
  the result cap, and memory once, when the result is appended).
```

with

```elixir
  Counted: `BaseIOSchema.to_json/1` of `Normandy.Test.CountingContent` (memory content)
  and `Jason.Encoder.encode/2` of `CountingOutput` (a tool's output: Dispatch renders it
  once and reuses the text for its encodability checks and the result cap, Task 7.0a, and
  memory encodes it once, when the result is appended). `Turn.Inline` over
  `Dispatch.dispatch_one/3` costs the same.
```

Replace the alias block's first lines

```elixir
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
```

with

```elixir
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Inline
```

and after `alias Normandy.Components.AgentMemory.Entry` add `alias Normandy.Components.ToolCall`.

Replace

```elixir
  # Encodings per tool result: Dispatch's four, memory's one. Constant in N.
  @per_result 5
```

with

```elixir
  # Encodings per tool result: Dispatch's one, memory's one. Constant in N, with the
  # result cap on or off.
  @per_result 2
```

The existing tests (`run`/`stream` × compactor × turns, the compaction test, `Turn.Session`) keep
their assertions; they now expect 2 per result. Add before the module's final `end`:

```elixir
  test "run with the result cap off: each tool result is encoded twice" do
    {seeded, out} = counters()

    config =
      WireScript.client(json_replies(1..3))
      |> agent(out, seeded_memory(seeded), {Compactor.NoOp, []})
      |> Map.put(:max_tool_result_chars, nil)

    Enum.reduce(1..3, config, fn t, config ->
      {:ok, config, _} = BaseAgent.run(config, "question #{t}")
      config
    end)

    assert CountingContent.count(out) == @per_result * 3
  end

  test "Turn.Inline over dispatch_one/3: each tool result is encoded twice" do
    {seeded, out} = counters()
    config = agent(WireScript.client([]), out, seeded_memory(seeded), {Compactor.NoOp, []})
    {:ok, memory} = Agent.start_link(fn -> config.memory end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    call = %ToolCall{id: "t1", name: "rows", input: %{}}

    deps = %{
      call_llm: fn _request ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, %ToolCallResponse{tool_calls: [call]}}
          _ -> {:ok, %ToolCallResponse{content: "done", tool_calls: []}}
        end
      end,
      dispatch: fn calls ->
        Enum.map(calls, &Dispatch.dispatch_one(config, &1, BaseAgent.base_agent_pipeline(config)))
      end,
      append: fn role, content ->
        Agent.update(memory, &AgentMemory.add_message(&1, role, content))
      end
    }

    assert {:ok, %Turn.State{status: :stopped}} =
             Inline.run(Turn.new(response_model: %ToolCallResponse{}), deps)

    assert CountingContent.count(out) == @per_result
  end
```

Create `test/agents/dispatch_render_test.exs`:

```elixir
defmodule Normandy.Agents.DispatchRenderTest do
  @moduledoc """
  Task 7.0a (A4): Dispatch renders a tool output once, with `ToolResult.render/1`: the
  text memory sent before, and the same outputs fail it as failed `Normandy.JSON.encode/1`
  (so no output becomes, or stops being, an error result). An output JSON cannot write
  is described by the exception's module, never its message (row 11).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.Dispatch
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.ReturnTool
  alias Normandy.Tools.Toolset

  defp leaf do
    one_of([
      integer(),
      float(),
      boolean(),
      constant(nil),
      atom(:alphanumeric),
      string(:printable),
      binary(),
      constant(self()),
      constant(make_ref()),
      tuple({integer(), atom(:alphanumeric)})
    ])
  end

  defp key, do: one_of([atom(:alphanumeric), string(:printable), integer(), constant({:k, 1})])

  defp output do
    tree(leaf(), fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(key(), child, max_length: 3),
        constant([1 | 2])
      ])
    end)
  end

  # Wrapped in a list: a bare binary or number is not encoded (Dispatch checks a binary's
  # UTF-8 itself), and Dispatch encodes only the other outputs.
  property "render/1 fails exactly on the outputs Normandy.JSON.encode/1 fails on" do
    check all(term <- map(output(), &[&1]), max_runs: 500) do
      assert match?({:ok, _}, ToolResult.render(term)) ==
               match?({:ok, _}, Normandy.JSON.encode(term))
    end
  end

  # The text memory sent before Task 7.0a (ToolResult.render_output/1 was sort_keys then
  # encode!): the wire does not change.
  property "render/1 gives the text sort_keys then encode! gave, or that call's exception" do
    check all(term <- map(output(), &[&1])) do
      expected =
        try do
          {:ok, term |> Normandy.JSON.sort_keys() |> Normandy.JSON.encode!()}
        rescue
          exception -> {:error, exception.__struct__}
        end

      actual =
        case ToolResult.render(term) do
          {:ok, text} -> {:ok, text}
          {:error, %module{}} -> {:error, module}
        end

      assert actual == expected
    end
  end

  defp dispatch(output) do
    config = %{toolset: Toolset.new([%ReturnTool{name: "t", output: output}])}
    Dispatch.dispatch_one(config, %ToolCall{id: "c1", name: "t", input: %{}})
  end

  test "an output with invalid UTF-8 inside is described by the exception's module" do
    assert %ToolResult{is_error: true, output: text} = dispatch(%{"rows" => <<0xFF, "secret">>})

    assert text ==
             "the tool ran, but its output cannot be sent as JSON: encoding it raised Jason.EncodeError"

    refute text =~ "secret"
  end

  test "an output with a tuple key is described by the value's type" do
    assert %ToolResult{is_error: true, output: text} = dispatch(%{{:k, 1} => 1})

    assert text ==
             "the tool ran, but its output cannot be sent as JSON: it contains a tuple"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/linear_history_test.exs test/agents/dispatch_render_test.exs`
Expected: FAIL. Every count test in `linear_history_test.exs` fails with `left: 5`/`right: 2`
(1 turn), `left: 40`/`right: 16` (8 turns); the two new tests with `left: 12`/`right: 6` and
`left: 5`/`right: 2` (the cap-off run counts 4 per result). Both properties fail with
`UndefinedFunctionError` for `Normandy.Components.ToolResult.render/1`; the UTF-8 test fails
because the text is `Jason.EncodeError`'s message (`"invalid byte 0xFF in <<255, 115, ...>>"`).
The tuple-key test passes (unchanged behaviour, kept as a guard).

- [ ] **Step 3: `ToolResult.render/1`**

In `lib/normandy/components/tool_result.ex`, replace the `@doc false` comment block and
`render_output/1` (from `@doc false` to the last `def render_output`) with:

```elixir
  @doc false
  # The text the model reads for `output` (BaseIOSchema.to_json/1 below, and
  # Normandy.Agents.Dispatch, which renders each output once for its encodability check
  # and its cap): a binary as-is, a number as its digits, anything else (a map, a list,
  # an atom, a boolean, nil) as JSON, every plain map's keys sorted (Normandy.JSON "Text
  # for the model": the same result is the same text on every node). An output JSON
  # cannot express is {:error, exception}: what sorting its keys raised (a tuple key, an
  # improper list) or what the adapter raised (Normandy.JSON.encode/2; a misconfigured
  # :adapter still raises). A binary is returned unchecked; Dispatch checks its UTF-8.
  @spec render(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def render(output) when is_binary(output), do: {:ok, output}
  def render(output) when is_number(output), do: {:ok, to_string(output)}

  def render(output) do
    with {:ok, sorted} <- sort_keys(output), do: Normandy.JSON.encode(sorted)
  end

  defp sort_keys(output) do
    {:ok, Normandy.JSON.sort_keys(output)}
  rescue
    exception -> {:error, exception}
  end

  @doc false
  # render/1's text. Dispatch turns an output JSON cannot express into an error result
  # after every hook has run, so this raises only for a ToolResult built outside Dispatch.
  @spec render_output(term()) :: String.t()
  def render_output(output) do
    case render(output) do
      {:ok, text} -> text
      {:error, exception} -> raise exception
    end
  end
```

The BaseIOSchema impl below it is unchanged (it calls `render_output/1`).

- [ ] **Step 4: Dispatch carries the rendering**

In `lib/normandy/agents/dispatch.ex`:

1. Replace `finish/3` and the whole `ensure_encodable/1` (its comment, `@doc false`, `@spec` and
   three clauses) with:

```elixir
  @doc false
  # The last step of every result that leaves Dispatch, and of the results
  # Normandy.Hooks.ServerGlue rewrites through after_tool (interrupted, rejected and
  # expired results, which skip Dispatch): encodable/2, then the cap (see the
  # moduledoc's "Result cap"). Runs once per result: the cap's note is not idempotent.
  @spec finish(map(), ToolCall.t(), ToolResult.t()) :: ToolResult.t()
  def finish(config, %ToolCall{} = call, %ToolResult{} = result),
    do: finish(config, call, result, nil)

  defp finish(config, call, result, rendering) do
    {result, {_output, text}} = encodable(result, rendering)
    cap(result, text, config, call)
  end

  # A rendering is {output, text}: the output a result held when ToolResult.render/1
  # turned it into text, so later steps reuse the text while the result still holds that
  # output (=== on the same term returns at once) and render again only when a hook
  # replaced it. nil when nothing was rendered yet.
  #
  # Hooks (before-hook halts, after_tool, after_hooks) may build any %ToolResult{},
  # and memory keeps it for every later request. So the encodability check runs on
  # the final result, the last point before it can reach memory. Returns the result,
  # replaced by an error result when the model could not read it, and its rendering.
  defp encodable(%ToolResult{output: output} = result, {rendered, _text} = rendering)
       when output === rendered,
       do: {result, rendering}

  defp encodable(%ToolResult{output: output} = result, _stale_or_nil) do
    case ToolResult.render(output) do
      {:ok, text} when is_binary(output) ->
        if String.valid?(text),
          do: {result, {output, text}},
          else: unreadable(result, invalid_utf8_output())

      {:ok, text} ->
        {result, {output, text}}

      {:error, exception} ->
        unreadable(result, unencodable_output(exception))
    end
  end

  defp unreadable(result, message),
    do: {%{result | output: message, is_error: true}, {message, message}}
```

(The name `error_result` is taken: `Dispatch.error_result/3` is public.)

2. In `execute/4`, replace the `:ok ->` branch body with:

```elixir
      :ok ->
        {result, rendering} = execute_and_wrap(config, call, invocation, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)

        {result, rendering} =
          config |> after_tool_slot(call, result, pipeline) |> encodable(rendering)

        config
        |> run_after_hooks(call, result, pipeline.after_hooks)
        |> Map.put(:tool_call_id, call.id)
        |> then(&finish(config, call, &1, rendering))
```

`execute_and_wrap/4` is unchanged: it returns what `wrap_output/2` or `wrap_error/2` returns,
now a `{result, rendering}` pair.

3. Replace `wrap_output/2` (both clauses and the comment above them) with:

```elixir
  # The model reads a tool result as JSON (ToolResult's BaseIOSchema impl), and
  # memory keeps the result for every later request. So an output JSON cannot
  # express (a tuple, a pid) is replaced here by an error result that says so,
  # before it reaches memory. Returns the result and its rendering (encodable/2); a
  # binary is checked after the after_tool slot, which may still replace it.
  defp wrap_output(call, output) when is_binary(output) or is_number(output),
    do: {%ToolResult{tool_call_id: call.id, output: output, is_error: false}, nil}

  defp wrap_output(call, output),
    do: encodable(%ToolResult{tool_call_id: call.id, output: output, is_error: false}, nil)
```

4. Replace the three `wrap_error/2` clauses (keep the comment above them) with:

```elixir
  defp wrap_error(call, error) when is_binary(error),
    do: {%ToolResult{tool_call_id: call.id, output: error, is_error: true}, nil}

  defp wrap_error(call, error) when is_exception(error),
    do:
      {%ToolResult{tool_call_id: call.id, output: Exception.message(error), is_error: true},
       nil}

  defp wrap_error(call, error) do
    output = %{error: error}

    case ToolResult.render(output) do
      {:ok, text} ->
        {%ToolResult{tool_call_id: call.id, output: output, is_error: true}, {output, text}}

      {:error, _exception} ->
        {%ToolResult{tool_call_id: call.id, output: %{error: inspect(error)}, is_error: true},
         nil}
    end
  end
```

5. Replace `cap/3` (keep the three comment lines above it) with:

```elixir
  # text is the result's rendering (encodable/2), what the model reads.
  defp cap(result, text, config, call) do
    case result_limit(config, call.name) do
      {nil, _source} -> result
      {limit, source} -> cap_text(result, text, %{limit: limit, source: source}, config, call)
    end
  end
```

6. Replace `defp unencodable(exception), do: Exception.message(exception)` with:

```elixir
  # By the exception's module only: a message (Jason.EncodeError's "invalid byte ... in
  # <<...>>") can quote the output's bytes into the model's text.
  defp unencodable(%module{}), do: "encoding it raised #{inspect(module)}"
```

Check: `grep -n "ensure_encodable\|JSON.encode(" lib/normandy/agents/dispatch.ex` → 0 hits;
`grep -rn "render_output" lib` → `tool_result.ex` (its definition and the BaseIOSchema impl)
and one comment in `lib/normandy/json.ex` ("Callers: ToolResult.render_output/1 ..."), still true.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/linear_history_test.exs test/agents/dispatch_render_test.exs test/agents/wire_identity_test.exs test/agents/tool_result_cap_test.exs test/agents/model_text_key_order_test.exs test/agents/turn/server_store_failures_test.exs test/hooks/tool_hooks_test.exs test/json_struct_encoding_test.exs test/agents/turn/server_test.exs`
Expected: PASS. `wire_identity_test.exs`, `tool_result_cap_test.exs` (incl. "Dispatch.finish/3 at
the chokepoint"), `model_text_key_order_test.exs`, `tool_hooks_test.exs:129` and
`server_test.exs:2875` ("... it contains a tuple") pass unchanged.

- [ ] **Step 6: Gate**

Run: `mix format && mix precommit 2>&1 | tee /tmp/7.0a-precommit.log` → ` 0 failures`, exit 0;
`mix docs --warnings-as-errors` → exit 0. No tagged suite (no store, registry or persistence
change).

- [ ] **Step 7: MIGRATING-2.0.md**

In `## 36. Model-facing text and schemas`, after the bullet that ends
"must match the binary. Other error terms keep `%{error: term}`.", add:

```markdown
- An output whose encoding raised (a map holding a string that is not valid UTF-8, which
  makes Jason raise `Jason.EncodeError`) reaches the model as "the tool ran, but its output
  cannot be sent as JSON: encoding it raised Jason.EncodeError", the exception's module,
  instead of the exception's message, which quoted the output's bytes. A value JSON cannot
  express is still named by its type ("... it contains a tuple").
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/components/tool_result.ex
git add lib/normandy/agents/dispatch.ex
git add test/agents/linear_history_test.exs
git add test/agents/dispatch_render_test.exs
git add MIGRATING-2.0.md
git commit -m "perf(dispatch): render a tool output once

Dispatch encoded a map or list tool output four times (two encodability
checks, wrap_output/2 and the result cap). ToolResult.render/1 renders it
once and the text is reused while the output is unchanged; a hook that
replaces the output costs one more rendering. Memory's encoding, and so
the wire, is unchanged: 2 encodings per result on run/3, stream/3,
Turn.Server and Turn.Inline (was 5).

An output whose encoding raised is described by the exception's module,
not its message, which could quote the output's bytes (W5 5.4a)."
```

---

### Task 7.0b: A refused terminal save is retried; an answered turn is not resumed (H10, row 3)

`Turn.Server` discards the result of the terminal turn-state save (`server.ex:1498`, `:1507`:
`_ = persist_turn_state(...)`). When the store refuses it, nothing is logged, the store keeps the
turn's last in-flight save (`:steering`, `inflight: true`), and **any** eager start resumes the
finished turn: the inventory's probe re-ran the model call and stored a second answer. This task
(decision 27 A1, A2): logs the refusal by tag; keeps the state in a new `Data` field
`unsaved_terminal` and saves it again on a timer, before the next turn request (refused with
`:persist_failed` until it lands) and before passivation (deferred until it lands); and, on an
eager resume of a `:steering` turn whose answer is already the last stored message, saves the turn
as finished without a model call (this also covers a crash between the answer's append and the
terminal save, with no store fault). No `SessionStore` callback, persisted format, Turn core
effect or telemetry event changes, so `Turn.Driver`, `Turn.Inline`, `run/3` and `stream/3` are
untouched (they have no store).

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (moduledoc section "Terminal saves"; `Data`
  field; two module attributes; four `handle_event/4` clauses; `{:finalize, _}`/`{:fail, _}`;
  new private functions)
- Modify: `lib/normandy/agents/turn.ex` (new `answered?/1`)
- Modify: `MIGRATING-2.0.md` (create `## 43.`; `## 39.` first bullet; Known limits H10 bullet)
- Create: `test/support/terminal_save_store.ex` (`Normandy.Test.TerminalSaveStore`)
- Create: `test/support/terminal_save_cases.ex` (`Normandy.Test.TerminalSaveCases`)
- Test: create `test/agents/turn/terminal_save_test.exs`; modify
  `test/behaviours/session_store/ets_test.exs`, `mnesia_test.exs`, `redis_test.exs`,
  `postgres_contract_test.exs` (one `use` line each); modify the comment at
  `test/agents/turn/server_store_failures_test.exs` ("a terminal save is best-effort")

**Interfaces:**
- Consumes: `persist_turn_state/2` (returns `:ok | {:error, Describe.reason_term(reason)}`),
  `describe_reason/1`, `emit_failed_run/4`, `turn_end/4`, `release_turn_ctx/1`, `idle_timeout/1`,
  `start_resumed_run_span/1`, `close_resumed_batch/1` (all in `server.ex`); `Turn.tool_calls/1`,
  `Turn.paused?/1` (private, in `turn.ex`); `AgentMemory.messages/1`.
- Produces: `Turn.Server.Data.unsaved_terminal :: Turn.State.t() | nil` (header);
  `{:timeout, :retry_terminal_save}` generic timeout whose content is its own delay (1_000 ms,
  doubling to 30_000 ms); `run/2` reply `{:error, %TurnError{type: :persist_failed, reason:
  {:terminal_unsaved, reason}}}`; `Normandy.Agents.Turn.answered?([Message.t()]) :: boolean()`
  (public, documented: the resume guard's predicate, header "Resume guard"); log line
  `Turn.Server session "sid": turn state not saved; retrying (<tag>)` at `:warning` with
  metadata `session_id`, `reason` (Header conflicts 1); test support `Normandy.Test.TerminalSaveStore`
  and `Normandy.Test.TerminalSaveCases`.

The predicate (header "Resume guard"): the loaded turn state's `status` is `:steering` **and**
the last message of the loaded memory is `%Message{role: "assistant"}` whose content makes no
tool call (`Turn.tool_calls/1 == []`) **and** is not a paused turn (`Turn.paused?/1` false:
`stop_reason` `:pause_turn` or `"pause_turn"`). The core appends an assistant message with no
tool call only in the `:output_guarded` step (the answer) or `continue_paused/2` (a paused turn,
sent back for the model to continue), so the predicate is the answer and nothing else. A
`:steering` save with empty history (`eager_resume_test.exs`) or ending in tool results or the
iteration-cap notice still resumes; `:awaiting_approval` is never guarded.

State/data changes, all in `:idle`:

| Event in `:idle` | `unsaved_terminal` is `nil` | `unsaved_terminal` is set |
|---|---|---|
| `{:call, from}` turn request | as today | save it; saved → clear, cancel the timer, re-insert the request (`{:next_event, {:call, from}, msg}`); refused → reply `{:error, %TurnError{type: :persist_failed, reason: {:terminal_unsaved, reason}}}`, run `:start` + `:exception`, `on_turn_end`, nothing appended |
| `:state_timeout :passivate` | as today | save it; saved → clear, cancel the timer, re-insert `:passivate` (the existing clause runs `on_passivate` and stops); refused → stay, re-arm `idle_timeout` |
| `{:timeout, :retry_terminal_save}` (content `delay_ms`) | cannot fire (cancelled on every save that lands) | save it; saved → clear; refused → re-arm with `min(delay_ms * 2, 30_000)` |
| stale approval cast, stray `:info` | dropped (unchanged) | dropped (unchanged) |

Entering `:idle` from `{:finalize, _}`, `{:fail, _}` or the resume guard calls
`save_terminal/2`: saved → as today; refused → log, set `unsaved_terminal`, arm the timer at
1_000 ms. Every refused retry logs the same warning.

- [ ] **Step 1: Write the failing tests (the eager-restart reproduction first)**

Create `test/support/terminal_save_store.ex`:

```elixir
defmodule Normandy.Test.TerminalSaveStore do
  @moduledoc """
  A session store for tests that wraps another (`{module, handle}`) and refuses
  terminal turn-state saves (`:stopped`, `:failed`) while its switch is on, as a store
  in an outage does. Every other call goes to the wrapped store.

  `new/1` takes the wrapped `{module, handle}` and returns this store's handle.
  `fail_terminal/2` flips the switch. `ops/1` returns every `save_turn_state/4` and
  `append_entry/3` in call order: `{:save, status, inflight?, :ok | :refused}` and
  `{:append, role}`. A refused save writes nothing and returns `{:error, :store_down}`.
  """

  alias Normandy.Agents.Turn

  defstruct [:inner, :agent]

  @type t :: %__MODULE__{inner: {module(), term()}, agent: pid()}

  @spec new({module(), term()}) :: t()
  def new({mod, _handle} = inner) when is_atom(mod) do
    {:ok, agent} = Agent.start_link(fn -> %{fail?: false, ops: []} end)
    %__MODULE__{inner: inner, agent: agent}
  end

  @spec fail_terminal(t(), boolean()) :: :ok
  def fail_terminal(%__MODULE__{agent: agent}, fail?) when is_boolean(fail?),
    do: Agent.update(agent, &%{&1 | fail?: fail?})

  @spec ops(t()) :: [tuple()]
  def ops(%__MODULE__{agent: agent}), do: agent |> Agent.get(& &1.ops) |> Enum.reverse()

  def append_entry(%__MODULE__{inner: {mod, h}} = store, sid, entry) do
    record(store, {:append, entry.role})
    mod.append_entry(h, sid, entry)
  end

  def history(%__MODULE__{inner: {mod, h}}, sid), do: mod.history(h, sid)
  def load_turn_state(%__MODULE__{inner: {mod, h}}, sid), do: mod.load_turn_state(h, sid)
  def list_resumable(%__MODULE__{inner: {mod, h}}), do: mod.list_resumable(h)

  def save_turn_state(%__MODULE__{inner: {mod, h}} = store, sid, %Turn.State{} = ts, inflight?) do
    if ts.status in [:stopped, :failed] and Agent.get(store.agent, & &1.fail?) do
      record(store, {:save, ts.status, inflight?, :refused})
      {:error, :store_down}
    else
      result = mod.save_turn_state(h, sid, ts, inflight?)
      record(store, {:save, ts.status, inflight?, :ok})
      result
    end
  end

  defp record(%__MODULE__{agent: agent}, op),
    do: Agent.update(agent, &%{&1 | ops: [op | &1.ops]})
end
```

Create `test/support/terminal_save_cases.ex`. Its second test is the inventory's probe
(`probe_h10.exs`) as a test: a tool turn whose terminal save is refused, the server stopped
before any retry, the store back, an eager start of the same session.

```elixir
defmodule Normandy.Test.TerminalSaveCases do
  @moduledoc """
  Task 7.0b (H10, Review Focus #1) on one session-store backend: a turn whose terminal
  save the store refuses is saved before the next turn, and an eager restart never asks
  the model again for a turn whose answer is stored.

  `use` it in a test module that also `use ExUnit.Case`, after any setup the backend
  needs (the store's `new/0` must return its handle, as for the store contract):

      use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.ETS

  `config/1` and `start/5` are public for tests that need more than these two cases.
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Components.ToolCall
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TerminalSaveStore

  @doc """
  An agent with one tool whose model answers in rounds of two calls: a call to the
  tool `"big"`, then the text `"done"`. Each call sends `{:converse, request, opts}`
  to `owner`.
  """
  @spec config(pid()) :: Normandy.Agents.BaseAgentConfig.t()
  def config(owner) do
    calls = :atomics.new(1, [])

    reply = fn _response_model ->
      n = :atomics.add_get(calls, 1, 1)

      if rem(n, 2) == 1,
        do: %ToolCallResponse{tool_calls: [%ToolCall{id: "call_#{n}", name: "big", input: %{}}]},
        else: %ToolCallResponse{content: "done", tool_calls: []}
    end

    %{client: %StubClient{notify: owner, reply: reply}, model: "m"}
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ReturnTool{output: "ok"})
  end

  @doc """
  Starts an eager server for `sid` under `sup`, on `store` (a `TerminalSaveStore`), with
  `config(self())`; `opts` are added to the start options (`:idle_timeout_ms`).
  """
  @spec start(pid(), String.t(), TerminalSaveStore.t(), term(), keyword()) :: pid()
  def start(sup, sid, store, registry, opts \\ []) do
    {:ok, pid} =
      Turn.Supervisor.start_server(
        sup,
        [
          session_id: sid,
          config: config(self()),
          store: {TerminalSaveStore, store},
          registry: {Native, registry},
          resume_policy: :eager
        ] ++ opts
      )

    pid
  end

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote bind_quoted: [store: store] do
      alias Normandy.Agents.Turn
      alias Normandy.Behaviours.SessionRegistry.Native
      alias Normandy.Test.TerminalSaveCases
      alias Normandy.Test.TerminalSaveStore

      @terminal_save_backend store

      describe "a refused terminal save (#{inspect(store)})" do
        setup do
          inner = {@terminal_save_backend, @terminal_save_backend.new()}

          {:ok,
           inner: inner,
           store: TerminalSaveStore.new(inner),
           sup: start_supervised!({Turn.Supervisor, max_restarts: 0}),
           registry: Native.new(),
           sid: "terminal-save-#{System.unique_integer([:positive])}"}
        end

        test "lands before the next turn starts; the session leaves the in-flight index", ctx do
          %{inner: {mod, h}, store: store, sid: sid} = ctx
          srv = TerminalSaveCases.start(ctx.sup, sid, store, ctx.registry)

          TerminalSaveStore.fail_terminal(store, true)
          assert {:ok, %{chat_message: "done"}} = Turn.Server.run(srv, %{chat_message: "one"})
          assert {:ok, [^sid]} = mod.list_resumable(h)
          assert {:ok, %Turn.State{status: :steering}} = mod.load_turn_state(h, sid)

          TerminalSaveStore.fail_terminal(store, false)
          assert {:ok, %{chat_message: "done"}} = Turn.Server.run(srv, %{chat_message: "two"})

          # The refused save is retried, and lands, before the second turn's first write.
          assert TerminalSaveStore.ops(store) == [
                   {:append, "user"},
                   {:append, "assistant"},
                   {:append, "tool"},
                   {:save, :steering, true, :ok},
                   {:append, "assistant"},
                   {:save, :stopped, false, :refused},
                   {:save, :stopped, false, :ok},
                   {:append, "user"},
                   {:append, "assistant"},
                   {:append, "tool"},
                   {:save, :steering, true, :ok},
                   {:append, "assistant"},
                   {:save, :stopped, false, :ok}
                 ]

          assert {:ok, []} = mod.list_resumable(h)
          assert {:ok, %Turn.State{status: :stopped}} = mod.load_turn_state(h, sid)
        end

        test "an eager restart makes no model call and stores no second answer", ctx do
          %{inner: {mod, h}, store: store, sid: sid} = ctx
          srv = TerminalSaveCases.start(ctx.sup, sid, store, ctx.registry)

          TerminalSaveStore.fail_terminal(store, true)
          assert {:ok, %{chat_message: "done"}} = Turn.Server.run(srv, %{chat_message: "one"})
          assert_received {:converse, _, _}
          assert_received {:converse, _, _}

          # The process dies before any retry lands (the window no retry can close).
          :ok = Turn.Supervisor.stop_server(ctx.sup, srv)
          TerminalSaveStore.fail_terminal(store, false)

          restarted = TerminalSaveCases.start(ctx.sup, sid, store, ctx.registry)
          # The load and the :resume event run before the server takes this message.
          assert {:idle, _data} = :sys.get_state(restarted)

          refute_received {:converse, _, _}
          {:ok, entries} = mod.history(h, sid)
          assert Enum.map(entries, & &1.role) == ["user", "assistant", "tool", "assistant"]
          assert {:ok, %Turn.State{status: :stopped}} = mod.load_turn_state(h, sid)
          assert {:ok, []} = mod.list_resumable(h)
        end
      end
    end
  end
end
```

Run the cases on every backend. In each file below, add the line right after the
`use Normandy.SessionStoreContract, ...` call (after its `stored_entry_ids:` line), so each
backend's own setup (the Mnesia reset, the Postgres sandbox checkout and table clean-up) runs
first:

| File | Line to add |
|---|---|
| `test/behaviours/session_store/ets_test.exs` | `use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.ETS` |
| `test/behaviours/session_store/mnesia_test.exs` (module `MnesiaTest`) | `use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.Mnesia` |
| `test/behaviours/session_store/redis_test.exs` (`@moduletag :redis`) | `use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.Redis` |
| `test/behaviours/session_store/postgres_contract_test.exs` (`@moduletag :postgres`) | `use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.Postgres` |

Create `test/agents/turn/terminal_save_test.exs` (InMemory: the two cases, plus the log line,
the refusal, the timer, passivation, a paused turn's resume and the predicate):

```elixir
defmodule Normandy.Agents.Turn.TerminalSaveTest do
  @moduledoc """
  Task 7.0b (H10, decision 27 A1/A2): a terminal turn-state save the store refuses is
  logged, kept and saved again (before the next turn, at passivation, on a timer); turns
  are refused meanwhile; a resumed turn whose answer is stored makes no model call.
  `Normandy.Test.TerminalSaveCases` runs on InMemory at the end of this file and in each
  other backend's store test.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.{BaseAgentInputSchema, BaseAgentOutputSchema, ToolCallResponse, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.{Message, ToolCall}
  alias Normandy.Test.{TerminalSaveCases, TerminalSaveStore}
  alias Normandy.TurnError

  setup do
    mem = InMemory.new()

    {:ok,
     mem: mem,
     store: TerminalSaveStore.new({InMemory, mem}),
     sup: start_supervised!({Turn.Supervisor, max_restarts: 0}),
     registry: Native.new(),
     sid: "terminal-save-#{System.unique_integer([:positive])}"}
  end

  defp start(ctx, opts \\ []),
    do: TerminalSaveCases.start(ctx.sup, ctx.sid, ctx.store, ctx.registry, opts)

  defp refused_saves(store),
    do: Enum.count(TerminalSaveStore.ops(store), &match?({:save, _, _, :refused}, &1))

  describe "a refused terminal save" do
    test "is logged by its tag with the session id; the turn still replies {:ok, _}", ctx do
      srv = start(ctx)
      TerminalSaveStore.fail_terminal(ctx.store, true)

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:session_id]], fn ->
          assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
                   Turn.Server.run(srv, %{chat_message: "one"})
        end)

      assert log =~
               "session_id=#{ctx.sid} [warning] Turn.Server session #{inspect(ctx.sid)}: " <>
                 "turn state not saved; retrying (:store_down)"

      assert {:ok, [_]} = InMemory.list_resumable(ctx.mem)
    end

    test "refuses the next turn with :persist_failed while the store still refuses it", ctx do
      srv = start(ctx)
      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
      assert_received {:converse, _, _}
      assert_received {:converse, _, _}
      {:ok, before} = InMemory.history(ctx.mem, ctx.sid)

      assert {:error, %TurnError{} = error} = Turn.Server.run(srv, %{chat_message: "two"})
      assert error.type == :persist_failed
      assert error.reason == {:terminal_unsaved, :store_down}

      assert Exception.message(error) ==
               "turn failed: persist failed: the session store rejected a write " <>
                 "({:terminal_unsaved, ...})"

      refute_received {:converse, _, _}
      assert InMemory.history(ctx.mem, ctx.sid) == {:ok, before}
      assert {:ok, %Turn.State{status: :steering}} = InMemory.load_turn_state(ctx.mem, ctx.sid)

      TerminalSaveStore.fail_terminal(ctx.store, false)

      assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
               Turn.Server.run(srv, %{chat_message: "two"})

      assert {:ok, []} = InMemory.list_resumable(ctx.mem)
    end

    test "is saved by the retry timer with no turn request", ctx do
      srv = start(ctx)
      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
      TerminalSaveStore.fail_terminal(ctx.store, false)

      # The first retry fires 1_000 ms after the refusal. TerminalSaveStore records a
      # save after the wrapped store wrote it, so wait for the record.
      assert wait_until(
               fn ->
                 List.last(TerminalSaveStore.ops(ctx.store)) == {:save, :stopped, false, :ok}
               end,
               300
             )

      assert {:ok, []} = InMemory.list_resumable(ctx.mem)
      assert {:ok, %Turn.State{status: :stopped}} = InMemory.load_turn_state(ctx.mem, ctx.sid)
      assert Process.alive?(srv)
    end

    test "defers passivation until it lands", ctx do
      srv = start(ctx, idle_timeout_ms: 20)
      ref = Process.monitor(srv)
      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})

      # The turn's own save, then at least two passivations that found it unsaved.
      assert wait_until(fn -> refused_saves(ctx.store) >= 3 end)
      refute_received {:DOWN, ^ref, :process, ^srv, _}
      assert Native.whereis(ctx.registry, ctx.sid) == {:ok, srv}

      TerminalSaveStore.fail_terminal(ctx.store, false)
      assert_receive {:DOWN, ^ref, :process, ^srv, {:shutdown, :passivated}}, 2_000
      assert {:ok, []} = InMemory.list_resumable(ctx.mem)
    end
  end

  describe "an eager resume of a saved :steering turn" do
    test "whose history ends in a paused turn calls the model", ctx do
      paused = %ToolCallResponse{content: "searching", tool_calls: [], stop_reason: :pause_turn}

      for {role, content} <- [
            {"user", %BaseAgentInputSchema{chat_message: "one"}},
            {"assistant", paused}
          ] do
        entry = %Entry{id: UUID.uuid4(), turn_id: "t1", role: role, content: content}
        {:ok, _} = InMemory.append_entry(ctx.mem, ctx.sid, entry)
      end

      steering = %Turn.State{status: :steering, iterations_left: 5, max_iterations: 5}
      :ok = InMemory.save_turn_state(ctx.mem, ctx.sid, steering, true)

      _srv = start(ctx)

      # The load, the resume and the call's task run before the message: under a full
      # suite they can take longer than assert_receive's default 100 ms.
      assert_receive {:converse, _request, _opts}, 5_000
    end
  end

  describe "Turn.answered?/1" do
    @answer %Message{role: "assistant", content: %BaseAgentOutputSchema{chat_message: "done"}}
    @user %Message{role: "user", content: %BaseAgentInputSchema{chat_message: "one"}}
    @call %ToolCall{id: "c1", name: "big", input: %{}}

    test "is true when the last message is an assistant answer" do
      assert Turn.answered?([@user, @answer])
      assert Turn.answered?([@user, %Message{role: "assistant", content: "done"}])
    end

    test "is false for a tool call, a paused turn, a tool result, a user message or nothing" do
      tool_use = %Message{role: "assistant", content: %ToolCallResponse{tool_calls: [@call]}}
      paused = %ToolCallResponse{tool_calls: [], stop_reason: :pause_turn}
      paused_wire = %{paused | stop_reason: "pause_turn"}

      refute Turn.answered?([])
      refute Turn.answered?([@user])
      refute Turn.answered?([@user, tool_use])
      refute Turn.answered?([@user, %Message{role: "assistant", content: paused}])
      refute Turn.answered?([@user, %Message{role: "assistant", content: paused_wire}])
      refute Turn.answered?([@user, tool_use, %Message{role: "tool", content: "ok"}])
      refute Turn.answered?([@user, @answer, @user])
    end
  end
end

defmodule Normandy.Agents.Turn.TerminalSaveInMemoryTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.InMemory
end
```

(The cases sit in their own module: both setups would start a `Turn.Supervisor` with the same
child id.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/terminal_save_test.exs test/behaviours/session_store/ets_test.exs test/behaviours/session_store/mnesia_test.exs`
Expected: FAIL. In `terminal_save_test.exs`, 8 of 9: "an eager restart makes no model call..."
fails with `Unexpectedly received message {:converse, %Normandy.LLM.Request{... messages: [...,
%Message{role: "assistant", content: "done"}] ...}` (the finished turn was asked again; if the
resumed call has not run yet when `:sys.get_state/1` is handled, the `{:idle, _}` match fails
with the server `:running` instead); "lands before the next turn starts" fails on the `ops`
list (no `{:save, :stopped, false, :ok}` before the second `{:append, "user"}`); the log test
fails (`assert log =~`, nothing logged); the refusal test fails at
`assert {:error, %TurnError{} = error}` (the turn ran: `{:ok, _}`); the timer test and the
passivation test fail at their `wait_until` (`Expected truthy, got false`); both `answered?/1`
tests fail with `UndefinedFunctionError`. "whose history ends in a paused turn calls the model"
passes (a guard against an over-wide predicate). The ETS and Mnesia files fail the same two
cases.

- [ ] **Step 3: `Turn.answered?/1`**

In `lib/normandy/agents/turn.ex`, insert before the `@doc` of `unanswered_tool_calls/1`:

```elixir
  @doc """
  Whether `messages` end with a turn's answer: an assistant message that makes no tool
  call and is not a paused turn (`stop_reason` `pause_turn`, sent back for the model to
  continue). A turn's history ends this way only once the answer is appended (the
  `:output_guarded` step); after a tool batch it ends with the results, or the
  iteration-cap notice.

  `Turn.Server` reads it before it resumes a saved `:steering` turn: a server that
  stopped after the answer's append and before its `:stopped` save must not ask the
  model again.
  """
  @spec answered?([Message.t()]) :: boolean()
  def answered?(messages) when is_list(messages) do
    case List.last(messages) do
      %Message{role: "assistant", content: content} ->
        tool_calls(content) == [] and not paused?(content)

      _other ->
        false
    end
  end
```

- [ ] **Step 4: `Turn.Server` state and data**

In `lib/normandy/agents/turn/server.ex`:

1. `defmodule Data`: replace the last two fields

```elixir
              start_opts: nil,
              retry_ms: nil
```

with

```elixir
              start_opts: nil,
              retry_ms: nil,
              unsaved_terminal: nil
```

2. After `@retry_max_ms 30_000` add:

```elixir

  # Backoff between saves of a terminal turn state the store refused (save_terminal/2).
  @terminal_retry_initial_ms 1_000
  @terminal_retry_max_ms 30_000
```

3. Moduledoc: insert before `  ## Session start`:

```elixir
  ## Terminal saves

  A turn ends by saving its terminal turn state (`:stopped` or `:failed`), which also
  takes an eager session out of the store's in-flight index (`list_resumable/1`). The
  reply does not wait on that save: if the store refuses it, the turn's reply stands
  (`{:ok, _}` for a turn that succeeded), the server logs a warning by the reason's tag
  (`Turn.Server session "sid": turn state not saved; retrying (:store_down)`), keeps the
  state and saves it again on a timer (1 s, doubling to 30 s), before the next `run/2`
  and before passivating. Until a save lands, `run/2` replies `{:error,
  %Normandy.TurnError{type: :persist_failed, reason: {:terminal_unsaved, reason}}}`
  without running the turn or appending its input, and the server does not passivate.

  If the server dies before a save lands, the store still lists the session in flight,
  and the next eager start (a restart, `Turn.Session.run/2`, `ResumeReaper`) resumes the
  turn. A resumed `:steering` turn whose answer is already the last stored message
  (`Normandy.Agents.Turn.answered?/1`) is saved as finished with no model call; any
  other turn runs again.

```

- [ ] **Step 5: The terminal save and its retries**

1. In `interpret/2`, replace the `{:finalize, value}` and `{:fail, reason}` branches with:

```elixir
      {:finalize, value} ->
        # Persist the terminal (:stopped) turn state so the resume reaper and an eager
        # start can tell a completed session from a mid-turn one. The turn already
        # succeeded, so a refused save does not fail it: save_terminal/2 keeps the
        # state and retries it.
        {data, retry} = save_terminal(data, data.turn_state)
        stop_run_span(data, :stop, run_stop_metadata(data))
        reply(data, {:ok, value})
        turn_end(data, data.config, {:ok, value})
        data = release_turn_ctx(data)

        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil},
         [idle_timeout(data) | retry]}

      {:fail, reason} ->
        # Persist the terminal (:failed) turn state the same way.
        {data, retry} = save_terminal(data, data.turn_state)
        exception = TurnError.from_reason(reason)
        stop_run_span(data, :exception, Span.exception_metadata(:error, exception, []))
        reply(data, {:error, exception})
        turn_end(data, data.config, ServerGlue.fail_outcome(reason))
        data = release_turn_ctx(data)

        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil},
         [idle_timeout(data) | retry]}
```

2. Insert before the comment `# A failed turn's error is persisted as the exception the turn
failed with, redacted` (above `persist_turn_state/2`):

```elixir
  # Saves a terminal (:stopped, :failed) turn state. A store that refuses it leaves the
  # turn's last in-flight save in place (the session stays in list_resumable/1), so the
  # state is kept in unsaved_terminal and saved again: before the next turn request
  # (which is refused while the save fails), before passivation (which waits) and on the
  # :retry_terminal_save timer. Returns the data and the timer action to add, if any.
  defp save_terminal(data, turn_state) do
    case persist_turn_state(data, turn_state) do
      :ok ->
        {data, []}

      {:error, reason} ->
        log_unsaved_terminal(data, reason)

        {%{data | unsaved_terminal: turn_state},
         [
           {{:timeout, :retry_terminal_save}, @terminal_retry_initial_ms,
            @terminal_retry_initial_ms}
         ]}
    end
  end

  defp retry_terminal_save(%Data{unsaved_terminal: turn_state} = data) do
    case persist_turn_state(data, turn_state) do
      :ok ->
        {:ok, %{data | unsaved_terminal: nil}}

      {:error, reason} ->
        log_unsaved_terminal(data, reason)
        {:error, data, reason}
    end
  end

  # reason is already reduced to its tags (persist_turn_state/2); no telemetry event
  # (decision 27 A2). The text names the session and the tag too: Logger's default
  # formatter drops a tuple metadata value.
  defp log_unsaved_terminal(data, reason) do
    metadata = [session_id: data.session_id, reason: reason]

    Logger.log(
      :warning,
      "Turn.Server session #{inspect(data.session_id)}: turn state not saved; retrying " <>
        "(#{describe_reason(reason)})",
      metadata
    )
  end

  # The reply to a turn request while the last turn's terminal state is unsaved: a
  # :persist_failed TurnError, reported like a refused admission (a run :start and
  # :exception, on_turn_end with no turn id). Nothing is appended.
  defp refuse_unsaved_terminal(from, msg, data, reason) do
    data = %{data | turn_ctx_token: OtelCtx.attach(turn_caller_ctx(msg))}
    exception = %TurnError{type: :persist_failed, reason: {:terminal_unsaved, reason}}
    emit_failed_run(data, data.config, nil, exception)
    :gen_statem.reply(from, {:error, exception})
    turn_end(data, data.config, {:error, exception}, turn_id: nil)
    {:keep_state, release_turn_ctx(data)}
  end

  defp turn_caller_ctx({:turn, _user_input, caller_ctx}), do: caller_ctx
  defp turn_caller_ctx({:turn, _user_input}), do: nil
```

3. Insert this clause **before** `def handle_event({:call, from}, {:turn, user_input}, :idle, data)`
(and after the `{:timeout, :retry}` `:unavailable` clause), so it is matched first:

```elixir
  # :idle with a terminal turn state the store refused (save_terminal/2): it is saved
  # before the request runs, so no turn starts while the store still lists the last one
  # in flight. Saved, the request is handled again as a plain :idle request; still
  # refused, it gets a :persist_failed TurnError and nothing is appended.
  def handle_event({:call, from}, msg, :idle, %Data{unsaved_terminal: %Turn.State{}} = data)
      when is_turn_request(msg) do
    case retry_terminal_save(data) do
      {:ok, data} ->
        {:keep_state, data,
         [{{:timeout, :retry_terminal_save}, :cancel}, {:next_event, {:call, from}, msg}]}

      {:error, data, reason} ->
        refuse_unsaved_terminal(from, msg, data, reason)
    end
  end

```

4. Replace the comment and first line of the passivation clause

```elixir
  # Idle long enough → passivate. Final turn state is already persisted; on_passivate
```

with the two new clauses, then the corrected comment start:

```elixir
  # The backoff retry of a terminal save the store refused (save_terminal/2). The timer's
  # content is its own delay, doubled after each refusal up to @terminal_retry_max_ms.
  # A save that lands on a turn request or at passivation cancels it.
  def handle_event(
        {:timeout, :retry_terminal_save},
        delay_ms,
        :idle,
        %Data{unsaved_terminal: %Turn.State{}} = data
      ) do
    case retry_terminal_save(data) do
      {:ok, data} ->
        {:keep_state, data}

      {:error, data, _reason} ->
        next_ms = min(delay_ms * 2, @terminal_retry_max_ms)
        {:keep_state, data, [{{:timeout, :retry_terminal_save}, next_ms, next_ms}]}
    end
  end

  # Passivation waits for an unsaved terminal turn state: a stopped server would leave
  # the session in the store's in-flight index, and the next eager start would resume a
  # turn that already ended. Saved, the passivation runs as usual (the clause below);
  # still refused, the server stays up and tries again after another idle timeout.
  def handle_event(
        :state_timeout,
        :passivate,
        :idle,
        %Data{unsaved_terminal: %Turn.State{}} = data
      ) do
    case retry_terminal_save(data) do
      {:ok, data} ->
        {:keep_state, data,
         [{{:timeout, :retry_terminal_save}, :cancel}, {:next_event, :state_timeout, :passivate}]}

      {:error, data, _reason} ->
        {:keep_state, data, idle_timeout(data)}
    end
  end

  # Idle long enough → passivate. Final turn state is persisted (the clause above waits
  # for one the store refused); on_passivate
```

(The rest of that comment and the existing `handle_event(:state_timeout, :passivate, state,
data) when state in [:idle, :unavailable]` clause are unchanged.)

- [ ] **Step 6: The resume guard**

1. Replace the `:resume` clause (its comment and body) with:

```elixir
  # Eager auto-resume: drive the persisted in-flight turn to completion. No caller
  # is waiting (pending_reply is nil → reply/2 is a no-op), so the turn finalizes
  # silently while persisting at each boundary. A turn whose answer is already stored
  # is only saved as finished (finish_answered/1).
  def handle_event(:internal, :resume, :idle, data) do
    if answered?(data) do
      finish_answered(data)
    else
      resume_turn(start_resumed_run_span(data))
    end
  end
```

2. After `defp close_resumed_batch(data), do: {:ok, data}` add:

```elixir

  defp resume_turn(data) do
    case close_resumed_batch(data) do
      {:ok, data} ->
        {state, effects} = Turn.resume(data.turn_state)
        interpret(effects, %{data | turn_state: state})

      {:error, data, reason} ->
        fail(data, reason)
    end
  end

  # A saved :steering turn whose answer is the last message in the stored history
  # (Turn.answered?/1) ended: the server stopped after the answer's append and before
  # its :stopped save landed (a crash, or a store that refused that save). Only an
  # answer ends a turn's history, so the same turn run again would ask the model a
  # second time and append a second answer.
  defp answered?(%Data{turn_state: %Turn.State{status: :steering}, config: %{memory: memory}}),
    do: memory |> AgentMemory.messages() |> Turn.answered?()

  defp answered?(_data), do: false

  # Saves the answered turn as :stopped, with no model call, run span or hook: no turn
  # runs in this process. A refused save is kept and retried like any terminal save.
  defp finish_answered(data) do
    Logger.info(
      "Turn.Server session #{inspect(data.session_id)}: the resumed turn's answer is " <>
        "already stored; saved the turn as finished without a model call"
    )

    turn_state = %{data.turn_state | status: :stopped}
    {data, retry} = save_terminal(data, turn_state)
    {:keep_state, %{data | turn_state: turn_state}, [idle_timeout(data) | retry]}
  end
```

3. In `test/agents/turn/server_store_failures_test.exs` replace the comment line
`    # on; a terminal save is best-effort).` with
`    # on; a refused terminal save is retried instead, terminal_save_test.exs).`

Check: `grep -n "_ = persist_turn_state" lib/normandy/agents/turn/server.ex` → 0 hits;
`grep -n "persist_turn_state(" lib/normandy/agents/turn/server.ex` → 4 hits (the `{:persist, _}`
effect, `save_terminal/2`, `retry_terminal_save/1`, the definition).

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/terminal_save_test.exs test/agents/turn/eager_resume_test.exs test/agents/turn/resume_reaper_test.exs test/agents/turn/server_store_failures_test.exs test/agents/turn/server_test.exs test/behaviours/session_store/ets_test.exs test/behaviours/session_store/mnesia_test.exs`
Expected: PASS (`terminal_save_test.exs`: 9 tests, 0 failures). `eager_resume_test.exs` (a
`:steering` state with empty history still resumes) and `resume_reaper_test.exs` pass unchanged;
`server_store_failures_test.exs` "a terminal-state save that exits after a successful turn still
replies {:ok, _}" passes unchanged (the exit is logged and retried). Run the file three times;
it does not flake (scratch run: 3 of 3 green).

- [ ] **Step 8: Gate and tagged suites**

Run: `mix format && mix precommit 2>&1 | tee /tmp/7.0b-precommit.log` → ` 0 failures`, exit 0;
`mix docs --warnings-as-errors` → exit 0. Then the tagged suites (this task changes
`Turn.Server` persistence and runs on every backend):

- `mix test.redis` → ` 0 failures` (runs `RedisTest`'s two new cases).
- `docker start normandy-test-pg`, then
  `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` → ` 0 failures` (runs
  `PostgresContractTest`'s two new cases; the controller stops the container afterwards).
- `mix test --only distributed --include postgres` → ` 0 failures` (eager resume and the reaper
  across nodes).

- [ ] **Step 9: MIGRATING-2.0.md**

1. In `## 39. Turn.Server start, store failures and compaction persistence`, first bullet,
   replace

```markdown
  turn. The terminal-state save after a successful turn is best-effort, so its exit leaves the
  reply `{:ok, _}`. `exit_reason` carries no stacktrace, and a call's arguments are replaced by
```

with

```markdown
  turn. The terminal-state save after a successful turn does not fail it, so its exit leaves
  the reply `{:ok, _}`; the save is retried (§43). `exit_reason` carries no stacktrace, and a call's arguments are replaced by
```

2. Insert before `## Known limits of 2.0`:

```markdown
## 43. Turn.Server terminal saves and blank answers

- A terminal turn-state save (`:stopped` or `:failed`) that the session store refuses is no
  longer dropped silently. The turn's reply is unchanged (`{:ok, _}` for a turn that
  succeeded); the server logs a warning by the reason's tag (`Turn.Server session "sid":
  turn state not saved; retrying (<tag>)`, metadata `session_id` and `reason`), keeps the
  state and saves it again on a timer (1 s, doubling to 30 s), before the next `run/2` and
  before passivating. No telemetry event is added.
- While that save fails, `Turn.Server.run/2` (and `Turn.Session.run/2`) returns
  `{:error, %Normandy.TurnError{type: :persist_failed, reason: {:terminal_unsaved,
  reason}}}` without running the turn or storing its input, and the server does not
  passivate (it stays registered, so `ResumeReaper` and `Turn.Session` reach it). Retry the
  call once the store is back. It used to run the turn while the store still listed the
  previous one in flight.
- An eager start that resumes a saved `:steering` turn whose answer is already the last
  stored message (the server stopped between storing the answer and saving the turn as
  `:stopped`) saves the turn as finished and calls no model. It used to call the model
  again and store a second answer. `Normandy.Agents.Turn.answered?/1` is the check.

```

3. In `## Known limits of 2.0`, replace the H10 bullet

```markdown
- **A failed final turn-state save can leave a session in the in-flight index** (H10). If
  the store fails while saving a turn's terminal state, the session stays marked in flight,
  and `ResumeReaper` may later resume a turn that had already finished.
```

with

```markdown
- **A failed turn can run again after a store outage** (H10). `Turn.Server` retries a
  terminal turn-state save the store refused (§43), but if the server process dies first (a
  node crash, a supervisor shutdown) the session stays in the in-flight index and the next
  eager start resumes the turn: a turn whose answer was stored is only marked finished, a
  turn that failed calls the model again, with no caller waiting.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/agents/turn/server.ex
git add lib/normandy/agents/turn.ex
git add test/support/terminal_save_store.ex
git add test/support/terminal_save_cases.ex
git add test/agents/turn/terminal_save_test.exs
git add test/agents/turn/server_store_failures_test.exs
git add test/behaviours/session_store/ets_test.exs
git add test/behaviours/session_store/mnesia_test.exs
git add test/behaviours/session_store/redis_test.exs
git add test/behaviours/session_store/postgres_contract_test.exs
git add MIGRATING-2.0.md
git commit -m "fix(turn-server): retry a refused terminal save; resume no answered turn

A terminal turn-state save the store refused was dropped silently, so the
session stayed in the in-flight index and any eager start (a restart,
Turn.Session after passivation, ResumeReaper) re-ran the finished turn's
model call and stored a second answer (H10, decision 25 A10).

Turn.Server logs the refusal by tag, keeps the state in unsaved_terminal
and saves it again on a backoff timer (1 s to 30 s), before the next turn
(refused :persist_failed {:terminal_unsaved, reason} meanwhile) and before
passivating (deferred until it lands). An eager resume of a :steering
turn whose answer is the last stored message (Turn.answered?/1) saves it
as finished without a model call. No event (decision 27 A1, A2)."
```

---

### Task 7.0c: Blank `nil` answers, summarizer frame, Workflow example, test filters (rows 6-10, 12)

Five small fixes: a `nil` `chat_message` is a blank answer on every path (decision 27 A3, row
10); the summarizer labels a content block with no binary `type` instead of raising
`CaseClauseError` (row 8) and escapes a closing `</conversation_summary>` inside the summary
(row 9); the Workflow moduledoc example compiles and runs, and the DSL stops making the compiler
warn about `when_result` values a workflow never returns (row 6, Header conflicts 6); `mix test`
stops warning about `test/fixtures/` (row 7); and the Known-limits list loses its stray blank
line (row 12).

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`ensure_answer!/1`)
- Modify: `lib/normandy/context/summarizer.ex` (`block_lines/3`, `summary_message/1`)
- Modify: `lib/normandy/dsl/workflow.ex` (moduledoc example; new `__after_condition__/3`; generated `after_step/2`)
- Modify: `mix.exs` (`test_ignore_filters`)
- Modify: `MIGRATING-2.0.md` (`## 43.` one bullet; Known limits blank line)
- Modify (test doubles): `test/support/stub_client.ex`, `test/support/model_mockup.ex`
- Test: modify `test/agents/blank_answer_test.exs`, `test/context/summarizer_test.exs`; create
  `test/dsl/workflow_moduledoc_test.exs`; update the assertions listed in Step 1 (8 files)

**Interfaces:**
- Consumes: `ensure_answer!/1` callers `convert_final_text/3` and `validate_turn_output/2` (every
  BaseAgent-handler path: `run/3`, `run!/3`, `Turn.Driver`, `Turn.Server`; a stream's answer is
  built from text deltas and is never `nil`); `Reactive.all/3` result shape.
- Produces: `Normandy.DSL.Workflow.__after_condition__(step_name, state, value)` (`@doc false`,
  called by every workflow's generated `after_step/2`); `Normandy.Test.StubClient.answer/1` (the
  default reply).

- [ ] **Step 1: Write the failing tests**

1. `test/agents/blank_answer_test.exs`: replace

```elixir
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
```

with

```elixir
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
```

and `  alias Normandy.Test.ScriptedTextClient` with

```elixir
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.ScriptedTextClient
  alias Normandy.Test.StubClient
```

then add before the module's final `end`:

```elixir
  # Decision 27 A3: a client that returns the answer struct itself can leave
  # chat_message nil, and a tool loop's final response can carry no text at all. Neither
  # is an answer. (A stream builds its answer from text deltas, so it never holds nil.)
  describe "a nil chat_message" do
    defp nil_answer_agents do
      chat =
        BaseAgent.init(%{
          client: %StubClient{reply: fn _ -> %BaseAgentOutputSchema{chat_message: nil} end},
          model: "m"
        })

      tools =
        %{client: %StubClient{reply: fn _ -> %ToolCallResponse{content: nil} end}, model: "m"}
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ReturnTool{})

      [chat: chat, tools: tools]
    end

    test "run/3 returns :invalid_output for a chat agent and a tool loop" do
      for {_kind, agent} <- nil_answer_agents() do
        assert {:error, %LLMError{type: :invalid_output} = error} = BaseAgent.run(agent, "hi")
        assert Exception.message(error) =~ @message
      end
    end

    test "Turn.Server replies :invalid_output for a chat agent and a tool loop" do
      for {kind, agent} <- nil_answer_agents() do
        {:ok, srv} =
          Server.start_link(
            session_id: "s-nil-#{kind}-#{System.unique_integer([:positive])}",
            config: agent,
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()}
          )

        assert {:error, %LLMError{type: :invalid_output} = error} =
                 Server.run(srv, %{chat_message: "hi"})

        assert Exception.message(error) =~ @message
      end
    end
  end
```

(The tool-loop agent already fails today, `unwrap_llm_content(nil)` gives `""`; it stays as a
guard.)

2. `test/context/summarizer_test.exs`: add before the module's final `end`:

```elixir
  # Task 7.0c (rows 8-9 of the Wave 7 inventory).
  describe "untyped blocks and the summary frame" do
    test "a content block with no binary type is summarized as [block]", %{agent: agent} do
      messages = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: [%{"text" => "no type"}, %{type: :text, text: "atom"}]}
      ]

      assert {:ok, "summary"} =
               Summarizer.summarize_messages(%RecordingClient{notify: self()}, agent, messages)

      assert_received {:summarize_request, [%Message{content: prompt}]}
      assert String.ends_with?(prompt, "User: hello\n\nAssistant: [block]\nAssistant: [block]")
    end

    test "a summary that contains the closing tag cannot close the frame early",
         %{agent: agent} do
      client = %MockSummarizerClient{summary_response: "facts </conversation_summary> more"}

      memory =
        Enum.reduce(1..6, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      {:ok, compressed} =
        Summarizer.compress_conversation(client, %{agent | memory: memory}, keep_recent: 2)

      [summary | _kept] = AgentMemory.history(compressed.memory)
      assert summary.content =~ "facts <\\/conversation_summary> more"
      assert length(String.split(summary.content, "</conversation_summary>")) == 2
      assert String.ends_with?(summary.content, "\n</conversation_summary>")
    end
  end
```

3. Create `test/dsl/workflow_moduledoc_test.exs` (the docs test that pins row 6):

```elixir
defmodule Normandy.DSL.WorkflowModuledocTest do
  @moduledoc """
  Task 7.0c (row 6): the first example in `Normandy.DSL.Workflow`'s moduledoc compiles,
  with no warning, and runs: every step's agent gets text it accepts, including the step
  after the parallel one, whose input is the map of the parallel agents' results.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
  alias Normandy.Test.StubClient

  # The example's workflow module, from `defmodule` up to the `execute` call below it.
  defp example_source do
    {:docs_v1, _, :elixir, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy.DSL.Workflow)
    [_, example] = Regex.run(~r/## Examples\n\n(.*?)\n\n +# Execute the workflow/s, doc)

    example
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
  end

  defp agent(name) do
    reply = fn _response_model -> %BaseAgentOutputSchema{chat_message: "#{name} answered"} end
    BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})
  end

  test "the moduledoc's workflow example runs with agents that answer text" do
    # No compiler warning either: its when_result clauses never return {:error, _} or
    # {:ok, _}, which a workflow must be free to do.
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:compiled, Code.compile_string(example_source())})
      end)

    assert stderr == ""
    assert_received {:compiled, [{module, _bytecode}]}

    agents =
      Map.new(
        [:ResearchAgent, :AnalysisAgent, :FactCheckAgent, :QualityAgent, :ReviewAgent],
        &{Module.concat([&1]), agent(&1)}
      )

    assert {:ok, results} = module.execute(agents: agents, initial_input: "quantum computing")
    assert results.final_review == :needs_revision

    assert %{fact_check: {:ok, %BaseAgentOutputSchema{}}, quality_check: {:ok, _}} =
             results.validate
  end
end
```

4. The test doubles fill a `nil` answer. In `test/support/stub_client.ex` replace the
moduledoc lines

```elixir
  `{:error, %Normandy.LLMError{}}`; or the function raises. The default returns the
  response model unchanged. Any other tuple (such as a 1.x `{response, usage}` left
  unmigrated) raises `ArgumentError`; any other term is returned as is, for
  `Normandy.LLM.Call` to reject.
```

with

```elixir
  `{:error, %Normandy.LLMError{}}`; or the function raises. The default (`answer/1`)
  returns the response model, its `:chat_message` set to `"stub answer"` when it is
  `nil` (a `nil` answer is an error, decision 27 A3). Any other tuple (such as a 1.x
  `{response, usage}` left unmigrated) raises `ArgumentError`; any other term is
  returned as is, for `Normandy.LLM.Call` to reject.
```

and `  defstruct reply: &Function.identity/1, notify: nil, options: %{}` with

```elixir
  defstruct reply: &__MODULE__.answer/1, notify: nil, options: %{}

  @doc "The default reply: the response model, a `nil` `:chat_message` filled in."
  @spec answer(term()) :: term()
  def answer(%{chat_message: nil} = response_model),
    do: %{response_model | chat_message: "stub answer"}

  def answer(response_model), do: response_model
```

In `test/support/model_mockup.ex` replace

```elixir
  defimpl Normandy.Agents.Model, for: __MODULE__ do
    def converse(_config, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: request.response_model}}
```

with

```elixir
  defimpl Normandy.Agents.Model, for: __MODULE__ do
    alias Normandy.Test.StubClient

    # The response model, a nil :chat_message filled in (a nil answer is an error,
    # decision 27 A3).
    def converse(_config, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: StubClient.answer(request.response_model)}}
```

5. The assertions that read the old `nil` answer (found by running the suite with Steps 3-4
applied: 25 failing tests in these 8 files, 0 elsewhere). Change each:

| File | Before | After |
|---|---|---|
| `test/agents/base_agent_test.exs` "get response" | `assert response == %Normandy.Agents.BaseAgentOutputSchema{}` | `assert response == %Normandy.Agents.BaseAgentOutputSchema{chat_message: "stub answer"}` |
| `test/agents/base_agent_test.exs` "run" | `mock_output = %BaseAgentOutputSchema{}` | `mock_output = %BaseAgentOutputSchema{chat_message: "stub answer"}` |
| `test/agents/base_agent_run_result_test.exs` "run!/2 returns {config, output}..." | `BaseAgent.run!(agent(& &1), %{chat_message: "x"})` | `BaseAgent.run!(agent(&StubClient.answer/1), %{chat_message: "x"})` |
| `test/agents/base_agent_guardrails_test.exs` "allows passing inputs through" and "empty guard list is a no-op" | `# ModelMockup returns the output schema unchanged.` / `assert response == %Normandy.Agents.BaseAgentOutputSchema{}` | `# ModelMockup answers "stub answer".` / `assert response == %Normandy.Agents.BaseAgentOutputSchema{chat_message: "stub answer"}` |
| same file, "an output violation raises ViolationError by default" | comment `# ModelMockup returns an empty BaseAgentOutputSchema (chat_message: nil).`; guard `[output: [{RequiredFields, fields: [:chat_message]}]]`; `assert [%{guard: RequiredFields} \| _] = error.violations` | comment `# ModelMockup answers "stub answer" (11 graphemes): MaxLength 5 fires.`; guard `[output: [{MaxLength, limit: 5, field: :chat_message}]]`; `assert [%{guard: MaxLength} \| _] = error.violations` |
| same file, "with on_violation :warn it logs a warning and does not halt" | the two comment lines `# ModelMockup returns an empty ...` and `# RequiredFields([:chat_message]) will fire.`; `guardrails: [output: [{RequiredFields, fields: [:chat_message]}], on_violation: :warn]`; final `assert response == %Normandy.Agents.BaseAgentOutputSchema{}` | one comment `# ModelMockup answers "stub answer" (11 graphemes): MaxLength 5 fires.`; `guardrails: [output: [{MaxLength, limit: 5, field: :chat_message}], on_violation: :warn]`; `assert response == %Normandy.Agents.BaseAgentOutputSchema{chat_message: "stub answer"}` |
| same file, "passes silently when output satisfies the guard" | `# chat_message is nil → MaxLength is a no-op on nil fields, no warning.` | `# "stub answer" is within the limit: no warning.` |
| same file, alias block | `    MaxLength,` / `    RequiredFields,` / `    SemanticScope` | `    MaxLength,` / `    SemanticScope` (now unused) |
| `test/dsl/agent_guardrails_test.exs` `GuardedAgent` | `guardrails(:output, [` / `{RequiredFields, fields: [:chat_message]}` / `])` | `# ModelMockup answers "stub answer" (11 graphemes), which this blocks.` then `guardrails(:output, [` / `{MaxLength, limit: 5, field: :chat_message}` / `])` |
| same file, the two config assertions (`agent.guardrails[:output] == ...` and `config.guardrails[:output] == ...`) | `[{RequiredFields, fields: [:chat_message]}]` | `[{MaxLength, limit: 5, field: :chat_message}]` (WarnOnlyAgent keeps `RequiredFields`, so the alias stays) |
| `test/coordination/agent_process_test.exs` "executes agent synchronously" | `assert {:ok, result} = AgentProcess.run(pid, "Test input")` / `assert is_map(result)` | `# A chat answer is returned as its text.` / `assert {:ok, "stub answer"} = AgentProcess.run(pid, "Test input")` |
| same file, "handles different input formats" | `assert {:ok, result1} = AgentProcess.run(pid, "text")` / `assert is_map(result1)` and `assert {:ok, result2} = AgentProcess.run(pid, %{chat_message: "text"})` / `assert is_map(result2)` | `assert {:ok, "stub answer"} = AgentProcess.run(pid, "text")` and `assert {:ok, "stub answer"} = AgentProcess.run(pid, %{chat_message: "text"})` |
| same file, "executes agent asynchronously" | `assert_receive {:agent_result, "async_agent", {:ok, result}}, 1000` / `assert is_map(result)` | `assert_receive {:agent_result, "async_agent", {:ok, "stub answer"}}, 1000` |
| `test/coordination/agent_supervisor_test.exs` "supervised agents can execute work" | `# Agent should work normally` / `assert {:ok, result} = AgentProcess.run(pid, "Test input")` / `assert is_map(result)` | `# Agent should work normally; a chat answer is returned as its text.` / `assert {:ok, "stub answer"} = AgentProcess.run(pid, "Test input")` |
| `test/coordination/reactive_test.exs` "returns first successful result from agent processes" | `assert {:ok, result} = Reactive.race(pids, "test")` / `assert is_map(result)` | `# An agent process returns a chat answer as its text.` / `assert {:ok, "stub answer"} = Reactive.race(pids, "test")` |
| `test/coordination/hierarchical_coordinator_test.exs` `CaptureClient.converse/3` | `{:ok, %Normandy.LLM.Response{content: struct(request.response_model, client.reply)}}` | `# A reply without :chat_message answers "<name> done" (a nil answer is an error).` / `reply = Map.put_new(client.reply, :chat_message, "#{client.name} done")` / `{:ok, %Normandy.LLM.Response{content: struct(request.response_model, reply)}}` |
| same file, "a manager whose aggregation call exits returns a :task_down TurnError" | `do: %{response_model \| delegation_plan: ["t1"]},` | `do: %{response_model \| chat_message: "plan", delegation_plan: ["t1"]},` |

(`AgentProcess` returns an answer's `chat_message` when it is set,
`lib/normandy/coordination/agent_process.ex:948-951`; with `nil` it returned the struct.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/blank_answer_test.exs test/context/summarizer_test.exs test/dsl/workflow_moduledoc_test.exs`
Expected: FAIL, 5 tests: both "a nil chat_message" tests (`right: {:ok, ...}` from the chat
agent); "a content block with no binary type..." with `** (CaseClauseError) no case clause
matching`; "a summary that contains the closing tag..." on `=~ "facts <\\/conversation_summary>
more"` (the content holds the raw tag); the moduledoc test at `assert stderr == ""` (Elixir
1.19: `warning: the following clause will never match: {:error, reason} ... which has type:
dynamic(:approve or :needs_revision or {:ok, term()})` in `ResearchWorkflow.after_step/2`; on a
compiler that does not warn it fails later, with `** (Protocol.UndefinedError) protocol
String.Chars not implemented for Normandy.Agents.BaseAgentOutputSchema`, the `:analyze_sources`
transform interpolating the struct). The Step 1 item 5 edits pass against the
unchanged library (the doubles answer `"stub answer"` either way).

Also run: `mix test --only w7_none 2>&1 | grep -c "test_load_filters"` → `1` (the warning naming
`test/fixtures/templates/generate_v1_0_0.exs`).

- [ ] **Step 3: A `nil` answer is blank (row 10)**

In `lib/normandy/agents/base_agent.ex`, replace the comment above `ensure_answer!/1` and its
first line:

```elixir
  # An empty or whitespace-only answer (the model ended its turn with no text, AX-32) is
  # the :invalid_output LLMError, never a blank success (decision 22). The one check, for
  # the converted answer (convert_final_text/3) and the validated one
  # (validate_turn_output/2).
  defp ensure_answer!(answer) do
    if is_binary(answer) and String.trim(answer) == "" do
```

with

```elixir
  # An empty or whitespace-only answer (the model ended its turn with no text, AX-32), or
  # none (a client that returns the output struct with chat_message: nil, decision 27 A3),
  # is the :invalid_output LLMError, never a blank success (decision 22). The one check,
  # for the converted answer (convert_final_text/3) and the validated one
  # (validate_turn_output/2).
  defp ensure_answer!(answer) do
    if is_nil(answer) or (is_binary(answer) and String.trim(answer) == "") do
```

The error's detail is unchanged ("expected a final answer, got an empty one: the model ended
its turn with no text").

- [ ] **Step 4: Summarizer (rows 8-9)**

In `lib/normandy/context/summarizer.ex`:

1. In `block_lines/3` (the `is_map(block)` clause), after the `type when is_binary(type) ->`
branch add:

```elixir

      # No type, or one that is not a string (an atom-keyed type: :text): nothing to
      # read it by.
      _other ->
        [label(role, "[block]")]
```

2. Replace `summary_message/1` (and its one comment line) with:

```elixir
  # Framed so the model does not read the summary as something the user just said (AX-28).
  # A closing tag inside the summary (the model's text) is escaped, so it cannot end the
  # frame early and leave the rest outside it.
  defp summary_message(summary) do
    escaped = String.replace(summary, "</conversation_summary>", "<\\/conversation_summary>")

    "The earlier part of this conversation was summarized automatically to save space. " <>
      "The summary is context, not a new message.\n\n" <>
      "<conversation_summary>\n" <> escaped <> "\n</conversation_summary>"
  end
```

- [ ] **Step 5: Workflow example and `when_result` (row 6)**

In `lib/normandy/dsl/workflow.ex`:

1. Moduledoc, first example: replace

```elixir
            transform fn sources -> "Analyze these: \#{sources}" end
```

with

```elixir
            transform fn %{chat_message: sources} -> "Analyze these: " <> sources end
```

after `            input from: :analyze_sources` (in `parallel :validate`) add

```elixir
            transform fn %{chat_message: analysis} -> analysis end
```

and replace

```elixir
          # Conditional execution: the clause's value becomes the step result
          step :final_review do
            agent ReviewAgent
            input from: :validate
            when_result do
```

with

```elixir
          # Conditional execution: the clause's value becomes the step result. A
          # parallel step's result maps each agent's name to its {:ok, answer} or
          # {:error, exception}.
          step :final_review do
            agent ReviewAgent
            input from: :validate
            transform fn %{fact_check: {:ok, facts}, quality_check: {:ok, quality}} ->
              "Facts: " <> facts.chat_message <> "\\nQuality: " <> quality.chat_message
            end
            when_result do
```

2. Insert before `defmacro __using__(_opts) do`:

```elixir
  @doc false
  # A step's when_result value, applied to the workflow's state (see "Conditional
  # Execution"). Here and not in the generated module: there the compiler sees which
  # values that workflow's clauses return, and warns in the user's module about the
  # branches they never reach (a workflow whose clauses never return {:error, _}).
  @spec __after_condition__(atom(), map(), term()) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {atom(), term()}}}
  def __after_condition__(step_name, _state, {:error, reason}),
    do: {:halt, {:error, {step_name, reason}}}

  def __after_condition__(step_name, state, {:ok, value}),
    do: {:cont, {:ok, put_step_result(state, step_name, value)}}

  def __after_condition__(step_name, state, value),
    do: {:cont, {:ok, put_step_result(state, step_name, value)}}

  defp put_step_result(state, name, value),
    do: %{state | results: Map.put(state.results, name, value), current_input: value}

```

3. In `__before_compile__/1`, the `else` branch of `after_step =`: replace

```elixir
          defp after_step(step, state) do
            result = Map.fetch!(state.results, step.name)

            case __workflow_condition__(step.name, {:ok, result}) do
              {:error, reason} -> {:halt, {:error, {step.name, reason}}}
              {:ok, value} -> {:cont, {:ok, put_step_result(state, step.name, value)}}
              value -> {:cont, {:ok, put_step_result(state, step.name, value)}}
            end
          end

          defp put_step_result(state, name, value) do
            %{state | results: Map.put(state.results, name, value), current_input: value}
          end
```

with

```elixir
          defp after_step(step, state) do
            result = Map.fetch!(state.results, step.name)

            unquote(__MODULE__).__after_condition__(
              step.name,
              state,
              __workflow_condition__(step.name, {:ok, result})
            )
          end
```

(`unquote(__MODULE__)`, not the literal module: `credo --strict` flags a nested module
reference in the quote.)

(The moduledoc is a plain heredoc, so its `\\n` renders as `\n` in the docs; a bare `\n`
would break the example's string across two lines.)

- [ ] **Step 6: `test_ignore_filters` (row 7)**

In `mix.exs` `project/0`, after `test_coverage: [summary: [threshold: 60]],` add:

```elixir
      # test/fixtures holds data and the script that generates it, not tests: without this,
      # `mix test` warns that they match no :test_load_filters.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/blank_answer_test.exs test/context/summarizer_test.exs test/dsl test/agents/base_agent_test.exs test/agents/base_agent_guardrails_test.exs test/agents/base_agent_run_result_test.exs test/coordination`
Expected: PASS (`blank_answer_test.exs` 9 tests; `summarizer_test.exs` 30; `test/dsl` 109 with
the new file). `mix test --only w7_none 2>&1 | grep -c "test_load_filters"` → `0`.

- [ ] **Step 8: Gate**

Run: `mix format && mix precommit 2>&1 | tee /tmp/7.0c-precommit.log` → ` 0 failures`, exit 0
(this run is the one that proves no other test read a `nil` answer); `mix docs
--warnings-as-errors` → exit 0. No tagged suite (no store change; `Turn.Server` runs the same
handler).

- [ ] **Step 9: MIGRATING-2.0.md**

1. In `## 43.` (created by Task 7.0b), add after its last bullet:

```markdown
- A final answer whose `chat_message` is `nil` is now `{:error, %Normandy.LLMError{type:
  :invalid_output}}` on `run/3`, `run!/3` (raises), `Turn.Server` and `Turn.Session`, like an
  empty one (§32). It reaches only an output schema with a `:chat_message` field, from a
  client that returns the output struct itself (a test double that returns the response
  model unchanged, or a structured-output answer that leaves the field out). A stream builds
  its answer from text, so it never holds `nil`. Make test doubles fill `chat_message`.
```

2. In `## Known limits of 2.0`, delete the empty line between the bullet ending
"If you must erase a user's data, check the store\n  afterwards." and the bullet starting
"- **Every compaction stores the whole compacted conversation.**" (row 12). Check:
`awk '/^## Known limits/,/^## New, non-breaking/' MIGRATING-2.0.md | grep -c '^$'` → 3 (after the
heading, after the intro line, before `## New`).

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/agents/base_agent.ex
git add lib/normandy/context/summarizer.ex
git add lib/normandy/dsl/workflow.ex
git add mix.exs
git add MIGRATING-2.0.md
git add test/support/stub_client.ex
git add test/support/model_mockup.ex
git add test/agents/blank_answer_test.exs
git add test/context/summarizer_test.exs
git add test/dsl/workflow_moduledoc_test.exs
git add test/agents/base_agent_test.exs
git add test/agents/base_agent_run_result_test.exs
git add test/agents/base_agent_guardrails_test.exs
git add test/dsl/agent_guardrails_test.exs
git add test/coordination/agent_process_test.exs
git add test/coordination/agent_supervisor_test.exs
git add test/coordination/reactive_test.exs
git add test/coordination/hierarchical_coordinator_test.exs
git commit -m "fix: a nil answer is blank; summarizer frame; workflow example

- A final answer whose chat_message is nil is the :invalid_output
  LLMError, like an empty one (decision 27 A3). StubClient and
  ModelMockup fill a nil answer with \"stub answer\".
- Summarizer: a block with no binary type is labelled [block] instead
  of raising CaseClauseError; a </conversation_summary> inside the
  summary is escaped so it cannot close the frame.
- The Workflow moduledoc example compiles and runs; a when_result value
  is applied by Workflow.__after_condition__/3, so a workflow whose
  clauses never return {:error, _} no longer makes the compiler warn.
- mix.exs ignores test/fixtures in the test load filters.
- MIGRATING Known limits: one list."
```

---

### Task 7.0d: Compile on Elixir 1.15/1.16; Horde `~> 0.10` (decision 27 B1, B2)

`lib/normandy/schema/validator.ex:206` matches `%Duration{}` unguarded; `Duration` ships with
Elixir 1.17, and an unknown struct in a pattern is a `CompileError`, so the library does not
compile on 1.15/1.16 (CI's legs `test` 1.15/26, 1.16/26 and the post-merge integration job).
`type.ex:799,863` already guard the same match. Two tests build a `Duration` unguarded. The
optional `horde` dependency is tightened to the version `SessionRegistry.Horde.Via` was checked
against (decision 26a); `mix.lock` already holds 0.10.0 and does not change.

Probe (scratch, `Code.with_diagnostics/1` around `Code.compile_string/1`, run on
`hexpm/elixir:1.15.8-erlang-26.2.5.6-alpine-3.20.3`, `elixir:1.16` (1.16.3) and the local
1.19.5): the guarded shapes used below (a `defp` with `%Duration{}` inside
`if Code.ensure_loaded?(Duration)`, and module attributes built with
`if Code.ensure_loaded?(Duration), do: ... Duration.new!(hour: 1) ..., else: ...`) compile with
no diagnostic on all three; the unguarded `defp f(%Duration{})` raises `CompileError` on 1.15
and 1.16. The full suite was not run on 1.15/1.16 (the containers cannot install Hex: TLS
`unsupported_certificate` to builds.hex.pm); CI's matrix in Task 7.7 is the end-to-end check.

**Files:**
- Modify: `lib/normandy/schema/validator.ex` (`formatted_value?/3`)
- Modify: `mix.exs` (`{:horde, ...}`)
- Modify: `MIGRATING-2.0.md` (create `## 44.`)
- Test: modify `test/type_base_types_test.exs`, `test/schema/json_schema_types_test.exs`

**Interfaces:**
- Consumes: `Code.ensure_loaded?/1` (the `type.ex:799` precedent).
- Produces: nothing new. `mix.lock` unchanged.

- [ ] **Step 1: Guard the tests (the pinning change)**

This change has no behaviour on 1.17+; the tests that would fail to compile on 1.15/1.16 are
made version-safe, and the CI matrix (Task 7.7) is the failing-then-passing check.

In `test/type_base_types_test.exs`, remove the line `    duration: Duration.new!(hour: 1),`
from `@samples` and add after the list's closing `]`:

```elixir

  # Duration ships with Elixir 1.17 (the library supports 1.15).
  @samples if Code.ensure_loaded?(Duration),
             do: @samples ++ [duration: Duration.new!(hour: 1)],
             else: @samples
```

In `test/schema/json_schema_types_test.exs`, after `defp prop(name), ...` add:

```elixir

  # Duration ships with Elixir 1.17 (the library supports 1.15).
  @duration if Code.ensure_loaded?(Duration), do: %{for: Duration.new!(hour: 1)}, else: %{}
```

and replace the `Validator.validate/2` call in "the Validator accepts Elixir values for the
string-with-format types":

```elixir
    assert {:ok, _} =
             Validator.validate(Kinds, %{
               on: ~D[2026-10-01],
               at: ~T[10:00:00],
               for: Duration.new!(hour: 1),
               blob: "abc",
               meta: %{"a" => 1},
               thing: %URI{}
             })
```

with

```elixir
    assert {:ok, _} =
             Validator.validate(
               Kinds,
               Map.merge(
                 %{on: ~D[2026-10-01], at: ~T[10:00:00], blob: "abc", meta: %{"a" => 1}, thing: %URI{}},
                 @duration
               )
             )
```

(`mix format` rewraps the inner map.)

- [ ] **Step 2: Run the tests**

Run: `mix format && mix test test/type_base_types_test.exs test/schema/json_schema_types_test.exs`
Expected: PASS, `23 tests, 0 failures` on 1.19 (the `duration` sample still runs there).

- [ ] **Step 3: Guard the validator**

In `lib/normandy/schema/validator.ex`, replace

```elixir
  defp formatted_value?(%Date{}, :string, "date"), do: true
  defp formatted_value?(%Time{}, :string, "time"), do: true
  defp formatted_value?(%Duration{}, :string, "duration"), do: true
  defp formatted_value?(_, _, _), do: false
```

with

```elixir
  defp formatted_value?(%Date{}, :string, "date"), do: true
  defp formatted_value?(%Time{}, :string, "time"), do: true

  # Duration ships with Elixir 1.17; on 1.15 and 1.16 the struct pattern would not compile.
  if Code.ensure_loaded?(Duration) do
    defp formatted_value?(%Duration{}, :string, "duration"), do: true
  end

  defp formatted_value?(_, _, _), do: false
```

Check: `grep -rnw "Duration" lib test | grep -v "ensure_loaded?(Duration)\|Duration ships"` →
`type.ex:800`, `type.ex:864`, `validator.ex:39` (moduledoc text), `validator.ex:209`,
`type_base_types_test.exs:22`: every code hit inside an `ensure_loaded?(Duration)` branch.

- [ ] **Step 4: Horde `~> 0.10`**

In `mix.exs` `deps/0`, replace `      {:horde, "~> 0.9", optional: true},` with:

```elixir
      # SessionRegistry.Horde.Via relies on Horde 0.10's registration order (decision 26a).
      {:horde, "~> 0.10", optional: true},
```

Run: `mix deps.get` then `git diff --exit-code mix.lock` → exit 0 (lock unchanged, horde 0.10.0);
`mix deps.unlock --check-unused` → exit 0.

- [ ] **Step 5: Gate**

Run: `mix format && mix precommit 2>&1 | tee /tmp/7.0d-precommit.log` → ` 0 failures`, exit 0;
`mix docs --warnings-as-errors` → exit 0; `mix test --only distributed --include postgres` → `
0 failures` (the Horde registry and supervisor tests; `docker start normandy-test-pg` first, the
controller stops it).

- [ ] **Step 6: MIGRATING-2.0.md**

Insert before `## Known limits of 2.0` (after `## 43.`):

```markdown
## 44. Dependencies and platform

- The optional `horde` dependency is `~> 0.10` (was `~> 0.9`):
  `SessionRegistry.Horde.Via` relies on Horde 0.10's registration order. A project locked
  to Horde 0.9 runs `mix deps.update horde`.

```

(Task 7.5b adds the Claudio 0.7.1 bullet to this section.)

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/schema/validator.ex
git add mix.exs
git add test/type_base_types_test.exs
git add test/schema/json_schema_types_test.exs
git add MIGRATING-2.0.md
git commit -m "fix(deps): compile on Elixir 1.15/1.16; require Horde ~> 0.10

The Validator matched %Duration{} unguarded (b02914e); Duration ships
with Elixir 1.17, so lib/ did not compile on the 1.15 and 1.16 CI legs.
The clause and two tests are guarded with Code.ensure_loaded?/1, as in
type.ex (decision 27 B1). Horde is tightened to ~> 0.10, the version
SessionRegistry.Horde.Via was checked against (B2); mix.lock unchanged."
```

---

### Task 7.0e: No log handler runs in the Horde supervisor's `init/1` (decision 28 A6)

The preflight saw `test/agents/turn/session_delete_test.exs:170` ("through the Horde supervisor
too") fail once (seed 606572, `scratchpad/w7-7.3d.log`): `Session.run/2`'s `start_child` call
exited because `Horde.DynamicSupervisorImpl` (`:del_21253`) crashed with `FunctionClauseError` in
`handle_info/2` on `{:EXIT, #PID<0.49741.0>, :normal}`, 1 ms after it started.

**Cause (verified; Appendix A6's theory was wrong).** No Normandy process is linked to the Horde
impl: Normandy links nothing to it (`grep -rn "Process.link\|spawn_link" lib` → only
`watched_worker.ex:35` and `turn/server.ex:1636`, both their own workers), and right after
`Turn.Supervisor.Horde.start_link/1` the impl's links are exactly its parent (probe below). The
linked process is a `Task` started **inside the impl** by ExUnit's log capture:

- `deps/horde/lib/horde/dynamic_supervisor_impl.ex:44` logs `"Starting ... with name ..."` at
  `:info` in `init/1`, **before** `:46` sets `trap_exit`; its `handle_info/2` clauses
  (`:355-398`) have no `{:EXIT, _, _}` clause. (`registry_impl.ex:52` traps first and has an
  `:EXIT` clause at `:115`, so `Horde.Registry` is not affected.)
- A `:logger` handler runs in the logging process. Whenever any test captures logs
  (`@moduletag :capture_log`, `capture_log/2`; `session_delete_test.exs` has the tag),
  `ExUnit.CaptureServer.log/2` (Elixir 1.19.5, read from its debug info) runs one
  `Task.async` per capture format in the caller, `Task.await_many/1`s them, and drains the tasks'
  `{:EXIT, pid, _}` only when the caller traps exits **at that moment**. The impl does not trap
  yet, so nothing is drained and the task stays linked until it exits `:normal`.
- If the task exits after the impl has reached `:46`, the link's `:normal` exit becomes a
  `{:EXIT, task, :normal}` message, the impl crashes, and its `:one_for_all`,
  `max_restarts: 0` supervisor goes down. Usually the task exits first and the signal is dropped,
  hence a rare flake.
- The failing log's pids match: with the capture task, Horde's children start as outer, crdt,
  impl, **task**, processes supervisor, signal, poller, listener, and the test's
  `InMemory.new()` comes next. The store was `#PID<0.49746.0>`, so the impl was `0.49740` and
  `#PID<0.49741.0>` the task spawned in its `init/1`.

Probes (scratch worktree of `4ac60ee`, deterministic): (A) a `:logger` handler that, like
`CaptureServer.log/2`, `spawn_link`s a process from the logging Horde impl and holds it: after
`start_link/1` the impl's links are `[outer, held]` and `trap_exit` is `true`; releasing the held
process crashes the impl with `{:function_clause, [{Horde.DynamicSupervisorImpl, :handle_info, ...}`,
`Last message: {:EXIT, #PID<...>, :normal}` (the preflight's crash). (B) the same with
`Logger.put_module_level(Horde.DynamicSupervisorImpl, :warning)`: the handler is never called and
the links are `[outer]`. (C) an `:erlang.trace(self(), true, [:procs, :set_on_spawn])` around
`capture_log(fn -> HSup.start_link(name: sup) end)`: the impl (`0.386`) spawns and links
`{Task.Supervised, :reply, ...}` (`0.387`), which exits `:normal`.

**Fix on Normandy's side (test environment only).** `test/test_helper.exs` sets
`Horde.DynamicSupervisorImpl`'s module level to `:warning`, so its `init/1` `:info` line reaches
no handler and nothing is linked before it traps exits. Production is not affected (the default
handler links nothing), so no `lib/` change and no MIGRATING bullet. A test pins both halves: no
handler runs in the impl's `init/1`, and Horde 0.10 still crashes on a stray `:normal` exit (when
that test fails after a Horde upgrade, the `test_helper.exs` line can go). Reporting it upstream is
Q's call (Appendix A7).

**Files:**
- Create: `test/agents/turn/horde_init_log_test.exs`
- Modify: `test/test_helper.exs`

**Interfaces:**
- Consumes: `Normandy.Agents.Turn.Supervisor.Horde.start_link/1`; `Logger.put_module_level/2`; `:logger.add_handler/3`.
- Produces: nothing in `lib/`. After this task, no `:logger` handler sees `Horde.DynamicSupervisorImpl`'s `:info` events in the test VM.

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn/horde_init_log_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.HordeInitLogTest do
  @moduledoc """
  Task 7.0e. Horde 0.10's `Horde.DynamicSupervisorImpl.init/1` logs "Starting ..." at
  `:info` before it traps exits, and its `handle_info/2` has no clause for
  `{:EXIT, pid, reason}`. A `:logger` handler runs in the logging process, and ExUnit's
  capture handler (`ExUnit.CaptureServer.log/2`, active whenever any test captures logs)
  links a `Task` to that process. When the task exits `:normal` after the impl has
  started trapping exits, the impl crashes with `FunctionClauseError` and its Horde
  supervisor (`:one_for_all`, no restarts) goes down. `test/test_helper.exs` sets the
  impl's module level to `:warning`, so no handler runs in its `init/1`.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup

  # Links a process to the process that logs, as ExUnit.CaptureServer.log/2's
  # Task.async does, and keeps it alive, so it is still linked when init/1 returns.
  # Acts only in the impl registered under this test's name (async: true).
  defmodule LinkingHandler do
    @moduledoc false
    def log(_event, %{config: %{sup: sup, to: to}}) do
      if Process.info(self(), :registered_name) == {:registered_name, sup} do
        linked =
          spawn_link(fn ->
            receive do
              :release -> :ok
            end
          end)

        send(to, {:linked, self(), linked})
      end

      :ok
    end
  end

  defp unique_name, do: :"horde_init_log_#{System.unique_integer([:positive])}"

  # :temporary: a crashed Horde supervisor is not restarted under the same name.
  defp start_horde(sup) do
    start_supervised!(%{
      id: sup,
      start: {HSup, :start_link, [[name: sup]]},
      type: :supervisor,
      restart: :temporary
    })
  end

  test "no log handler runs in the Horde impl's init/1" do
    sup = unique_name()
    handler = :"#{sup}_handler"

    :ok =
      :logger.add_handler(handler, LinkingHandler, %{
        config: %{sup: sup, to: self()},
        level: :all
      })

    on_exit(fn -> :logger.remove_handler(handler) end)

    outer = start_horde(sup)
    impl = Process.whereis(sup)

    # start_link returns after init/1, so a handler call made in init/1 has sent this.
    refute_received {:linked, ^impl, _linked}
    assert {:links, [^outer]} = Process.info(impl, :links)
  end

  # Pins the Horde behaviour the module level in test_helper.exs works around: when
  # this test fails, Horde handles a stray {:EXIT, pid, :normal}; drop that line.
  @tag :capture_log
  test "Horde 0.10's impl crashes on {:EXIT, pid, :normal} from a linked process" do
    sup = unique_name()
    start_horde(sup)
    impl = Process.whereis(sup)
    ref = Process.monitor(impl)
    test_pid = self()

    linked =
      spawn(fn ->
        Process.link(impl)
        send(test_pid, :linked)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :linked
    send(linked, :release)

    assert_receive {:DOWN, ^ref, :process, ^impl,
                    {:function_clause, [{Horde.DynamicSupervisorImpl, :handle_info, _, _} | _]}},
                   1_000
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/agents/turn/horde_init_log_test.exs`
Expected: FAIL, `2 tests, 1 failure`: "no log handler runs in the Horde impl's init/1" with
`Unexpectedly received message {:linked, #PID<...>, #PID<...>} (which matched {:linked, ^impl, _linked})`.
The second test passes (it pins Horde's behaviour and passes before and after the fix).

- [ ] **Step 3: Keep the impl's `init/1` line out of every handler**

In `test/test_helper.exs`, replace

```elixir
base_exclude = [:integration, :normandy_integration, :postgres, :distributed, :redis]
```

with

```elixir
# Horde 0.10's DynamicSupervisorImpl logs "Starting ..." at :info in init/1 before it
# traps exits, and has no handle_info/2 clause for {:EXIT, _, _}. ExUnit's capture_log
# handler runs in the logging process and links a Task to it; a Task that exits :normal
# after the impl traps exits crashes the impl and its Horde supervisor. No handler runs
# for that line at :warning (Task 7.0e, test/agents/turn/horde_init_log_test.exs).
:ok = Logger.put_module_level(Horde.DynamicSupervisorImpl, :warning)

base_exclude = [:integration, :normandy_integration, :postgres, :distributed, :redis]
```

(`Logger.put_module_level/2` needs no loaded module; it applies to Horde's compiled
`Logger.info/1` call, which checks the level before any handler runs.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/agents/turn/horde_init_log_test.exs`
Expected: PASS, `2 tests, 0 failures`.

- [ ] **Step 5: Repeat the Horde tests**

Run:
`mix test test/agents/turn/session_delete_test.exs test/agents/turn/supervisor_horde_test.exs test/agents/turn/horde_init_log_test.exs --repeat-until-failure 50 2>&1 | tee /tmp/w7-7.0e-repeat.log | grep -cE "^16 tests, 0 failures"`
Expected: `51` (the first run plus 50 repeats, each `16 tests, 0 failures`; Elixir 1.19's
`--repeat-until-failure` stops at the first failing run; a lower count means a run failed: read
`/tmp/w7-7.0e-repeat.log`). Verified on `4ac60ee` + this task: 51.

- [ ] **Step 6: Gate**

Run: `mix format && mix precommit 2>&1 | tee /tmp/w7-7.0e.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.0e.log`
and `mix docs --warnings-as-errors`.
Expected: ` 0 failures` (two more tests than after Task 7.0d), exit 0; docs exit 0.

Then the distributed suite (Horde across peer nodes): `docker start normandy-test-pg`, then
`MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres`
→ ` 0 failures` (on `4ac60ee` + this task: 77 tests, 0 failures); the controller stops
`normandy-test-pg` afterwards. No Redis or Postgres store suite: no store, registry or
`Turn.Server` code changes.

- [ ] **Step 7: MIGRATING-2.0.md**

No bullet: the change is in the test environment only; no public function, option, message or
behaviour of the library changes.

- [ ] **Step 8: Commit**

```bash
git add test/agents/turn/horde_init_log_test.exs
git add test/test_helper.exs
git commit -m "test(horde): keep log handlers out of the Horde supervisor's init

Horde 0.10's DynamicSupervisorImpl logs at :info in init/1 before it
traps exits and has no handle_info/2 clause for {:EXIT, _, _}. ExUnit's
capture_log handler runs in the logging process and links a Task to it;
a Task that exited :normal after the impl trapped exits crashed the impl
(session_delete_test, seed 606572). test_helper.exs raises the impl's
module level to :warning; a test pins both halves (decision 28 A6)."
```

---

### Task 7.2a: Hide the internals (DX-13, REL-7, decision 27 C1)

Eighteen implementation modules get `@moduledoc false`. Their moduledoc text stays in the
file as `#` comments, as `Hooks.BaseAgentGlue` does. Every public doc that links to one is
reworded. `MIX_ENV=dev mix docs --warnings-as-errors` reports 19 "references … but it is
hidden" warnings after the hiding and none after the rewording (both observed).

**Files:**
- Modify (hide): `lib/normandy/hooks/runner.ex`, `lib/normandy/hooks/handlers.ex`,
  `lib/normandy/agents/turn/driver.ex`, `lib/normandy/agents/turn/inline.ex`,
  `lib/normandy/telemetry/metadata.ex`, `lib/normandy/telemetry/otel_ctx.ex`,
  `lib/normandy/telemetry/provider.ex`, `lib/normandy/telemetry/killed_run.ex`,
  `lib/normandy/telemetry/workflow_span.ex`, `lib/normandy/llm/json/content_cleaner.ex`,
  `lib/normandy/llm/json/decoder.ex`, `lib/normandy/llm/json/retry_feedback.ex`,
  `lib/normandy/llm/json/scanner.ex`, `lib/normandy/llm/json/schema_binder.ex`,
  `lib/normandy/llm/json/schema_translator.ex`, `lib/normandy/agents/validation_middleware.ex`,
  `lib/normandy/behaviours/session_registry/horde/via.ex`,
  `lib/normandy/behaviours/session_registry/redis/via.ex`
- Modify (reword references): `docs/guides/hooks.md`, `lib/normandy/agents/dispatch.ex`,
  `lib/normandy/batch/processor.ex`, `lib/normandy/coordination/parallel_orchestrator.ex`,
  `lib/normandy/coordination/reactive.ex`, `lib/normandy/behaviours/hooks.ex`,
  `lib/normandy/dsl/workflow.ex`, `lib/normandy/guardrails/guard.ex`,
  `lib/normandy/llm/json_deserializer.ex`, `lib/normandy/telemetry.ex`, `ROADMAP.md`
- Modify: `MIGRATING-2.0.md` (create `## 45.`; reword one §42 bullet)
- Test: create `test/docs/docs_groups_test.exs`; `test/hooks/guide_examples_test.exs` runs the
  rewritten guide example unchanged

**Interfaces:**
- Consumes: nothing from earlier Wave 7 tasks. 7.0a may have edited `dispatch.ex`, but not the
  moduledoc's "## Telemetry" paragraph.
- Produces: `test/docs/docs_groups_test.exs` (module `Normandy.Docs.DocsGroupsTest`), which
  Task 7.2b extends; `## 45. Testing support and docs` in `MIGRATING-2.0.md`, which Tasks 7.3b–e append to.

- [ ] **Step 1: Write the failing test**

Create `test/docs/docs_groups_test.exs`:

```elixir
defmodule Normandy.Docs.DocsGroupsTest do
  @moduledoc """
  HexDocs layout (DX-13, REL-7, decision 27 C1): internals are hidden, and every
  module with docs is in exactly one `groups_for_modules` group in `mix.exs`.
  """
  use ExUnit.Case, async: true

  # Implementation details: `@moduledoc false` (decision 27 C1).
  @hidden [
    Normandy.Agents.Turn.Driver,
    Normandy.Agents.Turn.Inline,
    Normandy.Agents.ValidationMiddleware,
    Normandy.Behaviours.SessionRegistry.Horde.Via,
    Normandy.Behaviours.SessionRegistry.Redis.Via,
    Normandy.Hooks.Handlers,
    Normandy.Hooks.Runner,
    Normandy.LLM.Json.ContentCleaner,
    Normandy.LLM.Json.Decoder,
    Normandy.LLM.Json.RetryFeedback,
    Normandy.LLM.Json.Scanner,
    Normandy.LLM.Json.SchemaBinder,
    Normandy.LLM.Json.SchemaTranslator,
    Normandy.Telemetry.KilledRun,
    Normandy.Telemetry.Metadata,
    Normandy.Telemetry.OtelCtx,
    Normandy.Telemetry.Provider,
    Normandy.Telemetry.WorkflowSpan
  ]

  # Public although internal-looking: adapter authors, hook authors and handler
  # injection use them (decision 27 C1).
  @kept_public [
    Normandy.Agents.Dispatch,
    Normandy.Agents.Dispatch.Invocation,
    Normandy.Agents.Dispatch.Pipeline,
    Normandy.Agents.Turn.Driver.Handlers,
    Normandy.Hooks.Context,
    Normandy.LLM.StructuredOutputs,
    Normandy.Schema.Validator,
    Normandy.Telemetry.Request,
    Normandy.Telemetry.Usage
  ]

  test "internals have no docs page" do
    shown = Enum.reject(@hidden, &(moduledoc(&1) == :hidden))
    assert shown == [], "expected @moduledoc false, found docs on: #{inspect(shown)}"
  end

  test "the public helpers keep their docs page" do
    hidden = Enum.filter(@kept_public, &(moduledoc(&1) == :hidden))
    assert hidden == [], "expected a @moduledoc, found it hidden on: #{inspect(hidden)}"
  end

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(mod)
    moduledoc
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/docs/docs_groups_test.exs`
Expected: FAIL, 1 of 2. `internals have no docs page` reports
`expected @moduledoc false, found docs on: [Normandy.Agents.Turn.Driver, … Normandy.Telemetry.WorkflowSpan]`
(all 18). `the public helpers keep their docs page` passes: it guards the keep-list from here on.

- [ ] **Step 3: Hide the 18 modules**

Save this script outside the repository (for example `$TMPDIR/hide_moduledoc.sh`). It
replaces the first `@moduledoc """ … """` heredoc in each file with `@moduledoc false`,
followed by the same text as `#` comments at the heredoc's indentation. The nested
`Turn.Driver.Handlers` moduledoc (`driver.ex:24`, a one-line string) is not touched, so
Handlers stays public.

```sh
#!/bin/sh
for f in "$@"; do
  perl -0pi -e 's{^([ \t]*)\@moduledoc """\n(.*?)^\1"""\n}{my ($i, $b) = ($1, $2); $b =~ s/^\Q$i\E//mg; $b =~ s/^(?=.)/$i# /mg; $b =~ s/^$/$i#/mg; "$i\@moduledoc false\n$b"}mse' "$f"
done
```

Run it from the repository root on the 18 files in **Files** (Modify (hide)):

```sh
sh $TMPDIR/hide_moduledoc.sh lib/normandy/hooks/runner.ex lib/normandy/hooks/handlers.ex \
  lib/normandy/agents/turn/driver.ex lib/normandy/agents/turn/inline.ex \
  lib/normandy/telemetry/metadata.ex lib/normandy/telemetry/otel_ctx.ex \
  lib/normandy/telemetry/provider.ex lib/normandy/telemetry/killed_run.ex \
  lib/normandy/telemetry/workflow_span.ex lib/normandy/llm/json/content_cleaner.ex \
  lib/normandy/llm/json/decoder.ex lib/normandy/llm/json/retry_feedback.ex \
  lib/normandy/llm/json/scanner.ex lib/normandy/llm/json/schema_binder.ex \
  lib/normandy/llm/json/schema_translator.ex lib/normandy/agents/validation_middleware.ex \
  lib/normandy/behaviours/session_registry/horde/via.ex \
  lib/normandy/behaviours/session_registry/redis/via.ex
git diff --stat | tail -1    # 18 files changed
grep -c "@moduledoc false" lib/normandy/hooks/runner.ex lib/normandy/agents/turn/driver.ex   # 1 each
```

Comments are subject to Credo's 120-column limit, which does not apply inside a heredoc.
After the script, three comment lines exceed it. Fix them by hand:

In `lib/normandy/hooks/runner.ex`, delete the comment paragraph that no longer holds (hooks
are now tested through an agent; see Step 4):

```
  #
  # These functions are also the supported way to test a hook with the library's rules
  # applied (rewrite threading, halts, `:on_error`, return contracts): pass a config map such
  # as `%{name: "a", behaviours: %{hooks: [{MyHook, []}]}}`.
```

and replace the `:on_error` bullet and its table:

```
  #   * `:on_error`, removed from opts before the callback sees them:
  #
  #     | Event | `:reraise` (default) | `:open` | `:closed` |
  #     |---|---|---|---|
  #     | `on_prompt`, `before_llm`, `before_tool` | propagates | logged; the value passes on | halts, reason naming the hook |
  #     | `after_tool` | propagates | logged; the result passes on | the result becomes an error result naming the hook; later `after_tool` entries do not run |
  #     | `after_compact`, `on_session_start` | propagates | logged; injects nothing | propagates |
  #     | `on_turn_end`, `on_passivate` | logged | logged | logged |
  #
```

with:

```
  #   * `:on_error` is removed from opts before the callback sees them; what each policy
  #     does per event is the table in docs/guides/hooks.md, "Errors (`:on_error`)". Under
  #     `:closed`, an `after_tool` crash makes the result an error result naming the hook
  #     and later `after_tool` entries do not run.
```

The guide's table (`docs/guides/hooks.md`, "## Errors (`:on_error`)") already has every row.

In `lib/normandy/telemetry/killed_run.ex`, replace:

```
  #     `:exception` after the real one; that window is short. `Batch.Processor` runs no callbacks in the task and doesn't mark:
  #     its window, from the run's `:stop` to the task's reply, is the same short window.
```

with:

```
  #     `:exception` after the real one; that window is short. `Batch.Processor` runs no
  #     callbacks in the task and doesn't mark: its window, from the run's `:stop` to the
  #     task's reply, is the same short window.
```

- [ ] **Step 4: Reword every public reference to a hidden module**

Each before/after below is an exact, unique match. ExDoc links a backticked
fully-qualified name, so a doc that should not link loses the backticks or names a public
module instead.

`docs/guides/hooks.md`, section "## Testing a hook": replace from
`Call the callback directly with a context:` through `name and pass the name in opts (a pid is refused).` with:

````markdown
Call the callback directly with a context, or run it through an agent:

```elixir
defmodule MyAppTest.RedactHookTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.ContentBlock
  alias Normandy.HookHaltError
  alias Normandy.Hooks.Context

  test "redacts an SSN" do
    ctx = %Context{event: :on_prompt}
    assert {:cont, "id [ssn]"} = MyApp.Hooks.Redact.on_prompt("id 123-45-6789", ctx, [])
  end

  test "an agent refuses what the hook cannot read" do
    config =
      BaseAgent.init(
        client: %Normandy.LLM.ClaudioAdapter{api_key: "never-used"},
        model: "claude-opus-5-5",
        behaviours: %Normandy.Behaviours.Config{hooks: [{MyApp.Hooks.Redact, []}]}
      )

    assert {:error, %HookHaltError{hook: MyApp.Hooks.Redact, reason: "unsupported input shape"}} =
             BaseAgent.run(config, [%ContentBlock.Text{text: "id 123-45-6789"}])
  end
end
```

The second test runs the hook the way an agent does: ordering, `:on_error` and the return
contracts apply. An `on_prompt` halt ends the turn before any model call, so the client is
never called. To receive messages from a hook in a test, register the test process under a
name and pass the name in opts (a pid is refused).
````

`lib/normandy/agents/dispatch.ex` (moduledoc "## Telemetry"):
- `(`%{count: 1}`, metadata from `Normandy.Telemetry.Metadata.tool_denied/4`) with` →
  `(`%{count: 1}`, metadata as listed in `Normandy.Telemetry`) with`
- the two lines
  ```
    `[:normandy, :tool, :result_truncated]` (`%{original_chars, kept_chars}`, metadata from
    `Normandy.Telemetry.Metadata.tool_result_truncated/3`).
  ```
  →
  ```
    `[:normandy, :tool, :result_truncated]` (`%{original_chars, kept_chars}`, metadata as
    listed in `Normandy.Telemetry`).
  ```

`lib/normandy/batch/processor.ex`: `` See\n  `Normandy.Telemetry.KilledRun`. `` (the last two lines
of the moduledoc) → `` See\n  "Killed runs" in `Normandy.Telemetry`. ``

`lib/normandy/coordination/parallel_orchestrator.ex` and `lib/normandy/coordination/reactive.ex`:
`` See `Normandy.Telemetry.KilledRun`. `` → `` See "Killed runs" in `Normandy.Telemetry`. ``
(one occurrence in each file).

`lib/normandy/behaviours/hooks.ex`:
`` `{module, opts}` entries, run in list order by `Normandy.Hooks.Runner`. `` →
`` `{module, opts}` entries, run in list order. ``

`lib/normandy/dsl/workflow.ex`:
`` entry points (see `Normandy.Telemetry.WorkflowSpan`); `Reactive`'s combinators `` →
`` entry points (see `Normandy.Telemetry`); `Reactive`'s combinators ``

`lib/normandy/guardrails/guard.ex`, replace:

```
  Violations use the same `%{path, message, constraint}` shape as
  `Normandy.Agents.ValidationMiddleware`, with an additional `:guard` key
  identifying the module that produced the violation. This means
  `Normandy.Agents.ValidationMiddleware.error_message/1` renders guardrail
  violations without modification.
```

with:

```
  Violations use the same `%{path, message, constraint}` shape as the `errors` of a
  `Normandy.Schema.ValidationError`, with an additional `:guard` key identifying the
  module that produced the violation.
```

`lib/normandy/llm/json_deserializer.ex`: replace the paragraph and table from
`This module is a thin facade over five focused units under` through the
`| `Normandy.LLM.Json.RetryFeedback` | … |` row and the blank line after it with:

```
  It strips Markdown fences and surrounding prose, recovers a truncated top-level
  string, decodes through the configured JSON adapter (with a `:max_input_bytes` guard),
  casts and validates the result against the target schema, and builds the corrective
  retry prompt after a parse error.

```

`lib/normandy/telemetry.ex`:
- `` One hook module call (`Normandy.Hooks.Runner`): one span per `{module, opts}` entry per `` →
  `` One hook module call: one span per `{module, opts}` entry per ``
- in "## Killed runs", delete the blank line and `` See `Normandy.Telemetry.KilledRun` for the details. ``
  after the bullet ending `` produce a late synthetic `:exception`. ``. The section already
  holds the guarantees and limits. `test/telemetry/catalogue_test.exs` and
  `test/hooks/runner_test.exs:491` read this moduledoc. Neither asserts on the deleted line
  (they pass, observed).

`MIGRATING-2.0.md` §42, first bullet:
`` - `Normandy.Telemetry.OtelCtx` asks the code server once per node whether OpenTelemetry is `` →
`- Normandy asks the code server once per node whether OpenTelemetry is`

`ROADMAP.md`:
`` - `Normandy.Agents.ValidationMiddleware` - Integrated logging for validation `` →
`- Normandy.Agents.ValidationMiddleware (internal since 2.0) - Integrated logging for validation`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/docs/docs_groups_test.exs test/hooks/guide_examples_test.exs test/telemetry test/hooks/runner_test.exs`
Expected: PASS (`docs_groups_test.exs`: 2 tests; `guide_examples_test.exs`: 3 tests).

Run: `MIX_ENV=dev mix docs --warnings-as-errors 2>&1 | grep -c "warning:"`
Expected: `0`, exit 0. A warning here names a reference Step 4 missed; reword it the same way.

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.2a.log; grep -E " [0-9]+ failures|Total errors|found no issues" /tmp/w7-7.2a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0, Credo `found no issues`; docs exit 0. No tagged suite: no runtime code changes.

- [ ] **Step 7: MIGRATING-2.0.md**

Insert before `## Known limits of 2.0` (after `## 44.`, which Task 7.0d created). Keep the
hidden names unbackticked (Header conflict 2):

```markdown
## 45. Testing support and docs

- These modules are internal in 2.0: they have no docs page (`@moduledoc false`) and may
  change in any release: Normandy.Hooks.Runner, Normandy.Hooks.Handlers,
  Normandy.Agents.Turn.Driver, Normandy.Agents.Turn.Inline,
  Normandy.Agents.ValidationMiddleware, Normandy.Telemetry.KilledRun,
  Normandy.Telemetry.Metadata, Normandy.Telemetry.OtelCtx, Normandy.Telemetry.Provider,
  Normandy.Telemetry.WorkflowSpan, Normandy.LLM.Json.ContentCleaner,
  Normandy.LLM.Json.Decoder, Normandy.LLM.Json.RetryFeedback, Normandy.LLM.Json.Scanner,
  Normandy.LLM.Json.SchemaBinder, Normandy.LLM.Json.SchemaTranslator,
  Normandy.Behaviours.SessionRegistry.Horde.Via and
  Normandy.Behaviours.SessionRegistry.Redis.Via. `Normandy.Agents.Turn.Driver.Handlers`,
  `Normandy.Hooks.Context`, `Normandy.Telemetry.Request` and `Normandy.Telemetry.Usage`
  stay public.
- To test a hook under the library's rules (ordering, `:on_error`, return contracts), run
  it through an agent: `BaseAgent.run/3` on a config whose `behaviours` lists the hook. The
  hooks guide's "Testing a hook" section shows it. Calling the hook runner directly is no
  longer documented.
```

Run `mix docs --warnings-as-errors` again. Expected: exit 0. A backticked hidden name fails it.

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/hooks/runner.ex lib/normandy/hooks/handlers.ex \
  lib/normandy/agents/turn/driver.ex lib/normandy/agents/turn/inline.ex \
  lib/normandy/telemetry/metadata.ex lib/normandy/telemetry/otel_ctx.ex \
  lib/normandy/telemetry/provider.ex lib/normandy/telemetry/killed_run.ex \
  lib/normandy/telemetry/workflow_span.ex lib/normandy/llm/json/content_cleaner.ex \
  lib/normandy/llm/json/decoder.ex lib/normandy/llm/json/retry_feedback.ex \
  lib/normandy/llm/json/scanner.ex lib/normandy/llm/json/schema_binder.ex \
  lib/normandy/llm/json/schema_translator.ex lib/normandy/agents/validation_middleware.ex \
  lib/normandy/behaviours/session_registry/horde/via.ex \
  lib/normandy/behaviours/session_registry/redis/via.ex
git add docs/guides/hooks.md lib/normandy/agents/dispatch.ex lib/normandy/batch/processor.ex \
  lib/normandy/coordination/parallel_orchestrator.ex lib/normandy/coordination/reactive.ex \
  lib/normandy/behaviours/hooks.ex lib/normandy/dsl/workflow.ex lib/normandy/guardrails/guard.ex \
  lib/normandy/llm/json_deserializer.ex lib/normandy/telemetry.ex ROADMAP.md MIGRATING-2.0.md \
  test/docs/docs_groups_test.exs
git commit -m "docs: hide internal modules from HexDocs; test hooks through an agent"
```

---

### Task 7.2b: Every documented module in exactly one group; group the guides (DX-13, REL-7)

The 147 modules with a docs page after 7.2a (`:application.get_key(:normandy, :modules)`,
excluding hidden modules and the 3 protocol implementations ExDoc omits) are grouped as
follows. 75 are grouped today and 72 are not. The test fails on any module that is ungrouped,
grouped twice, or grouped while hidden or missing, so a later task that adds a module must
also group it.

**Files:**
- Modify: `mix.exs` (`docs:` — `groups_for_extras`, `groups_for_modules`)
- Modify: `README.md` ("## Documentation", the API documentation line)
- Test: modify `test/docs/docs_groups_test.exs` (two tests and three helpers)

**Interfaces:**
- Consumes: `test/docs/docs_groups_test.exs` from Task 7.2a; the hidden set of Task 7.2a.
- Produces: the "Docs groups test" (header interface). The `groups_for_modules` keys are
  `Core`, `Agents`, `"Durable turns"`, `"Session stores and registries"`, `Memory`, `Hooks`,
  `Behaviours`, `DSL`, `Coordination`, `Components`, `Tools`, `"Context Management"`,
  `Resilience`, `Guardrails`, `"Batch Processing"`, `MCP`, `A2A`, `"LLM Adapters"`,
  `Testing` (empty; 7.3b and 7.3d append `Normandy.Test.*`), `Errors` and `Telemetry`. The
  `groups_for_extras` keys are `Guides` (`~r{docs/guides/.*}`, so Task 7.3e's `testing.md`
  lands there) and `"Upgrading and changes"`.

- [ ] **Step 1: Write the failing tests**

In `test/docs/docs_groups_test.exs`, add these tests after `the public helpers keep their docs page`:

```elixir
  test "every lib/ module with docs is in exactly one docs group" do
    grouped =
      for {group, mods} <- groups(), mod <- mods do
        assert is_atom(mod),
               "expected module atoms in group #{inspect(group)}, got: #{inspect(mod)}"

        mod
      end

    {:ok, modules} = :application.get_key(:normandy, :modules)

    documented =
      for mod <- modules,
          lib_module?(mod),
          not protocol_impl?(mod),
          moduledoc(mod) != :hidden,
          do: mod

    counts = Enum.frequencies(grouped)
    ungrouped = documented |> Enum.reject(&Map.has_key?(counts, &1)) |> Enum.sort()
    duplicated = for {mod, n} <- counts, n > 1, do: mod
    unknown = Enum.sort(Map.keys(counts) -- documented)

    assert ungrouped == [], "expected a docs group in mix.exs for: #{inspect(ungrouped)}"

    assert duplicated == [],
           "expected one docs group each, found several for: #{inspect(duplicated)}"

    assert unknown == [],
           "expected documented lib/ modules only, found hidden, protocol impl or missing: " <>
             inspect(unknown)
  end

  test "the README's API documentation line names every docs group" do
    [line] = Regex.run(~r/^- \*\*📚 \[API documentation\].*$/m, File.read!("README.md"))

    missing =
      for {group, _mods} <- groups(), not String.contains?(line, to_string(group)), do: group

    assert missing == [], "expected the README to name the docs groups #{inspect(missing)}"
  end
```

and these helpers before `defp moduledoc/1`:

```elixir
  defp groups,
    do: Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:groups_for_modules)

  # test/support modules are in :normandy's module list in the test env.
  defp lib_module?(mod) do
    Code.ensure_loaded!(mod)
    source = mod.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    String.starts_with?(Path.relative_to_cwd(source), "lib/")
  end

  # ExDoc lists no protocol implementation.
  defp protocol_impl?(mod), do: function_exported?(mod, :__impl__, 1)
```

`lib_module?/1` runs `Code.ensure_loaded!/1` first: `function_exported?(_, :__impl__, 1)` is
false for a module that is not loaded yet. It also excludes `test/support`, whose 39
`Normandy.Test.*` modules are compiled into `:normandy` in the test env.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/docs/docs_groups_test.exs`
Expected: FAIL, 2 of 4.
- `expected a docs group in mix.exs for: [Normandy, Normandy.Agents.BaseAgentInputSchema, …]`
  lists the 72 modules added to groups in Step 3 (a module there not in Step 3's list was
  added by a task before this one: group it by its moduledoc's area and say so in the task report).
- The README test reports
  `expected the README to name the docs groups [:Components, :"Batch Processing", :Errors, :Telemetry]`
  (it reads today's `mix.exs` groups, before Step 3 adds the new ones).

- [ ] **Step 3: The groups**

In `mix.exs`, replace everything from the line `        # groups_for_extras: [` through
the closing `        ],` of `groups_for_modules` (the line before
`        # Old entries name functions since removed`) with:

```elixir
        groups_for_extras: [
          Guides: ~r{docs/guides/.*},
          "Upgrading and changes": ["MIGRATING-2.0.md", "CHANGELOG.md"]
        ],
        # Every module with docs is in exactly one group (test/docs/docs_groups_test.exs).
        groups_for_modules: [
          Core: [
            Normandy,
            Normandy.Schema,
            Normandy.Schema.Wire,
            Normandy.Schema.Introspection,
            Normandy.Schema.Validator,
            Normandy.Type,
            Normandy.Validate,
            Normandy.ParameterizedType,
            Normandy.JSON,
            Normandy.Metadata
          ],
          Agents: [
            Normandy.Agents.BaseAgent,
            Normandy.Agents.BaseAgentConfig,
            Normandy.Agents.BaseAgentInputSchema,
            Normandy.Agents.BaseAgentOutputSchema,
            Normandy.Agents.ConfigTemplate,
            Normandy.Agents.Model,
            Normandy.Agents.ToolCallResponse,
            Normandy.Options
          ],
          "Durable turns": [
            Normandy.Agents.Turn,
            Normandy.Agents.Turn.State,
            Normandy.Agents.Turn.Session,
            Normandy.Agents.Turn.Server,
            Normandy.Agents.Turn.Supervisor,
            Normandy.Agents.Turn.Supervisor.Horde,
            Normandy.Agents.Turn.ResumeReaper,
            Normandy.Agents.Turn.Driver.Handlers,
            Normandy.Cluster
          ],
          "Session stores and registries": [
            Normandy.Behaviours.SessionStore,
            Normandy.Behaviours.SessionStore.InMemory,
            Normandy.Behaviours.SessionStore.ETS,
            Normandy.Behaviours.SessionStore.Mnesia,
            Normandy.Behaviours.SessionStore.Postgres,
            Normandy.Behaviours.SessionStore.Postgres.Migration,
            Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate,
            Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy,
            Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight,
            Normandy.Behaviours.SessionStore.Redis,
            Normandy.Behaviours.SessionRegistry,
            Normandy.Behaviours.SessionRegistry.Native,
            Normandy.Behaviours.SessionRegistry.Horde,
            Normandy.Behaviours.SessionRegistry.Redis,
            Normandy.Behaviours.SessionRegistry.Redis.Handle
          ],
          Memory: [
            Normandy.Tools.Memory,
            Normandy.Behaviours.MemoryStore,
            Normandy.Behaviours.MemoryStore.InMemory,
            Normandy.Behaviours.MemoryStore.ETS,
            Normandy.Behaviours.MemoryStore.Mnesia,
            Normandy.Behaviours.MemoryStore.Postgres,
            Normandy.Behaviours.MemoryStore.Postgres.Migration,
            Normandy.Behaviours.MemoryStore.Redis
          ],
          Hooks: [
            Normandy.Behaviours.Hooks,
            Normandy.Hooks.Context
          ],
          Behaviours: [
            Normandy.Behaviours.Config,
            Normandy.Behaviours.AgentTemplate,
            Normandy.Behaviours.AgentTemplate.Catalog,
            Normandy.Behaviours.BudgetTracker,
            Normandy.Behaviours.BudgetTracker.NoOp,
            Normandy.Behaviours.Compactor,
            Normandy.Behaviours.Compactor.NoOp,
            Normandy.Behaviours.Compactor.WindowManager,
            Normandy.Behaviours.CredentialProvider,
            Normandy.Behaviours.CredentialProvider.FromClient,
            Normandy.Behaviours.ModelCatalog,
            Normandy.Behaviours.ModelCatalog.ModelsAPI,
            Normandy.Behaviours.ModelCatalog.Static,
            Normandy.Behaviours.PolicyEngine,
            Normandy.Behaviours.PolicyEngine.AllowAll,
            Normandy.Behaviours.PolicyEngine.Ruleset
          ],
          DSL: [
            Normandy.DSL.Agent,
            Normandy.DSL.Workflow
          ],
          Coordination: [
            Normandy.Coordination.Pattern,
            Normandy.Coordination.Reactive,
            Normandy.Coordination.AgentPool,
            Normandy.Coordination.SequentialOrchestrator,
            Normandy.Coordination.ParallelOrchestrator,
            Normandy.Coordination.Orchestration,
            Normandy.Coordination.HierarchicalCoordinator,
            Normandy.Coordination.AgentProcess,
            Normandy.Coordination.AgentSupervisor,
            Normandy.Coordination.AgentMessage,
            Normandy.Coordination.SharedContext,
            Normandy.Coordination.StatefulContext
          ],
          Components: [
            Normandy.Components.AgentMemory,
            Normandy.Components.AgentMemory.Entry,
            Normandy.Components.Message,
            Normandy.Components.ContentBlock.Text,
            Normandy.Components.ContentBlock.Image,
            Normandy.Components.ContentBlock.Document,
            Normandy.Components.PromptSpecification,
            Normandy.Components.SystemPromptGenerator,
            Normandy.Components.BaseIOSchema,
            Normandy.Components.ContextProvider,
            Normandy.Components.DateTimeProvider,
            Normandy.Components.StreamEvent,
            Normandy.Components.StreamProcessor,
            Normandy.Components.ToolCall,
            Normandy.Components.ToolResult
          ],
          Tools: [
            Normandy.Tool,
            Normandy.Tools.Toolset,
            Normandy.Tools.Context,
            Normandy.Tools.Input,
            Normandy.Tools.Executor,
            Normandy.Agents.Dispatch,
            Normandy.Agents.Dispatch.Invocation,
            Normandy.Agents.Dispatch.Pipeline
          ],
          "Context Management": [
            Normandy.Context.TokenCounter,
            Normandy.Context.WindowManager,
            Normandy.Context.Summarizer
          ],
          Resilience: [
            Normandy.Resilience.Retry,
            Normandy.Resilience.CircuitBreaker
          ],
          Guardrails: [
            Normandy.Guardrails,
            Normandy.Guardrails.Guard,
            Normandy.Guardrails.ViolationError,
            Normandy.Guardrails.Builtins.MaxLength,
            Normandy.Guardrails.Builtins.ForbiddenSubstrings,
            Normandy.Guardrails.Builtins.RegexGuard,
            Normandy.Guardrails.Builtins.RequiredFields,
            Normandy.Guardrails.Builtins.SemanticScope
          ],
          "Batch Processing": [
            Normandy.Batch.Processor
          ],
          MCP: [
            Normandy.MCP.ToolWrapper,
            Normandy.MCP.Registry,
            Normandy.MCP.ServerConfig
          ],
          A2A: [
            Normandy.A2A.AgentTool,
            Normandy.A2A.Registry,
            Normandy.A2A.Server
          ],
          "LLM Adapters": [
            Normandy.LLM.Request,
            Normandy.LLM.Response,
            Normandy.LLM.ClaudioAdapter,
            Normandy.LLM.OpenAICompatibleAdapter,
            Normandy.LLM.StructuredOutputs,
            Normandy.LLM.JsonDeserializer
          ],
          # Shipped test helpers (Normandy.Test.*); Tasks 7.3b and 7.3d add their modules.
          Testing: [],
          Errors: [
            Normandy.LLMError,
            Normandy.TurnError,
            Normandy.OrchestrationError,
            Normandy.ToolNotFoundError,
            Normandy.TurnNotFoundError,
            Normandy.ContextProviderNotFoundError,
            Normandy.HookHaltError,
            Normandy.ModelCatalogError,
            Normandy.Schema.ValidationError,
            Normandy.CastError,
            Normandy.InvalidChangesetError,
            Normandy.Guardrails.GuardError
          ],
          Telemetry: [
            Normandy.Telemetry,
            Normandy.Telemetry.Span,
            Normandy.Telemetry.Request,
            Normandy.Telemetry.Usage
          ]
        ],
```

`Normandy.Guardrails.GuardError` moves from ExDoc's automatic "Exceptions" group to Errors.

In `README.md`, replace the line

```
- **📚 [API documentation](https://hexdocs.pm/normandy)** — every module, grouped by Core, Agents, DSL, Coordination, Tools, Context Management, Resilience, Guardrails, MCP, A2A, and LLM Adapters.
```

with

```
- **📚 [API documentation](https://hexdocs.pm/normandy)** — every public module, grouped by area: Core, Agents, Durable turns, Session stores and registries, Memory, Hooks, Behaviours, DSL, Coordination, Components, Tools, Context Management, Resilience, Guardrails, Batch Processing, MCP, A2A, LLM Adapters, Testing, Errors and Telemetry.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/docs/docs_groups_test.exs`
Expected: PASS (4 tests).

Run: `MIX_ENV=dev mix docs --warnings-as-errors`, then
`sed 's/^sidebarNodes=//; s/;$//' doc/dist/sidebar_items-*.js | python3 -c 'import json,sys,collections; d=json.load(sys.stdin); print(collections.Counter(m.get("group","") for m in d["modules"])[""], collections.Counter(e.get("group","") for e in d["extras"]))'`
Expected: docs exit 0; `0` modules in group `""`, no `"Exceptions"` group; extras
`Guides: 3`, `Upgrading and changes: 2`, `"": 4` (api-reference, readme, license, roadmap).

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.2b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.2b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite.

- [ ] **Step 6: MIGRATING-2.0.md**

No entry: the sidebar layout changes and no API does.

- [ ] **Step 7: Commit**

```bash
git add mix.exs README.md test/docs/docs_groups_test.exs
git commit -m "docs: group every documented module and the guides on HexDocs"
```

---

### Task 7.3a: The last BaseAgent docs and "Choosing an entry point" (DX-10, plan.md 7.3)

Plan.md's acceptance is met by documenting three functions. "mix docs lists no public function
without docs" cannot be checked with `mix docs`: it exits 0 and renders `reset_memory/1` with an
empty body (inventory 7.3 §0.2). So a `Code.fetch_docs/1` test pins it (R2). Task 7.3f widens
the test to every visible module.

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`@doc` on `reset_memory/1`,
  `register_context_provider/3`, `delete_context_provider/2`)
- Modify: `lib/normandy.ex` (moduledoc)
- Test: create `test/docs/doc_coverage_test.exs`

**Interfaces:**
- Consumes: nothing. Task 7.0c edits `base_agent.ex` elsewhere (A3). Anchor on the `@spec` lines quoted below.
- Produces: `test/docs/doc_coverage_test.exs` (module `Normandy.Docs.DocCoverageTest`),
  scoped to `BaseAgent` and `Turn.Session` (header interface "Doc coverage test"; Task 7.3f1
  widens it).

- [ ] **Step 1: Write the failing test**

Create `test/docs/doc_coverage_test.exs`:

```elixir
defmodule Normandy.Docs.DocCoverageTest do
  @moduledoc """
  Public API has docs (DX-10, decision 27 C5). ExDoc renders an undocumented function
  with an empty body and no warning, so the compiled docs chunks are checked instead.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Session

  @kinds [:function, :macro, :callback, :macrocallback]

  test "BaseAgent and Turn.Session document every public function" do
    missing = Enum.flat_map([BaseAgent, Session], &undocumented/1)
    assert missing == [], "expected @doc on: #{inspect(missing)}"
  end

  test "the Normandy moduledoc says which entry point to use" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy)
    assert doc =~ "## Choosing an entry point"

    for mod <- ~w(Agents.BaseAgent DSL.Agent Coordination.AgentProcess Agents.Turn.Session) do
      assert doc =~ "| `Normandy.#{mod}` |", "expected a table row for Normandy.#{mod}"
    end
  end

  # `{module, kind, name, arity}` for each function, macro or callback with no @doc.
  defp undocumented(mod) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)
    for {{kind, name, arity}, _, _, :none, _} <- docs, kind in @kinds, do: {mod, kind, name, arity}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/docs/doc_coverage_test.exs`
Expected: FAIL, 2 of 2:
`expected @doc on: [{Normandy.Agents.BaseAgent, :function, :delete_context_provider, 2}, {Normandy.Agents.BaseAgent, :function, :register_context_provider, 3}, {Normandy.Agents.BaseAgent, :function, :reset_memory, 1}]`
(order as in the docs chunk), and `Assertion with =~ failed` on `"## Choosing an entry point"`.

- [ ] **Step 3: The three docs**

In `lib/normandy/agents/base_agent.ex`, insert before `  @spec reset_memory(BaseAgentConfig.t()) :: BaseAgentConfig.t()`:

```elixir
  @doc """
  Returns `config` with its memory back to the memory it was built with (`init/1`'s
  `:memory`, empty by default), dropping every turn since. Nothing else changes: tools,
  context providers and the prompt specification stay as they are.
  """
```

Insert before `  @spec register_context_provider(BaseAgentConfig.t(), atom(), struct()) ::`:

```elixir
  @doc """
  Returns `config` with `provider` registered under `name`, replacing any provider already
  registered under that name. `provider` is a struct implementing
  `Normandy.Components.ContextProvider`; its `title/1` and `get_info/1` are read each time
  the system prompt is built, into the prompt's "Context" section.
  """
```

Insert before `  @spec delete_context_provider(BaseAgentConfig.t(), atom()) :: BaseAgentConfig.t()`:

```elixir
  @doc """
  Returns `config` without the context provider registered under `name`. Deleting a name
  with no provider returns `config` unchanged.
  """
```

These were checked against the code: `reset_memory/1` puts `initial_memory`, which
`init/1` sets to `:memory` or `AgentMemory.new_memory()` (`base_agent.ex:80-87`).
`SystemPromptGenerator.build_context/2` writes `# Context`, then one `## <title>`
section per provider (`system_prompt_generator.ex:64-77`). `Map.put` and `Map.delete` do the rest.

- [ ] **Step 4: The decision table**

Replace the whole of `lib/normandy.ex` with:

```elixir
defmodule Normandy do
  @moduledoc """
  Normandy builds Claude-powered agents in Elixir: typed I/O schemas, tools,
  conversation memory, hooks, guardrails and durable turns.

  Define inputs and outputs with `Normandy.Schema`, then pick an entry point.

  ## Choosing an entry point

  | Use | When | The conversation lives in | Survives a process or node restart |
  |---|---|---|---|
  | `Normandy.Agents.BaseAgent` | You call the agent from your own code: a script, a request handler, a test. `init/1`, then `run/3` or `stream/3`. | the `BaseAgentConfig` value `run/3` returns | no |
  | `Normandy.DSL.Agent` | The same, with the agent declared once in a module (`MyAgent.new/1`, `MyAgent.run/2`). | the `BaseAgentConfig` value | no |
  | `Normandy.Coordination.AgentProcess` | Other processes call one agent, one turn at a time, through a supervised process. | the process | no; with `turn_engine: :server` and a durable store, yes |
  | `Normandy.Agents.Turn.Session` | Conversations outlive a process or a node; tool calls can wait for approval. | a `Normandy.Behaviours.SessionStore` | yes, with a durable store |

  See the guides for tools, memory, hooks and distributed sessions.
  """
end
```

The facts behind the rows: DSL agents generate `new/1` (returns the `BaseAgentConfig`) and
`run/2,3` (`dsl/agent.ex:573`, `:598`). AgentProcess's `:server` engine routes turns through
`Turn.Session`, but without `:store` it starts an in-memory store
(`coordination/agent_process.ex:49-70`), hence "with a durable store". A Postgres, Mnesia
or Redis `SessionStore` is durable; InMemory and ETS are not.

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix format && mix test test/docs/doc_coverage_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite.

- [ ] **Step 7: MIGRATING-2.0.md**

No entry (docs only).

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/agents/base_agent.ex lib/normandy.ex test/docs/doc_coverage_test.exs
git commit -m "docs(agents): document the last BaseAgent functions; choosing an entry point"
```

---

### Task 7.3b: `Normandy.Test.FakeClient`, a scripted model client in the package (DX-8, decision 27 D1)

Today a user who tests an agent without the network must implement `Normandy.Agents.Model`
themselves. That means:

- the `response_model`-filling convention;
- hand-written SSE event maps for streaming;
- protocol consolidation, since a `defimpl` in a `.exs` test file is not dispatched once
  protocols are consolidated (inventory §2.2).

Normandy's own suite has 40 inline `defimpl`s for that reason.

This task ships `Normandy.Test.FakeClient` in `lib/`:

- It answers from a script, in call order, from any process on the node.
- It records every `%Normandy.LLM.Request{}`.
- It works on every turn path: `BaseAgent.run/3` (over `Turn.Driver`), `BaseAgent.stream/3`, an `AgentProcess` worker,
  `Turn.Inline` (through `Normandy.LLM.Call`) and `Turn.Server` (through `Turn.Session`).

The test covers each path. It also adds the decision 27 D1 rule as a test: `test/support`
never defines a module name `lib/` ships.

The diff is about 900 lines: the module with its docs (~470) and its test (~380). It is
one task because the module and its tests cannot be reviewed apart. No behaviour outside
the new module changes, no telemetry event is added (decision 27 A2), and no wire bytes
change.

**Files:**
- Create: `lib/normandy/test/fake_client.ex` (`Normandy.Test.FakeClient`, `Normandy.Test.FakeClient.ScriptExhaustedError`, the `Normandy.Agents.Model` implementation)
- Create: `test/normandy/test/fake_client_test.exs`
- Create: `test/normandy/test/shipped_names_test.exs`
- Modify: `test/options_coverage_test.exs` (`@validated`)
- Modify: `mix.exs` (the "Testing" group of `groups_for_modules`, created by Task 7.2b)
- Modify: `MIGRATING-2.0.md` (append to `## 45. Testing support and docs`, created by Task 7.2a)

**Interfaces:**
- Consumes:
  - `Normandy.Agents.Model`: the "Response content" and "Stream events" contract, `model.ex:16-65`.
  - `Normandy.LLM.Request`, `Normandy.LLM.Response`, `Normandy.Agents.ToolCallResponse` (fields `content`, `tool_calls`, `stop_reason`) and `Normandy.Components.ToolCall`.
  - `Normandy.LLM.ParseFailure.parse_text_output/3`. It is `@moduledoc false`, "shared by every adapter", and gives the adapter's `:on_parse_failure` semantics.
  - `Normandy.LLM.Call.stop_reason/1`, `Normandy.Options.validate!/3`, `Normandy.Options.docs/1`, `Normandy.Options.plain_map/1` and `Normandy.JSON.encode!/1`.
  - The "Testing" group in `mix.exs` (Task 7.2b).
- Produces (the header's shared interface, exact API):
  - `Normandy.Test.FakeClient.new(script, opts \\ []) :: t()`. The only option is `:options`, a plain map, default `%{}`. A bad option raises through `Normandy.Options.validate!/3`.
  - Script items:
    - `{:text, binary | [binary, ...]}`
    - `{:structured, map}`
    - `{:tool_calls, [{name :: binary, input :: map} | %ToolCall{}, ...]}`
    - each of the three above with a keyword list as a third element: `:stop_reason`, `:usage`, `:stream_error_after`
    - `{:error, %Normandy.LLMError{}}`
    - `(Normandy.LLM.Request.t() -> item)`
  - A generated tool call id is `"toolu_fake_<request index>_<position>"`.
  - `Normandy.Test.FakeClient.requests(client) :: [Normandy.LLM.Request.t()]`, oldest first.
  - `Normandy.Test.FakeClient.remaining(client) :: non_neg_integer()`.
  - `Normandy.Test.FakeClient.ScriptExhaustedError`, with fields `index` and `scripted`. The message is `"Normandy.Test.FakeClient: request N has no scripted reply (M scripted); add an item to the script passed to new/2"`.
  - `@doc false` `next!/2`, `response/4` and `events/3`, called only by the `Model` implementation.
- Tagged suites: none (no store, registry or persistence change).

- [ ] **Step 1: Write the failing tests**

Create `test/normandy/test/fake_client_test.exs`:

```elixir
defmodule Normandy.Test.FakeClientTest do
  @moduledoc """
  Task 7.3b (DX-8): the shipped `Normandy.Test.FakeClient` answers scripted replies on
  every turn path (`run/3` over `Turn.Driver`, `stream/3`, `Turn.Inline`, `Turn.Server`
  through `Turn.Session`, an `AgentProcess` worker), records every request, and refuses a
  bad script by name.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver
  alias Normandy.Agents.Turn.Inline
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Components.ToolCall
  alias Normandy.Coordination.AgentProcess
  alias Normandy.LLM.Call
  alias Normandy.LLM.Request
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.FakeClient.ScriptExhaustedError
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  defmodule Weather do
    use Normandy.Tool, name: "weather", description: "The weather in a city"

    defstruct []

    @impl Normandy.Tool
    def input_schema(_tool),
      do: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]}

    @impl Normandy.Tool
    def run(_tool, %Normandy.Tools.Context{input: %{"city" => city}}),
      do: {:ok, "cold in #{city}"}
  end

  defmodule Answer do
    use Normandy.Schema

    io_schema "An answer" do
      field(:answer, :string, required: true)
      field(:confidence, :float)
    end
  end

  defp agent(client, extra \\ %{}),
    do: BaseAgent.init(Map.merge(%{client: client, model: "claude-opus-5-5"}, extra))

  defp tool_agent(client, extra \\ %{}),
    do: client |> agent(extra) |> BaseAgent.register_tool(%Weather{})

  defp weather_round, do: {:tool_calls, [{"weather", %{"city" => "Oslo"}}]}

  defp collect, do: fn event -> send(self(), {:event, event}) end

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp tool_result_ids(%Request{messages: messages}) do
    for %{role: "tool", content: blocks} <- messages, %{tool_use_id: id} <- blocks, do: id
  end

  describe "run/3 (Turn.Driver)" do
    test "a text reply is the chat answer and the request is recorded" do
      client = FakeClient.new([{:text, "Hello there"}])

      assert {:ok, _agent, %BaseAgentOutputSchema{chat_message: "Hello there"}} =
               BaseAgent.run(agent(client, %{max_tokens: 512}), "hi")

      assert [%Request{model: "claude-opus-5-5", max_tokens: 512, messages: [user]}] =
               FakeClient.requests(client)

      assert user.role == "user"
      assert FakeClient.remaining(client) == 0
    end

    test "a tool round then a text answer runs the tool with a generated call id" do
      client = FakeClient.new([weather_round(), {:text, "It is cold."}])

      assert {:ok, agent, %{chat_message: "It is cold."}} =
               BaseAgent.run(tool_agent(client), "weather?")

      assert ["user", "assistant", "tool", "assistant"] =
               agent.memory |> AgentMemory.messages() |> Enum.map(& &1.role)

      assert [first, second] = FakeClient.requests(client)
      assert first.response_model == %ToolCallResponse{}
      assert [%{name: "weather"}] = first.tools
      assert tool_result_ids(second) == ["toolu_fake_0_0"]
    end

    test "a %ToolCall{} keeps its id" do
      call = %ToolCall{id: "call_1", name: "weather", input: %{"city" => "Rome"}}
      client = FakeClient.new([{:tool_calls, [call]}, {:text, "Warm."}])

      assert {:ok, _agent, %{chat_message: "Warm."}} = BaseAgent.run(tool_agent(client), "q")
      assert [_, second] = FakeClient.requests(client)
      assert tool_result_ids(second) == ["call_1"]
    end

    test "a structured reply fills the output schema, with and without tools" do
      plain = FakeClient.new([{:structured, %{answer: "42", confidence: 0.9}}])

      assert {:ok, _agent, %Answer{answer: "42", confidence: 0.9}} =
               BaseAgent.run(agent(plain, %{output_schema: %Answer{}}), "q")

      tools = FakeClient.new([weather_round(), {:structured, %{answer: "cold"}}])

      assert {:ok, _agent, %Answer{answer: "cold", confidence: nil}} =
               BaseAgent.run(tool_agent(tools, %{output_schema: %Answer{}}), "q")
    end

    test "a text reply is parsed into a non-chat schema; one that is not JSON follows on_parse_failure" do
      ok = FakeClient.new([{:text, ~s({"answer": "42"})}])

      assert {:ok, _agent, %Answer{answer: "42"}} =
               BaseAgent.run(agent(ok, %{output_schema: %Answer{}}), "q")

      bad = FakeClient.new([{:text, "not json"}], options: %{on_parse_failure: :error})

      assert {:error, %LLMError{type: :invalid_output}} =
               BaseAgent.run(agent(bad, %{output_schema: %Answer{}}), "q")
    end

    test "an error reply is returned, and retried when retryable" do
      rate_limited = LLMError.new(type: :rate_limit, retryable?: true)
      client = FakeClient.new([{:error, rate_limited}, {:text, "after retry"}])
      retrying = agent(client, %{retry: [max_attempts: 2, base_delay: 1]})

      assert {:ok, _agent, %{chat_message: "after retry"}} = BaseAgent.run(retrying, "q")
      assert length(FakeClient.requests(client)) == 2

      denied = LLMError.new(type: :authentication, retryable?: false)

      assert {:error, %LLMError{type: :authentication}} =
               BaseAgent.run(agent(FakeClient.new([{:error, denied}])), "q")
    end

    test "stop_reason: :max_tokens is the :max_tokens error; usage is reported" do
      cut = FakeClient.new([{:text, "par", stop_reason: :max_tokens, usage: %{output_tokens: 7}}])

      assert {:error, %LLMError{type: :max_tokens, usage: %{output_tokens: 7}}} =
               BaseAgent.run(agent(cut), "q")
    end

    test "a function item receives the request" do
      client =
        FakeClient.new([
          fn %Request{tool_choice: choice} -> {:text, "tool_choice=#{inspect(choice)}"} end
        ])

      assert {:ok, _agent, %{chat_message: "tool_choice=nil"}} = BaseAgent.run(agent(client), "q")
    end

    test "Turn.Driver with the non-streaming handlers" do
      client = FakeClient.new([weather_round(), {:text, "Driven."}])
      config = client |> tool_agent() |> BaseAgent.admit_turn_input("q")

      state =
        Turn.new(
          max_iterations: 5,
          response_model: %ToolCallResponse{},
          output_schema: config.output_schema
        )

      assert {_config, %Turn.State{status: :stopped, final_response: final}} =
               Driver.drive(state, BaseAgent.non_streaming_handlers(), config)

      assert %BaseAgentOutputSchema{chat_message: "Driven."} = final
      assert length(FakeClient.requests(client)) == 2
    end
  end

  describe "stream/3" do
    test "a tool round then a text answer in chunks, delivered as events" do
      client = FakeClient.new([weather_round(), {:text, ["Co", "ld."]}])

      assert {:ok, _agent, %{chat_message: "Cold."}} =
               BaseAgent.stream(tool_agent(client), "q", collect())

      deltas = for %StreamEvent{type: :text_delta, data: data} <- events(), do: data
      assert deltas == ["Co", "ld."]
      assert [_, second] = FakeClient.requests(client)
      assert tool_result_ids(second) == ["toolu_fake_0_0"]
    end

    test "a structured reply fills the output schema" do
      client = FakeClient.new([{:structured, %{answer: "42"}}])

      assert {:ok, _agent, %Answer{answer: "42"}} =
               BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
    end

    test "stream_error_after ends the stream in a transport error after that many deltas" do
      client = FakeClient.new([{:text, ["ab", "cd"], stream_error_after: 1}])

      assert {:error, %LLMError{type: :stream}} = BaseAgent.stream(agent(client), "q", collect())

      assert [%StreamEvent{type: :message_start}, %StreamEvent{type: :text_delta, data: "ab"}] =
               events()
    end

    test "an error reply and a cut-off answer are errors" do
      overloaded = LLMError.new(type: :overloaded, retryable?: false)

      assert {:error, %LLMError{type: :overloaded}} =
               BaseAgent.stream(agent(FakeClient.new([{:error, overloaded}])), "q", collect())

      refused = FakeClient.new([{:text, "", stop_reason: :refusal}])

      assert {:error, %LLMError{type: :refusal}} =
               BaseAgent.stream(agent(refused), "q", collect())
    end
  end

  describe "Turn.Inline" do
    test "the client answers the inline shell's calls through Normandy.LLM.Call" do
      client = FakeClient.new([weather_round(), {:text, "Inline."}])
      config = tool_agent(client)

      call_llm = fn _turn_request ->
        request = %Request{
          model: config.model,
          messages: [],
          max_tokens: 64,
          tools: Toolset.to_tool_schemas(config.toolset),
          response_model: %ToolCallResponse{}
        }

        {:ok, response} = Call.converse(client, request, [])
        {:ok, response.content}
      end

      deps = %{
        call_llm: call_llm,
        dispatch: fn calls ->
          Enum.map(
            calls,
            &Dispatch.dispatch_one(config, &1, BaseAgent.base_agent_pipeline(config))
          )
        end
      }

      assert {:ok, %Turn.State{stop_reason: :completed, final_response: final}} =
               Inline.run(Turn.new(max_iterations: 5, response_model: :rm), deps)

      assert %ToolCallResponse{content: "Inline.", stop_reason: :end_turn} = final
      assert FakeClient.remaining(client) == 0
    end
  end

  describe "Turn.Server through Turn.Session" do
    setup do
      store = InMemory.new()
      session_id = "fake-#{System.unique_integer([:positive])}"

      %{
        store: store,
        session_id: session_id,
        opts: [
          session_id: session_id,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          supervisor: start_supervised!(Turn.Supervisor)
        ]
      }
    end

    test "two turns take three replies from the server's worker processes", ctx do
      client = FakeClient.new([weather_round(), {:text, "Cold."}, {:text, "Second turn."}])
      session = Turn.Session.new([config: tool_agent(client)] ++ ctx.opts)

      assert {:ok, %{chat_message: "Cold."}} = Turn.Session.run(session, "weather?")
      assert {:ok, %{chat_message: "Second turn."}} = Turn.Session.run(session, "again")

      assert {:ok, history} = InMemory.history(ctx.store, ctx.session_id)

      assert ["user", "assistant", "tool", "assistant", "user", "assistant"] =
               Enum.map(history, & &1.role)

      assert length(FakeClient.requests(client)) == 3
    end

    test "an exhausted script is a :task_down TurnError carrying the exception", ctx do
      session = Turn.Session.new([config: agent(FakeClient.new([]))] ++ ctx.opts)

      assert {:error,
              %TurnError{type: :task_down, reason: %ScriptExhaustedError{index: 0, scripted: 0}}} =
               Turn.Session.run(session, "q")
    end
  end

  describe "AgentProcess" do
    test "the inline engine's worker process takes the replies" do
      client = FakeClient.new([weather_round(), {:text, "From a process."}])
      pid = start_supervised!({AgentProcess, agent: tool_agent(client)})

      assert {:ok, "From a process."} = AgentProcess.run(pid, "q")
      assert FakeClient.remaining(client) == 0
    end
  end

  describe "the script" do
    test "a request past the last item raises ScriptExhaustedError" do
      client = FakeClient.new([{:text, "one"}])
      assert {:ok, _agent, _} = BaseAgent.run(agent(client), "q")

      error = assert_raise ScriptExhaustedError, fn -> BaseAgent.run(agent(client), "q") end

      assert Exception.message(error) ==
               "Normandy.Test.FakeClient: request 1 has no scripted reply (1 scripted); " <>
                 "add an item to the script passed to new/2"

      assert length(FakeClient.requests(client)) == 2
    end

    test "with retry:, every retry of the raise takes a request index" do
      client = FakeClient.new([])
      retrying = agent(client, %{retry: [max_attempts: 2, base_delay: 1]})

      assert_raise ScriptExhaustedError, fn -> BaseAgent.run(retrying, "q") end
      assert length(FakeClient.requests(client)) == 2
    end

    test "a misspelled item is named" do
      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient.new/2: script item 1 is {:txt, \"hi\"}; expected " <>
                     "{:text, text}, {:structured, map}, {:tool_calls, calls} (each with an " <>
                     "optional keyword list of :stop_reason, :usage, :stream_error_after), " <>
                     "{:error, %Normandy.LLMError{}} or a 1-arity function",
                   fn -> FakeClient.new([{:text, "ok"}, {:txt, "hi"}]) end
    end

    test "an unknown item option, a bad tool call and a bad option are named" do
      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient.new/2: script item 0 has unknown option " <>
                     ":stop; supported: :stop_reason, :usage, :stream_error_after",
                   fn -> FakeClient.new([{:text, "x", stop: :max_tokens}]) end

      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient.new/2: script item 0 is a :tool_calls reply " <>
                     "with the call {:weather, %{}}; expected {name, input} (a binary and a " <>
                     "map) or a %Normandy.Components.ToolCall{}",
                   fn -> FakeClient.new([{:tool_calls, [{:weather, %{}}]}]) end

      assert_raise ArgumentError,
                   ~r/^Normandy.Test.FakeClient.new\/2: unknown option :notify/,
                   fn -> FakeClient.new([], notify: self()) end
    end

    test "a function item that returns a bad item raises when called" do
      client = FakeClient.new([fn _request -> :oops end])

      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient: the function at script item 0 returned an item " <>
                     "that is :oops; expected {:text, text}, {:structured, map}, " <>
                     "{:tool_calls, calls} (each with an optional keyword list of " <>
                     ":stop_reason, :usage, :stream_error_after), " <>
                     "{:error, %Normandy.LLMError{}} or a 1-arity function",
                   fn -> BaseAgent.run(agent(client), "q") end
    end

    test "tool calls to an agent without tools raise on run/3 and stream/3" do
      message =
        "Normandy.Test.FakeClient: script item 0 is a :tool_calls reply, but request 0 " <>
          "lists no tools; only an agent with tools receives tool calls (register a tool, " <>
          "or script a :text or :structured reply)"

      assert_raise ArgumentError, message, fn ->
        BaseAgent.run(agent(FakeClient.new([weather_round()])), "q")
      end

      assert_raise ArgumentError, message, fn ->
        BaseAgent.stream(agent(FakeClient.new([weather_round()])), "q", collect())
      end
    end
  end
end
```

Create `test/normandy/test/shipped_names_test.exs` (it reads sources: when `lib/` and
`test/support` define the same name, only one module survives compilation, so a runtime
check cannot see the clash):

```elixir
defmodule Normandy.Test.ShippedNamesTest do
  @moduledoc """
  Decision 27 D1: `lib/` ships `Normandy.Test.*` modules, and `test/support` (compiled into
  the same app in the test env) never defines a module name `lib/` ships. Reads the
  sources: when both define a name, only one module survives compilation.
  """
  use ExUnit.Case, async: true

  defp defined_modules(glob) do
    glob
    |> Path.wildcard()
    |> Enum.flat_map(fn path -> path |> File.read!() |> Code.string_to_quoted!() |> walk([]) end)
    |> MapSet.new()
  end

  # Every `defmodule` name, nested ones under their parent's name.
  defp walk({:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, prefix) do
    name = prefix ++ parts
    [Module.concat(name) | walk(body, name)]
  end

  defp walk({left, _meta, args}, prefix) when is_list(args),
    do: walk(left, prefix) ++ Enum.flat_map(args, &walk(&1, prefix))

  defp walk({left, right}, prefix), do: walk(left, prefix) ++ walk(right, prefix)
  defp walk(list, prefix) when is_list(list), do: Enum.flat_map(list, &walk(&1, prefix))
  defp walk(_other, _prefix), do: []

  test "test/support defines no module that lib/ ships" do
    shipped = defined_modules("lib/**/*.ex")
    support = defined_modules("test/support/**/*.ex")

    # The walk finds both sides' modules, nested ones included.
    assert Normandy.Test.FakeClient in shipped
    assert Normandy.Test.FakeClient.ScriptExhaustedError in shipped
    assert Normandy.Test.StubClient in support

    assert MapSet.intersection(shipped, support) == MapSet.new()
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/normandy/test/fake_client_test.exs` and then
`mix test test/normandy/test/shipped_names_test.exs`
Expected: FAIL.
- The first fails to compile: `error: Normandy.Test.FakeClient.ScriptExhaustedError.__struct__/1 is undefined, cannot expand struct Normandy.Test.FakeClient.ScriptExhaustedError`.
- The second fails on `assert Normandy.Test.FakeClient in shipped`.

- [ ] **Step 3: The module**

Create `lib/normandy/test/fake_client.ex`:

```elixir
defmodule Normandy.Test.FakeClient do
  @moduledoc """
  A scripted model client for tests: no network, no API key, no `Normandy.Agents.Model`
  implementation of your own.

  `new/2` takes the replies in call order. Each request takes the next one, whichever
  process makes it (`Normandy.Agents.BaseAgent.run/3`, `Normandy.Agents.BaseAgent.stream/3`,
  a `Normandy.Agents.Turn.Session`'s server, a `Normandy.Coordination.AgentProcess`), as
  long as it runs on the node that built the client. `requests/1` returns every request
  received so far, oldest first, as `Normandy.LLM.Request` structs.

      client =
        Normandy.Test.FakeClient.new([
          {:tool_calls, [{"weather", %{"city" => "Oslo"}}]},
          {:text, "Cold."}
        ])

      agent =
        Normandy.Agents.BaseAgent.init(client: client, model: "claude-opus-5-5")
        |> Normandy.Agents.BaseAgent.register_tool(%MyApp.WeatherTool{})

      {:ok, _agent, %{chat_message: "Cold."}} =
        Normandy.Agents.BaseAgent.run(agent, "Weather in Oslo?")

      [_tool_round, final_request] = Normandy.Test.FakeClient.requests(client)

  ## Script items

    * `{:text, text}` - the answer text. `text` is a binary, or a list of binaries that
      `stream/3` sends as one text delta each (`converse/3` joins them). For an output
      schema other than the chat schema, the text is parsed into it as JSON, as the
      Claudio adapter parses a model's text (the client's `:on_parse_failure` applies).
    * `{:structured, map}` - a structured answer: `map` encoded as JSON, then parsed into
      the request's response model, or sent as the text of a tool loop's final answer.
    * `{:tool_calls, calls}` - one or more tool calls. Each call is `{name, input}` (its
      id is `"toolu_fake_<request>_<position>"`, both counted from 0) or a
      `%Normandy.Components.ToolCall{}` used as given. Only a request that lists tools
      takes them: scripted for one that lists none, they raise.
    * `{:error, %Normandy.LLMError{}}` - the call fails with that error; its `retryable?`
      decides whether a configured `retry:` resends the request.
    * a 1-arity function - called with the `%Normandy.LLM.Request{}`; returns one of the
      items above.

  `:text`, `:structured` and `:tool_calls` take a keyword list as a third element:

    * `:stop_reason` - the response's stop reason (default `:tool_use` for tool calls,
      `:end_turn` otherwise). `:max_tokens` and `:refusal` make Normandy return
      `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`.
    * `:usage` - the usage map the response reports (default `nil`, no usage), for
      example `%{input_tokens: 12, output_tokens: 3}`.
    * `:stream_error_after` - streaming only: the stream ends in a transport error after
      this many content deltas (at its end when the reply has fewer).

  `new/2` checks every item and raises `ArgumentError` naming the first bad one.

  ## The end of the script

  A request past the last item raises `Normandy.Test.FakeClient.ScriptExhaustedError`:
  `run/3` and `stream/3` raise it, and a `Normandy.Agents.Turn.Server` replies
  `{:error, %Normandy.TurnError{type: :task_down}}` whose `reason` is the exception. With
  `retry:` configured, BaseAgent retries a raised call, so each retry takes a request
  index too. `remaining/1` tells how many items no request has taken.

  The requests live in an ETS table owned by the process that called `new/2`: build the
  client in the test process, not in `setup_all` or a task that exits before the test
  ends.
  """

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall
  alias Normandy.LLM.Call
  alias Normandy.LLM.ParseFailure
  alias Normandy.LLM.Request
  alias Normandy.LLM.Response
  alias Normandy.LLMError

  defmodule ScriptExhaustedError do
    @moduledoc "A `Normandy.Test.FakeClient` received more requests than it has script items."
    defexception [:index, :scripted]

    @impl true
    def message(%__MODULE__{index: index, scripted: scripted}),
      do:
        "Normandy.Test.FakeClient: request #{index} has no scripted reply " <>
          "(#{scripted} scripted); add an item to the script passed to new/2"
  end

  @enforce_keys [:script, :counter, :table]
  defstruct [:script, :counter, :table, options: %{}]

  @type call :: {String.t(), map()} | ToolCall.t()
  @type item_opts :: [
          stop_reason: Response.stop_reason(),
          usage: map() | nil,
          stream_error_after: non_neg_integer()
        ]
  @type item ::
          {:text, String.t() | [String.t()]}
          | {:text, String.t() | [String.t()], item_opts()}
          | {:structured, map()}
          | {:structured, map(), item_opts()}
          | {:tool_calls, [call(), ...]}
          | {:tool_calls, [call(), ...], item_opts()}
          | {:error, LLMError.t()}
          | (Request.t() -> item())

  @type t :: %__MODULE__{
          script: tuple(),
          counter: :atomics.atomics_ref(),
          table: :ets.tid(),
          options: map()
        }

  @new_schema NimbleOptions.new!(
                options: [
                  type: {:custom, Normandy.Options, :plain_map, []},
                  default: %{},
                  doc:
                    "The client's `options` map, read as a real client's would be (for " <>
                      "example `%{on_parse_failure: :error}`)."
                ]
              )

  @item_opts [:stop_reason, :usage, :stream_error_after]

  @doc """
  A client that answers its requests with `script`, in order.

  ## Options

  #{Normandy.Options.docs(@new_schema)}
  """
  @spec new([item()], keyword()) :: t()
  def new(script, opts \\ [])

  def new(script, opts) when is_list(script) do
    opts = Normandy.Options.validate!(opts, @new_schema, {__MODULE__, :new, 2})

    script
    |> Enum.with_index()
    |> Enum.each(fn {item, index} ->
      check_item!(item, "Normandy.Test.FakeClient.new/2: script item #{index}")
    end)

    %__MODULE__{
      script: List.to_tuple(script),
      counter: :atomics.new(1, []),
      table: :ets.new(__MODULE__, [:ordered_set, :public]),
      options: Keyword.fetch!(opts, :options)
    }
  end

  def new(script, _opts) do
    raise ArgumentError,
          "Normandy.Test.FakeClient.new/2: expected the script as a list of items, got: " <>
            inspect(script, limit: 5)
  end

  @doc "Every request the client received, oldest first."
  @spec requests(t()) :: [Request.t()]
  def requests(%__MODULE__{table: table}),
    do: table |> :ets.tab2list() |> Enum.map(fn {_index, request} -> request end)

  @doc "How many script items no request has taken yet."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{script: script, counter: counter}),
    do: max(tuple_size(script) - :atomics.get(counter, 1), 0)

  @doc false
  # The item for the next request, which is recorded first. Called by the Model impl.
  @spec next!(t(), Request.t()) :: {non_neg_integer(), item()}
  def next!(%__MODULE__{} = client, %Request{} = request) do
    index = :atomics.add_get(client.counter, 1, 1) - 1
    true = :ets.insert(client.table, {index, request})

    if index >= tuple_size(client.script) do
      raise ScriptExhaustedError, index: index, scripted: tuple_size(client.script)
    end

    case elem(client.script, index) do
      fun when is_function(fun, 1) ->
        item = fun.(request)

        check_item!(
          item,
          "Normandy.Test.FakeClient: the function at script item #{index} returned an item that"
        )

        {index, item}

      item ->
        {index, item}
    end
  end

  @doc false
  # The %Response{} for an item on converse/3.
  @spec response(t(), Request.t(), non_neg_integer(), item()) ::
          {:ok, Response.t()} | {:error, LLMError.t()}
  def response(_client, _request, _index, {:error, %LLMError{} = error}), do: {:error, error}

  def response(client, request, index, item) do
    {kind, value, opts} = split(item)
    check_tools!(request, kind, index)
    stop_reason = Keyword.get(opts, :stop_reason, default_stop(kind))

    case fill(client, request.response_model, kind, value, index, stop_reason) do
      {:error, %LLMError{}} = error ->
        error

      content ->
        {:ok, %Response{content: content, stop_reason: stop_reason, usage: opts[:usage]}}
    end
  end

  @doc false
  # The stream events for an item on stream/3.
  @spec events(Request.t(), non_neg_integer(), item()) :: {:ok, list()} | {:error, LLMError.t()}
  def events(_request, _index, {:error, %LLMError{} = error}), do: {:error, error}

  def events(request, index, item) do
    {kind, value, opts} = split(item)
    check_tools!(request, kind, index)
    stop_reason = opts |> Keyword.get(:stop_reason, default_stop(kind)) |> to_string()
    blocks = stream_blocks(kind, value, index)

    events =
      [
        %{
          type: "message_start",
          message: %{
            "id" => "msg_fake_#{index}",
            "type" => "message",
            "role" => "assistant",
            "model" => request.model,
            "content" => []
          }
        }
      ] ++
        blocks ++
        [
          %{
            type: "message_delta",
            delta: %{"stop_reason" => stop_reason},
            usage: stringify(opts[:usage])
          },
          %{type: "message_stop"}
        ]

    {:ok, cut_stream(events, Keyword.get(opts, :stream_error_after))}
  end

  defp split({kind, value}), do: {kind, value, []}
  defp split({kind, value, opts}), do: {kind, value, opts}

  defp check_tools!(%Request{tools: []}, :tool_calls, index) do
    raise ArgumentError,
          "Normandy.Test.FakeClient: script item #{index} is a :tool_calls reply, but request " <>
            "#{index} lists no tools; only an agent with tools receives tool calls " <>
            "(register a tool, or script a :text or :structured reply)"
  end

  defp check_tools!(_request, _kind, _index), do: :ok

  defp default_stop(:tool_calls), do: :tool_use
  defp default_stop(_kind), do: :end_turn

  defp fill(_client, %ToolCallResponse{} = model, :tool_calls, calls, index, stop),
    do: %{model | tool_calls: tool_calls(calls, index), stop_reason: stop}

  defp fill(_client, model, :tool_calls, _calls, index, _stop) do
    raise ArgumentError,
          "Normandy.Test.FakeClient: script item #{index} is a :tool_calls reply, but request " <>
            "#{index} expects #{describe_model(model)}; only an agent with tools receives " <>
            "tool calls (register a tool, or script a :text or :structured reply)"
  end

  defp fill(client, model, :structured, map, index, stop),
    do: fill(client, model, :text, Normandy.JSON.encode!(map), index, stop)

  defp fill(_client, nil, :text, text, _index, _stop), do: IO.iodata_to_binary(text)

  defp fill(_client, %ToolCallResponse{} = model, :text, text, _index, stop),
    do: %{model | content: IO.iodata_to_binary(text), stop_reason: stop}

  defp fill(_client, %{chat_message: _} = model, :text, text, _index, _stop),
    do: %{model | chat_message: IO.iodata_to_binary(text)}

  # A cut-off or refused answer is not parsed (Normandy turns it into an error).
  defp fill(client, %_{} = model, :text, text, _index, stop) do
    if Call.stop_reason(stop) in [:max_tokens, :model_context_window_exceeded, :refusal],
      do: model,
      else: ParseFailure.parse_text_output(%{client: client}, IO.iodata_to_binary(text), model)
  end

  defp tool_calls(calls, index) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn
      {%ToolCall{} = call, _position} ->
        call

      {{name, input}, position} ->
        %ToolCall{id: "toolu_fake_#{index}_#{position}", name: name, input: input}
    end)
  end

  defp stream_blocks(:tool_calls, calls, index) do
    calls
    |> tool_calls(index)
    |> Enum.with_index()
    |> Enum.flat_map(fn {call, position} ->
      block(
        position,
        %{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => %{}},
        [%{"type" => "input_json_delta", "partial_json" => Normandy.JSON.encode!(call.input)}]
      )
    end)
  end

  defp stream_blocks(:structured, map, index),
    do: stream_blocks(:text, Normandy.JSON.encode!(map), index)

  defp stream_blocks(:text, text, _index) do
    chunks = if is_list(text), do: text, else: [text]

    block(
      0,
      %{"type" => "text", "text" => ""},
      Enum.map(chunks, &%{"type" => "text_delta", "text" => &1})
    )
  end

  defp block(index, start, deltas) do
    [%{type: "content_block_start", index: index, content_block: start}] ++
      Enum.map(deltas, &%{type: "content_block_delta", index: index, delta: &1}) ++
      [%{type: "content_block_stop", index: index}]
  end

  # The events up to the n-th content delta, then a transport error.
  defp cut_stream(events, nil), do: events

  defp cut_stream(events, n) do
    {kept, _rest} =
      Enum.reduce_while(events, {[], 0}, fn
        %{type: "content_block_delta"}, {acc, ^n} -> {:halt, {acc, n}}
        %{type: "content_block_delta"} = event, {acc, seen} -> {:cont, {[event | acc], seen + 1}}
        event, {acc, seen} -> {:cont, {[event | acc], seen}}
      end)

    Enum.reverse([{:error, :closed} | kept])
  end

  defp stringify(nil), do: nil
  defp stringify(usage), do: Map.new(usage, fn {key, value} -> {to_string(key), value} end)

  defp describe_model(nil), do: "a text answer (response_model nil)"
  defp describe_model(%module{}), do: "%#{inspect(module)}{}"

  # ── Script checks ─────────────────────────────────────────────────────────────

  @shape "expected {:text, text}, {:structured, map}, {:tool_calls, calls} (each with an " <>
           "optional keyword list of :stop_reason, :usage, :stream_error_after), " <>
           "{:error, %Normandy.LLMError{}} or a 1-arity function"

  defp check_item!(fun, _where) when is_function(fun, 1), do: :ok
  defp check_item!({:error, %LLMError{}}, _where), do: :ok

  defp check_item!({kind, value}, where) when kind in [:text, :structured, :tool_calls],
    do: check_value!(kind, value, where)

  defp check_item!({kind, value, opts} = item, where)
       when kind in [:text, :structured, :tool_calls] do
    check_value!(kind, value, where)
    check_opts!(opts, item, where)
  end

  defp check_item!(item, where), do: bad!(where, "is #{inspect(item, limit: 5)}; #{@shape}")

  defp check_value!(:text, text, _where) when is_binary(text), do: :ok

  defp check_value!(:text, [_ | _] = chunks, where) do
    if Enum.all?(chunks, &is_binary/1),
      do: :ok,
      else: bad!(where, "is a :text reply whose list holds a non-binary chunk")
  end

  defp check_value!(:structured, map, _where) when is_map(map) and not is_struct(map), do: :ok

  defp check_value!(:tool_calls, [_ | _] = calls, where) do
    case Enum.find(calls, &(not call?(&1))) do
      nil ->
        :ok

      call ->
        bad!(
          where,
          "is a :tool_calls reply with the call #{inspect(call, limit: 5)}; expected " <>
            "{name, input} (a binary and a map) or a %Normandy.Components.ToolCall{}"
        )
    end
  end

  defp check_value!(kind, value, where),
    do: bad!(where, "is a #{inspect(kind)} reply with #{inspect(value, limit: 5)}; #{@shape}")

  defp call?({name, input}) when is_binary(name) and is_map(input), do: true
  defp call?(%ToolCall{}), do: true
  defp call?(_call), do: false

  defp check_opts!(opts, item, where) do
    unless Keyword.keyword?(opts),
      do: bad!(where, "is #{inspect(item, limit: 5)}; its third element must be a keyword list")

    case Keyword.keys(opts) -- @item_opts do
      [] -> :ok
      [key | _] -> bad!(where, "has unknown option #{inspect(key)}; supported: #{supported()}")
    end

    check_opt!(:stop_reason, opts[:stop_reason], &(is_atom(&1) or is_binary(&1)), where)
    check_opt!(:usage, opts[:usage], &(is_nil(&1) or is_map(&1)), where)

    check_opt!(
      :stream_error_after,
      opts[:stream_error_after],
      &(is_nil(&1) or (is_integer(&1) and &1 >= 0)),
      where
    )
  end

  defp check_opt!(_key, nil, _valid?, _where), do: :ok

  defp check_opt!(key, value, valid?, where) do
    if valid?.(value),
      do: :ok,
      else: bad!(where, "has an invalid #{inspect(key)}: #{inspect(value, limit: 5)}")
  end

  defp supported, do: Enum.map_join(@item_opts, ", ", &inspect/1)

  @spec bad!(String.t(), String.t()) :: no_return()
  defp bad!(where, detail), do: raise(ArgumentError, "#{where} #{detail}")

  defimpl Normandy.Agents.Model do
    alias Normandy.Test.FakeClient

    def converse(client, request, _opts) do
      {index, item} = FakeClient.next!(client, request)
      FakeClient.response(client, request, index, item)
    end

    def stream(client, request, _opts) do
      {index, item} = FakeClient.next!(client, request)
      FakeClient.events(request, index, item)
    end
  end
end
```

Notes for the implementer:

- `fill/6` follows the `Model` moduledoc ("Response content"), one rule per `response_model`:
  - `nil`: the text.
  - `%ToolCallResponse{}`: `content` or `tool_calls`, plus `stop_reason`.
  - A `:chat_message` schema: the text, unparsed. A blank text stays blank, so Normandy's
    `:invalid_output` check sees it (`blank_answer_test.exs`).
  - Any other struct: the text parsed by `ParseFailure.parse_text_output/3`, unless the stop
    reason is `:max_tokens`, `:model_context_window_exceeded` or `:refusal`. Then the empty
    response model goes back, as the protocol allows, and Normandy returns the error.
- The stream is Anthropic-ordered events with a string `:type` and string-keyed nested maps
  (`model.ex:57-65`), the shape `StreamProcessor.build_final_message/1` reads
  (`stream_processor.ex:98-146`). The usage map's keys are stringified for the stream only.
- `check_tools!/3` raises for a `:tool_calls` item when the request lists no tools, on both
  paths. Without it, a streamed tool call to a tool-less agent would be dropped by BaseAgent's
  no-tools strip and surface as an unrelated blank-answer error.
- Nothing logs; the only raises are `ArgumentError` (a bad script) and `ScriptExhaustedError`.

- [ ] **Step 4: The options-coverage list**

`test/options_coverage_test.exs` (Ruling 6) fails on any `lib/` file that reads
`Keyword.get(opts` and is in neither list. `FakeClient` reads its script items' options that
way. Its entry point, `new/2`, validates its options with `Normandy.Options.validate!/3`. In
`@validated`, after `"lib/normandy/resilience/circuit_breaker.ex",` insert:

```elixir
    "lib/normandy/test/fake_client.ex",
```

- [ ] **Step 5: The docs group**

Task 7.2b created a `Testing:` group in `mix.exs` `groups_for_modules` (its
`test/docs/docs_groups_test.exs` requires every module with docs in exactly one group). Make
that group contain these two modules, keeping any entry Task 7.2b put there:

```elixir
          Testing: [
            Normandy.Test.FakeClient,
            Normandy.Test.FakeClient.ScriptExhaustedError
          ]
```

The `Model` implementation module (`Normandy.Agents.Model.Normandy.Test.FakeClient`) has
`:hidden` docs (checked with `Code.fetch_docs/1`), so it needs no group.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/normandy/test test/options_coverage_test.exs test/docs`
Expected: PASS. `fake_client_test.exs`: 23 tests; `shipped_names_test.exs`: 1 test.

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; dialyzer passes; docs exit 0.

- [ ] **Step 8: MIGRATING-2.0.md**

Append after the last bullet of `## 45. Testing support and docs` (created by Task 7.2a, ruling R8):

```markdown
- `Normandy.Test.FakeClient` is a model client for tests that answers from a script:
  `FakeClient.new([{:tool_calls, [{"weather", %{"city" => "Oslo"}}]}, {:text, "Cold."}])`.
  Items are text (a list of chunks streams one delta per chunk), structured maps, tool calls,
  `{:error, %Normandy.LLMError{}}` or a function of the request, with optional
  `:stop_reason`, `:usage` and `:stream_error_after`. It works with `BaseAgent.run/3`,
  `stream/3`, `Turn.Session` and `AgentProcess` from any process on the node, needs no
  protocol implementation or `consolidate_protocols: false` of your own and no
  Mox/`Req.Test` allowance, and records every request (`FakeClient.requests/1`). A request
  past the script raises `Normandy.Test.FakeClient.ScriptExhaustedError`.
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/test/fake_client.ex test/normandy/test/fake_client_test.exs \
  test/normandy/test/shipped_names_test.exs test/options_coverage_test.exs mix.exs \
  MIGRATING-2.0.md
git commit -m "feat(test): ship Normandy.Test.FakeClient, a scripted model client"
```

---

### Task 7.3c: Normandy's scripted-client tests run on `FakeClient`; three support clients go (decision 27 D2)

Three `test/support` clients do `FakeClient`'s job:

- `Normandy.Test.ScriptedToolClient`: one tool round, then a fixed answer.
- `Normandy.Test.ScriptedTextClient`: a fixed text, a two-delta stream, a transport error
  after the first delta, and a stream-call counter.
- `Normandy.Test.StreamingProbeClient`: a streamed `probe` tool call, then `"done"`.

Ten test files use them. This task moves those files to `Normandy.Test.FakeClient`, so the
shipped module is exercised by Normandy's own suite, and deletes the three clients.
`StubClient`, `ModelMockup`, `WireScript`, `TaggingClient`, `MockSummarizerClient` and the 40
inline `defimpl`s stay (D2).

No test is added or removed: the ten files hold 106 tests before and after. The only
assertion that changes meaning is the message-start id in `base_agent_stream_test.exs`:
`FakeClient` names its messages `msg_fake_<request>`.

**Files:**
- Delete (`git rm`, one per file): `test/support/scripted_tool_client.ex`, `test/support/scripted_text_client.ex`, `test/support/streaming_probe_client.ex`
- Modify: `test/agents/base_agent_stream_test.exs`, `test/agents/blank_answer_test.exs`, `test/agents/base_agent_output_schema_prompt_test.exs`, `test/agents/tool_context_test.exs`, `test/agents/mid_round_compaction_test.exs`, `test/agents/turn/server_store_failures_test.exs`, `test/a2a/server_limits_test.exs`, `test/hooks/tool_hooks_test.exs`, `test/hooks/llm_compaction_hooks_test.exs`, `test/hooks/base_agent_hooks_test.exs`

**Interfaces:**
- Consumes: `Normandy.Test.FakeClient.new/2`, `requests/1`, the item option `stream_error_after:` and `%ToolCall{}` calls (Task 7.3b).
- Produces: nothing new. `test/support` loses `ScriptedToolClient`, `ScriptedTextClient` and `StreamingProbeClient`.
- Tagged suites: none. `server_store_failures_test.exs` is untagged and uses `InMemory` and its wrappers.

Rewrite rules, used below and for any use an earlier Wave 7 task added:

| Before | After |
|---|---|
| `%ScriptedTextClient{text: t}`, the model asked k times | `FakeClient.new([{:text, t}, ...])`, k items |
| `%ScriptedTextClient{text: t, notify: self()}` + `assert_received {:stream_request, req}` | `client = FakeClient.new([{:text, t}])` + `[req] = FakeClient.requests(client)` |
| `%ScriptedTextClient{..., fail_after_first_delta: true, calls: c}` + `:counters.get(c, 1)` | `FakeClient.new([{:text, [first, rest], stream_error_after: 1}])` + `length(FakeClient.requests(client))` |
| `%ScriptedTextClient{..., options: o}` | `FakeClient.new([...], options: o)` |
| `%ScriptedToolClient{calls: calls}`, per turn the agent runs | `{:tool_calls, calls}, {:text, "done"}` per turn |
| `%StreamingProbeClient{}` | `FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}])` (with `%ToolCall{id: "call_1", name: "probe", input: %{}}` where a test asserts that id) |
| a client the test never calls (option checks, dispatch-only tests) | `FakeClient.new([])` |

- [ ] **Step 1: Delete the three clients (the failing step)**

```bash
git rm test/support/scripted_tool_client.ex
git rm test/support/scripted_text_client.ex
git rm test/support/streaming_probe_client.ex
```

List the users. After Tasks 7.0a and 7.0c, check that nothing new appeared:

```bash
grep -rlE "ScriptedToolClient|ScriptedTextClient|StreamingProbeClient" test lib
```

Expected: exactly the ten files under **Files** (at `9131274`). If an earlier task added a
file or a use, migrate it with the rules above.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/base_agent_stream_test.exs`
Expected: FAIL at compile: `Normandy.Test.ScriptedTextClient.__struct__/1 is undefined, cannot expand struct Normandy.Test.ScriptedTextClient`.

- [ ] **Step 3: `base_agent_stream_test.exs`**

Apply by content (hunk line numbers are as of `9131274`):

```diff
diff --git a/test/agents/base_agent_stream_test.exs b/test/agents/base_agent_stream_test.exs
--- a/test/agents/base_agent_stream_test.exs
+++ b/test/agents/base_agent_stream_test.exs
@@ -4,7 +4,7 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
   alias Normandy.Components.StreamEvent
   alias Normandy.LLMError
-  alias Normandy.Test.ScriptedTextClient
+  alias Normandy.Test.FakeClient
 
   defmodule Answer do
     use Normandy.Schema
@@ -118,7 +118,7 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   end
 
   test "stream/3 and run/2 return the same chat output" do
-    client = %ScriptedTextClient{text: "Actors share nothing."}
+    client = FakeClient.new([{:text, "Actors share nothing."}, {:text, "Actors share nothing."}])
 
     assert {:ok, _, %BaseAgentOutputSchema{chat_message: "Actors share nothing."} = streamed} =
              BaseAgent.stream(agent(client), %{chat_message: "hi"}, collect())
@@ -127,7 +127,7 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   end
 
   test "stream/3 and run/2 return the same struct for a non-chat schema" do
-    client = %ScriptedTextClient{text: ~s({"answer": "42"})}
+    client = FakeClient.new([{:text, ~s({"answer": "42"})}, {:text, ~s({"answer": "42"})}])
     a = agent(client, %{output_schema: %Answer{}})
 
     assert {:ok, _, %Answer{answer: "42"} = streamed} = BaseAgent.stream(a, "q", collect())
@@ -135,10 +135,10 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   end
 
   test "the callback receives %StreamEvent{} in order" do
-    BaseAgent.stream(agent(%ScriptedTextClient{text: "abcd"}), "hi", collect())
+    BaseAgent.stream(agent(FakeClient.new([{:text, ["ab", "cd"]}])), "hi", collect())
 
     assert [
-             %StreamEvent{type: :message_start, data: %{id: "msg_1", model: "m"}},
+             %StreamEvent{type: :message_start, data: %{id: "msg_fake_0", model: "m"}},
              %StreamEvent{type: :text_delta, data: "ab"},
              %StreamEvent{type: :text_delta, data: "cd"},
              %StreamEvent{type: :message_stop, data: nil}
@@ -146,19 +146,18 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   end
 
   test "a non-chat schema is shown in the streaming system prompt; a chat schema is not" do
-    client = %ScriptedTextClient{text: ~s({"answer": "42"}), notify: self()}
+    client = FakeClient.new([{:text, ~s({"answer": "42"})}, {:text, "hi"}])
 
     BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
-    assert_received {:stream_request, %{system: answer_prompt}}
-    assert answer_prompt =~ "# OUTPUT SCHEMA"
+    BaseAgent.stream(agent(client), "q", collect())
 
-    BaseAgent.stream(agent(%{client | text: "hi"}), "q", collect())
-    assert_received {:stream_request, %{system: chat_prompt}}
+    assert [%{system: answer_prompt}, %{system: chat_prompt}] = FakeClient.requests(client)
+    assert answer_prompt =~ "# OUTPUT SCHEMA"
     refute chat_prompt =~ "# OUTPUT SCHEMA"
   end
 
   test "a non-chat answer that isn't JSON is the error run/2 would give" do
-    client = %ScriptedTextClient{text: "not json at all", options: %{on_parse_failure: :error}}
+    client = FakeClient.new([{:text, "not json at all"}], options: %{on_parse_failure: :error})
 
     assert {:error, %LLMError{type: :invalid_output} = streamed} =
              BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
@@ -244,12 +243,11 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   end
 
   test "a stream that fails after output reached the callback is not retried" do
-    calls = :counters.new(1, [])
-    client = %ScriptedTextClient{text: "abcd", fail_after_first_delta: true, calls: calls}
+    client = FakeClient.new([{:text, ["ab", "cd"], stream_error_after: 1}])
     a = agent(client, %{retry: [max_attempts: 3, base_delay: 1]})
 
     assert {:error, %LLMError{type: :stream}} = BaseAgent.stream(a, "hi", collect())
-    assert :counters.get(calls, 1) == 1
+    assert length(FakeClient.requests(client)) == 1
 
     assert [%StreamEvent{type: :message_start}, %StreamEvent{type: :text_delta, data: "ab"}] =
              events()
@@ -270,7 +268,7 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
   test "run/3 rejects any option" do
     error =
       assert_raise ArgumentError, fn ->
-        BaseAgent.run!(agent(%ScriptedTextClient{text: "x"}), "hi", max_turns: 2)
+        BaseAgent.run!(agent(FakeClient.new([])), "hi", max_turns: 2)
       end
 
     assert error.message ==
@@ -281,12 +279,12 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
 
   test "run/3 rejects the old streaming options with a stream/3 hint" do
     assert_raise ArgumentError, ~r/BaseAgent.stream\/3/, fn ->
-      BaseAgent.run(agent(%ScriptedTextClient{text: "x"}), "hi", stream: true, on_chunk: & &1)
+      BaseAgent.run(agent(FakeClient.new([])), "hi", stream: true, on_chunk: & &1)
     end
   end
 
   test "run/3 and run!/3 name themselves and reject options that are not a keyword list" do
-    agent = agent(%ScriptedTextClient{text: "x"})
+    agent = agent(FakeClient.new([]))
 
     assert_raise ArgumentError,
                  "Normandy.Agents.BaseAgent.run/3: unknown option :max_turns; run/3 takes no options",
@@ -309,7 +307,7 @@ defmodule Normandy.Agents.BaseAgentStreamTest do
     defp nil_schema(config), do: %{config | output_schema: nil}
 
     test "run/2 and stream/3 without tools" do
-      a = nil_schema(agent(%ScriptedTextClient{text: "plain"}))
+      a = nil_schema(agent(FakeClient.new([{:text, "plain"}, {:text, "plain"}])))
 
       assert {:ok, _, %BaseAgentOutputSchema{chat_message: "plain"}} = BaseAgent.run(a, "q")
 
```

- [ ] **Step 4: The other nine files**

Task 7.0c adds blank-answer tests and the `ReturnTool`/`StubClient` aliases to
`blank_answer_test.exs`. The hunk below is written against the file as 7.0c leaves it and
changes only the `chat_agent/1` helper and the alias. Apply by content:

```diff
diff --git a/test/a2a/server_limits_test.exs b/test/a2a/server_limits_test.exs
--- a/test/a2a/server_limits_test.exs
+++ b/test/a2a/server_limits_test.exs
@@ -6,7 +6,7 @@ defmodule Normandy.A2A.ServerLimitsTest do
   alias Normandy.A2A.Server
   alias Normandy.Agents.BaseAgent
   alias Normandy.Components.ToolCall
-  alias Normandy.Test.{ContextProbe, OwnLog, ScriptedToolClient, StubClient, TelemetryCapture}
+  alias Normandy.Test.{ContextProbe, FakeClient, OwnLog, StubClient, TelemetryCapture}
   alias Normandy.Tools.Context
 
   @request_stop [:normandy, :a2a, :request, :stop]
@@ -84,7 +84,18 @@ defmodule Normandy.A2A.ServerLimitsTest do
   describe ":tool_context" do
     defp probe_agent do
       %{
-        client: %ScriptedToolClient{calls: [%ToolCall{id: "call_1", name: "probe", input: %{}}]},
+        # Three turns (one per handle_message/4 call), each a tool round then an answer.
+        client:
+          FakeClient.new(
+            List.duplicate(
+              [
+                {:tool_calls, [%ToolCall{id: "call_1", name: "probe", input: %{}}]},
+                {:text, "done"}
+              ],
+              3
+            )
+            |> List.flatten()
+          ),
         model: "test",
         name: "ctx-agent",
         tool_context: %{memory_namespace: "shared"}
diff --git a/test/agents/base_agent_output_schema_prompt_test.exs b/test/agents/base_agent_output_schema_prompt_test.exs
--- a/test/agents/base_agent_output_schema_prompt_test.exs
+++ b/test/agents/base_agent_output_schema_prompt_test.exs
@@ -6,7 +6,7 @@ defmodule Normandy.Agents.BaseAgentOutputSchemaPromptTest do
   alias Normandy.Agents.Turn
   alias Normandy.Behaviours.SessionRegistry.Native
   alias Normandy.Behaviours.SessionStore.InMemory
-  alias Normandy.Test.ScriptedTextClient
+  alias Normandy.Test.FakeClient
   alias Normandy.Test.StubClient
 
   defmodule Answer do
@@ -89,12 +89,12 @@ defmodule Normandy.Agents.BaseAgentOutputSchemaPromptTest do
     assert {:ok, _agent, %Ordered{value: "v"}} = BaseAgent.run(agent, "hi")
     assert_receive {:converse, %Normandy.LLM.Request{system: synced}, _}
 
-    streaming = %ScriptedTextClient{text: ~s({"value":"v"}), notify: self()}
+    streaming = FakeClient.new([{:text, ~s({"value":"v"})}])
 
     assert {:ok, _agent, %Ordered{value: "v"}} =
              BaseAgent.stream(%{agent | client: streaming}, "hi", fn _ -> :ok end)
 
-    assert_receive {:stream_request, %Normandy.LLM.Request{system: streamed}}
+    assert [%Normandy.LLM.Request{system: streamed}] = FakeClient.requests(streaming)
 
     {:ok, srv} =
       Turn.Server.start_link(
diff --git a/test/agents/blank_answer_test.exs b/test/agents/blank_answer_test.exs
--- a/test/agents/blank_answer_test.exs
+++ b/test/agents/blank_answer_test.exs
@@ -14,14 +14,14 @@ defmodule Normandy.Agents.BlankAnswerTest do
   alias Normandy.Behaviours.SessionRegistry.Native
   alias Normandy.Behaviours.SessionStore.InMemory
   alias Normandy.LLMError
+  alias Normandy.Test.FakeClient
   alias Normandy.Test.ReturnTool
-  alias Normandy.Test.ScriptedTextClient
   alias Normandy.Test.StubClient
 
   @message "expected a final answer, got an empty one: the model ended its turn with no text"
 
   defp chat_agent(text),
-    do: BaseAgent.init(%{client: %ScriptedTextClient{text: text}, model: "m", max_tokens: 64})
+    do: BaseAgent.init(%{client: FakeClient.new([{:text, text}]), model: "m", max_tokens: 64})
 
   for text <- ["", "  \n"] do
     @text text
diff --git a/test/agents/mid_round_compaction_test.exs b/test/agents/mid_round_compaction_test.exs
--- a/test/agents/mid_round_compaction_test.exs
+++ b/test/agents/mid_round_compaction_test.exs
@@ -12,8 +12,8 @@ defmodule Normandy.Agents.MidRoundCompactionTest do
   alias Normandy.Components.ToolCall
   alias Normandy.Components.ToolResult
   alias Normandy.Test.ContextProbe
+  alias Normandy.Test.FakeClient
   alias Normandy.Test.FakeTool
-  alias Normandy.Test.StreamingProbeClient
   alias Normandy.Test.TelemetryCapture
 
   @thinking %{"type" => "thinking", "thinking" => "plan", "signature" => "sig"}
@@ -107,7 +107,7 @@ defmodule Normandy.Agents.MidRoundCompactionTest do
     test "BaseAgent.stream/3" do
       config =
         %{
-          client: %StreamingProbeClient{},
+          client: FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}]),
           model: "m",
           name: "mid-round-stream",
           behaviours: %Config{compactor: recording()}
diff --git a/test/agents/tool_context_test.exs b/test/agents/tool_context_test.exs
--- a/test/agents/tool_context_test.exs
+++ b/test/agents/tool_context_test.exs
@@ -4,13 +4,16 @@ defmodule Normandy.Agents.ToolContextTest do
   alias Normandy.Agents.{BaseAgent, Dispatch, ToolCallResponse, Turn}
   alias Normandy.Agents.Turn.Inline
   alias Normandy.Components.{ToolCall, ToolResult}
-  alias Normandy.Test.{ContextProbe, ScriptedToolClient, StreamingProbeClient}
+  alias Normandy.Test.{ContextProbe, FakeClient}
   alias Normandy.Tools.{Context, Toolset}
 
   defp probe_call, do: %ToolCall{id: "call_1", name: "probe", input: %{}}
 
+  # One tool round with probe_call/0, then the answer "done".
+  defp probe_client, do: FakeClient.new([{:tool_calls, [probe_call()]}, {:text, "done"}])
+
   defp agent(extra \\ %{}) do
-    %{client: %ScriptedToolClient{calls: [probe_call()]}, model: "test", name: "ctx-agent"}
+    %{client: probe_client(), model: "test", name: "ctx-agent"}
     |> Map.merge(extra)
     |> BaseAgent.init()
     |> BaseAgent.register_tool(%ContextProbe{notify: self()})
@@ -23,7 +26,7 @@ defmodule Normandy.Agents.ToolContextTest do
                  ~r/:tool_context option: expected a plain map \(not a struct\), got: a list/,
                  fn ->
                    BaseAgent.init(%{
-                     client: %ScriptedToolClient{},
+                     client: FakeClient.new([]),
                      model: "test",
                      tool_context: [a: 1]
                    })
@@ -47,7 +50,7 @@ defmodule Normandy.Agents.ToolContextTest do
 
   test "the BaseAgent streaming loop hands the contextual tool the session's context" do
     config =
-      agent(%{client: %StreamingProbeClient{}, tool_context: %{memory_namespace: "acme/stream"}})
+      agent(%{client: probe_client(), tool_context: %{memory_namespace: "acme/stream"}})
 
     {:ok, _config, _response} =
       BaseAgent.stream(config, %{chat_message: "go"}, fn _ -> :ok end)
diff --git a/test/agents/turn/server_store_failures_test.exs b/test/agents/turn/server_store_failures_test.exs
--- a/test/agents/turn/server_store_failures_test.exs
+++ b/test/agents/turn/server_store_failures_test.exs
@@ -15,8 +15,8 @@ defmodule Normandy.Agents.Turn.ServerStoreFailuresTest do
   alias Normandy.Behaviours.SessionStore.InMemory
   alias Normandy.Components.AgentMemory.Entry
   alias Normandy.Components.ToolCall
+  alias Normandy.Test.FakeClient
   alias Normandy.Test.ReturnTool
-  alias Normandy.Test.ScriptedToolClient
   alias Normandy.Test.StubClient
   alias Normandy.Test.TurnConfig
   alias Normandy.TurnError
@@ -153,7 +153,11 @@ defmodule Normandy.Agents.Turn.ServerStoreFailuresTest do
 
   # One tool round: the turn persists its :steering state after the batch.
   defp start_config(true) do
-    client = %ScriptedToolClient{calls: [%ToolCall{id: "call_1", name: "big", input: %{}}]}
+    client =
+      FakeClient.new([
+        {:tool_calls, [%ToolCall{id: "call_1", name: "big", input: %{}}]},
+        {:text, "done"}
+      ])
 
     %{client: client, model: "m"}
     |> BaseAgent.init()
diff --git a/test/hooks/base_agent_hooks_test.exs b/test/hooks/base_agent_hooks_test.exs
--- a/test/hooks/base_agent_hooks_test.exs
+++ b/test/hooks/base_agent_hooks_test.exs
@@ -5,7 +5,7 @@ defmodule Normandy.Hooks.BaseAgentHooksTest do
   alias Normandy.Behaviours.Config
   alias Normandy.Components.AgentMemory
   alias Normandy.Hooks.Context
-  alias Normandy.Test.{ContextProbe, StreamingProbeClient, StubClient, TelemetryCapture}
+  alias Normandy.Test.{ContextProbe, FakeClient, StubClient, TelemetryCapture}
   alias Normandy.Test.Hooks, as: TestHooks
   alias Normandy.Test.Hooks.Probe
 
@@ -104,7 +104,7 @@ defmodule Normandy.Hooks.BaseAgentHooksTest do
     test "runs on the streaming path" do
       config =
         %{
-          client: %StreamingProbeClient{},
+          client: FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}]),
           model: "test",
           name: "hooks-stream",
           behaviours: %Config{hooks: [probe()]}
@@ -211,7 +211,7 @@ defmodule Normandy.Hooks.BaseAgentHooksTest do
     test "fires once on the streaming path" do
       config =
         %{
-          client: %StreamingProbeClient{},
+          client: FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}]),
           model: "test",
           name: "hooks-stream",
           behaviours: %Config{hooks: [probe()]}
diff --git a/test/hooks/llm_compaction_hooks_test.exs b/test/hooks/llm_compaction_hooks_test.exs
--- a/test/hooks/llm_compaction_hooks_test.exs
+++ b/test/hooks/llm_compaction_hooks_test.exs
@@ -6,7 +6,7 @@ defmodule Normandy.Hooks.LlmCompactionHooksTest do
   alias Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter
   alias Normandy.Behaviours.Config
   alias Normandy.Components.{AgentMemory, Message, ToolResult}
-  alias Normandy.Test.{ContextProbe, KeepLastCompactor, StreamingProbeClient, StubClient}
+  alias Normandy.Test.{ContextProbe, FakeClient, KeepLastCompactor, StubClient}
   alias Normandy.Test.Hooks, as: TestHooks
   alias Normandy.Test.Hooks.Probe
 
@@ -75,7 +75,7 @@ defmodule Normandy.Hooks.LlmCompactionHooksTest do
     test "runs on the streaming path, once per LLM call" do
       config =
         %{
-          client: %StreamingProbeClient{},
+          client: FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}]),
           model: "test",
           name: "llm-hooks-stream",
           behaviours: %Config{hooks: [probe()]}
@@ -85,7 +85,7 @@ defmodule Normandy.Hooks.LlmCompactionHooksTest do
 
       {:ok, _config, _response} = BaseAgent.stream(config, input("go"), fn _ -> :ok end)
 
-      # StreamingProbeClient makes two calls: the tool_use round, then the text answer.
+      # The client answers two calls: the tool_use round, then the text answer.
       assert_received {:hook, :p, :before_llm, _}
       assert_received {:hook, :p, :before_llm, _}
       refute_received {:hook, :p, :before_llm, _}
@@ -95,7 +95,7 @@ defmodule Normandy.Hooks.LlmCompactionHooksTest do
   test "a before_llm halt on the streaming path returns HookHaltError and fires on_turn_end once" do
     config =
       %{
-        client: %StreamingProbeClient{},
+        client: FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}]),
         model: "test",
         name: "llm-hooks-stream-halt",
         behaviours: %Config{hooks: [probe(returns: [before_llm: {:halt, "budget spent"}])]}
diff --git a/test/hooks/tool_hooks_test.exs b/test/hooks/tool_hooks_test.exs
--- a/test/hooks/tool_hooks_test.exs
+++ b/test/hooks/tool_hooks_test.exs
@@ -4,7 +4,7 @@ defmodule Normandy.Hooks.ToolHooksTest do
   alias Normandy.Agents.{BaseAgent, Dispatch}
   alias Normandy.Behaviours.Config
   alias Normandy.Components.{ToolCall, ToolResult}
-  alias Normandy.Test.{ContextProbe, ScriptedToolClient, TelemetryCapture}
+  alias Normandy.Test.{ContextProbe, FakeClient, TelemetryCapture}
   alias Normandy.Test.Hooks, as: TestHooks
   alias Normandy.Test.Hooks.{Probe, TurnEndOnly}
 
@@ -27,7 +27,8 @@ defmodule Normandy.Hooks.ToolHooksTest do
   defp call(name \\ "probe"), do: %ToolCall{id: "call_1", name: name, input: %{}}
 
   defp agent(behaviours, name \\ "tool-hooks-agent") do
-    %{client: %ScriptedToolClient{}, model: "test", name: name, behaviours: behaviours}
+    # These tests dispatch one call through the pipeline; the model is never asked.
+    %{client: FakeClient.new([]), model: "test", name: name, behaviours: behaviours}
     |> BaseAgent.init()
     |> BaseAgent.register_tool(%ContextProbe{notify: self()})
   end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:

```bash
mix format && mix test test/agents/base_agent_stream_test.exs test/agents/blank_answer_test.exs \
  test/agents/base_agent_output_schema_prompt_test.exs test/agents/tool_context_test.exs \
  test/agents/mid_round_compaction_test.exs test/agents/turn/server_store_failures_test.exs \
  test/a2a/server_limits_test.exs test/hooks/tool_hooks_test.exs \
  test/hooks/llm_compaction_hooks_test.exs test/hooks/base_agent_hooks_test.exs
grep -rnE "ScriptedToolClient|ScriptedTextClient|StreamingProbeClient" test lib
```

Expected: PASS, 108 tests, 0 failures (106 at `9131274`, plus the 2 tests Task 7.0c adds to
`blank_answer_test.exs`; the suite total is unchanged by this task). The grep prints nothing. Historical plan files under
`docs/superpowers/plans/` and `investigations/` still name the clients; leave them.

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. `test/normandy/test/shipped_names_test.exs`
still passes, since `Normandy.Test.StubClient` stays in `test/support`.

- [ ] **Step 7: MIGRATING-2.0.md**

No bullet: `test/support` is not part of the package, and no user-visible behaviour changes.

- [ ] **Step 8: Commit**

```bash
git add test/agents/base_agent_stream_test.exs test/agents/blank_answer_test.exs \
  test/agents/base_agent_output_schema_prompt_test.exs test/agents/tool_context_test.exs \
  test/agents/mid_round_compaction_test.exs test/agents/turn/server_store_failures_test.exs \
  test/a2a/server_limits_test.exs test/hooks/tool_hooks_test.exs \
  test/hooks/llm_compaction_hooks_test.exs test/hooks/base_agent_hooks_test.exs
git commit -m "test: run the scripted-client tests on FakeClient and delete three support clients"
```

(Step 1's `git rm` already staged the three deletions. Do not `git add` the deleted paths:
git refuses them with `fatal: pathspec ... did not match any files` and adds nothing.
`git status --short test/support` shows three `D ` lines before the commit.)

---

### Task 7.3d: The store and registry contracts ship in `lib/` (D3, DX-8)

Moves the three ExUnit contract suites from `test/support/` into `lib/normandy/test/`,
renamed `Normandy.Test.SessionStoreContract`, `Normandy.Test.MemoryStoreContract` and
`Normandy.Test.SessionRegistryContract`, so a third-party backend author can run them.
Changes:

- `new: {m, f, a}` builds the handle for each test (default `{impl, :new, []}`).
- `stored_entry_ids:` becomes an optional `{m, f, a}`. With `nil` (the default), the two
  delete tests check through the behaviour's callbacks only.
- The `use` options are checked through `Normandy.Options.validate!/3` while the test
  module compiles.
- The registry contract no longer depends on `test/support`'s `Normandy.Test.Eventually`.

A scratch run of this exact change (worktree at HEAD `9131274`) gave: `mix test` 3700
tests, 0 failures; `mix test.redis` on the three Redis contract files, 58 tests,
0 failures; `mix credo --strict` clean; `mix dialyzer` passed;
`mix docs --warnings-as-errors` exit 0. Postgres was not run in that probe.

Shipping ExUnit code in `lib/` needs no guard. The modules define only a
`defmacro __using__`, and `test`/`assert`/`setup` expand in the user's test module.
A lib module like this compiles with `--warnings-as-errors` in dev and `MIX_ENV=prod`
(research inventory §0.5; Bypass, StreamData and `Req.Test` do the same).

**Files:**
- Move (`git mv`) and modify: `test/support/session_store_contract.ex` → `lib/normandy/test/session_store_contract.ex`
- Move (`git mv`) and modify: `test/support/memory_store_contract.ex` → `lib/normandy/test/memory_store_contract.ex`
- Move (`git mv`) and rewrite: `test/support/session_registry_contract.ex` → `lib/normandy/test/session_registry_contract.ex`
- Modify (the `use` line): `test/behaviours/session_store/{in_memory,ets,redis,postgres_contract,mnesia}_test.exs`, `test/behaviours/memory_store/{in_memory,ets,mnesia,redis,postgres}_test.exs`, `test/behaviours/session_registry/{native,horde,redis}_test.exs` (13 files)
- Modify: `lib/normandy/behaviours/memory_store.ex`, `lib/normandy/behaviours/session_store.ex`, `lib/normandy/behaviours/session_registry.ex` (moduledoc pointers)
- Modify: `mix.exs` (`groups_for_modules` "Testing" group)
- Modify: `MIGRATING-2.0.md` (`## 45. Testing support and docs`)
- Test: create `test/normandy/test/contracts_test.exs`

**Interfaces:**
- Consumes: the `Normandy.Behaviours.SessionStore`, `MemoryStore` and `SessionRegistry` callbacks (unchanged); `Normandy.Options.validate!/3` and `Normandy.Options.docs/1`; NimbleOptions' `:mfa` type; the "Testing" group in `mix.exs` `groups_for_modules` (created by Task 7.2b; Task 7.3b added `Normandy.Test.FakeClient` to it).
- Produces (shared interface, header):
  - `use Normandy.Test.SessionStoreContract, impl: Mod, new: {m, f, a}, stored_entry_ids: {m, f, a} | nil`
  - `use Normandy.Test.MemoryStoreContract, impl: Mod, new: {m, f, a}`
  - `use Normandy.Test.SessionRegistryContract, impl: Mod, new: {m, f, a}`
  - On a bad option, the test module fails to compile with an `ArgumentError` whose message starts `Normandy.Test.<Contract>.__using__/1:`.
  - `@doc false` helpers `validate!/1` on each contract and `Normandy.Test.SessionRegistryContract.wait_until/2`.

- [ ] **Step 1: Write the failing test**

Create `test/normandy/test/contracts_test.exs` (the directory Task 7.3b created for
`fake_client_test.exs`):

```elixir
defmodule Normandy.Test.ContractsTest.DefaultsOnly do
  @moduledoc """
  Review Focus 3: a third-party store author passes only `impl:` (so `new:` defaults to
  `{impl, :new, []}` and `stored_entry_ids:` to nil). Every contract test runs; the delete
  tests check through the public API only.
  """
  use ExUnit.Case, async: true
  use Normandy.Test.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory
end

defmodule Normandy.Test.ContractsTest.ExplicitNew do
  use ExUnit.Case, async: true

  use Normandy.Test.MemoryStoreContract,
    impl: Normandy.Behaviours.MemoryStore.InMemory,
    new: {Normandy.Behaviours.MemoryStore.InMemory, :new, [[]]}
end

defmodule Normandy.Test.ContractsTest do
  use ExUnit.Case, async: true

  alias Normandy.Test.ContractsTest.{DefaultsOnly, ExplicitNew}

  test "a contract used with impl: alone defines every contract test" do
    names = Enum.map(DefaultsOnly.__ex_unit__().tests, & &1.name)
    assert length(names) == 16
    assert :"test deleting a fork keeps its parent's history" in names
  end

  test "a contract used with new: defines every contract test" do
    assert length(ExplicitNew.__ex_unit__().tests) == 33
  end

  # The use line runs when the test module compiles: a bad option fails that compile.
  defp compile_use(contract, opts) do
    Code.compile_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, "Bad#{System.unique_integer([:positive])}")) do
          use ExUnit.Case, register: false
          use unquote(contract), unquote(Macro.escape(opts))
        end
      end
    )
  end

  for {contract, supported} <- [
        {Normandy.Test.SessionStoreContract, ":impl, :new, :stored_entry_ids"},
        {Normandy.Test.MemoryStoreContract, ":impl, :new"},
        {Normandy.Test.SessionRegistryContract, ":impl, :new"}
      ] do
    @contract contract
    @supported supported

    test "#{inspect(contract)} names a missing :impl" do
      assert_raise ArgumentError,
                   "#{inspect(@contract)}.__using__/1: required :impl option not found, " <>
                     "received options: [:new]",
                   fn -> compile_use(@contract, new: {Kernel, :self, []}) end
    end

    test "#{inspect(contract)} names an unknown option and lists the supported ones" do
      assert_raise ArgumentError,
                   "#{inspect(@contract)}.__using__/1: unknown option :store; " <>
                     "supported: #{@supported}",
                   fn ->
                     compile_use(@contract,
                       impl: Normandy.Behaviours.SessionStore.InMemory,
                       store: 1
                     )
                   end
    end

    test "#{inspect(contract)} wants :new as {module, function, args}" do
      assert_raise ArgumentError,
                   "#{inspect(@contract)}.__using__/1: invalid value for :new option: " <>
                     "expected tuple {mod, fun, args}, got: a tuple",
                   fn -> compile_use(@contract, impl: Kernel, new: {Kernel, :self}) end
    end
  end

  test "SessionStoreContract wants :stored_entry_ids as {module, function, args} or nil" do
    error =
      assert_raise ArgumentError, fn ->
        compile_use(Normandy.Test.SessionStoreContract,
          impl: Normandy.Behaviours.SessionStore.InMemory,
          stored_entry_ids: {Kernel, :ids}
        )
      end

    # NimbleOptions' {:or, ...} message lists one reason per allowed type.
    assert error.message =~
             "Normandy.Test.SessionStoreContract.__using__/1: expected :stored_entry_ids option " <>
               "to match at least one given type"

    assert error.message =~
             "invalid value for :stored_entry_ids option: expected tuple {mod, fun, args}, " <>
               "got: a tuple"
  end
end
```

The 16 and 33 are today's test counts in the two contracts
(`grep -c '^      test "' test/support/session_store_contract.ex` → 16;
`grep -c '^ *test "' test/support/memory_store_contract.ex` → 33). A contract test that
is added later must update them.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/normandy/test/contracts_test.exs`
Expected: FAIL at compile: `module Normandy.Test.SessionStoreContract is not loaded and could not be found`.

- [ ] **Step 3: Move the three files**

```bash
mkdir -p lib/normandy/test
git mv test/support/session_store_contract.ex lib/normandy/test/session_store_contract.ex
git mv test/support/memory_store_contract.ex lib/normandy/test/memory_store_contract.ex
git mv test/support/session_registry_contract.ex lib/normandy/test/session_registry_contract.ex
```

(`lib/normandy/test/` already exists after Task 7.3b; `mkdir -p` is a no-op then.)

- [ ] **Step 4: `Normandy.Test.SessionStoreContract`**

In `lib/normandy/test/session_store_contract.ex`, replace everything from the first line
through the `setup do ... end` block (the old head ends with
`setup do\n        {:ok, handle: @store.new()}\n      end`) with:

```elixir
defmodule Normandy.Test.SessionStoreContract do
  @schema NimbleOptions.new!(
            impl: [
              type: :atom,
              required: true,
              doc: "The module implementing `Normandy.Behaviours.SessionStore`."
            ],
            new: [
              type: :mfa,
              doc:
                "`{module, function, args}` returning a fresh, empty handle, called once " <>
                  "per test. Default: `{impl, :new, []}`."
            ],
            stored_entry_ids: [
              type: {:or, [:mfa, nil]},
              default: nil,
              doc:
                "`{module, function, args}` called with the handle appended to `args`; it " <>
                  "returns the id of every entry the backend still stores, in any session " <>
                  "(an entry without an `id` of its own counts under the id `history/2` " <>
                  "returns for it). `nil` skips the storage-level delete checks."
            ]
          )

  @moduledoc """
  The ExUnit tests every `Normandy.Behaviours.SessionStore` implementation must pass.
  Normandy runs them against its own five backends; run them against yours.

      defmodule MyApp.SessionStoreTest do
        use ExUnit.Case, async: true

        use Normandy.Test.SessionStoreContract,
          impl: MyApp.SessionStore,
          new: {MyApp.SessionStore, :new, [[url: "..."]]}
      end

  Options, checked when the test module compiles (a bad one raises `ArgumentError`):

  #{Normandy.Options.docs(@schema)}

  Every test builds its handle with `:new` and needs it **empty**: tests use fixed
  session ids (`"s1"`, `"parked"`) and assert exact `list_resumable/1` results. A
  backend whose storage is shared between handles (a database, a node-global table)
  must give each handle its own namespace, or reset the storage in a `setup` placed
  before the `use` line, and its test module must be `async: false` when handles can
  see each other's data.

  The tests run real concurrency (200 `Task`s appending to one session, awaited for up
  to 5 s) and fork and delete sessions.

  With `:stored_entry_ids`, the two tests that delete a fork's parent or a fork also
  check that the deleted session's own entries are gone from storage; without it they
  check through the behaviour's callbacks only (`history/2` of the survivor).
  """

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts),
    do: Normandy.Options.validate!(opts, @schema, {__MODULE__, :__using__, 1})

  defmacro __using__(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [opts: opts, contract: __MODULE__] do
      alias Normandy.Components.AgentMemory.Entry

      contract_opts = contract.validate!(opts)
      @store Keyword.fetch!(contract_opts, :impl)
      @new_handle Keyword.get(contract_opts, :new) || {@store, :new, []}
      @stored_entry_ids Keyword.fetch!(contract_opts, :stored_entry_ids)

      setup do
        {mod, fun, args} = @new_handle
        {:ok, handle: apply(mod, fun, args)}
      end
```

Why it is written this way:
- `opts` is bound with `bind_quoted`, so the keyword list (with aliases expanded in the
  caller) is evaluated in the test module's body. A bad option therefore raises while
  that module compiles. The macro itself only sees AST.
- The contract is called through the bound `contract` variable, not
  `Normandy.Test.SessionStoreContract.validate!`. Credo's `--strict` design check flags
  the nested module call inside a quote ("Nested modules could be aliased"), and an
  `alias` would leak into the user's module.

Replace `contract_stored_ids/1`:

```elixir
      defp contract_stored_ids(h) do
        {mod, fun} = @stored_entry_ids
        apply(mod, fun, [h])
      end
```

with:

```elixir
      # nil when the test module passed no :stored_entry_ids: the storage checks are skipped.
      defp contract_stored_ids(h) do
        case @stored_entry_ids do
          nil -> nil
          {mod, fun, args} -> apply(mod, fun, args ++ [h])
        end
      end
```

In the test `"deleting a fork's parent keeps the fork's history and drops the parent's own entries"`, replace:

```elixir
        assert :ok = @store.delete_session(h, "parent")

        assert {:ok, entries} = @store.history(h, forked)
        assert Enum.map(entries, & &1.content) == ["a", "b"]

        stored = contract_stored_ids(h)
        refute own in stored
        refute snap in stored
        assert Enum.all?(entries, &(&1.id in stored))
```

with:

```elixir
        assert :ok = @store.delete_session(h, "parent")
        assert {:ok, []} = @store.history(h, "parent")

        assert {:ok, entries} = @store.history(h, forked)
        assert Enum.map(entries, & &1.content) == ["a", "b"]

        case contract_stored_ids(h) do
          nil ->
            :ok

          stored ->
            refute own in stored
            refute snap in stored
            assert Enum.all?(entries, &(&1.id in stored))
        end
```

In the test `"deleting a fork keeps its parent's history"`, replace:

```elixir
        assert Enum.map(entries, & &1.content) == ["a", "b", "c"]
        refute fork_own in contract_stored_ids(h)
```

with:

```elixir
        assert Enum.map(entries, & &1.content) == ["a", "b", "c"]
        assert {:ok, []} = @store.history(h, forked)

        case contract_stored_ids(h) do
          nil -> :ok
          stored -> refute fork_own in stored
        end
```

The rest of the file (the other 14 tests, `contract_entry/2`, `contract_entry_with_id/2`)
is unchanged. It still uses `UUID` (`elixir_uuid`, a runtime dependency), so the lib module
needs no new dependency.

- [ ] **Step 5: `Normandy.Test.MemoryStoreContract`**

In `lib/normandy/test/memory_store_contract.ex`, replace everything from the first line
through the `setup do ... end` block (the old head ends with
`{:ok, handle: @store.new(), ns: "contract-#{System.unique_integer([:positive])}"}\n      end`)
with:

```elixir
defmodule Normandy.Test.MemoryStoreContract do
  @schema NimbleOptions.new!(
            impl: [
              type: :atom,
              required: true,
              doc: "The module implementing `Normandy.Behaviours.MemoryStore`."
            ],
            new: [
              type: :mfa,
              doc:
                "`{module, function, args}` returning a handle, called once per test. " <>
                  "Default: `{impl, :new, []}`."
            ]
          )

  @moduledoc """
  The ExUnit tests every `Normandy.Behaviours.MemoryStore` implementation must pass.
  Normandy runs them against its own five backends; run them against yours.

      defmodule MyApp.MemoryStoreTest do
        use ExUnit.Case, async: true

        use Normandy.Test.MemoryStoreContract,
          impl: MyApp.MemoryStore,
          new: {MyApp.MemoryStore, :new, [[url: "..."]]}
      end

  Options, checked when the test module compiles (a bad one raises `ArgumentError`):

  #{Normandy.Options.docs(@schema)}

  Each test writes under its own namespace (`"contract-<unique integer>"`), so handles may
  share storage and the test module may be `async: true`, unless your backend keeps
  node-global state that `new` resets (then `async: false`). The tests run real
  concurrency (`Task`s racing on one namespace, awaited for up to 15 s), drive the
  `memory` tool (`Normandy.Tools.Memory`) against the store, and fill a namespace past
  `Normandy.Behaviours.MemoryStore.list_limit/0`.
  """

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts),
    do: Normandy.Options.validate!(opts, @schema, {__MODULE__, :__using__, 1})

  defmacro __using__(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [opts: opts, contract: __MODULE__] do
      alias Normandy.Behaviours.MemoryStore
      alias Normandy.Tools.{Context, Memory}

      contract_opts = contract.validate!(opts)
      @store Keyword.fetch!(contract_opts, :impl)
      @new_handle Keyword.get(contract_opts, :new) || {@store, :new, []}

      setup do
        {mod, fun, args} = @new_handle

        {:ok, handle: apply(mod, fun, args), ns: "contract-#{System.unique_integer([:positive])}"}
      end
```

The 33 tests below are unchanged.

- [ ] **Step 6: `Normandy.Test.SessionRegistryContract`**

Replace the whole content of `lib/normandy/test/session_registry_contract.ex` with the code
below. The poll copies `Normandy.Test.Eventually.wait_until/2`
(`test/support/eventually.ex`: check, then up to `retries` more checks 10 ms apart) with the
budget the old contract passed (300). `test/support` is not in a user's build, so the contract
cannot call it. The local helper is named `contract_wait_until/1` so it cannot clash with a
user's `import Normandy.Test.Eventually` or their own `wait_until/1`.

```elixir
defmodule Normandy.Test.SessionRegistryContract do
  @schema NimbleOptions.new!(
            impl: [
              type: :atom,
              required: true,
              doc: "The module implementing `Normandy.Behaviours.SessionRegistry`."
            ],
            new: [
              type: :mfa,
              doc:
                "`{module, function, args}` returning a fresh, empty handle, called once " <>
                  "per test. Default: `{impl, :new, []}`."
            ]
          )

  @moduledoc """
  The ExUnit tests every `Normandy.Behaviours.SessionRegistry` implementation must pass.
  Normandy runs them against `Native`, `Horde` and `Redis`; run them against yours.

      defmodule MyApp.SessionRegistryTest do
        use ExUnit.Case, async: true
        use Normandy.Test.SessionRegistryContract, impl: MyApp.SessionRegistry
      end

  Options, checked when the test module compiles (a bad one raises `ArgumentError`):

  #{Normandy.Options.docs(@schema)}

  Every test registers the fixed session id `"s1"`, so each handle must start empty
  (its own namespace, or `async: false` and a reset in a `setup` before the `use` line).
  A registry may be eventually consistent: every check after a change polls `whereis/2`
  every 10 ms for up to 3 s, and a process killed while registered must disappear within
  that time.
  """

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts),
    do: Normandy.Options.validate!(opts, @schema, {__MODULE__, :__using__, 1})

  @doc false
  # Polls `fun` until it returns true: at most `retries` more checks, 10 ms apart.
  @spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
  def wait_until(fun, retries \\ 300) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, contract: __MODULE__] do
      contract_opts = contract.validate!(opts)
      @normandy_contract contract
      @reg Keyword.fetch!(contract_opts, :impl)
      @new_handle Keyword.get(contract_opts, :new) || {@reg, :new, []}

      setup do
        {mod, fun, args} = @new_handle
        {:ok, handle: apply(mod, fun, args)}
      end

      # NOTE: a registry may be eventually consistent (Horde reflects a register/
      # unregister through an async CRDT→ETS flush), so every "mutate then observe via
      # whereis" assertion polls. For a synchronous impl (Native) the poll returns on
      # the first check, so this costs nothing there.
      test "register then whereis returns the pid; unknown is :none", %{handle: h} do
        assert :none = @reg.whereis(h, "s1")
        assert :ok = @reg.register(h, "s1", self())
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == {:ok, self()} end)
      end

      test "double-register the same session is {:error, :taken}", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert contract_wait_until(fn -> match?({:ok, _}, @reg.whereis(h, "s1")) end)
        assert {:error, :taken} = @reg.register(h, "s1", self())
      end

      test "unregister frees the session", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert contract_wait_until(fn -> match?({:ok, _}, @reg.whereis(h, "s1")) end)
        assert :ok = @reg.unregister(h, "s1")
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == :none end)
        assert :ok = @reg.register(h, "s1", self())
      end

      test "a dead process auto-unregisters", %{handle: h} do
        parent = self()

        pid =
          spawn(fn ->
            :ok = @reg.register(h, "s1", self())
            send(parent, :registered)
            Process.sleep(:infinity)
          end)

        ref = Process.monitor(pid)
        assert_receive :registered, 1_000
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == {:ok, pid} end)

        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        # Registry cleanup is async on owner death; poll until it lands. Horde's
        # CRDT cleanup can exceed a few hundred ms under full-suite load, so the
        # budget is generous (the poll returns as soon as the condition holds, so
        # a fast impl like Native pays nothing).
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == :none end)
      end

      defp contract_wait_until(fun), do: @normandy_contract.wait_until(fun)
    end
  end
end
```

The `Process.sleep(10)` is the poll interval of an eventual-consistency check, as in
`Eventually`. It is not used to order messages: each check is a synchronous `whereis/2`.

- [ ] **Step 7: The 13 `use` lines and the 5 `stored_entry_ids` values**

```bash
grep -rlE "use Normandy\.(SessionStore|MemoryStore|SessionRegistry)Contract" test | sort
```

Expected: 13 files, namely
`test/behaviours/memory_store/{ets,in_memory,mnesia,postgres,redis}_test.exs`,
`test/behaviours/session_registry/{horde,native,redis}_test.exs` and
`test/behaviours/session_store/{ets,in_memory,mnesia,postgres_contract,redis}_test.exs`.

Rewrite rule: `use Normandy.<X>Contract` → `use Normandy.Test.<X>Contract`:

```bash
grep -rlE "use Normandy\.(SessionStore|MemoryStore|SessionRegistry)Contract" test \
  | xargs sed -i '' -E 's/use Normandy\.(SessionStore|MemoryStore|SessionRegistry)Contract/use Normandy.Test.\1Contract/'
grep -rnE "use Normandy\.(SessionStore|MemoryStore|SessionRegistry)Contract" test | wc -l   # 0
grep -rnE "use Normandy\.Test\.(SessionStore|MemoryStore|SessionRegistry)Contract" test | wc -l   # 15 (the 13 files + 2 in Step 1's contracts_test.exs)
```

Rewrite rule: `stored_entry_ids: {__MODULE__, :stored_entry_ids}` → `stored_entry_ids: {__MODULE__, :stored_entry_ids, []}`.
The five backends' `stored_entry_ids/1` functions keep their one-argument shape, because
the contract appends the handle to `[]`:

```bash
grep -rl "stored_entry_ids: {__MODULE__, :stored_entry_ids}" test \
  | xargs sed -i '' 's/stored_entry_ids: {__MODULE__, :stored_entry_ids}/stored_entry_ids: {__MODULE__, :stored_entry_ids, []}/'
grep -rn "stored_entry_ids: {__MODULE__, :stored_entry_ids, \[\]}" test | wc -l   # 5
```

(On Linux, use `sed -i` without `''`.) Comments that say `SessionStoreContract` without
the namespace (`mnesia_test.exs:7`, `concurrent_append_mnesia_test.exs:48`) stay as they
are; they name the suite, not a module.

- [ ] **Step 8: Behaviour moduledocs point at the contracts**

`lib/normandy/behaviours/memory_store.ex` moduledoc: replace
"Semantics every impl must pass (`Normandy.MemoryStoreContract`):" with
"Semantics every impl must pass (`Normandy.Test.MemoryStoreContract`):".

`lib/normandy/behaviours/session_store.ex` moduledoc: after the paragraph that ends
"returning a fresh handle for tests and callers.", add the paragraph:

```
  Every impl must pass the ExUnit suite `Normandy.Test.SessionStoreContract`.
```

`lib/normandy/behaviours/session_registry.ex` moduledoc: after the paragraph that ends
"Distributed impls (Horde/syn) are deferred.", add the paragraph:

```
  Every impl must pass the ExUnit suite `Normandy.Test.SessionRegistryContract`.
```

(After Task 7.2a these backticked references are to visible modules, so ExDoc links them.)

- [ ] **Step 9: The docs group**

In `mix.exs` `groups_for_modules`, add to the `Testing:` list that Task 7.2b created (it
holds `Normandy.Test.FakeClient` and `Normandy.Test.FakeClient.ScriptExhaustedError` after
Task 7.3b; add a comma after `ScriptExhaustedError` and append):

```elixir
            Normandy.Test.SessionStoreContract,
            Normandy.Test.MemoryStoreContract,
            Normandy.Test.SessionRegistryContract
```

`test/docs/docs_groups_test.exs` (Task 7.2b) fails without this: the three modules have
moduledocs and would be in no group.

- [ ] **Step 10: Run the tests to verify they pass**

Run: `mix format && mix test test/normandy/test/contracts_test.exs test/behaviours test/docs`
Expected: PASS. In `contracts_test.exs`: 61 tests (16 + 33 contract tests, 9 option tests
over three contracts, 1 `stored_entry_ids` test, 2 count tests). The Redis and Postgres
contract files are excluded here; Step 12 runs them.

- [ ] **Step 11: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3d.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3d.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. `mix credo --strict` reports no issues; the
two `LongQuoteBlocks` disables move with their files.

- [ ] **Step 12: Tagged suites (every backend's contract)**

The move touches every backend's contract test file, so run:

- `mix test.redis 2>&1 | tee /tmp/w7-7.3d-redis.log` → ` 0 failures`
- `docker start normandy-test-pg`, then
  `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tee /tmp/w7-7.3d-pg.log` → ` 0 failures`
  (the controller stops the container afterwards; no database is created or dropped)
- `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tee /tmp/w7-7.3d-dist.log` → ` 0 failures`

- [ ] **Step 13: MIGRATING-2.0.md**

Append to `## 45. Testing support and docs` (created by Task 7.2a):

```markdown
- The store and registry contract suites ship in the package:
  `Normandy.Test.SessionStoreContract`, `Normandy.Test.MemoryStoreContract` and
  `Normandy.Test.SessionRegistryContract`. A custom `SessionStore`, `MemoryStore` or
  `SessionRegistry` runs the tests Normandy's own backends pass:
  `use Normandy.Test.SessionStoreContract, impl: MyApp.Store` inside a module that has
  `use ExUnit.Case`. `new: {module, function, args}` builds each test's handle (default
  `{impl, :new, []}`); the session store's optional `stored_entry_ids: {m, f, a}` (called
  with the handle appended) adds storage-level checks to the two delete tests. Options are
  checked when the test module compiles. Each moduledoc says what a handle must provide
  (empty per test) and when the test module must be `async: false`.
- Projects that copied Normandy's `test/support` contracts (`Normandy.SessionStoreContract`,
  `Normandy.MemoryStoreContract`, `Normandy.SessionRegistryContract`, never part of the
  package) switch to the `Normandy.Test.*` names. `stored_entry_ids:` is now
  `{module, function, args}` (`{__MODULE__, :stored_entry_ids, []}` for the old
  `{__MODULE__, :stored_entry_ids}`) and may be left out.
```

- [ ] **Step 14: Commit**

```bash
git add lib/normandy/test/session_store_contract.ex lib/normandy/test/memory_store_contract.ex \
  lib/normandy/test/session_registry_contract.ex \
  test/behaviours/session_store/in_memory_test.exs test/behaviours/session_store/ets_test.exs \
  test/behaviours/session_store/redis_test.exs test/behaviours/session_store/postgres_contract_test.exs \
  test/behaviours/session_store/mnesia_test.exs \
  test/behaviours/memory_store/in_memory_test.exs test/behaviours/memory_store/ets_test.exs \
  test/behaviours/memory_store/mnesia_test.exs test/behaviours/memory_store/redis_test.exs \
  test/behaviours/memory_store/postgres_test.exs \
  test/behaviours/session_registry/native_test.exs test/behaviours/session_registry/horde_test.exs \
  test/behaviours/session_registry/redis_test.exs \
  lib/normandy/behaviours/memory_store.ex lib/normandy/behaviours/session_store.ex \
  lib/normandy/behaviours/session_registry.ex \
  mix.exs MIGRATING-2.0.md test/normandy/test/contracts_test.exs
git commit -m "feat(test): ship the store and registry contracts as Normandy.Test.*Contract"
```

(`git mv` in Step 3 already staged the removal of the old `test/support/*_contract.ex`
paths; do not `git add` them: git refuses a path that is in neither the tree nor the index
(`fatal: pathspec ... did not match any files`) and the whole `git add` fails. `git status`
shows two `renamed:` entries before the commit (session store, memory store); the rewritten
registry contract shows as `deleted:` `test/support/session_registry_contract.ex` plus
`new file:` `lib/normandy/test/session_registry_contract.ex`.)

---

### Task 7.3e: `docs/guides/testing.md`, whose examples run in the suite (DX-8, Review Focus 2)

No guide, README section or MIGRATING section covers testing your own agents (inventory
§4.1). This task adds the guide. Each `MyApp.*` module in it is compiled, and each
`MyAppTest.*` test module is compiled and its tests run by `test/docs/testing_guide_test.exs`.
Per-module test counts pin the guide: a deleted, renamed or broken example fails there. The
mechanism is the hooks guide test's (`test/hooks/guide_examples_test.exs`): compile the
example with `use ExUnit.Case, register: false` and run its tests by hand. It adds two
things: the example's `setup` runs through `module.__ex_unit__(:setup, context)`, and
literal swaps are asserted to be present before they are applied.

Covered: scripted text, request capture, tools (in the loop and alone), structured output,
retry, stop reasons, streaming, a durable session (`Turn.Session` on `InMemory`, `Native`,
`Turn.Supervisor`, all under `start_supervised!`), telemetry with
`:telemetry_test.attach_event_handlers/2`, hooks (a link), the store contract, a client of
your own (prose), and live tests (prose).

A scratch check at `9131274` (with Task 7.3d's module stood in by a shim delegating to
today's `test/support` contract): 9 tests, 0 failures, under `--trace` too. Changing one
expected answer in the guide made the guide test fail. `mix docs --warnings-as-errors`
exited 0, and `doc/testing.html` links `hooks.html` and `Normandy.Test.FakeClient.html#new/2`.

**Files:**
- Create: `docs/guides/testing.md`
- Create: `test/docs/testing_guide_test.exs`
- Modify: `mix.exs` (`docs` `extras`; `groups_for_extras` if Task 7.2b lists guides by path)
- Modify: `README.md` ("Documentation" list)
- Modify: `MIGRATING-2.0.md` (`## 45. Testing support and docs`)

**Interfaces:**
- Consumes:
  - From Task 7.3b: `Normandy.Test.FakeClient` (`new/2`, `requests/1`, `remaining/1`, the items and their options).
  - From Task 7.3d: `use Normandy.Test.SessionStoreContract, impl:, new:`.
  - `Normandy.Agents.BaseAgent.init/1`, `run/3`, `stream/3`, `register_tool/3`; `Normandy.Agents.Turn.Session.new/1`, `run/2`; `Normandy.Behaviours.SessionStore.InMemory` (child spec from `use Agent`); `Normandy.Behaviours.SessionRegistry.Native.start_link/1` (`name:`); `Normandy.Agents.Turn.Supervisor` (child spec, no options needed); `Normandy.Tools.Context` (`tool_call_id` is enforced).
  - The run `:stop` totals `input_tokens`/`output_tokens` (`Normandy.Telemetry`, "Run totals").
- Produces: the guide (an ExDoc extra) and the guide test.
- Tagged suites: none.

- [ ] **Step 1: Write the failing test**

Create `test/docs/testing_guide_test.exs`:

```elixir
defmodule Normandy.Docs.TestingGuideTest do
  @moduledoc """
  Task 7.3e: every example in `docs/guides/testing.md` compiles cleanly and every example
  test passes against the shipped `Normandy.Test.*` modules. The counts pin the guide: a
  dropped or broken block fails here.
  """
  use ExUnit.Case, async: true

  @guide Path.expand("../../docs/guides/testing.md", __DIR__)

  # Example test modules, by name, with how many tests each defines.
  @example_tests %{
    "MyAppTest.GreeterTest" => 2,
    "MyAppTest.WeatherAgentTest" => 2,
    "MyAppTest.VerdictTest" => 3,
    "MyAppTest.StreamingTest" => 1,
    "MyAppTest.SessionTest" => 1,
    "MyAppTest.UsageTest" => 1
  }

  # Compiled once: compiling an example module twice would warn about the redefinition.
  setup_all do
    compiled =
      for source <- blocks(~r/```elixir\n(defmodule MyApp\..*?)```/s) do
        Code.with_diagnostics(fn -> Code.compile_string(source) end)
      end

    %{compiled: compiled}
  end

  defp blocks(regex) do
    regex
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> List.flatten()
  end

  # The guide's test module named `name`, compiled unregistered: ExUnit's own run has
  # started, and registering a module now fails under --trace and --slowest.
  defp example_test_module(name, swaps \\ []) do
    [source] = blocks(~r/```elixir\n(defmodule #{Regex.escape(name)} do.*?)```/s)

    source =
      Enum.reduce([{"use ExUnit.Case,", "use ExUnit.Case, register: false,"} | swaps], source, fn
        {from, to}, source ->
          assert source =~ from, "#{name}: the guide's example no longer contains #{from}"
          String.replace(source, from, to)
      end)

    {[{module, _binary}], diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source) end)

    assert diagnostics == [], "#{name} did not compile cleanly: #{inspect(diagnostics)}"
    module
  end

  test "the guide's example modules compile without warnings", %{compiled: compiled} do
    assert length(compiled) == 2

    for {_modules, diagnostics} <- compiled do
      assert diagnostics == [], "example did not compile cleanly: #{inspect(diagnostics)}"
    end
  end

  test "the guide has exactly the example test modules listed here" do
    names = blocks(~r/```elixir\ndefmodule (MyAppTest\.\w+) do/)

    assert Enum.sort(names) ==
             Enum.sort(Map.keys(@example_tests) ++ ["MyAppTest.SessionStoreTest"])
  end

  for {name, count} <- @example_tests do
    test "the guide's #{name} passes" do
      module = example_test_module(unquote(name))
      tests = module.__ex_unit__().tests
      assert length(tests) == unquote(count)

      for test <- tests do
        context = module.__ex_unit__(:setup, %{test: test.name, module: module})
        apply(module, test.name, [context])
      end
    end
  end

  defmodule ContractReference do
    use ExUnit.Case, register: false
    use Normandy.Test.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory
  end

  test "the guide's store contract example defines the whole contract" do
    # The guide's MyApp.SessionStore is played by InMemory. Running the tests would
    # repeat the InMemory contract run; the count shows the guide's options were
    # accepted and every contract test was defined.
    in_memory = "Normandy.Behaviours.SessionStore.InMemory"

    module =
      example_test_module("MyAppTest.SessionStoreTest", [
        {"impl: MyApp.SessionStore", "impl: #{in_memory}"},
        {"new: {MyApp.SessionStore, :new, []}", "new: {#{in_memory}, :new, []}"}
      ])

    reference = length(ContractReference.__ex_unit__().tests)
    assert reference > 0
    assert length(module.__ex_unit__().tests) == reference
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/docs/testing_guide_test.exs`
Expected: FAIL. `setup_all` raises `** (File.Error) could not read file ".../docs/guides/testing.md": no such file or directory`, and every test in the module is invalidated.

- [ ] **Step 3: The guide**

Create `docs/guides/testing.md`:

````markdown
# Testing agents

Normandy ships what you need to test an agent without a network or an API key:

- `Normandy.Test.FakeClient`, a model client that answers from a script and records every
  request it receives;
- `Normandy.Test.SessionStoreContract`, `Normandy.Test.MemoryStoreContract` and
  `Normandy.Test.SessionRegistryContract`, the test suites every built-in backend passes,
  for a backend of your own.

Every example below runs in Normandy's own test suite, against the version these docs
describe.

## A scripted model

Give `Normandy.Test.FakeClient.new/2` the replies in the order the agent will ask for
them, and use the client like any other:

```elixir
defmodule MyAppTest.GreeterTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.FakeClient

  test "answers the greeting" do
    client = FakeClient.new([{:text, "Hello, Ada."}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5")

    assert {:ok, _agent, %{chat_message: "Hello, Ada."}} = BaseAgent.run(agent, "I am Ada")
  end

  test "sends the user's message and the agent's max_tokens" do
    client = FakeClient.new([{:text, "Hi."}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5", max_tokens: 512)

    {:ok, _agent, _output} = BaseAgent.run(agent, "I am Ada")

    assert [%Normandy.LLM.Request{max_tokens: 512, messages: [message]}] =
             FakeClient.requests(client)

    assert message.role == "user"
    assert FakeClient.remaining(client) == 0
  end
end
```

`FakeClient.requests/1` returns every `Normandy.LLM.Request` the client received, oldest
first: the system prompt, the messages, the tool schemas and the token limit are what the
model would have seen. A request past the end of the script raises
`Normandy.Test.FakeClient.ScriptExhaustedError`, so a test that makes one call too many
fails loudly. A misspelled script item raises `ArgumentError` from `new/2`, naming it.

## Tools

A tool is a module; the agent runs it when the script asks for it:

```elixir
defmodule MyApp.WeatherTool do
  use Normandy.Tool, name: "weather", description: "The weather in a city"

  defstruct []

  @impl Normandy.Tool
  def input_schema(_tool),
    do: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]}

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %{"city" => city}}),
    do: {:ok, "12°C and raining in #{city}"}
end
```

Script a `{:tool_calls, [{name, input}]}` reply, then the answer the model gives once it
has the result:

```elixir
defmodule MyAppTest.WeatherAgentTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.FakeClient

  defp agent(client) do
    [client: client, model: "claude-opus-5-5"]
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%MyApp.WeatherTool{})
  end

  test "calls the tool, then answers from its result" do
    client =
      FakeClient.new([
        {:tool_calls, [{"weather", %{"city" => "Oslo"}}]},
        {:text, "Bring an umbrella."}
      ])

    assert {:ok, _agent, %{chat_message: "Bring an umbrella."}} =
             BaseAgent.run(agent(client), "Weather in Oslo?")

    [_tool_round, answer_request] = FakeClient.requests(client)
    [_user, _assistant, tool_message] = answer_request.messages
    assert [%{content: "12°C and raining in Oslo", is_error: false}] = tool_message.content
  end

  test "the tool alone" do
    context = %Normandy.Tools.Context{tool_call_id: "call_1", input: %{"city" => "Lima"}}

    assert {:ok, "12°C and raining in Lima"} =
             MyApp.WeatherTool.run(%MyApp.WeatherTool{}, context)
  end
end
```

A tool call's id is `"toolu_fake_<request>_<position>"` (both counted from 0); pass a
`%Normandy.Components.ToolCall{}` instead of `{name, input}` to choose it.

## Structured output, errors and stop reasons

`{:structured, map}` answers with JSON for the agent's output schema. `{:error,
%Normandy.LLMError{}}` fails the call: a `retryable?` error is resent when the agent has
`retry:`. A `:stop_reason` option makes a reply cut off (`:max_tokens`) or refused
(`:refusal`), which Normandy returns as an error:

```elixir
defmodule MyApp.Verdict do
  use Normandy.Schema

  io_schema "A verdict" do
    field(:approved, :boolean, required: true)
    field(:reason, :string)
  end
end
```

```elixir
defmodule MyAppTest.VerdictTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient

  defp agent(client, opts \\ []),
    do: BaseAgent.init([client: client, model: "claude-opus-5-5", output_schema: %MyApp.Verdict{}] ++ opts)

  test "a structured answer" do
    client = FakeClient.new([{:structured, %{approved: true, reason: "within policy"}}])

    assert {:ok, _agent, %MyApp.Verdict{approved: true, reason: "within policy"}} =
             BaseAgent.run(agent(client), "Refund order 42?")
  end

  test "a rate limit is retried" do
    rate_limited = LLMError.new(type: :rate_limit, retryable?: true)
    client = FakeClient.new([{:error, rate_limited}, {:structured, %{approved: false}}])

    assert {:ok, _agent, %MyApp.Verdict{approved: false}} =
             BaseAgent.run(agent(client, retry: [max_attempts: 2, base_delay: 1]), "Refund?")
  end

  test "an answer cut off at max_tokens is an error" do
    client = FakeClient.new([{:text, ~s({"appro), stop_reason: :max_tokens}])

    assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent(client), "Refund?")
  end
end
```

A function of the request is a script item too, for a reply that depends on what was
sent: `fn %Normandy.LLM.Request{} = request -> {:text, ...} end`.

## Streaming

`BaseAgent.stream/3` takes the same script. A `{:text, chunks}` reply with a list of
binaries arrives as one text delta per chunk:

```elixir
defmodule MyAppTest.StreamingTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.StreamEvent
  alias Normandy.Test.FakeClient

  test "delivers the deltas, then returns the answer" do
    client = FakeClient.new([{:text, ["Hel", "lo."]}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5")
    test_pid = self()

    assert {:ok, _agent, %{chat_message: "Hello."}} =
             BaseAgent.stream(agent, "hi", fn event -> send(test_pid, event) end)

    assert_received %StreamEvent{type: :text_delta, data: "Hel"}
    assert_received %StreamEvent{type: :text_delta, data: "lo."}
  end
end
```

`stream_error_after: n` ends a streamed reply in a transport error after `n` deltas, to
test what your callback does with a partial answer.

## Sessions

A durable session runs its turns in a `Normandy.Agents.Turn.Server` process; the client
answers it there. Start the store, the registry and the supervisor under the test's
supervisor, so they stop with the test:

```elixir
defmodule MyAppTest.SessionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeClient

  setup do
    registry = :"registry_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: Native, start: {Native, :start_link, [[name: registry]]}})

    %{
      store: start_supervised!(InMemory),
      registry: registry,
      supervisor: start_supervised!(Turn.Supervisor)
    }
  end

  test "two turns of one session", ctx do
    client = FakeClient.new([{:text, "Noted."}, {:text, "You said blue."}])

    session =
      Turn.Session.new(
        session_id: "user-1",
        config: BaseAgent.init(client: client, model: "claude-opus-5-5"),
        store: {InMemory, ctx.store},
        registry: {Native, ctx.registry},
        supervisor: ctx.supervisor
      )

    assert {:ok, %{chat_message: "Noted."}} = Turn.Session.run(session, "My color is blue.")
    assert {:ok, %{chat_message: "You said blue."}} = Turn.Session.run(session, "My color?")

    assert {:ok, history} = InMemory.history(ctx.store, "user-1")
    assert Enum.map(history, & &1.role) == ["user", "assistant", "user", "assistant"]
  end
end
```

## Telemetry

Every run emits `[:normandy, :agent, :run, :stop]` with the run's totals (see
`Normandy.Telemetry`). A `:usage` option on a script item sets what the reply reports:

```elixir
defmodule MyAppTest.UsageTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.FakeClient

  test "the run reports its token totals" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:normandy, :agent, :run, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    client = FakeClient.new([{:text, "Hi.", usage: %{input_tokens: 12, output_tokens: 3}}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5", name: "usage-test")

    {:ok, _agent, _output} = BaseAgent.run(agent, "hi")

    assert_receive {[:normandy, :agent, :run, :stop], ^ref, _measurements,
                    %{agent_name: "usage-test", input_tokens: 12, output_tokens: 3}}
  end
end
```

Handlers attached this way receive events from every process: match on a field your
test owns (here the agent's name), as `async: true` tests run side by side.

## Hooks

A hook is a module of callbacks; call them directly, or run the hook through an agent
(`BaseAgent.run/3` on a config whose `behaviours` lists it) for the library's rules. See
"Testing a hook" in the [hooks guide](hooks.md).

## A store or registry of your own

Run the contract suite the built-in backends pass. `impl:` is your module; `new:` builds a
fresh, empty handle for each test (default `{impl, :new, []}`):

```elixir
defmodule MyAppTest.SessionStoreTest do
  use ExUnit.Case, async: true

  use Normandy.Test.SessionStoreContract,
    impl: MyApp.SessionStore,
    new: {MyApp.SessionStore, :new, []}
end
```

`Normandy.Test.MemoryStoreContract` and `Normandy.Test.SessionRegistryContract` take the
same options. Each module's documentation says what a handle must provide and when a backend
needs `async: false`.

## A client of your own

To test an adapter for another provider, implement `Normandy.Agents.Model` (its
documentation is the contract). Two things differ from `FakeClient`:

- **Protocol consolidation.** A `defimpl` in a `.exs` test file is not used once protocols
  are consolidated. Put the implementation in a file compiled with your project (for
  example `test/support/`, added to `elixirc_paths` for the test environment), or set
  `consolidate_protocols: false` for the test environment in `mix.exs`.
- **Process ownership.** A `Turn.Server` session, an `AgentProcess` and BaseAgent's tool
  tasks call the client from their own processes. `Req.Test` and Mox expectations
  need an allowance for those pids (see `MIGRATING-2.0.md`, "AgentProcess and
  coordination"). `FakeClient` needs none: any process on the node takes the next reply.

## Live tests

Keep tests that call a real model out of the default run. Tag them, exclude the tag in
`test/test_helper.exs`, and run them with `mix test --only integration`:

    ExUnit.start(exclude: [:integration])

    @tag :integration
    test "the live model answers" do
      ...
    end
````

- [ ] **Step 4: Extras and the README**

In `mix.exs` `docs` `extras`, after `"docs/guides/hooks.md"` (add the comma) insert:

```elixir
          "docs/guides/testing.md"
```

Check `groups_for_extras` from Task 7.2b:

- If it lists guides by path, add `"docs/guides/testing.md"` beside `"docs/guides/hooks.md"`.
- If it matches guides with a regex on `docs/guides/`, the new guide is already covered.

In `README.md` "Documentation", after the line that starts
`- **🌐 [Distributed sessions guide]`, insert:

```markdown
- **🧪 [Testing guide](docs/guides/testing.md)** — offline tests with `Normandy.Test.FakeClient`, durable sessions, telemetry, and the store contracts for your own backends.
```

(Task 7.3g later edits this list for DX-34; it keeps this line.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix format && mix test test/docs/testing_guide_test.exs && mix test test/docs/testing_guide_test.exs --trace`
Expected: PASS twice, 9 tests, 0 failures (`--trace` checks that the unregistered example
modules run under it).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3e.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3e.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. `doc/testing.html` exists.

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 45. Testing support and docs`:

```markdown
- A new guide, `docs/guides/testing.md` ("Testing agents" on HexDocs), shows offline tests
  with `FakeClient` on `run/3`, `stream/3` and `Turn.Session`, telemetry assertions, and the
  contract suites for a custom store or registry. Its examples run in Normandy's own suite.
```

- [ ] **Step 8: Commit**

```bash
git add docs/guides/testing.md test/docs/testing_guide_test.exs mix.exs README.md MIGRATING-2.0.md
git commit -m "docs(guides): testing guide whose examples run in the suite"
```

---

### Task 7.3f: Doc coverage on every visible module (decision 27 C5)

This task runs after 7.3b–7.3e, which add `lib/normandy/test/*.ex`. Those modules come with
their own docs; the widened test checks them too. 7.3f widens `doc_coverage_test.exs` to every
lib/ module with a docs page and every function, macro and callback in it. The ~85 missing docs
are written in four area sub-tasks. Each sub-task is ≤ ~250 diff lines.

**Gaps that remain** (`Module:kind:name/arity`). These were measured on the scratch worktree with
7.2a and 7.3a applied (87 entries):

| Sub-task | Entries | Area |
|---|---|---|
| 7.3f1 | 18 | Agents, memory, LLM: `BaseAgentInputSchema`/`BaseAgentOutputSchema` `get_json_schema/0` (one `@doc` in the `io_schema` macro), `ConfigTemplate.from_config/2,3`, `Agents.Model` `converse/3`, `stream/3` (function + callback each, one `@doc` each), `AgentMemory` `new_memory/1`, `initialize_turn/1`, `get_current_turn_id/1`, `history/1`, `entries/1`, `dump/1`, `load/1`, `LLM.StructuredOutputs` `enabled?/1`, `schema_for/2`, `AgentTemplate.Catalog.put/3` |
| 7.3f2 | 22 | Schema, types and validation: `Validate` (19: `apply_action/2`, `apply_action!/2`, `apply_changes/1`, `cast/4`, `empty_values/0`, `field_missing?/2`, `get_field/3`, `traverse_errors/2`, `validate_change/3`, `validate_change/4`, `validate_confirmation/3`, `validate_exclusion/4`, `validate_format/4`, `validate_inclusion/4`, `validate_length/3`, `validate_number/3`, `validate_required/3`, `validate_subset/4`, `validations/1`), `Schema.field/3` (macro), `Type.parameterized?/2`, `InvalidChangesetError.message/1` (`@impl true`, not a `@doc`) |
| 7.3f3 | 26 | Store and registry contracts: `MemoryStore` callbacks `get/3`, `list/3`, `put/6`, `delete/4`, `delete_tree/3`, `rename/4`, `delete_namespace/2`; `SessionStore` callbacks `append_entry/3`, `history/2`, `fork/3`, `load_turn_state/2`, `save_config_template/3`, `load_config_template/2`; `SessionRegistry` callbacks `whereis/2`, `register/3`, `unregister/2`; `up/0` and `down/0` of `MemoryStore.Postgres.Migration` and of `SessionStore.Postgres.Migration`, `MigrationAddTemplate`, `MigrationAddResumePolicy`, `MigrationAddInflight` |
| 7.3f4 | 21 | Extension behaviours: `Behaviours.Hooks` callbacks (9: `on_session_start/2`, `on_passivate/2`, `on_prompt/3`, `before_llm/3`, `before_tool/3`, `after_tool/4`, `after_compact/4`, `on_turn_end/3`, `validate_opts!/1`), `Tool` callbacks `name/1`, `description/1`, `input_schema/1`, `run/2`, `BudgetTracker` `check/3`, `record/4`, `AgentTemplate.fetch/2`, `Compactor.maybe_compact/3`, `CredentialProvider.get_token/2`, `ModelCatalog.context_window/2`, `PolicyEngine.check/2`, `Guardrails.Guard.check/2` |

**Enumeration command.** It is the same filter the test uses: a dev build, no `test/support`.
Run it from the repository root:

```sh
MIX_ENV=dev mix run --no-start -e '
{:ok, mods} = :application.get_key(:normandy, :modules)
for mod <- Enum.sort(mods),
    Code.ensure_loaded?(mod),
    not function_exported?(mod, :__impl__, 1),
    {:docs_v1, _, _, _, moduledoc, _, docs} <- [Code.fetch_docs(mod)],
    moduledoc != :hidden,
    {{kind, name, arity}, _, _, :none, _} <- docs,
    kind in [:function, :macro, :callback, :macrocallback],
    do: IO.puts("#{inspect(mod)}:#{kind}:#{name}/#{arity}")
' | tee /tmp/w7-undocumented.txt | wc -l
```

Expected at the start of 7.3f1: `87`, the lines of the table above. A different count means
an earlier task added or documented something. Give the difference to the controller before
writing docs. A module of 7.3b/7.3d that shows up here is that task's gap.

**House style for a doc.** This is what the existing docs do (`Turn.Session.new/1`, `run/2`,
`SessionStore.save_turn_state/4`, `BaseAgent.fetch_context_provider/2`):
- The first sentence says what it returns or does, in the present tense with no subject
  (`Returns …`, `Builds …`, `Appends …`), and ends with a period. ExDoc shows it as the summary.
- Name each return shape exactly in backticks (`{:ok, entry_id}`, `:none`,
  `{:error, reason}`). Name each exception it raises and the condition. Do not restate
  the `@spec`: say what the spec cannot (when, which one, what happens next).
- Options: a NimbleOptions schema gets `## Options` from `Normandy.Options.docs/1`, as
  `init/1` does. A plain keyword list gets a `* `:key` - meaning (default)` list.
- A callback says who calls it, when, what each return makes the library do, and whether
  an error is retried, logged or returned. In a `defprotocol` one `@doc` covers the
  function and the callback.
- Examples are 4-space indented code, never `iex>` (Task 7.3g1's test fails on an `iex>`
  outside the doctested files). They use only real modules, or placeholders the text
  introduces (`calculator`, "a struct of a module that `use`s `Normandy.Tool`").
- Fully qualified backticked names only for public modules. A hidden one fails
  `mix docs --warnings-as-errors`.
- Plain words and short sentences. No "This function", "simply", "easily" or "powerful".
  Lines ≤ 92 columns, as in the surrounding docs.
- An exception's `message/1` or a behaviour implementation gets `@impl true` (which hides it), not a `@doc`.
- Check every claim against the function body before writing it. The worked examples
  below were checked against HEAD `9131274`.

#### Task 7.3f1: Widen the test; agents, memory and LLM docs

**Files:**
- Modify: `test/docs/doc_coverage_test.exs` (replaced)
- Modify: `lib/normandy/schema.ex` (`io_schema/2`'s generated `get_json_schema/0`),
  `lib/normandy/agents/config_template.ex`, `lib/normandy/agents/model.ex`,
  `lib/normandy/components/agent_memory.ex`, `lib/normandy/llm/structured_outputs.ex`,
  `lib/normandy/behaviours/agent_template.ex` (`Catalog.put/3`)

**Interfaces:**
- Consumes: Task 7.3a's test (replaced); Task 7.2a's hidden set (the test skips hidden modules).
- Produces: the header interface "Doc coverage test", widened. The `@not_yet_documented`
  attribute shrinks in 7.3f2–f3 and is deleted in 7.3f4.

- [ ] **Step 1: Write the failing test**

Replace `test/docs/doc_coverage_test.exs` with the file below. `@not_yet_documented` lists
the 7.3f2, 7.3f3 and 7.3f4 entries, the three lower blocks of the table above (69 lines,
copied from `/tmp/w7-undocumented.txt`):

```elixir
defmodule Normandy.Docs.DocCoverageTest do
  @moduledoc """
  Public API has docs (DX-10, decision 27 C5). ExDoc renders an undocumented function
  with an empty body and no warning, so the compiled docs chunks are checked instead:
  every function, macro and callback of every lib/ module with a docs page has a @doc.
  """
  use ExUnit.Case, async: true

  @kinds [:function, :macro, :callback, :macrocallback]

  # Gaps documented by Tasks 7.3f2-7.3f4, which remove their lines; 7.3f4 deletes the list.
  @not_yet_documented ~w(
    Normandy.InvalidChangesetError:function:message/1
    Normandy.Schema:macro:field/3
    Normandy.Type:function:parameterized?/2
    Normandy.Validate:function:apply_action/2
    Normandy.Validate:function:apply_action!/2
    Normandy.Validate:function:apply_changes/1
    Normandy.Validate:function:cast/4
    Normandy.Validate:function:empty_values/0
    Normandy.Validate:function:field_missing?/2
    Normandy.Validate:function:get_field/3
    Normandy.Validate:function:traverse_errors/2
    Normandy.Validate:function:validate_change/3
    Normandy.Validate:function:validate_change/4
    Normandy.Validate:function:validate_confirmation/3
    Normandy.Validate:function:validate_exclusion/4
    Normandy.Validate:function:validate_format/4
    Normandy.Validate:function:validate_inclusion/4
    Normandy.Validate:function:validate_length/3
    Normandy.Validate:function:validate_number/3
    Normandy.Validate:function:validate_required/3
    Normandy.Validate:function:validate_subset/4
    Normandy.Validate:function:validations/1
    Normandy.Behaviours.MemoryStore:callback:delete/4
    Normandy.Behaviours.MemoryStore:callback:delete_namespace/2
    Normandy.Behaviours.MemoryStore:callback:delete_tree/3
    Normandy.Behaviours.MemoryStore:callback:get/3
    Normandy.Behaviours.MemoryStore:callback:list/3
    Normandy.Behaviours.MemoryStore:callback:put/6
    Normandy.Behaviours.MemoryStore:callback:rename/4
    Normandy.Behaviours.MemoryStore.Postgres.Migration:function:down/0
    Normandy.Behaviours.MemoryStore.Postgres.Migration:function:up/0
    Normandy.Behaviours.SessionRegistry:callback:register/3
    Normandy.Behaviours.SessionRegistry:callback:unregister/2
    Normandy.Behaviours.SessionRegistry:callback:whereis/2
    Normandy.Behaviours.SessionStore:callback:append_entry/3
    Normandy.Behaviours.SessionStore:callback:fork/3
    Normandy.Behaviours.SessionStore:callback:history/2
    Normandy.Behaviours.SessionStore:callback:load_config_template/2
    Normandy.Behaviours.SessionStore:callback:load_turn_state/2
    Normandy.Behaviours.SessionStore:callback:save_config_template/3
    Normandy.Behaviours.SessionStore.Postgres.Migration:function:down/0
    Normandy.Behaviours.SessionStore.Postgres.Migration:function:up/0
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight:function:down/0
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight:function:up/0
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy:function:down/0
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy:function:up/0
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate:function:down/0
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate:function:up/0
    Normandy.Behaviours.AgentTemplate:callback:fetch/2
    Normandy.Behaviours.BudgetTracker:callback:check/3
    Normandy.Behaviours.BudgetTracker:callback:record/4
    Normandy.Behaviours.Compactor:callback:maybe_compact/3
    Normandy.Behaviours.CredentialProvider:callback:get_token/2
    Normandy.Behaviours.Hooks:callback:after_compact/4
    Normandy.Behaviours.Hooks:callback:after_tool/4
    Normandy.Behaviours.Hooks:callback:before_llm/3
    Normandy.Behaviours.Hooks:callback:before_tool/3
    Normandy.Behaviours.Hooks:callback:on_passivate/2
    Normandy.Behaviours.Hooks:callback:on_prompt/3
    Normandy.Behaviours.Hooks:callback:on_session_start/2
    Normandy.Behaviours.Hooks:callback:on_turn_end/3
    Normandy.Behaviours.Hooks:callback:validate_opts!/1
    Normandy.Behaviours.ModelCatalog:callback:context_window/2
    Normandy.Behaviours.PolicyEngine:callback:check/2
    Normandy.Guardrails.Guard:callback:check/2
    Normandy.Tool:callback:description/1
    Normandy.Tool:callback:input_schema/1
    Normandy.Tool:callback:name/1
    Normandy.Tool:callback:run/2
  )

  test "every visible module documents its functions, macros and callbacks" do
    {:ok, modules} = :application.get_key(:normandy, :modules)

    missing =
      for mod <- Enum.sort(modules),
          lib_module?(mod),
          not protocol_impl?(mod),
          moduledoc(mod) != :hidden,
          item <- undocumented(mod),
          do: item

    assert missing -- @not_yet_documented == [],
           "expected @doc on: #{inspect(missing -- @not_yet_documented)}"

    assert @not_yet_documented -- missing == [],
           "documented now, remove from @not_yet_documented: " <>
             inspect(@not_yet_documented -- missing)
  end

  test "the Normandy moduledoc says which entry point to use" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy)
    assert doc =~ "## Choosing an entry point"

    for mod <- ~w(Agents.BaseAgent DSL.Agent Coordination.AgentProcess Agents.Turn.Session) do
      assert doc =~ "| `Normandy.#{mod}` |", "expected a table row for Normandy.#{mod}"
    end
  end

  # "Module:kind:name/arity" for each function, macro or callback with no @doc.
  defp undocumented(mod) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    for {{kind, name, arity}, _, _, :none, _} <- docs,
        kind in @kinds,
        do: "#{inspect(mod)}:#{kind}:#{name}/#{arity}"
  end

  # test/support modules are in :normandy's module list in the test env.
  defp lib_module?(mod) do
    Code.ensure_loaded!(mod)
    source = mod.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    String.starts_with?(Path.relative_to_cwd(source), "lib/")
  end

  # ExDoc lists no protocol implementation.
  defp protocol_impl?(mod), do: function_exported?(mod, :__impl__, 1)

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(mod)
    moduledoc
  end
end
```

The second assertion keeps the list honest: an entry that has been documented must leave the list.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/docs/doc_coverage_test.exs`
Expected: FAIL. The message is `expected @doc on: [...]` with exactly the 18 7.3f1 entries
(for example `"Normandy.Agents.BaseAgentInputSchema:function:get_json_schema/0"`,
`"Normandy.Agents.Model:callback:converse/3"`).

- [ ] **Step 3: Write the 7.3f1 docs**

Write one `@doc` per function, in the house style. Three of them, verbatim:

`lib/normandy/schema.ex`, in `io_schema/2`'s postlude, directly above
`          def get_json_schema do`. This documents every `io_schema` module, users' included:

```elixir
          @doc "Returns this schema's JSON Schema specification, as `__schema__(:specification)` does."
```

`lib/normandy/agents/model.ex`, above `  @spec converse(t(), Normandy.LLM.Request.t(), keyword()) ::`:

```elixir
  @doc """
  Makes one model call for `request` and returns `{:ok, %Normandy.LLM.Response{}}` with
  `request.response_model` filled as the moduledoc's "Response content" describes, or
  `{:error, %Normandy.LLMError{}}`. Normandy decides whether to retry from the error's
  `retryable?`. A raise is a bug, not an error result: the caller's run re-raises it.
  """
```

`lib/normandy/components/agent_memory.ex`, above `  @spec new_memory(pos_integer() | nil) :: t()`:

```elixir
  @doc """
  Returns an empty memory. With `max_messages`, an append that takes the active branch
  past that many messages drops the oldest; `nil` keeps every message.
  """
```

Check `max_messages` against `enforce_max_messages/1` before keeping the wording. Write the
remaining 12 the same way: `stream/3`, `initialize_turn/1`, `get_current_turn_id/1`, `history/1`,
`entries/1`, `dump/1`, `load/1`, `from_config/2`, `from_config/3`, `enabled?/1`,
`schema_for/2` and `Catalog.put/3`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/docs/doc_coverage_test.exs`, then the enumeration command.
Expected: PASS (2 tests); the enumeration prints 69.

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3f1.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3f1.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite.

- [ ] **Step 6: MIGRATING-2.0.md**

No entry (docs only).

- [ ] **Step 7: Commit**

```bash
git add test/docs/doc_coverage_test.exs lib/normandy/schema.ex lib/normandy/agents/config_template.ex \
  lib/normandy/agents/model.ex lib/normandy/components/agent_memory.ex \
  lib/normandy/llm/structured_outputs.ex lib/normandy/behaviours/agent_template.ex
git commit -m "docs: doc coverage on every visible module; agents, memory and LLM docs"
```

(`git add` only the files that changed. `Catalog.put/3` may live in its own file. Check
`git status --short`.)

#### Task 7.3f2: Schema, types and validation docs

**Files:** Modify `lib/normandy/validate.ex`, `lib/normandy/schema.ex` (`field/3`),
`lib/normandy/type.ex` (`parameterized?/2`), `lib/normandy/exceptions.ex`
(`InvalidChangesetError.message/1`), `test/docs/doc_coverage_test.exs`.
**Interfaces:** Consumes 7.3f1's test. Produces nothing new.

- [ ] **Step 1: Write the failing test.** In `test/docs/doc_coverage_test.exs`, delete the
  22 lines from `Normandy.InvalidChangesetError:function:message/1` through
  `Normandy.Validate:function:validations/1`.
- [ ] **Step 2: Run it to verify it fails.** `mix format && mix test test/docs/doc_coverage_test.exs`
  → FAIL, `expected @doc on: [...]` with exactly those 22 entries.
- [ ] **Step 3: Write the docs.** In `lib/normandy/exceptions.ex`, add `@impl true` above
  `  def message(%{action: action, changeset: changeset}) do` in `InvalidChangesetError`
  (an `Exception` callback; this hides it as the other exceptions' `message/1` are). Worked
  example, verbatim, above `  @spec cast(` in `lib/normandy/validate.ex`:

  ```elixir
  @doc """
  Casts `params` into a changeset on `data`, a schema struct. Each key of `permitted` (atoms)
  is read from `params` (atom or string keys) and cast to its field's type; the result goes
  in `changes` unless it equals the current value. A value in `:empty_values` becomes the
  field's default. A value that does not cast adds an `"is invalid"` error and makes the
  changeset invalid. A permitted key absent from `params` is skipped. `params` of
  `:invalid` gives an invalid changeset with no changes.

  Options:

    * `:empty_values` - values treated as empty (default `empty_values/0`)
    * `:force_changes` - put a value in `changes` even when it equals the current one
      (default `false`)
    * `:message` - `fn key, metadata -> message | nil end`, replacing the error message

  Raises `Normandy.CastError` when `params` is a struct or not a map, and
  `ArgumentError` for a permitted key that is not an atom or not a field, or a
  `:message` that is not a 2-arity function.
  """
  ```

  `Schema.field/3`'s `@doc` lists every option in `@field_opts`. Point to the moduledoc's
  constraint list instead of copying it. Write the other 20 in the house style.
- [ ] **Step 4: Run it to verify it passes.** Same command → PASS; enumeration prints 47.
- [ ] **Step 5: Gate.** `mix precommit 2>&1 | tee /tmp/w7-7.3f2.log` → ` 0 failures`;
  `mix docs --warnings-as-errors` exit 0. No tagged suite.
- [ ] **Step 6: MIGRATING-2.0.md.** No entry.
- [ ] **Step 7: Commit.**
  ```bash
  git add lib/normandy/validate.ex lib/normandy/schema.ex lib/normandy/type.ex \
    lib/normandy/exceptions.ex test/docs/doc_coverage_test.exs
  git commit -m "docs: document Validate, Schema.field/3 and Type.parameterized?/2"
  ```

#### Task 7.3f3: Store and registry contract docs

**Files:** Modify `lib/normandy/behaviours/memory_store.ex`,
`lib/normandy/behaviours/session_store.ex`, `lib/normandy/behaviours/session_registry.ex`,
`lib/normandy/behaviours/memory_store/postgres/migration.ex`,
`lib/normandy/behaviours/session_store/postgres/migration.ex`,
`migration_add_template.ex`, `migration_add_resume_policy.ex`, `migration_add_inflight.ex`
(same directory), `test/docs/doc_coverage_test.exs`.
**Interfaces:** Consumes 7.3f2's test. Produces nothing new. Docs only: no tagged suite. The
store contracts that 7.3d moved run in plain `mix test` for InMemory/ETS/Mnesia.

- [ ] **Step 1: Write the failing test.** Delete the 26 lines from
  `Normandy.Behaviours.MemoryStore:callback:delete/4` through
  `Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate:function:up/0`.
- [ ] **Step 2: Run it to verify it fails.** → FAIL listing exactly those 26.
- [ ] **Step 3: Write the docs.** Worked examples, verbatim:

  `session_store.ex`, above `  @callback append_entry(handle(), session_id(), Entry.t()) ::`:

  ```elixir
  @doc """
  Appends `entry` to the session's history and returns `{:ok, entry_id}`: the entry's own
  `id`, or a new one when it is `nil`. An entry with no `parent_id` goes after the
  session's head. A store error is `{:error, reason}`; `Turn.Server` fails the turn
  with a `:persist_failed` `Normandy.TurnError`.
  """
  ```

  `session_registry.ex`, above `  @callback whereis(handle(), session_id()) ::`:

  ```elixir
  @doc """
  Returns `{:ok, pid}` for the live `Turn.Server` of `session_id`, `:none` when there is
  none, or `{:error, reason}` when the backend cannot answer. Never answer `:none` for an
  outage: the router would start a second server for a live session.
  """
  ```

  `migration_add_template.ex`, above `def up`/`def down`:

  ```elixir
  @doc "Adds the `config_template` column to `normandy_sessions`."
  ...
  @doc "Removes the `config_template` column."
  ```

  Check `{:ok, entry_id}` and the parent rule against `SessionStore.InMemory.append_entry/3`
  and `Postgres.do_append_entry/3` (`postgres.ex:44-46`: `entry.id || Ecto.UUID.generate()`,
  `entry.parent_id || session.head_id`) before keeping them. The other 23 follow the house
  style. A migration's `up/0` doc names the tables, columns and indexes it creates, and when
  to run it (the order the `SessionStore.Postgres` moduledoc gives after Task 7.3g2).
- [ ] **Step 4: Run it to verify it passes.** → PASS; enumeration prints 21.
- [ ] **Step 5: Gate.** `mix precommit 2>&1 | tee /tmp/w7-7.3f3.log` → ` 0 failures`; docs exit 0.
- [ ] **Step 6: MIGRATING-2.0.md.** No entry.
- [ ] **Step 7: Commit.**
  ```bash
  git add lib/normandy/behaviours/memory_store.ex lib/normandy/behaviours/session_store.ex \
    lib/normandy/behaviours/session_registry.ex \
    lib/normandy/behaviours/memory_store/postgres/migration.ex \
    lib/normandy/behaviours/session_store/postgres/migration.ex \
    lib/normandy/behaviours/session_store/postgres/migration_add_template.ex \
    lib/normandy/behaviours/session_store/postgres/migration_add_resume_policy.ex \
    lib/normandy/behaviours/session_store/postgres/migration_add_inflight.ex \
    test/docs/doc_coverage_test.exs
  git commit -m "docs: document the store and registry callbacks and the Postgres migrations"
  ```

#### Task 7.3f4: Extension behaviour docs; the list goes

**Files:** Modify `lib/normandy/behaviours/hooks.ex`, `lib/normandy/tool.ex`,
`lib/normandy/behaviours/budget_tracker.ex`, `lib/normandy/behaviours/agent_template.ex`,
`lib/normandy/behaviours/compactor.ex`, `lib/normandy/behaviours/credential_provider.ex`,
`lib/normandy/behaviours/model_catalog.ex`, `lib/normandy/behaviours/policy_engine.ex`,
`lib/normandy/guardrails/guard.ex`, `test/docs/doc_coverage_test.exs`.
**Interfaces:** Consumes 7.3f3's test. Produces the final "Doc coverage test" (header):
no allowlist.

- [ ] **Step 1: Write the failing test.** In `test/docs/doc_coverage_test.exs`: delete the
  comment line `# Gaps documented by Tasks 7.3f2-7.3f4, …` and the whole `@not_yet_documented`
  attribute. In the coverage test, replace the two assertions with
  `assert missing == [], "expected @doc on: #{inspect(missing)}"`.
- [ ] **Step 2: Run it to verify it fails.** → FAIL listing exactly the 21 7.3f4 entries.
- [ ] **Step 3: Write the docs.** Worked example, verbatim, above
  `  @callback on_prompt(input :: term(), Context.t(), opts()) ::` in `behaviours/hooks.ex`:

  ```elixir
  @doc """
  Runs on a turn's validated input, before input guardrails. `{:cont, input}` passes it
  on (a changed input is validated again), `{:halt, reason}` ends the turn with a
  `Normandy.HookHaltError` before any model call.
  """
  ```

  The other 8 hook callbacks restate their row of the moduledoc's return table, plus when
  the callback runs (`docs/guides/hooks.md` "Events" has it). `Tool` callbacks: `name/1` is
  the registered and wire name, with `prefix__` rules for MCP/A2A (`Normandy.Tool`
  moduledoc). `run/2` gets the validated input as `context.input`. The rest follow the house style.
- [ ] **Step 4: Run it to verify it passes.** → PASS; enumeration prints `0`.
- [ ] **Step 5: Gate.** `mix precommit 2>&1 | tee /tmp/w7-7.3f4.log` → ` 0 failures`; docs exit 0.
- [ ] **Step 6: MIGRATING-2.0.md.** No entry.
- [ ] **Step 7: Commit.**
  ```bash
  git add lib/normandy/behaviours/hooks.ex lib/normandy/tool.ex \
    lib/normandy/behaviours/budget_tracker.ex lib/normandy/behaviours/agent_template.ex \
    lib/normandy/behaviours/compactor.ex lib/normandy/behaviours/credential_provider.ex \
    lib/normandy/behaviours/model_catalog.ex lib/normandy/behaviours/policy_engine.ex \
    lib/normandy/guardrails/guard.ex test/docs/doc_coverage_test.exs
  git commit -m "docs: document every extension behaviour callback"
  ```

---

### Task 7.3g1: `iex>` examples are doctested or plain code (DX-32)

Eleven lib files hold `iex>` examples, and five modules are doctested
(`grep -rhn "doctest " test`: `Type`, `Coordination.Pattern`, `SystemPromptGenerator`,
`AgentMemory`, `Telemetry.Usage`). Seven files have examples that cannot run. They use
`message: _` patterns, placeholder `User`/`MySchema` modules, or tool structs that do not
exist (`%CalculatorTool{}`). Those become plain indented code with `#=>` results.
`Tools.Input.message/1`'s single example runs, so it becomes a doctest.

**Files:**
- Modify: `lib/normandy/guardrails.ex`, `lib/normandy/tools/toolset.ex`,
  `lib/normandy/llm/json_deserializer.ex`, `lib/normandy/agents/base_agent.ex`
  (`list_tools/1`, `has_tools?/1`), `lib/normandy/agents/validation_middleware.ex` (hidden
  since 7.2a; converted so the rule has no exception), `lib/normandy/schema/introspection.ex`,
  `lib/normandy/schema/validator.ex`
- Test: create `test/docs/devex_docs_test.exs`; modify `test/tools/input_test.exs`
  (`doctest`)

**Interfaces:**
- Consumes: nothing. 7.0c and 7.3a edit `base_agent.ex` elsewhere, 7.3h removes three
  `Toolset` functions later, and the script is anchored on `iex>` lines only.
- Produces: `test/docs/devex_docs_test.exs` (module `Normandy.Docs.DevexDocsTest`), which
  7.3g2 extends.

- [ ] **Step 1: Write the failing test**

Create `test/docs/devex_docs_test.exs`:

```elixir
defmodule Normandy.Docs.DevexDocsTest do
  @moduledoc """
  Devex Tier 3-4 docs fixes (DX-20, DX-32, DX-34, DX-35) stay fixed.
  """
  use ExUnit.Case, async: true

  # Files whose `iex>` examples run as doctests (`doctest` in a test module).
  @doctested [
    "lib/normandy/components/agent_memory.ex",
    "lib/normandy/components/system_prompt_generator.ex",
    "lib/normandy/coordination/pattern.ex",
    "lib/normandy/telemetry/usage.ex",
    "lib/normandy/tools/input.ex",
    "lib/normandy/type.ex"
  ]

  test "DX-32: every iex> example in lib/ is doctested" do
    with_examples =
      for path <- Path.wildcard("lib/**/*.ex"),
          File.read!(path) =~ ~r/^\s*iex>/m,
          do: path

    undoctested = Enum.sort(with_examples -- @doctested)

    assert undoctested == [],
           "expected iex> examples only in doctested files, found them in: " <>
             inspect(undoctested)
  end
end
```

In `test/tools/input_test.exs`, add after `  alias Normandy.Tools.{Context, Input}`:

```elixir

  doctest Input
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/docs/devex_docs_test.exs test/tools/input_test.exs`
Expected: `devex_docs_test.exs` FAILS:
`expected iex> examples only in doctested files, found them in: ["lib/normandy/agents/base_agent.ex", "lib/normandy/agents/validation_middleware.ex", "lib/normandy/guardrails.ex", "lib/normandy/llm/json_deserializer.ex", "lib/normandy/schema/introspection.ex", "lib/normandy/schema/validator.ex", "lib/normandy/tools/toolset.ex"]`.
`input_test.exs` passes (`1 doctest, 20 tests, 0 failures`, observed): the example already runs.

- [ ] **Step 3: Convert the examples**

Save this script outside the repository (`$TMPDIR/deiex.py`). The prompt goes, the expected
result becomes a `#=>` comment with `#   ` continuation lines, and a blank line ends a result:

```python
import re
import sys

PROMPT = re.compile(r"^(\s*)(?:iex|\.\.\.)> ?(.*)$")

for path in sys.argv[1:]:
    out, indent, state = [], "", None
    for line in open(path).read().split("\n"):
        m = PROMPT.match(line)
        if m:
            indent, state = m.group(1), "first"
            out.append(indent + m.group(2))
        elif state and line.strip() and line.startswith(indent):
            mark = "#=> " if state == "first" else "#   "
            out.append(indent + mark + line[len(indent):])
            state = "rest"
        else:
            state = None
            out.append(line)
    open(path, "w").write("\n".join(out))
```

```sh
python3 $TMPDIR/deiex.py lib/normandy/guardrails.ex lib/normandy/tools/toolset.ex \
  lib/normandy/llm/json_deserializer.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/agents/validation_middleware.ex lib/normandy/schema/introspection.ex \
  lib/normandy/schema/validator.ex
grep -rc "iex>" lib | grep -v ":0$"
```

Expected: only `type.ex:63`, `tools/input.ex:1`, `coordination/pattern.ex:58` and
`telemetry/usage.ex:4` remain. For example, the result in `guardrails.ex` reads:

```
      alias Normandy.Guardrails
      alias Normandy.Guardrails.Builtins.MaxLength
      Guardrails.run([{MaxLength, limit: 5}], "too long")
      #=> {:error, [%{guard: MaxLength, path: [], message: _, constraint: :max_length}]}
```

Then replace `Toolset`'s nonexistent structs with placeholders the moduledoc introduces:

```sh
perl -pi -e 's/%(?:CalculatorTool|Calculator|EnhancedCalculator)\{\}/calculator/g; s/%Tool1\{\}/tool1/g; s/%Tool2\{\}/tool2/g; s/%StringTool\{\}/string_tool/g; s/"enhanced_calculator"/"calculator"/g' lib/normandy/tools/toolset.ex
grep -cE "%(CalculatorTool|Calculator|EnhancedCalculator|Tool1|Tool2|StringTool)\{\}" lib/normandy/tools/toolset.ex   # 0
```

and in the `Toolset` moduledoc replace

```
  `to_tool_schemas/1` produces the tool definitions sent to the model.
  """
```

with

```
  `to_tool_schemas/1` produces the tool definitions sent to the model.

  In the examples, `calculator`, `string_tool`, `tool1` and `tool2` stand for structs of
  modules that `use Normandy.Tool`, each named after its variable.
  """
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/docs/devex_docs_test.exs test/tools/input_test.exs test/tools/toolset_test.exs test/agents/validation_middleware_test.exs`
Expected: PASS (`devex_docs_test.exs`: 1 test; `input_test.exs`: 1 doctest, 20 tests).

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3g1.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3g1.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures` (one more doctest than before), exit 0; docs exit 0. No tagged suite.

- [ ] **Step 6: MIGRATING-2.0.md**

No entry (docs only).

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/guardrails.ex lib/normandy/tools/toolset.ex lib/normandy/llm/json_deserializer.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/agents/validation_middleware.ex \
  lib/normandy/schema/introspection.ex lib/normandy/schema/validator.ex \
  test/docs/devex_docs_test.exs test/tools/input_test.exs
git commit -m "docs: iex examples are doctested or plain code"
```

---

### Task 7.3g2: Error messages, Postgres setup docs, one model id, README quickstart, package files (DX-31, DX-20, DX-34, DX-35)

**Files:**
- Modify: `lib/normandy/schema.ex` (DX-31: `__field__/4`, `__schema__/2`, `check_options!`)
- Modify: `lib/normandy/behaviours/session_store/postgres.ex`,
  `lib/normandy/behaviours/memory_store/postgres.ex` (DX-20: moduledocs, `new/0` docs)
- Modify: `README.md`, `docs/guides/hooks.md`, `docs/guides/agent-memory.md`,
  `lib/normandy/dsl/agent.ex` (DX-34)
- Modify: `mix.exs` (`package.files`, DX-35)
- Modify: `MIGRATING-2.0.md` (`## New, non-breaking`)
- Test: modify `test/docs/devex_docs_test.exs`, `test/schema/field_options_test.exs`,
  `test/readme_test.exs`

**Interfaces:**
- Consumes: `test/docs/devex_docs_test.exs` (7.3g1). Task 7.3e has added a testing-guide line
  to README's "## Documentation" and `docs/guides/testing.md`. The model-id test covers that guide too.
- Produces: `field/3` and duplicate-schema `ArgumentError` messages (below); `"MIGRATING-2.0.md"`
  in `package.files`. Task 7.5's tarball check (in 7.5a/7.7) can rely on it.

- [ ] **Step 1: Write the failing tests**

In `test/docs/devex_docs_test.exs`, add after the DX-32 test:

```elixir
  test "DX-34: the README and the guides name one model, claude-opus-5-5" do
    ids =
      for path <- ["README.md" | Path.wildcard("docs/guides/*.md")],
          [id] <- Regex.scan(~r/claude-(?:opus|sonnet|haiku)-[0-9][\w-]*/, File.read!(path)),
          id != "claude-opus-5-5",
          do: {path, id}

    assert ids == [], "expected only claude-opus-5-5, found: #{inspect(ids)}"
  end

  test "DX-35: the Hex package ships MIGRATING-2.0.md" do
    files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)
    assert "MIGRATING-2.0.md" in files
  end

  describe "DX-20: Postgres store setup" do
    test "SessionStore.Postgres documents the Repo handle and its four migrations in order" do
      doc = moduledoc(Normandy.Behaviours.SessionStore.Postgres)
      assert doc =~ "`{Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo}`"
      refute doc =~ "repo: MyApp.Repo"

      assert doc =~
               "`Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`, " <>
                 "`MigrationAddResumePolicy` and `MigrationAddInflight`, in that order"
    end

    test "MemoryStore.Postgres documents the Repo handle" do
      assert moduledoc(Normandy.Behaviours.MemoryStore.Postgres) =~
               "`{Normandy.Behaviours.MemoryStore.Postgres, MyApp.Repo}`"
    end

    test "both new/0 docs say an application passes its Repo instead" do
      for mod <- [
            Normandy.Behaviours.SessionStore.Postgres,
            Normandy.Behaviours.MemoryStore.Postgres
          ] do
        assert function_doc(mod, :new, 0) =~
                 "An application passes its Repo module as the handle instead."
      end
    end
  end

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(mod)
    String.replace(doc, ~r/\s+/, " ")
  end

  defp function_doc(mod, name, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    Enum.find_value(docs, fn
      {{:function, ^name, ^arity}, _, _, %{"en" => doc}, _} -> String.replace(doc, ~r/\s+/, " ")
      _ -> nil
    end)
  end
```

(The Postgres modules compile in the test env: `ecto_sql` is fetched there. These tests are
not tagged `:postgres` and need no database.)

In `test/schema/field_options_test.exs`, change the existing assertion in
`Ecto options that did nothing are unknown options` from
`assert_raise ArgumentError, ~r{invalid option :#{opt} for field/3}, fn ->` to
`assert_raise ArgumentError, ~r{^field/3: unknown option :#{opt} for field :name; }, fn ->`.
Then add before `  test "valid options compile" do`:

```elixir
  test "an unknown option is named with its field and the options field/3 takes" do
    message =
      "field/3: unknown option :defaults for field :name; expected one of: :all_of, " <>
        ":any_of, :compute, :default, :description, :else_schema, :enum, :examples, " <>
        ":exclusive_maximum, :exclusive_minimum, :format, :if_schema, " <>
        ":include_in_json_schema, :max_items, :max_length, :maximum, :min_items, " <>
        ":min_length, :minimum, :one_of, :pattern, :redact, :required, " <>
        ":skip_default_validation, :then_schema, :unique_items, :virtual"

    assert_raise ArgumentError, message, fn ->
      compile(~s|field(:name, :string, defaults: :x)|)
    end
  end

  test "a second schema in one module is an ArgumentError naming the first" do
    source = """
    defmodule Normandy.Schema.FieldOptionsTest.Twice do
      use Normandy.Schema

      schema do
        field(:a, :string)
      end

      io_schema "again" do
        field(:b, :string)
      end
    end
    """

    assert_raise ArgumentError,
                 "schema already defined for Normandy.Schema.FieldOptionsTest.Twice on line 4; " <>
                   "a module defines one schema (schema/1 or io_schema/2)",
                 fn -> Code.compile_string(source) end
  end
```

(`grep -rn "invalid option :\|schema already defined" test` → only that one assertion uses the
old text. Without the `:` the grep also hits two test names that say "invalid options"
(`config_template_test.exs`, `base_agent_compaction_config_test.exs`); they are unrelated.)

Replace `test/readme_test.exs` with:

```elixir
defmodule Normandy.ReadmeTest do
  @moduledoc """
  Runs the README's quickstart against a stubbed Messages API: if the README stops
  running, this fails.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @client_line ~s|%Normandy.LLM.ClaudioAdapter{api_key: System.get_env("ANTHROPIC_API_KEY")}|

  test "the quickstart prints the answer and sends max_tokens 16_000 to claude-opus-5-5" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [
          %{"type" => "text", "text" => ~s({"chat_message": "Actors share nothing."})}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })
    end)

    assert capture_io(fn -> Code.eval_string(quickstart()) end) == "Actors share nothing.\n"
    assert_received {:request, %{"max_tokens" => 16_000, "model" => "claude-opus-5-5"}}
  end

  test "the quickstart prints the error of a failed turn" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
      })
    end)

    assert capture_io(fn -> Code.eval_string(quickstart()) end) ==
             "Turn failed: LLM call failed: authentication (401): invalid x-api-key\n"
  end

  # The README's Quick Start block, its client pointed at the Req.Test stub.
  defp quickstart do
    [block] =
      Regex.run(~r/## Quick Start.*?```elixir\n(.*?)```/s, File.read!("README.md"),
        capture: :all_but_first
      )

    # The swap below must not silently do nothing if the README changes.
    assert block =~ @client_line

    String.replace(
      block,
      @client_line,
      ~s|%Normandy.LLM.ClaudioAdapter{api_key: "test-key", | <>
        "options: %{req_options: [plug: {Req.Test, #{inspect(__MODULE__)}}, retry: false]}}"
    )
  end
end
```

(`LLM call failed: authentication (401): invalid x-api-key` is the observed
`Exception.message/1` of the `LLMError` for that response, probe at HEAD.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/docs/devex_docs_test.exs test/schema/field_options_test.exs test/readme_test.exs`
Expected: FAIL:
- DX-34: lists `{"README.md", "claude-sonnet-4-6"}`, `{"docs/guides/agent-memory.md", "claude-sonnet-4-5"}` ×3, `{"docs/guides/hooks.md", "claude-sonnet-4-5"}` ×2
- DX-35: `"MIGRATING-2.0.md" in files` fails
- DX-20: the three tests fail (the moduledoc says `repo: MyApp.Repo`)
- field options: the changed regex and the two new tests fail. The old message is
  `invalid option :defaults for field/3`; the old duplicate error is a `RuntimeError`
- readme: both tests fail (the quickstart prints nothing)

- [ ] **Step 3: DX-31 — `lib/normandy/schema.ex`**

In `__field__/4`: `    check_options!(type, opts, @field_opts, "field/3")` →
`    check_options!(name, type, opts, @field_opts)`.

In `__schema__/2`, replace
`      raise "schema already defined for #{inspect(module)} on line #{previous_line}"` with:

```elixir
      raise ArgumentError,
            "schema already defined for #{inspect(module)} on line #{previous_line}; " <>
              "a module defines one schema (schema/1 or io_schema/2)"
```

Delete the 3-arity helper:

```elixir
  defp check_options!(opts, valid, fun_arity) do
    case Enum.find(opts, fn {k, _} -> k not in valid end) do
      {k, _} -> raise ArgumentError, "invalid option #{inspect(k)} for #{fun_arity}"
      nil -> :ok
    end
  end
```

and replace the three 4-arity clauses:

```elixir
  defp check_options!({:parameterized, _}, _opts, _valid, _fun_arity) do
    :ok
  end

  defp check_options!({_, type}, opts, valid, fun_arity) do
    check_options!(type, opts, valid, fun_arity)
  end

  defp check_options!(_type, opts, valid, fun_arity) do
    check_options!(opts, valid, fun_arity)
  end
```

with:

```elixir
  defp check_options!(_name, {:parameterized, _}, _opts, _valid), do: :ok

  defp check_options!(name, {_, type}, opts, valid), do: check_options!(name, type, opts, valid)

  defp check_options!(name, _type, opts, valid) do
    case Enum.find(opts, fn {k, _} -> k not in valid end) do
      {k, _} ->
        raise ArgumentError,
              "field/3: unknown option #{inspect(k)} for field #{inspect(name)}; " <>
                "expected one of: #{valid |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}"

      nil ->
        :ok
    end
  end
```

(`grep -n "check_options!" lib/normandy/schema.ex` → the call in `__field__/4` and the three
new clauses. Nothing else calls it.)

- [ ] **Step 4: DX-20 — the Postgres store docs**

`lib/normandy/behaviours/session_store/postgres.ex`, moduledoc, replace:

```
    Configure via `{Normandy.Behaviours.SessionStore.Postgres, repo: MyApp.Repo}` and
    run `Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`,
    `MigrationAddResumePolicy` and `MigrationAddInflight` from a host migration.
```

with:

```
    Pass it as `{Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo}` (the handle is
    the Repo module itself), for example as `Turn.Session.new/1`'s `:store`. Its tables
    come from four migrations: call the `up/0` of
    `Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`,
    `MigrationAddResumePolicy` and `MigrationAddInflight`, in that order, from one host
    migration, and their `down/0` in the reverse order (the distributed sessions guide
    has the migration module).
```

and replace
`    @doc "Test/default handle: the Repo configured for :normandy. Returns the Repo module."` with:

```elixir
    @doc """
    Returns the first Repo of `config :normandy, :ecto_repos`, the handle Normandy's own
    tests use. An application passes its Repo module as the handle instead. Raises
    `ArgumentError` when `:ecto_repos` is not set for `:normandy`.
    """
```

`lib/normandy/behaviours/memory_store/postgres.ex`, moduledoc, replace:

```
    Durable, cluster-shared `MemoryStore` over Postgres. The handle is the host's Ecto
    Repo module; run `Normandy.Behaviours.MemoryStore.Postgres.Migration` from a host
    migration.
```

with:

```
    Durable, cluster-shared `MemoryStore` over Postgres. The handle is the host's Ecto
    Repo module: pass `{Normandy.Behaviours.MemoryStore.Postgres, MyApp.Repo}`, for
    example as `Normandy.Tools.Memory.new/1`'s `:store`. Its tables come from
    `Normandy.Behaviours.MemoryStore.Postgres.Migration`: call its `up/0` and `down/0`
    from a host migration.
```

and replace `    @doc "Test/default handle: the Repo configured for :normandy."` with the same four-line
`@doc` as `SessionStore.Postgres.new/0` above. (`Application.fetch_env!/2` raises
`ArgumentError` for an unset key. The guide's migration module,
`docs/guides/distributed_sessions.md:25-40`, already calls the four in this order.)

- [ ] **Step 5: DX-34 — one model id and the quickstart**

```sh
perl -pi -e 's/claude-sonnet-4-[56]/claude-opus-5-5/g' README.md docs/guides/hooks.md \
  docs/guides/agent-memory.md lib/normandy/dsl/agent.ex
grep -rn "claude-sonnet" README.md docs/guides lib | wc -l    # 0
```

Seven replacements: README 1, hooks.md 2, agent-memory.md 3, `dsl/agent.ex` 1 (the
`guardrails` example). Two ids are left alone on purpose:
`lib/normandy/context/token_counter.ex:42`'s default argument `"claude-haiku-4-5-20251001"`,
which is code (changing it changes `count_message/3`'s behaviour), and
`MIGRATING-2.0.md:14`'s 1.x example, which shows `temperature: 0.7`, which Opus rejects.

In `README.md` "## Quick Start", replace:

```
# 3. Run a turn
{:ok, agent, response} =
  Normandy.Agents.BaseAgent.run(agent, %{
    chat_message: "Explain Elixir's actor model in one sentence."
  })
```

with:

```
# 3. Run a turn: {:ok, agent, response} with the updated agent (it holds the
#    conversation), or {:error, exception}, e.g. a %Normandy.LLMError{}
input = %{chat_message: "Explain Elixir's actor model in one sentence."}

case Normandy.Agents.BaseAgent.run(agent, input) do
  {:ok, _agent, response} -> IO.puts(response.chat_message)
  {:error, error} -> IO.puts("Turn failed: " <> Exception.message(error))
end
```

In README "## Documentation", add after the distributed sessions guide line (Task 7.3e's
testing-guide line stays where 7.3e put it):

```
- **🪝 [Hooks guide](docs/guides/hooks.md)** — lifecycle hooks: rewrite, halt, inject, audit.
- **🧠 [Agent memory guide](docs/guides/agent-memory.md)** — the memory tool and its stores.
```

- [ ] **Step 6: DX-35 — package files**

In `mix.exs` `package/0`:
`      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),` →
`      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md MIGRATING-2.0.md),`

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/docs test/schema test/readme_test.exs test/hooks/guide_examples_test.exs`
Expected: PASS (`devex_docs_test.exs`: 6 tests; `field_options_test.exs`: +2; `readme_test.exs`: 2).
Run `mix hex.build --unpack -o /tmp/w7-pkg && ls /tmp/w7-pkg/MIGRATING-2.0.md` → the file is
listed (no publish; delete `/tmp/w7-pkg` afterwards with `rm -r /tmp/w7-pkg`).

- [ ] **Step 8: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3g2.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3g2.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite: the Postgres modules change docs only.

- [ ] **Step 9: MIGRATING-2.0.md**

Append to the end of `## New, non-breaking`:

```markdown
- An unknown `field/3` option raises
  `ArgumentError` "field/3: unknown option :x for field :name; expected one of: …", naming
  the field and listing the options (it named neither). A second `schema`/`io_schema` in
  one module raises `ArgumentError` instead of a bare `RuntimeError`.
- The Hex package includes MIGRATING-2.0.md.
- The README quickstart and the guides use `claude-opus-5-5`; the quickstart reads
  `response.chat_message` and handles `{:error, exception}`.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/schema.ex lib/normandy/behaviours/session_store/postgres.ex \
  lib/normandy/behaviours/memory_store/postgres.ex README.md docs/guides/hooks.md \
  docs/guides/agent-memory.md lib/normandy/dsl/agent.ex mix.exs MIGRATING-2.0.md \
  test/docs/devex_docs_test.exs test/schema/field_options_test.exs test/readme_test.exs
git commit -m "fix(schema): field/3 errors name the field and the valid options; DX-20, DX-34, DX-35 docs"
```

---

### Task 7.3h-i: DSL agent blocks with a mixed prompt fail to compile (DX-23, decision 27 E3, decision 28 A2)

An `agent do ... end` block with `system_prompt` beside `background`, `steps` or
`output_instructions` now raises `ArgumentError` while the module compiles. Today it compiles
and silently drops the structured prompt (`apply_system_prompt/1`'s `cond`,
`dsl/agent.ex:661-683`: `system_prompt` wins). The error is an `ArgumentError`, like the
DSL's other compile-time checks (`memory/1`, `guardrails/3`, `hooks/1`, all tested through
`Code.compile_string/1` on the CI matrix 1.15-1.19: `test/dsl/agent_memory_test.exs:73-86`,
`agent_guardrails_test.exs:132-146`, `agent_hooks_test.exs:45-70`). Verified on 1.19.5: a raise
in `__before_compile__/1` reaches `Code.compile_string/1`'s caller as that `ArgumentError`.

An `agent` block without `model` still compiles, and `new/1` still serves it when given
`:model` (decision 28 A2: Q keeps the "model given to `new/1`" path). The runtime check in
`init_config!/4` (`"<Mod>.new/1: requires :model (a string), got none"`), its two tests in
`test/dsl/agent_test.exs` (`"an agent that declares no model raises, naming new/1"`,
`"a model given to new/1 serves an agent that declares none"`, both on `NoModelAgent`) and
MIGRATING §21's sentence on it stay unchanged.

Scoping the `import` into `agent do` (the other half of DX-23 in `devex.md`) is out of scope:
decision 27 E3 asks only for the compile errors, and the clash is documented
(`dsl/agent.ex:58-77`).

**Files:**
- Modify: `lib/normandy/dsl/agent.ex` (moduledoc "Features" bullet; `agent/1` doc; new `check_declarations!/1`; `__before_compile__/1`)
- Modify: `MIGRATING-2.0.md` (create `## 46. DSL, Workflow and Toolset`)
- Test: modify `test/dsl/agent_test.exs`

**Interfaces:**
- Consumes: the module attributes the DSL macros set (`:agent_system_prompt`, `:agent_background`, `:agent_steps`, `:agent_output_instructions`).
- Produces: the compile-time `ArgumentError` message
  `"<Mod>: system_prompt cannot be combined with <names>; use system_prompt alone or background/steps/output_instructions"`
  (`<names>` = the declared ones among `background, steps, output_instructions`, in that order, joined by `", "`).

Callers checked (every `use Normandy.DSL.Agent` in the repo:
`grep -rln "use Normandy.DSL.Agent" lib test docs e2e README.md` → 14 hits outside
`examples/`). None declares `system_prompt` beside a structured prompt: a scratch run of this
change on `4ac60ee` gave `mix test` 3642 tests, 0 failures, with only the test below added.
`e2e/09_dsl.exs` declares `model` and `system_prompt` only; `docs/guides/agent-memory.md:89-95`
and the `Normandy.DSL.Agent` moduledoc examples declare no mixed prompt. The `examples/` apps
are deleted in Task 7.3h-v.

- [ ] **Step 1: Write the failing test**

In `test/dsl/agent_test.exs`, insert before `    test "a missing client raises ArgumentError naming new/1" do`
(after `"a misspelled :model is named, not reported missing"`, which stays as it is, on
`NoModelAgent`):

```elixir
    test "system_prompt beside background, steps or output_instructions does not compile" do
      assert_raise ArgumentError,
                   "Normandy.DSLTest.MixedPromptAgent: system_prompt cannot be combined with " <>
                     "background, output_instructions; use system_prompt alone or " <>
                     "background/steps/output_instructions",
                   fn ->
                     Code.compile_string("""
                     defmodule Normandy.DSLTest.MixedPromptAgent do
                       use Normandy.DSL.Agent

                       agent do
                         model("m")
                         system_prompt("You are helpful.")
                         background("Background")
                         output_instructions("Be brief")
                       end
                     end
                     """)
                   end
    end

```

`NoModelAgent` and its three tests stay.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/dsl/agent_test.exs`
Expected: FAIL, 1 failure: the new test reports `Expected exception ArgumentError but nothing was raised` (the module compiles today).

- [ ] **Step 3: The compile-time check**

In `lib/normandy/dsl/agent.ex`, add after `put_declared_hooks/2` (the private helper sits before
`__before_compile__/1`, whose expansion calls it):

```elixir
  # The agent block's own contradictions, checked when the module compiles.
  defp check_declarations!(module) do
    structured =
      Enum.filter(
        [
          background: :agent_background,
          steps: :agent_steps,
          output_instructions: :agent_output_instructions
        ],
        fn {_name, attr} -> Module.get_attribute(module, attr) != nil end
      )

    if Module.get_attribute(module, :agent_system_prompt) != nil and structured != [] do
      raise ArgumentError,
            "#{inspect(module)}: system_prompt cannot be combined with " <>
              Enum.map_join(structured, ", ", fn {name, _attr} -> Atom.to_string(name) end) <>
              "; use system_prompt alone or background/steps/output_instructions"
    end

    :ok
  end
```

Place it immediately above the `# credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity`
line that precedes `defmacro __before_compile__`. Then change the macro head:

```elixir
  defmacro __before_compile__(_env) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
```

to

```elixir
  defmacro __before_compile__(env) do
    check_declarations!(env.module)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
```

`Module.get_attribute/2` works here: `__before_compile__/1` expands while the module is still
open. The values are the evaluated ones (a `background(System.get_env("B"))` that yields `nil`
counts as not declared).

`init_config!/4`'s runtime `requires :model` check stays: it is the error for an agent that
declares no model and is given none in `new/1`.

- [ ] **Step 4: Docs**

In the moduledoc "## Features" list, replace

```
  - Configuration checked when the agent is built (`new/1` raises without a model)
```

with

```
  - Configuration checked when the agent is built (`new/1` raises without a model)
  - Checked when the module compiles: an `agent` block with `system_prompt` beside
    `background`, `steps` or `output_instructions` raises `ArgumentError`
```

In `agent/1`'s `@doc` "## Available Options", replace

```
  - `system_prompt` - System prompt text (optional)
```

with

```
  - `system_prompt` - System prompt text (optional). Not together with `background`,
    `steps` or `output_instructions`: the module does not compile
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/dsl`
Expected: PASS, 110 tests, 0 failures (after Tasks 7.0a-7.3g2: Task 7.0c adds one test under `test/dsl`; this task adds one; on `4ac60ee` alone the count is 109).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3h-i.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3h-i.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite: nothing here touches a store, the registry or `Turn.Server`.

- [ ] **Step 7: MIGRATING-2.0.md**

`## 21.` does not change (its "an agent that declares no model and is given none in `new/1`
raises `ArgumentError`" sentence stays true).

Create the section after `## 45. Testing support and docs` (Task 7.2a) and before
`## Known limits of 2.0`:

```markdown
## 46. DSL, Workflow and Toolset

- An `agent` block with `system_prompt` and any of `background`, `steps` or
  `output_instructions` no longer compiles (`ArgumentError` naming the module and the
  conflicting declarations). `system_prompt` used to win and the others were dropped without a
  word. Keep `system_prompt` alone, or move its text into `background`.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/dsl/agent.ex test/dsl/agent_test.exs MIGRATING-2.0.md
git commit -m "feat(dsl)!: an agent block with a mixed prompt fails to compile"
```

---

### Task 7.3h-ii: Remove `Workflow` `execute/1`'s `:context` option (DX-24, decision 27 E2)

`execute/1` validates `:context` (`dsl/workflow.ex:156-161`), stores it in the run state
(`:454`, `:483`) and nothing ever reads it (`grep -n "context" lib/normandy/dsl/workflow.ex` →
lines 156, 160, 454, 462, 480, 483 only). Removing it makes a caller who passes it get the
house-style unknown-option `ArgumentError` (verified in scratch:
`"Normandy.DSL.WorkflowTest.SequentialWorkflow.execute/1: unknown option :context; supported: :agents, :initial_input"`).

Callers: `grep -rn "context:" test/dsl/workflow*.exs e2e docs/guides README.md | grep -v "tool_context\|context_provider\|telemetry_span_context"`
→ 1 hit, `test/dsl/workflow_test.exs:176` (rewritten below). `MIGRATING-2.0.md:876` ("a
workflow's `execute/1` `:context` is a plain map") becomes stale (Step 6).

**Files:**
- Modify: `lib/normandy/dsl/workflow.ex` (`@execute_opts_schema`; generated `execute/1`, `execute_workflow/3`)
- Modify: `MIGRATING-2.0.md` (§30 sentence; §46 bullet)
- Test: modify `test/dsl/workflow_test.exs`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3` through `__validate_execute_opts__/2` (unchanged).
- Produces: `execute/1` options `:agents`, `:initial_input` only.

- [ ] **Step 1: Write the failing test**

In `test/dsl/workflow_test.exs`, replace the test `"passes context through workflow"` with:

```elixir
    test ":context is no longer an option (DX-24)", %{agents: agents_map} do
      assert_raise ArgumentError,
                   "Normandy.DSL.WorkflowTest.SequentialWorkflow.execute/1: unknown option " <>
                     ":context; supported: :agents, :initial_input",
                   fn ->
                     SequentialWorkflow.execute(
                       agents: agents_map,
                       initial_input: "test",
                       context: %{user_id: 123}
                     )
                   end
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/dsl/workflow_test.exs`
Expected: FAIL, 1 failure: `Expected exception ArgumentError but nothing was raised`.

- [ ] **Step 3: Remove the option**

In `lib/normandy/dsl/workflow.ex`, in `@execute_opts_schema`, delete the `context:` entry so the
schema ends:

```elixir
                         initial_input: [
                           type: :any,
                           required: true,
                           doc: "The first step's input."
                         ]
                       )
```

In the generated `execute/1`, delete `        context = Keyword.fetch!(opts, :context)` and change
`execute_workflow(steps, agents_map, initial_input, context)` to
`execute_workflow(steps, agents_map, initial_input)`. Change
`defp execute_workflow(steps, agents_map, initial_input, context) do` to
`defp execute_workflow(steps, agents_map, initial_input) do` and delete `          context: context,`
from its `initial_state` map, which becomes:

```elixir
        initial_state = %{
          results: %{},
          current_input: initial_input
        }
```

Check: `grep -n "context" lib/normandy/dsl/workflow.ex` → no output.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/dsl/workflow_test.exs test/dsl/workflow_transform_integration_test.exs test/options_test.exs test/options_coverage_test.exs`
Expected: PASS, 0 failures (62 tests at HEAD `9131274`).

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3h-ii.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3h-ii.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite.

- [ ] **Step 6: MIGRATING-2.0.md**

In `## 30.`, replace `` `:manager_prompt` is a string; a workflow's `execute/1` `:context` is a plain map. ``
with `` `:manager_prompt` is a string. ``

Append to `## 46.`:

```markdown
- A workflow's `execute/1` no longer takes `:context`; passing it raises
  `ArgumentError` `"MyWorkflow.execute/1: unknown option :context; supported: :agents, :initial_input"`.
  It was accepted and never reached a step. Pass what a step needs in its input or its agent's
  config.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/dsl/workflow.ex test/dsl/workflow_test.exs MIGRATING-2.0.md
git commit -m "feat(dsl)!: remove Workflow execute/1's unused :context option"
```

---

### Task 7.3h-iii: Remove the three `Toolset` schema filters (DX-35, decision 27 E4)

`Toolset.filter_by_required_params/2`, `filter_by_param_type/2` and `tools_with_constraint/2`
have no caller in `lib/` (`grep -rn "filter_by_required_params\|filter_by_param_type\|tools_with_constraint" lib`
→ only their definitions and doc examples in `lib/normandy/tools/toolset.ex`). Their private
helpers `keep/2`, `has_required_params?/1`, `has_param_type?/2` and `has_constraint?/2` have no
other caller (`grep -n "keep(\|has_required_params?\|has_param_type?\|has_constraint?" lib/normandy/tools/toolset.ex`
→ the definitions and the three filters only). Verified in scratch: removing the six compiles
with `--warnings-as-errors` (`Normandy.Schema.Introspection` stays used by
`get_schema_introspection/1`).

Task 7.3g (DX-32) runs earlier and may rewrite these functions' `iex>` examples; anchor the
deletion on the function heads below, not on doc text.

Tests that use them (`grep -rn "filter_by_required_params\|filter_by_param_type\|tools_with_constraint" test`
→ 19 lines in 2 files): `test/tools/toolset_metadata_test.exs` (3 describe blocks, 9 tests; 1
assertion block in `"metadata methods work seamlessly with schema-based tools"`; 3 assertions in
`"handles empty registry gracefully"`; the test `"handles tools with no properties in schema"`)
and `test/tools/toolset_test.exs` (2 tests that used a filter to show options are dropped with
their tool).

**Files:**
- Modify: `lib/normandy/tools/toolset.ex`
- Modify: `MIGRATING-2.0.md` (§46 bullet)
- Test: modify `test/tools/toolset_metadata_test.exs`, `test/tools/toolset_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Normandy.Tools.Toolset` without `filter_by_required_params/2`, `filter_by_param_type/2`, `tools_with_constraint/2`.

- [ ] **Step 1: Write the failing test and drop the filter tests**

In `test/tools/toolset_metadata_test.exs`:

1. Delete the three blocks `describe "filter_by_required_params/2" do ... end`,
   `describe "filter_by_param_type/2" do ... end` and `describe "tools_with_constraint/2" do ... end`
   (everything from `  describe "filter_by_required_params/2" do` up to, not including,
   `  describe "introspect_schema/2" do`).
2. In `"metadata methods work seamlessly with schema-based tools"`, delete:

   ```elixir

      # Find constraints
      enum_tools = Toolset.tools_with_constraint(registry, :enum)
      assert "enhanced_calculator" in enum_tools
   ```

3. In `describe "edge cases"`, replace the test `"handles empty registry gracefully"` and the
   test `"handles tools with no properties in schema"` that follows it with:

   ```elixir
    test "handles empty registry gracefully" do
      registry = Toolset.new()

      assert Toolset.list_metadata(registry) == []
    end

    test "the 1.x schema filters are gone" do
      Code.ensure_loaded!(Toolset)
      refute function_exported?(Toolset, :filter_by_required_params, 2)
      refute function_exported?(Toolset, :filter_by_param_type, 2)
      refute function_exported?(Toolset, :tools_with_constraint, 2)
    end
   ```

In `test/tools/toolset_test.exs`, replace

```elixir
    test "a filter drops the timeouts of the tools it drops" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, timeout: 1_000)
      filtered = Toolset.filter_by_param_type(toolset, "no-such-type")

      assert Toolset.timeout(toolset, "calculator") == 1_000
      assert Toolset.timeout(filtered, "calculator") == nil
    end
```

with

```elixir
    test "unregister/2 drops the timeout of the tool it drops" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, timeout: 1_000)

      assert Toolset.timeout(toolset, "calculator") == 1_000
      assert Toolset.timeout(Toolset.unregister(toolset, "calculator"), "calculator") == nil
    end
```

and replace

```elixir
    test "unregister/2 and the filters drop the caps of the tools they drop" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, max_result_chars: 500)

      assert Toolset.max_result_chars(Toolset.unregister(toolset, "calculator"), "calculator") ==
               :error

      filtered = Toolset.filter_by_param_type(toolset, "no-such-type")
      assert Toolset.max_result_chars(filtered, "calculator") == :error
    end
```

with

```elixir
    test "unregister/2 drops the cap of the tool it drops" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, max_result_chars: 500)

      assert Toolset.max_result_chars(Toolset.unregister(toolset, "calculator"), "calculator") ==
               :error
    end
```

Check: `grep -rn "filter_by_required_params\|filter_by_param_type\|tools_with_constraint" test` →
the three `refute function_exported?` lines only.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/tools/toolset_metadata_test.exs test/tools/toolset_test.exs`
Expected: FAIL, 1 failure: `"the 1.x schema filters are gone"` (`Expected false or nil, got true` on the first `refute`).

- [ ] **Step 3: Remove the functions**

In `lib/normandy/tools/toolset.ex` delete, each with the `@doc` block directly above it:

- `@spec filter_by_required_params(t(), boolean()) :: t()` and `def filter_by_required_params/2`
- `@spec filter_by_param_type(t(), String.t()) :: t()` and `def filter_by_param_type/2`
- the comment `# The filtered tools, with the registration options of the tools kept.` and `defp keep/2`
- `@spec tools_with_constraint(t(), atom()) :: [String.t()]` and `def tools_with_constraint/2`
- `defp has_required_params?/1`, `defp has_param_type?/2`, `defp has_constraint?/2`

After the deletion, `list_metadata/1`'s `end` is followed by the `@doc` of `introspect_schema/2`,
and `get_schema_introspection/1`'s `end` by the `@doc` of `valid_name?/1`.

Check: `grep -n "filter_by\|tools_with_constraint\|defp keep\|has_required_params?\|has_param_type?\|has_constraint?" lib/normandy/tools/toolset.ex`
→ no output; `mix compile --warnings-as-errors` exits 0.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/tools/toolset_metadata_test.exs test/tools/toolset_test.exs`
Expected: PASS (48 tests at HEAD `9131274`), 0 failures.

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3h-iii.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3h-iii.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0 (`CHANGELOG.md:704` names `filter_by_required_params/2`
unqualified in a 1.x entry, which ExDoc does not link; leave history as it is). No tagged suite.

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 46.`:

```markdown
- `Toolset.filter_by_required_params/2`, `Toolset.filter_by_param_type/2` and
  `Toolset.tools_with_constraint/2` are removed; nothing in Normandy called them. Filter
  `Toolset.list_metadata/1` (each entry has `:input_schema`) or `Toolset.list/1` yourself.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/tools/toolset.ex test/tools/toolset_metadata_test.exs \
  test/tools/toolset_test.exs MIGRATING-2.0.md
git commit -m "feat(tools)!: remove the three unused Toolset schema filters"
```

---

### Task 7.3h-iv: `ModelCatalog.Static` logs its deprecation once per VM (DX-33, decision 27 E6, ruling R7)

`ModelCatalog.Static` is deprecated only in its moduledoc (`behaviours/model_catalog.ex:46-58`)
and MIGRATING §5 (`MIGRATING-2.0.md:98`). `@deprecated` would not help: its only function is an
`@impl` `defdelegate context_window/2` that users never call. Per R7, a config that names it logs
one `Logger.warning` per VM, at `BaseAgent.init/1` and at `ConfigTemplate.rebuild/3` (a 1.x
template naming it reaches only the second). The flag is a `:persistent_term` key; two racing
first calls may both log (documented, harmless). The message names modules only, never the
catalog's opts (decision 6).

The hook points: `init/1` (`base_agent.ex:76`, after `check_init!/1`), not `check_init!/1`
itself, whose comment promises "no side effect" and which `AgentPool.start_link/1` also calls;
and the end of `ConfigTemplate.rebuild/3` (`config_template.ex:244-245`, after
`validate_compaction_config!/2` and `validate_client_options!/1`, so a template that fails a
check logs nothing). `Turn.Server` calls `rebuild/3` on load; the change adds only a log line
there, nothing persisted, so the tagged suites are not needed.

**Files:**
- Modify: `lib/normandy/behaviours/model_catalog.ex` (`Static`)
- Modify: `lib/normandy/agents/base_agent.ex` (alias; `init/1`; new `warn_deprecated_catalog/1`)
- Modify: `lib/normandy/agents/config_template.ex` (`rebuild/3`)
- Modify: `MIGRATING-2.0.md` (§5 bullet)
- Test: create `test/behaviours/model_catalog_static_test.exs`

**Interfaces:**
- Consumes: `Normandy.Behaviours.Config` `model_catalog: {module, opts}`.
- Produces: `ModelCatalog.Static.warn_deprecated/0 :: :ok` and `warned_key/0` (both `@doc false`); `BaseAgent.warn_deprecated_catalog(Config.t() | nil) :: :ok` (`@doc false`). No telemetry event (decision 27 A2).

- [ ] **Step 1: Write the failing test**

Create `test/behaviours/model_catalog_static_test.exs`:

```elixir
defmodule Normandy.Behaviours.ModelCatalogStaticTest do
  @moduledoc """
  DX-33 (decision 27 E6): a config whose model catalog is the deprecated
  `ModelCatalog.Static` logs one warning per VM, from `BaseAgent.init/1` and from
  `ConfigTemplate.rebuild/3`. The flag is VM-global, so this module is not async.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ConfigTemplate}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.ModelCatalog.{ModelsAPI, Static}
  alias Normandy.Test.OwnLog
  alias Normandy.Test.StubClient
  alias Normandy.Tools.Toolset

  @warning "Normandy.Behaviours.ModelCatalog.Static is deprecated and will be removed in 3.0; " <>
             "set model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}, which " <>
             "answers the same (this warning is logged once per VM)"

  # init/1 and rebuild/3 log in the caller, so OwnLog keeps exactly their lines.
  setup do
    :persistent_term.erase(Static.warned_key())
    on_exit(fn -> :persistent_term.erase(Static.warned_key()) end)
  end

  defp init(catalog, opts \\ []) do
    BaseAgent.init(%{
      client: %StubClient{},
      model: "m",
      behaviours: %Config{model_catalog: {catalog, opts}}
    })
  end

  defp supplement do
    %{
      toolset: Toolset.new(),
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token -> %StubClient{} end
    }
  end

  test "init/1 warns once per VM for ModelCatalog.Static, never for ModelsAPI" do
    assert OwnLog.capture(fn -> init(ModelsAPI) end) == ""

    first = OwnLog.capture(fn -> init(Static, secret: "hunter2") end)
    assert first =~ "[warning] " <> @warning
    refute first =~ "hunter2"

    assert OwnLog.capture(fn -> init(Static) end) == ""
  end

  test "ConfigTemplate.rebuild/3 warns for a template naming ModelCatalog.Static" do
    template = ConfigTemplate.from_config(init(Static), "t")
    :persistent_term.erase(Static.warned_key())

    log = OwnLog.capture(fn -> ConfigTemplate.rebuild(template, supplement(), "TOKEN") end)
    assert log =~ "[warning] " <> @warning
    assert OwnLog.capture(fn -> ConfigTemplate.rebuild(template, supplement(), "TOKEN") end) == ""
  end
end
```

(`StubClient` stays in `test/support` after Task 7.3c, which deletes only the three scripted
clients. The default compactor is `NoOp`, so `validate_compaction_config!/2` accepts a
non-Claudio client with either catalog.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/behaviours/model_catalog_static_test.exs`
Expected: FAIL, 2 failures: `** (UndefinedFunctionError) function Normandy.Behaviours.ModelCatalog.Static.warned_key/0 is undefined or private` (in `setup`).

- [ ] **Step 3: The warning**

In `lib/normandy/behaviours/model_catalog.ex`, replace the body of `defmodule Static` after its
moduledoc:

```elixir
    @behaviour Normandy.Behaviours.ModelCatalog

    @impl true
    defdelegate context_window(model, opts), to: Normandy.Behaviours.ModelCatalog.ModelsAPI
  end
```

with

```elixir
    @behaviour Normandy.Behaviours.ModelCatalog

    require Logger

    @warned_key {__MODULE__, :deprecation_warned}

    @impl true
    defdelegate context_window(model, opts), to: Normandy.Behaviours.ModelCatalog.ModelsAPI

    @doc false
    # Logs the deprecation once per VM (a :persistent_term flag); `BaseAgent.init/1` and
    # `ConfigTemplate.rebuild/3` call it for a config whose model_catalog is this module.
    # Two first calls racing may both log; every later call logs nothing.
    @spec warn_deprecated() :: :ok
    def warn_deprecated do
      unless :persistent_term.get(@warned_key, false) do
        :persistent_term.put(@warned_key, true)

        Logger.warning(
          "Normandy.Behaviours.ModelCatalog.Static is deprecated and will be removed in 3.0; " <>
            "set model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}, which " <>
            "answers the same (this warning is logged once per VM)"
        )
      end

      :ok
    end

    @doc false
    # The flag warn_deprecated/0 sets, for tests that check the warning.
    @spec warned_key() :: {__MODULE__, :deprecation_warned}
    def warned_key, do: @warned_key
  end
```

Append one paragraph at the end of the `Static` moduledoc (after "The old static model table
is gone."):

```
    A config that names it logs one deprecation warning per VM, from
    `Normandy.Agents.BaseAgent.init/1` or `Normandy.Agents.ConfigTemplate.rebuild/3`.
```

In `lib/normandy/agents/base_agent.ex`, add `alias Normandy.Behaviours.ModelCatalog` after
`alias Normandy.Behaviours.Hooks`. In `init/1`, after
`    behaviours = Keyword.fetch!(opts, :behaviours)` add:

```elixir
    :ok = warn_deprecated_catalog(behaviours)
```

After the `end` that closes `check_init!/1` (anchor on the function, not on what follows: Task
7.3a gave `reset_memory/1` a `@doc` there), add:

```elixir

  @doc false
  # init/1 and ConfigTemplate.rebuild/3: ModelCatalog.Static logs its deprecation once
  # per VM. Only the module is checked, never the catalog's opts.
  @spec warn_deprecated_catalog(Config.t() | nil) :: :ok
  def warn_deprecated_catalog(%Config{model_catalog: {ModelCatalog.Static, _opts}}),
    do: ModelCatalog.Static.warn_deprecated()

  def warn_deprecated_catalog(_behaviours), do: :ok
```

(`Config` is already aliased to `Normandy.Behaviours.Config` in this module. The full names
`Normandy.Behaviours.ModelCatalog.ModelsAPI`/`.Static` in `validate_compaction_config!/2` stay
as they are.)

In `lib/normandy/agents/config_template.ex`, `rebuild/3` ends:

```elixir
    |> BaseAgent.validate_compaction_config!({__MODULE__, :rebuild, 3})
    |> validate_client_options!()
  end
```

Change it to:

```elixir
    |> BaseAgent.validate_compaction_config!({__MODULE__, :rebuild, 3})
    |> validate_client_options!()
    |> tap(&BaseAgent.warn_deprecated_catalog(&1.behaviours))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/behaviours/model_catalog_static_test.exs test/agents/config_template_test.exs`
Expected: PASS (31 tests at HEAD `9131274`), 0 failures. `config_template_test.exs:468` ("a 1.x
template naming ModelCatalog.Static still decodes") only decodes the atom; no log.

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3h-iv.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3h-iv.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; credo clean (the alias avoids credo's nested-module suggestion,
seen in scratch); docs exit 0. No tagged suite (log only; nothing persisted, no store call).

- [ ] **Step 6: MIGRATING-2.0.md**

In `## 5.`, replace

```markdown
- `ModelCatalog.Static` is deprecated. It delegates to `ModelsAPI` and will be removed in 3.0.
  Its static model table is gone. Templates persisted by 1.x name it, which is why it stays.
```

with

```markdown
- `ModelCatalog.Static` is deprecated. It delegates to `ModelsAPI` and will be removed in 3.0.
  Its static model table is gone. Templates persisted by 1.x name it, which is why it stays.
  A config that names it logs one warning per VM (from `BaseAgent.init/1` or
  `ConfigTemplate.rebuild/3`); set `model_catalog: {ModelCatalog.ModelsAPI, []}` and re-save
  persisted templates to silence it.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/behaviours/model_catalog.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/agents/config_template.ex test/behaviours/model_catalog_static_test.exs \
  MIGRATING-2.0.md
git commit -m "feat(behaviours): ModelCatalog.Static logs its deprecation once per VM"
```

---

### Task 7.3h-v: Delete the 1.x example apps; `examples/README.md` points at the guides (DX-29, decision 27 E1, ruling R7, decision 28 A4)

Both apps use removed 1.x APIs and do not compile against 2.0
(`examples/agent_horde/lib/agent_horde/pipeline.ex:107` calls `Normandy.Tools.BaseTool.run/1`;
`tools/exa_search.ex:28` has `defimpl Normandy.Tools.BaseTool`). Tracked files:
`git ls-files examples | awk -F/ '{print $2}' | sort | uniq -c` → 24 `agent_horde`, 27
`customer_support_app`, 1 `README.md`, 1 `tools` (`examples/tools/weather.ex`, kept: MIGRATING §24
and `test/support/normandy_integration_helper.ex:84` use it).

On disk, the apps also hold ignored, untracked files: `git status --short --ignored examples` →
`!! examples/agent_horde/_build/`, `deps/`, `erl_crash.dump`,
`reports/how-does-the-raft-consensus-algorithm-work-20260620005509.md`,
`!! examples/customer_support_app/_build/`, `deps/`. They are ignored only by the apps' own
`.gitignore` files (`examples/agent_horde/.gitignore`: `reports/*`, `_build/`, `deps/`;
`examples/customer_support_app/.gitignore`: `/_build/`, `/deps/`), except `erl_crash.dump`, which
the root `.gitignore:17` ignores everywhere. `git rm -r` deletes those tracked `.gitignore` files,
so the `_build/`, `deps/` and `reports/` leftovers become **untracked** (shown by `git status`).
The implementer does not delete them (deleting directories needs `rm -rf`, forbidden without Q's
confirmation) and must not `git add` them: right after the `git rm -r` the implementer reports
them (Step 4) and Q removes both directories (Step 5, decision 28 A4a). They are build output and
a generated report; nothing is lost.

Other references (`git grep -n "examples/\|customer_support\|agent_horde\|CustomerSupport\|AgentHorde" -- ':!examples' ':!investigations' ':!docs/superpowers' ':!CHANGELOG.md'`):
`MIGRATING-2.0.md:599` (`examples/tools/weather.ex`, kept), `test/support/normandy_integration_helper.ex:84-90`
(the weather tool, kept), `marketing/demo-1.0/agent-horde-script.md:25,35,42,44` (the 1.0 demo
script; it describes the 1.0 release and keeps its text, with a one-line note at the top that it
was written for 1.0 and the app is gone in 2.0: Step 8, decision 28 A4b). `mix.exs`, `.formatter.exs`,
`.credo.exs` and `.github/` name no example (`grep -rn "examples" mix.exs .formatter.exs .credo.exs .github` → no output).

**Files:**
- Delete: `examples/customer_support_app/` (27 tracked files), `examples/agent_horde/` (24 tracked files)
- Modify: `examples/README.md` (rewritten)
- Modify: `marketing/demo-1.0/agent-horde-script.md` (one note line at the top)
- Modify: `MIGRATING-2.0.md` (§46 bullet)
- Test: create `test/docs/examples_readme_test.exs`

**Interfaces:**
- Consumes: the guides `docs/guides/distributed_sessions.md`, `docs/guides/agent-memory.md`, `docs/guides/hooks.md`, and `docs/guides/testing.md` (created by Task 7.3e, which runs before this task).
- Produces: nothing in `lib/`.

- [ ] **Step 1: Write the failing test**

Create `test/docs/examples_readme_test.exs`:

```elixir
defmodule Normandy.Docs.ExamplesReadmeTest do
  @moduledoc """
  DX-29 (decision 27 E1): the 1.x example apps are gone, and `examples/README.md`
  points at the guides; every relative link in it resolves.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @readme Path.join(@root, "examples/README.md")

  test "the 1.x example apps are gone" do
    refute File.exists?(Path.join(@root, "examples/customer_support_app/mix.exs"))
    refute File.exists?(Path.join(@root, "examples/agent_horde/mix.exs"))
    assert File.exists?(Path.join(@root, "examples/tools/weather.ex"))
  end

  test "the README names no removed app and links every guide" do
    text = File.read!(@readme)

    refute text =~ "customer_support_app"
    refute text =~ "CustomerSupport"
    refute text =~ "BaseTool"

    links =
      ~r/\]\(([^)#]+)\)/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&String.starts_with?(&1, "http"))

    for guide <- ~w(distributed_sessions.md agent-memory.md hooks.md testing.md) do
      assert "../docs/guides/#{guide}" in links
    end

    for link <- links do
      assert File.exists?(Path.expand(link, Path.dirname(@readme))),
             "examples/README.md links #{link}, which does not exist"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/docs/examples_readme_test.exs`
Expected: FAIL, 2 failures: `"the 1.x example apps are gone"` (`Expected false or nil, got true` on
the first `refute`) and the README test (`Refute with =~ failed` on `refute text =~ "customer_support_app"`).

- [ ] **Step 3: Delete the apps**

```bash
git rm -r -q examples/customer_support_app
git rm -r -q examples/agent_horde
git status --short examples
```

Expected `git status` output: `D ` lines for the 51 tracked files and `??` lines for
`examples/agent_horde/_build/`, `examples/agent_horde/deps/`, `examples/agent_horde/reports/`,
`examples/customer_support_app/_build/`, `examples/customer_support_app/deps/` (whichever exist on
this machine). Do not delete or add the `??` paths.

Check: `git ls-files examples` → exactly `examples/README.md` and `examples/tools/weather.ex`.

- [ ] **Step 4: Report the leftovers**

Run: `git status --short --ignored examples/`

Report its untracked (`??`) and ignored (`!!`) lines to the controller verbatim, with
`git ls-files examples/agent_horde examples/customer_support_app` (expected: no output, so
neither directory holds a tracked file any more). Expected, on a working tree that has built the
apps: `?? examples/agent_horde/_build/`, `?? examples/agent_horde/deps/`,
`?? examples/agent_horde/reports/`, `!! examples/agent_horde/erl_crash.dump` (ignored by the
root `.gitignore:17`), `?? examples/customer_support_app/_build/`,
`?? examples/customer_support_app/deps/`; on a fresh checkout, no `??`/`!!` line under the two
apps. Do not delete, move or `git add` any of them. Stop here until Step 5 is done.

- [ ] **Step 5: Q: remove the leftovers**

**Q:** With the list from Step 4 in front of you, run in the Claude Code prompt:

```
! rm -rf examples/customer_support_app examples/agent_horde
```

The implementer never runs `rm -rf`. When Q confirms, the implementer checks
`git status --short --ignored examples/` → only the `D ` deletions of Step 3 (no `??` or `!!`
line under the two apps) and continues.

- [ ] **Step 6: Rewrite `examples/README.md`**

Replace the whole file with:

````markdown
# Normandy examples

The example applications that used to live here (`agent_horde` and the customer support
app) were written for Normandy 1.x and do not compile against 2.0, so they were removed.
The guides show 2.0 end to end:

- [Distributed sessions](../docs/guides/distributed_sessions.md): durable `Turn.Session`s,
  session stores and registries, running on a cluster.
- [Agent memory](../docs/guides/agent-memory.md): the `memory` tool, namespaces and memory
  stores.
- [Hooks](../docs/guides/hooks.md): lifecycle hooks around prompts, LLM calls, tools and
  compaction.
- [Testing](../docs/guides/testing.md): `Normandy.Test.FakeClient` and the store contracts.

The [README](../README.md) has the quickstart, and [MIGRATING-2.0.md](../MIGRATING-2.0.md)
the changes from 1.x.

## A tool that calls an HTTP API

[`tools/weather.ex`](tools/weather.ex) defines `MyApp.Tools.Weather`, a `Normandy.Tool` that
fetches the current weather from Open-Meteo (no API key needed). Copy it into your
application and rename the module. It is not part of the Normandy package.
````

Check that the file's statement about `weather.ex` is true: `grep -n "use Normandy.Tool" examples/tools/weather.ex` → 1 hit.

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix format && mix test test/docs/examples_readme_test.exs`
Expected: PASS, 2 tests, 0 failures.

- [ ] **Step 8: Mark the 1.0 demo script**

In `marketing/demo-1.0/agent-horde-script.md`, replace the first line

```markdown
# Normandy Agent Horde — Screen-Recording Script
```

with

```markdown
> Written for Normandy 1.0. The `examples/agent_horde` app it records was removed in Normandy 2.0 (it used the 1.x API); see `examples/README.md`.

# Normandy Agent Horde — Screen-Recording Script
```

(the note line, then a blank line so the heading stays a heading). Nothing else in the file
changes.

Check: `git diff --stat marketing/demo-1.0/agent-horde-script.md` → `1 file changed, 2 insertions(+)`;
`head -1 marketing/demo-1.0/agent-horde-script.md` → the note line.

- [ ] **Step 9: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w7-7.3h-v.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.3h-v.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. `mix format --check-formatted` (in precommit) does
not read `examples/` or `marketing/` (`.formatter.exs` inputs). No tagged suite.

- [ ] **Step 10: MIGRATING-2.0.md**

Append to `## 46.`:

```markdown
- The repository's `examples/customer_support_app` and `examples/agent_horde` applications are
  removed: they used the 1.x API (`Normandy.Tools.BaseTool`) and no longer compiled. They were
  never in the Hex package. `examples/README.md` now points at the guides;
  `examples/tools/weather.ex` stays.
```

- [ ] **Step 11: Commit**

The deletions are already staged by Step 3.

```bash
git add examples/README.md
git add marketing/demo-1.0/agent-horde-script.md
git add test/docs/examples_readme_test.exs
git add MIGRATING-2.0.md
git status --short examples marketing
git commit -m "docs(examples)!: delete the 1.x example apps; point examples/README.md at the guides"
```

Expected `git status --short examples marketing` before the commit: the `D ` deletions,
`M  examples/README.md` and `M  marketing/demo-1.0/agent-horde-script.md`; no `??` line (Q
removed the leftovers in Step 5).

---

### Task 7.5a: Claudio 0.7.1 — citations replay, version, changelog (decision 27 B3; Q publishes)

Claudio's `feat/add-messages` branch already has `Request.add_messages/2` (`796d7c1`, `1490b75`). This
task adds the citations replay on that branch, bumps `@version` to `0.7.1` and turns the changelog's
`[Unreleased]` into `[0.7.1]`. Citations are kept when a response is parsed
(`text_block/2`, `lib/claudio/messages/response.ex:648-649`) and dropped only when it is replayed:
`block_to_api/1` (`response.ex:655-657`) returns `%{"type" => "text", "text" => text}`. The same function
serves `to_assistant_content/1` (`:447-451`) and `Request.add_message/3` for typed blocks
(`to_api_block/1`, `:456-457`, called from `request.ex` `unwrap_typed/1`), so one clause fixes both.

All commands in this task run in `/Users/antonio/personal/claudio`. Never push; never touch `main`.

**Files (Claudio repository):**
- Modify: `lib/claudio/messages/response.ex` (`block_to_api/1` text clause; `to_assistant_content/1` doc)
- Modify: `mix.exs` (`@version "0.7.1"`)
- Modify: `CHANGELOG.md` (`## [Unreleased]` → `## [0.7.1]`, `### Fixed` bullet)
- Modify: `CLAUDE.md` (the "Preserves citations" line, `:138` on the branch)
- Test: `test/response_test.exs` (describe `"to_assistant_content/1"`), `test/messages/stream_test.exs`
  (describe `"build_final_message/1 citations"`)

**Interfaces:**
- Consumes: `Response.from_map/1`, `Response.to_assistant_content/1`, `Request.add_message/3`,
  `ClaudioStream.parse_events/1`, `ClaudioStream.build_final_message/1` (all existing).
- Produces: `to_assistant_content/1` emits `"citations"` on a text block whose `:citations` is a non-empty
  list (nil or `[]` → no key). Claudio `0.7.1` = `add_messages/2` + this. Consumed by Task 7.5b.

- [ ] **Step 1: Switch to the branch and check the tree**

```bash
cd /Users/antonio/personal/claudio
git status --short          # expected: only "?? .claude/worktrees/" and "?? Claudio"
git switch feat/add-messages
git log --oneline -2        # expected: 1490b75 docs: CLAUDE.md notes add_messages/2 / 796d7c1 feat(request): ...
mix deps.get
```

If `git status --short` shows anything else, stop and ask Q (the untracked `Claudio/` and
`.claude/worktrees/` are Q's and stay untouched).

- [ ] **Step 2: Write the failing tests**

In `test/response_test.exs`, inside `describe "to_assistant_content/1" do` (it starts at `:266`), after
the test `"serializes mcp_tool_result blocks to API shape (no server_name: the API rejects it)"`, add:

```elixir
    test "replays a text block's citations" do
      citation = %{
        "type" => "char_location",
        "cited_text" => "The grass is green.",
        "document_index" => 0,
        "document_title" => "Example",
        "start_char_index" => 0,
        "end_char_index" => 20
      }

      response =
        Response.from_map(%{
          "content" => [
            %{"type" => "text", "text" => "the grass is green", "citations" => [citation]}
          ]
        })

      assert Response.to_assistant_content(response) == [
               %{"type" => "text", "text" => "the grass is green", "citations" => [citation]}
             ]
    end

    test "a text block without citations, or with an empty list, replays without the key" do
      response = %Response{
        content: [
          %{type: :text, text: "plain"},
          %{type: :text, text: "empty", citations: []},
          %{type: :text, text: "nil", citations: nil}
        ]
      }

      assert Response.to_assistant_content(response) == [
               %{"type" => "text", "text" => "plain"},
               %{"type" => "text", "text" => "empty"},
               %{"type" => "text", "text" => "nil"}
             ]
    end

    test "a typed text block passed to add_message/3 keeps its citations" do
      citation = %{"type" => "char_location", "cited_text" => "x", "document_index" => 0}

      payload =
        Request.new("claude-x")
        |> Request.add_message(:assistant, [%{type: :text, text: "x", citations: [citation]}])
        |> Request.to_map()

      assert %{"messages" => [%{"content" => [block]}]} = payload
      assert block == %{"type" => "text", "text" => "x", "citations" => [citation]}
    end
```

In `test/messages/stream_test.exs`, at the end of the test `"accumulates citations_delta onto the
streamed block"` (describe `"build_final_message/1 citations"`, `:344`), after the two
`assert %{"type" => "char_location", ...}` lines, add:

```elixir
      # A streamed cited block replays with its citations, in order (Claudio 0.7.1).
      assert Response.to_assistant_content(Response.from_map(message)) == [
               %{
                 "type" => "text",
                 "text" => "Paris",
                 "citations" => [first_citation, second_citation]
               }
             ]
```

- [ ] **Step 3: Run them and see them fail**

```bash
mix test test/response_test.exs test/messages/stream_test.exs
```

Expected: 3 failures — `"replays a text block's citations"`, `"a typed text block passed to
add_message/3 keeps its citations"` and `"accumulates citations_delta onto the streamed block"`, each a
left/right diff whose right side has `"citations"` and left side does not. The "without the key" test
passes already (it pins that the fix adds no empty key).

- [ ] **Step 4: Implement**

In `lib/claudio/messages/response.ex`, replace:

```elixir
  defp block_to_api(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end
```

with:

```elixir
  # A text block's citations go back with it: the API accepts them on an assistant
  # text block, and preserved thinking binds the turn as it was returned. An absent,
  # nil or empty list sends no key (the API's own text blocks omit it).
  defp block_to_api(%{type: :text, text: text} = block) do
    case block[:citations] do
      [_ | _] = citations -> %{"type" => "text", "text" => text, "citations" => citations}
      _none -> %{"type" => "text", "text" => text}
    end
  end
```

In the `@doc` of `to_assistant_content/1`, replace the sentence

```
  Emits string-keyed blocks that preserve `signature` (thinking) and `data`
  (redacted_thinking) — both required by the API when continuing an
  extended-thinking + tool-use conversation.
```

with

```
  Emits string-keyed blocks that preserve `signature` (thinking), `data`
  (redacted_thinking) and a text block's `citations` — the API needs the first two
  when continuing an extended-thinking + tool-use conversation, and preserved
  thinking binds the turn as it was returned.
```

- [ ] **Step 5: Run the tests and see them pass**

```bash
mix format
mix test test/response_test.exs test/messages/stream_test.exs
```

Expected: `0 failures`.

- [ ] **Step 6: Version, changelog, CLAUDE.md**

`mix.exs`: `@version "0.7.0"` → `@version "0.7.1"`.

`CHANGELOG.md`: replace the line `## [Unreleased]` (the block that holds the `add_messages/2` bullet)
with `## [0.7.1]` and add, after that block's `### Added` list:

```markdown
### Fixed

- `Response.to_assistant_content/1` replays a text block's `citations`, and `Request.add_message/3`
  sends them for a typed text block. They were parsed but dropped on replay, so a replayed cited turn
  differed from the one the API returned.
```

The release date is added by Q at publish time (Step 8), as `005c51d` did for 0.7.0.

`CLAUDE.md` (Claudio's, on the branch `:138`): replace

```
- **Preserves citations** on `text` blocks (the raw citation maps — `char_location`, `page_location`, `content_block_location`, `search_result_location`, `web_search_result_location` — kept verbatim for reading; not replayed by `to_assistant_content/1`)
```

with

```
- **Preserves citations** on `text` blocks (the raw citation maps — `char_location`, `page_location`, `content_block_location`, `search_result_location`, `web_search_result_location` — kept verbatim; `to_assistant_content/1` replays a non-empty list)
```

- [ ] **Step 7: Claudio's gate, then commit**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w7-7.5a-claudio.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.5a-claudio.log
mix docs --warnings-as-errors
```

Expected: ` 0 failures`, credo and dialyzer clean, exit 0; docs exit 0. Then:

```bash
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git add test/messages/stream_test.exs
git add CLAUDE.md
git commit -m "fix(response): to_assistant_content/1 replays a text block's citations"
git add mix.exs
git add CHANGELOG.md
git commit -m "chore(release): 0.7.1"
git log --oneline main..HEAD   # expected 4 commits: the two above, 1490b75, 796d7c1
```

- [ ] **Step 8: Q: publish Claudio 0.7.1** (outward-facing; the controller hands this to Q)

**Q:** in `/Users/antonio/personal/claudio`: push `feat/add-messages`, open and merge its PR to `main`
(CI green), add the date (`## [0.7.1] - <YYYY-MM-DD>`, commit `chore(release): date 0.7.1`), tag
`v0.7.1`, push the tag, `mix hex.publish`. Done when `mix hex.info claudio` lists `0.7.1`. Task 7.5b
starts only after that.

---

### Task 7.1a: `tools/api_diff/` — public-API diff checked against MIGRATING (C4, R3)

R3 replaces "every commit is matched to a MIGRATING section" with a deterministic check: compile the base
ref and the working tree, dump each tree's public API from the compiled docs (a module is public unless
its moduledoc is `:hidden`; a function, macro or callback unless its doc is `:hidden`; default arguments
expanded), and list every removed module, removed function/callback, changed spec and removed struct field
that MIGRATING-2.0.md does not name. This task ships the tool; Task 7.1b runs it and closes the gaps.

The matcher works per `## ` section of MIGRATING: a removed module is named when some code span holds its
last alias segment as a token; a function, callback or field is named when some code span holds
`Last.name`, or when one section has a code span holding `name` and also mentions the module's last alias
segment (so `check` in §37 does not cover `BudgetTracker.check/2` unless §37 mentions `BudgetTracker`).
A fenced block counts as one code span. Items the matcher cannot see, or that are not changes for a
caller, go in `tools/api_diff/reviewed.txt` with a reason. Prototyped against a `main` clone and HEAD
`9131274`: 12 removed modules, 50 removed functions, 33 changed specs, 20 removed fields; after the
reviewed list below, 10 unmatched — exactly the inventory's U1–U6.

**Files:**
- Create: `tools/api_diff/api_diff.exs` (`NormandyTools.ApiDiff`: `dump/1`, `diff/2`, `unmatched/3`, `parse_reviewed/1`)
- Create: `tools/api_diff/cli.exs` (`dump` / `compare` commands; the only code that prints, writes or halts)
- Create: `tools/api_diff/run.sh` (builds the base ref from `git archive`, runs both dumps and the compare)
- Create: `tools/api_diff/reviewed.txt`
- Create: `tools/api_diff/README.md`
- Modify: `.formatter.exs` (`inputs` gains `"tools/**/*.{ex,exs}"`)
- Test: create `test/tools/api_diff_test.exs`

**Interfaces:**
- Consumes: `Code.fetch_docs/1`, `Code.Typespec.fetch_specs/1`, `Code.Typespec.spec_to_quoted/2`, `git archive`.
- Produces (header "Shared interfaces"): `tools/api_diff/run.sh <base-ref>` → report at the printed path,
  exit 0 when `## unmatched (0)`, 1 otherwise, 2 on a build failure; `NormandyTools.ApiDiff.dump/1 ::
  snapshot()`, `diff/2 :: %{removed_modules:, removed_functions:, changed_specs:, removed_fields:}` (sorted
  string lists), `unmatched/3 :: [String.t()]`, `parse_reviewed/1 :: MapSet.t(String.t())`. Not in
  `package.files` (`mix.exs` `package/0` lists `lib priv .formatter.exs mix.exs README.md LICENSE
  CHANGELOG.md`, plus `MIGRATING-2.0.md` after Task 7.3g). Task 7.1b consumes the report.

- [ ] **Step 1: Write the failing test**

Create `test/tools/api_diff_test.exs`:

````elixir
defmodule NormandyTools.ApiDiffTest do
  @moduledoc """
  Task 7.1a (decision 27 C4, R3): tools/api_diff dumps the public API from compiled docs,
  diffs two dumps, and lists the removed or changed items MIGRATING-2.0.md does not name.
  """
  use ExUnit.Case, async: true

  Code.require_file("../../tools/api_diff/api_diff.exs", __DIR__)

  alias NormandyTools.ApiDiff

  @base %{
    modules: MapSet.new(["Normandy.A", "Normandy.Gone"]),
    functions:
      MapSet.new([
        "Normandy.A.keep/1 function",
        "Normandy.A.drop/2 function",
        "Normandy.A.cb/1 callback",
        "Normandy.Gone.f/0 function"
      ]),
    specs: %{"Normandy.A.keep/1" => "keep(integer()) :: :ok"},
    structs: %{"Normandy.A" => [:a, :b]}
  }

  @head %{
    modules: MapSet.new(["Normandy.A"]),
    functions: MapSet.new(["Normandy.A.keep/1 function", "Normandy.A.cb/2 callback"]),
    specs: %{"Normandy.A.keep/1" => "keep(integer()) :: {:ok, term()}"},
    structs: %{"Normandy.A" => [:a]}
  }

  test "diff/2 lists removed modules, functions, changed specs and removed fields" do
    assert ApiDiff.diff(@base, @head) == %{
             removed_modules: ["Normandy.Gone"],
             # Normandy.Gone.f/0 is covered by its module's removal.
             removed_functions: ["Normandy.A.cb/1 callback", "Normandy.A.drop/2 function"],
             changed_specs: ["Normandy.A.keep/1"],
             removed_fields: ["Normandy.A.b field"]
           }
  end

  @migrating """
  # Migrating

  ## 1. Tools

  `Normandy.Tools.Gone` is gone.

  ## 2. Lookups

  - `get_tool/2` became `fetch_tool/2` on `BaseAgent`.
  - `Session.run/2` replies a tuple.

  ## 3. Catalog

  The ModelCatalog behaviour has one callback:

  ```elixir
  @callback context_window(model, opts) :: {:ok, pos_integer()} | {:error, term()}
  ```

  ## 4. Security

  `PolicyEngine.check/2` is unchanged.
  """

  @diff %{
    removed_modules: ["Normandy.Tools.Gone"],
    removed_functions: [
      "Normandy.Agents.BaseAgent.get_tool/2 function",
      "Normandy.Behaviours.BudgetTracker.check/2 callback",
      "Normandy.Behaviours.ModelCatalog.context_window/1 callback"
    ],
    changed_specs: ["Normandy.Agents.Turn.Session.run/2"],
    removed_fields: ["Normandy.Components.StreamEvent.index field"]
  }

  test "unmatched/3 keeps only the items no section names and reviewed.txt does not list" do
    reviewed = MapSet.new(["Normandy.Components.StreamEvent.index"])

    # get_tool: name and BaseAgent in one section. Session.run: `Session.run` in a span.
    # context_window: inside a fenced block, ModelCatalog in the section. check: §4 has a
    # `check` span but never mentions BudgetTracker.
    assert ApiDiff.unmatched(@diff, @migrating, reviewed) == [
             "Normandy.Behaviours.BudgetTracker.check/2 callback"
           ]
  end

  test "parse_reviewed/1 reads key<TAB>reason lines and refuses a line without a reason" do
    assert ApiDiff.parse_reviewed("# comment\n\nNormandy.A.f/1\tspec only\n") ==
             MapSet.new(["Normandy.A.f/1"])

    assert_raise ArgumentError,
                 ~s(api_diff reviewed.txt: expected <key><TAB><reason>, got "Normandy.A.f/1"),
                 fn -> ApiDiff.parse_reviewed("Normandy.A.f/1\n") end
  end

  test "dump/1 reads this build's public API from its docs chunks" do
    snapshot = ApiDiff.dump(Path.join(Mix.Project.build_path(), "lib/normandy/ebin"))

    assert "Normandy.Agents.BaseAgent" in snapshot.modules
    assert "Normandy.Agents.BaseAgent.init/1 function" in snapshot.functions
    assert Map.has_key?(snapshot.specs, "Normandy.Agents.BaseAgent.init/1")
    assert :model in Map.fetch!(snapshot.structs, "Normandy.Agents.BaseAgentConfig")
    # @moduledoc false since Task 7.2a.
    refute "Normandy.Hooks.Runner" in snapshot.modules
    # Protocol implementations are not listed (ExDoc does not list them either).
    refute Enum.any?(
             snapshot.modules,
             &String.starts_with?(&1, "Normandy.Agents.Model.Normandy.")
           )
  end
end
````

- [ ] **Step 2: Run it and see it fail**

```bash
mix format
mix test test/tools/api_diff_test.exs
```

Expected: the file fails to load with `(Code.LoadError) could not load .../tools/api_diff/api_diff.exs`.

- [ ] **Step 3: Implement the module**

Create `tools/api_diff/api_diff.exs`:

````elixir
defmodule NormandyTools.ApiDiff do
  @moduledoc false
  # Compares the public API of two compiled Normandy trees and lists every removed or
  # changed item that MIGRATING-2.0.md does not name. See tools/api_diff/README.md.
  #
  # dump/1 reads beams; diff/2, unmatched/3 and parse_reviewed/1 are pure. cli.exs is the
  # only code that prints, writes files or halts.

  @kinds [:function, :macro, :callback, :macrocallback]

  @type snapshot :: %{
          modules: MapSet.t(String.t()),
          functions: MapSet.t(String.t()),
          specs: %{String.t() => String.t()},
          structs: %{String.t() => [atom()]}
        }

  @doc "The public API of every beam in `ebin`. Loads the modules to read struct fields."
  @spec dump(Path.t()) :: snapshot()
  def dump(ebin) do
    true = Code.prepend_path(ebin)
    beams = ebin |> Path.join("Elixir.*.beam") |> Path.wildcard() |> Enum.sort()

    Enum.reduce(
      beams,
      %{modules: MapSet.new(), functions: MapSet.new(), specs: %{}, structs: %{}},
      fn beam, acc ->
        mod_atom = beam |> Path.basename(".beam") |> String.to_atom()
        mod = mod_atom |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

        case Code.fetch_docs(beam) do
          {:docs_v1, _, _, _, :hidden, _, _} ->
            acc

          {:docs_v1, _, _, _, _moddoc, _, entries} ->
            if protocol_impl?(mod_atom),
              do: acc,
              else: add_module(acc, mod, mod_atom, beam, entries)

          {:error, reason} ->
            raise "api_diff: no docs chunk in #{beam} (#{inspect(reason)}); compile with docs on"
        end
      end
    )
  end

  # ExDoc does not list protocol implementations; their functions are the protocol's.
  defp protocol_impl?(mod_atom) do
    {:module, ^mod_atom} = Code.ensure_loaded(mod_atom)
    function_exported?(mod_atom, :__impl__, 1)
  end

  defp add_module(acc, mod, mod_atom, beam, entries) do
    funs = public_functions(mod, entries)

    %{
      acc
      | modules: MapSet.put(acc.modules, mod),
        functions: MapSet.union(acc.functions, funs),
        specs: Map.merge(acc.specs, specs(mod, beam, funs)),
        structs: put_struct(acc.structs, mod, mod_atom)
    }
  end

  # "Mod.name/arity kind", default arguments expanded (f/3 with one default is also f/2).
  defp public_functions(mod, entries) do
    for {{kind, name, arity}, _, _, doc, meta} <- entries,
        kind in @kinds,
        doc != :hidden,
        a <- (arity - Map.get(meta, :defaults, 0))..arity//1,
        into: MapSet.new(),
        do: "#{mod}.#{name}/#{a} #{kind}"
  end

  defp specs(mod, beam, funs) do
    visible = MapSet.new(funs, &(&1 |> String.split(" ") |> hd()))

    case Code.Typespec.fetch_specs(File.read!(beam)) do
      {:ok, specs} ->
        for {{name, arity}, clauses} <- specs,
            key = "#{mod}.#{name}/#{arity}",
            MapSet.member?(visible, key),
            into: %{} do
          text =
            clauses
            |> Enum.map_join(
              " ; ",
              &(Code.Typespec.spec_to_quoted(name, &1) |> Macro.to_string())
            )
            |> String.replace(~r/\s+/, " ")

          {key, text}
        end

      :error ->
        %{}
    end
  end

  defp put_struct(structs, mod, mod_atom) do
    if function_exported?(mod_atom, :__struct__, 0) do
      fields = mod_atom.__struct__() |> Map.keys() |> List.delete(:__struct__) |> Enum.sort()
      Map.put(structs, mod, fields)
    else
      structs
    end
  end

  @doc "What `head` removed or changed relative to `base`, as sorted lists of item strings."
  @spec diff(snapshot(), snapshot()) :: %{atom() => [String.t()]}
  def diff(base, head) do
    gone = MapSet.difference(base.modules, head.modules)

    %{
      removed_modules: Enum.sort(gone),
      removed_functions:
        base.functions
        |> MapSet.difference(head.functions)
        |> Enum.reject(&MapSet.member?(gone, module_of(&1)))
        |> Enum.sort(),
      changed_specs:
        Enum.sort(
          for {key, spec} <- base.specs,
              Map.has_key?(head.specs, key),
              Map.fetch!(head.specs, key) != spec,
              do: key
        ),
      removed_fields:
        Enum.sort(
          for {mod, fields} <- base.structs,
              head_fields = Map.get(head.structs, mod),
              is_list(head_fields),
              field <- fields -- head_fields,
              do: "#{mod}.#{field} field"
        )
    }
  end

  defp module_of(item),
    do: item |> key() |> String.replace(~r/\.[^.]+\/\d+$/, "")

  @doc """
  The items of `diff` that `migrating` does not name and `reviewed` does not list.

  Per `## ` section of `migrating`: a module is named when a code span holds its last
  alias segment as a token; a function, callback or field when a code span holds
  `Last.name`, or a code span holds `name` and the section mentions `Last` (the module's
  last alias segment). A fenced block is one code span.
  """
  @spec unmatched(%{atom() => [String.t()]}, String.t(), MapSet.t(String.t())) :: [String.t()]
  def unmatched(diff, migrating, reviewed) do
    sections = sections(migrating)

    diff
    |> Map.values()
    |> List.flatten()
    |> Enum.reject(&(MapSet.member?(reviewed, key(&1)) or named?(&1, sections)))
    |> Enum.sort()
  end

  # "Mod.f/2 function" -> "Mod.f/2"; "Mod.field field" -> "Mod.field"; a module is its own key.
  defp key(item), do: item |> String.split(" ") |> hd()

  defp sections(text) do
    text
    |> String.split(~r/\n(?=## )/)
    |> Enum.map(&{&1, spans(&1)})
  end

  # Fenced blocks count as one span each; then the inline `code` spans outside them.
  defp spans(section) do
    fences = Regex.scan(~r/```[^\n]*\n(.*?)```/s, section, capture: :all_but_first)
    rest = Regex.replace(~r/```.*?```/s, section, "")
    inline = Regex.scan(~r/`([^`]+)`/, rest, capture: :all_but_first)
    List.flatten(fences ++ inline)
  end

  defp named?(item, sections) do
    case String.split(item, " ") do
      [mod] ->
        last = mod |> String.split(".") |> List.last()
        Enum.any?(sections, fn {_text, spans} -> Enum.any?(spans, &token?(&1, last)) end)

      [path, _kind] ->
        member_named?(path, sections)
    end
  end

  defp member_named?(path, sections) do
    [_, mod, name] = Regex.run(~r/^(.+)\.([^.\/]+)(?:\/\d+)?$/, path)
    last = mod |> String.split(".") |> List.last()
    qualified = last <> "." <> name

    Enum.any?(sections, fn {text, spans} ->
      Enum.any?(spans, &token?(&1, qualified)) or
        (Enum.any?(spans, &token?(&1, name)) and String.contains?(text, last))
    end)
  end

  defp token?(span, name),
    do: Regex.match?(~r/(?<![A-Za-z0-9_])#{Regex.escape(name)}(?![A-Za-z0-9_?!])/, span)

  @doc "`reviewed.txt`: one `<key><TAB><reason>` per line; `#` lines and blank lines ignored."
  @spec parse_reviewed(String.t()) :: MapSet.t(String.t())
  def parse_reviewed(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> MapSet.new(fn line ->
      case String.split(line, "\t", parts: 2) do
        [key, reason] when reason != "" ->
          key

        _ ->
          raise ArgumentError,
                "api_diff reviewed.txt: expected <key><TAB><reason>, got #{inspect(line)}"
      end
    end)
  end
end
````

- [ ] **Step 4: Run the test and see it pass**

```bash
mix format
mix test test/tools/api_diff_test.exs
```

Expected: `4 tests, 0 failures`.

- [ ] **Step 5: The command line, the runner script, the reviewed list, the README**

Create `tools/api_diff/cli.exs`:

```elixir
# tools/api_diff/cli.exs: command line for tools/api_diff/api_diff.exs; see the README.
Code.require_file("api_diff.exs", __DIR__)

defmodule NormandyTools.ApiDiff.CLI do
  @moduledoc false
  alias NormandyTools.ApiDiff

  def main(["dump", ebin, out]),
    do: File.write!(out, :erlang.term_to_binary(ApiDiff.dump(ebin)))

  def main(["compare", base, head, migrating, reviewed]) do
    diff = ApiDiff.diff(read_term(base), read_term(head))

    for {section, items} <- Enum.sort(diff) do
      IO.puts("## #{section} (#{length(items)})")
      Enum.each(items, &IO.puts/1)
    end

    reviewed = reviewed |> File.read!() |> ApiDiff.parse_reviewed()

    case ApiDiff.unmatched(diff, File.read!(migrating), reviewed) do
      [] ->
        IO.puts("## unmatched (0)")

      items ->
        IO.puts("## unmatched (#{length(items)})")
        Enum.each(items, &IO.puts/1)
        System.halt(1)
    end
  end

  def main(argv) do
    IO.puts(
      :stderr,
      "usage: cli.exs dump <ebin> <out.term> | " <>
        "compare <base.term> <head.term> <MIGRATING.md> <reviewed.txt>; got #{inspect(argv)}"
    )

    System.halt(2)
  end

  defp read_term(path), do: path |> File.read!() |> :erlang.binary_to_term()
end

NormandyTools.ApiDiff.CLI.main(System.argv())
```

Create `tools/api_diff/run.sh` and `chmod +x tools/api_diff/run.sh`:

```bash
#!/usr/bin/env bash
# Usage: tools/api_diff/run.sh <base-ref>        e.g. tools/api_diff/run.sh main
#
# Builds <base-ref> from `git archive` (no worktree, nothing in the repository changes) and the
# working tree, dumps both public APIs and checks every removed or changed item against
# MIGRATING-2.0.md. Exit 0: every item is named there or in reviewed.txt; 1: some are not
# (listed under "## unmatched"); 2: a build failed. Scratch files stay in the printed directory.
set -euo pipefail

base_ref="${1:?usage: tools/api_diff/run.sh <base-ref>}"
root="$(git rev-parse --show-toplevel)"
here="$root/tools/api_diff"
work="$(mktemp -d "${TMPDIR:-/tmp}/normandy-api-diff.XXXXXX")"
mkdir "$work/base"
git -C "$root" archive "$base_ref" | tar -x -C "$work/base"

if ! (cd "$work/base" && MIX_ENV=dev mix deps.get && MIX_ENV=dev mix compile) >"$work/base-build.log" 2>&1; then
  echo "building $base_ref failed; see $work/base-build.log" >&2
  exit 2
fi

if ! (cd "$root" && MIX_ENV=dev mix compile) >"$work/head-build.log" 2>&1; then
  echo "building the working tree failed; see $work/head-build.log" >&2
  exit 2
fi

elixir "$here/cli.exs" dump "$work/base/_build/dev/lib/normandy/ebin" "$work/base.term"
elixir "$here/cli.exs" dump "$root/_build/dev/lib/normandy/ebin" "$work/head.term"

status=0
elixir "$here/cli.exs" compare "$work/base.term" "$work/head.term" \
  "$root/MIGRATING-2.0.md" "$here/reviewed.txt" | tee "$work/report.txt" || status=$?
echo "report: $work/report.txt"
exit "$status"
```

Create `tools/api_diff/reviewed.txt` (each separator is one TAB character):

```
# Items tools/api_diff reports that MIGRATING-2.0.md covers in words the matcher cannot see,
# or that are not changes for a caller. One <key><TAB><reason> per line.
Normandy.Agents.BaseAgent.run_with_tools/1	§20 table: run_with_tools(agent, input) -> run(agent, input); the section never spells BaseAgent
Normandy.Agents.BaseAgent.run_with_tools/2	§20 table: run_with_tools(agent, input) -> run(agent, input); the section never spells BaseAgent
Normandy.Components.StreamEvent.__meta__	§20: the 1.x SSE StreamEvent is replaced by %StreamEvent{type, data}
Normandy.Components.StreamEvent.index	§20: the 1.x SSE StreamEvent is replaced by %StreamEvent{type, data}
Normandy.Components.StreamEvent.message	§20: the 1.x SSE StreamEvent is replaced by %StreamEvent{type, data}
Normandy.Components.StreamEvent.usage	§20: the 1.x SSE StreamEvent is replaced by %StreamEvent{type, data}
Normandy.Context.WindowManager.estimate_conversation_tokens/1	spec only: pos_integer() became non_neg_integer() (0 for an empty input); same values
Normandy.Context.WindowManager.estimate_message_content_tokens/1	spec only: pos_integer() became non_neg_integer(); same values
Normandy.Context.WindowManager.estimate_tokens/1	spec only: pos_integer() became non_neg_integer(); same values
Normandy.Validate.cast/4	spec only: the clauses are unchanged (lib/normandy/validate.ex cast/4 vs main); main's spec was looser
```

Create `tools/api_diff/README.md`:

````markdown
# tools/api_diff

Checks that `MIGRATING-2.0.md` names every public API item a release removes or changes. Not part of
the Hex package.

```bash
tools/api_diff/run.sh main
```

It builds `main` from `git archive` in a temporary directory (`mix deps.get` there needs network or a
warm Hex cache) and the working tree with `MIX_ENV=dev mix compile`, then prints:

- `## removed_modules`, `## removed_functions` (functions, macros and callbacks, default arguments
  expanded), `## changed_specs`, `## removed_fields` (struct fields): what the working tree removed or
  changed relative to `main`. A module is public unless it is `@moduledoc false`; a function unless it
  is `@doc false`. Protocol implementations are skipped.
- `## unmatched`: the items `MIGRATING-2.0.md` does not name. Exit status 1 when there are any.

An item is named when one `## ` section of MIGRATING has a code span with the module's last alias
segment (a module), with `Last.name`, or with `name` while the section also mentions `Last` (a function,
callback or field). A fenced block counts as a code span.

When an item is covered in words the matcher cannot see, or is not a change for a caller (a spec that
only got more precise), add it to `reviewed.txt` as `<key><TAB><reason>`; the key is the item without
its kind (`Normandy.A.f/1`, `Normandy.A.field`). Otherwise write the MIGRATING text.

The pure parts (`NormandyTools.ApiDiff.diff/2`, `unmatched/3`, `parse_reviewed/1`) are tested in
`test/tools/api_diff_test.exs`.
````

In `.formatter.exs`, replace

```elixir
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
```

with

```elixir
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,tools}/**/*.{ex,exs}"],
```

- [ ] **Step 6: Run the tool once against `main` (informational)**

```bash
mix format
tools/api_diff/run.sh main; echo "exit=$?"
```

Expected (verified on the stacked preflight branch after Tasks 7.0a-7.3h-v and 7.5a): exit 1; the
report's sections read `## changed_specs (32)`, `## removed_fields (20)`, `## removed_functions (50)`,
`## removed_modules (23)` (the prototype's 12 plus the 11 modules Task 7.2a hid that `main` documented),
and `## unmatched (18)`: the 10 items of the inventory's U1–U6 plus the 8 hidden modules no section
names yet (`Turn.Driver`, `Turn.Inline` and `SessionRegistry.Redis.Via` are hidden too, but an existing
section already names them, so they are matched):

```
Normandy.Agents.BaseAgent.process_batch/3
Normandy.Agents.ValidationMiddleware
Normandy.Batch.Processor.process_batch/3
Normandy.Batch.Processor.process_batch_chunked/3
Normandy.Behaviours.BudgetTracker.check/2 callback
Normandy.Behaviours.BudgetTracker.record/2 callback
Normandy.Behaviours.ModelCatalog.Static.limits/0 function
Normandy.Context.WindowManager.ensure_within_limit/2
Normandy.Context.WindowManager.truncate_conversation/2
Normandy.LLM.Json.ContentCleaner
Normandy.LLM.Json.Decoder
Normandy.LLM.Json.RetryFeedback
Normandy.LLM.Json.Scanner
Normandy.LLM.Json.SchemaBinder
Normandy.LLM.Json.SchemaTranslator
Normandy.Telemetry.OtelCtx
Normandy.Type.autogenerate/0 callback
Normandy.hello/0 function
```

Wave 7's own removals (Task 7.3h-iii's `Toolset` filters, 7.3h-ii's `:context` option) do not appear:
`Toolset` is new since `main` (1.x had `Tools.Registry`, listed as a removed module) and an option is not
an API item. Any other unmatched item is a change an earlier Wave 7 task made without its MIGRATING bullet: stop
and report it to the controller (do not add it to `reviewed.txt` to make the list shorter). Task 7.1b
closes these items.

- [ ] **Step 7: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w7-7.1a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.1a.log
mix docs --warnings-as-errors
mix hex.build --unpack -o /tmp/w7-7.1a-pkg && test ! -e /tmp/w7-7.1a-pkg/tools && echo "tools/ not packaged"
```

Expected: ` 0 failures`, exit 0; docs exit 0; `tools/ not packaged`. No tagged suite: nothing here
touches a store, the registry or `Turn.Server`.

- [ ] **Step 8: MIGRATING** — none. The tool is repository tooling, not a library change.

- [ ] **Step 9: Commit**

```bash
git add tools/api_diff/api_diff.exs
git add tools/api_diff/cli.exs
git add tools/api_diff/run.sh
git add tools/api_diff/reviewed.txt
git add tools/api_diff/README.md
git add .formatter.exs
git add test/tools/api_diff_test.exs
git commit -m "chore(tools): api_diff checks MIGRATING-2.0.md against the public API diff"
```

---

### Task 7.1b: MIGRATING-2.0.md — the uncovered API and REL-4 changes, the index, Known limits (REL-4, C2, C3)

Runs after every code task (header Task order) so `tools/api_diff` sees the final surface. It closes the
10 API gaps the 7.1a run lists (U1–U6) and the modules Task 7.2a hid that `main` documented, adds the 12
uncovered REL-4 behaviour changes (re-verified below), moves the two breaking bullets out of
"New, non-breaking", adds the "Who is affected" index (C3) and refreshes "Known limits of 2.0". Tables and
code samples appear only where a signature, return shape or option changes (C2).

Re-verified on `9131274` (each claim below was read in the code):
- U1 `lib/normandy/behaviours/budget_tracker.ex:17-18` `check/3`, `record/4`; `main` `:14-15` `check/2`,
  `record/2`. Called from `lib/normandy/behaviours/config.ex:76-80` with the `%ToolCall{}` and the result.
- U2 `main:lib/normandy/type.ex:267,278` `@callback autogenerate()`; gone at HEAD.
- U3 `main:lib/normandy.ex:15` `def hello`; gone.
- U4 `main:lib/normandy/behaviours/model_catalog.ex:36` `def limits`; gone.
- U5 `lib/normandy/context/window_manager.ex` `@spec ensure_within_limit(struct(), t()) :: {:ok, struct()} | {:error, term()}` and the same for `truncate_conversation/2`.
- U6 `lib/normandy/batch/processor.ex:71` `@type item_result :: {:ok, term()} | {:error, term()}`.
- `3c33c08` `init_options.ex:132-135` `on_violation` default `:block`; `ViolationError` is
  `lib/normandy/guardrails/violation_error.ex`.
- `8747a71` `resilience/retry.ex:88-92,248` every failure `{:error, {reason, attempts, errors}}` (`main`
  `:173` returned a non-retryable error bare); `preset/1` raises on an unknown name (`:412-415`; `main`
  `:316` fell back to `:standard`).
- `308bc17` `policy_engine.ex:50-54` `:rules` and `:default_action` required.
- `dd84539` `a2a/server.ex:73-76` `expose_tools` default `[]`; `:146-152` `:no_text`, `:agent_failed`.
- `1070a3f` `coordination/agent_pool.ex:240-253` `{:error, :timeout}`.
- `9b62724` `mix.exs:181` `extra_applications` has `:mnesia` only in dev/test; `main` `:132` always.
- `6432e49` `validate.ex:446-458` "requires the fields declared `required: true`"; `main` `:434-437`
  required every field. `3e8202a` whitespace-only required value is blank.
- `92c0683`, `08c5366`, `9ee9a10` (subjects: compute on a non-virtual field raises at compile time; a
  guardrail `:field` the struct lacks raises; a built-in guard's config error raises under any `:on_error`).
- `5279a84` `agents/turn/supervisor.ex:13-14` 100 restarts in 5 s, `:max_restarts`/`:max_seconds`.

**Files:**
- Modify: `MIGRATING-2.0.md` (intro, new `## Who is affected`, §5, §11, §18, §21, §30, §35, §37, §39, §40,
  §42, new §47, additions to §45, "Known limits of 2.0", "New, non-breaking")
- Test: create `test/docs/migrating_test.exs`

**Interfaces:**
- Consumes: `tools/api_diff/run.sh main` (Task 7.1a); sections §43–§46 as Tasks 7.0b, 7.0c, 7.0d, 7.3b–e,
  7.3h and 7.5b wrote them (header "MIGRATING sections"); the H10 bullet as Task 7.0b reduced it and the
  blank line Task 7.0c removed.
- Produces: `## Who is affected` (a table whose cells name sections as `§N`), §47 "Behaviour callbacks
  and removed leftovers", §45 (the hidden-module pointers). Task 7.4b's CHANGELOG and Task 7.7's PR
  body link to them; Task 7.6b edits "Known limits" afterwards (the paused server-tool bullet).

- [ ] **Step 1: Confirm the gap list**

```bash
tools/api_diff/run.sh main; echo "exit=$?"
```

Expected: exit 1, `## unmatched` = the 10 items in Task 7.1a Step 6 plus the hidden modules. Write the
`## removed_modules` lines that are not among the 12 deleted 1.x modules (`Agents.ConverseResult`,
`Agents.Dispatch.DenialEnvelope`, `NonExistentContextProvider`, `NonExistentTurn`, `Tools.BaseTool`,
`Tools.Registry`, `Tools.SchemaBaseTool`, the five `Tools.Examples.*`) into §45 in Step 4. If any other item
is unmatched, stop and report it to the controller: an earlier Wave 7 task shipped a change without its
MIGRATING bullet.

- [ ] **Step 2: Write the failing test**

Create `test/docs/migrating_test.exs`:

```elixir
defmodule Normandy.Docs.MigratingTest do
  @moduledoc """
  Task 7.1b (decision 27 C2, C3): MIGRATING-2.0.md's numbered sections run 1..n, its
  "Who is affected" index names only existing sections and every section at least once,
  the closing sections follow the last numbered one, the two breaking items no longer sit
  under "New, non-breaking", and its code fences are balanced.
  """
  use ExUnit.Case, async: true

  @path Path.expand("../../MIGRATING-2.0.md", __DIR__)

  setup_all do
    {:ok, text: File.read!(@path)}
  end

  defp numbered(text),
    do: for([_, n] <- Regex.scan(~r/^## (\d+)\. /m, text), do: String.to_integer(n))

  defp section(text, heading) do
    [_, body] = Regex.run(~r/^#{Regex.escape(heading)}\n(.*?)(?=^## |\z)/ms, text)
    body
  end

  test "numbered sections run 1..n with no gap", %{text: text} do
    numbers = numbered(text)
    assert numbers == Enum.to_list(1..length(numbers))
  end

  test "the index names only existing sections, and every section", %{text: text} do
    index = section(text, "## Who is affected")
    listed = for [_, n] <- Regex.scan(~r/§(\d+)/, index), uniq: true, do: String.to_integer(n)

    assert Enum.sort(listed) == numbered(text),
           "index lists #{inspect(Enum.sort(listed))}, sections are #{inspect(numbered(text))}"
  end

  test "the index comes before section 1, the closing sections after the last one",
       %{text: text} do
    [{index_at, _}] = Regex.run(~r/^## Who is affected$/m, text, return: :index)
    [{first_at, _}] = Regex.run(~r/^## 1\. /m, text, return: :index)
    [{limits_at, _}] = Regex.run(~r/^## Known limits of 2\.0$/m, text, return: :index)
    [{new_at, _}] = Regex.run(~r/^## New, non-breaking$/m, text, return: :index)
    last = numbered(text) |> List.last()
    [{last_at, _}] = Regex.run(~r/^## #{last}\. /m, text, return: :index)

    assert index_at < first_at
    assert last_at < limits_at and limits_at < new_at
  end

  test "breaking changes are not filed under New, non-breaking", %{text: text} do
    new = section(text, "## New, non-breaking")
    refute new =~ "`:fallbacks` is rejected on streaming calls"
    refute new =~ "now raise on an invalid"
  end

  test "code fences are balanced", %{text: text} do
    fences = Regex.scan(~r/^\s*`{3}/m, text)
    assert rem(length(fences), 2) == 0, "#{length(fences)} fence lines"
  end
end
```

- [ ] **Step 3: Run it and see it fail**

```bash
mix format
mix test test/docs/migrating_test.exs
```

Expected: 3 failures — `"the index names only existing sections, and every section"` and `"the index
comes before section 1, ..."` (`MatchError`: no `## Who is affected`), and `"breaking changes are not
filed under New, non-breaking"`. The other two pass.

- [ ] **Step 4: Write the MIGRATING text**

Edit `MIGRATING-2.0.md` as follows (anchor on headings; sections §43–§46 are already there).

**(a) Intro and index.** After the intro paragraph (the one ending "Each breaking change below says what
to do."), insert:

```markdown
## Who is affected

Find the rows that describe you and read the sections they list. Every section is listed at least once.

| You | Read |
|---|---|
| Everyone upgrading | §1, §11, §17, §20, §21, §30, §44 |
| Build and run agents (`BaseAgent`, schemas, prompts, memory) | §2, §8, §18, §19, §23, §28, §29, §32, §33, §36, §38, §43 |
| Write tools, or use MCP or A2A | §3, §15, §24, §25, §34, §37 |
| Use the DSLs (`agent do`, `workflow do`) | §21, §46 |
| Run durable sessions (`Turn.Session`, `Turn.Server`, clusters) | §12, §13, §22, §26, §39, §40, §43 |
| Implement `Normandy.Agents.Model` (your own LLM client) | §4, §9, §23, §33, §38 |
| Implement a behaviour or a custom type (`BudgetTracker`, `PolicyEngine`, `ModelCatalog`, `Compactor`, `SessionStore`, `MemoryStore`, hooks, `Normandy.Type`) | §5, §16, §37, §40, §47 |
| Compact long conversations | §5, §6, §7, §35 |
| Coordinate agents (orchestrators, `AgentProcess`, `AgentPool`, batches) | §27, §31, §42 |
| Consume telemetry or logs | §9, §14, §41 |
| Operate stores (Postgres, Redis, Mnesia) | §10, §13, §40 |
| Test code that uses Normandy | §45 |
| Referenced a module that is now internal | §45 |

Limits that 2.0 still has are listed under "Known limits of 2.0" at the end.
```

**(b) §5** (Model catalog and compaction): after the `ModelCatalog.Static` is deprecated bullet (as Task
7.3h-iv extended it, it ends "persisted templates to silence it."), add:

```markdown
- `ModelCatalog.Static.limits/0` is gone with the static table. Ask `ModelCatalog.ModelsAPI` for a
  model's window (`context_window/2`).
```

**(c) §11** (LLM failures …): at the end of the section, add:

````markdown
- `Normandy.Resilience.Retry.with_retry/2` returns `{:error, {reason, attempts, errors}}` for every
  failure, a non-retryable one included (1.x returned that error bare). `Retry.preset/1` raises
  `ArgumentError` on an unknown name (1.x fell back to `:standard`).

  | 1.x | 2.0 |
  |---|---|
  | non-retryable failure: `{:error, reason}` | `{:error, {reason, 1, [reason]}}` |
  | retries exhausted: `{:error, {reason, attempts, errors}}` | unchanged |
  | `Retry.preset(:typo)` → the `:standard` options | raises `ArgumentError` |

  ```elixir
  case Retry.with_retry(fun, Retry.preset(:standard)) do
    {:ok, value} -> value
    {:error, {reason, _attempts, _errors}} -> {:error, reason}
  end
  ```
````

**(d) §18** (The default input schema …): at the end, add:

```markdown
- `Normandy.Validate.validate/2` requires only the fields declared `required: true`. 1.x required every
  field of the schema.
- A required value that is only whitespace is blank: `validate_required/2` rejects `"  "` as it rejects
  `""`. 1.x accepted it.
```

**(e) §21** (`BaseAgent.init/1` and DSL `new/1` check their options): at the end, add:

````markdown
- **An output guardrail violation blocks the answer by default.** `run/3` and `stream/3` return
  `{:error, %Normandy.Guardrails.ViolationError{}}`; 1.x logged the violation and returned the answer. To
  keep the 1.x behaviour, set `on_violation: :warn`:

  ```elixir
  BaseAgent.init(client: client, model: model, guardrails: [output: guards, on_violation: :warn])
  ```
- These now fail where they are written instead of passing silently: `compute:` on a field that is not
  `virtual: true` (a compile error), a guardrail `:field` the struct does not have (`ArgumentError`), and
  a built-in guard's configuration error, which raises under every `:on_error` (`:open` and `:closed`
  used to swallow it).
````

**(f) §30** (Every option is checked): at the end, add the two bullets moved out of "New, non-breaking"
(and delete them there, (n) below):

```markdown
- `BaseAgent.init/1` and `ConfigTemplate.rebuild/3` raise on an invalid `ClaudioAdapter`
  `client.options` combination; 1.x failed on the first call, after any retries.
  `ClaudioAdapter.validate_options!/1` is the public check.
- `client.options[:fallbacks]` is refused on streaming calls (`ArgumentError`): partial output from a
  declining model would already have reached the stream callback.
```

**(g) §35** (Compaction): at the end, add:

````markdown
- `Normandy.Context.WindowManager.truncate_conversation/2` and `ensure_within_limit/2` return
  `{:error, reason}` when a `:summarize` compaction fails (its summary request failed). 1.x returned only
  `{:ok, agent}`.

  ```elixir
  with {:ok, agent} <- WindowManager.ensure_within_limit(agent, manager) do
    BaseAgent.run(agent, input)
  end
  ```
````

**(h) §37** (Security hardening): at the end, add:

````markdown
- `PolicyEngine.Ruleset` requires `:rules` and `:default_action`. 1.x defaulted `:default_action` to
  `:allow`; a ref without it now raises `ArgumentError` when the agent is built. Say what an unmatched
  call gets:

  ```elixir
  {Normandy.Behaviours.PolicyEngine.Ruleset, rules: rules, default_action: :allow}
  ```
- `A2A.Server.build_agent_card/2` lists no tools unless you pass `:expose_tools` (a list of names or
  `:all`); 1.x listed every tool. `handle_message/4` returns `{:error, :agent_failed}` when the agent
  raises or exits (the detail is logged, not sent), and `{:error, :no_text}` for a message with only file
  or data parts (1.x ran it as an empty prompt).
````

**(i) §39** (Turn.Server start, store failures …): at the end, add:

```markdown
- `Turn.Supervisor` and `Turn.Supervisor.Horde` allow 100 restarts in 5 seconds (OTP's default is 3);
  `start_link/1` takes `:max_restarts` and `:max_seconds`.
```

**(j) §40** (Session stores, registry and memory stores): at the end, add:

```markdown
- Normandy no longer starts `:mnesia`. If you use `SessionStore.Mnesia` or `MemoryStore.Mnesia`, add it
  to your application's `extra_applications` in `mix.exs`: `[:logger, :mnesia]`.
```

**(k) §42** (AgentProcess and coordination): at the end, add:

````markdown
- `Batch.Processor.process_batch/3`, `process_batch_chunked/3` and `BaseAgent.process_batch/3` return
  one `{:ok, result}` or `{:error, reason}` per input, in input order. 1.x returned the bare response, or
  `nil` for an input that failed. A slow input no longer stops the batch.

  | 1.x | 2.0 |
  |---|---|
  | `{:ok, [response, nil]}` | `{:ok, [{:ok, response}, {:error, reason}]}` |

  ```elixir
  {:ok, results} = Batch.Processor.process_batch(agent, inputs)
  for {:ok, response} <- results, do: response
  ```
- `AgentPool.checkout/2` returns `{:error, :timeout}` when no agent frees up within `:timeout`; 1.x
  exited the caller. Match the tuple instead of catching the exit.
````

**(l) New §47; pointers added to §45**, after §46 and before `## Known limits of 2.0`:

````markdown
## 47. Behaviour callbacks and removed leftovers

- `Normandy.Behaviours.BudgetTracker` callbacks receive the tool call and the opts:

  | 1.x | 2.0 |
  |---|---|
  | `check(scope, est)` | `check(scope, call, opts)` |
  | `record(scope, usage)` | `record(scope, call, result, opts)` |

  `call` is the `%Normandy.Components.ToolCall{}`, `result` its `%Normandy.Components.ToolResult{}`, and
  `opts` the `opts` half of the `{module, opts}` ref in `Normandy.Behaviours.Config`.

  ```elixir
  defmodule MyBudget do
    @behaviour Normandy.Behaviours.BudgetTracker

    @impl true
    def check(scope, _call, opts),
      do: if(MyLedger.spent(scope) < opts[:limit], do: :ok, else: {:error, :over_budget})

    @impl true
    def record(scope, call, _result, _opts), do: MyLedger.add(scope, call.name)
  end
  ```
- The `Normandy.Type` optional callback `autogenerate/0` is gone; nothing calls it. Delete it from a
  custom type (an `@impl true` on it warns at compile time).
- `Normandy`'s generated placeholder `hello/0` is gone.

````

Append to `## 45. Testing support and docs` (Task 7.2a; ruling R8), as one sub-list under its first bullet (after its last line, "stay public."), these pointers, each only for a module §45 lists. The names are shortened on purpose: a code span with a hidden module's full name fails `mix docs --warnings-as-errors` ("references module ... but it is hidden", H7), and `tools/api_diff` needs a code span holding the last alias segment:

````markdown

  If you called one directly:

  - `Turn.Driver`, `Turn.Inline`: run turns with `BaseAgent.run/3`, `stream/3` or
    `Turn.Session`. `Turn.Driver.Handlers` stays public.
  - `ValidationMiddleware`: input and output validation run inside every turn.
  - `Json.ContentCleaner`, `Decoder`, `RetryFeedback`, `Scanner`, `SchemaBinder`,
    `SchemaTranslator`: use `Normandy.LLM.JsonDeserializer`.
  - `OtelCtx`: trace context is carried for you (see `Normandy.Telemetry`).
  - `Redis.Via`: pass the registry handle (`SessionRegistry.Redis.handle/1`).
````

Every module Step 1 listed under `## removed_modules` (minus the 12 deleted 1.x modules) must be named in §45's first bullet; add any that Task 7.2a did not list there (unbackticked). Delete a pointer above whose module §45 does not list.

**(m) "Known limits of 2.0"**: Task 7.0b already reduced the H10 bullet and Task 7.0c removed the stray
blank line. Append these bullets after the last one ("A custom `retry_if` …"):

```markdown
- **A resumed turn can miss the iteration-cap notice.** If `Turn.Server` stops while it appends the
  results of the last allowed tool round, the resumed turn makes its final call without the notice that
  no more tools will run. The answer is still produced.
- **Memory-store bookkeeping.** `MemoryStore.InMemory` totals a namespace from all its documents on every
  limited write, so a write's cost grows with the namespace. `MemoryStore.Postgres` keeps a namespace's
  counter row, at zero, after its last document is deleted, until `delete_namespace/2`.
- **`Schema.Wire` cleans the top level only.** `title` keys inside `$defs`, `definitions`,
  `patternProperties`, `dependentSchemas` and `contains` reach the model as written.
- **A policy reason that is not a string is not shown to the model.** A `PolicyEngine` that denies with
  a non-binary reason gets the generic "blocked by policy" text in the tool result.
- **A schema struct inside a plain-map field is not validated.** Validation descends into fields that
  are schema structs or lists of them, not into plain maps.
- **The memory tool checks its mounts on its first call.** A session namespace that equals a mount's
  raises on the first `memory` tool call, not when the agent is built.
```

**(n) "New, non-breaking"**: delete the two bullets moved in (f):

```markdown
- `:fallbacks` is rejected on streaming calls: partial output from a declining model would
  already have reached the stream callback.
- `BaseAgent.init/1` and `ConfigTemplate.rebuild/3` now raise on an invalid
  `ClaudioAdapter` `client.options` combination instead of failing on the first call (after
  any retries). `ClaudioAdapter.validate_options!/1` is the public check.
```

- [ ] **Step 5: Run the test and the API diff**

```bash
mix format
mix test test/docs/migrating_test.exs
tools/api_diff/run.sh main; echo "exit=$?"
```

Expected: `5 tests, 0 failures`; `## unmatched (0)`, exit 0. If an item stays unmatched, fix the
MIGRATING text so the section names it (`Last.name` in a code span, or the name in a code span and the
module's last alias segment in the section); `reviewed.txt` takes only items that are covered in words or
are not changes, each with a reason.

- [ ] **Step 6: Gate**

```bash
mix precommit 2>&1 | tee /tmp/w7-7.1b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.1b.log
mix docs --warnings-as-errors
```

Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite (docs only).

- [ ] **Step 7: Commit**

Write the commit body to `/tmp/w7-7.1b-msg.txt`: the subject line, a blank line, then the `## unmatched`
section of the first Step 1 report (the gaps), then this mapping, then the final report's section counts:

```
docs(migrating): cover every 2.0 API change; who-is-affected index; known limits

api_diff main..HEAD before: <paste the "## unmatched (N)" list from Step 1>
Closed by: U1 BudgetTracker check/3, record/4 -> §47; U2 Type autogenerate/0 -> §47;
U3 Normandy.hello/0 -> §47; U4 ModelCatalog.Static.limits/0 -> §5; U5 WindowManager
{:error, reason} -> §35; U6 Batch ordered results -> §42; hidden modules -> §45.
REL-4: 3c33c08 -> §21; 8747a71 -> §11; 0d01d04 -> §30 (moved); 308bc17, dd84539 -> §37;
791bbd7, 1070a3f -> §42; 9b62724 -> §40; 6432e49, 3e8202a -> §18; 92c0683, 08c5366,
9ee9a10 -> §21; 5279a84 -> §39; fd0d2b7 §21, 930e62c §27, 72b8490 §37, fa7411c/c7c5f27
§38/§23 already covered; 875d014 needs no line (pre-release only).
api_diff main..HEAD after: <paste the four "## <section> (N)" counts> ## unmatched (0)
Known limits added: parked rows 18, 19, 20, 21, 22, 24 (7.0-code-leftovers.md).
2.x, not user-visible, no bullet: row 26 (Turn.Server run_while_server_alive/3 duplicates
WatchedWorker).
```

Replace each `<paste …>` with the output before committing (the committed message has no angle
brackets), then:

```bash
git add MIGRATING-2.0.md
git add test/docs/migrating_test.exs
git commit -F /tmp/w7-7.1b-msg.txt
```

---

### Task 7.1c: Triage the keyword-flagged commits (R3)

The API diff sees signatures, specs and fields. A behaviour change that keeps its signature (a new
default, a raise where there was none) is found by reading commits. REL-4's table covers part of them;
this task reads the rest. The list is fixed to the commits before Wave 7 (`main..9131274`): every Wave 7
task writes its own MIGRATING bullets.

```bash
git log main..9131274 --format='%h %s' \
  | grep -vE '^[0-9a-f]+ (docs|test|chore|ci|style)(\(|:)' \
  | grep -iE "raise|reject|require|default|no longer|return|instead|refus|remove|drop|rename|must"
```

Verified on 2026-10-07: 119 lines.

**Files:**
- Create: `investigations/pre-2.0-audit/wave-7-migrating-triage.md`
- Modify: `MIGRATING-2.0.md` (only for a gap the triage finds)

**Interfaces:**
- Consumes: the MIGRATING sections as Task 7.1b left them; `tools/api_diff/run.sh` (re-run at the end).
- Produces: the triage table (file + commit body). Task 7.4b's CHANGELOG reads MIGRATING, not this table.

- [ ] **Step 1: Build the list**

```bash
git log main..9131274 --format='%h %s' \
  | grep -vE '^[0-9a-f]+ (docs|test|chore|ci|style)(\(|:)' \
  | grep -iE "raise|reject|require|default|no longer|return|instead|refus|remove|drop|rename|must" \
  > /tmp/w7-7.1c-list.txt
wc -l < /tmp/w7-7.1c-list.txt
```

Expected: `119`. A different count means the range is wrong; stop and check `git rev-parse 9131274`.

- [ ] **Step 2: Triage each commit**

For each line, `git show --stat <hash>` and read the diff of `lib/`. Classify it with exactly one of:

- `§N` — MIGRATING section N already states the change (quote the phrase you matched in the table).
- `gap → §N` — a user can observe the change and no section states it: write the bullet into the
  fitting section now (one sentence of what changed, one of what to do; a table or sample only when a
  signature, return shape or option changes).
  A user-visible addition that breaks nothing (a new option) is `gap → New, non-breaking` and its bullet
  goes at the end of `## New, non-breaking`. (Preflight on the stacked branch found 17 gaps: §18 92abfd2;
  §19 ca08503, e22c4f6, 02906c8; §25 3beee8b, 72b8490; §27 930e62c; §30 0d01d04; §32 5e7bbe3; §33 fa7411c;
  §37 b2a115f; §38 c9157ec; §40 448419f, 7b72fcc; §42 951077d; §44 f52dce7; New, non-breaking 641bd80.
  Four of them — 0d01d04, 72b8490, fa7411c, 930e62c — are commits Task 7.1b's REL-4 mapping calls
  covered; the existing bullets state only part of each change.)
- `internal` — no public function, option, return value, raised error, log, telemetry or persisted shape
  changes (name what it changed, e.g. "private helper rename").
- `pre-release` — it changes behaviour that only existed on this branch (never on `main`/1.3.0): name the
  earlier branch commit that introduced it.

Record the table in `investigations/pre-2.0-audit/wave-7-migrating-triage.md`:

```markdown
# Wave 7 Task 7.1c: keyword-flagged commits, main..9131274

`git log main..9131274` filtered as in plan-wave-7.md Task 7.1c: 119 commits.

| Commit | Subject | Class | Evidence |
|---|---|---|---|
```

one row per commit, in `git log` order (newest first), then a closing line `Gaps written: N (§…)`.

- [ ] **Step 3: Check**

```bash
test "$(grep -c '^| [0-9a-f]\{7\} ' investigations/pre-2.0-audit/wave-7-migrating-triage.md)" -eq 119 && echo "119 rows"
mix format
mix test test/docs/migrating_test.exs
tools/api_diff/run.sh main; echo "exit=$?"
mix precommit 2>&1 | tee /tmp/w7-7.1c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.1c.log
mix docs --warnings-as-errors
```

Expected: `119 rows`; `5 tests, 0 failures`; `## unmatched (0)`, exit 0; ` 0 failures`; docs exit 0.

- [ ] **Step 4: Commit**

Body: the subject, a blank line, the table rows, the `Gaps written` line.

```bash
{ echo "docs(migrating): triage the keyword-flagged commits before Wave 7"; echo;
  sed -n '/^| Commit /,$p' investigations/pre-2.0-audit/wave-7-migrating-triage.md; } > /tmp/w7-7.1c-msg.txt
git add investigations/pre-2.0-audit/wave-7-migrating-triage.md
git add MIGRATING-2.0.md      # only when Step 2 wrote a gap; skip this line otherwise
git commit -F /tmp/w7-7.1c-msg.txt
```

---

### Task 7.4a: release.yml releases only when cog names a version (decision 27 F1, R6)

cog 7.0.0's `cog bump --auto --dry-run` exits 0 when nothing is releasable and prints
`No conventional commits for your repository that required a bump. ...` / `Pre-Hooks and Post-Hooks have
been skipped.` on stdout (rehearsed again for this plan on the scratch clone with a `v2.0.0` tag:
`release-version.sh` below printed `release=false`). `release.yml`'s "Determine next version" step reads
exit 0 as releasable, so every docs or CI merge to `main` runs `cog bump` (no tag), then `mix hex.publish`
of the existing version: Release runs `28049498744` and `28563121153` failed that way. The fix: release
only when the dry run's last stdout line is a version; a non-zero cog exit is a cog failure and fails
the job (Header conflict 6). The decision moves into a script so it is tested.

**Files:**
- Create: `.github/scripts/release-version.sh`
- Modify: `.github/workflows/release.yml` (step "Determine next version")
- Modify: `.github/workflows/README.md` (the jobs list, a Release section)
- Test: create `test/release/release_version_script_test.exs`

**Interfaces:**
- Consumes: `cog` on `PATH` (installed by `.github/scripts/install-cog.sh`, cog 7.0.0).
- Produces: `.github/scripts/release-version.sh` prints `release=true` + `version=vX.Y.Z` or
  `release=false` on stdout (for `$GITHUB_OUTPUT`), the reason on stderr; exit 1 when cog fails. The later
  steps of `release.yml` read `steps.bump_check.outputs.release` as today.

- [ ] **Step 1: Write the failing test**

Create `test/release/release_version_script_test.exs`:

```elixir
defmodule Normandy.Release.ReleaseVersionScriptTest do
  @moduledoc """
  Task 7.4a (decision 27 F1): `.github/scripts/release-version.sh` decides whether the
  Release workflow publishes. A version on the last line of `cog bump --auto --dry-run`
  releases it; cog's "nothing to bump" output does not; a cog failure fails the step. A
  stub `cog` on `PATH` plays cog.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @script Path.expand("../../.github/scripts/release-version.sh", __DIR__)

  # cog 7.0.0's stdout with nothing to release (observed on a clone tagged v2.0.0).
  @no_bump """
  No conventional commits for your repository that required a bump. Changelogs, version and hooks are not touched.
  Pre-Hooks and Post-Hooks have been skipped.\
  """

  defp run(dir, cog_stdout, cog_exit) do
    stub = Path.join(dir, "cog")
    File.write!(stub, ~s(#!/bin/sh\nprintf '%s\\n' "$COG_STUB_OUT"\nexit "$COG_STUB_EXIT"\n))
    File.chmod!(stub, 0o755)

    {out, status} =
      System.cmd("bash", [@script],
        env: [
          {"PATH", dir <> ":" <> System.fetch_env!("PATH")},
          {"COG_STUB_OUT", cog_stdout},
          {"COG_STUB_EXIT", Integer.to_string(cog_exit)}
        ],
        stderr_to_stdout: true
      )

    {String.split(out, "\n", trim: true), status}
  end

  test "a version on the dry run's last line releases it", %{tmp_dir: dir} do
    {lines, status} = run(dir, "Bumped version: v1.3.0 -> v2.0.0\nv2.0.0", 0)

    assert status == 0
    assert "release=true" in lines
    assert "version=v2.0.0" in lines
  end

  test "cog's nothing-to-bump output, exit 0, does not release", %{tmp_dir: dir} do
    {lines, status} = run(dir, @no_bump, 0)

    assert status == 0
    assert "release=false" in lines
    refute "release=true" in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "version="))
  end

  test "a cog failure fails the step instead of skipping the release", %{tmp_dir: dir} do
    {lines, status} = run(dir, "Error: invalid cog.toml", 3)

    assert status == 1
    assert "cog bump --auto --dry-run failed; see its output above." in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "release="))
  end
end
```

- [ ] **Step 2: Run it and see it fail**

```bash
mix format
mix test test/release/release_version_script_test.exs
```

Expected: `3 tests, 3 failures`; bash reports `.github/scripts/release-version.sh: No such file or
directory` (status 127).

- [ ] **Step 3: Implement**

Create `.github/scripts/release-version.sh` and `chmod +x .github/scripts/release-version.sh`:

```bash
#!/usr/bin/env bash
# Decides whether the Release workflow publishes. Prints `release=true` and
# `version=<tag>` (or `release=false`) for $GITHUB_OUTPUT on stdout; the reason on stderr.
#
# cog 7 exits 0 with nothing to release and prints a sentence, not a version, so the exit
# status alone cannot decide: a release needs the dry run's last line to be a version.
# A non-zero exit is a cog failure (bad config, broken history) and fails the job.
set -euo pipefail

# cog's own diagnostics go to stderr, which the job log shows; stdout carries the result.
if ! out="$(cog bump --auto --dry-run)"; then
  echo "cog bump --auto --dry-run failed; see its output above." >&2
  exit 1
fi

last="$(printf '%s\n' "$out" | tail -n1)"

if [[ "$last" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "release=true"
  echo "version=${last}"
  echo "Releasable change detected: ${last}" >&2
else
  echo "release=false"
  echo "No releasable commits since the last tag (cog: ${last}); skipping release." >&2
fi
```

In `.github/workflows/release.yml`, replace the whole "Determine next version" step:

```yaml
      - name: Determine next version
        id: bump_check
        run: |
          # No pipe in the `if` condition: the exit status must be cog's, not
          # tail's. Piping here would mask a non-zero cog exit unless pipefail
          # is set, breaking the clean no-op when nothing is releasable.
          if version="$(cog bump --auto --dry-run 2>/dev/null)"; then
            version="$(printf '%s\n' "$version" | tail -n1)"
            echo "release=true" >> "$GITHUB_OUTPUT"
            echo "version=${version}" >> "$GITHUB_OUTPUT"
            echo "Releasable change detected: ${version}"
          else
            echo "release=false" >> "$GITHUB_OUTPUT"
            echo "No releasable commits since last tag; skipping release."
          fi
```

with:

```yaml
      # cog 7 exits 0 with nothing to release, so the script releases only when the dry
      # run's last line is a version (a docs-only merge to main must not republish).
      - name: Determine next version
        id: bump_check
        run: .github/scripts/release-version.sh >> "$GITHUB_OUTPUT"
```

In `.github/workflows/README.md`, replace everything from `### Jobs` down to (not including)
`### Caching Strategy` with:

```markdown
### Jobs

#### 1. **Test** (matrix)
Elixir/OTP 1.15/26, 1.16/26, 1.17/26, 1.17/27, 1.18/27 and 1.19/28 — the declared floor
(`elixir: "~> 1.15"`) through the newest. Each leg compiles with warnings as errors and runs
`mix test --warnings-as-errors`; the 1.17/27 leg also checks formatting and coverage (threshold in
`mix.exs`).

#### 2. **Integration Tests**
Pushes to `main` only, Elixir 1.15/OTP 26, after the test matrix passes:
`mix test --only integration --only normandy_integration` against the live API when the
`ANTHROPIC_API_KEY` secret is set (skipped otherwise).

#### 3. **Code Quality**
Elixir 1.19/OTP 28: unused-dependency check, `mix hex.audit`, `mix hex.outdated` (informational),
compile without optional dependencies, `mix credo --strict`, `mix dialyzer`, and
`MIX_ENV=dev mix docs --warnings-as-errors`.

#### 4. **Test with unlocked dependencies**
Elixir 1.19/OTP 28: `mix deps.unlock --all`, then compile and test against the newest versions
`mix.exs` allows.

#### 5. **Postgres, Redis and Distributed**
The test files `mix test` excludes, against service containers (Elixir 1.19/OTP 28):
- **Postgres**: `mix test.postgres`
- **Redis**: `mix test.redis`
- **Distributed**: starts `epmd`, then `NORMANDY_REDIS=true mix test.postgres --only distributed`
  with both services, for the multi-node (`:peer`) tests

#### 6. **All Checks Passed**
Fails unless every job above succeeded; Integration Tests may also be skipped.

## Release workflow (`release.yml`)

Runs after CI succeeds on a push to `main`. `.github/scripts/release-version.sh` asks
`cog bump --auto --dry-run` for the next version and releases only when cog names one: a merge with
only `docs:`, `ci:`, `chore:` or `test:` commits since the last tag publishes nothing. A release bumps
`@version`, writes the CHANGELOG section and tags (`cog bump --auto`), publishes to Hex, pushes the bump
commit and the tag, and creates the GitHub release. If `cog` itself fails, the job fails.
```

- [ ] **Step 4: Run the test and see it pass**

```bash
mix format
mix test test/release/release_version_script_test.exs
```

Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Rehearse on a scratch clone (no repository state changes)**

```bash
S=$(mktemp -d); git clone -q /Users/antonio/personal/normandy "$S/r" && cd "$S/r"
git checkout -q main
git tag v9.9.9 HEAD      # a scratch tag in the scratch clone only
PATH="$HOME/.local/bin:$PATH" bash /Users/antonio/personal/normandy/.github/scripts/release-version.sh
cd /Users/antonio/personal/normandy
```

Expected: `release=false` and `No releasable commits since the last tag (cog: Pre-Hooks and Post-Hooks
have been skipped.); skipping release.`, exit 0. (cog 7.0.0 is at `~/.local/bin/cog`, as in CI.) Leave the
scratch directory; it is outside the repository.

- [ ] **Step 6: Gate**

```bash
mix precommit 2>&1 | tee /tmp/w7-7.4a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.4a.log
mix docs --warnings-as-errors
```

Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite.

- [ ] **Step 7: MIGRATING** — none (CI only, nothing a library user sees).

- [ ] **Step 8: Commit**

```bash
git add .github/scripts/release-version.sh
git add .github/workflows/release.yml
git add .github/workflows/README.md
git add test/release/release_version_script_test.exs
git commit -m "ci(release): release only when cog bump names a version"
```

---

### Task 7.5b: Normandy on Claudio 0.7.1 — one `add_messages/2` call, citations replayed (decision 24/25 A9, B3)

Starts after Q has published Claudio 0.7.1 (`mix hex.info claudio` lists `0.7.1`). Today
`ClaudioAdapter.add_messages/3` (`claudio_adapter.ex:499-509`) reduces over the messages with one
`Claudio.Messages.Request.add_message/3` per message, and `add_message/3` appends with `messages ++
[message]`: building a request is quadratic in the history. `build_request/3` (`:782-794`) is the one
builder for every path (legacy, structured, raw retry, streaming), so switching it covers `run/3`,
`stream/3`, `get_response/2`, `Turn.Driver`, `Turn.Inline` and `Turn.Server` at once.

Wire bytes stay identical. `add_messages/2` applies `add_message/3`'s checks, normalization and betas in
order (its doc, `claudio/lib/claudio/messages/request.ex` on the branch). The named helpers the adapter
used for three two-block shapes (`dispatch_multimodal/3`, `:674-703`) build exactly the maps
`ImageBlock.to_claudio/1`, `DocumentBlock.to_claudio/1` and `TextBlock.to_claudio/1` build when
`cache_control` is nil, the only case the helpers were used (compared: Claudio `request.ex`
`add_message_with_image/5`, `add_message_with_image_url/4`, `add_message_with_document/5` with no options
vs `image.ex:91-126`, `document.ex:72-82`, `text.ex:64-67`). So every non-system message becomes one
`{role, content}` entry. `test/agents/wire_identity_test.exs` pins it.

Citations: with 0.7.1, `Claudio.Messages.Response.to_assistant_content/1` keeps them, and both the
non-streaming (`claudio_adapter.ex:907`) and the streaming (`ToolCallResponse.api_blocks/1`,
`tool_call_response.ex:57-66`) paths fill `content_blocks` through it. No Normandy code changes for
citations; a test pins them on all three paths.

**Files:**
- Modify: `mix.exs` (`{:claudio, "~> 0.7.1"}`), `mix.lock` (by `mix deps.update claudio`)
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`add_messages/3`, `add_single_message/3`; new private
  `append_messages/2`, `message_entry/1`; delete `dispatch_multimodal/3`)
- Modify: `MIGRATING-2.0.md` (§33 the Claudio 0.7 sentence; §44 two bullets)
- Modify: `investigations/pre-2.0-audit/claudio-gaps.md` (two rows)
- Modify: `test/llm/claudio_adapter_multimodal_test.exs` (one stale comment)
- Test: create `test/llm/claudio_adapter_add_messages_test.exs`; modify
  `test/agents/assistant_turn_replay_test.exs` (`assert_replayed_as_received/0`)

**Interfaces:**
- Consumes: `Claudio.Messages.Request.add_messages/2 :: (t(), [{role(), content()}]) :: t()` (Claudio
  0.7.1, Task 7.5a); `Response.to_assistant_content/1` with citations.
- Produces: unchanged public surface. `add_messages/3` and `add_single_message/3` keep their `@doc false`
  signatures (tests and `context/token_counter.ex:191` call them).

- [ ] **Step 1: Write the failing tests**

Create `test/llm/claudio_adapter_add_messages_test.exs`:

```elixir
defmodule Normandy.LLM.ClaudioAdapterAddMessagesTest do
  @moduledoc """
  Task 7.5b: the adapter appends a conversation with one
  `Claudio.Messages.Request.add_messages/2` call (linear time), never a loop of
  `add_message/3`.
  """
  # Call tracing sets a global trace pattern on Claudio.Messages.Request.
  use ExUnit.Case, async: false

  alias Claudio.Messages.Request
  alias Normandy.Components.Message

  # Inside a `defimpl`, a public `def` is reachable at this qualified name.
  @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

  setup do
    {:module, Request} = Code.ensure_loaded(Request)
    _ = :erlang.trace_pattern({Request, :add_messages, 2}, true, [:local])
    _ = :erlang.trace_pattern({Request, :add_message, 3}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({Request, :_, :_}, false, [:local]) end)
    :ok
  end

  test "a 2_000-message history is one add_messages/2 call and no add_message/3" do
    history =
      for n <- 1..2_000 do
        %Message{role: if(rem(n, 2) == 1, do: "user", else: "assistant"), content: "m#{n}"}
      end

    # A process cannot trace its own calls (OTP 28 delivers nothing), so the build runs in
    # a child traced by this test process.
    test_pid = self()

    builder =
      spawn(fn ->
        receive do
          :go ->
            request =
              @impl_module.add_messages(
                Request.new("m"),
                [%Message{role: "system", content: "sys"} | history],
                false
              )

            send(test_pid, {:built, request})
        end
      end)

    1 = :erlang.trace(builder, true, [:call])
    send(builder, :go)
    assert_receive {:built, request}, 5_000
    # Every trace message from the builder is in the mailbox once this arrives.
    delivered = :erlang.trace_delivered(builder)
    assert_receive {:trace_delivered, ^builder, ^delivered}, 5_000

    assert length(request.messages) == 2_000
    assert request.system == "sys"
    assert_received {:trace, _, :call, {Request, :add_messages, [_request, entries]}}
    assert length(entries) == 2_000
    assert hd(entries) == {:user, "m1"}
    refute_received {:trace, _, :call, {Request, :add_message, _}}
  end
end
```

In `test/agents/assistant_turn_replay_test.exs`, replace:

```elixir
  defp assert_replayed_as_received do
    assert replayed_assistant(1) == expected_replay()
    assert_received {:tool_ran, "weather"}
    refute_received {:tool_ran, "docs__search"}
  end
```

with:

```elixir
  defp assert_replayed_as_received do
    content = replayed_assistant(1)
    assert content == expected_replay()
    # Claudio 0.7.1 replays a text block's citations (Task 7.5b, decision 27 B3): the
    # cited block goes back exactly as the API returned it.
    assert Enum.at(content, 1) == @cited
    assert_received {:tool_ran, "weather"}
    refute_received {:tool_ran, "docs__search"}
  end
```

This covers `run/3`, `stream/3` and `Turn.Server` (the three tests that call it).

- [ ] **Step 2: Run them and see them fail (still on Claudio 0.7.0)**

```bash
mix format
mix test test/llm/claudio_adapter_add_messages_test.exs test/agents/assistant_turn_replay_test.exs
```

Expected: 4 failures. The add_messages test fails at `assert_received {:trace, _, :call, {Request,
:add_messages, ...}}` (0.7.0 has no `add_messages/2`; the mailbox holds 2_000 `add_message` traces: "Showing 10 of 2000 messages"). The
three replay tests fail at `assert Enum.at(content, 1) == @cited`: the left side has no `"citations"`.

- [ ] **Step 3: Move to Claudio 0.7.1**

In `mix.exs`, replace `{:claudio, "~> 0.7.0"},` with `{:claudio, "~> 0.7.1"},`, then:

```bash
mix deps.update claudio
grep -n '"claudio"' mix.lock     # expected: {:hex, :claudio, "0.7.1", ...}
```

- [ ] **Step 4: Build the conversation with one `add_messages/2` call**

In `lib/normandy/llm/claudio_adapter.ex` (inside `defimpl Normandy.Agents.Model`), replace the
function `add_messages/3` — from its `@doc false` line through its final `end` — with:

```elixir
    @doc false
    # Public (not `defp`) so tests can exercise the full message pipeline
    # directly without round-tripping through `converse/3` and a live Claudio
    # HTTP client. Not part of the adapter's supported surface.
    #
    # Conversation caching: with `enable_caching`, set Claudio's top-level
    # automatic breakpoint. The API places it on the last cacheable block of any
    # role (tool results included) and moves it forward as the conversation
    # grows. Together with the explicit system and last-tool breakpoints that's 3
    # of the 4 allowed. Normandy marks no message block itself.
    def add_messages(request, messages, enable_caching) do
      ensure_single_leading_system!(messages)

      request =
        if enable_caching,
          do: Claudio.Messages.Request.set_cache_control(request),
          else: request

      case messages do
        [%Message{role: "system"} = system | rest] ->
          request
          |> add_single_message(system, enable_caching)
          |> append_messages(rest)

        _no_system ->
          append_messages(request, messages)
      end
    end

    # One Claudio call for the whole conversation: Request.add_messages/2 appends in
    # time linear in the history (a loop of add_message/3 copies the list each time).
    defp append_messages(request, messages),
      do: Claudio.Messages.Request.add_messages(request, Enum.map(messages, &message_entry/1))
```

Keep the two `"system"` clauses of `add_single_message/3` (the `is_list(content)` one and the
`is_binary(content)` one) and their comment as they are. Replace every other `add_single_message/3`
clause — the five clauses after them, from the `role in ["user", "assistant"] and is_list(content)`
clause through `def add_single_message(_request, other, _enable_caching)` — with:

```elixir
    def add_single_message(request, message, _enable_caching) do
      {role, content} = message_entry(message)
      Claudio.Messages.Request.add_message(request, role, content)
    end

    # A message as Claudio's `{role, content}`: content blocks become API maps here, so
    # add_messages/2 and add_message/3 get the same entry.
    defp message_entry(%Message{role: role, content: content})
         when role in ["user", "assistant"] and is_list(content) do
      blocks = content |> ensure_non_empty_content!() |> Enum.map(&block_to_claudio/1)
      {String.to_existing_atom(role), blocks}
    end

    # Single ContentBlock struct as content — treat as a one-element list
    # so the wire shape is symmetric with `content: [block]`. Without this,
    # a caller who sets `content: %Image{...}` ships a raw struct to
    # Claudio and the request is malformed at JSON-encode time.
    defp message_entry(%Message{role: role, content: %block_mod{} = block})
         when role in ["user", "assistant"] and
                block_mod in [TextBlock, ImageBlock, DocumentBlock] do
      {String.to_existing_atom(role), [block_to_claudio(block)]}
    end

    defp message_entry(%Message{role: role, content: content})
         when role in ["user", "assistant"],
         do: {String.to_existing_atom(role), content}

    # List-form tool content: convert ContentBlock structs to Anthropic
    # wire shape. Pre-shaped maps (e.g. from BaseIOSchema.to_json/1) pass
    # through via the `%{} = raw when not is_struct` branch of
    # block_to_claudio/1, preserving the pre-multimodal tool_result path.
    defp message_entry(%Message{role: "tool", content: content}) when is_list(content),
      do: {:user, content |> ensure_non_empty_content!() |> Enum.map(&block_to_claudio/1)}

    # Tool results are serialized via the BaseIOSchema protocol; they go as a user message.
    defp message_entry(%Message{role: "tool", content: content}), do: {:user, content}

    # Caller typos and unsupported roles (e.g. OpenAI's "function") would
    # otherwise silently disappear from the request — the model gets a
    # degraded conversation with no feedback loop. Raise at the boundary.
    defp message_entry(%Message{role: role, turn_id: turn_id})
         when is_binary(role) and role not in ["system", "user", "assistant", "tool"] do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: unrecognized message role #{inspect(role)} " <>
              "(turn_id=#{inspect(turn_id)}). Expected one of: " <>
              ~s("system", "user", "assistant", "tool".)
    end

    defp message_entry(%Message{role: role}) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: message role must be a string, got: " <>
              Describe.type_of(role)
    end

    defp message_entry(other) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: expected a %Normandy.Components.Message{}, got " <>
              Describe.type_of(other)
    end
```

Delete the comment block that starts `# Opportunistic dispatch: when a content list exactly matches a
shape` and the four `defp dispatch_multimodal(...)` clauses after it (nothing else calls them:
`grep -n dispatch_multimodal lib` → 0 lines after the edit). `ensure_single_leading_system!/1`,
`ensure_non_empty_content!/1` and the `block_to_claudio/1` clauses stay.

The error messages are unchanged, so `test/llm/claudio_adapter_multimodal_test.exs`'s raise tests keep
passing. In that file, replace the comment

```elixir
      # 6-block list deliberately avoids the 2-arity shapes Claudio wraps
      # (add_message_with_image etc.), guaranteeing dispatch_multimodal/3's
      # raw-list fallback clause runs.
```

with

```elixir
      # Six blocks in one message: each becomes its API map, in order.
```

- [ ] **Step 5: Run the tests and see them pass; wire identity unchanged**

```bash
mix format
mix test test/llm/claudio_adapter_add_messages_test.exs test/agents/assistant_turn_replay_test.exs
mix test test/agents/wire_identity_test.exs test/llm/claudio_adapter_multimodal_test.exs \
  test/llm/claudio_adapter_caching_test.exs test/llm/claudio_adapter_request_parity_test.exs \
  test/hooks/llm_compaction_hooks_test.exs test/context/summarizer_test.exs
git status --short test/fixtures/wire_identity     # expected: nothing (no fixture rewritten)
```

Expected: `0 failures` from both `mix test` commands, and no fixture change.

- [ ] **Step 6: MIGRATING, claudio-gaps.md**

`MIGRATING-2.0.md` §33 (Tool calls and assistant turns are replayed as received): in the bullet about
`content_blocks`, replace

```
  this field existed, or built by hand with `content_blocks: []`, is rebuilt as before. Claudio
  0.7 leaves `citations` out of replayed text blocks, and `server_name` out of a replayed
  `mcp_tool_result` (the API rejects it there).
```

with

```
  this field existed, or built by hand with `content_blocks: []`, is rebuilt as before. A
  replayed text block keeps its `citations` (Claudio 0.7.1); a replayed `mcp_tool_result` leaves
  out `server_name`, which the API rejects there.
```

§44 (Dependencies and platform; Task 7.0d created it): add at the end:

```markdown
- Normandy requires Claudio `~> 0.7.1`: run `mix deps.update claudio`. A request is built with one
  `Claudio.Messages.Request.add_messages/2` call, in time linear in the conversation's length (it was
  quadratic); the request body is unchanged.
- A cited text block in a tool-using turn goes back to the API with its `citations`. Claudio 0.7.0
  dropped them on replay, so the replayed turn differed from the one the API returned.
```

`investigations/pre-2.0-audit/claudio-gaps.md`: change the title to `# Claudio 0.7 gaps for Normandy 2.0`
and append two rows to the table:

```markdown
| a conversation built in linear time | `Request.add_messages/2` (Claudio 0.7.1, `796d7c1`); `ClaudioAdapter.add_messages/3` makes one call (Task 7.5b, `test/llm/claudio_adapter_add_messages_test.exs`) | ok (0.7.1) |
| citations replayed on text blocks | `Response.to_assistant_content/1` emits a non-empty `citations` list (Claudio 0.7.1, Task 7.5a); Normandy test `test/agents/assistant_turn_replay_test.exs` on run/3, stream/3, Turn.Server; live check scenario 16 part B (Task 7.6a/7.6b) | ok (0.7.1) |
```

- [ ] **Step 7: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w7-7.5b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.5b.log
mix docs --warnings-as-errors
mix hex.build --unpack -o /tmp/w7-7.5b-pkg && grep -n claudio /tmp/w7-7.5b-pkg/hex_metadata.config
```

Expected: ` 0 failures`, exit 0; docs exit 0; the package requires `claudio` `~> 0.7.1`. No tagged suite:
the request builder is store- and registry-independent, and `Turn.Server` is covered by the wire
identity and replay tests above.

- [ ] **Step 8: Commit**

```bash
git add mix.exs
git add mix.lock
git add lib/normandy/llm/claudio_adapter.ex
git add test/llm/claudio_adapter_add_messages_test.exs
git add test/llm/claudio_adapter_multimodal_test.exs
git add test/agents/assistant_turn_replay_test.exs
git add MIGRATING-2.0.md
git add investigations/pre-2.0-audit/claudio-gaps.md
git commit -m "feat(llm): build requests with Claudio 0.7.1 add_messages/2; replay citations"
```

---

### Task 7.6a-i: e2e — usage and cost totals, `mix e2e --estimate` (decision 4, REL-9)

Task 7.6a is split in two for review size: **7.6a-i** (part 1 below: usage, cost, estimate) and
**7.6a-ii** (parts 2 and 3: scenarios 15 and 16). Offline work only: no scenario runs here (live spend is
Task 7.6b, after Q approves). The three parts:

1. **Usage and cost.** The suite collects Claudio's per-call measurements (`E2E.Support.usages/0`) but
   prints none, so no run has a measured cost. Each scenario now prints
   `usage: input=N output=N cache_read=N cache_write=N est_cost=$X.XX` and puts the same numbers in its
   `E2E_RESULT` line, also when an invariant fails or the cap is exceeded; the runner adds an `est $`
   column and a total line, and `mix e2e --estimate` prints a cap-based estimate without calling the API
   (Task 7.6b's spend-approval step). Streamed calls report their tokens on
   `[:claudio, :messages, :stream, :stop]` (Claudio `lib/claudio/messages/stream.ex:300-316`), not on
   `[:claudio, :messages, :create, :stop]` (`messages.ex:249-268`, tokens empty for a stream), so the
   support module listens to both and counts a call only on the second. Prices
   (`NormandyTest.E2E.Prices`, Header conflict 2), USD per million tokens, Anthropic list prices as of
   2026-10 (`claude-api` skill, cached 2026-09-25): Haiku 4.5 1.00 / 5.00 / cache read 0.10 / cache write
   1.25; Sonnet 5.5 2.00 / 10.00 / 0.20 / 2.50; Opus 5.5 4.00 / 20.00 / 0.20 / 5.00 (write = 1.25 × input,
   5-minute TTL; Opus 5.5's read is 0.05 × input).
2. **Scenario 15 — AX-7 preserved thinking** (`e2e/15_preserved_thinking.exs`, `claude-opus-5-5`,
   `thinking: :adaptive`, `thinking_block_binding: :error`, cap 8). With `:error` the API rejects a request
   whose replayed thinking no longer matches the conversation it was produced in (the check is enforced by
   default only for accounts created on or after 2026-08-31, hence the explicit option; Haiku 4.5 never
   runs it). Run 1: a non-chat output schema and a tool whose first result names a second SKU, with
   `max_tool_iterations: 2` — two tool rounds, then the forced final call (`tool_choice: :none` plus the
   iteration-cap notice, `output_config.format` beside the tools). Run 2 (`run/3`) and run 3 (`stream/3`) on
   the same memory replay run 1's thinking, tool and notice blocks. Invariants: no `LLMError`, the totals,
   three calls in run 1 (the final-call path ran), and at least one thinking block in memory (otherwise the
   probe proves nothing). Expected live calls: 3 + 2 + 1.
3. **Scenario 16 — paused MCP turn, crash, new input; cited replay** (`e2e/16_mcp_pause.exs`,
   Haiku 4.5, cap 8).
   - *Part A, live path.* An agent whose only tools are a public MCP server's (`mcp_servers:`, Header
     conflict 1) runs under `Turn.Session` (lazy resume, the default) with a `:subscriber`. The prompt
     asks for 12 sequential calls of one MCP tool. The API's server-side loop stops after 10 iterations
     with `stop_reason: "pause_turn"`; Normandy appends the paused response (persisted before the next
     effect, `server.ex:1419-1433`) and continues the turn (`Turn.continue_paused/2`, `turn.ex:509-512`),
     which emits `:iteration` with `iteration > 1` before the continuation call. The subscriber runs in the
     server process; on that event, with the store's last assistant entry paused, it tells the scenario
     and blocks; the scenario kills the server, waits for the supervisor's restart, and sends new input.
     The restarted server (lazy) appends the user message after the paused turn — the exact shape of the
     known limit — and the invariant is that the API accepts it.
   - *Part A, fallbacks.* If the turn finishes without a pause, the scenario reconstructs the shape:
     one `BaseAgent.get_response/2` with the MCP server, the response cut after its first `mcp_tool_use`
     (its result dropped), stored as a paused `%ToolCallResponse{}`, then `run/3` with new input. If no
     candidate server answers an MCP `initialize` from this machine, it does the same at Claudio level with
     `web_search` (Normandy cannot declare server tools, `claudio_adapter.ex:838-844`). The scenario prints
     `PAUSE_PATH live | synthetic_mcp | synthetic_web_search` so Task 7.6b knows which was verified.
   - *Part B, citations.* A text document with citations enabled and a client tool requested in the same
     reply: the cited text block and the `tool_use` arrive together, the tool runs, and the next request
     replays the cited block (Claudio 0.7.1). Invariants: the answer arrives (`{:ok, …}`) and memory holds a
     tool-call turn with a cited text block. Prints `CITATIONS_REPLAY accepted (N cited block(s))`.

**How the pause is provoked, honestly.** Candidates (no authorization; checked by name and documented
URL, not reachable from this sandbox while writing): DeepWiki `https://mcp.deepwiki.com/mcp`
(tool `read_wiki_structure`, argument `repoName`), the remote Fetch server
`https://remote.mcpservers.org/fetch/mcp` (tool `fetch`, argument `url`); GitMCP
(`https://gitmcp.io/<owner>/<repo>`) is a third if both fail. `pause_turn` comes from the API's
server-side sampling loop reaching its limit of 10 iterations (Anthropic docs, "Stop reasons for
server-side tools"). That is documented for server tools; I have not seen it documented for the MCP
connector, and a model may batch calls into one iteration or stop early. So a live pause is likely but
**not reliable**: the scenario does not fail when none comes; it takes the reconstructed path and says
so, and Task 7.6b words the Known-limits bullet by which path ran.

**Files (7.6a-i):**
- Create: `test/support/e2e/prices.ex` (`NormandyTest.E2E.Prices`)
- Modify: `e2e/support.exs` (`model/1`, usage per model, stream usage handler, `report/0`; failure paths report)
- Modify: `test/support/e2e/runner.ex` (`@suite_cap 150`, scenario 16 timeout, usage in `parse_result/1`,
  `run_one/2`, `summary/1`; `estimate/1`; `--estimate` in `main/1`)
- Test: modify `test/e2e/runner_test.exs`; create `test/e2e/prices_test.exs`

**Interfaces (7.6a-i):**
- Consumes: Claudio telemetry `[:claudio, :messages, :create, :stop]` (measurements: token keys;
  metadata `:model`) and `[:claudio, :messages, :stream, :stop]`.
- Produces (header "e2e usage total"): the `usage:` line per scenario and `usage (known):` in the
  summary; `E2E_RESULT` gains `"usage": {"input", "output", "cache_read", "cache_write", "cost_usd"}`;
  `NormandyTest.E2E.Runner.estimate/1 :: String.t()`; `mix e2e --estimate [names]`;
  `NormandyTest.E2E.Prices.price!/1`, `totals/1`, `sum/1`, `format/2`. Task 7.6b consumes all of them.

- [ ] **Step 1: Write the failing tests**

Create `test/e2e/prices_test.exs`:

```elixir
defmodule NormandyTest.E2E.PricesTest do
  @moduledoc "Task 7.6a: e2e token totals and their estimated cost (REL-9)."
  use ExUnit.Case, async: true

  alias NormandyTest.E2E.Prices

  test "totals/1 sums tokens per call and prices them by model" do
    calls = [
      {"claude-haiku-4-5-20251001",
       %{
         input_tokens: 1_000_000,
         output_tokens: 100_000,
         cache_read_input_tokens: 1_000_000,
         cache_creation_input_tokens: 0
       }},
      {"claude-opus-5-5", %{input_tokens: 0, output_tokens: 50_000, cache_creation_input_tokens: 200_000}},
      # A streamed call's create:stop carries no tokens and may carry no model.
      {nil, %{}}
    ]

    assert %{
             input: 1_000_000,
             output: 150_000,
             cache_read: 1_000_000,
             cache_write: 200_000,
             cost: cost
           } = Prices.totals(calls)

    # Haiku 1.00 + 0.50 + 0.10; Opus 1.00 (output) + 1.00 (cache write).
    assert_in_delta cost, 3.60, 1.0e-9
  end

  test "format/2 prints the usage line" do
    totals = %{input: 10, output: 2, cache_read: 0, cache_write: 4, cost: 1.234}

    assert Prices.format(totals) ==
             "usage: input=10 output=2 cache_read=0 cache_write=4 est_cost=$1.23"

    assert Prices.format(totals, "usage (known)") =~ "usage (known): input=10"
  end

  test "price!/1 names an unknown model, and a priced call needs a model" do
    assert_raise ArgumentError,
                 ~s(no e2e price for model "gpt-x"; add it to NormandyTest.E2E.Prices ) <>
                   ~s{(known prefixes: "claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5")},
                 fn -> Prices.price!("gpt-x") end

    assert_raise ArgumentError, ~r/carries tokens but no model/, fn ->
      Prices.totals([{nil, %{input_tokens: 5}}])
    end
  end

  test "sum/1 adds totals" do
    a = %{input: 1, output: 2, cache_read: 3, cache_write: 4, cost: 0.5}
    assert Prices.sum([a, a]) == %{input: 2, output: 4, cache_read: 6, cache_write: 8, cost: 1.0}
    assert Prices.sum([]) == %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
  end
end
```

In `test/e2e/runner_test.exs`:

- Replace the test `"preflight refuses a selection whose live-call caps exceed the suite cap"` body with:

```elixir
    big = Enum.map(1..9, &%{id: "0#{&1}_s", name: "s", path: "p", cap: 18})

    assert {:error, msg} = Runner.preflight("sk-x", big, fn -> :ok end)
    assert msg =~ "162"
    assert msg =~ "150"
```

- Replace the test `"summary shows unknown call counts as ? and totals the known ones"` with:

```elixir
  test "summary shows unknown counts and costs as ? and totals the known ones" do
    table =
      Runner.summary([
        %{
          id: "01_a",
          status: :pass,
          exit: 0,
          calls: 8,
          ms: 12_000,
          log: "l",
          reason: nil,
          usage: %{input: 1_000, output: 200, cache_read: 0, cache_write: 0, cost: 0.12}
        },
        %{id: "02_b", status: :fail, exit: 2, calls: nil, ms: 3_000, log: "l", reason: nil, usage: nil}
      ])

    assert table =~ "| scenario | result | exit | live calls | wall s | est $ |"
    assert table =~ "| 01_a | PASS | 0 | 8 | 12.0 | 0.12 |"
    assert table =~ "| 02_b | FAIL | 2 | ? | 3.0 | ? |"
    assert table =~ "total live calls (known): 8"

    assert table =~
             "usage (known): input=1000 output=200 cache_read=0 cache_write=0 est_cost=$0.12"
  end
```

- Add these tests before the last `end`:

```elixir
  test "parse_result reads the usage block" do
    out =
      ~s(E2E_RESULT {"scenario":"x","calls":2,"ms":5,"usage":{"input":10,"output":2,) <>
        ~s("cache_read":0,"cache_write":4,"cost_usd":0.25}})

    assert {:ok,
            %{
              calls: 2,
              ms: 5,
              usage: %{input: 10, output: 2, cache_read: 0, cache_write: 4, cost: 0.25}
            }} = Runner.parse_result(out)
  end

  test "parse_result names a malformed usage block" do
    out = ~s(E2E_RESULT {"scenario":"x","calls":2,"ms":5,"usage":{"input":"ten"}})

    assert {:error, "malformed E2E_RESULT usage: " <> _} = Runner.parse_result(out)
  end

  test "parse_result leaves usage nil when the scenario printed none" do
    assert {:ok, %{usage: nil}} =
             Runner.parse_result(~s(E2E_RESULT {"scenario":"x","calls":1,"ms":2}))
  end

  test "estimate prices every scenario at its cap, Opus where the scenario asks for it",
       %{tmp_dir: dir} do
    File.write!(Path.join(dir, "01_a.exs"), ~s|S.start("01_a", cap: 20)|)

    File.write!(
      Path.join(dir, "15_preserved_thinking.exs"),
      ~s|S.start("15_preserved_thinking", cap: 8)\nmodel: S.model(:opus)|
    )

    text = Runner.estimate(Runner.discover(dir))

    assert text =~ "| 01_a | claude-haiku-4-5 | 20 | 6000+400 | 0.16 | 0.19 |"
    assert text =~ "| 15_preserved_thinking | claude-opus-5-5 | 8 | 8000+2000 | 0.58 | 0.64 |"
    assert text =~ "estimate: $0.74 expected, $0.83 upper bound"
  end
```

(`@moduletag :tmp_dir` is already set at the top of the file.)

- [ ] **Step 2: Run them and see them fail**

```bash
mix format
mix test test/e2e/prices_test.exs test/e2e/runner_test.exs
```

Expected: the 4 `prices_test.exs` tests fail with `UndefinedFunctionError` (module
`NormandyTest.E2E.Prices` is not available); in `runner_test.exs` the preflight test fails (`msg` says 140, not 150), the summary test
fails (no `est $` column), the two usage `parse_result` tests fail (no `usage` key), and the estimate
test fails (`Runner.estimate/1` is undefined). The `usage nil` test fails too (no `:usage` key).

- [ ] **Step 3: Implement `NormandyTest.E2E.Prices`**

Create `test/support/e2e/prices.ex`:

```elixir
defmodule NormandyTest.E2E.Prices do
  @moduledoc """
  USD per million tokens for the models the live e2e suite calls: Anthropic API list prices
  as of 2026-10. `cache_write` is the 5-minute cache write (1.25 x input). Used by
  `e2e/support.exs` for each scenario's usage line and by `NormandyTest.E2E.Runner` for the
  summary and `mix e2e --estimate`. An estimate, not an invoice: no batch or fast-mode
  pricing, no server-tool fees (web search bills per search).
  """

  @prices [
    {"claude-haiku-4-5", %{input: 1.00, output: 5.00, cache_read: 0.10, cache_write: 1.25}},
    {"claude-sonnet-5-5", %{input: 2.00, output: 10.00, cache_read: 0.20, cache_write: 2.50}},
    {"claude-opus-5-5", %{input: 4.00, output: 20.00, cache_read: 0.20, cache_write: 5.00}}
  ]

  @zero %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}

  @doc "The price row whose model-id prefix `model` starts with (dated ids included)."
  @spec price!(String.t()) :: map()
  def price!(model) when is_binary(model) do
    case Enum.find(@prices, fn {prefix, _} -> String.starts_with?(model, prefix) end) do
      {_prefix, price} ->
        price

      nil ->
        raise ArgumentError,
              "no e2e price for model #{inspect(model)}; add it to #{inspect(__MODULE__)} " <>
                "(known prefixes: #{Enum.map_join(@prices, ", ", &inspect(elem(&1, 0)))})"
    end
  end

  @doc """
  Token totals and estimated cost of `calls`, a list of `{model, measurements}` where the
  measurements are Claudio's telemetry token keys. A call with no tokens costs nothing
  whatever its model (a streamed request's `create` stop); one with tokens needs a model.
  """
  @spec totals([{String.t() | nil, map()}]) :: map()
  def totals(calls) do
    Enum.reduce(calls, @zero, fn {model, m}, acc ->
      t = %{
        input: Map.get(m, :input_tokens, 0),
        output: Map.get(m, :output_tokens, 0),
        cache_read: Map.get(m, :cache_read_input_tokens, 0),
        cache_write: Map.get(m, :cache_creation_input_tokens, 0)
      }

      sum([acc, Map.put(t, :cost, cost(model, t))])
    end)
  end

  defp cost(_model, %{input: 0, output: 0, cache_read: 0, cache_write: 0}), do: 0.0

  defp cost(nil, t) do
    raise ArgumentError,
          "an e2e call carries tokens but no model in its telemetry metadata: #{inspect(t)}"
  end

  defp cost(model, t) do
    p = price!(model)

    (t.input * p.input + t.output * p.output + t.cache_read * p.cache_read +
       t.cache_write * p.cache_write) / 1_000_000
  end

  @doc "Adds totals maps."
  @spec sum([map()]) :: map()
  def sum(totals) do
    Enum.reduce(totals, @zero, fn t, acc ->
      %{
        input: acc.input + t.input,
        output: acc.output + t.output,
        cache_read: acc.cache_read + t.cache_read,
        cache_write: acc.cache_write + t.cache_write,
        cost: acc.cost + t.cost
      }
    end)
  end

  @doc "The one-line usage report: `<label>: input=N output=N cache_read=N cache_write=N est_cost=$X.XX`."
  @spec format(map(), String.t()) :: String.t()
  def format(t, label \\ "usage") do
    "#{label}: input=#{t.input} output=#{t.output} cache_read=#{t.cache_read} " <>
      "cache_write=#{t.cache_write} est_cost=$#{dollars(t.cost)}"
  end

  @doc "Dollars with two decimals."
  @spec dollars(number()) :: String.t()
  def dollars(amount), do: :erlang.float_to_binary(amount / 1, decimals: 2)
end
```

- [ ] **Step 4: Usage in `e2e/support.exs`**

In `e2e/support.exs`:

- Replace `@model "claude-haiku-4-5-20251001"` and `def model, do: @model` with:

```elixir
  @model "claude-haiku-4-5-20251001"
  # Scenario 15 (AX-7): preserved thinking is checked on Opus 5.5, never on Haiku 4.5.
  @opus "claude-opus-5-5"

  alias NormandyTest.E2E.Prices

  def model, do: @model
  def model(:opus), do: @opus
```

- In `start/2`, add `priced: []` to the Agent's initial map (beside `usages: []`), and after the
  `:telemetry.attach("e2e-claudio-calls", ...)` line add:

```elixir
    # A streamed request reports its tokens when the stream ends, not on create's stop.
    :ok =
      :telemetry.attach(
        "e2e-claudio-stream-usage",
        [:claudio, :messages, :stream, :stop],
        &__MODULE__.on_stream_usage/4,
        nil
      )
```

- Replace `def on_call(_event, measurements, _meta, _config), do: count_remote_call(measurements)` and
  the whole `count_remote_call/1` with:

```elixir
  @doc false
  def on_call(_event, measurements, meta, _config),
    do: count_remote_call(measurements, Map.get(meta, :model))

  @doc false
  def on_stream_usage(_event, measurements, meta, _config) do
    Agent.update(__MODULE__, fn s -> %{s | priced: s.priced ++ [{Map.get(meta, :model), measurements}]} end)
  end

  @doc "Count one real Messages API request; halts the scenario when the cap is exceeded."
  def count_remote_call(measurements, model \\ @model) do
    {n, cap} =
      Agent.get_and_update(__MODULE__, fn s ->
        s = %{
          s
          | calls: s.calls + 1,
            usages: s.usages ++ [measurements],
            priced: s.priced ++ [{model, measurements}]
        }

        {{s.calls, s.cap}, s}
      end)

    if n > cap do
      IO.puts("INVARIANT FAILED: live-call cap #{cap} exceeded (#{n})")
      report()
      otel_report()
      System.halt(2)
    end

    :ok
  end
```

(Scenario 11's sink calls `count_remote_call/1` with a peer's measurements; its peers run `S.model()`,
which the default covers.)

- Replace the failing clause of `assert!/3`:

```elixir
  def assert!(label, _falsy, msg) do
    IO.puts("INVARIANT FAILED: #{label} — #{msg}")
    report()
    otel_report()
    System.halt(2)
  end
```

- Replace `finish/0` with:

```elixir
  def finish do
    otel_report()
    report()
  end

  # The usage line and the E2E_RESULT line the runner parses; also printed before a failure
  # halts, so a failed scenario's spend is known too.
  defp report do
    %{id: id, calls: n, t0: t0, priced: priced} = Agent.get(__MODULE__, & &1)
    ms = System.monotonic_time(:millisecond) - t0
    totals = Prices.totals(priced)
    IO.puts("\nLIVE CALLS USED: #{n}")
    IO.puts(Prices.format(totals))

    usage = %{
      input: totals.input,
      output: totals.output,
      cache_read: totals.cache_read,
      cache_write: totals.cache_write,
      cost_usd: Float.round(totals.cost, 6)
    }

    IO.puts("E2E_RESULT " <> Jason.encode!(%{scenario: id, calls: n, ms: ms, usage: usage}))
  end
```

- [ ] **Step 5: The runner**

In `test/support/e2e/runner.ex`:

- `@suite_cap 140` → `@suite_cap 150`; `@timeouts %{"11_distributed" => 600_000}` →
  `@timeouts %{"11_distributed" => 600_000, "16_mcp_pause" => 600_000}`; add
  `alias NormandyTest.E2E.Prices` under the moduledoc and these attributes under `@distributed`:

```elixir
  # Assumed tokens per call for `estimate/1` (input, output); every scenario at its cap.
  @est_tokens %{"15_preserved_thinking" => {8_000, 2_000}, "16_mcp_pause" => {30_000, 1_000}}
  @default_est_tokens {6_000, 400}
```

- Replace `parse_result/1` with:

```elixir
  def parse_result(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(:missing, fn
      "E2E_RESULT " <> json -> decode_result(json)
      _ -> nil
    end)
  end

  defp decode_result(json) do
    case Jason.decode(json) do
      {:ok, %{"calls" => calls, "ms" => ms} = result} when is_integer(calls) and is_integer(ms) ->
        case decode_usage(Map.get(result, "usage")) do
          {:ok, usage} -> {:ok, %{calls: calls, ms: ms, usage: usage}}
          :error -> {:error, "malformed E2E_RESULT usage: #{String.slice(json, 0, 200)}"}
        end

      _ ->
        {:error, "malformed E2E_RESULT line: #{String.slice(json, 0, 200)}"}
    end
  end

  defp decode_usage(nil), do: {:ok, nil}

  defp decode_usage(%{
         "input" => i,
         "output" => o,
         "cache_read" => r,
         "cache_write" => w,
         "cost_usd" => c
       })
       when is_integer(i) and is_integer(o) and is_integer(r) and is_integer(w) and is_number(c),
       do: {:ok, %{input: i, output: o, cache_read: r, cache_write: w, cost: c / 1}}

  defp decode_usage(_other), do: :error
```

- In `run_one/2`: the `:timeout` branch's `Map.merge(base, %{...})` gains `usage: nil`; in the
  `{:exit, status}` branch the two `{:ok, %{calls: calls}}` clauses become `{:ok, %{calls: calls, usage:
  usage}}` and their maps gain `usage: usage`; the `:missing` and `{:error, reason}` clauses' maps gain
  `usage: nil`. In `run_all/3`, the blocked result map gains `usage: nil`.

- Replace `summary/1` with:

```elixir
  def summary(results) do
    rows =
      Enum.map(results, fn r ->
        calls = if is_integer(r.calls), do: Integer.to_string(r.calls), else: "?"
        exit = if is_integer(r.exit), do: Integer.to_string(r.exit), else: "-"
        secs = :erlang.float_to_binary(r.ms / 1000, decimals: 1)
        cost = if r.usage, do: Prices.dollars(r.usage.cost), else: "?"
        note = if r.reason, do: " #{r.reason}", else: ""

        "| #{r.id} | #{r.status |> Atom.to_string() |> String.upcase()} | #{exit} | #{calls} | " <>
          "#{secs} | #{cost} |#{note}"
      end)

    known = results |> Enum.map(& &1.calls) |> Enum.filter(&is_integer/1) |> Enum.sum()
    usage = results |> Enum.map(& &1.usage) |> Enum.reject(&is_nil/1) |> Prices.sum()

    Enum.join(
      ["| scenario | result | exit | live calls | wall s | est $ |", "|---|---|---|---|---|---|"] ++
        rows ++
        [
          "",
          "total live calls (known): #{known} (suite cap #{@suite_cap})",
          Prices.format(usage, "usage (known)")
        ],
      "\n"
    )
  end

  @doc """
  A spend estimate for `scenarios` before a run: every scenario at its live-call cap, with
  the assumed tokens per call in `@est_tokens`. "Upper" prices every input token as a
  cache write. A scenario that contains `S.model(:opus)` is priced as Opus 5.5.
  """
  def estimate(scenarios) do
    rows =
      Enum.map(scenarios, fn s ->
        model = if File.read!(s.path) =~ "S.model(:opus)", do: "claude-opus-5-5", else: "claude-haiku-4-5"
        {input, output} = Map.get(@est_tokens, s.id, @default_est_tokens)
        p = Prices.price!(model)
        expected = s.cap * (input * p.input + output * p.output) / 1_000_000
        upper = s.cap * (input * p.cache_write + output * p.output) / 1_000_000
        {"| #{s.id} | #{model} | #{s.cap} | #{input}+#{output} | #{Prices.dollars(expected)} | " <>
           "#{Prices.dollars(upper)} |", expected, upper}
      end)

    expected = rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    upper = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    Enum.join(
      ["| scenario | model | cap | tokens/call in+out | est $ | upper $ |", "|---|---|---|---|---|---|"] ++
        Enum.map(rows, &elem(&1, 0)) ++
        [
          "",
          "estimate: $#{Prices.dollars(expected)} expected, $#{Prices.dollars(upper)} upper bound " <>
            "(every scenario at its cap)"
        ],
      "\n"
    )
  end
```

- In `main/1`, before `all = discover("e2e")`'s `with`, handle the flag. Replace the body with:

```elixir
  def main(["--estimate" | names]) do
    all = discover("e2e")

    with {:ok, selected} <- select(all, names),
         :ok <- check_caps(selected) do
      IO.puts(estimate(selected))
      System.halt(0)
    else
      {:error, msg} ->
        IO.puts(:stderr, "mix e2e --estimate: " <> msg)
        System.halt(1)
    end
  end

  def main(argv) do
    all = discover("e2e")
    key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("API_KEY")

    with {:ok, selected} <- select(all, argv),
         {:ok, %{blocked: blocked}} <- preflight(key, selected, &postgres_check/0) do
      dir = Path.join(["e2e", "reports", Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")])
      File.mkdir_p!(dir)
      results = run_all(selected, blocked, dir)
      table = summary(results)
      File.write!(Path.join(dir, "summary.md"), table <> "\n")
      IO.puts("\n" <> table <> "\nreports: #{dir}")
      if Enum.all?(results, &(&1.status == :pass)), do: System.halt(0), else: System.halt(1)
    else
      {:error, msg} ->
        IO.puts(:stderr, "mix e2e: " <> msg)
        System.halt(1)
    end
  end
```

  and move the `@dialyzer {:nowarn_function, main: 1}` line above the first `main/1` clause (it already
  covers both clauses).

- [ ] **Step 6: Run the offline tests and see them pass**

```bash
mix format
mix test test/e2e/prices_test.exs test/e2e/runner_test.exs
```

Expected: `0 failures` (4 prices tests; the runner file's existing 17 tests plus 4 new ones).

- [ ] **Step 7: Gate and commit 7.6a-i**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w7-7.6a-i.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.6a-i.log
mix docs --warnings-as-errors
git add test/support/e2e/prices.ex
git add test/support/e2e/runner.ex
git add test/e2e/prices_test.exs
git add test/e2e/runner_test.exs
git add e2e/support.exs
git commit -m "test(e2e): usage and cost per scenario, mix e2e --estimate"
```

Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite (no library code). MIGRATING: none (test
tooling only).

---

### Task 7.6a-ii: e2e scenario 15 (AX-7 on Opus 5.5) and scenario 16 (MCP pause, crash, new input; citations replay) (decision 27 F3, F4, B3)

Parts 2 and 3 of the design under Task 7.6a-i, and "How the pause is provoked, honestly" there.

**Files (7.6a-ii):**
- Create: `e2e/15_preserved_thinking.exs`, `e2e/16_mcp_pause.exs`
- Modify: `e2e/README.md`

**Interfaces (7.6a-ii):**
- Consumes: `E2E.Support.model/1`, `report/0` (7.6a-i); `BaseAgent.init/1` (`mcp_servers:`,
  `max_tool_iterations:`, `output_schema:`), `BaseAgent.run/3`, `stream/3`, `get_response/2`,
  `register_tool/2`, `Turn.Session.new/1` (`:subscriber`), `Turn.Session.run/2`,
  `Turn.Supervisor.start_link/1`, `SessionStore.InMemory.history/2`, `SessionRegistry.Native.whereis/2`,
  `Normandy.MCP.ServerConfig.new/2` / `allow_tools/2`, `AgentMemory.add_message/3` / `messages/1`,
  Claudio `Client.new/1`, `Messages.create/2`, `Request.add_web_search_tool/2`,
  `Response.to_assistant_content/1`.
- Produces: the `PAUSE_PATH`, `PAUSE_SHAPE` and `CITATIONS_REPLAY` lines Task 7.6b reads.

There is no offline failing test for a live scenario: each one's first action is a paid API call. Step 3
checks that they parse and that every function they call exists; Task 7.6b runs them.

- [ ] **Step 1: Scenario 15**

Create `e2e/15_preserved_thinking.exs`:

```elixir
# e2e/15_preserved_thinking.exs — AX-7: Normandy's history replays under preserved thinking.
# Opus 5.5 with thinking_block_binding: :error rejects a request whose replayed thinking no
# longer matches the conversation it was produced in. A tool loop that reaches its iteration
# cap (the final call: tool_choice :none and the notice, output_config.format beside the
# tools), then run/3 and stream/3 on the same memory, must all be accepted.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.{BaseAgent, ToolCallResponse}
alias Normandy.Components.{AgentMemory, Message}

defmodule E2E.S15.Stock do
  use Normandy.Schema

  io_schema "Stock levels the agent looked up" do
    field(:total, :integer, required: true, description: "sum of the units of every SKU looked up")
    field(:skus, {:array, :string}, required: true, description: "the SKUs looked up, in order")
  end
end

defmodule E2E.S15.Lookup do
  defmodule Input do
    use Normandy.Schema

    io_schema "Look up one SKU's stock." do
      field(:sku, :string, required: true, description: "the SKU, for example A1")
    end
  end

  use Normandy.Tool,
    name: "stock_lookup",
    description: "Look up one SKU's stock. The result may name a linked SKU to look up next.",
    input: Input

  defstruct []

  @stock %{
    "A1" => "7 units. Linked SKU: B2 (look it up too).",
    "B2" => "5 units. No linked SKU.",
    "C3" => "4 units. No linked SKU."
  }

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{sku: sku}}) do
    case Map.fetch(@stock, String.upcase(sku)) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "unknown SKU #{sku}; known: A1, B2, C3"}
    end
  end
end

S.start("15_preserved_thinking", cap: 8)

agent =
  BaseAgent.init(%{
    client: S.client(%{thinking: :adaptive, thinking_block_binding: :error, recv_timeout: 180_000}),
    model: S.model(:opus),
    max_tokens: 4_000,
    name: "s15",
    output_schema: struct!(E2E.S15.Stock),
    max_tool_iterations: 2
  })
  |> BaseAgent.register_tool(struct!(E2E.S15.Lookup))

# An LLMError's message carries the API's text: a 400 naming thinking is the finding.
expect_stock = fn label, result ->
  case result do
    {:ok, agent, %E2E.S15.Stock{} = stock} -> {agent, stock}
    {:error, error} -> S.assert!(label, false, Exception.message(error))
    other -> S.assert!(label, false, inspect(other))
  end
end

thinking_replayed? = fn agent ->
  agent.memory
  |> AgentMemory.messages()
  |> Enum.any?(fn
    %Message{role: "assistant", content: %ToolCallResponse{content_blocks: blocks}} ->
      Enum.any?(blocks, &(&1["type"] in ["thinking", "redacted_thinking"]))

    _other ->
      false
  end)
end

S.narrate("Run 1: two chained lookups, then the iteration cap forces the final call.")
before = S.calls()

{agent, s1} =
  expect_stock.(
    "run 1 is accepted",
    BaseAgent.run(agent, %{
      chat_message:
        "Look up SKU A1 with stock_lookup. Its result names a linked SKU: look that one up " <>
          "too, one call at a time. Then report the total units and the SKUs."
    })
  )

S.turn(1, "A1 and its linked SKU", inspect(s1))
S.assert!("run 1 made 3 calls: two tool rounds, then the forced final call", S.calls() - before == 3, "#{S.calls() - before}")
S.assert!("run 1 totals A1 + B2 = 12", s1.total == 12, inspect(s1))
S.assert!("memory holds thinking blocks to replay (else this probe proves nothing)", thinking_replayed?.(agent), "no thinking block in any assistant tool turn")

S.narrate("Run 2 (run/3) on the same memory: run 1's thinking, tool and notice blocks replay.")

{agent, s2} =
  expect_stock.(
    "run 2 is accepted (replayed thinking still binds)",
    BaseAgent.run(agent, %{chat_message: "Also look up SKU C3 and report the new total of all three SKUs."})
  )

S.turn(2, "add C3", inspect(s2))
S.assert!("run 2 totals 16", s2.total == 16, inspect(s2))

S.narrate("Run 3 (stream/3) on the same memory.")

{_agent, s3} =
  expect_stock.(
    "the streamed run 3 is accepted",
    BaseAgent.stream(agent, %{chat_message: "Repeat the total and the SKUs. No lookups."}, fn _event -> :ok end)
  )

S.turn(3, "repeat", inspect(s3))
S.assert!("run 3 repeats 16", s3.total == 16, inspect(s3))

S.finish()
```

- [ ] **Step 2: Scenario 16**

Create `e2e/16_mcp_pause.exs`:

```elixir
# e2e/16_mcp_pause.exs — Part A: a turn paused on the MCP connector (pause_turn), its
# Turn.Server killed while paused, then new input on the restarted server (decision 27 F3).
# Part B: a cited text block replayed on the next request (Claudio 0.7.1, decision 27 B3).
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema, ToolCallResponse, Turn}
alias Normandy.Behaviours.SessionRegistry.Native
alias Normandy.Behaviours.SessionStore.InMemory
alias Normandy.Components.{AgentMemory, Message}
alias Normandy.MCP.ServerConfig

defmodule E2E.S16.RecordCity do
  defmodule Input do
    use Normandy.Schema

    io_schema "Record the city your answer names." do
      field(:city, :string, required: true, description: "the city")
    end
  end

  use Normandy.Tool,
    name: "record_city",
    description: "Record the city your answer names. Call it in the same reply as the answer.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{city: city}}), do: {:ok, "recorded #{city}"}
end

S.start("16_mcp_pause", cap: 8)

# Public MCP servers that need no authorization, tried in order. One tool, called once per
# item in sequence: 12 calls overrun the API's server-side loop (10 iterations).
candidates = [
  %{
    name: "deepwiki",
    url: "https://mcp.deepwiki.com/mcp",
    tool: "read_wiki_structure",
    items:
      ~w(elixir-lang/elixir phoenixframework/phoenix elixir-ecto/ecto elixir-plug/plug
         wojtekmach/req dashbitco/broadway elixir-nx/nx phoenixframework/phoenix_live_view
         sorentwo/oban absinthe-graphql/absinthe elixir-mint/mint beam-telemetry/telemetry)
  },
  %{
    name: "fetch",
    url: "https://remote.mcpservers.org/fetch/mcp",
    tool: "fetch",
    items: for(n <- 1..12, do: "https://example.com/?item=#{n}")
  }
]

# Reachable from this machine is not proof the API reaches it, but an unreachable one is
# certainly skipped.
reachable? = fn %{url: url} ->
  body = %{
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: %{
      protocolVersion: "2025-06-18",
      capabilities: %{},
      clientInfo: %{name: "normandy-e2e", version: "0"}
    }
  }

  case Req.post(url,
         json: body,
         headers: [{"accept", "application/json, text/event-stream"}],
         receive_timeout: 10_000,
         retry: false
       ) do
    {:ok, %Req.Response{status: 200}} -> true
    _other -> false
  end
end

prompt = fn %{tool: tool, items: items} ->
  "Call the #{tool} tool exactly once for each of the #{length(items)} items below, strictly " <>
    "one call at a time: make one call, wait for its result, then make the next. Never put two " <>
    "tool calls in one step. After the last call, reply with one short line per item.\n" <>
    Enum.map_join(items, "\n", &("- " <> &1))
end

agent_for = fn server, name ->
  BaseAgent.init(%{
    client: S.client(%{recv_timeout: 290_000}),
    model: S.model(),
    max_tokens: 4_000,
    name: name,
    max_tool_iterations: 3,
    mcp_servers: [ServerConfig.new(server.name, server.url) |> ServerConfig.allow_tools([server.tool])]
  })
end

paused_entry? = fn
  %{role: "assistant", content: %ToolCallResponse{stop_reason: reason}} -> reason in [:pause_turn, "pause_turn"]
  _other -> false
end

accepted? = fn
  {:ok, %{chat_message: text}} when is_binary(text) -> String.trim(text) != ""
  {:ok, _config, %{chat_message: text}} when is_binary(text) -> String.trim(text) != ""
  {:ok, %Claudio.Messages.Response{}} -> true
  _other -> false
end

followup = "Stop the lookups now. In one sentence, how many items do you have results for?"

# The paused shape rebuilt from a real MCP response: cut after its first mcp_tool_use
# (dropping that call's result), stored as a paused turn, then new input.
synthetic_mcp = fn server ->
  config = agent_for.(server, "s16-synthetic")
  ask = %BaseAgentInputSchema{chat_message: "Call #{server.tool} once for #{hd(server.items)}, then answer in one sentence."}
  config = %{config | memory: AgentMemory.add_message(config.memory, "user", ask)}
  %ToolCallResponse{content_blocks: blocks} = BaseAgent.get_response(config, %ToolCallResponse{})

  case Enum.find_index(blocks, &(&1["type"] == "mcp_tool_use")) do
    nil ->
      S.assert!("the model called the MCP tool (material for the rebuilt pause)", false, inspect(blocks))

    i ->
      paused = %ToolCallResponse{content_blocks: Enum.take(blocks, i + 1), stop_reason: :pause_turn}
      config = %{config | memory: AgentMemory.add_message(config.memory, "assistant", paused)}
      IO.puts("PAUSE_PATH synthetic_mcp")
      BaseAgent.run(config, %{chat_message: followup})
  end
end

# The same shape with the API's web_search server tool, through Claudio: Normandy cannot
# declare server tools.
synthetic_web = fn ->
  alias Claudio.Messages.{Request, Response}
  client = Claudio.Client.new(%{token: S.api_key!(), version: "2023-06-01"})

  request =
    Request.new(S.model())
    |> Request.set_max_tokens(1_000)
    |> Request.add_web_search_tool(version: :basic)
    |> Request.add_message(:user, "Search the web once for the Elixir programming language, then answer in one sentence.")

  {:ok, response} = Claudio.Messages.create(client, request)
  blocks = Response.to_assistant_content(response)

  case Enum.find_index(blocks, &(&1["type"] == "server_tool_use")) do
    nil ->
      S.assert!("the model searched (material for the rebuilt pause)", false, inspect(blocks))

    i ->
      IO.puts("PAUSE_PATH synthetic_web_search")

      request
      |> Request.add_message(:assistant, Enum.take(blocks, i + 1))
      |> Request.add_message(:user, "Answer in one sentence without searching again.")
      |> then(&Claudio.Messages.create(client, &1))
  end
end

S.narrate("Part A: a paused MCP-connector turn, its server killed, then new input.")
server = Enum.find(candidates, reachable?)

result =
  if server do
    S.narrate("Live: #{server.name} (#{server.url}), #{length(server.items)} sequential #{server.tool} calls in one turn.")
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    sid = "e2e-pause-#{System.unique_integer([:positive])}"
    scenario = self()
    armed = :atomics.new(1, [])

    # Runs in the Turn.Server process. The :iteration event after a paused response comes
    # after that response is in the store; tell the scenario, then wait to be killed.
    subscriber = fn
      :iteration, %{iteration: i} when i > 1 ->
        {:ok, entries} = InMemory.history(store, sid)
        last = entries |> Enum.reverse() |> Enum.find(&(&1.role == "assistant"))

        if paused_entry?.(last) and :atomics.compare_exchange(armed, 1, 0, 1) == :ok do
          send(scenario, {:paused, self()})

          receive do
            :release -> :ok
          after
            60_000 -> :ok
          end
        end

      _name, _meta ->
        :ok
    end

    session =
      Turn.Session.new(
        session_id: sid,
        config: agent_for.(server, "s16"),
        store: {InMemory, store},
        registry: {Native, reg},
        supervisor: sup,
        subscriber: subscriber
      )

    task =
      Task.async(fn ->
        try do
          Turn.Session.run(session, %{chat_message: prompt.(server)})
        catch
          :exit, reason -> {:exited, reason}
        end
      end)

    receive do
      {:paused, pid} ->
        S.narrate("The turn paused (pause_turn); killing its Turn.Server before the continuation.")
        Process.exit(pid, :kill)
        first = Task.await(task, 30_000)
        S.assert!("the caller of the killed turn gets an exit, not an answer", match?({:exited, _}, first), inspect(first))

        new_pid =
          S.wait_for(
            fn ->
              case Native.whereis(reg, sid) do
                {:ok, p} when p != pid -> p
                _ -> nil
              end
            end,
            10_000,
            "the supervisor restarts the session server"
          )

        S.narrate("Restarted as #{inspect(new_pid)}; new input on the paused history.")
        result = Turn.Session.run(session, %{chat_message: followup})
        {:ok, entries} = InMemory.history(store, sid)
        i = Enum.find_index(entries, paused_entry?)
        S.assert!("the store holds the paused assistant turn", is_integer(i), inspect(Enum.map(entries, & &1.role)))
        S.assert!("the new input directly follows the paused turn", Enum.at(entries, i + 1).role == "user", inspect(Enum.map(entries, & &1.role)))
        IO.puts("PAUSE_PATH live")
        result

      {ref, first} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        S.narrate("No pause_turn: the server-side loop finished the turn (#{inspect(elem(first, 0))}). Rebuilding the paused shape.")
        synthetic_mcp.(server)
    after
      280_000 -> S.assert!("the first turn pauses or finishes within 280 s", false, "neither happened")
    end
  else
    S.narrate("No candidate MCP server answered an initialize from here; rebuilding the shape with web_search.")
    synthetic_web.()
  end

S.assert!("the API accepts new input after a paused turn", accepted?.(result), inspect(result))
IO.puts("PAUSE_SHAPE accepted")

S.narrate("Part B: a cited answer and a tool call in one reply; the cited block is replayed.")

doc = %{
  "type" => "document",
  "source" => %{
    "type" => "text",
    "media_type" => "text/plain",
    "data" => "The capital of France is Paris. Paris has about two million residents."
  },
  "title" => "France facts",
  "citations" => %{"enabled" => true}
}

cited =
  BaseAgent.init(%{client: S.client(), model: S.model(), max_tokens: 800, name: "s16b", max_tool_iterations: 2})
  |> BaseAgent.register_tool(struct!(E2E.S16.RecordCity))

cited = %{cited | memory: AgentMemory.add_message(cited.memory, "user", [doc, %{"type" => "text", "text" => "Read the document above."}])}

case BaseAgent.run(cited, %{
       chat_message:
         "In one reply: state France's capital in one sentence, citing the document, and call " <>
           "record_city with that city."
     }) do
  {:ok, cited, %{chat_message: text}} ->
    S.turn(1, "cite and record", text)

    blocks =
      for %Message{role: "assistant", content: %ToolCallResponse{content_blocks: b}} <-
            AgentMemory.messages(cited.memory),
          block <- b,
          block["type"] == "text" and is_list(block["citations"]),
          do: block

    S.assert!("the tool-call turn carried a cited text block (else the replay was not exercised)", blocks != [], inspect(AgentMemory.messages(cited.memory)))
    IO.puts("CITATIONS_REPLAY accepted (#{length(blocks)} cited block(s))")

  {:error, error} ->
    S.assert!("the API accepts the replayed cited turn", false, Exception.message(error))
end

S.finish()
```

- [ ] **Step 3: Check that both scenarios parse and resolve (no API call)**

```bash
for f in e2e/15_preserved_thinking.exs e2e/16_mcp_pause.exs; do
  MIX_ENV=test mix run -e "
    {:ok, ast} = Code.string_to_quoted(File.read!(\"$f\"))
    IO.puts(\"parsed $f\")
  "
done
MIX_ENV=test mix run -e 'IO.inspect(Enum.map(NormandyTest.E2E.Runner.discover("e2e"), &{&1.id, &1.cap}))'
MIX_ENV=test mix run e2e/run.exs --estimate
```

Expected: `parsed …` for both; the discover list ends with `{"15_preserved_thinking", 8}` and
`{"16_mcp_pause", 8}`; the estimate's last line is `estimate: $1.92 expected, $2.24 upper bound (every
scenario at its cap)` (01–14 Haiku at 133 calls: 1.06 / 1.26; 15 Opus: 0.58 / 0.64; 16 Haiku: 0.28 /
0.34). Running a scenario file is not possible offline: each starts by calling the API.

Then confirm every remote call in the two new files exists (the inventory's AST probe idea, by hand):

```bash
MIX_ENV=test mix run -e '
for {m, f, a} <- [
  {Normandy.Agents.BaseAgent, :get_response, 2}, {Normandy.Agents.BaseAgent, :stream, 3},
  {Normandy.Agents.Turn.Session, :new, 1}, {Normandy.Agents.Turn.Supervisor, :start_link, 1},
  {Normandy.MCP.ServerConfig, :allow_tools, 2}, {Normandy.Components.AgentMemory, :add_message, 3},
  {Normandy.Behaviours.SessionStore.InMemory, :history, 2}, {Normandy.Behaviours.SessionRegistry.Native, :whereis, 2},
  {Claudio.Messages.Request, :add_web_search_tool, 2}, {Claudio.Messages.Response, :to_assistant_content, 1},
  {Claudio.Client, :new, 1}, {Claudio.Messages, :create, 2}
] do
  Code.ensure_loaded!(m)
  IO.puts("#{inspect(m)}.#{f}/#{a} #{function_exported?(m, f, a)}")
end'
```

Expected: every line ends `true`.

- [ ] **Step 4: `e2e/README.md`**

- Replace the first paragraph's `Fourteen multi-turn scenarios` with `Sixteen multi-turn scenarios`.
- Replace `**Every run calls the live Anthropic API** (Haiku 4.5).` through `A full run is roughly
  $0.15–0.50.` with:

```markdown
**Every run calls the live Anthropic API**: Haiku 4.5, except scenario 15 (Opus 5.5). Each scenario
declares a live-call cap (`S.start(id, cap: n)`) and halts if it exceeds it; the runner refuses a
selection whose caps sum past 150. `mix e2e --estimate [names]` prints a cap-based estimate without
calling the API (about $1.92, at most $2.24, for the full suite with every scenario at its cap; a real run
uses fewer calls). Each scenario prints `usage: input=N output=N cache_read=N cache_write=N
est_cost=$X.XX`, and the summary adds them up (prices in `test/support/e2e/prices.ex`, list prices as of
2026-10).
```

- In "Prerequisites", replace the scenario 11 bullet with:

```markdown
- Scenario 11 only: a Postgres the test config reaches, with the test database migrated. Either
  `docker compose -f docker-compose.verify.yml up -d` and `MIX_ENV=test mix ecto.setup`, or an existing
  partition database: `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix e2e distributed`
- Scenario 16 only: a public MCP server the API can reach (it tries DeepWiki, then the remote Fetch
  server, and falls back to a rebuilt paused turn; see the scenario's header)
```

- Add two rows to the scenario table:

```markdown
| 15 | preserved_thinking | AX-7: thinking replay on Opus 5.5 with `thinking_block_binding: :error`, final call after the iteration cap, run/3 and stream/3 |
| 16 | mcp_pause | MCP-connector `pause_turn`, `Turn.Server` killed while paused, new input; cited text replayed |
```

- Add after the table:

```markdown
Scenario 16 prints `PAUSE_PATH live` when the API paused the turn and the kill happened on the paused
history, `PAUSE_PATH synthetic_mcp` or `synthetic_web_search` when it rebuilt the paused shape instead
(no pause came, or no MCP server answered), and `CITATIONS_REPLAY accepted (N cited block(s))`.
```

- [ ] **Step 5: Gate and commit**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w7-7.6a-ii.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.6a-ii.log
mix docs --warnings-as-errors
git add e2e/15_preserved_thinking.exs
git add e2e/16_mcp_pause.exs
git add e2e/README.md
git commit -m "test(e2e): scenario 15 preserved thinking on Opus 5.5, scenario 16 MCP pause and citations replay"
```

Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite. MIGRATING: none (test scenarios).

---

### Task 7.6b: The live 2.0 run (decision 4, REL-9; Q approves the spend)

One full `mix e2e` on the final code: the 14 existing scenarios plus 15 and 16. Fixes for what it finds
are separate commits; only failed scenarios are rerun. The log is
`investigations/pre-2.0-audit/e2e-2.0.log` (header). Starts after Task 7.6a (and 7.5b: scenario 16 part B
needs Claudio 0.7.1).

**Files:**
- Create: `investigations/pre-2.0-audit/e2e-2.0.log`
- Modify: `MIGRATING-2.0.md` ("Known limits of 2.0": the paused server-tool bullet, by Step 6)
- Fix commits, if any: files named by the failing scenario's triage (Step 5)

**Interfaces:**
- Consumes: `mix e2e --estimate`, `mix e2e`, the `usage:`/`PAUSE_PATH`/`PAUSE_SHAPE`/`CITATIONS_REPLAY`
  lines (Task 7.6a).
- Produces: the measured cost (summary `usage (known):` line) and the probe results, for Task 7.4b's
  CHANGELOG and Task 7.8's gate.

- [ ] **Step 1: Estimate**

```bash
mix e2e --estimate
```

Expected (16 scenarios, caps 149): the table, ending
`estimate: $1.92 expected, $2.24 upper bound (every scenario at its cap)`. The last real run used 91 calls
for 13 scenarios (`e2e/reports/20261003T211245Z/summary.md`), so the spend is likely near half the
expected figure.

- [ ] **Step 2: Q: approve the spend**

**Q:** the controller shows Q the Step 1 table and asks: "Run the full live e2e suite once (about $1–2,
at most $2.24), then rerun only failed scenarios, up to $1 more in total?" Run nothing until Q says yes.
A rerun that would pass that $1 needs Q's yes again, with its own `mix e2e --estimate <names>`.

- [ ] **Step 3: Run**

```bash
docker start normandy-test-pg
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix e2e 2>&1 | tee investigations/pre-2.0-audit/e2e-2.0.log
```

Scenario 11 uses the existing partition database `normandy_test_w54probe` (Header conflict 5; nothing is
created). Scenario 12 needs Elixir ≥ 1.17 / OTP ≥ 27 (local 1.19/28). Expected: the summary table with 16
rows, `total live calls (known)` and `usage (known): … est_cost=$X.XX`. The controller stops
`normandy-test-pg` afterwards.

- [ ] **Step 4: Check the log**

```bash
grep -cE "sk-ant|x-api-key" investigations/pre-2.0-audit/e2e-2.0.log    # expected: 0
grep -E "^PAUSE_PATH|^PAUSE_SHAPE|^CITATIONS_REPLAY|^usage \(known\)|^\| 1[56]_" investigations/pre-2.0-audit/e2e-2.0.log
```

If the first count is not 0, stop: do not commit the log; tell the controller (the key must be rotated by Q).

- [ ] **Step 5: Triage every FAIL**

For each failed scenario, read its `e2e/reports/<ts>/<id>.log` and classify the first
`INVARIANT FAILED:` line:

- **Model wording** (a recall check on a correct but differently phrased answer): note it in the log
  commit's body; no code change; rerun once in Step 7.
- **Normandy defect**: write an offline test that reproduces it (a `Normandy.Test.WireScript` or
  `Normandy.Test.FakeClient` test on `run/3`, `stream/3` and `Turn.Server`), fix it, run
  `mix precommit` (` 0 failures`), and commit it alone (`fix(<area>): <what>`), with a MIGRATING bullet
  if a user can observe the change. If the fix touches a store backend, `Turn.Server` persistence or the
  registry, also run `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`
  and `mix test --only distributed --include postgres`.
- **A probe result that needs a decision** — stop and report to the controller with the exact
  `INVARIANT FAILED` line and the API error text; the controller asks Q:
  - scenario 15 fails with a 400 that names thinking: Normandy edits replayed history somewhere; which
    edit, and whether to fix it before 2.0, is Q's call;
  - scenario 16 `PAUSE_SHAPE` is not reached (the API rejected new input after a paused turn): the
    options are a 2.0 fix (on admission after a paused last turn, `Turn.Server` first sends the
    continuation) or keeping the known limit with the measured error; Q decides;
  - `CITATIONS_REPLAY` is not reached because the API rejected the replayed citations: Claudio 0.7.1's
    replay is wrong; Q decides between a Claudio 0.7.2 and a known limit.

- [ ] **Step 6: Known limits from the probes**

In `MIGRATING-2.0.md` "Known limits of 2.0", the bullet that starts
`- **A paused server-tool turn after a crash is unverified.**` (three lines) is, by scenario 16's
`PAUSE_PATH` line, when `PAUSE_SHAPE accepted` was printed:

- `PAUSE_PATH live`: deleted.
- `PAUSE_PATH synthetic_mcp`: replaced with

```markdown
- **A paused MCP-connector turn after a crash is checked on a rebuilt history only.** Normandy
  declares no server tools, so a paused turn (`pause_turn`) comes only from the MCP connector
  (`mcp_servers:`). If `Turn.Server` stops while such a turn is paused and the session then takes new
  input, the paused assistant turn is followed by the user message. The 2.0 live run checked that the API
  accepts that shape on a paused turn rebuilt from a real response (an `mcp_tool_use` without its result),
  not on a live `pause_turn`.
```

- `PAUSE_PATH synthetic_web_search`: replaced with the same bullet, its last sentence ending "…rebuilt
  from a real `web_search` response through Claudio (a `server_tool_use` without its result), not on an
  MCP-connector turn or a live `pause_turn`."

When `PAUSE_SHAPE accepted` was not printed, leave the bullet as it is; Step 5 already took it to Q.
Scenario 15 and part B passing need no Known-limits text.

- [ ] **Step 7: Rerun failed scenarios only**

```bash
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix e2e <failed names> 2>&1 | tee -a investigations/pre-2.0-audit/e2e-2.0.log
```

Write the failed names (from Step 3's summary) in place of `<failed names>`. Within the $1 Q approved
(Step 2). Expected: every rerun scenario PASS; a second failure of the same scenario goes back to Step 5
as a defect or to Q, never a third run.

- [ ] **Step 8: Gate and commit**

```bash
mix format
mix test test/docs/migrating_test.exs
mix precommit 2>&1 | tee /tmp/w7-7.6b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.6b.log
mix docs --warnings-as-errors
git add investigations/pre-2.0-audit/e2e-2.0.log
git add MIGRATING-2.0.md      # only when Step 6 changed it
git commit -m "docs(e2e): live 2.0 run, measured cost and probe results"
```

Commit body: the final summary table, the `usage (known)` line, the `PAUSE_PATH`, `PAUSE_SHAPE` and
`CITATIONS_REPLAY` lines, and one line per Step 5 classification (scenario, class, fix commit or "model
wording").

---

### Task 7.4b: CHANGELOG — the 2.0 notes after the first separator (REL-5, decision 27 C6)

Runs after Task 7.6b, so the notes include the live run's fixes. Today `CHANGELOG.md:8-62` is an
`## [Unreleased]` block (telemetry only) above the first `- - -` (`:64`). cog inserts its generated
section at the first `- - -`, so that block would stay stranded above `## [v2.0.0]`. Rehearsed (inventory
§3.2): with the hand-written block placed after a new first `- - -`, `cog bump --auto` writes
`- - -` / `## [v2.0.0]` (generated) / `- - -` / `## Normandy 2.0 release notes` / … / `- - -` /
`## [v1.3.0]`, one `## [v2.0.0]` heading, and later releases still go on top. Hexdocs 2.0.0 ships these
notes because `mix hex.publish` runs after the bump.

**Files:**
- Modify: `CHANGELOG.md`
- Test: create `test/docs/changelog_layout_test.exs`

**Interfaces:**
- Consumes: MIGRATING-2.0.md as Tasks 7.1b, 7.1c and 7.6b left it; the fix commits of Task 7.6b.
- Produces: `## Normandy 2.0 release notes` directly after the first `- - -`. Task 7.7's PR body links it.

- [ ] **Step 1: Write the failing test**

Create `test/docs/changelog_layout_test.exs`:

```elixir
defmodule Normandy.Docs.ChangelogLayoutTest do
  @moduledoc """
  Task 7.4b (REL-5, decision 27 C6): cog inserts each release's section at the first
  `- - -` line, so the hand-written 2.0 notes sit after a separator with nothing but the
  preamble and cog's own `## [vX.Y.Z]` sections above them (none before the 2.0 release).
  """
  use ExUnit.Case, async: true

  @lines Path.expand("../../CHANGELOG.md", __DIR__) |> File.read!() |> String.split("\n")

  test "no Unreleased block remains" do
    refute Enum.any?(@lines, &String.starts_with?(&1, "## [Unreleased]"))
  end

  test "the 2.0 notes follow a separator, below only cog's release sections" do
    separator = Enum.find_index(@lines, &(&1 == "- - -"))
    notes = Enum.find_index(@lines, &(&1 == "## Normandy 2.0 release notes"))
    v1_3 = Enum.find_index(@lines, &String.starts_with?(&1, "## [v1.3.0]"))
    # cog bump puts its `- - -` / `## [vX.Y.Z]` section above the notes (and a blank line
    # before them), so the test holds before and after every release.
    above = @lines |> Enum.take(notes) |> Enum.reject(&(&1 == ""))

    assert List.last(above) == "- - -"
    assert notes < v1_3
    assert Enum.at(@lines, v1_3 - 1) == "- - -"
    refute @lines |> Enum.take(separator) |> Enum.any?(&String.starts_with?(&1, "## "))

    assert above
           |> Enum.filter(&String.starts_with?(&1, "## "))
           |> Enum.all?(&(&1 =~ ~r/^## \[v\d/))
  end

  test "the notes send upgraders to MIGRATING-2.0.md" do
    notes = Enum.find_index(@lines, &(&1 == "## Normandy 2.0 release notes"))
    v1_3 = Enum.find_index(@lines, &String.starts_with?(&1, "## [v1.3.0]"))
    assert @lines |> Enum.slice(notes..v1_3) |> Enum.join("\n") =~ "MIGRATING-2.0.md"
  end
end
```

- [ ] **Step 2: Run it and see it fail**

```bash
mix format
mix test test/docs/changelog_layout_test.exs
```

Expected: `3 tests, 3 failures` (the `[Unreleased]` heading exists; `notes` is `nil`, so `Enum.take/2`
raises `FunctionClauseError` in the second and building `notes..v1_3` raises `ArgumentError` in the third).
The second test does not pin `notes == separator + 1`: after `cog bump` on `main` the first `- - -` is
cog's, above `## [v2.0.0]`, and a blank line precedes the notes (Step 5 shows it), so that form would fail
CI on `main` right after the release; this form holds before and after.

- [ ] **Step 3: Write the notes**

In `CHANGELOG.md`, replace the line `## [Unreleased]` with these lines (the existing `### Added`,
`### Changed` and `### Fixed` headings and bullets that follow it stay where they are):

```markdown
- - -
## Normandy 2.0 release notes

Normandy 2.0 moves to Claudio 0.7.1 and works with the current Claude models (Opus 4.7 and later reject
sampling parameters and budgeted thinking). It is a breaking release: **read `MIGRATING-2.0.md` before
upgrading**; its "Who is affected" table at the top sends you to the sections that concern you, and
"Known limits of 2.0" at the end lists what 2.0 does not do yet.

### Highlights

- **One model protocol.** `Normandy.Agents.Model` is `converse/3` and `stream/3` over
  `%Normandy.LLM.Request{}`; failures are `%Normandy.LLMError{}` and `run/3` returns
  `{:ok, config, output}` or `{:error, exception}` (`run!/3` raises). `stream/3` returns the output schema
  like `run/3`.
- **Durable sessions.** `Turn.Session` and `Turn.Server` persist every turn boundary to a
  `SessionStore` (InMemory, ETS, Mnesia, Postgres, Redis), resume after a crash or on another node
  (`SessionRegistry` Native, Horde or Redis; `ResumeReaper`), park tool calls for approval, and keep a
  turn whose final save failed until the store recovers.
- **Tools.** One `Normandy.Tool` behaviour (`use Normandy.Tool, name:, description:, input:`), a
  `Toolset`, validated tool input, per-tool timeouts and result caps; MCP and A2A tools are prefixed.
- **Lifecycle hooks** (`Normandy.Behaviours.Hooks`), **long-term memory** (`Normandy.Tools.Memory` over a
  `MemoryStore`), **policy, budget and guardrails** checked on every path.
- **Structured outputs on tool loops.** A non-chat output schema is sent as `output_config.format` beside
  the tools; a cut-off, refused or blank answer is an error on every path.
- **Prompt caching on by default**, the conversation built in linear time, assistant turns (thinking,
  citations, server and MCP tool blocks) replayed exactly as the API returned them.
- **Every option is validated** (NimbleOptions; an unknown option raises naming it).
- **Observability.** The `Normandy.Telemetry` catalogue documents every event; run, LLM-call, request,
  tool, approval and workflow spans carry OpenTelemetry GenAI attributes and run totals.
- **Testing support.** `Normandy.Test.FakeClient` and the store and registry contracts
  (`Normandy.Test.SessionStoreContract`, `MemoryStoreContract`, `SessionRegistryContract`) ship in the
  package; `docs/guides/testing.md` shows them.
```

The existing `### Added` heading and its telemetry bullets follow this block unchanged. Add this bullet
as the first one under the existing `### Changed`:

```markdown
- Breaking changes are listed, with what to do, in `MIGRATING-2.0.md` (sections 1–47). The bullets below
  are the telemetry and rolling-deploy changes; MIGRATING has the rest.
```

Before the existing `### Fixed` bullets, add these as the first under `### Fixed`:

```markdown
- `Turn.Server` no longer leaves a finished session in the in-flight index when the store fails at the
  turn's last save: it keeps the result, retries the save, refuses new turns with `:persist_failed`
  until it lands, and a resume whose answer is already stored makes no model call.
- A tool result is encoded once on every path (it was encoded up to five times).
- Normandy compiles on Elixir 1.15 and 1.16 again (`%Duration{}` is matched only where it exists).
```

and then one bullet per fix commit Task 7.6b made, in commit order, each the commit subject's
description rewritten as a sentence (`fix(turn): x does y` → `- x does y.`). If Task 7.6b made none, add
nothing more.

Check the separator count: the block now starts with `- - -` and the existing `- - -` before
`## [v1.3.0]` stays.

- [ ] **Step 4: Run the test**

```bash
mix format
mix test test/docs/changelog_layout_test.exs
mix docs --warnings-as-errors
```

Expected: `3 tests, 0 failures`; docs exit 0 (CHANGELOG.md is in `skip_undefined_reference_warnings_on`).

- [ ] **Step 5: Rehearse the release on a scratch clone (nothing outside it changes)**

```bash
S=$(mktemp -d)
git clone -q /Users/antonio/personal/normandy "$S/r" && cd "$S/r"
git checkout -q main
git merge --squash -q origin/feat/claudio-0.7-migration 2>/dev/null || git merge --squash -q feat/claudio-0.7-migration
git commit -q -m "feat!: Normandy 2.0 (#99)"
PATH="$HOME/.local/bin:$PATH" cog bump --auto
grep -c '^## \[v2\.0\.0\]' CHANGELOG.md
grep -c '^## \[Unreleased\]' CHANGELOG.md
grep -n '^## \|^- - -$' CHANGELOG.md | head -6
grep -n '@version' mix.exs
cd /Users/antonio/personal/normandy
```

The clone has the local branch as `origin/feat/claudio-0.7-migration` (a clone of a local repository
names its branches `origin/*`); the second form of the merge is a fallback for a detached setup. Expected:
`cog bump` prints `Bumped version: v1.3.0 -> v2.0.0`; counts `1` and `0`; the first `## `/`- - -` lines are `- - -`,
`## [v2.0.0]…`, `- - -`, `## Normandy 2.0 release notes` (a blank line before the notes heading); `@version "2.0.0"`. Leave the scratch directory.

- [ ] **Step 6: Gate and commit**

```bash
mix precommit 2>&1 | tee /tmp/w7-7.4b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.4b.log
git add CHANGELOG.md
git add test/docs/changelog_layout_test.exs
git commit -m "docs(changelog): Normandy 2.0 release notes after the first separator"
```

Expected: ` 0 failures`, exit 0. No tagged suite.

---

### Task 7.8: Wave gate (controller)

**Files:**
- Modify: `investigations/pre-2.0-audit/decisions.md` (Wave 7 Progress bullet)
- Proposed (Q approves before any edit): `CLAUDE.md` text collected from the task reports and Appendix B

- [ ] **Step 1: Full gate on the final commit**

```bash
caffeinate -i -s mix precommit 2>&1 | tee /tmp/w7-gate-precommit.log; echo "exit=${pipestatus[1]}"
grep -E " [0-9]+ failures" /tmp/w7-gate-precommit.log
mix docs --warnings-as-errors 2>&1 | tee /tmp/w7-gate-docs.log; echo "exit=${pipestatus[1]}"
```

Expected: ` 0 failures`, both exits 0.

- [ ] **Step 2: Tagged suites**

```bash
docker start normandy-test-pg
caffeinate -i -s mix test.redis 2>&1 | tee /tmp/w7-gate-redis.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 caffeinate -i -s mix test.postgres 2>&1 | tee /tmp/w7-gate-pg.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tee /tmp/w7-gate-dist1.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tee /tmp/w7-gate-dist2.log
docker stop normandy-test-pg
```

Expected: ` 0 failures` in each log. A failure is reported to Q with the raw output before any fix (RULE 0).

- [ ] **Step 3: Package and API checks**

```bash
mix hex.build --unpack -o /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-pkg
ls -R /private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/w7-pkg | grep -E "priv/test_repo|investigations|tools/|examples" ; echo "grep-exit=$?"
tools/api_diff/run.sh main; echo "exit=$?"
```

Expected: hex.build exit 0, `MIGRATING-2.0.md` present in the package, grep-exit 1 (none of those paths), `api_diff` `## unmatched (0)` and exit 0.

- [ ] **Step 4: Records**

Append a "Wave 7" Progress bullet to `decisions.md` (commits, reviews, gate numbers, deferred items, the e2e log path and cost), update the memory file `pre-2-0-audit-2026-10.md`, and present the collected CLAUDE.md proposals to Q one by one. Commit `decisions.md` alone: `docs(investigations): Wave 7 done`.

---

### Task 7.7: The release PR text (decision 3, REL-3, decision 27 F2, R5; Q pushes, opens and merges)

Runs after Task 7.8 (the controller's gate). Writes the PR title, the PR body, the squash commit body and
Q's merge steps to one file. The repository squashes with `squash_merge_commit_message: COMMIT_MESSAGES`
(every branch commit message as the body, AI trailers of `6a5f5d0` and `8311a3d` included, and cog would
read them as authors), and "Rebase and merge" stays enabled (F2b): Q picks "Squash and merge" and
replaces the body. Rehearsed (inventory 7.5 "Version probes"): title `feat!: Normandy 2.0` with a short
body gives `v2.0.0`; `feat:` would give `v1.4.0`, so the `!` and the `BREAKING CHANGE` footer are both
kept.

**Files:**
- Create: `investigations/pre-2.0-audit/release-pr.md`

**Interfaces:**
- Consumes: CHANGELOG.md (Task 7.4b), MIGRATING-2.0.md, `investigations/pre-2.0-audit/e2e-2.0.log`
  (Task 7.6b), `.github/workflows/ci.yml` job names.
- Produces: the file Q reads at merge time.

- [ ] **Step 1: Write `investigations/pre-2.0-audit/release-pr.md`**

````markdown
# Normandy 2.0 release PR

## Title

```
feat!: Normandy 2.0
```

## PR body

```
Normandy 2.0: Claudio 0.7.1, durable sessions, one tool contract, lifecycle hooks, long-term
memory, structured outputs on tool loops, a telemetry catalogue, validated options everywhere,
and shipped test helpers.

This is a breaking release. MIGRATING-2.0.md lists every breaking change and what to do, with a
"Who is affected" table at the top and the known limits of 2.0 at the end. The release notes
are in CHANGELOG.md ("Normandy 2.0 release notes").

How it was checked
- mix precommit (compile with warnings as errors, unused deps, format, credo --strict, dialyzer,
  tests) and mix docs --warnings-as-errors on the branch tip
- the Redis, Postgres and distributed suites (mix test.redis, mix test.postgres,
  mix test --only distributed --include postgres)
- one live run of the 16 e2e scenarios: investigations/pre-2.0-audit/e2e-2.0.log
- tools/api_diff/run.sh main: every public API item removed or changed since 1.3.0 is named in
  MIGRATING-2.0.md
- the release rehearsed on a scratch clone: cog bump gives v2.0.0 and one CHANGELOG section

Merge with "Squash and merge" and the squash body in investigations/pre-2.0-audit/release-pr.md.
```

## Squash commit body

Paste this as the whole commit message body (GitHub keeps the title above it):

```
Normandy 2.0: Claudio 0.7.1, durable sessions, one tool contract, lifecycle hooks,
long-term memory, structured outputs on tool loops, a telemetry catalogue, validated
options everywhere, and shipped test helpers.

To upgrade from 1.x, read MIGRATING-2.0.md; the release notes are in CHANGELOG.md.

BREAKING CHANGE: see MIGRATING-2.0.md
```

## Merge steps (Q)

1. Push the branch (a fast-forward of `origin/feat/claudio-0.7-migration`):
   `git push origin feat/claudio-0.7-migration`
2. Open the PR against `main`:
   `gh pr create --base main --head feat/claudio-0.7-migration --title "feat!: Normandy 2.0" --body-file <the PR body above, saved to a file>`
3. Wait for CI on the PR: `Test` on 1.15/26, 1.16/26, 1.17/26, 1.17/27, 1.18/27, 1.19/28; `Code Quality`;
   `Test with unlocked dependencies`; `Postgres session store tests`; the Redis and Distributed jobs;
   `All Checks Passed`; and the PR-title check. Integration Tests run only after the merge.
4. Merge: choose **Squash and merge** (not "Rebase and merge", which would put every branch commit on
   `main`). Keep the title `feat!: Normandy 2.0 (#<n>)`. Replace the whole body GitHub pre-fills with the
   squash commit body above. Confirm.
5. After the merge, watch the CI run on `main` (Integration Tests on 1.15/26 included) and then the
   Release workflow. Expected: commit `chore(version): v2.0.0`, tag `v2.0.0`, `mix hex.info normandy`
   lists `2.0.0`, a GitHub release `v2.0.0`, hexdocs 2.0.0 with the release notes.
6. If Release publishes to Hex but fails pushing the bump commit or the tag, push them by hand
   (`release.yml` explains why); do not rerun the workflow.
````

- [ ] **Step 2: Check the squash message**

```bash
f=investigations/pre-2.0-audit/release-pr.md
body=$(awk '/^## Squash commit body/{s=1} s&&/^```$/{n++; next} s&&n==1' "$f")
printf '%s\n' "$body"
PATH="$HOME/.local/bin:$PATH" cog verify "$(printf 'feat!: Normandy 2.0 (#99)\n\n%s\n' "$body")"; echo "verify=$?"
printf '%s\n' "$body" | grep -ciE "co-authored-by|claude-session|generated with"   # expected: 0
```

Expected: the body prints (7 lines); `verify=0` (cog reads it as a breaking `feat`); the grep prints `0`.

Then rehearse the version with this exact message on a scratch clone (as in Task 7.4b Step 5, with
`git commit -q -F <file holding the title line, a blank line and the body>` instead of the one-line
commit): `cog bump --auto --dry-run | tail -n1` prints `v2.0.0`.

- [ ] **Step 3: Gate and commit**

```bash
mix precommit 2>&1 | tee /tmp/w7-7.7.log; grep -E " [0-9]+ failures|Total errors" /tmp/w7-7.7.log
mix docs --warnings-as-errors
git add investigations/pre-2.0-audit/release-pr.md
git commit -m "docs(investigations): release PR text and merge steps for Normandy 2.0"
```

Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 4: Q: push, open, merge** — **Q:** follows "Merge steps (Q)" in the file. The controller
  never pushes.

---

## Appendix A — questions for Q (from the section writers)

1. **A3 reaches native structured outputs.** With `chat_message: nil` blank, an answer under native structured outputs whose model omits the optional `chat_message` is `{:error, %LLMError{type: :invalid_output}}`. **Recommend accept** (an omitted answer is blank; the retry/fallback already handles `:invalid_output`). Alternative: also make `chat_message` required in the default output schema so structured outputs cannot omit it — that changes wire bytes (the schema) and needs a MIGRATING line.
   **Q (decision 28):** accepted. An omitted `chat_message` under native structured outputs is `:invalid_output`; no schema change.
2. **E3's missing-model error removes a documented 2.0 path.** Today an `agent` block with no `model` compiles and `MyAgent.new(client: c, model: "m")` serves it (`dsl/agent.ex:459-464`, MIGRATING §21). My E3 question described it as "fails only at runtime", which undersold it. **Recommend: keep that path** — Task 7.3h-i does only the `system_prompt`-conflict half; §21 stays. Alternative: as written (compile error without `model`).
   **Q (decision 28):** accepted: keep the path. Task 7.3h-i does only the `system_prompt`-conflict compile error; the runtime `requires :model` check, its tests and §21 stay (H12 updated).
3. **Hiding `Hooks.Runner`** drops its documented "supported way to test a hook"; 7.2a moves the guide to an agent-level test (verified). **Recommend hide** (C1). Alternative: keep Runner public with a narrowed moduledoc.
   **Q (decision 28):** accepted. `Hooks.Runner` is hidden; hooks are tested through `BaseAgent.run/3`.
4. **`examples/` leftovers.** After `git rm -r` of both apps, untracked build output (`_build`, `deps`) remains under them; clearing it is an `rm -rf` of those two directories — **your command** (or approve mine at that step). `marketing/demo-1.0/agent-horde-script.md` points at the deleted app: **recommend keep** (a 1.0 demo script) — or delete it.
   **Q (decision 28):** (a) accepted: after `git rm -r` the implementer reports the leftovers (`git status --short --ignored examples/`) and Q runs `! rm -rf examples/customer_support_app examples/agent_horde` (Task 7.3h-v Steps 4-5). (b) **not as recommended:** the script gets a one-line note that it was written for Normandy 1.0 and the app is gone in 2.0 (Task 7.3h-v Step 8).
5. **Scenario 16 if no live `pause_turn` can be provoked.** The rebuilt paused-turn shape checks "does the API accept the history", not a live pause. **Recommend:** accept the rebuilt shape and word the Known-limits bullet exactly as checked (7.6b Step 6). 7.6b's spend approval asks for the first run (~$1.92-2.24) plus up to $1 of reruns in one go.
   **Q (decision 28):** accepted: the rebuilt shape counts if no live `pause_turn` occurs; the spend for 7.6b is asked at the step.

6. **A Horde flake found by the preflight.** `test/.../session_delete_test.exs:170` "through the Horde supervisor too" failed once (seed 606572, not reproducible with the same seed or 3 file reruns): `Horde.DynamicSupervisorImpl.handle_info/2` raised `FunctionClauseError` on `{:EXIT, pid, :normal}`. Theory (unverified): a process linked to the Horde supervisor but not its child — likely on Wave 6's `stop_server/2` path for `Session.delete/1` — exits `:normal`, and Horde 0.10 has no clause for it. **Recommend:** a new Task 7.0e before 7.2a: reproduce deterministically (link a non-child process to the supervisor and exit it `:normal`), then fix our side so no non-child is linked to the Horde supervisor; if it is Horde's own bug, report it to you with the evidence before any workaround.
   **Q (decision 28):** accepted: new Task 7.0e. Its investigation proved the theory wrong: no Normandy process is linked to the impl. ExUnit's capture-log handler (`ExUnit.CaptureServer.log/2`) links a `Task` to `Horde.DynamicSupervisorImpl` while it logs `:info` in `init/1` (`dynamic_supervisor_impl.ex:44`), before it traps exits (`:46`); a task that exits `:normal` afterwards hits the missing `{:EXIT, _, _}` clause (`:355-398`). Normandy avoids it in its test environment (`test_helper.exs` module level, Task 7.0e); production is unaffected. See item 7.

7. **Report the Horde init-order issue upstream? (from Task 7.0e)** Horde 0.10's `DynamicSupervisorImpl` logs before it traps exits and has no catch-all `handle_info/2`, so any `:logger` handler that links a process to the caller (ExUnit's capture handler does) can crash it. Task 7.0e works around it in Normandy's test environment only; users who capture logs in their own suites while starting `Turn.Supervisor.Horde` can hit the same rare flake. Filing an issue (or a PR moving `Process.flag(:trap_exit, true)` above the log line) is outward-facing, so it is yours. **Recommend:** file it after 2.0; no Normandy change either way. **Q (decision 28, A7):** accept the test-only fix; no upstream report.

## Appendix B — section writers' notes (verbatim)

### Notes: 7.0

**Could not verify.**
- The Postgres suite and `mix test --only distributed --include postgres`: `normandy-test-pg`
  was stopped and the brief does not let a writer start containers. The two
  `TerminalSaveCases` tests in `postgres_contract_test.exs` were not run. They run `Turn.Server`
  processes against the shared sandbox connection (the module sets `{:shared, self()}`), as the
  distributed handoff tests do. ETS, Mnesia, InMemory and Redis ran green.
- Elixir 1.15/1.16 end-to-end: only the guard shapes were compiled on those versions (Task 7.0d
  probe); Hex cannot be installed in the local containers. Task 7.7's CI run is the check.

**Risks.**
1. A3's reach (Header conflicts 5): a user with a custom output schema whose `chat_message` is
   optional, on native structured outputs, now gets `:invalid_output` when the model leaves it
   out. Consistent with decision 22 (blank is an error); the MIGRATING bullet says so. 25
   failing tests in 8 files change with the two doubles.
2. `{:next_event, {:call, from}, msg}` re-inserts the caller's request after a retried save
   lands; the scratch run covers it (refusal test, then a successful `run/2`).
3. The timer test waits on the real 1_000 ms first retry (`wait_until` up to 3 s): deterministic,
   about 1 s of suite time. The backoff doubling is not tested (it would take 3 s+).
4. `~> 0.10` admits Horde 0.11+, which nobody has checked against `Via`'s ordering assumption
   (decision 27 B2 chose it over `~> 0.10.0`).
5. The Workflow DSL change (`__after_condition__/3`) is in the generated code of every
   workflow; `test/dsl` (109 tests) covers `when_result`'s three outcomes.

**Proposed CLAUDE.md text (verbatim, for Task 7.8).** In the `Normandy.Agents.Turn.Server`
bullet, after the `on_approval_timeout` sub-bullet, add:

```
  - A terminal turn-state save the store refuses is logged by tag (no event), kept in `Data.unsaved_terminal` and saved again on a `{:timeout, :retry_terminal_save}` timer (1 s doubling to 30 s), before the next turn and before passivating; meanwhile `run/2` replies `:persist_failed` `{:terminal_unsaved, reason}` and passivation waits. An eager resume of a `:steering` turn whose answer is the last stored message (`Turn.answered?/1`) saves it `:stopped` with no model call
```

In the `run/3` bullet of `Normandy.Agents.BaseAgent`, "a blank final answer is `{:error,
%LLMError{type: :invalid_output}}` on every path" stays true (a `nil` answer is now blank); no
edit needed. In "Dependencies", no Horde line exists; none proposed.

**Questions I would have asked Q (answers assumed).**
- Should the guard also cover `:awaiting_approval`? Assumed no: a parked turn has no answer
  yet; its history ends in the unanswered `tool_use`.
- Should a refused turn request also fire `on_turn_end`? Assumed yes, `{:error, exception}` with
  no turn id, the same as a crashed admission (`server.ex:855-860`), so hook-based accounting
  sees every refused `run/2`.

### Notes: 7.2 / 7.3a, f, g

- **Verified in a scratch worktree:** every code block of 7.2a, 7.2b, 7.3a, 7.3g1 and 7.3g2,
  plus 7.3f1's test (with the full 87-line list: passes; documenting 3 entries trips the
  stale-entry assertion as intended). `mix precommit` → ` 0 failures`, Credo clean, Dialyzer
  passed; `mix docs --warnings-as-errors` → exit 0; the sidebar has 147 modules in 21 groups
  and none ungrouped. **Not verified:** the ~80 7.3f docs I did not write out (only their
  enumeration and the worked examples), and 7.3g2's `mix hex.build --unpack` step (not run).
- **Cross-writer dependency:** 7.2a creates `## 45. Testing support and docs`. The 7.3b–7.3e
  writer must append to it, not create it. 7.3b and 7.3d must add their `Normandy.Test.*`
  modules to `Testing: [...]` in `mix.exs` (the groups test fails otherwise) and document
  every function (7.3f's enumeration should still print 87 at its start).
- **Risk:** the 7.3f1 entry count depends on 7.3b–e documenting everything they add, and on
  7.0a–d adding no undocumented public function. Step "Enumeration command" makes the
  implementer stop and report a mismatch rather than guess.
- **Runner hiding is a judgement Q may want to see** (Header conflict 1). Hiding
  `Hooks.Runner` drops its documented "supported way to test a hook". I assumed C1 stands and
  moved the guide to the agent-level test. The alternative is to keep `Hooks.Runner` public
  with a narrowed moduledoc. That changes one line of the `@hidden` list, the MIGRATING bullet
  and the groups (Hooks += Runner).
- **DX-32 scope:** I converted `validation_middleware.ex` too, though it is hidden after 7.2a,
  so that the test's rule ("`iex>` only in doctested files") has no exception.
- **Proposed CLAUDE.md text** (Notes section, new bullet, verbatim):
  `- Docs tests in test/docs/: docs_groups_test.exs (every lib/ module with docs is in exactly one mix.exs groups_for_modules group; internals listed there are @moduledoc false), doc_coverage_test.exs (every function, macro and callback of a visible module has @doc), devex_docs_test.exs (iex> only in doctested files; one model id, claude-opus-5-5, in README and guides). A new public module needs a group; a new internal one needs @moduledoc false.`
  And in "Lifecycle Hooks", the `Normandy.Hooks.Runner` line stays true but could add
  "(internal, `@moduledoc false`)".
- **Question I would have asked Q:** should the README quickstart show the error branch
  (done, per header: "shows the error tuple") with `IO.puts`, or pattern-match `{:ok, agent, response} =` and mention errors in a comment? I assumed the `case` form; the README test pins both branches.

### Notes: 7.3b-e, 7.3h

### 7.3b, 7.3c, 7.3e

- **What was verified.** All three were applied in one scratch worktree at `9131274`, which
  is now removed. Results:
  - `mix test --warnings-as-errors`: 74 doctests, 31 properties, 3671 tests, 0 failures.
  - `mix credo --strict`: no issues.
  - `MIX_ENV=test mix dialyzer`: passed, after two spec fixes that are already in the text
    (`next!/2`'s return type, `bad!/2 :: no_return()`).
  - `mix docs --warnings-as-errors`: exit 0.
  - The red states quoted in each Step 2 were observed.
  - Negative controls failed as they should: a `test/support` module named
    `Normandy.Test.FakeClient` failed the name-clash test, and a wrong expected answer in the
    guide failed the guide test.
- **Not verified.**
  - **The guide's contract example against Task 7.3d's real module.** In scratch, a shim
    named `Normandy.Test.SessionStoreContract` delegated to today's `test/support` contract.
    The guide test compares the example's test count with a `ContractReference` module using
    the same contract, so it holds whatever the contract's count is.
  - **Task 7.2b's groups test and Task 7.3a's doc-coverage test.** Neither exists yet.
    `Code.fetch_docs/1` shows the `Model` impl module as `:hidden` and
    `ScriptExhaustedError`'s `exception/1` and `message/1` as `:hidden`, and every public
    `FakeClient` function has a `@doc`.
- **Size.** 7.3b is about 900 lines (module ~470 with docs, test ~380). I kept it as one
  task because the module and its tests are reviewed together. It could split at the
  stream path (`events/3`, `cut_stream/2` and the `stream/3` describe block) if the
  controller wants under 400.
- **Behaviour worth knowing.**
  - With `retry:` configured, BaseAgent retries a raised `ScriptExhaustedError`. The default
    `retry_if` retries `{:exception, _, _}`, `base_agent.ex:381`. Each retry takes a request
    index; this is pinned by a test and documented.
  - `AgentProcess.run/2` returns the bare `chat_message` string (`{:ok, "..."}`), not the
    output struct. Observed and asserted as is; it is not a FakeClient matter.
- **Risk.** The ETS table behind `requests/1` belongs to the process that called `new/2`. A
  client built in `setup_all`, or in a task that exits, loses its table, and the next
  request raises `ArgumentError` from `:ets.insert/2`. The moduledoc says so. An `:heir` or
  a supervised owner would remove the limit but adds a process; I did not add one.
- **Left as is.** `docs/superpowers/plans/2026-10-03-agent-persistent-memory.md` and
  `2026-10-03-agent-hooks.md` still name the deleted support clients. They are historical
  plans, like `investigations/`.
- **Proposed CLAUDE.md text (verbatim, for Task 7.8):**
  - In `## Notes`, after the `Normandy.Test.OwnLog.capture/2` bullet, add:
    "- `Normandy.Test.FakeClient` (shipped in `lib/normandy/test/`) is the scripted model client for tests: `new([{:text, t | [chunks]} | {:structured, map} | {:tool_calls, [{name, input} | %ToolCall{}]} | {:error, %LLMError{}} | fun], options: %{})`, item options `:stop_reason`, `:usage`, `:stream_error_after`; `requests/1`, `remaining/1`; a request past the script raises `ScriptExhaustedError`. Use it instead of a new inline `defimpl Normandy.Agents.Model`. `test/support` never defines a module name `lib/` ships (`test/normandy/test/shipped_names_test.exs`)."
  - In `## Notes`, add:
    "- `docs/guides/testing.md` and `docs/guides/hooks.md` are guide-tested (`test/docs/testing_guide_test.exs`, `test/hooks/guide_examples_test.exs`): an example module change needs the test's counts updated."
- **Questions I would have asked Q, with the answers I assumed.**
  - Should `FakeClient` also send each request to the owner as a message? Assumed no:
    `requests/1` is the one capture mechanism.
  - Should the 40 inline `defimpl`s and `StubClient` move to `FakeClient` now? Assumed no,
    per D2 (only the three scripted clients).

### 7.3d

- **What was verified.** I ran this exact change in a scratch worktree at `9131274`. Taken
  before Tasks 7.2a/7.2b/7.3b, so with no "Testing" group and no `lib/normandy/test/` dir.
  Results:
  - `mix test`: 3700 tests, 0 failures.
  - `contracts_test.exs`: 61 tests, 0 failures (the unknown-option test there used `=~`
    rather than the exact `assert_raise` above; the exact text
    `...: unknown option :store; supported: :impl, :new, :stored_entry_ids` and
    `...: :impl, :new` came from the same `Options.validate!/3` probe).
  - `mix test.redis` on the three Redis contract files: 58 tests, 0 failures.
  - `credo --strict` clean, `dialyzer` passed, `mix docs --warnings-as-errors` exit 0.
  - **Not run:** Postgres (it needs `docker start`) and `--only distributed`.
- **Risk: test counts.** The `16`/`33` counts in `contracts_test.exs` change if an earlier
  Wave 7 task adds a contract test (7.0b's H10 store tests might). The implementer
  recounts with the greps in Step 1.
- **Risk: `mix test test/docs` in Step 10** assumes Task 7.2b created
  `test/docs/docs_groups_test.exs`.
- **Proposed CLAUDE.md text (verbatim).**
  - Line 81: replace
    "Contract: `test/support/session_store_contract.ex` (`stored_entry_ids:` option)"
    with
    "Contract: `Normandy.Test.SessionStoreContract` (`lib/normandy/test/`; `impl:`, optional `new:` and `stored_entry_ids:` as `{m, f, a}`)".
  - Line 111: replace
    "shared contract in `test/support/memory_store_contract.ex`"
    with
    "shared contract `Normandy.Test.MemoryStoreContract` (`lib/normandy/test/`)".
  - Add to the `Notes` section: "- `Normandy.Test.SessionStoreContract`, `MemoryStoreContract`, `SessionRegistryContract` ship in `lib/normandy/test/`; `test/support` never defines a module name `lib/` ships."
- **Questions I would have asked Q.**
  - Should the contracts take an `async:` option? I assumed no (header conflict 2).
  - Should the `stored_entry_ids` error message be one line? NimbleOptions'
    `{:or, [:mfa, nil]}` produces a multi-line message, which the test matches with `=~`.
    I assumed the multi-line message is acceptable.

### 7.3h

- **Verified in a scratch worktree** (removed): all four code changes (7.3h-i to iv) applied
  together with the test changes above gave `mix test` 74 doctests, 31 properties, 3630 tests,
  0 failures at HEAD `9131274`; `mix format --check-formatted` and `mix credo --strict` clean;
  `mix compile --warnings-as-errors` clean. **Not run in scratch:** `mix dialyzer` (no PLT in the
  scratch copy) and `mix docs --warnings-as-errors`; the gate steps run both. The examples task
  (7.3h-v) was not applied in scratch; its test was written against the repository's current
  file list.
- **Compile-time error type:** `ArgumentError`, like the DSL's existing compile-time checks,
  verified on Elixir 1.19.5 only; the existing `Code.compile_string` + `assert_raise ArgumentError`
  tests in `test/dsl/` already pass on the 1.15-1.18 CI legs, which is the evidence it holds there.
- **Header conflicts** above: E3 removes "a model given to `new/1` serves an agent that declares
  none" (I assumed Q accepted it with E3's "code that compiles today stops compiling"); the
  DX-33 bullet edits MIGRATING §5 instead of §46.
  *[Decision 28 A2: superseded. Q keeps the "model given to `new/1`" path; Task 7.3h-i does only
  the `system_prompt`-conflict compile error.]*
- **`marketing/demo-1.0/agent-horde-script.md`** still tells the reader to `cd examples/agent_horde`.
  It is a 1.0 demo script; I left it. Question for Q: delete it, add a "1.0 only" line, or keep.
  Assumed: keep, unchanged. *[Decision 28 A4b: Q chose the one-line "written for 1.0" note; Task
  7.3h-v Step 8.]*
- **Ignored leftovers become untracked** after `git rm -r` (the apps' own `.gitignore` files go
  with them); the plan forbids adding them and gives Q the `rm -rf` (Step 9 of 7.3h-v). If Q
  prefers, the controller can instead add `examples/*/_build/`, `examples/*/deps/` to the root
  `.gitignore`; I did not, since the directories should simply go.
  *[Decision 28 A4a: the report and Q's `rm -rf` now come right after the `git rm -r` (Task 7.3h-v
  Steps 4-5); no `.gitignore` change.]*
- **The warning race:** two concurrent first `init/1` calls with `ModelCatalog.Static` may both
  log (check-then-put on `:persistent_term`). Accepted as documented; making it strictly once
  would need a lock for a deprecation notice.
- **Order assumptions:** 7.3a's `reset_memory/1` `@doc` (7.3h-iv anchors after `check_init!/1`,
  not before `reset_memory/1`); 7.3g's DX-32 may rewrite the three filters' `iex>` examples
  (7.3h-iii anchors on function heads); 7.3e creates `docs/guides/testing.md` and `test/docs/`
  exists from 7.2b/7.3a (7.3h-v's README test needs the guide). 7.3b creates `## 45.`; 7.3h-i
  inserts `## 46.` after it.
- **CLAUDE.md:** no line becomes false. Optional addition to the `Normandy.DSL.Agent` bullet
  (verbatim, for Q):
  `  - An `agent` block with `system_prompt` beside `background`/`steps`/`output_instructions` raises `ArgumentError` at compile time`
  *[Decision 28 A2: the "without `model`" clause is dropped from this proposal; that half is not built.]*

### Notes: 7.1, 7.4-7.7

**Verified while writing (scratch only):**
- `tools/api_diff` (7.1a code exactly as written above): its 4 tests pass; run on a `main` clone vs HEAD
  `9131274` with the `reviewed.txt` above it reports 12 / 50 / 33 / 20 and `## unmatched (10)`, the
  U1–U6 list; with draft bullets naming those items, `## unmatched (0)`.
- `test/docs/migrating_test.exs` against today's MIGRATING: 5 tests, the 3 expected failures.
- `.github/scripts/release-version.sh`: its 3 tests pass with a stub `cog`; with real cog 7.0.0 on the
  rehearsal clone tagged `v2.0.0` it prints `release=false`, exit 0.
- `NormandyTest.E2E.Prices` and its 4 tests pass; the runner edits applied to a copy of `runner.ex` pass
  all 21 runner tests (17 existing, updated where noted, + 4 new); the patched `e2e/support.exs` prints
  the usage line and a usage-bearing `E2E_RESULT` from synthetic telemetry events.
- The estimate figures ($1.92 / $2.24 for 01–16) are computed from the caps and the assumed tokens.

**Not verified (no network to these hosts, no live spend):**
- That the MCP connector ever returns `pause_turn` (documented for server tools; not seen documented for
  the connector), that DeepWiki or the remote Fetch server is reachable from Anthropic, and that Haiku 4.5
  calls 12 MCP tools sequentially. Scenario 16 handles all three by rebuilding the paused shape and
  printing which path ran; Task 7.6b words the Known-limits bullet from that.
- That the API accepts two consecutive user messages in scenario 16 part B (memory holds the document
  message, then `run/3` appends the instruction). The API documents merging consecutive same-role turns;
  if it rejects them, put the instruction into the document message's text block and pass a one-word
  `chat_message`.
- `Claudio.Messages.Request.add_web_search_tool/2` with `version: :basic` (doc read at `request.ex:1835`,
  not the full option list); Step 3 of 7.6a-ii only checks that the function exists.
- The exit shape a `Turn.Session.run/2` caller gets when its server is killed (`session.ex:250-261`
  propagates it): scenario 16 matches any `{:exited, _}`.
- Claudio's citations replay for `"citations": []`: I chose to omit the key for an empty list (the API's
  own text blocks omit it). If the API returned `"citations": []` on some block, preserved thinking could
  see a difference; scenario 16 part B checks a real cited turn only.

**Risks:**
- Scenario 15 depends on the model chaining two lookups (three calls in run 1). A model that answers
  after one lookup fails the "3 calls" invariant; Task 7.6b classifies that as model behaviour, not a
  Normandy defect, and the probe is then inconclusive rather than passed.
- §48's module list depends on what Task 7.2a hid and what `main` documented; Task 7.1b takes it from the
  tool's output, not from this plan.
- `e2e/support.exs` now prints `E2E_RESULT` on a failed invariant too, so a failed scenario shows its call
  count and cost in the summary instead of `?` (intended; `run_one/2` already handled a result with a
  non-zero exit).

**Proposed CLAUDE.md text (verbatim; Task 7.8 collects it):**
- In "Dependencies", replace the Claudio line with:
  `- **Claudio** - LLM client library (Hex package \`~> 0.7.1\`; requests are built with \`Request.add_messages/2\`)`
- In "Common Commands" → "Development", add:
  `- \`tools/api_diff/run.sh main\` - Public API removed or changed since \`main\` that MIGRATING-2.0.md does not name (exit 1 lists them); reviewed exceptions in \`tools/api_diff/reviewed.txt\``
- Also stale outside CLAUDE.md: the auto-memory note "E2E suite 2026-10" says 13 scenarios and a suite cap
  of 120; after 7.6a it is 16 scenarios, cap 150, `mix e2e --estimate`.

**Questions I would have asked Q (answer assumed):**
- Scenario 16 without a live pause: is the rebuilt shape enough to reword the known limit? Assumed yes,
  with the bullet saying exactly what was checked (Task 7.6b Step 6).
- Rerun budget in 7.6b: assumed up to $1 beyond the first run, asked in the same approval.
- A failing `cog` failing the Release job (7.4a) instead of skipping: assumed wanted (no silent fallback).
- Release PR body: assumed no AI attribution line, per Q's CLAUDE.md ("no AI attribution in commits or
  PRs"), which overrides the session's PR-attribution reminder.

