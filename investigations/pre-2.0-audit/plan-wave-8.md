# Wave 8: principles-audit fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Phase 1 lanes run in parallel, one implementer per lane in its own git worktree; tasks inside a lane run in order. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Land every principles-audit finding Q took (A1–A12, A13 doc, B1–B4, C, D; Q 2026-10-23: remove A11 and A12) on `feat/claudio-0.7-migration` before the 2.0 release.

**Architecture:** Eight file-disjoint lanes (Phase 1) run in parallel worktrees branched from BASE (the commit that adds this plan), each reviewed on its own; the controller merges them into the feature branch. Three findings that cross lane boundaries run after the merge (Phase 2). One docs task writes MIGRATING/CHANGELOG/api_diff and the full gate runs last (Phase 3).

**Tech Stack:** Elixir 1.20.4 / OTP 29, ExUnit, Credo, Dialyzer, Claudio `~> 0.7.1`.

**Spec:** `investigations/pre-2.0-audit/principles-audit/` — eight audit reports (`agents.md`, `behaviours.md`, `coordination.md`, `llm.md`, `components.md`, `tools.md`, `schema.md`, `core.md`) and `TRIAGE.md`. A finding is cited `<report>#<n>`; its Evidence and Fix lines are the requirement. Where a report offers options, this plan's **Ruling** picks one and binds.

## Global Constraints

- Offline only: prefix every mix command with `env -u ANTHROPIC_API_KEY -u API_KEY`. Never run `mix e2e`. No network calls.
- Add files individually (`git add <path>`); never `git add .`/`-A`. No `git stash`. No AI attribution in commits (no Co-Authored-By, no "Generated with").
- Conventional commit titles; one commit per finding or tight group of findings; the title names the behaviour, not the finding ID (put the ID in the body: `principles-audit: tools#4`).
- Gate before every commit: `env -u ANTHROPIC_API_KEY -u API_KEY MIX_TEST_PARTITION=<lane partition> mix precommit 2>&1 | tee <lane log>`; the exit status (`${pipestatus[1]}` in zsh) must be 0. Elixir 1.20 prints `Result: N passed`, not "0 failures".
- `mix format` is fine on lib/ and test/ (e2e/ is outside the formatter inputs); never format e2e files.
- Do NOT edit `MIGRATING-2.0.md`, `CHANGELOG.md`, `tools/api_diff/reviewed.txt` or `CLAUDE.md`. For every public-API change, write the proposed MIGRATING and CHANGELOG text in the lane report (Task P3.1 applies it). CLAUDE.md wording goes to the report as a proposal for Q.
- Credo complexity/nesting findings get an inline `# credo:disable-for-next-line`, never a threshold change; removing an existing disable because the code is now flat is the goal of the flat-code findings.
- A new public module needs a `groups_for_modules` entry in `mix.exs` and `@doc` on every function/callback (`test/docs/`); an internal one is `@moduledoc false`. `test/support` never defines a module name `lib/` ships.
- Tests first for every behaviour change (red, then green; paste both outputs in the report). Doc-only and pure-move refactors need the existing suite green, no new test.
- Never create or drop a database. Only lane L2 runs `mix test.postgres` / `mix test.redis` in Phase 1 (partition `_w54probe`, `POSTGRES_PORT=55432`; containers `normandy-test-pg`, `normandy-test-redis` are up).
- Implementers never dispatch subagents.
- A failure you cannot explain: stop, write the raw error, theory and proposal in the report, return BLOCKED. Do not paper over it.

## Review Focus

1. A template-backed `Turn.Session` with the credential slot left unset → refused at `Turn.Session.new/1` with an `ArgumentError` naming `:credential`, never a server stuck in `:unavailable` (L1-T1 test).
2. A Redis store/registry `new/1` called without `:namespace`/`:url` → `ArgumentError` from `Normandy.Options` naming the key, before any connection (L2-T1 test).
3. Model output of 240 KB with an unclosed `{` → `JsonDeserializer` returns within 1 s (L4-T1 test, a time bound, not a benchmark).
4. A breaker child crash → `AgentProcess.ScopedRegistry` keeps its registrations (L8-T1 test).
5. `WindowManager` `:summarize` with no client → `ArgumentError` naming `:client`, not a silent `:oldest_first` (L5-T1 test).

---

## Phase 0 — controller setup (no subagent)

- [ ] For each lane `L1`..`L8`: `git worktree add ../normandy-wt/L<n> -b audit/L<n> BASE`, then `cp -cR _build deps ../normandy-wt/L<n>/` (APFS clone; keeps PLTs and compiled deps).
- [ ] Ledger `.superpowers/sdd/plan-wave-8/progress.md`, first line `# SDD ledger — plan: investigations/pre-2.0-audit/plan-wave-8.md`.
- [ ] Each lane's partition: `MIX_TEST_PARTITION=_L<n>`; log `.superpowers/sdd/plan-wave-8/L<n>-precommit.log` (absolute path to the main checkout).

Lane file ownership (a lane edits only its own files, plus tests and guides that mention what it changes; a guide shared by two lanes is resolved at merge):

| Lane | Owns | Model |
|---|---|---|
| L1 | `lib/normandy/agents/**`, `lib/normandy/hooks/**`, `lib/normandy/watched_worker.ex`, `lib/normandy/behaviours/config.ex`, `lib/normandy/behaviours/credential_provider.ex` | opus |
| L2 | `lib/normandy/behaviours/**` except the two files above, `lib/normandy/cluster.ex`, `lib/normandy/test/*_contract.ex`, `config/test.exs` | sonnet |
| L3 | `lib/normandy/coordination/**`, `lib/normandy/batch/**` | sonnet |
| L4 | `lib/normandy/llm/**`, `lib/normandy/mcp/**`, `lib/normandy/a2a/**` | sonnet |
| L5 | `lib/normandy/components/**`, `lib/normandy/context/**`, `lib/normandy/telemetry/**`, `lib/normandy/telemetry.ex` | sonnet |
| L6 | `lib/normandy/tools/**`, `lib/normandy/guardrails/**`, `lib/normandy/guardrails.ex`, `lib/normandy/tool.ex` | sonnet |
| L7 | `lib/normandy/schema/**`, `lib/normandy/dsl/**`, `lib/normandy/schema.ex`, `type.ex`, `validate.ex`, `parameterized_type.ex`, `metadata.ex` | sonnet |
| L8 | `lib/normandy/resilience/**`, `lib/normandy/test/fake_client.ex`, `lib/normandy/application.ex`, `lib/normandy/json.ex` | sonnet |

## Phase 1 — lanes (parallel)

### L1-T1: credential slot has no default; FromClient goes (A1 · behaviours#1)

**Files:** `lib/normandy/behaviours/config.ex:51`, `lib/normandy/behaviours/credential_provider.ex`, `lib/normandy/agents/turn/session.ex`, `lib/normandy/agents/turn/server.ex:679-701,795`, tests under `test/agents/turn/` and `test/behaviours/`.

**Ruling:** `%Behaviours.Config{}` `credential` defaults to `nil`. `Turn.Session.new/1` raises `ArgumentError` naming `:credential` when the session rebuilds its config from a stored template (`:template_provider`, or `:config` whose behaviours config has `credential: nil`) — find which sessions rebuild and pin that in the test. Delete `CredentialProvider.FromClient` and its unit test.

- [ ] Test `test "a template-backed session without a credential provider is refused at new/1"`: `assert_raise ArgumentError, ~r/:credential/, fn -> Turn.Session.new(...) end`. Red.
- [ ] Implement; green. Update every test that relied on the default (give it a test provider).
- [ ] Report: MIGRATING text ("`credential` has no default; `FromClient` removed; pass a `CredentialProvider` module").
- [ ] Commit `feat!: a template-backed session needs a credential provider`.

### L1-T2: one concurrent tool-batch runner (agents#1)

**Files:** `lib/normandy/agents/dispatch.ex`, `base_agent.ex:833,1427,1994-2001`, `turn/server.ex:2170-2225`.

**Interfaces — Produces:** `@doc false Normandy.Agents.Dispatch.run_batch(config :: BaseAgentConfig.t(), items :: [term()], fun :: (term() -> term())) :: [term()]` — owns `Task.async_stream` options, OTel capture/restore, the slim task config (`tool_task_config/1` moves here) and `unwrap_tool_task_result!/1`.

- [ ] Test: a `run/3` with two tool calls whose tool asserts the config it receives has empty memory entries (the B2 property, now on the BaseAgent path). Red on `dispatch_turn_tools`.
- [ ] Replace the four copies; delete `execute_one_streaming_tool_call/2`; drop the four `max(... || 1, 1)` (the value is a `pos_integer` after `init/1`).
- [ ] Green; commit `refactor(agents): one concurrent tool-batch runner for every turn path`.

### L1-T3: Turn.Server runs its worker through WatchedWorker (core#6)

- [ ] Replace `run_while_server_alive/3` with `Normandy.WatchedWorker`; delete the private copy and the "meant to move here" comment. Existing Turn.Server suite green. Commit `refactor(turn-server): run the turn worker through WatchedWorker`.

### L1-T4: ServerGlue calls hook functions directly (tools#1)

- [ ] Make `Hooks.Handlers.before_llm!/3` and `after_compact/2` `@doc false` public; `ServerGlue.before_llm`/`after_compact` call them and lose the `handlers` parameter; update the two `server.ex` call sites. Hooks suite green. Commit `refactor(hooks): server glue calls before_llm and after_compact directly`.

### L1-T5: supervisor contract as a behaviour (agents#2)

**Interfaces — Produces:** public `Normandy.Agents.Turn.ServerSupervisor` behaviour (name final) with the callbacks `Turn.Session` calls today on `:supervisor_mod` (`start_server/…`, `stop_server/2`; read session.ex for exact arities). Both lib implementations declare `@behaviour`; test doubles in `test/` declare it too. `mix.exs` group entry; `@doc` on each callback.

- [ ] Test: `Turn.Session.new/1` with a `:supervisor_mod` that does not export the callbacks raises `ArgumentError` naming `:supervisor_mod`. Red, implement, green.
- [ ] Commit `feat(turn): the session supervisor contract is a behaviour`.

### L1-T6: agents docs and small cleanups (agents#4, #5, #6)

- [ ] agents#4: rewrite the "later phases" text in `dispatch.ex` moduledoc, `default_pipeline/0` doc, `Turn.Inline` and `Turn.Driver` comments to describe `Config.to_pipeline/1` as it is.
- [ ] agents#5: delete the two uncalled `ValidationMiddleware` helpers (check `test/` callers first; delete their tests too).
- [ ] agents#6: extract per the report so `stream_attempt`, `consume_stream_with_incremental_guards` and `Turn.Start.start_server` reach depth ≤ 3; remove the credo disables that become unnecessary.
- [ ] Commits: `docs(agents): dispatch docs describe the shipped pipeline`, `refactor(agents): drop unused validation helpers and flatten three functions`.

### L1-T7: BaseAgent facade split (agents#3) — last in L1

**Ruling:** move the `@doc false` handler functions `Turn.Server` and others call into `@moduledoc false Normandy.Agents.BaseAgent.Handlers` (name final); `BaseAgent` keeps its public API and delegates nothing public. Pure move: no behaviour change, full suite green.

- [ ] Move; update aliases in Server, ConfigTemplate, Hooks, `Telemetry.RunUsage` (L1 may edit the alias lines in non-L1 files; note each in the report for merge).
- [ ] Commit `refactor(agents): BaseAgent's internal handlers move to their own module`.

### L2-T1: store and registry constructors take explicit handles (A2 · behaviours#3, core#7)

**Files:** `session_store/redis.ex:89-103`, `memory_store/redis.ex:149-157`, `session_registry/redis.ex:217-224`, `session_store/postgres.ex:33`, `memory_store/postgres.ex:36`, `lib/normandy/cluster.ex:177`, `config/test.exs`, `test/support/`.

**Ruling:** the three Redis `new/1` require `:url` and `:namespace` (memory store: its prefix option) in their NimbleOptions schemas; no `Application.get_env(:normandy, :redis_url, ...)` in lib. Postgres `new/0` is removed (the handle is the host's Repo module). Tests get their handles from a `test/support` helper `Normandy.TestHandles` (`redis_session_store/1`, `redis_memory_store/1`, `redis_registry/1`, `postgres_repo/0`; check the shipped-names test) that reads `config/test.exs`. Shipped contracts keep their `new: {m, f, a}` option; update their docs if they named the removed defaults. core#7: `redis_child_specs/1` reads `:redis_wait` and computes the plan once.

- [ ] Test: `assert_raise ArgumentError, ~r/:namespace/, fn -> SessionStore.Redis.new(url: "redis://localhost:6379") end` (and `:url`, and the other two modules). Red, implement, green.
- [ ] `mix precommit`, `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` all exit 0.
- [ ] Report: MIGRATING text. Commit `feat!: Redis and Postgres store constructors take explicit handles`.

### L2-T2: behaviours docs and fork flattening (behaviours#4, #5)

- [ ] behaviours#4: fix the stale Horde/"Phase N" text in `session_registry.ex`, `session_store.ex`, `policy_engine.ex`, `in_memory.ex`; add a contract test module running `SessionRegistryContract` against `AgentProcess.ScopedRegistry` (or, if ScopedRegistry is not a `SessionRegistry`, correct line 12's claim instead — say which in the report). Update `test/normandy/test/contracts_test.exs` counts if they change.
- [ ] behaviours#5: one `with` in `fork/3` of `in_memory.ex` and `mnesia.ex`; drop both credo disables.
- [ ] Commits `docs(behaviours): ...`, `refactor(session-store): flatten fork/3`.

### L3-T1: coordination API removals (A4 coordination#2, A5 coordination#7, A8 coordination#3)

**Rulings:**
- A4: remove `:shared_context` from `HierarchicalCoordinator` `new/1`, `execute/3`, `execute_with_tasks/3` schemas and the struct field; `SharedContext` itself stays.
- A5: remove `Pattern.ok/1` and `Pattern.error/1`. Rename `ok!/2` → `ok_value/2` and `error!/2` → `error_reason/2` (they return a default, they never raise); same `default:` option. Fix the moduledoc examples.
- A8 + coordination#3: one run-and-classify in `Orchestration.run_agent/3` (pid clause + label argument); `Reactive`, `HierarchicalCoordinator`, `AgentProcess.inline_turn` and `Batch.Processor` call it; one `prepare_input`. `Batch.Processor.process_batch/3` errors become the shape the other coordinators return (bare Normandy exception, or a `:task_down` `TurnError`; no stacktrace, no `{:exit, _}`/`{:throw, _}`).
- [ ] Tests: `Batch.Processor` with an agent that raises / exits / throws → `{:error, %TurnError{reason: :task_down}}` (or the bare exception for a Normandy error), never a stacktrace. Red, then green. Existing Pattern doctests updated.
- [ ] Report: MIGRATING text for all three. Commits `feat!: ...` one per ruling.

### L3-T2: coordination internals and docs (coordination#1, #4, #5, #6, #8, #9, #10)

- [ ] coordination#1: reads must not wait behind `update/4`'s fun without changing `get_table/1`'s public contract (e.g. run the fun outside the GenServer with a version CAS). Test: a `fetch` during a 500 ms `update` returns in < 50 ms. If no non-breaking design exists, fix only the docs and say so in the report.
- [ ] coordination#6: one engine module per `:turn_engine` so the 9 dispatch sites become one; `AgentProcess` public API unchanged.
- [ ] coordination#4, #10 doc fixes; #5, #8 flatten (drop the credo disables); #9 dedupe the helpers.
- [ ] Commits grouped: `fix(coordination): a context read never waits behind an update`, `refactor(coordination): ...`, `docs(coordination): ...`.

### L4-T1: linear JSON region extraction (B1 · llm#1)

- [ ] Test `test "unclosed brace in 240 KB of prose returns within 1 s"`: build `String.duplicate("{ word ", 40_000)`, `{t, _} = :timer.tc(fn -> JsonDeserializer.<the public entry the report names>(text, ...) end)`, `assert t < 1_000_000`. Red (≈30 s).
- [ ] Find the regions in one stack-based pass in `json/content_cleaner.ex`/`json_deserializer.ex:347`; same regions found on balanced input (existing tests green). Commit `fix(llm): JSON region extraction is linear on unclosed braces`.

### L4-T1b: drop truncated-string recovery (A12 · llm#10)

**Ruling:** remove the `recover_truncated_strings` option, `lib/normandy/llm/json/scanner.ex`, the recovery branch in `json/decoder.ex:33-41`, the `[:normandy, :json_deserializer, :recovery]` event, its tests, and its entry in the `Normandy.Telemetry` moduledoc (catalogue test must stay green; `telemetry.ex` is L5's file — make that one moduledoc edit and note it in the report for the merge).
- [ ] Test: `parse_and_validate(text, schema, recover_truncated_strings: true)` → `ArgumentError` naming the unknown option (if the options are NimbleOptions-validated; otherwise state what happens). Red, green.
- [ ] Report: MIGRATING text. Commit `feat!: JsonDeserializer drops truncated-string recovery`.

### L4-T2: llm internals and docs (llm#2–#7, #9, #11, #12)

- [ ] llm#3: `deserialize_with_retry` returns summed retry usage; summing moves to `Telemetry.Usage` (L5 owns `telemetry/` — if `Telemetry.Usage` needs a new function, put it in L4's report for the merge and keep a private helper meanwhile). `:on_retry_usage` stays.
- [ ] llm#4 pass invariants in a struct/map; llm#5 drop `deadline` from `poll_for_result/4`; llm#6 poll interval injectable through the tool's options (default 1_000) with a test of the polling path; llm#7 one parts-to-text function.
- [ ] llm#11: before dropping a dual-key read, confirm in `deps/claudio` which shape 0.7.1 emits; cite the file:line in the report.
- [ ] llm#2, #9, #12 doc fixes. Commits grouped by kind.

### L5-T1: context API (A3 components#10, A7 components#4, A9 components#9)

**Rulings:** `TokenCounter.count_message/3` has no default model (`count_message/2` removed). `:sliding_window` removed from `WindowManager`'s strategy `:in` list. `:summarize` without a client raises `ArgumentError` naming `:client`.
- [ ] Tests: `count_message/2` undefined (`refute function_exported?`); `:sliding_window` → `ArgumentError` from the options check; `:summarize` with no client → `ArgumentError, ~r/:client/`. Red, green.
- [ ] Report: MIGRATING text. Commits `feat!: ...` per ruling.

### L5-T2: components internals and docs (components#2, #3, #6, #7 doc, #8, #11, #5 doc is L7)

- [ ] components#2: pure estimators move to `@moduledoc false Normandy.Context.TokenEstimate`; WindowManager keeps `defdelegate`s; `mix xref graph --format cycles` shows the AgentMemory cycle gone (paste before/after counts).
- [ ] components#3: `Span.span/4` outcome variant; `Telemetry.Request.span` and the summary llm_call span use it; telemetry catalogue test green.
- [ ] components#6, #7 (example only; `accumulate_text/1` stays public) doc fixes; #8 replace `do_compress_conversation/7` with a guard; #11 Summarizer calls `AgentMemory.unwrap_llm_content/1` unless the single-key rule is intended — decide from git blame/tests and say which.
- [ ] Commits grouped.

### L6-T1: tools API (A6 tools#4, tools#5)

**Rulings:** remove `Toolset.fetch_metadata/2`, `list_metadata/1`, `introspect_schema/2`. Toolset holds one map `%{name => %Toolset.Entry{tool:, timeout:, max_result_chars:}}` (`Entry` `@moduledoc false`); `@type t` and the doctest follow; public functions keep their signatures.
- [ ] Existing toolset tests green; doctest updated. Report MIGRATING text. Commits `feat!: drop unused Toolset metadata functions`, `refactor(tools)!: Toolset keeps one entry per tool`.

### L6-T2: tools/guardrails internals and docs (B4 tools#3, tools#2, #6–#10)

- [ ] tools#3: `Memory.new/1` validates through `Normandy.Options.validate!/3` (accepts a map; unknown key → `ArgumentError` prefixed `Normandy.Tools.Memory.new/1:`). Test first.
- [ ] tools#2: one shared string-guard skeleton in `Guardrails.Builtins.Field` (internal); drop the three credo disables. tools#6, #7 flatten. tools#8 built-in check by an explicit list or a module attribute, not the name prefix. tools#9 doc. tools#10 Commands uses `Paths.root/0` and the runtime list limit.
- [ ] Commits grouped.

### L7-T1: Ecto residue out (A10 · schema#1, #2, components#5, plus `primitive?/1` from E)

**Rulings:** follow schema#1's Fix fully: drop `embed_as` (both behaviours and `__using__` defaults), `embedded_dump/3`, `embedded_load/3`, `match?/2`/`do_match?`, the cast clauses for types `field/3` rejects, `:in`/`:splice`, `Type.load/2,3`, and the `load` example in ParameterizedType's moduledoc; remove `Type.primitive?/1` if still callerless. schema#2's Fix fully (`changes: %{}` default, in `@type t`). components#5: drop `Normandy.Metadata`'s `source`, `context` and `:deleted` state; keep `__meta__` only if something reads it after that — otherwise remove the struct field too and say so.
- [ ] Full suite green; `mix docs --warnings-as-errors` green. Report: MIGRATING text and the CLAUDE.md `Normandy.Type` bullet rewrite (schema#4) as a proposal. Commits: `feat!: Normandy.Type drops Ecto's database callbacks`, `feat!: Validate drops changeset fields Normandy never used`, `feat!: Metadata keeps only what schemas read`.

### L7-T2: schema docs, DSL and flattening (schema#3, #4 lib part, #5–#9)

- [ ] schema#3: the `:datetime` error suggests types `field/3` accepts (test the message). schema#4, #9 doc fixes. schema#5 one quote for `step`/`parallel`/`race`; the ~125 generated runtime lines move to `@moduledoc false Normandy.DSL.Workflow.Runtime`; `execute/1`, `steps/0` unchanged. schema#6, #7, #8 flatten per the report; drop the disables that become unnecessary.
- [ ] Commits grouped.

### L8-T0: Normandy.JSON calls Jason directly (A11 · core#4)

**Ruling:** remove the `config :normandy, :adapter` key; `Normandy.JSON` calls Jason. Keep `Normandy.JSON` as the module the library calls (its public functions stay) unless nothing outside lib needs it — say which in the report. Delete the adapter tests in `test/app_env_config_test.exs` (keep the file's other tests). Update the `Normandy.JSON` moduledoc and any guide naming `:adapter`.
- [ ] Existing suite green; `grep -rn ":adapter" lib docs README.md` shows no JSON-adapter mention. Report: MIGRATING text and the CLAUDE.md `:adapter`/BaseIOSchema/Jason lines as a proposal. Commit `feat!: Normandy encodes JSON with Jason; the :adapter setting is gone`.

### L8-T1: core fixes (B2 core#2, B3 core#3, B4 core#1, core#5, #8, #9)

- [ ] B2 test: kill the breaker Registry child; assert a name registered in `AgentProcess.ScopedRegistry` before the kill still resolves after the restart. Red, then nest the breaker children under their own `rest_for_one` supervisor with a top-level `one_for_one`; green.
- [ ] B3: retry tests assert on `[:normandy, :retry, :attempt]` `delay_ms` with `base_delay: 1`; drop the `if length(times) == 3` guard; `timeout: 1` in the two slow breaker tests.
- [ ] B4: `Retry` options through `Normandy.Options.validate!/3`; test a map and a duplicate key.
- [ ] core#5 one shape constant in FakeClient, `check_item!/2` takes it as an argument (error text unchanged — existing tests pin it). core#8 diagram `>=`. core#9 drop "Default" from `preset(:standard)`'s doc (value unchanged).
- [ ] Commits grouped.

## Phase 1 review and merge (controller)

- [ ] Per lane, after its last task: `review-package` from BASE to the lane head; task reviewer (sonnet; opus for L1); fix rounds per the SDD skill.
- [ ] Merge lanes into `feat/claudio-0.7-migration` in order L8, L7, L6, L5, L4, L3, L2, L1 (`git merge --no-ff audit/L<n>`); resolve conflicts; precommit after each merge (partition `_w54probe`). A conflict whose resolution is not mechanical goes to Q.
- [ ] Remove each lane worktree after its merge (`git worktree remove`); branches kept until Q says.

## Phase 2 — cross-lane findings (sequential, on the merged branch)

### P2-T1: Compactor and ModelCatalog declare their own needs (behaviours#2)
- [ ] Optional `@callback validate_opts!(keyword()) :: keyword()` and `needs_window?/1` on `Compactor`; `WindowManager` implements them; `BaseAgent` (or its handlers module from L1-T7) calls them when exported; the module-name checks at `base_agent.ex:1141-1173` go. Test: a host compactor whose `validate_opts!/1` raises fails at `BaseAgent.init/1`. Commit `feat(compactor): a compactor validates its own options at init`.

### P2-T2: ContentBlock protocol (components#1)
- [ ] Public protocol `Normandy.Components.ContentBlock.Protocol` (name final; group entry, docs) with `to_claudio/1`, `estimate_tokens/1`, `label/1`, implemented by Text, Image, Document; the struct switches in window_manager, token_counter, summarizer, claudio_adapter (`block_to_claudio`), base_io_schema, agent_memory call it. Request bodies byte-identical (existing wire tests). Commit `refactor(components): content blocks answer through one protocol`.

### P2-T3: shared registration, URL sanitizer, status classification (llm#8)
- [ ] `@doc false Toolset.register_new/3` used by both MCP and A2A registries; one `sanitize_url/1` used by `ClientInspect` and `CircuitBreaker`; `LLMError.classify_status/1` and `LLMError.transport/1` (`@doc false`) used by both adapters — the 529/`nil` difference resolved toward the Claudio adapter's mapping, with a test for each status. Commit `refactor: one rule each for tool registration, URL redaction and HTTP status`.

## Phase 3 — docs, gate, final review

### P3.1: MIGRATING, CHANGELOG, api_diff
- [ ] Apply every lane's proposed MIGRATING/CHANGELOG text; `tools/api_diff/run.sh main` → unmatched 0; `mix test test/docs` green. Commit `docs: MIGRATING and CHANGELOG for the principles-audit changes`.
- [ ] Collect all CLAUDE.md proposals into one list for Q (no edit).

### P3.2: gate
- [ ] `mix precommit` 0, `mix docs --warnings-as-errors` 0, `mix test.redis` 0, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` 0, distributed suite twice, `mix hex.build --unpack` clean.

### P3.3: final whole-branch review (opus) on `BASE..HEAD`; one fix dispatch; re-review. Then decisions.md Wave 8 bullet, memory update, report to Q. Q does push/PR (7.7).
