# Autoresume Demo — Distributed Node-Kill Handoff

- **Date:** 2026-06-24
- **Status:** Approved (design); ready for implementation planning
- **Author:** Q (Antonio Cabrera)
- **Topic:** A runnable demo + mini web dashboard proving Normandy agents survive a full BEAM node kill and resume on a surviving node.

## 1. Goal

Demonstrate, live and convincingly, the autoresume capability already implemented in
Normandy (Phase 4b suspend/resume, Phase 7 distributed sessions, `ResumeReaper`):

> Kill an entire BEAM node while real Claude-powered agents are mid-task on it, and
> those agents reappear on a surviving node and continue from where they left off —
> visibly, on a live dashboard, with no human intervention.

The demo adds **no new resume logic** to the library. It is orchestration + instrumentation
+ a UI built on top of the existing, tested mechanism.

## 2. Decisions (keystones, approved)

| Decision | Choice | Why |
|---|---|---|
| Headline scenario | **Distributed node kill → `ResumeReaper` handoff** | Most dramatic; exercises the real distributed story |
| Dashboard medium | **Small web page** (Bandit + Plug, Server-Sent Events) | Visual node→node migration is the payoff; dev-scoped deps only |
| Agent work | **Real Claudio/Anthropic LLM calls** (with a deterministic `simulated` fallback toggle) | Convincing as "real agents"; simulated mode is the live-demo safety net |
| Cross-node state | **Postgres store + Horde registry** | Exactly matches the proven `resume_reaper_integration_test.exs` wiring |
| Cluster launch / kill | **`:peer` nodes launched by one command + in-dashboard "Kill node" button** | One scripted command; the kill button is the demo's drama and is reliable |

## 3. Grounded mechanism (verified against the codebase — do not re-derive)

These are the load-bearing facts the implementation relies on. All verified with file
references during brainstorming.

- **Suspend/resume FSM:** `Normandy.Agents.Turn.Server` is a `:gen_statem` with states
  `:idle`, `:running`, `:awaiting_approval`. Non-terminal `Turn.State` statuses
  (`:provisioning`, `:assistant_streaming`, `:tool_dispatch`, `:awaiting_approval`,
  `:steering`) are resumable; `:stopped`/`:failed` are terminal
  (`Turn.Server.resumable?/1`).
- **Eager auto-resume:** when started with `resume_policy: :eager` and a resumable
  persisted state, `Turn.Server.init/1` enqueues `{:next_event, :internal, :resume}` →
  `Turn.resume/1` re-derives effects and continues with no caller.
- **What is persisted (per session id):** the full `Turn.State` struct
  (`save_turn_state/3`), the conversation history as `AgentMemory.Entry` chain
  (`append_entry/3` / `history/2`), and a non-secret `ConfigTemplate`
  (`save_config_template/3`) plus `resume_policy`.
- **Tier-2 reconstruction (the heart of cross-node handoff):**
  `Turn.Server.reconstruct_config!/3` loads the template → fetches the node-local
  supplement from the template provider (`AgentTemplate.Catalog.fetch/2`: `tool_registry`,
  `before_hooks`, `after_hooks`, `client_builder`) → gets a token from the credential
  provider (`CredentialProvider.get_token/2`) → calls
  `ConfigTemplate.rebuild/3` which invokes `supplement.client_builder.(token)` to build a
  **fresh Claudio client** → reloads history. Fail-closed on missing token/history.
- **Claudio client is transferable:** it is a plain `Req.Request` struct (config-only, no
  live socket/pid), so it can be rebuilt on any node from just an API token + model
  settings. Confirmed in `lib/normandy/llm/claudio_adapter.ex` and
  `deps/claudio/lib/claudio/client.ex`.
- **`ResumeReaper`:** `:net_kernel.monitor_nodes(true)`; on `{:nodedown, _}` calls `reap/1`
  → `store.list_resumable` (eager sessions) → for each, if `registry.whereis == :none`
  **and** persisted turn state is non-terminal, restart via a **thin spec** (no `:config`;
  server reconstructs it). Concurrent reapers on multiple survivors are race-safe via the
  registry's atomic `:via` registration (`{:already_started, _}` treated as success).
- **Horde does NOT redistribute on node death** — it drops the dead node from its CRDT
  (so `whereis` returns `:none`). The `ResumeReaper`, not Horde, brings the agent back.
  This is why the reaper is mandatory for the demo.
- **Per-node wiring helper:** `Normandy.Cluster.child_specs/1` returns specs for the Horde
  registry (`SessionRegistry.Horde`, `members: :auto`), Horde supervisor
  (`Turn.Supervisor.Horde`, `members: :auto`), and the `ResumeReaper` (only when both
  `:store` and `:template_provider` are given). The demo calls this on every worker node.
- **Dashboard signal must be demo-owned:** the reaper restarts a session with a thin spec
  that carries **no `:subscriber`**, so the library's per-server event closure
  (`:iteration`/`:steering`/`:awaiting_approval`) does not survive handoff. The demo
  therefore instruments its own **tools** to emit a heartbeat (see §6).
- **Proven by tests:** `test/agents/turn/resume_reaper_integration_test.exs`
  (reaper → reconstruct → resume with Postgres + Horde), `eager_handoff_distributed_test.exs`
  (`:peer` nodes), `horde_distributed_test.exs` (cluster-wide `whereis` + atomic register),
  `tier2_integration_test.exs` (reconstruction path).

## 4. Architecture

### 4.1 Topology

| Node | Role | Runs |
|---|---|---|
| `observer@127.0.0.1` | control plane + UI | `DemoCollector`, Bandit web server (dashboard), cluster launcher (`:peer` supervisor), seeds |
| `node_a` / `node_b` / `node_c@127.0.0.1` | agent workers (`:peer` nodes) | Horde registry + Horde supervisor (`members: :auto`), `ResumeReaper`, `AgentTemplate.Catalog` (pre-populated), env credential provider, instrumented demo tools |

Shared state: **one Postgres instance** reachable by all worker nodes
(`docker-compose.verify.yml` already exposes Postgres on the port `config/test.exs` uses).

### 4.2 Agents and their work (real LLM, deliberately multi-step)

Each agent runs a multi-iteration tool loop modeled on `examples/agent_horde` — e.g.
"research topic X in N steps", calling an instrumented tool each iteration
(`research_step`, `summarize`). Multi-step is required: turn state is persisted at each
`:steering` boundary, so a node kill leaves genuine accumulated progress (history +
iteration count) to resume from, not just a single re-issued call. Agents are started
**eager + Tier-2** (template + credential provider) so the reaper can reconstruct them.

### 4.3 Failure → resume flow

1. Agent `research-c1d8` runs on `node_c`, step 9/20, turn state persisted `:steering`.
2. Operator clicks **Kill node_c** (POST `/kill/node_c`) → launcher halts that `:peer` node.
3. Horde drops `node_c` from its CRDT → session registration gone (`whereis → :none`).
4. `ResumeReaper` on a survivor catches `:nodedown` → `list_resumable` → finds
   `research-c1d8` (eager, unregistered, `:steering` = non-terminal).
5. Restart via thin spec → `reconstruct_config!` (template + Catalog supplement + env
   token) → **rebuilds a fresh Claudio client** → reloads history from Postgres.
6. `init/1` auto-resumes (`:eager` → internal `:resume`) → loop continues from step 9.

### 4.4 Dashboard

A small web page served by Bandit on the observer node, live-updated via SSE:

```
NORMANDY · Autoresume Live                    cluster: 2 up · 1 down       14:22:07
┌─ node_a ────────────────────┐ ┌─ node_b ────────────────────┐ ┌─ node_c ────────────────────┐
│ ● UP   uptime 02:14         │ │ ● UP   uptime 02:14         │ │ ✖ DOWN  killed 14:21:58     │
│ ┌ research-a3f2 ──────────┐ │ │ ┌ research-9b71 ──────────┐ │ │                             │
│ │ ▶ running   step 12/20  │ │ │ │ ▶ running   step  7/20  │ │ │  (no agents — node down)    │
│ │ ███████████░░░░░░░ 60%  │ │ │ │ ██████░░░░░░░░░░░░ 35%   │ │ │                             │
│ │ tool: research_step(…)  │ │ │ │ tool: summarize(…)      │ │ │                             │
│ └─────────────────────────┘ │ │ └─────────────────────────┘ │ │                             │
│ ┌ research-c1d8 ──────────┐ │ │                             │ │                             │
│ │ ↻ RESUMED from node_c   │ │ │                             │ │                             │
│ │   step 9/20 (was 9) ✓   │ │ │                             │ │                             │
│ └─────────────────────────┘ │ │                             │ │                             │
│        [ Kill node_a ]       │ │       [ Kill node_b ]       │ │      [ Restart node_c ]     │
└──────────────────────────────┘ └──────────────────────────────┘ └──────────────────────────────┘

EVENT LOG  (proves agents kept running)
14:21:58  ✖  node_c killed (manual) — research-c1d8 was @ step 9
14:22:01  ⚠  reaper(node_a): nodedown node_c → scanning store
14:22:01  ↻  reaper(node_a): research-c1d8 unregistered, turn_state=:steering → restarting here
14:22:02  ✓  research-c1d8 reconstructed on node_a (Tier-2 rebuilt Claudio client), history=8
14:22:03  ▶  research-c1d8 resumed at step 9/20 — continuing
```

Columns = nodes; cards = agents with a live step counter + progress bar + current tool
(the "agents are still running" proof); a **Kill node** button per column; an **event log**
narrating the handoff. A killed node's column offers **Restart node** to re-add capacity.

## 5. Event flow (survives handoff)

- Every instrumented tool casts `{:agent_step, session_id, node(), step, total, tool_name}`
  to the globally-registered `DemoCollector` on the observer, once per iteration. Because
  the reconstructed agent re-runs the same tools on the new node, the heartbeat resumes
  automatically — the node field flips and the counter continues.
- `DemoCollector` also runs `:net_kernel.monitor_nodes(true)` for authoritative
  `node down/up` events (the "reason" an agent went offline).
- `DemoCollector` folds these into per-agent state and pushes diffs to the browser over SSE
  (`GET /events`).

## 6. Project layout

The demo is its **own mix app** under `examples/` (like `agent_horde` /
`customer_support_app`). It depends on Normandy via a `path:` dep and owns its own deps, so
**the Normandy library's dependency tree is never modified**.

```
examples/autoresume_demo/
  mix.exs                       # path dep on ../.. (normandy) + {:postgrex, :ecto_sql, :bandit, :plug, :jason}
  config/config.exs             # Repo + dashboard port (4000) + DEMO_MODE
  lib/autoresume_demo/
    application.ex              # observer-side tree: Repo, Catalog, DemoCollector, web server, launcher
    cluster_launcher.ex         # spawns :peer nodes; wires Normandy.Cluster.child_specs per node; kill/restart
    repo.ex                     # Ecto repo for the Postgres session store
    env_credential_provider.ex  # ~10 lines: {:ok, System.fetch_env!("ANTHROPIC_API_KEY")}
    tools/research_step.ex       # instrumented BaseTool — real work (real or simulated) + heartbeat cast
    collector.ex                # DemoCollector GenServer (node monitor + per-agent state + SSE pub)
    web/router.ex               # Plug.Router: GET / (HTML), GET /events (SSE), POST /kill/:node, POST /restart/:node
    web/page.ex                 # the dashboard HTML/JS (SSE client; columns + cards + log)
    seeds.ex                    # starts the demo agents (eager, Tier-2) distributed across the cluster
  priv/repo/migrations/         # normandy_sessions + normandy_session_entries (reuse Postgres schema)
  README.md                     # run instructions + narration script for presenting
```

## 7. Running it

```bash
docker compose -f docker-compose.verify.yml up -d postgres
export ANTHROPIC_API_KEY=sk-...            # required for DEMO_MODE=real
cd examples/autoresume_demo && mix deps.get && mix ecto.setup
iex --sname observer -S mix                # boots cluster + dashboard, prints http://localhost:4000
# open the page, watch agents run, click "Kill node_c", watch the handoff
```

## 8. `DEMO_MODE` toggle (explicit, no silent fallback)

`DEMO_MODE=real` (default): `client_builder` builds a real Claudio client from the env
token; agents make real Anthropic calls.

`DEMO_MODE=simulated`: `client_builder` returns a stub that drives the same tool loop on a
timer with canned content. The **exact same** node-kill/resume mechanics run, offline and
deterministically. This is the live-demo safety net and the CI-able path. The mode is read
once at boot and logged; it never falls back automatically — if `real` is selected and the
key is missing, the app crashes loudly at boot.

## 9. Risks & mitigations

- **API/network flakiness in a live demo** → `DEMO_MODE=simulated` reproduces the full
  mechanic without the network.
- **`:peer` + Postgres + Horde timing/convergence** → follow `resume_reaper_integration_test.exs`
  wiring verbatim; add only orchestration + UI, no new resume logic.
- **Trivial-looking resume** → agents are multi-step (§4.2) so mid-task progress is visible.
- **Mnesia replication risk** → avoided by choosing Postgres (the proven path).

## 10. Acceptance criteria

1. One command brings up a 3-worker cluster + dashboard; the page lists each node and the
   agents running on it, with live-updating step counters.
2. In `DEMO_MODE=real`, agents make real Anthropic calls and the dashboard shows real
   tool progress.
3. Clicking **Kill node_X** halts that node; the dashboard marks it DOWN and logs the
   reason; any agent that was on it is shown as orphaned.
4. Within seconds, the `ResumeReaper` restarts each orphaned eager agent on a surviving
   node; the dashboard shows the agent's card move to the new node's column with a
   "RESUMED from node_X" badge and the **step counter continuing** from where it stopped.
5. The event log narrates: nodedown → reaper scan → reconstruct (Tier-2 client rebuild) →
   resume.
6. `DEMO_MODE=simulated` runs the identical flow with no network/API key, deterministically.
7. The Normandy library's `mix.exs` deps are unchanged (all demo deps live in
   `examples/autoresume_demo/mix.exs`).

## 11. Out of scope (YAGNI)

Authentication, dashboard persistence, multi-cluster, Redis/Mnesia store variants
(Postgres only), production hardening, Phoenix integration, approval-wait and idle-passivation
scenarios (node-kill is the single headline flow).
