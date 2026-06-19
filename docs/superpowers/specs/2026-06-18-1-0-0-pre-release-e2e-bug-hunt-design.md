# 1.0.0 Pre-Release E2E Bug Hunt — Design

**Date:** 2026-06-18
**Status:** Approved (design)
**Author:** Q

## Goal

Find **major bugs** in the features introduced after `0.6.3` (releases `0.7.0 → 0.8.0
→ 0.9.0 → 1.0.0`) before cutting the `1.0.0` release. This is a one-time,
time-boxed (~1–3 day) adversarial verification pass, **not** a permanent CI gate.
The deliverable is a ranked bug list with reproductions and a go/no-go call.
Sign-off is a byproduct of an empty Blocker list, not the objective.

Emphasis throughout: **edge cases**. Happy paths are largely covered by the
existing tagged suites; the bug yield is in the edges and the cross-feature
journeys.

## Scope

### Feature surface (what shipped after 0.6.3)

- **0.7.0** — Pluggable behaviours (Phase 2): `PolicyEngine`, `BudgetTracker`,
  `CredentialProvider`, `ModelCatalog`; `Behaviours.Config` bundle. Additive,
  default-off, behavior-preserving.
- **0.8.0** — Branching session memory + `SessionStore` (Phase 3): entry-based
  `AgentMemory` (**breaking** dump format), `SessionStore` behaviour
  (InMemory/ETS), `fork/2`, atom-exhaustion security fix on `load/1`, cycle-safe
  graph walks.
- **0.9.0** — Approval core + dispatch chokepoint split (Phase 4a/4b):
  `Dispatch.classify/execute`, Turn FSM human-approval parking
  (`:awaiting_approval`, `parked_calls`/`held_results`).
- **1.0.0** — Compaction at `:steering` boundary (Phase 5); durable turn engine
  `:server` mode (Phase 6: passivation, approval parking, rehydration); distributed
  multi-node sessions (Phase 7: Postgres/Redis/Mnesia stores, Horde
  registry/supervisor, `ResumeReaper`, config templates); guardrails (`admit`
  pre-charge filter, threaded `context`, per-guard `:on_error` policy,
  `SemanticScope`).

### Risk ranking (where effort goes)

| Risk | Surface | Why bugs hide here |
|---|---|---|
| 🔴 Highest | Phase 7 distributed/durable (PG/Redis/Mnesia stores, Horde, ResumeReaper) | Real backends have transaction/serialization/connection-loss semantics InMemory/ETS tests never exercise; node-down timing is racy. |
| 🔴 Highest | Phase 6 durable `:server` (passivation, approval parking, rehydration) | State round-trips through a store and back; reconstruction from config template is where data loss/corruption lives. |
| 🟠 High | 0.8 branching memory + breaking dump format | Migration path + atom-exhaustion fix + cycle-safe corrupt-dump walks. Real upgrade hazard. |
| 🟠 High | Guardrails `admit` / `:on_error` fail-open/closed | A fail-open bug silently lets disallowed input through — security-relevant. |
| 🟡 Med | Compaction at `:steering` boundary | Fires only when window exceeded; easy to never trigger in normal tests. |
| 🟢 Low | 0.7 behaviours (default-off) | Additive, defaults unchanged. |

### Out of scope (YAGNI)

Permanent CI integration; real multi-host cluster (in-VM `:peer` only); exhaustive
feature×backend matrix; property/chaos harness; adversarial diff code-read; any new
feature work or fixes beyond the minimum needed to *reproduce* a bug. Fixing the
bugs is a follow-up after the bug log exists.

## The testing landscape (current reality)

- 129 test files. Per-feature integration/distributed tests **exist**:
  `test/integration/*`, `test/agents/turn/*distributed*`, postgres/redis/mnesia
  store tests, Horde failover/handoff tests.
- They are **tag-gated and excluded by default**. `test/test_helper.exs` excludes
  `[:integration, :normandy_integration, :postgres, :distributed, :redis]`.
- **CI reality:** the `test` job runs `mix test` = units only. Integration runs
  *only* on push to `main`, *only* with an API key, *only*
  `--only integration --only normandy_integration`. `:postgres`, `:redis`, and
  `:distributed` suites are **effectively never run in CI**, including the entire
  Phase 7 distributed/durable surface.
- Distributed tests boot `:peer` nodes **in-VM** via `Normandy.ClusterCase`
  (`start_peer/1`, `start_horde_on_peer/2`, `start_test_repo_on_peer/2`, …) sharing
  this node's code paths. No Docker or separate hosts needed for the cluster
  itself; the PG/Redis *combo* distributed tests need those backends reachable.
- A standalone live-API smoke already exists: `smoke_guardrails.exs` (`mix run`),
  exercising happy-path + edge cases (guardrail violation, streaming `:incremental`
  halting mid-stream) and printing observable evidence + telemetry. This is the
  template the new smokes follow.

**Thesis:** the bug yield comes from (a) pointing the existing tagged suites at
**real Postgres/Redis** (not InMemory/ETS), (b) edge-case cross-feature smokes,
(c) mid-turn fault injection on the two 🔴 rows.

## Architecture & deliverables

Five artifacts, committed under `verify/` and `docs/release/`:

1. **`docker-compose.verify.yml`** — Postgres + Redis, pinned versions, ephemeral
   volumes. `docker compose -f docker-compose.verify.yml up -d` brings up the real
   backends; torn down after the pass.
2. **`docs/release/1.0.0-e2e-runbook.md`** — the exact ordered commands, env vars,
   and "what to look for" per step. Hand-re-runnable.
3. **`verify/*.exs` edge-case smoke scripts** — `mix run` scripts in the
   `smoke_guardrails.exs` style: hit the live API / real backends, print observable
   evidence + telemetry. **Where an invariant is unambiguous, the script asserts it
   and exits non-zero on break** (so a re-run catches regressions); where the
   outcome is judgement (model phrasing, latency), it prints for eyeball review.
4. **New `@tag :distributed` fault-injection tests** — extend the existing
   `ClusterCase` kill-node pattern with the missing mid-turn kill points on the two
   🔴 rows, run against **real PG/Redis**.
5. **`docs/release/1.0.0-bug-log.md`** — every defect: title · severity · exact
   repro command · observed vs expected (citing an evidence line) · root-cause
   **theory** (marked theory vs verified). Plus the go/no-go table.

## Execution order (data flow)

```
1. Stand up      docker compose -f docker-compose.verify.yml up -d  →  mix ecto.setup
2. Floor (gate)  mix test                  (units green = baseline; if red, STOP)
3. Real backends mix test.postgres
                 mix test.redis
                 mix test --include distributed --include postgres --include redis  (combo)
4. Live API      mix test --only integration --only normandy_integration   (API_KEY set)
5. Edge smokes   mix run verify/<each>.exs              (capture stdout → evidence/)
6. Fault inject  run the new kill-point :distributed tests against real backends
7. Triage        collect failures → bug-log.md → severity → go/no-go
```

- Step 2 is a **gate**: if units are red, stop and fix the floor first — no point
  hunting on a broken base.
- Steps 3–6 run **regardless of individual failures** (collect *all* bugs, not
  first-fail).
- Every step appends to an `evidence/` capture directory so the bug log cites real
  output, not memory.

## Verification matrix (where "with edge cases" lives)

Per 🔴/🟠 row: the real-backend suite plus the specific **edge cases** a smoke or
fault test must hit.

| Feature | Real-backend suite | Edge cases to hit |
|---|---|---|
| **Durable `:server`** (P6) | `agent_process_server_live_test` + server suite vs real PG | approval **timeout** (parked turn expires); **idle passivation** then **rehydrate-on-demand**; store-authoritative `get_agent` after restart (memory survives); `update_agent` template-only (memory mutation ignored); resume after process crash mid-turn |
| **Distributed stores + Horde** (P7) | `redis_combo_distributed`, `mnesia_distributed`, postgres+horde vs real PG/Redis | **node-down eager handoff** (ResumeReaper restarts eager non-terminal sessions); **lazy rehydrate** (route→whereis→rehydrate); `already_started` via-race; **Redis Streams** append ordering; **Mnesia** transactional append under concurrent writers; credentials **never** persisted in template |
| **Branching memory + breaking dump** (0.8) | memory suite vs real store | **0.8 dump-format migration** (pre-1.0 dump → load behavior); **atom-exhaustion** guard (corrupt dump with novel keys doesn't mint atoms); **cycle-safe** walk (parent-cycle dump terminates); `fork/2` divergent appends; `count_messages` across branches |
| **Guardrails admit / on_error** (1.0) | guardrails suite | **pre-charge `admit` block** (no turn/memory/CB charged); `:on_error` **`:open`** (flaky guard → pass), **`:closed`** (→ violation), **`:reraise`** (config bug crashes); **SemanticScope** fast_path short-circuit + classifier `{:block, reason}` → constraint; malformed return always raises |
| **Compaction** (1.0, 🟡) | compaction_turn vs live API | force **window-exceeded** at `:steering` boundary → compactor fires; history rebuild correct after compaction |

🟢 0.7 behaviours: one thin smoke confirming default-off behavior unchanged; no
deep dig.

## Bug capture, severity & go/no-go

**Severity rubric:**

- **Blocker** — data loss; corruption on resume/rehydrate; guardrail **fail-open**
  (disallowed input passes); crash on a documented path; credentials persisted.
  → **any open Blocker = no-go.**
- **Major** — wrong behavior under an edge case but recoverable and not
  security-relevant. → triaged case-by-case; may ship as a documented known-issue.
- **Minor** — cosmetic, logging, message text.
- **Flaky** — timing-dependent; logged for investigation, not an automatic blocker.

**Bug entry format:** title · severity · exact repro command · observed vs expected
(with cited evidence line) · root-cause **theory** (explicitly marked theory until
verified — no silent "probably").

**Go/no-go table:** one row per 🔴/🟠 feature → {suites green?, smokes clean?,
fault-inject survived?, open blockers}. Release is **go** iff zero open Blockers.

## Open assumptions (verify during implementation)

- An Anthropic `API_KEY` is available locally and hitting the live API for the
  smoke + integration suites is acceptable (mind the ~50 RPM org limit noted in
  CI — the smokes use `claude-haiku-4-5-20251001` and low `max_tokens`).
- Docker is available locally for `docker-compose.verify.yml`.
- The existing tagged suites (postgres/redis/distributed) are expected to pass
  against real backends; failures there are bugs (the whole point), not setup gaps
  — setup correctness is part of step 1.
