# Normandy pre-2.0 audit — consolidated (2026-10-04)

Source reports (same dir): audit-release.md, audit-security.md, audit-telemetry.md,
audit-perf.md, audit-devex.md, audit-agentx.md. 156 raw findings; duplicates merged below.
"Spot-checked" = orchestrator re-read the code path; everything else is the agent's claim.

Baseline: `mix precommit` green — 2551 tests / 73 doctests / 28 properties, 0 failures;
credo clean; dialyzer 31 skipped (ignore file). Coverage 82%.

## Tier 0 — blocks publishing 2.0
| ID | Finding | Status |
|---|---|---|
| REL-1 = DX-3 | Claudio `path:` dep — hex.build refuses, CI deps.get fails; mix.exs version 1.3.0 | spot-checked (hex.build output) |
| REL-2 | `mix docs --warnings-as-errors` fails (2× `c:` callback ref, hidden ServerGlue ref) | agent ran |
| REL-3 | cog: PR title without `!` releases v1.4.0 | agent simulated on clone |
| DX-1 = AX-2 | No `max_tokens` default; README quickstart omits it → nil → key dropped (`claudio_adapter.ex:573`) → API 400 on first run | spot-checked code path, not live |
| AX-1 | Agent with tools ignores custom `output_schema`: response model is ToolCallResponse (`base_agent.ex:580`), non-chat_message schemas get raw response back (`:783`) | spot-checked |

## Tier 1 — breaking changes: 2.0 or wait for 3.0 (decision needed)
- DX-2 delete `Model.completitions/6` (unused, misspelled) — spot-checked
- SEC-1 tool input mapped onto ANY struct field, not schema-declared keys (`dispatch.ex:194,480`) — spot-checked
- PERF-2 (+DX-27) breaker `start_link`ed from `init/1` caller (`base_agent.ex:137`); caller exit → `:noproc` forever. Bundle PERF-1 (killed half-open probe never frees slot), PERF-9 (admission race), A2 remainder, TEL-6 (no breaker/retry telemetry) into one breaker redesign — spot-checked start_link
- DX-5 (+TEL-2) three error models; Turn.Server wraps errors as `{:task_down, {exc, stack}}` (bad `error.type`, stacktrace args in telemetry + persisted state)
- DX-4 Model protocol: 7 positional args, streaming not in protocol
- DX-6/DX-7/DX-12 silent unknown-key/option drops in init/1, ~20 entry points, default input schema
- DX-11 duplicate run/run_with_tools, stream_response/stream_with_tools
- MEDIUM breaking: DX-14..DX-30 subset (see audit-devex.md breaking table)

## Tier 2 — HIGH, non-breaking, fix before merge
Release/docs: REL-4 MIGRATING missing ~15 breaking changes; REL-5 CHANGELOG; REL-6 integration test uses removed retry opts (spot-checked); REL-7=DX-13 docs groups (nonexistent IOModel, 104 ungrouped); DX-8 ship a fake client + testing guide; DX-9 export locals_without_parens; DX-10 @doc on core API, delete `Normandy.hello/0`.
Deps: TEL-1 `telemetry ~> 1.0` but memory span uses 3-tuple return (needs ≥1.3) — spot-checked.
Agent loop: AX-3 server MCP calls dispatched locally; AX-4 stop_reason ignored in tool loop (max_tokens/pause_turn/refusal); AX-5 iteration cap behaviour; AX-6 parallel results as N user messages; AX-7 assistant turns rebuilt not replayed (PLAUSIBLE 400, needs live probe); AX-9 summarizer drops tool results (atom/string key); AX-10 truncated JSON stored as answer; AX-11 `"description": null` in schemas.
Size caps: SEC-3 = AX-8 no tool-result size cap; SEC-6 = PERF-11 memory namespace cap counts first 1000 docs only.
Perf: PERF-3 quadratic history re-encode (B1) + compactor re-encodes; PERF-4 Turn.Server.init does store IO inside start_child.
Output validation: SEC-5 = TEL-4 invalid output returned as valid + full model output via IO.warn.

## Tier 3 — MEDIUM (by area; details in source reports)
Security SEC-2,4,7,8,9 · Telemetry TEL-3,5,7 · Perf PERF-5..10,12, B2/B3/B5 · AgentX token budgeting, error-result wording, schema ordering/constraints, caching placement · DevEx DX-14..30 non-breaking subset.

## Tier 4 — LOW
SEC-10..18, TEL-8..17, PERF-13..16, AX LOW ×10, DX-31..36, REL LOW (priv/test_repo shipped, elixir_uuid deprecation, req constraint, stray files, REL-8 `--trace` failure, REL-9 e2e not rerun since hooks/memory).

## Also noted
- Prompt audit 2026-09 memory was stale: 10/11 findings already fixed; open: AX-25 dated section headers.
