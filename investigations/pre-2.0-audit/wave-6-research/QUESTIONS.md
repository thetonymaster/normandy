# Wave 6 — questions for Q (consolidated from the research inventories, 2026-10-06)

Each block is copied verbatim from its inventory; numbering is per inventory (6.1 Q1..Q7, 6.2 Q1..Q9, 6.3 Q1..Q7, 6.4 Q1..Q9, 6.5 1..12).

## Task 6.1 (linear-time history) — 6.1-history.md


**Q1. Where the cache lives.**
(a) Fields `wire`/`tokens` on the public `%Entry{}`. Trims, deletes and forks maintain them automatically. They are visible in
`after_compact`'s `dropped` and in `initial_memory` templates.
(b) A private map `%AgentMemory{encoded: %{id => {wire, tokens}}}`. `Entry` stays as the store contract sees it, but
every mutation path must maintain the map.
*Recommend (a)*, with `ConfigTemplate` stripping the fields when the template is built and `rebuild/3` refilling them.
*Cost if wrong:* (a) adds a public struct field that hook authors may pattern-match on. (b) risks a stale map entry
after a missed mutation path, which would send the wrong content to the model.

**Q2. Encoding failures move from the LLM call to append.**
(a) Accept it and add a MIGRATING line.
(b) Rescue at append, leave the cache `nil`, and let the call-time fallback raise where it does today.
*Recommend (a)*: the error surfaces closer to its cause, and (b) is a silent fallback in all but name.
*Cost if wrong:* a Turn.Server user whose alerting matches `:task_down` for this case sees `:handler_crashed`
instead. The case is rare: Dispatch already turns unencodable tool output into an error result.

**Q3. Claudio's O(N²) `add_message` (Surprise 2).**
(a) Claudio 0.7.1 gains `Request.add_messages/2`, and Normandy bumps to it (6.1e). It can ride the 0.7.1 release
already pending for citations replay.
(b) A Normandy-side workaround that writes `request.messages` directly.
(c) Leave it.
*Recommend (a).* *Cost if wrong:* with (c), a 1200-message call still spends about 4.5 ms (quadratic) building
the request after 6.1, which is most of the remaining Normandy-side cost.

**Q4. B3 scope.** Measured at about 25 µs per call.
(a) Close B3 with the measurement and no code.
(b) Also precompute tool schemas in `Toolset` (6.1f).
(c) Also memoize the output-schema text per module.
*Recommend (a)* or (b). A full prompt cache is impossible without first splitting the providers out (AX-20).
*Cost if wrong:* under 0.1 ms per call.

**Q5. AX-12 / AX-19 / AX-20.** Confirm all three stay deferred to 2.x (reasons in §3–5). Two items need your
decision even if deferred:
(i) Should the AX-12 `ctx.prompt_tokens` piece go in now as a separate sub-task after 6.1? I recommend no.
(ii) Should `enable_caching` default to `true` in 2.0? It is a default and cost change, cheaper to make before
release than after, and it needs a MIGRATING entry. I recommend yes for 2.0, because tool loops re-pay the full
prefix every iteration without it, but this is your pricing call.

**Q6. Turn.Server compaction persistence** (decision 22 deferred it to "Wave 6", and no 6.x task names it).
(a) Add it to 6.2 (Turn.Server store IO), as a compaction-marker entry across the 5 SessionStore backends
(a persisted-format change).
(b) Its own task 6.1g after 6.1c.
(c) Keep it as a documented known limit (MIGRATING §… already says so; `MIGRATING-2.0.md:1148`).
*Recommend (a)*: it is store-format work like the rest of 6.2. *Cost if wrong:* a rehydrated session replays the
uncompacted history, which means a cache miss and a re-summary, and rarely a 400 on replayed thinking.

**Q7. SessionStore ETS: one row per session, O(N) per append** (`ets.ex:104-110`, Surprise 8). Fold it into
6.3 next to PERF-10's MemoryStore row layout? *Recommend yes.* It is not 6.1's acceptance.

## Task 6.2 (Turn.Server startup, store failures) — 6.2-server.md


**Q1. B2 on the sync BaseAgent path.** BaseAgent classifies inside each tool task, so a slim
config there also changes what `PolicyEngine.check/2`'s `ctx.config` sees.
(a) Slim only Turn.Server's tool tasks (classify stays in the worker with the full config).
BaseAgent is unchanged.
(b) Also move BaseAgent's classify out of the tasks (sequential policy checks, then parallel
execution).
(c) Give policy engines a memory without entries everywhere (breaking).
*Recommend (a).* Turn.Server is where large, long-lived histories live, and the measured cost is
small (Surprise 6). Cost if wrong: BaseAgent keeps N copies per batch, ~137 µs and 0.5 MiB each
at 1000 messages.

**Q2. Timing acceptance on CI.** Keep the literal "< 1 s" wall-clock test in the default suite
(5× headroom, `async: false`), or tag it `:perf` and rely on the deterministic gated test for
the gate? *Recommend default suite plus the gated test.* Cost if wrong: an occasional CI flake on
an overloaded runner.

**Q3. Reply shape for a crash during the load.** `{:load_crashed, %ArgumentError{}}`, or the
bare exception as today's `server_errors_test.exs:165` expects? *Recommend the bare normalized
exception* (no tagged tuple in replies, decision 15b). The log says it crashed. Cost if wrong:
hosts can't tell "provider raised" from "provider returned this exception" in the reason.

**Q4. PERF-7 scope.** Catch only `:exit` (timeouts, dead store) and let raises crash
(decision 15c: bugs raise), or catch raises from stores too? *Recommend exits only for in-turn
writes; everything during the load* (where a crash means a restart loop). Cost if wrong: a
buggy custom store that raises mid-turn still spends the shared restart budget.

**Q5. Crash reports dump the conversation (Surprise 5).** Add `format_status/1` to Turn.Server
(OTP 25+; the minimum supported Elixir 1.15 needs OTP ≥ 24, so it needs a guard or the
`format_status/2` fallback) that shows ids and state names only? It is not in plan.md's 6.2 text.
*Recommend yes, in 6.2a* (~30 lines). Otherwise route it to Task 6.4. Cost if skipped:
conversation content (PII) in error logs on every remaining crash path.

**Q6. `server_tool_use` after a failed pause.** (a) Live probe in Task 7.6 first, fix only if
the API rejects it. (b) Pre-emptively continue a paused turn before admitting the next input
(an extra LLM call). (c) Strip unmatched server blocks on the wire (edits history, which breaks
the append-only rule). *Recommend (a).* Cost if wrong: one failed request (400) for a session
after a rare pause-then-crash, until fixed.

**Q7. Compaction persistence (persisted-format change).** (a) A snapshot entry (`role:
"compaction"`) in the history stream, applied by `from_entries/1`: no store callback change, but
`history/2` readers see a new role. (b) A new optional `SessionStore` callback
(`save_snapshot/3`, `load_snapshot/2`) on all 5 backends with a contract suite (bigger; a
Postgres column or table). (c) Keep the known limit for 2.0 (the MIGRATING note stays).
Sub-question: does a failed snapshot write fail the turn (`:persist_failed`) or log and continue
uncompacted on restart? *Recommend (a) with log-and-continue.* A failed snapshot only degrades to
today's behaviour. Failing a turn whose messages are all stored would be a worse outcome. Cost if
wrong: (a) is a format that later readers (and 2.x) must keep understanding.

**Q8. Duplicate start under a self-registering registry.** The losing start now returns
`{:error, {:already_started, pid}}` from `Turn.Server.start_link/1` and `Turn.Supervisor.start_server/2`
(`Turn.Session` and `ResumeReaper` handle it already) instead of a running unregistered
duplicate. This is a behaviour change for anyone calling `start_server/2` directly. *Recommend
yes,* with a MIGRATING line. Cost if wrong: a direct caller that pattern-matched `{:ok, _}` on a
racing second start now sees an error tuple.

**Q9. ResumeReaper concurrency knob.** A module attribute (16), or a new
`:max_concurrency` start option (public, NimbleOptions-validated, documented)? *Recommend the
attribute.* Cost if wrong: a deployment with a slow store can't lower the burst without a
code change.

## Task 6.3 (cluster hygiene) — 6.3-cluster.md


**Q1 — How the Redis registry reaches its connection without the owner (PERF-6).**
Options:
- (a) **A handle value.** `%SessionRegistry.Redis.Handle{owner:, conn:, namespace:}`, built by
  `new/1` and `Cluster.redis_child_specs/1`, with the via term `{handle, sid}`. This breaks hosts
  that pass `{SessionRegistry.Redis, MyOwnerName}`, so it needs a MIGRATING entry.
- (b) **`:persistent_term`** keyed by `{SessionRegistry.Redis, owner}`, written in `init/1`. The
  handle is unchanged and the change is non-breaking. But it is hidden global state, which your
  global rules forbid. A restarted owner rewrites the key, which triggers a global GC. Each
  `new/1` in tests leaves a key behind.
- (c) A public named ETS table per owner.

Recommendation: (a). It mirrors `SessionStore.Redis`'s `{conn, ns}` value handle and has no
hidden globals. The break is small: hosts already build `{Mod, handle}` tuples. Cost if wrong:
another public-shape change after 2.0.

**Q2 — What the refresh does when a key it owns turns out to be lost (`pexpire_if_owner` returns 0).**
Options:
- (a) Re-claim with `SET NX PX`. If another node holds the key, log it, emit
  `[:normandy, :session_registry, :ownership_lost]` and stop the local server with
  `{:shutdown, :registration_lost}`. This fences split-brain.
- (b) Re-claim only, and log.
- (c) Ignore, as today.

Recommendation: (a). A duplicate server writing the same session is the July "no single-writer
fencing" item. Cost if wrong: a stop during a brief Redis failover kills an in-flight turn, which
then resumes per its policy.

**Q3 — Is the eager index "in-flight sessions", and how does the server feed it (PERF-8)?**
This is breaking for third-party `SessionStore`s.
- **(A) A new callback.** `set_resumable(handle, sid, boolean)`, called by Turn.Server when the
  flag flips. The flag flip is a separate write, so a crash between the two writes can leave the
  index wrong.
- **(B) A new argument.** `save_turn_state(handle, sid, state, resumable?)`: one atomic write. It
  touches 34 test call sites and 6 stubs.
- **(C) Keep the "all eager" semantics** and add only `delete_session/2`. That meets the
  acceptance's letter, but `:nodedown` still scans every live eager session.

Recommendation: (B). The index can never disagree with the persisted state, and every
backend does it in one round trip. Cost if wrong: one more callback change after 2.0.

**Q4 — What `delete_session/2` does with entries a fork still uses (Postgres, Mnesia).**
Options:
- (a) **Conservative GC.** Delete only the head-side part of the chain that no other session
  reaches. An entry counts as shared if it is another session's head or has a child outside this
  chain.
  - Postgres: one transaction, using the existing `parent_id` index.
  - Mnesia: needs a full entries scan per delete, because `parent_id` sits inside the data map.
- (b) **Metadata-only delete** on those two backends: the entries stay, and this is documented as
  not erasure.
- (c) **Refuse** to delete a session that has forks: `{:error, :has_forks}`.

Recommendation: (a) for Postgres. For Mnesia, (a) with the scan, documented as O(entries). Cost if
wrong: retention and erasure promises.

**Q5 — Should there be a public `Turn.Session.delete/1`?** It would stop the live server, then
delete the stored session. It races with a concurrent `run/2`, which could restart the session;
document that. Recommendation: yes. Without it, the store callback has no caller in the library,
and the hosts that need retention would have to stop servers themselves.

**Q6 — Where the `WAIT` connection comes from (PERF-12).**
Options:
- (a) `SessionStore.Redis` owns a small pool of `k` Redix connections for waited writes, with a new
  `new/1` option `:wait_connections` (default 4). The handle carries them, and
  `Cluster.redis_child_specs/1` starts the pool when `config :normandy, :redis_wait` asks for
  replicas.
- (b) The host passes a dedicated connection. Document that it must not be shared, and have
  `redis_child_specs/1` take a second `:store_redix` keyword.
- (c) `WAIT` only once per turn boundary (on `save_turn_state`). That changes the documented
  "every write" fail-closed promise (`redis.ex:17-23`).

Recommendation: (a), with (b)'s `:store_redix` as an override. Either way, the write and the
`WAIT` must share the connection (Surprise 1). Cost if wrong: the handle tuple changes shape
again.

**Q7 — Is this a MIGRATING note, or nothing?**
- The Redis in-flight key replaces `"#{ns}:resumable"`.
- Postgres needs a new migration module.
- Sessions in flight at upgrade time are not in the new index until their next persist, so a node
  lost during the rolling deploy misses them.

Recommendation: a MIGRATING section, plus the guide's migration list
(`distributed_sessions.md:28-35`). The decision here is whether to backfill the new index from
non-terminal turn states. A Postgres backfill is impossible, because turn state is an opaque
blob. A Redis backfill would mean decoding every eager session. My recommendation is no backfill:
document it, and say to drain eager sessions before upgrading.

## Task 6.4 (telemetry) — 6.4-telemetry.md


**Q1. Run totals: how usage reaches the run stop (TEL-7).**
- (a) A `:counters` accumulator carried on the transient call request (recommended; no persisted format, no handler
  contract change).
- (b) Handlers return usage beside the response, and `Turn.State` sums it. This changes `Driver.Handlers.call_llm`'s
  return, so custom AgentProcess handlers break, and it changes the persisted `Turn.State`.
- (c) Ship only `iterations`, `stop_reason` and `finish_reason`, and leave the token sum to bridges.

Cost if (a) is wrong: summary (compaction) calls are not in the run total (their llm_call span carries
`purpose: :summary`), and a custom `call_llm` reports `llm_calls: 0`. Decide also: should compaction summaries be
counted? Recommendation: no, and document it. Threading the accumulator into `Compactor`/`Summarizer` widens 6.4b.

**Q2. Turn.Server admission: under the caller (recommended) or under the run span (BaseAgent parity)?**
- Recommended: attach the caller context only, so on_prompt is a sibling of run. `metadata_test.exs:165-181`
  (Turn.Server run `:start` carries `turn_id`) keeps holding.
- Full parity: start the run span before admission. On_prompt and guardrails become run children, as in BaseAgent,
  and TEL-12's crash case is covered for free. But the run `:start` loses `turn_id` (the turn is begun after
  admission), which changes the catalogue's run-start text and that test.

Cost if wrong: a dashboard expecting on_prompt latency inside the run's duration sees it outside.

**Q3. Log level change (TEL-8) is observable behaviour.** Lifecycle start/stop go to `:debug`. Hosts that relied on
`:info` lines lose them by default. Recommendation: yes, with a MIGRATING line ("set `Logger` to `:debug` for
`Normandy.Agents.BaseAgent` or use telemetry"). Also confirm the residual `IO.warn` for `on_violation: :warn`
becomes `Logger.warning` (stderr capture in host tests would change).

**Q4. `get_response/2` (TEL-11).** Options: give it an llm_call span (recommended, non-breaking); or `@doc false`
it/remove it before 2.0 (breaking; one test caller, listed in CLAUDE.md). Cost if the span is wrong: llm_call dashboards
gain calls with no `iteration`.

**Q5. Baggage (TEL-15).** Drop inbound baggage in `A2A.Server` (recommended, a security default). Should
`AgentTool` also stop sending outbound baggage (inject trace context only)? Recommendation: keep outbound, since it
is the host's own context. Cost if wrong: a host relying on A2A baggage propagation loses it inbound. That is
breaking-ish for anyone using it with 1.x, so it needs a MIGRATING line.

**Q6. TEL-16 scope.** The audit's minimum is three events. Batch gets no span, only quieter logs. Add
`[:normandy, :batch, :run]` (span: item_count, succeeded, failed) too? Recommendation: no for 2.0. Its item runs
already emit run spans under the caller. Cost if wrong: no batch-level duration without summing.

**Q7. Wave 5 item (1), the memory backend reason.** Options A, B or C (§1b). Recommendation: B (safe-term
describer, SQLSTATE code for Postgrex). This is a behaviour change to model-facing text, so it needs a MIGRATING
note only if the memory tool's error text is considered API.

**Q8. Wave 5 item (2), the credential reason in `TurnError`.** Options A, B or C (§1b). Recommendation: B (reduce to
a tag term in the reply). Should session store load reasons get the same treatment (C, with 6.2)?

**Q9. TEL-5 scope.** Also change `guardrails.ex:189`'s `inspect(other)` (guard return contract)? Recommendation:
yes, same sub-task, same describer.

## Task 6.5 (process hygiene) — 6.5-process.md


1. **A7: the `AgentProcess` default mode.**
   (a) Keep `:inline` default, make it non-blocking with a FIFO run queue (one worker at a time, reads answer at
   once, `update_agent/2` queued). (b) Make `:server` the default: breaking; every AgentProcess starts an
   InMemory store, a registry and a Turn.Supervisor, `get_agent/1` reads the store, `update_agent/2` ignores
   memory changes. (c) Keep blocking inline and document it.
   **Recommend (a):** no result-shape change, same serialization as Turn.Server, fixes A7, PERF-13's queued-caller
   half and the inline cast memory loss. Cost if wrong: (a) changes when `get_agent/1` returns during a run
   (pre-run snapshot instead of waiting), and an inline crash killed from outside becomes a `:task_down`
   `TurnError`; MIGRATING lines.
2. **PERF-13: `AgentProcess.run/3` default `:timeout` 60_000 → `:infinity`** (breaking default). Recommend yes,
   matching `Turn.Server.run/2`; turns are bounded by retry, tool timeouts and `max_tool_iterations`. Cost if
   wrong: a caller that relied on the 60 s exit hangs on a stuck client instead; it can pass `timeout:`.
3. **SEC-14 bound.** Option name `:max_pending_runs`; default (recommend `100`; `:infinity` keeps today's
   unbounded behaviour); refusal error: a new `TurnError` type `:queue_full` (recommend; `@types` in
   `turn_error.ex:58-66` is public) vs reusing `:session_unavailable`. Also confirm inline `cast/3` becomes
   serialized and keeps memory (today: concurrent turns from one snapshot, memory discarded). Cost if wrong:
   users who used inline casts as a parallel fan-out lose parallelism (`Reactive.all/3` is the tool for that).
4. **Atom leak fix shape:** a shared app-level `Registry` behind an internal scoped `SessionRegistry` (recommend)
   vs. documenting "pass `:registry`" and leaving the leak. Cost if wrong: one more child in
   `Normandy.Application`.
5. **Watched-worker helper:** AgentProcess needs the same "worker dies with its owner" shape as
   `Turn.Server.run_while_server_alive/3` (`server.ex:1443-1454`). Recommend an internal `@moduledoc false`
   module used by both (two implementations exist now), with Turn.Server switching to it in 6.2 or later; the
   alternative is a private copy in AgentProcess. Cost if wrong: a small duplicate, or a cross-task file touch.
6. **StatefulContext:** doc fix only (non-breaking) vs doc fix + `:protected` table (breaking for anyone writing
   to `get_table/1`'s table directly). Recommend doc + `:protected`. Removing the per-read `get_table` call needs
   a named table (an atom per context) or a different handle; recommend leaving the call and correcting the docs.
7. **HierarchicalCoordinator error shape:** today `{:error, {:manager_failed, {:exception, e, stacktrace}}}`
   and `{:error, {:aggregation_failed, e, stacktrace}}`. Recommend decision 6's shape (no stacktrace; the bare
   exception, or `%OrchestrationError{}` like the other orchestrators), breaking, in 6.5f, MIGRATING line. Also:
   keep the manager's delegation conversation for the aggregation call (behaviour change) or document that
   aggregation is a fresh conversation (recommend document). Cost if wrong: stacktraces keep leaking arguments
   into returned values.
8. **AgentPool `:lifo`/`:fifo`:** fix to match the docs (recommend; the default `:lifo` then really hands out the
   most recently returned agent, a behaviour change worth a MIGRATING line) vs. swap the docs.
9. **Deferred agentx:** AX-18 corrective retry, AX-29 input section, AX-33 native memory tool → recommend all
   three to 2.x, listed as known limits in CHANGELOG/MIGRATING. Cost if wrong: none of them is a correctness bug
   today.
10. **B6 incremental guardrails O(R²):** a tail window would change what a guard sees (a pattern spanning the
    window start). Recommend documenting the cost in `Normandy.Guardrails` (`:incremental` re-scans the whole
    text every `chunk_size` bytes) and no code change.
11. **B5 owner:** recommend 6.3 (stores). It is in Wave 6's header but in no task.
12. **Batch-completeness assertion before the next LLM call (July LOW):** 6.2 (Turn core, all three
    interpreters) or defer. Recommend 6.2 if its diff budget allows; it is a cheap invariant check.
