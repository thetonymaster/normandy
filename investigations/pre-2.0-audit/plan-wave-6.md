# Wave 6 — Performance and observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A conversation costs linear Normandy-side work per message, `Turn.Server` starts concurrently and survives store failures, cluster and store backends stop scaling with total history, telemetry tells a whole run's story inside the caller's trace without leaking data, and `AgentProcess` stops blocking its own mailbox.

**Architecture:** Each history entry carries its model-facing encoding and token estimate, computed once when content is set; request building, token counting and compaction read that cache. `Turn.Server` loads its session after `init/1` in a `:loading` state and treats a store exit as a failed write, never a crash; compaction is persisted as a snapshot entry in the existing history stream. Store backends move to one row per document/entry with counter rows; the session store keeps an index of sessions with a turn in flight. Run totals travel on the transient call request as a `:counters` accumulator. `AgentProcess` keeps `:inline` as default but runs turns from a FIFO queue in a watched worker.

**Tech Stack:** Elixir ~> 1.15, Claudio `~> 0.7.0` (Hex), NimbleOptions (through `Normandy.Options`), `:telemetry`, OpenTelemetry API (optional), Redix, Postgrex/Ecto SQL, Mnesia, ExUnit + StreamData.

**Spec:** `investigations/pre-2.0-audit/plan.md` § "Wave 6" (Tasks 6.1–6.5) and § "Review Focus"; decisions 6, 8a, 8b, 15, 21, 22, 23 **24** and **25** (Q's answers to Appendix A, all recommendations accepted) in `investigations/pre-2.0-audit/decisions.md`; findings PERF-3, PERF-4, PERF-6, PERF-7, PERF-8, PERF-10, PERF-12–PERF-16, A7, B1–B3, B5 in `perf.md`; TEL-3, TEL-5, TEL-7–TEL-16 in `telemetry.md`; SEC-14 in `security.md`; the July audit `investigations/performance-race-audit.md`. Decision 24 is Q's acceptance of every recommendation in `wave-6-research/QUESTIONS.md`; those answers are binding here and are listed under "Rulings against plan.md". The facts inventories behind this plan are `wave-6-research/6.1-history.md`, `6.2-server.md`, `6.3-cluster.md`, `6.4-telemetry.md`, `6.5-process.md` (verified against HEAD `d624fbf`). Section writers read the inventory for their group in full.

## Finding IDs closed by this wave

PERF-3/B1, B3 (by measurement), PERF-4, PERF-7, B2, PERF-6, PERF-8, PERF-10, PERF-12, B5, PERF-13, PERF-15, PERF-16, A7, SEC-14, TEL-3, TEL-5, TEL-7–TEL-16, the July leftovers listed per task, Wave 5 deferrals (Turn.Server compaction persistence, reaper `reap/1` concurrency), Wave 5 open items (memory-store reason in `memory/commands.ex`, credential reason in `TurnError`, Workflow DSL blank-answer example). Already fixed before this wave (no task; the gate task re-asserts with a test name): PERF-14 (`reactive_test.exs:75-158`), TEL-17, TEL-1/2/4/6, the reaper `inspect(reason)` log (`aaf5311`), Redis `whereis` transport errors. Moved out: `server_tool_use` after a failed pause → Task 7.6 live probe; AX-12, AX-18 retry, AX-19, AX-20, AX-29, AX-33 → 2.x known limits (listed in MIGRATING by Task 6.6); Claudio `Request.add_messages/2` → Claudio 0.7.1 (Task 6.1e prepares it; the Normandy switch rides Task 7.5's version bump).

## Global Constraints

- Elixir `~> 1.15` / OTP ≥ 24 (`format_status/1` is OTP 25+: guard it or also define `format_status/2`); no new dependencies.
- Every public function that takes options validates them with `Normandy.Options.validate!(opts, schema, {Mod, :fun, arity})`; an unknown option raises `ArgumentError` in the house style.
- No message, log line, telemetry metadata, tool result or persisted term contains a credential, a stacktrace, conversation content, SQL text or model text in an error `reason` (decision 6). Errors are logged by type/tag, never with `inspect(error)`.
- Every new telemetry event or metadata key is documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs` enforces it).
- Every user-visible change gets a bullet in `MIGRATING-2.0.md`, in the section its task owns (see "MIGRATING sections"), placed after `## 37.` and before `## New, non-breaking`; non-breaking additions go under `## New, non-breaking`.
- A change to message encoding, request building, the loop or run telemetry holds on **every** path: BaseAgent `run/3`, `stream/3`, `Turn.Driver`, `Turn.Inline`, `Turn.Server`. A new Turn core effect is wired into all three interpreters. Tests cover sync, `stream/3` and `Turn.Server` at minimum.
- **6.1 changes no wire byte and no token estimate.** Request bodies for the same scripted conversation are identical before and after: every value, every array in order, compared decoded (JSON object key order of atom-keyed maps is not stable between VM runs on OTP 26+, see H1). The fixture is recorded on unmodified `d624fbf` code as Task 6.1a's first commit. Task 6.1f (decision 25) changes the key order inside model-visible JSON text, never a value; the decoded fixture still holds. Exception: `tokens_removed` uses the cached model-facing estimate (H2).
- Store backend changes keep `test/support/session_store_contract.ex` / `memory_store_contract.ex` passing on every backend; a new rule goes into the contract, not one backend's test file.
- Tests are deterministic: no test depends on two processes racing; never `Process.sleep` to wait for a message (use `assert_receive`, `Normandy.Test.Eventually.wait_until/1`, `:sys.get_state/1` or a synchronous call). Concurrency is proven with gates (a counter of arrivals plus an explicit release), not timing. The one wall-clock assertion (Task 6.2b) has ≥5× headroom and lives in an `async: false` module next to its deterministic twin.
- Run `mix format` before every test run. A task is done only when `mix precommit 2>&1 | tee <log>` shows ` 0 failures` and exit 0, and `mix docs --warnings-as-errors` exits 0. Tasks that touch a Redis or Postgres backend, `Turn.Server` start paths, the registry or the reaper also run `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` (after `docker start normandy-test-pg`) and `mix test --only distributed`; the task text names which.
- Commits: add files individually (`git add <path>`; `git add .`/`-A` forbidden); no AI attribution of any kind in the message (no Co-Authored-By, no "Generated with"); never push.
- Never run a destructive command (dropping a database or table, `rm -rf`, `git reset --hard`) and never create or drop a database without the controller asking Q first. No step in this plan needs one. Postgres runs use the existing partition DB `normandy_test_w54probe`; a new migration is applied to it by `mix test.postgres`'s own migrate step.
- Do not edit `CLAUDE.md`. Proposed CLAUDE.md text goes to the controller in the task report; Task 6.6 collects it for Q.

## Task order

`6.1a → 6.1b → 6.1c → 6.1d → 6.1e → 6.1f → 6.2a → 6.2b → 6.2c → 6.2d → 6.2e → 6.2f → 6.2g → 6.3a → 6.3b → 6.3c → 6.3d → 6.3e → 6.3f → 6.3g → 6.3h → 6.3i → 6.4a → 6.4b → 6.4c → 6.4d → 6.4e → 6.5a → 6.5b → 6.5c → 6.5d → 6.5e → 6.5f → 6.6 (gate)`

Section writers may split or merge lettered sub-tasks inside their group; the group order is fixed. Files touched by several groups, in order: `turn/server.ex` (6.2a–g, 6.3c `persist_turn_state/2` only, 6.4a/b/c/e), `components/agent_memory.ex` (6.1a–c, 6.2e `without_entries/1`, 6.2g `from_entries/1`, 6.5b `delete_turn/2`), `agents/base_agent.ex` (6.1b, 6.4b, 6.4c), `turn/resume_reaper.ex` (6.2f, 6.3e, 6.4e), `turn/session.ex` (6.2c, 6.2d, 6.3e), `session_store/*.ex` (6.2g contract only, then 6.3a–e), `coordination/agent_process.ex` (6.5c–e), `coordination/agent_pool.ex` (6.4e, 6.5f). Write each edit against the header's description of the earlier change and anchor on function names, not line numbers.

### Group content (from the inventories' task splits, adjusted by the rulings)

- **6.1a** Request-body fixture recorded first (own commit), `Normandy.Test.CountingContent`, entry cache: `wire`/`tokens` on `%Entry{}`, private `put_content/2`, `history/1` and the conversation estimate read the cache, `from_entries/1`/`load/1` fill it, `ConfigTemplate` strips/refills it. **6.1b** `AgentMemory.request_messages_for/2` (one walk, stale-thinking drop on the cached term) used by both BaseAgent builders (`TokenCounter` unchanged, H3); the `to_json`/`drop_thinking` equivalence property. **6.1c** Compactor single estimate, cached `tokens_removed`, `AgentMemory.keep_entries/3` for WindowManager and Summarizer rebuilds. **6.1d** Acceptance counting tests (run, stream, Turn.Session, compactor, tools). **6.1f** (decision 25, A1) the model-facing encoding sorts plain-map keys recursively. **6.1e** `enable_caching` default `true` (adapter option default, docs, MIGRATING) and the Claudio-side `Request.add_messages/2` patch on a local branch of `/Users/antonio/personal/claudio` (see R2).
- **6.2a** `store_call/1` (exits → `{:error, {:store_exit, reason}}`), `safe_load/1`, `retry_load/1` catches, session-store load reasons described by tag, `format_status` hiding the conversation, batch-completeness assertion before the next LLM call (July LOW). **6.2b** Load after `init/1` (`:loading` state), `Normandy.Test.GatedStore`, concurrency + timing tests. **6.2c** `register_self` `:taken` → `{:stop, {:already_started, pid}}`; `Turn.Start` race clause. **6.2d** Passivation retry in `Session.run/2`. **6.2e** B2 slim worker copies (Turn.Server only), `AgentMemory.without_entries/1`. **6.2f** ResumeReaper concurrent `maybe_start` (`@reap_concurrency 16`), crash-safe per session. **6.2g** Compaction snapshot entry.
- **6.3a** Redis/Postgres store leftovers (fork UUID, `pipeline_ok/1`, pipelined `copy_prefix`, Postgres ancestry by ids). **6.3b** B5: `SessionStore.ETS` one row per entry. **6.3c** `save_turn_state/4` + in-flight `list_resumable/1` on all five backends (Postgres migration module `MigrationAddInflight`), `persist_turn_state/2`, stubs, call sites, guide, MIGRATING. **6.3d** `delete_session/2` on all five backends, contract delete rules (Review Focus 1), Postgres fork `FOR SHARE`, InMemory fork copies only the chain. **6.3e** `Turn.Session.delete/1`, `stop_server/2` on both supervisors (H5). **6.3f** PERF-6 caller-side `whereis` with the handle struct, batched `EVALSHA` refresh, ownership fencing. **6.3g** PERF-12 `WAIT` connection pool. **6.3h** PERF-10 ETS per-document rows on a shared `MemoryStore.Rows`. **6.3i** PERF-10 Mnesia per-document rows.
- **6.4a** Turn.Server trace context for admission/`on_turn_end`/`close_batch` hooks and failed-run spans (TEL-3, TEL-12). **6.4b** Run totals (TEL-7), `usage: nil` (TEL-10), `get_response/2` span (TEL-11). **6.4c** Logs and redaction (TEL-8, TEL-4 residual, TEL-5 incl. `guardrails.ex`, Wave 5 items 1 and 2). **6.4d** TEL-9 (doc + pinning test), TEL-13, TEL-14, TEL-15. **6.4e** TEL-16 events.
- **6.5a** `OtelCtx` probe cache (PERF-16). **6.5b** `delete_turn/2` linear with a cycle/dangling-parent guard (PERF-15). **6.5c** Inline FIFO run queue, `run/3` timeout `:infinity` (A7, PERF-13). **6.5d** Casts through the queue, `:max_pending_runs`, `:queue_full` (SEC-14). **6.5e** Shared scoped registry (atom leak). **6.5f** Leftovers: Workflow DSL doc, AgentPool `:lifo`/`:fifo`, `StatefulContext` docs + `:protected`, `SharedContext` doc, HierarchicalCoordinator error shape, `reactive.ex:475` pid-branch timeout, B6 guardrail cost doc.
- **6.6** Wave gate (written by the controller): full gate, tagged suites, `hex.build`, MIGRATING known-limits list for the deferred AX items, CLAUDE.md proposals for Q, records.

## Shared interfaces (exact names; every task uses these)

| Name | Owner | Shape |
|---|---|---|
| `%AgentMemory.Entry{wire: nil, tokens: nil}` | 6.1a | Derived, never persisted: `wire` = `AgentMemory.model_content(content)` (string or block list), `tokens` = `Normandy.Context.WindowManager.estimate_message_content_tokens(wire) + 10`. Set only through private `put_content/2`. Readers use `Map.get(entry, :wire) || model_content(entry.content)` (pre-field terms). `ConfigTemplate` stores entries with both `nil` and `rebuild/3` refills them. An unencodable content raises at append (R1). |
| `AgentMemory.request_messages_for(memory, prefix_key)` | 6.1b | `@doc false`; one chain walk → request messages, applying the stale-thinking verdict to the cached `wire` and merging tool runs exactly as `request_messages/1`. `drop_stale_thinking/2`, `history/1`, `request_messages/1` stay public and unchanged. |
| `AgentMemory.keep_entries(memory, kept_entries, opts)` | 6.1c | `@doc false`; one-pass rebuild from kept `%Entry{}`s (re-links `parent_id`, strips thinking via `put_content/2`). |
| `Normandy.Test.CountingContent` | 6.1a | Test-support struct + `BaseIOSchema` impl counting `to_json/1` calls in a `:counters` ref. |
| `Normandy.JSON.sort_keys(term)` | 6.1f | `@doc false`; every plain map, at any depth, becomes a `Jason.OrderedObject` with its keys sorted by their JSON text; structs as `Normandy.JSON`'s struct rule (not sorted); an `OrderedObject` keeps its order, its values walked. Used by `ToolResult.render_output/1` and `BaseIOSchema`'s `Map` impl only. |
| `client.options[:enable_caching]` default `true` | 6.1e | ClaudioAdapter; `false` opts out. |
| `{:error, {:store_exit, reason}}` | 6.2a | Turn.Server-internal wrapper for a store call that exited; surfaces as `%TurnError{type: :persist_failed, reason: {:store_exit, reason}}` (in-turn writes) or `:session_unavailable` (loads). Store raises still raise mid-turn; during the load everything is caught (R5). |
| `Turn.Server` state `:loading` | 6.2b | Entered only by `init/1`, left in the `:internal :load` event to `:idle` or `:unavailable`. |
| `Normandy.Test.GatedStore` | 6.2b | Test support wrapping InMemory: counts arrivals in `history/2`, blocks until released. |
| `{:error, {:already_started, pid}}` from `Turn.Server.start_link/1` / `Turn.Supervisor.start_server/2` | 6.2c | A racing duplicate start under a self-registering registry; `{:stop, :registration_race}` when the winner died in between (retried by `Turn.Start`). |
| `AgentMemory.without_entries(memory)` | 6.2e | `@doc false`; keeps `head` and `current_turn_id`, drops entries. Turn.Server tool tasks only (BaseAgent unchanged, R6). |
| History entry `role: "compaction"` | 6.2g | `content: %{version: 1, entries: [%{id, turn_id, role, content}]}` = the full post-compaction chain; appended after a successful compaction; `AgentMemory.from_entries/1` applies the **last** one and never keeps it in memory. A failed snapshot write logs by tag and continues. |
| `SessionStore` callbacks `save_turn_state(handle, sid, state, inflight?)` (6.3c) and `delete_session(handle, sid)` (6.3d) | 6.3c/d | `save_turn_state/4` replaces `/3`: `inflight?` = `resume_policy == :eager and resumable?(state)`, written atomically with the state; `list_resumable/1` returns only in-flight sessions. `delete_session/2` is idempotent (`:ok` for a missing session), removes turn state, template, index membership and entries no other session reaches (fork-shared entries stay). |
| `Normandy.Agents.Turn.Session.delete(session)` | 6.3e | Public; stops the live server through the supervisor, then `store.delete_session/2`. Races with a concurrent `run/2` are documented. |
| `%Normandy.Behaviours.SessionRegistry.Redis.Handle{owner:, conn:, namespace:}` | 6.3f | Via term `{handle, sid}`; `whereis` runs in the caller on `conn`; exits → `{:error, _}`. |
| `[:normandy, :session_registry, :ownership_lost]` | 6.3f | Emitted when refresh finds a key it owned taken by another node; the local server stops with `{:shutdown, :registration_lost}`. |
| `SessionStore.Redis.new/1` option `:wait_connections` | 6.3g | `pos_integer`, default `4`; a waited write and its `WAIT` run on connection `:erlang.phash2(session_id, k)`; `Cluster.redis_child_specs/1` starts the pool when `config :normandy, :redis_wait` asks for replicas; `:store_redix` overrides. |
| `Normandy.Behaviours.MemoryStore.Rows` | 6.3h | `@moduledoc false`; CAS, limit, rename and tree rules over `fetch/2`, `put/3`, `delete/2`, `range/2`; implementations ETS (6.3h) and Mnesia (6.3i). Totals row key `{ns, 0}`. |
| `Normandy.Telemetry.RunUsage` | 6.4a/b | `@moduledoc false`; `new/0`, `add(acc | nil, stop_meta)`, `stop_metadata(acc)`; carried as `request[:run_usage]`; summaries not counted. |
| Run stop metadata keys `llm_calls`, `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens`, `iterations`, `stop_reason`, `finish_reason` | 6.4b | Token keys only when some call reported them. |
| Workflow stop metadata `status: :ok | :error` | 6.4d | |
| Events `[:normandy, :turn, :unavailable]`, `[:normandy, :resume_reaper, :sweep]`, `[:normandy, :agent_pool, :checkout]` | 6.4e | As in `6.4-telemetry.md` §2 TEL-16. |
| `Normandy.Components.ContentBlock.Describe.reason_term/1` | 6.2a | Reduces an error reason to a tag term with no data (a `{Postgrex.Error, code}` clause gives the SQLSTATE); reused by 6.4c for the credential and memory-store reasons. |
| `Turn.Supervisor.stop_server(sup, pid)` / `Turn.Supervisor.Horde.stop_server/2` | 6.3e | `:ok | {:error, :not_found}`; a custom `:supervisor_mod` needs it only for `Session.delete/1` (else `ArgumentError` naming the module). |
| `SessionRegistry.Redis.handle/1`, `fetch_handle/1`; `Normandy.Cluster.redis_handles/1` | 6.3f | Pure handle constructor; one call to a running owner; `%{registry: {SessionRegistry.Redis, h}, store: {SessionStore.Redis, h}}` from `redis_child_specs/1`'s options. `ownership_lost` measurement `count: 1`, metadata `session_id`, `registry`. |
| `SessionStore.Redis` handle `{conn, ns, wait, wait_conns}`; `redis_child_specs/1` `:wait_connections`; `@doc false SessionStore.Redis.app_env_wait!/0` | 6.3g | `{conn, ns}` and `{conn, ns, wait}` keep working. |
| `MemoryStore.Mnesia` attributes `[:key, :value]`, `:ordered_set`; `MnesiaSetup.create_table!/5` | 6.3i | An existing table of another layout raises. |
| Sweep metadata `store`, `status`, `reason`; checkout metadata `pool` | 6.4e | Additions to the TEL-16 events (H7). |
| `Normandy.WatchedWorker`; `Normandy.Coordination.AgentProcess.ScopedRegistry` (registry `Normandy.Coordination.AgentProcess.Registry`) | 6.5c, 6.5e | Both `@moduledoc false`. |
| `AgentProcess.start_link/1` option `:max_pending_runs` | 6.5d | `pos_integer | :infinity`, default `100`; over → `{:error, %TurnError{type: :queue_full}}`. |
| `TurnError` type `:queue_full` | 6.5d | Added to `@types`. |
| `AgentProcess.run/3` `:timeout` default `:infinity` | 6.5c | |

## MIGRATING sections

`## 38.` History, encoding and caching (6.1) · `## 39.` Turn.Server start, store failures and compaction persistence (6.2; replaces §35's known-limit paragraph) · `## 40.` Session stores, registry and memory stores (6.3) · `## 41.` Telemetry and logs (6.4) · `## 42.` AgentProcess and coordination (6.5) · Task 6.6 adds `## Known limits of 2.0` (AX-12, AX-18 retry, AX-19, AX-20, AX-29, AX-33, SEC-8 HMAC, the deferred `server_tool_use` probe) unless one exists.

## Rulings against plan.md (decision 24)

- **R1 (6.1)** Acceptance reads "Normandy-side message encodings are O(N) in total over N turns" (the HTTP body is inherently re-encoded per call); proven by counting `to_json/1` calls, plus byte-identical request bodies. The cache lives on `%Entry{}` (6.1 Q1 a). An unencodable content raises at append; on Turn.Server that is `:handler_crashed` (`:append`) instead of `:task_down` — MIGRATING line (6.1 Q2 a).
- **R2 (6.1)** Claudio's quadratic `Request.add_message/3` is fixed in Claudio 0.7.1 by a bulk `Request.add_messages/2`. Task 6.1e writes and tests that patch on a local branch `feat/add-messages` in `/Users/antonio/personal/claudio` (commit, never push, never publish); Q publishes 0.7.1 with the citations patch; Task 7.5 switches `claudio_adapter.ex` `add_messages/3` to it with the version bump. Until then the Normandy-side request build stays quadratic in Claudio only.
- **R3 (6.1)** B3 is closed by the measurement (≈25 µs per call; a cached prompt is impossible while context providers run on every build). No code (controller ruling on 6.1 Q4, which recommended "(a) or (b)").
- **R4 (6.1)** `enable_caching` defaults to `true` in 2.0 (6.1 Q5 ii), MIGRATING line with the cost note; AX-12, AX-19, AX-20 stay deferred.
- **R5 (6.2)** Store exits are caught for in-turn writes and best-effort persists; during the load every raise, exit and throw is caught (a crash there is a restart loop). The reply for a load crash is the bare normalized exception inside `:session_unavailable` (6.2 Q3, Q4). Session-store load reasons are described by tag like the credential reason (controller ruling on 6.4 Q8's open sub-question: yes, in 6.2a).
- **R6 (6.2)** B2 slims Turn.Server's worker and tool-task copies only; BaseAgent's classify-in-task stays (6.2 Q1 a). `format_status` shows ids and state names only (6.2 Q5). Timing acceptance: default suite, `async: false`, plus the gated deterministic test (6.2 Q2).
- **R7 (6.2)** Compaction persistence = snapshot entry with log-and-continue on a failed snapshot write (6.2 Q7 a, 6.1 Q6 a). `server_tool_use` after a failed pause: no code; Task 7.6 probe (6.2 Q6 a). Reaper concurrency is a module attribute (6.2 Q9); the reaper owns it in 6.2f, so 6.3 does not touch `reap/1` concurrency.
- **R8 (6.3)** Eager index = sessions with a turn in flight, via `save_turn_state/4` (6.3 Q3 B); `delete_session/2` keeps fork-shared entries (Postgres one transaction; Mnesia full scan, documented O(entries)) (6.3 Q4 a); `Turn.Session.delete/1` (6.3 Q5); no index backfill — MIGRATING says drain eager sessions before upgrading (6.3 Q7). The Redis registry handle becomes a struct (6.3 Q1 a); refresh fences lost ownership (6.3 Q2 a); `WAIT` uses a store-owned pool with `:store_redix` override (6.3 Q6 a). B5 is owned by 6.3b (6.5 Q11).
- **R9 (6.4)** Run usage via `RunUsage` on the call request; compaction summaries are not counted (documented) (6.4 Q1 a). Turn.Server admission attaches the caller context only; `on_prompt` is a sibling of run (6.4 Q2). Lifecycle logs `:debug`, `IO.warn` → `Logger.warning` (6.4 Q3). `get_response/2` gets an llm_call span (6.4 Q4). Inbound A2A baggage dropped, outbound kept (6.4 Q5). No batch span (6.4 Q6). Memory-store reasons: safe-term describer, SQLSTATE code for Postgrex; the "deferred batch B / B2" test flips (6.4 Q7 B). Credential reason in `TurnError` reduced to a tag term (6.4 Q8 B). `guardrails.ex:189` uses the same return describer (6.4 Q9).
- **R10 (6.5)** `AgentProcess` keeps `:inline` default behind a FIFO run queue with one worker; reads answer at once (6.5 Q1 a); `run/3` timeout `:infinity` (Q2); `:max_pending_runs` 100 and `:queue_full`; inline casts serialized and keep memory (Q3); shared app-level registry fixes the atom leak (Q4); an internal watched-worker module shared later with Turn.Server (Q5 — 6.5 creates it, Turn.Server is not switched in this wave); `StatefulContext` docs + `:protected` (Q6); HierarchicalCoordinator returns decision-6 shapes, aggregation documented as a fresh conversation (Q7); AgentPool `:lifo`/`:fifo` fixed to the docs (Q8); deferred AX items are known limits (Q9); B6 documented only (Q10); batch-completeness assertion in 6.2a (Q12).


## Header refinements from the section writers (accepted by the controller)

- **H1 (6.1)** JSON key order of atom-keyed maps varies between VM runs (OTP 26+ orders small atom-keyed maps by atom index): observed on `d624fbf`, `tool_result` blocks from `components/tool_result.ex:37-44` encoded `tool_use_id`/`is_error` in either order across runs. The 6.1 fixture compares decoded bodies. Model-visible JSON text built from a plain map (a tool's map output in a `tool_result` string, map message content) is key-sorted by Task 6.1f (Q chose A1 (b), decision 25); values are unchanged, so the decoded fixture holds.
- **H2 (6.1c)** `tokens_removed` is computed from the cached model-facing estimate, so `tokens_removed == tokens_before - tokens_after` now holds for chat messages too (it did not); MIGRATING bullet.
- **H3 (6.1b)** `TokenCounter` keeps `history/1` (it drops no stale thinking and removes system messages before merging); after 6.1a that reads the cache.
- **H4 (6.1a)** Turn.Server admission's `BaseAgent.begin_turn/2` runs under `call_handler(data, :append, ...)`, so an unencodable input replies `:handler_crashed` (`:append`) instead of crashing the server. A memory dump whose tool calls are plain maps (never encodable) raises at `load/1`, naming the entry.
- **H5 (6.3)** The 6.3c/6.3d split is by feature (a callback change lands with all five implementations or `--warnings-as-errors` fails). `Session.delete/1` needs `stop_server/2` on both supervisors. InMemory `fork/3` keeps only the forked chain.
- **H6 (6.2)** A self-registering start whose `whereis/2` lookup fails stops with that reason (`{:error, reason}` from `Turn.Start`). The batch-completeness check lives in the pure core (`Turn.apply_tool_results/2`); no interpreter change.
- **H7 (6.4)** TEL-16 metadata additions listed in Shared interfaces. TEL-14: Anthropic's memory `create` maps to semconv `upsert_memory` (registry checked 2026-10-06); `view` → `search_memory`, `str_replace`/`insert`/`rename` → `update_memory`, `delete` → `delete_memory`.
- **H8 (controller, 6.2d)** Passivation stops the server with `{:shutdown, :passivated}`; `Session.run/2` re-routes only an exit with that reason or `:noproc` (a `:normal` exit, e.g. a host's `:gen_statem.stop/1` mid-turn, is not retried: the turn may have run tools).
- **H9 (controller, 6.5)** `get_stats/1` `run_count` counts failed turns in both modes (writer's choice, kept). 6.5f also replaces `HierarchicalCoordinator`'s `String.to_atom(worker.id)` (an atom per worker id) if the inventory's evidence holds at preflight; otherwise it is listed in Task 6.6's known limits.
- **H10 (controller, July leftover)** A failed terminal turn-state save leaves the session in the in-flight index, so the reaper may resume a finished turn (its `non_terminal?` guard reads the store). Not fixed here; Task 6.6 lists it for Wave 7.

## Review Focus

1. **A session restored after a compaction, then a fork from an entry before the snapshot, then a delete of the parent.** Expect the restored memory equal to the live memory before stop, the fork's history intact, and the parent's unshared entries gone, on every session-store backend. Tests: Tasks 6.2g (restore, fork) and 6.3c/6.3d (delete with forks).
2. **A store that exits mid-turn, during the load, and during the `:unavailable` retry, under a supervisor with `max_restarts: 0`.** Expect `persist_failed`/`session_unavailable` replies, the same pid alive, no stacktrace anywhere, and no conversation in the persisted state or the log (the reply to the session's own caller may carry a bug's exception in full, decision 6 / Wave 2 M3). Tests: Tasks 6.2a, 6.2b.
3. **A tool-loop conversation with thinking, cached content and a compaction, sent through `run/3`, `stream/3` and `Turn.Server`.** Expect request bodies byte-identical to the frozen fixture and the encoding count constant per message as turns grow. Tests: Tasks 6.1b, 6.1d.
4. **An `AgentProcess` under load: a long inline run, `get_agent/1` and `get_stats` during it, 101 queued casts with `max_pending_runs: 100`, and the caller dying mid-run.** Expect reads answered at once, exactly one `:queue_full`, memory kept from every completed run, and no orphan worker. Tests: Tasks 6.5c, 6.5d.
5. **A Turn.Server turn whose `on_prompt` hook returns a malformed value carrying a secret, inside a caller span.** Expect the hook span parented to the caller, a run `:exception` with a `:handler_crashed` `TurnError`, and the secret in neither the reply, the log nor telemetry. Tests: Tasks 6.4a, 6.4c.

---

### Task 6.1a: Each history entry carries its encoding and token estimate (PERF-3/B1, R1)

`AgentMemory.history/1` re-encodes every message on every request (`BaseIOSchema.to_json/1` per
entry), and `Context.WindowManager.estimate_conversation_tokens/1` re-encodes it again; over N turns
that is N² encodings (4N² under `Compactor.WindowManager`). This task stores each entry's
model-facing term (`wire`) and token estimate (`tokens`) when its content is set, and makes
`history/1`, the conversation estimate and `ConfigTemplate` use them. It first freezes the request
bodies of a scripted conversation from the unmodified code, so this task and every later 6.1 task
prove they change no request (Header conflicts 1, 2).

**Files:**
- Create: `test/agents/wire_identity_test.exs`, `test/fixtures/wire_identity/{run,stream,server}-caching-{false,true}.json` (6 files, recorded in Step 1)
- Modify: `lib/normandy/components/agent_memory/entry.ex` (fields `wire`, `tokens`; moduledoc)
- Modify: `lib/normandy/components/agent_memory.ex` (moduledoc; `add_message/4`, `history/1`, `delete_turn/2`, `drop_stale_thinking/2`, `from_entries/1`, `load/1`, `enforce_max_messages/1`; new `entry_wire/1`, `entry_tokens/1`, `drop_cache/1`, `fill_cache/1`, private `put_content/2`, `estimate_tokens/1`, `bare_entry/1`, `fill_entry/1`, `strip_thinking/1`, `load_entry/1`)
- Modify: `lib/normandy/context/window_manager.ex` (`estimate_conversation_tokens/1`)
- Modify: `lib/normandy/components/base_io_schema.ex` (the two protocol `@spec`s take `t()`)
- Modify: `lib/normandy/agents/config_template.ex` (`storable_fields!/1`, `rebuild/3`, new `memory_cache/2`)
- Modify: `lib/normandy/agents/turn/server.ex` (`handle_event({:call, from}, {:turn, user_input, caller_ctx}, :idle, data)`)
- Modify: `MIGRATING-2.0.md` (create `## 38.`)
- Create: `test/support/counting_content.ex` (`Normandy.Test.CountingContent`)
- Test: create `test/components/agent_memory/entry_cache_test.exs`, `test/agents/turn/server_append_encoding_test.exs`; modify `test/agents/config_template_test.exs` (2 tests), `test/components/agent_memory_test.exs` (1 test flips), and give the test-double `Resp` structs a `BaseIOSchema` implementation in `test/support/turn_config.ex`, `test/agents/turn/session_test.exs`, `test/coordination/agent_process_server_test.exs`, `test/agents/turn/server_integration_test.exs`, `test/agents/turn/server_postgres_e2e_test.exs`

**Interfaces:**
- Consumes: `Normandy.Context.WindowManager.estimate_message_content_tokens/1` (unchanged), `BaseIOSchema.to_json/1` (unchanged), `Normandy.Test.WireScript.client/2` (unchanged).
- Produces: `%AgentMemory.Entry{wire: nil, tokens: nil}` (header); `AgentMemory.entry_wire(entry) :: String.t() | list()` and `AgentMemory.entry_tokens(entry) :: non_neg_integer()` (`@doc false`; the header's `Map.get(entry, :wire) || model_content(entry.content)` reader, and its token twin); `AgentMemory.drop_cache(memory)` / `fill_cache(memory)` (`@doc false`, for `ConfigTemplate`); private `put_content/2`, `strip_thinking/1` (used by 6.1c); `Normandy.Test.CountingContent.counter/0`, `new/2`, `count/1`; `Normandy.Agents.WireIdentityTest` and its fixtures (re-run by 6.1b–6.1e).

- [ ] **Step 1: Freeze the request bodies (before touching `lib/`)**

`git status --short lib/` must print nothing. Create `test/agents/wire_identity_test.exs`:

```elixir
defmodule Normandy.Agents.WireIdentityTest do
  @moduledoc """
  Task 6.1 (PERF-3, R1): caching each message's encoding changes no request.

  One scripted conversation (an io_schema input, a tool round with thinking and two
  parallel tool results, one of them JSON, a system prompt change that makes earlier
  thinking stale, and a compaction) is sent through `BaseAgent.run/3`, `BaseAgent.stream/3`
  and `Turn.Server`, with prompt caching off and on. Every request body must equal the one
  recorded from the code before Task 6.1 (`d624fbf`) in `test/fixtures/wire_identity/`:
  every value, every array in its order. Bodies are compared decoded, because the order
  of a JSON object's keys is not stable between VM runs (an atom-keyed map iterates in
  atom-table order since OTP 26: a tool_result block's `is_error` and `tool_use_id` swap
  places from one run to the next on the same code).

  To record (once, on the code before Task 6.1a):
  `NORMANDY_RECORD_WIRE=1 mix test test/agents/wire_identity_test.exs`. A recording run
  writes the fixtures and fails on purpose, so it can never pass a gate.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.PromptSpecification
  alias Normandy.Test.FakeTool
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @fixtures Path.expand("../fixtures/wire_identity", __DIR__)
  @record System.get_env("NORMANDY_RECORD_WIRE") == "1"

  defmodule Question do
    use Normandy.Schema

    io_schema "A question about a city" do
      field(:text, :string, required: true)
      field(:lang, :string, default: "en")
    end
  end

  # A context provider whose text the test changes between turns: the system prompt,
  # and so the prefix key, changes, and earlier thinking becomes stale.
  defmodule Phase do
    @moduledoc false
    defstruct [:agent]

    defimpl Normandy.Components.ContextProvider do
      def title(_phase), do: "Phase"
      def get_info(%{agent: agent}), do: Agent.get(agent, & &1)
    end
  end

  # Each reply as content blocks and a stop reason; json_replies/0 and sse_replies/0
  # render them.
  @replies [
    {[
       %{"type" => "thinking", "thinking" => "plan one", "signature" => "sig-1"},
       %{"type" => "text", "text" => "Checking."},
       %{
         "type" => "tool_use",
         "id" => "t1",
         "name" => "weather",
         "input" => %{"city" => "Paris"}
       },
       %{"type" => "tool_use", "id" => "t2", "name" => "facts", "input" => %{}}
     ], "tool_use"},
    {[%{"type" => "text", "text" => "Paris is sunny."}], "end_turn"},
    {[
       %{"type" => "thinking", "thinking" => "plan two", "signature" => "sig-2"},
       %{"type" => "tool_use", "id" => "t3", "name" => "weather", "input" => %{"city" => "Lyon"}}
     ], "tool_use"},
    {[%{"type" => "text", "text" => "Lyon is cloudy."}], "end_turn"},
    {[%{"type" => "text", "text" => "Done."}], "end_turn"}
  ]

  @turns [
    {"phase one", %{text: "Weather in Paris?", lang: "en"}},
    {"phase two", %{text: "And Lyon?", lang: "fr"}},
    {"phase two", %{text: "Thanks, that is all.", lang: "en"}}
  ]

  defp json_replies, do: Enum.map(@replies, fn {blocks, stop} -> {:json, blocks, stop} end)

  defp sse_replies do
    @replies
    |> Enum.with_index()
    |> Enum.map(fn {{blocks, stop}, i} ->
      events = blocks |> Enum.with_index() |> Enum.flat_map(fn {b, j} -> sse_block(j, b) end)
      {:sse, WireScript.message("msg_#{i}", events, stop)}
    end)
  end

  defp sse_block(j, %{"type" => "thinking", "thinking" => t, "signature" => s}) do
    WireScript.block(j, %{"type" => "thinking", "thinking" => ""}, [
      %{"type" => "thinking_delta", "thinking" => t},
      %{"type" => "signature_delta", "signature" => s}
    ])
  end

  defp sse_block(j, %{"type" => "text", "text" => t}),
    do:
      WireScript.block(j, %{"type" => "text", "text" => ""}, [
        %{"type" => "text_delta", "text" => t}
      ])

  defp sse_block(j, %{"type" => "tool_use", "input" => input} = b) do
    WireScript.block(j, %{b | "input" => %{}}, [
      %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}
    ])
  end

  # The compactor's window (270 tokens of room) is crossed only at turn 3's start.
  defp agent(client, phase) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      max_tokens: 1024,
      input_schema: %Question{},
      prompt_specification: %PromptSpecification{
        background: ["You answer questions about cities."],
        context_providers: %{phase: %Phase{agent: phase}}
      },
      toolset:
        Toolset.new([
          %FakeTool{name: "weather"},
          %ReturnTool{name: "facts", output: %{"population" => 2_100_000, "tags" => ["capital"]}}
        ]),
      behaviours: %Normandy.Behaviours.Config{
        compactor: {Compactor.WindowManager, context_window: 1_270, reserved_tokens: 1_000}
      }
    })
  end

  # The scenario's request bodies, decoded, in call order.
  defp run_turns(path, caching) do
    {:ok, phase} = Agent.start_link(fn -> "" end)
    replies = if path == :stream, do: sse_replies(), else: json_replies()
    client = WireScript.client(replies, %{enable_caching: caching})
    :ok = drive(path, agent(client, phase), phase)

    for n <- 0..(length(@replies) - 1) do
      assert_received {:wire_body, ^n, body}
      body
    end
  end

  defp drive(:server, config, phase) do
    {:ok, srv} =
      Server.start_link(
        session_id: "wire-identity-#{System.unique_integer([:positive])}",
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    for {text, input} <- @turns do
      Agent.update(phase, fn _ -> text end)
      {:ok, _out} = Server.run(srv, input)
    end

    :ok
  end

  defp drive(path, config, phase) do
    _final =
      Enum.reduce(@turns, config, fn {text, input}, config ->
        Agent.update(phase, fn _ -> text end)
        {:ok, config, _out} = turn(path, config, input)
        config
      end)

    :ok
  end

  defp turn(:run, config, input), do: BaseAgent.run(config, input)
  defp turn(:stream, config, input), do: BaseAgent.stream(config, input, fn _event -> :ok end)

  for path <- [:run, :stream, :server], caching <- [false, true] do
    @tag path: path, caching: caching
    test "#{path}, caching #{caching}: every request body is identical to the fixture",
         %{path: path, caching: caching} do
      bodies = run_turns(path, caching)
      file = Path.join(@fixtures, "#{path}-caching-#{caching}.json")

      if @record do
        File.mkdir_p!(@fixtures)
        File.write!(file, Jason.encode_to_iodata!(bodies, pretty: true))
        flunk("recorded #{length(bodies)} bodies to #{file}; rerun without NORMANDY_RECORD_WIRE")
      end

      expected = file |> File.read!() |> Jason.decode!()
      assert length(bodies) == length(expected)

      for {body, want, n} <- Enum.zip([bodies, expected, 0..(length(expected) - 1)]) do
        assert body == want, "request #{n} differs from #{file}"
      end
    end
  end

  for path <- [:run, :stream, :server] do
    @tag path: path
    test "#{path}: the scenario reaches every case it is meant to pin", %{path: path} do
      [_first, _second, third, fourth, fifth] =
        run_turns(path, false)

      # Turn 2's first call drops turn 1's stale thinking; its second call keeps turn 2's.
      refute inspect(third["messages"]) =~ "sig-1"
      assert inspect(fourth["messages"]) =~ "sig-2"
      # Only turn 3 starts compacted: its first message is no longer turn 1's question.
      assert inspect(hd(fourth["messages"])) =~ "Weather in Paris?"
      refute inspect(hd(fifth["messages"])) =~ "Weather in Paris?"
      # A JSON tool result and an io_schema input are on the wire.
      assert inspect(fourth["messages"]) =~ ~s(\\"population\\":2100000)
      assert inspect(fourth["messages"]) =~ ~s(\\"lang\\":\\"fr\\")
    end
  end
end
```

Run: `mix format && NORMANDY_RECORD_WIRE=1 mix test test/agents/wire_identity_test.exs`
Expected: `9 tests, 6 failures`; each failure reads
`recorded 5 bodies to .../test/fixtures/wire_identity/<path>-caching-<bool>.json; rerun without NORMANDY_RECORD_WIRE`;
the three "reaches every case" tests pass. `ls test/fixtures/wire_identity` lists the 6 files.

Run three times: `for i in 1 2 3; do mix test test/agents/wire_identity_test.exs; done`
Expected: `9 tests, 0 failures` each time.

- [ ] **Step 2: Gate and commit the frozen fixture**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1a-fixture.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1a-fixture.log`
Expected: ` 0 failures`, exit 0.

```bash
git add test/agents/wire_identity_test.exs \
  test/fixtures/wire_identity/run-caching-false.json \
  test/fixtures/wire_identity/run-caching-true.json \
  test/fixtures/wire_identity/stream-caching-false.json \
  test/fixtures/wire_identity/stream-caching-true.json \
  test/fixtures/wire_identity/server-caching-false.json \
  test/fixtures/wire_identity/server-caching-true.json
git commit -m "test(agents): freeze request bodies before the history cache"
```

- [ ] **Step 3: Write the failing tests**

Create `test/support/counting_content.ex`:

```elixir
defmodule Normandy.Test.CountingContent do
  @moduledoc """
  Memory content that counts its encodings: each `BaseIOSchema.to_json/1` of it adds 1
  to slot 1 of `ref` (a `:counters` ref) and returns `text`. Tests of Task 6.1 use it to
  prove a message is encoded once, however many requests carry it.
  """

  @enforce_keys [:ref]
  defstruct [:ref, text: "counted"]

  @type t :: %__MODULE__{ref: :counters.counters_ref(), text: String.t()}

  @doc "A counter for `new/2`, starting at 0."
  @spec counter() :: :counters.counters_ref()
  def counter, do: :counters.new(1, [])

  @doc "Content counting into `ref`, sent to the model as `text`."
  @spec new(:counters.counters_ref(), String.t()) :: t()
  def new(ref, text \\ "counted"), do: %__MODULE__{ref: ref, text: text}

  @doc "How many times content counting into `ref` was encoded."
  @spec count(:counters.counters_ref()) :: non_neg_integer()
  def count(ref), do: :counters.get(ref, 1)
end

defimpl Normandy.Components.BaseIOSchema, for: Normandy.Test.CountingContent do
  def to_json(%{ref: ref, text: text}) do
    :counters.add(ref, 1, 1)
    text
  end

  def get_schema(_content), do: %{}
end
```

Create `test/components/agent_memory/entry_cache_test.exs`:

```elixir
defmodule Normandy.Components.AgentMemory.EntryCacheTest do
  @moduledoc """
  Task 6.1a (PERF-3): an entry's model-facing encoding (`wire`) and token estimate
  (`tokens`) are computed once, when its content is set, and every reader uses them.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.ToolCall
  alias Normandy.Context.WindowManager
  alias Normandy.Test.CountingContent

  defmodule NoEncoding do
    @moduledoc false
    defstruct [:value]
  end

  @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}

  defp tool_response(prefix_key) do
    %ToolCallResponse{
      content: "calling",
      tool_calls: [%ToolCall{id: "c1", name: "lookup", input: %{"q" => "x"}}],
      thinking: [@thinking],
      prefix_key: prefix_key
    }
  end

  # Every entry's cache is what encoding its content gives now.
  defp assert_cache_consistent(memory) do
    for {_id, entry} <- AgentMemory.entries(memory) do
      wire = BaseIOSchema.to_json(entry.content)
      assert entry.wire == wire
      assert entry.tokens == WindowManager.estimate_message_content_tokens(wire) + 10
    end
  end

  test "an append encodes the content once; history/1 and the estimate read the cache" do
    ref = CountingContent.counter()

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", CountingContent.new(ref, "hello there"))
      |> AgentMemory.add_message("assistant", %{"answer" => 42})

    assert CountingContent.count(ref) == 1

    for _ <- 1..3 do
      assert [
               %{role: "user", content: "hello there"},
               %{role: "assistant", content: ~s({"answer":42})}
             ] =
               AgentMemory.history(memory)

      assert WindowManager.estimate_conversation_tokens(memory) ==
               WindowManager.estimate_tokens("hello there") + 10 +
                 WindowManager.estimate_tokens(~s({"answer":42})) + 10
    end

    assert CountingContent.count(ref) == 1
    assert_cache_consistent(memory)
  end

  test "the chat schemas' cached wire is their text, as history/1 sent before" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", %Normandy.Agents.BaseAgentInputSchema{chat_message: "hi"})
      |> AgentMemory.add_message("assistant", %Normandy.Agents.BaseAgentOutputSchema{
        chat_message: "hello"
      })

    assert [%Entry{wire: "hi", tokens: 11}, %Entry{wire: "hello", tokens: 11}] =
             AgentMemory.entry_chain(memory)
  end

  test "content that cannot be encoded raises at the append" do
    assert_raise Protocol.UndefinedError, fn ->
      AgentMemory.add_message(AgentMemory.new_memory(), "user", %NoEncoding{value: 1})
    end
  end

  test "dropping stale thinking, deleting a turn and a max_messages trim keep the cache" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "q1")
      |> AgentMemory.add_message("assistant", tool_response(1))
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", "q2")
      |> AgentMemory.add_message("assistant", tool_response(1))

    dropped = AgentMemory.drop_stale_thinking(memory, 2)
    assert_cache_consistent(dropped)
    refute Enum.any?(AgentMemory.history(dropped), &match?(%{content: [@thinking | _]}, &1))

    [first | _] = AgentMemory.entry_chain(memory)
    deleted = AgentMemory.delete_turn(memory, first.turn_id)
    assert_cache_consistent(deleted)

    trimmed = AgentMemory.add_message(%{memory | max_messages: 2}, "user", "q3")
    assert_cache_consistent(trimmed)
  end

  test "an entry without thinking keeps its cached term through a trim (nothing re-encoded)" do
    ref = CountingContent.counter()

    memory =
      Enum.reduce(1..4, AgentMemory.new_memory(2), fn i, m ->
        AgentMemory.add_message(m, "user", CountingContent.new(ref, "m#{i}"))
      end)

    assert CountingContent.count(ref) == 4
    assert [%Entry{wire: "m3"}, %Entry{wire: "m4"}] = AgentMemory.entry_chain(memory)
  end

  test "from_entries/1 fills the cache of stored entries, including pre-field terms" do
    stored = %Entry{id: "e1", parent_id: nil, turn_id: "t", role: "user", content: %{"a" => 1}}
    # A term decoded from a template written before :wire and :tokens existed.
    old_shape =
      Map.drop(
        %Entry{id: "e2", parent_id: "e1", turn_id: "t", role: "assistant", content: "ok"},
        [:wire, :tokens]
      )

    memory = AgentMemory.from_entries([stored, old_shape])

    assert [%Entry{id: "e1", wire: ~s({"a":1})}, %Entry{id: "e2", wire: "ok", tokens: 11}] =
             AgentMemory.entry_chain(memory)

    assert_cache_consistent(memory)
  end

  test "dump/1 never writes the cache; load/1 computes it" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "q")
      |> AgentMemory.add_message("assistant", tool_response(nil))

    dump = AgentMemory.dump(memory)

    for entry <- Jason.decode!(dump)["entries"] do
      assert Map.keys(entry) |> Enum.sort() == ~w(content id parent_id role turn_id)
    end

    loaded = AgentMemory.load(dump)
    assert_cache_consistent(loaded)
    assert AgentMemory.history(loaded) == AgentMemory.history(memory)
  end

  test "a hand-built entry with no cache is encoded when read" do
    entry = %Entry{id: "e1", parent_id: nil, turn_id: "t", role: "user", content: %{"k" => "v"}}
    memory = %AgentMemory{entries: %{"e1" => entry}, head: "e1", current_turn_id: "t"}

    assert AgentMemory.history(memory) == [%{role: "user", content: ~s({"k":"v"})}]

    assert WindowManager.estimate_conversation_tokens(memory) ==
             WindowManager.estimate_tokens(~s({"k":"v"})) + 10
  end

  test "drop_cache/1 clears every entry's cache and fill_cache/1 restores it" do
    memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", %{"a" => 1})
    bare = AgentMemory.drop_cache(memory)

    assert [%Entry{wire: nil, tokens: nil}] = AgentMemory.entry_chain(bare)
    assert AgentMemory.fill_cache(bare) == memory
  end
end
```

Create `test/agents/turn/server_append_encoding_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerAppendEncodingTest do
  @moduledoc """
  Task 6.1a (R1): memory encodes a message when it is appended, so under `Turn.Server`
  content that cannot be encoded fails the turn as a crashed `:append` before the store
  holds it, and the server stays up.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig
  alias Normandy.TurnError

  defmodule NoEncoding do
    @moduledoc false
    defstruct content: "", tool_calls: nil
  end

  defp start(answer, config \\ TurnConfig.build()) do
    sid = "enc-#{System.unique_integer([:positive])}"
    store = InMemory.new()
    handlers = %{BaseAgent.non_streaming_handlers() | call_llm: fn _c, _s, _r -> answer end}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: handlers,
        subscriber: nil
      )

    {srv, store, sid}
  end

  test "an answer that cannot be encoded fails as a crashed :append; the store keeps the input only" do
    config = %{TurnConfig.build() | output_schema: %NoEncoding{}}
    {srv, store, sid} = start(%NoEncoding{content: "x"}, config)

    assert {:error,
            %TurnError{
              type: :handler_crashed,
              handler: :append,
              reason: %Protocol.UndefinedError{protocol: Normandy.Components.BaseIOSchema}
            }} = Turn.Server.run(srv, "hello")

    assert {:ok, [%{role: "user", content: "hello"}]} = InMemory.history(store, sid)
    assert Process.alive?(srv)
  end

  test "an input that cannot be encoded fails as a crashed :append before anything is stored" do
    {srv, store, sid} = start(%TurnConfig.Resp{content: "fine"})

    assert {:error,
            %TurnError{
              type: :handler_crashed,
              handler: :append,
              reason: %Protocol.UndefinedError{protocol: Normandy.Components.BaseIOSchema}
            }} = Turn.Server.run(srv, %NoEncoding{content: "x"})

    assert {:ok, []} = InMemory.history(store, sid)
    assert {:ok, %TurnConfig.Resp{content: "fine"}} = Turn.Server.run(srv, "hello")
  end
end
```

In `test/agents/config_template_test.exs`, inside `describe "round trip"`, after the test
`"rebuild(from_config(c)) gives back c"`, add:

```elixir
    test "initial_memory is stored without its entries' encodings; rebuild computes them" do
      supp = round_trip_supplement()
      tmpl = ConfigTemplate.from_config(full_config(supp), "t")

      assert [%AgentMemory.Entry{content: "seed", wire: nil, tokens: nil}] =
               AgentMemory.entry_chain(tmpl.initial_memory)

      assert [%AgentMemory.Entry{content: "seed", wire: "seed", tokens: 11}] =
               AgentMemory.entry_chain(ConfigTemplate.rebuild(tmpl, supp, "TOKEN").initial_memory)
    end

    test "a template saved before entries had wire and tokens rebuilds with them" do
      supp = round_trip_supplement()
      config = full_config(supp)
      tmpl = ConfigTemplate.from_config(config, "t")

      old_entries =
        Map.new(tmpl.initial_memory.entries, fn {id, e} -> {id, Map.drop(e, [:wire, :tokens])} end)

      tmpl = put_in(tmpl.initial_memory.entries, old_entries)

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").initial_memory == config.initial_memory
    end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run each separately (a compile error in one file stops the others):
- `mix format && mix test test/components/agent_memory/entry_cache_test.exs` — Expected: FAIL to compile, `unknown key :wire for struct Normandy.Components.AgentMemory.Entry`.
- `mix test test/agents/config_template_test.exs` — Expected: FAIL to compile, same error.
- `mix test test/agents/turn/server_append_encoding_test.exs` — Expected: `2 tests, 2 failures`, both `match (=) failed` with `right: {:ok, ...}` (today the append never encodes).

- [ ] **Step 5: The entry fields**

In `lib/normandy/components/agent_memory/entry.ex`, replace the end of the moduledoc, the
`defstruct` and the `@type` (from `  chain; branches are siblings sharing a \`parent_id\`.` to the end
of the module) with:

```elixir
  chain; branches are siblings sharing a `parent_id`.

  `wire` and `tokens` are derived from `content` when `Normandy.Components.AgentMemory`
  sets it: `wire` is what the model is sent for it (a string or a list of content
  blocks) and `tokens` its estimate (`Normandy.Context.WindowManager`'s, plus 10 for the
  message). They are never persisted: a session store keeps `id`, `parent_id`,
  `turn_id`, `role` and `content`, and an entry it returns has both `nil` until
  `Normandy.Components.AgentMemory.from_entries/1` fills them. Build entries with
  `Normandy.Components.AgentMemory`, not by hand; a hand-built entry with `nil` fields is
  encoded each time it is read.
  """

  defstruct [:id, :parent_id, :turn_id, :role, :content, wire: nil, tokens: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          turn_id: String.t(),
          role: String.t(),
          content: struct() | map() | list(),
          wire: String.t() | list() | nil,
          tokens: non_neg_integer() | nil
        }
end
```

- [ ] **Step 6: `AgentMemory` sets and reads the cache**

All edits in `lib/normandy/components/agent_memory.ex`.

(a) Moduledoc: after the paragraph ending `identical to the previous linear implementation.`, add:

```elixir

  Each entry's model-facing encoding is computed once, when its content is set (an
  append, a thinking drop, `from_entries/1`, `load/1`), and kept on the entry
  (`Normandy.Components.AgentMemory.Entry`'s `wire` and `tokens`). Building a request
  or estimating the conversation reads it, so a content that cannot be encoded raises
  at the append rather than at the next LLM call.
```

(b) Aliases: after `alias Normandy.Components.Message` add `alias Normandy.Context.WindowManager`.
(`Normandy.Context.WindowManager` already calls `AgentMemory`; the new call is a runtime one, no
compile-time cycle.)

(c) In `add_message/4`, replace

```elixir
    entry = %Entry{
      id: id,
      parent_id: memory.head,
      turn_id: Keyword.get(opts, :turn_id, memory.current_turn_id),
      role: role,
      content: content
    }
```

with

```elixir
    entry =
      put_content(
        %Entry{
          id: id,
          parent_id: memory.head,
          turn_id: Keyword.get(opts, :turn_id, memory.current_turn_id),
          role: role
        },
        content
      )
```

(d) Replace `history/1` with it and four new functions:

```elixir
  @spec history(t()) :: [%{role: String.t(), content: String.t() | list()}]
  def history(%__MODULE__{} = memory) do
    memory
    |> entry_chain()
    |> Enum.map(fn %Entry{role: role} = entry -> %{role: role, content: entry_wire(entry)} end)
  end

  @doc false
  # What the model is sent for `entry`: its cached `wire`, or (an entry built by hand,
  # or decoded from a term written before the field existed) the encoding computed now.
  @spec entry_wire(Entry.t()) :: String.t() | list()
  def entry_wire(entry), do: Map.get(entry, :wire) || model_content(entry.content)

  @doc false
  # The entry's token estimate (Context.WindowManager's, plus 10 for the message),
  # cached like entry_wire/1.
  @spec entry_tokens(Entry.t()) :: non_neg_integer()
  def entry_tokens(entry),
    do: Map.get(entry, :tokens) || estimate_tokens(entry_wire(entry))

  @doc false
  # The memory with every entry's cache cleared: what ConfigTemplate persists, so a
  # template never carries an encoding another Normandy version would replay.
  @spec drop_cache(t()) :: t()
  def drop_cache(%__MODULE__{entries: entries} = memory) do
    %{memory | entries: Map.new(entries, fn {id, entry} -> {id, bare_entry(entry)} end)}
  end

  @doc false
  # The memory with every entry's cache computed (ConfigTemplate.rebuild/3).
  @spec fill_cache(t()) :: t()
  def fill_cache(%__MODULE__{entries: entries} = memory) do
    %{memory | entries: Map.new(entries, fn {id, entry} -> {id, fill_entry(entry)} end)}
  end
```

(e) After `defp model_content(content), do: BaseIOSchema.to_json(content)` add:

```elixir

  # The only place an entry's content is set: content, wire and tokens change together.
  defp put_content(%Entry{} = entry, content) do
    wire = model_content(content)
    %Entry{entry | content: content, wire: wire, tokens: estimate_tokens(wire)}
  end

  defp estimate_tokens(wire), do: WindowManager.estimate_message_content_tokens(wire) + 10

  # An entry with its five stored fields and no cache. struct/2 reads only those keys,
  # so it also takes an entry decoded from a term written before `wire` existed.
  defp bare_entry(entry),
    do: struct(Entry, Map.take(entry, [:id, :parent_id, :turn_id, :role, :content]))

  defp fill_entry(entry) do
    bare = bare_entry(entry)
    put_content(bare, bare.content)
  end

  # Thinking is dropped by re-setting the content, so the cache follows; an entry with
  # none is returned as it is (nothing to re-encode).
  defp strip_thinking(%Entry{content: content} = entry) do
    if has_thinking?(content), do: put_content(entry, drop_thinking(content)), else: entry
  end
```

(f) In `delete_turn/2`: `do: {id, %{entry | content: drop_thinking(entry.content)}},` →
`do: {id, strip_thinking(entry)},`.

(g) In `drop_stale_thinking/2`: `{Map.put(entries, id, %{entry | content: drop_thinking(entry.content)}), state}` →
`{Map.put(entries, id, put_content(entry, drop_thinking(entry.content))), state}`.

(h) In `enforce_max_messages/1` (the `max` clause):
`|> Map.new(fn {id, entry} -> {id, %{entry | content: drop_thinking(entry.content)}} end)` →
`|> Map.new(fn {id, entry} -> {id, strip_thinking(entry)} end)`. (Re-putting every entry here
would re-encode the whole memory on every append over the cap.)

(i) `from_entries/1`: add the doc line `Each entry's encoding is computed here, once.` after
`` `current_turn_id` the last entry's `turn_id`, so the active branch reconstructs. ``, and replace
`entries: Map.new(entries, fn %Entry{id: id} = e -> {id, e} end),` with
`entries: Map.new(entries, fn %Entry{id: id} = e -> {id, fill_entry(e)} end),`.

(j) `load/1`: replace

```elixir
    entries =
      for e <- loaded["entries"], into: %{} do
        {e["id"],
         %Entry{
           id: e["id"],
           parent_id: e["parent_id"],
           turn_id: e["turn_id"],
           role: e["role"],
           content: decode_content(e["content"])
         }}
      end
```

with

```elixir
    entries = for e <- loaded["entries"], into: %{}, do: {e["id"], load_entry(e)}
```

and add right after the `# ── internals ──...` comment line:

```elixir

  # A dump is data: content the model cannot be sent (a 1.x tool call stored as a plain
  # map) is refused here, naming the entry, rather than at the next request.
  defp load_entry(e) do
    entry = %Entry{id: e["id"], parent_id: e["parent_id"], turn_id: e["turn_id"], role: e["role"]}
    content = decode_content(e["content"])

    try do
      put_content(entry, content)
    rescue
      error ->
        reraise ArgumentError,
                [
                  message:
                    "AgentMemory.load/1: entry #{inspect(entry.id)} has content that cannot be " <>
                      "encoded for the model (#{inspect(error.__struct__)})"
                ],
                __STACKTRACE__
    end
  end
```

(The message names the entry id and the exception module, never the content. `decode_content/1`'s
own `ArgumentError` for a non-schema struct is raised before the `try`, unchanged.)

(k) In `lib/normandy/components/base_io_schema.ex`, the protocol's specs name the protocol type
instead of `struct()` (it is implemented for strings, maps and lists too):
`@spec to_json(struct()) :: String.t() | list()` → `@spec to_json(t()) :: String.t() | list()` and
`@spec get_schema(struct()) :: term()` → `@spec get_schema(t()) :: term()`. Without it dialyzer
narrows `add_message/4`'s content to `struct()` (the append now calls `to_json/1`) and fails
`Summarizer.rebuild_memory_with_summary/4`'s plain-string summary append (`no_return` + `call`,
`summarizer.ex`) until 6.1c deletes that function.

- [ ] **Step 7: The conversation estimate reads the cache**

In `lib/normandy/context/window_manager.ex`, replace `estimate_conversation_tokens/1` (keep its
`@doc`):

```elixir
  @spec estimate_conversation_tokens(AgentMemory.t()) :: non_neg_integer()
  def estimate_conversation_tokens(memory) do
    # Each message's estimate (its content plus ~10 tokens for role and structure) is
    # computed when the message is stored (AgentMemory.Entry's `tokens`).
    memory
    |> AgentMemory.entry_chain()
    |> Enum.reduce(0, fn entry, acc -> acc + AgentMemory.entry_tokens(entry) end)
  end
```

`truncate_oldest_first/2`, `split_to_fit/2`, `estimate_messages_for_tokens/2` and `rebuild_memory/2`
stay as they are until Task 6.1c (they read `history/1`, which no longer encodes).

- [ ] **Step 8: Templates store `initial_memory` without the cache**

In `lib/normandy/agents/config_template.ex`, replace the last two lines of `storable_fields!/1`
(`    fields` and its closing `  end`) with:

```elixir
    Map.update!(fields, :initial_memory, &memory_cache(&1, :drop))
  end

  # A memory's per-entry encodings (AgentMemory.Entry's `wire` and `tokens`) are derived:
  # a template stores the memory without them, and rebuild/3 computes them again, so a
  # template never replays an encoding made by another Normandy version.
  defp memory_cache(%AgentMemory{} = memory, :drop), do: AgentMemory.drop_cache(memory)
  defp memory_cache(%AgentMemory{} = memory, :fill), do: AgentMemory.fill_cache(memory)
  defp memory_cache(other, _action), do: other
```

In `rebuild/3`, after
`|> struct(Map.take(tmpl, @data_fields))` add `|> Map.update!(:initial_memory, &memory_cache(&1, :fill))`.
A 1.0 template without `:initial_memory` leaves the struct default `nil`, which `memory_cache/2`
passes through.

- [ ] **Step 9: `Turn.Server` admission appends under the `:append` guard**

In `lib/normandy/agents/turn/server.ex`, in
`handle_event({:call, from}, {:turn, user_input, caller_ctx}, :idle, data)`, replace

```elixir
    with {:ok, admitted} <- admit(data, user_input),
         {:ok, repairs} <- close_batch(data, missing) do
      config = BaseAgent.begin_turn(last_config(repairs, data.config), admitted)
      start_turn(from, {user_input, caller_ctx}, config, repairs, data)
```

with

```elixir
    # begin_turn/2 encodes the input as it appends it, so an input that cannot be
    # encoded fails here, as a crashed :append, before anything reaches the store.
    with {:ok, admitted} <- admit(data, user_input),
         {:ok, repairs} <- close_batch(data, missing),
         {:ok, config} <-
           call_handler(data, :append, fn ->
             BaseAgent.begin_turn(last_config(repairs, data.config), admitted)
           end) do
      start_turn(from, {user_input, caller_ctx}, config, repairs, data)
```

The existing `{:crashed, reason}` clause of the `else` replies the `TurnError` and keeps `data`
(nothing was stored: `close_batch/2` only builds the repairs, `start_turn/5` persists them).

- [ ] **Step 10: Test doubles get an encoding; the legacy dump test flips**

The suite's fake answer `Resp` structs (`defstruct content: "", tool_calls: nil`) have no
`BaseIOSchema` implementation; stubbed `call_llm` handlers never encoded them, but the append now
does (16 tests fail without this step). Directly after the `defmodule Resp ... end` block in each of
`test/support/turn_config.ex`, `test/agents/turn/session_test.exs`,
`test/coordination/agent_process_server_test.exs`, `test/agents/turn/server_integration_test.exs` and
`test/agents/turn/server_postgres_e2e_test.exs` add (the same impl `server_test.exs` and
`tool_result_cap_test.exs` already have):

```elixir

  # Memory encodes what it stores (AgentMemory.Entry's `wire`), so the fake answer
  # needs an encoding like any output schema.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end
```

Check: `grep -rln "defimpl Normandy.Components.BaseIOSchema, for: Resp" test | wc -l` → `8`
(the five above plus `server_test.exs`, `tool_result_cap_test.exs` and `hooks/server_hooks_test.exs`).

In `test/components/agent_memory_test.exs`, the test
`"a dump written before nested structs were tagged still loads"` becomes (rename, keep the `legacy`
binding, replace the two assertions after it):

```elixir
    test "a dump written before nested structs were tagged raises at load, naming the entry" do
```

```elixir
      # Its tool call decodes as a plain map, which the model cannot be sent: the entry's
      # encoding is computed at load (Task 6.1a), so the dump is refused here.
      assert_raise ArgumentError,
                   ~s|AgentMemory.load/1: entry "e1" has content that cannot be encoded | <>
                     "for the model (KeyError)",
                   fn -> AgentMemory.load(legacy) end
    end
```

(Before, it loaded, and the next request raised `KeyError` in `ToolCallResponse`'s `to_json/1`.)

- [ ] **Step 11: Run the tests to verify they pass**

Run: `mix format && mix test test/components/agent_memory/entry_cache_test.exs test/agents/turn/server_append_encoding_test.exs test/agents/config_template_test.exs test/components/agent_memory_test.exs test/agents/wire_identity_test.exs test/behaviours/compactor_test.exs test/context/window_manager_test.exs test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs`
Expected: PASS (`entry_cache_test.exs` 9 tests, `server_append_encoding_test.exs` 2, `config_template_test.exs` 29, `wire_identity_test.exs` 9).

- [ ] **Step 12: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

Tagged suites (this task touches `Turn.Server` admission and a Postgres test file): `docker start normandy-test-pg`, then
`MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres --include distributed`
Expected: ` 0 failures`. (`mix test --only distributed` alone has one test that needs Postgres,
`EagerHandoffDistributedTest` "Postgres-backed session rehydrates...", which fails with
`Normandy.TestRepo not started` on `d624fbf` too; the combined run covers it.) `mix test.redis`: not needed (no Redis code).

- [ ] **Step 13: MIGRATING-2.0.md**

Insert after the end of `## 37.` and before `## New, non-breaking`:

```markdown
## 38. History, encoding and caching

- Memory encodes a message once, when it is stored: `AgentMemory.add_message/4`,
  `from_entries/1` and `load/1` call `BaseIOSchema.to_json/1` and keep the result on the entry,
  and every request, token estimate and compaction reads it. A conversation of N turns costs N
  encodings instead of N². Request bodies are unchanged.
- Content that cannot be encoded (a struct with no `BaseIOSchema` implementation, a tuple or a
  pid in an `:any` field) raises when it is stored, from `run/3` or `stream/3`, instead of at the
  next LLM call. Under `Turn.Server` the turn fails with
  `%Normandy.TurnError{type: :handler_crashed, handler: :append}` before the store holds the
  message, the turn's input included; it used to fail as `:task_down` from the LLM worker, after
  the store held it. A test double used as an output schema needs a `BaseIOSchema`
  implementation.
- `%Normandy.Components.AgentMemory.Entry{}` has two derived fields, `wire` (what the model is
  sent for the message) and `tokens` (its estimate). They are never persisted: a session store
  returns entries with both `nil`, `from_entries/1` fills them, and a config template stores
  `initial_memory` without them. A hand-built entry with `nil` fields still works (it is encoded
  each time it is read). Compare entries from a memory with entries from a store on `id`,
  `role`, `turn_id` and `content`, not as whole structs.
- `AgentMemory.load/1` raises `ArgumentError` naming the entry
  (`AgentMemory.load/1: entry "e1" has content that cannot be encoded for the model (KeyError)`)
  for a dump whose content cannot be sent, such as a 1.x dump whose tool calls were stored as
  plain maps. Such a dump used to load and fail at the next request.
- A memory holds each message's encoding beside its content: histories heavy in JSON tool
  results take up to about twice the memory they did.
```

- [ ] **Step 14: Commit**

```bash
git add lib/normandy/components/agent_memory/entry.ex lib/normandy/components/agent_memory.ex \
  lib/normandy/components/base_io_schema.ex lib/normandy/context/window_manager.ex lib/normandy/agents/config_template.ex \
  lib/normandy/agents/turn/server.ex MIGRATING-2.0.md test/support/counting_content.ex \
  test/components/agent_memory/entry_cache_test.exs \
  test/agents/turn/server_append_encoding_test.exs test/agents/config_template_test.exs \
  test/components/agent_memory_test.exs test/support/turn_config.ex \
  test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs \
  test/agents/turn/server_integration_test.exs test/agents/turn/server_postgres_e2e_test.exs
git commit -m "perf(memory): encode each message once, when it is stored"
```

---

### Task 6.1b: One walk per request, stale thinking applied to the cached term (PERF-3)

After 6.1a a request still walks the chain twice and rebuilds every stale entry:
`drop_stale_thinking/2` re-sets the content of each entry whose thinking is stale (re-encoding it)
and its result is thrown away after the call (`base_agent.ex` `get_response_with_usage/3` and
`build_stream_request/1`). `AgentMemory.request_messages_for/2` makes one walk, applies the same
verdict to the cached `wire` (`drop_thinking/1` on the encoded blocks), and merges tool runs exactly
as `request_messages/1` does. A property proves `drop_thinking(to_json(r)) == to_json(drop_thinking(r))`
for the `ToolCallResponse` shapes Normandy stores, and a second one proves the new function equals the
old pipeline. `drop_stale_thinking/2`, `history/1` and `request_messages/1` stay public and unchanged.
`TokenCounter` keeps its own pipeline (Header conflict 3). No MIGRATING bullet: nothing visible changes.

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (new `request_messages_for/2`)
- Modify: `lib/normandy/agents/base_agent.ex` (`get_response_with_usage/3`, `build_stream_request/1`)
- Test: create `test/components/agent_memory/request_messages_for_test.exs`; re-run `test/agents/wire_identity_test.exs`

**Interfaces:**
- Consumes: `AgentMemory.entry_wire/1`, `thinking_verdict/3`, `drop_thinking/1`, `request_messages/1` (6.1a / existing).
- Produces: `AgentMemory.request_messages_for(memory, prefix_key) :: [Message.t()]` (`@doc false`, header).

- [ ] **Step 1: Write the failing tests**

Create `test/components/agent_memory/request_messages_for_test.exs`:

```elixir
defmodule Normandy.Components.AgentMemory.RequestMessagesForTest do
  @moduledoc """
  Task 6.1b (PERF-3): `AgentMemory.request_messages_for/2` builds a request's messages in
  one walk from the cached encodings, and gives exactly what
  `drop_stale_thinking/2 |> history/1 |> request_messages/1` gives.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.CountingContent

  defp composed(memory, key),
    do:
      memory
      |> AgentMemory.drop_stale_thinking(key)
      |> AgentMemory.history()
      |> AgentMemory.request_messages()

  # ── generators: the shapes Normandy stores ────────────────────────────────────

  defp thinking_gen do
    one_of([
      map({string(:alphanumeric), string(:alphanumeric)}, fn {t, s} ->
        %{"type" => "thinking", "thinking" => t, "signature" => s}
      end),
      map(string(:alphanumeric), &%{"type" => "redacted_thinking", "data" => &1})
    ])
  end

  defp tool_call_gen do
    gen all(
          id <- string(:alphanumeric, min_length: 1),
          input <- one_of([constant(%{"q" => "x"}), constant(%{}), constant("not an object")])
        ) do
      %ToolCall{id: id, name: "lookup", input: input}
    end
  end

  # A response as the adapter stores it: content_blocks in API order (thinking first),
  # or none (built by hand, or stored before the field existed).
  defp tool_call_response_gen do
    gen all(
          thinking <- list_of(thinking_gen(), max_length: 2),
          text <- one_of([constant(nil), constant(""), string(:alphanumeric, min_length: 1)]),
          calls <- list_of(tool_call_gen(), max_length: 2),
          with_blocks? <- boolean(),
          key <- member_of([nil, 1, 2])
        ) do
      blocks =
        if with_blocks?,
          do:
            thinking ++
              if(text in [nil, ""], do: [], else: [%{"type" => "text", "text" => text}]) ++
              Enum.map(
                calls,
                &%{"type" => "tool_use", "id" => &1.id, "name" => "lookup", "input" => &1.input}
              ),
          else: []

      %ToolCallResponse{
        content: text,
        tool_calls: calls,
        thinking: thinking,
        content_blocks: blocks,
        prefix_key: key
      }
    end
  end

  defp entry_gen do
    one_of([
      map(string(:alphanumeric), &{"user", &1}),
      map(tool_call_response_gen(), &{"assistant", &1}),
      map(string(:alphanumeric), &{"tool", %ToolResult{tool_call_id: "c", output: &1}}),
      constant({"tool", %ToolResult{tool_call_id: "c", output: %{"n" => 1}, is_error: true}}),
      map(thinking_gen(), &{"assistant", [&1, %{"type" => "text", "text" => "t"}]}),
      constant({"user", %{"structured" => [1, 2]}})
    ])
  end

  property "drop_thinking/1 of an encoded response equals encoding the response without thinking" do
    check all(response <- tool_call_response_gen()) do
      assert AgentMemory.drop_thinking(BaseIOSchema.to_json(response)) ==
               BaseIOSchema.to_json(AgentMemory.drop_thinking(response))
    end
  end

  property "request_messages_for/2 equals drop_stale_thinking |> history |> request_messages" do
    check all(
            entries <- list_of(entry_gen(), max_length: 12),
            key <- member_of([1, 2])
          ) do
      memory =
        Enum.reduce(entries, AgentMemory.new_memory(), fn {role, content}, m ->
          AgentMemory.add_message(m, role, content)
        end)

      assert AgentMemory.request_messages_for(memory, key) == composed(memory, key)
    end
  end

  test "a stale response's thinking is left out; a later kept one stays" do
    thinking = %{"type" => "thinking", "thinking" => "t", "signature" => "s"}
    stale = %ToolCallResponse{content: "a", thinking: [thinking], prefix_key: 1}
    current = %ToolCallResponse{content: "b", thinking: [thinking], prefix_key: 2}

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "q")
      |> AgentMemory.add_message("assistant", stale)
      |> AgentMemory.add_message("user", "q2")
      |> AgentMemory.add_message("assistant", current)

    assert [
             %{role: "user", content: "q"},
             %{role: "assistant", content: [%{type: "text", text: "a"}]},
             %{role: "user", content: "q2"},
             %{role: "assistant", content: [^thinking, %{type: "text", text: "b"}]}
           ] = AgentMemory.request_messages_for(memory, 2)
  end

  test "building requests encodes nothing again" do
    ref = CountingContent.counter()

    memory =
      Enum.reduce(1..5, AgentMemory.new_memory(), fn i, m ->
        AgentMemory.add_message(m, "user", CountingContent.new(ref, "m#{i}"))
      end)

    for _ <- 1..10, do: AgentMemory.request_messages_for(memory, 1)

    assert CountingContent.count(ref) == 5
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/components/agent_memory/request_messages_for_test.exs`
Expected: `2 properties, 2 tests, 3 failures`, each `(UndefinedFunctionError) function Normandy.Components.AgentMemory.request_messages_for/2 is undefined or private`.
The `drop_thinking/1` property passes already: it pins the equivalence the implementation relies on.

- [ ] **Step 3: `request_messages_for/2`**

In `lib/normandy/components/agent_memory.ex`, directly before `defp fold_user_text([`, add:

```elixir
  @doc false
  # The messages of a request built from `memory` in one walk of the active branch:
  # each entry's cached encoding, with the thinking drop_stale_thinking/2 would remove
  # under `prefix_key` removed from that encoding (drop_thinking/1 on the encoded blocks
  # gives what encoding the dropped content gives), then merged as request_messages/1
  # merges. Equal to
  # `memory |> drop_stale_thinking(prefix_key) |> history() |> request_messages()`,
  # without encoding anything again.
  @spec request_messages_for(t(), integer()) :: [Message.t()]
  def request_messages_for(%__MODULE__{} = memory, prefix_key) do
    {history, _state} =
      memory
      |> entry_chain()
      |> Enum.map_reduce(:leading, fn %Entry{role: role, content: content} = entry, state ->
        case thinking_verdict(content, prefix_key, state) do
          {:keep, state} -> {%{role: role, content: entry_wire(entry)}, state}
          {:drop, state} -> {%{role: role, content: drop_thinking(entry_wire(entry))}, state}
        end
      end)

    request_messages(history)
  end
```

- [ ] **Step 4: Both BaseAgent builders use it**

In `lib/normandy/agents/base_agent.ex`, `get_response_with_usage/3`: delete

```elixir
    history =
      config.memory
      |> AgentMemory.drop_stale_thinking(prefix_key.(config.model))
      |> AgentMemory.history()

```

and in the `%Normandy.LLM.Request{}` that follows replace
`messages: AgentMemory.request_messages(history),` with
`messages: AgentMemory.request_messages_for(config.memory, prefix_key.(config.model)),`.

`build_stream_request/1`: delete

```elixir
    messages =
      config.memory
      |> AgentMemory.drop_stale_thinking(prefix_key)
      |> AgentMemory.history()
      |> AgentMemory.request_messages()

```

and replace `messages: messages,` with `messages: AgentMemory.request_messages_for(config.memory, prefix_key),`.

Check: `grep -n "drop_stale_thinking\|request_messages(" lib/normandy/agents/base_agent.ex` prints
nothing; `grep -rn "request_messages_for(" lib` prints 4 lines (the `@spec`, the definition and the two builders).
`Turn.Server` calls these builders through `BaseAgent.non_streaming_handlers/0`; `Turn.Inline`
builds no messages.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/components/agent_memory/request_messages_for_test.exs test/agents/wire_identity_test.exs test/agents/tool_call_response_test.exs test/agents/tool_result_coalescing_test.exs test/components/agent_memory_test.exs test/agents/base_agent_streaming_test.exs`
Expected: PASS (`request_messages_for_test.exs` 2 properties, 2 tests; `wire_identity_test.exs` 9 tests).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. Tagged suites: none (no store, registry or start-path code).

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/agents/base_agent.ex \
  test/components/agent_memory/request_messages_for_test.exs
git commit -m "perf(agents): build a request's messages in one walk of the cached history"
```

---

### Task 6.1c: Compaction estimates once and keeps kept entries' encodings (PERF-3 amplifier)

`Behaviours.Compactor.WindowManager.run/2` estimates the conversation three times per boundary even
when nothing is compacted, then walks the chain twice for `dropped_entries/2`; its rebuild
(`Context.WindowManager.rebuild_memory/2`, `Summarizer.rebuild_memory_with_summary/4`) re-appends
every kept message with `add_message/4`, which validates options, re-encodes it and, under
`max_messages`, walks the chain on each append. This task: one estimate (a sum of cached integers),
the no-op meta returned at once when within budget, `tokens_removed` from the cached estimates
(Header conflict 4), and `AgentMemory.keep_entries/3`, a one-pass rebuild that keeps each unchanged
entry's encoding. A property proves `keep_entries/3` builds exactly what the per-message rebuild built.

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (new `keep_entries/3`, `@keep_entries_opts_schema`, private `link_entry/2`)
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex` (moduledoc; `run/2`, new `compact/3`, `tokens_removed_this_turn/2`; drop the `BaseIOSchema` alias)
- Modify: `lib/normandy/context/window_manager.ex` (`truncate_oldest_first/2`, `estimate_messages_for_tokens/2`; new `newest_fitting/2`; delete `split_to_fit/2`, `rebuild_memory/2`)
- Modify: `lib/normandy/context/summarizer.ex` (`do_compress_conversation/7`; delete `rebuild_memory_with_summary/4`)
- Modify: `MIGRATING-2.0.md` (`## 38.`)
- Test: create `test/context/compaction_cache_test.exs`; re-run `test/behaviours/compactor_test.exs`, `test/context/window_manager_test.exs`, `test/context/summarizer_test.exs`, `test/agents/wire_identity_test.exs`

**Interfaces:**
- Consumes: `AgentMemory.entry_tokens/1`, `put_content/2`, `strip_thinking/1`, `enforce_max_messages/1` (6.1a / existing), `AgentMemory.keep_count/2` (unchanged).
- Produces: `AgentMemory.keep_entries(memory, kept_entries, opts)` (`@doc false`, header) with one option, `summary: {role, content} | nil` (default `nil`), validated by `Normandy.Options.validate!/3` under `{AgentMemory, :keep_entries, 3}`.

- [ ] **Step 1: Write the failing tests**

Create `test/context/compaction_cache_test.exs`:

```elixir
defmodule Normandy.Context.CompactionCacheTest do
  @moduledoc """
  Task 6.1c (PERF-3): compaction reads the entries' cached estimates and rebuilds the
  memory in one pass (`AgentMemory.keep_entries/3`) without encoding a kept message again.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Test.CountingContent
  alias Normandy.Test.MockSummarizerClient

  @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}

  defp counting_memory(ref, n) do
    Enum.reduce(1..n, AgentMemory.initialize_turn(AgentMemory.new_memory()), fn i, m ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      AgentMemory.add_message(m, role, CountingContent.new(ref, "message number #{i} padding"))
    end)
  end

  # What WindowManager and Summarizer did before Task 6.1c: one add_message per kept
  # entry, under its own id and turn, with its thinking dropped.
  defp reference_keep(memory, kept, summary) do
    fresh = %{
      AgentMemory.new_memory(memory.max_messages)
      | current_turn_id: memory.current_turn_id
    }

    fresh =
      case summary do
        nil -> fresh
        {role, content} -> AgentMemory.add_message(fresh, role, content, id: "summary")
      end

    Enum.reduce(kept, fresh, fn entry, mem ->
      AgentMemory.add_message(mem, entry.role, AgentMemory.drop_thinking(entry.content),
        turn_id: entry.turn_id,
        id: entry.id
      )
    end)
  end

  # The summary gets a new UUID; the reference gives it the id "summary". Renames the
  # one entry of `result` that is not one of `memory`'s (if a cap left it in).
  defp rename_summary(result, memory) do
    case Enum.reject(Map.values(result.entries), &Map.has_key?(memory.entries, &1.id)) do
      [] ->
        result

      [summary] ->
        entries =
          result.entries
          |> Map.delete(summary.id)
          |> Map.put("summary", %{summary | id: "summary"})
          |> Map.new(fn
            {id, %Entry{parent_id: parent} = e} when parent == summary.id ->
              {id, %{e | parent_id: "summary"}}

            pair ->
              pair
          end)

        head = if result.head == summary.id, do: "summary", else: result.head
        %{result | entries: entries, head: head}
    end
  end

  defp message_gen do
    one_of([
      map(string(:alphanumeric), &{"user", &1}),
      map(string(:alphanumeric), &{"assistant", &1}),
      constant(
        {"assistant", %ToolCallResponse{content: "c", thinking: [@thinking], prefix_key: 1}}
      ),
      constant({"assistant", [@thinking, %{"type" => "text", "text" => "t"}]})
    ])
  end

  property "keep_entries/3 builds what one add_message per kept entry built" do
    check all(
            messages <- list_of(message_gen(), min_length: 1, max_length: 10),
            keep <- integer(0..10),
            max <- one_of([constant(nil), integer(1..6)]),
            summary <- one_of([constant(nil), constant({"user", "the summary"})])
          ) do
      memory =
        Enum.reduce(messages, AgentMemory.new_memory(), fn {role, content}, m ->
          AgentMemory.add_message(m, role, content)
        end)

      memory = %{memory | max_messages: max}
      kept = memory |> AgentMemory.entry_chain() |> Enum.take(-keep)

      assert rename_summary(AgentMemory.keep_entries(memory, kept, summary: summary), memory) ==
               reference_keep(memory, kept, summary)
    end
  end

  test "keep_entries/3 starts a turn for a memory with none, as add_message/4 does" do
    memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", "q")
    [kept] = AgentMemory.entry_chain(memory)

    result =
      AgentMemory.keep_entries(%{memory | current_turn_id: nil}, [kept], summary: {"user", "s"})

    assert is_binary(result.current_turn_id)

    assert [%Entry{content: "s", turn_id: turn}, %Entry{id: id, turn_id: kept_turn}] =
             AgentMemory.entry_chain(result)

    assert turn == result.current_turn_id
    assert {id, kept_turn} == {kept.id, kept.turn_id}

    assert %AgentMemory{entries: entries, current_turn_id: nil} =
             AgentMemory.keep_entries(%{memory | current_turn_id: nil}, [])

    assert entries == %{}
  end

  test "keep_entries/3 refuses an unknown option" do
    assert_raise ArgumentError,
                 "Normandy.Components.AgentMemory.keep_entries/3: unknown option :sumary; " <>
                   "supported: :summary",
                 fn ->
                   AgentMemory.keep_entries(AgentMemory.new_memory(), [], sumary: {"user", "s"})
                 end
  end

  test "an :oldest_first compaction encodes no kept message again" do
    ref = CountingContent.counter()
    acc = %{memory: counting_memory(ref, 40)}

    {result, meta} =
      WMCompactor.maybe_compact(acc, %{model: "m", window: 120}, reserved_tokens: 16)

    assert meta.compacted
    assert length(AgentMemory.entry_chain(result.memory)) < 40
    assert CountingContent.count(ref) == 40
  end

  test "a :summarize compaction encodes no kept message again (the summary is new text)" do
    ref = CountingContent.counter()

    acc = %{
      memory: counting_memory(ref, 20),
      client: %MockSummarizerClient{summary_response: "a short summary"},
      model: "m"
    }

    {result, meta} =
      WMCompactor.maybe_compact(acc, %{model: "m", window: 200},
        strategy: :summarize,
        reserved_tokens: 64
      )

    assert meta.compacted
    assert [%Entry{wire: "The earlier part" <> _} | _] = AgentMemory.entry_chain(result.memory)
    # The summary request reads history/1 (cached wire); nothing is encoded twice.
    assert CountingContent.count(ref) == 20
  end

  test "a conversation within the window is estimated once and left as it is" do
    ref = CountingContent.counter()
    acc = %{memory: counting_memory(ref, 4)}

    assert {^acc,
            %{
              compacted: false,
              tokens_before: before,
              tokens_after: before,
              tokens_removed: 0,
              strategy: :oldest_first,
              dropped: []
            }} =
             WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, reserved_tokens: 16)

    assert before == Normandy.Context.WindowManager.estimate_conversation_tokens(acc.memory)
    assert CountingContent.count(ref) == 4
  end

  test "tokens_removed counts what the model is sent for a chat message, as tokens_before does" do
    memory =
      Enum.reduce(1..10, AgentMemory.initialize_turn(AgentMemory.new_memory()), fn i, m ->
        AgentMemory.add_message(m, "user", %BaseAgentInputSchema{
          chat_message: "this turn message #{i} with padding text"
        })
      end)

    {_acc, meta} =
      WMCompactor.maybe_compact(%{memory: memory}, %{model: "m", window: 80}, reserved_tokens: 16)

    assert meta.compacted
    assert meta.tokens_removed == Enum.sum(Enum.map(meta.dropped, & &1.tokens))
    assert meta.tokens_removed == meta.tokens_before - meta.tokens_after
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/context/compaction_cache_test.exs`
Expected: `1 property, 6 tests, 6 failures`: the property and the two `keep_entries/3` tests with
`UndefinedFunctionError ... AgentMemory.keep_entries/3 is undefined or private`; the two counting tests
with a count above 40 / 20 (the rebuild re-encodes every kept message); the `tokens_removed` test
with `tokens_removed` above `tokens_before - tokens_after` (it estimates `{"chat_message": ...}` JSON).
`"a conversation within the window ..."` passes already: it pins the no-op meta Step 4 must keep.

- [ ] **Step 3: `AgentMemory.keep_entries/3`**

In `lib/normandy/components/agent_memory.ex`, after `@add_message_opts_schema ...` add:

```elixir
  @keep_entries_opts_schema NimbleOptions.new!(
                              summary: [
                                type: {:or, [{:tuple, [:string, :any]}, nil]},
                                default: nil,
                                doc:
                                  "`{role, content}` of a message stored first, as a new " <>
                                    "entry of the current turn (a compaction summary)."
                              ]
                            )
```

After `add_message/4` add:

```elixir
  @doc false
  # The memory compaction leaves: `memory`'s cap and current turn, holding the
  # `:summary` message (if any) and then `kept` (entries of `memory`'s active branch,
  # oldest first) under their own ids and turns, re-linked into one chain. Kept entries
  # lose their thinking: it was produced with the removed messages in place. Built in
  # one pass; an entry whose content is unchanged keeps its cached encoding, and the
  # cap is enforced once, at the end.
  @spec keep_entries(t(), [Entry.t()], keyword()) :: t()
  def keep_entries(%__MODULE__{} = memory, kept, opts \\ []) when is_list(kept) do
    opts = Options.validate!(opts, @keep_entries_opts_schema, {__MODULE__, :keep_entries, 3})
    summary = Keyword.fetch!(opts, :summary)
    # A memory with no current turn gets one once it holds a message, as add_message/4 does.
    turn_id = memory.current_turn_id || if(summary || kept != [], do: UUID.uuid4())

    lead =
      case summary do
        nil ->
          []

        {role, content} ->
          [put_content(%Entry{id: UUID.uuid4(), turn_id: turn_id, role: role}, content)]
      end

    {entries, head} =
      Enum.reduce(lead ++ Enum.map(kept, &strip_thinking/1), {%{}, nil}, &link_entry/2)

    enforce_max_messages(%__MODULE__{
      entries: entries,
      head: head,
      current_turn_id: turn_id,
      max_messages: memory.max_messages
    })
  end
```

After `fill_entry/1` (6.1a) add:

```elixir

  defp link_entry(%Entry{id: id} = entry, {entries, parent_id}),
    do: {Map.put(entries, id, %Entry{entry | parent_id: parent_id}), id}
```

(The cap enforced once at the end gives what enforcing it after every append gave; the property in
Step 1 checks it for caps 1–6.)

- [ ] **Step 4: The compactor estimates once**

In `lib/normandy/behaviours/compactor/window_manager.ex`:

Moduledoc: replace the paragraph starting `Triggered at the turn's \`:steering\` boundary:` (through
`thinking (see "Compacting mid-round" in \`Normandy.Behaviours.Compactor\`).`) with:

```elixir
  Triggered at the turn's `:steering` boundary: builds a `WindowManager` sized to the
  model's context window (`ctx.window`, unless `opts` pins `:context_window`) and estimates
  the conversation once, summing each message's estimate cached on its entry
  (`Normandy.Components.AgentMemory.Entry`). Under budget it changes nothing, so a
  mid-round boundary (`ctx.mid_round`) leaves the open tool round and its thinking alone
  until the conversation no longer fits; over budget it delegates to
  `WindowManager.truncate_conversation/2`, and a compaction strips the kept messages'
  thinking (see "Compacting mid-round" in `Normandy.Behaviours.Compactor`).
```

Delete `alias Normandy.Components.BaseIOSchema`. Replace the head of `run/2`, from
`defp run(acc, manager) do` through `case WM.ensure_within_limit(acc, manager) do`, with:

```elixir
  # One estimate (a sum of the entries' cached estimates). Within budget nothing else
  # runs: the meta is the no-op one, with no dropped entries, so after_compact does not run.
  defp run(acc, manager) do
    before = WM.estimate_conversation_tokens(acc.memory)

    if before <= manager.max_tokens - manager.reserved_tokens do
      {acc,
       %{
         compacted: false,
         tokens_before: before,
         tokens_after: before,
         tokens_removed: 0,
         strategy: manager.strategy,
         dropped: []
       }}
    else
      compact(acc, manager, before)
    end
  end

  defp compact(acc, manager, before) do
    case WM.truncate_conversation(acc, manager) do
```

(the rest of the old `run/2` body, the `{:ok, acc2}` and `{:error, reason}` branches, stays as the
body of `compact/3`). The within-budget test is the one `within_limit?/2` made
(`current <= max_tokens - reserved_tokens`), so behaviour is unchanged.

Replace `tokens_removed_this_turn/2` and its comment:

```elixir
  # Gross estimated tokens of the dropped messages that belong to the current turn:
  # what the task budget's `remaining` must subtract (Anthropic task-budgets doc,
  # "Carrying a budget across compaction"). Earlier turns were never this task's
  # spend, and a summary is new, so it is never dropped. Each message counts its
  # cached estimate (what the model is sent for it, plus 10 tokens of per-message
  # overhead), the same estimate `tokens_before` sums; it approximates, it is not the
  # exact request payload.
  defp tokens_removed_this_turn(before_memory, dropped) do
    turn_id = AgentMemory.get_current_turn_id(before_memory)

    dropped
    |> Enum.filter(&(&1.turn_id == turn_id))
    |> Enum.map(&AgentMemory.entry_tokens/1)
    |> Enum.sum()
  end
```

- [ ] **Step 5: `Context.WindowManager` reads cached estimates and rebuilds in one pass**

In `lib/normandy/context/window_manager.ex`, in `truncate_oldest_first/2` replace the `else` branch
(from `# Remove oldest messages until under limit.` through `{:ok, %{agent | memory: new_memory}}`) with:

```elixir
      # Remove oldest messages until under limit, reading each message's cached
      # estimate (AgentMemory.Entry's `tokens`).
      entries = AgentMemory.entry_chain(agent.memory)

      # Start the kept window at a user message (see AgentMemory.keep_count/2);
      # a newest message larger than the target keeps its turn rather than
      # emptying the memory.
      keep =
        entries
        |> Enum.reverse()
        |> Enum.map(& &1.role)
        |> AgentMemory.keep_count(max(newest_fitting(entries, target_tokens), 1))

      # Each kept message stays under its entry id (a compactor reports what it dropped
      # by entry id) and turn, with its stored content.
      new_memory = AgentMemory.keep_entries(agent.memory, Enum.take(entries, -keep))
      {:ok, %{agent | memory: new_memory}}
```

Replace `estimate_messages_for_tokens/2`, `split_to_fit/2` and `rebuild_memory/2` (all three, to the
end of the module) with:

```elixir
  # Keep at least 5 messages.
  defp estimate_messages_for_tokens(memory, target_tokens),
    do: memory |> AgentMemory.entry_chain() |> newest_fitting(target_tokens) |> max(5)

  # How many of the newest entries fit in `target_tokens` together (cached estimates).
  defp newest_fitting(entries, target_tokens) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while({0, 0}, fn entry, {count, tokens} ->
      entry_tokens = AgentMemory.entry_tokens(entry)

      if tokens + entry_tokens <= target_tokens do
        {:cont, {count + 1, tokens + entry_tokens}}
      else
        {:halt, {count, tokens}}
      end
    end)
    |> elem(0)
  end
end
```

(`newest_fitting/2` counts what `length(fitting)` from `split_to_fit/2` counted: the same reduction
over the same per-message estimate.)

- [ ] **Step 6: The summarizer rebuilds with `keep_entries/3`**

In `lib/normandy/context/summarizer.ex`, delete `rebuild_memory_with_summary/4` (the function, from
`defp rebuild_memory_with_summary(` to its `end`). In `do_compress_conversation/7`'s `{:ok, summary}`
branch replace

```elixir
        # Create new memory with summary + recent messages
        new_memory =
          rebuild_memory_with_summary(
            agent.memory,
            summary,
            summary_role,
            Enum.zip(recent_messages, recent_entries(agent.memory, length(recent_messages)))
          )
```

with

```elixir
        # The summary goes first, as plain text: wrapped in a schema it reached the
        # model as {"chat_message": ...} JSON, which Haiku 4.5 read as data, not
        # conversation. The recent messages follow under their own ids and turns.
        new_memory =
          AgentMemory.keep_entries(
            agent.memory,
            recent_entries(agent.memory, length(recent_messages)),
            summary: {summary_role, summary_message(summary)}
          )
```

Check: `grep -rn "rebuild_memory\|split_to_fit\|ensure_within_limit" lib/normandy/context lib/normandy/behaviours`
prints only `ensure_within_limit/2`'s own definition and docs in `context/window_manager.ex` (it stays
public).

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/context/compaction_cache_test.exs test/behaviours/compactor_test.exs test/context/window_manager_test.exs test/context/summarizer_test.exs test/agents/mid_round_compaction_test.exs test/hooks/server_hooks_test.exs test/agents/wire_identity_test.exs`
Expected: PASS (`compaction_cache_test.exs` 1 property, 6 tests; `compactor_test.exs` unchanged, including
`"removing this turn's messages reports their estimate (equals the net drop without a summary)"`, whose
raw-string messages estimate the same either way).

- [ ] **Step 8: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. Tagged suites: none.

- [ ] **Step 9: MIGRATING-2.0.md**

Append to `## 38.`:

```markdown
- `Compactor.WindowManager`'s `tokens_removed` sums the dropped messages' cached estimates, the
  same estimate `tokens_before` and `tokens_after` sum, instead of estimating each message's
  `BaseIOSchema.to_json/1`. For the default chat schemas the model is sent the text, not
  `{"chat_message": ...}` JSON, so `tokens_removed` is a few tokens lower per such message and,
  when no summary is added, equals `tokens_before - tokens_after`. With `:task_budget`, the
  `remaining` sent after a compaction moves with it.
- Compaction keeps each kept message's encoding; only a message whose thinking it strips is
  encoded again.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/behaviours/compactor/window_manager.ex \
  lib/normandy/context/window_manager.ex lib/normandy/context/summarizer.ex MIGRATING-2.0.md \
  test/context/compaction_cache_test.exs
git commit -m "perf(compaction): estimate once and rebuild memory in one pass"
```

---

### Task 6.1d: Acceptance — Normandy encodes each message once (PERF-3/B1, R1)

R1's acceptance: Normandy-side message encodings are O(N) in total over N turns. Counted with
`Normandy.Test.CountingContent` (memory content) and a counting `Jason.Encoder` for a tool's output,
on `run/3`, `stream/3` and `Turn.Session` (rehydration included), with and without a compactor and
across a real compaction. The counts are per message and do not depend on N. This task adds tests
only; they pass on 6.1a–6.1c. Measured on `d624fbf` with the same file (planning run): the seeded
6 messages counted 12 / 96 encodings after 1 / 8 turns (`run/3` and `stream/3`) and 48 / 384 with
`Compactor.WindowManager`; every one of the 11 tests failed.

**Files:**
- Test: create `test/agents/linear_history_test.exs`

**Interfaces:**
- Consumes: `Normandy.Test.CountingContent` (6.1a), `Normandy.Test.WireScript.client/2`, `message/3`, `block/3`, `Normandy.Test.ReturnTool`, `Normandy.Test.Eventually.wait_until/1`.
- Produces: nothing.

- [ ] **Step 1: Write the acceptance tests**

Create `test/agents/linear_history_test.exs`:

```elixir
defmodule Normandy.Agents.LinearHistoryTest do
  @moduledoc """
  Task 6.1d (PERF-3/B1, R1): Normandy encodes each message once, however long the
  conversation grows. Over N turns, K seeded messages stay at K encodings and every tool
  result costs the same number of encodings, on `BaseAgent.run/3`, `BaseAgent.stream/3`
  and `Turn.Session` (whose rehydration encodes each stored message once more), with and
  without a compactor. Before Task 6.1 the counts grew with N² (`model_content/1` ran
  100, 400 and 1600 times over 10, 20 and 40 turns; four times that with
  `Compactor.WindowManager`).

  Counted: `BaseIOSchema.to_json/1` of `Normandy.Test.CountingContent` (memory content)
  and `Jason.Encoder.encode/2` of `CountingOutput` (a tool's output: Dispatch encodes it
  four times, in `execute/4`'s and `finish/3`'s encodability checks, `wrap_output/2` and
  the result cap, and memory once, when the result is appended).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Test.CountingContent
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule CountingOutput do
    @moduledoc false
    defstruct [:ref]

    defimpl Jason.Encoder do
      def encode(%{ref: ref}, opts) do
        :counters.add(ref, 1, 1)
        Jason.Encode.map(%{"rows" => 3}, opts)
      end
    end
  end

  # Encodings per tool result: Dispatch's four, memory's one. Constant in N.
  @per_result 5
  @seeded 6
  @no_compaction {Compactor.WindowManager, context_window: 1_000_000, reserved_tokens: 1_000}

  defp seeded_memory(ref) do
    Enum.reduce(1..@seeded, AgentMemory.new_memory(), fn i, m ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      AgentMemory.add_message(m, role, CountingContent.new(ref, "seeded message #{i}"))
    end)
  end

  # One tool round per turn: a tool_use, then the answer.
  defp blocks(turn) do
    [
      {[%{"type" => "tool_use", "id" => "t#{turn}", "name" => "rows", "input" => %{}}],
       "tool_use"},
      {[%{"type" => "text", "text" => "answer #{turn}"}], "end_turn"}
    ]
  end

  defp json_replies(turns),
    do: for(t <- turns, {content, stop} <- blocks(t), do: {:json, content, stop})

  defp sse_replies(turns) do
    for t <- turns, {[block], stop} <- blocks(t) do
      events =
        case block do
          %{"type" => "tool_use"} ->
            WireScript.block(0, block, [%{"type" => "input_json_delta", "partial_json" => "{}"}])

          %{"type" => "text", "text" => text} ->
            WireScript.block(0, %{"type" => "text", "text" => ""}, [
              %{"type" => "text_delta", "text" => text}
            ])
        end

      {:sse, WireScript.message("msg_#{t}", events, stop)}
    end
  end

  defp agent(client, out, memory, compactor) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      max_tokens: 1_000,
      memory: memory,
      toolset: Toolset.new([%ReturnTool{name: "rows", output: %CountingOutput{ref: out}}]),
      behaviours: %Normandy.Behaviours.Config{compactor: compactor}
    })
  end

  defp counters, do: {CountingContent.counter(), CountingContent.counter()}

  for path <- [:run, :stream],
      compactor <- [:none, :window_manager],
      turns <- [1, 8] do
    @tag path: path, compactor: compactor, turns: turns
    test "#{path}, compactor #{compactor}, #{turns} turns: each message is encoded once", %{
      path: path,
      compactor: compactor,
      turns: turns
    } do
      {seeded, out} = counters()
      compactor = if compactor == :none, do: {Compactor.NoOp, []}, else: @no_compaction

      client =
        case path do
          :run -> WireScript.client(json_replies(1..turns))
          :stream -> WireScript.client(sse_replies(1..turns))
        end

      config = agent(client, out, seeded_memory(seeded), compactor)

      Enum.reduce(1..turns, config, fn t, config ->
        {:ok, config, _} =
          case path do
            :run -> BaseAgent.run(config, "question #{t}")
            :stream -> BaseAgent.stream(config, "question #{t}", fn _event -> :ok end)
          end

        config
      end)

      assert CountingContent.count(seeded) == @seeded
      assert CountingContent.count(out) == @per_result * turns
    end
  end

  test "a compaction during the conversation encodes no kept message again" do
    {seeded, out} = counters()
    turns = 8
    # Small enough that the seeded messages are cut once the conversation grows.
    compactor = {Compactor.WindowManager, context_window: 1_150, reserved_tokens: 1_000}

    config =
      agent(WireScript.client(json_replies(1..turns)), out, seeded_memory(seeded), compactor)

    final =
      Enum.reduce(1..turns, config, fn t, config ->
        {:ok, config, _} = BaseAgent.run(config, "question #{t}")
        config
      end)

    refute Enum.any?(
             AgentMemory.entry_chain(final.memory),
             &match?(%Entry{content: %CountingContent{}}, &1)
           )

    assert CountingContent.count(seeded) == @seeded
    assert CountingContent.count(out) == @per_result * turns
  end

  for turns <- [1, 8] do
    @tag turns: turns
    test "Turn.Session, #{turns} turns: each message is encoded once, and once more per rehydration",
         %{turns: turns} do
      {seeded, out} = counters()
      store = InMemory.new()
      reg = Native.new()
      {:ok, sup} = Turn.Supervisor.start_link([])
      sid = "linear-#{System.unique_integer([:positive])}"

      # The server's memory is the store's history, so the seeded messages go there.
      for entry <- AgentMemory.entry_chain(seeded_memory(seeded)) do
        {:ok, _} = InMemory.append_entry(store, sid, %{entry | wire: nil, tokens: nil})
      end

      seed_encodings = CountingContent.count(seeded)

      session =
        Turn.Session.new(
          session_id: sid,
          config:
            agent(
              WireScript.client(json_replies(1..(turns + 1))),
              out,
              AgentMemory.new_memory(),
              @no_compaction
            ),
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: sup
        )

      for t <- 1..turns, do: assert({:ok, _} = Turn.Session.run(session, "question #{t}"))

      assert CountingContent.count(seeded) == seed_encodings + @seeded
      assert CountingContent.count(out) == @per_result * turns

      # A restart rebuilds the memory from the store: every stored message once more.
      {:ok, pid} = Native.whereis(reg, sid)
      Process.exit(pid, :kill)
      assert wait_until(fn -> match?({:ok, new} when new != pid, Native.whereis(reg, sid)) end)

      assert {:ok, _} = Turn.Session.run(session, "question #{turns + 1}")
      assert CountingContent.count(seeded) == seed_encodings + 2 * @seeded
      # turns results rehydrated once each, plus the new turn's result.
      assert CountingContent.count(out) == @per_result * turns + turns + @per_result
    end
  end
end
```

- [ ] **Step 2: Run the tests**

Run: `mix format && mix test test/agents/linear_history_test.exs` (and once more to see it stable).
Expected: `11 tests, 0 failures`. A failure prints the count; a count that grows with the turn
count means a path re-encodes history (find it with
`:erlang.trace_pattern({Normandy.Components.AgentMemory, :put_content, 2}, true, [:local, :call_count])`).

- [ ] **Step 3: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1d.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1d.log`.
Expected: ` 0 failures`, exit 0. Tagged suites: none (InMemory only).

- [ ] **Step 4: Commit**

```bash
git add test/agents/linear_history_test.exs
git commit -m "test(agents): each message is encoded once over a conversation (PERF-3)"
```

---

### Task 6.1e: Prompt caching on by default; Claudio `Request.add_messages/2` (R2, R4)

Two parts, two repositories. **Part A (Normandy):** `ClaudioAdapter`'s `options[:enable_caching]`
defaults to `true` (R4, 6.1 Q5 ii); `false` opts out. **Part B (Claudio):** the bulk
`Claudio.Messages.Request.add_messages/2` that makes building a request linear (R2), on a new local
branch `feat/add-messages` of `/Users/antonio/personal/claudio`, committed, never pushed or published.
Normandy's `add_messages/3` (`claudio_adapter.ex`) does **not** switch to it in this wave: that rides
Task 7.5's Claudio 0.7.1 bump. Until then a request build stays quadratic inside Claudio only
(≈4.5 ms at 1200 messages, measured).

**Files (Part A):**
- Modify: `lib/normandy/llm/claudio_adapter.ex` (moduledoc "Configuration"; `build_request/3`)
- Modify: `MIGRATING-2.0.md` (`## 38.`)
- Test: modify `test/llm/claudio_adapter_caching_test.exs` (`sent_body/2`, one new test), `test/agents/tool_loop_output_format_test.exs` (the `"run/3, #{route}: #{outcome}"` tests' system assertion)

**Files (Part B, in `/Users/antonio/personal/claudio`):**
- Modify: `lib/claudio/messages/request.ex` (`add_message/3` → shared private `build_message/4`; new `add_messages/2`)
- Modify: `CHANGELOG.md` (`## [Unreleased]`)
- Test: modify `test/request_test.exs` (new `describe "add_messages/2"`)

**Interfaces:**
- Consumes: Part A: `Map.get(client.options, :enable_caching, ...)` in `build_request/3` (the one request builder for every call path). Part B: Claudio's `normalize_content/1`, `add_beta/2` and the replay-beta helpers (unchanged).
- Produces: `client.options[:enable_caching]` default `true` (header); `Claudio.Messages.Request.add_messages(request, [{role, content}]) :: Request.t()` on Claudio branch `feat/add-messages` (consumed by Task 7.5).

#### Part A — Normandy

- [ ] **Step 1: Write the failing test**

In `test/llm/claudio_adapter_caching_test.exs`, `describe "prompt caching on the wire"`: replace
`defp sent_body(name, enable_caching) do` with

```elixir
    # `caching`: the :enable_caching option to set, or :unset to leave it out.
    defp sent_body(name, caching) do
```

and in its body replace

```elixir
        options: %{
          enable_caching: enable_caching,
          req_options: [plug: {Req.Test, name}, retry: false]
        }
```

with

```elixir
        options:
          Map.merge(
            %{req_options: [plug: {Req.Test, name}, retry: false]},
            if(caching == :unset, do: %{}, else: %{enable_caching: caching})
          )
```

Before `test "caching off: no breakpoints at all" do` add:

```elixir
    test "caching is on when the option is left out (the 2.0 default)" do
      assert sent_body(__MODULE__.Unset, :unset) == sent_body(__MODULE__.OnToo, true)
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix format && mix test test/llm/claudio_adapter_caching_test.exs`
Expected: `1 failure`, `"caching is on when the option is left out (the 2.0 default)"`: the left body
has no `"cache_control"` and a string `"system"`.

- [ ] **Step 3: Flip the default**

In `lib/normandy/llm/claudio_adapter.ex`, `build_request/3`: replace
`enable_caching = Map.get(client.options, :enable_caching, false)` with

```elixir
      # On unless the client opts out (MIGRATING-2.0.md §38).
      enable_caching = Map.get(client.options, :enable_caching, true)
```

Check: `grep -rn "enable_caching, false" lib` prints nothing. (`TokenCounter` passes `false` to
`add_messages/3` explicitly for `count_tokens`; unchanged.)

Moduledoc, "## Configuration": replace
`The adapter reads these keys from \`options\` (a map). Nothing below is sent unless set:` with

```
  The adapter reads these keys from `options` (a map). Nothing below is sent unless set,
  except prompt caching, which is on unless `:enable_caching` is `false`:
```

and replace the `:enable_caching` bullet (`- \`:enable_caching\` - Prompt caching (default: false): ...`
through `most one more, or the API rejects the request`) with:

```
  - `:enable_caching` - Prompt caching (default: `true`; `false` turns it off): an
    explicit breakpoint on the system prompt and the last tool, plus the API's automatic
    breakpoint for the conversation. Keep context-provider output stable across calls, or
    the cache stops at the system prompt. Normandy uses 3 of the API's 4 cache breakpoints
    (system, last tool, automatic); callers who add their own `cache_control` markers can
    add at most one more, or the API rejects the request. A cache write costs 1.25 times
    the input price and a cache read 0.1 times, so an agent that makes one call per
    conversation pays more with it on; a tool loop, which re-sends its prefix on every
    call, pays less
```

- [ ] **Step 4: The test that read the system prompt as a string**

With caching on, a `WireScript` client without options sends the system prompt as one cached text
block. In `test/agents/tool_loop_output_format_test.exs`, in the `"run/3, #{route}: #{outcome}"` test
(inside `for route <- [:off, :rejected], {answer, outcome} <- @outcomes`), replace
`assert body["system"] =~ "# OUTPUT SCHEMA"` with

```elixir
        # Caching is on by default (MIGRATING-2.0.md §38): the system prompt is one block.
        assert [%{"text" => system, "cache_control" => %{"type" => "ephemeral"}}] = body["system"]
        assert system =~ "# OUTPUT SCHEMA"
```

These six generated tests are the only ones the flip breaks in the default suite (full run with the
flip only: `6 failures`, all `Kernel.=~/2` given a list). `test/agents/wire_identity_test.exs` sets
`enable_caching` explicitly, so its fixtures stand.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/llm/claudio_adapter_caching_test.exs test/agents/tool_loop_output_format_test.exs test/agents/wire_identity_test.exs test/readme_test.exs`
Expected: PASS (the first two files: 41 tests).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1e.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1e.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. Tagged suites: none.

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 38.`:

```markdown
- Prompt caching is on by default: `Normandy.LLM.ClaudioAdapter`'s `options[:enable_caching]`
  defaults to `true` (it was `false`). Requests carry the breakpoints listed in §8 (system
  prompt, last tool, the API's automatic one), and the system prompt goes out as one text block
  instead of a string. A cache write costs 1.25 times the input price and a cache read 0.1
  times: an agent that makes one call per conversation pays more; a tool loop, which re-sends
  its whole prefix on every iteration, pays less. Set `enable_caching: false` to opt out, and
  on a `base_url` gateway that rejects top-level `cache_control`.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/llm/claudio_adapter.ex MIGRATING-2.0.md \
  test/llm/claudio_adapter_caching_test.exs test/agents/tool_loop_output_format_test.exs
git commit -m "feat(llm)!: prompt caching is on by default"
```

#### Part B — Claudio `Request.add_messages/2` (local branch, never pushed)

All commands in `/Users/antonio/personal/claudio`. Never `git push`, never `mix hex.publish`, never
change `@version`.

- [ ] **Step 9: Branch from `main`**

Run: `git -C /Users/antonio/personal/claudio status --short` — Expected: only untracked entries
(`?? .claude/worktrees/`, `?? Claudio` on 2026-10-06); stop and report to the controller if a tracked
file is modified. Run: `git -C /Users/antonio/personal/claudio rev-parse --abbrev-ref HEAD` → `main`,
`git -C /Users/antonio/personal/claudio log -1 --format=%h` → `005c51d` (`chore(release): date 0.7.0`);
if either differs, stop and report. Then:
`git -C /Users/antonio/personal/claudio switch -c feat/add-messages`.

- [ ] **Step 10: Write the failing tests**

In `test/request_test.exs`, before `describe "add_message/3 with a fallback block" do`, add:

```elixir
  describe "add_messages/2" do
    # Every content shape add_message/3 treats specially, in one conversation.
    @conversation [
      {:user, "What is the weather?"},
      {:assistant,
       [
         %{"type" => "fallback", "from" => %{"model" => "a"}, "to" => %{"model" => "b"}},
         %{"type" => "text", "text" => "Checking."}
       ]},
      {:user, [%{"type" => "text", "text" => "go on"}]},
      {:assistant, [%{"type" => "compaction", "content" => "s", "signature" => "sig"}]},
      {:assistant, [%{"type" => "compaction", "content" => "s"}]},
      {:assistant, [%{type: :server_tool_use, id: "s", name: "advisor", input: %{}}]},
      {:assistant,
       [%{"type" => "mcp_tool_use", "id" => "m", "name" => "x", "server_name" => "s"}]},
      {:user, [%{type: :text, text: "typed", citations: nil}]}
    ]

    defp one_by_one(request, messages),
      do:
        Enum.reduce(messages, request, fn {role, content}, acc ->
          Request.add_message(acc, role, content)
        end)

    test "equals add_message/3 once per message: messages, order and betas" do
      base =
        Request.new("m")
        |> Request.add_message(:user, "earlier")
        |> Request.add_beta("context-management-2025-06-27")

      assert Request.add_messages(base, @conversation) == one_by_one(base, @conversation)

      assert Request.required_betas(Request.add_messages(base, @conversation)) == [
               "context-management-2025-06-27",
               "server-side-fallback-2026-07-01",
               "compact-2026-09-04",
               "compact-2026-01-12",
               "advisor-tool-2026-03-01",
               "mcp-client-2025-11-20"
             ]
    end

    test "an empty list leaves the request as it is" do
      request = Request.add_message(Request.new("m"), :user, "hi")
      assert Request.add_messages(request, []) == request
    end

    test "raises as add_message/3 does, naming add_messages/2" do
      request = Request.new("m")

      assert_raise ArgumentError,
                   "Request.add_messages/2: content must be a string or a list of content blocks; got nil",
                   fn -> Request.add_messages(request, [{:user, "ok"}, {:assistant, nil}]) end

      assert_raise ArgumentError,
                   "Request.add_messages/2: :system is not a message role. Use set_system/2 for " <>
                     "the system prompt, or add_system_message/3 for a mid-conversation system message",
                   fn -> Request.add_messages(request, [{:system, "be terse"}]) end

      assert_raise ArgumentError,
                   ~s|Request.add_messages/2: role must be :user or :assistant; got "user"|,
                   fn -> Request.add_messages(request, [{"user", "hi"}]) end

      assert_raise ArgumentError,
                   "Request.add_messages/2: each message must be a {role, content} tuple",
                   fn -> Request.add_messages(request, [%{role: :user, content: "hi"}]) end
    end

    test "add_message/3 keeps its own name in its errors" do
      assert_raise ArgumentError,
                   "Request.add_message/3: content must be a string or a list of content blocks; got nil",
                   fn -> Request.add_message(Request.new("m"), :user, nil) end
    end
  end

```

- [ ] **Step 11: Run the tests to verify they fail**

Run: `mix format && mix test test/request_test.exs`
Expected: `241 tests, 3 failures` — the three `add_messages/2` tests with
`UndefinedFunctionError ... Claudio.Messages.Request.add_messages/2 is undefined or private`
(`"add_message/3 keeps its own name in its errors"` passes already).

- [ ] **Step 12: Implement**

In `lib/claudio/messages/request.ex`, replace the four `add_message/3` clauses (from
`def add_message(%__MODULE__{}, role, nil) when role in [:user, :assistant] do` through the clause
raising `"Request.add_message/3: role must be :user or :assistant; got ..."`; keep the `@doc` and
`@spec` above them) with:

```elixir
  def add_message(%__MODULE__{messages: messages} = request, role, content) do
    {message, request} = build_message(request, role, content, "add_message/3")
    %{request | messages: messages ++ [message]}
  end

  @doc """
  Adds `messages`, a list of `{role, content}` tuples, to the conversation in order.

  The result equals calling `add_message/3` once per element: the same checks (each
  raises `ArgumentError` naming `add_messages/2`), the same content normalization and
  the same replay betas, declared in the same order. It takes time linear in the number
  of messages, where a loop of `add_message/3` is quadratic (each call appends to the
  list), so build a long conversation with it.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_messages([
        {:user, "What is the weather in Paris?"},
        {:assistant, "Sunny."},
        {:user, "And in Lyon?"}
      ])
  """
  @spec add_messages(t(), [{role(), content()}]) :: t()
  def add_messages(%__MODULE__{messages: messages} = request, new_messages)
      when is_list(new_messages) do
    {built, request} =
      Enum.map_reduce(new_messages, request, fn
        {role, content}, acc ->
          build_message(acc, role, content, "add_messages/2")

        _other, _acc ->
          raise ArgumentError,
                "Request.add_messages/2: each message must be a {role, content} tuple"
      end)

    %{request | messages: messages ++ built}
  end

  # One message in the API's shape, and the request with the betas its content needs.
  # `fun` names the public function in error messages.
  defp build_message(%__MODULE__{}, role, nil, fun) when role in [:user, :assistant] do
    raise ArgumentError,
          "Request.#{fun}: content must be a string or a list of content blocks; got nil"
  end

  defp build_message(%__MODULE__{} = request, role, content, _fun)
       when role in [:user, :assistant] do
    message = %{
      "role" => to_string(role),
      "content" => normalize_content(content)
    }

    # Replaying a `fallback` block (Response.to_assistant_content/1) needs the beta even
    # on a turn that does not set fallbacks (400 without it, probed 2026-09-25).
    request =
      if has_fallback_block?(content), do: add_beta(request, @fallback_beta), else: request

    # A replayed compaction block needs its beta: signed (on-demand) blocks need
    # compact-2026-09-04, unsigned (threshold) blocks compact-2026-01-12 (probed 2026-09-26).
    request = add_compaction_replay_betas(request, content)

    # Replaying advisor blocks needs the advisor beta even without the tool (probed 2026-09-26).
    request = if has_advisor_block?(content), do: add_beta(request, @advisor_beta), else: request

    # Replaying MCP blocks needs the connector beta even without a server (probed 2026-10-05).
    request = if has_mcp_block?(content), do: add_beta(request, @mcp_beta), else: request

    {message, request}
  end

  defp build_message(%__MODULE__{}, :system, _content, fun) do
    raise ArgumentError,
          "Request.#{fun}: :system is not a message role. Use set_system/2 for the " <>
            "system prompt, or add_system_message/3 for a mid-conversation system message"
  end

  defp build_message(%__MODULE__{}, role, _content, fun) do
    raise ArgumentError,
          "Request.#{fun}: role must be :user or :assistant; got #{inspect(role)}"
  end
```

(`add_message/3`'s messages are unchanged: `fun` is `"add_message/3"` there.)

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```markdown

### Added

- `Request.add_messages/2` adds a list of `{role, content}` messages in one call, in time linear in
  their number (a loop of `add_message/3` is quadratic). It applies `add_message/3`'s checks,
  content normalization and replay betas; errors name `add_messages/2`.
```

- [ ] **Step 13: Run the tests to verify they pass**

Run: `mix format && mix test test/request_test.exs && mix test`
Expected: `241 tests, 0 failures`; full suite ` 0 failures` (864 tests, 52 excluded on 2026-10-06).

- [ ] **Step 14: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1e-claudio.log; grep -E " [0-9]+ failures|Total errors|found no issues" /tmp/w6-6.1e-claudio.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, credo `found no issues`, dialyzer passes, exit 0; docs exit 0. (The first
dialyzer run may build PLTs under `_build/plts`.)

- [ ] **Step 15: Commit (local only) and leave `main` checked out**

```bash
git -C /Users/antonio/personal/claudio add lib/claudio/messages/request.ex test/request_test.exs CHANGELOG.md
git -C /Users/antonio/personal/claudio commit -m "feat(request): add_messages/2 builds a conversation in linear time"
git -C /Users/antonio/personal/claudio log -1 --format='%h %s'
git -C /Users/antonio/personal/claudio switch main
```

Report the commit hash to the controller (Task 7.5 consumes it). Do not push.

---

### Task 6.1f: Model-facing JSON text lists plain-map keys sorted (decision 25, A1)

On OTP 26+ a small atom-keyed map iterates its keys in atom-creation order, so a tool that returns
a plain atom-keyed map can produce different `tool_result` text for the same result on two nodes or
after a restart: the prompt-cache prefix misses, and caching is on by default since 6.1e. Every
model-visible JSON text Normandy builds from a message's plain map goes through two functions, and
both now sort: `ToolResult.render_output/1` (the `tool_result` text, which `AgentMemory.model_content/1`
caches in `Entry.wire` through `ToolResult`'s `BaseIOSchema.to_json/1`, and which `Dispatch.finish/3`'s
cap measures) and `BaseIOSchema`'s `Map` impl (a plain map given as message content; also the A2A
server's and `HierarchicalCoordinator`'s text for a map answer). Both call the new
`@doc false Normandy.JSON.sort_keys/1`: every plain map, at any depth, becomes a
`Jason.OrderedObject` with its keys sorted by their JSON text (ties such as `"a"` and `:a` by term
order); a struct goes through `Normandy.JSON`'s struct rule as before (not sorted); a
`Jason.OrderedObject` keeps its order and its values are walked. Values and list order never change,
so 6.1a's decoded fixture still passes (its JSON tool result is string-keyed, already in order; its
io_schema input is a struct).

Not changed (rulings, recorded in `wave-6-sections/PREFLIGHT.md`):
- **io_schema structs** (`Normandy.Schema`'s `BaseIOSchema.to_json/1`, `__serializable__/1`): a struct
  keeps its encoding (decision 25: structs untouched). Sorting it would also change 6.1a's fixture
  (`{"text":...,"lang":...}` would become `{"lang":...,"text":...}`), which this task must keep.
- **The system prompt's `# OUTPUT SCHEMA` block and `RetryFeedback`'s schema**: their maps are
  Normandy's compile-time JSON Schema specifications, keyed by keyword atoms (`:type`,
  `:description`, `:required`, `:properties`) that exist before host code runs; properties are
  already an `OrderedObject` in declaration order. Sorting would move `"type"` after `"properties"`
  in every structured-output prompt, with no instability observed.
- **`Summarizer`'s transcript** reads `history/1`, whose tool results and map content are the sorted
  cached text; only a map handed to `summarize_messages/4` directly is encoded there, for a one-off
  request that is never a cached prefix. **`TokenCounter`**'s `count_tokens` text and the token
  estimates only measure length, which sorting does not change.

**Files:**
- Modify: `lib/normandy/json.ex` (moduledoc "## Text for the model"; new `sort_keys/1`, `key_text/1`)
- Modify: `lib/normandy/components/tool_result.ex` (`render_output/1`)
- Modify: `lib/normandy/components/base_io_schema.ex` (`Map` impl)
- Modify: `MIGRATING-2.0.md` (`## 38.`)
- Test: create `test/agents/model_text_key_order_test.exs`

**Interfaces:**
- Consumes: `Normandy.JSON.normalize/1` (private, the struct rule), `Normandy.Test.WireScript.client/2`, `message/3`, `block/3` (6.1a), `Normandy.Test.ReturnTool`. After 6.1a, `AgentMemory.put_content/2` stores `model_content(content)` in `Entry.wire`; this task changes what that text is for maps, not where it is computed.
- Produces: `@doc false Normandy.JSON.sort_keys(term) :: term()` (header Shared interfaces). No new public function, option or event.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/model_text_key_order_test.exs`:

```elixir
defmodule Normandy.Agents.ModelTextKeyOrderTest do
  @moduledoc """
  Task 6.1f (decision 25, A1): the JSON text Normandy writes for the model from a plain
  map lists its keys sorted, at every depth, so the same tool result is the same text on
  every node and after a restart (a stable prompt-cache prefix). On OTP 26+ a small
  atom-keyed map iterates its keys in atom-creation order, so before this task the text
  depended on which atom the VM happened to create first.

  The keys here are atoms created at test time in reverse alphabetical order, so the
  unsorted encoding lists them zeta, mid, alpha. A struct with its own `Jason.Encoder`
  and a `Jason.OrderedObject` keep their order; values and list order never change.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.ToolResult
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule Derived do
    @moduledoc false
    @derive {Jason.Encoder, only: [:zulu, :alpha]}
    defstruct [:zulu, :alpha]
  end

  # Three atoms created now, in reverse alphabetical order (zeta, mid, alpha).
  defp fresh_keys do
    suffix = System.unique_integer([:positive])
    for name <- ["zeta", "mid", "alpha"], do: String.to_atom("#{name}_#{suffix}")
  end

  # A tool output with atom keys at three depths, a string key among them, and a list of
  # maps; and its text with every object's keys sorted.
  defp output_and_text do
    [z, m, a] = fresh_keys()
    [z2, m2, a2] = fresh_keys()

    output = %{
      z => 1,
      "beta" => "b",
      m => %{z2 => "x", a2 => "y"},
      a => [%{m2 => true, a2 => false}, 3]
    }

    text =
      ~s({"#{a}":[{"#{a2}":false,"#{m2}":true},3],"beta":"b",) <>
        ~s("#{m}":{"#{a2}":"y","#{z2}":"x"},"#{z}":1})

    {output, text}
  end

  defp result_text(output) do
    [%{content: text}] = BaseIOSchema.to_json(%ToolResult{tool_call_id: "t", output: output})
    text
  end

  describe "the encoding" do
    test "a tool's map output is sent with its keys sorted, at every depth" do
      {output, text} = output_and_text()

      assert result_text(output) == text
      assert ToolResult.render_output(output) == text
      # The same values: only the order of the keys changed.
      assert Jason.decode!(text) == Jason.decode!(Normandy.JSON.encode!(output))
    end

    test "map content is sent with its keys sorted" do
      {output, text} = output_and_text()

      assert BaseIOSchema.to_json(output) == text
    end

    test "a struct with its own encoder and an OrderedObject keep their order; maps in an OrderedObject are sorted" do
      [z, _m, a] = fresh_keys()

      output = %{
        "struct" => %Derived{zulu: 1, alpha: 2},
        "ordered" => Jason.OrderedObject.new([{"zulu", %{z => 1, a => 2}}, {"alpha", 0}])
      }

      assert result_text(output) ==
               ~s({"ordered":{"zulu":{"#{a}":2,"#{z}":1},"alpha":0},) <>
                 ~s("struct":{"zulu":1,"alpha":2}})
    end
  end

  describe "on every path" do
    @replies [
      {[%{"type" => "tool_use", "id" => "t1", "name" => "facts", "input" => %{}}], "tool_use"},
      {[%{"type" => "text", "text" => "Done."}], "end_turn"}
    ]

    defp json_replies, do: Enum.map(@replies, fn {blocks, stop} -> {:json, blocks, stop} end)

    defp sse_replies do
      for {{[block], stop}, i} <- Enum.with_index(@replies) do
        events =
          case block do
            %{"type" => "tool_use"} ->
              WireScript.block(0, block, [
                %{"type" => "input_json_delta", "partial_json" => "{}"}
              ])

            %{"type" => "text", "text" => text} ->
              WireScript.block(0, %{"type" => "text", "text" => ""}, [
                %{"type" => "text_delta", "text" => text}
              ])
          end

        {:sse, WireScript.message("msg_#{i}", events, stop)}
      end
    end

    defp agent(client, output) do
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        max_tokens: 1024,
        toolset: Toolset.new([%ReturnTool{name: "facts", output: output}])
      })
    end

    # The tool_result texts in the request that follows the tool round.
    defp sent_results do
      assert_received {:wire_body, 1, body}

      for %{"content" => blocks} when is_list(blocks) <- body["messages"],
          %{"type" => "tool_result", "content" => content} <- blocks,
          do: content
    end

    test "run/3" do
      {output, text} = output_and_text()
      config = agent(WireScript.client(json_replies()), output)

      assert {:ok, _config, _out} = BaseAgent.run(config, "go")
      assert sent_results() == [text]
    end

    test "stream/3" do
      {output, text} = output_and_text()
      config = agent(WireScript.client(sse_replies()), output)

      assert {:ok, _config, _out} = BaseAgent.stream(config, "go", fn _event -> :ok end)
      assert sent_results() == [text]
    end

    test "Turn.Server" do
      {output, text} = output_and_text()

      {:ok, srv} =
        Server.start_link(
          session_id: "key-order-#{System.unique_integer([:positive])}",
          config: agent(WireScript.client(json_replies()), output),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:ok, _out} = Server.run(srv, "go")
      assert sent_results() == [text]
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/model_text_key_order_test.exs`
Expected: `6 tests, 6 failures`. Each `left:` lists the keys in creation order, e.g.
`"{\"zeta_326\":1,\"mid_326\":{\"zeta_390\":\"x\",\"alpha_390\":\"y\"},\"alpha_326\":[...],\"beta\":\"b\"}"`
against the sorted `right:`; the struct/OrderedObject test differs only inside the `OrderedObject`
(`{"zeta_N":1,"alpha_N":2}` against `{"alpha_N":2,"zeta_N":1}`).

- [ ] **Step 3: Implement**

`lib/normandy/json.ex`. In the moduledoc, after the paragraph ending
`` it is: the adapter raises on it, and `encode/2` returns that exception. `` add:

```
  ## Text for the model

  The JSON text Normandy writes into a message for the model (a tool result's text,
  a map given as message content) lists every plain map's keys sorted by their text,
  at any depth, so the same value is the same text on every node and after a restart
  (on OTP 26+ a small atom-keyed map iterates its keys in atom-creation order). Values
  and list order are unchanged. A struct is encoded as above, and a
  `Jason.OrderedObject` keeps its order (the plain maps among its values are sorted).
  The sorted maps reach the adapter as `Jason.OrderedObject` structs, so a custom
  `:adapter` must encode those in order, as Jason does.
```

After `defp normalize(other), do: other` (before the `@doc false` of `own_encoder?/1`) add:

```elixir
  @doc false
  # "Text for the model" in the moduledoc: every plain map becomes a Jason.OrderedObject
  # with its keys sorted by their JSON text (ties, such as "a" and :a, by term order, so
  # the result never depends on the map's iteration order). A struct is normalized as
  # encode!/2 does it, not sorted; an OrderedObject keeps its order and its values are
  # walked. Callers: ToolResult.render_output/1 and BaseIOSchema's Map impl.
  @spec sort_keys(term()) :: term()
  def sort_keys(%Jason.OrderedObject{values: values} = object),
    do: %{object | values: Enum.map(values, fn {key, value} -> {key, sort_keys(value)} end)}

  def sort_keys(%_{} = struct), do: normalize(struct)

  def sort_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    |> Enum.sort_by(fn {key, _value} -> {key_text(key), key} end)
    |> Jason.OrderedObject.new()
  end

  def sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  def sort_keys(other), do: other

  # A key as Jason writes it: an atom by its name, anything else through String.Chars.
  defp key_text(key) when is_atom(key), do: Atom.to_string(key)
  defp key_text(key), do: to_string(key)
```

(`encode!/2` then normalizes the result again: an `OrderedObject` has its own `Jason.Encoder`, so it
is kept whole. A key JSON cannot express, such as a tuple, raises `Protocol.UndefinedError` from
`key_text/1`, the exception Jason raised for it before.)

`lib/normandy/components/tool_result.ex`, `render_output/1`: replace

```elixir
  # else (a map, a list, an atom, a boolean, nil) as JSON. Dispatch turns an output JSON
  # cannot express into an error result after every hook has run, so this raises only
  # for a ToolResult built outside Dispatch.
  @spec render_output(term()) :: String.t()
  def render_output(output) when is_binary(output), do: output
  def render_output(output) when is_number(output), do: to_string(output)
  def render_output(output), do: Normandy.JSON.encode!(output)
```

with

```elixir
  # else (a map, a list, an atom, a boolean, nil) as JSON, every plain map's keys sorted
  # (Normandy.JSON "Text for the model": the same result is the same text on every node).
  # Dispatch turns an output JSON cannot express into an error result after every hook
  # has run, so this raises only for a ToolResult built outside Dispatch.
  @spec render_output(term()) :: String.t()
  def render_output(output) when is_binary(output), do: output
  def render_output(output) when is_number(output), do: to_string(output)
  def render_output(output), do: output |> Normandy.JSON.sort_keys() |> Normandy.JSON.encode!()
```

`lib/normandy/components/base_io_schema.ex`, `defimpl Normandy.Components.BaseIOSchema, for: Map`:
replace `  def to_json(map), do: Normandy.JSON.encode!(map)` with

```elixir
  # Keys sorted at every depth (Normandy.JSON "Text for the model").
  def to_json(map), do: map |> Normandy.JSON.sort_keys() |> Normandy.JSON.encode!()
```

Dispatch's encodability checks (`ensure_encodable/1`, `wrap_output/2`, `wrap_error/2`) keep
`Normandy.JSON.encode/1` unsorted: they only ask whether the output encodes, and sorting does not
change that.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/model_text_key_order_test.exs test/agents/wire_identity_test.exs test/components/ test/json_test.exs test/json_struct_encoding_test.exs`
Expected: `2 properties, 179 tests, 0 failures` (preflight on 6.1a–6.1e). `wire_identity_test.exs`
passing is the "values unchanged" proof against the frozen fixture.

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.1f.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.1f.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0 (preflight on 6.1a–6.1e: `72 doctests, 31 properties, 3426 tests`);
docs exit 0. Tagged suites: none (no backend, no `Turn.Server` start path).

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 38.` (after 6.1e's prompt-caching bullet):

```markdown
- The JSON text Normandy writes for the model from a plain map (a tool's map or list output in
  its `tool_result`, a map given as message content) lists every map's keys sorted by their
  text, at any depth. On OTP 26+ a small atom-keyed map iterates its keys in atom-creation
  order, so the same tool result could be different text on two nodes or after a restart, and
  miss the prompt cache. Values and list order are unchanged. Structs are encoded as before
  (one with its own `Jason.Encoder` by that encoder), and a `Jason.OrderedObject` keeps its
  order: return one from a tool whose key order means something to the model. A custom
  `config :normandy, :adapter` now receives `Jason.OrderedObject` structs in this text and must
  encode them in order, as Jason does.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/json.ex
git add lib/normandy/components/tool_result.ex
git add lib/normandy/components/base_io_schema.ex
git add test/agents/model_text_key_order_test.exs
git add MIGRATING-2.0.md
git commit -m "fix(json): model-facing JSON text lists plain-map keys sorted (A1)"
```

---

---

### Task 6.2a: Store exits and load crashes never crash `Turn.Server` (PERF-7, R5, Q5, Q12)

A store call that exits fails the write (`:persist_failed`, `{:store_exit, reason}`) or the
load (`:unavailable`), and anything the load raises, exits or throws is caught. The load
still runs in `init/1` here; Task 6.2b moves it out. A session store's load reason reaches
`run/2` reduced to its tags. `format_status` hides the conversation from crash reports. The
Turn core fails a tool batch that comes back short before the next LLM call.

**Files:**
- Modify: `lib/normandy/components/content_block/describe.ex` (new `reason_term/1`)
- Modify: `lib/normandy/agents/turn.ex` (`apply_tool_results/2` split into the completeness check, `complete_batch/2`, `incomplete_batch/3`, `unanswered_ids/2`)
- Modify: `lib/normandy/agents/turn/server.ex` (moduledoc "Store unavailable" and "Errors from `run/2`"; `init/1`; new `check_start_source!/2`, `safe_load/1`, `check_server_options/2`, `store_reason/1`, `store_call/1`, `format_status/1` (`/2` on OTP 24), `status_data/1`; `describe_reason/1`, `session_unavailable/1`, `retry_load/1`, `load_config_template/3` → `/2`, `with_stored_memory/3`, `load_turn_state/2`, `persist_turn_state/2`, `append_to_store/5`)
- Modify: `lib/normandy/agents/turn/session.ex` (`server_opts/1`: store reasons by tag)
- Modify: `lib/normandy/turn_error.ex` (moduledoc: `:persist_failed`, `:session_unavailable`, "`:reason` in replies")
- Modify: `MIGRATING-2.0.md` (create `## 39.`)
- Test: create `test/components/content_block/describe_test.exs`, `test/agents/turn/server_store_failures_test.exs`; modify `test/agents/turn_test.exs` (new describe block), `test/agents/turn_driver_test.exs` (two doubles fixed, one new test), `test/agents/turn_inline_test.exs` (new describe block)

**Interfaces:**
- Consumes: `TurnError.drop_stacktraces/1`, `TurnError.redact/1`, `TurnError.format_raised/3`, `Exception.normalize/3`, `Describe.type_of/1`, `check_template/1` (Server, unchanged).
- Produces: `Describe.reason_term(term) :: term()` (`@moduledoc false` module; Task 6.4c reuses it); `{:error, {:store_exit, reason}}` (header; Server-internal) surfacing as `%TurnError{type: :persist_failed, reason: {:store_exit, reason}}` or inside `:session_unavailable`; `{:load_crashed, exception}` (Server-internal, replied as the bare exception); core failure reason `{:unexpected_event, status, {:incomplete_batch, [tool_call_id]}}`; `Turn.Server.format_status/1`.

- [ ] **Step 1: Write the failing tests**

Create `test/components/content_block/describe_test.exs`:

```elixir
defmodule Normandy.Components.ContentBlock.DescribeTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContentBlock.Describe

  describe "reason_term/1" do
    test "keeps atoms, integers and tuples of them whole" do
      assert Describe.reason_term(:timeout) == :timeout
      assert Describe.reason_term({:exit, :noproc}) == {:exit, :noproc}
      assert Describe.reason_term({:namespace_full, :bytes, 10}) == {:namespace_full, :bytes, 10}

      assert Describe.reason_term({:store_exit, {:timeout, {GenServer, :call, 3}}}) ==
               {:store_exit, {:timeout, {GenServer, :call, 3}}}
    end

    test "an exception becomes its module" do
      assert Describe.reason_term(%RuntimeError{message: "password=hunter2"}) == RuntimeError
      assert Describe.reason_term({:boom, %ArgumentError{message: "x"}}) == {:boom, ArgumentError}
    end

    test "a Postgrex.Error with a SQLSTATE becomes {Postgrex.Error, code}" do
      error = %Postgrex.Error{postgres: %{code: :unique_violation, detail: "Key (path)=(/x)"}}
      assert Describe.reason_term(error) == {Postgrex.Error, :unique_violation}
      assert Describe.reason_term(%Postgrex.Error{message: "SELECT 1"}) == Postgrex.Error
    end

    test "strings, maps, lists and other terms become their type, at any depth" do
      assert Describe.reason_term("SELECT secret FROM keys") == "a string (23 bytes)"

      assert Describe.reason_term({:http_error, %{"token" => "SECRET"}, [1, 2]}) ==
               {:http_error, "a map", "a list"}

      assert Describe.reason_term(self()) == "an unsupported term"
    end
  end
end
```

Create `test/agents/turn/server_store_failures_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerStoreFailuresTest do
  @moduledoc """
  Task 6.2a (PERF-7, Review Focus #2): a session store that exits, and a load that
  raises, exits or throws, never crash `Turn.Server`. In-turn writes fail the turn
  `:persist_failed` with `{:store_exit, reason}`; a load leaves the server `:unavailable`
  replying `:session_unavailable`. Every server runs under a `Turn.Supervisor` with
  `max_restarts: 0`, so one restart would stop the supervisor.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ConfigTemplate, Turn}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.StubClient
  alias Normandy.Test.TurnConfig
  alias Normandy.TurnError

  # InMemory, except that the operations in the switch exit the way a timed-out
  # GenServer.call does, with the call's message (the entry being written) in the reason.
  # Handle: {in_memory_pid, switch_agent}. An op is :history, :load_turn_state,
  # :save_turn_state or {:append_entry, role}.
  defmodule ExitingStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def new do
      {:ok, switch} = Agent.start_link(fn -> MapSet.new() end)
      {InMemory.new(), switch}
    end

    def exit_on({_mem, switch}, ops), do: Agent.update(switch, fn _ -> MapSet.new(ops) end)

    def append_entry({mem, _} = h, sid, entry) do
      maybe_exit(h, {:append_entry, entry.role}, {:append_entry, sid, entry})
      InMemory.append_entry(mem, sid, entry)
    end

    def history({mem, _} = h, sid) do
      maybe_exit(h, :history, {:history, sid})
      InMemory.history(mem, sid)
    end

    def load_turn_state({mem, _} = h, sid) do
      maybe_exit(h, :load_turn_state, {:load_turn_state, sid})
      InMemory.load_turn_state(mem, sid)
    end

    def save_turn_state({mem, _} = h, sid, ts) do
      maybe_exit(h, :save_turn_state, {:save_turn_state, sid, ts})
      InMemory.save_turn_state(mem, sid, ts)
    end

    defp maybe_exit({_mem, switch}, op, message) do
      if MapSet.member?(Agent.get(switch, & &1), op),
        do: exit({:timeout, {GenServer, :call, [:store, message, 5000]}})
    end
  end

  # A store whose history read fails with a reason carrying a secret and a query.
  defmodule LeakyReasonStore do
    @moduledoc false
    def history(_h, _sid),
      do: {:error, {:query_failed, %{"password" => "hunter2"}, "SELECT secret FROM keys"}}

    def load_turn_state(_h, _sid), do: :error
  end

  # A store whose template read and write fail with a reason carrying a connection string.
  defmodule LeakyTemplateStore do
    @moduledoc false
    def load_config_template(_h, _sid), do: {:error, {:db_down, %{"dsn" => "postgres://u:pw@h"}}}

    def save_config_template(_h, _sid, _t),
      do: {:error, {:db_down, %{"dsn" => "postgres://u:pw@h"}}}
  end

  defmodule ExitingProvider do
    @moduledoc false
    def fetch(_handle, _template_id), do: exit(:provider_down)
  end

  defmodule ThrowingCreds do
    @moduledoc false
    @behaviour Normandy.Behaviours.CredentialProvider
    @impl true
    def get_token(_provider, _opts), do: throw(:vault_sealed)
  end

  @secret "my secret words"

  defp sup do
    {:ok, sup} = Turn.Supervisor.start_link(max_restarts: 0)
    sup
  end

  defp sid(tag), do: "#{tag}-#{System.unique_integer([:positive])}"

  defp start(sup, sid, store, reg) do
    {:ok, srv} =
      Turn.Supervisor.start_server(sup,
        session_id: sid,
        config: BaseAgent.init(%{client: %StubClient{}, model: "m"}),
        store: store,
        registry: {Native, reg}
      )

    srv
  end

  describe "in-turn writes" do
    test "an append that exits fails the turn :persist_failed; the same server runs the next turn" do
      sup = sup()
      reg = Native.new()
      {mem, _} = store = ExitingStore.new()
      sid = sid("append-exit")
      srv = start(sup, sid, {ExitingStore, store}, reg)

      ExitingStore.exit_on(store, [{:append_entry, "assistant"}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error,
                  %TurnError{
                    type: :persist_failed,
                    reason: {:store_exit, {:timeout, {GenServer, :call, 3}}}
                  } = error} = Turn.Server.run(srv, %{chat_message: @secret})

          refute inspect(error) =~ @secret
        end)

      refute log =~ @secret
      assert Process.alive?(srv)
      assert Process.alive?(sup)
      assert Native.whereis(reg, sid) == {:ok, srv}

      assert {:ok, %Turn.State{status: :failed, error: persisted}} =
               InMemory.load_turn_state(mem, sid)

      refute inspect(persisted) =~ @secret
      refute contains_stacktrace?(persisted)

      ExitingStore.exit_on(store, [])
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "again"})
      assert Native.whereis(reg, sid) == {:ok, srv}
    end

    test "a user-message append that exits replies :persist_failed before the turn starts" do
      sup = sup()
      store = ExitingStore.new()
      srv = start(sup, sid("user-exit"), {ExitingStore, store}, Native.new())

      ExitingStore.exit_on(store, [{:append_entry, "user"}])

      assert {:error, %TurnError{type: :persist_failed, reason: {:store_exit, {:timeout, _}}}} =
               Turn.Server.run(srv, %{chat_message: @secret})

      assert Process.alive?(srv)
      assert Process.alive?(sup)
    end

    test "a terminal-state save that exits after a successful turn still replies {:ok, _}" do
      sup = sup()
      store = ExitingStore.new()
      srv = start(sup, sid("finalize-exit"), {ExitingStore, store}, Native.new())

      ExitingStore.exit_on(store, [:save_turn_state])

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      assert Process.alive?(srv)
      assert Process.alive?(sup)
    end
  end

  describe "the load" do
    test "a history read that exits leaves the server :unavailable until the store answers" do
      sup = sup()
      store = ExitingStore.new()
      ExitingStore.exit_on(store, [:history])
      srv = start(sup, sid("load-exit"), {ExitingStore, store}, Native.new())
      ref = Process.monitor(srv)

      assert {:error,
              %TurnError{
                type: :session_unavailable,
                reason: {:store_exit, {:timeout, {GenServer, :call, 3}}}
              }} = Turn.Server.run(srv, %{chat_message: "hi"})

      assert {:unavailable, _} = :sys.get_state(srv)

      # The :unavailable retry runs the same load: it exits again, and the server stays.
      assert {:error, %TurnError{type: :session_unavailable}} =
               Turn.Server.run(srv, %{chat_message: "hi"})

      refute_received {:DOWN, ^ref, :process, _, _}

      ExitingStore.exit_on(store, [])
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      assert Process.alive?(sup)
    end

    test "a store's load reason is replied by its tags, never its terms" do
      srv = start(sup(), sid("leaky"), {LeakyReasonStore, nil}, Native.new())

      assert {:error,
              %TurnError{
                type: :session_unavailable,
                reason: {:query_failed, "a map", "a string (23 bytes)"}
              } = error} = Turn.Server.run(srv, %{chat_message: "hi"})

      refute inspect(error) =~ "hunter2"
      refute inspect(error) =~ "SELECT"
    end

    test "Turn.Session.run/2 reduces a store's template reasons the same way" do
      {:ok, cat} = Catalog.start_link([])

      base = [
        session_id: sid("leaky-template"),
        store: {LeakyTemplateStore, nil},
        registry: {Native, Native.new()},
        supervisor: sup(),
        template_provider: {Catalog, cat}
      ]

      # Thin (no :config): the template read fails. Tier 2 with a config: the save fails.
      for opts <- [base, Keyword.put(base, :config, TurnConfig.build())] do
        assert {:error,
                %TurnError{type: :session_unavailable, reason: {:db_down, "a map"}} = error} =
                 Turn.Session.run(Turn.Session.new(opts), %{chat_message: "hi"})

        refute inspect(error) =~ "pw@h"
      end
    end

    for {name, setup} <- [
          {"a template provider that exits", :provider_exits},
          {"a client_builder that raises", :builder_raises},
          {"a credential provider that throws", :creds_throw}
        ] do
      test "#{name} leaves the server :unavailable and alive" do
        sup = sup()
        {opts, expected} = thin_start(unquote(setup))
        {:ok, srv} = Turn.Supervisor.start_server(sup, opts)
        ref = Process.monitor(srv)

        assert {:error, %TurnError{type: :session_unavailable, reason: reason} = error} =
                 Turn.Server.run(srv, %{chat_message: "hi"})

        assert expected.(reason)
        refute contains_stacktrace?(error)
        assert {:unavailable, _} = :sys.get_state(srv)
        refute_received {:DOWN, ^ref, :process, _, _}
        assert Process.alive?(sup)
      end
    end

    test "a saved template with a bad :on_approval_timeout is refused like a bad template" do
      {opts, _expected} = thin_start(:bad_server_option)
      {:ok, srv} = Turn.Supervisor.start_server(sup(), opts)

      assert {:error,
              %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
               Turn.Server.run(srv, %{chat_message: "hi"})

      assert message =~ ":on_approval_timeout must be :continue or :fail"
    end
  end

  describe "format_status" do
    test ":sys.get_status/1 shows the session id, never the conversation" do
      store = InMemory.new()
      sid = sid("status")
      srv = start(sup(), sid, {InMemory, store}, Native.new())

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: @secret})

      status = inspect(:sys.get_status(srv), limit: :infinity, printable_limit: :infinity)
      assert status =~ sid
      refute status =~ @secret
      refute status =~ "BaseAgentConfig"
    end
  end

  # {start options, a predicate on the replied reason} for a thin start whose load fails.
  defp thin_start(kind) do
    store = InMemory.new()
    sid = sid("thin-#{kind}")
    base = TurnConfig.build()
    {:ok, cat} = Catalog.start_link([])

    :ok = InMemory.save_config_template(store, sid, thin_template(kind, base))

    :ok =
      Catalog.put(cat, "kind-a", %{
        toolset: base.toolset,
        before_hooks: [],
        after_hooks: [],
        client_builder: thin_builder(kind, base)
      })

    provider = if kind == :provider_exits, do: {ExitingProvider, nil}, else: {Catalog, cat}

    opts = [
      session_id: sid,
      store: {InMemory, store},
      registry: {Native, Native.new()},
      template_provider: provider
    ]

    {opts, thin_expected(kind)}
  end

  defp thin_template(:creds_throw, base),
    do:
      put_in(
        ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential,
        {ThrowingCreds, []}
      )

  defp thin_template(:bad_server_option, base),
    do:
      Map.put(ConfigTemplate.from_config(base, "kind-a"), :server_options, %{
        on_approval_timeout: :sometimes
      })

  defp thin_template(_kind, base), do: ConfigTemplate.from_config(base, "kind-a")

  defp thin_builder(:builder_raises, _base), do: fn _token -> raise "builder bug" end
  defp thin_builder(_kind, base), do: fn _token -> base.client end

  defp thin_expected(:provider_exits), do: &(&1 == :provider_down)
  defp thin_expected(:builder_raises), do: &match?(%RuntimeError{message: "builder bug"}, &1)
  defp thin_expected(:creds_throw), do: &(&1 == :vault_sealed)
  defp thin_expected(:bad_server_option), do: &match?({:invalid_template, _}, &1)

  # A stacktrace is a list whose first element is an {module, function, arity_or_args, location} frame.
  defp contains_stacktrace?([{m, f, a, loc} | _])
       when is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)) and is_list(loc),
       do: true

  defp contains_stacktrace?(list) when is_list(list), do: Enum.any?(list, &contains_stacktrace?/1)

  defp contains_stacktrace?(tuple) when is_tuple(tuple),
    do: contains_stacktrace?(Tuple.to_list(tuple))

  defp contains_stacktrace?(%_{} = struct), do: contains_stacktrace?(Map.from_struct(struct))
  defp contains_stacktrace?(map) when is_map(map), do: contains_stacktrace?(Map.to_list(map))
  defp contains_stacktrace?(_term), do: false
end
```

In `test/agents/turn_test.exs`, insert before `  describe "step/2 iteration cap" do` (the helper names are prefixed: the file already defines `call/1` at its `unanswered_tool_calls` block):

```elixir
  describe "step/2 batch completeness (July LOW)" do
    defp batch_state(calls) do
      %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        pending_calls: calls
      }
    end

    defp batch_call(id), do: %ToolCall{id: id, name: "weather", input: %{}}
    defp batch_result(id), do: %ToolResult{tool_call_id: id, output: "ok", is_error: false}

    test "a batch whose results leave a call unanswered fails the turn before the next LLM call" do
      s = batch_state([batch_call("c1"), batch_call("c2"), batch_call("c3")])
      results = [batch_result("c1"), batch_result("c3")]

      {s2, effects} = Turn.step(s, {:tool_results, results})

      reason = {:unexpected_event, :tool_dispatch, {:incomplete_batch, ["c2"]}}
      assert s2.status == :failed
      assert s2.error == reason
      assert s2.pending_calls == []

      assert effects == [
               {:append_message, "tool", batch_result("c1")},
               {:append_message, "tool", batch_result("c3")},
               {:fail, reason}
             ]
    end

    test "an approval that resolves a batch short fails it the same way" do
      parked = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        pending_calls: [batch_call("c1"), batch_call("c2")],
        parked_calls: [batch_call("c2")],
        held_results: [batch_result("c1")]
      }

      # Complete: c1 held, c2 rejected.
      {s2, effects} = Turn.step(parked, {:approval, %{"c2" => :reject}})
      assert s2.status == :steering
      refute Enum.any?(effects, &match?({:fail, _}, &1))

      # Short: the approved c2 came back with no result.
      {running, [{:execute_approved, [_c2]}]} =
        Turn.step(parked, {:approval, %{"c2" => :approve}})

      {s3, effects3} = Turn.step(running, {:approved_results, []})

      assert s3.error == {:unexpected_event, :awaiting_approval, {:incomplete_batch, ["c2"]}}
      assert effects3 == [{:append_message, "tool", batch_result("c1")}, {:fail, s3.error}]
    end

    test "a complete batch, in any order, and an empty continuation pass" do
      {s2, _} =
        Turn.step(
          batch_state([batch_call("c1"), batch_call("c2")]),
          {:tool_results, [batch_result("c2"), batch_result("c1")]}
        )

      assert s2.status == :steering

      {s3, _} = Turn.step(batch_state([]), {:tool_results, []})
      assert s3.status == :steering
    end
  end
```

In `test/agents/turn_driver_test.exs` the two tool-loop tests' doubles return results without a `tool_call_id`, which the core now refuses. In `drive/3 runs a tool loop: dispatches, converts, threads acc across iterations`, replace

```elixir
        Enum.map(calls, fn _ -> %{result: :ok} end)
```

with

```elixir
        Enum.map(calls, fn call -> %{tool_call_id: call.id, result: :ok} end)
```

and in `drive/3 runs the compact handler at the steering boundary and threads acc`, replace

```elixir
      dispatch_tools: fn _acc, calls -> Enum.map(calls, fn _ -> %{ok: true} end) end,
```

with

```elixir
      dispatch_tools: fn _acc, calls ->
        Enum.map(calls, fn call -> %{tool_call_id: call.id, ok: true} end)
      end,
```

Then insert before `  test "drive/3 runs a tool loop: dispatches, converts, threads acc across iterations" do`:

```elixir
  test "drive/3 raises when a dispatch leaves a tool call unanswered" do
    handlers = %{
      recording_handlers(self())
      | call_llm: fn _acc, _state, _req -> %{content: nil, tool_calls: [%{id: "c1"}]} end,
        dispatch_tools: fn _acc, _calls -> [] end
    }

    state = Turn.new(max_iterations: 5, response_model: :rm, output_schema: :rm)

    assert_raise RuntimeError,
                 ~s(Turn FSM reached :failed unexpectedly: {:unexpected_event, :tool_dispatch, {:incomplete_batch, ["c1"]}}),
                 fn -> Driver.drive(state, handlers, []) end
  end

```

In `test/agents/turn_inline_test.exs`, insert before `  describe "run/2 hitting the iteration cap" do`:

```elixir
  describe "run/2 with a dispatch that answers part of the batch" do
    test "returns the incomplete-batch failure before the next LLM call" do
      test_pid = self()
      calls = [%ToolCall{id: "c1", name: "weather"}, %ToolCall{id: "c2", name: "weather"}]
      answered = %ToolResult{tool_call_id: "c1", output: "ok", is_error: false}

      deps = %{
        call_llm: fn req ->
          send(test_pid, {:called_llm, req})
          {:ok, %ToolCallResponse{content: nil, tool_calls: calls}}
        end,
        dispatch: fn _calls -> [answered] end,
        append: fn role, content -> send(test_pid, {:appended, role, content}) end,
        emit: fn _name, _meta -> :ok end
      }

      reason = {:unexpected_event, :tool_dispatch, {:incomplete_batch, ["c2"]}}

      assert {:error, ^reason, %Turn.State{status: :failed}} =
               Inline.run(Turn.new(max_iterations: 5, response_model: :rm), deps)

      assert_received {:appended, "tool", ^answered}
      assert_received {:called_llm, _}
      refute_received {:called_llm, _}
    end
  end

```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/components/content_block/describe_test.exs test/agents/turn/server_store_failures_test.exs test/agents/turn_test.exs test/agents/turn_driver_test.exs test/agents/turn_inline_test.exs`
Expected: FAIL, 19 failures:
- `describe_test.exs`: 4, `UndefinedFunctionError` for `Describe.reason_term/1`.
- `server_store_failures_test.exs`: all 11. The three in-turn tests die with `** (EXIT from #PID<...>) shutdown` (the server crashed, and the `max_restarts: 0` supervisor linked to the test stopped); the history-exit, provider-exit, builder-raise and creds-throw tests fail their `{:ok, srv} =` match on `{:error, ...}` from the start; the bad `:on_approval_timeout` test on `{:error, {%ArgumentError{...}, _}}`; the two reason tests and the `format_status` test on their assertions.
- `turn_test.exs`: 2 (`a batch whose results leave a call unanswered ...`, `an approval that resolves a batch short ...`); `turn_driver_test.exs`: 1 (no raise); `turn_inline_test.exs`: 1.

- [ ] **Step 3: `Describe.reason_term/1`**

In `lib/normandy/components/content_block/describe.ex`, after `def reason_tag(reason), do: type_of(reason)` add:

```elixir
  # An error reason reduced to a term that is safe to hand back to a caller: atoms and
  # integers are kept, tuples are walked (so {:exit, :noproc} and {:store_exit, {:timeout,
  # {GenServer, :call, 3}}} stay whole), an exception becomes its module (a
  # Postgrex.Error with a SQLSTATE becomes {Postgrex.Error, code}), and any other term
  # (a string, a map, a list, a pid) becomes type_of/1's description of it. A provider's
  # or a store's reason can carry a response body, a query or a secret; its shape and
  # tags are what a caller can act on.
  @spec reason_term(term()) :: term()
  def reason_term(%{__struct__: Postgrex.Error, __exception__: true, postgres: %{code: code}})
      when is_atom(code) and code != nil,
      do: {Postgrex.Error, code}

  def reason_term(%mod{__exception__: true}), do: mod
  def reason_term(reason) when is_atom(reason) or is_integer(reason), do: reason

  def reason_term(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&reason_term/1) |> List.to_tuple()

  def reason_term(reason), do: type_of(reason)
```

(`Postgrex` is an optional dependency: the clause matches the struct by its `__struct__`
key, so it compiles without it.)

- [ ] **Step 4: The Turn core checks a batch before the next LLM call**

In `lib/normandy/agents/turn.ex`, replace the head of `defp apply_tool_results(%State{} = s, results) do` (the line and the comment line after it, `    # Never below 0: a paused final call's continuation passes here with 0 left.`) with:

```elixir
  defp apply_tool_results(%State{} = s, results) do
    case unanswered_ids(s.pending_calls, results) do
      [] -> complete_batch(s, results)
      missing -> incomplete_batch(s, results, missing)
    end
  end

  # The ids of the batch's calls that no result answers. The Claude API rejects the
  # next request while a tool_use has no tool_result, so a batch that comes back short
  # (a shell or handler bug) fails the turn here, before the next LLM call, instead of
  # as a 400 from the API.
  defp unanswered_ids(pending_calls, results) do
    answered = for %{tool_call_id: id} <- results, into: MapSet.new(), do: id
    for call <- pending_calls, id = Map.get(call, :id), not MapSet.member?(answered, id), do: id
  end

  # The results that did arrive are appended (a tool that ran keeps its result); the
  # turn then fails, and Turn.Server's next turn closes the rest with interrupted results.
  defp incomplete_batch(s, results, missing) do
    reason = {:unexpected_event, s.status, {:incomplete_batch, missing}}
    appends = Enum.map(results, &{:append_message, "tool", &1})

    {%{s | status: :failed, error: reason, pending_calls: [], parked_calls: [], held_results: []},
     appends ++ [{:fail, reason}]}
  end

  defp complete_batch(%State{} = s, results) do
    # Never below 0: a paused final call's continuation passes here with 0 left.
```

The rest of the old body (from `new_left = ...` to its end) is now `complete_batch/2`'s
body, unchanged. Results are read with a `%{tool_call_id: id}` pattern, so a result that is
not a map answers nothing.

- [ ] **Step 5: `Turn.Server` catches store exits and load crashes**

All edits in `lib/normandy/agents/turn/server.ex`.

5a. In `init/1`, replace

```elixir
    store = Keyword.fetch!(opts, :store)
    session_id = Keyword.fetch!(opts, :session_id)

    register_self(%Data{registry: Keyword.fetch!(opts, :registry), session_id: session_id})
```

with

```elixir
    session_id = Keyword.fetch!(opts, :session_id)
    check_start_source!(opts, session_id)

    register_self(%Data{registry: Keyword.fetch!(opts, :registry), session_id: session_id})
```

and in the same function replace `    case load_session(opts, store, session_id) do` with
`    case safe_load(opts) do`. The comment block above it stays.

5b. Replace `defp load_session/3` with these four functions:

```elixir
  # No :config AND no :template_provider: a Tier-2 thin start can't reconstruct. A
  # misconfigured start, not a load fault, so it fails the start before any IO.
  defp check_start_source!(opts, session_id) do
    unless Keyword.has_key?(opts, :config) or Keyword.has_key?(opts, :template_provider) do
      raise ArgumentError,
            "Turn.Server: session #{inspect(session_id)} was started with neither :config " <>
              "nor :template_provider. A Tier-2 (Horde) thin start requires :template_provider " <>
              "so the server can reconstruct config from the persisted template."
    end
  end

  # The whole load (store reads, the template and credential providers, the template's
  # rebuild, the hook check) runs here. Anything it raises, exits or throws is logged by
  # its type and becomes {:load_crashed, exception}: the server waits :unavailable and
  # retries, instead of crashing into a supervisor restart (the restarted server would
  # crash the same way, spending the restart limit every session shares).
  defp safe_load(opts) do
    load_session(opts, Keyword.fetch!(opts, :store), Keyword.fetch!(opts, :session_id))
  catch
    kind, reason ->
      Logger.error(
        "Turn.Server load crashed (session #{inspect(Keyword.fetch!(opts, :session_id))}): " <>
          TurnError.format_raised(kind, reason, __STACKTRACE__)
      )

      normalized =
        kind |> Exception.normalize(reason, __STACKTRACE__) |> TurnError.drop_stacktraces()

      {:error, {:load_crashed, normalized}}
  end

  defp load_session(opts, store, session_id) do
    with {:ok, config, template} <- start_config(opts, store, session_id),
         :ok <- check_server_options(opts, template),
         :ok <- check_hooks(config),
         {:ok, config} <- with_stored_memory(config, store, session_id),
         {:ok, turn_state} <- load_turn_state(store, session_id) do
      {:ok, config, template, turn_state}
    end
  end

  # A saved template's server options are checked with the rest of the load, so
  # init_data/4 never raises on them: a bad value is refused like a bad template.
  defp check_server_options(opts, template) do
    check_template(fn ->
      _ = timeout_options(opts, template)
      :ok
    end)
  end
```

Keep `defp unavailable(opts, reason)` (Task 6.2b removes it): it now sits between
`check_server_options/2` and `unavailable_data/2`. Concretely, the code between
`load_session/3` and `unavailable_data/2` after this step is `check_server_options/2`, then
the unchanged `unavailable/2`.

5c. After the `describe_reason({:credential_unavailable, mod, reason})` clause add:

```elixir
  # Logged once, with its stacktrace, where safe_load/1 caught it.
  defp describe_reason({:load_crashed, exception}),
    do: "the load crashed: #{Describe.reason_tag(exception)}"

  defp describe_reason({:store_exit, reason}),
    do: "the session store exited: #{Describe.reason_tag(reason)}"
```

5d. After the `session_unavailable({:persist_failed, _r} = reason)` clause add:

```elixir
  # A load that raised, exited or threw: the exception itself, as Exception.normalize/3
  # made it (the log line says it crashed).
  defp session_unavailable({:load_crashed, exception}),
    do: %TurnError{type: :session_unavailable, reason: exception}
```

5e. In `retry_load/1`, replace

```elixir
    store = Keyword.fetch!(opts, :store)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, config, template, turn_state} <- load_session(opts, store, session_id),
```

with

```elixir
    with {:ok, config, template, turn_state} <- safe_load(opts),
```

5f. In `start_config/3`, replace
`        with {:ok, tmpl} <- load_config_template(store, template_provider, session_id),` with
`        with {:ok, tmpl} <- load_config_template(store, session_id),`. Replace both
`load_config_template/3` clauses (and the comment `# No :config AND no :template_provider — ...` above the first) with:

```elixir
  # check_start_source!/2 made sure a thin start has a :template_provider.
  defp load_config_template({mod, handle}, session_id) do
    case store_call(fn -> mod.load_config_template(handle, session_id) end) do
      {:ok, tmpl} -> {:ok, tmpl}
      :error -> {:error, {:no_config_template, session_id}}
      {:error, reason} -> {:error, store_reason(reason)}
    end
  end
```

5g. Replace `with_stored_memory/3`'s second clause and `load_turn_state/2` with:

```elixir
  defp with_stored_memory(config, {mod, handle}, session_id) do
    case store_call(fn -> mod.history(handle, session_id) end) do
      {:ok, entries} ->
        max_messages = config.memory && config.memory.max_messages

        {:ok,
         %{config | memory: %{AgentMemory.from_entries(entries) | max_messages: max_messages}}}

      {:error, reason} ->
        {:error, store_reason(reason)}
    end
  end

  defp load_turn_state({mod, handle}, sid) do
    case store_call(fn -> mod.load_turn_state(handle, sid) end) do
      {:ok, ts} -> {:ok, ts}
      :error -> {:ok, nil}
      {:error, reason} -> {:error, store_reason(reason)}
    end
  end

  # A session store's load reason is replied to every run/2 caller: it is reduced to its
  # tags (Describe.reason_term/1), since a backend's reason can hold a query, a response
  # body or a connection's options.
  defp store_reason(reason), do: Describe.reason_term(reason)
```

5h. Replace `persist_turn_state/2` with:

```elixir
  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: store_call(fn -> mod.save_turn_state(handle, sid, persistable(turn_state)) end)

  # A store call that exits (a GenServer or Agent call timeout, a dead store process, a
  # dead connection) fails like the store's own {:error, reason}: the write is not
  # adopted and the turn fails :persist_failed, or the load leaves the server
  # :unavailable. The exit reason loses its stacktraces and a call's arguments (they hold
  # the entry being written). A raise is a bug in the store and still raises mid-turn
  # (decision 15c); during the load safe_load/1 catches it.
  defp store_call(fun) do
    fun.()
  catch
    :exit, reason ->
      {:error, {:store_exit, reason |> TurnError.drop_stacktraces() |> TurnError.redact()}}
  end
```

5i. Replace the body of `append_to_store/5` with:

```elixir
  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, config, role, content, id) do
    entry = %AgentMemory.Entry{
      id: id,
      turn_id: current_turn_id(config),
      role: role,
      content: content
    }

    case store_call(fn -> mod.append_entry(handle, sid, entry) end) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
```

5j. Before `defp validate_on_approval_timeout!(mode) when mode in [:continue, :fail], do: :ok` add:

```elixir
  # What a crash report, :sys.get_status/1 and the observer show of this server: its ids
  # and state names, never the conversation (the config's memory, the start options'
  # second config, the turn state's responses) nor the user input in a queued or
  # postponed turn request (decision 6). format_status/1 is OTP 25+; OTP 24 calls
  # format_status/2.
  if String.to_integer(List.to_string(:erlang.system_info(:otp_release))) >= 25 do
    @impl true
    def format_status(status) do
      status
      |> Map.update(:data, nil, &status_data/1)
      |> Map.update(:queue, [], &length/1)
      |> Map.update(:postponed, [], &length/1)
      |> Map.update(:log, [], &length/1)
    end
  else
    @impl true
    def format_status(_opt, [_pdict, state, data]),
      do: [data: [{~c"State", {state, status_data(data)}}]]
  end

  defp status_data(%Data{} = data) do
    %{
      session_id: data.session_id,
      turn_status: data.turn_state && data.turn_state.status,
      task_kind: data.task_kind,
      resume_policy: data.resume_policy
    }
  end

  defp status_data(_other), do: :redacted
```

5k. Moduledoc, section "Store unavailable": replace

```
  Every start, supervisor restarts included, loads the session from the store. If
  the store fails that load, the start still succeeds: the server waits in
  `:unavailable`, retries the load on a backoff timer (200 ms doubling to 30 s) and
  on every `run/2`, and replies `{:error, %Normandy.TurnError{type: :session_unavailable,
  reason: reason}}` with the store's reason until a load succeeds. It then carries on as
```

with

```
  Every start, supervisor restarts included, loads the session from the store. If
  the store fails that load, or the load raises, exits or throws (a template or
  credential provider, the template's rebuild), the start still succeeds: the server
  waits in `:unavailable`, retries the load on a backoff timer (200 ms doubling to 30 s)
  and on every `run/2`, and replies `{:error, %Normandy.TurnError{type:
  :session_unavailable, reason: reason}}` until a load succeeds. `reason` is the store's
  reason reduced to its tags (atoms and integers kept, an exception as its module, any
  other term as its type: `{:query_failed, "a map"}`), `{:store_exit, exit_reason}` for a
  store call that exited, or the exception the load raised. It then carries on as
```

In section "Errors from `run/2`", replace

```
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason.
```

with:

```
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason, or
      `{:store_exit, exit_reason}` when the store call exited. The write is not adopted
      and the server stays up; a store that raises is a bug and crashes the server.
```

- [ ] **Step 6: `Turn.Session` reduces a store's template reasons the same way**

In `lib/normandy/agents/turn/session.ex`, in `server_opts(%__MODULE__{config: nil} = session)`
replace `      {:error, reason} -> {:error, reason}` with
`      {:error, reason} -> {:error, Describe.reason_term(reason)}`, and replace the third
clause

```elixir
  defp server_opts(%__MODULE__{config: config} = session) do
    with :ok <- save_template(session, config), do: {:ok, thin_server_opts(session)}
  end
```

with

```elixir
  # A store's reason reaches every run/2 caller, so it is reduced to its tags like the
  # load reasons Turn.Server replies (Describe.reason_term/1).
  defp server_opts(%__MODULE__{config: config} = session) do
    case save_template(session, config) do
      :ok -> {:ok, thin_server_opts(session)}
      {:error, reason} -> {:error, Describe.reason_term(reason)}
    end
  end
```

(`Describe` is already aliased in `session.ex`.)

- [ ] **Step 7: `TurnError` moduledoc**

In `lib/normandy/turn_error.ex`, replace

```
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason
```

with:

```
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason, or
      `{:store_exit, exit_reason}` when the store call exited (a call timeout, a dead store
      process): the exit reason with no stacktrace and a call's arguments replaced by
      their count, `{:timeout, {GenServer, :call, 3}}`
```

Replace

```
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure.
```

with

```
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure. A session
      store's own reason is reduced to its tags: atoms and integers are kept, tuples are
      walked, an exception becomes its module, and any other term becomes a description of
      its type (`{:query_failed, "a map"}`). A load that raised, exited or threw gives the
      exception (an exit's or a throw's reason).
```

(the `Turn.Session.approve/2` line after it stays), and in "## `:reason` in replies, in the
store and in telemetry" replace

```
  The `TurnError` replied to the caller holds the full `:reason`, a non-Normandy exception
  included. The copy `Turn.Server` persists as a failed turn's `Turn.State.error`, and
  every telemetry
```

with

```
  The `TurnError` replied to the caller holds the full `:reason`, a non-Normandy exception
  included, except a session store's reason (see `:session_unavailable` above). The copy
  `Turn.Server` persists as a failed turn's `Turn.State.error`, and every telemetry
```

(the sentence continues unchanged with `` `:exception` `reason`, are redacted: ...``).

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test test/components/content_block/describe_test.exs test/agents/turn/server_store_failures_test.exs test/agents/turn_test.exs test/agents/turn_driver_test.exs test/agents/turn_inline_test.exs test/agents/turn/server_errors_test.exs test/agents/turn/server_test.exs test/agents/turn/session_test.exs`
Expected: PASS. `server_errors_test.exs:165` (`RaisingProvider` raises in `fetch/2`) still gets
`reason: %ArgumentError{message: "provider bug"}`: the server now starts `:unavailable` and
`session_unavailable({:load_crashed, e})` replies `e`. `server_test.exs:368` (neither
`:config` nor `:template_provider`) still fails the start: `check_start_source!/2` raises in
`init/1` before any IO.

- [ ] **Step 9: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite here: the load still runs in
`init/1`; Task 6.2b runs them.

- [ ] **Step 10: MIGRATING-2.0.md**

Insert after the end of `## 38.` (Task 6.1) and before `## New, non-breaking`:

```markdown
## 39. Turn.Server start, store failures and compaction persistence

- A session store call that exits (a `GenServer` or `Agent` call timeout, a dead store
  process or connection) no longer crashes `Turn.Server`. During a turn the write fails like
  a store's `{:error, reason}`: `run/2` returns `{:error, %Normandy.TurnError{type:
  :persist_failed, reason: {:store_exit, exit_reason}}}` and the same server takes the next
  turn. The terminal-state save after a successful turn is best-effort, so its exit leaves the
  reply `{:ok, _}`. `exit_reason` carries no stacktrace, and a call's arguments are replaced by
  their count (`{:timeout, {GenServer, :call, 3}}`). A store that raises mid-turn is a bug and
  still crashes the server.
- Anything the session load raises, exits or throws (the store, the template or credential
  provider, `ConfigTemplate.rebuild/3`, a supplement's `client_builder`) leaves the server
  `:unavailable` and retrying, instead of crashing it into a supervisor restart. `run/2`
  replies `:session_unavailable` with the exception as `:reason` (an exit's or a throw's
  reason for those). A saved template whose `:on_approval_timeout` is not `:continue` or
  `:fail` is refused as `{:invalid_template, message}`.
- A session store's error reaches `run/2` reduced to its tags: atoms and integers are kept,
  tuples are walked, an exception becomes its module (`{Postgrex.Error, code}` for a Postgres
  error with a SQLSTATE), and any other term becomes a description of its type (`"a map"`,
  `"a string (23 bytes)"`). `{:error, :store_down}` is replied unchanged;
  `{:error, {:query_failed, %{...}}}` becomes `{:query_failed, "a map"}`. `Turn.Session.run/2`
  reduces a store's template read or save error the same way. Match on the tags.
- `Turn.Server` implements `format_status`: crash reports, `:sys.get_status/1` and the
  observer show the session id, turn status, task kind and resume policy, and the length of
  each event queue, never the config, the conversation or a queued user input.
- The Turn core fails a turn whose tool batch comes back without a result for every tool
  call, before the next LLM call. The results that arrived are appended, then the turn fails
  with `{:unexpected_event, status, {:incomplete_batch, tool_call_ids}}`: `Turn.Server` replies
  an `:unexpected_event` `TurnError`, `Turn.Driver` raises, `Turn.Inline` returns
  `{:error, reason, state}`. A custom `Turn.Driver.Handlers` `dispatch_tools` or a
  `Turn.Inline` `:dispatch` dep must return one result per call, carrying its
  `tool_call_id`.
```

- [ ] **Step 11: Commit**

```bash
git add lib/normandy/components/content_block/describe.ex lib/normandy/agents/turn.ex \
  lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/session.ex \
  lib/normandy/turn_error.ex MIGRATING-2.0.md \
  test/components/content_block/describe_test.exs \
  test/agents/turn/server_store_failures_test.exs test/agents/turn_test.exs \
  test/agents/turn_driver_test.exs test/agents/turn_inline_test.exs
git commit -m "fix(turn): store exits and load crashes never crash Turn.Server"
```

---

### Task 6.2b: The session loads after `init/1` (PERF-4, R6 timing)

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`init/1`, new `handle_event(:internal, :load, :loading, _)`, `with_session_start/1`, delete `unavailable/2`, `retry_load/1` comment, moduledoc "Store unavailable" and "Session start")
- Modify: `lib/normandy/agents/turn/session.ex` (comment above `rehydrate_and_start/1`)
- Modify: `lib/normandy/agents/turn/resume_reaper.ex` (moduledoc, one sentence)
- Create: `test/support/gated_store.ex` (`Normandy.Test.GatedStore`)
- Test: create `test/agents/turn/server_start_test.exs`; modify `test/agents/turn/resume_reaper_test.exs` (`a resumed session whose credential lookup fails logs no provider reason terms`)

**Interfaces:**
- Consumes: `safe_load/1`, `unavailable_data/2`, `check_start_source!/2` (Task 6.2a).
- Produces: `Turn.Server` state `:loading` (header); `Normandy.Test.GatedStore.new/0`, `arrivals/1`, `release/1` and the `SessionStore` callbacks (header).

- [ ] **Step 1: Write the failing tests**

Create `test/support/gated_store.ex`:

```elixir
defmodule Normandy.Test.GatedStore do
  @moduledoc """
  An InMemory session store whose `history/2` waits at a gate, to prove that session
  loads run concurrently without timing anything.

      store = GatedStore.new()
      GatedStore.arrivals(store)  # history/2 calls that reached the gate so far
      GatedStore.release(store)   # lets every waiting and every later call through

  The gate is a process linked to the caller of `new/0`; a waiting `history/2` blocks in
  a call to it with no timeout.
  """
  use GenServer

  alias Normandy.Behaviours.SessionStore.InMemory

  def new do
    {:ok, gate} = GenServer.start_link(__MODULE__, :ok)
    {InMemory.new(), gate}
  end

  def arrivals({_mem, gate}), do: GenServer.call(gate, :arrivals)
  def release({_mem, gate}), do: GenServer.call(gate, :release)

  def history({mem, gate}, sid) do
    :ok = GenServer.call(gate, :pass, :infinity)
    InMemory.history(mem, sid)
  end

  def append_entry({mem, _}, sid, entry), do: InMemory.append_entry(mem, sid, entry)
  def load_turn_state({mem, _}, sid), do: InMemory.load_turn_state(mem, sid)
  def save_turn_state({mem, _}, sid, term), do: InMemory.save_turn_state(mem, sid, term)
  def load_config_template({mem, _}, sid), do: InMemory.load_config_template(mem, sid)
  def save_config_template({mem, _}, sid, tmpl), do: InMemory.save_config_template(mem, sid, tmpl)
  def list_resumable({mem, _}), do: InMemory.list_resumable(mem)

  @impl true
  def init(:ok), do: {:ok, %{arrived: 0, open?: false, waiting: []}}

  @impl true
  def handle_call(:pass, _from, %{open?: true} = state),
    do: {:reply, :ok, %{state | arrived: state.arrived + 1}}

  def handle_call(:pass, from, state),
    do: {:noreply, %{state | arrived: state.arrived + 1, waiting: [from | state.waiting]}}

  def handle_call(:arrivals, _from, state), do: {:reply, state.arrived, state}

  def handle_call(:release, _from, state) do
    Enum.each(state.waiting, &GenServer.reply(&1, :ok))
    {:reply, :ok, %{state | open?: true, waiting: []}}
  end
end
```

Create `test/agents/turn/server_start_test.exs` (the one wall-clock test of the wave; it
measured 205 ms on the scratch run, 5x under its bound, against 10 073 ms before):

```elixir
defmodule Normandy.Agents.Turn.ServerStartTest do
  @moduledoc """
  Task 6.2b (PERF-4): a session loads after `init/1` returns, so
  `Turn.Supervisor.start_server/2` does not wait for the store and sessions load
  concurrently. The gated test proves the concurrency; the wall-clock test is the plan's
  acceptance ("50 starts against a 200 ms store under 1 s"), with 5x headroom over the
  ~200 ms parallel floor. `async: false` keeps the 50 extra processes off schedulers that
  async suites share.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.{GatedStore, StubClient}

  # InMemory whose history/2 takes 200 ms, like a slow backend.
  defmodule SlowStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def history(mem, sid) do
      Process.sleep(200)
      InMemory.history(mem, sid)
    end

    defdelegate append_entry(mem, sid, entry), to: InMemory
    defdelegate load_turn_state(mem, sid), to: InMemory
    defdelegate save_turn_state(mem, sid, term), to: InMemory
  end

  @sessions 50

  defp server_opts(store, reg, sid) do
    [
      session_id: sid,
      config: BaseAgent.init(%{client: %StubClient{}, model: "m"}),
      store: store,
      registry: {Native, reg}
    ]
  end

  test "50 starts return before any load finishes, and the 50 loads wait at once" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    store = GatedStore.new()

    # Each start must return while every load is held at the gate. Before Task 6.2b the
    # first start blocked in init/1 for good; the 1 s await turns that into a failure.
    pids =
      for i <- 1..@sessions do
        task =
          Task.async(fn ->
            Turn.Supervisor.start_server(sup, server_opts({GatedStore, store}, reg, "gated-#{i}"))
          end)

        {:ok, pid} = Task.await(task, 1_000)
        pid
      end

    assert wait_until(fn -> GatedStore.arrivals(store) == @sessions end)

    :ok = GatedStore.release(store)

    # :sys.get_state/1 is answered after the load event: every server is :idle.
    for pid <- pids, do: assert({:idle, _} = :sys.get_state(pid))
  end

  test "a run/2 sent during the load waits for it and is answered" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    store = GatedStore.new()

    opts = server_opts({GatedStore, store}, Native.new(), "gated-run")
    start = Task.async(fn -> Turn.Supervisor.start_server(sup, opts) end)
    {:ok, srv} = Task.await(start, 1_000)

    assert wait_until(fn -> GatedStore.arrivals(store) == 1 end)
    caller = Task.async(fn -> Turn.Server.run(srv, %{chat_message: "hi"}) end)

    # The server is blocked in its load: the call waits in its mailbox.
    assert wait_until(fn -> Process.info(srv, :message_queue_len) == {:message_queue_len, 1} end)
    :ok = GatedStore.release(store)
    assert {:ok, _} = Task.await(caller, 5_000)
  end

  test "50 concurrent starts and turns against a 200 ms store finish under 1 s" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    mem = InMemory.new()

    started = System.monotonic_time(:millisecond)

    results =
      1..@sessions
      |> Enum.map(fn i ->
        Task.async(fn ->
          {:ok, pid} =
            Turn.Supervisor.start_server(sup, server_opts({SlowStore, mem}, reg, "slow-#{i}"))

          Turn.Server.run(pid, %{chat_message: "hi"})
        end)
      end)
      |> Task.await_many(30_000)

    elapsed = System.monotonic_time(:millisecond) - started

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert elapsed < 1_000, "50 starts and turns took #{elapsed} ms (serialized: ~10 000 ms)"
  end
end
```

In `test/agents/turn/resume_reaper_test.exs`, test `a resumed session whose credential lookup
fails logs no provider reason terms`: the failed load is now logged after `reap/1` returns,
so the capture must wait for it. Replace

```elixir
    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ResumeReaper.reap(state) end)

    assert {:ok, pid} = Native.whereis(reg, "s-creds")
    :gen_statem.stop(pid)
```

with

```elixir
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = ResumeReaper.reap(state)
        assert {:ok, pid} = Native.whereis(reg, "s-creds")
        # The server loads after init/1 returns: get_state/1 answers once the load ran.
        assert {:unavailable, _} = :sys.get_state(pid)
        :gen_statem.stop(pid)
      end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/server_start_test.exs`
Expected: FAIL, 3 failures: the two gated tests exit in `Task.await(..., 1000)` with
`** (EXIT) time out` (the first start blocks in `init/1` at the gate), and the wall-clock test
fails with `50 starts and turns took ~10000 ms (serialized: ~10 000 ms)`.

- [ ] **Step 3: Load in the first event**

In `lib/normandy/agents/turn/server.ex`, replace the end of `init/1`, from the comment
`    # The store is the only source of durable state, on a first start and on a` to the end of
the function, with:

```elixir
    # The load runs as the first event, not here: Turn.Supervisor.start_server/2 waits for
    # init/1 inside the one supervisor process, so a load in init/1 would serialize every
    # session start behind every other session's store and provider IO. gen_statem runs
    # an inserted event before it takes any message (a run/2, a system message), so
    # nothing ever sees the :loading state.
    data = %Data{
      session_id: session_id,
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000),
      start_opts: opts
    }

    {:ok, :loading, data, [{:next_event, :internal, :load}]}
  end
```

Delete `defp unavailable(opts, reason)` (its only caller was `init/1`).

Replace `with_session_start/1` and its comment with:

```elixir
  # A new session's on_session_start hooks run as the event right after the load, so a
  # slow hook does not block the supervisor starting this server and a crashing one
  # sends it :unavailable instead of failing the start.
  defp with_session_start({:ok, :idle, data, actions}) do
    if ServerGlue.session_start?(data.config, data.turn_state),
      do:
        {:next_state, :idle, data,
         [{:next_event, :internal, :session_start} | List.wrap(actions)]},
      else: {:next_state, :idle, data, actions}
  end
```

Insert before `  # :unavailable — the store failed the load at start. A turn request retries it:`:

```elixir
  # :loading — the session's first load (init/1 inserted this event). The store is the
  # only source of durable state, on a first start and on a supervisor restart alike: the
  # start arguments are captured once and would bring back the memory and turn state of
  # the first start. Starting without the saved turn would drop it, and crashing would
  # make the supervisor restart the server at once, spending the restart limit every
  # session shares. So a failed or crashed load sends the server :unavailable, retrying.
  def handle_event(:internal, :load, :loading, %Data{start_opts: opts}) do
    case safe_load(opts) do
      {:ok, config, template, turn_state} ->
        opts |> init_data(config, template, turn_state) |> with_session_start()

      {:error, reason} ->
        {data, actions} = unavailable_data(opts, reason)
        {:next_state, :unavailable, data, actions}
    end
  end
```

Replace the comment above `retry_load/1` with:

```elixir
  # Loads the session again. On success the transition is the one the first load (the
  # :load event) would have made, except that a new session's on_session_start hooks run
  # here, inline: a caller or the retry timer triggered this, and a failure must reach
  # that caller now. The retry timer is cancelled.
```

Moduledoc, "Store unavailable": replace its first line (as Task 6.2a left it)

```
  Every start, supervisor restarts included, loads the session from the store. If
```

with

```
  Every start, supervisor restarts included, loads the session from the store, in the
  server's first event after `init/1` returns: `Turn.Supervisor.start_server/2` returns
  as soon as the server is registered, and sessions load concurrently. A `run/2` sent
  meanwhile waits for the load. If
```

(re-wrap the rest of that paragraph). "Session start": replace

```
  `on_session_start` hooks (`Normandy.Behaviours.Hooks`) run as the first event after
  `init/1` returns, so the supervisor starting the server is not blocked by them. What
```

with

```
  `on_session_start` hooks (`Normandy.Behaviours.Hooks`) run as the event right after the
  load, so the supervisor starting the server is not blocked by them. What
```

- [ ] **Step 4: Comments that named `init/1` as the loader**

In `lib/normandy/agents/turn/session.ex`, replace the comment above `defp rehydrate_and_start` with:

```elixir
  # Turn.Server loads the turn state and rebuilds memory from the store itself, in
  # its first event after init/1 (on every start, including supervisor restarts), so
  # the server opts carry only the caller's config and options and the start returns
  # before the load. A store fault in that load comes back as run/2's {:error, reason}
  # (the server waits :unavailable).
```

In `lib/normandy/agents/turn/resume_reaper.ex` moduledoc, replace

```
  under the supervisor, where `Turn.Server.init/1` reconstructs config from the
```

with

```
  under the supervisor; the started `Turn.Server` reconstructs config from the
```

Check: `grep -n "init/1" lib/normandy/agents/turn/*.ex` lists only lines that say the load
runs after `init/1`: in `server.ex` the moduledoc "Store unavailable", the `start_link/1` doc,
the `init/1` comment and the `:loading` clause comment; in `session.ex` the new comment above
`rehydrate_and_start/1` (5 lines in all).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/server_start_test.exs test/agents/turn/ test/hooks/server_hooks_test.exs test/coordination/`
Expected: PASS. The ~18 `:sys.get_state/1` assertions right after a start (for example
`server_hooks_test.exs:147, 565`) keep passing: `gen_statem` runs the inserted `:load` event
before it answers the system message.

- [ ] **Step 6: Gate and tagged suites**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2b.log`, `mix docs --warnings-as-errors`, `mix test.redis`, `docker start normandy-test-pg && MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`, `mix test --only distributed`.
Expected: ` 0 failures` and exit 0 for each; docs exit 0. (`mix test --only distributed`
alone fails `eager_handoff_distributed_test.exs` "Postgres-backed session rehydrates..."
with `Normandy.TestRepo not started` unless Postgres is included; that is unchanged from
`d624fbf`. Run it as `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 NORMANDY_POSTGRES=true mix test --only distributed --include postgres` to cover it.)

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 39.`:

```markdown
- `Turn.Server` loads its session after `init/1` returns, in its first event:
  `Turn.Supervisor.start_server/2` and `Turn.Server.start_link/1` return before the store and
  the template and credential providers are read, so session starts no longer wait for each
  other in the supervisor. A `run/2` sent meanwhile waits for the load. Code that inspected
  the load's effects right after a start (a log line, the server's state) must first make a
  call to the server (`run/2`, or `:sys.get_state/1` in tests). A start with neither
  `:config` nor `:template_provider` still raises `ArgumentError` in the start.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/session.ex \
  lib/normandy/agents/turn/resume_reaper.ex MIGRATING-2.0.md test/support/gated_store.ex \
  test/agents/turn/server_start_test.exs test/agents/turn/resume_reaper_test.exs
git commit -m "perf(turn): Turn.Server loads its session after init/1"
```

---

### Task 6.2c: A duplicate self-registering start stops with `{:already_started, pid}` (July leftover, Q8)

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`init/1`, `register_self/1`, new `self_register/3`, new `start_loading/2`)
- Modify: `lib/normandy/agents/turn/start.ex` (`via_race?/1` clauses, comment)
- Modify: `lib/normandy/agents/turn/session.ex` (moduledoc "Start-time race")
- Test: create `test/agents/turn/self_register_race_test.exs`

**Interfaces:**
- Consumes: `SessionRegistry.register/3 :: :ok | {:error, :taken}`, `whereis/2`; `Turn.Start.start_server/6`.
- Produces: `{:error, {:already_started, pid}}` and `{:error, :registration_race}` from `Turn.Server.start_link/1` / `Turn.Supervisor.start_server/2` (header); `Turn.Start` retries `:registration_race` (bare or `{:registration_race, child}`).

- [ ] **Step 1: Write the failing tests**

Create `test/agents/turn/self_register_race_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.SelfRegisterRaceTest do
  @moduledoc """
  Task 6.2c (July leftover): a second start for a session that a self-registering
  registry (Native) already holds stops in `init/1` with `{:already_started, winner}`,
  before it loads anything, instead of running unregistered next to the winner.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Agents.Turn.Start
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Test.StubClient

  # Native, except that whereis/2 answers :none to its first `misses` calls: a caller
  # that looked the session up before the winner registered.
  defmodule LateRegistry do
    @moduledoc false
    alias Normandy.Behaviours.SessionRegistry.Native

    def new(misses) do
      {:ok, left} = Agent.start_link(fn -> misses end)
      {Native.new(), left}
    end

    def whereis({reg, left}, sid) do
      if Agent.get_and_update(left, &{&1, max(&1 - 1, 0)}) > 0,
        do: :none,
        else: Native.whereis(reg, sid)
    end

    def register({reg, _}, sid, pid), do: Native.register(reg, sid, pid)
    def unregister({reg, _}, sid), do: Native.unregister(reg, sid)
    def child_name(_handle, _sid), do: :self_register
  end

  # register/3 answers :taken to its first call while whereis/2 finds nobody (the
  # registered server died in between); afterwards it registers for real.
  defmodule VanishingWinnerRegistry do
    @moduledoc false
    alias Normandy.Behaviours.SessionRegistry.Native

    def new do
      {:ok, taken?} = Agent.start_link(fn -> true end)
      {Native.new(), taken?}
    end

    def register({reg, taken?}, sid, pid) do
      if Agent.get_and_update(taken?, &{&1, false}),
        do: {:error, :taken},
        else: Native.register(reg, sid, pid)
    end

    def whereis({reg, _}, sid), do: Native.whereis(reg, sid)
    def unregister({reg, _}, sid), do: Native.unregister(reg, sid)
    def child_name(_handle, _sid), do: :self_register
  end

  defp opts(sid, store, registry) do
    [
      session_id: sid,
      config: BaseAgent.init(%{client: %StubClient{}, model: "m"}),
      store: store,
      registry: registry
    ]
  end

  test "a second start of a registered session returns {:error, {:already_started, winner}}" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    store = {InMemory, InMemory.new()}

    {:ok, winner} = Turn.Supervisor.start_server(sup, opts("dup", store, {Native, reg}))

    assert {:error, {:already_started, ^winner}} =
             Turn.Supervisor.start_server(sup, opts("dup", store, {Native, reg}))

    assert %{active: 1} = DynamicSupervisor.count_children(sup)
    assert Native.whereis(reg, "dup") == {:ok, winner}
  end

  test "Turn.Session.run/2 from a caller that missed the winner runs on the winner" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    {reg, _} = late = LateRegistry.new(1)
    store = {InMemory, InMemory.new()}

    {:ok, winner} = Turn.Supervisor.start_server(sup, opts("late", store, {LateRegistry, late}))

    session =
      Turn.Session.new(
        session_id: "late",
        registry: {LateRegistry, late},
        supervisor: sup,
        store: store,
        config: BaseAgent.init(%{client: %StubClient{}, model: "m"})
      )

    assert {:ok, _} = Turn.Session.run(session, %{chat_message: "hi"})

    assert %{active: 1} = DynamicSupervisor.count_children(sup)
    assert Native.whereis(reg, "late") == {:ok, winner}
    {:idle, data} = :sys.get_state(winner)
    assert length(AgentMemory.messages(data.config.memory)) == 2
  end

  test "a winner that died before the lookup is :registration_race, which Turn.Start retries" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    vanishing = VanishingWinnerRegistry.new()
    server_opts = opts("vanish", {InMemory, InMemory.new()}, {VanishingWinnerRegistry, vanishing})

    assert {:error, :registration_race} = Turn.Supervisor.start_server(sup, server_opts)

    # The first register answered :taken; the retry registers.
    vanishing2 = VanishingWinnerRegistry.new()
    registry = {VanishingWinnerRegistry, vanishing2}
    server_opts = Keyword.put(server_opts, :registry, registry)

    assert {:ok, pid} =
             Start.start_server(Turn.Supervisor, sup, server_opts, registry, "vanish")

    assert VanishingWinnerRegistry.whereis(vanishing2, "vanish") == {:ok, pid}
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/self_register_race_test.exs`
Expected: FAIL, 3 failures: the second start returns `{:ok, pid}` (a second server), the
session test counts `%{active: 2}`, and the vanishing-winner start returns `{:ok, _}`
instead of `{:error, :registration_race}`.

- [ ] **Step 3: `init/1` stops a duplicate before it loads**

In `lib/normandy/agents/turn/server.ex`, `init/1` (after Task 6.2b) becomes:

```elixir
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    check_start_source!(opts, session_id)

    case register_self(%Data{registry: Keyword.fetch!(opts, :registry), session_id: session_id}) do
      :ok -> start_loading(opts, session_id)
      {:stop, _reason} = stop -> stop
    end
  end

  defp start_loading(opts, session_id) do
```

followed by the rest of Task 6.2b's `init/1` body (the comment, `data = %Data{...}` and
`{:ok, :loading, data, [{:next_event, :internal, :load}]}`) and `end`.

Replace `register_self/1` and its comment with:

```elixir
  # When the server was started under a `{:via, _, _}` name, the via callback
  # already registered it; only self-register otherwise. A session already registered
  # stops this start before it loads anything, the way a via-named start fails: with
  # {:already_started, winner}, which Turn.Start (Turn.Session, ResumeReaper) routes to
  # the winner. A winner that died between our register and our lookup is
  # :registration_race, which Turn.Start retries. A registry that cannot answer the
  # lookup stops the start with its reason, as Turn.Session does on a failed lookup.
  defp register_self(%Data{registry: {mod, handle}, session_id: sid}) do
    case child_name_for(mod, handle, sid) do
      :self_register -> self_register(mod, handle, sid)
      {:via, _via_mod, _term} -> :ok
    end
  end

  defp self_register(mod, handle, sid) do
    with {:error, :taken} <- mod.register(handle, sid, self()) do
      case mod.whereis(handle, sid) do
        {:ok, winner} -> {:stop, {:already_started, winner}}
        :none -> {:stop, :registration_race}
        {:error, reason} -> {:stop, reason}
      end
    end
  end
```

`{:stop, _}` from `init/1` returns `{:error, reason}` from `start_link/1` and logs nothing
(probed under a `DynamicSupervisor`: no crash report).

- [ ] **Step 4: `Turn.Start` retries `:registration_race`**

In `lib/normandy/agents/turn/start.ex`, replace

```elixir
  # Recognize the via-not-registered race in either the bare or nested shape.
  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(_), do: false
```

with

```elixir
  # Recognize the via-not-registered race in either the bare or nested shape, and a
  # self-registering server's :registration_race (the session's registered server died
  # between that start's register/3 and its whereis/2).
  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(:registration_race), do: true
  defp via_race?({:registration_race, _child}), do: true
  defp via_race?(_), do: false
```

and in the comment at the top of `start_server/6`, replace

```elixir
  #   * `{:process_not_registered_via, _}` — the via registration was not resolvable
  #     at start time (a concurrent winner mid-registration, OR a registry that has
  #     not converged yet). Route to the winner if one is now visible, else retry the
  #     start briefly. Genuine errors propagate unchanged.
```

with

```elixir
  #   * `{:process_not_registered_via, _}` — the via registration was not resolvable
  #     at start time (a concurrent winner mid-registration, OR a registry that has
  #     not converged yet), or `:registration_race` — a self-registering server found
  #     the session taken by a server that then died. Route to the winner if one is
  #     now visible, else retry the start briefly. Genuine errors propagate unchanged.
```

- [ ] **Step 5: `Turn.Session` moduledoc**

In `lib/normandy/agents/turn/session.ex`, replace the two paragraphs under `## Start-time race` with:

```
  Two callers that both find no server may both start one; one start wins and the
  other gets `{:error, {:already_started, pid}}`, which `run/2` treats as `{:ok, pid}`,
  so all callers converge on the single winner. For via-based registries (Horde,
  Redis) the supervisor supplies a `:name` computed by `child_name/2`, so the OTP
  supervisor registers atomically at start. For `:self_register` (Native) registries
  the losing server finds the session taken in `init/1` and stops before loading
  anything, with the same `{:already_started, pid}`.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/self_register_race_test.exs test/agents/turn/ test/coordination/`
Expected: PASS.

- [ ] **Step 7: Gate and tagged suites**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2c.log`, `mix docs --warnings-as-errors`, `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 NORMANDY_POSTGRES=true mix test --only distributed --include postgres`.
Expected: ` 0 failures`, exit 0 for each; docs exit 0.

- [ ] **Step 8: MIGRATING-2.0.md**

Append to `## 39.`:

```markdown
- A second `Turn.Supervisor.start_server/2` (or `Turn.Server.start_link/1`) for a session that
  a self-registering registry (`SessionRegistry.Native`) already holds returns
  `{:error, {:already_started, pid}}` and stops before loading anything. It used to start a
  second server that ran unregistered next to the first and wrote to the same session.
  `Turn.Session`, `ResumeReaper` and `AgentProcess` already treat it as a successful start;
  code that calls `start_server/2` directly and matched only `{:ok, pid}` must handle it. A
  start that found the session taken by a server that died before it could be looked up
  returns `{:error, :registration_race}`, which `Turn.Session` and `ResumeReaper` retry.
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/start.ex \
  lib/normandy/agents/turn/session.ex MIGRATING-2.0.md \
  test/agents/turn/self_register_race_test.exs
git commit -m "fix(turn): a duplicate self-registering start stops with already_started"
```

---

### Task 6.2d: `Turn.Session.run/2` survives a passivating server (July leftover, H8)

Passivation (the `:passivate` state timeout in `:idle`/`:unavailable`) is the only place
`Turn.Server` stops itself between turns. It now stops with `{:shutdown, :passivated}`
instead of `:normal` (H8), so a caller can tell it from any other stop: a call that exits
`{:shutdown, :passivated}` or `:noproc` never ran its turn and is routed again. Any other
exit, `:normal` included (a host's `:gen_statem.stop/1` mid-turn), may come after the turn
ran and propagates. `{:shutdown, _}` is a normal exit for supervisors (a `:transient` child
is not restarted) and for crash reports (none is logged), but unlike `:normal` it reaches a
linked process that does not trap exits (only a direct `Turn.Server.start_link/1` caller;
the supervisors trap exits).

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (the `:passivate` clause of `handle_event/4` and its comment; moduledoc "Store unavailable", last sentence)
- Modify: `lib/normandy/agents/turn/session.ex` (`@passivation_attempts`, `run/2` doc, new `run_on_server/3`; the `run(other, _)` clause moves up)
- Test: create `test/agents/turn/session_passivation_test.exs`; modify `test/agents/turn/server_test.exs` (two passivation assertions), `test/agents/turn/server_integration_test.exs` (one), `test/hooks/server_hooks_test.exs` (one)

**Interfaces:**
- Consumes: `Turn.Server.run/2` (`:gen_statem.call/3`, exit shape `{reason, {:gen_statem, :call, _}}`), `ensure_server/1`.
- Produces: `Turn.Server` passivation stop reason `{:shutdown, :passivated}` (H8); `{:error, %TurnError{type: :session_unavailable, reason: :passivated}}` after three servers.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/turn/session_passivation_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.SessionPassivationTest do
  @moduledoc """
  Task 6.2d (July leftover, H8): a `Turn.Session.run/2` whose call reaches a server that
  passivated (stopped `{:shutdown, :passivated}`, or already gone) routes the turn to a
  fresh server instead of exiting the caller. Any other stop, `:normal` included,
  propagates. Each registry below hands out a scripted pid first, so every case is
  deterministic.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.StubClient
  alias Normandy.TurnError

  # Native, except that whereis/2 first answers with the scripted pids, in order (a
  # pid, or :always to answer it forever), and counts its calls.
  defmodule ScriptedRegistry do
    @moduledoc false
    alias Normandy.Behaviours.SessionRegistry.Native

    def new(script) do
      {:ok, agent} = Agent.start_link(fn -> %{script: script, calls: 0} end)
      {Native.new(), agent}
    end

    def calls({_reg, agent}), do: Agent.get(agent, & &1.calls)

    def whereis({reg, agent}, sid) do
      Agent.get_and_update(agent, fn
        %{script: [{:always, pid}]} = s -> {{:ok, pid}, %{s | calls: s.calls + 1}}
        %{script: [pid | rest]} = s -> {{:ok, pid}, %{s | script: rest, calls: s.calls + 1}}
        %{script: []} = s -> {:native, %{s | calls: s.calls + 1}}
      end)
      |> case do
        :native -> Native.whereis(reg, sid)
        found -> found
      end
    end

    def register({reg, _}, sid, pid), do: Native.register(reg, sid, pid)
    def unregister({reg, _}, sid), do: Native.unregister(reg, sid)
    def child_name(_handle, _sid), do: :self_register
  end

  # Answers a turn call by stopping with `reason`, without replying: the caller's call
  # exits with {reason, {:gen_statem, :call, _}}, as it does against a server that
  # stopped with the call in its mailbox.
  defmodule StopsOnCall do
    @moduledoc false
    use GenServer

    def start(reason), do: GenServer.start(__MODULE__, reason)

    @impl true
    def init(reason), do: {:ok, reason}

    @impl true
    def handle_call(_request, _from, reason), do: {:stop, reason, reason}
  end

  defp session(registry) do
    {:ok, sup} = Turn.Supervisor.start_link([])

    Turn.Session.new(
      session_id: "s-#{System.unique_integer([:positive])}",
      registry: registry,
      supervisor: sup,
      store: {InMemory, InMemory.new()},
      config: BaseAgent.init(%{client: %StubClient{}, model: "m"})
    )
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    pid
  end

  test "a call to a server that is already gone is routed to a fresh server" do
    registry = ScriptedRegistry.new([dead_pid()])

    assert {:ok, _} =
             Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})

    assert ScriptedRegistry.calls(registry) == 2
  end

  test "a call that a passivating server never answered is routed to a fresh server" do
    {:ok, passivating} = StopsOnCall.start({:shutdown, :passivated})
    registry = ScriptedRegistry.new([passivating])

    assert {:ok, _} =
             Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})

    refute Process.alive?(passivating)
    assert ScriptedRegistry.calls(registry) == 2
  end

  test "after three servers that passivated, run/2 returns :passivated" do
    registry = ScriptedRegistry.new([{:always, dead_pid()}])

    assert {:error, %TurnError{type: :session_unavailable, reason: :passivated}} =
             Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})

    assert ScriptedRegistry.calls(registry) == 3
  end

  # :normal is not passivation (H8): a host's :gen_statem.stop/1 mid-turn exits the
  # call :normal after the turn may have run tools.
  for reason <- [:normal, :boom] do
    test "a server that stops #{inspect(reason)} under the call propagates: the turn may have run" do
      {:ok, stopping} = StopsOnCall.start(unquote(reason))
      registry = ScriptedRegistry.new([stopping])

      assert {unquote(reason), {:gen_statem, :call, _}} =
               catch_exit(
                 Turn.Session.run(session({ScriptedRegistry, registry}), %{chat_message: "hi"})
               )

      assert ScriptedRegistry.calls(registry) == 1
    end
  end
end
```

The existing tests that watch a server passivate expect the new reason. In
`test/agents/turn/server_test.exs`, test `passivates (stops :normal) after the idle timeout`:
rename it to `passivates (stops {:shutdown, :passivated}) after the idle timeout`, make its
first line `    Process.flag(:trap_exit, true)` (the test starts the server with `start_link/1`, and
unlike `:normal` a `{:shutdown, _}` exit reaches a linked process that does not trap exits),
and replace

```elixir
    assert_receive {:DOWN, ^ref, :process, ^srv, :normal}, 1_000
```

with

```elixir
    assert_receive {:DOWN, ^ref, :process, ^srv, {:shutdown, :passivated}}, 1_000
```

In the same file, test `with no call for idle_timeout_ms, it stops normally` (describe
`store unavailable at start`): rename it to `with no call for idle_timeout_ms, it passivates`
and replace

```elixir
      assert_receive {:EXIT, ^srv, :normal}, 1_000
```

with

```elixir
      assert_receive {:EXIT, ^srv, {:shutdown, :passivated}}, 1_000
```

In `test/hooks/server_hooks_test.exs`, describe `on_passivate`, test `runs when the idle
server passivates; a crash still stops it normally`: rename it to `runs when the idle server
passivates; a crash still passivates it` and replace its last
`assert_receive {:EXIT, ^srv, :normal}, 1_000` with
`assert_receive {:EXIT, ^srv, {:shutdown, :passivated}}, 1_000`.

In `test/agents/turn/server_integration_test.exs`, test `park → approve → resume → finalize,
then passivate → rehydrate → continue` (its "Phase 2"),
replace

```elixir
        assert_receive {:DOWN, ^ref, _, _, :normal}, 1_000
```

with

```elixir
        assert_receive {:DOWN, ^ref, _, _, {:shutdown, :passivated}}, 1_000
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/session_passivation_test.exs test/agents/turn/server_test.exs test/agents/turn/server_integration_test.exs test/hooks/server_hooks_test.exs`
Expected: FAIL, 7 failures. In `session_passivation_test.exs` 3, each `** (exit) exited in:
:gen_statem.call(...)` with `** (EXIT) no process` (two) or `** (EXIT) shutdown: :passivated`
(one); the `:normal` and `:boom` tests pass before and after (they pin the exits that must
not be retried). The four passivation assertions in the other three files fail with
`Assertion failed, no matching message after 1000ms` (the mailbox shows the `:normal` exit).

- [ ] **Step 3: Passivation stops with `{:shutdown, :passivated}`**

In `lib/normandy/agents/turn/server.ex`, in the `handle_event(:state_timeout, :passivate,
state, data)` clause, replace `    {:stop, :normal, data}` with
`    {:stop, {:shutdown, :passivated}, data}`, and replace the comment above the clause with:

```elixir
  # Idle long enough → passivate. Final turn state is already persisted; on_passivate
  # hooks run (logged-only, through call_handler/3), then the server stops with
  # {:shutdown, :passivated}: a normal exit for the supervisor (a :transient child is not
  # restarted) and for crash reports, and the one reason Turn.Session.run/2 reads as "the
  # turn never ran" and routes again (H8). An :unavailable server nobody calls stops too,
  # with no hooks (it loaded no config); the next caller starts it again.
```

In the moduledoc, section "Store unavailable", replace the paragraph's last sentence
`` With no call for `:idle_timeout_ms`, the server stops normally.`` (as Task 6.2b re-wrapped
it, the sentence spans two lines) with
`` With no call for `:idle_timeout_ms`, the server passivates (stops with `{:shutdown, :passivated}`).``
and re-wrap.

- [ ] **Step 4: Route the turn again**

In `lib/normandy/agents/turn/session.ex`, after `@stored_server_options [...]` add:

```elixir

  # How many servers run/2 tries when the one it found passivated under its call.
  @passivation_attempts 3
```

Append to `run/2`'s `@doc`, after the `(Ruling 7).` line:

```
  A server that passivates while the call waits for it never runs the turn; `run/2`
  routes the turn again, to a fresh server, up to three servers in all, then returns
  `{:error, %Normandy.TurnError{type: :session_unavailable, reason: :passivated}}`. Only
  a server that stopped with `{:shutdown, :passivated}` (`Turn.Server`'s passivation) or
  was already gone is retried; any other exit of the server, `:normal` included,
  propagates to the caller.
```

Replace the `def run(%__MODULE__{} = session, user_input) do ... end` clause and the
`def run(other, _user_input)` clause after it with:

```elixir
  def run(%__MODULE__{} = session, user_input),
    do: run_on_server(session, user_input, @passivation_attempts)

  def run(other, _user_input), do: raise(ArgumentError, not_a_session(:run, other))

  # A server that passivates stops with {:shutdown, :passivated}, and a call queued
  # behind its :passivate (or sent to it after it stopped) never ran: the call exits
  # with that reason or :noproc. The turn is routed again, to a fresh server, at most
  # @passivation_attempts times in all. Any other exit (a crash mid-turn, {:nodedown, _},
  # a host's :normal stop) may come after the turn ran, and propagates (H8).
  defp run_on_server(session, user_input, attempts_left) do
    case ensure_server(session) do
      {:ok, pid} ->
        try do
          Server.run(pid, user_input)
        catch
          :exit, {reason, {:gen_statem, :call, _}}
          when reason == :noproc or reason == {:shutdown, :passivated} ->
            if attempts_left > 1,
              do: run_on_server(session, user_input, attempts_left - 1),
              else: {:error, %TurnError{type: :session_unavailable, reason: :passivated}}
        end

      # A start function that raised comes back from the supervisor as
      # {exception, stacktrace}: the stacktrace is dropped (decision 6).
      {:error, reason} ->
        {:error,
         %TurnError{type: :session_unavailable, reason: TurnError.drop_stacktraces(reason)}}
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/session_passivation_test.exs test/agents/turn/session_test.exs test/agents/turn/server_test.exs test/agents/turn/server_integration_test.exs test/hooks/server_hooks_test.exs test/coordination/agent_process_server_test.exs`
Expected: PASS. Check: `grep -rn "{:stop, :normal" lib/normandy/agents/turn/` prints nothing.

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2d.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2d.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 39.`:

```markdown
- `Turn.Server` passivation (no call for `:idle_timeout_ms`) stops the server with reason
  `{:shutdown, :passivated}` instead of `:normal`. Supervisors and crash reports treat it as a
  normal exit (a `:transient` child is not restarted, nothing is logged); code that monitors a
  session's server and matched `:normal` must match `{:shutdown, :passivated}`. Unlike
  `:normal`, the exit reaches linked processes: a process that started a server with
  `Turn.Server.start_link/1` outside a supervisor and does not trap exits now exits with it at
  passivation. Start servers under `Turn.Supervisor` (as `Turn.Session` does) or trap exits.
- `Turn.Session.run/2` routes a turn again when the server it found passivated before running
  it (the call exits `{:shutdown, :passivated}` or `:noproc`), to a fresh server, up to three
  servers in all; then it returns `{:error, %Normandy.TurnError{type: :session_unavailable,
  reason: :passivated}}`. It used to exit the caller. `AgentProcess` in `:server` mode inherits
  this. Any other exit of the server (a crash mid-turn, `{:nodedown, _}`, a host's `:normal`
  stop) still propagates, since the turn may have run.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/session.ex MIGRATING-2.0.md \
  test/agents/turn/session_passivation_test.exs test/agents/turn/server_test.exs \
  test/agents/turn/server_integration_test.exs test/hooks/server_hooks_test.exs
git commit -m "fix(turn): passivation stops {:shutdown, :passivated}; Session.run/2 routes past it"
```

---

### Task 6.2e: Slim worker and tool-task copies in `Turn.Server` (B2, R6)

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (new `without_entries/1`)
- Modify: `lib/normandy/agents/turn/server.ex` (`spawn_task/3`, new `tool_task_config/1`, `dispatch/2`, `execute_approved/2`)
- Test: create `test/agents/turn/server_tool_task_config_test.exs`; modify `test/components/agent_memory_test.exs` (one test appended)

**Interfaces:**
- Consumes: `Dispatch.execute/4`, `Dispatch.execute_approved/3` (unchanged); `Tools.Context.build/3`, `Metadata.tool/3`, `Hooks.Context` read `memory.current_turn_id` only.
- Produces: `AgentMemory.without_entries(memory) :: t()` (header; `@doc false`).

- [ ] **Step 1: Write the failing tests**

Create `test/agents/turn/server_tool_task_config_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerToolTaskConfigTest do
  @moduledoc """
  Task 6.2e (B2): `Turn.Server` runs each tool task with a config whose memory has no
  entries, so a batch does not copy the conversation once per tool. The turn id stays,
  and classification (policy, before-hooks) still sees the whole conversation.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, ToolCall, ToolResult}
  alias Normandy.Test.Eventually
  alias Normandy.Tools.Toolset

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Reports the turn id its Tools.Context carries.
  defmodule TurnIdTool do
    use Normandy.Tool, name: "probe", description: "reports its context"

    defstruct notify: nil

    @impl Normandy.Tool
    def input_schema(_tool), do: %{type: "object", properties: %{}}

    @impl Normandy.Tool
    def run(%__MODULE__{notify: pid}, %Normandy.Tools.Context{turn_id: turn_id}) do
      send(pid, {:tool_turn_id, turn_id})
      {:ok, "ok"}
    end
  end

  defp config(test_pid, policy) do
    behaviours = %Config{
      policy: policy,
      before_hooks: [
        fn config, call ->
          send(test_pid, {:before_hook_entries, map_size(config.memory.entries)})
          {:cont, call}
        end
      ],
      after_hooks: [
        fn config, _call, %ToolResult{} = result ->
          send(
            test_pid,
            {:after_hook, map_size(config.memory.entries), config.memory.current_turn_id}
          )

          result
        end
      ]
    }

    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      toolset: Toolset.new([%TurnIdTool{notify: test_pid}]),
      behaviours: behaviours
    }
  end

  defp start(config, sid) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _config, _state, _request ->
      if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0,
        do: %Resp{tool_calls: [%ToolCall{id: "p1", name: "probe", input: %{}}]},
        else: %Resp{content: "done"}
    end

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
      )

    srv
  end

  test "a dispatched tool runs with no entries and the turn's id; its before-hook saw them" do
    srv = start(config(self(), {Normandy.Behaviours.PolicyEngine.AllowAll, []}), "slim-dispatch")

    assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "go")

    # Classification ran in the worker with the conversation (user + assistant).
    assert_received {:before_hook_entries, 2}
    assert_received {:after_hook, 0, turn_id} when is_binary(turn_id)
    assert_received {:tool_turn_id, ^turn_id}

    {:idle, data} = :sys.get_state(srv)
    assert data.config.memory.current_turn_id == turn_id
  end

  test "an approved call runs with no entries too" do
    policy =
      {Normandy.Behaviours.PolicyEngine.Ruleset,
       rules: [%{match: "probe", action: :require_approval, rule_id: "R1"}],
       default_action: :allow}

    srv = start(config(self(), policy), "slim-approved")
    caller = Task.async(fn -> Turn.Server.run(srv, "go") end)

    assert Eventually.wait_until(fn ->
             match?({:awaiting_approval, _}, :sys.get_state(srv))
           end)

    :ok = Turn.Server.approve(srv, %{"p1" => :approve})

    assert {:ok, %Resp{content: "done"}} = Task.await(caller, 5_000)
    assert_received {:after_hook, 0, turn_id} when is_binary(turn_id)
    assert_received {:tool_turn_id, ^turn_id}
  end
end
```

Append to `test/components/agent_memory_test.exs`, before the module's final `end`:

```elixir

  test "without_entries/1 drops the entries and keeps head, turn id and cap" do
    memory =
      AgentMemory.new_memory(5)
      |> AgentMemory.add_message("user", "a")
      |> AgentMemory.add_message("assistant", "b")

    slim = AgentMemory.without_entries(memory)

    assert slim.entries == %{}
    assert slim.head == memory.head
    assert slim.current_turn_id == memory.current_turn_id
    assert slim.max_messages == 5
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/server_tool_task_config_test.exs test/components/agent_memory_test.exs`
Expected: FAIL, 3 failures: both server tests on `assert_received {:after_hook, 0, turn_id}`
(the after-hook sees 2 entries), and `UndefinedFunctionError` for
`AgentMemory.without_entries/1`.

- [ ] **Step 3: `AgentMemory.without_entries/1`**

In `lib/normandy/components/agent_memory.ex`, after `def entries(%__MODULE__{entries: entries}), do: entries` add:

```elixir

  @doc false
  # The memory with no entries; head, current_turn_id and max_messages kept. For a copy
  # sent to a process that reads only the turn id (Turn.Server's tool tasks: tool spans,
  # Tools.Context and hook contexts read current_turn_id). head names an entry the copy
  # no longer holds, so nothing may walk or append to it.
  @spec without_entries(t()) :: t()
  def without_entries(%__MODULE__{} = memory), do: %{memory | entries: %{}}
```

- [ ] **Step 4: The worker and the tool tasks copy less**

In `lib/normandy/agents/turn/server.ex`, `spawn_task/3`: add to the comment above it

```elixir
  #
  # The closure copies what it captures into the worker's heap: only the fields a
  # worker reads (call_llm_event/3, compact_event/3, dispatch/2, execute_approved/2,
  # worker_hook/3), not the start options' second config, the spans or the caller.
```

and replace `    current = data` with

```elixir
    current = %Data{config: data.config, turn_state: data.turn_state, session_id: data.session_id}
```

Insert before `  # Classify every call; execute the allowed ones concurrently (mirrors`:

```elixir
  # The config a tool task runs with: the conversation's entries left behind, so each
  # task's copy is small (B2). Execution, budget, after_tool and after-hooks read the
  # agent's name, model, toolset, tool_context, behaviours and the turn id
  # (memory.current_turn_id), never the entries. Classification (policy, before-hooks)
  # runs in the worker with the full config.
  defp tool_task_config(%{memory: %AgentMemory{} = memory} = config),
    do: %{config | memory: AgentMemory.without_entries(memory)}

  defp tool_task_config(config), do: config
```

In `dispatch/2`, after `    denied = for {_call, {:deny, %_{} = result}} <- classified, do: result` add
`    tool_config = tool_task_config(config)` and in its `Task.async_stream` closure replace
`Dispatch.execute(config, invocation, ncall, pipeline)` with
`Dispatch.execute(tool_config, invocation, ncall, pipeline)`. Classification above it keeps
`config`. In `execute_approved/2`, after `    parent_ctx = OtelCtx.capture()` add
`    tool_config = tool_task_config(config)` and replace
`Dispatch.execute_approved(config, call, pipeline)` with
`Dispatch.execute_approved(tool_config, call, pipeline)`. Check:
`grep -c "tool_config" lib/normandy/agents/turn/server.ex` → 4 (two `tool_config =
tool_task_config(config)` bindings, `Dispatch.execute(tool_config` and
`Dispatch.execute_approved(tool_config`).

`BaseAgent.dispatch_turn_tools/2` and `dispatch_stream_tools/3` are not changed (R6: their
policy check runs inside each task and keeps the full config).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/server_tool_task_config_test.exs test/components/agent_memory_test.exs test/agents/turn/ test/telemetry/`
Expected: PASS. Tool spans keep their `turn_id` (`test/telemetry/` reads it from the slim
memory's `current_turn_id`).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2e.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2e.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 39.`:

```markdown
- Under `Turn.Server`, a tool's execution, budget, `after_tool` and function `after_hooks` run
  with a config whose `memory` holds no entries (`head`, `current_turn_id` and `max_messages`
  are kept), so a tool batch no longer copies the conversation into every tool task. Policy
  engines and `before_hooks` still see the whole conversation. An after-hook that read
  messages from `config.memory` under `Turn.Server` must get them another way.
  `BaseAgent.run/3`, `stream/3`, `Turn.Driver` and `Turn.Inline` are unchanged.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/agents/turn/server.ex \
  MIGRATING-2.0.md test/agents/turn/server_tool_task_config_test.exs \
  test/components/agent_memory_test.exs
git commit -m "perf(turn): Turn.Server tool tasks run without the conversation's entries"
```

---

### Task 6.2f: `ResumeReaper` starts a sweep's sessions concurrently (Wave 5 deferral, R7)

**Files:**
- Modify: `lib/normandy/agents/turn/resume_reaper.ex` (`@reap_concurrency 16`, `reap/1` and its doc, new `reap_session/2`, alias `Normandy.TurnError`)
- Test: modify `test/agents/turn/resume_reaper_test.exs` (one describe block appended)

**Interfaces:**
- Consumes: `not_running?/3`, `non_terminal?/3`, `start_session/2` (unchanged); `TurnError.describe_raised/3`.
- Produces: `reap/1` unchanged in shape (`:ok`, returns after the sweep).

- [ ] **Step 1: Write the failing tests**

In `test/agents/turn/resume_reaper_test.exs`, insert before the module's final `end`:

```elixir
  describe "a sweep's concurrency (Task 6.2f)" do
    # A supervisor whose start_server/2 returns only once `n` starts have arrived: a
    # sweep that started sessions one at a time would wait at the first start for good.
    defmodule GatedSup do
      @moduledoc false
      use GenServer

      def start_link({test_pid, n}), do: GenServer.start_link(__MODULE__, {test_pid, n})

      def start_server(gate, opts),
        do: GenServer.call(gate, {:arrive, Keyword.fetch!(opts, :session_id)}, :infinity)

      @impl true
      def init({test_pid, n}), do: {:ok, %{test_pid: test_pid, n: n, waiting: []}}

      @impl true
      def handle_call({:arrive, sid}, from, state) do
        send(state.test_pid, {:reaper_started, sid})
        waiting = [from | state.waiting]

        if length(waiting) == state.n do
          Enum.each(waiting, &GenServer.reply(&1, {:ok, self()}))
          {:noreply, %{state | waiting: []}}
        else
          {:noreply, %{state | waiting: waiting}}
        end
      end
    end

    # start_server/2 raises for "s-raises" and records every other start. The
    # "supervisor" handle is the test pid.
    defmodule RaisingSup do
      @moduledoc false
      def start_server(test_pid, opts) do
        case Keyword.fetch!(opts, :session_id) do
          "s-raises" -> raise ArgumentError, "SECRET-START-BUG"
          sid -> send(test_pid, {:started, sid})
        end

        {:ok, self()}
      end
    end

    defp eager_sessions(sids) do
      store = InMemory.new()

      for sid <- sids do
        :ok =
          InMemory.save_config_template(store, sid, %{template_id: "k", resume_policy: :eager})

        :ok = InMemory.save_turn_state(store, sid, %Turn.State{status: :steering})
      end

      store
    end

    defp sweep_state(store, sup, sup_mod) do
      {:ok, cat} = Catalog.start_link([])

      %{
        store: {InMemory, store},
        registry: {Native, Native.new()},
        supervisor: sup,
        supervisor_mod: sup_mod,
        template_provider: {Catalog, cat},
        host_server_opts: []
      }
    end

    test "the sessions of a sweep start at once" do
      sids = ["s-a", "s-b", "s-c"]
      {:ok, gate} = GatedSup.start_link({self(), length(sids)})
      state = sweep_state(eager_sessions(sids), gate, GatedSup)

      sweep = Task.async(fn -> ResumeReaper.reap(state) end)
      assert :ok = Task.await(sweep, 5_000)

      for sid <- sids, do: assert_received({:reaper_started, ^sid})
    end

    test "a session whose start raises is logged by type and skipped; the others start" do
      state = sweep_state(eager_sessions(["s-ok", "s-raises"]), self(), RaisingSup)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ResumeReaper.reap(state)
        end)

      assert_received {:started, "s-ok"}
      assert log =~ ~s(ResumeReaper: resuming "s-raises" crashed: ArgumentError)
      refute log =~ "SECRET-START-BUG"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/resume_reaper_test.exs`
Expected: FAIL, 2 failures: `the sessions of a sweep start at once` exits in
`Task.await(..., 5000)` with `** (EXIT) time out` (the first start waits at the gate for the
others), and the raising test fails with `** (ArgumentError) SECRET-START-BUG` raised
through `reap/1`.

- [ ] **Step 3: The concurrent sweep**

In `lib/normandy/agents/turn/resume_reaper.ex`, after `  alias Normandy.Options` add:

```elixir
  alias Normandy.TurnError

  # Sessions a sweep checks and starts at once. Each one waits on the registry, the
  # store and a start (Turn.Start retries a via race for up to ~200 ms).
  @reap_concurrency 16
```

Replace `reap/1` (doc included) with:

```elixir
  @doc """
  Restart every eager, unregistered, non-terminal session under the supervisor.
  Exposed (not private) so it can be unit-tested without orchestrating real nodes.

  Sessions are checked and started concurrently, up to 16 at a time; `reap/1` returns
  once every one of them is done. A session whose check or start raises, exits or
  throws is logged by the failure's type and skipped; the others are still reaped.
  """
  @spec reap(map()) :: :ok
  def reap(state) do
    {store_mod, store_handle} = state.store

    case store_mod.list_resumable(store_handle) do
      {:ok, sids} ->
        sids
        |> Task.async_stream(&reap_session(state, &1),
          max_concurrency: @reap_concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Stream.run()

      {:error, reason} ->
        # Don't let a store failure silently suppress eager handoff on :nodedown —
        # surface it so operators can detect and triage missed reaps.
        Logger.warning("ResumeReaper: list_resumable failed: #{Describe.reason_tag(reason)}")
        :ok
    end
  end

  # One session of a sweep, in its own task (linked to the reaper): a crash here is
  # caught, so it neither kills the reaper nor stops the sweep.
  defp reap_session(state, sid) do
    {store_mod, store_handle} = state.store
    {reg_mod, reg_handle} = state.registry

    if not_running?(reg_mod, reg_handle, sid) and non_terminal?(store_mod, store_handle, sid),
      do: start_session(state, sid)

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "ResumeReaper: resuming #{inspect(sid)} crashed: " <>
          TurnError.describe_raised(kind, reason, __STACKTRACE__)
      )

      :ok
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/resume_reaper_test.exs`
Expected: PASS (14 tests).

- [ ] **Step 5: Gate and tagged suites**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2f.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2f.log`, `mix docs --warnings-as-errors`, `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 NORMANDY_POSTGRES=true mix test --only distributed --include postgres` (`resume_reaper_integration_test.exs` is in the distributed set).
Expected: ` 0 failures`, exit 0 for each; docs exit 0.

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 39.`:

```markdown
- `ResumeReaper.reap/1` checks and starts a sweep's sessions concurrently, 16 at a time, and
  still returns after the sweep. A session whose check or start raises, exits or throws is
  logged by the failure's type (`ResumeReaper: resuming "sid" crashed: ArgumentError`) and
  skipped; it used to stop the sweep and crash the reaper.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn/resume_reaper.ex MIGRATING-2.0.md \
  test/agents/turn/resume_reaper_test.exs
git commit -m "perf(turn): ResumeReaper starts a sweep's sessions concurrently"
```

---

### Task 6.2g: `Turn.Server` stores compaction as a snapshot entry (Wave 5 deferral, R7)

After Task 6.1a, `%Entry{}` has `wire`/`tokens` set only through the private
`put_content/2`, and `from_entries/1` fills them (private `fill_entry/1`, which rebuilds the
entry from its five stored fields and calls `put_content/2`). Task 6.1c added the private
`link_entry/2` (`{entries, parent_id}` accumulator, sets `parent_id`). This task reuses both:
every entry the new code builds goes through `fill_entry/1`, and the snapshot holds only
`id`, `turn_id`, `role` and `content` (the cache is never persisted).

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (`from_entries/1` and its doc; new `compaction_content/1`, `stored_chain/1`, `compacted_chain/2`, `split_at_last_compaction/1`, `snapshot_entries/1`; reuses 6.1a's `fill_entry/1` and 6.1c's `link_entry/2`; alias `Normandy.Components.ContentBlock.Describe`)
- Modify: `lib/normandy/agents/turn/server.ex` (the `:compact_result` clause; new `persist_compaction/3`)
- Modify: `test/support/session_store_contract.ex` (one rule)
- Modify: `MIGRATING-2.0.md` (`## 35.` last bullet; `## 39.`)
- Test: create `test/components/agent_memory_compaction_test.exs`, `test/agents/turn/server_compaction_persistence_test.exs`; modify `test/hooks/server_hooks_test.exs` (two tests)

**Interfaces:**
- Consumes: `fill_entry/1` (`put_content/2`), `from_entries/1`'s cache fill (Task 6.1a); `link_entry/2` (Task 6.1c); `store_call/1`, `describe_reason/1` (Task 6.2a); `meta.compacted` from `BaseAgent.compact_turn_memory/3` / `after_compact`.
- Produces: history entry `role: "compaction"`, `content: %{version: 1, entries: [%{id, turn_id, role, content}]}` (header); `AgentMemory.compaction_content(memory)` (`@doc false`); `from_entries/1` applies the last snapshot.

- [ ] **Step 1: Write the failing tests**

Create `test/components/agent_memory_compaction_test.exs`:

```elixir
defmodule Normandy.Components.AgentMemoryCompactionTest do
  @moduledoc """
  Task 6.2g: `AgentMemory.from_entries/1` applies the last `"compaction"` snapshot entry
  of a stored history, and `compaction_content/1` builds that snapshot.
  """
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  defp stored(id, role, content, turn_id \\ "t1"),
    do: %Entry{id: id, turn_id: turn_id, role: role, content: content}

  defp snapshot(id, entries, turn_id \\ "t2"),
    do: stored(id, "compaction", %{version: 1, entries: entries}, turn_id)

  defp chain(memory),
    do:
      memory |> AgentMemory.entry_chain() |> Enum.map(&{&1.id, &1.parent_id, &1.role, &1.content})

  test "the last snapshot's entries, then the entries after it, linked in order" do
    history = [
      stored("u1", "user", "one"),
      stored("a1", "assistant", "first answer"),
      snapshot("c1", [%{id: "s1", turn_id: "t1", role: "user", content: "old summary"}]),
      stored("u2", "user", "two", "t2"),
      snapshot("c2", [
        %{id: "s2", turn_id: "t2", role: "user", content: "summary"},
        %{id: "u2", turn_id: "t2", role: "user", content: "two"}
      ]),
      stored("a2", "assistant", "second answer", "t2")
    ]

    memory = AgentMemory.from_entries(history)

    assert chain(memory) == [
             {"s2", nil, "user", "summary"},
             {"u2", "s2", "user", "two"},
             {"a2", "u2", "assistant", "second answer"}
           ]

    assert memory.head == "a2"
    assert memory.current_turn_id == "t2"
    refute Map.has_key?(memory.entries, "c2")
    refute Map.has_key?(memory.entries, "u1")
  end

  test "a snapshot with nothing after it: its entries, and its turn as the current one" do
    memory =
      AgentMemory.from_entries([
        stored("u1", "user", "one"),
        snapshot("c1", [%{id: "k1", turn_id: "t1", role: "user", content: "one"}], "t9")
      ])

    assert chain(memory) == [{"k1", nil, "user", "one"}]
    assert memory.current_turn_id == "t9"
  end

  test "compaction_content/1 is what from_entries/1 restores" do
    live =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "summary")
      |> AgentMemory.add_message("assistant", %{"answer" => 42})

    restored =
      AgentMemory.from_entries([
        stored("u0", "user", "dropped"),
        snapshot("c1", AgentMemory.compaction_content(live).entries, live.current_turn_id)
      ])

    assert chain(restored) == chain(live)
    assert restored.head == live.head
    assert restored.current_turn_id == live.current_turn_id

    assert %{version: 1, entries: [%{id: _, turn_id: _, role: "user", content: "summary"} | _]} =
             AgentMemory.compaction_content(live)
  end

  test "a snapshot of another version raises, naming it" do
    assert_raise ArgumentError,
                 ~s|AgentMemory.from_entries/1: compaction entry "c1" has snapshot version 2; this Normandy reads version 1|,
                 fn ->
                   AgentMemory.from_entries([
                     stored("c1", "compaction", %{version: 2, entries: []})
                   ])
                 end
  end

  test "a compaction entry that is not a snapshot raises, naming its type" do
    assert_raise ArgumentError,
                 ~s|AgentMemory.from_entries/1: compaction entry "c1" expected content %{version: 1, entries: [...]}, got: a string (6 bytes)|,
                 fn -> AgentMemory.from_entries([stored("c1", "compaction", "secret")]) end
  end
end
```

Create `test/agents/turn/server_compaction_persistence_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerCompactionPersistenceTest do
  @moduledoc """
  Task 6.2g (Wave 5 deferral, Review Focus #1): `Turn.Server` stores each compaction as
  a `"compaction"` history entry, so a restarted server rebuilds the compacted memory,
  not the full history. A failed snapshot write is logged and the turn goes on.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}
  alias Normandy.Test.KeepLastCompactor

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # InMemory, except that a "compaction" append returns {:error, :disk_full}.
  defmodule NoSnapshotStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def append_entry(_h, _sid, %{role: "compaction"}), do: {:error, :disk_full}
    defdelegate append_entry(h, sid, entry), to: InMemory
    defdelegate history(h, sid), to: InMemory
    defdelegate load_turn_state(h, sid), to: InMemory
    defdelegate save_turn_state(h, sid, ts), to: InMemory
  end

  defp config(keep) do
    %BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{},
      toolset: nil,
      behaviours: %Config{compactor: {KeepLastCompactor, keep: keep, context_window: 200_000}}
    }
  end

  defp start(sid, store) do
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config(2),
        store: store,
        registry: {Native, Native.new()},
        handlers: %{
          BaseAgent.non_streaming_handlers()
          | call_llm: fn _config, _state, _request -> %Resp{content: "answer"} end
        }
      )

    srv
  end

  defp chain(memory),
    do:
      memory
      |> AgentMemory.entry_chain()
      |> Enum.map(&{&1.id, &1.parent_id, &1.turn_id, &1.role, &1.content})

  defp memory_of(srv) do
    {_state, data} = :sys.get_state(srv)
    data.config.memory
  end

  test "a restarted server rebuilds the compacted memory the live server had" do
    store = InMemory.new()
    sid = "compaction-restore-#{System.unique_integer([:positive])}"
    srv = start(sid, {InMemory, store})

    for text <- ["one", "two", "three"], do: assert({:ok, _} = Turn.Server.run(srv, text))

    live = memory_of(srv)
    {:ok, stored} = InMemory.history(store, sid)
    assert Enum.count(stored, &(&1.role == "compaction")) == 2
    assert length(chain(live)) < Enum.count(stored, &(&1.role != "compaction"))

    :ok = :gen_statem.stop(srv)
    restored = memory_of(start(sid, {InMemory, store}))

    assert chain(restored) == chain(live)
    assert restored.head == live.head
    assert restored.current_turn_id == live.current_turn_id
  end

  test "a snapshot the store refuses is logged by its tag; the turn succeeds" do
    store = InMemory.new()
    sid = "compaction-refused-#{System.unique_integer([:positive])}"
    srv = start(sid, {NoSnapshotStore, store})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for text <- ["one", "two"], do: assert({:ok, _} = Turn.Server.run(srv, text))
      end)

    assert log =~ ~s|Turn.Server could not store a compaction (session "#{sid}"): :disk_full|
    {:ok, stored} = InMemory.history(store, sid)
    refute Enum.any?(stored, &(&1.role == "compaction"))

    # A restart rebuilds the uncompacted conversation: every stored message.
    :ok = :gen_statem.stop(srv)
    restored = memory_of(start(sid, {NoSnapshotStore, store}))
    assert length(chain(restored)) == length(stored)
  end
end
```

In `test/support/session_store_contract.ex`, insert before `      test "fork on an unknown entry errors", %{handle: h} do`:

```elixir
      # Turn.Server stores each compaction as a "compaction" entry whose content is the
      # conversation after it (Task 6.2g); AgentMemory.from_entries/1 applies the last one.
      test "a compaction snapshot round-trips in order, and a fork before it does not see it",
           %{handle: h} do
        alias Normandy.Components.AgentMemory

        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        {:ok, before} = @store.append_entry(h, "s1", contract_entry("assistant", "b"))

        snapshot = %{
          version: 1,
          entries: [%{id: "k1", turn_id: "t", role: "user", content: "summary of a and b"}]
        }

        {:ok, _} = @store.append_entry(h, "s1", contract_entry("compaction", snapshot))
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "c"))

        assert {:ok, entries} = @store.history(h, "s1")
        assert Enum.map(entries, & &1.role) == ["user", "assistant", "compaction", "user"]
        assert Enum.at(entries, 2).content == snapshot

        restored = entries |> AgentMemory.from_entries() |> AgentMemory.messages()
        assert Enum.map(restored, & &1.content) == ["summary of a and b", "c"]

        {:ok, forked} = @store.fork(h, "s1", before)
        assert {:ok, fe} = @store.history(h, forked)

        assert fe
               |> AgentMemory.from_entries()
               |> AgentMemory.messages()
               |> Enum.map(& &1.content) ==
                 ["a", "b"]
      end
```

In `test/hooks/server_hooks_test.exs`, the two tests that pinned "compaction is not stored"
change:

1. Rename `after a restart, after_compact reports the dropped messages again under the same ids`
   to `after a restart, the memory is the compacted one: nothing is dropped twice`. Before
   `      :ok = :gen_statem.stop(srv)` insert

   ```elixir
      {_state, live} = :sys.get_state(srv)
      live_ids = live.config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)

   ```

   and replace its last line
   `      assert Enum.take(Enum.map(dropped_again, & &1.id), length(ids)) == ids` with

   ```elixir
      dropped_again_ids = Enum.map(dropped_again, & &1.id)
      assert dropped_again_ids == live_ids
      assert MapSet.disjoint?(MapSet.new(dropped_again_ids), MapSet.new(ids))
   ```

2. Rename `after_compact gets dropped entries under their store ids; injections stay out of the store`
   to `after_compact gets dropped entries under their store ids; injections are stored only in the compaction`,
   and after `      refute Enum.any?(stored, &(&1.content == "remember: metric"))` insert

   ```elixir

      assert [%{content: %{version: 1, entries: snapshot}}] =
               Enum.filter(stored, &(&1.role == "compaction"))

      assert Enum.any?(snapshot, &(&1.content == "remember: metric"))
   ```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/components/agent_memory_compaction_test.exs test/agents/turn/server_compaction_persistence_test.exs test/hooks/server_hooks_test.exs test/behaviours/session_store/in_memory_test.exs test/behaviours/session_store/ets_test.exs test/behaviours/session_store/mnesia_test.exs`
Expected: FAIL: `agent_memory_compaction_test.exs` 5 (the memory holds the snapshot entry
itself, no `ArgumentError`, `UndefinedFunctionError` for `compaction_content/1`);
`server_compaction_persistence_test.exs` 2 (no `"compaction"` entry stored; no log line);
`server_hooks_test.exs` 2 (no compaction entry; the restored memory drops the first turn's
ids again); the contract rule, 1 per backend (3), on `["a", "b", %{version: 1, ...}, "c"]`.

- [ ] **Step 3: `from_entries/1` applies the last snapshot**

In `lib/normandy/components/agent_memory.ex`, add `alias Normandy.Components.ContentBlock.Describe`
after `alias Normandy.Components.BaseIOSchema`.

Append to `from_entries/1`'s `@doc`, after its first paragraph:

```
  An entry whose role is `"compaction"` is the snapshot `Turn.Server` stores after a
  compaction: its content, `%{version: 1, entries: [%{id: _, turn_id: _, role: _,
  content: _}]}`, is the whole conversation as that compaction left it. The memory is
  then the **last** snapshot's entries followed by the entries stored after it, linked
  in that order; the entries before that snapshot and the snapshot entry itself are not
  in the memory. A `"compaction"` entry of any other shape raises `ArgumentError`.
```

Rename the non-empty clause `def from_entries(entries) when is_list(entries) do ... end`
(as Task 6.1a left it, building `entries` with `fill_entry/1`) to
`defp stored_chain(entries) do ... end`, body unchanged, with the comment
`  # The store's own chain: each entry keeps the parent link the store gave it.` above it,
and put before it:

```elixir
  def from_entries(entries) when is_list(entries) do
    case split_at_last_compaction(entries) do
      :none -> stored_chain(entries)
      {snapshot, later} -> compacted_chain(snapshot, later)
    end
  end

  @doc false
  # The content of the "compaction" entry Turn.Server stores after a compaction (see
  # from_entries/1): the active branch as plain maps.
  @spec compaction_content(t()) :: %{version: 1, entries: [map()]}
  def compaction_content(%__MODULE__{} = memory) do
    %{
      version: 1,
      entries: Enum.map(entry_chain(memory), &Map.take(&1, [:id, :turn_id, :role, :content]))
    }
  end

```

After `stored_chain/1` add:

```elixir
  # The snapshot's conversation, then the entries stored after it, each linked to the one
  # before it (a stored entry after the snapshot names the snapshot entry as its parent).
  # current_turn_id is the last stored entry's, the snapshot's when nothing follows it.
  defp compacted_chain(snapshot, later) do
    {entries, head} =
      snapshot
      |> snapshot_entries()
      |> Enum.concat(later)
      |> Enum.map(&fill_entry/1)
      |> Enum.reduce({%{}, nil}, &link_entry/2)

    %__MODULE__{
      entries: entries,
      head: head,
      current_turn_id: List.last([snapshot | later]).turn_id,
      max_messages: nil
    }
  end

  defp split_at_last_compaction(entries) do
    case entries |> Enum.reverse() |> Enum.split_while(&(&1.role != "compaction")) do
      {_later_newest_first, []} -> :none
      {later_newest_first, [snapshot | _]} -> {snapshot, Enum.reverse(later_newest_first)}
    end
  end

  defp snapshot_entries(%Entry{content: %{version: 1, entries: entries}}) when is_list(entries) do
    Enum.map(entries, fn %{id: id, turn_id: turn_id, role: role, content: content} ->
      %Entry{id: id, turn_id: turn_id, role: role, content: content}
    end)
  end

  defp snapshot_entries(%Entry{id: id, content: %{version: version}}) when version != 1 do
    raise ArgumentError,
          "AgentMemory.from_entries/1: compaction entry #{inspect(id)} has snapshot version " <>
            "#{inspect(version)}; this Normandy reads version 1"
  end

  defp snapshot_entries(%Entry{id: id, content: content}) do
    raise ArgumentError,
          "AgentMemory.from_entries/1: compaction entry #{inspect(id)} expected content " <>
            "%{version: 1, entries: [...]}, got: " <> Describe.type_of(content)
  end
```

(`fill_entry/1` is Task 6.1a's and `link_entry/2` Task 6.1c's, both private in this module;
do not define a second `link_entry/2`: a later clause with the same head would never match.)

- [ ] **Step 4: `Turn.Server` stores the snapshot**

In `lib/normandy/agents/turn/server.ex`, in the clause
`handle_event(:info, {task_ref, {:compact_result, config2, meta}}, :running, ...)`, after
`    Process.demonitor(task_ref, [:flush])` add `    persist_compaction(data, config2, meta)`.

Before the comment above `new_entry_id/2` (it starts `# The id of the entry`) add:

```elixir
  # A compaction rewrote the conversation (messages dropped or summarized, thinking
  # stripped, after_compact injections added): store what it left as one "compaction"
  # entry, so a restart rebuilds this memory (AgentMemory.from_entries/1) instead of the
  # full history. A failed write is logged by its tag and the turn goes on: every message
  # is still stored, and a restart then rebuilds the uncompacted conversation.
  defp persist_compaction(%Data{store: {mod, handle}, session_id: sid}, config, %{compacted: true}) do
    entry = %AgentMemory.Entry{
      turn_id: current_turn_id(config),
      role: "compaction",
      content: AgentMemory.compaction_content(config.memory)
    }

    case store_call(fn -> mod.append_entry(handle, sid, entry) end) do
      {:ok, _id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Turn.Server could not store a compaction (session #{inspect(sid)}): " <>
            "#{describe_reason(reason)}; a restart rebuilds the uncompacted conversation"
        )
    end
  end

  defp persist_compaction(_data, _config, _meta), do: :ok
```

A store that raises on this append still crashes the server, like every in-turn write
(R5). No telemetry event is added: `[:normandy, :agent, :compaction]` already reports the
compaction.

- [ ] **Step 5: Run the tests to verify they pass**

Run: the Step 2 command, then `mix test test/agents/turn/ test/coordination/agent_process_server_test.exs test/components/`
Expected: PASS.

- [ ] **Step 6: Gate and tagged suites**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.2g.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.2g.log`, `mix docs --warnings-as-errors`, `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 NORMANDY_POSTGRES=true mix test --only distributed --include postgres`.
Expected: ` 0 failures`, exit 0 for each; docs exit 0. The contract rule runs on Redis
(`redis_test.exs`), Postgres (`postgres_contract_test.exs`) and Mnesia, ETS, InMemory: Redis
gives the snapshot its stream id (it is appended without one) and `[:safe]` decoding keeps
its atom keys (they exist).

- [ ] **Step 7: MIGRATING-2.0.md**

In `## 35.`, replace its last bullet (from ``- `Turn.Server` does not store compaction.`` to
`This is a known limit of this release; a later 2.0 release stores compaction.`) with:

```markdown
- `Turn.Server` stores each compaction, and a restored session starts from the compacted
  conversation; see section 39.
```

Append to `## 39.`:

```markdown
- `Turn.Server` stores each compaction. After a compaction that changed memory it appends a
  history entry with role `"compaction"` whose content is `%{version: 1, entries: [%{id:,
  turn_id:, role:, content:}]}`: the whole conversation the compaction left (the summary, the
  kept messages with their thinking stripped, `after_compact` injections). Every message stays
  stored as before. `AgentMemory.from_entries/1`, which `Turn.Server` and `AgentProcess` in
  `:server` mode use to rebuild memory, applies the last such entry: the memory is its
  conversation followed by the entries stored after it. A session restored after
  passivation, a restart or a handoff therefore continues from the compacted conversation: the
  prompt cache keeps hitting, a `:summarize` compactor does not pay for a new summary, and
  `after_compact` does not report the same messages twice.
- Code that reads `SessionStore.history/2` itself sees these entries; pass the list to
  `AgentMemory.from_entries/1`, or skip entries whose role is `"compaction"`. A `"compaction"`
  entry of another version raises `ArgumentError` in `from_entries/1` (`Turn.Server` then
  waits `:unavailable`). Forking a session at an entry before a compaction gives the
  uncompacted conversation up to that entry.
- If the store refuses the compaction entry, the turn goes on and the failure is logged
  (`Turn.Server could not store a compaction (session "sid"): <tag>; a restart rebuilds the
  uncompacted conversation`); a restart then rebuilds the full conversation, as in 1.x.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/agents/turn/server.ex \
  test/support/session_store_contract.ex MIGRATING-2.0.md \
  test/components/agent_memory_compaction_test.exs \
  test/agents/turn/server_compaction_persistence_test.exs test/hooks/server_hooks_test.exs
git commit -m "feat(turn): Turn.Server stores compaction as a snapshot history entry"
```

---

---

### Group 6.3: MIGRATING §40 ownership

6.3a creates `## 40. Session stores, registry and memory stores` (after `## 39.`, before
`## New, non-breaking`) with its table; 6.3c and 6.3d append rows and bullets; 6.3e and 6.3b add
bullets under `## New, non-breaking`. 6.3f–6.3i (other writer) append to the same §40 after 6.3e.

---

### Task 6.3a: Redis/Postgres store leftovers (July)

Redis forks get UUID ids (two nodes could mint the same `"fork_<n>"`), Redis pipelines stop
dropping in-band errors (`pipeline_ok/1`), Redis `fork/3` copies its prefix in pipelines instead of
one round trip per entry, and Postgres `fork/3` checks ancestry by ids without decoding every
content blob.

**Files:**
- Modify: `lib/normandy/behaviours/session_store/redis.ex` (`fork/3`, `save_config_template/3`, `copy_prefix/3`, new `pipeline_ok/1`, attribute `@copy_chunk`)
- Modify: `lib/normandy/behaviours/session_store/postgres.ex` (`ancestor_of_head?/3`, new `chain_ids/2`)
- Modify: `MIGRATING-2.0.md` (create `## 40.`)
- Test: modify `test/behaviours/session_store/redis_store_extra_test.exs`, `test/behaviours/session_store/postgres_test.exs`; create `test/behaviours/session_store/redis_pipeline_error_test.exs`

**Interfaces:**
- Consumes: `UUID.uuid4/0`, `Redix.pipeline/2` (per-command Redis errors come back inside `{:ok, results}`, `deps/redix/lib/redix.ex:339,361,374-376`; probed: a `WRONGTYPE` returns `{:ok, [%Redix.Error{message: "WRONGTYPE ..."}]}`).
- Produces: private `pipeline_ok/1 :: ({:ok, [term]} | {:error, term}) -> {:ok, [term]} | {:error, term}` (header name; 6.3c and 6.3d reuse it); private `chain_ids/2` in Postgres (`[{id_bin, parent_bin}]`, newest first; 6.3d reuses it).

- [ ] **Step 1: Write the failing tests**

Append to `test/behaviours/session_store/redis_store_extra_test.exs`, before the module's final `end`:

```elixir
  test "two forks of one session get distinct UUID ids", %{handle: h} do
    {:ok, at} = Redis.append_entry(h, "s-uuid", e("user", "a"))

    {:ok, first} = Redis.fork(h, "s-uuid", at)
    {:ok, second} = Redis.fork(h, "s-uuid", at)

    assert first != second
    assert {:ok, _} = UUID.info(first)
    assert {:ok, _} = UUID.info(second)
  end

  test "fork copies a prefix longer than one pipeline chunk, in order", %{handle: h} do
    ids = for n <- 1..1_001, do: elem(Redis.append_entry(h, "s-long", e("user", n)), 1)

    {:ok, forked} = Redis.fork(h, "s-long", List.last(ids))
    {:ok, entries} = Redis.history(h, forked)

    assert Enum.map(entries, & &1.content) == Enum.to_list(1..1_001)
  end
```

Create `test/behaviours/session_store/redis_pipeline_error_test.exs`:

```elixir
defmodule Normandy.Behaviours.SessionStore.RedisPipelineErrorTest do
  @moduledoc """
  A Redis error returned inside a pipeline's results (Redix reports it in-band, in
  `{:ok, results}`) fails the write instead of being dropped.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis

  test "save_config_template returns a command's in-band error" do
    {conn, ns} = h = Redis.new()
    # The eager set's key holds a string, so SADD answers WRONGTYPE.
    {:ok, "OK"} = Redix.command(conn, ["SET", "#{ns}:resumable", "not-a-set"])

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} =
             Redis.save_config_template(h, "s1", %{template_id: "k", resume_policy: :eager})

    {:ok, _} = Redix.command(conn, ["DEL", "#{ns}:resumable", "#{ns}:{s1}:meta"])
  end
end
```

(The cleanup is in the test body, not `on_exit/1`: the connection is linked to the test process and
is gone when `on_exit` runs — observed `{:redix_exited_during_call, :noproc}`.)

In `test/behaviours/session_store/postgres_test.exs`, add after the `alias` lines:

```elixir
  import Ecto.Query, only: [from: 2]
  alias Normandy.Behaviours.SessionStore.Postgres.Schemas.Entry, as: PgEntry
  alias Normandy.Behaviours.SessionStore.Postgres.Schemas.Session, as: PgSession
```

and append before the module's final `end`:

```elixir
  test "fork checks ancestry by ids, without decoding any entry's content" do
    {:ok, root} = Postgres.append_entry(Normandy.TestRepo, "s-ids", entry("user", "a"))
    {:ok, at} = Postgres.append_entry(Normandy.TestRepo, "s-ids", entry("assistant", "b"))

    # A blob binary_to_term rejects: a fork that decoded contents would raise.
    {1, _} =
      Normandy.TestRepo.update_all(from(e in PgEntry, where: e.id == ^root),
        set: [content: <<131, 255>>]
      )

    assert {:ok, forked} = Postgres.fork(Normandy.TestRepo, "s-ids", at)
    assert %PgSession{head_id: ^at} = Normandy.TestRepo.get(PgSession, forked)
  end
```

- [ ] **Step 2: Run them; expect failure**

```bash
mix format
mix test.redis test/behaviours/session_store/redis_store_extra_test.exs test/behaviours/session_store/redis_pipeline_error_test.exs
docker start normandy-test-pg
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres test/behaviours/session_store/postgres_test.exs
```

Expected (Redis, observed in scratch): 2 failures — `two forks of one session get distinct UUID
ids` (`UUID.info("fork_…")` is `{:error, _}`) and `save_config_template returns a command's in-band
error` (`right: :ok`). The 1,001-entry fork passes before and after (it pins order across chunks).
Expected (Postgres, not run in scratch): `fork checks ancestry ...` fails with `** (ArgumentError)`
raised from `Codec.decode/1` inside `Postgres.chain/2`.

- [ ] **Step 3: Implement**

`lib/normandy/behaviours/session_store/redis.ex`. Add above `@new_opts_schema`:

```elixir
    # Entries copied per pipeline by fork/3.
    @copy_chunk 1_000
```

In `fork/3` replace

```elixir
        new_id = "fork_#{System.unique_integer([:positive])}"
```

with

```elixir
        new_id = UUID.uuid4()
```

In `save_config_template/3` replace

```elixir
      case Redix.pipeline(conn, cmds) do
        {:ok, _} -> wait(conn, wait)
        {:error, reason} -> {:error, reason}
      end
```

with

```elixir
      with {:ok, _} <- pipeline_ok(Redix.pipeline(conn, cmds)), do: wait(conn, wait)
```

Replace the whole `copy_prefix/3` with:

```elixir
    # One pipeline per @copy_chunk entries. A failure part-way deletes the partial stream
    # (best effort: the fork's id was never returned, so nothing refers to it) and returns
    # the failure.
    defp copy_prefix(conn, dest_stream, prefix) do
      prefix
      |> Enum.chunk_every(@copy_chunk)
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        cmds = Enum.map(chunk, fn [_old_id, kv] -> ["XADD", dest_stream, "*" | kv] end)

        case pipeline_ok(Redix.pipeline(conn, cmds)) do
          {:ok, _} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        :ok ->
          :ok

        {:error, _reason} = error ->
          _ = Redix.command(conn, ["DEL", dest_stream])
          error
      end
    end

    # Redix returns a command's Redis error inside {:ok, results}: the first one fails the
    # whole write instead of being dropped.
    defp pipeline_ok({:ok, results}) do
      case Enum.find(results, &match?(%Redix.Error{}, &1)) do
        nil -> {:ok, results}
        %Redix.Error{} = error -> {:error, error}
      end
    end

    defp pipeline_ok({:error, _reason} = error), do: error
```

`lib/normandy/behaviours/session_store/postgres.ex`. Replace `ancestor_of_head?/3` with:

```elixir
    # Ids only: the fork check never decodes a content blob.
    defp ancestor_of_head?(repo, session_id, entry_id) do
      with %Session{head_id: head_id} when not is_nil(head_id) <- repo.get(Session, session_id),
           {:ok, target} <- Ecto.UUID.dump(entry_id) do
        repo |> chain_ids(head_id) |> Enum.any?(fn {id, _parent} -> id == target end)
      else
        _ -> false
      end
    end
```

(`Ecto.UUID.dump/1` returns `:error` for a non-UUID id such as the contract's `"no-such-entry"`,
which keeps `fork on an unknown entry errors` returning `{:error, :no_such_entry}`.)

Add above `defp load_uuid(nil)`:

```elixir
    # The chain from head_id to the root as raw {id, parent_id} pairs, newest first.
    defp chain_ids(repo, head_id) do
      sql = """
      WITH RECURSIVE branch(id, parent_id, depth) AS (
        SELECT id, parent_id, 0 FROM normandy_session_entries WHERE id = $1
        UNION ALL
        SELECT e.id, e.parent_id, b.depth + 1
        FROM normandy_session_entries e
        JOIN branch b ON e.id = b.parent_id
      )
      SELECT id, parent_id FROM branch ORDER BY depth
      """

      %{rows: rows} = SQL.query!(repo, sql, [Ecto.UUID.dump!(head_id)])
      Enum.map(rows, fn [id, parent_id] -> {id, parent_id} end)
    end
```

In the Redis moduledoc, nothing changes in this task (6.3c rewrites the eager-set sentence).

- [ ] **Step 4: Run them; expect pass**

```bash
mix format
mix test.redis test/behaviours/session_store/
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres test/behaviours/session_store/
```

Expected: ` 0 failures` on both.

- [ ] **Step 5: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w6-6.3a-precommit.log   # expect " 0 failures", exit 0
mix docs --warnings-as-errors
mix test.redis 2>&1 | tee /tmp/w6-6.3a-redis.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tee /tmp/w6-6.3a-pg.log
```

- [ ] **Step 6: MIGRATING-2.0.md**

Insert after the last line of `## 39.` (Task 6.2's section) and before `## New, non-breaking`:

```markdown
## 40. Session stores, registry and memory stores

`SessionStore` and `SessionRegistry.Redis` are released behaviours and modules: a store or host
code you wrote against 1.x must follow the changes below.

| 1.x | 2.0 |
|---|---|
| `SessionStore.Redis.fork/3` named the new session `"fork_<n>"`, an integer unique only on the node that forked | A UUID, as every other store returns |

- `SessionStore.Redis`: a pipelined write whose command fails inside Redis (a `WRONGTYPE`, an
  out-of-memory error) returns `{:error, %Redix.Error{}}`. 1.x returned `:ok` and dropped the error.
- `SessionStore.Redis.fork/3` copies the history in pipelines of 1,000 entries instead of one round
  trip per entry. If a pipeline fails, the partial copy is deleted and `fork/3` returns the error.
- `SessionStore.Postgres.fork/3` checks that the fork point is on the session's chain by ids; it no
  longer reads and decodes every entry's content.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/behaviours/session_store/redis.ex
git add lib/normandy/behaviours/session_store/postgres.ex
git add test/behaviours/session_store/redis_store_extra_test.exs
git add test/behaviours/session_store/redis_pipeline_error_test.exs
git add test/behaviours/session_store/postgres_test.exs
git add MIGRATING-2.0.md
git commit -m "fix(session_store): UUID Redis forks, checked pipelines, id-only Postgres fork check"
```

---

### Task 6.3b: `SessionStore.ETS` keeps one row per entry (B5)

An append rewrote the whole `%AgentMemory{}` (`ets.ex:104-111`; 944 µs per append at 5,000
entries, inventory §5). Rows become `{{:entry, sid, id}, %Entry{}}` plus `{{:head, sid}, id}`;
turn-state and template rows are unchanged. The handle (owner pid), the private table and the
GenServer serialization are unchanged, so `test/options/store_options_test.exs` is untouched.

**Files:**
- Modify: `lib/normandy/behaviours/session_store/ets.ex` (moduledoc, `init/1`, every `handle_call/3` clause that touches `{:session, _}`, new `head/2`, `chain/3,5`; `alias AgentMemory` dropped)
- Modify: `MIGRATING-2.0.md` (`## New, non-breaking`)
- Test: modify `test/behaviours/session_store/ets_test.exs`

**Interfaces:**
- Consumes: `%AgentMemory.Entry{}` (6.1a's `wire`/`tokens` fields ride along as stored; the store does not read them). After Task 6.2g, the contract has a compaction-entry rule; a `role: "compaction"` entry is an entry like any other here.
- Produces: nothing public. Row layout (internal): `{{:entry, sid, id}, entry}`, `{{:head, sid}, id}`, `{{:turn_state, sid}, term}`, `{{:config_template, sid}, tmpl}`; table `[:ordered_set, :private]`.

- [ ] **Step 1: Write the failing test**

Append to `test/behaviours/session_store/ets_test.exs` (after the existing module):

```elixir
defmodule Normandy.Behaviours.SessionStore.ETSLayoutTest do
  @moduledoc "Task 6.3b (B5): one row per entry, so an append does not copy the history."
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.ETS
  alias Normandy.Components.AgentMemory.Entry

  defp entry(content), do: %Entry{turn_id: "t", role: "user", content: content}

  # :ets.info/2 works on a private table from another process; the owner's state is the tid.
  test "an append adds one entry row; the session keeps one head row" do
    store = ETS.new()
    table = :sys.get_state(store)

    for n <- 1..5, do: {:ok, _} = ETS.append_entry(store, "s1", entry(n))

    assert :ets.info(table, :size) == 6
    assert {:ok, entries} = ETS.history(store, "s1")
    assert Enum.map(entries, & &1.content) == [1, 2, 3, 4, 5]
  end

  test "fork copies only the chain up to the fork point" do
    store = ETS.new()
    table = :sys.get_state(store)
    {:ok, _} = ETS.append_entry(store, "s1", entry("a"))
    {:ok, at} = ETS.append_entry(store, "s1", entry("b"))
    {:ok, _} = ETS.append_entry(store, "s1", entry("c"))

    {:ok, forked} = ETS.fork(store, "s1", at)

    # s1: 3 entries + head; the fork: a, b + head.
    assert :ets.info(table, :size) == 7
    assert {:ok, [%{content: "a"}, %{content: "b", id: ^at}]} = ETS.history(store, forked)
  end
end
```

- [ ] **Step 2: Run it; expect failure**

```bash
mix format
mix test test/behaviours/session_store/ets_test.exs
```

Expected: both layout tests fail on `:ets.info(table, :size)` (`left: 1` and `left: 2`: one
`{:session, sid}` row per session today).

- [ ] **Step 3: Implement**

In `lib/normandy/behaviours/session_store/ets.ex`, replace the `@moduledoc` with:

```elixir
  @moduledoc """
  ETS-backed `SessionStore` — fast, in-node. A GenServer owns a private ETS table
  and serializes every mutation through its mailbox, so concurrent appends and forks
  to the same `session_id` cannot clobber each other. The handle is the owner pid.

  One row per entry: `{{:entry, session_id, id}, %Entry{}}`, plus the session's head
  `{{:head, session_id}, id}`, its opaque turn state `{{:turn_state, session_id}, term}`
  and its config template `{{:config_template, session_id}, template}`. An append
  writes two rows whatever the history's length; `history/2` walks `parent_id` from
  the head (O(n), once per server start). `fork/3` copies the chain from the fork
  point back to the root into the new session. The table is private to the owner;
  start one store per logical session space.
  """
```

Delete the line `alias Normandy.Components.AgentMemory` (keep `alias Normandy.Components.AgentMemory.Entry`).

Replace `init/1` and the `handle_call/3` clauses for `:append_entry`, `:history` and `:fork`, and
the private `lookup_memory/2`, with:

```elixir
  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    # Ordered, so a session's entry rows ({:entry, sid, _}) are one key range.
    {:ok, :ets.new(name, [:ordered_set, :private])}
  end

  @impl GenServer
  def handle_call({:append_entry, session_id, entry}, _from, table) do
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || head(table, session_id)}
    :ets.insert(table, [{{:entry, session_id, id}, entry}, {{:head, session_id}, id}])
    {:reply, {:ok, id}, table}
  end

  def handle_call({:history, session_id}, _from, table) do
    {:reply, {:ok, chain(table, session_id, head(table, session_id))}, table}
  end

  def handle_call({:fork, session_id, from_entry_id}, _from, table) do
    reply =
      cond do
        head(table, session_id) == nil ->
          {:error, :no_such_session}

        not :ets.member(table, {:entry, session_id, from_entry_id}) ->
          {:error, :no_such_entry}

        true ->
          new_id = UUID.uuid4()
          copied = chain(table, session_id, from_entry_id)
          rows = for %Entry{id: id} = e <- copied, do: {{:entry, new_id, id}, e}
          :ets.insert(table, [{{:head, new_id}, from_entry_id} | rows])
          {:ok, new_id}
      end

    {:reply, reply, table}
  end
```

and, at the end of the module (replacing `lookup_memory/2`):

```elixir
  defp head(table, session_id) do
    case :ets.lookup(table, {:head, session_id}) do
      [{_, id}] -> id
      [] -> nil
    end
  end

  # The chain from `id` back to the root, chronological. Stops at a missing parent or
  # an entry already seen, as AgentMemory.entry_chain/1 does (an append may name any
  # parent_id).
  defp chain(table, session_id, id), do: chain(table, session_id, id, %{}, [])

  defp chain(_table, _sid, nil, _seen, acc), do: acc

  defp chain(table, session_id, id, seen, acc) do
    with false <- Map.has_key?(seen, id),
         [{_, %Entry{parent_id: parent} = entry}] <- :ets.lookup(table, {:entry, session_id, id}) do
      chain(table, session_id, parent, Map.put(seen, id, true), [entry | acc])
    else
      _stop -> acc
    end
  end
```

(`seen` is a plain map, not a `MapSet`: dialyzer reported `call_without_opaque` on the `MapSet`
version in scratch.) The `:save_turn_state`, `:load_turn_state`, `:save_config_template`,
`:load_config_template` and `:list_resumable` clauses are unchanged in this task.

Semantics kept: `history/2` of an unknown session is `{:ok, []}`; `fork/3` of a session with no
entries is `{:error, :no_such_session}`; a fork point that is any entry of the session (on the chain
or not) is accepted, as `AgentMemory.fork/2` did. Changed: the fork holds only the chain its head
reaches (it held the parent's whole entry map).

- [ ] **Step 4: Run; expect pass**

```bash
mix format
mix test test/behaviours/session_store/ets_test.exs
```

Expected: `12 tests, 0 failures` (10 contract + 2 layout, at HEAD; after Task 6.2g the contract has
one more).

- [ ] **Step 5: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w6-6.3b-precommit.log   # expect " 0 failures", exit 0
mix docs --warnings-as-errors
```

No tagged suite: ETS is in the default suite.

- [ ] **Step 6: MIGRATING-2.0.md**

Append under `## New, non-breaking`:

```markdown
- `SessionStore.ETS` keeps one row per entry: an append writes two rows instead of copying the
  session's whole history (B5), and a fork copies only the history up to the fork point. The
  handle and every return value are unchanged.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/behaviours/session_store/ets.ex
git add test/behaviours/session_store/ets_test.exs
git add MIGRATING-2.0.md
git commit -m "perf(session_store): ETS store keeps one row per entry"
```

---

### Task 6.3c: The in-flight index through `save_turn_state/4` (PERF-8, part 1)

`list_resumable/1` returned every `:eager` session, forever (Redis `SADD` on template save, never
removed; full scans on Postgres/Mnesia/ETS/InMemory). It now returns the sessions whose last
turn-state save was in flight. `Turn.Server` computes the flag in `persist_turn_state/2` — the one
function behind all three persist sites (`{:persist, ts}`, `{:finalize, _}`, `{:fail, _}`) — so
no Turn core effect changes and `Turn.Driver`/`Turn.Inline` (whose `{:persist, _}` is a no-op) are
untouched. Header conflict 1 explains why all five backends move here.

**Files:**
- Modify: `lib/normandy/behaviours/session_store.ex` (`save_turn_state` callback + doc, `list_resumable` doc)
- Modify: `lib/normandy/behaviours/session_store/in_memory.ex` (state `:inflight`, `save_turn_state/4`, `list_resumable/1`)
- Modify: `lib/normandy/behaviours/session_store/ets.ex` (`save_turn_state/4`, `{:save_turn_state, ...}` and `:list_resumable` clauses, moduledoc)
- Modify: `lib/normandy/behaviours/session_store/mnesia.ex` (`@empty_session`, `save_turn_state/4`, `list_resumable/1`)
- Modify: `lib/normandy/behaviours/session_store/redis.ex` (moduledoc, `save_turn_state/4`, `save_config_template/3`, `list_resumable/1`, `resumable_key/1` → `inflight_key/1`)
- Modify: `lib/normandy/behaviours/session_store/postgres.ex` (moduledoc, `save_turn_state/4`, `do_list_resumable/1`)
- Modify: `lib/normandy/behaviours/session_store/postgres/schemas.ex` (`Session` field `:inflight`)
- Create: `lib/normandy/behaviours/session_store/postgres/migration_add_inflight.ex`
- Create: `priv/test_repo/migrations/20261006000000_add_inflight.exs`
- Modify: `.dialyzer_ignore.exs`
- Modify: `lib/normandy/agents/turn/server.ex` (`persist_turn_state/2` only, new `inflight?/2`)
- Modify: `docs/guides/distributed_sessions.md`, `MIGRATING-2.0.md`
- Test: modify `test/support/session_store_contract.ex`, `test/support/flaky_store.ex`, `test/behaviours/session_store/redis_pipeline_error_test.exs`, `test/behaviours/session_store/postgres_test.exs`, and the call sites listed in Step 3e; create `test/agents/turn/server_inflight_test.exs`

**Interfaces:**
- Consumes: `Turn.Server` `%Data{resume_policy: :lazy | :eager}` and private `resumable?/1` (`status not in [:stopped, :failed]`, `server.ex:662-663`); after Task 6.2a, `persist_turn_state/2`'s body runs inside `store_call/1`; after Task 6.2b, `Normandy.Test.GatedStore` wraps InMemory; `pipeline_ok/1` (6.3a).
- Produces: `@callback save_turn_state(handle, session_id, state, inflight? :: boolean()) :: :ok | {:error, term()}` (replaces `/3`); `list_resumable/1` = in-flight sessions; `Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight` (`up/0`, `down/0`); Postgres column `normandy_sessions.inflight boolean NOT NULL DEFAULT false`, index `normandy_sessions_inflight_index` (partial, `WHERE inflight = true`), index on `normandy_sessions.head_id` (used by 6.3d); Redis key `"<ns>:inflight"` (replaces `"<ns>:resumable"`).

- [ ] **Step 1: Write the failing tests**

In `test/support/session_store_contract.ex`:

Replace `assert :ok = @store.save_turn_state(h, "s1", term)` with
`assert :ok = @store.save_turn_state(h, "s1", term, false)`.

Replace the whole test `"list_resumable returns only sessions whose template resume_policy is :eager"`
with:

```elixir
      test "list_resumable lists the sessions whose last turn-state save was in flight",
           %{handle: h} do
        :ok = @store.save_turn_state(h, "parked", {:state, :awaiting_approval}, true)
        :ok = @store.save_turn_state(h, "steering", {:state, :steering}, true)
        :ok = @store.save_turn_state(h, "idle", {:state, :stopped}, false)

        assert {:ok, ids} = @store.list_resumable(h)
        assert Enum.sort(ids) == ["parked", "steering"]

        # The turn ends: the same write that saves the terminal state drops the session.
        :ok = @store.save_turn_state(h, "parked", {:state, :stopped}, false)
        assert {:ok, ["steering"]} = @store.list_resumable(h)

        # Saving it again in flight lists it again, once.
        :ok = @store.save_turn_state(h, "parked", {:state, :steering}, true)
        :ok = @store.save_turn_state(h, "parked", {:state, :steering}, true)
        assert {:ok, ids} = @store.list_resumable(h)
        assert Enum.sort(ids) == ["parked", "steering"]
      end

      test "an :eager config template does not list a session by itself", %{handle: h} do
        :ok = @store.save_config_template(h, "eager1", %{template_id: "k", resume_policy: :eager})
        assert {:ok, []} = @store.list_resumable(h)
      end
```

Create `test/agents/turn/server_inflight_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerInflightTest do
  @moduledoc """
  Task 6.3c (PERF-8): Turn.Server saves whether a turn is in flight with every turn
  state, so the store's `list_resumable/1` names an `:eager` session only while its turn
  runs or waits for approval.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log
  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Test.FakeTool
  alias Normandy.Test.TurnConfig
  alias Normandy.Test.TurnConfig.Resp
  alias Normandy.Tools.Toolset

  # The first call asks for the billing tool, which needs approval; the next answers.
  defp handlers do
    calls = :counters.new(1, [])

    call_llm = fn _config, _state, _request ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1,
        do: %Resp{content: "", tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]},
        else: %Resp{content: "done", tool_calls: nil}
    end

    %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
  end

  defp config do
    %{
      TurnConfig.build()
      | toolset: Toolset.new([%FakeTool{name: "billing"}]),
        behaviours: %Normandy.Behaviours.Config{
          policy:
            {Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }
  end

  defp start(store, sid, resume_policy) do
    test_pid = self()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config(),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: handlers(),
        resume_policy: resume_policy,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    caller = Task.async(fn -> Turn.Server.run(srv, "bill me") end)
    assert_receive {:event, :awaiting_approval, _meta}, 2_000
    {srv, caller}
  end

  test "an :eager session is listed while parked and dropped when its turn ends" do
    store = InMemory.new()
    {srv, caller} = start(store, "s-eager", :eager)

    assert wait_until(fn -> InMemory.list_resumable(store) == {:ok, ["s-eager"]} end)

    :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
    assert {:ok, %Resp{content: "done"}} = Task.await(caller, 2_000)

    assert {:ok, %Turn.State{status: :stopped}} = InMemory.load_turn_state(store, "s-eager")
    assert {:ok, []} = InMemory.list_resumable(store)
  end

  test "a :lazy session is never listed" do
    store = InMemory.new()
    {_srv, _caller} = start(store, "s-lazy", :lazy)

    assert wait_until(fn ->
             match?(
               {:ok, %Turn.State{status: :awaiting_approval}},
               InMemory.load_turn_state(store, "s-lazy")
             )
           end)

    assert {:ok, []} = InMemory.list_resumable(store)
  end
end
```

(`wait_until/1` polls the store, not a timing assumption: the `:awaiting_approval` event and the
persist are separate steps of the server.)

In `test/behaviours/session_store/postgres_test.exs`, append before the final `end`:

```elixir
  test "the in-flight index is a partial index over inflight" do
    %{rows: [[indexdef]]} =
      Normandy.TestRepo.query!(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'normandy_sessions_inflight_index'"
      )

    assert indexdef =~ ~r/WHERE \(?inflight/
  end
```

Replace the whole of `test/behaviours/session_store/redis_pipeline_error_test.exs` (6.3a's test
targets the eager set, which `save_config_template/3` no longer writes) with:

```elixir
defmodule Normandy.Behaviours.SessionStore.RedisPipelineErrorTest do
  @moduledoc """
  A Redis error returned inside a pipeline's results (Redix reports it in-band, in
  `{:ok, results}`) fails the write instead of being dropped.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis

  # The in-flight index key holds a string, so SADD and SREM answer WRONGTYPE.
  defp broken_index do
    {conn, ns} = h = Redis.new()
    {:ok, "OK"} = Redix.command(conn, ["SET", "#{ns}:inflight", "not-a-set"])
    {h, conn, ns}
  end

  test "save_turn_state/4 returns the index command's in-band error, in flight or not" do
    {h, conn, ns} = broken_index()

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} =
             Redis.save_turn_state(h, "s1", :steering, true)

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} =
             Redis.save_turn_state(h, "s1", :stopped, false)

    {:ok, _} = Redix.command(conn, ["DEL", "#{ns}:inflight", "#{ns}:{s1}:meta"])
  end
end
```

- [ ] **Step 2: Run them; expect failure**

```bash
mix format
mix test test/behaviours/session_store/ test/agents/turn/server_inflight_test.exs
```

Expected (observed at preflight, stacked on 6.1–6.2): `53 tests, 10 failures (53 excluded)`. Every
contract run (InMemory, ETS, Mnesia) fails `list_resumable lists ...` and the turn-state round-trip
with `UndefinedFunctionError ... save_turn_state/4`, and `an :eager config template does not list a
session by itself` (the old `list_resumable/1` lists the template's session); the `:eager` server
test fails (the server still calls `/3`, so the index never fills: the `wait_until` returns
`false`). The `:lazy` server test passes before and after (nothing lists a lazy session).

- [ ] **Step 3a: Implement — the behaviour**

`lib/normandy/behaviours/session_store.ex`: replace

```elixir
  @callback save_turn_state(handle(), session_id(), state :: term()) :: :ok | {:error, term()}
```

with

```elixir
  @doc """
  Saves the session's turn state and, in the same write, whether its turn is in flight.

  `inflight?` is what `Turn.Server` computes: the session is `:eager` and its turn has
  not ended (status other than `:stopped` and `:failed`). `list_resumable/1` lists the
  sessions whose last save had `inflight?: true`. The two are written together, so the
  index never disagrees with the saved state; a backend that cannot write both
  atomically may leave a session listed that is not in flight (the reaper re-checks the
  turn state), never the reverse.
  """
  @callback save_turn_state(handle(), session_id(), state :: term(), inflight? :: boolean()) ::
              :ok | {:error, term()}
```

and replace the `@doc` above `@callback list_resumable` with:

```elixir
  @doc """
  Lists the sessions with a turn in flight: those whose last `save_turn_state/4` had
  `inflight?: true`.

  Used by `Turn.ResumeReaper` on node-down to find the eager sessions to restart; the
  reaper still checks liveness (`whereis`) and the saved turn state, so a stale member
  is skipped. The cost follows the number of sessions in flight, not the number stored.
  """
```

In the moduledoc, replace `(\`save_turn_state\`, \`load_turn_state\`)` with
`(\`save_turn_state/4\`, \`load_turn_state/2\`)`.

- [ ] **Step 3b: Implement — InMemory, ETS, Mnesia**

`in_memory.ex`. In `start_link/1` replace the `Agent.start_link` line with:

```elixir
    Agent.start_link(fn ->
      %{sessions: %{}, turn_states: %{}, config_templates: %{}, inflight: MapSet.new()}
    end)
```

Replace `save_turn_state/3` with:

```elixir
  def save_turn_state(pid, session_id, term, inflight?) when is_boolean(inflight?) do
    Agent.update(pid, fn state ->
      inflight =
        if inflight?,
          do: MapSet.put(state.inflight, session_id),
          else: MapSet.delete(state.inflight, session_id)

      %{state | turn_states: Map.put(state.turn_states, session_id, term), inflight: inflight}
    end)
  end
```

Replace `list_resumable/1` with:

```elixir
  def list_resumable(pid) do
    Agent.get(pid, fn state -> {:ok, MapSet.to_list(state.inflight)} end)
  end
```

`ets.ex`. Replace the client `save_turn_state/3` with:

```elixir
  def save_turn_state(pid, session_id, term, inflight?) when is_boolean(inflight?) do
    GenServer.call(pid, {:save_turn_state, session_id, term, inflight?})
  end
```

Replace the `{:save_turn_state, session_id, term}` clause with:

```elixir
  def handle_call({:save_turn_state, session_id, term, inflight?}, _from, table) do
    :ets.insert(table, {{:turn_state, session_id}, term})

    if inflight?,
      do: :ets.insert(table, {{:inflight, session_id}}),
      else: :ets.delete(table, {:inflight, session_id})

    {:reply, :ok, table}
  end
```

Replace the `:list_resumable` clause with (an ordered-set match with a bound key prefix walks only
the `{:inflight, _}` range):

```elixir
  def handle_call(:list_resumable, _from, table) do
    {:reply, {:ok, List.flatten(:ets.match(table, {{:inflight, :"$1"}}))}, table}
  end
```

In the moduledoc replace

```
  One row per entry: `{{:entry, session_id, id}, %Entry{}}`, plus the session's head
  `{{:head, session_id}, id}`, its opaque turn state `{{:turn_state, session_id}, term}`
  and its config template `{{:config_template, session_id}, template}`. An append
```

with

```
  One row per entry: `{{:entry, session_id, id}, %Entry{}}`, plus the session's head
  `{{:head, session_id}, id}`, its opaque turn state `{{:turn_state, session_id}, term}`,
  its config template `{{:config_template, session_id}, template}` and, while its turn
  is in flight, `{{:inflight, session_id}}`. An append
```

`mnesia.ex`. In `@empty_session` replace `resume_policy: nil` with `resume_policy: nil,` followed by
`inflight: false`. Replace `save_turn_state/3` with:

```elixir
  def save_turn_state(%{sessions: st}, session_id, term, inflight?) when is_boolean(inflight?) do
    to_ok(
      txn(fn ->
        data = read_session(st, session_id)
        # Map.put, not %{data | ...}: a row written before 2.0 has no :inflight key.
        :mnesia.write(
          {st, session_id, data |> Map.put(:turn_state, term) |> Map.put(:inflight, inflight?)}
        )
      end)
    )
  end
```

Replace `list_resumable/1` with (probed: a map pattern in a Mnesia match spec matches rows whose
map has `inflight: true`; a row without the key does not match):

```elixir
  def list_resumable(%{sessions: st}) do
    # A scan of the sessions table that copies out only the matching ids; a row written
    # before 2.0 has no :inflight key and does not match.
    txn(fn -> :mnesia.select(st, [{{st, :"$1", %{inflight: true}}, [], [:"$1"]}]) end)
  end
```

- [ ] **Step 3c: Implement — Redis and Postgres**

`redis.ex`. In the moduledoc replace

```
    (turn state, config template, resume policy) lives in a hash; eager session_ids live
    in a SET for `list_resumable/1`.
```

with

```
    (turn state, config template, resume policy) lives in a hash; the ids of the sessions
    with a turn in flight live in the SET `"<namespace>:inflight"` for `list_resumable/1`.
```

Replace `save_turn_state/3` with:

```elixir
    @impl true
    def save_turn_state(handle, session_id, term, inflight?) when is_boolean(inflight?) do
      {conn, ns} = conn_ns(handle)
      wait = wait_setting!(handle)
      hset = ["HSET", meta_key(ns, session_id), "turn_state", encode(term)]

      # Not a MULTI: the index key is in another cluster slot. Ordered so a Redis crash
      # between the two leaves the index with an extra member (the reaper re-checks the
      # turn state), never without one: added before the state, removed after it.
      cmds =
        if inflight?,
          do: [["SADD", inflight_key(ns), session_id], hset],
          else: [hset, ["SREM", inflight_key(ns), session_id]]

      with {:ok, _} <- pipeline_ok(Redix.pipeline(conn, cmds)), do: wait(conn, wait)
    end
```

In `save_config_template/3` replace everything from `cmds = [` to the end of the function body
(the `with ... pipeline_ok ...` line from 6.3a) with:

```elixir
      with {:ok, _} <-
             Redix.command(conn, [
               "HSET",
               meta_key(ns, session_id),
               "config_template",
               encode(tmpl),
               "resume_policy",
               rp
             ]) do
        wait(conn, wait)
      end
```

In `list_resumable/1` replace `resumable_key(ns)` with `inflight_key(ns)`. Replace
`defp resumable_key(ns), do: "#{ns}:resumable"` with `defp inflight_key(ns), do: "#{ns}:inflight"`
(keep the comment above it). After this, `grep -n resumable_key lib/normandy/behaviours/session_store/redis.ex`
prints nothing. Task 6.3g edits `wait/2` and the waited writes after this task; anchor there on
function names.

`postgres.ex`. Replace the moduledoc sentence

```
    Configure via `{Normandy.Behaviours.SessionStore.Postgres, repo: MyApp.Repo}` and
    run `Normandy.Behaviours.SessionStore.Postgres.Migration` from a host migration.
```

with

```
    Configure via `{Normandy.Behaviours.SessionStore.Postgres, repo: MyApp.Repo}` and
    run `Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`,
    `MigrationAddResumePolicy` and `MigrationAddInflight` from a host migration.
```

Replace `save_turn_state/3` and `do_save_turn_state/3` with:

```elixir
    @impl true
    def save_turn_state(repo, session_id, term, inflight?) when is_boolean(inflight?),
      do: backend(fn -> do_save_turn_state(repo, session_id, term, inflight?) end)

    defp do_save_turn_state(repo, session_id, term, inflight?) do
      blob = encode(term)

      %Session{session_id: session_id}
      |> Ecto.Changeset.change(turn_state: blob, inflight: inflight?)
      |> repo.insert(
        on_conflict: [
          set: [turn_state: blob, inflight: inflight?, updated_at: DateTime.utc_now()]
        ],
        conflict_target: :session_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
```

In `do_list_resumable/1` replace `|> where([s], s.resume_policy == "eager")` with:

```elixir
        # Served by the partial index normandy_sessions_inflight_index.
        |> where([s], s.inflight == true)
```

`postgres/schemas.ex`, in `Session`'s schema, after `field(:resume_policy, :string)`:

```elixir
        field(:inflight, :boolean, default: false)
```

Create `lib/normandy/behaviours/session_store/postgres/migration_add_inflight.ex`:

```elixir
if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight do
    @moduledoc """
    Adds Normandy 2.0's in-flight index to `normandy_sessions`: the `inflight` column
    `SessionStore.Postgres.save_turn_state/4` writes with the turn state, a partial index
    over the rows where it is true (`list_resumable/1`), and an index on `head_id`
    (`delete_session/2` checks which entries another session still uses).

    Call it from a host migration after the other `Postgres.Migration*` modules, and run
    it before 2.0 serves traffic: 2.0 reads and writes the column. The column has a
    default, so running it while 1.x nodes still serve is safe. Existing rows start with
    `inflight = false`: a session whose turn was in flight at the upgrade is not resumed
    by `ResumeReaper` until its next turn-state save (see MIGRATING-2.0 §40, "drain eager
    sessions before upgrading").
    """
    use Ecto.Migration

    def up do
      alter table(:normandy_sessions) do
        add(:inflight, :boolean, null: false, default: false)
      end

      create(
        index(:normandy_sessions, [:session_id],
          name: :normandy_sessions_inflight_index,
          where: "inflight = true"
        )
      )

      create(index(:normandy_sessions, [:head_id]))
    end

    def down do
      drop(index(:normandy_sessions, [:head_id]))
      drop(index(:normandy_sessions, [:session_id], name: :normandy_sessions_inflight_index))

      alter table(:normandy_sessions) do
        remove(:inflight)
      end
    end
  end
end
```

Create `priv/test_repo/migrations/20261006000000_add_inflight.exs` (applied to
`normandy_test_w54probe` by `mix test.postgres`'s `ecto.migrate` step; nothing is created or
dropped):

```elixir
defmodule Normandy.TestRepo.Migrations.AddInflight do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight.down()
end
```

`.dialyzer_ignore.exs`: insert before the `# behaviours/memory_store/postgres/migration.ex` comment
(dialyzer reported `unmatched_return` at the `create`/`drop` calls in scratch, as for the other
migrations):

```elixir
  # behaviours/session_store/postgres/migration_add_inflight.ex up/0 + down/0: the same
  # idiomatic Ecto create/drop index calls.
  {"lib/normandy/behaviours/session_store/postgres/migration_add_inflight.ex", :unmatched_return},

```

- [ ] **Step 3d: Implement — Turn.Server**

In `lib/normandy/agents/turn/server.ex`, `persist_turn_state/2` is
(at `d624fbf`; after Task 6.2a the call inside is wrapped in `store_call(fn -> ... end)`):

```elixir
  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: mod.save_turn_state(handle, sid, persistable(turn_state))
```

Make the head bind `= data` and change only the store call, inside `store_call/1` if 6.2a put it
there:

```elixir
  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid} = data, turn_state),
    do: mod.save_turn_state(handle, sid, persistable(turn_state), inflight?(data, turn_state))

  # The store's in-flight index (list_resumable/1, read by ResumeReaper): an eager
  # session whose turn has not ended. Saved with the state, so the two never disagree.
  defp inflight?(%Data{resume_policy: policy}, turn_state),
    do: policy == :eager and resumable?(turn_state)
```

(With 6.2a: `do: store_call(fn -> mod.save_turn_state(handle, sid, persistable(turn_state), inflight?(data, turn_state)) end)`.)
No other line of `server.ex` changes. `grep -n "save_turn_state" lib/normandy/agents/turn/server.ex`
prints exactly one line.

- [ ] **Step 3e: Implement — stubs and call sites**

Every 3-arity `save_turn_state` definition in tests (`def` or `defdelegate`) becomes 4-arity,
forwarding the flag:

```bash
grep -rnE "def(delegate)? save_turn_state\(" test
```

At `d624fbf` this prints 6 lines; after Tasks 6.2a–6.2g it prints 10. The four added by 6.2, by the
same rule:

| File | Before | After |
|---|---|---|
| `test/support/gated_store.ex` (6.2b) | `def save_turn_state({mem, _}, sid, term), do: InMemory.save_turn_state(mem, sid, term)` | `def save_turn_state({mem, _}, sid, term, inflight?),` / `do: InMemory.save_turn_state(mem, sid, term, inflight?)` |
| `test/agents/turn/server_store_failures_test.exs` (6.2a) | `def save_turn_state({mem, _} = h, sid, ts) do` … `InMemory.save_turn_state(mem, sid, ts)` | `def save_turn_state({mem, _} = h, sid, ts, inflight?) do` … `InMemory.save_turn_state(mem, sid, ts, inflight?)` (the `maybe_exit/3` line unchanged) |
| `test/agents/turn/server_start_test.exs` (6.2b) | `defdelegate save_turn_state(mem, sid, term), to: InMemory` | `defdelegate save_turn_state(mem, sid, term, inflight?), to: InMemory` |
| `test/agents/turn/server_compaction_persistence_test.exs` (6.2g) | `defdelegate save_turn_state(h, sid, ts), to: InMemory` | `defdelegate save_turn_state(h, sid, ts, inflight?), to: InMemory` |

Exact rewrites at `d624fbf`:

| File:line | Before | After |
|---|---|---|
| `test/support/flaky_store.ex:28` | `def save_turn_state({mem, _}, sid, term), do: InMemory.save_turn_state(mem, sid, term)` | `def save_turn_state({mem, _}, sid, term, inflight?),` / `do: InMemory.save_turn_state(mem, sid, term, inflight?)` |
| `test/agents/turn/server_test.exs:54` | `def save_turn_state(h, sid, t), do: InMemory.save_turn_state(h, sid, t)` | `def save_turn_state(h, sid, t, i), do: InMemory.save_turn_state(h, sid, t, i)` |
| `test/agents/turn/server_test.exs:79` | `def save_turn_state({h, _, _}, sid, t), do: InMemory.save_turn_state(h, sid, t)` | `def save_turn_state({h, _, _}, sid, t, i), do: InMemory.save_turn_state(h, sid, t, i)` |
| `test/agents/turn/server_test.exs:934` | `def save_turn_state(_handle, _sid, _state), do: :ok` | `def save_turn_state(_handle, _sid, _state, _inflight?), do: :ok` |
| `test/agents/turn/server_errors_test.exs:34` | `def save_turn_state(_handle, _sid, _ts), do: {:error, :store_down}` | `def save_turn_state(_handle, _sid, _ts, _inflight?), do: {:error, :store_down}` |
| `test/hooks/server_hooks_test.exs:61` | `def save_turn_state(h, sid, t), do: InMemory.save_turn_state(h, sid, t)` | `def save_turn_state(h, sid, t, i), do: InMemory.save_turn_state(h, sid, t, i)` |

Every call that seeds a store gets the flag the server would have written: `true` when the
session is `:eager` and the state's status is neither `:stopped` nor `:failed`; `false` for a lazy
session, a terminal state or an opaque test term — except where noted.

```bash
grep -rn "save_turn_state(" test | grep -v "def save_turn_state"
```

At `d624fbf`: 28 lines (1 is the contract, done in Step 1). Rewrites:

| File | Call | 4th argument |
|---|---|---|
| `test/agents/turn/resume_reaper_test.exs` | `"s-eager"` (`:steering`), lines 54 and 180 | `true` |
| same | `"s-lazy"` (`:steering`, lazy template) | `false` |
| same | `"s-done"` (`:stopped`), `"s-failed"` (`:failed`) | `true` — a stale member, as a Redis crash between the two commands leaves; the reaper's `non_terminal?` must still skip them. Replace the comment above them with `# s-done / s-failed: listed (a stale index member, as a Redis crash between the` / `# state and the index write leaves one) but terminal (:stopped / :failed) -> SKIP` |
| same | `"s-live"`, `"s1"` (`:steering` and `:awaiting_approval`, 4 calls), `"s-creds"` | `true` |
| same | 6.2f's `eager_sessions/1` helper (`InMemory.save_turn_state(store, sid, %Turn.State{status: :steering})`) | `true` |
| same | the comment `# s-lazy: lazy -> not in list_resumable -> SKIP` | becomes `# s-lazy: lazy -> saved not in flight -> not in list_resumable -> SKIP` |
| `test/agents/turn/redis_combo_distributed_test.exs` | `"eager_live"`, `"eager_registered"` | `true` |
| same | `"eager_done"` (`:stopped`) | `false`; its comment becomes `# eager but TERMINAL                     -> not in flight, so not listed` |
| `test/agents/turn/server_test.exs` | `"s-resume-announce"` (parked, server `resume_policy: :eager`), `sid` parked (line 1079, eager) | `true` |
| same | line 2222 `if turn_state, do: :ok = InMemory.save_turn_state(store, sid, turn_state)` | `false` (the helper only seeds the state the server loads) |
| `test/agents/turn/eager_resume_test.exs:38` | `steering`, eager | `true` |
| `test/agents/turn/eager_handoff_distributed_test.exs:147` | `steering`, eager | `true` |
| `test/agents/turn/resume_reaper_integration_test.exs:64` | `:awaiting_approval`, eager | `true` (mix format wraps the call: `:ok =` / `PG.save_turn_state(Normandy.TestRepo, sid, %Turn.State{status: :awaiting_approval}, true)`) |
| `test/agents/turn/session_test.exs:257` | `%Turn.State{}` | `false` |
| `test/app_env_config_test.exs:157`, `test/behaviours/session_store/redis_backend_error_test.exs:58`, `redis_wait_test.exs:27`, `redis_store_extra_test.exs:33`, `postgres_test.exs:71,78`, `postgres_backend_error_test.exs:28` | opaque terms (`:state`, `:ts`, `%{step: 1}`, `term`, `%{x: 1}`) | `false` |

After the rewrite this prints nothing:

```bash
grep -rn "save_turn_state(" test lib | grep -v "def save_turn_state\|defdelegate save_turn_state" | grep -v ", true)\|, false)\|inflight?\|, i)"
```

`test/agents/turn/session_test.exs` (`describe "resume_policy: :eager"`): rename the test
`"a Tier-2 start saves it in the template, so the session is listed as resumable"` to
`"a Tier-2 start saves it in the template; the session is listed only once a turn is in flight"`
and replace

```elixir
      assert {:ok, ["s-eager"]} = InMemory.list_resumable(store)
```

with

```elixir
      # No turn ran (the supervisor refused the start), so nothing is in flight.
      assert {:ok, []} = InMemory.list_resumable(store)
```

- [ ] **Step 4: Run; expect pass**

```bash
mix format
mix test test/behaviours/session_store/ test/agents/turn/ test/hooks/server_hooks_test.exs test/app_env_config_test.exs
mix test.redis test/behaviours/session_store/ test/agents/turn/redis_combo_distributed_test.exs
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres test/behaviours/session_store/ test/agents/turn/resume_reaper_integration_test.exs
```

Expected: ` 0 failures` each (scratch: default 202 tests in `session_store/` + `agents/turn/`;
Redis 27 tests; Postgres not run in scratch).

- [ ] **Step 5: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w6-6.3c-precommit.log   # expect " 0 failures", exit 0
mix docs --warnings-as-errors
mix test.redis 2>&1 | tee /tmp/w6-6.3c-redis.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tee /tmp/w6-6.3c-pg.log
mix test --only distributed --include postgres 2>&1 | tee /tmp/w6-6.3c-dist.log
```

(Without Postgres, `--only distributed` has one environmental failure,
`EagerHandoffDistributedTest` "Normandy.TestRepo not started" — the same at `d624fbf`.)

- [ ] **Step 6: Guide and MIGRATING**

`docs/guides/distributed_sessions.md`:

- In the Tier-1 migration snippet, after `Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy.up()` add `    Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight.up()`, and as the first line of `down` add `    Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight.down()`.
- Replace the note under it (`> The \`MigrationAddTemplate\` / \`MigrationAddResumePolicy\` columns are only *used* by` … `may run only \`Migration.up()\` / \`.down()\`.`) with:

```markdown
> The `MigrationAddTemplate`, `MigrationAddResumePolicy` and `MigrationAddInflight` columns are
> only *used* by Tier 2 (template-based reconstruction + eager resume). They're inert under Tier 1,
> but including them now means a later Tier-2 upgrade needs no extra migration. A strictly Tier-1
> deployment may run only `Migration.up()` / `.down()`. Upgrading from 1.x: add a migration that
> runs `MigrationAddInflight.up()` and apply it before 2.0 serves traffic.
```

- In "Eager handoff", replace `eager, unregistered, non-terminal sessions (found via` / `` `SessionStore.list_resumable/1`). `` with:

```markdown
> eager, unregistered, non-terminal sessions (found via
> `SessionStore.list_resumable/1`, which lists only the sessions whose turn is in flight:
> `Turn.Server` saves that flag with every turn state, so the list does not grow with the
> number of sessions stored).
```

`MIGRATING-2.0.md` §40: append to the table (after 6.3a's row):

```markdown
| `@callback save_turn_state(handle, session_id, state)` | `@callback save_turn_state(handle, session_id, state, inflight?)`. `Turn.Server` passes `inflight?: true` while an `:eager` session's turn has not ended (status other than `:stopped`/`:failed`); the store writes it with the state |
| `list_resumable/1`: every session whose config template is `:eager`, whatever its turn state | The sessions whose last `save_turn_state/4` had `inflight?: true`. A template alone no longer lists a session |
| `SessionStore.Redis`: the eager set `"<namespace>:resumable"`, filled by `save_config_template/3` and never emptied | `"<namespace>:inflight"`, kept by `save_turn_state/4`. `"<namespace>:resumable"` is no longer read; delete it after the upgrade |
| `SessionStore.Postgres`: `Migration`, `MigrationAddTemplate`, `MigrationAddResumePolicy` | Also run `MigrationAddInflight` (column `inflight`, a partial index on it, an index on `head_id`) before 2.0 serves traffic |
```

and append these bullets after 6.3a's bullets:

```markdown
- **Your own `SessionStore`.** Implement `save_turn_state/4` and write `inflight?` in the same write
  as the state. If your backend cannot, add the session to the index before writing the state and
  remove it after, so a crash leaves an extra member (the reaper re-checks the turn state), never
  a missing one. `list_resumable/1` returns the sessions saved with `inflight?: true`. Duck-typed
  test stores that define `save_turn_state/3` must take the fourth argument.
- **Drain eager sessions before upgrading.** No store backfills the new index: the turn state is an
  opaque term, and Postgres cannot read it in SQL. A session whose turn is in flight when you
  upgrade is not in the index until `Turn.Server` saves its turn state again, so a node lost in
  that window is not resumed by `ResumeReaper` (the session still recovers on its next caller,
  through the lazy path). Before upgrading, let eager turns finish and approve or reject parked
  calls. Together with §13 (2.0 and 1.x nodes must not host sessions from one Postgres or Redis
  store at the same time), upgrade all session-hosting nodes at once after the drain.
- `SessionStore.Mnesia`: a session row written by 1.x has no `:inflight` key and is not listed until
  its next turn-state save. ETS and InMemory stores do not outlive the node.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/behaviours/session_store.ex
git add lib/normandy/behaviours/session_store/in_memory.ex
git add lib/normandy/behaviours/session_store/ets.ex
git add lib/normandy/behaviours/session_store/mnesia.ex
git add lib/normandy/behaviours/session_store/redis.ex
git add lib/normandy/behaviours/session_store/postgres.ex
git add lib/normandy/behaviours/session_store/postgres/schemas.ex
git add lib/normandy/behaviours/session_store/postgres/migration_add_inflight.ex
git add priv/test_repo/migrations/20261006000000_add_inflight.exs
git add .dialyzer_ignore.exs
git add lib/normandy/agents/turn/server.ex
git add test/support/session_store_contract.ex
git add test/support/flaky_store.ex
git add test/agents/turn/server_inflight_test.exs
git add test/agents/turn/server_test.exs
git add test/agents/turn/server_errors_test.exs
git add test/hooks/server_hooks_test.exs
git add test/agents/turn/resume_reaper_test.exs
git add test/agents/turn/redis_combo_distributed_test.exs
git add test/agents/turn/eager_resume_test.exs
git add test/agents/turn/eager_handoff_distributed_test.exs
git add test/agents/turn/resume_reaper_integration_test.exs
git add test/agents/turn/session_test.exs
git add test/app_env_config_test.exs
git add test/behaviours/session_store/redis_backend_error_test.exs
git add test/behaviours/session_store/redis_wait_test.exs
git add test/behaviours/session_store/redis_store_extra_test.exs
git add test/behaviours/session_store/redis_pipeline_error_test.exs
git add test/behaviours/session_store/postgres_test.exs
git add test/behaviours/session_store/postgres_backend_error_test.exs
git add docs/guides/distributed_sessions.md
git add MIGRATING-2.0.md
git add test/support/gated_store.ex
git add test/agents/turn/server_store_failures_test.exs
git add test/agents/turn/server_start_test.exs
git add test/agents/turn/server_compaction_persistence_test.exs
git commit -m "feat(session_store)!: list_resumable lists in-flight sessions via save_turn_state/4"
```

---

### Task 6.3d: `delete_session/2` on every backend (PERF-8, part 2)

No public function could delete a session from any store (inventory §2). The new callback deletes
turn state, template, index membership and the entries no other session reaches. InMemory, ETS and
Redis copy a fork's entries, so a session's entries are its own; Postgres and Mnesia share ancestors
between forks (`postgres.ex:8-9`, `mnesia.ex:149-152`), so an entry stays while another session's
chain reaches it (R8 / 6.3 Q4 a).

**Files:**
- Modify: `lib/normandy/behaviours/session_store.ex` (new callback)
- Modify: `lib/normandy/behaviours/session_store/in_memory.ex` (`fork/3` copies the chain; `delete_session/2`)
- Modify: `lib/normandy/behaviours/session_store/ets.ex` (`delete_session/2`, its `handle_call/3`)
- Modify: `lib/normandy/behaviours/session_store/mnesia.ex` (`delete_session/2`, `unshared_chain/4`, `walk_unshared/6`)
- Modify: `lib/normandy/behaviours/session_store/redis.ex` (`delete_session/2`)
- Modify: `lib/normandy/behaviours/session_store/postgres.ex` (`delete_session/2`, `do_delete_session/2`, `delete_unshared_chain/3`, `unshared_prefix/3`, new `share_lock_session/2`, `do_fork/3`)
- Modify: `MIGRATING-2.0.md`
- Test: modify `test/support/session_store_contract.ex`, `test/behaviours/session_store/{in_memory,ets,mnesia,redis,postgres_contract}_test.exs`, `test/behaviours/session_store/redis_pipeline_error_test.exs`, `test/behaviours/session_store/postgres_backend_error_test.exs`, `test/behaviours/session_store/mnesia_test.exs` (backend-error module)

**Interfaces:**
- Consumes: `chain_ids/2` and `pipeline_ok/1` (6.3a); the `head_id` index (6.3c's migration); the in-flight index (6.3c). After Task 6.2g, `role: "compaction"` snapshot entries are ordinary entries in the history stream; deletion treats them like any other entry.
- Produces: `@callback delete_session(handle, session_id) :: :ok | {:error, term()}` (idempotent); contract option `stored_entry_ids: {module, function_name}` (required).

- [ ] **Step 1: Write the failing tests**

`test/support/session_store_contract.ex`:

Replace the `@moduledoc` example and its following paragraph:

```elixir
  @moduledoc """
  Shared ExUnit contract for `Normandy.Behaviours.SessionStore` impls.

  Use in a test module that also `use ExUnit.Case`:

      use Normandy.SessionStoreContract,
        impl: Normandy.Behaviours.SessionStore.InMemory,
        stored_entry_ids: {__MODULE__, :stored_entry_ids}

  The impl must export `new/0` (or `new/1` with all defaults) returning the bare
  handle (not `{:ok, handle}`), passable directly to the callbacks.

  `:stored_entry_ids` names a public function of the test module that takes a handle and
  returns the ids of every entry the backend still stores, in any session (an entry with
  no `id` of its own counts under the id `history/2` returns for it). The delete rules
  use it to check that a deleted session's unshared entries are gone.
  """
```

In `__using__/1` replace

```elixir
    impl = Keyword.fetch!(opts, :impl)

    quote bind_quoted: [impl: impl] do
```

with

```elixir
    impl = Keyword.fetch!(opts, :impl)
    stored_entry_ids = Keyword.fetch!(opts, :stored_entry_ids)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [impl: impl, stored_entry_ids: stored_entry_ids] do
```

(credo `--strict` reported "Avoid long quote blocks" in scratch; the comment follows
`test/support/memory_store_contract.ex:14`.) After `@store impl` add `@stored_entry_ids stored_entry_ids`.
Insert before `test "implements the SessionStore behaviour" do`:

```elixir
      defp contract_stored_ids(h) do
        {mod, fun} = @stored_entry_ids
        apply(mod, fun, [h])
      end

      # Entries with their own UUID ids, as Turn.Server writes them: every backend
      # returns that id (a Redis stream id is unique only within its stream).
      defp contract_entry_with_id(role, content),
        do: %{contract_entry(role, content) | id: UUID.uuid4()}

      test "delete_session removes the session; a second delete and a missing one are :ok",
           %{handle: h} do
        {:ok, _} = @store.append_entry(h, "doomed", contract_entry("user", "a"))
        :ok = @store.save_turn_state(h, "doomed", {:state, :steering}, true)
        :ok = @store.save_config_template(h, "doomed", %{template_id: "k", resume_policy: :eager})
        :ok = @store.save_turn_state(h, "kept", {:state, :steering}, true)

        assert :ok = @store.delete_session(h, "doomed")

        # The in-flight index shrinks: the reaper never sees a deleted session.
        assert {:ok, ["kept"]} = @store.list_resumable(h)
        assert {:ok, []} = @store.history(h, "doomed")
        assert :error = @store.load_turn_state(h, "doomed")
        assert :error = @store.load_config_template(h, "doomed")

        assert :ok = @store.delete_session(h, "doomed")
        assert :ok = @store.delete_session(h, "never-existed")
      end

      test "a deleted session's id starts a new history", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "reused", contract_entry("user", "old"))
        :ok = @store.delete_session(h, "reused")

        {:ok, _} = @store.append_entry(h, "reused", contract_entry("user", "new"))
        assert {:ok, [%{content: "new"}]} = @store.history(h, "reused")
      end

      # Review Focus 1: a compacted session, a fork from before its snapshot, then a
      # delete of the parent.
      test "deleting a fork's parent keeps the fork's history and drops the parent's own entries",
           %{handle: h} do
        {:ok, _} = @store.append_entry(h, "parent", contract_entry_with_id("user", "a"))
        {:ok, at} = @store.append_entry(h, "parent", contract_entry_with_id("assistant", "b"))
        {:ok, own} = @store.append_entry(h, "parent", contract_entry_with_id("user", "c"))

        snapshot = %{
          contract_entry_with_id("compaction", nil)
          | content: %{
              version: 1,
              entries: [%{id: "x", turn_id: "t", role: "user", content: "c"}]
            }
        }

        {:ok, snap} = @store.append_entry(h, "parent", snapshot)
        {:ok, forked} = @store.fork(h, "parent", at)

        assert :ok = @store.delete_session(h, "parent")

        assert {:ok, entries} = @store.history(h, forked)
        assert Enum.map(entries, & &1.content) == ["a", "b"]

        stored = contract_stored_ids(h)
        refute own in stored
        refute snap in stored
        assert Enum.all?(entries, &(&1.id in stored))
      end

      test "deleting a fork keeps its parent's history", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "parent", contract_entry_with_id("user", "a"))
        {:ok, at} = @store.append_entry(h, "parent", contract_entry_with_id("assistant", "b"))
        {:ok, _} = @store.append_entry(h, "parent", contract_entry_with_id("user", "c"))
        {:ok, forked} = @store.fork(h, "parent", at)
        {:ok, fork_own} = @store.append_entry(h, forked, contract_entry_with_id("assistant", "d"))

        assert :ok = @store.delete_session(h, forked)

        assert {:ok, entries} = @store.history(h, "parent")
        assert Enum.map(entries, & &1.content) == ["a", "b", "c"]
        refute fork_own in contract_stored_ids(h)
      end
```

(The snapshot content is the 6.2g shape `%{version: 1, entries: [%{id, turn_id, role, content}]}`.
Explicit ids are required: in scratch, with stream ids, Redis failed this test 1 run in 5 — a fork's
copy got the same millisecond stream id as the parent's deleted entry.)

Give each backend test module its `stored_entry_ids/1`:

`test/behaviours/session_store/in_memory_test.exs` (whole file):

```elixir
defmodule Normandy.Behaviours.SessionStore.InMemoryTest do
  use ExUnit.Case, async: true

  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.InMemory,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  def stored_entry_ids(pid) do
    Agent.get(pid, fn state ->
      Enum.flat_map(state.sessions, fn {_sid, memory} -> Map.keys(memory.entries) end)
    end)
  end
end
```

`test/behaviours/session_store/ets_test.exs`: replace
`use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.ETS` (first module) with:

```elixir
  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.ETS,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  # The table is private to its owner: read it there. :sys.replace_state/2 runs the
  # function in the owner and replies after it, so the message is already here.
  def stored_entry_ids(pid) do
    test_pid = self()

    :sys.replace_state(pid, fn table ->
      send(test_pid, {:entry_ids, :ets.select(table, [{{{:entry, :_, :"$1"}, :_}, [], [:"$1"]}])})
      table
    end)

    receive do
      {:entry_ids, ids} -> ids
    after
      0 -> raise "ETS owner did not report its entry ids"
    end
  end
```

`test/behaviours/session_store/mnesia_test.exs` (first module): replace
`use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Mnesia` with:

```elixir
  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.Mnesia,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  def stored_entry_ids(%{entries: entries}), do: :mnesia.dirty_all_keys(entries)
```

and in `MnesiaBackendErrorTest` add:

```elixir
  test "delete_session reports an aborted transaction as {:error, reason}" do
    assert {:error, {:no_exists, :normandy_missing_table}} =
             Mnesia.delete_session(missing_table_handle(), "s1")
  end
```

`test/behaviours/session_store/redis_test.exs` (whole file):

```elixir
defmodule Normandy.Behaviours.SessionStore.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis

  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.Redis,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  # Every stream in the handle's namespace; an entry's id is its `id` field, else its
  # stream id (as history/2 returns it).
  def stored_entry_ids({conn, ns}) do
    {:ok, keys} = Redix.command(conn, ["KEYS", "#{ns}:*:stream"])
    Enum.flat_map(keys, &stream_entry_ids(conn, &1))
  end

  defp stream_entry_ids(conn, key) do
    {:ok, raw} = Redix.command(conn, ["XRANGE", key, "-", "+"])
    Enum.map(raw, fn [stream_id, kv] -> entry_id(stream_id, kv) end)
  end

  defp entry_id(stream_id, kv) do
    case kv |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end) |> Map.get("id") do
      id when id in [nil, ""] -> stream_id
      id -> id
    end
  end
end
```

(If Task 6.3g has changed the Redis handle shape by the time this runs — it runs after this task in
the header order, so it has not — the head match `{conn, ns}` is what 6.3g must keep or update.)

`test/behaviours/session_store/postgres_contract_test.exs`: replace
`use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Postgres` with:

```elixir
  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.Postgres,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  def stored_entry_ids(repo) do
    %{rows: rows} = repo.query!("SELECT id FROM normandy_session_entries")
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end
```

`test/behaviours/session_store/redis_pipeline_error_test.exs`: append before the final `end`:

```elixir
  test "delete_session returns the index command's in-band error" do
    {h, conn, ns} = broken_index()

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} = Redis.delete_session(h, "s1")

    {:ok, _} = Redix.command(conn, ["DEL", "#{ns}:inflight"])
  end
```

`test/behaviours/session_store/postgres_backend_error_test.exs`: in the `for` list add after the
`list_resumable:` entry:

```elixir
          delete_session: fn -> Postgres.delete_session(DownRepo, "s1") end,
```

If `test/support/gated_store.ex` (6.2b) declares `@behaviour Normandy.Behaviours.SessionStore`, add
`def delete_session(store, sid), do: InMemory.delete_session(<its InMemory handle>, sid)` there
(compile with `--warnings-as-errors` reports it otherwise). The duck-typed stubs need nothing: only
`Turn.Session.delete/1` calls the callback. `FailingAppendStore` (`server_test.exs:928`) declares
the behaviour inside a test body and already omits callbacks; leave it.

- [ ] **Step 2: Run them; expect failure**

```bash
mix format
mix test test/behaviours/session_store/
```

Expected: the suite compiles (`@store.delete_session` is a dynamic call) and every delete rule fails
with `UndefinedFunctionError ... delete_session/2` on InMemory, ETS and Mnesia;
`MnesiaBackendErrorTest` "delete_session reports ..." fails the same way, and so does
`PostgresBackendErrorTest` "every callback reports an unreachable database ..." (it runs in the
default suite: its repo is a stub). Observed at preflight: `64 tests, 14 failures (62 excluded)`.

- [ ] **Step 3: Implement**

`lib/normandy/behaviours/session_store.ex`, after the `list_resumable` callback:

```elixir
  @doc """
  Deletes a session: its turn state, its config template, its membership of the
  in-flight index and the entries of its history that no other session reaches.

  Idempotent: deleting a missing session is `:ok`. A fork keeps its history: on the
  backends that copy a fork's entries (InMemory, ETS, Redis) the session's own copy goes;
  on those that share ancestor entries between forks (Postgres, Mnesia) an entry stays
  while another session's history still reaches it. Deleting does not stop a live
  `Turn.Server`; `Normandy.Agents.Turn.Session.delete/1` does both.
  """
  @callback delete_session(handle(), session_id()) :: :ok | {:error, term()}
```

`in_memory.ex`. In `fork/3` replace

```elixir
            {:ok, forked} ->
              new_id = UUID.uuid4()
              {{:ok, new_id}, put_in(state.sessions[new_id], forked)}
```

with

```elixir
            {:ok, forked} ->
              new_id = UUID.uuid4()
              # Only the chain the fork's head reaches: the parent's later entries stay
              # the parent's, so deleting it removes them.
              chain = AgentMemory.entry_chain(forked)
              forked = %{forked | entries: Map.new(chain, &{&1.id, &1})}
              {{:ok, new_id}, put_in(state.sessions[new_id], forked)}
```

(Do not use `AgentMemory.from_entries/1` here: after Task 6.2g it applies and drops compaction
snapshots, which a store must keep.) Add before `# Append an entry, minting`:

```elixir
  @impl true
  def delete_session(pid, session_id) do
    Agent.update(pid, fn state ->
      %{
        state
        | sessions: Map.delete(state.sessions, session_id),
          turn_states: Map.delete(state.turn_states, session_id),
          config_templates: Map.delete(state.config_templates, session_id),
          inflight: MapSet.delete(state.inflight, session_id)
      }
    end)
  end
```

`ets.ex`. After the client `list_resumable/1`:

```elixir
  @impl Normandy.Behaviours.SessionStore
  def delete_session(pid, session_id), do: GenServer.call(pid, {:delete_session, session_id})
```

and before `defp head(table, session_id) do`:

```elixir
  def handle_call({:delete_session, session_id}, _from, table) do
    # A fork copies its entries, so every {:entry, session_id, _} row is this session's.
    :ets.match_delete(table, {{:entry, session_id, :_}, :_})

    for key <- [:head, :turn_state, :config_template, :inflight],
        do: :ets.delete(table, {key, session_id})

    {:reply, :ok, table}
  end
```

`mnesia.ex`. Replace the line `# --- private ---` with:

```elixir
  @doc """
  Deletes the session's row and the entries of its chain that no other session reaches
  (`c:Normandy.Behaviours.SessionStore.delete_session/2`).

  Forks share ancestor entries here, and an entry's parent link sits inside its data, so
  finding the entries another session still uses scans both tables: O(entries + sessions)
  under a write lock on both, which blocks every other write to the store meanwhile.
  """
  @impl true
  def delete_session(%{entries: et, sessions: st}, session_id) do
    to_ok(
      txn(fn ->
        :mnesia.write_lock_table(st)
        :mnesia.write_lock_table(et)

        case :mnesia.read({st, session_id}) do
          [] ->
            :ok

          [{_, ^session_id, %{head_id: head}}] ->
            et |> unshared_chain(st, session_id, head) |> Enum.each(&:mnesia.delete({et, &1}))
            :mnesia.delete({st, session_id})
        end
      end)
    )
  end

  # --- private ---

  # The ids on the chain from `head`, newest first, up to the first one another session
  # reaches: another session's head, or an entry with a child off this chain. Every
  # ancestor of a reached entry is reached too, so the walk stops there.
  defp unshared_chain(et, st, session_id, head) do
    other_heads =
      :mnesia.foldl(
        fn
          {_, sid, %{head_id: h}}, acc when sid != session_id and h != nil -> MapSet.put(acc, h)
          _, acc -> acc
        end,
        MapSet.new(),
        st
      )

    children =
      :mnesia.foldl(
        fn
          {_, id, %{parent_id: p}}, acc when p != nil -> Map.update(acc, p, [id], &[id | &1])
          _, acc -> acc
        end,
        %{},
        et
      )

    walk_unshared(et, head, nil, other_heads, children, [])
  end

  defp walk_unshared(_et, nil, _child, _heads, _children, acc), do: acc

  defp walk_unshared(et, id, child, heads, children, acc) do
    shared? =
      MapSet.member?(heads, id) or Enum.any?(Map.get(children, id, []), &(&1 != child))

    with false <- shared?,
         [{_, ^id, %{parent_id: parent}}] <- :mnesia.read({et, id}) do
      walk_unshared(et, parent, id, heads, children, [id | acc])
    else
      _stop -> acc
    end
  end
```

`redis.ex`. Before `# --- private ---`:

```elixir
    @impl true
    def delete_session(handle, session_id) do
      {conn, ns} = conn_ns(handle)
      wait = wait_setting!(handle)

      # A fork copies its prefix into its own stream, so the session's keys are all its
      # own. The index entry goes last: a crash in between leaves an extra member whose
      # turn state is gone, which the reaper skips.
      cmds = [
        ["DEL", stream_key(ns, session_id), meta_key(ns, session_id)],
        ["SREM", inflight_key(ns), session_id]
      ]

      with {:ok, _} <- pipeline_ok(Redix.pipeline(conn, cmds)), do: wait(conn, wait)
    end
```

`postgres.ex`. In `do_fork/3` replace

```elixir
          repo.get(Session, session_id) == nil ->
            repo.rollback(:no_such_session)
```

with

```elixir
          # FOR SHARE: a concurrent delete_session/2 of this session waits for the fork
          # (and then keeps the entries the fork reaches), or the fork sees no session.
          share_lock_session(repo, session_id) == nil ->
            repo.rollback(:no_such_session)
```

After `lock_session/2` add (`Ecto.Query.lock/3` needs a literal, hence a second function):

```elixir
    defp share_lock_session(repo, session_id) do
      Session
      |> where([s], s.session_id == ^session_id)
      |> lock("FOR SHARE")
      |> repo.one()
    end
```

Before `# --- Private helpers ---` add:

```elixir
    @impl true
    def delete_session(repo, session_id),
      do: backend(fn -> do_delete_session(repo, session_id) end)

    # One transaction holding the session row: a concurrent fork of this session (which
    # takes the row FOR SHARE) runs wholly before or after it. Entries another session
    # reaches stay: forks share ancestors here.
    defp do_delete_session(repo, session_id) do
      repo.transaction(fn ->
        case lock_session(repo, session_id) do
          nil ->
            :ok

          %Session{head_id: head_id} ->
            _ = delete_unshared_chain(repo, session_id, head_id)
            {_count, _} = repo.delete_all(where(Session, [s], s.session_id == ^session_id))
            :ok
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp delete_unshared_chain(_repo, _session_id, nil), do: :ok

    defp delete_unshared_chain(repo, session_id, head_id) do
      chain = chain_ids(repo, head_id)
      ids = Enum.map(chain, fn {id, _parent} -> id end)

      %{rows: head_rows} =
        SQL.query!(
          repo,
          "SELECT head_id FROM normandy_sessions WHERE head_id = ANY($1::uuid[]) AND session_id <> $2",
          [ids, session_id]
        )

      %{rows: child_rows} =
        SQL.query!(
          repo,
          "SELECT parent_id, id FROM normandy_session_entries WHERE parent_id = ANY($1::uuid[])",
          [ids]
        )

      other_heads = MapSet.new(head_rows, fn [id] -> id end)
      children = Enum.group_by(child_rows, fn [parent, _id] -> parent end, fn [_p, id] -> id end)

      case unshared_prefix(chain, other_heads, children) do
        [] ->
          :ok

        doomed ->
          SQL.query!(repo, "DELETE FROM normandy_session_entries WHERE id = ANY($1::uuid[])", [
            doomed
          ])
      end
    end

    # The ids from the head down to the first entry another session reaches: another
    # session's head, or an entry with a child off this chain. Every ancestor of a reached
    # entry is reached too.
    defp unshared_prefix(chain, other_heads, children) do
      chain
      |> Enum.reduce_while({nil, []}, fn {id, _parent}, {child, acc} ->
        shared? =
          MapSet.member?(other_heads, id) or
            Enum.any?(Map.get(children, id, []), &(&1 != child))

        if shared?, do: {:halt, {child, acc}}, else: {:cont, {id, [id | acc]}}
      end)
      |> elem(1)
    end
```

All four statements use indexes: the `chain_ids/2` CTE the primary key, the head lookup 6.3c's
`head_id` index, the child lookup `parent_id`'s index (`postgres/migration.ex:24`), the delete the
primary key. A `Postgrex.Error` inside the transaction re-raises out of `repo.transaction/1` and
`backend/1` returns `{:error, e}`.

- [ ] **Step 4: Run; expect pass**

```bash
mix format
mix test test/behaviours/session_store/
mix test.redis test/behaviours/session_store/
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres test/behaviours/session_store/
```

Expected: ` 0 failures` each (scratch: default 60 store tests; Redis contract stable over 6 runs).

- [ ] **Step 5: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w6-6.3d-precommit.log   # expect " 0 failures", exit 0
mix docs --warnings-as-errors
mix test.redis 2>&1 | tee /tmp/w6-6.3d-redis.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tee /tmp/w6-6.3d-pg.log
mix test --only distributed --include postgres 2>&1 | tee /tmp/w6-6.3d-dist.log
```

- [ ] **Step 6: MIGRATING-2.0.md**

§40 table, append:

```markdown
| No store could delete a session | `@callback delete_session(handle, session_id) :: :ok \| {:error, term}`: removes the turn state, the template, the in-flight index membership and the history no other session reaches; `:ok` for a missing session. Every built-in store implements it; implement it in your own store |
| `SessionStore.InMemory.fork/3` and `SessionStore.ETS.fork/3` kept every entry of the parent in the fork | Only the history up to the fork point (what the fork's `history/2` returned anyway) |
```

§40 bullets, append:

```markdown
- Forks and deletes: on Postgres and Mnesia a fork shares the parent's entries up to the fork point,
  so `delete_session/2` keeps every entry another session's history still reaches; on InMemory, ETS
  and Redis a fork has its own copy. `SessionStore.Postgres.fork/3` now takes the source session's
  row `FOR SHARE`, so a fork and a delete of the same session do not interleave.
- `SessionStore.Mnesia.delete_session/2` scans both tables under a write lock on both
  (O(entries + sessions)); writes to the store wait for it.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/behaviours/session_store.ex
git add lib/normandy/behaviours/session_store/in_memory.ex
git add lib/normandy/behaviours/session_store/ets.ex
git add lib/normandy/behaviours/session_store/mnesia.ex
git add lib/normandy/behaviours/session_store/redis.ex
git add lib/normandy/behaviours/session_store/postgres.ex
git add test/support/session_store_contract.ex
git add test/behaviours/session_store/in_memory_test.exs
git add test/behaviours/session_store/ets_test.exs
git add test/behaviours/session_store/mnesia_test.exs
git add test/behaviours/session_store/redis_test.exs
git add test/behaviours/session_store/postgres_contract_test.exs
git add test/behaviours/session_store/redis_pipeline_error_test.exs
git add test/behaviours/session_store/postgres_backend_error_test.exs
git add MIGRATING-2.0.md
git commit -m "feat(session_store)!: delete_session/2 on every store, keeping fork-shared entries"
```

---

### Task 6.3e: `Turn.Session.delete/1`

Without a caller the store callback is unreachable for hosts, and they would have to stop servers
themselves (R8 / 6.3 Q5). `delete/1` stops the live server through the supervisor (header conflict 2)
and then calls `delete_session/2`. A store call that exits is a failed delete, as in `Turn.Server`
(6.2a's `store_call/1` rule: exits caught, raises propagate; decision 25, A6):
`{:error, %TurnError{type: :persist_failed, reason: {:store_exit, tag}}}`. Registry and supervisor
calls are not wrapped, as in `run/2` (ruling, `PREFLIGHT.md`).

**Files:**
- Modify: `lib/normandy/agents/turn/session.ex` (moduledoc first paragraph, `delete/1`, `delete_from_store/3`, `stop_server_fun!/1`, `stop_live_server/3`)
- Modify: `lib/normandy/agents/turn/supervisor.ex` (`stop_server/2`)
- Modify: `lib/normandy/agents/turn/supervisor/horde.ex` (`stop_server/2`)
- Modify: `lib/normandy/agents/turn/resume_reaper.ex` (moduledoc and the `:store` option doc only; 6.2f owns `reap/1`)
- Modify: `lib/normandy/turn_error.ex` (moduledoc bullets only)
- Modify: `docs/guides/distributed_sessions.md`, `MIGRATING-2.0.md`
- Test: create `test/agents/turn/session_delete_test.exs`

**Interfaces:**
- Consumes: `SessionStore.delete_session/2` (6.3d); `SessionRegistry.whereis/2`; `TurnError.drop_stacktraces/1` (exists before Wave 6); `Describe.reason_term/1` (6.2a); `DynamicSupervisor.terminate_child/2`, `Horde.DynamicSupervisor.terminate_child/2` (both `:ok | {:error, :not_found}`). After Tasks 6.2c/6.2d, `session.ex` has `run/2`'s passivation retry; `delete/1` is added after `put_config/2` and does not touch it.
- Produces: `Normandy.Agents.Turn.Session.delete(t()) :: :ok | {:error, TurnError.t()}`; `Normandy.Agents.Turn.Supervisor.stop_server(sup, pid) :: :ok | {:error, :not_found}`; `Normandy.Agents.Turn.Supervisor.Horde.stop_server(sup, pid) :: :ok | {:error, :not_found}`.

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn/session_delete_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.SessionDeleteTest do
  @moduledoc """
  Task 6.3e (PERF-8, decision 24 R8): `Turn.Session.delete/1` stops the live server
  through the supervisor, then deletes the session from the store.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log
  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Session
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Test.FakeTool
  alias Normandy.Test.TurnConfig
  alias Normandy.Test.TurnConfig.Resp
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  defmodule DownRegistry do
    @moduledoc false
    def whereis(_handle, _sid), do: {:error, :registry_down}
  end

  defmodule RefusingStore do
    @moduledoc false
    def delete_session(_handle, _sid), do: {:error, :disk_full}
  end

  # A store whose call exits, as a GenServer.call to a stuck store process does.
  defmodule ExitingStore do
    @moduledoc false
    def delete_session(_handle, sid),
      do: exit({:timeout, {GenServer, :call, [:store, {:delete_session, sid}, 5_000]}})
  end

  defmodule RaisingStore do
    @moduledoc false
    def delete_session(_handle, _sid), do: raise("store bug")
  end

  # A supervisor whose stop_server/2 never finds the child.
  defmodule ForeignSupervisor do
    @moduledoc false
    def start_server(_sup, _opts), do: {:error, :unused}
    def stop_server(_sup, _pid), do: {:error, :not_found}
  end

  defmodule NoStopSupervisor do
    @moduledoc false
    def start_server(_sup, _opts), do: {:error, :unused}
  end

  defp session(store, reg, sup, extra \\ []) do
    Session.new(
      Keyword.merge(
        [
          session_id: "s-del",
          config: TurnConfig.build(),
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: sup,
          handlers: %{
            BaseAgent.non_streaming_handlers()
            | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
          }
        ],
        extra
      )
    )
  end

  defp setup_infra do
    {:ok, sup} = Turn.Supervisor.start_link([])
    {InMemory.new(), Native.new(), sup}
  end

  defp seed(store), do: InMemory.append_entry(store, "s-del", %Entry{role: "user", content: "a"})

  test "stops the live server and deletes the stored session" do
    {store, reg, sup} = setup_infra()
    session = session(store, reg, sup)
    assert {:ok, %Resp{content: "ok"}} = Session.run(session, "hello")
    {:ok, pid} = Native.whereis(reg, "s-del")
    ref = Process.monitor(pid)

    assert :ok = Session.delete(session)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
    assert DynamicSupervisor.which_children(sup) == []
    assert {:ok, []} = InMemory.history(store, "s-del")
    assert :error = InMemory.load_turn_state(store, "s-del")
    assert wait_until(fn -> Native.whereis(reg, "s-del") == :none end)
  end

  test "with no live server it deletes the stored session; again is :ok" do
    {store, reg, sup} = setup_infra()
    {:ok, _} = seed(store)

    assert :ok = Session.delete(session(store, reg, sup))
    assert {:ok, []} = InMemory.history(store, "s-del")
    assert :ok = Session.delete(session(store, reg, sup))
  end

  # The plan's acceptance: the eager set shrinks after a session is deleted.
  test "an :eager session parked mid-turn leaves the in-flight index and its caller exits" do
    {store, reg, sup} = setup_infra()
    test_pid = self()

    call_llm = fn _c, _s, _r ->
      %Resp{content: "", tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]}
    end

    config = %{
      TurnConfig.build()
      | toolset: Toolset.new([%FakeTool{name: "billing"}]),
        behaviours: %Normandy.Behaviours.Config{
          policy:
            {Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    session =
      session(store, reg, sup,
        config: config,
        resume_policy: :eager,
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm},
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    # Start the server, then call it directly: the exit is the caller's to observe
    # (Session.run/2 may retry a stopped server, Task 6.2d).
    {:ok, pid} =
      Turn.Supervisor.start_server(sup,
        session_id: "s-del",
        config: config,
        store: {InMemory, store},
        registry: {Native, reg},
        resume_policy: :eager,
        handlers: session.handlers,
        subscriber: session.subscriber
      )

    spawn(fn ->
      result =
        try do
          Turn.Server.run(pid, "bill me")
        catch
          :exit, reason -> {:exited, reason}
        end

      send(test_pid, {:caller, result})
    end)

    assert_receive {:event, :awaiting_approval, _}, 2_000
    assert wait_until(fn -> InMemory.list_resumable(store) == {:ok, ["s-del"]} end)

    assert :ok = Session.delete(session)

    assert {:ok, []} = InMemory.list_resumable(store)
    assert_receive {:caller, {:exited, {:shutdown, _call}}}, 1_000
  end

  test "through the Horde supervisor too" do
    alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
    alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

    reg = HReg.new()
    sup = :"del_#{System.unique_integer([:positive])}"
    {:ok, _} = HSup.start_link(name: sup)
    store = InMemory.new()
    session = session(store, nil, sup, supervisor_mod: HSup, registry: {HReg, reg})

    assert {:ok, %Resp{content: "ok"}} = Session.run(session, "hello")
    assert wait_until(fn -> match?({:ok, _}, HReg.whereis(reg, "s-del")) end)
    {:ok, pid} = HReg.whereis(reg, "s-del")
    ref = Process.monitor(pid)

    assert :ok = Session.delete(session)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
    assert {:ok, []} = InMemory.history(store, "s-del")
    assert {:error, :not_found} = HSup.stop_server(sup, pid)
  end

  test "a registry that cannot answer deletes nothing" do
    {store, _reg, sup} = setup_infra()
    {:ok, _} = seed(store)
    session = session(store, nil, sup, registry: {DownRegistry, nil})

    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Session.delete(session)

    assert {:ok, [_]} = InMemory.history(store, "s-del")
  end

  test "a live server the supervisor does not own deletes nothing" do
    {store, reg, _sup} = setup_infra()
    :ok = Native.register(reg, "s-del", self())
    {:ok, _} = seed(store)
    session = session(store, reg, :unused, supervisor_mod: ForeignSupervisor)

    assert {:error, %TurnError{type: :session_unavailable, reason: {:not_stopped, :not_found}}} =
             Session.delete(session)

    assert {:ok, [_]} = InMemory.history(store, "s-del")
  end

  test "a store that refuses the delete is a :persist_failed TurnError" do
    {_store, reg, sup} = setup_infra()
    session = session(nil, reg, sup, store: {RefusingStore, nil})

    assert {:error, %TurnError{type: :persist_failed, reason: :disk_full}} =
             Session.delete(session)
  end

  # Decision 25 (A6): a store exit is a failed delete, as in Turn.Server (Task 6.2a's
  # store_call/1); the call's arguments (the session id here) are not in the reason.
  test "a store that exits is a :persist_failed TurnError with {:store_exit, tag}" do
    {_store, reg, sup} = setup_infra()
    session = session(nil, reg, sup, store: {ExitingStore, nil})

    assert {:error,
            %TurnError{
              type: :persist_failed,
              reason: {:store_exit, {:timeout, {GenServer, :call, "a list"}}}
            }} = Session.delete(session)
  end

  test "a store that raises raises (a bug, not a failed delete)" do
    {_store, reg, sup} = setup_infra()
    session = session(nil, reg, sup, store: {RaisingStore, nil})

    assert_raise RuntimeError, "store bug", fn -> Session.delete(session) end
  end

  test "a :supervisor_mod without stop_server/2 raises, naming it" do
    {store, reg, _sup} = setup_infra()
    session = session(store, reg, :unused, supervisor_mod: NoStopSupervisor)

    assert_raise ArgumentError,
                 "Normandy.Agents.Turn.Session.delete/1: the :supervisor_mod " <>
                   "Normandy.Agents.Turn.SessionDeleteTest.NoStopSupervisor does not export " <>
                   "stop_server/2, so the session's server cannot be stopped",
                 fn -> Session.delete(session) end
  end

  test "a non-session argument raises" do
    assert_raise ArgumentError,
                 ~r/delete\/1: expected a %Normandy.Agents.Turn.Session\{\}.*got: a map/,
                 fn -> Session.delete(%{}) end
  end
end
```

- [ ] **Step 2: Run it; expect failure**

```bash
mix format
mix test test/agents/turn/session_delete_test.exs
```

Expected: 11 failures, `UndefinedFunctionError ... Normandy.Agents.Turn.Session.delete/1 is
undefined or private`.

- [ ] **Step 3: Implement**

`lib/normandy/agents/turn/supervisor.ex`, after `start_server/2`:

```elixir
  @doc """
  Stops the session server `pid`, a child of `sup`, without a restart. Returns
  `{:error, :not_found}` when `pid` is not a child of `sup` (it already exited, or another
  supervisor started it). Used by `Normandy.Agents.Turn.Session.delete/1`.
  """
  @spec stop_server(:gen_statem.server_ref() | pid(), pid()) :: :ok | {:error, :not_found}
  def stop_server(sup, pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(sup, pid)
```

`lib/normandy/agents/turn/supervisor/horde.ex`, after `start_server/2`:

```elixir
    @doc """
    Stops the session server `pid`, on any node, without a restart. Returns
    `{:error, :not_found}` when the Horde supervisor `sup` (its name) has no such child.
    Used by `Normandy.Agents.Turn.Session.delete/1`.
    """
    @spec stop_server(term(), pid()) :: :ok | {:error, :not_found}
    def stop_server(sup, pid) when is_pid(pid),
      do: Horde.DynamicSupervisor.terminate_child(sup, pid)
```

(`Turn.Server` does not trap exits, so the supervisor's `:shutdown` ends it without `terminate/3`
and without a store write; the stop happens-before the delete.)

`lib/normandy/agents/turn/session.ex`. In the moduledoc replace

```
  A handle on one durable session. `new/1` checks the options once; `run/2` routes a turn
  to the session's `Turn.Server` and `approve/2` delivers approval decisions to it.
```

with

```
  A handle on one durable session. `new/1` checks the options once; `run/2` routes a turn
  to the session's `Turn.Server`, `approve/2` delivers approval decisions to it and
  `delete/1` stops it and deletes it from the store.
```

Insert before the `@doc` of `put_config/2`:

```elixir
  @doc """
  Deletes the session: stops its live server, if any, through `:supervisor_mod`'s
  `stop_server/2`, then deletes it from the store (`SessionStore.delete_session/2`: turn
  state, template, in-flight index membership, and the history no fork still uses).
  Returns `:ok`, also for a session that does not exist.

  A server is stopped by its supervisor's shutdown, mid-turn included: a `run/2` waiting
  on it exits, and a turn in flight is not resumed. Errors:

    * `{:error, %Normandy.TurnError{type: :session_unavailable, reason: reason}}` - the
      registry could not answer (`reason` is its reason), or the live server is not a
      child of `:supervisor` (`reason: {:not_stopped, :not_found}`; it may have just
      exited, so calling again is safe). Nothing was deleted.
    * `{:error, %Normandy.TurnError{type: :persist_failed, reason: reason}}` - the store
      refused the delete (`reason` is its reason reduced to its tags, as for `run/2`'s
      store failures), or its call exited (`reason: {:store_exit, tag}`, the exit reason
      reduced the same way, e.g. `{:store_exit, {:timeout, {GenServer, :call, "a list"}}}`).
      The server is already stopped; calling again finishes the job. A store that raises
      raises.

  The handle's `:supervisor_mod` must export `stop_server/2`
  (`Normandy.Agents.Turn.Supervisor` and `Normandy.Agents.Turn.Supervisor.Horde` do);
  another module raises `ArgumentError` naming it.

  Nothing stops a new turn from starting the session again: a `run/2` that starts after
  the server stopped (or a `ResumeReaper` restart between the stop and the delete) gets
  a fresh server, which then finds the history deleted or, if it wrote first, keeps its
  own writes. Stop routing turns to a session before deleting it.
  """
  @spec delete(t()) :: :ok | {:error, TurnError.t()}
  def delete(%__MODULE__{} = session) do
    {reg_mod, reg_handle} = session.registry
    {store_mod, store_handle} = session.store
    stop_server = stop_server_fun!(session.supervisor_mod)

    with :ok <-
           stop_live_server(reg_mod.whereis(reg_handle, session.session_id), session, stop_server) do
      # The store's reason is reduced to its tags, as run/2's template save does.
      case delete_from_store(store_mod, store_handle, session.session_id) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, %TurnError{type: :persist_failed, reason: Describe.reason_term(reason)}}
      end
    end
  end

  def delete(other) do
    raise ArgumentError,
          "Normandy.Agents.Turn.Session.delete/1: expected a %Normandy.Agents.Turn.Session{} " <>
            "(build one with Normandy.Agents.Turn.Session.new/1), got: " <>
            Describe.type_of(other)
  end
```

Insert before `defp ensure_server(`:

```elixir
  # A store call that exits (a dead store process, a call timeout) is a failed delete,
  # as in Turn.Server (store_call/1); a raise is a bug and propagates.
  defp delete_from_store(store_mod, store_handle, session_id) do
    store_mod.delete_session(store_handle, session_id)
  catch
    :exit, reason -> {:error, {:store_exit, TurnError.drop_stacktraces(reason)}}
  end

  defp stop_server_fun!(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :stop_server, 2) do
      &mod.stop_server/2
    else
      raise ArgumentError,
            "Normandy.Agents.Turn.Session.delete/1: the :supervisor_mod #{inspect(mod)} " <>
              "does not export stop_server/2, so the session's server cannot be stopped"
    end
  end

  defp stop_live_server(:none, _session, _stop_server), do: :ok

  defp stop_live_server({:ok, pid}, session, stop_server) do
    case stop_server.(session.supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, %TurnError{type: :session_unavailable, reason: {:not_stopped, :not_found}}}
    end
  end

  defp stop_live_server({:error, reason}, _session, _stop_server),
    do: {:error, %TurnError{type: :session_unavailable, reason: reason}}
```

`lib/normandy/turn_error.ex` moduledoc (as Task 6.2a left it). In the `:persist_failed` bullet replace

```
      their count, `{:timeout, {GenServer, :call, 3}}`
```

with

```
      their count, `{:timeout, {GenServer, :call, 3}}`. `Turn.Session.delete/1` returns it
      when the store refused the delete or its call exited, with the reason reduced to its
      tags (`{:store_exit, {:timeout, {GenServer, :call, "a list"}}}`)
```

and at the end of the `:session_unavailable` bullet replace

```
      `Turn.Session.approve/2` returns it with `reason: :no_session` when no server is live
```

with

```
      `Turn.Session.approve/2` returns it with `reason: :no_session` when no server is live;
      `Turn.Session.delete/1` returns it when the registry cannot answer or the live server
      is not the supervisor's (`reason: {:not_stopped, :not_found}`)
```

`lib/normandy/agents/turn/resume_reaper.ex` (6.2f rewrote `reap/1`; these are doc-only edits —
if 6.2f reworded these sentences, keep its wording and apply the same meaning). In the moduledoc
replace (the third line continues with ` It is restarted as a thin spec`; keep that sentence)

```
  A session is reaped when it is (1) `:eager` (`SessionStore.list_resumable/1`),
  (2) not currently registered anywhere (`SessionRegistry.whereis/2 == :none`), and
  (3) has a **non-terminal** persisted turn state.
```

with

```
  A session is reaped when (1) its turn is in flight (`SessionStore.list_resumable/1`
  lists the sessions whose last turn-state save was `:eager` and unfinished), (2) it is
  not registered anywhere (`SessionRegistry.whereis/2 == :none`), and (3) its persisted
  turn state is still **non-terminal** (this guards against an index member a crash left
  behind). A deleted session (`Turn.Session.delete/1`) is never listed.
```

In the `:store` option's `doc:` replace `"\`list_resumable/1\` names the \`:eager\` sessions."` with
`"\`list_resumable/1\` names the sessions with an eager turn in flight."`.

- [ ] **Step 4: Run; expect pass**

```bash
mix format
mix test test/agents/turn/session_delete_test.exs test/agents/turn/session_test.exs test/agents/turn/resume_reaper_test.exs
```

Expected: ` 0 failures` (scratch: 9/9 in `session_delete_test.exs`, 3 consecutive runs; 11/11 with
A6's two tests, preflight on the stacked tree: `54 tests, 0 failures` for the three files).

- [ ] **Step 5: Gate**

```bash
mix format
mix precommit 2>&1 | tee /tmp/w6-6.3e-precommit.log   # expect " 0 failures", exit 0
mix docs --warnings-as-errors
mix test.redis 2>&1 | tee /tmp/w6-6.3e-redis.log
MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tee /tmp/w6-6.3e-pg.log
mix test --only distributed --include postgres 2>&1 | tee /tmp/w6-6.3e-dist.log
```

- [ ] **Step 6: Guide and MIGRATING**

`docs/guides/distributed_sessions.md`: insert before `## Cluster formation (libcluster, optional)`:

```markdown
## Deleting a session

`Turn.Session.delete(session)` stops the session's live server through its supervisor (a turn in
flight is not resumed; a `run/2` waiting on it exits), then calls the store's
`delete_session/2`: the turn state, the config template, the in-flight index membership and the
history go. On Postgres and Mnesia a fork shares its parent's history up to the fork point, so
the entries a fork still reaches stay; deleting the fork later removes them. `delete/1` is
idempotent. It does not stop new turns: stop routing to a session before deleting it, or a
`run/2` (or `ResumeReaper`, for an eager session in flight) may start it again. A custom
`:supervisor_mod` must export `stop_server/2`.
```

`MIGRATING-2.0.md`, append under `## New, non-breaking`:

```markdown
- `Turn.Session.delete/1` stops a session's live server and deletes it from the store
  (`SessionStore.delete_session/2`). `Turn.Supervisor.stop_server/2` and
  `Turn.Supervisor.Horde.stop_server/2` stop one server without a restart; a custom
  `:supervisor_mod` needs `stop_server/2` only for `delete/1`. A store that refuses the
  delete, or whose call exits, is `{:error, %TurnError{type: :persist_failed}}` (an exit as
  `reason: {:store_exit, tag}`); a store that raises raises.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn/session.ex
git add lib/normandy/agents/turn/supervisor.ex
git add lib/normandy/agents/turn/supervisor/horde.ex
git add lib/normandy/agents/turn/resume_reaper.ex
git add lib/normandy/turn_error.ex
git add test/agents/turn/session_delete_test.exs
git add docs/guides/distributed_sessions.md
git add MIGRATING-2.0.md
git commit -m "feat(turn): Turn.Session.delete/1 stops and deletes a session"
```

---

---

### Task 6.3f: Redis registry — handle struct, caller-side `whereis`, batched refresh, ownership fencing (PERF-6)

`SessionRegistry.Redis.whereis/2` today is a `GenServer.call` to the per-node owner, which runs a
blocking `GET` (`session_registry/redis.ex:75-76, 192-210`); the refresh walks every session with
one `EVAL` each and ignores the result (`:242-248, 286-288`). Measured on loopback: 9.5k lookups/s
through the owner against 122k/s caller-side; one refresh over 5,000 sessions held a `whereis`
for 604 ms, a pipelined `EVALSHA` refresh of the same keys takes 14 ms. Ruling R8: the handle
becomes `%SessionRegistry.Redis.Handle{owner:, conn:, namespace:}` (6.3 Q1 a), and a refresh that
finds its key held by another process stops the local one (6.3 Q2 a). The registry is released
in v1.3.0, so the handle change is a MIGRATING entry.

**Files:**
- Modify (replace whole file): `lib/normandy/behaviours/session_registry/redis.ex`
- Modify (replace whole file): `lib/normandy/behaviours/session_registry/redis/via.ex`
- Modify: `lib/normandy/cluster.ex` (`redis_child_specs/1` through `redis_reaper_specs/4`; new `redis_handles/1`)
- Modify: `lib/normandy/telemetry.ex` (moduledoc "## Events": new event)
- Modify: `docs/guides/distributed_sessions.md` ("### Redis combo")
- Modify: `MIGRATING-2.0.md` (`## 40.`)
- Modify: `test/support/cluster_case.ex` (`start_redis_unlinked/1`, `spawn_redis_registered_on_peer/3`, `do_spawn_redis_registered/2`)
- Create: `test/behaviours/session_registry/redis_refresh_test.exs`
- Test (modify): `test/behaviours/session_registry/redis_backend_error_test.exs`, `redis_untrusted_value_test.exs`, `redis_distributed_test.exs`, `test/cluster_test.exs`, `test/options/store_options_test.exs`

Unchanged and still passing as they are (the struct flows through `new/0`): `redis_test.exs`
(contract), `redis_via_test.exs`, `test/agents/turn/redis_combo_distributed_test.exs`.

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `Normandy.Components.ContentBlock.Describe.type_of/1` and `reason_tag/1`, `Normandy.Test.TelemetryCapture.attach/2`, `Normandy.Test.Eventually`.
- Produces: `%Normandy.Behaviours.SessionRegistry.Redis.Handle{owner: atom(), conn: GenServer.server(), namespace: String.t()}` (header); `SessionRegistry.Redis.handle/1`, `fetch_handle/1`; `new/1 :: Handle.t()`; via term `{handle, session_id}`; `whereis/2` errors `{:error, :noproc}` (connection not running) and `{:error, {:exit, tag}}` (it died mid-call) besides Redix's own `{:error, %Redix.ConnectionError{}}`; event `[:normandy, :session_registry, :ownership_lost]` (header); exit reason `{:shutdown, :registration_lost}` (header); `Normandy.Cluster.redis_handles/1`.

- [ ] **Step 1: Write the failing tests**

Create `test/behaviours/session_registry/redis_refresh_test.exs`. The refresh is triggered by
sending `:refresh`; `:sys.get_state/1` returns only after the owner handled it, so no sleep:

```elixir
defmodule Normandy.Behaviours.SessionRegistry.RedisRefreshTest do
  @moduledoc """
  PERF-6: `whereis/2` runs in the caller, the TTL refresh is one pipelined `EVALSHA`
  per chunk, and a registration found taken by another process is fenced: the local
  process stops with `{:shutdown, :registration_lost}` and
  `[:normandy, :session_registry, :ownership_lost]` is emitted. The refresh is
  triggered by sending `:refresh`; `:sys.get_state/1` waits for it to finish.
  """
  use ExUnit.Case, async: true
  @moduletag :redis
  @moduletag :capture_log

  alias Normandy.Behaviours.SessionRegistry.Redis
  alias Normandy.Test.TelemetryCapture

  setup do
    handle = Redis.new()

    {:ok, raw} =
      Redix.start_link(Application.get_env(:normandy, :redis_url, "redis://localhost:6379"))

    {:ok, handle: handle, raw: raw}
  end

  defp key(handle, sid), do: "#{handle.namespace}:reg:{#{sid}}"

  defp sleeper do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp refresh(handle) do
    send(handle.owner, :refresh)
    :sys.get_state(handle.owner)
  end

  test "whereis does not wait on the owner", %{handle: handle} do
    pid = sleeper()
    :ok = Redis.register(handle, "s1", pid)
    :ok = :sys.suspend(handle.owner)

    assert Redis.whereis(handle, "s1") == {:ok, pid}
    assert Redis.whereis(handle, "s2") == :none

    :ok = :sys.resume(handle.owner)
  end

  test "a refresh extends the TTL of every key the owner holds", %{handle: h, raw: raw} do
    pids = for sid <- ["a", "b", "c"], into: %{}, do: {sid, sleeper()}
    for {sid, pid} <- pids, do: :ok = Redis.register(h, sid, pid)

    for sid <- ["a", "b", "c"],
        do: {:ok, 1} = Redix.command(raw, ["PEXPIRE", key(h, sid), "1000"])

    refresh(h)

    for sid <- ["a", "b", "c"] do
      {:ok, ttl} = Redix.command(raw, ["PTTL", key(h, sid)])
      assert ttl > 1_000, "#{sid}: PTTL #{ttl}"
    end
  end

  test "a refresh after the script cache was flushed reloads the script", %{
    handle: h,
    raw: raw
  } do
    :ok = Redis.register(h, "a", sleeper())
    {:ok, 1} = Redix.command(raw, ["PEXPIRE", key(h, "a"), "1000"])
    {:ok, "OK"} = Redix.command(raw, ["SCRIPT", "FLUSH"])

    refresh(h)

    {:ok, ttl} = Redix.command(raw, ["PTTL", key(h, "a")])
    assert ttl > 1_000
  end

  test "a key that lapsed is claimed again", %{handle: h, raw: raw} do
    pid = sleeper()
    :ok = Redis.register(h, "a", pid)
    {:ok, 1} = Redix.command(raw, ["DEL", key(h, "a")])

    refresh(h)

    assert Redis.whereis(h, "a") == {:ok, pid}
    assert Process.alive?(pid)
  end

  test "a key another process holds stops the local one and emits ownership_lost", %{
    handle: h,
    raw: raw
  } do
    pid = sleeper()
    other = sleeper()
    keep = sleeper()
    :ok = Redis.register(h, "taken", pid)
    :ok = Redis.register(h, "kept", keep)
    ref = Process.monitor(pid)

    tel =
      TelemetryCapture.attach([[:normandy, :session_registry, :ownership_lost]],
        registry: h.owner
      )

    {:ok, "OK"} = Redix.command(raw, ["SET", key(h, "taken"), :erlang.term_to_binary(other)])

    refresh(h)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :registration_lost}}

    assert_received {:telemetry, ^tel, %{count: 1}, %{session_id: "taken", registry: owner}}

    assert owner == h.owner
    refute_received {:telemetry, ^tel, _, %{session_id: "kept"}}
    assert Redis.whereis(h, "taken") == {:ok, other}
    assert Redis.whereis(h, "kept") == {:ok, keep}

    state = :sys.get_state(h.owner)
    refute Map.has_key?(state.sids, "taken")
    assert Map.has_key?(state.sids, "kept")
  end
end
```

Replace `test/behaviours/session_registry/redis_backend_error_test.exs` (untagged: the
connection points at port 1) with:

```elixir
defmodule Normandy.Behaviours.SessionRegistry.RedisBackendErrorTest do
  # No :redis tag: these tests need a connection that cannot reach Redis.
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionRegistry.Redis

  setup do
    # Port 1 refuses connections; without sync_connect every command fails with
    # a connection error instead of the start failing.
    conn =
      start_supervised!(
        {Redix, host: "127.0.0.1", port: 1, sync_connect: false, exit_on_disconnection: false}
      )

    name = :"redis_registry_down_#{System.unique_integer([:positive])}"
    {:ok, _} = Redis.start_link(name: name, conn: conn, namespace: "normandy-test-down")
    {:ok, handle: Redis.handle(owner: name, conn: conn, namespace: "normandy-test-down")}
  end

  test "whereis reports a connection failure as {:error, reason}, not as no session", ctx do
    assert {:error, %Redix.ConnectionError{}} = Redis.whereis(ctx.handle, "s1")
  end

  test "whereis runs in the caller: a suspended owner does not hold it", ctx do
    :ok = :sys.suspend(ctx.handle.owner)

    assert {:error, %Redix.ConnectionError{}} = Redis.whereis(ctx.handle, "s1")

    :ok = :sys.resume(ctx.handle.owner)
  end

  test "whereis on a stopped connection is {:error, _}, not an exit", ctx do
    :ok = stop_supervised(Redix)

    assert {:error, {:exit, :redix_exited_during_call}} = Redis.whereis(ctx.handle, "s1")

    named = %{ctx.handle | conn: :normandy_no_such_redix}
    assert {:error, :noproc} = Redis.whereis(named, "s1")
  end

  test "a 1.x handle (the owner's name) raises, naming the handle struct", ctx do
    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionRegistry.Redis.whereis/2: expected a " <>
                   "%Normandy.Behaviours.SessionRegistry.Redis.Handle{} (build it with " <>
                   "Normandy.Behaviours.SessionRegistry.Redis.handle/1), got: " <>
                   inspect(ctx.handle.owner),
                 fn -> Redis.whereis(ctx.handle.owner, "s1") end
  end
end
```

In `test/behaviours/session_registry/redis_untrusted_value_test.exs`, the owner is now
`ctx.owner.owner` (the setup's `Redis.new/1` returns the handle):

```elixir
# before
    assert Process.alive?(Process.whereis(ctx.owner))
# after
    assert Process.alive?(Process.whereis(ctx.owner.owner))
```

In `test/behaviours/session_registry/redis_distributed_test.exs` (tagged `:distributed`), use
handles. In both tests, replace

```elixir
    {:ok, _} = Reg.start_link(name: :reg_a, url: url, namespace: ns)
    {:ok, _} = ClusterCase.start_redis_on_peer(peer_node, name: :reg_b, url: url, namespace: ns)
```

with

```elixir
    {:ok, _} = Reg.start_link(name: :reg_a, url: url, namespace: ns)
    reg_a = Reg.fetch_handle(:reg_a)

    {:ok, reg_b} =
      ClusterCase.start_redis_on_peer(peer_node, name: :reg_b, url: url, namespace: ns)
```

and then: `ClusterCase.spawn_redis_registered_on_peer(peer_node, :reg_b, "s1")` →
`ClusterCase.spawn_redis_registered_on_peer(peer_node, reg_b, "s1")`;
`Reg.whereis(:reg_a, "s1")` → `Reg.whereis(reg_a, "s1")`;
`Reg.register(:reg_a, "race", local_pid)` → `Reg.register(reg_a, "race", local_pid)`;
`:rpc.call(peer_node, Reg, :register, [:reg_b, "race", peer_pid])` →
`:rpc.call(peer_node, Reg, :register, [reg_b, "race", peer_pid])`.
Check: `grep -c ":reg_a\|:reg_b" test/behaviours/session_registry/redis_distributed_test.exs`
→ `6` (two `Reg.start_link(name: :reg_a, ...)`, two `Reg.fetch_handle(:reg_a)`, two
`start_redis_on_peer(peer_node, name: :reg_b, ...)`).

In `test/support/cluster_case.ex`, the peer helpers return and take the handle:

```elixir
  @doc """
  Start a `Normandy.Behaviours.SessionRegistry.Redis` owner on a remote peer node
  without letting the erpc transport worker link to it (same unlinking pattern as
  `start_horde_on_peer/2`). Returns `{:ok, handle}`.
  """
  def start_redis_on_peer(node, opts) do
    :rpc.call(node, __MODULE__, :start_redis_unlinked, [opts])
  end

  @doc false
  def start_redis_unlinked(opts) do
    {:ok, pid} = Redis.start_link(opts)
    Process.unlink(pid)
    {:ok, Redis.fetch_handle(Keyword.fetch!(opts, :name))}
  end

  @doc """
  Spawn a long-lived process on `node` that registers itself in the Redis registry
  `handle` under `session_id` and then sleeps. Returns the remote pid.

  Mirrors `do_spawn_registered/2` but for the Redis backend.
  """
  def spawn_redis_registered_on_peer(node, handle, session_id) do
    :rpc.call(node, __MODULE__, :do_spawn_redis_registered, [handle, session_id])
  end

  @doc false
  def do_spawn_redis_registered(handle, session_id) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Redis.register(handle, session_id, self())
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    receive do
      :registered -> pid
    after
      5000 ->
        raise "do_spawn_redis_registered: timeout waiting for registration on #{inspect(handle.owner)}"
    end
  end
```

In `test/cluster_test.exs`, add the aliases after `alias Normandy.Agents.Turn.ResumeReaper`:

```elixir
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Redis, as: RedisReg
  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore
```

and append, before the module's final `end`:

```elixir
  describe "the Redis combo" do
    @combo [
      redix: [name: :combo_redix, host: "localhost"],
      namespace: "combo",
      registry: :combo_reg,
      supervisor: :combo_sup,
      template_provider: {Catalog, :c}
    ]

    test "redis_handles/1 returns the registry's handle struct and the store's handle" do
      assert Normandy.Cluster.redis_handles(@combo) == %{
               registry:
                 {RedisReg,
                  %RedisReg.Handle{owner: :combo_reg, conn: :combo_redix, namespace: "combo"}},
               store: {RedisStore, {:combo_redix, "combo"}}
             }
    end

    test "the reaper gets the handles redis_handles/1 returns" do
      [reaper] =
        @combo
        |> Normandy.Cluster.redis_child_specs()
        |> Enum.filter(&(spec_id(&1) == {ResumeReaper, :combo_reg}))

      {ResumeReaper, :start_link, [opts]} = reaper.start
      handles = Normandy.Cluster.redis_handles(@combo)
      assert opts[:registry] == handles.registry
      assert opts[:store] == handles.store
    end
  end
```

In `test/options/store_options_test.exs`, add to `@cases` after the
`{:ttl, {RedisReg, :start_link, [[ttl: 1]]}},` line:

```elixir
    {:ownr, {RedisReg, :handle, [[ownr: :x]]}},
```

and after `{:namespce, {Cluster, :redis_child_specs, [[namespce: "n"]]}},`:

```elixir
    {:namespce, {Cluster, :redis_handles, [[namespce: "n"]]}},
```

and append, before the module's final `end`:

```elixir
  test "Cluster.redis_handles/1 names a :redix list without :name" do
    error =
      assert_raise ArgumentError, fn ->
        Cluster.redis_handles(redix: [host: "h"], namespace: "n", registry: :r, supervisor: :s)
      end

    assert error.message ==
             "Normandy.Cluster.redis_handles/1: :redix must include :name, the Redix " <>
               "connection's registered name"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test --include redis test/behaviours/session_registry/ test/cluster_test.exs test/options/store_options_test.exs`
Expected: FAIL. `test/cluster_test.exs` does not compile (`Normandy.Behaviours.SessionRegistry.Redis.Handle.__struct__/1
is undefined, cannot expand struct`), which aborts the whole run. Without that file
(`mix test --include redis test/behaviours/session_registry/ test/options/store_options_test.exs`;
preflight stacked on 6.3e: `63 tests, 14 failures (2 excluded)`): `Redis.handle/1`,
`Redis.fetch_handle/1` and `Cluster.redis_handles/1` are undefined (`UndefinedFunctionError`); in
`redis_refresh_test.exs` `Redis.new/0` still returns the owner's name, so `handle.owner` fails
(`function :redis_registry_N.owner/0 is undefined`); `redis_untrusted_value_test.exs` fails the
same way.

- [ ] **Step 3: Replace the registry**

Replace `lib/normandy/behaviours/session_registry/redis.ex` with:

```elixir
# Compiled only when Redix is available (an `optional` dep).
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionRegistry.Redis do
    @moduledoc """
    Distributed `SessionRegistry` using Redis as the shared `session_id → pid` name
    table, with cross-node routing over **Erlang distribution** (Redis replaces Horde's
    CRDT, not distribution). A per-node owner GenServer monitors locally registered pids
    (clearing the key on `:DOWN`) and refreshes key TTLs so a crashed node's keys lapse on
    their own.

    The handle is a `Normandy.Behaviours.SessionRegistry.Redis.Handle`,
    `%Handle{owner:, conn:, namespace:}`: the owner's
    registered name, the Redix connection and the key namespace. `new/1` returns one;
    build one with `handle/1` from the values given to `start_link/1`, or with
    `fetch_handle/1` for an owner that opened its own connection from `:url`.
    `whereis/2` runs in the caller, on the handle's connection: a lookup never waits on
    the owner. `register/3` and `unregister/2` go through the owner, which monitors the
    pids.

    Registration is atomic via `SET … NX` (no read-modify-write), so a concurrent start
    cluster-wide yields one winner; the losers route to it. Use as a `:via` registry
    through `child_name/2` (the via term is `{handle, session_id}`) to get atomic,
    supervisor-driven starts (closes the start race), exactly like the Horde impl.

    ## Refresh and lost ownership

    Every `ttl_ms / 2` the owner extends the TTL of each key it holds, in pipelines of
    1,000 `EVALSHA` calls. A key that lapsed (a late refresh, an eviction) is
    claimed again with `SET … NX`. A key another node now holds means two servers for
    one session: the owner stops its local process with exit reason
    `{:shutdown, :registration_lost}`, logs a warning and emits
    `[:normandy, :session_registry, :ownership_lost]`. A `Turn.Server` stopped this way
    is not restarted (`restart: :transient`); its session goes on where the key points.
    """
    @behaviour Normandy.Behaviours.SessionRegistry
    use GenServer

    alias Normandy.Components.ContentBlock.Describe
    alias Normandy.Options

    require Logger

    @default_ttl_ms 60_000
    @refresh_chunk 1_000

    defmodule Handle do
      @moduledoc """
      A `SessionRegistry.Redis` handle: the owner's registered name, the Redix connection
      the caller looks keys up on, and the key namespace. Build it with
      `Normandy.Behaviours.SessionRegistry.Redis.handle/1`.
      """
      @enforce_keys [:owner, :conn, :namespace]
      defstruct [:owner, :conn, :namespace]

      @type t :: %__MODULE__{owner: atom(), conn: GenServer.server(), namespace: String.t()}
    end

    @new_opts_schema NimbleOptions.new!(
                       name: [type: :atom, doc: "The owner's name (default: a unique one)."],
                       url: [
                         type: :string,
                         type_doc: "`t:String.t/0`",
                         doc: "The Redis URL (default: `config :normandy, :redis_url`)."
                       ],
                       namespace: [
                         type: :string,
                         doc: "The key namespace (default: a unique one)."
                       ]
                     )

    @handle_opts_schema NimbleOptions.new!(
                          owner: [
                            type: :atom,
                            required: true,
                            doc: "The owner's registered name (`start_link/1`'s `:name`)."
                          ],
                          conn: [
                            type: {:custom, __MODULE__, :conn, []},
                            type_doc: "`t:GenServer.server/0`",
                            required: true,
                            doc: "The Redix connection the owner uses (pid or name)."
                          ],
                          namespace: [
                            type: :string,
                            required: true,
                            doc: "The key namespace (`start_link/1`'s `:namespace`)."
                          ]
                        )

    @start_link_opts_schema NimbleOptions.new!(
                              name: [
                                type: :atom,
                                required: true,
                                doc: "The owner's registered name (the handle's `:owner`)."
                              ],
                              conn: [
                                type: {:custom, __MODULE__, :conn, []},
                                type_doc: "`t:GenServer.server/0`",
                                doc: "A started Redix connection (pid or name)."
                              ],
                              url: [
                                type: :string,
                                type_doc: "`t:String.t/0`",
                                doc: "A Redis URL to connect to when `:conn` is not given."
                              ],
                              namespace: [
                                type: :string,
                                required: true,
                                doc: "The key namespace."
                              ],
                              ttl_ms: [
                                type: :pos_integer,
                                default: @default_ttl_ms,
                                doc:
                                  "Registration TTL in ms, refreshed every `ttl_ms / 2`; a dead " <>
                                    "node's keys lapse after it."
                              ]
                            )

    # Compare-and-delete: remove the key only if it still holds OUR value, so a
    # node never evicts a key another node re-claimed after a TTL lapse.
    @del_if_owner ~S{if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end}

    @pexpire_if_owner ~S{if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("PEXPIRE", KEYS[1], ARGV[2]) else return 0 end}

    @del_if_owner_sha :crypto.hash(:sha, @del_if_owner) |> Base.encode16(case: :lower)
    @pexpire_if_owner_sha :crypto.hash(:sha, @pexpire_if_owner) |> Base.encode16(case: :lower)

    # --- behaviour API (handle = %Handle{}) ---

    # In the caller, on the handle's connection: no owner hop, so a lookup never queues
    # behind a registration or a refresh. A stale value is deleted here too
    # (compare-and-delete, so a key another node re-claimed survives).
    @impl Normandy.Behaviours.SessionRegistry
    def whereis(%Handle{conn: conn, namespace: ns}, session_id) do
      key = reg_key(ns, session_id)

      case redis(conn, &Redix.command(&1, ["GET", key])) do
        {:ok, nil} ->
          :none

        {:ok, blob} when is_binary(blob) ->
          case decode_pid(blob) do
            {:ok, pid} -> {:ok, pid}
            :stale -> stale(conn, key, blob)
          end

        # An outage is not "no session": that would start a duplicate server.
        {:error, reason} ->
          {:error, reason}
      end
    end

    def whereis(other, _session_id), do: raise(ArgumentError, not_a_handle(:whereis, 2, other))

    @impl Normandy.Behaviours.SessionRegistry
    def register(%Handle{owner: owner}, session_id, pid),
      do: GenServer.call(owner, {:register, session_id, pid})

    def register(other, _session_id, _pid),
      do: raise(ArgumentError, not_a_handle(:register, 3, other))

    @impl Normandy.Behaviours.SessionRegistry
    def unregister(%Handle{owner: owner}, session_id),
      do: GenServer.call(owner, {:unregister, session_id})

    def unregister(other, _session_id),
      do: raise(ArgumentError, not_a_handle(:unregister, 2, other))

    @impl Normandy.Behaviours.SessionRegistry
    def child_name(%Handle{} = handle, session_id),
      do: {:via, Normandy.Behaviours.SessionRegistry.Redis.Via, {handle, session_id}}

    def child_name(other, _session_id),
      do: raise(ArgumentError, not_a_handle(:child_name, 2, other))

    # A 1.x handle was the owner's name: say what replaced it.
    defp not_a_handle(fun, arity, other) do
      "#{inspect(__MODULE__)}.#{fun}/#{arity}: expected a " <>
        "%#{inspect(Handle)}{} (build it with #{inspect(__MODULE__)}.handle/1), got: " <>
        Describe.type_of(other)
    end

    # --- lifecycle ---

    @doc """
    Test/default handle: starts an owner GenServer with its own Redix connection and
    returns its handle.

    ## Options

    #{Options.docs(@new_opts_schema)}
    """
    @spec new(keyword()) :: Handle.t()
    def new(opts \\ []) do
      opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

      name =
        Keyword.get_lazy(opts, :name, fn ->
          :"redis_registry_#{System.unique_integer([:positive])}"
        end)

      url =
        Keyword.get(
          opts,
          :url,
          Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
        )

      ns = Keyword.get(opts, :namespace, "normandy_reg_#{UUID.uuid4()}")
      {:ok, _pid} = start_link(name: name, url: url, namespace: ns)
      fetch_handle(name)
    end

    @doc """
    Builds the handle of an owner started with `start_link/1`'s `:name`, `:conn` and
    `:namespace`. Starts and calls nothing.

    ## Options

    #{Options.docs(@handle_opts_schema)}
    """
    @spec handle(keyword()) :: Handle.t()
    def handle(opts) do
      opts = Options.validate!(opts, @handle_opts_schema, {__MODULE__, :handle, 1})

      %Handle{
        owner: Keyword.fetch!(opts, :owner),
        conn: Keyword.fetch!(opts, :conn),
        namespace: Keyword.fetch!(opts, :namespace)
      }
    end

    @doc """
    The handle of a running owner, asked of it once: for an owner started with `:url`,
    whose connection only the owner knows. Keep the result; a lookup with it never calls
    the owner.
    """
    @spec fetch_handle(atom()) :: Handle.t()
    def fetch_handle(owner) when is_atom(owner), do: GenServer.call(owner, :handle)

    @doc """
    Starts the per-node owner GenServer. Build the handle with `handle/1` from the same
    `:name`, `:conn` and `:namespace`, or with `fetch_handle/1` when the owner connects
    from `:url`.

    ## Options

    #{Options.docs(@start_link_opts_schema)}
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

      unless Keyword.has_key?(opts, :conn) or Keyword.has_key?(opts, :url) do
        raise ArgumentError,
              "Normandy.Behaviours.SessionRegistry.Redis.start_link/1: requires :conn (a Redix " <>
                "connection) or :url"
      end

      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @doc false
    # A NimbleOptions custom type: a pid or a registered name, never nil (a nil :conn
    # would pass the :conn-or-:url check and then fail in init/1).
    @spec conn(term()) :: {:ok, GenServer.server()} | {:error, String.t()}
    def conn(conn) when is_pid(conn), do: {:ok, conn}
    def conn(conn) when is_atom(conn) and conn != nil, do: {:ok, conn}
    def conn({:global, _name} = conn), do: {:ok, conn}
    def conn({:via, mod, _name} = conn) when is_atom(mod), do: {:ok, conn}
    def conn({name, node} = conn) when is_atom(name) and is_atom(node), do: {:ok, conn}

    def conn(other),
      do:
        {:error,
         "expected a Redix connection (a pid or a registered name), got: " <>
           Describe.type_of(other)}

    @impl GenServer
    def init(opts) do
      conn =
        case Keyword.get(opts, :conn) do
          nil ->
            {:ok, c} = Redix.start_link(Keyword.fetch!(opts, :url))
            c

          supplied ->
            supplied
        end

      ttl = Keyword.fetch!(opts, :ttl_ms)
      {:ok, _ref} = :timer.send_interval(div(ttl, 2), :refresh)

      {:ok,
       %{
         name: Keyword.fetch!(opts, :name),
         conn: conn,
         ns: Keyword.fetch!(opts, :namespace),
         ttl: ttl,
         mons: %{},
         sids: %{}
       }}
    end

    @impl GenServer
    def handle_call({:register, sid, pid}, _from, s) do
      cmd = ["SET", reg_key(s.ns, sid), :erlang.term_to_binary(pid), "NX", "PX", to_string(s.ttl)]

      case redis(s.conn, &Redix.command(&1, cmd)) do
        {:ok, "OK"} ->
          s = drop_existing(s, sid)
          ref = Process.monitor(pid)

          {:reply, :ok,
           %{s | mons: Map.put(s.mons, ref, sid), sids: Map.put(s.sids, sid, {pid, ref})}}

        {:ok, nil} ->
          {:reply, {:error, :taken}, s}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    end

    def handle_call(:handle, _from, s),
      do: {:reply, %Handle{owner: s.name, conn: s.conn, namespace: s.ns}, s}

    def handle_call({:unregister, sid}, _from, s) do
      s =
        case Map.pop(s.sids, sid) do
          {{pid, ref}, sids} ->
            Process.demonitor(ref, [:flush])
            _ = del_if_owner(s.conn, reg_key(s.ns, sid), :erlang.term_to_binary(pid))
            %{s | sids: sids, mons: Map.delete(s.mons, ref)}

          {nil, _} ->
            s
        end

      {:reply, :ok, s}
    end

    @impl GenServer
    def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
      s =
        case Map.pop(s.mons, ref) do
          {nil, _} ->
            s

          {sid, mons} ->
            _ = del_if_owner(s.conn, reg_key(s.ns, sid), :erlang.term_to_binary(pid))
            %{s | mons: mons, sids: Map.delete(s.sids, sid)}
        end

      {:noreply, s}
    end

    def handle_info(:refresh, s) do
      s = s.sids |> Enum.chunk_every(@refresh_chunk) |> Enum.reduce(s, &refresh_chunk/2)
      {:noreply, s}
    end

    def handle_info(_msg, s), do: {:noreply, s}

    # A pid is routable iff it lives on this node (and is alive) or on a connected node.
    # A pid on a node no longer in the cluster is treated as dead → triggers rehydrate.
    # The keyspace is shared, so another client may have written the value.
    # `[:safe]` creates no atoms; it refuses a pid only when its node atom is
    # unknown here, and such a node is not connected, so the pid is not live
    # anyway (see alive?/1). A value that is not a pid is no session either.
    defp decode_pid(blob) do
      case :erlang.binary_to_term(blob, [:safe]) do
        pid when is_pid(pid) -> if alive?(pid), do: {:ok, pid}, else: :stale
        _other -> :stale
      end
    rescue
      ArgumentError -> :stale
    end

    defp stale(conn, key, blob) do
      _ = del_if_owner(conn, key, blob)
      :none
    end

    defp alive?(pid) do
      cond do
        node(pid) == node() -> Process.alive?(pid)
        node(pid) in Node.list() -> true
        true -> false
      end
    end

    defp reg_key(ns, sid), do: "#{ns}:reg:{#{sid}}"

    defp del_if_owner(conn, key, value) do
      redis(conn, fn c ->
        case Redix.command(c, ["EVALSHA", @del_if_owner_sha, "1", key, value]) do
          {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
            Redix.command(c, ["EVAL", @del_if_owner, "1", key, value])

          other ->
            other
        end
      end)
    end

    # One pipeline of compare-and-PEXPIRE per chunk. 1: still ours, TTL extended.
    # 0: the key lapsed or another node holds it (reclaim/4 tells which).
    defp refresh_chunk(chunk, s) do
      case pexpire_chunk(s, chunk) do
        {:ok, results} ->
          chunk
          |> Enum.zip(results)
          |> Enum.reduce(s, fn {{sid, {pid, ref}}, result}, s ->
            refreshed(s, sid, pid, ref, result)
          end)

        {:error, reason} ->
          Logger.warning(
            "SessionRegistry.Redis #{inspect(s.name)} could not refresh " <>
              "#{length(chunk)} registrations (#{Describe.reason_tag(reason)}); " <>
              "retrying at the next refresh"
          )

          s
      end
    end

    defp pexpire_chunk(s, chunk) do
      cmds =
        Enum.map(chunk, fn {sid, {pid, _ref}} ->
          ["EVALSHA", @pexpire_if_owner_sha, "1", reg_key(s.ns, sid)] ++
            [:erlang.term_to_binary(pid), Integer.to_string(s.ttl)]
        end)

      redis(s.conn, &pexpire_pipeline(&1, cmds))
    end

    defp pexpire_pipeline(conn, cmds) do
      with {:ok, results} <- Redix.pipeline(conn, cmds) do
        if Enum.any?(results, &noscript?/1),
          do: reload_and_retry(conn, cmds),
          else: {:ok, results}
      end
    end

    # A restarted or flushed server forgot the script: load it, send the chunk again
    # (PEXPIRE is idempotent).
    defp reload_and_retry(conn, cmds) do
      with {:ok, _sha} <- Redix.command(conn, ["SCRIPT", "LOAD", @pexpire_if_owner]),
           do: Redix.pipeline(conn, cmds)
    end

    defp noscript?(%Redix.Error{message: "NOSCRIPT" <> _}), do: true
    defp noscript?(_result), do: false

    defp refreshed(s, _sid, _pid, _ref, 1), do: s
    defp refreshed(s, sid, pid, ref, 0), do: reclaim(s, sid, pid, ref)

    defp refreshed(s, sid, _pid, _ref, %Redix.Error{} = error) do
      Logger.warning(
        "SessionRegistry.Redis #{inspect(s.name)} could not refresh session " <>
          "#{inspect(sid)} (#{Describe.reason_tag(error)}); retrying at the next refresh"
      )

      s
    end

    # The key is not ours any more. If it lapsed, SET NX takes it back. If another node
    # holds it, two processes claim one session: stop ours.
    defp reclaim(s, sid, pid, ref) do
      cmd = ["SET", reg_key(s.ns, sid), :erlang.term_to_binary(pid), "NX", "PX"]

      case redis(s.conn, &Redix.command(&1, cmd ++ [Integer.to_string(s.ttl)])) do
        {:ok, "OK"} ->
          s

        {:ok, nil} ->
          fence(s, sid, pid, ref)

        {:error, reason} ->
          Logger.warning(
            "SessionRegistry.Redis #{inspect(s.name)} could not re-claim session " <>
              "#{inspect(sid)} (#{Describe.reason_tag(reason)}); retrying at the next refresh"
          )

          s
      end
    end

    defp fence(s, sid, pid, ref) do
      Process.demonitor(ref, [:flush])

      Logger.warning(
        "SessionRegistry.Redis #{inspect(s.name)}: session #{inspect(sid)} is registered " <>
          "by another process; stopping the local one"
      )

      :telemetry.execute(
        [:normandy, :session_registry, :ownership_lost],
        %{count: 1},
        %{session_id: sid, registry: s.name}
      )

      Process.exit(pid, {:shutdown, :registration_lost})
      %{s | mons: Map.delete(s.mons, ref), sids: Map.delete(s.sids, sid)}
    end

    # A Redix call that cannot exit or raise: a connection that is not running is
    # {:error, :noproc}, one that dies mid-call {:error, {:exit, tag}}.
    defp redis(conn, fun) do
      case GenServer.whereis(conn) do
        nil -> {:error, :noproc}
        server -> fun.(server)
      end
    catch
      :exit, reason -> {:error, {:exit, exit_tag(reason)}}
    end

    defp exit_tag(reason) when is_atom(reason), do: reason

    defp exit_tag(reason)
         when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
         do: elem(reason, 0)

    defp exit_tag(_reason), do: :unknown

    defp drop_existing(s, sid) do
      case Map.pop(s.sids, sid) do
        {{_pid, ref}, sids} ->
          Process.demonitor(ref, [:flush])
          %{s | sids: sids, mons: Map.delete(s.mons, ref)}

        {nil, _} ->
          s
      end
    end
  end
end
```

Notes for the implementer: `whereis/2` resolves the connection with `GenServer.whereis/1` first
because `Redix.Connection.pipeline/4` calls `Process.monitor(GenServer.whereis(conn))`, which
raises `ArgumentError` for an unregistered name; passing it the resolved pid turns a dead
connection into an exit, which `redis/2` catches. `Process.exit(pid, {:shutdown,
:registration_lost})` ends a `Turn.Server` without a callback (it does not trap exits,
`server.ex` "terminate/3" comment) and `Turn.Supervisor` children are `restart: :transient`, so
it is not restarted.

- [ ] **Step 4: Replace the `:via` module**

Replace `lib/normandy/behaviours/session_registry/redis/via.ex` with (the raise messages name
the session and the owner, and the reason by tag, not the handle's connection or the reason's
terms):

```elixir
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionRegistry.Redis.Via do
    @moduledoc """
    `:via` callbacks for `SessionRegistry.Redis`. The name is
    `{%SessionRegistry.Redis.Handle{}, session_id}`; registration goes through the local
    owner GenServer, lookups run in the caller. A `Turn.Server` started under
    `{:via, __MODULE__, {handle, session_id}}`
    registers atomically at process start (`SET … NX`); a losing concurrent start gets
    `{:error, {:already_started, pid}}` and the router routes to the winner.
    """
    alias Normandy.Behaviours.SessionRegistry.Redis, as: Reg
    alias Normandy.Components.ContentBlock.Describe

    def register_name({handle, sid}, pid) do
      case Reg.register(handle, sid, pid) do
        :ok ->
          :yes

        {:error, :taken} ->
          :no

        {:error, reason} ->
          # A transport/Redis failure is not contention. Returning :no would
          # masquerade an outage as a lost race and route to a nonexistent
          # winner — crash loud and diagnosable instead of a silent fallback.
          raise "SessionRegistry.Redis.Via: register failed for session " <>
                  "#{inspect(sid)} in #{inspect(handle.owner)}: #{Describe.reason_tag(reason)}"
      end
    end

    def whereis_name({handle, sid}) do
      case Reg.whereis(handle, sid) do
        {:ok, pid} ->
          pid

        :none ->
          :undefined

        # As in register_name/2: an outage is not "no process"; crash loud.
        {:error, reason} ->
          raise "SessionRegistry.Redis.Via: whereis failed for session " <>
                  "#{inspect(sid)} in #{inspect(handle.owner)}: #{Describe.reason_tag(reason)}"
      end
    end

    def unregister_name({handle, sid}) do
      :ok = Reg.unregister(handle, sid)
      :ok
    end

    def send(name, msg) do
      case whereis_name(name) do
        :undefined -> :erlang.error(:badarg, [name, msg])
        pid -> Kernel.send(pid, msg)
      end
    end
  end
end
```

- [ ] **Step 5: `Normandy.Cluster`: the combo's handles**

In `lib/normandy/cluster.ex`, replace everything from the `@doc """` line that starts
`Child specs for the **Redis combo**` up to (not including) `defp libcluster_specs(opts, reg) do`
with:

```elixir
  @doc """
  Child specs for the **Redis combo** (Redis registry + Redis store + local supervisor +
  reaper) — Redis as the single distributed dependency. `:template_provider` enables the
  `ResumeReaper` for eager handoff. Cross-node routing still uses Erlang distribution.

  ## Options

  #{Options.docs(@redis_child_specs_opts_schema)}
  """
  @spec redis_child_specs(keyword()) :: [Supervisor.child_spec() | map()]
  def redis_child_specs(opts) do
    opts =
      Options.validate!(opts, @redis_child_specs_opts_schema, {__MODULE__, :redis_child_specs, 1})

    redix = Keyword.fetch!(opts, :redix)
    conn_name = conn_name!(redix, :redis_child_specs)
    ns = Keyword.fetch!(opts, :namespace)
    registry = Keyword.fetch!(opts, :registry)
    supervisor = Keyword.fetch!(opts, :supervisor)
    handles = build_redis_handles(opts, :redis_child_specs)

    [
      {Redix, redix},
      %{
        id: registry,
        start: {RedisReg, :start_link, [[name: registry, conn: conn_name, namespace: ns]]}
      },
      %{id: supervisor, start: {LocalSup, :start_link, [[name: supervisor]]}}
    ] ++ redis_reaper_specs(opts, handles, registry, supervisor)
  end

  @doc """
  The `{module, handle}` pairs of the registry and store that `redis_child_specs/1` starts
  for the same options: pass them to `Normandy.Agents.Turn.Session.new/1` as `:registry`
  and `:store`. Starts and calls nothing.

  ## Options

  The options of `redis_child_specs/1`.
  """
  @spec redis_handles(keyword()) :: %{registry: {module(), term()}, store: {module(), term()}}
  def redis_handles(opts) do
    opts
    |> Options.validate!(@redis_child_specs_opts_schema, {__MODULE__, :redis_handles, 1})
    |> build_redis_handles(:redis_handles)
  end

  defp build_redis_handles(opts, fun) do
    conn_name = conn_name!(Keyword.fetch!(opts, :redix), fun)
    ns = Keyword.fetch!(opts, :namespace)

    %{
      registry:
        {RedisReg,
         RedisReg.handle(owner: Keyword.fetch!(opts, :registry), conn: conn_name, namespace: ns)},
      store: {RedisStore, {conn_name, ns}}
    }
  end

  defp conn_name!(redix, fun) do
    case Keyword.fetch(redix, :name) do
      {:ok, name} ->
        name

      :error ->
        raise ArgumentError,
              "Normandy.Cluster.#{fun}/1: :redix must include :name, the Redix " <>
                "connection's registered name"
    end
  end

  defp redis_reaper_specs(opts, handles, registry, supervisor) do
    case Keyword.get(opts, :template_provider) do
      nil ->
        []

      template_provider ->
        [
          %{
            id: {ResumeReaper, registry},
            start:
              {ResumeReaper, :start_link,
               [
                 [
                   store: handles.store,
                   registry: handles.registry,
                   supervisor: supervisor,
                   supervisor_mod: LocalSup,
                   template_provider: template_provider
                 ]
               ]}
          }
        ]
    end
  end
```

`grep -n "RedisReg, registry" lib/normandy/cluster.ex` then returns nothing (the reaper used to
get the owner's name as the handle).

- [ ] **Step 6: Telemetry catalogue**

In `lib/normandy/telemetry.ex`, in the moduledoc's `## Events`, after the
`### \`[:normandy, :retry, :attempt]\`` paragraph (it ends "LLM calls also emit one
`[:normandy, :llm, :request]` span per attempt.") and before `## Turn.Server`, add:

```markdown
  ### `[:normandy, :session_registry, :ownership_lost]`

  A `SessionRegistry.Redis` refresh found a session key it held now holding another
  process, so two processes claimed one session; the owner stopped its local one with
  exit reason `{:shutdown, :registration_lost}`. Measurement `count: 1`. Metadata:
  `session_id`, `registry` (the owner's registered name). Emitted in the owner's process,
  outside any caller's trace context. A key that merely lapsed is claimed again and
  emits nothing.
```

(Task 6.4e later adds its events in the same section; keep this one after `retry`.)

- [ ] **Step 7: Guide**

In `docs/guides/distributed_sessions.md`, "### Redis combo", replace

```markdown
The store and registry are chosen here, in the child specs; `Normandy.Behaviours.Config` has
no session slots (the two 1.x slots were never read and are gone in 2.0).

> Note: `redis_child_specs/1` shares a single Redix connection across the store, registry, and reaper. Under high throughput, give the registry its own connection (pass a separate `:conn`) to avoid a single-mailbox bottleneck.
```

with

````markdown
The store and registry are chosen here, in the child specs; `Normandy.Behaviours.Config` has
no session slots (the two 1.x slots were never read and are gone in 2.0).
`Normandy.Cluster.redis_handles/1`, given the same options, returns the registry and store
to pass to `Turn.Session.new/1`:

```elixir
%{registry: registry, store: store} = Normandy.Cluster.redis_handles(same_opts)
Normandy.Agents.Turn.Session.new(session_id: id, registry: registry, store: store, ...)
```

The registry's handle is a `%Normandy.Behaviours.SessionRegistry.Redis.Handle{}` (not the
owner's name). Lookups (`whereis`) run in the caller on the Redix connection, so they never
queue behind the registry owner; registrations go through the owner.
````

(The old note's "pass a separate `:conn`" was never possible through `redis_child_specs/1`;
Task 6.3g adds the paragraph on connections.)

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix format && mix test --include redis test/behaviours/session_registry/ test/agents/turn/redis_combo_distributed_test.exs test/cluster_test.exs test/options/store_options_test.exs test/telemetry/catalogue_test.exs`
Expected: PASS (65 tests in the scratch run plus the catalogue's 3; stacked on 6.3a–e:
`73 tests, 0 failures (2 excluded)`; `redis_refresh_test.exs` 5 tests,
`redis_backend_error_test.exs` 4).

- [ ] **Step 9: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.3f.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.3f.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.
Tagged suites (Redis up: `docker ps` shows `normandy-test-redis`):
`mix test.redis 2>&1 | tail -3` → ` 0 failures`;
`docker start normandy-test-pg`, then
`MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tail -3`
→ ` 0 failures` (includes `redis_distributed_test.exs`, which needs Redis). The distributed run
needs Postgres although nothing here touches a Postgres backend:
`test/agents/turn/eager_handoff_distributed_test.exs` is tagged only `:distributed` and its setup
raises `Normandy.TestRepo not started` without it (a bare `mix test --only distributed` gives
`9 tests, 1 failure`). No `mix test.postgres` run.

- [ ] **Step 10: MIGRATING-2.0.md**

Append to `## 40. Session stores, registry and memory stores` (created by Task 6.3d; if it is
missing, create it after `## 39.` and before `## New, non-breaking`):

```markdown
- `SessionRegistry.Redis`'s handle is `%Normandy.Behaviours.SessionRegistry.Redis.Handle{owner:,
  conn:, namespace:}`, not the owner's registered name. `new/1` returns one. For an owner you
  start yourself, build it with `SessionRegistry.Redis.handle(owner: MyApp.SessionRegistry,
  conn: MyApp.SessionRedix, namespace: "normandy")` (the `:name`, `:conn` and `:namespace` you
  gave `start_link/1`), or call `SessionRegistry.Redis.fetch_handle(MyApp.SessionRegistry)` once
  for an owner started with `:url`. Pass `{SessionRegistry.Redis, handle}` where you passed
  `{SessionRegistry.Redis, MyApp.SessionRegistry}`; the old form raises `ArgumentError` naming
  the struct. The `:via` name is `{handle, session_id}`. With the Redis combo,
  `Normandy.Cluster.redis_handles/1` (the options of `redis_child_specs/1`) returns the
  registry and the store to give `Turn.Session.new/1`.
- `SessionRegistry.Redis.whereis/2` runs in the caller on the handle's Redix connection
  instead of calling the owner, so a lookup no longer queues behind registrations and the TTL
  refresh. A connection that is not running returns `{:error, :noproc}`, one that dies during
  the call `{:error, {:exit, tag}}`; 1.x exited the caller when the owner was down.
- The registry's TTL refresh sends one pipeline of `EVALSHA` per 1,000 sessions instead of one
  `EVAL` per session. A key that lapsed is claimed again. A key another process now holds (two
  servers for one session, after a partition or a Redis failover) stops the local process with
  exit reason `{:shutdown, :registration_lost}`, logs a warning and emits
  `[:normandy, :session_registry, :ownership_lost]`. A `Turn.Server` stopped this way is not
  restarted, and a caller waiting in its `run/2` exits with that reason, as for any server
  that stops mid-turn (`Turn.Session.run/2` routes a turn again only after
  `{:shutdown, :passivated}` or `:noproc`, see `## 39.`); the session goes on where the key
  points.
```

- [ ] **Step 11: Commit**

```bash
git add lib/normandy/behaviours/session_registry/redis.ex
git add lib/normandy/behaviours/session_registry/redis/via.ex
git add lib/normandy/cluster.ex
git add lib/normandy/telemetry.ex
git add docs/guides/distributed_sessions.md
git add MIGRATING-2.0.md
git add test/support/cluster_case.ex
git add test/behaviours/session_registry/redis_refresh_test.exs
git add test/behaviours/session_registry/redis_backend_error_test.exs
git add test/behaviours/session_registry/redis_untrusted_value_test.exs
git add test/behaviours/session_registry/redis_distributed_test.exs
git add test/cluster_test.exs
git add test/options/store_options_test.exs
git commit -m "perf(session_registry): look up Redis registrations in the caller and fence lost ones"
```

---

### Task 6.3g: Redis store — waited writes on their own connections (PERF-12)

Every waited write runs `WAIT` on the connection that did the write (`session_store/redis.ex`
`wait/2`); when that connection is shared (the combo shares one Redix connection between store,
registry and reaper, `cluster.ex:180-196`), every later command queues behind the `WAIT`: a
registry `whereis` waited 622 ms behind five appends with `wait: {1, 100}`. `WAIT` waits for the
replication of the writes of the connection it runs on (Redis docs; inventory Surprise 1), so the
fix is not "WAIT on another connection" but "the write and its WAIT together on a connection used
for nothing else". Ruling R8 / 6.3 Q6 (a): the store owns a pool of `k` connections
(`:wait_connections`, default 4), a session's waited writes use connection
`:erlang.phash2(session_id, k)`, `Cluster.redis_child_specs/1` starts the pool when
`config :normandy, :redis_wait` asks for replicas, and `:store_redix` overrides.

This task runs after 6.3a–e. In `session_store/redis.ex` it anchors on function names: the
waited write functions are found with a grep (Step 3c), whatever 6.3a/6.3d made their bodies.

**Files:**
- Modify: `lib/normandy/behaviours/session_store/redis.ex` (moduledoc; `@new_opts_schema`; `new/1`; new `check_wait_connections!/1`, `app_env_wait!/0`, `write_target!/2`; `conn_ns/1`; every waited write function; `wait_setting!/1` removed)
- Modify: `lib/normandy/cluster.ex` (`@redis_child_specs_opts_schema`; the region from `redis_child_specs/1` to `redis_reaper_specs/4`; alias `Describe`)
- Modify: `lib/normandy/options.ex` (`@sensitive_keys` gains `:store_redix`)
- Modify: `docs/guides/distributed_sessions.md` ("### Redis combo")
- Modify: `MIGRATING-2.0.md` (`## 40.`)
- Create: `test/behaviours/session_store/redis_wait_pool_test.exs` (`:redis`)
- Create: `test/cluster_redis_wait_test.exs` (untagged, `async: false`)
- Test (modify): `test/behaviours/session_store/redis_wait_test.exs`, `test/behaviours/session_store/redis_backend_error_test.exs` (module `RedisWaitConfigTest`), `test/options/store_options_test.exs`

**Interfaces:**
- Consumes: 6.3f's `Cluster.redis_handles/1`, `build_redis_handles/2`, `conn_name!/2`; 6.3c's `save_turn_state/4`; 6.3a's `pipeline_ok/1` (unchanged here: it keeps running on whatever `conn` the function binds).
- Produces: `SessionStore.Redis.new/1` option `:wait_connections` (header); handle `{conn, ns, wait, wait_conns}`; `SessionStore.Redis.app_env_wait!/0` (`@doc false`); `Cluster.redis_child_specs/1` options `:store_redix` (header) and `:wait_connections`; pool connection names `:"<redix name>.wait.<i>"`.

- [ ] **Step 1: Write the failing tests**

Create `test/behaviours/session_store/redis_wait_pool_test.exs`. The test Redis has no
replica, so `WAIT 1 60000` blocks until `CLIENT UNBLOCK`; `CLIENT LIST ID` shows the client
blocked (flag `b`) in `wait` (verified on the local Redis 7.4.11; `CLIENT LIST ID` needs Redis
≥ 6.2). A test that fails before the unblock leaves a client blocked for up to 60 s; it is a
scratch namespace and nothing else waits on it. `save_turn_state/4` is 6.3c's arity:

```elixir
defmodule Normandy.Behaviours.SessionStore.RedisWaitPoolTest do
  @moduledoc """
  PERF-12: a waited write and its `WAIT` run on one of the handle's wait connections,
  chosen by session id, so a `WAIT` blocks neither the store's main connection nor the
  other wait connections. The test Redis has no replica, so `WAIT 1 60000` blocks until
  `CLIENT UNBLOCK` releases it; `CLIENT LIST ID` shows when it is blocked. No sleeps.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Test.Eventually

  setup do
    {:ok, raw} =
      Redix.start_link(Application.get_env(:normandy, :redis_url, "redis://localhost:6379"))

    {:ok, raw: raw}
  end

  defp client_id(conn) do
    {:ok, id} = Redix.command(conn, ["CLIENT", "ID"])
    Integer.to_string(id)
  end

  # Blocked now (flag b) in a WAIT (cmd is the client's last command, so it alone stays
  # "wait" after the client is released).
  defp blocked_in_wait?(raw, id) do
    {:ok, line} = Redix.command(raw, ["CLIENT", "LIST", "ID", id])
    line =~ ~r/ flags=[A-Za-z]*b/ and line =~ " cmd=wait "
  end

  # The session ids that land on wait connection 0 and on wait connection 1 of 2.
  defp sessions_on_each_conn do
    ids = Enum.map(1..50, &"s#{&1}")
    {Enum.find(ids, &(:erlang.phash2(&1, 2) == 0)), Enum.find(ids, &(:erlang.phash2(&1, 2) == 1))}
  end

  test "a blocked WAIT holds neither reads nor another session's wait connection", %{raw: raw} do
    {conn, _ns, {1, 60_000}, {wait0, wait1}} =
      store = Redis.new(wait: {1, 60_000}, wait_connections: 2)

    {blocked_sid, other_sid} = sessions_on_each_conn()
    id0 = client_id(wait0)
    id1 = client_id(wait1)

    task =
      Task.async(fn ->
        Redis.append_entry(store, blocked_sid, %Entry{role: "user", content: "a"})
      end)

    assert Eventually.wait_until(fn -> blocked_in_wait?(raw, id0) end)

    # The main connection answers while the WAIT holds wait connection 0.
    assert {:ok, [%Entry{content: "a"}]} = Redis.history(store, blocked_sid)
    assert {:ok, "PONG"} = Redix.command(conn, ["PING"])
    # So does wait connection 1: another session's write is not queued behind it.
    assert {:ok, "PONG"} = Redix.command(wait1, ["PING"])
    refute blocked_in_wait?(raw, id1)
    assert Task.yield(task, 0) == nil

    assert {:ok, 1} = Redix.command(raw, ["CLIENT", "UNBLOCK", id0])
    assert Task.await(task) == {:error, {:wait_unmet, 0, 1}}

    other =
      Task.async(fn -> Redis.save_turn_state(store, other_sid, :ts, false) end)

    assert Eventually.wait_until(fn -> blocked_in_wait?(raw, id1) end)
    refute blocked_in_wait?(raw, id0)
    assert {:ok, 1} = Redix.command(raw, ["CLIENT", "UNBLOCK", id1])
    assert Task.await(other) == {:error, {:wait_unmet, 0, 1}}
  end

  test "one session's waited writes always use the same wait connection", %{raw: raw} do
    {_conn, _ns, {1, 60_000}, wait_conns} =
      store = Redis.new(wait: {1, 60_000}, wait_connections: 3)

    expected = elem(wait_conns, :erlang.phash2("s-same", 3))
    id = client_id(expected)

    for write <- [
          fn -> Redis.append_entry(store, "s-same", %Entry{role: "user", content: "a"}) end,
          fn -> Redis.save_turn_state(store, "s-same", :ts, false) end,
          fn -> Redis.save_config_template(store, "s-same", %{}) end
        ] do
      task = Task.async(write)
      assert Eventually.wait_until(fn -> blocked_in_wait?(raw, id) end)
      assert {:ok, 1} = Redix.command(raw, ["CLIENT", "UNBLOCK", id])
      assert Task.await(task) == {:error, {:wait_unmet, 0, 1}}
    end
  end
end
```

Create `test/cluster_redis_wait_test.exs`:

```elixir
defmodule Normandy.ClusterRedisWaitTest do
  @moduledoc """
  PERF-12: when `config :normandy, :redis_wait` asks for replicas, the Redis combo starts
  a pool of Redix connections for the store's waited writes and builds the store handle
  on it; `:store_redix` gives the store its own connection instead. Pure: the specs and
  handles are built, nothing is started.
  """
  # async: false — sets the :redis_wait app env.
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore
  alias Normandy.Cluster

  @combo [
    redix: [name: :combo_redix, host: "localhost", port: 6379],
    namespace: "combo",
    registry: :combo_reg,
    supervisor: :combo_sup
  ]

  setup do
    previous = Application.fetch_env(:normandy, :redis_wait)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:normandy, :redis_wait, value)
        :error -> Application.delete_env(:normandy, :redis_wait)
      end
    end)
  end

  defp redix_specs(specs) do
    for %{id: id, start: {Redix, :start_link, [opts]}} <-
          Enum.map(specs, &Supervisor.child_spec(&1, [])),
        do: {id, opts}
  end

  test "without replicas: one connection, shared, and a {conn, namespace} store" do
    Application.put_env(:normandy, :redis_wait, {0, 0})

    assert [{Redix, [name: :combo_redix, host: "localhost", port: 6379]}] =
             redix_specs(Cluster.redis_child_specs(@combo))

    assert Cluster.redis_handles(@combo).store == {RedisStore, {:combo_redix, "combo"}}
  end

  test "with replicas: a pool of :wait_connections named after :redix, in the store handle" do
    Application.put_env(:normandy, :redis_wait, {1, 100})
    pool = [:"combo_redix.wait.0", :"combo_redix.wait.1"]
    opts = Keyword.put(@combo, :wait_connections, 2)

    assert [{Redix, _} | waits] = redix_specs(Cluster.redis_child_specs(opts))

    assert waits == Enum.map(pool, &{&1, [name: &1, host: "localhost", port: 6379]})

    assert Cluster.redis_handles(opts).store ==
             {RedisStore, {:combo_redix, "combo", {1, 100}, List.to_tuple(pool)}}

    assert {RedisStore, {_conn, _ns, {1, 100}, default_pool}} =
             Cluster.redis_handles(@combo).store

    assert tuple_size(default_pool) == 4
  end

  test ":store_redix gives the store its own connection and starts no pool" do
    Application.put_env(:normandy, :redis_wait, {1, 100})
    opts = Keyword.put(@combo, :store_redix, name: :combo_store_redix, host: "h2")

    assert [
             {Redix, [name: :combo_redix, host: "localhost", port: 6379]},
             {:store_redix, [name: :combo_store_redix, host: "h2"]}
           ] =
             redix_specs(Cluster.redis_child_specs(opts))

    assert Cluster.redis_handles(opts).store ==
             {RedisStore, {:combo_store_redix, "combo", {1, 100}}}

    Application.put_env(:normandy, :redis_wait, {0, 0})
    assert Cluster.redis_handles(opts).store == {RedisStore, {:combo_store_redix, "combo"}}
  end

  test ":store_redix and :wait_connections together raise" do
    opts = @combo ++ [store_redix: [name: :s], wait_connections: 2]

    assert_raise ArgumentError,
                 "Normandy.Cluster.redis_child_specs/1: :wait_connections and :store_redix " <>
                   "exclude each other (with :store_redix, waited writes run on that connection)",
                 fn -> Cluster.redis_child_specs(opts) end
  end

  test "a pool needs an atom :redix name" do
    Application.put_env(:normandy, :redis_wait, {1, 100})
    opts = Keyword.put(@combo, :redix, name: {:global, :combo}, host: "h")

    assert_raise ArgumentError,
                 "Normandy.Cluster.redis_handles/1: with config :normandy, :redis_wait, the " <>
                   ":redix :name must be an atom (the WAIT pool is named after it), got: a tuple",
                 fn -> Cluster.redis_handles(opts) end
  end
end
```

In `test/behaviours/session_store/redis_wait_test.exs`, replace the first test:

```elixir
  test "new/1 keeps the wait setting and its wait connections in the handle", %{store: store} do
    assert {conn, _ns, {1, 50}, wait_conns} = store
    assert tuple_size(wait_conns) == 4
    refute conn in Tuple.to_list(wait_conns)
    assert {_conn, _ns, {1, 50}, {_one}} = Redis.new(wait: {1, 50}, wait_connections: 1)
  end

  test "a wait of 0 replicas opens no wait connections" do
    assert {_conn, _ns, {0, 0}} = Redis.new(wait: {0, 0})
  end
```

(The old test asserted `{_conn, _ns, {1, 50}} = store`.)

In `test/behaviours/session_store/redis_backend_error_test.exs`, module
`Normandy.Behaviours.SessionStore.RedisWaitConfigTest` (untagged), add before
`test "a :redis_wait app env with replicas and no timeout raises on the write"`:

```elixir
  test "new/1 refuses :wait_connections without a replica wait" do
    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionStore.Redis.new/1: :wait_connections needs a " <>
                   ":wait of one replica or more, got: no :wait",
                 fn -> Redis.new(wait_connections: 2) end

    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionStore.Redis.new/1: :wait_connections needs a " <>
                   ":wait of one replica or more, got: a :wait of 0 replicas",
                 fn -> Redis.new(wait: {0, 10}, wait_connections: 2) end
  end

  test "a handle whose wait connections are not a non-empty tuple raises on the write" do
    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionStore.Redis: the handle's wait_conns must be a " <>
                   "non-empty tuple of Redix connections, got: a list",
                 fn -> Redis.save_turn_state({:c, "ns", {1, 10}, [:c]}, "s1", :ts, false) end
  end
```

In `test/options/store_options_test.exs`: rename the sensitive-keys test and add
`:store_redix`:

```elixir
  test ":url, :redix, :store_redix and :templates are sensitive keys" do
    for key <- [:url, :redix, :store_redix, :templates],
        do: assert(key in Normandy.Options.sensitive_keys())
  end
```

and add to `@redaction_cases`, before the `{:templates, ...}` entry:

```elixir
    {:store_redix, "`t:keyword/0`",
     {Cluster, :redis_child_specs,
      [
        [
          store_redix: :"sk-secret",
          redix: [name: :r],
          namespace: "n",
          registry: :r,
          supervisor: :s
        ]
      ]}},
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test --include redis test/behaviours/session_store/redis_wait_pool_test.exs test/behaviours/session_store/redis_wait_test.exs test/behaviours/session_store/redis_backend_error_test.exs test/cluster_redis_wait_test.exs test/options/store_options_test.exs`
Expected: FAIL. `new/1` rejects `:wait_connections` ("unknown option :wait_connections"); the
combo has no `:store_redix`/`:wait_connections` options and builds `{conn, ns}`; the
`:store_redix` redaction case fails on the message (`unknown option :store_redix` instead of the
type error; nothing is echoed because the key is unknown) and the sensitive-keys test fails
(`:store_redix` not in the list). Preflight stacked on 6.3f: `52 tests, 11 failures`.

- [ ] **Step 3: The store**

All edits in `lib/normandy/behaviours/session_store/redis.ex`.

3a. Moduledoc. Replace the handle sentence

```
    The `handle` is `{conn, namespace}` or `{conn, namespace, wait}` (the host owns the
    Redix connection, Oban-style).
```

with

```
    The `handle` is `{conn, namespace}`, `{conn, namespace, wait}` or
    `{conn, namespace, wait, wait_conns}` (the host owns the Redix connections,
    Oban-style; `new/1` opens its own).
```

and replace the end of the durability paragraph,
`Redis treats 0 as wait forever, which would stall the shared connection.` followed by the
closing `"""`, with:

```
    Redis treats 0 as wait forever.

    ## Waited writes and connections

    `WAIT` blocks the connection it runs on until the replicas acknowledge that
    connection's own earlier writes, so a write and its `WAIT` must share a connection,
    and every command queued behind them on it waits too. `wait_conns` is a tuple of
    Redix connections used for nothing else: a session's waited writes and their `WAIT`
    run on `elem(wait_conns, :erlang.phash2(session_id, tuple_size(wait_conns)))`, so one
    session's writes stay in order and other sessions, reads and a registry sharing
    `conn` do not queue behind its `WAIT`. `new/1` with a replica `:wait` opens
    `:wait_connections` of them. A handle without `wait_conns` runs waited writes on
    `conn`.
    """
```

3b. Aliases and `new/1`. After `alias Normandy.Components.AgentMemory.Entry` add
`alias Normandy.Components.ContentBlock.Describe`, and after the alias block add
`@default_wait_connections 4`. In `@new_opts_schema`, after the `wait:` entry, add:

```elixir
                       wait_connections: [
                         type: :pos_integer,
                         doc:
                           "How many connections waited writes run on (default `4`); only " <>
                             "with a `:wait` of one replica or more."
                       ],
```

Replace `new/1`'s `@spec` and body (from `@spec new(keyword())` to the function's `end`) with:

```elixir
    @spec new(keyword()) ::
            {pid(), binary()}
            | {pid(), binary(), {non_neg_integer(), non_neg_integer()}}
            | {pid(), binary(), {pos_integer(), pos_integer()}, tuple()}
    def new(opts \\ []) do
      opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
      check_wait_connections!(opts)

      url =
        Keyword.get(
          opts,
          :url,
          Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
        )

      # Checked before connecting, so a bad setting starts nothing.
      _ =
        with {:ok, wait} <- Keyword.fetch(opts, :wait),
             do: check_wait!(wait, "SessionStore.Redis.new/1: :wait")

      {:ok, conn} = Redix.start_link(url)
      ns = Keyword.get(opts, :namespace, "normandy_test_#{UUID.uuid4()}")

      case Keyword.fetch(opts, :wait) do
        {:ok, {0, _timeout} = wait} ->
          {conn, ns, wait}

        {:ok, wait} ->
          k = Keyword.get(opts, :wait_connections, @default_wait_connections)

          wait_conns =
            for _ <- 1..k do
              {:ok, wait_conn} = Redix.start_link(url)
              wait_conn
            end

          {conn, ns, wait, List.to_tuple(wait_conns)}

        :error ->
          {conn, ns}
      end
    end

    defp check_wait_connections!(opts) do
      case {Keyword.fetch(opts, :wait_connections), Keyword.get(opts, :wait, {0, 0})} do
        {{:ok, _k}, {0, _timeout}} ->
          raise ArgumentError,
                "Normandy.Behaviours.SessionStore.Redis.new/1: :wait_connections needs a " <>
                  ":wait of one replica or more, got: " <>
                  if(Keyword.has_key?(opts, :wait), do: "a :wait of 0 replicas", else: "no :wait")

        _ ->
          :ok
      end
    end

    @doc false
    # The `config :normandy, :redis_wait` setting, checked: `Normandy.Cluster` reads it
    # once when it builds the Redis combo's specs and handles.
    @spec app_env_wait!() :: {non_neg_integer(), non_neg_integer()}
    def app_env_wait!,
      do:
        check_wait!(
          Application.get_env(:normandy, :redis_wait, {0, 0}),
          "SessionStore.Redis: the :redis_wait app env"
        )
```

(`:wait_connections` has no NimbleOptions default so that giving it without a replica wait can
be refused; the default lives in `@default_wait_connections`.)

3c. The waited writes. Find them:
`grep -n "wait_setting!(handle)" lib/normandy/behaviours/session_store/redis.ex`.
At `d624fbf` that is 3 lines (`append_entry/3`, `save_turn_state/3`, `save_config_template/3`);
after 6.3c/6.3d expect `append_entry/3`, `save_turn_state/4`, `save_config_template/3`, plus
`delete_session/2` only if 6.3d made it wait (it does: preflight N = 4). Call that count N. Rewrite rule, in each of those
N functions: delete the line `wait = wait_setting!(handle)` and replace the same function's
`{conn, ns} = conn_ns(handle)` with `{conn, ns, wait} = write_target!(handle, session_id)`.
Nothing else in the body changes: its commands and its `wait(conn, wait)` already use `conn`,
which is now the session's wait connection when the handle has one. Example (`append_entry/3`):

```elixir
# before
    def append_entry(handle, session_id, %Entry{} = entry) do
      {conn, ns} = conn_ns(handle)
      wait = wait_setting!(handle)
      fields = encode_entry_fields(entry)
# after
    def append_entry(handle, session_id, %Entry{} = entry) do
      {conn, ns, wait} = write_target!(handle, session_id)
      fields = encode_entry_fields(entry)
```

3d. `conn_ns/1` and the wait helpers. Add a clause after `defp conn_ns({conn, ns, _wait}), do: {conn, ns}`:

```elixir
    defp conn_ns({conn, ns, _wait, _wait_conns}), do: {conn, ns}
```

and replace the whole `wait_setting!/1` (its comment, `defp wait_setting!({_conn, _ns, wait})`
and `defp wait_setting!({_conn, _ns})`) with:

```elixir
    # The connection a session's write and its WAIT run on, the namespace and the wait.
    # WAIT waits for the earlier writes of its own connection, so both share one; with
    # wait_conns a session always gets the same one, so its writes stay in order. A
    # handle with no wait of its own reads the :redis_wait app env before the write, so
    # a bad setting fails the write instead of following it.
    defp write_target!({conn, ns}, _session_id), do: {conn, ns, app_env_wait!()}
    defp write_target!({conn, ns, wait}, _session_id), do: {conn, ns, wait}

    defp write_target!({_conn, ns, wait, wait_conns}, session_id)
         when is_tuple(wait_conns) and tuple_size(wait_conns) > 0,
         do: {elem(wait_conns, :erlang.phash2(session_id, tuple_size(wait_conns))), ns, wait}

    defp write_target!({_conn, _ns, _wait, wait_conns}, _session_id) do
      raise ArgumentError,
            "Normandy.Behaviours.SessionStore.Redis: the handle's wait_conns must be a " <>
              "non-empty tuple of Redix connections, got: " <> Describe.type_of(wait_conns)
    end
```

Checks: `grep -c "wait_setting!" lib/normandy/behaviours/session_store/redis.ex` → `0`;
`grep -c "write_target!(handle, session_id)" lib/normandy/behaviours/session_store/redis.ex` → N.
Reads (`history`, `load_*`, `list_resumable`) and `fork` keep `conn_ns/1`, so they stay on `conn`.

- [ ] **Step 4: The combo**

In `lib/normandy/options.ex`, `@sensitive_keys`, add `:store_redix,` after `:secret,` (it holds
Redix options, so possibly a password).

In `lib/normandy/cluster.ex`, add `alias Normandy.Components.ContentBlock.Describe` after
`alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore`, and replace
`@redis_child_specs_opts_schema` (the whole `NimbleOptions.new!(...)` assignment) with the block
below, which adds `:store_redix`, `:wait_connections` and `@default_wait_connections`:

```elixir
  @redis_child_specs_opts_schema NimbleOptions.new!(
                                   redix: [
                                     type: :keyword_list,
                                     type_doc: "`t:keyword/0`",
                                     required: true,
                                     doc:
                                       "Options for the Redix connection; must include `:name`."
                                   ],
                                   namespace: [
                                     type: :string,
                                     required: true,
                                     doc: "The key namespace for the registry and the store."
                                   ],
                                   registry: [
                                     type: :atom,
                                     required: true,
                                     doc: "The Redis registry owner's name."
                                   ],
                                   supervisor: [
                                     type: :atom,
                                     required: true,
                                     doc: "The local `Turn.Supervisor`'s name."
                                   ],
                                   template_provider: [
                                     type: @session_types.template_provider,
                                     type_doc: "`{module, handle}`",
                                     doc: "The `AgentTemplate`; starts the reaper."
                                   ],
                                   store_redix: [
                                     type: :keyword_list,
                                     type_doc: "`t:keyword/0`",
                                     doc:
                                       "Options (with `:name`) for a Redix connection the " <>
                                         "store uses alone, for every command and every " <>
                                         "`WAIT`, instead of `:redix`'s and a `WAIT` pool. " <>
                                         "Share it with nothing: a `WAIT` stalls it."
                                   ],
                                   wait_connections: [
                                     type: :pos_integer,
                                     doc:
                                       "How many connections the store's `WAIT` pool opens " <>
                                         "(default `4`); only when `config :normandy, " <>
                                         ":redis_wait` asks for replicas and without " <>
                                         "`:store_redix`."
                                   ]
                                 )

  @default_wait_connections 4
```

Then replace the region 6.3f wrote (from the `@doc """` of `redis_child_specs/1` up to, not
including, `defp libcluster_specs(opts, reg) do`) with:

```elixir
  @doc """
  Child specs for the **Redis combo** (Redis registry + Redis store + local supervisor +
  reaper) — Redis as the single distributed dependency. `:template_provider` enables the
  `ResumeReaper` for eager handoff. Cross-node routing still uses Erlang distribution.
  `redis_handles/1` returns the registry and store to give `Turn.Session.new/1`.

  The registry and the store share the `:redix` connection, except for the store's waited
  writes. When `config :normandy, :redis_wait` asks for replicas (read here, once), the
  specs also start `:wait_connections` Redix connections, named `:"<redix name>.wait.<i>"`,
  and the store runs each waited write and its `WAIT` on one of them (see
  `Normandy.Behaviours.SessionStore.Redis`). With `:store_redix`, the store uses that
  connection for everything and no pool starts.

  ## Options

  #{Options.docs(@redis_child_specs_opts_schema)}
  """
  @spec redis_child_specs(keyword()) :: [Supervisor.child_spec() | map()]
  def redis_child_specs(opts) do
    opts =
      Options.validate!(opts, @redis_child_specs_opts_schema, {__MODULE__, :redis_child_specs, 1})

    redix = Keyword.fetch!(opts, :redix)
    conn_name = conn_name!(redix, :redis_child_specs)
    ns = Keyword.fetch!(opts, :namespace)
    registry = Keyword.fetch!(opts, :registry)
    supervisor = Keyword.fetch!(opts, :supervisor)
    handles = build_redis_handles(opts, :redis_child_specs)

    [{Redix, redix}] ++
      store_conn_specs(opts, :redis_child_specs) ++
      [
        %{
          id: registry,
          start: {RedisReg, :start_link, [[name: registry, conn: conn_name, namespace: ns]]}
        },
        %{id: supervisor, start: {LocalSup, :start_link, [[name: supervisor]]}}
      ] ++ redis_reaper_specs(opts, handles, registry, supervisor)
  end

  @doc """
  The `{module, handle}` pairs of the registry and store that `redis_child_specs/1` starts
  for the same options: pass them to `Normandy.Agents.Turn.Session.new/1` as `:registry`
  and `:store`. Starts and calls nothing.

  ## Options

  The options of `redis_child_specs/1`.
  """
  @spec redis_handles(keyword()) :: %{registry: {module(), term()}, store: {module(), term()}}
  def redis_handles(opts) do
    opts
    |> Options.validate!(@redis_child_specs_opts_schema, {__MODULE__, :redis_handles, 1})
    |> build_redis_handles(:redis_handles)
  end

  defp build_redis_handles(opts, fun) do
    conn_name = conn_name!(Keyword.fetch!(opts, :redix), fun)
    ns = Keyword.fetch!(opts, :namespace)

    %{
      registry:
        {RedisReg,
         RedisReg.handle(owner: Keyword.fetch!(opts, :registry), conn: conn_name, namespace: ns)},
      store: {RedisStore, store_handle(opts, fun)}
    }
  end

  # The store's handle: on :store_redix's connection, or on :redix's with a WAIT pool
  # when the app env asks for replicas. {conn, ns} otherwise, which reads the app env
  # on every write, as any such handle does.
  defp store_handle(opts, fun) do
    ns = Keyword.fetch!(opts, :namespace)

    case {store_plan(opts, fun), RedisStore.app_env_wait!()} do
      {{:own, conn}, {0, _timeout}} -> {conn, ns}
      {{:own, conn}, wait} -> {conn, ns, wait}
      {{:shared, conn}, {0, _timeout}} -> {conn, ns}
      {{:shared, conn}, wait} -> {conn, ns, wait, List.to_tuple(wait_conn_names(opts, fun))}
    end
  end

  defp store_conn_specs(opts, fun) do
    case {store_plan(opts, fun), RedisStore.app_env_wait!()} do
      {{:own, _conn}, _wait} ->
        [Supervisor.child_spec({Redix, Keyword.fetch!(opts, :store_redix)}, id: :store_redix)]

      {{:shared, _conn}, {0, _timeout}} ->
        []

      {{:shared, _conn}, _wait} ->
        redix = Keyword.fetch!(opts, :redix)

        for name <- wait_conn_names(opts, fun),
            do: Supervisor.child_spec({Redix, Keyword.put(redix, :name, name)}, id: name)
    end
  end

  defp store_plan(opts, fun) do
    case {Keyword.fetch(opts, :store_redix), Keyword.has_key?(opts, :wait_connections)} do
      {{:ok, _store_redix}, true} ->
        raise ArgumentError,
              "Normandy.Cluster.#{fun}/1: :wait_connections and :store_redix exclude each " <>
                "other (with :store_redix, waited writes run on that connection)"

      {{:ok, store_redix}, false} ->
        {:own, conn_name!(store_redix, fun, :store_redix)}

      {:error, _} ->
        {:shared, conn_name!(Keyword.fetch!(opts, :redix), fun)}
    end
  end

  defp wait_conn_names(opts, fun) do
    conn_name = conn_name!(Keyword.fetch!(opts, :redix), fun)

    unless is_atom(conn_name) do
      raise ArgumentError,
            "Normandy.Cluster.#{fun}/1: with config :normandy, :redis_wait, the :redix " <>
              ":name must be an atom (the WAIT pool is named after it), got: " <>
              Describe.type_of(conn_name)
    end

    k = Keyword.get(opts, :wait_connections, @default_wait_connections)
    for i <- 0..(k - 1), do: :"#{conn_name}.wait.#{i}"
  end

  defp conn_name!(redix, fun, key \\ :redix) do
    case Keyword.fetch(redix, :name) do
      {:ok, name} ->
        name

      :error ->
        raise ArgumentError,
              "Normandy.Cluster.#{fun}/1: #{inspect(key)} must include :name, the Redix " <>
                "connection's registered name"
    end
  end

  defp redis_reaper_specs(opts, handles, registry, supervisor) do
    case Keyword.get(opts, :template_provider) do
      nil ->
        []

      template_provider ->
        [
          %{
            id: {ResumeReaper, registry},
            start:
              {ResumeReaper, :start_link,
               [
                 [
                   store: handles.store,
                   registry: handles.registry,
                   supervisor: supervisor,
                   supervisor_mod: LocalSup,
                   template_provider: template_provider
                 ]
               ]}
          }
        ]
    end
  end
```

`:"#{conn_name}.wait.#{i}"` creates at most `:wait_connections` atoms once at boot, from a
name the host chose (the same pattern as `SessionRegistry.Redis.new/1`'s default owner name);
credo's `UnsafeToAtom` does not flag it (checked).

- [ ] **Step 5: Guide**

In `docs/guides/distributed_sessions.md`, after the paragraph 6.3f added that ends "registrations
go through the owner.", add:

```markdown
The registry, the reaper and the store share the `:redix` connection. A replica wait
(`config :normandy, :redis_wait`, read when the specs are built) would block that
connection on every write, so the combo then also starts a pool of `:wait_connections`
(default 4) Redix connections, and each session's waited writes and their `WAIT` run on
one of them. To give the store a connection of its own instead (for every command and
every `WAIT`), pass `store_redix: [name: MyApp.StoreRedix, ...]`; share it with nothing.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test --include redis test/behaviours/session_store/ test/app_env_config_test.exs test/cluster_redis_wait_test.exs test/cluster_test.exs test/options/store_options_test.exs`
Expected: PASS (`redis_wait_pool_test.exs` 2 tests, `cluster_redis_wait_test.exs` 5; stacked
on 6.3f: `155 tests, 0 failures (29 excluded)`). Run `redis_wait_pool_test.exs` three times: it
passed 3/3 in the scratch run and 3/3 stacked.

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.3g.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.3g.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.
Tagged: `mix test.redis 2>&1 | tail -3` → ` 0 failures`. No Postgres or distributed run: nothing
here touches them (the distributed Redis registry test does not build a store).

- [ ] **Step 8: MIGRATING-2.0.md**

Append to `## 40.`:

```markdown
- `SessionStore.Redis.new/1` with a `:wait` of one replica or more opens `:wait_connections`
  (default 4) more Redix connections and returns the four-element handle
  `{conn, namespace, wait, wait_conns}`. Each session's waited writes and their `WAIT` run on
  one of them (`:erlang.phash2(session_id, k)`), so a `WAIT` no longer stalls reads, other
  sessions or a registry sharing `conn`. Handles you build as `{conn, namespace}` or
  `{conn, namespace, wait}` still work and still wait on `conn`. `:wait_connections` without
  such a `:wait` raises `ArgumentError`.
- `Normandy.Cluster.redis_child_specs/1`: when `config :normandy, :redis_wait` asks for
  replicas (read when the specs are built), it also starts `:wait_connections` (new option,
  default 4) Redix connections named `:"<redix name>.wait.<i>"` (the `:redix` `:name` must then
  be an atom) and gives the store that pool. The new option `:store_redix` (Redix options with
  `:name`) gives the store a connection of its own for every command and every `WAIT` instead;
  it cannot be combined with `:wait_connections`. Build the handles for `Turn.Session.new/1`
  with `Cluster.redis_handles/1`, not by hand: the store's handle depends on these options and
  the app env. The guide's old advice to "pass a separate `:conn`" was not possible and is
  gone.
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/behaviours/session_store/redis.ex
git add lib/normandy/cluster.ex
git add lib/normandy/options.ex
git add docs/guides/distributed_sessions.md
git add MIGRATING-2.0.md
git add test/behaviours/session_store/redis_wait_pool_test.exs
git add test/cluster_redis_wait_test.exs
git add test/behaviours/session_store/redis_wait_test.exs
git add test/behaviours/session_store/redis_backend_error_test.exs
git add test/options/store_options_test.exs
git commit -m "perf(session_store): run Redis waited writes and their WAIT on a connection pool"
```

---

### Task 6.3h: ETS memory store — one row per document on `MemoryStore.Rows` (PERF-10)

`MemoryStore.ETS` keeps one row per namespace, `{namespace, docs}` (`memory_store/ets.ex:3-5`):
every `get` copies the whole namespace map into the caller, and every write copies it out of the
table, runs `Docs`, and writes it back (`:64-68`). Measured: `get` 141 µs and `put` 270 µs median
at 1,000 documents (the default `max_namespace_documents`), against 0 µs / 5 µs at one. Wave
5.4b's limits make it worse: `Docs.put/5` sums the whole namespace before each write
(`docs.ex:27-34, 86-88`). The new layout keeps one row per document and a per-namespace totals row,
so the limit check reads one row. The rules move to `Normandy.Behaviours.MemoryStore.Rows`
(header), whose second implementation is Mnesia (Task 6.3i). MemoryStore is new in 2.0 (not in
v1.3.0), so no data migration.

Row layout, in an `:ordered_set`:
- `{{namespace, path}, %{content, version, updated_at}}` per document;
- `{{namespace, 0}, {bytes, documents}}` per non-empty namespace. The integer `0` sorts before
  every binary path (number < bitstring in term order), so a namespace's rows are contiguous and
  a walk from `{ns, prefix}` never meets the totals row.

`get/3` stays a direct read in the caller (one `:ets.lookup`; `test/tools/memory_test.exs:704-730`
pins that a dead owner's read raises `ArgumentError`, and still passes). `list/3` moves into the
owner: a walk over several rows next to a concurrent `rename/4` could otherwise see a document
at both paths, and `rename/4` is atomic in the behaviour's contract.

**Files:**
- Create: `lib/normandy/behaviours/memory_store/rows.ex`
- Modify (replace whole file): `lib/normandy/behaviours/memory_store/ets.ex`
- Modify: `lib/normandy/behaviours/memory_store/docs.ex` (comments only)
- Modify: `docs/guides/agent-memory.md` ("## Backends", the InMemory/ETS paragraph)
- Test (modify): `test/behaviours/memory_store/ets_test.exs`

**Interfaces:**
- Consumes: `MemoryStore.check_limits/3`, `MemoryStore.validate_limits!/2`, `MemoryStore.list_limit/0`, `at_or_under?/2`, `under?/2`, `reparent/3` (all unchanged); `MemoryStore.Docs.next_version/2`.
- Produces: `Normandy.Behaviours.MemoryStore.Rows` (`@moduledoc false`; callbacks `fetch/2`, `put/3`, `delete/2`, `range/2`; functions `get/3`, `list/3`, `put/6`, `delete/4`, `delete_tree/3`, `rename/4`, `delete_namespace/2`, each taking `{access_module, arg}` first); `Normandy.Behaviours.MemoryStore.ETS.Table` (`@moduledoc false`, the ETS row access). The ETS handle stays `{pid, tid}`; the `MemoryStore` contract is unchanged.

- [ ] **Step 1: Write the failing tests**

Replace `test/behaviours/memory_store/ets_test.exs` with:

```elixir
defmodule Normandy.Behaviours.MemoryStore.ETSTest do
  use ExUnit.Case, async: true
  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.ETS

  alias Normandy.Behaviours.MemoryStore.ETS, as: EtsMem

  describe "row layout (PERF-10)" do
    test "one row per document plus one totals row per namespace" do
      {_pid, table} = store = EtsMem.new()

      for i <- 1..5, do: {:ok, 1} = EtsMem.put(store, "ns", "/memories/f#{i}", "abc", :new)
      {:ok, 1} = EtsMem.put(store, "other", "/memories/x", "z", :new)

      assert :ets.info(table, :type) == :ordered_set
      assert :ets.info(table, :size) == 5 + 1 + 1 + 1

      assert [{{"ns", "/memories/f3"}, %{content: "abc", version: 1}}] =
               :ets.lookup(table, {"ns", "/memories/f3"})

      assert :ets.lookup(table, {"ns", 0}) == [{{"ns", 0}, {15, 5}}]
      assert :ets.lookup(table, {"other", 0}) == [{{"other", 0}, {1, 1}}]
    end

    test "an overwrite rewrites its row and the totals row only" do
      {_pid, table} = store = EtsMem.new()
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/a", "12345", :new)
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/b", "1", :new)
      {:ok, 2} = EtsMem.put(store, "ns", "/memories/a", "12", 1)

      assert :ets.info(table, :size) == 3
      assert :ets.lookup(table, {"ns", 0}) == [{{"ns", 0}, {3, 2}}]
    end

    test "emptying a namespace removes its totals row" do
      {_pid, table} = store = EtsMem.new()
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/a", "x", :new)
      {:ok, 1} = EtsMem.put(store, "ns", "/memories/d/b", "y", :new)

      assert :ok = EtsMem.delete(store, "ns", "/memories/a", :any)
      assert {:ok, 1} = EtsMem.delete_tree(store, "ns", "/memories/d")
      assert :ets.info(table, :size) == 0

      {:ok, 1} = EtsMem.put(store, "ns", "/memories/a", "x", :new)
      assert :ok = EtsMem.delete_namespace(store, "ns")
      assert :ets.info(table, :size) == 0
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/behaviours/memory_store/ets_test.exs`
Expected: FAIL, two of the three "row layout (PERF-10)" tests (`36 tests, 2 failures`):
`:ets.info(table, :type)` is `:set` (first test) and the size is 1, not 3 (one row per
namespace; second test). "emptying a namespace removes its totals row" already passes: the old
store drops an emptied namespace's row, so the table size is 0 either way. The contract tests
pass.

- [ ] **Step 3: `MemoryStore.Rows`**

Create `lib/normandy/behaviours/memory_store/rows.ex`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.Rows do
  @moduledoc false
  # The MemoryStore rules over a table with one row per document and one totals row per
  # namespace:
  #
  #   * `{namespace, path}` → `%{content, version, updated_at}`
  #   * `{namespace, 0}`    → `{bytes, documents}` (absent while the namespace is empty)
  #
  # The integer 0 sorts before every binary path, so in an ordered table a namespace's
  # rows stay contiguous and its totals row comes first. ETS and Mnesia implement the
  # row access below. The caller makes each function here atomic: the ETS owner runs it
  # in its single process, Mnesia inside one transaction. Every write reads the totals
  # row first; on Mnesia that takes the namespace's write lock, so a namespace's writers
  # run one at a time, as with the old one-row-per-namespace layout.

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore.Docs

  @typedoc "A row-access module and its argument (the ETS table, or Mnesia's `{table, lock}`)."
  @type access :: {module(), term()}
  @type key :: {MemoryStore.namespace(), MemoryStore.path() | 0}

  @doc "The value under `key`, or `:error`."
  @callback fetch(arg :: term(), key()) :: {:ok, term()} | :error
  @doc "Writes `value` under `key`."
  @callback put(arg :: term(), key(), value :: term()) :: :ok
  @doc "Removes `key`; a missing key is `:ok`."
  @callback delete(arg :: term(), key()) :: :ok
  @doc "The document rows of `namespace` whose path starts with `prefix` (bytes), by path."
  @callback range(arg :: term(), {MemoryStore.namespace(), MemoryStore.path()}) ::
              [{MemoryStore.path(), map()}]

  @spec get(access(), MemoryStore.namespace(), MemoryStore.path()) ::
          {:ok, %{content: String.t(), version: pos_integer()}} | :not_found
  def get(access, ns, path) do
    case doc(access, ns, path) do
      nil -> :not_found
      d -> {:ok, %{content: d.content, version: d.version}}
    end
  end

  @spec list(access(), MemoryStore.namespace(), MemoryStore.path()) ::
          {:ok, [MemoryStore.entry()]}
  def list(access, ns, prefix) do
    entries =
      access
      |> under(ns, prefix, &MemoryStore.at_or_under?/2)
      |> Enum.take(MemoryStore.list_limit())
      |> Enum.map(fn {path, d} ->
        %{path: path, size: byte_size(d.content), updated_at: d.updated_at}
      end)

    {:ok, entries}
  end

  @spec put(
          access(),
          MemoryStore.namespace(),
          MemoryStore.path(),
          String.t(),
          pos_integer() | :new | :any,
          MemoryStore.limits()
        ) :: {:ok, pos_integer()} | {:error, :conflict | MemoryStore.namespace_full()}
  def put({mod, arg} = access, ns, path, content, expected, limits) do
    before = totals(access, ns)
    current = doc(access, ns, path)

    with {:ok, version} <- Docs.next_version(current && current.version, expected),
         totals = after_put(before, current, content),
         :ok <- MemoryStore.check_limits(limits, before, totals) do
      doc = %{content: content, version: version, updated_at: DateTime.utc_now()}
      :ok = mod.put(arg, {ns, path}, doc)
      :ok = put_totals(access, ns, totals)
      {:ok, version}
    end
  end

  @spec delete(access(), MemoryStore.namespace(), MemoryStore.path(), pos_integer() | :any) ::
          :ok | :not_found | {:error, :conflict}
  def delete(access, ns, path, expected) do
    before = totals(access, ns)

    case {doc(access, ns, path), expected} do
      {nil, _expected} ->
        :not_found

      {%{version: v} = d, expected} when expected == :any or expected == v ->
        1 = drop(access, ns, [{path, d}], before)
        :ok

      _stale ->
        {:error, :conflict}
    end
  end

  @spec delete_tree(access(), MemoryStore.namespace(), MemoryStore.path()) ::
          {:ok, non_neg_integer()}
  def delete_tree(access, ns, prefix) do
    before = totals(access, ns)
    {:ok, drop(access, ns, under(access, ns, prefix, &MemoryStore.at_or_under?/2), before)}
  end

  # A rename moves rows but keeps the namespace's totals; the totals row is still read
  # first, for its lock.
  @spec rename(access(), MemoryStore.namespace(), MemoryStore.path(), MemoryStore.path()) ::
          {:ok, pos_integer()} | :not_found | {:error, :exists}
  def rename({mod, arg} = access, ns, from, to) do
    _totals = totals(access, ns)

    moving =
      case doc(access, ns, from) do
        nil -> under(access, ns, from, &MemoryStore.under?/2)
        d -> [{from, d}]
      end

    cond do
      moving == [] ->
        :not_found

      under(access, ns, to, &MemoryStore.at_or_under?/2) != [] ->
        {:error, :exists}

      true ->
        Enum.each(moving, fn {path, _d} -> :ok = mod.delete(arg, {ns, path}) end)

        Enum.each(moving, fn {path, d} ->
          :ok = mod.put(arg, {ns, MemoryStore.reparent(path, from, to)}, d)
        end)

        {:ok, length(moving)}
    end
  end

  @spec delete_namespace(access(), MemoryStore.namespace()) :: :ok
  def delete_namespace({mod, arg} = access, ns) do
    _totals = totals(access, ns)
    Enum.each(mod.range(arg, {ns, ""}), fn {path, _d} -> :ok = mod.delete(arg, {ns, path}) end)
    mod.delete(arg, {ns, 0})
  end

  defp doc({mod, arg}, ns, path) do
    case mod.fetch(arg, {ns, path}) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp totals({mod, arg}, ns) do
    case mod.fetch(arg, {ns, 0}) do
      {:ok, {bytes, count}} -> {bytes, count}
      :error -> {0, 0}
    end
  end

  defp put_totals({mod, arg}, ns, {0, 0}), do: mod.delete(arg, {ns, 0})
  defp put_totals({mod, arg}, ns, totals), do: mod.put(arg, {ns, 0}, totals)

  defp under({mod, arg}, ns, prefix, keep?) do
    arg
    |> mod.range({ns, prefix})
    |> Enum.filter(fn {path, _d} -> keep?.(path, prefix) end)
  end

  # Removes `rows` and their bytes and count from the totals; returns how many.
  defp drop({mod, arg} = access, ns, rows, {bytes, count}) do
    Enum.each(rows, fn {path, _d} -> :ok = mod.delete(arg, {ns, path}) end)
    gone = Enum.reduce(rows, 0, fn {_path, d}, sum -> sum + byte_size(d.content) end)
    :ok = put_totals(access, ns, {bytes - gone, count - length(rows)})
    length(rows)
  end

  defp after_put({bytes, count}, nil, content), do: {bytes + byte_size(content), count + 1}

  defp after_put({bytes, count}, %{content: old}, content),
    do: {bytes - byte_size(old) + byte_size(content), count}
end
```

Every write function reads the totals row before anything else; on Mnesia (6.3i) that read
takes the namespace's write lock. `rename/4` reads it for the lock only. A version conflict is
returned before the limit check (`Docs.next_version/2` first), as the contract requires.

- [ ] **Step 4: The ETS store**

Replace `lib/normandy/behaviours/memory_store/ets.ex` with:

```elixir
defmodule Normandy.Behaviours.MemoryStore.ETS do
  @moduledoc """
  ETS-backed `MemoryStore`, in-node. One row per document, `{{namespace, path}, doc}`,
  plus one totals row per namespace, `{{namespace, 0}, {bytes, documents}}`, in an
  `:ordered_set`, so an operation costs what it touches, not the namespace's size. A
  GenServer owns the `:protected` table and runs every write and every `list/3`, so
  compare-and-set, rename and the `put/6` limits are atomic and a listing never sees half
  of a rename. `get/3` reads the table directly. The handle is `{pid, table}`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  use GenServer

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore.Rows
  alias Normandy.Options

  @no_opts_schema NimbleOptions.new!([])

  @doc """
  Starts a fresh store; returns its handle `{owner_pid, table}`.

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec new(keyword()) :: {pid(), :ets.tid()}
  def new(opts \\ []) do
    [] = Options.validate!(opts, @no_opts_schema, {__MODULE__, :new, 1})
    {:ok, pid} = GenServer.start_link(__MODULE__, [])
    {pid, GenServer.call(pid, :table)}
  end

  @impl Normandy.Behaviours.MemoryStore
  def list({pid, _table}, ns, prefix), do: GenServer.call(pid, {:rows, :list, [ns, prefix]})

  @impl Normandy.Behaviours.MemoryStore
  def get({_pid, table}, ns, path), do: Rows.get({__MODULE__.Table, table}, ns, path)

  @impl Normandy.Behaviours.MemoryStore
  def put({pid, _table}, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    GenServer.call(pid, {:rows, :put, [ns, path, content, expected, limits]})
  end

  @impl Normandy.Behaviours.MemoryStore
  def delete({pid, _table}, ns, path, expected),
    do: GenServer.call(pid, {:rows, :delete, [ns, path, expected]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_tree({pid, _table}, ns, prefix),
    do: GenServer.call(pid, {:rows, :delete_tree, [ns, prefix]})

  @impl Normandy.Behaviours.MemoryStore
  def rename({pid, _table}, ns, from, to),
    do: GenServer.call(pid, {:rows, :rename, [ns, from, to]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_namespace({pid, _table}, ns),
    do: GenServer.call(pid, {:rows, :delete_namespace, [ns]})

  @impl GenServer
  def init(_opts),
    do:
      {:ok, :ets.new(:normandy_memory_store, [:ordered_set, :protected, read_concurrency: true])}

  @impl GenServer
  def handle_call(:table, _from, table), do: {:reply, table, table}

  def handle_call({:rows, fun, args}, _from, table),
    do: {:reply, apply(Rows, fun, [{__MODULE__.Table, table} | args]), table}

  defmodule Table do
    @moduledoc false
    # MemoryStore.Rows' row access over the store's ordered_set: `{key, value}` rows.
    @behaviour Normandy.Behaviours.MemoryStore.Rows

    @impl true
    def fetch(table, key) do
      case :ets.lookup(table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :error
      end
    end

    @impl true
    def put(table, key, value) do
      true = :ets.insert(table, {key, value})
      :ok
    end

    @impl true
    def delete(table, key) do
      true = :ets.delete(table, key)
      :ok
    end

    # Walks the ordered keys from `{ns, prefix}` and stops at the first key that is not
    # a path of `ns` starting with `prefix`: the cost is the rows in range, not the
    # namespace. `{ns, 0}` sorts before `{ns, prefix}`, so the totals row is never seen.
    @impl true
    def range(table, {ns, prefix} = first) do
      acc =
        case :ets.lookup(table, first) do
          [{^first, doc}] -> [{prefix, doc}]
          [] -> []
        end

      walk(table, :ets.next(table, first), ns, prefix, acc)
    end

    defp walk(table, {ns, path} = key, ns, prefix, acc) when is_binary(path) do
      if String.starts_with?(path, prefix) do
        [{^key, doc}] = :ets.lookup(table, key)
        walk(table, :ets.next(table, key), ns, prefix, [{path, doc} | acc])
      else
        Enum.reverse(acc)
      end
    end

    defp walk(_table, _end_or_other_namespace, _ns, _prefix, acc), do: Enum.reverse(acc)
  end
end
```

In `lib/normandy/behaviours/memory_store/docs.ex`, replace the module comment

```elixir
  # Pure operations on one namespace's documents, `%{path => %{content, version,
  # updated_at}}`. InMemory, ETS and Mnesia run these inside their single serialized
  # writer (an Agent call, the ETS owner, a Mnesia transaction), which makes each atomic.
  # Every write returns `{reply, docs}`.
```

with

```elixir
  # Pure operations on one namespace's documents, `%{path => %{content, version,
  # updated_at}}`. InMemory and Mnesia run these inside their single serialized writer
  # (an Agent call, a Mnesia transaction), which makes each atomic. Every write returns
  # `{reply, docs}`. ETS keeps a row per document and uses MemoryStore.Rows.
```

and in the `next_version/2` comment, `Shared
  # with the Postgres backend.` → `Shared
  # with MemoryStore.Rows and the Postgres backend.`

- [ ] **Step 5: Guide**

In `docs/guides/agent-memory.md`, "## Backends", replace

```markdown
**InMemory and ETS** (node-local, lost on restart; for tests and single-node use). Like
Mnesia, they keep a whole namespace as one value (one row per namespace), so every
operation's cost grows with the namespace's size. Use these three for small namespaces and
prefer Postgres or Redis for large or busy ones:
```

with

```markdown
**InMemory and ETS** (node-local, lost on restart; for tests and single-node use).
InMemory keeps a whole namespace as one value in one process, so every operation's cost
grows with the namespace's size: use it for tests and small namespaces. ETS keeps one row
per document plus a totals row per namespace, so a `get` or `put` costs the same at any
namespace size; its owner process serializes every write and every listing:
```

(The Mnesia paragraph below still says "one row per namespace; see above"; Task 6.3i rewrites it.
Until then "see above" points at a paragraph that no longer describes Mnesia; this is a one-task
gap, accepted.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/behaviours/memory_store/ test/tools/memory_test.exs test/options/store_options_test.exs`
Expected: PASS (the ETS contract unchanged; `memory_test.exs`'s "a store that exits or raises"
test still reports `"Error: memory store unavailable: ArgumentError"` for a dead ETS owner,
because `view` and `str_replace` call `get/3` first).

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.3h.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.3h.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. Default suite only: the ETS store has no tagged
tests, and the Redis/Postgres memory stores are untouched.

- [ ] **Step 8: MIGRATING-2.0.md**

None in this task: `MemoryStore` is new in 2.0, the ETS handle and the contract are unchanged.
Task 6.3i adds the one bullet that covers both layouts.

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/behaviours/memory_store/rows.ex
git add lib/normandy/behaviours/memory_store/ets.ex
git add lib/normandy/behaviours/memory_store/docs.ex
git add docs/guides/agent-memory.md
git add test/behaviours/memory_store/ets_test.exs
git commit -m "perf(memory_store): one ETS row per document with a namespace totals row"
```

---

### Task 6.3i: Mnesia memory store — one record per document on `MemoryStore.Rows` (PERF-10)

`MemoryStore.Mnesia` stores `{table, namespace, docs}` (`memory_store/mnesia.ex:80`): every read
is a transaction that copies the namespace, every write takes the namespace's write lock and
writes the whole map back, which with `disc_copies` logs the whole namespace to every replica.
This task moves it onto `MemoryStore.Rows` (Task 6.3h): an `:ordered_set` table with attributes
`[:key, :value]`, the same `{ns, path}` and `{ns, 0}` keys. A write's first read is the totals
record with a write lock, so one namespace's writers still run one at a time, as with the old
namespace record. `list/3`, `delete_tree/3`, `rename/4` and `delete_namespace/2` use
`:mnesia.select/3`, which locks the whole table for the transaction (a read lock for `list/3`):
a rename or tree delete in one namespace briefly holds writes in the others. Documented in the
moduledoc; rare operations.

`MnesiaSetup.create_table!/4` always creates `:set` tables and returns `:ok` for any existing
table. It gains a type argument, and an existing table whose attributes or type differ now
raises: a memory table created by a 2.0 pre-release has the old attributes and would otherwise
be read and written as if it matched. The session store's two tables pass `:set` (unchanged,
so an existing v1.3.0 session table still matches).

**Files:**
- Modify (replace whole file): `lib/normandy/behaviours/memory_store/mnesia.ex`
- Modify: `lib/normandy/behaviours/mnesia_setup.ex` (`create_table!/4` → `/5`, new `check_layout!/3`)
- Modify: `lib/normandy/behaviours/session_store/mnesia.ex` (`create_tables/1`: two calls)
- Modify: `lib/normandy/behaviours/memory_store/docs.ex` (module comment)
- Modify: `docs/guides/agent-memory.md` (the Mnesia paragraph)
- Modify: `MIGRATING-2.0.md` (`## 40.`)
- Test (modify): `test/behaviours/memory_store/mnesia_test.exs`

**Interfaces:**
- Consumes: `MemoryStore.Rows` and its callbacks (6.3h).
- Produces: `Normandy.Behaviours.MemoryStore.Mnesia.Table` (`@moduledoc false`, the Mnesia row access; `arg` is `{table, :read | :write}`); `MnesiaSetup.create_table!(name, attrs, type, copies, nodes)`; the table layout `[:key, :value]`, `:ordered_set`.

- [ ] **Step 1: Write the failing tests**

Replace `test/behaviours/memory_store/mnesia_test.exs` with (the pinned attribute assertion in
"defaults to :normandy_memory_documents ..." changes from `[:namespace, :docs]` to
`[:key, :value]` and gains the type):

```elixir
defmodule Normandy.Behaviours.MemoryStore.MnesiaTest do
  # async: false — Mnesia is node-global state. The reset mirrors
  # test/behaviours/session_store/mnesia_test.exs (see its comment on the phantom
  # :nonode@nohost db_node).
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.MemoryStore.Mnesia, as: MnesiaStore

  setup do
    :mnesia.stop()
    :mnesia.delete_schema([node()])
    :ok = :mnesia.start()
    on_exit(fn -> :mnesia.stop() end)
  end

  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Mnesia

  test "a missing table is a backend error, not :not_found" do
    assert {:error, _} = MnesiaStore.get(:normandy_no_such_table, "ns", "/memories/a")
  end

  describe "create_tables/1" do
    test "defaults to :normandy_memory_documents with :disc_copies, and is idempotent" do
      on_exit(fn ->
        :mnesia.stop()
        :mnesia.delete_schema([node()])
      end)

      assert :ok = MnesiaStore.create_tables()
      assert :ok = MnesiaStore.create_tables()

      assert :normandy_memory_documents in :mnesia.system_info(:tables)
      assert :mnesia.table_info(:normandy_memory_documents, :disc_copies) == [node()]
      assert :mnesia.table_info(:normandy_memory_documents, :ram_copies) == []
      assert :mnesia.table_info(:normandy_memory_documents, :attributes) == [:key, :value]
      assert :mnesia.table_info(:normandy_memory_documents, :type) == :ordered_set

      # usable as a store handle
      assert {:ok, 1} =
               MnesiaStore.put(:normandy_memory_documents, "ns", "/memories/a", "x", :new)
    end

    test "honours :table and :copies" do
      assert :ok = MnesiaStore.create_tables(table: :normandy_memory_custom, copies: :ram_copies)
      assert :ok = MnesiaStore.create_tables(table: :normandy_memory_custom, copies: :ram_copies)

      assert :mnesia.table_info(:normandy_memory_custom, :ram_copies) == [node()]
      assert :mnesia.table_info(:normandy_memory_custom, :disc_copies) == []
      refute :normandy_memory_documents in :mnesia.system_info(:tables)
    end

    test "refuses an existing table of another layout, naming both" do
      {:atomic, :ok} =
        :mnesia.create_table(:normandy_memory_old,
          attributes: [:namespace, :docs],
          ram_copies: [node()]
        )

      assert_raise RuntimeError,
                   "Mnesia table :normandy_memory_old exists with attributes " <>
                     "[:namespace, :docs] and type :set; expected [:key, :value] and " <>
                     ":ordered_set. Delete the table or use another table name.",
                   fn ->
                     MnesiaStore.create_tables(table: :normandy_memory_old, copies: :ram_copies)
                   end
    end
  end

  describe "row layout (PERF-10)" do
    test "one record per document plus one totals record per namespace" do
      table = MnesiaStore.new()

      for i <- 1..5, do: {:ok, 1} = MnesiaStore.put(table, "ns", "/memories/f#{i}", "abc", :new)

      assert :mnesia.table_info(table, :size) == 6

      assert [{^table, {"ns", "/memories/f3"}, %{content: "abc", version: 1}}] =
               :mnesia.dirty_read(table, {"ns", "/memories/f3"})

      assert :mnesia.dirty_read(table, {"ns", 0}) == [{table, {"ns", 0}, {15, 5}}]

      assert {:ok, 5} = MnesiaStore.delete_tree(table, "ns", "/memories")
      assert :mnesia.table_info(table, :size) == 0
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/behaviours/memory_store/mnesia_test.exs`
Expected: FAIL: the attributes are `[:namespace, :docs]` and the type `:set`; the old-layout
table is accepted (no raise); the "row layout" test finds 1 record and no `{"ns", 0}` key.

- [ ] **Step 3: `MnesiaSetup`**

In `lib/normandy/behaviours/mnesia_setup.ex`, replace `create_table!/4` with:

```elixir
  def create_table!(name, attrs, type, copies, nodes) do
    case :mnesia.create_table(name, [{:attributes, attrs}, {:type, type}, {copies, nodes}]) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^name}} ->
        check_layout!(name, attrs, type)

      {:aborted, reason} ->
        raise "Mnesia create_table #{inspect(name)} failed: #{inspect(reason)}"
    end
  end

  # An existing table is used only when its layout is the one asked for: a table of
  # another layout (an older Normandy's) would be read and written as if it matched.
  defp check_layout!(name, attrs, type) do
    case {:mnesia.table_info(name, :attributes), :mnesia.table_info(name, :type)} do
      {^attrs, ^type} ->
        :ok

      {got_attrs, got_type} ->
        raise "Mnesia table #{inspect(name)} exists with attributes #{inspect(got_attrs)} " <>
                "and type #{inspect(got_type)}; expected #{inspect(attrs)} and " <>
                "#{inspect(type)}. Delete the table or use another table name."
    end
  end
```

In `lib/normandy/behaviours/session_store/mnesia.ex`, `create_tables/1` (after 6.3c these two
lines are unchanged; anchor on them):

```elixir
# before
    :ok = MnesiaSetup.create_table!(entries, [:id, :data], copies, nodes)
    :ok = MnesiaSetup.create_table!(sessions, [:session_id, :data], copies, nodes)
# after
    :ok = MnesiaSetup.create_table!(entries, [:id, :data], :set, copies, nodes)
    :ok = MnesiaSetup.create_table!(sessions, [:session_id, :data], :set, copies, nodes)
```

Check: `grep -rn "create_table!(" lib` → 4 lines (the definition, the memory store's call, the
two session-store calls), each with five arguments.

- [ ] **Step 4: The Mnesia store**

Replace `lib/normandy/behaviours/memory_store/mnesia.ex` with:

```elixir
defmodule Normandy.Behaviours.MemoryStore.Mnesia do
  @moduledoc """
  Distributed, durable `MemoryStore` over Mnesia, in an `:ordered_set` table with
  attributes `[:key, :value]`: one row per document (`{namespace, path}` → the document)
  plus one totals row per namespace (`{namespace, 0}` → `{bytes, documents}`). Every
  operation is one `:mnesia.transaction/1`. A write first takes the write lock on its
  namespace's totals row, so a namespace's writers run one at a time and compare-and-set,
  rename, delete_tree and the `put/6` limits are atomic across the cluster. `get/3` reads
  one row. `list/3`, `delete_tree/3`, `rename/4` and `delete_namespace/2` select the
  namespace's rows, which locks the whole table for the transaction (a read lock for
  `list/3`): a rename or tree delete in one namespace briefly holds writes in the others.

  The handle is the table name. Create it with `create_tables/1` (`copies: :disc_copies`
  by default, for durability; `:table` defaults to `:normandy_memory_documents`); `new/1`
  makes a uniquely named `ram_copies` table for tests. A release using this store must
  include `:mnesia` in `extra_applications`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  # :mnesia is not a declared application dependency (see the moduledoc).
  @compile {:no_warn_undefined, :mnesia}

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore.Rows
  alias Normandy.Behaviours.MnesiaSetup
  alias Normandy.Options

  @new_opts_schema NimbleOptions.new!(
                     table: [type: :atom, doc: "The table (default: a unique name)."]
                   )

  @create_tables_opts_schema NimbleOptions.new!(
                               table: [
                                 type: :atom,
                                 default: :normandy_memory_documents,
                                 doc: "The table."
                               ],
                               copies: [
                                 type: {:in, [:disc_copies, :ram_copies]},
                                 default: :disc_copies,
                                 doc: "Disc or RAM copies."
                               ],
                               nodes: [
                                 type: {:list, :atom},
                                 doc: "The nodes holding copies (default: `[node()]`)."
                               ],
                               wait_timeout: [
                                 type: :timeout,
                                 default: 30_000,
                                 doc: "How long to wait for the table to load, in ms."
                               ]
                             )

  @doc """
  Test/default handle: a fresh uniquely named `ram_copies` table on this node.

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
    table = Keyword.get(opts, :table, :"normandy_memory_#{System.unique_integer([:positive])}")
    :ok = create_tables(table: table, copies: :ram_copies)
    table
  end

  @doc """
  Creates the memory table.

  ## Options

  #{Options.docs(@create_tables_opts_schema)}
  """
  @spec create_tables(keyword()) :: :ok
  def create_tables(opts \\ []) do
    opts = Options.validate!(opts, @create_tables_opts_schema, {__MODULE__, :create_tables, 1})
    table = Keyword.fetch!(opts, :table)
    copies = Keyword.fetch!(opts, :copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    :ok = MnesiaSetup.ensure_started!()
    if copies == :disc_copies, do: MnesiaSetup.ensure_disc_schema!(nodes)
    :ok = MnesiaSetup.create_table!(table, [:key, :value], :ordered_set, copies, nodes)

    MnesiaSetup.wait_for_tables!(
      [table],
      Keyword.fetch!(opts, :wait_timeout),
      "MemoryStore.Mnesia"
    )
  end

  @impl true
  def list(table, ns, prefix),
    do: txn(fn -> Rows.list({__MODULE__.Table, {table, :read}}, ns, prefix) end)

  @impl true
  def get(table, ns, path),
    do: txn(fn -> Rows.get({__MODULE__.Table, {table, :read}}, ns, path) end)

  @impl true
  def put(table, ns, path, content, expected, limits \\ []) do
    limits = MemoryStore.validate_limits!(limits, __MODULE__)
    write(table, :put, [ns, path, content, expected, limits])
  end

  @impl true
  def delete(table, ns, path, expected), do: write(table, :delete, [ns, path, expected])

  @impl true
  def delete_tree(table, ns, prefix), do: write(table, :delete_tree, [ns, prefix])

  @impl true
  def rename(table, ns, from, to), do: write(table, :rename, [ns, from, to])

  @impl true
  def delete_namespace(table, ns), do: write(table, :delete_namespace, [ns])

  defp write(table, fun, args),
    do: txn(fn -> apply(Rows, fun, [{__MODULE__.Table, {table, :write}} | args]) end)

  # The transaction's own value is the reply; an abort is a backend error.
  defp txn(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, reply} -> reply
      {:aborted, reason} -> {:error, reason}
    end
  end

  defmodule Table do
    @moduledoc false
    # MemoryStore.Rows' row access inside a transaction: records `{table, key, value}`,
    # every read and select under the transaction's `lock` (`:read` or `:write`).
    @behaviour Normandy.Behaviours.MemoryStore.Rows

    @compile {:no_warn_undefined, :mnesia}

    @impl true
    def fetch({table, lock}, key) do
      case :mnesia.read(table, key, lock) do
        [{^table, ^key, value}] -> {:ok, value}
        [] -> :error
      end
    end

    @impl true
    def put({table, _lock}, key, value), do: :mnesia.write(table, {table, key, value}, :write)

    @impl true
    def delete({table, _lock}, key), do: :mnesia.delete(table, key, :write)

    # A select on the namespace's document keys (the binary paths; the totals row's key
    # is the integer 0), filtered to the prefix and sorted by path: a select inside a
    # transaction does not promise key order.
    @impl true
    def range({table, lock}, {ns, prefix}) do
      spec = [{{table, {ns, :"$1"}, :"$2"}, [{:is_binary, :"$1"}], [{{:"$1", :"$2"}}]}]

      table
      |> :mnesia.select(spec, lock)
      |> Enum.filter(fn {path, _doc} -> String.starts_with?(path, prefix) end)
      |> Enum.sort_by(&elem(&1, 0))
    end
  end
end
```

In `lib/normandy/behaviours/memory_store/docs.ex`, replace the module comment 6.3h wrote with:

```elixir
  # Pure operations on one namespace's documents, `%{path => %{content, version,
  # updated_at}}`. InMemory runs these inside one Agent call, which makes each atomic.
  # Every write returns `{reply, docs}`. ETS and Mnesia keep a row per document and use
  # MemoryStore.Rows; they share `next_version/2`.
```

- [ ] **Step 5: Guide**

In `docs/guides/agent-memory.md`, replace

```markdown
**Mnesia** (one row per namespace; see above): create the table once at boot (`:disc_copies` by default; the default table is
`:normandy_memory_documents`), and use the table name as the handle.
```

with

```markdown
**Mnesia** (one row per document plus a totals row per namespace, in an `:ordered_set`
table): create the table once at boot (`:disc_copies` by default; the default table is
`:normandy_memory_documents`), and use the table name as the handle. A write locks its
namespace's totals row, so one namespace's writers run one at a time. A listing, rename or
tree delete selects the namespace's rows and locks the whole table while it runs.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/behaviours/memory_store/ test/behaviours/session_store/mnesia_test.exs test/tools/memory_test.exs test/options/store_options_test.exs`
Expected: PASS (the Mnesia contract unchanged, including the three concurrency tests through
the memory tool and "two writers that fit alone but not together").

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.3i.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.3i.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.
Tagged: `docker start normandy-test-pg`, then
`MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tail -3`
→ ` 0 failures` (`session_store/mnesia_distributed_test.exs` builds its tables through
`create_table!/5`; Postgres is needed because `eager_handoff_distributed_test.exs` is tagged only
`:distributed`, see 6.3f Step 9). Stop `normandy-test-pg` afterwards if you started it.

- [ ] **Step 8: MIGRATING-2.0.md**

Append to `## 40.`:

```markdown
- `MemoryStore.ETS` and `MemoryStore.Mnesia` (new in 2.0) keep one row per document plus one
  totals row per namespace, so a `get` or `put` no longer copies the whole namespace. The
  Mnesia table is an `:ordered_set` with attributes `[:key, :value]`. A Mnesia memory table
  created by a 2.0 pre-release has the old layout: `MemoryStore.Mnesia.create_tables/1` now
  raises, naming both layouts; delete it (`:mnesia.delete_table/1`) and create it again. The
  same check applies to the session store's Mnesia tables, whose layout is unchanged.
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/behaviours/memory_store/mnesia.ex
git add lib/normandy/behaviours/mnesia_setup.ex
git add lib/normandy/behaviours/session_store/mnesia.ex
git add lib/normandy/behaviours/memory_store/docs.ex
git add docs/guides/agent-memory.md
git add MIGRATING-2.0.md
git add test/behaviours/memory_store/mnesia_test.exs
git commit -m "perf(memory_store): one Mnesia record per document with a namespace totals record"
```

---

---

### Task 6.4a: `Turn.Server` runs admission and `on_turn_end` in the caller's trace; a turn that fails before it runs gets a run span (TEL-3, TEL-12)

Today `Turn.Server` attaches the caller's OTel context only between the hand-emitted run `:start` and its
`:stop`/`:exception` (`start_run_span/5` attaches, `stop_run_span/3` detaches). Admission (`admit/2`: schema,
`on_prompt` hooks, input guardrails), the repair of an interrupted batch (`close_batch/2`: `after_tool` hooks) and
`on_turn_end` (`turn_end/4`, always after the detach) run with no context, so their hook spans are roots of other
traces (inventory probe P1). Ruling R9: the server attaches the caller's context for the whole turn (admission to
`on_turn_end`); admission stays outside the run span (on_prompt is the run's sibling). A crash in admission and a
failed write of the turn's first messages reply an error but emit no run span (TEL-12); they get the same
`:start` + `:exception` pair rejected input already gets.

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`Data` field `turn_ctx_token`; the `:idle` `{:turn, input, caller_ctx}` clause; `start_turn/5`; `start_run_span/5` → `/4`; `emit_rejected_run/3` → `emit_failed_run/4`; `start_resumed_run_span/1`; `stop_run_span/3`; new `release_turn_ctx/1`; the `{:finalize, _}` and `{:fail, _}` clauses of `interpret/2`; remove `persist_failed/1`)
- Modify: `lib/normandy/telemetry.ex` (moduledoc: run `:exception` bullet; "Turn.Server" parenting bullet)
- Modify: `test/support/hook_probes.ex` (new `Normandy.Test.Hooks.PromptOnly`)
- Modify: `MIGRATING-2.0.md` (create `## 41. Telemetry and logs`)
- Test: `test/telemetry/span_hierarchy_test.exs`, `test/telemetry/metadata_test.exs`

**Interfaces:**
- Consumes: `OtelCtx.attach/1`, `OtelCtx.detach/1` (unchanged); `Normandy.Test.OtelSpanBridge`, `Normandy.Test.TelemetryCapture`, `Normandy.Test.Hooks.Probe`/`TurnEndOnly` (unchanged); after Task 6.3c, `SessionStore.save_turn_state/4`.
- Produces: `Turn.Server.Data` field `turn_ctx_token` (internal); `Normandy.Test.Hooks.PromptOnly` (test support).

Tagged suites: none (no start path, registry or reaper change). The default suite covers Turn.Server.

- [ ] **Step 1: Write the failing tests**

Append to `test/support/hook_probes.ex`:

```elixir

defmodule Normandy.Test.Hooks.PromptOnly do
  @moduledoc """
  Implements only on_prompt, so a turn opens exactly one hook span for it. Sends
  `{:prompt_only, input}` to `opts[:notify]` (a registered name) and returns
  `opts[:returns]`, or passes (`{:cont, input}`).
  """
  use Normandy.Behaviours.Hooks

  @impl true
  def on_prompt(input, _ctx, opts) do
    if dest = opts[:notify], do: send(dest, {:prompt_only, input})
    Keyword.get(opts, :returns, {:cont, input})
  end
end
```

In `test/telemetry/span_hierarchy_test.exs`, insert before the comment
`# A server whose "weather" tool needs approval, so the turn parks after the` (after the `describe
"Turn.Server.run/2"` block, which stays unchanged, including "does not carry one turn's caller context into the
next", the regression guard for the detach):

```elixir
  # A Turn.Server whose config carries `hooks`, with the bridge also opening hook spans.
  defp start_hooked_turn_server(client, hooks, store \\ {InMemory, InMemory.new()}) do
    OtelSpanBridge.attach(prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :hook]])

    config =
      BaseAgent.init(%{
        client: client,
        model: "test-model",
        behaviours: %Normandy.Behaviours.Config{hooks: hooks}
      })

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "span-hook-#{System.unique_integer([:positive])}",
        config: config,
        store: store,
        registry: {Native, Native.new()}
      )

    srv
  end

  describe "Turn.Server hooks outside the run (TEL-3)" do
    test "an on_prompt hook span is a child of the caller, a sibling of run" do
      srv =
        start_hooked_turn_server(counted_client(false), [{Normandy.Test.Hooks.PromptOnly, []}])

      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.hook", "normandy.agent.run"])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert hook.parent_span_id == caller_span.span_id
      assert run.parent_span_id == caller_span.span_id
      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end

    test "an on_turn_end hook span is a child of the caller" do
      srv =
        start_hooked_turn_server(counted_client(false), [{Normandy.Test.Hooks.TurnEndOnly, []}])

      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)
      # on_turn_end runs after the reply; await_spans blocks until its span ends.
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.hook"])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")

      assert hook.parent_span_id == caller_span.span_id
      assert hook.trace_id == caller_span.trace_id
    end

    test "a rejected input's on_prompt and on_turn_end hook spans are children of the caller" do
      srv =
        start_hooked_turn_server(counted_client(false), [
          {Normandy.Test.Hooks.PromptOnly, returns: {:halt, "no"}},
          {Normandy.Test.Hooks.TurnEndOnly, []}
        ])

      caller = start_caller_span()

      assert {:error, %Normandy.HookHaltError{}} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.hook",
          "normandy.hook",
          "normandy.agent.run"
        ])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hooks = Enum.filter(spans, &(&1.name == "normandy.hook"))
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert [_, _] = hooks
      assert Enum.all?(hooks, &(&1.parent_span_id == caller_span.span_id))
      assert run.parent_span_id == caller_span.span_id
    end

    test "after a hooked turn the server holds no caller context" do
      srv =
        start_hooked_turn_server(counted_client(false), [{Normandy.Test.Hooks.TurnEndOnly, []}])

      caller = start_caller_span()
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      :otel_span.end_span(caller)
      _ = OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.hook"])

      # The two-element request carries no context: its spans are roots.
      assert {:ok, _} = :gen_statem.call(srv, {:turn, %{chat_message: "again"}}, :infinity)

      spans = OtelSpanBridge.await_spans(["normandy.agent.run", "normandy.hook"])
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")

      assert run.parent_span_id == :undefined
      assert hook.parent_span_id == :undefined
    end

    # X9: Task 6.2's exits (:loading, :unavailable, a load crash, passivation) attach no
    # turn context; a request that arrives in :unavailable is postponed and replayed in
    # :idle, where the :turn clause attaches and releases it like any other.
    @tag :capture_log
    test "a turn replayed after an :unavailable load runs in the caller's context and releases it" do
      store = FlakyStore.new()
      FlakyStore.down(store)

      srv =
        start_hooked_turn_server(
          counted_client(false),
          [{Normandy.Test.Hooks.TurnEndOnly, []}],
          {FlakyStore, store}
        )

      assert {:unavailable, _} = :sys.get_state(srv)
      FlakyStore.up(store)

      # run/2 in :unavailable retries the load and replays the request in :idle.
      caller = start_caller_span()
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.hook"])
      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")

      assert OtelSpanBridge.fetch_span!(spans, "normandy.hook").parent_span_id ==
               caller_span.span_id

      assert {:ok, _} = :gen_statem.call(srv, {:turn, %{chat_message: "again"}}, :infinity)

      spans = OtelSpanBridge.await_spans(["normandy.agent.run", "normandy.hook"])
      assert OtelSpanBridge.fetch_span!(spans, "normandy.agent.run").parent_span_id == :undefined
      assert OtelSpanBridge.fetch_span!(spans, "normandy.hook").parent_span_id == :undefined
    end
  end

```

In the module's aliases, `alias Normandy.Test.{FakeTool, OtelSpanBridge, StubClient}` becomes
`alias Normandy.Test.{FakeTool, FlakyStore, OtelSpanBridge, StubClient}` (6.2a's `test/support/flaky_store.ex`;
credo flags the nested name otherwise).

In `test/telemetry/metadata_test.exs`, `describe "Turn.Server run span"`, insert before
`@tag :capture_log` / `test "rejected input emits run :start and :exception like BaseAgent, same reply" do`. The
store stub uses `save_turn_state/4`, the callback Task 6.3c introduces:

```elixir
    # Fails every "user" append; everything else goes to InMemory.
    defmodule UserAppendFailStore do
      @moduledoc false
      alias Normandy.Behaviours.SessionStore.InMemory
      def new, do: InMemory.new()
      def append_entry(_h, _sid, %{role: "user"}), do: {:error, :disk_full}
      def append_entry(h, sid, e), do: InMemory.append_entry(h, sid, e)

      def save_turn_state(h, sid, t, inflight?),
        do: InMemory.save_turn_state(h, sid, t, inflight?)

      def load_turn_state(h, sid), do: InMemory.load_turn_state(h, sid)
      def history(h, sid), do: InMemory.history(h, sid)
    end

    @tag :capture_log
    test "an admission crash emits run :start and :exception with the replied TurnError" do
      TelemetryCapture.attach_span(
        [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]],
        session_id: "s-admit-crash"
      )

      hooks = [{Normandy.Test.Hooks.Probe, returns: [on_prompt: {:raise, "x"}]}]
      config = server_config(%{behaviours: %Normandy.Behaviours.Config{hooks: hooks}})
      srv = start_server("s-admit-crash", config)

      assert {:error, %Normandy.TurnError{type: :handler_crashed, handler: :admit}} =
               Turn.Server.run(srv, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :run, :start],
                       %{session_id: "s-admit-crash"} = start_meta}

      refute Map.has_key?(start_meta, :turn_id)

      assert_received {:span, [:normandy, :agent, :run, :exception],
                       %{
                         session_id: "s-admit-crash",
                         kind: :error,
                         reason: %Normandy.TurnError{
                           type: :handler_crashed,
                           handler: :admit,
                           reason: %{exception: RuntimeError}
                         },
                         stacktrace: []
                       }}
    end

    test "a failed write of the turn's first message emits run :start and :exception" do
      TelemetryCapture.attach_span(
        [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]],
        session_id: "s-persist-fail"
      )

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: "s-persist-fail",
          config: server_config(%{}),
          store: {UserAppendFailStore, UserAppendFailStore.new()},
          registry: {Native, Native.new()}
        )

      assert {:error, %Normandy.TurnError{type: :persist_failed, reason: :disk_full}} =
               Turn.Server.run(srv, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :run, :start],
                       %{session_id: "s-persist-fail", turn_id: turn_id}}

      assert is_binary(turn_id)

      assert_received {:span, [:normandy, :agent, :run, :exception],
                       %{
                         session_id: "s-persist-fail",
                         turn_id: ^turn_id,
                         kind: :error,
                         reason: %Normandy.TurnError{type: :persist_failed, reason: :disk_full},
                         stacktrace: []
                       }}
    end

```

The code below emits the run events before it replies, and the telemetry handler runs in the server process, so its
messages reach the test before the reply does and `assert_received` (no wait) is deterministic.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/telemetry/span_hierarchy_test.exs test/telemetry/metadata_test.exs`
Expected: FAIL, `36 tests, 5 failures` (stacked on 6.3i): the three parenting tests ("an on_prompt hook span…",
"an on_turn_end hook span…": `hook.parent_span_id` is `:undefined`; "a rejected input's…": the
`Enum.all?(hooks, ...)` assertion), and both new metadata tests (`No message matching
{:span, [:normandy, :agent, :run, :start], ...}`). "after a hooked turn the server holds no caller context" and
the X9 "replayed after an :unavailable load" test pass already (regression guards).

- [ ] **Step 3: One context for the whole turn**

In `lib/normandy/agents/turn/server.ex`:

a. `defmodule Data`: after `run_span: nil,` add `turn_ctx_token: nil,`.

b. The `:idle` clause `def handle_event({:call, from}, {:turn, user_input, caller_ctx}, :idle, data) do`. Replace its
first line of body (`missing = data.config.memory |> ...`) by:

```elixir
    # The caller's OTel context is current for the whole turn, admission to on_turn_end;
    # release_turn_ctx/1 puts back the context that was current before it.
    data = %{data | turn_ctx_token: OtelCtx.attach(caller_ctx)}
    missing = data.config.memory |> AgentMemory.messages() |> Turn.unanswered_tool_calls()
```

and replace its `else` branches:

```elixir
      {:rejected, exception} ->
        emit_rejected_run(data, caller_ctx, exception)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, data.config, {:rejected, exception}, turn_id: nil)
        {:keep_state, data}

      {:crashed, reason} ->
        exception = TurnError.from_reason(reason)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, data.config, {:error, exception}, turn_id: nil)
        {:keep_state, data}
```

with

```elixir
      {:rejected, exception} ->
        emit_failed_run(data, data.config, nil, exception)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, data.config, {:rejected, exception}, turn_id: nil)
        {:keep_state, release_turn_ctx(data)}

      {:crashed, reason} ->
        exception = TurnError.from_reason(reason)
        emit_failed_run(data, data.config, nil, exception)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, data.config, {:error, exception}, turn_id: nil)
        {:keep_state, release_turn_ctx(data)}
```

If Task 6.2d added actions to these returns (an idle-timeout re-arm: `{:keep_state, data, idle_timeout(data)}`),
keep them and only replace `data` by `release_turn_ctx(data)`: `{:keep_state, data2, idle_timeout(data2)}` with
`data2 = release_turn_ctx(data)`.

c. `start_turn/5`: replace `run_span = start_run_span(data, config, caller_ctx, Metadata.turn_id(config))` by
`run_span = start_run_span(data, config, Metadata.turn_id(config))` (`caller_ctx` is still used by
`OtelCtx.inject(caller_ctx)` above it), and its `else` branch plus the `persist_failed/1` helper below it:

```elixir
      {:error, stored, reason} ->
        :gen_statem.reply(from, persist_failed(reason))
        turn_end(data, config, persist_failed(reason))
        {:keep_state, %{data | config: stored}}
    end
  end

  defp persist_failed(reason), do: {:error, %TurnError{type: :persist_failed, reason: reason}}
```

by

```elixir
      {:error, stored, reason} ->
        exception = %TurnError{type: :persist_failed, reason: reason}
        emit_failed_run(data, config, Metadata.turn_id(config), exception)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, config, {:error, exception})
        {:keep_state, release_turn_ctx(%{data | config: stored})}
    end
  end
```

(`grep -n "persist_failed(" lib/normandy/agents/turn/server.ex` must then show no call of the removed helper; the
`{:persist_failed, reason}` tuples elsewhere are unrelated.)

d. Replace the comment block and head of `start_run_span/5`:

```elixir
  # The caller's OTel context is attached in this (long-lived) process before
  # :start, so a bridged run span nests under the caller's span; stop_run_span/3
  # detaches it again so it does not leak into the next turn.
  defp start_run_span(data, config, caller_ctx, turn_id, extra_meta \\ %{}) do
    caller_ctx_token = OtelCtx.attach(caller_ctx)

```

by

```elixir
  # The turn's context (the caller's, attached by the :turn clause or by
  # start_resumed_run_span/1) is current at :start, so a bridged run span nests under
  # the caller's span.
  defp start_run_span(data, config, turn_id, extra_meta \\ %{}) do
```

and its last line `%{start: start, meta: meta, caller_ctx_token: caller_ctx_token}` by `%{start: start, meta: meta}`.

e. Replace `emit_rejected_run/3` with its comment:

```elixir
  # A turn that fails before its run starts (rejected or crashed admission, a failed
  # write of its first messages) is reported as BaseAgent.run/2 reports a raised
  # admission: a run span that ends in :exception with the replied exception. turn_id is
  # nil for an admission failure (no turn was begun) and the begun turn's id for a
  # failed write.
  defp emit_failed_run(data, config, turn_id, exception) do
    span = start_run_span(data, config, turn_id)

    stop_run_span(
      %{data | run_span: span, approval_wait: 0},
      :exception,
      Span.exception_metadata(:error, exception, [])
    )
  end
```

f. `start_resumed_run_span/1`: replace its last two lines

```elixir
    run_span = start_run_span(data, data.config, caller_ctx, turn_id, %{resumed: true})
    %{data | run_span: run_span, approval_wait: 0}
```

by

```elixir
    token = OtelCtx.attach(caller_ctx)
    run_span = start_run_span(data, data.config, turn_id, %{resumed: true})
    %{data | run_span: run_span, approval_wait: 0, turn_ctx_token: token}
```

g. `stop_run_span/3`: the head becomes `defp stop_run_span(%Data{run_span: %{start: start, meta: meta}} = data,
event, extra) do` and its last line `OtelCtx.detach(span.caller_ctx_token)` becomes `:ok`. Below it add:

```elixir
  # Puts back the context that was current before the turn attached its own
  # (turn_ctx_token), after on_turn_end ran under the turn's, so one turn's context
  # does not leak into the next.
  defp release_turn_ctx(%Data{turn_ctx_token: token} = data) do
    OtelCtx.detach(token)
    %{data | turn_ctx_token: nil}
  end
```

h. `interpret/2`, the `{:finalize, value}` and `{:fail, reason}` clauses: after the line
`turn_end(data, data.config, {:ok, value})` (finalize) and after
`turn_end(data, data.config, ServerGlue.fail_outcome(reason))` (fail) add `data = release_turn_ctx(data)`; the
following `{:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}` lines stay.

`with_approver_ctx/3` keeps discarding its tokens: `detach/1` of the turn token restores the context saved when the
turn began, whatever was attached after it. `terminate/3` needs no detach (the process ends).

`grep -n "caller_ctx_token\|emit_rejected_run" lib/normandy/agents/turn/server.ex` → 0 hits.

- [ ] **Step 4: Catalogue**

In `lib/normandy/telemetry.ex` moduledoc, run span section, replace

```
    * `:exception` from `Turn.Server` has `kind: :error`, `reason`: the exception `run/2`
      replies (rejected input included), redacted as described above, and
      `stacktrace: []`.
```

by

```
    * `:exception` from `Turn.Server` has `kind: :error`, `reason`: the exception `run/2`
      replies, redacted as described above, and `stacktrace: []`. A turn that fails before
      it runs emits a run `:start` and `:exception` too: rejected input and a crash in
      admission (no `turn_id`), and a failed write of the turn's first messages (with the
      begun turn's `turn_id`).
```

and in "## Turn.Server" replace the "Parenting" bullet

```
    * Parenting: `run/2` carries the caller's OTel context in the call, and the server
      attaches it around the run `:start`, so the run nests under the caller's span.
      llm_call and tool spans, which run in the server's tasks, nest under the run.
```

by

```
    * Parenting: `run/2` carries the caller's OTel context in the call, and the server
      makes it current for the whole turn, from admission to `on_turn_end`, then puts back
      the context it had before. The run nests under the caller's span; llm_call and tool
      spans, which run in the server's tasks, nest under the run. The hook spans the
      server runs outside the run (admission's `on_prompt`, the `after_tool` of an
      interrupted batch's results, `on_turn_end`) are children of the caller, siblings of
      the run. `BaseAgent` admits input inside its run span, so there `on_prompt` is the
      run's child. A resumed durable turn uses the context saved with it the same way.
```

The `server.ex` dynamic call-site count in `test/telemetry/catalogue_test.exs` stays 1 (`stop_run_span/3`).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/telemetry test/hooks test/agents/turn`
Expected: PASS (0 failures; the span hierarchy module has 5 more tests, metadata 2 more). Stacked: `2 doctests, 447 tests, 0 failures (8 excluded)` before the X9 test.

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.4a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.4a.log` and
`mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0.

- [ ] **Step 7: MIGRATING-2.0.md**

Insert after the end of `## 40.` and before `## New, non-breaking`:

```markdown
## 41. Telemetry and logs

- `Turn.Server` keeps the caller's OpenTelemetry context current for the whole turn, from
  admission to `on_turn_end`. Hook spans the server runs outside the run (`on_prompt`, the
  `after_tool` of an interrupted batch's results, `on_turn_end`) are now children of the
  caller's span, in its trace; they used to be roots of new traces. They are siblings of
  the run span, not its children (`BaseAgent` keeps `on_prompt` inside its run).
- A `Turn.Server` turn whose admission crashes (`:handler_crashed`, `handler: :admit`) or
  whose first messages cannot be written (`:persist_failed`) now emits a run `:start` and
  `:exception` carrying the replied error, as rejected input already did. Dashboards that
  count runs see these turns.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/telemetry.ex test/support/hook_probes.ex \
  test/telemetry/span_hierarchy_test.exs test/telemetry/metadata_test.exs MIGRATING-2.0.md
git commit -m "fix(turn): run admission and on_turn_end in the caller's trace; report pre-run failures as runs"
```

---

### Task 6.4b: A run's `:stop` carries its totals; no `usage: nil`; `get_response/2` is an llm_call span (TEL-7, TEL-10, TEL-11)

A run's `:stop` today repeats its start metadata plus `turn_id`. The token usage of its calls exists only in each
llm_call span's stop, and no channel carries it back (`call_turn_llm/3` returns only the content; Turn.Server makes
each call in a fresh worker). Ruling R9 / 6.4 Q1 (a): an explicit `:counters` accumulator,
`Normandy.Telemetry.RunUsage`, rides the transient call request as `request[:run_usage]`; `with_llm_call_span`
adds each finished call to it; the run's `:stop` reads it plus the final `Turn.State`. Compaction summaries are not
counted (documented). Also: the llm_call stop no longer carries `usage: nil` (TEL-10; the stream path already
omits it), and `get_response/2` (public, no span today) gets an llm_call span without `iteration` (TEL-11, R9).
`before_llm` hooks never see the accumulator: `Normandy.Hooks.Handlers` hands a hook only
`%{final:, iterations_left:}` and a hook returns `:cont` or a halt, never a request, so it can neither read nor drop
`request[:run_usage]` (in BaseAgent the hook runs before `with_run_usage/2` adds the key; in Turn.Server the key is on
the request `ServerGlue.before_llm/4` receives, but not on the info). A host's own Turn.Server `:handlers` `call_llm`
receives the request with the key and may ignore it. Pinned by the "before_llm hooks and the run accumulator" tests.

**Files:**
- Create: `lib/normandy/telemetry/run_usage.ex`
- Modify: `lib/normandy/telemetry/usage.ex` (`put_raw/2`)
- Modify: `lib/normandy/telemetry/metadata.ex` (`run_stop/2`)
- Modify: `lib/normandy/agents/base_agent.ex` (`get_response/2`, `get_response_with_usage/3`, `run!/3`, `stream/3`, `run_turn/2` → `/3`, `drive_turn/2` → `/3`, new `with_run_usage/2`, `call_turn_llm/3`, new `llm_stop_metadata/4`, `run_stream_turn/3` → `/4`, `call_stream_llm/4`, `stream_llm_attempt/5`, `with_agent_run_span/3`, `with_llm_call_span/3` → `/4`; remove `put_usage/2`, `completed_iterations/1`)
- Modify: `lib/normandy/agents/turn/server.ex` (`start_run_span/4`, `interpret/2` `{:call_llm, _}` and `{:finalize, _}`, new `run_usage/1`, `run_stop_metadata/1`)
- Modify: `lib/normandy/context/summarizer.ex` (`llm_call_span/3`)
- Modify: `lib/normandy/telemetry.ex` (run stop bullet, new "Run totals" subsection, llm_call text, mapping rows)
- Modify: `MIGRATING-2.0.md` (`## 41.`, `## New, non-breaking`)
- Test: create `test/telemetry/run_usage_test.exs`, `test/telemetry/run_totals_test.exs`; modify `test/context/summarizer_test.exs`, `test/agents/base_agent_logging_test.exs`

**Interfaces:**
- Consumes: `Normandy.Test.WireScript.client/2`, `message/3`, `block/3` (Wave 5); `Turn.State` fields `max_iterations`, `iterations_left`, `stop_reason`, `last_response` (unchanged); 6.4a's `start_run_span/4`.
- Produces: `Normandy.Telemetry.RunUsage` (`@moduledoc false`; `new/0`, `add(acc | nil, stop_meta) :: :ok`, `stop_metadata(acc) :: map()`, header); `request[:run_usage]` on every call request of `run/3`, `stream/3` and `Turn.Server`; run `:stop` keys `llm_calls`, `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens`, `iterations`, `stop_reason`, `finish_reason` (header); `Normandy.Telemetry.Metadata.run_stop(Turn.State.t(), :counters.counters_ref()) :: map()` (public, documented); `Normandy.Telemetry.Usage.put_raw(map(), term()) :: map()` (public, documented); `@doc` on `BaseAgent.get_response/2`.

Tagged suites: none.

- [ ] **Step 1: Write the failing tests**

Create `test/telemetry/run_usage_test.exs`:

```elixir
defmodule Normandy.Telemetry.RunUsageTest do
  use ExUnit.Case, async: true

  alias Normandy.Telemetry.RunUsage

  test "a new accumulator reports no calls and no token keys" do
    assert RunUsage.stop_metadata(RunUsage.new()) == %{llm_calls: 0}
  end

  test "sums the counts of every call and keeps only the counts some call reported" do
    acc = RunUsage.new()
    assert :ok = RunUsage.add(acc, %{input_tokens: 10, output_tokens: 5, model: "m"})
    assert :ok = RunUsage.add(acc, %{input_tokens: 7, cache_read_input_tokens: 3})
    assert :ok = RunUsage.add(acc, %{})

    assert RunUsage.stop_metadata(acc) == %{
             llm_calls: 3,
             input_tokens: 17,
             output_tokens: 5,
             cache_read_input_tokens: 3
           }
  end

  test "a reported count of 0 is kept" do
    acc = RunUsage.new()
    :ok = RunUsage.add(acc, %{cache_write_input_tokens: 0})
    assert RunUsage.stop_metadata(acc) == %{llm_calls: 1, cache_write_input_tokens: 0}
  end

  test "nil (a request with no accumulator) adds nothing" do
    assert :ok = RunUsage.add(nil, %{input_tokens: 1})
  end
end
```

Create `test/telemetry/run_totals_test.exs`:

```elixir
defmodule Normandy.Telemetry.RunTotalsTest do
  @moduledoc """
  Task 6.4b (TEL-7, TEL-10, TEL-11): a run's `:stop` carries its totals (llm calls,
  tokens, iterations, stop and finish reason) on `run/3`, `stream/3` and `Turn.Server`;
  an llm_call stop never carries `usage: nil`; `get_response/2` is an llm_call span.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeTool
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @weather %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @done %{"type" => "text", "text" => "Done."}
  @run_stop [:normandy, :agent, :run, :stop]
  @token_keys [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens]

  defp agent(client, extra \\ %{}) do
    name = "run-totals-#{System.unique_integer([:positive])}"

    config =
      BaseAgent.init(
        Map.merge(
          %{
            client: client,
            model: "claude-opus-5-5",
            name: name,
            toolset: Toolset.new([%FakeTool{}])
          },
          extra
        )
      )

    {name, config}
  end

  defp server(config, session_id, extra \\ []) do
    {:ok, srv} =
      Server.start_link(
        [
          session_id: session_id,
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        ] ++ extra
      )

    srv
  end

  # One tool round, then the answer: two calls, each billed 1 input and 1 output token
  # (WireScript's usage).
  defp json_tool_turn,
    do: WireScript.client([{:json, [@weather], "tool_use"}, {:json, [@done], "end_turn"}])

  defp streamed_tool_turn do
    tool =
      WireScript.message(
        "msg_0",
        WireScript.block(0, @weather, [%{"type" => "input_json_delta", "partial_json" => "{}"}]),
        "tool_use"
      )

    text =
      WireScript.message(
        "msg_1",
        WireScript.block(0, %{"type" => "text", "text" => ""}, [
          %{"type" => "text_delta", "text" => "Done."}
        ]),
        "end_turn"
      )

    WireScript.client([{:sse, tool}, {:sse, text}])
  end

  defp assert_tool_turn_totals(meta) do
    assert %{
             llm_calls: 2,
             input_tokens: 2,
             output_tokens: 2,
             iterations: 1,
             stop_reason: :completed,
             finish_reason: "end_turn"
           } = meta

    refute Map.has_key?(meta, :cache_read_input_tokens)
    refute Map.has_key?(meta, :cache_write_input_tokens)
  end

  describe "run :stop totals" do
    test "run/3" do
      {name, config} = agent(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(config, "go")

      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "stream/3" do
      {name, config} = agent(streamed_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(config, "go", fn _event -> :ok end)

      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "Turn.Server" do
      {_name, config} = agent(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], session_id: "s-run-totals")
      srv = server(config, "s-run-totals")

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")

      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "a provider that reports no usage gives the call count and no token keys" do
      {name, config} =
        agent(%StubClient{reply: fn rm -> Map.put(rm, :chat_message, "hi") end}, %{toolset: nil})

      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, _output} = BaseAgent.run(config, "go")

      assert_received {:span, @run_stop, meta}
      assert %{llm_calls: 1, iterations: 0, stop_reason: :completed} = meta
      for key <- @token_keys, do: refute(Map.has_key?(meta, key), "unexpected #{key}")
      # A run without tools answers with its output schema, which has no stop reason.
      refute Map.has_key?(meta, :finish_reason)
    end

    # Through Turn.Server's own :handlers option, not AgentProcess (whose internals 6.5
    # reworks); AgentProcess passes the same handlers to the server.
    test "a custom call_llm handler opens no llm_call span, so the run counts no calls" do
      {_name, config} = agent(%StubClient{}, %{toolset: nil})
      TelemetryCapture.attach_span([@run_stop], session_id: "s-run-totals-custom")

      call_llm = fn _config, _state, _request ->
        %ToolCallResponse{content: "ok", tool_calls: [], stop_reason: :end_turn}
      end

      srv =
        server(config, "s-run-totals-custom",
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      assert {:ok, _} = Server.run(srv, "go")

      assert_received {:span, @run_stop, meta}

      assert %{llm_calls: 0, iterations: 0, stop_reason: :completed, finish_reason: "end_turn"} =
               meta

      for key <- @token_keys, do: refute(Map.has_key?(meta, key), "unexpected #{key}")
    end
  end

  # The accumulator rides the call request; a before_llm hook is handed only the call's
  # info (Normandy.Hooks.Handlers), so it can neither see nor drop request[:run_usage].
  describe "before_llm hooks and the run accumulator" do
    defp hooked(client) do
      agent(client, %{behaviours: %Config{hooks: [{Probe, notify: TestHooks.sink(), tag: :p}]}})
    end

    defp assert_hook_info_only do
      assert_received {:hook, :p, :before_llm, [info, _ctx]}
      assert Map.keys(info) |> Enum.sort() == [:final, :iterations_left]
    end

    test "run/3" do
      {name, config} = hooked(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(config, "go")

      assert_hook_info_only()
      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "stream/3" do
      {name, config} = hooked(streamed_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(config, "go", fn _event -> :ok end)

      assert_hook_info_only()
      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "Turn.Server" do
      {_name, config} = hooked(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], session_id: "s-run-totals-hooked")
      srv = server(config, "s-run-totals-hooked")

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")

      assert_hook_info_only()
      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end
  end

  describe "llm_call :stop usage (TEL-10)" do
    test "a call whose provider reports no usage has no :usage key" do
      {name, config} =
        agent(%StubClient{reply: fn rm -> Map.put(rm, :chat_message, "hi") end}, %{toolset: nil})

      TelemetryCapture.attach_span([[:normandy, :agent, :llm_call, :stop]], agent_name: name)

      assert {:ok, _config, _output} = BaseAgent.run(config, "go")

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], meta}
      refute Map.has_key?(meta, :usage)
    end
  end

  describe "get_response/2 (TEL-11)" do
    test "is one llm_call span with no iteration, its requests numbered under it" do
      {name, config} = agent(WireScript.client([{:json, [@done], "end_turn"}]), %{toolset: nil})

      TelemetryCapture.attach_span(
        [
          [:normandy, :agent, :llm_call, :start],
          [:normandy, :agent, :llm_call, :stop],
          @run_stop
        ],
        agent_name: name
      )

      _response = BaseAgent.get_response(config)

      assert_received {:span, [:normandy, :agent, :llm_call, :start], start}
      refute Map.has_key?(start, :iteration)
      assert %{stream: false, model: "claude-opus-5-5"} = start

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], stop}
      assert %{attempts: 1, input_tokens: 1, output_tokens: 1} = stop
      refute_received {:span, @run_stop, _}
    end
  end
end
```

(Probed on `d624fbf`: WireScript's JSON reply and its SSE `message/3` each give the llm_call stop
`input_tokens: 1, output_tokens: 1`, so two calls total 2 and 2 on all three paths.)

In `test/context/summarizer_test.exs`, `describe "telemetry"`, insert before
`test "a failed summary call ends the span with the LLMError", %{name: name} do`:

```elixir
    test "a summary call whose provider reports no usage has no :usage key", %{name: name} do
      agent =
        named_agent(name, fn rm ->
          {:ok, %Normandy.LLM.Response{content: %{rm | chat_message: "summary"}}}
        end)

      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert {:ok, "summary"} = Summarizer.summarize_messages(agent.client, agent, messages)

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], stop}
      refute Map.has_key?(stop, :usage)
    end

```

In `test/agents/base_agent_logging_test.exs`, test "emits structured lifecycle logs for agent, llm, and tool spans",
after `assert Enum.count(messages, &(&1 == "normandy llm call stop")) == 2` add:

```elixir

    # One tool round: the run stop line counts rounds, as the run :stop telemetry does.
    run_stop = Enum.find(events, &(logger_message(&1) == "normandy agent run stop"))
    assert run_stop.meta.iterations == 1
```

(Today the line logs `completed_iterations/1`, the assistant messages of the last turn: 2 here.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/telemetry/run_usage_test.exs test/telemetry/run_totals_test.exs test/context/summarizer_test.exs test/agents/base_agent_logging_test.exs`
Expected: FAIL, 16 failures: `run_usage_test.exs` 4 (`UndefinedFunctionError ... Normandy.Telemetry.RunUsage.new/0
(module ... is not available)`); `run_totals_test.exs` 10 (no `llm_calls` in any run stop, the three
"before_llm hooks and the run accumulator" tests on the same totals assertion after their hook check passes, `usage: nil` present,
`get_response/2` emits no llm_call; probed on `d624fbf`); the summarizer test on `refute Map.has_key?(stop, :usage)`;
the logging test on `run_stop.meta.iterations == 1` (left: 2).

- [ ] **Step 3: `RunUsage`, `Usage.put_raw/2`, `Metadata.run_stop/2`**

Create `lib/normandy/telemetry/run_usage.ex`:

```elixir
defmodule Normandy.Telemetry.RunUsage do
  @moduledoc false
  # A run's totals over its llm_call spans, for the run :stop metadata (see "Run totals"
  # in Normandy.Telemetry). The value is an explicit :counters array carried on the
  # transient call request as request[:run_usage], never process state and never
  # persisted: Turn.Server makes each LLM call in a fresh worker process, and the turn
  # state it persists must not change shape. A call request without the key (a custom
  # shell) adds nothing (add/2 takes nil).
  #
  # Only llm_call spans that reach :stop are counted: a failed call adds nothing, and a
  # summary call (compaction, Normandy.Context.Summarizer) is not counted, since it is
  # made without the request.

  @token_keys [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens]
  @token_count length(@token_keys)

  # Slot 1 counts calls; slots 2..5 hold the token totals in @token_keys order, slots
  # 6..9 a 1 once some call reported that count.
  @llm_calls 1
  @totals Enum.with_index(@token_keys, 2)
  @reported Enum.with_index(@token_keys, 2 + @token_count)

  @type t :: :counters.counters_ref()

  @spec new() :: t()
  def new, do: :counters.new(1 + 2 * @token_count, [])

  # Adds one finished llm_call: its stop metadata's normalized counts
  # (Normandy.Telemetry.Usage keys), each only when present.
  @spec add(t() | nil, map()) :: :ok
  def add(nil, _stop_metadata), do: :ok

  def add(ref, stop_metadata) when is_map(stop_metadata) do
    :counters.add(ref, @llm_calls, 1)

    for {{key, total}, {key, reported}} <- Enum.zip(@totals, @reported),
        count = Map.get(stop_metadata, key),
        is_integer(count) do
      :counters.add(ref, total, count)
      :counters.put(ref, reported, 1)
    end

    :ok
  end

  # %{llm_calls: n} plus each token total some call reported.
  @spec stop_metadata(t()) :: map()
  def stop_metadata(ref) do
    for {{key, total}, {key, reported}} <- Enum.zip(@totals, @reported),
        :counters.get(ref, reported) == 1,
        into: %{llm_calls: :counters.get(ref, @llm_calls)},
        do: {key, :counters.get(ref, total)}
  end
end
```

In `lib/normandy/telemetry/usage.ex`, before `defp sources(usage) do`, add:

```elixir
  @doc """
  Puts the raw provider `usage` under `:usage` in `metadata` when it is a non-empty map,
  and returns `metadata` unchanged otherwise, so a call whose provider reported no usage
  has no `:usage` key (never `usage: nil`).

  ## Examples

      iex> Normandy.Telemetry.Usage.put_raw(%{}, %{input_tokens: 3})
      %{usage: %{input_tokens: 3}}

      iex> Normandy.Telemetry.Usage.put_raw(%{}, nil)
      %{}
  """
  @spec put_raw(map(), term()) :: map()
  def put_raw(metadata, usage) when is_map(usage) and map_size(usage) > 0,
    do: Map.put(metadata, :usage, usage)

  def put_raw(metadata, _usage), do: metadata

```

(Its two doctests run through the existing `doctest Usage` in `test/telemetry/usage_test.exs:6`.)

In `lib/normandy/telemetry/metadata.ex`, add `alias Normandy.Agents.Turn` before `alias Normandy.Components.AgentMemory`
and `alias Normandy.Telemetry.RunUsage` after `alias Normandy.Telemetry.Provider`; after `run/2` add:

```elixir
  @doc """
  The keys a finished run's `:stop` adds (see "Run totals" in `Normandy.Telemetry`), from
  the turn's final state and the run's usage accumulator (internal):
  `llm_calls` and the token totals some call reported, `iterations` (tool rounds and
  pause continuations completed), `stop_reason` (`:completed | :max_iterations`) and
  `finish_reason` (the last response's stop reason as a string, when it has one).
  """
  @spec run_stop(Turn.State.t(), :counters.counters_ref()) :: map()
  def run_stop(%Turn.State{} = state, run_usage) do
    run_usage
    |> RunUsage.stop_metadata()
    |> Map.merge(%{
      iterations: state.max_iterations - state.iterations_left,
      stop_reason: state.stop_reason,
      finish_reason: finish_reason(state.last_response)
    })
    |> reject_nil()
  end

  # A response map's stop reason as a string (the llm_call finish_reason form); a run
  # without tools answers with its output schema struct, which has none.
  defp finish_reason(%{stop_reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp finish_reason(%{stop_reason: reason}) when is_binary(reason), do: reason
  defp finish_reason(_response), do: nil
```

The doc names no hidden module in backticks and the spec uses `:counters.counters_ref()`, not `RunUsage.t()`:
`mix docs --warnings-as-errors` rejects a reference to a `@moduledoc false` module.

- [ ] **Step 4: BaseAgent carries the accumulator and reports the totals**

All in `lib/normandy/agents/base_agent.ex` (after Task 6.1b, whose request-building changes do not touch these
lines). Add `alias Normandy.Telemetry.RunUsage` after `alias Normandy.Telemetry.Request`.

a. `get_response/2`: replace

```elixir
  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(%BaseAgentConfig{} = config, response_model \\ nil) do
    {response, _usage, _meta} = get_response_with_usage(config, response_model)
    response
  end
```

by

```elixir
  @doc """
  Makes one LLM request with the agent's prompt, tools and memory, outside any run, and
  returns the response parsed into `response_model` (default: the output schema). It is
  an `[:normandy, :agent, :llm_call]` span with no `iteration` and no run around it.
  """
  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(%BaseAgentConfig{} = config, response_model \\ nil) do
    llm_metadata =
      %{model: config.model, agent_name: config.name}
      |> Map.merge(Metadata.ids(config))
      |> Map.merge(
        Provider.request_metadata(config,
          stream: false,
          response_model: response_model || Map.get(config, :output_schema),
          output_format: request_output_format(response_model, config),
          tools?: has_tools?(config)
        )
      )

    with_llm_call_span(config, llm_metadata, nil, fn ->
      tracker = request_tracker(config)

      {response, usage, meta} =
        get_response_with_usage(config, response_model, request_tracker: tracker)

      {response, llm_stop_metadata(llm_metadata, usage, meta, tracker)}
    end)
  end
```

b. `get_response_with_usage/3`: its last parameter `extra_opts \\ []` becomes `extra_opts` (every caller now passes
it; the compiler warns about an unused default otherwise), and

```elixir
    # Numbers the provider requests of this call (get_response/2 has no llm_call
    # span to create one).
    tracker = Keyword.get_lazy(extra_opts, :request_tracker, fn -> request_tracker(config) end)
```

becomes

```elixir
    # Numbers the provider requests of this call; every caller passes the tracker of
    # its llm_call span.
    tracker = Keyword.fetch!(extra_opts, :request_tracker)
```

c. `run!/3`: replace

```elixir
    # run_turn/2 runs the tool loop when the agent has tools (turn_response_model/1).
    with_agent_run_span(config, metadata, fn ->
      {run_turn(config, user_input), metadata}
    end)
```

by

```elixir
    # run_turn/3 runs the tool loop when the agent has tools (turn_response_model/1).
    with_agent_run_span(config, metadata, fn ->
      run_usage = RunUsage.new()
      {result, final_state} = run_turn(config, user_input, run_usage)
      {result, Map.merge(metadata, Metadata.run_stop(final_state, run_usage))}
    end)
```

d. `stream/3`: replace `{run_stream_turn(config, user_input, callback), metadata}` by

```elixir
        run_usage = RunUsage.new()
        {result, final_state} = run_stream_turn(config, user_input, callback, run_usage)
        {result, Map.merge(metadata, Metadata.run_stop(final_state, run_usage))}
```

e. `run_turn/2` becomes `run_turn/3`:

```elixir
  @spec run_turn(BaseAgentConfig.t(), struct() | map() | nil, RunUsage.t()) ::
          {{BaseAgentConfig.t(), struct()}, Turn.State.t()}
  defp run_turn(config, user_input, run_usage) do
```

and its last two lines `{config, final_state} = drive_turn(config, state)` / `{config, final_state.final_response}`
become

```elixir
    {config, final_state} = drive_turn(config, state, run_usage)
    {{config, final_state.final_response}, final_state}
```

f. Replace `drive_turn/2`:

```elixir
  defp drive_turn(%BaseAgentConfig{} = config, %Turn.State{} = state) do
    Driver.drive(state, HookHandlers.wrap(non_streaming_handlers(), config), config)
  end
```

by

```elixir
  defp drive_turn(%BaseAgentConfig{} = config, %Turn.State{} = state, run_usage) do
    handlers = non_streaming_handlers() |> with_run_usage(run_usage) |> HookHandlers.wrap(config)
    Driver.drive(state, handlers, config)
  end

  # Puts the run's usage accumulator on every call request, where with_llm_call_span/4
  # finds it (Normandy.Telemetry.RunUsage).
  defp with_run_usage(%Driver.Handlers{call_llm: call_llm} = handlers, run_usage) do
    %{
      handlers
      | call_llm: fn config, state, request ->
          call_llm.(config, state, Map.put(request, :run_usage, run_usage))
        end
    }
  end
```

g. `call_turn_llm/3`: `with_llm_call_span(config, llm_metadata, fn ->` becomes
`with_llm_call_span(config, llm_metadata, Map.get(request, :run_usage), fn ->`, and its stop metadata

```elixir
      meta =
        llm_metadata
        |> Map.merge(%{
          has_tool_calls: tool_calls != [],
          tool_call_count: length(tool_calls),
          usage: usage
        })
        |> Map.merge(
          Map.take(response_meta, [
            :served_by,
            :input_transformations,
            :response_id,
            :finish_reason
          ])
          |> normalize_finish_reason()
        )
        |> Map.merge(Request.summary(tracker))

      {r, meta}
    end)
  end
```

becomes

```elixir
      meta =
        llm_metadata
        |> Map.merge(%{has_tool_calls: tool_calls != [], tool_call_count: length(tool_calls)})
        |> llm_stop_metadata(usage, response_meta, tracker)

      {r, meta}
    end)
  end

  # The stop keys a non-streaming llm_call adds from its response: the raw usage when
  # the provider reported some, the response meta Normandy reports, the request summary.
  defp llm_stop_metadata(metadata, usage, response_meta, tracker) do
    metadata
    |> Usage.put_raw(usage)
    |> Map.merge(
      response_meta
      |> Map.take([:served_by, :input_transformations, :response_id, :finish_reason])
      |> normalize_finish_reason()
    )
    |> Map.merge(Request.summary(tracker))
  end
```

h. `run_stream_turn/3` becomes `defp run_stream_turn(config, user_input, callback, run_usage) when
is_function(callback, 1) do`, and its end

```elixir
    {config, final_state} =
      Driver.drive(state, HookHandlers.wrap(streaming_handlers(callback), config), config)

    {config, final_state.final_response}
  end
```

becomes

```elixir
    handlers =
      callback |> streaming_handlers() |> with_run_usage(run_usage) |> HookHandlers.wrap(config)

    {config, final_state} = Driver.drive(state, handlers, config)
    {{config, final_state.final_response}, final_state}
  end
```

i. `call_stream_llm/4`: `with_llm_call_span(config, llm_metadata, fn ->` becomes
`with_llm_call_span(config, llm_metadata, Map.get(turn_request, :run_usage), fn ->`.
`stream_llm_attempt/5`: `|> put_usage(Map.get(final_message, :usage))}` becomes
`|> Usage.put_raw(Map.get(final_message, :usage))}`.

j. `with_agent_run_span/3`: in the "normandy agent run stop" log, `iterations: completed_iterations(result),` becomes
`iterations: Map.get(stop_metadata, :iterations, 0),`.

k. `with_llm_call_span/3` becomes `/4`:

```elixir
  # `run_usage` is the run's Normandy.Telemetry.RunUsage (nil outside a run, as for
  # get_response/2): a call that reaches :stop adds its counts to it.
  defp with_llm_call_span(config, telemetry_metadata, run_usage, fun) do
```

both `iteration: telemetry_metadata.iteration` (start log and `log_metadata`) become
`iteration: Map.get(telemetry_metadata, :iteration)` (a `get_response/2` call has no `:iteration`; dot access would
raise `KeyError`), and after `stop_metadata = merge_normalized_usage(stop_metadata, result)` add
`:ok = RunUsage.add(run_usage, stop_metadata)`.

l. Delete `put_usage/2` (both clauses and its comment) and `completed_iterations/1` (both clauses).
`grep -n "put_usage\|completed_iterations\|with_llm_call_span(config, llm_metadata, fn" lib/normandy/agents/base_agent.ex`
→ 0 hits; `grep -c "with_llm_call_span(" lib/normandy/agents/base_agent.ex` → 4 (def + 3 calls).

- [ ] **Step 5: Turn.Server and the Summarizer**

In `lib/normandy/agents/turn/server.ex` (after 6.4a): add `alias Normandy.Telemetry.RunUsage` after
`alias Normandy.Telemetry.OtelCtx`. In `start_run_span/4` the last line `%{start: start, meta: meta}` becomes
`%{start: start, meta: meta, usage: RunUsage.new()}`. In `interpret/2`:

```elixir
      {:call_llm, request} ->
        spawn_task(data, :llm, &call_llm_event(&1, &2, request))
```

becomes

```elixir
      {:call_llm, request} ->
        request = Map.put(request, :run_usage, run_usage(data))
        spawn_task(data, :llm, &call_llm_event(&1, &2, request))
```

(whatever 6.2e did to `spawn_task/3`, the `request` it closes over is this one), and in the `{:finalize, value}`
clause `stop_run_span(data, :stop, %{})` becomes `stop_run_span(data, :stop, run_stop_metadata(data))`. Before
`release_turn_ctx/1` add:

```elixir
  # The run's usage accumulator (Normandy.Telemetry.RunUsage), put on each call request.
  # run_span is nil only outside a turn, where no call is made; nil adds nothing.
  defp run_usage(%Data{run_span: %{usage: usage}}), do: usage
  defp run_usage(%Data{run_span: nil}), do: nil

  # The run totals a finished turn's run :stop adds (Metadata.run_stop/2).
  defp run_stop_metadata(%Data{run_span: %{usage: usage}, turn_state: state}),
    do: Metadata.run_stop(state, usage)

  defp run_stop_metadata(%Data{run_span: nil}), do: %{}
```

The `:counters` reference works across the worker process (same node); it is never persisted (the call request is
not part of `Turn.State`).

In `lib/normandy/context/summarizer.ex`, `llm_call_span/3`: `|> Map.put(:usage, usage)` becomes
`|> Usage.put_raw(usage)`.

- [ ] **Step 6: Catalogue**

In `lib/normandy/telemetry.ex`, run span section, replace
`    * Stop metadata: the start keys, plus `turn_id` from the finished run.` by

```
    * Stop metadata: the start keys, plus `turn_id` from the finished run and the run
      totals (see "Run totals" below): `llm_calls`, `input_tokens`, `output_tokens`,
      `cache_read_input_tokens`, `cache_write_input_tokens` (each token total only when
      some call reported it), `iterations`, `stop_reason` and `finish_reason`.
```

After `  A run `:exception` may be synthetic: see "Killed runs".` add:

```

  #### Run totals

  A run's `:stop` sums the llm_call spans of that run that reached `:stop`:

    * `llm_calls` - how many there were (always present).
    * `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
      `cache_write_input_tokens` - the sums of those calls' normalized counts, each only
      when some call reported it.
    * `iterations` - the tool rounds the turn completed (a `pause_turn` continuation
      counts as one); `0` for an answer with no tool call.
    * `stop_reason` - `:completed`, or `:max_iterations` when the answer came from the
      final call after `max_tool_iterations` rounds.
    * `finish_reason` - the provider's stop reason of the last response, as a string
      (`"end_turn"`); absent when that response carries none (a run without tools gets
      its answer as the output schema, which has no stop reason).

  Not counted: a failed llm_call, compaction's summary calls (their own llm_call spans
  carry `purpose: :summary`; add them from those), and calls a custom `call_llm` handler
  (`Turn.Server`'s or `AgentProcess`'s `:handlers`) makes without an llm_call span, which
  gives `llm_calls: 0`. A resumed durable turn's run counts the calls made after the
  resume. A run that ends in `:exception` carries no totals.
```

In the llm_call section replace

```
  `Normandy.Context.Summarizer` emits one per summary request too (compaction runs it
  inside the run), so a run's token totals include its summaries.
```

by

```
  `Normandy.Context.Summarizer` emits one per summary request too (compaction runs it
  inside the run); the run's own totals leave summaries out (see "Run totals").
  `BaseAgent.get_response/2` emits one, outside any run.
```

`    * Start metadata: `model`, `iteration` (1-based; absent on a summary call),` becomes

```
    * Start metadata: `model`, `iteration` (1-based; absent on a summary call and on
      `get_response/2`),
```

and `      `usage`, the raw provider usage map, exactly as reported;` becomes

```
      `usage`, the raw provider usage map, exactly as reported (absent when the provider
      reported none, never `nil`);
```

In the mapping table, replace the five rows from `gen_ai.response.finish_reasons` to
`gen_ai.usage.cache_write.input_tokens` by:

```
  | `gen_ai.response.finish_reasons` | llm_call, request and run stop `finish_reason`, as a one-element list |
  | `gen_ai.usage.input_tokens` | llm_call, request and run stop `input_tokens` (on run, the run total) |
  | `gen_ai.usage.output_tokens` | llm_call, request and run stop `output_tokens` |
  | `gen_ai.usage.cache_read.input_tokens` | llm_call, request and run stop `cache_read_input_tokens` |
  | `gen_ai.usage.cache_write.input_tokens` | llm_call, request and run stop `cache_write_input_tokens` |
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/telemetry test/context/summarizer_test.exs test/agents test/coordination`
Expected: PASS (`run_totals_test.exs` 10 tests, `run_usage_test.exs` 4).

- [ ] **Step 8: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.4b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.4b.log` and
`mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0 (probed: the hidden-module rule above is the one docs trap).

- [ ] **Step 9: MIGRATING-2.0.md**

Append to `## 41. Telemetry and logs`:

```markdown
- `[:normandy, :agent, :llm_call, :stop]` no longer carries `usage: nil` when the provider
  reported no usage (non-streaming and summary calls); the key is absent, as it already was
  for streams. Read it with `Map.get(meta, :usage)`.
- The `normandy agent run stop` log line's `iterations` now counts the tool rounds the turn
  completed (the run `:stop`'s `iterations`), not the assistant messages of the last turn: a
  one-round tool turn logs `1`, not `2`.
- `BaseAgent.get_response/2` now emits an `[:normandy, :agent, :llm_call]` span (no
  `iteration`, no run around it).
```

Append to `## New, non-breaking`:

```markdown
- `[:normandy, :agent, :run, :stop]` carries the run's totals: `llm_calls`, `input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens` (each only when a
  call reported it), `iterations`, `stop_reason` and `finish_reason` (see "Run totals" in the
  `Normandy.Telemetry` catalogue). Compaction summary calls are not in the totals.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/telemetry/run_usage.ex lib/normandy/telemetry/usage.ex \
  lib/normandy/telemetry/metadata.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/agents/turn/server.ex lib/normandy/context/summarizer.ex lib/normandy/telemetry.ex \
  MIGRATING-2.0.md test/telemetry/run_usage_test.exs test/telemetry/run_totals_test.exs \
  test/context/summarizer_test.exs test/agents/base_agent_logging_test.exs
git commit -m "feat(telemetry): run stop carries the run's llm calls, tokens, iterations and finish reason"
```

---

### Task 6.4c: Logs and errors carry no values: lifecycle logs at `:debug`, contract errors by shape, store and credential reasons by tag (TEL-8, TEL-4 residual, TEL-5, Wave 5 items 1 and 2)

Four leftovers of decision 6 and one log-volume fix, all small. (1) TEL-8: BaseAgent's six lifecycle lines, Batch's
four and Retry's "succeeded" line log at `:info`; they move to `:debug` (R9). The `on_violation: :warn` output
guardrail writes to stderr with `IO.warn` (`output_violation/2`, TEL-4 residual); it becomes `Logger.warning` (R9).
(2) TEL-5: `Runner.contract!/3` and `Guardrails.run/3` put `inspect` of a hook's or guard's bad return into the
`ArgumentError` message, which reaches the caller (`run!/3` raises it; `Turn.Server` replies it as the
`:handler_crashed` reason). A new `Describe.shape/1` names atoms and the shapes of tuples only (R9 / 6.4 Q9).
(3) Wave 5 item 1: `Memory.Commands.backend/1` logs the whole store reason (a `Postgrex.Error` carries the SQL and
row values) and shows the model up to 200 inspected chars; both now get one safe text (R9 / 6.4 Q7 B). (4) Wave 5
item 2: `Turn.Server.reconstruct_config/2` keeps a credential provider's raw reason in the reply; it is reduced to
its tag term (R9 / 6.4 Q8 B), with 6.2a's describer. This task also lands Review Focus #5's test.

**Files:**
- Modify: `lib/normandy/components/content_block/describe.ex` (`shape/1`; `reason_term/1` is 6.2a's, reused as is)
- Modify: `lib/normandy/hooks/runner.ex` (`contract!/3`)
- Modify: `lib/normandy/guardrails.ex` (`run/3`'s bad-return raise)
- Modify: `lib/normandy/tools/memory/commands.ex` (`backend/1`; `reason_text/1` → `safe_reason/1`, `plain_term?/1`)
- Modify: `lib/normandy/agents/turn/server.ex` (`reconstruct_config/2`)
- Modify: `lib/normandy/agents/base_agent.ex` (six `log_lifecycle(:info, ...)`; `output_violation(:warn, _)`)
- Modify: `lib/normandy/batch/processor.ex`, `lib/normandy/resilience/retry.ex` (`Logger.info` → `Logger.debug`)
- Modify: `MIGRATING-2.0.md` (`## 41.`)
- Test: `test/hooks/runner_test.exs`, `test/guardrails/guardrails_test.exs`, `test/tools/memory_test.exs`, `test/agents/turn/server_test.exs`, `test/agents/base_agent_usage_telemetry_test.exs`, `test/agents/base_agent_served_by_test.exs`, `test/agents/base_agent_guardrails_test.exs`, `test/telemetry/span_hierarchy_test.exs`

**Interfaces:**
- Consumes (from 6.2a): `Normandy.Components.ContentBlock.Describe.reason_term/1 :: term()`, the session-store
  load-reason describer of ruling R5: atoms and integers kept, tuples walked element by element, an exception →
  its module (a `Postgrex.Error` with a SQLSTATE → `{Postgrex.Error, code}`), anything else → `type_of/1`'s
  string. So `{:http_error, %{...}}` becomes `{:http_error, "a map"}` (not `:http_error`). (Preflight X2: it
  exists on the stacked tree; 6.3e's `Session.delete/1` uses it too.) From 6.4a: `Normandy.Test.Hooks.PromptOnly`, `start_hooked_turn_server/2`.
- Produces: `Describe.shape(term()) :: String.t()` (`@moduledoc false` module; for contract errors).

Tagged suites: `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` (after
`docker start normandy-test-pg`; the memory store text changes on the Postgres backend's error path) and
`mix test --only distributed --include postgres` with the same env (the credential change is on the Turn.Server load path that Horde restarts use).

- [ ] **Step 1: Write the failing tests**

`test/hooks/runner_test.exs`, `describe "return contract"`, test "a consumed value outside the contract raises
ArgumentError even under :open": replace

```elixir
      assert_raise ArgumentError, ~r/got: \{:inject, "not a list"\}/, fn ->
        Runner.after_compact(
          config([probe(:a, returns: [after_compact: {:inject, "not a list"}])]),
          [],
          %{}
        )
      end
```

by

```elixir
      error =
        assert_raise ArgumentError, fn ->
          Runner.after_compact(
            config([probe(:a, returns: [after_compact: {:inject, "not a list"}])]),
            [],
            %{}
          )
        end

      assert error.message =~ "got: {:inject, a string (10 bytes)}"
      refute error.message =~ "not a list"
```

(The `~r/... got: :yes/` assertion above it stays: an atom is shown in full.)

`test/guardrails/guardrails_test.exs`: before `defmodule ReturnsGarbage do` add

```elixir
  defmodule ReturnsSecret do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, _opts), do: {:error, "SECRET-in-return"}
  end

```

and before `test "raises on malformed guard return" do` add

```elixir
    test "a malformed guard return is described by its shape, not its contents" do
      error =
        assert_raise ArgumentError, fn -> Guardrails.run([ReturnsSecret], "x") end

      assert error.message =~ "got: {:error, a string (16 bytes)}"
      refute error.message =~ "SECRET"
    end

```

`test/tools/memory_test.exs`, `describe "deferred batch B"`. Replace the test "backend text for an exception struct
names only the module, and logs the whole reason" (it pins the leak: `assert log =~ "SELECT secret FROM keys"`) by:

```elixir
    test "backend text for an exception struct names only the module, in the log too" do
      reason = %RuntimeError{message: "SELECT secret FROM keys WHERE id = 7"}
      t = Memory.new(store: {RawErrorStore, reason})

      log =
        capture_log(fn ->
          assert {:error, :backend, "Error: memory store unavailable: RuntimeError"} =
                   typed(t, %{"command" => "view", "path" => "/memories/a"})
        end)

      assert log =~ "memory store failure: RuntimeError"
      refute log =~ "SELECT"
    end

    @tag :capture_log
    test "a Postgrex.Error is its module and SQLSTATE name, never its query or detail" do
      reason = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          detail: "Key (path)=(/memories/secret-doc) already exists."
        },
        query: "INSERT INTO normandy_memory_documents VALUES ('secret-content')"
      }

      t = Memory.new(store: {RawErrorStore, reason})

      log =
        capture_log(fn ->
          assert {:error, :backend,
                  "Error: memory store unavailable: Postgrex.Error (:unique_violation)"} =
                   typed(t, %{"command" => "view", "path" => "/memories/a"})
        end)

      refute log =~ "secret"
      refute log =~ "INSERT"
    end
```

and in the test "a long reason is cut at 200 characters plus an ellipsis; short ones are unchanged" replace its
head and body up to the second `capture_log(fn ->` and its `for` line:

```elixir
    test "a long reason is cut at 200 characters plus an ellipsis; short ones are unchanged" do
      long = String.duplicate("x", 500)
      t = Memory.new(store: {RawErrorStore, long})

      log =
        capture_log(fn ->
          assert {:error, :backend, "Error: memory store unavailable: " <> text} =
                   typed(t, %{"command" => "view", "path" => "/memories/a"})

          assert String.length(text) == 201
          assert String.ends_with?(text, "…")
          assert text == String.slice(inspect(long), 0, 200) <> "…"
        end)

      assert log =~ long

      capture_log(fn ->
        for {reason, text} <- [{:timeout, ":timeout"}, {{:exit, :noproc}, "{:exit, :noproc}"}] do
```

by

```elixir
    test "a reason with data is its tag; a reason of atoms and integers is shown whole" do
      long = String.duplicate("x", 500)

      log =
        capture_log(fn ->
          for {reason, text} <- [
                {long, "a string (500 bytes)"},
                {{:http_error, %{"token" => "sk-secret"}}, ":http_error"},
                {%{password: "pw"}, "a map"}
              ] do
            t = Memory.new(store: {RawErrorStore, reason})

            assert {:error, :backend, "Error: memory store unavailable: " <> ^text} =
                     typed(t, %{"command" => "view", "path" => "/memories/a"})
          end
        end)

      refute log =~ "xxxxx"
      refute log =~ "sk-secret"
      refute log =~ "pw"

      capture_log(fn ->
        for {reason, text} <- [
              {:timeout, ":timeout"},
              {{:exit, :noproc}, "{:exit, :noproc}"},
              {{:namespace_full, :bytes, 10}, "{:namespace_full, :bytes, 10}"}
            ] do
```

(the rest of that loop is unchanged). The `:timeout` texts at `memory_test.exs:458, 492, 504, 700, 1105` and the
`"{:exit, :noproc}"` / `"ArgumentError"` texts of "a store that exits or raises is reported as unavailable with
error_type :backend" stay as they are.

`test/agents/turn/server_test.exs`, `describe "a thin start that cannot rebuild its config"`: after
`defmodule FailingCreds do ... end` add

```elixir

    defmodule LeakyCreds do
      @behaviour Normandy.Behaviours.CredentialProvider
      @impl true
      def get_token(_provider, _opts),
        do: {:error, {:http_error, %{"token" => "SECRET-vault-token", "status" => 403}}}
    end
```

and after the test "a credential provider that fails is run/2's error, not a crash" (which stays:
`:vault_sealed` is an atom and is its own tag) add

```elixir

    test "a credential provider's reason reaches the reply and the log as its tag only" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, srv} = thin_start(LeakyCreds, true)

          assert {:error,
                  %TurnError{
                    type: :session_unavailable,
                    reason: {:credential_unavailable, LeakyCreds, {:http_error, "a map"}}
                  } = error} = Turn.Server.run(srv, "hello")

          refute inspect(error, limit: :infinity) =~ "SECRET"
          refute Exception.message(error) =~ "SECRET"
        end)

      refute log =~ "SECRET"
    end
```

(6.2a's `reason_term/1` walks the tuple: the map becomes `"a map"`, the tag stays. After 6.2b the load runs after
`start_link/1` returns; `run/2` reaches the server after it, so the reply is the
`:unavailable` one either way.)

`test/agents/base_agent_usage_telemetry_test.exs`: the module comment `# async: false — one test sets the global
Logger level to :info.` becomes `... to :debug.`; in `run_and_capture_stop/2`
`ExUnit.CaptureLog.capture_log([metadata: [:input_tokens, :output_tokens]], fn ->` becomes
`ExUnit.CaptureLog.capture_log([level: :debug, metadata: [:input_tokens, :output_tokens]], fn ->`; in the test "the
llm call stop log line carries the normalized token counts" `Logger.configure(level: :info)` becomes
`Logger.configure(level: :debug)`; and before that test add:

```elixir
  # The global level is set to :debug so an :info line would be captured: the refutes
  # cannot pass because the logger dropped everything.
  test "lifecycle lines are :debug: nothing is logged at :info for a run" do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    agent =
      BaseAgent.init(%{client: stub_client(nil), model: "claude-opus-5-5", temperature: nil})

    log = ExUnit.CaptureLog.capture_log([level: :info], fn -> BaseAgent.run!(agent, "hello") end)

    refute log =~ "normandy agent run"
    refute log =~ "normandy llm call"
  end

```

`test/agents/base_agent_served_by_test.exs`: the same three edits (comment `:info` → `:debug`;
`capture_log([metadata: [:served_by]], fn ->` → `capture_log([level: :debug, metadata: [:served_by]], fn ->`;
`Logger.configure(level: :info)` → `Logger.configure(level: :debug)` in "the llm call stop log line carries
served_by").

`test/agents/base_agent_guardrails_test.exs`: the module comment becomes

```elixir
  # async: false — captures the log and refutes on it; another test's warning could
  # land in the same capture.
```

`import ExUnit.CaptureIO` becomes `import ExUnit.CaptureLog`; in "with on_violation :warn it logs a warning and does
not halt"

```elixir
      {output, {_updated, response}} =
        capture_io_and_result(fn ->
          BaseAgent.run!(agent, "hi")
        end)

      assert output =~ "output guardrail violation"
```

becomes

```elixir
      {{_updated, response}, output} = with_log(fn -> BaseAgent.run!(agent, "hi") end)

      assert output =~ "[warning] Agent output guardrail violation"
```

in "passes silently when output satisfies the guard" `capture_io(:stderr, fn ->` becomes `capture_log(fn ->`; in
"on exhausted tool loop max-iterations branch still runs output guardrails"

```elixir
      {output, {updated, _response}} =
        capture_io_and_result(fn ->
          BaseAgent.run!(agent, "anything")
        end)
```

becomes `{{updated, _response}, output} = with_log(fn -> BaseAgent.run!(agent, "anything") end)`; and delete the
private helper `capture_io_and_result/1` with its comment (`# capture_io on :stderr swallows IO.warn output. ...`).
`grep -n "capture_io" test/agents/base_agent_guardrails_test.exs` → 0 hits.

`test/telemetry/span_hierarchy_test.exs`, `describe "Turn.Server hooks outside the run (TEL-3)"` (6.4a), before
`test "after a hooked turn the server holds no caller context" do` add Review Focus #5:

```elixir
    # Review Focus #5.
    test "a malformed on_prompt return carrying a secret: parented, reported, never leaked" do
      secret = "SECRET-#{System.unique_integer([:positive])}"

      srv =
        start_hooked_turn_server(counted_client(false), [
          {Normandy.Test.Hooks.PromptOnly, returns: {:ok, secret}}
        ])

      attach_forward([
        [:normandy, :hook, :exception],
        [:normandy, :agent, :run, :start],
        [:normandy, :agent, :run, :exception]
      ])

      caller = start_caller_span()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error,
                  %Normandy.TurnError{
                    type: :handler_crashed,
                    handler: :admit,
                    reason: %ArgumentError{}
                  } = error} = Turn.Server.run(srv, %{chat_message: "hi"})

          refute inspect(error, limit: :infinity) =~ secret
          refute Exception.message(error.reason) =~ secret
        end)

      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.hook", "normandy.agent.run"])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")
      assert hook.parent_span_id == caller_span.span_id

      assert_received {:telemetry, [:normandy, :agent, :run, :exception], _,
                       %{
                         kind: :error,
                         reason: %Normandy.TurnError{type: :handler_crashed, handler: :admit}
                       } = run_meta, _}

      assert_received {:telemetry, [:normandy, :hook, :exception], _, hook_meta, _}

      refute inspect(run_meta, limit: :infinity) =~ secret
      refute inspect(hook_meta, limit: :infinity) =~ secret
      refute log =~ secret
    end

```

(`attach_forward/1` and `forward_event/4` are defined further down the same module; the forwarded tuple is
`{:telemetry, event, measurements, metadata, current_span_ctx}`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/hooks/runner_test.exs test/guardrails/guardrails_test.exs test/tools/memory_test.exs test/agents/turn/server_test.exs test/agents/base_agent_usage_telemetry_test.exs test/agents/base_agent_served_by_test.exs test/agents/base_agent_guardrails_test.exs test/telemetry/span_hierarchy_test.exs`
Expected: FAIL, `259 tests, 10 failures` (stacked on 6.4b): runner (`error.message =~ "got: {:inject, a string (10 bytes)}"`), guardrails
(`got: {:error, a string (16 bytes)}`), memory ×3 (the exception, Postgrex and tag tests), server_test (reason is
`{:credential_unavailable, LeakyCreds, {:http_error, %{...}}}`), usage telemetry ("lifecycle lines are :debug":
`log =~ "normandy agent run"`), guardrails agent tests ×2 (`with_log` captures nothing: the warning still goes to
stderr), span hierarchy (`refute inspect(error, limit: :infinity) =~ secret`). The served_by edits pass both before
and after (they only widen the capture).

- [ ] **Step 3: `Describe.shape/1`**

In `lib/normandy/components/content_block/describe.ex`, at the end of the module add:

```elixir

  # A value returned against a contract, for its error message: an atom in full, a
  # tuple as the shapes of its elements, anything else by its type (type_of/1). Never a
  # string's, a map's or a list's contents.
  @spec shape(term()) :: String.t()
  def shape(value) when is_atom(value), do: inspect(value)

  def shape(value) when is_tuple(value),
    do: "{" <> (value |> Tuple.to_list() |> Enum.map_join(", ", &shape/1)) <> "}"

  def shape(value), do: type_of(value)
```

6.2a added `Describe.reason_term/1`; Step 5 uses it as is (preflight X2). Do not add a second definition.

- [ ] **Step 4: Contract errors by shape (TEL-5)**

`lib/normandy/hooks/runner.ex`: add `alias Normandy.Components.ContentBlock.Describe` after
`alias Normandy.Components.AgentMemory.Entry`, and in `contract!/3` replace `got: #{inspect(ret)}"` by
`got: #{Describe.shape(ret)}"`.

`lib/normandy/guardrails.ex` (already aliases `Describe`), `run/3`'s `other ->` branch: replace

```elixir
                "expected #{inspect(mod)}.check/2 to return :ok or {:error, [violation]}, got: #{inspect(other)}"
```

by

```elixir
                "expected #{inspect(mod)}.check/2 to return :ok or {:error, [violation]}, got: #{Describe.shape(other)}"
```

(Only this `got: #{inspect(other)}` of the three in the file: the other two describe an `:on_error` value and a
guard spec, configuration, not a guard's return.)

- [ ] **Step 5: Store and credential reasons by tag (Wave 5 items 1, 2)**

`lib/normandy/tools/memory/commands.ex`: add `alias Normandy.Components.ContentBlock.Describe` after
`alias Normandy.Behaviours.MemoryStore`, and replace everything from `@reason_chars 200` to the end of
`reason_text/1` (the module's last definitions):

```elixir
  @reason_chars 200

  # The model sees a bounded reason: an exception reports its module only (a Postgrex
  # error carries SQL text), anything else is cut. The log keeps the whole reason.
  defp backend(reason) do
    Logger.warning(
      "memory store failure: #{inspect(reason, limit: :infinity, printable_limit: :infinity)}"
    )

    {:error, :backend, "Error: memory store unavailable: " <> reason_text(reason)}
  end

  defp reason_text(%{__exception__: true, __struct__: mod}), do: inspect(mod)
  defp reason_text({:exception, mod}) when is_atom(mod), do: inspect(mod)

  defp reason_text(reason) do
    text = inspect(reason)

    if String.length(text) > @reason_chars,
      do: String.slice(text, 0, @reason_chars) <> "…",
      else: text
  end
```

by

```elixir
  # The log and the model get the same text (decision 6): a store reason can carry SQL
  # text, row values or a backend's options.
  defp backend(reason) do
    text = safe_reason(reason)
    Logger.warning("memory store failure: " <> text)
    {:error, :backend, "Error: memory store unavailable: " <> text}
  end

  # A store reason described without its data. A term built only from atoms and integers
  # (:timeout, {:exit, :noproc}, {:namespace_full, :bytes, 10}) is shown whole. An
  # exception is its module, and a Postgrex.Error adds its SQLSTATE name
  # (postgres.code, e.g. :unique_violation), never its query or detail. Anything else
  # is its tag (Describe.reason_tag/1). Postgrex is optional, so the error is matched
  # as a map.
  defp safe_reason(%{__exception__: true, __struct__: Postgrex.Error, postgres: %{code: code}})
       when is_atom(code) and not is_nil(code),
       do: "Postgrex.Error (#{inspect(code)})"

  defp safe_reason(%{__exception__: true, __struct__: mod}), do: inspect(mod)
  defp safe_reason({:exception, mod}) when is_atom(mod), do: inspect(mod)

  defp safe_reason(reason) do
    if plain_term?(reason), do: inspect(reason), else: Describe.reason_tag(reason)
  end

  defp plain_term?(term) when is_atom(term) or is_integer(term), do: true

  defp plain_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&plain_term?/1)

  defp plain_term?(_term), do: false
```

`grep -c "backend(reason)" lib/normandy/tools/memory/commands.ex` → 13 (12 call sites, unchanged, plus the
`defp backend(reason) do` head).

`lib/normandy/agents/turn/server.ex`, `reconstruct_config/2`'s `else`: replace

```elixir
      {:token, {:error, reason}} -> {:error, {:credential_unavailable, cred_mod, reason}}
```

by

```elixir
      # The provider's reason can hold a token, a vault path or a response body: the
      # reply and the log carry it reduced to its tags (Describe.reason_term/1).
      {:token, {:error, reason}} ->
        {:error, {:credential_unavailable, cred_mod, Describe.reason_term(reason)}}
```

(`describe_reason/1`'s `{:credential_unavailable, mod, reason}` clause stays; `Describe.reason_tag/1` of a tag term
is the same text.)

- [ ] **Step 6: Log levels (TEL-8, TEL-4 residual)**

Mechanical rewrites, with exact counts:
- `lib/normandy/agents/base_agent.ex`: `log_lifecycle(:info, ` → `log_lifecycle(:debug, ` — 6 sites (run start/stop,
  llm call start/stop, tool execute start/stop); afterwards `grep -c "log_lifecycle(:debug" lib/normandy/agents/base_agent.ex` → 8
  (2 were already `:debug`) and `grep -c "log_lifecycle(:info" ...` → 0.
- `lib/normandy/batch/processor.ex`: `Logger.info(` → `Logger.debug(` — 4 sites.
- `lib/normandy/resilience/retry.ex`: `Logger.info("Retry succeeded on attempt #{attempt}")` →
  `Logger.debug("Retry succeeded on attempt #{attempt}")` — 1 site.
- `grep -rn "Logger.info\|log_lifecycle(:info" lib` → 1 hit, `lib/normandy/coordination/reactive.ex:116`, inside a
  moduledoc example (not a call; leave it).

In `base_agent.ex`, `output_violation(:warn, violations)`: `IO.warn(` → `Logger.warning(` (same argument;
`require Logger` is already at the top). `grep -rn "IO.warn" lib` → 1 hit, `behaviours/hooks.ex:91` (a compile-time
warning, correct as is).

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/guardrails test/tools test/agents test/telemetry`
Expected: PASS.

- [ ] **Step 8: Gate and tagged suites**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.4c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.4c.log`,
`mix docs --warnings-as-errors`, `mix test.redis 2>&1 | tail -3`,
`docker start normandy-test-pg && MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tail -3`,
`MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tail -3`
(a bare `--only distributed` fails `eager_handoff_distributed_test.exs`'s setup without Postgres; see 6.3f).
Expected: ` 0 failures` in each; docs exit 0.

- [ ] **Step 9: MIGRATING-2.0.md**

Append to `## 41. Telemetry and logs`:

```markdown
- The lifecycle log lines `normandy agent run start|stop`, `normandy llm call start|stop` and
  `normandy tool execute start|stop`, `Batch.Processor`'s progress lines and `Retry`'s
  "Retry succeeded on attempt N" are now `:debug` (they were `:info`). Set the `Logger` level
  to `:debug` to keep them, or use the telemetry events, which carry the same facts.
- An output guardrail with `on_violation: :warn` now logs `Logger.warning("Agent output
  guardrail violation: ...")` instead of printing with `IO.warn` to stderr. Tests that
  captured it with `capture_io(:stderr, ...)` use `capture_log/1`.
- A hook or guard that returns a value outside its contract still raises `ArgumentError`, but
  the message describes the value's shape instead of showing it: `got: {:inject, a string (10
  bytes)}` instead of `got: {:inject, "not a list"}`. Atoms are still shown (`got: :yes`).
- The memory tool's "memory store unavailable" text, and the `memory store failure` log line,
  show the store reason only when it is made of atoms and integers (`:timeout`,
  `{:exit, :noproc}`); an exception is its module (`Postgrex.Error (:unique_violation)` adds
  the SQLSTATE name), anything else its tag (`:http_error`, `a string (500 bytes)`). The log
  no longer holds the full reason (a `Postgrex.Error`'s SQL and row values), and the
  200-character cut is gone.
- A credential provider's failure reaches `run/2`'s `:session_unavailable` `TurnError` as
  `{:credential_unavailable, provider_module, reason}`, where `reason` is reduced as session
  store load reasons are (`## 39.`): atoms and integers kept, tuples walked, an exception
  its module, any other term its type (`{:http_error, %{"token" => ...}}` becomes
  `{:http_error, "a map"}`); the provider's data (a response body, a token) is dropped. Log
  the detail in the provider if you need it.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/components/content_block/describe.ex lib/normandy/hooks/runner.ex \
  lib/normandy/guardrails.ex lib/normandy/tools/memory/commands.ex \
  lib/normandy/agents/turn/server.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/batch/processor.ex lib/normandy/resilience/retry.ex MIGRATING-2.0.md \
  test/hooks/runner_test.exs test/guardrails/guardrails_test.exs test/tools/memory_test.exs \
  test/agents/turn/server_test.exs test/agents/base_agent_usage_telemetry_test.exs \
  test/agents/base_agent_served_by_test.exs test/agents/base_agent_guardrails_test.exs \
  test/telemetry/span_hierarchy_test.exs
git commit -m "fix(telemetry): lifecycle logs at debug; contract errors, store and credential reasons carry no values"
```

---

### Task 6.4d: Workflow status, inbound baggage dropped, the tool-timeout limit and the memory semconv rows (TEL-9, TEL-13, TEL-14, TEL-15)

Four small items. TEL-13: the `[:normandy, :workflow, :run]` stop has no outcome; every caller of
`WorkflowSpan.span/3` returns `{:ok, _} | {:error, _}` since Wave 2 (`sequential_orchestrator.ex`,
`parallel_orchestrator.ex`, `hierarchical_coordinator.ex`, `dsl/workflow.ex`), so the stop gets `status` from the
result. TEL-15 (R9 / 6.4 Q5): `A2A.Server.handle_message/3,4` extracts the whole carrier with the global propagator,
so a remote caller's `baggage` header becomes baggage in this process (probe P2); only `traceparent` and `tracestate`
are extracted now. Outbound (`AgentTool`) is unchanged. TEL-9: a tool past its timeout is shut down and spans open
in it never end; documented as a known limit, pinned by a test. TEL-14: the catalogue gains the
`gen_ai.operation.name` mapping for memory commands (see Header conflict 2).

**Files:**
- Modify: `lib/normandy/telemetry/workflow_span.ex` (`span/3`, moduledoc, new `status/1`)
- Modify: `lib/normandy/a2a/server.ex` (`trace_ctx/1`, `handle_message/3` doc)
- Modify: `lib/normandy/telemetry.ex` (workflow section, A2A section, mapping table, Known limits)
- Modify: `MIGRATING-2.0.md` (`## 41.`, `## New, non-breaking`)
- Test: `test/telemetry/workflow_span_test.exs`, `test/telemetry/a2a_propagation_test.exs`, `test/tools/executor_test.exs`, `test/telemetry/catalogue_test.exs`

**Interfaces:**
- Consumes: `Normandy.Test.TaggingClient` (`:fail_on`), `Normandy.Test.OtelSpanBridge`, `Normandy.Test.TelemetryCapture` (unchanged).
- Produces: workflow run stop metadata `status: :ok | :error` (header).

Tagged suites: none.

- [ ] **Step 1: Write the failing tests**

`test/telemetry/workflow_span_test.exs`: before `test "ParallelOrchestrator.execute/3 with spec inputs" do` add

```elixir
  describe "stop status (TEL-13)" do
    defp stop_status(spans, orchestrator) do
      assert [{[_, _, _, :stop], stop}] =
               Enum.filter(spans, fn {event, meta} ->
                 List.last(event) == :stop and meta.orchestrator == orchestrator
               end)

      stop.status
    end

    test "is :ok for a run that returns {:ok, _}" do
      spans = workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute(specs(), "x") end)
      assert stop_status(spans, :parallel) == :ok
    end

    test "is :error for a run that returns {:error, _}" do
      failing = %{
        id: "bad",
        agent:
          BaseAgent.init(%{
            client: %TaggingClient{name: "bad", fail_on: "x"},
            model: "test-model"
          })
      }

      spans =
        workflow_spans(fn ->
          assert {:error, %Normandy.OrchestrationError{}} =
                   ParallelOrchestrator.execute([failing], "x")
        end)

      assert stop_status(spans, :parallel) == :error
    end
  end

```

`test/telemetry/a2a_propagation_test.exs`, `describe "A2A.Server.handle_message/3"`: before
`test "accepts atom header names" do` add

```elixir
    test "drops inbound baggage; the request still joins the carrier's trace" do
      test_pid = self()
      id = {__MODULE__, :baggage, make_ref()}

      :ok =
        :telemetry.attach(
          id,
          [:normandy, :agent, :run, :start],
          &__MODULE__.forward_baggage/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(id) end)
      message = Message.new(:user, [Part.text("hi")])

      assert {:ok, _task} =
               Server.handle_message(remote_agent(), message, [
                 {"traceparent", @traceparent},
                 {"Baggage", "user_id=secret42"},
                 {"baggage", "tenant=t1"}
               ])

      assert_received {:baggage_at_run_start, baggage}
      assert baggage == %{}

      spans = OtelSpanBridge.await_spans(["normandy.a2a.request"])
      request = OtelSpanBridge.fetch_span!(spans, "normandy.a2a.request")
      assert request.trace_id == @trace_id
      assert request.parent_span_id == @parent_span_id
    end

```

and before `def handle_request(event, _measurements, metadata, test_pid),` add

```elixir
  # The baggage current where the run starts (the process handle_message/3 runs in).
  def forward_baggage(_event, _measurements, %{agent_name: "remote-agent"}, test_pid),
    do: send(test_pid, {:baggage_at_run_start, :otel_baggage.get_all()})

  def forward_baggage(_event, _measurements, _metadata, _test_pid), do: :ok

```

(The run `:start` fires in the calling process, inside the attach, so the handler sees the extracted context.)

`test/tools/executor_test.exs`: add `alias Normandy.Test.TelemetryCapture` before
`alias Normandy.Tools.{Context, Executor}`, and in `describe "timeout"` before `test "the default is 30 seconds" do`
add

```elixir
    # A tool whose run opens a span and never returns: the span stays open.
    defmodule SpanThenHangTool do
      @moduledoc false
      use Normandy.Tool, name: "span_then_hang", description: "opens a span, then waits"

      alias Normandy.Telemetry.Span

      defstruct marker: nil

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}

      @impl Normandy.Tool
      def run(%__MODULE__{marker: marker}, %Context{}) do
        Span.span([:normandy, :memory, :command], %{command: marker}, fn ->
          receive do
            :never_sent -> {{:ok, "done"}, %{}}
          end
        end)
      end
    end

    # TEL-9, a documented limit ("Known limits" in Normandy.Telemetry): the timed-out
    # tool's process is shut down, so a span open inside it emits no :stop or :exception.
    test "a span open inside a tool past its :timeout never ends" do
      marker = "tel9-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [
          [:normandy, :memory, :command, :start],
          [:normandy, :memory, :command, :stop],
          [:normandy, :memory, :command, :exception]
        ],
        command: marker
      )

      assert {:error, "Tool execution timeout after 50ms"} =
               Executor.execute_tool(%SpanThenHangTool{marker: marker},
                 context: ctx(%{}),
                 timeout: 50
               )

      assert_received {:span, [:normandy, :memory, :command, :start], _}
      # Task.shutdown/1 returned only after the tool's process died, and that process's
      # messages to this one arrive in order before its death is seen, so any end event
      # would already be here.
      refute_received {:span, [:normandy, :memory, :command, :stop], _}
      refute_received {:span, [:normandy, :memory, :command, :exception], _}
    end

```

This pins today's behaviour (it passes before and after); the 50 ms is the tool's timeout, not a wait for ordering.

`test/telemetry/catalogue_test.exs`, `describe "Normandy.Telemetry catalogue"`, add after the last test:

```elixir

    test "the memory command span's semconv operation names are documented (TEL-14)" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Normandy.Telemetry)

      for name <- ~w(search_memory upsert_memory update_memory delete_memory) do
        assert moduledoc =~ "`#{name}`", "missing gen_ai.operation.name #{name}"
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/telemetry/workflow_span_test.exs test/telemetry/a2a_propagation_test.exs test/tools/executor_test.exs test/telemetry/catalogue_test.exs`
Expected: FAIL, `43 tests, 4 failures` (stacked on 6.4c): both "stop status" tests (`stop.status` raises `KeyError`, no `:status` key),
the baggage test (`assert baggage == %{}`, left: `%{"tenant" => {"t1", []}, "user_id" => {"secret42", []}}`), and the catalogue test
(`missing gen_ai.operation.name search_memory`). The executor test passes.

- [ ] **Step 3: Implement**

`lib/normandy/telemetry/workflow_span.ex`: in the moduledoc (the line `` `:step_count`). It never carries ...``
continues after the metadata sentence), replace

```
  `:step_count`). It never carries input, output or message content. Agent runs
  started inside `fun` nest under this span
```

by

```
  `:step_count`). The `:stop` adds `:status`: `:error` when `fun` returned
  `{:error, _}`, `:ok` otherwise (every caller returns `{:ok, _} | {:error, _}`).
  It never carries input, output or message content. Agent runs started inside `fun`
  nest under this span
```

and replace the body of `span/3`

```elixir
    Span.span([:normandy, :workflow, :run], metadata, fn ->
      {fun.(), metadata}
    end)
  end
```

by

```elixir
    Span.span([:normandy, :workflow, :run], metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :status, status(result))}
    end)
  end

  defp status({:error, _reason}), do: :error
  defp status(_result), do: :ok
```

`lib/normandy/a2a/server.ex`: in the `handle_message/3` doc replace

```
  the remote caller's trace. Without one (absent or malformed) the current
  context is left alone.
```

(the second line continues with `` If your HTTP instrumentation ...``; keep that sentence)

by

```
  the remote caller's trace. Only `traceparent` and `tracestate` are read: an inbound
  `baggage` header is dropped, so a remote caller cannot set baggage entries in this
  process's context (they would reach every outbound call that propagates it). Without
  a `traceparent` (absent or malformed) the current context is left alone.
```

and replace `trace_ctx/1`

```elixir
  defp trace_ctx(carrier) do
    if Enum.any?(carrier, fn {name, _} -> String.downcase(name) == "traceparent" end) do
      OtelCtx.extract(carrier)
    end
  end
```

by

```elixir
  # Only the W3C trace-context headers are extracted: inbound baggage is dropped.
  defp trace_ctx(carrier) do
    trace_headers =
      Enum.filter(carrier, fn {name, _} ->
        String.downcase(name) in ["traceparent", "tracestate"]
      end)

    if Enum.any?(trace_headers, fn {name, _} -> String.downcase(name) == "traceparent" end) do
      OtelCtx.extract(trace_headers)
    end
  end
```

(`OtelCtx.extract/1` stays generic: the turn-resume carrier is Normandy's own.)

`lib/normandy/telemetry.ex`:
- Workflow section: after the `Metadata:` bullet (`` `step_count`, and for DSL workflows `workflow_name` (the module).``)
  add

  ```
      * Stop metadata adds `status`: `:error` when the entry point returned
        `{:error, _}`, `:ok` otherwise. A raise ends the span in `:exception`.
  ```

- A2A section: the Parenting bullet gains, after `` `traceparent`, the request span (and the agent run inside it) joins that trace.``,
  the line `      Only `traceparent` and `tracestate` are read; inbound `baggage` is dropped.`
- Mapping table: the `gen_ai.operation.name` row becomes

  ```
  | `gen_ai.operation.name` | derived from the event: `invoke_agent` for run, `chat` for llm_call and request, `execute_tool` for tool execute, `invoke_workflow` for workflow run; for memory command, from `command`: `search_memory` for `"view"`, `upsert_memory` for `"create"` (it writes the file whether or not it exists), `update_memory` for `"str_replace"`, `"insert"` and `"rename"`, `delete_memory` for `"delete"` |
  ```

  and the sentence above the table "Checked against semantic-conventions-genai `main` on 2026-10-03." becomes
  "Checked against semantic-conventions-genai `main` on 2026-10-03 (memory operations on 2026-10-06)."
- Known limits: after `    * Killed runs: see "Killed runs". Inner spans of a killed run stay open.` add

  ```
      * Tool timeouts: a tool that runs past its timeout is shut down. Spans opened inside
        it (a memory command, a sub-agent's run, its llm_calls) never end; the tool span
        ends with `status: :error, error_type: :timeout`.
  ```

  and in the "W3C propagation" bullet, after `` extracts them from the carrier it is
      given.`` (mid-line: the line goes on with `` The injection needs ...``; reflow) add `` The server drops inbound `baggage`; `AgentTool` sends the host's own baggage
      when its propagator is configured to.``

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/telemetry test/tools/executor_test.exs test/coordination test/dsl`
Expected: PASS.

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.4d.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.4d.log` and
`mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. (Credo flags a fully qualified `Normandy.Telemetry.Span` or
`Normandy.Test.TelemetryCapture` inside the executor test's nested module: the aliases above are required.)

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 41. Telemetry and logs`:

```markdown
- `A2A.Server.handle_message/3,4` reads only `traceparent` and `tracestate` from the carrier;
  an inbound `baggage` header is dropped, so a remote caller can no longer set baggage
  entries that your outbound calls would forward. Outbound A2A calls (`AgentTool`) still send
  your own baggage. If you relied on inbound baggage, extract it yourself from the request
  headers.
```

Append to `## New, non-breaking`:

```markdown
- `[:normandy, :workflow, :run, :stop]` carries `status: :ok | :error` (`:error` when the
  orchestrator or workflow returned `{:error, _}`).
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/telemetry/workflow_span.ex lib/normandy/a2a/server.ex lib/normandy/telemetry.ex \
  MIGRATING-2.0.md test/telemetry/workflow_span_test.exs test/telemetry/a2a_propagation_test.exs \
  test/tools/executor_test.exs test/telemetry/catalogue_test.exs
git commit -m "feat(telemetry): workflow stop status; drop inbound A2A baggage; document tool-timeout spans and memory semconv"
```

---

### Task 6.4e: Operational events for an unavailable session, a reaper sweep and a pool checkout (TEL-16)

`Turn.Server`'s `:unavailable` state, `ResumeReaper` and `AgentPool` emit no telemetry today (`grep -c ":telemetry\."`
gives 0 for `resume_reaper.ex` and `agent_pool.ex`; `unavailable_data/2` only logs). The three events of the header,
with the metadata of Header conflict 1. This task runs after 6.2: Turn.Server's load is in the `:loading` state
(6.2b) and still fails through `unavailable_data/2`, and `reap/1` starts sessions concurrently (6.2f), so the sweep's
counts are reduced from what each session's start returned, never from shared mutable counters. Batch gets no event
(R9 / 6.4 Q6; its item runs already emit run spans).

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`unavailable_data/2`; the three `:unavailable` clauses; new `emit_unavailable/3`)
- Modify: `lib/normandy/agents/turn/resume_reaper.ex` (`reap/1`, 6.2f's `reap_session/2`, `not_running?/3` → `registry_check/3`, `non_terminal?/3` → `turn_check/3`, `start_session/2`'s return, new `emit_sweep/4`)
- Modify: `lib/normandy/coordination/agent_pool.ex` (`handle_call({:checkout, ...})`, `handle_info({:checkout_timeout, _})`, `waiter_down/2`, `do_checkin/2`, `handle_agent_death/2`, `serve_waiter/1`, `hand_to_waiter/2` → `/3`, new `emit_checkout/3`)
- Modify: `lib/normandy/telemetry.ex` (three event sections)
- Modify: `MIGRATING-2.0.md` (`## New, non-breaking`)
- Test: create `test/telemetry/operational_events_test.exs`; modify `test/agents/turn/resume_reaper_test.exs` (Step 4g)

**Interfaces:**
- Consumes: from 6.2a, `Describe.reason_term/1` (as in 6.4c); from 6.2b, the `:internal :load` event that calls
  `unavailable_data/2` on a failed load, and `retry_load/1` returning `{:error, reason}` (never raising, R5); from 6.2f,
  `reap/1` running `reap_session/2` per session through `Task.async_stream(..., max_concurrency: @reap_concurrency,
  ordered: false, timeout: :infinity)` with a per-session catch logged by tag; `Normandy.Test.FlakyStore` (as 6.3c
  left it), `Normandy.Test.Eventually.wait_until/1`.
- Produces: events `[:normandy, :turn, :unavailable]`, `[:normandy, :resume_reaper, :sweep]`,
  `[:normandy, :agent_pool, :checkout]` (header, with Header conflict 1's keys).

Tagged suites: `mix test.redis`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres` (after
`docker start normandy-test-pg`) and `mix test --only distributed --include postgres` with the same env (the reaper and the Turn.Server load path; the
eager-handoff distributed tests drive `reap/1`).

- [ ] **Step 1: Write the failing tests**

Create `test/telemetry/operational_events_test.exs`:

```elixir
defmodule Normandy.Telemetry.OperationalEventsTest do
  @moduledoc """
  Task 6.4e (TEL-16): `[:normandy, :turn, :unavailable]`,
  `[:normandy, :resume_reaper, :sweep]` and `[:normandy, :agent_pool, :checkout]`.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Coordination.AgentPool
  alias Normandy.Test.FlakyStore
  alias Normandy.Test.TelemetryCapture
  alias Normandy.TurnError

  describe "[:normandy, :turn, :unavailable]" do
    test "a failed load at start, on a request and on the retry timer, each by its phase" do
      sid = "s-unavailable-#{System.unique_integer([:positive])}"
      ref = TelemetryCapture.attach([[:normandy, :turn, :unavailable]], session_id: sid)
      store = FlakyStore.new()
      FlakyStore.down(store)

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}),
          store: {FlakyStore, store},
          registry: {Native, Native.new()}
        )

      # The load runs after start_link/1 returns (the :loading state), so wait for it.
      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{session_id: ^sid, phase: :start, reason: :store_down}},
                     1_000

      assert {:error, %TurnError{type: :session_unavailable}} = Turn.Server.run(srv, "hi")

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{session_id: ^sid, phase: :request, reason: :store_down}}

      # The first retry fires after the initial backoff (200 ms).
      assert_receive {:telemetry, ^ref, %{count: 1},
                      %{session_id: ^sid, phase: :retry, reason: :store_down}},
                     2_000
    end
  end

  describe "[:normandy, :resume_reaper, :sweep]" do
    defmodule SweepStore do
      @moduledoc false
      alias Normandy.Agents.Turn.State
      def list_resumable(:down), do: {:error, {:store_down, "detail"}}

      def list_resumable(_handle),
        do: {:ok, ["s-start", "s-live", "s-done", "s-fault", "s-refused", "s-raise"]}

      def load_turn_state(_handle, "s-done"), do: {:ok, %State{status: :stopped}}
      def load_turn_state(_handle, "s-fault"), do: {:error, :timeout}
      def load_turn_state(_handle, _sid), do: {:ok, %State{status: :steering}}
    end

    defmodule SweepSup do
      @moduledoc false
      def start_server(_handle, opts) do
        case Keyword.fetch!(opts, :session_id) do
          "s-refused" -> {:error, :refused}
          "s-raise" -> raise ArgumentError, "sup bug"
          _sid -> {:ok, spawn(fn -> :ok end)}
        end
      end
    end

    defp sweep_state(store_handle) do
      reg = Native.new()
      :ok = Native.register(reg, "s-live", self())

      %{
        store: {SweepStore, store_handle},
        registry: {Native, reg},
        supervisor: nil,
        supervisor_mod: SweepSup,
        template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, nil},
        host_server_opts: []
      }
    end

    # s-start starts; s-live (registered) and s-done (terminal) are skipped; s-fault (load
    # error), s-refused (start error) and s-raise (a raising start, caught per session) fail.
    test "one event per reap, counting what each session's start returned" do
      ref = TelemetryCapture.attach([[:normandy, :resume_reaper, :sweep]], store: SweepStore)

      assert :ok = ResumeReaper.reap(sweep_state(:up))

      assert_received {:telemetry, ^ref, measurements, %{status: :ok}}

      assert %{scanned: 6, started: 1, skipped: 2, failed: 3, duration: duration} = measurements
      assert is_integer(duration) and duration >= 0
      refute_received {:telemetry, ^ref, _, _}
    end

    test "a failed listing is a sweep with status :error and the reason reduced" do
      ref = TelemetryCapture.attach([[:normandy, :resume_reaper, :sweep]], store: SweepStore)

      assert :ok = ResumeReaper.reap(sweep_state(:down))

      assert_received {:telemetry, ^ref, %{scanned: 0, started: 0, skipped: 0, failed: 0},
                       %{status: :error, reason: {:store_down, "a string (6 bytes)"}} = meta}

      refute inspect(meta) =~ "detail"
    end
  end

  describe "[:normandy, :agent_pool, :checkout]" do
    defp pool(opts) do
      {:ok, pool} =
        AgentPool.start_link(
          Keyword.merge(
            [
              agent_config: %{client: %NormandyTest.Support.ModelMockup{}, model: "m"},
              size: 1,
              max_overflow: 0
            ],
            opts
          )
        )

      ref = TelemetryCapture.attach([[:normandy, :agent_pool, :checkout]], pool: pool)
      {pool, ref}
    end

    test "an immediate checkout, a refused one and a timed-out one" do
      {pool, ref} = pool([])

      assert {:ok, _agent} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, %{wait: 0}, %{outcome: :ok, overflow: false}}

      assert {:error, :no_agents} = AgentPool.checkout(pool, block: false)
      assert_received {:telemetry, ^ref, %{wait: 0}, %{outcome: :no_agents, overflow: false}}

      # The one agent is never returned, so this checkout can only time out.
      assert {:error, :timeout} = AgentPool.checkout(pool, timeout: 50)
      assert_received {:telemetry, ^ref, %{wait: wait}, %{outcome: :timeout, overflow: false}}
      assert wait > 0
    end

    test "a waiter served by a checkin reports its wait" do
      {pool, ref} = pool([])
      assert {:ok, agent} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, _, %{outcome: :ok}}

      waiter = Task.async(fn -> AgentPool.checkout(pool, timeout: :infinity) end)
      wait_until(fn -> AgentPool.stats(pool).waiting == 1 end)

      :ok = AgentPool.checkin(pool, agent)

      assert {:ok, ^agent} = Task.await(waiter)
      # Emitted by the pool before it replies to the waiter, which then replies here:
      # two senders, so wait for it rather than assume the order.
      assert_receive {:telemetry, ^ref, %{wait: wait}, %{outcome: :ok, overflow: false}}
      assert wait > 0
    end

    test "a checkout that starts an overflow agent says so" do
      {pool, ref} = pool(max_overflow: 1)

      assert {:ok, _first} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, _, %{outcome: :ok, overflow: false}}

      assert {:ok, _second} = AgentPool.checkout(pool)
      assert_received {:telemetry, ^ref, %{wait: 0}, %{outcome: :ok, overflow: true}}
    end
  end
end
```

`assert_received` (no wait) is used only where the event is emitted in the process that then replies to the test
(`handle_call` before `{:reply, ...}`; `reap/1` in the test process).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/telemetry/operational_events_test.exs`
Expected: FAIL, `6 tests, 6 failures` (no event is emitted: `No message matching {:telemetry, ^ref, ...}`).

- [ ] **Step 3: `[:normandy, :turn, :unavailable]`**

In `lib/normandy/agents/turn/server.ex`:

a. `unavailable_data/2`: after its first line `session_id = Keyword.fetch!(opts, :session_id)` add
`emit_unavailable(session_id, reason, :start)`. Every failed load or session start reaches the `:unavailable` state
through this function (after 6.2b: the `:internal :load` event and the `:session_start` event), so `:start` covers
both.

b. The `:unavailable` turn-request clause (`def handle_event({:call, from}, msg, :unavailable, data) when
is_turn_request(msg) do`), its `{:error, reason} ->` branch: add `emit_unavailable(data.session_id, reason,
:request)` as its first line, before the `{:keep_state_and_data, [{:reply, ...} ...]}` return.

c. The `:unavailable` approval clause (`def handle_event(:cast, {:approval, _decisions, _approver_ctx}, :unavailable,
data) do`), its `{:error, reason} ->` branch: add `emit_unavailable(data.session_id, reason, :request)` as its first
line, before the `Logger.warning(` that drops the approval.

d. The retry timer clause (`def handle_event({:timeout, :retry}, :retry, :unavailable, data) do`): its
`{:error, _reason} ->` branch becomes

```elixir
      {:error, reason} ->
        emit_unavailable(data.session_id, reason, :retry)
        retry_ms = min(data.retry_ms * 2, @retry_max_ms)
```

(the rest of the branch unchanged).

e. Before the comment `# A handler crash was logged where it happened, and its exception can carry hook data:`
(above `describe_reason/1`) add:

```elixir
  # [:normandy, :turn, :unavailable]: a load or session start failed. The reason is its
  # tag only (Describe.reason_term/1), as in the log.
  defp emit_unavailable(session_id, reason, phase) do
    :telemetry.execute(
      [:normandy, :turn, :unavailable],
      %{count: 1},
      %{session_id: session_id, reason: Describe.reason_term(reason), phase: phase}
    )
  end
```

`grep -c "emit_unavailable(" lib/normandy/agents/turn/server.ex` → 5 (def + 4 calls). The literal event name keeps
`server.ex`'s dynamic call-site count at 1.

- [ ] **Step 4: `[:normandy, :resume_reaper, :sweep]`**

In `lib/normandy/agents/turn/resume_reaper.ex`, as Task 6.2f left it (`reap/1` runs `reap_session/2` per session
through `Task.async_stream(..., max_concurrency: @reap_concurrency, ordered: false, timeout: :infinity) |>
Stream.run()`; `reap_session/2` catches and logs a crash; `not_running?/3` and `non_terminal?/3` return booleans;
`alias Normandy.TurnError` is already there). Preflight X3: this is a diff against that code; the sweep counts come
from the value each session's task returns, so they are exact however many sessions run at once.

a. `reap/1`: its `@doc` gains a last paragraph, after `` throws is logged by the failure's type and skipped; the
others are still reaped.``:

```
  Emits one `[:normandy, :resume_reaper, :sweep]` event per call (see `Normandy.Telemetry`).
```

and its body becomes

```elixir
  def reap(state) do
    {store_mod, store_handle} = state.store
    started_at = System.monotonic_time()

    case store_mod.list_resumable(store_handle) do
      {:ok, sids} ->
        outcomes =
          sids
          |> Task.async_stream(&reap_session(state, &1),
            max_concurrency: @reap_concurrency,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, outcome} -> outcome end)

        emit_sweep(state, started_at, outcomes, %{status: :ok})

      {:error, reason} ->
        # Don't let a store failure silently suppress eager handoff on :nodedown —
        # surface it so operators can detect and triage missed reaps.
        Logger.warning("ResumeReaper: list_resumable failed: #{Describe.reason_tag(reason)}")
        emit_sweep(state, started_at, [], %{status: :error, reason: Describe.reason_term(reason)})
    end
  end
```

(`Stream.run()` → `Enum.map/2` over the `{:ok, outcome}` elements: `reap_session/2` never raises, so no task exits;
`reap/1` returns `:ok`, the value of `:telemetry.execute/3`.)

b. `reap_session/2`: the comment above it gains `` Returns the session's outcome for the sweep event: :started,
:skipped (registered, or its turn is terminal) or :failed (a lookup, a load or the start failed, or it crashed; each
is logged where it happened).``; its body

```elixir
    if not_running?(reg_mod, reg_handle, sid) and non_terminal?(store_mod, store_handle, sid),
      do: start_session(state, sid)

    :ok
```

becomes

```elixir
    with :absent <- registry_check(reg_mod, reg_handle, sid),
         :resumable <- turn_check(store_mod, store_handle, sid) do
      start_session(state, sid)
    else
      :running -> :skipped
      :terminal -> :skipped
      :failed -> :failed
    end
```

and its `catch` clause's last line `:ok` becomes `:failed` (the log line is unchanged).

c. After `reap_session/2` add:

```elixir
  # [:normandy, :resume_reaper, :sweep]: counts from the outcomes the sweep's tasks
  # returned, so they are exact however many sessions ran at once.
  defp emit_sweep(state, started_at, outcomes, metadata) do
    counts = Enum.frequencies(outcomes)
    {store_mod, _handle} = state.store

    :telemetry.execute(
      [:normandy, :resume_reaper, :sweep],
      %{
        duration: System.monotonic_time() - started_at,
        scanned: length(outcomes),
        started: Map.get(counts, :started, 0),
        skipped: Map.get(counts, :skipped, 0),
        failed: Map.get(counts, :failed, 0)
      },
      Map.put(metadata, :store, store_mod)
    )
  end
```

d. `not_running?/3` becomes `registry_check/3` (comment unchanged): `:none -> true` → `:none -> :absent`,
`{:ok, _pid} -> false` → `{:ok, _pid} -> :running`, and the `{:error, reason}` branch ends in `:failed` instead of
`false` (its log line unchanged).

e. `non_terminal?/3` becomes `turn_check/3`:

```elixir
  defp turn_check(store_mod, store_handle, sid) do
    case store_mod.load_turn_state(store_handle, sid) do
      {:ok, %Turn.State{status: status}} when status not in [:stopped, :failed] ->
        :resumable

      {:error, reason} ->
        # A lazy caller can still rehydrate the session later; log the missed reap.
        Logger.warning(
          "ResumeReaper: could not load the turn state of #{inspect(sid)}: #{Describe.reason_tag(reason)}"
        )

        :failed

      _terminal_or_none ->
        :terminal
    end
  end
```

f. `start_session/2`'s `case Start.start_server(...)`: the branches return the outcome:

```elixir
      {:ok, _pid} ->
        :started

      {:error, reason} ->
        Logger.warning("ResumeReaper: failed to resume #{sid}: #{Describe.reason_tag(reason)}")
        :failed

      other ->
        Logger.warning(
          "ResumeReaper: unexpected start_server result for #{sid}: #{Describe.type_of(other)}"
        )

        :failed
```

`grep -n "not_running?\|non_terminal?\|Stream.run" lib/normandy/agents/turn/resume_reaper.ex` → 0 hits.

The log lines the existing tests read (`resume_reaper_test.exs`: "could not load the turn state of \"s-fault\"",
":store_unavailable", "could not look up \"s-eager\" in the registry") are unchanged.

g. `test/agents/turn/resume_reaper_test.exs`, `describe "the via-registration race"`: its five
`refute log =~ "failed to resume"` become `refute log =~ "failed to resume s-race"` and its two
`refute log =~ "unexpected start_server"` become `refute log =~ "unexpected start_server result for s-race"`. Their
async `capture_log` sees every process's logs, and the new sweep test (async) logs a "failed to resume s-refused"
line on purpose (observed at preflight: "the supervisor-nested race shape is retried too" failed on it).

- [ ] **Step 5: `[:normandy, :agent_pool, :checkout]`**

In `lib/normandy/coordination/agent_pool.ex` (the waiter tuple gains its queue time: `{from, timer, mref, queued_at}`;
`grep -n "_timer" lib/normandy/coordination/agent_pool.ex` lists the 4 patterns to update, all below):

a. `handle_call({:checkout, block, timeout}, ...)`: the `case do_checkout(state) do` becomes

```elixir
    case do_checkout(state) do
      {:ok, agent_pid, new_state} ->
        emit_checkout(:ok, 0, new_state.overflow_count > state.overflow_count)
        {:reply, {:ok, agent_pid}, lend(agent_pid, client, new_state)}

      {:error, :no_agents} when block ->
        # Watch the waiter, so one that dies is dropped instead of being handed an agent.
        mref = Process.monitor(client)
        timer = start_checkout_timer(from, timeout)
        waiter = {from, timer, mref, System.monotonic_time()}
        {:noreply, %{state | waiting: :queue.in(waiter, state.waiting)}}

      {:error, reason} ->
        emit_checkout(reason, 0, false)
        {:reply, {:error, reason}, state}
    end
```

b. `handle_info({:checkout_timeout, from}, state)`:

```elixir
    {gone, waiting} =
      split_waiters(state.waiting, fn {waiter, _timer, _mref} -> waiter == from end)

    Enum.each(gone, fn {_from, _timer, mref} ->
      Process.demonitor(mref, [:flush])
      GenServer.reply(from, {:error, :timeout})
    end)
```

becomes

```elixir
    {gone, waiting} =
      split_waiters(state.waiting, fn {waiter, _timer, _mref, _queued_at} -> waiter == from end)

    Enum.each(gone, fn {_from, _timer, mref, queued_at} ->
      Process.demonitor(mref, [:flush])
      emit_checkout(:timeout, System.monotonic_time() - queued_at, false)
      GenServer.reply(from, {:error, :timeout})
    end)
```

c. `waiter_down/2`: its first two lines become

```elixir
    {gone, waiting} =
      split_waiters(state.waiting, fn {_from, _timer, mref, _queued_at} -> mref == ref end)

    Enum.each(gone, fn {_from, timer, _mref, _queued_at} -> cancel_checkout_timer(timer) end)
```

(a waiter that died is not answered and emits nothing).

d. `hand_to_waiter/2` becomes `/3` with the event emitted before the reply:

```elixir
  # `overflow?`: the agent was started as an overflow agent for this waiter.
  defp hand_to_waiter(agent_pid, state, overflow?) do
    {{:value, {{client, _tag} = from, timer, mref, queued_at}}, waiting} =
      :queue.out(state.waiting)

    cancel_checkout_timer(timer)
    Process.demonitor(mref, [:flush])
    emit_checkout(:ok, System.monotonic_time() - queued_at, overflow?)
    GenServer.reply(from, {:ok, agent_pid})
```

(the rest of the function unchanged). Its three callers: in `do_checkin/2`
`hand_to_waiter(agent_pid, new_state)` → `hand_to_waiter(agent_pid, new_state, false)` (an agent coming back); in
`handle_agent_death/2` `hand_to_waiter(new_pid, state)` → `hand_to_waiter(new_pid, state, false)` (a replacement
within `size`); and `serve_waiter/1` becomes

```elixir
  defp serve_waiter(state) do
    with false <- :queue.is_empty(state.waiting),
         {:ok, agent_pid, new_state} <- do_checkout(state) do
      hand_to_waiter(agent_pid, new_state, new_state.overflow_count > state.overflow_count)
    else
      _ -> state
    end
  end
```

`grep -c "hand_to_waiter(" lib/normandy/coordination/agent_pool.ex` → 4.

e. Before `# A waiter with timeout: :infinity has no timer.` add:

```elixir
  # [:normandy, :agent_pool, :checkout], emitted where the checkout's reply is sent. `wait`
  # is the time the caller waited in the queue (0 when answered at once).
  defp emit_checkout(outcome, wait, overflow?) do
    :telemetry.execute(
      [:normandy, :agent_pool, :checkout],
      %{wait: wait},
      %{pool: self(), outcome: outcome, overflow: overflow?}
    )
  end
```

- [ ] **Step 6: Catalogue**

In `lib/normandy/telemetry.ex`, "## Events", before `  ### `[:normandy, :json_deserializer, :fallback]`` add:

```
  ### `[:normandy, :turn, :unavailable]`

  `Turn.Server` could not load or start its session and is (still) `:unavailable`.
  Measurement `count: 1`. Metadata: `session_id`; `phase`: `:start` (the load after
  `init/1`, or the new session's `on_session_start`), `:retry` (the backoff timer's load
  failed again) or `:request` (a `run/2` or an approval retried the load and it failed);
  `reason`, reduced as `run/2`'s `:session_unavailable` reason is: atoms and integers
  kept, tuples walked, an exception its module (`{Postgrex.Error, code}` for one with a
  SQLSTATE), any other term a description of its type (`"a map"`). Never the reason's
  data.

  ### `[:normandy, :resume_reaper, :sweep]`

  One `Normandy.Agents.Turn.ResumeReaper.reap/1` (on every `:nodedown`). Measurements:
  `duration` (native units), `scanned` (sessions `list_resumable/1` returned), `started`,
  `skipped` (registered elsewhere, or their turn is no longer in flight) and `failed` (a
  registry lookup, a turn-state load or the start failed; each is logged). `started +
  skipped + failed == scanned`. Metadata: `store` (the `SessionStore` module), `status`
  (`:ok`, or `:error` when the listing failed, with every count `0`) and, on `:error`,
  `reason` (reduced as for `[:normandy, :turn, :unavailable]`).

  ### `[:normandy, :agent_pool, :checkout]`

  One `Normandy.Coordination.AgentPool.checkout/2` answered, emitted by the pool when it
  replies. Measurement `wait`: native units the caller waited for an agent to come back
  (`0` when answered at once). Metadata: `pool` (the pool's pid), `outcome` (`:ok |
  :timeout | :no_agents | :failed_to_start_agent`), `overflow` (`true` when an overflow
  agent was started for this checkout). A blocked caller that dies before it is served
  emits nothing.

```

`test/telemetry/catalogue_test.exs` finds the three literal `:telemetry.execute([...])` sites and these headings;
no `@dynamic` entry changes.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/telemetry test/agents/turn test/coordination`
Expected: PASS (`operational_events_test.exs` 6 tests; the existing pool tests unchanged, the reaper tests with
Step 4g's narrowed refutes). Stacked: `46 doctests, 705 tests, 0 failures (8 excluded)`.

- [ ] **Step 8: Gate and tagged suites**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.4e.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.4e.log`,
`mix docs --warnings-as-errors`, `mix test.redis 2>&1 | tail -3`,
`docker start normandy-test-pg && MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres 2>&1 | tail -3`,
`MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres 2>&1 | tail -3`.
Expected: ` 0 failures` in each; docs exit 0.

- [ ] **Step 9: MIGRATING-2.0.md**

Append to `## New, non-breaking`:

```markdown
- New telemetry events (see the `Normandy.Telemetry` catalogue):
  `[:normandy, :turn, :unavailable]` (a `Turn.Server` whose session could not be loaded or
  started; `phase` and the reduced reason), `[:normandy, :resume_reaper, :sweep]` (one per
  `ResumeReaper.reap/1`: sessions scanned, started, skipped, failed) and
  `[:normandy, :agent_pool, :checkout]` (one per answered `AgentPool.checkout/2`: `wait`,
  `outcome`, `overflow`).
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/resume_reaper.ex \
  lib/normandy/coordination/agent_pool.ex lib/normandy/telemetry.ex MIGRATING-2.0.md \
  test/telemetry/operational_events_test.exs test/agents/turn/resume_reaper_test.exs
git commit -m "feat(telemetry): events for an unavailable session, a reaper sweep and a pool checkout"
```

---

---

### Task 6.5a: `OtelCtx` asks the code server once per module (PERF-16)

Without OpenTelemetry, every `OtelCtx` call costs a `code_server` round trip
(`Code.ensure_loaded?/1` of an absent module): 24.6 µs per call, serialized node-wide
(inventory 6.5 §1 PERF-16; 51 call sites, every path goes through these five functions). This
task caches the answer per node in `:persistent_term`. No telemetry event or metadata changes.

**Files:**
- Modify: `lib/normandy/telemetry/otel_ctx.ex` (moduledoc, new `__loaded__?/1`, `capture/0`, `attach/1`, `inject/1`, `extract/1`, `detach/1`)
- Modify: `MIGRATING-2.0.md` (create `## 42.`)
- Test: modify `test/telemetry/otel_ctx_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Normandy.Telemetry.OtelCtx.__loaded__?(module()) :: boolean()` (`@doc false`; cache key `{Normandy.Telemetry.OtelCtx, module}` in `:persistent_term`).

- [ ] **Step 1: Write the failing tests**

In `test/telemetry/otel_ctx_test.exs` (already `async: false`), insert before `describe "inject/1" do`:

```elixir
  describe "__loaded__?/1" do
    test "asks the code server once per module, then answers from the cache" do
      module = NormandyTest.NoSuchOtelModule
      key = {OtelCtx, module}
      :persistent_term.erase(key)
      on_exit(fn -> :persistent_term.erase(key) end)

      code_server = Process.whereis(:code_server)
      :erlang.trace(code_server, true, [:receive])

      results = for _ <- 1..100, do: OtelCtx.__loaded__?(module)

      :erlang.trace(code_server, false, [:receive])
      trace_ref = :erlang.trace_delivered(code_server)
      assert_receive {:trace_delivered, ^code_server, ^trace_ref}

      assert Enum.uniq(results) == [false]
      assert code_server_calls_about(module) == 1
    end

    test "every function reads the cache" do
      {ctx, _span} = ctx_with_span()
      carrier = OtelCtx.inject(ctx)

      keys =
        for module <- [OpenTelemetry.Ctx, :otel_propagator_text_map, :otel_ctx],
            do: {OtelCtx, module}

      on_exit(fn -> Enum.each(keys, &:persistent_term.erase/1) end)

      # OTel is loaded in the test env; a cached `false` must make every function a no-op.
      Enum.each(keys, &:persistent_term.put(&1, false))

      assert OtelCtx.capture() == nil
      assert OtelCtx.attach(ctx) == nil
      assert OtelCtx.detach(make_ref()) == :ok
      assert OtelCtx.inject(ctx) == []
      assert OtelCtx.extract(carrier) == nil
    end
  end

  # The trace messages the code server received from this process naming `module`.
  defp code_server_calls_about(module) do
    me = self()

    receive_all()
    |> Enum.count(fn
      {:trace, _cs, :receive, {:code_call, ^me, request}} when is_tuple(request) ->
        module in Tuple.to_list(request)

      _other ->
        false
    end)
  end

  defp receive_all(acc \\ []) do
    receive do
      {:trace, _, :receive, _} = msg -> receive_all([msg | acc])
    after
      0 -> acc
    end
  end

```

The `after 0` only drains: `:erlang.trace_delivered/1` already guaranteed every trace message
is in the mailbox. On OTP 26+ the code server receives
`{:code_call, pid, {:get_object_code_for_loading, module}}` per lookup of an absent module
(observed on OTP 28); older releases send `{:ensure_loaded, module}`; both name the module. The
erase in `on_exit` makes the next real call re-probe and cache `true` again (the suite's
sync modules run one at a time, so no other test sees the forced `false`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/telemetry/otel_ctx_test.exs`
Expected: FAIL, 2 tests: `** (UndefinedFunctionError) function Normandy.Telemetry.OtelCtx.__loaded__?/1 is undefined or private` and, in "every function reads the cache", `assert OtelCtx.capture() == nil` fails (left is the current context).

- [ ] **Step 3: The cache**

In `lib/normandy/telemetry/otel_ctx.ex`, in the moduledoc, after the paragraph ending
`function here is a cheap no-op.` insert:

```
  Whether each OTel module is loaded is asked of the code server once per node, then
  cached in `:persistent_term`: an absent module would otherwise cost a code-server
  round trip on every call, from every process. So OTel loaded after the first call
  that looked for it (a hot code load) is not seen until the node restarts.
```

Before `@spec capture() :: term() | nil` insert:

```elixir
  @doc false
  # Code.ensure_loaded?/1, asked once per node and module (see the moduledoc). Public
  # for its test only.
  @spec __loaded__?(module()) :: boolean()
  def __loaded__?(module) do
    key = {__MODULE__, module}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        loaded = Code.ensure_loaded?(module)
        :persistent_term.put(key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

```

Then replace every probe (exact rewrite; `grep -c "Code.ensure_loaded?" lib/normandy/telemetry/otel_ctx.ex`
is 6 before this step, 2 after — the call inside `__loaded__?/1` and its comment line):

- `capture/0`, `attach/1`, `detach/1`: `if Code.ensure_loaded?(OpenTelemetry.Ctx) and` → `if __loaded__?(OpenTelemetry.Ctx) and` (3 sites; the `function_exported?/3` checks stay).
- `inject/1`: `if Code.ensure_loaded?(:otel_propagator_text_map) do` → `if __loaded__?(:otel_propagator_text_map) do`.
- `extract/1`: `if Code.ensure_loaded?(:otel_propagator_text_map) and Code.ensure_loaded?(:otel_ctx) do` → `if __loaded__?(:otel_propagator_text_map) and __loaded__?(:otel_ctx) do`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/telemetry/otel_ctx_test.exs test/telemetry/span_hierarchy_test.exs test/telemetry/a2a_propagation_test.exs test/telemetry/killed_run_test.exs`
Expected: PASS (`otel_ctx_test.exs`: 8 tests).

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.5a.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.5a.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite (no store, registry or `Turn.Server` start path changes).

- [ ] **Step 6: MIGRATING-2.0.md**

Insert after the end of `## 41.` and before `## New, non-breaking`:

```markdown
## 42. AgentProcess and coordination

- `Normandy.Telemetry.OtelCtx` asks the code server once per node whether OpenTelemetry is
  loaded and caches the answer. OpenTelemetry loaded into a running node after Normandy first
  looked for it (a hot code load) is not seen until the node restarts.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/telemetry/otel_ctx.ex test/telemetry/otel_ctx_test.exs MIGRATING-2.0.md
git commit -m "perf(telemetry): OtelCtx probes each OpenTelemetry module once per node"
```

---

### Task 6.5b: `AgentMemory.delete_turn/2` is linear and survives a corrupt memory (PERF-15)

`delete_turn/2` walks every surviving entry to the root (`after_deleted?/3`): quadratic
(4 000 entries: 470 ms; 20 000: about 12 s), a parent cycle among the survivors hangs it, and a
`parent_id` naming no entry raises `BadMapError` (inventory 6.5 Surprise 2). It also misses the
entry right after the deleted turn: `after_deleted?/3` starts from the re-linked parent, so an
assistant entry whose parent was deleted keeps thinking produced with the deleted turn in its
history (verified: the new test "drops the thinking of the entry right after the deleted turn"
fails at `d624fbf`). The fix computes the deleted entries' descendants once through a
parent → children index with a visited set.

This task runs after Task 6.1a: entry content is set only through the private
`put_content/2`, which also sets the `wire`/`tokens` cache. 6.1a's `delete_turn/2` already
calls its private `strip_thinking/1` (`put_content/2` only when the content has thinking), and
the thinking drop below keeps calling it, so a survivor without thinking is not re-encoded.

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (`delete_turn/2` and its doc; `after_deleted?/3` removed; new private `descendants/2`, `collect_descendants/3`)
- Modify: `MIGRATING-2.0.md` (`## 42.`)
- Test: modify `test/components/agent_memory_test.exs`

**Interfaces:**
- Consumes: `AgentMemory.strip_thinking/1` and `put_content/2` (private, Task 6.1a), `surviving_ancestor/3` (unchanged).
- Produces: nothing new; `delete_turn/2`'s contract is unchanged but for the direct-child fix.

- [ ] **Step 1: Write the failing tests**

In `test/components/agent_memory_test.exs`, insert before `describe "history edits drop the thinking they invalidate" do`:

```elixir
  describe "delete_turn/2 on large and corrupt memories (PERF-15)" do
    # One entry per turn, in a chain: e1 <- e2 <- ... <- en.
    defp chain(n) do
      entries =
        Map.new(1..n, fn i ->
          parent = if i == 1, do: nil, else: "e#{i - 1}"

          {"e#{i}",
           %Entry{
             id: "e#{i}",
             parent_id: parent,
             turn_id: "t#{i}",
             role: "user",
             content: "m#{i}"
           }}
        end)

      %AgentMemory{entries: entries, head: "e#{n}", current_turn_id: "t#{n}"}
    end

    test "deleting the first turn of a 20_000-entry chain is linear" do
      # The walk-to-root version takes ~12 s here (quadratic); a linear one, milliseconds.
      task = Task.async(fn -> AgentMemory.delete_turn(chain(20_000), "t1") end)
      memory = Task.await(task, 5_000)

      assert AgentMemory.count_messages(memory) == 19_999
      assert AgentMemory.fetch_entry!(memory, "e2").parent_id == nil
      assert memory.head == "e20000"
    end

    test "survivors without thinking keep their cached term (nothing re-encoded)" do
      ref = CountingContent.counter()

      memory =
        Enum.reduce(1..3, AgentMemory.new_memory(), fn i, m ->
          m
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", CountingContent.new(ref, "m#{i}"))
        end)

      [first | _] = AgentMemory.entry_chain(memory)
      deleted = AgentMemory.delete_turn(memory, first.turn_id)

      assert CountingContent.count(ref) == 3
      assert Enum.map(AgentMemory.entry_chain(deleted), & &1.wire) == ["m2", "m3"]
    end

    test "a parent cycle among the survivors does not hang" do
      # x is deleted; y <-> z is a corrupt cycle that never reaches x.
      x = %Entry{id: "x", parent_id: nil, turn_id: "T", role: "user", content: "x"}
      y = %Entry{id: "y", parent_id: "z", turn_id: "U", role: "user", content: "y"}
      z = %Entry{id: "z", parent_id: "y", turn_id: "U", role: "assistant", content: "z"}

      memory = %AgentMemory{
        entries: %{"x" => x, "y" => y, "z" => z},
        head: "y",
        current_turn_id: "U"
      }

      result = Task.await(Task.async(fn -> AgentMemory.delete_turn(memory, "T") end), 2_000)

      assert Map.keys(result.entries) |> Enum.sort() == ["y", "z"]
      assert AgentMemory.fetch_entry!(result, "y").parent_id == "z"
      assert AgentMemory.fetch_entry!(result, "z").parent_id == "y"
    end

    test "a parent_id that names no entry does not raise" do
      x = %Entry{id: "x", parent_id: nil, turn_id: "T", role: "user", content: "x"}
      y = %Entry{id: "y", parent_id: "missing", turn_id: "U", role: "user", content: "y"}

      memory = %AgentMemory{entries: %{"x" => x, "y" => y}, head: "y", current_turn_id: "U"}
      result = AgentMemory.delete_turn(memory, "T")

      assert Map.keys(result.entries) == ["y"]
      assert AgentMemory.fetch_entry!(result, "y").parent_id == "missing"
    end
  end

```

In the same file, inside `describe "history edits drop the thinking they invalidate"`, insert
before `test "drop_thinking/1 removes thinking blocks from a block list and a ToolCallResponse" do`:

```elixir
    test "delete_turn drops the thinking of the entry right after the deleted turn" do
      # u (turn 1) <- a2 (turn 2, deleted) <- a3 (turn 3, directly after it).
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "go")
        |> AgentMemory.initialize_turn()

      deleted_turn = memory.current_turn_id

      memory =
        memory
        |> AgentMemory.add_message("assistant", %ToolCallResponse{
          thinking: @thinking,
          tool_calls: [%ToolCall{id: "a", name: "weather", input: %{}}]
        })
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("assistant", %ToolCallResponse{
          thinking: @thinking,
          tool_calls: [%ToolCall{id: "b", name: "weather", input: %{}}]
        })

      memory = AgentMemory.delete_turn(memory, deleted_turn)

      assert thinking_by_call(memory) == [{"b", []}]
    end

```

Add `alias Normandy.Test.CountingContent` to the file's aliases (after
`alias Normandy.Components.ToolResult`; credo flags the nested name otherwise).

The `%Entry{}` literals carry no `wire`/`tokens` (the pre-field shape Task 6.1a's readers
accept); `put_content/2` fills them for the entries whose thinking is dropped. The
"nothing re-encoded" test passes before and after the change (it pins 6.1a's cache contract
through the rewrite: `put_content/2` on every survivor fails it, `left: 5`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/components/agent_memory_test.exs`
Expected: FAIL, 4 tests: the 20 000-entry test exits `Task.await(..., 5000)` with `** (EXIT) time out`; the survivor-cycle test exits `Task.await(..., 2000)` with `** (EXIT) time out`; the dangling-parent test raises `** (BadMapError) expected a map, got: nil`; the direct-child test fails `assert thinking_by_call(memory) == [{"b", []}]` (left: `[{"b", [%{"type" => "thinking", ...}]}]`).

- [ ] **Step 3: One pass**

In `lib/normandy/components/agent_memory.ex`, replace `delete_turn/2`'s `@doc`, the whole
`delete_turn/2` and `after_deleted?/3` (both clauses) with:

```elixir
  @doc """
  Removes every entry of turn `turn_id`, re-linking the survivors around it. Every
  surviving entry that had a deleted entry among its ancestors loses its thinking (it was
  produced with the deleted turn in its history). Raises `Normandy.TurnNotFoundError`
  when the memory has no entry of that turn.

  Linear in the number of entries. A corrupt memory (a parent cycle, a `parent_id`
  naming no entry) does not hang or raise.
  """
  @spec delete_turn(t(), String.t()) :: t()
  def delete_turn(%__MODULE__{} = memory, turn_id) do
    deleted =
      for {id, %Entry{turn_id: ^turn_id}} <- memory.entries, into: MapSet.new(), do: id

    if MapSet.size(deleted) == 0 do
      raise Normandy.TurnNotFoundError, turn_id: turn_id
    end

    after_deleted = descendants(memory.entries, deleted)

    entries =
      for {id, entry} <- memory.entries, not MapSet.member?(deleted, id), into: %{} do
        entry = %{entry | parent_id: surviving_ancestor(entry.parent_id, memory.entries, deleted)}

        if MapSet.member?(after_deleted, id),
          do: {id, strip_thinking(entry)},
          else: {id, entry}
      end

    %{memory | entries: entries, head: surviving_ancestor(memory.head, memory.entries, deleted)}
  end

  # The ids of the entries below `roots` (not `roots` themselves), through one
  # parent => children index: O(entries). The visited set stops a parent cycle; a
  # parent_id that names no entry is a key nobody reaches.
  defp descendants(entries, roots) do
    children = Enum.group_by(entries, fn {_id, entry} -> entry.parent_id end, &elem(&1, 0))

    roots
    |> Enum.flat_map(&Map.get(children, &1, []))
    |> collect_descendants(children, roots)
    |> MapSet.difference(roots)
  end

  defp collect_descendants([], _children, seen), do: seen

  defp collect_descendants([id | rest], children, seen) do
    if MapSet.member?(seen, id),
      do: collect_descendants(rest, children, seen),
      else: collect_descendants(Map.get(children, id, []) ++ rest, children, MapSet.put(seen, id))
  end
```

Every root's children are pushed first, so a deleted entry met again (it is in `seen` from the
start) is skipped without losing the survivors below it. `surviving_ancestor/3,4` is
unchanged (already cycle-guarded). `strip_thinking/1` (Task 6.1a) goes through `put_content/2`,
the one writer of `content`/`wire`/`tokens` (header, Shared interfaces), and only for content
that has thinking.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/components/agent_memory_test.exs test/context/window_manager_test.exs`
Expected: PASS. The 20 000-entry test takes about 30 ms (measured at `d624fbf` + this change).

- [ ] **Step 5: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.5b.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.5b.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite (`delete_turn/2` has no caller in `lib/`).

- [ ] **Step 6: MIGRATING-2.0.md**

Append to `## 42.`:

```markdown
- `AgentMemory.delete_turn/2` is linear in the number of entries (it walked every surviving
  entry to the root), and a corrupt memory (a parent cycle, a `parent_id` naming no entry) no
  longer hangs it or raises `BadMapError`. It now also drops the thinking of the entry right
  after the deleted turn, which was produced with that turn in its history and used to keep it.
```

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/components/agent_memory.ex test/components/agent_memory_test.exs MIGRATING-2.0.md
git commit -m "perf(memory): delete_turn/2 is linear and terminates on a corrupt memory"
```

---
### Task 6.5c: Inline `AgentProcess` runs from a FIFO queue in a watched worker; `run/3` waits `:infinity` (A7, PERF-13)

An inline `AgentProcess` runs the whole turn inside `handle_call/3`, so `get_stats/1`,
`get_agent/1`, `get_id/1`, `approve/2` and `update_agent/2` block behind it (probe: `get_stats/1`
exits `{:timeout, _}` after 5 s during a run; inventory 6.5 §1 A7). Per R10 (6.5 Q1 a, Q2, Q5):
`:inline` stays the default; runs and `update_agent/2` calls go through one FIFO queue; one turn
at a time runs in a worker started from the committed config, so memory updates never race
(`agent_process_test.exs` "handles multiple concurrent runs" still holds); reads answer at once;
`run/3` waits `:infinity` by default. The worker is the new internal `Normandy.WatchedWorker`
(dies with its owner; Turn.Server is not switched to it in this wave). Casts stay as they are
until Task 6.5d.

Paths: only `AgentProcess` (inline engine). `BaseAgent.run/3` is unchanged and still runs the
turn, so `run/3`, `stream/3`, `Turn.Driver`, `Turn.Inline` and `Turn.Server` are untouched;
this task changes no message encoding, request or loop. No telemetry event or metadata
changes: the run span is BaseAgent's, and it still nests under the caller
(`span_hierarchy_test.exs` "AgentProcess.run (inline) nests the run under the caller" and
"does not leak the caller context into the next call" pass unchanged).

**Files:**
- Create: `lib/normandy/watched_worker.ex` (`Normandy.WatchedWorker`, `@moduledoc false`)
- Modify: `lib/normandy/coordination/agent_process.ex` (moduledoc; `@run_opts_schema`; `__opts_schema__/1`; `init/1`; inline `handle_call({:run, _, _}, ...)`; `handle_call({:update_agent, _}, ...)`; `put_agent/2`; new `handle_info/2` clauses; new private `update_agent_now/2`, `enqueue/2`, `dispatch/1`, `start_op/2`, `start_turn/5`, `finish_op/3`, `count_run/2`, `caller_alive?/1`, `inline_turn/3`)
- Modify: `lib/normandy/turn_error.ex` (moduledoc paragraph on `AgentProcess`)
- Modify: `lib/normandy/options.ex` (timeout table row)
- Modify: `lib/normandy/telemetry/killed_run.ex` (moduledoc bullet on agent processes)
- Modify: `MIGRATING-2.0.md` (`## 42.`)
- Test: create `test/coordination/agent_process_queue_test.exs`

**Interfaces:**
- Consumes: `BaseAgent.run/3`, `TurnError.log_raised/3`, `TurnError.format_raised/3`, `TurnError.from_reason/1`, `OtelCtx.restore/1`, the existing private `exit_reason/2`, `prepare_input/1`, `extract_result/1`.
- Produces: `Normandy.WatchedWorker.start(tag :: term(), work :: (-> term())) :: {pid(), reference()}` (the owner gets `{tag, watcher_pid, result}` then the watcher's `:DOWN`); `AgentProcess.__opts_schema__(:run)` (`@doc false`); `run/3` `:timeout` default `:infinity` (header); `AgentProcess` state keys `running` (`nil | %{pid, ref, op, started}`) and `queue` (`:queue` of ops `{:run, from, input, otel_ctx}` | `{:update, from, update_fn}`; Task 6.5d adds `{:cast, reply_to, input, otel_ctx}`).

- [ ] **Step 1: Write the failing tests**

Create `test/coordination/agent_process_queue_test.exs`. Every LLM call is gated: the
`StubClient` reply runs in the turn's worker, sends `{:llm_started, n, worker}` and blocks until
`{:release, n}` reaches that worker, so ordering is proven without sleeps (`wait_until/1`
polls the queue length through `:sys.get_state/1`):

```elixir
defmodule Normandy.Coordination.AgentProcessQueueTest do
  @moduledoc """
  Task 6.5c (A7, PERF-13): an inline `AgentProcess` runs its turns one at a time from a
  FIFO queue in a watched worker, so reads answer during a turn, runs and
  `update_agent/2` keep their order and memory, and a turn dies with its process.

  Every LLM call is gated: the client sends `{:llm_started, n, worker}` from the worker
  and blocks until the test sends `{:release, n}` to that worker.
  """
  use ExUnit.Case, async: true

  # How long a gate event may take to arrive. A turn's worker reaches the client after
  # BaseAgent's setup, which under a loaded suite (async DSL tests compiling modules)
  # has taken over ExUnit's default 100 ms; the events always come, so wait for them.
  @wait 5_000

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.AgentMemory
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Test.StubClient
  alias Normandy.TurnError

  defp gated_agent do
    parent = self()
    calls = :atomics.new(1, [])

    reply = fn response_model ->
      n = :atomics.add_get(calls, 1, 1)
      send(parent, {:llm_started, n, self()})

      receive do
        {:release, ^n} -> %{response_model | chat_message: "answer #{n}"}
      end
    end

    BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})
  end

  defp run_in_task(pid, input), do: Task.async(fn -> AgentProcess.run(pid, input) end)

  defp queued(pid), do: :queue.len(:sys.get_state(pid).queue)

  defp messages(pid), do: AgentMemory.count_messages(AgentProcess.get_agent(pid).memory)

  test "reads answer at once while a turn runs" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "busy")
    task = run_in_task(pid, "go")
    assert_receive {:llm_started, 1, worker}, @wait

    # A blocking implementation exits each of these with {:timeout, _} after 5 s.
    assert %{agent_id: "busy", run_count: 0} = AgentProcess.get_stats(pid)
    assert AgentProcess.get_id(pid) == "busy"
    assert messages(pid) == 0
    assert AgentProcess.approve(pid, %{}) == {:error, :inline_mode}

    send(worker, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(task)
    assert %{run_count: 1} = AgentProcess.get_stats(pid)
    assert messages(pid) == 2
  end

  test "runs execute one at a time, in order, each from the memory the previous one left" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    second = run_in_task(pid, "two")
    assert wait_until(fn -> queued(pid) == 1 end)
    refute_received {:llm_started, 2, _}

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)

    assert_receive {:llm_started, 2, worker2}, @wait
    send(worker2, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(second)

    assert messages(pid) == 4
    assert %{run_count: 2} = AgentProcess.get_stats(pid)
  end

  test "update_agent/2 waits for the turn in flight and the next run sees both" do
    parent = self()
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    update =
      Task.async(fn ->
        AgentProcess.update_agent(pid, fn agent ->
          send(parent, {:update_saw, AgentMemory.count_messages(agent.memory)})
          %{agent | temperature: 0.3}
        end)
      end)

    assert wait_until(fn -> queued(pid) == 1 end)
    assert Task.yield(update, 0) == nil

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)
    assert :ok = Task.await(update)
    assert_received {:update_saw, 2}

    second = run_in_task(pid, "two")
    assert_receive {:llm_started, 2, worker2}, @wait
    send(worker2, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(second)

    agent = AgentProcess.get_agent(pid)
    assert agent.temperature == 0.3
    assert AgentMemory.count_messages(agent.memory) == 4
  end

  test "a queued run whose caller died is skipped" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    doomed = spawn(fn -> AgentProcess.run(pid, "never") end)
    assert wait_until(fn -> queued(pid) == 1 end)
    ref = Process.monitor(doomed)
    Process.exit(doomed, :kill)
    assert_receive {:DOWN, ^ref, :process, ^doomed, :killed}, @wait

    third = run_in_task(pid, "three")
    assert wait_until(fn -> queued(pid) == 2 end)

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)

    # The dead caller's run never reached the client: the next call is the third run's.
    assert_receive {:llm_started, 2, worker3}, @wait
    send(worker3, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(third)

    assert %{run_count: 2} = AgentProcess.get_stats(pid)
    assert messages(pid) == 4
  end

  test "stop/1 kills the turn in flight" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    _caller = spawn(fn -> AgentProcess.run(pid, "go") end)
    assert_receive {:llm_started, 1, worker}, @wait
    ref = Process.monitor(worker)

    :ok = AgentProcess.stop(pid)

    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @wait
  end

  test "a worker killed from outside replies a :task_down TurnError and the next run works" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    Process.exit(worker1, :kill)

    assert {:error, %TurnError{type: :task_down, reason: :killed}} = Task.await(first)
    assert Process.alive?(pid)
    assert messages(pid) == 0

    second = run_in_task(pid, "two")
    assert_receive {:llm_started, 2, worker2}, @wait
    send(worker2, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(second)
  end

  test "an exit or a throw in the turn replies a :task_down TurnError and is logged" do
    for {kind, client_reply, reason} <- [
          {:exit, fn _rm -> exit(:client_gone) end, :client_gone},
          {:throw, fn _rm -> throw(:client_threw) end, {:nocatch, :client_threw}}
        ] do
      agent = BaseAgent.init(%{client: %StubClient{reply: client_reply}, model: "m"})
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "k_#{kind}")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %TurnError{type: :task_down, reason: ^reason}} =
                   AgentProcess.run(pid, "go")
        end)

      assert log =~ "Agent k_#{kind} raised #{kind}"
      assert Process.alive?(pid)
    end
  end

  test "run/3 waits without a timeout by default" do
    assert AgentProcess.__opts_schema__(:run).schema[:timeout][:default] == :infinity
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/coordination/agent_process_queue_test.exs`
Expected: FAIL, 8 tests (one of them hangs until ExUnit's 60 s test timeout):
- "reads answer at once while a turn runs": `** (exit) exited in: GenServer.call(#PID<...>, :get_stats, 5000) ** (EXIT) time out`
- "runs execute one at a time...", "update_agent/2 waits...", "a queued run whose caller died is skipped": `** (exit) exited in: :sys.get_state(#PID<...>) ** (EXIT) time out`
- "stop/1 kills the turn in flight": `** (ExUnit.TimeoutError) test timed out after 60000ms`
- "a worker killed from outside...": `** (EXIT from #PID<...>) killed` (there is no worker: the gate's `self()` is the `AgentProcess` itself, linked to the test)
- "an exit or a throw in the turn...": `** (EXIT from #PID<...>) :client_gone` (the exit kills the AgentProcess)
- "run/3 waits without a timeout by default": `** (FunctionClauseError) no function clause matching in Normandy.Coordination.AgentProcess.__opts_schema__/1`

- [ ] **Step 3: `Normandy.WatchedWorker`**

Create `lib/normandy/watched_worker.ex`:

```elixir
defmodule Normandy.WatchedWorker do
  @moduledoc false
  # Runs `work` in a process that never outlives its owner (the caller of `start/2`).
  #
  # `start/2` spawns a monitored, unlinked watcher and returns `{watcher, monitor_ref}`.
  # The watcher monitors the owner, traps exits and runs `work` in a linked worker:
  #
  #   * `work` returns `result`: the owner gets `{tag, watcher, result}`, then the
  #     watcher's `:DOWN` with reason `:normal` (demonitor it with `:flush`).
  #   * the worker dies (raised, exited, threw, was killed): the watcher exits with the
  #     worker's reason, which the owner sees as the watcher's `:DOWN`.
  #   * the owner dies: the worker is killed, so no turn runs on unseen.
  #
  # The owner keys the work by the watcher pid, so there is no monitor-ref handshake.
  # Turn.Server's run_while_server_alive/3 has the same shape; it is meant to move here.

  @spec start(term(), (-> term())) :: {pid(), reference()}
  def start(tag, work) when is_function(work, 0) do
    owner = self()
    spawn_monitor(fn -> watch(owner, tag, work) end)
  end

  defp watch(owner, tag, work) do
    owner_ref = Process.monitor(owner)
    Process.flag(:trap_exit, true)
    watcher = self()
    worker = spawn_link(fn -> send(watcher, {__MODULE__, work.()}) end)

    receive do
      {__MODULE__, result} -> send(owner, {tag, watcher, result})
      {:EXIT, ^worker, reason} -> exit(reason)
      {:DOWN, ^owner_ref, :process, _pid, _reason} -> Process.exit(worker, :kill)
    end
  end
end
```

It is `run_while_server_alive/3` (`server.ex`) without the monitor-ref handshake: the owner
keys the work by the watcher pid that `spawn_monitor/1` returns, so the worker never waits
for a message from its owner (the July LOW "handshake `receive` without `after`" shape is
gone from `AgentProcess`; Turn.Server keeps its own until it switches to this module).

- [ ] **Step 4: The queue in `AgentProcess`**

All edits in `lib/normandy/coordination/agent_process.ex`.

(a) Moduledoc: after the example block that ends `agent = AgentProcess.get_agent(pid)` and
before `## Durable turn engine (\`:server\` mode)`, insert:

```
  ## Inline turns (the default)

  With `turn_engine: :inline`, runs, casts and `update_agent/2` calls go through one FIFO
  queue and execute one at a time, each turn in a worker process started from the config
  the previous one left. The process itself never waits on a turn: `get_agent/1` (the
  config as of the last finished turn), `get_id/1`, `get_stats/1` and `approve/2` answer
  at once while a turn runs. A run whose caller died while it waited in the queue is
  skipped. The worker dies with the process (`stop/1` kills a turn in flight); a worker
  killed from outside replies a `:task_down` `Normandy.TurnError`.

```

(Until Task 6.5d, "runs, casts" overstates casts; 6.5d makes it true. Keep the sentence.)

(b) Aliases: after `alias Normandy.TurnError` add `alias Normandy.WatchedWorker`.

(c) `@run_opts_schema`: replace

```elixir
                       default: 60_000,
                       doc: "How long the caller waits for the reply, in ms."
```

with

```elixir
                       default: :infinity,
                       doc:
                         "How long the caller waits for the reply, in ms. A run is bounded " <>
                           "by its retries, tool timeouts and `max_tool_iterations`, so the " <>
                           "default waits for it, as `Turn.Server.run/2` does."
```

and replace

```elixir
  @spec __opts_schema__(:start_link) :: NimbleOptions.t()
  def __opts_schema__(:start_link), do: @start_link_opts_schema
```

with

```elixir
  @spec __opts_schema__(:start_link | :run) :: NimbleOptions.t()
  def __opts_schema__(:start_link), do: @start_link_opts_schema
  def __opts_schema__(:run), do: @run_opts_schema
```

(d) `init/1`, in the `base` map, after `pending_runs: %{},` insert:

```elixir
      # :inline mode: the turn in flight (%{pid, ref, op, started} or nil) and the ops
      # waiting behind it, oldest first (see enqueue/2).
      running: nil,
      queue: :queue.new(),
```

(e) Replace the whole inline run clause, from `@impl true` /
`def handle_call({:run, input, otel_ctx}, _from, state) do` through its closing `end` (the
`try ... after OtelCtx.detach(token) end` block and `result`), with:

```elixir
  # :inline: queued behind the turn in flight; the reply comes from handle_info/2.
  @impl true
  def handle_call({:run, input, otel_ctx}, from, state) do
    {:noreply, enqueue({:run, from, input, otel_ctx}, state)}
  end
```

The `:server` clause above it and the two-element `{:run, input}` clause stay.

(f) Replace the `update_agent` clause (keep the three comment lines above it):

```elixir
  @impl true
  def handle_call({:update_agent, update_fn}, _from, state) do
    case update_fn.(state.agent) do
      %BaseAgentConfig{} = updated -> put_agent(updated, state)
      other -> {:reply, {:not_a_config, Describe.type_of(other)}, state}
    end
  end
```

with

```elixir
  # :inline: queued like a run, so it sees the memory of every run before it and no run
  # in flight overwrites it.
  @impl true
  def handle_call({:update_agent, update_fn}, from, %{turn_engine: :inline} = state) do
    {:noreply, enqueue({:update, from, update_fn}, state)}
  end

  def handle_call({:update_agent, update_fn}, _from, state) do
    {reply, state} = update_agent_now(update_fn, state)
    {:reply, reply, state}
  end
```

Directly above `defp put_agent(updated, %{turn_engine: :server} = state) do` (below its
two-line comment) insert:

```elixir
  defp update_agent_now(update_fn, state) do
    case update_fn.(state.agent) do
      %BaseAgentConfig{} = updated -> {:ok, put_agent(updated, state)}
      other -> {{:not_a_config, Describe.type_of(other)}, state}
    end
  end

```

and make both `put_agent/2` clauses return the state instead of a reply tuple:

```elixir
    {:reply, :ok,
     %{state | agent: new_agent, session: Turn.Session.put_config(state.session, new_agent)}}
```
→
```elixir
    %{state | agent: new_agent, session: Turn.Session.put_config(state.session, new_agent)}
```

and `defp put_agent(updated, state), do: {:reply, :ok, %{state | agent: updated}}` →
`defp put_agent(updated, state), do: %{state | agent: updated}`.

(g) Before `@impl true` / `def handle_info({:run_result, ref, result}, state) do` insert (and
drop that `@impl true`, which now sits on the first `handle_info/2` clause below):

```elixir
  # :inline: the turn in flight finished (or its worker died); start the next op.
  @impl true
  def handle_info({:inline_result, pid, result}, %{running: %{pid: pid} = running} = state) do
    Process.demonitor(running.ref, [:flush])
    {:noreply, state |> finish_op(running, result) |> dispatch()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref} = running} = state) do
    error = {:error, TurnError.from_reason({:task_down, reason})}
    {:noreply, state |> finish_op(running, error) |> dispatch()}
  end

```

(h) After the `# Private Functions` line insert:

```elixir

  # :inline ops run one at a time, oldest first: {:run, from, input, otel_ctx} and
  # {:update, from, update_fn}.
  defp enqueue(op, state), do: dispatch(%{state | queue: :queue.in(op, state.queue)})

  # Starts queued ops while no turn is in flight: an update applies at once, a run
  # starts a worker (and dispatching stops until it finishes).
  defp dispatch(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} -> state
      {{:value, op}, queue} -> dispatch(start_op(op, %{state | queue: queue}))
    end
  end

  defp dispatch(state), do: state

  defp start_op({:update, from, update_fn}, state) do
    {reply, state} = update_agent_now(update_fn, state)
    GenServer.reply(from, reply)
    state
  end

  defp start_op({:run, from, input, otel_ctx} = op, state) do
    if caller_alive?(from),
      do: start_turn(op, "Agent #{state.agent_id}", input, otel_ctx, state),
      else: state
  end

  # The worker gets the committed config, the input and the caller's OTel context, not
  # the process state.
  defp start_turn(op, who, input, otel_ctx, state) do
    agent = state.agent

    {pid, ref} =
      WatchedWorker.start(:inline_result, fn ->
        OtelCtx.restore(otel_ctx)
        inline_turn(agent, input, who)
      end)

    running = %{pid: pid, ref: ref, op: op, started: System.monotonic_time(:millisecond)}
    %{state | running: running}
  end

  defp finish_op(state, %{op: {:run, from, _input, _ctx}} = running, result) do
    state = %{state | running: nil}

    case result do
      {:ok, agent, value} ->
        GenServer.reply(from, {:ok, value})
        count_run(%{state | agent: agent}, running.started)

      {:error, _exception} = error ->
        GenServer.reply(from, error)
        state
    end
  end

  defp count_run(state, started) do
    %{
      state
      | run_count: state.run_count + 1,
        last_run: DateTime.utc_now(),
        total_runtime_ms: state.total_runtime_ms + System.monotonic_time(:millisecond) - started
    }
  end

  # A caller that died while its run waited (a Reactive task killed past its timeout)
  # gets no turn. Only a local pid can be checked; a remote caller's run always starts.
  defp caller_alive?({pid, _tag}) when node(pid) == node(), do: Process.alive?(pid)
  defp caller_alive?(_from), do: true

  # One inline turn, in the worker. A Normandy error is returned; a raise (a bug) is
  # logged (arities only) and returned bare; an exit or a throw is logged and becomes
  # the :task_down TurnError a worker dying of it would give.
  defp inline_turn(agent, input, who) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, updated_agent, response} -> {:ok, updated_agent, extract_result(response)}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> TurnError.log_raised(who, e, __STACKTRACE__)
  catch
    kind, reason when kind in [:exit, :throw] ->
      Logger.error("#{who} raised " <> TurnError.format_raised(kind, reason, __STACKTRACE__))
      {:error, TurnError.from_reason({:task_down, exit_reason(kind, reason)})}
  end
```

`Process.alive?/1` raises for a pid of another node, hence the `node/1` guard. The failed-run
stats rule is unchanged here (an inline error is not counted); Task 6.5d unifies it.

- [ ] **Step 5: Docs that describe the old shape**

`lib/normandy/turn_error.ex`, moduledoc: replace

```
  Normandy error). With `turn_engine: :server` the turn runs in a worker, and its crash
  is replied as a `:task_down` `TurnError`. In inline mode (the default) the turn runs in
  the process itself, and `run/3` and `cast/3` reply that exception bare, as
  `{:error, exception}`, rather than wrapping it.
```

with

```
  Normandy error). With `turn_engine: :server` it is replied as a `:task_down`
  `TurnError`. In inline mode (the default) `run/3` and `cast/3` reply that exception
  bare, as `{:error, exception}`, rather than wrapping it. In both modes the turn runs
  in a worker process: an exit or a throw in it, or the worker killed from outside, is a
  `:task_down` `TurnError`.
```

`lib/normandy/options.ex`, timeout table: `| \`:timeout\` | \`AgentProcess.run/3\` | 60_000 |` →
`| \`:timeout\` | \`AgentProcess.run/3\` | \`:infinity\` |`.

`lib/normandy/telemetry/killed_run.ex`, moduledoc: replace

```
    * Not emitted for agent processes (a pid in `Reactive.race/3`): killing
      the task that waits on `AgentProcess.run/3` does not kill the run, which
      ends normally in the agent process.
```

with

```
    * Not emitted for agent processes (a pid in `Reactive.race/3`): killing
      the task that waits on `AgentProcess.run/3` does not kill a run in flight,
      which ends normally in the agent process's worker; a run still queued
      behind another is skipped.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/coordination/ test/telemetry/span_hierarchy_test.exs test/log_policy_test.exs test/telemetry/killed_run_test.exs test/turn_error_test.exs test/options`
Expected: PASS (`agent_process_queue_test.exs`: 8 tests). Unchanged and passing:
`agent_process_test.exs` (incl. "handles multiple concurrent runs", `run_count == 10`, and
"run/3 replies a raised bug as the bare exception and logs arities only": the worker's
stacktrace still has `Normandy.Agents.BaseAgent.<fun>/<arity>` frames),
`log_policy_test.exs:88-106`, `killed_run_test.exs` (pid contestant not killed),
`reactive_test.exs:75-158` (PERF-14 acceptance, re-run here), `span_hierarchy_test.exs:693-735`.

- [ ] **Step 7: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.5c.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.5c.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite: `:server` mode, stores and the
registry are untouched.

- [ ] **Step 8: MIGRATING-2.0.md**

Append to `## 42.`:

```markdown
- An inline `AgentProcess` (the default `turn_engine`) no longer runs a turn inside its own
  `handle_call/3`. Runs and `update_agent/2` calls queue in arrival order and execute one at
  a time, each turn in a worker process. `get_agent/1`, `get_id/1`, `get_stats/1` and
  `approve/2` answer while a turn runs (they used to wait for it and exit after 5 s);
  `get_agent/1` returns the config as of the last finished turn.
- `AgentProcess.run/3` waits `:infinity` by default (was 60_000 ms), as `Turn.Server.run/2`
  does: a turn is bounded by its retries, tool timeouts and `max_tool_iterations`. Pass
  `timeout:` to keep a bound. A run whose caller died while it waited in the queue (a
  `Reactive` contestant killed past the race's `:timeout`) is skipped.
- An exit or a throw inside an inline turn is replied as
  `{:error, %Normandy.TurnError{type: :task_down}}` and logged; it used to crash the
  `AgentProcess`. A raised bug is still replied bare. `AgentProcess.stop/1` kills a turn in
  flight; a turn worker killed from outside is a `:task_down` `TurnError`.
```

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/watched_worker.ex lib/normandy/coordination/agent_process.ex \
  lib/normandy/turn_error.ex lib/normandy/options.ex lib/normandy/telemetry/killed_run.ex \
  test/coordination/agent_process_queue_test.exs MIGRATING-2.0.md
git commit -m "fix(coordination): inline AgentProcess runs turns from a FIFO queue in a worker"
```

---

### Task 6.5d: Casts share the queue and a bound; no unsupervised tasks (SEC-14)

Both cast paths use `Task.start`: unsupervised, unlinked, unbounded, outliving the process.
The inline one runs N turns concurrently from one memory snapshot, discards their memory, and
sends nothing to `reply_to` for an exit or a throw (inventory 6.5 §1 SEC-14). Per R10 (6.5 Q3):
inline casts join the 6.5c queue and keep their memory; `:server` runs and casts start through
`Normandy.WatchedWorker` (the monitor-ref handshake of `spawn_run/3` goes); runs and casts in
both modes are bounded by `:max_pending_runs` (default 100), refused with a `:queue_full`
`TurnError`.

Paths: `AgentProcess` only. `:server` turns still go through `Turn.Session.run/2`, so
`Turn.Server` and its tests are untouched. No telemetry event changes (a refused run starts no
run span).

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (moduledoc; `@start_link_opts_schema`; `init/1`; `handle_call({:run, _, _}, ...)`; `handle_cast({:run_async, ...}, ...)`; `handle_info/2` `:server` clauses; `start_op/2`; `finish_op/3`; new `admit/2`, `start_server_turn/2`, `notify/3`, `server_turn/3`; removed `spawn_run/3`, `handle_async_run/3`)
- Modify: `lib/normandy/turn_error.ex` (`:queue_full`: moduledoc bullet, `@types`, `@type type`, `message/1`, `from_reason/1`)
- Modify: `MIGRATING-2.0.md` (`## 42.`)
- Test: create `test/coordination/agent_process_pending_test.exs`

**Interfaces:**
- Consumes: Task 6.5c's queue (`enqueue/2`, `dispatch/1`, `start_turn/5`, `count_run/2`, `inline_turn/3`), `Normandy.WatchedWorker.start/2`, `Turn.Session.run/2`.
- Produces: `AgentProcess.start_link/1` option `:max_pending_runs` (`pos_integer | :infinity`, default `100`; header); `TurnError` type `:queue_full`, `reason` = the limit, message `"turn refused: queue full: <limit> run(s) already pending"`, built by `TurnError.from_reason({:queue_full, limit})`; state keys `max_pending_runs`, `pending` (runs and casts admitted, not finished, both modes), `pending_runs` now `%{watcher_pid => %{ref, op, started}}`; queue op `{:cast, reply_to, input, otel_ctx}`.

- [ ] **Step 1: Write the failing tests**

Create `test/coordination/agent_process_pending_test.exs` (same gate as Task 6.5c; in
`:server` mode the gated `call_llm` runs in the `Turn.Server` worker). The "Review Focus 4"
test is header Review Focus #4:

```elixir
defmodule Normandy.Coordination.AgentProcessPendingTest do
  @moduledoc """
  Task 6.5d (SEC-14): casts go through the same admission as runs. Inline casts are
  queued and keep their memory; `:max_pending_runs` bounds runs and casts in both
  modes; every worker dies with its process.

  LLM calls are gated as in `AgentProcessQueueTest`: `{:llm_started, n, worker}`, then
  `{:release, n}` to that worker.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  # How long a gate event may take to arrive. A turn's worker reaches the client after
  # BaseAgent's setup, which under a loaded suite (async DSL tests compiling modules)
  # has taken over ExUnit's default 100 ms; the events always come, so wait for them.
  @wait 5_000

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.PromptSpecification
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Test.StubClient
  alias Normandy.TurnError

  defp gate do
    parent = self()
    calls = :atomics.new(1, [])

    fn ->
      n = :atomics.add_get(calls, 1, 1)
      send(parent, {:llm_started, n, self()})

      receive do
        {:release, ^n} -> n
      end
    end
  end

  defp gated_agent do
    wait = gate()

    BaseAgent.init(%{
      client: %StubClient{reply: fn rm -> %{rm | chat_message: "answer #{wait.()}"} end},
      model: "m"
    })
  end

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Memory encodes every entry when it is appended (Task 6.1a): the output needs an impl.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # A :server-mode template whose LLM call is gated (the Turn.Server worker runs it).
  defp gated_server_start(extra) do
    wait = gate()

    config = %BaseAgentConfig{
      output_schema: %Resp{},
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{}
    }

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: "answer #{wait.()}"} end
    }

    AgentProcess.start_link([agent: config, turn_engine: :server, handlers: handlers] ++ extra)
  end

  describe "inline cast/3" do
    test "is queued behind runs and keeps its turn in memory" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "c")
      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker1}, @wait

      :ok = AgentProcess.cast(pid, "two", reply_to: self())
      refute_received {:llm_started, 2, _}

      send(worker1, {:release, 1})
      assert {:ok, "answer 1"} = Task.await(run)

      assert_receive {:llm_started, 2, worker2}, @wait
      send(worker2, {:release, 2})
      assert_receive {:agent_result, "c", {:ok, "answer 2"}}, @wait

      assert AgentMemory.count_messages(AgentProcess.get_agent(pid).memory) == 4
      assert %{run_count: 2} = AgentProcess.get_stats(pid)
    end

    test "an exit in the cast's turn still reaches reply_to" do
      agent =
        BaseAgent.init(%{client: %StubClient{reply: fn _ -> exit(:gone) end}, model: "m"})

      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "c_exit")
      :ok = AgentProcess.cast(pid, "go", reply_to: self())

      assert_receive {:agent_result, "c_exit",
                      {:error, %TurnError{type: :task_down, reason: :gone}}},
                     @wait
    end

    test "a reply_to name that is not registered does not stop the process" do
      {:ok, pid} =
        AgentProcess.start_link(agent: BaseAgent.init(%{client: %StubClient{}, model: "m"}))

      :ok = AgentProcess.cast(pid, "go", reply_to: :normandy_no_such_process)
      assert {:ok, _} = AgentProcess.run(pid, "after")
      assert %{run_count: 2} = AgentProcess.get_stats(pid)
    end

    test "stop/1 kills the cast in flight" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
      :ok = AgentProcess.cast(pid, "go")
      assert_receive {:llm_started, 1, worker}, @wait
      ref = Process.monitor(worker)

      :ok = AgentProcess.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @wait
    end
  end

  describe ":max_pending_runs" do
    test "inline: the run or cast past the limit is refused at once, the others complete" do
      {:ok, pid} =
        AgentProcess.start_link(agent: gated_agent(), agent_id: "b", max_pending_runs: 2)

      :ok = AgentProcess.cast(pid, "one", reply_to: self())
      assert_receive {:llm_started, 1, worker1}, @wait
      :ok = AgentProcess.cast(pid, "two", reply_to: self())

      :ok = AgentProcess.cast(pid, "three", reply_to: self())

      assert_receive {:agent_result, "b",
                      {:error, %TurnError{type: :queue_full, reason: 2} = refused}},
                     @wait

      assert Exception.message(refused) == "turn refused: queue full: 2 run(s) already pending"

      assert {:error, %TurnError{type: :queue_full, reason: 2}} = AgentProcess.run(pid, "four")

      send(worker1, {:release, 1})
      assert_receive {:agent_result, "b", {:ok, "answer 1"}}, @wait
      assert_receive {:llm_started, 2, worker2}, @wait
      send(worker2, {:release, 2})
      assert_receive {:agent_result, "b", {:ok, "answer 2"}}, @wait

      # Room again once they finished.
      task = Task.async(fn -> AgentProcess.run(pid, "five") end)
      assert_receive {:llm_started, 3, worker3}, @wait
      send(worker3, {:release, 3})
      assert {:ok, "answer 3"} = Task.await(task)
      assert %{run_count: 3} = AgentProcess.get_stats(pid)
    end

    test "Review Focus 4: a long run, reads during it, 100 casts at the default limit, a dead caller" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "rf4")
      caller = spawn(fn -> AgentProcess.run(pid, "long") end)
      assert_receive {:llm_started, 1, worker1}, @wait

      assert %{run_count: 0} = AgentProcess.get_stats(pid)
      assert AgentMemory.count_messages(AgentProcess.get_agent(pid).memory) == 0

      # The run in flight is 1 of the default 100: casts 1..99 are admitted, cast 100 is not.
      for i <- 1..100, do: :ok = AgentProcess.cast(pid, "cast #{i}", reply_to: self())

      assert_receive {:agent_result, "rf4", {:error, %TurnError{type: :queue_full, reason: 100}}},
                     @wait

      # The caller dies mid-run; its turn still finishes and is kept.
      caller_ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @wait

      worker_ref = Process.monitor(worker1)
      send(worker1, {:release, 1})
      assert_receive {:DOWN, ^worker_ref, :process, ^worker1, _reason}, @wait

      for n <- 2..100 do
        assert_receive {:llm_started, ^n, worker}, @wait
        send(worker, {:release, n})
        expected = "answer #{n}"
        assert_receive {:agent_result, "rf4", {:ok, ^expected}}, @wait
      end

      refute_received {:agent_result, "rf4", {:error, _}}
      assert AgentMemory.count_messages(AgentProcess.get_agent(pid).memory) == 200
      assert %{run_count: 100} = AgentProcess.get_stats(pid)
      assert %{running: nil, pending: 0} = :sys.get_state(pid)
    end

    test "update_agent/2 is not a pending run" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), max_pending_runs: 1)
      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker1}, @wait

      update = Task.async(fn -> AgentProcess.update_agent(pid, &%{&1 | temperature: 0.1}) end)
      assert {:error, %TurnError{type: :queue_full}} = AgentProcess.run(pid, "two")

      send(worker1, {:release, 1})
      assert {:ok, "answer 1"} = Task.await(run)
      assert :ok = Task.await(update)
    end

    test ":server: the run or cast past the limit is refused at once" do
      {:ok, pid} = gated_server_start(agent_id: "s", max_pending_runs: 1)
      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker}, @wait

      assert {:error, %TurnError{type: :queue_full, reason: 1}} = AgentProcess.run(pid, "two")
      :ok = AgentProcess.cast(pid, "three", reply_to: self())
      assert_receive {:agent_result, "s", {:error, %TurnError{type: :queue_full}}}, @wait

      send(worker, {:release, 1})
      assert {:ok, %Resp{content: "answer 1"}} = Task.await(run)
    end

    test "is validated by start_link/1" do
      agent = BaseAgent.init(%{client: %StubClient{}, model: "m"})

      error =
        assert_raise ArgumentError, fn ->
          AgentProcess.start_link(agent: agent, max_pending_runs: 0)
        end

      assert error.message =~
               "Normandy.Coordination.AgentProcess.start_link/1: expected :max_pending_runs " <>
                 "option to match at least one given type"

      assert error.message =~ "expected positive integer, got: 0"

      assert {:ok, _pid} = AgentProcess.start_link(agent: agent, max_pending_runs: :infinity)
    end
  end

  describe ":server workers" do
    test "stop/1 kills a cast's worker" do
      {:ok, pid} = gated_server_start([])
      :ok = AgentProcess.cast(pid, "go")
      assert_receive {:llm_started, 1, _turn_worker}, @wait

      %{pending_runs: pending} = :sys.get_state(pid)
      assert [watcher] = Map.keys(pending)
      ref = Process.monitor(watcher)

      :ok = AgentProcess.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}, @wait
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/coordination/agent_process_pending_test.exs`
Expected: FAIL, 9 of 10 tests (observed on Task 6.5c's code):
- the three tests that start a process with `max_pending_runs:` raise
  `** (ArgumentError) Normandy.Coordination.AgentProcess.start_link/1: unknown option :max_pending_runs; supported: :agent, ...`;
  "is validated by start_link/1" fails its `=~` on that same message;
- "is queued behind runs and keeps its turn in memory": `assert AgentMemory.count_messages(...) == 4`, left `2` (the cast's memory is discarded);
- "an exit in the cast's turn still reaches reply_to": `no matching message after 100ms` (the cast `Task` dies with `:gone`);
- "inline cast/3 stop/1 kills the cast in flight": `no matching message after 100ms` for the `:DOWN` (the cast `Task` outlives the process);
- "Review Focus 4 ...": `no matching message after 100ms` for the `:queue_full` result;
- ":server workers stop/1 kills a cast's worker": `assert [watcher] = Map.keys(pending)` (the cast is a `Task`, not in `pending_runs`).

"a reply_to name that is not registered does not stop the process" passes already (it guards
the new `notify/3`).

- [ ] **Step 3: `TurnError` `:queue_full`**

In `lib/normandy/turn_error.ex`:

- moduledoc type list, after the `:session_unavailable` bullet (after Task 6.3e its last line
  is ``is not the supervisor's (`reason: {:not_stopped, :not_found}`)``; on `d624fbf` it was the
  `` `Turn.Session.approve/2` returns it with `reason: :no_session` ...`` line) insert:

```
    * `:queue_full` - `Normandy.Coordination.AgentProcess` refused a run or cast because
      `:max_pending_runs` runs and casts were already queued or in flight; `:reason` is
      that limit. Nothing ran
```

- `@types`: insert `:queue_full,` after `:session_unavailable,`; `@type type`: insert
  `| :queue_full` after `| :session_unavailable`.
- Before the catch-all `def message(%__MODULE__{type: type, reason: reason}),` insert:

```elixir
  def message(%__MODULE__{type: :queue_full, reason: limit}),
    do: "turn refused: queue full: #{inspect(limit)} run(s) already pending"

```

- Before `def from_reason({:unexpected_event, _state, _event} = reason),` insert:

```elixir
  def from_reason({:queue_full, limit}), do: %__MODULE__{type: :queue_full, reason: limit}

```

(If Task 6.4c changed `describe/1` or the credential clause of `from_reason/1`, these anchors
are still the catch-all `message/1` and the `:unexpected_event` clause.)

- [ ] **Step 4: Admission in `AgentProcess`**

All edits in `lib/normandy/coordination/agent_process.ex`, on Task 6.5c's version.

(a) Moduledoc: replace the "Inline turns" paragraph (Task 6.5c) with:

```
  With `turn_engine: :inline`, runs, casts and `update_agent/2` calls go through one FIFO
  queue and execute one at a time, each turn in a worker process started from the config
  the previous one left, so a cast's turn is kept in memory like a run's. The process
  itself never waits on a turn: `get_agent/1` (the config as of the last finished turn),
  `get_id/1`, `get_stats/1` and `approve/2` answer at once while a turn runs. A run whose
  caller died while it waited in the queue is skipped. The worker dies with the process
  (`stop/1` kills a turn in flight); a worker killed from outside replies a `:task_down`
  `Normandy.TurnError`.
```

After that paragraph insert:

```
  ## Pending runs

  Runs and casts that were admitted and have not finished (queued or in flight, in
  either mode) are bounded by `:max_pending_runs` (default 100). One more is refused at
  once: `run/3` returns, and `cast/3` sends to `:reply_to`,
  `{:error, %Normandy.TurnError{type: :queue_full, reason: limit}}`. `get_stats/1`'s
  `run_count` counts runs and casts that finished, failed ones included.

```

(b) `@start_link_opts_schema`: after the `idle_timeout_ms:` entry (add a comma after its
closing `]`) insert:

```elixir
                            max_pending_runs: [
                              type: {:or, [:pos_integer, {:in, [:infinity]}]},
                              default: 100,
                              type_doc: "a positive integer or `:infinity`",
                              doc:
                                "Runs and casts admitted and not finished (queued or in " <>
                                  "flight). One more is refused with a `:queue_full` " <>
                                  "`Normandy.TurnError`."
                            ]
```

`AgentSupervisor.start_agent/2` builds its schema from `__opts_schema__(:start_link)`, so it
accepts the option too.

(c) `init/1`, `base` map: put `# :server mode: worker pid => %{ref, op, started}, one per admitted run or cast.`
on the line above `pending_runs: %{},`, and replace `created_at: DateTime.utc_now()` with:

```elixir
      created_at: DateTime.utc_now(),
      max_pending_runs: Keyword.fetch!(opts, :max_pending_runs),
      # Runs and casts admitted and not finished, both modes (see admit/2).
      pending: 0
```

(d) Replace the `:server` run clause
(`def handle_call({:run, input, otel_ctx}, from, %{turn_engine: :server} = state) do` ... `end`)
and Task 6.5c's inline run clause (with its comment and `@impl true`) by one clause, keeping
the two comment lines above (`# The caller's OTel context rides in the call ...`):

```elixir
  def handle_call({:run, input, otel_ctx}, from, state) do
    case admit({:run, from, input, otel_ctx}, state) do
      {:ok, state} -> {:noreply, state}
      {:error, _} = full -> {:reply, full, state}
    end
  end
```

(e) Replace both `handle_cast({:run_async, input, reply_to, otel_ctx}, ...)` clauses (the
`:server` one with its `Task.start` and the inline one with its `Task.start`), and
`spawn_run/3` with its comment, by:

```elixir
  def handle_cast({:run_async, input, reply_to, otel_ctx}, state) do
    case admit({:cast, reply_to, input, otel_ctx}, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _} = full ->
        notify(reply_to, state.agent_id, full)
        {:noreply, state}
    end
  end
```

The three-element `{:run_async, input, reply_to}` clause above stays.

(f) Replace `handle_info({:run_result, ref, result}, state)` and the `:server`
`handle_info({:DOWN, ref, :process, _pid, reason}, state)` (with its `@impl true`) by:

```elixir
  # :server: a turn finished (or its worker died).
  def handle_info({:server_result, pid, result}, %{turn_engine: :server} = state) do
    case Map.pop(state.pending_runs, pid) do
      {nil, _pending} ->
        {:noreply, state}

      {running, pending_runs} ->
        Process.demonitor(running.ref, [:flush])
        {:noreply, finish_op(%{state | pending_runs: pending_runs}, running, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{turn_engine: :server} = state) do
    case Map.pop(state.pending_runs, pid) do
      {%{ref: ^ref} = running, pending_runs} ->
        error = {:error, TurnError.from_reason({:task_down, reason})}
        {:noreply, finish_op(%{state | pending_runs: pending_runs}, running, error)}

      _not_a_worker ->
        {:noreply, state}
    end
  end
```

The catch-all `handle_info(msg, state)` stays last.

(g) Private functions. Replace Task 6.5c's `enqueue/2` comment and definition with:

```elixir
  # A run ({:run, from, input, otel_ctx}) or cast ({:cast, reply_to, input, otel_ctx}) is
  # admitted while fewer than :max_pending_runs are pending: :server starts its worker at
  # once (Turn.Server serializes the turns), :inline queues it.
  defp admit(_op, %{max_pending_runs: max, pending: pending})
       when max != :infinity and pending >= max,
       do: {:error, TurnError.from_reason({:queue_full, max})}

  defp admit(op, state) do
    state = %{state | pending: state.pending + 1}

    case state.turn_engine do
      :server -> {:ok, start_server_turn(op, state)}
      :inline -> {:ok, enqueue(op, state)}
    end
  end

  # :inline ops run one at a time, oldest first: runs, casts and {:update, from, update_fn}.
  defp enqueue(op, state), do: dispatch(%{state | queue: :queue.in(op, state.queue)})
```

In `start_op({:run, ...})` replace `else: state` with `else: %{state | pending: state.pending - 1}`,
and add after that clause:

```elixir

  defp start_op({:cast, _reply_to, input, otel_ctx} = op, state),
    do: start_turn(op, "Async agent #{state.agent_id}", input, otel_ctx, state)
```

Replace Task 6.5c's `finish_op/3` with:

```elixir
  defp start_server_turn({_kind, _to, input, otel_ctx} = op, state) do
    session = state.session

    who =
      if elem(op, 0) == :run, do: "Agent #{state.agent_id}", else: "Async agent #{state.agent_id}"

    {pid, ref} =
      WatchedWorker.start(:server_result, fn ->
        OtelCtx.restore(otel_ctx)
        server_turn(session, prepare_input(input), who)
      end)

    running = %{ref: ref, op: op, started: System.monotonic_time(:millisecond)}
    %{state | pending_runs: Map.put(state.pending_runs, pid, running)}
  end

  # A finished run or cast: an inline turn's config is committed, the result goes to the
  # caller or reply_to, and the turn is counted whatever its outcome.
  defp finish_op(state, running, {:ok, agent, value}),
    do: finish_op(%{state | agent: agent}, running, {:ok, value})

  defp finish_op(state, %{op: op, started: started}, result) do
    case op do
      {:run, from, _input, _ctx} -> GenServer.reply(from, result)
      {:cast, reply_to, _input, _ctx} -> notify(reply_to, state.agent_id, result)
    end

    count_run(%{state | running: nil, pending: state.pending - 1}, started)
  end

  defp notify(nil, _agent_id, _result), do: :ok

  defp notify(reply_to, agent_id, result) when is_pid(reply_to),
    do: send(reply_to, {:agent_result, agent_id, result})

  # A name that is not registered must not crash this process (send/2 raises for it).
  defp notify(reply_to, agent_id, result) when is_atom(reply_to) do
    case Process.whereis(reply_to) do
      nil ->
        Logger.warning(
          "AgentProcess #{agent_id}: reply_to #{inspect(reply_to)} is not a registered " <>
            "process; the result is dropped"
        )

      pid ->
        send(pid, {:agent_result, agent_id, result})
    end
  end
```

Before the `exit_reason/2` comment insert, and change that comment's second line to
`# in a worker maps like the same failure arriving as its :DOWN.`:

```elixir
  # One :server turn, in the worker: the Turn.Session reply, or any raise, exit or throw
  # logged (arities only) and turned into the reply a worker dying of it would give (a
  # domain exception bare, anything else a :task_down TurnError).
  defp server_turn(session, user_input, who) do
    case Turn.Session.run(session, user_input) do
      {:ok, value} -> {:ok, extract_result(value)}
      {:error, _} = error -> error
    end
  catch
    kind, reason ->
      Logger.error("#{who} raised " <> TurnError.format_raised(kind, reason, __STACKTRACE__))
      {:error, TurnError.from_reason({:task_down, exit_reason(kind, reason)})}
  end

```

Delete `handle_async_run/3`. Check: `grep -n "Task.start\|spawn_run\|handle_async_run\|run_result\|monitor_ref" lib/normandy/coordination/agent_process.ex`
prints nothing.

`server_turn/3` keeps the replies `agent_process_server_test.exs` "run/3 and cast/3 reply the
same exception for ..." pins (a raised bug `:task_down` with the exception, a raised
`LLMError` bare, a throw `{:nocatch, _}`), and the stacktrace is logged once, by tag, instead
of by the emulator's crash report of a raw `spawn`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/coordination/ test/telemetry/span_hierarchy_test.exs test/log_policy_test.exs test/telemetry/killed_run_test.exs test/turn_error_test.exs test/options test/security/low_findings_test.exs`
Expected: PASS (`agent_process_pending_test.exs`: 10 tests). Unchanged and passing:
`agent_process_test.exs` "cast/3 sends a raised bug as the bare exception and logs it"
(`"Async agent async_buggy raised RuntimeError"`), "updates statistics even for async calls"
(`wait_until` on `run_count == 2`, now counted at completion), "async execution doesn't block
GenServer"; `agent_process_server_test.exs:197-240, 380-439`; `span_hierarchy_test.exs`
"AgentProcess.cast nests the run under the caller".

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.5d.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.5d.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite (`:server` mode runs on the
InMemory store and Native/supplied registries only; no store or registry code changes).

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 42.`:

```markdown
- An inline `AgentProcess.cast/3` joins the run queue: casts run one at a time, in order with
  runs, and each cast's turn is kept in the agent's memory. Inline casts used to run
  concurrently from one memory snapshot and discard what they added. For parallel fan-out
  use `Reactive.all/3` or `ParallelOrchestrator`. `reply_to` now hears back for every
  outcome, an exit or a throw included (an inline cast sent nothing for those).
- `AgentProcess.start_link/1` (and `AgentSupervisor.start_agent/2`) take
  `:max_pending_runs` (default 100): runs and casts queued or in flight, in either
  `turn_engine`. One more is refused at once with
  `{:error, %Normandy.TurnError{type: :queue_full, reason: limit}}` (returned by `run/3`, sent
  to a cast's `reply_to`). `max_pending_runs: :infinity` keeps 1.x's unbounded behaviour.
  `Normandy.TurnError` has the new type `:queue_full`.
- Run and cast workers are no longer unsupervised `Task`s that outlive the process: they die
  with the `AgentProcess`. A cast in flight when the process stops is killed and its
  `reply_to` hears nothing.
- `get_stats/1` counts a run or cast when it finishes, whatever its outcome (casts were
  counted when cast; failed inline runs were not counted).
- A `reply_to` name that is not registered is logged and the result dropped.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex lib/normandy/turn_error.ex \
  test/coordination/agent_process_pending_test.exs MIGRATING-2.0.md
git commit -m "fix(coordination): AgentProcess casts share the run queue and a pending-run bound"
```

---
### Task 6.5e: `:server`-mode `AgentProcess` registers in one shared, scoped registry (atom leak)

Without `:registry`, each `:server`-mode `AgentProcess` starts a `Native` registry named
`:"agentprocess_reg_#{n}"`, leaking about 3 atoms per start (the name plus the `Registry`'s
partition names; probe: 200 starts → 670 atoms; inventory 6.5 Surprise 4). Per R10 (6.5 Q4):
Normandy's application starts one unique `Registry`, and each such process gets a scope of its
own in it (`make_ref()`), keyed `{scope, session_id}`, so two processes with the same
`agent_id` and their own stores never see each other's servers. Entries go with the
registering `Turn.Server`.

**Files:**
- Create: `lib/normandy/coordination/agent_process/scoped_registry.ex` (`Normandy.Coordination.AgentProcess.ScopedRegistry`, `@moduledoc false`)
- Modify: `lib/normandy/application.ex` (one more child)
- Modify: `lib/normandy/coordination/agent_process.ex` (moduledoc, `:registry` option doc, aliases, `server_infra/1`)
- Modify: `MIGRATING-2.0.md` (`## 42.`)
- Test: create `test/coordination/agent_process_registry_test.exs`; modify `test/coordination/agent_process_server_test.exs` (":server infra ownership")

**Interfaces:**
- Consumes: `Normandy.Behaviours.SessionRegistry` callbacks; `Turn.Server` self-registration (`child_name/2` → `:self_register`; after Task 6.2c a `{:error, :taken}` from `register/3` stops the duplicate with `{:already_started, pid}`).
- Produces: `ScopedRegistry.new() :: {atom(), reference()}`, `ScopedRegistry.registry_name() :: atom()` (= `Normandy.Coordination.AgentProcess.Registry`), `whereis/2`, `register/3`, `unregister/2`, `child_name/2`; handle `{Normandy.Coordination.AgentProcess.Registry, scope}`.

- [ ] **Step 1: Write the failing tests**

Create `test/coordination/agent_process_registry_test.exs` (`async: false`: it counts atoms
node-wide; ExUnit runs sync modules alone):

```elixir
defmodule Normandy.Coordination.AgentProcessRegistryTest do
  @moduledoc """
  Task 6.5e: a `:server`-mode `AgentProcess` started without a `:registry` uses a scope
  in Normandy's shared registry, so starting one creates no atom, and two with the same
  agent id never see each other's servers.
  """
  # Counts atoms node-wide: nothing else may run.
  use ExUnit.Case, async: false

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.PromptSpecification
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Coordination.AgentProcess.ScopedRegistry

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Memory encodes every entry when it is appended (Task 6.1a): the output needs an impl.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  defp config do
    %BaseAgentConfig{
      output_schema: %Resp{},
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{}
    }
  end

  defp handlers(text) do
    %{BaseAgent.non_streaming_handlers() | call_llm: fn _c, _s, _r -> %Resp{content: text} end}
  end

  defp start_run_stop do
    {:ok, pid} =
      AgentProcess.start_link(agent: config(), turn_engine: :server, handlers: handlers("ok"))

    {:ok, _} = AgentProcess.run(pid, "go")
    :ok = AgentProcess.stop(pid)
  end

  test "starting, running and stopping a :server AgentProcess creates no atom" do
    # Warm up: module loading and first-use atoms.
    start_run_stop()
    before = :erlang.system_info(:atom_count)

    for _ <- 1..50, do: start_run_stop()

    assert :erlang.system_info(:atom_count) == before
  end

  test "two processes with the same agent id run separate sessions" do
    {:ok, a} =
      AgentProcess.start_link(
        agent: config(),
        agent_id: "same",
        turn_engine: :server,
        handlers: handlers("from a")
      )

    {:ok, b} =
      AgentProcess.start_link(
        agent: config(),
        agent_id: "same",
        turn_engine: :server,
        handlers: handlers("from b")
      )

    assert {:ok, %Resp{content: "from a"}} = AgentProcess.run(a, "go")
    assert {:ok, %Resp{content: "from b"}} = AgentProcess.run(b, "go")

    %{session: %{registry: {ScopedRegistry, {_name, scope_a}}}} = :sys.get_state(a)
    %{session: %{registry: {ScopedRegistry, {_name, scope_b}}}} = :sys.get_state(b)
    assert scope_a != scope_b
  end

  test "a server's entry goes with it" do
    {:ok, pid} =
      AgentProcess.start_link(
        agent: config(),
        agent_id: "gone",
        turn_engine: :server,
        handlers: handlers("ok")
      )

    {:ok, _} = AgentProcess.run(pid, "go")
    %{session: %{registry: {ScopedRegistry, handle}}} = :sys.get_state(pid)
    assert {:ok, server} = ScopedRegistry.whereis(handle, "gone")

    ref = Process.monitor(server)
    :ok = AgentProcess.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^server, _reason}

    assert wait_until(fn ->
             ScopedRegistry.whereis(handle, "gone") == :none
           end)
  end
end
```

In `test/coordination/agent_process_server_test.exs`, add
`alias Normandy.Coordination.AgentProcess.ScopedRegistry` after
`alias Normandy.Coordination.AgentProcess`, and in
`test "self-contained mode starts and owns store/registry/supervisor; stop tears them down"`
replace

```elixir
          registry: {_rm, reg_name},
```

with `registry: {ScopedRegistry, {reg_name, scope}},` and

```elixir
      assert is_atom(reg_name)
      assert is_pid(sup)
      assert owned != []
```

with

```elixir
      # A scope in Normandy's shared registry: nothing to start or own.
      assert reg_name == ScopedRegistry.registry_name()
      assert is_reference(scope)
      assert is_pid(sup)
      assert Enum.sort(owned) == Enum.sort([store_h, sup])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/coordination/agent_process_registry_test.exs test/coordination/agent_process_server_test.exs`
Expected: FAIL, 4 tests. "creates no atom": `assert :erlang.system_info(:atom_count) == before`
(left about 150 more than right, ~3 per start; observed 151 stacked); the other two registry tests and the ownership test:
`** (MatchError) no match of right hand side value` on the `{ScopedRegistry, ...}` pattern
(they compile with an undefined-module warning for `ScopedRegistry`).

- [ ] **Step 3: The scoped registry**

Create `lib/normandy/coordination/agent_process/scoped_registry.ex`:

```elixir
defmodule Normandy.Coordination.AgentProcess.ScopedRegistry do
  @moduledoc false
  # The SessionRegistry a :server-mode AgentProcess uses when it is given none: one
  # unique Registry started by Normandy.Application (@registry), shared by every such
  # process, with a scope per process so two of them with the same agent id (and their
  # own stores) never see each other's servers. The handle is {@registry, scope}; keys
  # are {scope, session_id}. A Turn.Server registers itself, and its entry goes with it.
  # Starting one creates no atom (a Native registry per process created ~3).
  @behaviour Normandy.Behaviours.SessionRegistry

  @registry Normandy.Coordination.AgentProcess.Registry

  @doc false
  @spec registry_name() :: atom()
  def registry_name, do: @registry

  @doc false
  @spec new() :: {atom(), reference()}
  def new, do: {@registry, make_ref()}

  @impl true
  def whereis({registry, scope}, session_id) do
    case Registry.lookup(registry, {scope, session_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :none
    end
  end

  @impl true
  def register({registry, scope}, session_id, pid) when pid == self() do
    case Registry.register(registry, {scope, session_id}, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :taken}
    end
  end

  @impl true
  def unregister({registry, scope}, session_id) do
    Registry.unregister(registry, {scope, session_id})
  end

  @impl true
  def child_name(_handle, _session_id), do: :self_register
end
```

`lib/normandy/application.ex`: after `use Application` add

```elixir

  alias Normandy.Coordination.AgentProcess.ScopedRegistry
```

and append to `children` (after the breaker `DynamicSupervisor` entry; add the comma):

```elixir
      {Registry, keys: :unique, name: ScopedRegistry.registry_name()}
```

Update the comment above `use Application` to:

```elixir
  # Normandy's own processes: the keyed circuit breakers (Normandy.Resilience.CircuitBreaker)
  # and the registry :server-mode AgentProcesses share (AgentProcess.ScopedRegistry).
  # :rest_for_one, so a crashed breaker Registry also stops every breaker (their
  # registrations are gone; they are `restart: :temporary`). Each starts again, closed, on
  # its next call. The AgentProcess registry is last: its crash stops nothing else.
```

`Registry.child_spec/1` uses the name as the child id, so the two `Registry` children do not
clash.

- [ ] **Step 4: `AgentProcess` uses it**

In `lib/normandy/coordination/agent_process.ex`:

- Aliases: delete `alias Normandy.Behaviours.SessionRegistry.Native`; after
  `alias Normandy.Components.ContentBlock.Describe` add
  `alias Normandy.Coordination.AgentProcess.ScopedRegistry`.
- `@start_link_opts_schema`, `registry:` doc: `"Without it the process starts and owns a \`Native\` registry."` →
  `"Without it the process uses a scope of its own in a " <> "registry Normandy starts."` (split as the neighbouring docs are).
- Moduledoc, the "Session infra" bullet: replace
  `` `start_link`; if omitted, the process starts and owns in-memory defaults`` /
  `that terminate with it. \`start_link\` builds one \`Turn.Session\` from them and from` with:

```
    `start_link`; if omitted, the process starts and owns an in-memory store and a
    `Turn.Supervisor` that terminate with it, and registers its sessions under a scope
    of its own in a registry Normandy starts (no atom per process). `start_link` builds
    one `Turn.Session` from them and from
```

- `server_infra/1`: replace the `{registry, owned_reg} = case Keyword.get(opts, :registry) do ... end`
  block with

```elixir
    # Without a :registry, a scope in Normandy's shared registry: nothing to start or own.
    registry = Keyword.get_lazy(opts, :registry, fn -> {ScopedRegistry, ScopedRegistry.new()} end)
```

  and `{:ok, store, registry, supervisor, owned_store ++ owned_reg ++ owned_sup}` with
  `{:ok, store, registry, supervisor, owned_store ++ owned_sup}`.

Check: `grep -n "Native\|agentprocess_reg" lib/normandy/coordination/agent_process.ex` prints nothing.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/coordination/ test/telemetry/span_hierarchy_test.exs test/normandy_application_test.exs`
Expected: PASS (`agent_process_registry_test.exs`: 3 tests).

- [ ] **Step 6: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.5e.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.5e.log`, `mix docs --warnings-as-errors`, and, after `docker start normandy-test-pg`, `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres` (this task changes a `Turn.Server` start path's registry; one distributed test, `eager_handoff_distributed_test.exs:111`, needs Postgres).
Expected: ` 0 failures`, exit 0 for each; docs exit 0. Not run: `mix test.redis`, `mix test.postgres` (no store or Redis/Horde registry code changes).

- [ ] **Step 7: MIGRATING-2.0.md**

Append to `## 42.`:

```markdown
- A `:server`-mode `AgentProcess` started without `:registry` no longer starts and owns a
  `Native` registry of its own (each one created about three atoms that were never freed).
  Its sessions register under a scope of its own in one registry that Normandy's application
  starts; two processes with the same `agent_id` still never see each other's servers. A
  supplied `:registry` is used as before.
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/coordination/agent_process/scoped_registry.ex lib/normandy/application.ex \
  lib/normandy/coordination/agent_process.ex test/coordination/agent_process_registry_test.exs \
  test/coordination/agent_process_server_test.exs MIGRATING-2.0.md
git commit -m "fix(coordination): :server AgentProcess shares one scoped registry instead of one per process"
```

---

### Task 6.5f: Coordination leftovers (pool order, StatefulContext, SharedContext, HierarchicalCoordinator errors, Reactive pid timeout, Workflow and guardrail docs)

The July and Wave 5 leftovers that R10 settles: AgentPool `:lifo`/`:fifo` fixed to their docs
(Q8); `StatefulContext` docs corrected and its table `:protected` (Q6); one `SharedContext`
sentence; `HierarchicalCoordinator` returns decision-6 shapes and documents the aggregation as a
fresh conversation (Q7); `Reactive`'s pid branch waits `:infinity` explicitly (PERF-13 after
Task 6.5c); the unreachable Workflow DSL blank-answer example replaced; the
`:incremental` guardrail cost documented (B6, Q10); and (H9, verified at preflight)
`create_conditional_specs/2` stops making an atom of every worker id (`String.to_atom(worker.id)`:
a fresh worker id run through `:conditional` left an atom of that name). PERF-14 needs no code: its acceptance is
`test/coordination/reactive_test.exs:75-158`, re-run in Step 5.

Task 6.4e added the `[:normandy, :agent_pool, :checkout]` event to `agent_pool.ex` at the reply
sites (`handle_call({:checkout, ...})`, `hand_to_waiter/2`, the `{:checkout_timeout, from}`
clause); this task changes only `do_checkout/1`'s second clause and adds no event.

**Files:**
- Modify: `lib/normandy/coordination/agent_pool.ex` (`do_checkout/1`)
- Modify: `lib/normandy/coordination/stateful_context.ex` (moduledoc, `fetch/2` doc, `get_table/1` doc, `init/1`)
- Modify: `lib/normandy/coordination/shared_context.ex` (moduledoc)
- Modify: `lib/normandy/coordination/hierarchical_coordinator.ex` (moduledoc, specs, `run_hierarchy/3`, `execute_manager/3`, new `run_manager/3`, `aggregate_with_manager/3`, alias, `create_conditional_specs/2`, new `plan_task/2`)
- Modify: `lib/normandy/coordination/reactive.ex` (`run_one/2` pid clause)
- Modify: `lib/normandy/dsl/workflow.ex` (moduledoc "Conditional Execution", `when_result/1` doc)
- Modify: `lib/normandy/guardrails.ex` (moduledoc, `:incremental` bullet)
- Modify: `MIGRATING-2.0.md` (`## 42.`)
- Test: modify `test/coordination/agent_pool_test.exs`, `test/coordination/stateful_context_test.exs`, `test/coordination/hierarchical_coordinator_test.exs`, `test/dsl/workflow_transform_integration_test.exs`

**Interfaces:**
- Consumes: `BaseAgent.run/3`, `TurnError.log_raised/3`, `TurnError.from_reason/1`, `AgentProcess.run/3` (Task 6.5c).
- Produces: `HierarchicalCoordinator.execute/3` → `{:ok, term()} | {:error, {:manager_failed | :aggregation_failed, Exception.t()}}`; `execute_with_tasks/3` → `{:ok, term()} | {:error, {:aggregation_failed, Exception.t()}}`.

- [ ] **Step 1: Write the failing tests**

`test/coordination/agent_pool_test.exs`: insert before `describe "transaction/3" do`:

```elixir
  describe "checkout strategy" do
    # Size 2, no overflow: check out both, return a then b (casts, ordered by the
    # stats/1 call behind them), then check out one.
    defp checkout_after_returns(strategy) do
      {:ok, pool} =
        AgentPool.start_link(
          agent_config: create_agent_config(),
          size: 2,
          max_overflow: 0,
          strategy: strategy
        )

      {:ok, a} = AgentPool.checkout(pool)
      {:ok, b} = AgentPool.checkout(pool)
      :ok = AgentPool.checkin(pool, a)
      :ok = AgentPool.checkin(pool, b)
      assert %{available: 2} = AgentPool.stats(pool)

      {:ok, next} = AgentPool.checkout(pool)
      AgentPool.stop(pool)
      {a, b, next}
    end

    test ":lifo hands out the most recently returned agent" do
      {_a, b, next} = checkout_after_returns(:lifo)
      assert next == b
    end

    test ":fifo hands out the least recently returned agent" do
      {a, _b, next} = checkout_after_returns(:fifo)
      assert next == a
    end
  end

```

`test/coordination/stateful_context_test.exs`: insert before `describe "process termination" do`:

```elixir
  describe "the table is :protected" do
    test "another process can read it but not write it" do
      {:ok, ctx} = StatefulContext.start_link()
      :ok = StatefulContext.put(ctx, "key", "value")
      table = StatefulContext.get_table(ctx)

      assert [{"key", "value"}] = :ets.lookup(table, "key")
      assert_raise ArgumentError, fn -> :ets.insert(table, {"key", "forged"}) end
      assert StatefulContext.fetch(ctx, "key") == {:ok, "value"}
    end
  end

```

`test/dsl/workflow_transform_integration_test.exs`: insert before
`test "steps/0 reports which steps have a when_result" do`:

```elixir
  test "a blank answer fails the step before when_result runs" do
    assert {:error, {:check, %Normandy.LLMError{type: :invalid_output}}} =
             WhenWorkflow.execute(agents: agents(""), initial_input: "x")

    refute_received {:agent_input, "second", _}
  end

```

`test/coordination/hierarchical_coordinator_test.exs`:

- In `describe "delegation strategies"`, after `test ":conditional sends each worker the task the manager assigned to its id"` add (H9):

```elixir
    test ":conditional reads a task under the worker id as an atom key" do
      coordinator =
        HierarchicalCoordinator.new(
          manager:
            agent("manager", %{delegation_plan: %{w2: "atom key for w2"}}, %AssignmentPlan{}),
          workers: workers(),
          delegation_strategy: :conditional
        )

      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "x")

      assert worker_input("w2") =~ "atom key for w2"
      refute_received {:llm_call, "w1", _}
    end

    test ":conditional creates no atom from a worker id" do
      # A fresh id: no atom of that name exists, and looking it up must not create one.
      id = "w-#{System.unique_integer([:positive])}-not-an-atom"

      coordinator =
        HierarchicalCoordinator.new(
          manager: agent("manager", %{delegation_plan: %{"w1" => "t"}}, %AssignmentPlan{}),
          workers: [%{id: id, agent: agent("w1", %{chat_message: "r1"})}],
          delegation_strategy: :conditional
        )

      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "x")
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
    end
```

- After `alias Normandy.Coordination.HierarchicalCoordinator` add:

```elixir
  alias Normandy.TurnError

  import ExUnit.CaptureLog
```

- `test "a manager whose model call exits returns {:error, {:manager_failed, {:exit, _}}}" do` →
  `test "a manager whose model call exits returns a :task_down TurnError" do`, and its
  assertion `assert {:error, {:manager_failed, {:exit, :boom}}} =` →
  `assert {:error, {:manager_failed, %TurnError{type: :task_down, reason: :boom}}} =`.
- `test "a manager whose aggregation call exits returns {:error, {:aggregation_failed, _}}" do` →
  `test "a manager whose aggregation call exits returns a :task_down TurnError" do`, and
  `assert {:error, {:aggregation_failed, {:exit, :boom}}} =` →
  `assert {:error, {:aggregation_failed, %TurnError{type: :task_down, reason: :boom}}} =`.
- Replace `test "a failing manager returns {:error, {:manager_failed, reason}}" do ... end` with:

```elixir
    test "a manager that raises returns the bare exception and logs arities only" do
      coordinator =
        HierarchicalCoordinator.new(
          manager: agent("manager", %{}, %Plan{}, true),
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      log =
        capture_log(fn ->
          assert {:error, {:manager_failed, %RuntimeError{message: "worker down"}}} =
                   HierarchicalCoordinator.execute(coordinator, "x")
        end)

      assert log =~ "HierarchicalCoordinator manager (planning) raised RuntimeError"
      assert log =~ ~r/Normandy\.Agents\.BaseAgent\.\S+\/\d+/
    end

    test "a manager whose model call throws returns a :task_down TurnError" do
      throwing =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{reply: fn _ -> throw(:boom) end},
          model: "test-model"
        })

      coordinator =
        HierarchicalCoordinator.new(
          manager: throwing,
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      assert {:error, {:manager_failed, %TurnError{type: :task_down, reason: {:nocatch, :boom}}}} =
               HierarchicalCoordinator.execute(coordinator, "x")
    end

    test "a manager whose model call returns a Normandy error returns it bare" do
      failing =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{
            reply: fn _ ->
              {:error, Normandy.LLMError.new(type: :overloaded, retryable?: false)}
            end
          },
          model: "test-model"
        })

      coordinator =
        HierarchicalCoordinator.new(
          manager: failing,
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      assert {:error, {:manager_failed, %Normandy.LLMError{type: :overloaded}}} =
               HierarchicalCoordinator.execute(coordinator, "x")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/coordination/agent_pool_test.exs test/coordination/stateful_context_test.exs test/coordination/hierarchical_coordinator_test.exs test/dsl/workflow_transform_integration_test.exs`
Expected: FAIL:
- `:lifo` and `:fifo`: `assert next == b` / `assert next == a` (each gets the other agent);
- StatefulContext: `Expected exception ArgumentError but nothing was raised` (the table is `:public`);
- HierarchicalCoordinator: the two exit tests (`{:manager_failed, {:exit, :boom}}` / `{:aggregation_failed, {:exit, :boom}}` do not match the `TurnError` patterns), the raise test (`{:exception, %RuntimeError{}, stacktrace}`), the throw test (`** (throw) :boom`: only exits were caught), and the Normandy-error test (`{:manager_failed, {:exception, %Normandy.LLMError{}, stacktrace}}`), and ":conditional creates no atom from a worker id" (`Expected exception ArgumentError but nothing was raised`): 6 failures. ":conditional reads a task under the worker id as an atom key" passes already (it pins the lookup `plan_task/2` keeps).
- The workflow test passes already: it pins the behaviour the corrected example documents (inventory probe `wf_probe.exs`).

- [ ] **Step 3: AgentPool order**

`lib/normandy/coordination/agent_pool.ex`, second `do_checkout/1` clause: replace

```elixir
  defp do_checkout(%State{available: available, strategy: strategy} = state) do
    {agent_pid, remaining} =
      case strategy do
        :lifo -> {List.last(available), Enum.drop(available, -1)}
        :fifo -> {List.first(available), Enum.drop(available, 1)}
      end
```

with

```elixir
  # `available` is newest first: a checkin puts the returned agent at its head.
  defp do_checkout(%State{available: available, strategy: strategy} = state) do
    {agent_pid, remaining} =
      case strategy do
        :lifo -> {hd(available), tl(available)}
        :fifo -> {List.last(available), Enum.drop(available, -1)}
      end
```

The `:strategy` option doc ("the most (`:lifo`) or least (`:fifo`) recently returned") is
now true; it stays.

- [ ] **Step 4: StatefulContext, SharedContext**

`lib/normandy/coordination/stateful_context.ex`:

- moduledoc: `using GenServer with ETS backing for high-performance reads.` → `using GenServer with ETS backing.`; replace the two bullets
  `- Fast reads via ETS (no GenServer bottleneck)` / `- Atomic updates via GenServer` with:

```
  - Reads from ETS: each read makes one short `GenServer.call` for the table, then
    looks the key up in ETS (a read never waits behind a write's work)
  - Atomic updates via GenServer: the table is `:protected`, so only the context
    process writes it
```

- `fetch/2` doc: `Reads directly from ETS for maximum performance (no GenServer call).` →

```
  Asks the context process for its table (one short `GenServer.call`), then reads
  the key from ETS.
```

- `get_table/1` doc: replace `Returns the ETS table reference for direct access.` and
  `Advanced users can use this for custom ETS operations.` with:

```
  Returns the ETS table, for reads (`:ets.lookup/2`, `:ets.select/2`, ...).

  The table is `:protected`: only the context process writes it, so a write from
  any other process raises `ArgumentError`. Write through `put/3`, `update/4` and
  `delete/2`.
```

- `init/1`: `:public,` → `:protected,` in the `:ets.new(:stateful_context, [...])` options.

`grep -n ":ets.insert\|:ets.delete" lib/normandy/coordination/stateful_context.ex` shows the
writes are all in `handle_call` clauses (the owner), so nothing else changes.

`lib/normandy/coordination/shared_context.ex`, moduledoc: after the paragraph ending
`enabling information sharing across agent` / `boundaries.` insert:

```

  A `SharedContext` is an immutable value: `put/3` returns a new one. Share it by
  passing it along (to the next step, the next agent), not between processes; for
  state several processes read and write, use `Normandy.Coordination.StatefulContext`.
```

- [ ] **Step 5: HierarchicalCoordinator errors**

`lib/normandy/coordination/hierarchical_coordinator.ex`:

- moduledoc: after the first paragraph (`... aggregates results.`) insert:

```

  `execute/3` runs the manager twice, both times from the config the coordinator holds:
  the aggregation call is a fresh conversation that does not include the planning call;
  it gets the workers' results, each under its worker id.

  ## Errors

  `{:error, {:manager_failed, exception}}` when the planning call fails and
  `{:error, {:aggregation_failed, exception}}` when the aggregation call does. The
  exception is Normandy's own (`Normandy.LLMError`, `Normandy.Schema.ValidationError`,
  ...), the exception a bug raised (logged with its stacktrace, arities only), or a
  `:task_down` `Normandy.TurnError` for an exit or a throw. No stacktrace is returned.
  A failed worker does not fail the call: the manager is told about it.
```

- After `alias Normandy.Telemetry.WorkflowSpan` add `alias Normandy.TurnError`.
- `@spec execute(t(), term(), keyword()) :: {:ok, term()} | {:error, term()}` →

```elixir
  @spec execute(t(), term(), keyword()) ::
          {:ok, term()}
          | {:error, {:manager_failed | :aggregation_failed, Exception.t()}}
```

- `execute_with_tasks/3` spec: `{:ok, term()} | {:error, term()}` →
  `{:ok, term()} | {:error, {:aggregation_failed, Exception.t()}}`.
- `run_hierarchy/3`: `{:error, reason} ->` / `{:error, {:manager_failed, reason}}` →
  `{:error, exception} ->` / `{:error, {:manager_failed, exception}}`.
- Replace `execute_manager/3` (with its `rescue`/`catch`) by:

```elixir
  defp execute_manager(manager, input, _context) do
    with {:ok, response} <- run_manager(manager, input, "planning") do
      {:ok, extract_delegation_plan(response)}
    end
  end

  # One manager call: {:ok, response} or {:error, exception}. A Normandy error is
  # returned; a raise (a bug) is logged (arities only) and returned bare; an exit (a
  # timed-out GenServer.call, say) or a throw is a :task_down TurnError.
  defp run_manager(manager, input, call) do
    case BaseAgent.run(manager, input) do
      {:ok, _updated_manager, response} -> {:ok, response}
      {:error, _exception} = error -> error
    end
  rescue
    e -> TurnError.log_raised("HierarchicalCoordinator manager (#{call})", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
    :throw, value -> {:error, TurnError.from_reason({:task_down, {:nocatch, value}})}
  end
```

- In `aggregate_with_manager/3`, replace the `try do ... end` block with:

```elixir
    case run_manager(manager, aggregation_input, "aggregation") do
      {:ok, response} ->
        {:ok,
         Map.get(response, :chat_message) || Map.get(response, :aggregated_result) || response}

      {:error, exception} ->
        {:error, {:aggregation_failed, exception}}
    end
```

- `create_conditional_specs/2` (H9): replace
  `case Map.get(plan, worker.id) || Map.get(plan, String.to_atom(worker.id)) do` with
  `case plan_task(plan, worker.id) do`, and after the fallback `create_conditional_specs/2`
  clause add:

```elixir

  # The task the plan assigns to worker `id`: under the id, or under an atom key of the
  # same name. The id is never made an atom (worker ids are any strings the host passes,
  # and an atom is never freed), so an atom key is matched by its name.
  defp plan_task(plan, id) do
    Map.get(plan, id) ||
      Enum.find_value(plan, fn {key, task} ->
        if is_atom(key) and Atom.to_string(key) == id, do: task
      end)
  end
```

  `grep -n "to_atom" lib/normandy/coordination/hierarchical_coordinator.ex` prints nothing.

The manager's conversation is still not carried into the aggregation call (Q7: documented,
not changed), and `shared_context` is still threaded but unread (`_context`; see Notes).

- [ ] **Step 6: Reactive, Workflow and Guardrails**

`lib/normandy/coordination/reactive.ex`: replace

```elixir
  defp run_one(pid, input) when is_pid(pid), do: AgentProcess.run(pid, input)
```

with

```elixir
  # No call timeout of its own: the race's :timeout bounds it (the task is killed past it).
  defp run_one(pid, input) when is_pid(pid), do: AgentProcess.run(pid, input, timeout: :infinity)
```

(Since Task 6.5c this is the default; spelling it out keeps the pid branch bounded only by the
race's own `:timeout` if the default ever changes. A killed waiter's queued run is skipped,
Task 6.5c.)

`lib/normandy/dsl/workflow.ex`, moduledoc "Conditional Execution" example: replace the line
`{:ok, %{chat_message: ""}} -> {:error, :empty_answer}` with
`{:ok, %{chat_message: "REJECT" <> _}} -> {:error, :rejected}`, and after that example's
closing `end` / `end` (the `step :process do` block) insert:

```

  A blank answer never reaches `when_result`: the agent's run already failed with
  `%Normandy.LLMError{type: :invalid_output}`, so the workflow returns
  `{:error, {step_name, %Normandy.LLMError{}}}`.
```

In the `when_result/1` `@doc` example, the same line replacement, and after its `end` (before
the closing `"""`) insert:

```

  A blank answer fails the step before `when_result` runs (see "Conditional Execution"
  in the moduledoc).
```

`grep -n 'chat_message: ""' lib/normandy/dsl/workflow.ex` prints nothing afterwards.

`lib/normandy/guardrails.ex`, moduledoc, at the end of the `:incremental` bullet (after
`` Guardrails' chunking approach.``) insert:

```

    Each check runs the guards on the **whole** text accumulated so far, not on the
    new chunk, so a pattern that spans two chunks is still seen. The cost grows with
    the square of the answer's length: an answer of `n` bytes is checked about
    `n / chunk_size` times on texts up to `n` bytes long (a 100_000-byte answer with
    the default `chunk_size: 200` runs the guards about 500 times, on 50_000 bytes on
    average). For long answers or guards that are slow or call a service, raise
    `chunk_size` or use `:accumulate`.
```

(Task 6.4c edits `guardrails.ex` at the guard-return describer, not the moduledoc; anchor on
the bullet text.)

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix format && mix test test/coordination/ test/dsl/ test/guardrails/ test/telemetry/killed_run_test.exs`
Expected: PASS. `reactive_test.exs:75-158` (PERF-14: exits, throws and linked crashes never
kill the caller; a trapping caller's mailbox is empty after `race/3`, `all/3`, `some/3`) passes
unchanged and is the PERF-14 acceptance.

- [ ] **Step 8: Gate**

Run: `mix precommit 2>&1 | tee /tmp/w6-6.5f.log; grep -E " [0-9]+ failures|Total errors" /tmp/w6-6.5f.log` and `mix docs --warnings-as-errors`.
Expected: ` 0 failures`, exit 0; docs exit 0. No tagged suite.

- [ ] **Step 9: MIGRATING-2.0.md**

Append to `## 42.`:

```markdown
- `AgentPool` `strategy: :lifo` (the default) now hands out the most recently returned agent
  and `:fifo` the least recently returned one, as documented; the two were swapped.
- `StatefulContext`'s ETS table is `:protected`: a write to `get_table/1`'s table from any
  process but the context raises `ArgumentError`; write through `put/3`, `update/4` and
  `delete/2`. Reads still make one `GenServer.call` for the table (the docs said they made
  none).
- `HierarchicalCoordinator.execute/3` and `execute_with_tasks/3` errors carry no stacktrace:

| 1.x | 2.0 |
|---|---|
| `{:error, {:manager_failed, {:exception, e, stacktrace}}}` | `{:error, {:manager_failed, e}}`, `e` the raised exception (logged with arities only) |
| `{:error, {:manager_failed, {:exit, reason}}}` | `{:error, {:manager_failed, %Normandy.TurnError{type: :task_down, reason: reason}}}` |
| `{:error, {:aggregation_failed, e, stacktrace}}` | `{:error, {:aggregation_failed, e}}` |
| `{:error, {:aggregation_failed, {:exit, reason}}}` | `{:error, {:aggregation_failed, %Normandy.TurnError{type: :task_down, reason: reason}}}` |
| a Normandy error (`LLMError`, ...) as `{:exception, e, stacktrace}` | the exception bare: `{:error, {:manager_failed, %Normandy.LLMError{}}}` |
| a throw escaped `execute/3` | `%Normandy.TurnError{type: :task_down, reason: {:nocatch, value}}` |

- `HierarchicalCoordinator`'s `:conditional` strategy no longer turns each worker id into an
  atom to look up its task (an atom per distinct worker id, never freed). A plan keyed by
  atoms still works: an atom key is matched by its name.
- `Reactive.race/3`, `all/3` and `some/3` no longer cut a pid contestant's call at 60 s:
  the race's own `:timeout` bounds it.
- `:incremental` output guardrails re-check the whole accumulated text every `chunk_size`
  bytes, so their cost grows with the square of the answer's length (now documented in
  `Normandy.Guardrails`); raise `chunk_size` for long answers.
```

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/coordination/agent_pool.ex lib/normandy/coordination/stateful_context.ex \
  lib/normandy/coordination/shared_context.ex lib/normandy/coordination/hierarchical_coordinator.ex \
  lib/normandy/coordination/reactive.ex lib/normandy/dsl/workflow.ex lib/normandy/guardrails.ex \
  test/coordination/agent_pool_test.exs test/coordination/stateful_context_test.exs \
  test/coordination/hierarchical_coordinator_test.exs \
  test/dsl/workflow_transform_integration_test.exs MIGRATING-2.0.md
git commit -m "fix(coordination): pool order, protected context table, hierarchical errors without stacktraces"
```

---

---

### Task 6.6: Wave gate — flaky tests, known limits, full gate, records

**Files:**
- Modify (6.6a): the test files named below (test code only; no `lib/` change unless a root cause is in `lib/`, which the controller rules on first)
- Modify (6.6b): `MIGRATING-2.0.md` (new `## Known limits of 2.0` before `## New, non-breaking`, unless one exists)
- Modify (6.6c): `investigations/pre-2.0-audit/decisions.md` (Wave 6 progress bullet); `CLAUDE.md` only with Q's approval of Appendix B's text

**Interfaces:** Consumes everything above. Produces nothing new.

- [ ] **Step 1 (6.6a): Fix the four flaky tests found in preflight.** Each one is reproduced first with its seed on the branch, root-caused from the failing output, and fixed without weakening what it asserts (Wave 5 ruling 11: a log refute that matters moves to its own `async: false` module, or is narrowed to a marker only this test's run can produce; never deleted). Record each root cause and fix in the ledger.
  1. `test/resilience/telemetry_test.exs` "a raise is typed by its module…": its async `capture_log` captured stack frames logged by `test/coordination/agent_process_server_test.exs:227`/`:400`. Seed `131968` (stack: preflight HEAD `caa3ec7`; reproduce on the branch with `mix test --seed 131968`, and if the order changed, with the three files together and `--repeat-until-failure 30`).
  2. `test/agents/base_agent_stream_error_log_test.exs`: `refute log =~ "[error]"` caught a Horde shutdown error logged after `resume_reaper_integration_test`'s `on_exit` kills its supervisor. Seed `775477` under `mix test.postgres`. The module is already `async: false` (Wave 5); the fix is the other side: the integration test stops its supervisor and waits for its shutdown to finish (monitor + `assert_receive {:DOWN, ...}`) inside `on_exit`, so its log cannot land in a later test.
  3. `test/hooks/runner_test.exs` async `refute log =~ "boom"` against `test/agents/turn/resume_reaper_test.exs`'s own `:boom` log line. Seed `996861` with the three files together.
  4. `test/coordination/agent_process_test.exs` "async execution doesn't block GenServer": a 10 ms wall-clock bound on `get_stats` (failed at 11 ms, seed `559121`). Replace the timing bound with a gate: hold the run's LLM call open (the 6.5c `assert_receive {:llm_started, ...}` pattern), assert `get_stats` returns while the run is held, then release.
  Run each fixed file 30 times (`mix test <file> --repeat-until-failure 30`) and its seed 3 times; precommit (` 0 failures`); commit per flake (`test(...): ...`, files added individually).

- [ ] **Step 2 (6.6b): Known limits.** Add `## Known limits of 2.0` to `MIGRATING-2.0.md` with one bullet each: AX-12 (context budget undercounts the real prompt), AX-18 (no corrective retry on the structured-output path), AX-19 (output schema both in the prompt and as the constraint), AX-20 (volatile context inside the cached system block), AX-29 (custom input schema reaches the model as bare JSON), AX-33 (memory tool is a custom tool, not `memory_20250818`), SEC-8 HMAC signing of stored templates, a paused `server_tool_use` followed by a crash (live check in Task 7.6), a failed terminal turn-state save can leave a session in the in-flight index (H10), and each Appendix A answer Q marks "known limit". Commit `docs(migrating): known limits of 2.0`.

- [ ] **Step 3: Full gate** on the last commit, every log tee'd, gating on ` 0 failures`:
  `caffeinate -i -s mix precommit 2>&1 | tee <log>`; `mix docs --warnings-as-errors`; `mix test.redis`;
  `docker start normandy-test-pg` then `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test.postgres`;
  `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix test --only distributed --include postgres` twice (a bare `--only distributed` fails on `eager_handoff_distributed_test.exs`, which needs Postgres — pre-existing);
  `mix hex.build --unpack -o <scratchpad>/hex` (no `investigations/`, `priv/test_repo`, `tools/examples`; no warnings);
  `docker stop normandy-test-pg`. Preflight reference on the stacked branch: 3590 tests; Redis 3683; Postgres 3657; distributed 76 ×2.

- [ ] **Step 4: Records.** Append a "Wave 6" progress bullet to `decisions.md` (commits, per-task review verdicts, gate numbers, deferred items: the known limits above, Appendix A items Q deferred, Claudio `add_messages/2` awaiting the 0.7.1 release and Task 7.5's adapter switch). Present Appendix B's CLAUDE.md text to Q; commit `CLAUDE.md` only after Q approves it. Commit `decisions.md` and `CLAUDE.md` separately, files added individually, no AI attribution. The controller removes the `w6-preflight` worktree; deleting the `w6-preflight` branch is asked of Q.

---

## Appendix A: open questions for Q (raised by writers and preflight; each with a recommendation)

- **A1. Model-visible JSON key order is not stable across restarts or nodes.** On OTP 26+ a small atom-keyed map orders its keys by atom creation, not alphabetically (verified: `#{zzz_new_atom_1 => 1, aaa_new_atom_2 => 2}` lists `zzz_` first on OTP 28). A tool that returns a plain atom-keyed map (`Dispatch.wrap_output/2` keeps the map; it is encoded into the `tool_result` text later) can therefore produce different text for the same result on two nodes or after a restart, so the prompt-cache prefix misses and, with caching on by default (R4), costs more. Structs with derived encoders and `Jason.OrderedObject` are stable. Options: (a) leave it and document it; (b) add Task 6.1f: the one model-facing encoding (`AgentMemory.model_content/1` for tool results, and the tool-output path) sorts the keys of plain maps recursively, leaving structs and `OrderedObject` alone, with a test that builds the map's atoms in reverse order in a peer node. **Recommend (b).** It changes wire bytes but not values (the decoded fixture still holds). Cost if wrong: a tool whose map key order carried meaning to the model loses that order; such tools should return an `OrderedObject`. *Accepted (decision 25): Task 6.1f.*
- **A2. `AgentMemory.load/1` raises for a dump it cannot encode** (6.1a writer's call; a 1.x dump with untagged tool calls). Alternative: load lazily and fail at the next request, as today. **Recommend keep raising** (same move as R1: fail at the cause; such a dump cannot be sent anyway). MIGRATING says it.
- **A3. `tokens_removed` now uses the cached model-facing estimate** (H2), a few tokens lower per chat message, and `tokens_removed == tokens_before - tokens_after` now holds. **Recommend keep.**
- **A4. `Dispatch` encodes each tool output four times** (three redundant; constant per result, not PERF-3). **Recommend defer to 2.x** (measured cost small; it touches the Wave 5 cap/encodability rules).
- **A5. A fenced `Turn.Server` (`{:shutdown, :registration_lost}`) reaches a `Session.run/2` caller as an exit**, like any mid-turn crash (H8 retries only passivation). Option: map it to a `:session_unavailable` `TurnError` in 6.2d. **Recommend leave as an exit** (the turn may have run; MIGRATING says so).
- **A6. `Turn.Session.delete/1` lets a store exit reach the caller** (R5's exit catching is Turn.Server-only; `run/2`'s template save behaves the same today). Option: catch exits in `delete/1` and return `:persist_failed` `{:store_exit, tag}`. **Recommend catch** (one clause in 6.3e, consistent with 6.2a). If you agree, I add it to 6.3e before execution. *Accepted (decision 25): applied in Task 6.3e.*
- **A7. `get_stats/1` `run_count` counts failed turns** in both `AgentProcess` modes (inline counted only successes before). **Recommend keep** (both modes agree).
- **A8. `HierarchicalCoordinator` errors keep a tag around the bare exception** (`{:manager_failed | :aggregation_failed, e}`, no stacktrace) rather than an `%OrchestrationError{}`. **Recommend keep.**
- **A9. Claudio `feat/add-messages`** branches from `main` (`005c51d`); no citations branch exists yet, and the branch does not bump `@version` (you own the release). **Recommend as written.**
- **A10. A failed terminal turn-state save leaves the session in the in-flight index** (H10; the reaper may resume a finished turn). **Recommend a Wave 7 item**, listed as a known limit until then.
- **A11. Smaller writer assumptions, recommended as written:** `Turn.Session`'s own store reasons (template read/save) are reduced by tag too; a snapshot is stored on every `compacted: true`, including mid-round; the reaper logs a crashed session at `:warning`; `delete/1` does not fall back to `:gen_statem.stop/3` when the supervisor does not own the server; Redis `delete_session/2` waits for replicas like every write; the library does not delete the old Redis `"<ns>:resumable"` key (MIGRATING tells operators); the run `:exception` carries no totals; two `guardrails.ex` configuration messages that `inspect` the caller's own options stay for a later wave.

## Appendix B: proposed CLAUDE.md text (collected for Task 6.6; applied only with Q's approval)

The verbatim proposals are in Appendix C under each writer's notes ("Proposed CLAUDE.md text"): 6.1 (Entry cache bullet; caching default in Configuration; a Claudio CLAUDE.md line), 6.2 (Turn.Server bullet; Session `run/2` line; `from_entries/1`), 6.3a–e (Session `delete/1`; SessionStore bullet), 6.3f–i (MemoryStore backends sentence; SessionRegistry.Redis bullet), 6.4 (`get_response/2`; run totals and Turn.Server trace context), 6.5 (AgentProcess bullet). Where 6.2 and 6.3a–e both rewrite the `Turn.Session` `run/2` line, Task 6.6 merges them into one line.

## Appendix C: section writers' notes (as written, with preflight annotations)

### Notes from the 6.1 writer

- **Verified in scratch** (worktree of `d624fbf`, Claudio copy of `005c51d`): every test file above,
  the full default suite with 6.1a–6.1e applied (`3420 tests, 0 failures`, run 5× after the
  decoded-fixture change), `credo --strict`, `dialyzer`, `docs --warnings-as-errors`,
  `mix test --only distributed` (8 pass; the one Postgres-needing test fails identically on
  `d624fbf`). The wire fixture was recorded on unmodified `d624fbf` code and matched after each of
  6.1a, 6.1b, 6.1c and 6.1e. Claudio: `request_test.exs` 241 tests and its full suite (864 tests) pass,
  credo clean. **Not run:** `mix test.postgres` (needs `docker start`), `mix test.redis`, Claudio's
  dialyzer and docs, `mix precommit` as one command. The fixture files are re-recorded by the
  implementer in 6.1a Step 1 (not copied from my scratch), so the plan's proof stands on their run.
- **Risk — encode at append surfaces latent non-encodable content.** Five test files used a plain
  `defstruct` as output schema with stubbed LLM calls; they now need a `BaseIOSchema` impl (6.1a
  Step 10). Hosts doing the same in their own tests will see `Protocol.UndefinedError` at append
  (MIGRATING bullet). A grep of `test/` for other structs appended without an impl found none beyond
  those five (the full suite is green).
- **Decision taken without Q — `AgentMemory.load/1` raises for a dump it cannot encode** (6.1a Step 6j,
  test flip in Step 10). Alternative: load lazily (cache `nil`, encode per read) for such entries,
  which keeps the old "loads, fails at next request" and the quadratic reads for them. I chose
  raising, consistent with R1 / Q2 (a): it is the same move (failure at the cause), and a 1.x dump
  with untagged tool calls cannot be sent anyway.
- **Decision taken without Q — `tokens_removed` value** (Header conflict 4). If Q wants the old number,
  6.1c Step 4's `tokens_removed_this_turn/2` keeps
  `WM.estimate_message_content_tokens(BaseIOSchema.to_json(&1.content)) + 10`, the `tokens_removed`
  test and MIGRATING bullet go, and 6.1d's compaction test must expect the current turn's dropped
  entries in its counts.
- **Finding outside 6.1's scope:** Dispatch encodes each tool output four times
  (`Dispatch.execute/4` and `finish/3` via `ensure_encodable/1`, `wrap_output/2`, `cap/3`), measured
  by stack sampling in 6.1d. Constant per result, so not PERF-3, but three of the four are redundant.
- **Decision 6 note:** a `:handler_crashed` reply carries the raw exception
  (`%Protocol.UndefinedError{value: <the content>}`) as `reason`, as every handler crash did before;
  `TurnError.message/1` describes it by type. Persisted/emitted forms are redacted by
  `TurnError.redact/1`. Unchanged by this task; 6.4c owns redaction.
- **Claudio branch base:** R2 says Q publishes 0.7.1 "with the citations patch"; no citations branch
  exists in `/Users/antonio/personal/claudio` today (branches: `main`, `feat/telemetry-otel`, `docs/*`).
  `feat/add-messages` starts from `main` (`005c51d`); Q rebases or merges it with the citations work.
- **Proposed CLAUDE.md text (Normandy), for Task 6.6:**
  - Under "Memory & Messages", after the `history/1` bullet: `  - Each `AgentMemory.Entry` carries derived `wire` (the model-facing encoding) and `tokens` (its estimate), set only by AgentMemory when content is set (`add_message/4`, thinking drops, `from_entries/1`, `load/1`) and never persisted; request builders use `request_messages_for/2` (`@doc false`, one walk) and compaction `keep_entries/3`. Content that cannot be encoded raises at append`.
  - In "Configuration", replace `are documented on \`Normandy.LLM.ClaudioAdapter\`; nothing is sent unless set` with `are documented on \`Normandy.LLM.ClaudioAdapter\`; nothing is sent unless set, except prompt caching, on by default (\`enable_caching: false\` opts out)`.
- **Proposed CLAUDE.md text (Claudio, `/Users/antonio/personal/claudio/CLAUDE.md` line 153 area, for Q):**
  append to the `to_assistant_content/1` bullet: `; `add_messages/2` adds `{role, content}` pairs in linear time with `add_message/3`'s checks and betas (errors name `add_messages/2`)`.
- **Questions I would have asked Q (answers assumed):** (1) Is decoded-JSON identity acceptable for
  "byte-identical"? Assumed yes: raw bytes are not reproducible on the same code (Header conflict 1).
  (2) Should the Claudio branch also bump `@version` to 0.7.1? Assumed no: Q owns the release.

### Notes from the 6.2 writer

**How this was checked.** All seven tasks were implemented in order in a scratch worktree of
`d624fbf` (no Wave 6.1), and every new test was run against the unchanged `lib/` first
(failures as listed in each Step 2) and then against the change. Final state of the scratch
tree: `mix compile --warnings-as-errors`, `mix credo --strict` (no issues), `mix dialyzer`
(passed), `mix test --warnings-as-errors` (3423 tests, 0 failures), `mix test.redis`
(3498 tests, 0 failures), `mix docs --warnings-as-errors` (exit 0), `mix test --only
distributed`: 8 of 9 pass; the ninth needs Postgres (`Normandy.TestRepo not started`), as at
`d624fbf`. The worktree has been removed.

**Not verified:**
- `mix test.postgres`: `normandy-test-pg` was stopped and I did not start it. The contract
  rule (6.2g) and the Postgres-backed distributed test are unrun on Postgres.
- The 6.1 interplay: `put_content/2` in `link_entry/2` (6.2g) and `stored_chain/1` being 6.1a's
  `from_entries/1` body. The scratch run used `%{entry | parent_id: parent}` without the cache.
- OTP 24: the `format_status/2` branch is chosen at compile time by `:otp_release` and was
  compiled only on OTP 28 (the `/1` branch).

**Risks:**
- (Superseded at preflight: the controller's H8 adopted the alternative below, and Task 6.2d
  now passivates with `{:shutdown, :passivated}` and retries only that and `:noproc`.)
  6.2d retried any exit with reason `:normal`. Passivation is the only normal stop
  `Turn.Server` makes, but a host's `:gen_statem.stop(pid)` mid-turn would re-run that turn
  (MIGRATING says so). Alternative if Q prefers: passivate with `{:shutdown, :passivated}` and
  retry only that and `:noproc`. That changes the passivation exit reason (one assertion,
  `server_test.exs` "with no call for idle_timeout_ms, it stops normally").
- 6.2a's batch check makes the core refuse results without a `tool_call_id` key. Two
  `turn_driver_test.exs` doubles needed it; a host's custom `dispatch_tools` returning other
  shapes now fails the turn (MIGRATING line). It is reachable only through custom handlers:
  `Turn.Server`'s and `BaseAgent`'s dispatchers always answer every call, so for `run/3`,
  `stream/3` and `Turn.Server` the existing tool-loop suites prove it never fires falsely; the
  firing path is tested on the core, `Turn.Driver` and `Turn.Inline`.
- 6.2a's diff is ~650 lines including ~420 of tests; it is one reviewable concern (store
  failures) plus the 26-line core check. Split the core check into its own commit if the
  reviewer prefers.
- 6.3c rewrites `persist_turn_state/2` (`save_turn_state/4`): keep its `store_call/1` wrapper.
  6.3e/6.4 edit `session.ex`/`server.ex` after this group; the anchors above are function names.
- 6.4c: use `Describe.reason_term/1` for `{:credential_unavailable, mod, reason}` in
  `reconstruct_config/2`; the 6.2a test `a credential provider that throws` covers the thrown
  path only and is unaffected.
- Surprise 9 (a rejected input does not re-arm the passivation timer) is not addressed: a
  deterministic test needs a timer, and no ruling asks for it.

**Proposed CLAUDE.md text (verbatim), for Task 6.6:**

Under `Normandy.Agents.Turn.Server`, add a bullet:

```
  - Loads its session in its first event after `init/1` (`:loading`), so a start never waits on the store; a duplicate self-registering start stops with `{:already_started, pid}`. A store call that exits is `{:store_exit, reason}` (`:persist_failed` mid-turn, `:session_unavailable` in a load); anything a load raises, exits or throws leaves the server `:unavailable`; a store's load reason is replied reduced by `Describe.reason_term/1`. Each compaction is stored as a `"compaction"` history entry (`%{version: 1, entries: [...]}`) that `AgentMemory.from_entries/1` applies. `format_status` shows ids and state names only
```

Under `Normandy.Agents.Turn.Session`, change the `run/2` line to:

```
  - `run/2` → `{:ok, output} | {:error, exception}`; a call that reaches a passivated server is routed again (three servers, then `:session_unavailable` `:passivated`); `approve/2` (`%{tool_call_id => :approve | :reject}`); `put_config/2` replaces the config
```

Under Memory & Messages, `AgentMemory`, add:

```
  - `from_entries/1` - Rebuild from store history; applies the last `"compaction"` snapshot entry
```

**Questions I would have asked Q (answers assumed):**
1. Should `Turn.Session`'s own store reasons (template read/save) also be reduced by tag?
   Assumed yes (R5 says "session-store load reasons"; these are the same store's reasons on
   the same reply).
2. Snapshot on every `compacted: true`, including a mid-round compaction? Assumed yes: the
   memory changed, and a restart mid-turn resumes from it.
3. `ResumeReaper` log for a crashed session: `:warning`, like its other skip logs. Assumed.

### Notes from the 6.3a-e writer

**Not verified.** (Preflight, stacked on 6.1–6.2: every Postgres step of 6.3a, 6.3c and 6.3d ran
against `normandy_test_w54probe` and passed — 6.3a's ancestry test red then green, the migration
applied by `mix test.postgres`, the stored predicate prints as `WHERE (inflight = true)`, the
delete rules green on all five backends. The items below are the writer's original notes.)
- No Postgres test ran (container stopped; I did not start it). Unrun: 6.3a's
  `fork checks ancestry by ids ...`, 6.3c's index test and `postgres_test.exs`/contract on the new
  column, 6.3d's delete SQL (`= ANY($1::uuid[])` with 16-byte binaries from raw rows; `chain_ids/2`
  CTE), `resume_reaper_integration_test.exs`, `eager_handoff_distributed_test.exs`. Compile,
  dialyzer and docs passed. The pg_indexes assertion is deliberately loose (`~r/WHERE \(?inflight/`)
  because I could not see how Postgres prints the stored predicate. Run the 6.3a/6.3c/6.3d Postgres
  steps first when executing.
- Postgres `delete_session/2` under concurrency (FOR UPDATE vs a fork's FOR SHARE) is reasoned, not
  tested; there is no deterministic gate for two Postgres transactions without a probe connection.
- Everything else (InMemory, ETS, Mnesia, Redis, Turn.Server, Session.delete with Native and Horde)
  ran in scratch against `d624fbf` without 6.1/6.2 changes. 6.2a's `store_call/1`, 6.2b's
  `GatedStore` and 6.2g's snapshot entry were written against the header only.

**Risks.**
- 6.3c touches 30 files (mostly one-token call-site changes); the reviewer should check the
  4th-argument table against the rule (eager and unfinished → `true`), especially the deliberate
  `true` for `s-done`/`s-failed` in `resume_reaper_test.exs` (stale-member coverage).
- The July leftover "terminal-state persist is best effort, so the reaper may resume a finished
  turn" (`server.ex:1322,1330`) is still open and is now sharper: a failed terminal save leaves the
  session in the in-flight index too. The reaper's `non_terminal?` reads the same failed state, so
  it would resume the finished turn as before. No task in the header owns it; propose a Wave 7 item.
- `Turn.Session.delete/1` lets a store **exit** (a dead InMemory Agent, a Redis connection exit)
  propagate to the caller; R5's exit catching is Turn.Server-only. Same as `run/2`'s template
  save today.
  *Preflight annotation:* resolved by A6 (decision 25): `delete/1` catches a store exit and returns
  `:persist_failed` with `reason: {:store_exit, tag}` (Step 3 `delete_from_store/3`, two tests);
  a store raise still raises; registry and supervisor exits are not wrapped (as in `run/2`).
  `run/2`'s template save is unchanged.
- `TurnError`'s `:session_unavailable` message reads "the session could not be started (...)",
  which is odd for a delete error. Left as is (changing the message is out of scope); flag for 6.4c.
- Mnesia `delete_session/2` write-locks both tables for a full scan: fine for rare deletes, bad for
  bulk retention jobs. Documented in the function doc and MIGRATING.

**Proposed CLAUDE.md text (verbatim), for Task 6.6.** In "Agent System", replace the
`Normandy.Agents.Turn.Session` sub-bullet

```
  - `run/2` → `{:ok, output} | {:error, exception}`; `approve/2` (`%{tool_call_id => :approve | :reject}`); `put_config/2` replaces the config
```

with

```
  - `run/2` → `{:ok, output} | {:error, exception}`; `approve/2` (`%{tool_call_id => :approve | :reject}`); `put_config/2` replaces the config; `delete/1` stops the live server (`supervisor_mod.stop_server/2`) then `SessionStore.delete_session/2`
```

and add under "Memory & Messages" (or a new "Session stores" bullet):

```
- **`Normandy.Behaviours.SessionStore`** - `save_turn_state/4` takes `inflight?` (eager and unfinished, computed by `Turn.Server.persist_turn_state/2`) written with the state; `list_resumable/1` returns only in-flight sessions; `delete_session/2` is idempotent and keeps fork-shared entries (Postgres, Mnesia share ancestors; InMemory, ETS, Redis copy). Postgres needs `MigrationAddInflight`. Contract: `test/support/session_store_contract.ex` (`stored_entry_ids:` option)
```

**Questions I would have asked Q (answer assumed).**
1. Should `delete/1` fall back to `:gen_statem.stop/3` when the supervisor does not own the live
   server (`{:error, :not_found}`)? Assumed **no**: no silent fallback; it returns
   `{:not_stopped, :not_found}` and the caller retries.
2. Should `SessionStore.Redis.delete_session/2` wait for replicas like every other write? Assumed
   **yes** (the "every write" fail-closed promise in the Redis moduledoc); 6.3g moves it onto the
   wait pool with the other waited writes.
3. Should the old Redis `"<ns>:resumable"` key be deleted by the library? Assumed **no**: MIGRATING
   tells operators to delete it; the library never reads it.

### Notes from the 6.3f-i writer

- **Verified in a scratch worktree of `d624fbf`** (removed afterwards): every code block above
  compiled and its tests passed, plus the full `mix precommit` (3399 tests, 0 failures, credo
  clean, dialyzer 36 skipped / 0 unnecessary), `mix test.redis` (3482, 0 failures), the Redis
  distributed registry file (2, 0), `mix docs --warnings-as-errors`. Not run: Postgres (nothing
  here touches it) and the full `--only distributed` suite (only the Redis registry file). The
  scratch run used `save_turn_state/3`; the plan's 6.3g tests call `/4` for 6.3c. Not verified
  against 6.3a–e's actual code, which did not exist yet: Step 3c of 6.3g is a grep-and-rewrite
  rule for that reason.
- **Risk: a fenced `Turn.Server`'s waiting caller.** `{:shutdown, :registration_lost}` reaches a
  `Session.run/2` caller as an exit. 6.2d's passivation retry catches only
  `{:shutdown, :passivated}` and `:noproc` (H8), so this exit propagates, like any mid-turn
  crash. MIGRATING says so (and points at `## 39.`). If Q
  wants it as a `TurnError`, that is a 6.2d change (`:registration_lost` → `:session_unavailable`).
- **Risk: the refresh fences on a single observation.** A `0` from the compare-and-PEXPIRE
  followed by a failed `SET NX` stops the local server at once (Q2 a). During a Redis failover
  with stale replica data this can stop a server whose key comes back; the turn then resumes per
  its policy (accepted in 6.3 Q2's "cost if wrong").
- **Risk: `:mnesia.table_info/2` on a disc table that is still loading.** `check_layout!/3` reads
  `:attributes` and `:type` right after `{:already_exists, _}`; these come from the schema, which
  is loaded before tables (it worked for `ram_copies` and `disc_copies` in the scratch run, both
  freshly created in the same node). A peer whose schema is not yet merged could fail here;
  `mnesia_distributed_test.exs` was not run. *Preflight (stacked on 6.3h):* the full
  `--only distributed --include postgres` run passed (`76 tests, 0 failures`), and a throwaway
  peer probe passed: a peer that joined with `change_config(:extra_db_nodes, _)` and then re-ran
  `SessionStore.Mnesia.create_tables/1` and `MemoryStore.Mnesia.create_tables/1` on the existing
  tables got `:ok` (the `{:already_exists, _}` → `check_layout!/3` path), as did a second fresh
  peer joining and calling it at once (`extra_db_nodes` merges the schema synchronously). Still
  unexercised: a node that calls `create_tables/1` before it joins the cluster (it creates its own
  table; pre-existing, not changed here).
- **6.3d interplay.** If 6.3d's `delete_session/2` on Redis calls `wait(conn, wait)`, Step 3c's
  rule moves it onto the session's wait connection (N = 4); otherwise N = 3. Either is correct.
  Preflight: it does, N = 4.
- **Assumed (no question asked):** `:wait_connections` also on `redis_child_specs/1` (same default)
  and mutually exclusive with `:store_redix`; with `:store_redix` and a replica wait the store
  handle is `{store_conn, ns, wait}` (all store traffic and every `WAIT` on that one dedicated
  connection, Q6 b's semantics); the combo reads `:redis_wait` once at spec time. ETS `list/3`
  goes through the owner (the inventory had it in the caller) so a listing never sees half a
  rename.
- **Proposed CLAUDE.md text** (Task 6.6 collects; do not edit now). Replace the MemoryStore
  bullet's backend sentence

  > backends InMemory, ETS, Mnesia, Postgres (counter table `normandy_memory_namespaces`),
  > Redis (`:bytes` key); shared contract in `test/support/memory_store_contract.ex`

  with

  > backends InMemory, ETS and Mnesia (one row per document plus a `{ns, 0}` totals row;
  > rules in `MemoryStore.Rows`), Postgres (counter table `normandy_memory_namespaces`),
  > Redis (`:bytes` key); shared contract in `test/support/memory_store_contract.ex`

  and add under "### Agent System", after the `Turn.Session` bullet:

  > - **`Normandy.Behaviours.SessionRegistry.Redis`** - Handle
  >   `%SessionRegistry.Redis.Handle{owner:, conn:, namespace:}` (`handle/1`, `fetch_handle/1`;
  >   the combo's from `Normandy.Cluster.redis_handles/1`); `whereis` runs in the caller; the
  >   refresh stops a process whose key another holds (`{:shutdown, :registration_lost}`,
  >   `[:normandy, :session_registry, :ownership_lost]`). `SessionStore.Redis` runs a session's
  >   waited writes and their `WAIT` on one of the handle's `wait_conns` (`new/1`
  >   `:wait_connections`; the combo's pool, or `:store_redix`)

### Notes from the 6.4 writer

**Verified.** All five tasks were applied, in order, to a scratch worktree of `d624fbf` (that is, without 6.1–6.3)
and run: every new test fails before its task's code and passes after it (the "Expected: FAIL" counts above are the
observed ones), and with all five applied `mix precommit` exited 0 (3412 tests, 0 failures, credo clean, dialyzer
passed) and `mix docs --warnings-as-errors` exited 0. The new telemetry test files passed 5 runs in a row. Also
probed on `d624fbf`: WireScript's JSON and SSE replies give an llm_call stop of `input_tokens: 1, output_tokens: 1`;
`:otel_baggage.get_all/0` returns the current context's baggage; `capture_log(level: :info)` drops `:debug` lines
while the global level is `:debug`; the semconv registry's memory operation names (Header conflict 2). The worktree
has been removed.

**Not verified.** The tagged suites (`mix test.redis`, `mix test.postgres` on `_w54probe`, `--only distributed`)
were not run for 6.4c/6.4e: other writers' probes share ports and node names, and the gate runs them.

**Assumed from other writers' tasks (check when assembling):**
1. *(Preflight: resolved, X2 — `reason_term/1` exists and walks tuples; 6.4c and 6.4e use it, no fallback.)*
   **6.2a's describer** is named `Normandy.Components.ContentBlock.Describe.reason_term/1 :: atom() | String.t()`
   (exception → module, atom-tagged tuple → its tag, atom → itself, else `type_of/1`). 6.4c Step 3 says how to find
   the real name and gives the function in full if 6.2a reduced reasons inline. If 6.2a's `session_unavailable/1`
   already reduces every reason (credential tuples included), 6.4c's change in `reconstruct_config/2` is redundant
   but harmless (idempotent on a tag).
2. *(Preflight: resolved, X3 — 6.4e Step 4 is now a diff against 6.2f's `reap/1` / `reap_session/2`.)*
   **6.2f's `reap/1`** runs `maybe_start/2` through `Task.async_stream` with `@reap_concurrency` and a per-session
   `catch` (inventory 6.2 §H). 6.4e replaces `reap/1`, `maybe_start/2` and the two checks wholesale with code that
   keeps those properties; if 6.2f's catch logs a different line, 6.4e keeps it. The sweep counts come from the
   values the tasks return, so they are exact under concurrency.
3. **6.2b** leaves `unavailable_data/2` as the one funnel into `:unavailable`; 6.4e emits `phase: :start` there.
4. **6.2d** may add an idle-timeout action to the rejected/crashed `{:keep_state, data}` returns; 6.4a Step 3b says
   how to merge.
5. **6.3c** changes `save_turn_state/3` to `/4`; 6.4a's test store uses `/4`, and 6.4e relies on 6.3c having
   updated `Normandy.Test.FlakyStore`.

**Risks.**
- 6.4a moves the OTel attach from `start_run_span`/`stop_run_span` to the whole turn. Every path that leaves a turn
  calls `release_turn_ctx/1` (rejected, crashed, persist failure, `{:finalize}`, `{:fail}`; `fail/2` and approval
  expiry go through `{:fail}`). A new exit path added by a later task without it would leak the caller's context
  into the next turn; "after a hooked turn the server holds no caller context" and the existing "does not carry one
  turn's caller context into the next" catch that.
- Run totals: a run that ends in `:exception` carries none; a resumed durable turn counts only calls after the
  resume (documented). A host bridge reading `usage` with `meta.usage` (dot access) on a no-usage provider now
  raises `KeyError`: MIGRATING says so.
- 6.4c changes model-facing text of the memory tool (`a string (500 bytes)` instead of the cut string). Decision 6
  outranks the debuggability of the old log; Postgres logs the failing SQL server-side.

**Left as is (outside R9's scope):** `guardrails.ex` has two more `got: #{inspect(other)}` messages, for an invalid
`:on_error` value and an invalid guard spec. Both describe configuration the caller passed, not a return value; a
guard spec can hold opts, so they are candidates for `Describe.shape/1` in a later wave.

**Proposed CLAUDE.md text (verbatim; Task 6.6 collects it).** Replace the `get_response/2` bullet under
`Normandy.Agents.BaseAgent` by:

```
  - `get_response/2` - One LLM request with the agent's prompt, tools and memory, outside a run (an `[:normandy, :agent, :llm_call]` span with no `iteration`)
```

and append to the `Normandy.Telemetry` bullet under "Observability & Telemetry":

```
  Run `:stop` carries the run's totals (`llm_calls`, token sums, `iterations`, `stop_reason`, `finish_reason`), summed by `Normandy.Telemetry.RunUsage`, a `:counters` ref every shell puts on its call requests as `request[:run_usage]` (`with_llm_call_span` adds each finished call; summary calls are not counted). `Turn.Server` keeps the caller's OTel context current from admission to `on_turn_end` (`turn_ctx_token`, released by `release_turn_ctx/1` on every turn exit)
```

**Questions I would have asked Q (answers assumed):**
- Should the run `:exception` also carry the totals spent before the failure? Assumed no (R9 names stop keys only;
  the failed llm_call's `reason.usage_counts` already carries what it billed).
- Map memory `create` to `upsert_memory` (the semconv value added since the inventory) rather than
  `update_memory`? Assumed yes (Header conflict 2).

### Notes from the 6.5 writer

**Verified.** All six tasks were implemented, in order, in a scratch worktree from `d624fbf`
(without Waves 6.1–6.4) and run: each task's new tests failed as stated in its Step 2 and passed
after its code; the whole set gave `mix precommit` ` 0 failures` (72 doctests, 28 properties,
3410 tests), credo clean, dialyzer clean, `mix docs --warnings-as-errors` exit 0; the gated
`AgentProcess` tests and the atom test passed 15 runs in a row; `mix test --only distributed`
gave 8 of 9 passing, the ninth (`eager_handoff_distributed_test.exs:111`) needing the stopped
Postgres container (`Normandy.TestRepo not started`), unrelated. Doc wording settled later
(6.5d's "Inline turns" paragraph, the HierarchicalCoordinator sentence on the aggregation call,
the `Normandy.Application` comment, the `killed_run.ex` bullet) was re-checked with
`mix format --check-formatted`, `mix credo --strict`, `mix docs --warnings-as-errors` and the
coordination tests. The code in the steps is the code that ran, except 6.5b's thinking drop,
which calls `put_content/2` (Task 6.1a) where the worktree, lacking 6.1a, used
`%{entry | content: ...}`.

**Not verified.** The distributed Postgres case above; the interaction with Task 6.2c's
`{:already_started, pid}` (a scoped registry returns `{:error, :taken}` like `Native`, so 6.2c's
rule applies unchanged); `OtelCtx` against an OTP below 26 (the test filters the code server's
requests by the module name, which `{:ensure_loaded, module}` also carries).

**Risks.**
- 6.5d makes inline casts serial: a caller that used `cast/3` as a parallel fan-out on one
  inline process loses the parallelism (Q3 accepted; MIGRATING says so).
- 6.5d counts failed runs and casts in `get_stats/1`'s `run_count` (inline failures were not
  counted before). Chosen so both engines and both entry points count the same way; the
  alternative (count only `{:ok, _}`) is a one-line change in `finish_op/3`.
- 6.5c's queue holds `update_agent/2` behind the turn in flight, as before; a slow turn still
  delays it (now without blocking reads).
- 6.5b changes which entries lose thinking (the entry right after a deleted turn now does).
  `delete_turn/2` has no caller in `lib/`, so only users who call it see this.

**Left open (outside 6.5's rulings).** `HierarchicalCoordinator` still threads `shared_context`
without reading it. (`create_conditional_specs/2`'s `String.to_atom(worker.id)` was listed here;
preflight added it to 6.5f per H9: a host that builds coordinators with per-request worker ids
leaked an atom per id.)
`Normandy.WatchedWorker` is not yet used by `Turn.Server` (R10).

**Proposed CLAUDE.md text** (for Task 6.6 to collect; nothing in CLAUDE.md is made false by
6.5, these add what is now true). Under "Agent System", after the Orchestrators bullet:

```
- **`Normandy.Coordination.AgentProcess`** - Agent as a process; `:inline` (default) runs turns one at a time from a FIFO queue (runs, casts, `update_agent/2`) in a `Normandy.WatchedWorker` that dies with the process, so reads answer during a turn; `run/3` waits `:infinity`; `:max_pending_runs` (default 100) bounds runs and casts in both engines, refused with a `:queue_full` `TurnError`; `:server` without `:registry` uses a scope in the app-level `AgentProcess.ScopedRegistry`
```

**Questions I would have asked Q (answer assumed).**
1. `run_count` for failed turns: count them (assumed, see Risks) or keep inline's "ok only"?
2. `HierarchicalCoordinator` shape: keep the `{:manager_failed | :aggregation_failed, e}` tag
   around the bare exception (assumed: it says which call failed, carries no stacktrace) rather
   than a bare exception or an `%OrchestrationError{}` (which models per-agent results, not a
   two-call manager).
3. Doc-only changes (the Workflow example) get no MIGRATING bullet (assumed); the B6 cost note
   gets one because it states a known limit.
