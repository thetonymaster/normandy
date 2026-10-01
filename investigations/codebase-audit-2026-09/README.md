# Codebase audit — bad practices, anti-patterns, testing gaps (2026-09-30)

Branch `feat/claudio-0.7-migration` at `1e3182b`. Five read-only auditors, one per area
(`agents.md`, `llm.md`, `schema.md`, `otp.md`, `tests.md` in this directory, full evidence per
finding). Excludes anything Credo `--strict` / Dialyzer now catch, and the races/perf items in
`../performance-race-audit.md` (each area file lists those as "Known"; all still present).

**75 findings: 20 HIGH, 33 MEDIUM, 22 LOW.** Nothing fixed here.

Added after the audit (2026-09-30, while designing approval expiry): AGENTS-16 (ResumeReaper
restarts sessions without their server options) and OTP-16 (`Turn.Supervisor` default restart
intensity), both MEDIUM.

## How much to trust each finding

| Mark | Meaning | Findings |
|---|---|---|
| **E** | Coordinator executed a probe and saw the failure | SCHEMA-1, SCHEMA-2, SCHEMA-5, LLM-3, AGENTS-4, TESTS-1, TESTS-2 |
| **R** | Coordinator re-read the code path | LLM-1, LLM-2, AGENTS-1, OTP-2, OTP-10 |
| — | Auditor read the code; not re-checked | everything else (theories are labelled in the area files) |

Probe results (`mix run`, throwaway script):
- SCHEMA-5: `validate_number(:n, greater_than: 0)` → `ArgumentError "expected option greater_than to be a decimal, integer, or float, got: 0"`.
- LLM-3: `SchemaBinder.bind(%{"text" => "hi"}, schema_with_text_field)` → `{:error, {:validation_error, ...}}`.
- SCHEMA-1: spec property types for `:map` / `:date` fields are `:map` / `:date` (not JSON Schema types).
- SCHEMA-2: `Validate.cast` on a nested-schema field → `UndefinedFunctionError Inner.cast/1`.
- AGENTS-4: a workflow with `transform fn r -> r end` fails to compile: `cannot escape #Function<...>`.
- TESTS-1: `ci.yml` had no Postgres/Redis/distributed job. Locally, with epmd + Postgres, `--include distributed --include postgres` → 1557 tests, 0 failures. (Postgres/Redis jobs since added, `1e3182b`; distributed still not run in CI.)
- TESTS-2: `mix test --cover` → Sequential/Parallel orchestrators and HierarchicalCoordinator at 0% (only live-API `:integration` tests touch them). Total coverage 70.1%.

## Themes

### 1. Errors become data (the dominant pattern)
A failure is converted into a normal-looking value, so nothing upstream can react.
- **LLM-1 (R)** `ClaudioAdapter.handle_error/2` does `IO.warn` and returns the blank
  `response_model`: a 401/429/529/timeout is an empty successful reply. Retry and CircuitBreaker
  only ever see raises, so they never fire on API errors; the Summarizer gets `""` and replaces
  history with an empty summary.
- **LLM-4** mid-stream `error` events and `{:error, _}` items are dropped; truncated output (and a
  half-streamed `tool_use`) comes back as success.
- AGENTS-7 (`ConverseResult.normalize` accepts `{:error, _}` as a response), AGENTS-8 (bad tool
  JSON → `%{}` and the tool runs), OTP-1 (store backend error → "no turn state" → in-flight turn
  dropped on rehydrate), OTP-4 (`Batch.Processor` → `nil` per failed item), OTP-6 (orchestrators
  feed error tuples to the next agent), LLM-5, AGENTS-5.

Root cause: `Model.converse/7` has no error return in its contract. One fix covers most of the
list: let `converse/7` return `{:error, reason}`, make `ConverseResult.normalize` pass it through,
treat it as retryable in `call_llm_with_resilience`, and handle it in Summarizer/streaming.

### 2. Guards that fail open
- **AGENTS-3** output guardrails only log + emit telemetry; non-streaming callers get no signal.
  (Commented as deliberate; it means an output guardrail does not guard.)
- SCHEMA-3 (composition/`if` keywords ignored on scalar/`:map` fields; `const` unimplemented),
  SCHEMA-8 (built-in guards pass when `:field` is misspelled), OTP-7 (`PolicyEngine.Ruleset`
  allows on a malformed rule), AGENTS-6 (`function_exported?` without `Code.ensure_loaded`
  skips validation), SCHEMA-10 (`redact: true` only affects `Inspect`; `to_json` still emits it).

### 3. Configuration silently dropped or ignored
- **AGENTS-2** `ConfigTemplate.from_config/rebuild` loses input/output guardrails, retry,
  circuit breaker, MCP servers and JSON-retry settings: a Tier-2 session rebuilt from a template
  runs **without guardrails**, no error.
- AGENTS-9 (`resume_policy: :eager` dropped on every `Session` start path), AGENTS-10 (DSL
  `max_messages` no-op; unknown keys ignored), LLM-6 (`enable_json_retry`/`json_retry_max_attempts`
  dead), LLM-7 (documented `:timeout`/`:base_url` never read), OTP-8 (budget tracker opts
  dropped), SCHEMA-7 (field options never validated).

### 4. Features that cannot work (and nothing tests)
AGENTS-4 (Workflow `transform`/`when_result` don't compile; `condition` never evaluated),
SCHEMA-5 (`validate_number` raises on every valid call), SCHEMA-4 (`Executor.execute*` run the
registry's tool, not the one passed; duplicate names overwrite), OTP-2 (`execute_same_input`
crashes without `:transform`), OTP-5 (hierarchical round-robin overwrites results when tasks >
workers), TESTS-3 (schema `compute:` never evaluated), TESTS-4 (`ValidationMiddleware` unused).
Each is a fix-or-delete decision; deleting public API is a breaking change.

### 5. Schema → JSON Schema correctness
SCHEMA-1 (E) invalid `type` values for `:map`, `:date`, `:any`, `:binary`, custom/parameterized
types; SCHEMA-2 (E) nested schemas crash `Validate.cast` on the legacy binding path; LLM-3 (E)
`SchemaBinder` renames `text`/`message`/`response` → `chat_message` for every schema, so user
schemas with those common field names fail to bind; known A8 (`__specification__` used as the
schema) still present.

### 6. OTP
- **AGENTS-1 (R)** `Turn.Server` calls `admit_turn_input/2` (raises on validation/guardrail
  rejection) inside `handle_event`. A bad input crashes the session; `restart: :transient` under a
  `DynamicSupervisor` with default intensity (3 in 5 s) means a burst of bad inputs takes down
  `Turn.Supervisor` and every live session.
- AGENTS-13 (server tasks are unlinked `spawn`), OTP-3 (`AgentPool` documents error tuples it
  never returns), OTP-9 (`:mnesia` in `extra_applications` starts Mnesia for every consumer),
  OTP-11 (no `wait_for_tables`; broken chain truncates history silently).

### 7. Security-adjacent (none critical)
- OTP-10 (R) Redis registry uses plain `binary_to_term/1` on Redis data. Deliberate and commented
  (a pid embeds its node atom, so `[:safe]` would reject unseen nodes). Exploiting it needs Redis
  write access; an `is_pid/1` check after decode would bound it. Downgraded to LOW in effect.
- LLM-9 (`AgentMemory.load` instantiates arbitrary existing structs from dumped data),
  SCHEMA-9/LLM-13 (error messages dump raw params / base64 blocks / `req_options`, which can hold
  auth headers), OTP-13 (A2A server returns exception text to remote callers).
- The "never inspect a client" rule holds everywhere in `lib/llm` (both adapters derive
  `Inspect` excluding `:api_key`).

### 8. Testing
- TESTS-1 (E): CI ran none of Postgres/Redis/distributed. Postgres + Redis now added; the 7
  `:distributed` files still never run in CI (need `epmd` + `--include distributed`; one needs
  Postgres too).
- TESTS-2 (E): orchestrators only covered by live-API tests; HierarchicalCoordinator,
  SharedContext, AgentMessage untested.
- TESTS-5 sleep-for-sync in coordination tests (55 sleep sites / 25 files); TESTS-6 41/149 files
  `async: false`, 4 with no visible blocker; TESTS-7 `async: true` module attaches a global
  telemetry handler with a fixed id; TESTS-8/9 weak or missing assertions; TESTS-12 the ~85 test
  compile warnings include "this clause cannot match" (tests not testing what they claim).
- Isolation smell: `eager_handoff_distributed_test.exs` can't carry `:postgres` because starting
  distribution mid-suite corrupts Mnesia tests.

## Recommended order
1. **Error contract** (theme 1): `{:error, _}` through `converse/7` → normalize → resilience →
   Summarizer/streaming. Largest blast radius; unblocks Retry/CircuitBreaker actually working.
   Public contract change → needs a decision (fits the 2.0 break).
2. **AGENTS-1**: return `{:error, _}` from `Turn.Server` on rejected input instead of raising.
3. **LLM-2**: Summarizer default `summary_role` → not `"system"`; adapter should refuse a
   non-leading system message.
4. **AGENTS-2**: carry guardrails etc. through `ConfigTemplate` (or refuse to template a config
   that has them).
5. **Schema correctness**: LLM-3, SCHEMA-1, SCHEMA-2.
6. **Fix-or-delete** pass over theme 4 (each a public-API decision).
7. CI: a distributed job (`epmd -daemon`, `--include distributed`, Postgres service).
