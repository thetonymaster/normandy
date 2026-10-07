# Wave 6 preflight log

### Task 6.1a — FIXED
- Commits: `609c57d` (fixture, recorded on unmodified `d624fbf`: record run `9 tests, 6 failures` with the 6 "recorded 5 bodies" messages, then 3× `9 tests, 0 failures`; precommit `72 doctests, 28 properties, 3387 tests, 0 failures (222 excluded)`), `ddb745e` (task).
- Red phase as stated (entry_cache/config_template: `unknown key :wire`; server_append_encoding: `2 tests, 2 failures`, `match (=) failed`, `right: {:ok, ...}`).
- Precommit: `72 doctests, 28 properties, 3400 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0; `mix docs --warnings-as-errors` 0. Postgres + distributed (`mix test.postgres --include distributed`, `_w54probe`): `3468 tests, 0 failures (154 excluded)`.
- Text correction (6.1.md, Step 6, new item (k) + Files + Step 14 `git add`): widen `BaseIOSchema`'s `@spec to_json(struct())`/`get_schema(struct())` to `t()`. Why: with encode-at-append dialyzer narrowed `add_message/4`'s content to `struct()` and reported 2 new errors (`summarizer.ex:491 no_return`, `:500 call` — the plain-string summary append) — the writer ran dialyzer only with 6.1a–e stacked, where 6.1c deletes that function. The spec was wrong anyway (strings, maps, lists implement the protocol).
- Text correction (6.1.md, Step 10 check): `wc -l` → `8`, not `7` (`test/hooks/server_hooks_test.exs` already has a `Resp` impl).
- X8 noted for later phases: every 6.2–6.5 test double that reaches memory (output schema, tool result, input) needs a `BaseIOSchema` impl or the append raises `Protocol.UndefinedError` (Turn.Server: `:handler_crashed` `:append`).

### Task 6.1b — FIXED
- Commit: `8a35afb`. Red phase as stated (`2 properties, 2 tests, 3 failures`, `UndefinedFunctionError ... request_messages_for/2`).
- Precommit: `72 doctests, 30 properties, 3402 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0. Fixture test passes. Tagged suites: none (per section).
- Text correction (6.1.md, Step 4 check): `grep -rn "request_messages_for(" lib` prints 4 lines, not 3 (the `@spec` line matches too). Cosmetic.

### Task 6.1c — PASS
- Commit: `74e472c`. Red phase as stated (`1 property, 6 tests, 6 failures`: 3× `keep_entries/3` undefined; counts 80 vs 40 and 40 vs 20; `tokens_removed` 168 vs 133).
- Precommit: `72 doctests, 31 properties, 3408 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed (36 skipped, 0 unnecessary), exit 0. Fixture test passes. Tagged suites: none (per section).
- No text corrections.

### Task 6.1d — PASS
- Commit: `00ca67c`. `linear_history_test.exs`: `11 tests, 0 failures` twice.
- Precommit: `72 doctests, 31 properties, 3419 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0. Tagged suites: none (per section).
- No text corrections.

### Task 6.1e — PASS
- Commit (Part A, Normandy): `2154065`. Red phase as stated (`14 tests, 1 failure`, the new "left out" test). Steps 4–5: `41 tests, 0 failures` for the two files.
- Precommit: `72 doctests, 31 properties, 3420 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0; `mix docs --warnings-as-errors` 0.
- Part B (Claudio), applied in a detached worktree of `005c51d` per the brief (no `feat/add-messages` branch created; worktree removed; diff kept at `scratchpad/w6p1-6.1e-claudio.diff`): Step 9 preconditions held (`main`, `005c51d`, only `?? .claude/worktrees/` and `?? Claudio`). Red `241 tests, 3 failures` as stated; green `241 tests, 0 failures`; full suite `864 tests, 0 failures (52 excluded)`; Claudio `mix precommit` exit 0 (credo no issues, dialyzer `Total errors: 0`); docs 0.
- No text corrections.

### Phase 1 end (6.1a–6.1e)
- `mix test.redis` once on `2154065`: `72 doctests, 31 properties, 3495 tests, 0 failures (147 excluded)`, exit 0.
- Postgres (`--include distributed`) ran after 6.1a only (the one 6.1 step naming it); `normandy-test-pg` started by this phase and stopped at its end.
- Wire fixture (`test/agents/wire_identity_test.exs`) green after every task (part of each precommit run).

### Task 6.2a — FIXED
- Commit: `c32b7bd`. Red phase as stated (`62 tests, 19 failures`: 4 `UndefinedFunctionError reason_term/1`; 11 store-failure tests incl. 3 `** (EXIT ...) shutdown`; 2 turn, 1 driver, 1 inline). Step 8: `193 tests, 0 failures`.
- Precommit: `72 doctests, 31 properties, 3440 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0. Dialyzer total went 36 → 37 skipped: the new one is `describe.ex contract_supertype` for `reason_term/1`'s `term() :: term()` spec, absorbed by the existing `~r"is a supertype of the success typing"` filter (no ignore-file change).
- Text correction (6.2.md, Step 7, `:reason` in replies): the before-snippet ended at "`included.`", which is mid-line in `turn_error.ex` ("`included. The copy ...`"); before/after rewritten to the real three lines. Cosmetic.

### Task 6.2b — FIXED
- Commit: `295160d`. Red phase as stated (`3 tests, 3 failures`: two `** (EXIT) time out`, wall clock `took 10069 ms`). Step 5: `42 doctests, 551 tests, 0 failures (8 excluded)`.
- Precommit: `72 doctests, 31 properties, 3443 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed (37 skipped, as after 6.2a), exit 0.
- Tagged: `mix test.redis` `72 doctests, 31 properties, 3518 tests, 0 failures (147 excluded)`; `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres --include distributed` `72 doctests, 31 properties, 3511 tests, 0 failures (154 excluded)`.
- Text correction (6.2.md, Step 4 "Check"): the grep also lists the new `session.ex` comment above `rehydrate_and_start/1` (the step's own text says "after init/1"); check now names it (5 lines). Cosmetic.

### Task 6.2c — PASS
- Commit: `034f699`. Red phase as stated (`3 tests, 3 failures`: `{:ok, pid}` second start, `%{active: 2}`, vanishing-winner `{:ok, _}`). Step 6: `42 doctests, 519 tests, 0 failures (8 excluded)`.
- Precommit: `72 doctests, 31 properties, 3446 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0.
- Tagged: `mix test.redis` `3521 tests, 0 failures (147 excluded)`; Postgres + distributed `3514 tests, 0 failures (154 excluded)`.
- No text corrections.

### Task 6.2d — FIXED (X1 / H8)
- Commit: `d26be0a`. Section rewritten for H8 before applying; red phase of the rewritten text as stated (`135 tests, 7 failures`: 3 in `session_passivation_test.exs` — two `no process`, one `shutdown: :passivated` — and the 4 existing passivation assertions `no matching message after 1000ms`). Step 5: `183 tests, 0 failures`; `grep "{:stop, :normal" lib/normandy/agents/turn/` empty.
- Precommit: `72 doctests, 31 properties, 3451 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0.
- Tagged (not named by the section; run because the stop reason reaches registries and Horde `:transient` children): `mix test.redis` `3526 tests, 0 failures (147 excluded)`; Postgres + distributed `3519 tests, 0 failures (154 excluded)`.
- Text correction (6.2.md, whole Task 6.2d, X1): rewritten for H8. Passivation now `{:stop, {:shutdown, :passivated}, data}` (new Step 3 in `server.ex`: clause comment + moduledoc "Store unavailable" last sentence); `run_on_server/3` catches only `:noproc` and `{:shutdown, :passivated}`; tests: the `StopsOnCall(:normal)` retry test becomes `{:shutdown, :passivated}`, a new `:normal`-propagates test (a `for` over `[:normal, :boom]`), and the 4 existing passivation assertions (`server_test.exs` ×2, `server_integration_test.exs`, `server_hooks_test.exs`) flip to `{:shutdown, :passivated}` (two renamed); MIGRATING gets a separate bullet for the stop reason; Files/Interfaces/commit updated.
- Text correction (same task, found applying the rewrite): `server_test.exs` "passivates ... after the idle timeout" starts the server with `start_link/1` and does not trap exits; `{:shutdown, _}`, unlike `:normal`, kills a linked non-trapping process (`** (EXIT from #PID<...>) shutdown: :passivated`). The step now adds `Process.flag(:trap_exit, true)` to that test, and the intro and the MIGRATING bullet say a direct `start_link/1` caller outside a supervisor now exits with the server at passivation.
- Ruling: the H8 reason is applied as-is although it changes linked-process behaviour for direct `Turn.Server.start_link/1` callers — H8 is binding and the library itself only starts servers under supervisors (which trap exits) — cost if wrong: a host linking to servers directly sees its process die at passivation; documented in MIGRATING.

### Task 6.2e — PASS
- Commit: `f897155`. Red phase as stated (`51 tests, 3 failures`: two `assert_received {:after_hook, 0, turn_id}`, one `UndefinedFunctionError without_entries/1`). Step 5: `2 doctests, 363 tests, 0 failures (8 excluded)`; `grep -c tool_config` → 4.
- Precommit: `72 doctests, 31 properties, 3454 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0.
- X8: the test's `Resp` double has a `BaseIOSchema` impl; tool output and input are strings. No text corrections.

### Task 6.2f — PASS
- Commit: `9d0f7fc`. Red phase as stated (`14 tests, 2 failures`: `** (EXIT) time out`, `** (ArgumentError) SECRET-START-BUG`). Step 4: `14 tests, 0 failures`.
- Precommit: `72 doctests, 31 properties, 3456 tests, 0 failures (222 excluded)`, credo no issues, dialyzer passed, exit 0.
- Tagged: `mix test.redis` `3531 tests, 0 failures (147 excluded)`; Postgres + distributed `3524 tests, 0 failures (154 excluded)`.
- No text corrections. (X3 note for 6.4e: `reap/1` is now `Task.async_stream` over `reap_session/2`; 6.4e must diff against that.)

### Task 6.2g — FIXED (X4, X6)
- Commit: `c09d507`. Red phase as stated (`79 tests, 12 failures`: compaction 5, persistence 2, hooks 2, contract 3 on InMemory/ETS/Mnesia). Step 2 command green: `79 tests, 0 failures`; Step 5: `2 properties, 360 tests, 0 failures (8 excluded)`.
- Precommit: `72 doctests, 31 properties, 3466 tests, 0 failures (224 excluded)`, credo no issues, dialyzer passed (37 skipped), exit 0. `mix docs --warnings-as-errors` exit 0 (once for the phase, on this commit).
- Tagged: `mix test.redis` `3542 tests, 0 failures (148 excluded)`; Postgres + distributed `3535 tests, 0 failures (155 excluded)`. X6: the snapshot contract rule ran and passed on InMemory, ETS, Mnesia, Redis and Postgres (`--trace` of `test/behaviours/session_store/` with both tags: `90 tests, 0 failures`). (6.3b must keep it passing on the B5 ETS rows; delete rules with snapshot entries are 6.3d's.)
- Text correction (6.2.md, intro, Files, Interfaces, Step 3, X4): the section defined a new private `link_entry/2` (`put_content(%{entry | parent_id: parent}, ...)`), but 6.1c already has a private `link_entry/2` with the same `{entries, parent_id}` accumulator — a second definition would be dead clauses after the first. `compacted_chain/2` now pipes `snapshot_entries/1 ++ later` through 6.1a's `fill_entry/1` (rebuild from stored fields + `put_content/2`) and reduces with 6.1c's `link_entry/2`; the new `link_entry/2` is removed; the "Before 6.1a the line is ..." note is replaced by a note naming both helpers. Also "as Task 6.1a left it, building `entries` with `put_content/2`" → "with `fill_entry/1`" (the real 6.1a body).
- Text correction (6.2.md, "Notes for the controller", Risks): the 6.2d `:normal`-retry risk marked superseded by H8.

### Phase 2 end (6.2a–6.2g)
- `normandy-test-pg` started by this phase (before 6.2b's tagged run) and stopped at its end. Redis was already running.
- Wall-clock test (6.2b) passed in every precommit and tagged run of the phase.

### Task 6.3a — PASS (X11)
- Commit: `d1d08db`. X11: `normandy-test-pg` started before the task; Postgres steps run first-class. Red phase as stated: Redis `11 tests, 2 failures` (`UUID.info("fork_…")` `{:error, _}`; `right: :ok`); Postgres `10 tests, 1 failure`, `** (ArgumentError)` from `:erlang.binary_to_term(<<131, 255>>, [:safe])` in `Codec.decode/1` via `Postgres.chain/2` ← `ancestor_of_head?/3`. Step 4: Redis `73 tests, 0 failures (23 excluded)`, Postgres `67 tests, 0 failures (29 excluded)`.
- Precommit: `72 doctests, 31 properties, 3466 tests, 0 failures (228 excluded)`, credo no issues, dialyzer passed (37 skipped), exit 0.
- Tagged: `mix test.redis` `3545 tests, 0 failures (149 excluded)`; Postgres `3527 tests, 0 failures (167 excluded)`.
- X10: `## 40.` created after `## 39.`, before `## New, non-breaking`.
- No text corrections.

### Task 6.3b — PASS (X6)
- Commit: `49c7317`. Red phase as stated (`13 tests, 2 failures`: `left: 1`/`right: 6`, `left: 2`/`right: 7`). Step 4: `13 tests, 0 failures` (10 contract + 6.2g's snapshot rule + 2 layout).
- X6: 6.2g's snapshot contract rule passes on the B5 ETS rows (and again after 6.3c/6.3d; traced on all five backends after 6.3d).
- Precommit: `72 doctests, 31 properties, 3468 tests, 0 failures (228 excluded)`, credo no issues, dialyzer passed (37 skipped), exit 0. No tagged suite (per section).
- No text corrections.

### Task 6.3c — FIXED (X11, X8)
- Commit: `4dda141`. Red: `53 tests, 10 failures (53 excluded)`. Step 4: default `279 tests, 0 failures (62 excluded)`; Redis `80 tests, 0 failures (25 excluded)`; Postgres `75 tests, 0 failures (30 excluded)` (migration `20261006000000_add_inflight` applied to `normandy_test_w54probe` by `mix test.postgres`; `pg_indexes` shows `... USING btree (session_id) WHERE (inflight = true)` and `normandy_sessions_head_id_index`).
- Precommit: `72 doctests, 31 properties, 3473 tests, 0 failures (231 excluded)`, credo no issues, dialyzer passed (40 skipped: the 3 new `unmatched_return` in `migration_add_inflight.ex`, covered by the new ignore entry), exit 0.
- Tagged: Redis `3553 tests, 0 failures (151 excluded)`; Postgres `3536 tests, 0 failures (168 excluded)`; `--only distributed --include postgres` `72 tests, 0 failures`.
- X8: the new `server_inflight_test.exs` doubles (`TurnConfig.Resp`, `FakeTool`) reach memory and are encodable (test green on every run).
- Text correction (6.3a-e.md, 6.3c Step 2 expected): stacked count `53 tests, 10 failures`; the contract's new "an :eager config template does not list a session by itself" also fails (old `list_resumable/1` lists the template), and only the `:eager` server test fails — the `:lazy` one passes before and after. The text said "both server tests fail".
- Text correction (6.3c Step 3e): 6.2 added four 3-arity stubs, two of them `defdelegate` which `grep "def save_turn_state("` misses: `test/support/gated_store.ex` (6.2b), `server_store_failures_test.exs` (6.2a), `server_start_test.exs` (6.2b, defdelegate), `server_compaction_persistence_test.exs` (6.2g, defdelegate). Grep changed to `grep -rnE "def(delegate)? save_turn_state\(" test` (10 lines after 6.2), a table for the four added; 6.2f's `eager_sessions/1` helper in `resume_reaper_test.exs` added to the call-site table (`true`); the final check grep also excludes `defdelegate save_turn_state`; the four files added to Step 7's `git add` list (replacing the "add gated_store if changed" note). Without them `--warnings-as-errors`/tests fail (`InMemory.save_turn_state/3 is undefined`).

### Task 6.3d — FIXED (X6, X11)
- Commit: `4305c46`. Red: `64 tests, 14 failures (62 excluded)`, all `UndefinedFunctionError ... delete_session/2`. Step 4: default `64 tests, 0 failures`; Postgres `91 tests, 0 failures (35 excluded)`; Redis store tests 6 consecutive runs `97 tests, 0 failures`.
- X6: `mix test test/behaviours/session_store/ --include postgres --include redis --trace`: `124 tests, 0 failures`; the four delete rules (incl. the Review Focus 1 rule with a 6.2g-shape snapshot entry) and the snapshot round-trip rule ran and passed on InMemory, ETS, Mnesia, Redis and Postgres. Postgres delete SQL (`chain_ids/2` CTE, `= ANY($1::uuid[])` with raw 16-byte ids, `FOR SHARE` fork) ran for the first time here and passed.
- Precommit: `72 doctests, 31 properties, 3486 tests, 0 failures (240 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0.
- Tagged: Postgres `3553 tests, 0 failures (173 excluded)`; distributed + postgres `76 tests, 0 failures`; Redis first run `3571 tests, 1 failure` — `Normandy.Resilience.TelemetryTest` "a raise is typed by its module, and the log holds no message or stacktrace" (`refute log =~ ~r/\.exs?:\d+/`: its async `capture_log` caught another test's hook-crash log with `runner_test.exs:248` frames). Not a 6.3 file; same seed (27934) rerun `3571 tests, 0 failures`, fresh run `0 failures`. Pre-existing cross-test log-capture flake.
- Text correction (6.3d Step 2 expected): `PostgresBackendErrorTest` ("every callback reports an unreachable database ...") also fails red — it runs in the default suite (stub repo); observed count added.

### Task 6.3e — FIXED
- Commit: `31d438e`. Red as stated (`9 tests, 9 failures`, `UndefinedFunctionError ... Session.delete/1`). Step 4: `52 tests, 0 failures`; `session_delete_test.exs` 3 consecutive runs `9 tests, 0 failures`. 6.2d's `{:shutdown, :passivated}` and 6.2a's `store_call/1` did not interact: the supervisor's `terminate_child` gives `:shutdown` (Turn.Server does not trap exits), as the test asserts.
- Precommit: `72 doctests, 31 properties, 3495 tests, 0 failures (240 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0 (once for the phase, on this tree).
- Tagged: Redis `3580 tests, 0 failures (155 excluded)`; Postgres `3562 tests, 0 failures (173 excluded)`; distributed + postgres `76 tests, 0 failures`.
- Text correction (6.3e Step 3, `turn_error.ex`): 6.2a reworded both bullets; the before-snippets (`:reason` is its reason` / `is that failure.` + approve line) no longer match. Rewritten as anchors on the 6.2a text: append the delete sentence after `` `{:timeout, {GenServer, :call, 3}}` `` and after the `approve/2` line.
- Text correction (6.3e Step 3, `resume_reaper.ex`): the before-snippet's third line continues with " It is restarted as a thin spec"; the text now says to keep that sentence.
- Ruling: `Session.delete/1`'s `:persist_failed` reason is `Describe.reason_term(reason)`, not the raw store reason — 6.2a reduces every store reason that reaches a `Session` caller (`server_opts/1`'s template load/save) and decision 6 forbids SQL text in a reason; the test's `:disk_full` is unchanged by it — cost if wrong: a host reading the raw reason (e.g. a `Postgrex.Error` struct) from `delete/1` gets its tag term; one-line revert. Section text (code + `@doc` bullet) updated.

### Phase 3 end (6.3a–6.3e)
- `normandy-test-pg` started by this phase (before 6.3a) and stopped at its end; Redis was already running.
- Section 6.3a-e.md "Notes for the controller" › "Not verified": preflight note added (all Postgres steps ran and passed).

### Task 6.3f — FIXED
- Commit: `05f924d`. Red: `test/cluster_test.exs` fails to compile (`...Redis.Handle.__struct__/1 is undefined, cannot expand struct`), aborting the stated run; without it `63 tests, 14 failures (2 excluded)` (`Redis.handle/1` undefined ×4, `:redis_registry_N.owner/0`/`.namespace/0` undefined ×6, ...). Step 8: `73 tests, 0 failures (2 excluded)`.
- Precommit: `72 doctests, 31 properties, 3503 tests, 0 failures (245 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0.
- Tagged: Redis first run `3593 tests, 1 failure (155 excluded)` — the known `Normandy.Resilience.TelemetryTest` "a raise is typed by its module, and the log holds no message or stacktrace" flake, **seed 131968**; output: `refute log =~ ~r/\.exs?:\d+/` matched frames `test/coordination/agent_process_server_test.exs:227` (Turn.Server "llm worker raised (session \"srv_async_crash\")" log) and `:400` (`ThrowingRegistry.whereis/2`, "Async agent ... raised throw") captured by its async `capture_log`. Unlike phase 3, the same seed **reproduces** (`--seed 131968`: `1 failure`, same test, same two foreign frames); fresh run `3593 tests, 0 failures`. Not a 6.3 file; not fixed. Distributed + postgres `76 tests, 0 failures`.
- Text correction (6.3f Step 2 expected): stacked, `cluster_test.exs` is a compile error that aborts the run (the `%RedisReg.Handle{}` literal); observed counts without it added.
- Text correction (6.3f Step 8 expected): stacked count `73 tests, 0 failures (2 excluded)` added.
- Text correction (6.3f Step 9): a bare `mix test --only distributed` gives `9 tests, 1 failure` — `eager_handoff_distributed_test.exs` is tagged only `:distributed` and its setup raises `Normandy.TestRepo not started` (pre-existing, by design per its moduledoc). Gate now starts `normandy-test-pg` and runs `--only distributed --include postgres` with the partition env.
- Text correction (6.3f Step 10, MIGRATING): the `:registration_lost` bullet now says `Turn.Session.run/2` re-routes only `{:shutdown, :passivated}`/`:noproc` (pointer to `## 39.`), so a fenced server's caller exit is consistent with 6.2d/H8 (verified against `session.ex` `run_on_server/3`).

### Task 6.3g — FIXED (X5)
- Commit: `fd19e6a`. Red: `52 tests, 11 failures` (unknown option `:wait_connections` / `:store_redix`; the two pool tests, the redaction and sensitive-keys tests, 4 combo tests). Step 6: `155 tests, 0 failures (29 excluded)`; `redis_wait_pool_test.exs` 3 consecutive runs `2 tests, 0 failures`.
- X5: the pool tests call 6.3c's `save_turn_state/4` and pass; 6.3a's `pipeline_ok/1` (in `save_turn_state/4`, `delete_session/2`) and 6.3c's in-flight SET commands run unchanged on the session's wait connection. Step 3c's grep found N = 4 (6.3d's `delete_session/2` waits), all rewritten to `write_target!/2`.
- Precommit: `72 doctests, 31 properties, 3511 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0.
- Tagged: Redis `3604 tests, 0 failures (155 excluded)` (seed 672235). No Postgres/distributed (per section).
- Text correction (6.3g Step 2 expected): the `:store_redix` redaction case fails on the message (`unknown option :store_redix`), not by echoing `sk-secret`; observed count added.
- Text correction (6.3g Step 3c): N = 4 stated (6.3d's `delete_session/2` waits).
- Text correction (6.3g Step 6): stacked count added.

### Task 6.3h — FIXED
- Commit: `18cefdd`. Red: `36 tests, 2 failures` (`left: :set`/`right: :ordered_set`; `left: 1`/`right: 3`). Step 6: `202 tests, 0 failures (76 excluded)`.
- Precommit: `72 doctests, 31 properties, 3514 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. No tagged suite (per section).
- Text correction (6.3h Step 2 expected): only two of the three layout tests fail; "emptying a namespace removes its totals row" passes on the old store too (it drops an emptied namespace's row, size 0 either way). The text said all three fail and that the size is 2 (it is 1 in the overwrite test, the one that checks size before the change).

### Task 6.3i — FIXED
- Commit: `caa3ec7`. Red as stated (`38 tests, 3 failures`: attributes `[:namespace, :docs]`; old-layout table accepted; size `1` vs `6`). Step 3 check: `grep -rn "create_table!(" lib` → 4 lines, five arguments each. Step 6: `225 tests, 0 failures (76 excluded)`.
- Precommit: `72 doctests, 31 properties, 3516 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0 (the phase's docs run, on this tree; also exit 0 after 6.3f).
- Tagged (`normandy-test-pg` started during 6.3f's gate, stopped at the end of the phase): Postgres `3583 tests, 0 failures (181 excluded)`; `--only distributed --include postgres` `76 tests, 0 failures`; Redis (extra) `3609 tests, 0 failures (155 excluded)`.
- Notes risk (`check_layout!/3` on a peer whose schema has not merged): full distributed run green; plus a throwaway peer probe (not committed): a peer that joined via `change_config(:extra_db_nodes, _)` then re-ran both Mnesia `create_tables/1` on the existing tables → `:ok` (the `{:already_exists, _}` → `check_layout!/3` path), and a second fresh peer joining and calling at once → `:ok`. A node calling `create_tables/1` before joining stays unexercised (pre-existing behaviour). Recorded in the section's Notes.
- Text correction (6.3i Step 7): distributed run needs Postgres (same cause as 6.3f Step 9); command updated.
- Text correction (Notes for the controller): the fenced-caller risk said 6.2d retries `:noproc`/`:normal`; H8 makes it `{:shutdown, :passivated}`/`:noproc` — reworded. The 6.3d-interplay note records N = 4.
- X10: `## 40.` received 6.3f (3 bullets), 6.3g (2), 6.3i (1), in task order after 6.3a–e's, before `## New, non-breaking`.

### Phase 4 end (6.3f–6.3i)
- `normandy-test-pg` started by this phase (6.3f gate) and stopped at its end; Redis was already running.
- Known flake recurred once (6.3f Redis run): `Normandy.Resilience.TelemetryTest` "a raise is typed by its module…", seed 131968, reproducible with that seed in this tree (foreign frames from `agent_process_server_test.exs:227`/`:400`). Not fixed.

### Task 6.4a — FIXED (X9)
- Commit: `2200fb3`. Red: `36 tests, 5 failures` as stated (3 parenting, 2 metadata `run :start` not received); "a rejected input's…" fails on the `Enum.all?(hooks, ...)` line, not a bare `:undefined` compare. Step 5: `2 doctests, 447 tests, 0 failures (8 excluded)`.
- Precommit: `72 doctests, 31 properties, 3523 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0.
- Tagged (not named by the section; asked by the dispatch): `normandy-test-pg` started; `--only distributed --include postgres` `76 tests, 0 failures`.
- X9 verified: no 6.2 exit runs with a turn context attached. The context is attached only by the `:idle` `{:turn, _, ctx}` clause (released on rejected/crashed admission, failed first write, `:finalize`, `:fail`) and by `start_resumed_run_span/1` (released by `:finalize`/`:fail`). `:loading` (`init/1`'s `:load` event runs before any call), the `:unavailable` clauses (reply or postpone, no attach), a load crash (`safe_load/1` in `:loading`), `:session_start` → `:unavailable` and `{:shutdown, :passivated}` (only from `:idle`/`:unavailable`, after release) attach nothing; no 6.2 transition leaves `:running`/`:awaiting_approval` except through `interpret/2`. One regression test added for the only 6.2 path a caller context travels through (a request postponed in `:unavailable` and replayed in `:idle`).
- Text correction (6.4.md, 6.4a Step 1): `start_hooked_turn_server/3` takes an optional store; new X9 test "a turn replayed after an :unavailable load runs in the caller's context and releases it" (uses 6.2a's `FlakyStore`); alias line change (credo `AliasUsage` flagged the nested name in my first precommit, exit 2).
- Text correction (6.4a Step 2/5): stacked counts; 5 new span-hierarchy tests.

### Task 6.4b — PASS
- Commit: `4201ada`. Red as stated (`41 tests, 13 failures`: RunUsage 4 `UndefinedFunctionError`, run_totals 7, summarizer 1 `usage` key, logging 1 `left: 2`). Step 7: `46 doctests, 6 properties, 1365 tests, 0 failures (8 excluded)`.
- Precommit: `74 doctests, 31 properties, 3535 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0.
- Every before-snippet matched stacked (6.1b's `request_messages_for/2` and 6.2e's slim worker do not touch these lines; `call_llm_event/3` passes the `request` through unchanged). No tagged suite (per section).
- No text corrections.

- **Follow-up X12 (phase 6)** — commit `4a11f18` `preflight: Task 6.4b follow-up`. Checked: a `before_llm` hook receives only `%{final:, iterations_left:}` (`Normandy.Hooks.Handlers.before_llm!/3`) and returns `:cont`/halt, so it can neither see, drop nor replace `:run_usage`. Where the key is: BaseAgent's `with_run_usage/2` sits *inside* `HookHandlers.wrap/2`, so the hook-time request has no `:run_usage`; Turn.Server puts it on the request before `ServerGlue.before_llm/4`, but only the info map reaches hooks. A host's Turn.Server `:handlers` `call_llm` gets the key (harmless). No code change; documented and pinned. New describe "before_llm hooks and the run accumulator" (run/3, stream/3, Turn.Server: hook info keys exactly `[:final, :iterations_left]` + the totals). Negative control: with the hook info merged into the request, all three fail (`left: [:final, :iterations_left, :response_model]`, Turn.Server also `:run_usage`). Precommit `74 doctests, 31 properties, 3554 tests, 0 failures (248 excluded)`, credo clean (after an alias-order fix, exit 4 first), dialyzer passed, exit 0.
- Text correction (6.4.md 6.4b): intro paragraph stating what hooks see; Step 1 adds the describe + `Config`/`TestHooks`/`Probe` aliases; Step 2 red count 13 → 16 (`run_totals_test.exs` 10, by reasoning: the three new tests fail on the same totals assertion as the existing three — not re-observed on pre-6.4b code); Step 7 `run_totals_test.exs` "8 tests" → 10 (it had 7, the 8 was already wrong).

### Task 6.4c — FIXED (X2)
- Commit: `e316222`. Red: `259 tests, 10 failures`, the ten stated (runner, guardrails, memory ×3, server_test, usage "lifecycle lines are :debug", guardrails agent ×2, span hierarchy RF#5). Step 7: `4 doctests, 6 properties, 1404 tests, 0 failures (8 excluded)`.
- Precommit: `74 doctests, 31 properties, 3540 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0.
- Tagged: Redis `74 doctests, 31 properties, 3633 tests, 0 failures (155 excluded)`; `--only distributed --include postgres` `76 tests, 0 failures`; Postgres first run `3607 tests, 1 failure (181 excluded)` (seed 775477, **reproduces** with that seed): `BaseAgentStreamErrorLogTest` "a failed stream's exception telemetry ... is not logged" — `refute log =~ "[error]"` caught a foreign `[error] GenServer ... terminating ** (stop) exited in: GenServer.call(:reapsup_N, :horde_shutting_down, 5000) ** (EXIT) killed` (Horde.SignalShutdown), logged asynchronously after `resume_reaper_integration_test.exs`'s `on_exit` `Process.exit(sup_pid, :kill)` (a sync `:postgres` module; ordering-dependent). Not a 6.4c file or behaviour (the `[error]` is Horde's; 6.4c's level change only turned the test's own lifecycle lines to `[debug]`); fresh run `3607 tests, 0 failures`. Not fixed; new cross-test log flake, recorded as a risk.
- Known flake (seed 131968): `mix test.redis --seed 131968` on this tree → `3633 tests, 0 failures` (test order changed with the new tests; 6.4c's `:debug` lines do not reach that test's `capture_log` at its level). Nothing to record beyond that.
- X2: 6.2a's `Describe.reason_term/1` exists; 6.4c's fallback definition dropped from Step 3. It walks tuples (`{:http_error, %{...}}` → `{:http_error, "a map"}`), unlike the section's assumed "tagged tuple → its atom": the `LeakyCreds` server test now expects `{:credential_unavailable, LeakyCreds, {:http_error, "a map"}}`; the Step 5 comment, Interfaces and the MIGRATING bullet reworded (pointer to `## 39.`'s identical rule).
- Ruling: the memory tool keeps the section's own text describer (`safe_reason/1`: plain atom/integer terms whole, exception module, `Postgrex.Error (:code)`, else `Describe.reason_tag/1`), not `reason_term/1` — its output is model- and log-facing text with a cut to the tag (`:http_error`, `a string (500 bytes)`), which the section's tests and MIGRATING pin; routing it through `reason_term/1` would need a new term-to-text formatter and change those texts — cost if wrong: two describers with slightly different tuple rules (credential/store replies walk tuples; the memory text cuts to the tag); a one-function swap later.
- Text correction (6.4c Step 5): `grep -c "backend(reason)"` → 13 (12 calls + the `defp` head), not 12.
- Text correction (6.4c Tagged suites, Step 8): distributed run needs Postgres (same cause as 6.3f Step 9); commands updated.
- Text correction (6.4c Step 2): stacked count.

### Task 6.4d — FIXED
- Commit: `b5fe58f`. Red: `43 tests, 4 failures` as stated (2 `KeyError :status`, baggage `left: %{"tenant" => ..., "user_id" => ...}`, catalogue `search_memory`); executor TEL-9 test passes before and after. Step 4: `46 doctests, 627 tests, 0 failures`.
- Precommit: `74 doctests, 31 properties, 3545 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0. No tagged suite (per section).
- Text correction (6.4d Step 3, `workflow_span.ex`): the before-snippet ended at `` `:step_count`).`` mid-line (the line goes on "It never carries input, ..."); before/after rewritten to whole lines.
- Text correction (6.4d Step 3, `a2a/server.ex` doc and the "W3C propagation" bullet): both anchors end mid-line; notes added to keep the rest of the line (reflow).
- Text correction (6.4d Step 2): stacked count.

### Task 6.4e — FIXED (X3, X2)
- Commit: `f5a6dc6`. Red: `6 tests, 6 failures` as stated. Step 7: `46 doctests, 705 tests, 0 failures (8 excluded)` (after the two fixes below; first run `1 failure` each time, see them).
- Precommit: `74 doctests, 31 properties, 3551 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0.
- Tagged: Redis `74 doctests, 31 properties, 3644 tests, 0 failures (155 excluded)`; Postgres `3618 tests, 0 failures (181 excluded)`; `--only distributed --include postgres` `76 tests, 0 failures`.
- X3: Step 4 rewritten as a diff against 6.2f's code (`reap_session/2` keeps its name, doc and catch; `Stream.run()` → `Enum.map/2` of the `{:ok, outcome}` elements; `not_running?/3`/`non_terminal?/3` → `registry_check/3`/`turn_check/3` returning atoms; the catch returns `:failed`). Counts come from the task results: the 6-session sweep test (all six under one `Task.async_stream` with `max_concurrency: 16`) gets `scanned: 6, started: 1, skipped: 2, failed: 3`; 5 consecutive runs of the module green.
- X2 (again): the sweep `:error` reason is `Describe.reason_term({:store_down, "detail"})` = `{:store_down, "a string (6 bytes)"}`, not `:store_down`; test expectation, test name, the catalogue `reason` text (two events) and the MIGRATING bullet reworded ("reduced", with the walked-tuple rule; the catalogue text names no hidden module).
- Text correction (6.4e, new Step 4g): the new async sweep test logs "failed to resume s-boom: :boom" on purpose; `resume_reaper_test.exs` "the supervisor-nested race shape is retried too" (async, `refute log =~ "failed to resume"`) failed on it in the Step 7 run. The five `refute ... "failed to resume"` and two `refute ... "unexpected start_server"` in `describe "the via-registration race"` are narrowed to their own session (`s-race`). The new test's start-error session is renamed `s-boom` → `s-refused` (`{:error, :refused}`) so it adds no "boom" line for `runner_test.exs`'s three `refute log =~ "boom"` (a pre-existing collision with `resume_reaper_test`'s own `:boom` line remains).
- Ruling: narrow the existing over-broad refutes rather than make `OperationalEventsTest` `async: false` — the refutes are the fragile side (any async test logging a resume failure breaks them) — cost if wrong: none functional; a refute that names `s-race` misses a "failed to resume" line for another session in the same sweep, which those tests never have.
- Text correction (6.4e Tagged suites, Step 8): distributed run needs Postgres; commands updated. Step 2/7 stacked counts.
- Intermittent failure after the commit, then explained: one of three runs of `operational_events_test.exs resume_reaper_test.exs runner_test.exs` together reported `51 tests, 1 failure` (output not kept); reproduced on the 3rd of a new loop (seed 996861): `Normandy.Hooks.RunnerTest` ":on_error :open on before_tool and after_tool logs and passes the value on" — `refute log =~ "boom"` caught `resume_reaper_test.exs`'s own `ResumeReaper: failed to resume s-race: :boom` (both modules async). Pre-existing (that reaper test and those refutes predate Wave 6); 6.4e's rename of `s-boom` keeps it from adding a second source. Not fixed here; recorded as a risk. (The same capture also holds the Runner's `[error] hook ... crashed` line with `test/support/hook_probes.ex:59` frames, the kind of foreign frame the known `Resilience.TelemetryTest` flake trips on.)

### Phase 5 end (6.4a–6.4e)
- `normandy-test-pg` started by this phase (6.4a's distributed run) and stopped at its end; Redis was already running.
- X10: `## 41. Telemetry and logs` created by 6.4a after `## 40.`, before `## New, non-breaking`; 6.4b, 6.4c, 6.4d appended to it in order; 6.4b, 6.4d, 6.4e appended to `## New, non-breaking`.
- X8: the 6.4 test doubles that reach memory (`metadata_test.exs` `UserAppendFailStore` turns, `run_totals_test.exs` `FakeTool`/`WireScript`/`StubClient`, 6.4a's hooked servers) ran green in every precommit; no new `BaseIOSchema` impl needed.
- `mix docs --warnings-as-errors` exit 0 after 6.4b, 6.4d and 6.4e.
- Test-isolation risks seen this phase (none caused by a 6.4 code change): `BaseAgentStreamErrorLogTest` vs a killed Horde supervisor's async `[error]` (Postgres suite, seed 775477); `RunnerTest` `refute log =~ "boom"` vs `ResumeReaperTest`'s `:boom` line (seed 996861 in a 3-file run). The known `Resilience.TelemetryTest` seed-131968 flake did not reproduce on this tree.

### Task 6.5a — FIXED
- Commit: `57ca13f`. Red as stated (`8 tests, 2 failures`: `UndefinedFunctionError ... __loaded__?/1`; `assert OtelCtx.capture() == nil`, left `%{}`). Step 4: `63 tests, 0 failures`; `otel_ctx_test.exs` 8 tests.
- Precommit: `74 doctests, 31 properties, 3556 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. `mix docs --warnings-as-errors` exit 0. No tagged suite (per section).
- X10: `## 42. AgentProcess and coordination` created after `## 41.`, before `## New, non-breaking`.
- Text correction (6.5.md 6.5a Step 3): `grep -c "Code.ensure_loaded?"` after the step is 2, not 1 (the inserted `__loaded__?/1` comment line names it too).

### Task 6.5b — FIXED (X4)
- Commit: `3cbec8d`. Red as stated (`53 tests, 4 failures`: two `Task.await` time outs, `BadMapError`, the direct-child `left:`). Step 4: `85 tests, 0 failures`.
- Precommit: `74 doctests, 31 properties, 3561 tests, 0 failures (248 excluded)`, credo no issues (after one run with exit 2: 3 `AliasUsage` on the new test's nested `Normandy.Test.CountingContent`), dialyzer passed (40 skipped), exit 0. No tagged suite (per section).
- X4: 6.1a's real `delete_turn/2` already strips through its private `strip_thinking/1` (`put_content/2` only when `has_thinking?/1`), which the section (written on `d624fbf`) did not know. The section's `put_content(entry, drop_thinking(entry.content))` compiles and passes the section's tests, but re-encodes every survivor below the deleted turn (a 20 000-entry delete → 19 999 `to_json/1` calls), against R1's encode-once rule.
- Ruling: Step 3 calls `strip_thinking(entry)` — keeps 6.1a's no-re-encode behaviour; cost if wrong: none (same content result; only skips a no-op re-encode).
- Text correction (6.5.md 6.5b intro, Interfaces, Step 1, Step 3): the `strip_thinking/1` line and prose; new test "survivors without thinking keep their cached term (nothing re-encoded)" (`CountingContent`, passes before and after; negative control with `put_content/2` on every survivor: `left: 5, right: 3`) + `alias Normandy.Test.CountingContent`.

### Task 6.5c — PASS
- Commit: `c774419`. Red as stated (`8 tests, 8 failures`, each with the stated error; "stop/1 kills the turn in flight" hits the 60 s ExUnit timeout). Step 6: `42 doctests, 546 tests, 0 failures`; queue + `agent_process_test.exs` 5 consecutive runs `34 tests, 0 failures`.
- Precommit: `74 doctests, 31 properties, 3569 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. No tagged suite (per section).
- Every before-snippet matched stacked (`agent_process.ex`, `turn_error.ex`, `options.ex`, `killed_run.ex` are untouched by 6.1–6.4). X8: the gated `StubClient` replies are `BaseAgentOutputSchema`s (encodable). No text corrections.

### Task 6.5d — FIXED (X8)
- Commit: `b8f8d3b`. Red as stated (`10 tests, 9 failures`, each as listed; "a reply_to name that is not registered..." passes before). Step 5: `42 doctests, 575 tests, 0 failures` (after the X8 fix; first run 1 failure, below). Pending + queue + `agent_process_test.exs` + `agent_process_server_test.exs` 5 consecutive runs `63 tests, 0 failures` (incl. Review Focus 4's 100 casts).
- Precommit: `74 doctests, 31 properties, 3579 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (40 skipped), exit 0. No tagged suite (per section).
- X8: the test's `:server`-mode output double `Resp` had no `BaseIOSchema` impl; with 6.1a's encode-at-append the Turn.Server turn replied `{:error, %TurnError{type: :handler_crashed, handler: :append, reason: %Protocol.UndefinedError{...Resp...}}}` (":server: the run or cast past the limit is refused at once", `Task.await(run)`). Text correction (6.5.md 6.5d Step 1): `defimpl Normandy.Components.BaseIOSchema, for: Resp` (`to_json` = content, `get_schema` = `%{}`, the shape of the other `Resp` doubles).
- Text correction (6.5d Step 3): the `:session_unavailable` bullet's last line is 6.3e's `Turn.Session.delete/1` sentence (`` (`reason: {:not_stopped, :not_found}`) ``) on the stacked tree, not the `approve/2` line; anchor reworded.
- 6.4b cross-check: `AgentProcess` `:server` mode passes `:handlers` to Turn.Server; a custom `call_llm` there opens no llm_call span, so the run `:stop` reports `llm_calls: 0` (pinned by 6.4b's "a custom call_llm handler opens no llm_call span..."). 6.5d changes nothing in that path; no test of 6.5 asserts run totals.

### Task 6.5e — FIXED (X8)
- Commit: `35fa0e3`. Red (after the X8 fix below) as stated: `22 tests, 4 failures` — three `MatchError` on the `{ScopedRegistry, ...}` pattern, "creates no atom" `left: 35497, right: 35346` (151 more, not "about 184"; 50 starts × 3). Step 5: `42 doctests, 396 tests, 0 failures`.
- Precommit: `74 doctests, 31 properties, 3582 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (`Total errors: 42, Skipped: 42` — two more than before, both skipped by the repo's `~r"is a supertype of the success typing"` entry: `ScopedRegistry.new/0`'s `{atom(), reference()}` and `registry_name/0`'s `atom()` specs; no ignore-file change), exit 0. Distributed (`normandy-test-pg` started): `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres` `76 tests, 0 failures`.
- X8: the registry test's `Resp` double had no `BaseIOSchema` impl; first red run "two processes with the same agent id..." failed on `{:error, ...}` (Turn.Server `:handler_crashed` `:append`) instead of the stated `MatchError`. Text correction (6.5e Step 1): `defimpl Normandy.Components.BaseIOSchema, for: Resp`.
- Text correction (6.5e Step 2): atom delta ~150. Step 6: the distributed command with the Postgres env and `--include postgres` (same cause as 6.3f/6.4c).
- 6.3f check: the Redis registry handle struct and caller-side `whereis` do not touch `SessionRegistry`'s four callbacks; `ScopedRegistry` implements `whereis/2`, `register/3`, `unregister/2`, `child_name/2` (`:self_register`) and Turn.Server's 6.2c `{:error, :taken}` path is unchanged.

### Task 6.5f — FIXED (X7/H9)
- Commit: `375d340`. Red as stated (`101 tests, 8 failures`: `:lifo`/`:fifo`, StatefulContext `:protected`, the five HierarchicalCoordinator shapes; the workflow test passes already) plus X7's atom test (below). Step 7 after the follow-up below: 6 runs of `mix test test/coordination/ test/dsl/ test/guardrails/ test/telemetry/killed_run_test.exs` → 5× `42 doctests, 583 tests, 0 failures`, 1× the pre-existing `AgentProcessTest` wall-clock flake (below).
- Precommit (on the tree with 6.5f and the 6.5c/d follow-up): `74 doctests, 31 properties, 3590 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (42 skipped), exit 0.
- Anchors: 6.4e's `:checkout` event left `do_checkout/1`'s second clause as the section expects; every other before-snippet matched stacked.
- X7/H9 verified: `create_conditional_specs/2` called `String.to_atom(worker.id)` on every `:conditional` run; a fresh worker id run through it left an atom (`String.to_existing_atom(id)` did not raise — red of the new test). Worker ids are host-supplied, so a host building coordinators with per-request ids leaks an atom per id. Fixed with `plan_task/2` (string key, else an atom key matched by `Atom.to_string/1`; no atom created). Tests: ":conditional creates no atom from a worker id" (red before, green after) and ":conditional reads a task under the worker id as an atom key" (passes before and after; pins the atom-key lookup). Text correction (6.5.md 6.5f): intro, Files, Step 1 tests, Step 2 count 5 → 6, Step 5 new item, Step 9 MIGRATING bullet, Notes "Left open" paragraph.
- Ruling (X7): match atom keys by name instead of `String.to_existing_atom/1` with a rescue — no exception as control flow, keeps the original string-first precedence — cost if wrong: O(plan size) scan per worker on a miss (plans are small).
- **Follow-up `476f22c` `preflight: Tasks 6.5c/6.5d follow-up`** (test files only): with `test/dsl/` and `test/guardrails/` in the same run, the 6.5c/6.5d gate tests failed about 1 run in 2 (pre-6.5f: on `35fa0e3` + reverted 6.5f WIP, 4 of 5 runs failed: "runs execute one at a time..." ×2, "a queued run whose caller died...", "an exit in the cast's turn...", ":server workers stop/1..."; seeds 928803, 207762, 513633, 983064; with 6.5f, seeds 312132, 889889, 323240, 735960), every time `Assertion failed, no matching message after 100ms ... The process mailbox is empty` on the first `assert_receive {:llm_started, 1, _}` (or an `{:agent_result, ...}`): ExUnit's default 100 ms. The worker always gets there (no lost message); it takes longer while async DSL tests compile modules (theory: unconsolidated-protocol dispatch and module loading wait on the code server; not proven). Fix: `@wait 5_000` on every `assert_receive` in `agent_process_queue_test.exs` and `agent_process_pending_test.exs`; then 6 loaded runs, 0 gate failures. Text correction (6.5.md 6.5c and 6.5d Step 1): both test blocks replaced by the committed files (`@wait` with its comment). Not separately precommit-gated (gated together with 6.5f's precommit above).
- New flake recorded, not fixed (pre-existing, on `d624fbf` too): `AgentProcessTest` "async execution doesn't block GenServer" — `assert end_time - start_time < 10` (`left: 11`), seed 559121 in the loaded Step 7 run. A 10 ms wall-clock bound on `get_stats/1` under a loaded suite; for Task 6.6.

### Phase 6 end (6.4b follow-up, 6.5a–6.5f) — final gate on `375d340`
- `mix precommit` (log `w6p6-gate-precommit.log` in the scratchpad): `74 doctests, 31 properties, 3590 tests, 0 failures (248 excluded)`, credo no issues, dialyzer passed (`Total errors: 42, Skipped: 42`), exit 0. `mix docs --warnings-as-errors` exit 0 (also after 6.5a).
- `mix test.redis`: `74 doctests, 31 properties, 3683 tests, 0 failures (155 excluded)` (seed 882156).
- Postgres (`normandy-test-pg` started in 6.5e, stopped at the end of this phase): `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` `74 doctests, 31 properties, 3657 tests, 0 failures (181 excluded)` (seed 651001).
- `mix test --only distributed --include postgres` (same env) twice: `76 tests, 0 failures` (seeds 946759, 413942).
- `mix hex.build --unpack` into the scratchpad (`w6p6/hex/normandy`): 172 files; no `investigations/`, no `priv/test_repo`; `lib/normandy/watched_worker.ex` and `lib/normandy/coordination/agent_process/scoped_registry.ex` included.
- Known flakes: none of the three listed (`Resilience.TelemetryTest` seed 131968, `BaseAgentStreamErrorLogTest` seed 775477, `runner_test` seed 996861) hit in this phase's runs. New: the 6.5c/6.5d gate tests' 100 ms `assert_receive` (fixed, `476f22c`); `AgentProcessTest` "async execution doesn't block GenServer" 10 ms wall-clock bound (seed 559121, not fixed).
- X10: `## 42.` created by 6.5a, appended by 6.5b–6.5f in task order, before `## New, non-breaking`. X8: three test doubles needed a `BaseIOSchema` impl (6.5d pending test `Resp`, 6.5e registry test `Resp`; 6.5c's StubClient outputs were already encodable).
