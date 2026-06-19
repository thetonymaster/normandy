# Normandy Agent Horde — Demo Design

**Date:** 2026-06-19
**Status:** Design — pending Q review
**Author:** Brainstormed with Q

## Goal

Build a new example app, `examples/agent_horde/`, that takes **one research
question** and runs ~13 Normandy agents through a parallel fan-out pipeline
touching **7 live external services**, then synthesizes a cited report and
writes it to a **local Markdown file**.

It is a screen-recording vehicle: Q drives the terminal at human pace and edits
the footage. The companion deliverable is a **shot-by-shot video script** (not a
rendered video — we explicitly abandoned the flaky VHS auto-render approach).

Secondary win: the repo currently ships only `customer_support_app`. This
becomes Normandy's flagship **multi-agent + multi-provider** example, and the
core LLM adapter it requires is a real, reusable library feature.

## Verified service palette (probed live, 2026-06-19)

Used by the horde (7):

| Category | Service | Auth | Notes |
|---|---|---|---|
| LLM | Anthropic (Claude) | `ANTHROPIC_API_KEY` | via existing `Claudio` |
| LLM | OpenAI | `OPENAI_API_KEY` | via new adapter |
| LLM | DO Inference | `DO_INFERENCE_KEY` + `DO_INFERENCE_URL` (`https://inference.do-ai.run/v1`) | OpenAI-compatible; same new adapter |
| Search | Exa | `EXA_API_KEY` | POST `api.exa.ai/search` |
| Search | SerpAPI | `SERPAPI_API_KEY` | GET `serpapi.com/search.json` |
| Search | Serper | `SERPER_API_KEY` | POST `google.serper.dev/search` |
| Scrape | Firecrawl | `FIRECRAWL_API_KEY` | POST `api.firecrawl.dev/v2/scrape` |

Deliberately **not** used:
- **Neon Postgres / Resend email** — removed from the pipeline at Q's request.
- **DO Spaces / S3** — the report is written to a local file, not uploaded.
- **DigitalOcean droplet API** — provisioning costs money; DO is used only as an
  LLM provider (inference), not for infrastructure.
- **Tika** — `localhost:9999` unreachable and its Phoenix client certs are
  missing files; test-only mTLS fixture, not a live service here.
- **Twilio / Grafana Cloud / TLS cert paths** — excluded by Q.

## Architecture

```
 you ▸ "<research question>"
   │
   ▼  ① PLANNER  (Claude)            decompose → 3 sub-queries + angle
   │
   ▼  ② SEARCH FAN-OUT (parallel, 3 agents, 3 providers)
        Exa-agent   SerpAPI-agent   Serper-agent      each returns top URLs+snippets
   │
   ▼  ③ CURATOR  (Claude)            merge + dedup URLs, pick top ~4 sources
   │
   ▼  ④ SCRAPE FAN-OUT (parallel, ~4 agents)   Firecrawl markdown per source
   │
   ▼  ⑤ ANALYST FAN-OUT (parallel, 3 agents, 3 DIFFERENT PROVIDERS) ★
        Claude-analyst   GPT-analyst (OpenAI)   DO-analyst (DO-inference)
   │
   ▼  ⑥ EDITOR  (Claude)            synthesize ONE cited report from 3 analyses
   │
   ▼  ⑦ WRITER  (deterministic)     write reports/<slug>-<ts>.md, return path
   │
   ▼  CLI prints: the report + the local file path
```

Agent count: Planner 1 + Searchers 3 + Curator 1 + Scrapers ~4 + Analysts 3 +
Editor 1 = **~13 LLM/tool agents**; the three parallel fan-out points (search,
scrape, analyst) are the showcase. The final write is plain file I/O, not an LLM
agent.

### Why this shape
- **Two parallel fan-outs over different providers** (3 search engines, 3 LLM
  providers) are the showcase: they exercise Normandy's `parallel` workflow
  execution (`Task.async_stream`, verified in
  `test/integration/multi_agent_workflows_test.exs`) and the new
  provider-agnostic `Model` adapter.
- Sequential steps (Planner → Curator → Editor → Writer) carry data between
  fan-outs, matching Normandy's workflow model (steps sequential, agents within a
  block concurrent; each agent in a block receives the same step input).

## Components to build

### 1. Core library: `Normandy.LLM.OpenAICompatibleAdapter` (NEW)

- **File:** `lib/normandy/llm/openai_compatible_adapter.ex`
- **Test:** `test/llm/openai_compatible_adapter_test.exs`
- Implements the `Normandy.Agents.Model` protocol (`completitions/6`,
  `converse/7`) against any OpenAI-compatible `/chat/completions` endpoint.
- Struct carries `base_url`, `api_key`, and optional `organization`. One adapter
  instance per provider:
  - OpenAI → `base_url: "https://api.openai.com/v1"`, `OPENAI_API_KEY`
  - DO inference → `base_url: DO_INFERENCE_URL`, `DO_INFERENCE_KEY`
- Uses **Req** (already transitive via Claudio). JSON via Jason/Poison.
- `converse/7` maps Normandy messages → OpenAI `messages`, sends
  `model/temperature/max_tokens`, parses the assistant content back into the
  agent's `response_model`. Returns `{populated_response_model, usage_map}` to
  match `ClaudioAdapter`'s contract.
- Tool-calling: the analyst agents in this demo need **no tools** (pure
  summarization), so v1 of the adapter implements text completion only and may
  raise a clear error if `opts[:tools]` is non-empty. (Full OpenAI function-call
  support is out of scope for this demo; noted as a follow-up.)
- Mirrors `ClaudioAdapter` error handling and telemetry shape where practical.

### 2. Example app `examples/agent_horde/`

```
examples/agent_horde/
  mix.exs                         # deps: {:normandy, path: "../../"}, {:claudio, "~> 0.5.0"}, {:req, ...}, {:jason, ...}
  config/config.exs, config/dev.exs   # adapter (Poison), Logger level :warning for clean recording
  lib/agent_horde.ex
  lib/agent_horde/cli.ex          # interactive prompt + rich per-stage logging (the on-camera visual)
  lib/agent_horde/pipeline.ex     # orchestrates the 7 stages (DSL.Workflow + Reactive for dynamic fan-out); final stage writes the .md file
  lib/agent_horde/clients.ex      # builds Claude / OpenAI / DO Model client structs from env
  lib/agent_horde/agents/{planner,curator,searcher,scraper,analyst,editor}.ex
  lib/agent_horde/tools/{exa_search,serpapi_search,serper_search,firecrawl_scrape}.ex
  lib/agent_horde/schemas/...     # io_schema input/output structs per agent
  reports/                        # generated .md reports land here (git-ignored)
  test/agent_horde_test.exs       # offline smoke test (tools/agents stubbed) — no live keys in CI
```

**Tools** (each `defimpl Normandy.Tools.BaseTool`, `run/1` does a `Req` call):
- `ExaSearch`, `SerpApiSearch`, `SerperSearch` — query → `[%{url,title,snippet}]`
- `FirecrawlScrape` — url → `%{url, title, markdown}`

**Agents:**
- DSL-defined single agents (`use Normandy.DSL.Agent`): Planner, Curator, Editor —
  fixed role, fixed (or no) tool.
- Programmatic agents via `BaseAgentConfig` for the fan-outs, so they can be
  parameterized:
  - `Searcher` instantiated 3× with a different search tool each.
  - `Scraper` instantiated N× (one per curated URL), run via `Reactive.all/2`.
  - `Analyst` instantiated 3× with a different `:client` each (Claude / OpenAI /
    DO) — this is where the new adapter is exercised.
- `clients.ex` builds the three `Model` client structs from env once and hands
  them to the right agents.

**Final write (⑦):** plain `File.write!` of the Editor's `report_markdown` to
`reports/<slugified-question>-<utc-timestamp>.md`; returns the path. Deterministic
— not an LLM agent.

**CLI / pipeline driver:**
- Interactive: `🧠 Ask the horde:` → read question → run pipeline → print report
  + local file path.
- Each stage emits a labeled progress line (engine names, provider names, source
  count, per-stage timing). This logging is the primary thing the camera
  captures, so it is designed for legibility, not debug noise.

### Data flow & schemas (io_schema per agent)
- Planner out: `%{queries: [string], angle: string}`
- Searcher out: `%{engine: string, results: [%{url, title, snippet}]}`
- Curator out: `%{selected_urls: [string], reason: string}`
- Scraper out: `%{url, title, markdown}`
- Analyst out: `%{provider: string, summary: string, key_points: [string]}`
- Editor out: `%{report_markdown: string, sources: [string]}`
- Pipeline final return: `%{path: string, bytes: integer}`

Display fields (`summary`, `report_markdown`) are prose-only by instruction —
we previously hit raw-JSON leakage in a greeter agent, so output_instructions
explicitly forbid JSON/code-fences in prose fields.

## One-time setup before recording (I perform; reversible)
1. Smoke-run the pipeline once on a throwaway question to confirm all 7 services
   answer end-to-end and the local report file is written and readable.

No external setup — no buckets, no Neon, no Resend, no droplets. The horde writes
its report under `examples/agent_horde/reports/` (git-ignored).

## Deliverables to Q
1. A **working horde** runnable as `cd examples/agent_horde && mix run -e
   'AgentHorde.CLI.start()'` (or similar), producing live multi-agent output and
   a local `.md` report.
2. A **shot-by-shot video script** (`marketing/demo-1.0/agent-horde-script.md`):
   terminal/font setup, the exact command, the question to type, what each
   on-screen beat shows, caption/narration suggestions, rough timing, and the
   reveal (open/`cat` the generated report `.md`). Q records + edits.

## Risks & mitigations
- **New core adapter is library code** → full unit tests; project rule: all
  tests pass. Kept minimal (text completion only).
- **Live latency** (search+scrape+9 LLM calls) → a *feature* on camera (real work
  visible); Q controls pacing. Pipeline logs per-stage timing so slow stages read
  as "thinking," not "hung."
- **Provider output variance** (OpenAI/DO returning unexpected shapes) → adapter
  parses defensively and the Editor tolerates a missing analyst (fan-out is
  fail-slow: a dead analyst doesn't sink the run).
- **Cost** → ~9 LLM calls + a handful of search/scrape calls per run; cents.

## Out of scope
- Neon, Resend, DO Spaces, Twilio, Grafana, DO droplet provisioning, Tika.
- OpenAI function-calling / tool-use through the new adapter (text completion
  only for v1).
- Any change to Normandy core beyond adding the one `Model` adapter.
- VHS / auto-rendered video; voiceover; captions burned in (Q edits).
```
