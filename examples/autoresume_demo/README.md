# Autoresume Demo — Distributed Node-Kill Handoff

Real Claude-powered agents run on a local multi-node BEAM cluster. Kill a whole
node and watch the `ResumeReaper` reconstruct each agent on a surviving node and
resume it from persisted state — live, on a web dashboard.

## Prerequisites
- Docker (for Postgres) — or any Postgres reachable on `localhost:5432`.
- For real mode: `ANTHROPIC_API_KEY`.

## Run (real mode)
```bash
docker compose -f ../../docker-compose.verify.yml up -d postgres
export ANTHROPIC_API_KEY=sk-...
mix deps.get
mix ecto.setup
iex --name observer@127.0.0.1 --cookie demo -S mix
# open http://localhost:4000
```

## Run (simulated mode — no API key / offline, deterministic)
```bash
docker compose -f ../../docker-compose.verify.yml up -d postgres
export DEMO_MODE=simulated
mix deps.get && mix ecto.setup
iex --name observer@127.0.0.1 --cookie demo -S mix
# open http://localhost:4000
```

## What you'll see
- One column per worker node; each running agent is a card with a step counter
  and progress bar that keeps advancing (proof the agents are running).
- Click **Kill <node>**: the column flips to DOWN, the event log records the
  reason, and within seconds the agent reappears in another column with a
  **↻ RESUMED from <node>** badge and its step counter continuing.

## Configuration (env)
| Var | Default | Meaning |
|---|---|---|
| `DEMO_MODE` | `real` | `real` or `simulated` (no silent fallback) |
| `DEMO_MODEL` | `claude-3-5-sonnet-20241022` | model id (override to a newer id your account supports) |
| `WORKER_NODES` | `3` | number of worker :peer nodes |
| `DASHBOARD_PORT` | `4000` | web dashboard port |
| `SIM_STEP_DELAY_MS` | `1500` | per-step delay in simulated mode |
| `POSTGRES_*` | see config | DB connection |

## How it works
See `docs/superpowers/specs/2026-06-24-autoresume-demo-design.md`. The dashboard
reads the same durable Postgres state the resume mechanism uses; real-vs-simulated
switches only at the `client_builder` (the seam carried through Tier-2 handoff).
