# Normandy 2.0 release-readiness audit

Branch `feat/claudio-0.7-migration` (HEAD f7991a9, 358 commits ahead of `main`), audited 2026-10-04.
Toolchain locally: Elixir 1.19.5 / OTP 28. I did not edit or commit any tracked file. The working tree
afterwards shows only the pre-existing `?? investigations/genai-telemetry-audit.md`. I did not run the
live e2e suite or the live integration suite.

## Observed results (summary)

| Check | Command | Result |
|---|---|---|
| Format | `MIX_ENV=test mix format --check-formatted` | exit 0 (so precommit's `format` step changed nothing) |
| Precommit | `mix precommit` | **exit 0** |
| . credo | (in precommit) | `4404 mods/funs, found no issues.` |
| . dialyzer | (in precommit) | `Total errors: 31, Skipped: 31, Unnecessary Skips: 0` / `done (passed successfully)` |
| . tests | (in precommit) | `73 doctests, 28 properties, 2551 tests, 0 failures (203 excluded)` |
| Forced recompile | `MIX_ENV=test mix compile --force --warnings-as-errors` | exit 0, 186 files, no warnings |
| No optional deps | `MIX_ENV=dev mix compile --no-optional-deps --warnings-as-errors --force` | exit 0, 153 files |
| Consumer build | throwaway app with `{:normandy, path: ...}`, `MIX_ENV=prod mix compile` | exit 0; Normandy has no warnings; only a third-party warning from elixir_uuid |
| Random seeds | `mix test` x3 (seeds 646866, 512359, 141203) | 0 failures each |
| Trace mode | `mix test --slowest 10` (implies `--trace`) | **1 failure** (REL-8) |
| Coverage | `mix test --cover` + `mix test.coverage` | **82.08%** total (threshold 60) |
| Hex build | `MIX_ENV=dev mix hex.build --unpack` | **fails**: `Dependencies excluded from the package (only Hex packages can be dependencies): claudio` |
| Docs | `MIX_ENV=dev mix docs --warnings-as-errors` | **fails**: 3 warnings (REL-2) |
| Audit | `mix hex.audit` | exit 0 (4 advisories ignored in mix.exs; reasons documented there) |
| Version bump | cocogitto 7.0.0 dry run on a squash-merged clone | `v1.3.0 -> v1.4.0` without `!`, `v1.3.0 -> v2.0.0` with `!` (REL-3) |

---

## Findings

### REL-1 — BLOCKER — Claudio is a path dependency; 0.7.0 is not on Hex
**Evidence**
- `mix hex.build`: `** (Mix) Stopping package build due to errors. Dependencies excluded from the package (only Hex packages can be dependencies): claudio`
- `mix hex.info claudio`: latest Hex release `0.6.0 (2026-06-20)`. `../Claudio` is on `main` at a9dff4b with `@version "0.7.0"`, but its newest tag is `v0.6.0`, so 0.7.0 is untagged and unpublished.
- CI runners don't check out `../Claudio`, so every CI job's `mix deps.get` fails on GitHub for this branch. The PR can't go green until the dep is a Hex dep. (I inferred this from the workflow: `actions/checkout` checks out only this repo. I did not observe a CI run.)
- `mix.lock:7` still pins `"claudio": {:hex, :claudio, "0.6.0", ...}`, and `deps/claudio` holds the 0.6.0 Hex package. Path deps aren't locked, so neither is used, but `mix hex.outdated` misleadingly reports `claudio 0.6.0 Up-to-date`.

**Fix**: tag and publish Claudio 0.7.0. Then set `{:claudio, "~> 0.7.0"}` in mix.exs:229, run `mix deps.update claudio` (rewrites mix.lock:7), and rerun precommit, `hex.build` and `docs`.

### REL-2 — BLOCKER — `mix docs --warnings-as-errors` fails (fails the CI `quality` job)
**Evidence** (`MIX_ENV=dev mix docs --warnings-as-errors`, exit 1):
```
warning: documentation references module "Normandy.Hooks.ServerGlue" but it is hidden
  └─ lib/normandy/hooks/handlers.ex:6
warning: documentation references function "Claudio.MCP.Client.call_tool/4" but it is undefined or private
  └─ lib/normandy/telemetry.ex:438
  └─ lib/normandy/mcp/tool_wrapper.ex:33
Documents have been generated, but generation for html format failed due to warnings
```
`call_tool/4` is a `@callback` (`../Claudio/lib/claudio/mcp/client.ex:75`), not a function. `ServerGlue` is `@moduledoc false`.

**Fix**: write `` `c:Claudio.MCP.Client.call_tool/4` `` in telemetry.ex:438 and tool_wrapper.ex:33. In handlers.ex:6, name ServerGlue in plain text (no backticks), or document the module. Rerun after REL-1, because the Claudio doc refs resolve against the Claudio version actually in use.

### REL-3 — BLOCKER — the release ships as 1.4.0 unless the squash title carries `!`
**Evidence**: release.yml runs `cog bump --auto` on main and then publishes. Serial squash merges mean cog sees one commit. I simulated this on clones of the repo (`git merge --squash` of the branch onto main, then `cog bump --auto`):
- title `feat(llm): Claudio 0.7 and 2.0 changes` gives `Bumped version: v1.3.0 -> v1.4.0`, `@version "1.4.0"`
- title `feat(llm)!: Claudio 0.7 and 2.0 changes` gives `Bumped version: v1.3.0 -> v2.0.0`

README.md:36 already tells users `{:normandy, "~> 2.0"}`. A 1.4.0 release would silently ship 16+ breaking changes under a minor version, and the README snippet would fail to resolve. `pr-title.yml` only checks that the title is a conventional commit, not that it's breaking.

**Fix**: give the squash/PR title `!` (for example `feat!: Normandy 2.0`) or add a `BREAKING CHANGE:` footer. Before merging, confirm with `cog bump --auto --dry-run` on a local squash. mix.exs `@version "1.3.0"` must stay as is: cog rewrites it (cog.toml pre_bump_hooks).

### REL-4 — HIGH — MIGRATING-2.0.md misses breaking changes that commits made without a `!` marker
**Evidence**: every one of the 16 `!` commits maps to a MIGRATING section (§1–§12). But many fix/feat commits change public defaults, return shapes or raise behaviour, and MIGRATING never mentions them. Keyword counts in MIGRATING-2.0.md are 0 for `max_retries|unknown option`, `default_action|Ruleset`, `A2A`, `AgentPool|checkout`, `max_restarts`, `tool name|Registry`, `Validate.validate|whitespace|blank`, `compute`, `encoder|unsendable`. Commits (`git log main..HEAD`):

| Commit | Change users will hit |
|---|---|
| 3c33c08 | Output guardrail violation now **raises `ViolationError`** and isn't saved (was: log a warning). Opt out with `output_guardrails_on_violation: :warn` |
| 8747a71 | `Retry`/`retry_options` **raise on unknown options** (`max_retries:` was silently ignored), `preset/1` raises on a typo, and every failure is now `{:error, {e, attempts, errors}}` |
| 0d01d04 | `ClaudioAdapter` **raises on unknown `client.options` keys** at `init/1` |
| fd0d2b7 | DSL `new/1` raises on unknown options; `run/3` with `stream: true` and no `:on_chunk` raises |
| 308bc17 | `PolicyEngine.Ruleset` **requires `:rules` and `:default_action`** (missing used to mean allow) |
| dd84539 | A2A server lists **no tools by default** (`:expose_tools`); failures become `{:error, :agent_failed}`; file/data-only parts return `{:error, :no_text}`. The commit body itself says "(breaking)" |
| 930e62c | `ParallelOrchestrator.execute/2` returns `{:ok, r} | {:error, reason}` per agent in order (it used to drop failures); `SequentialOrchestrator` returns errors instead of raising |
| 791bbd7 | `Batch.Processor` ordered results are `{:ok, r} | {:error, e}` (were bare responses or `nil`); stats errors are `{input, error}` |
| 1070a3f | `AgentPool.checkout` returns `{:error, :timeout}` (it used to exit the caller) |
| 9b62724 | Normandy **no longer starts `:mnesia`**; Mnesia session/memory store users must add `:mnesia` to their `extra_applications` |
| 72b8490 | `Tools.Registry.register/3` raises on names with dots or longer than 64 characters (MCP and A2A names) |
| 6432e49 | `Validate.validate/2` requires only `required: true` fields (it used to require all fields) |
| 3e8202a | A required value of only whitespace is now blank |
| fa7411c / c7c5f27 | Messages the adapter can't send raise; content without a BaseIOSchema encoder raises `Protocol.UndefinedError` (used to become `""`) |
| d43d9a5 | Removed `Type.adapter_autogenerate/2`, `adapter_load/3`, `adapter_dump/3` and the `autogenerate/0` callback |
| 92c0683 / 08c5366 / 9ee9a10 | Compile- or init-time raises for misconfiguration (`compute:` on a non-virtual field, unknown guardrail `:field`, guard config errors) |
| 5279a84 | Turn supervisors default to 100 restarts in 5s (was OTP's 3/5) |
| 875d014 | History edits drop the thinking blocks they invalidate (memory notes it was "judged pre-release only", so no MIGRATING line) |

**Fix**: add a "Stricter validation (raises at init)" section and a "Changed return shapes" section, covering at least the guardrail default, retry options, client.options, Ruleset, A2A defaults, orchestrator/batch/pool shapes, Mnesia `extra_applications`, Registry names and `Validate.validate/2`. Other agents may cover parts of this; the list above comes from commit messages, not from diffing the APIs.

### REL-5 — HIGH — CHANGELOG `[Unreleased]` covers only telemetry, and cocogitto leaves it stranded above v2.0.0
**Evidence**
- CHANGELOG.md:8–63: the `[Unreleased]` Added/Changed/Fixed lists cover the telemetry work only. The Claudio 0.7 migration, temperature, LLMError, hooks, agent memory/`Tools.Memory`, MemoryStore backends, structured outputs fallback and the audit fixes are all missing.
- In the cog simulation, the generated 2.0.0 entry is one line (`![BREAKING] (llm) Claudio 0.7 and 2.0 changes`) plus 6 docs/ci commits already on main. It's inserted at the first `- - -`, **below** the hand-written block: CHANGELOG lines `8: ## [Unreleased]`, `65: ## [v2.0.0]...`. After release, the file would still open with an "Unreleased" section describing changes that were already released.

**Fix**: before merging, rewrite `[Unreleased]` as complete 2.0 notes (highlights plus a link to MIGRATING-2.0.md). After the bump, move it under the `v2.0.0` heading in a follow-up commit. Alternatively, rename the heading to something that stays true afterwards, such as "2.0.0 release notes (hand-written)".

### REL-6 — HIGH — the live `:integration` suite has 2.0 rot, and its job gates the release
**Evidence**
- `test/integration/agent_resilience_integration_test.exs:27-28` passes `retry_options: [max_retries: 3, initial_delay: 100]`, and `:47` passes `[max_retries: 0]`. `Retry.validate_options!/1` (lib/normandy/resilience/retry.ex:136–178) raises `ArgumentError` on unknown keys; the valid keys are `:max_attempts` and `:base_delay`. The e2e memory file also records "Excluded `:integration` suite has 2.0 rot".
- ci.yml `integration-tests` runs `mix test --only integration --only normandy_integration` on every push to main when `ANTHROPIC_API_KEY` is set. `all-checks-complete` fails on its failure, and release.yml runs only on CI `success`. So if the secret is set, the 2.0 merge produces no release. I did not run it, because it costs money.
- Lower risk: many integration tests pass `temperature:` (for example `end_to_end_scenarios_test.exs:15`). The helper defaults to `claude-haiku-4-5-20251001`, which accepts temperature, but a repo variable `NORMANDY_TEST_MODEL` set to Opus 4.7+ would make them return 400.

**Fix**: change the options to `max_attempts`/`base_delay`. Grep test/integration and test/normandy_integration for other 1.x options. Run the integration suite once locally with a key before merging.

### REL-7 — MEDIUM — `groups_for_modules` is stale; 104 of 158 doc modules are ungrouped
**Evidence**: I compared the generated `doc/*.html` against the module names in mix.exs. 104 documented modules fall into the default bucket, including every 2.0 headline module: `Agents.Turn.*` (Server, Session, State, Supervisor), `Behaviours.*` (Hooks, MemoryStore.*, SessionStore.*, SessionRegistry.*, Compactor.*, ModelCatalog.*, PolicyEngine.*), `Hooks.*`, `Tools.Memory`, `Tools.Context`, `Tools.ContextualTool`, `LLMError`, `HookHaltError`, `ModelCatalogError`, `Telemetry.*`, `LLM.OpenAICompatibleAdapter`, `LLM.Json.*`, `Agents.Dispatch*`, `Agents.ConverseResult`, `Agents.ConfigTemplate`, `Cluster`. mix.exs also names `Normandy.Agents.IOModel`, which doesn't exist (lib/normandy/agents/io_model.ex defines `BaseAgentInputSchema` and `BaseAgentOutputSchema`), so ex_doc ignores that entry silently. `groups_for_extras` is commented out, so the three guides aren't grouped.
Several modules look internal and probably belong under `@moduledoc false`, or at least an "Internals" group: `LLM.Json.Scanner`/`Decoder`/`ContentCleaner`/`SchemaBinder`, `Telemetry.OtelCtx`/`KilledRun`/`Request`/`WorkflowSpan`, `Hooks.Runner` (CLAUDE.md calls it "the only caller of hook modules").

**Fix**: add groups (Turn / Sessions & Stores / Hooks / Memory / Errors / Telemetry / LLM Adapters, plus the OpenAI adapter), remove `IOModel` and add the two schema modules, and enable `groups_for_extras: [Guides: ~r/docs\/guides\/.*/]`.

### REL-8 — MEDIUM — `mix test --trace` / `--slowest` fails deterministically
**Evidence**: `mix test --slowest 10` reported `2549 tests, 1 failure`. `mix test test/hooks/guide_examples_test.exs --trace` gives `3 tests, 1 failure`; the same file without `--trace` gives `3 tests, 0 failures`.
```
1) test the guide's "Testing a hook" example passes (Normandy.Hooks.GuideExamplesTest)
   test/hooks/guide_examples_test.exs:44
   ** (RuntimeError) cannot add module named MyAppTest.RedactHookTest to test suite after the suite starts running
   code: [{module, _binary}] = Code.compile_string(source)
```
The test compiles the guide's `use ExUnit.Case` module at runtime. Under `--trace` every module runs synchronously, and ExUnit rejects the registration. Precommit and CI don't use `--trace`, but anyone debugging with `--trace` (or measuring with `--slowest`) gets a red suite.

**Fix**: in the test, rewrite the extracted source to `use ExUnit.Case, register: false` before `Code.compile_string/1`. That option keeps the module out of the ExUnit server, and the test already calls the test functions itself.

### REL-9 — MEDIUM — e2e gate is incomplete before merge
**Evidence**: memory `agent-persistent-memory-2026-10.md` says "e2e scenario 14 (e2e/14_memory.exs) has NEVER run live; suite cap raised 120→140; README cost estimate $0.15–0.50 is unmeasured". `release-2-0-merge-gate.md` says to run `mix e2e` before the 2.0 merge. The last recorded full run (13/13) was 2026-10-02, before the hooks work (998e5f1..f7991a9) and the memory feature. Other open items listed there: `Turn.Session.run` blocks about 120 s when the Horde registry hasn't converged; a broad dialyzer `contract_supertype` ignore regex; no unsandboxed Postgres concurrency test; streaming_guardrails test handlers lack detach.

**Fix**: run `mix e2e` once on the final tree, after REL-1 (it costs money, so it's Q's call). Record the measured cost in the e2e README.

### REL-10 — LOW — package ships test-only migrations under `priv/`
**Evidence**: the `hex.build` file list includes `priv/test_repo/migrations/*.exs` (4 files, defining `Normandy.TestRepo.Migrations.*`). The only reference is config/test.exs:20 (`priv: "priv/test_repo"`). Hosts use `...Postgres.Migration.up/0` from lib (MIGRATING §15). Apart from that, `priv/` holds only the excluded, gitignored `priv/plts`, which is stale because the PLTs moved to `_build/plts`.

**Fix**: drop `priv` from `package[:files]` and remove `exclude_patterns`, or move the test migrations to `test/support/migrations` and point config/test.exs there.

### REL-11 — LOW — package and docs metadata gaps
- `package[:links]` has only GitHub. Add `"Changelog" => "https://hexdocs.pm/normandy/changelog.html"` and a migration-guide link.
- `package[:files]` omits MIGRATING-2.0.md, although the README links it. Hexdocs has it as an extra; the tarball doesn't.
- README Documentation section (README.md:95–99) doesn't link the agent-memory or hooks guides. It also doesn't state the minimum Elixir/OTP (mix.exs says `~> 1.15`; CI's oldest leg is 1.15/OTP 26).
- `mix.exs` docs contain TODO comments (logo, guides).
- ROADMAP.md (an extra, last edited 2026-04-18) has no 2.0, hooks, memory or distributed-session entries.
- **Fix**: edit as listed. None of this blocks the release.

### REL-12 — LOW — dependency observations
- `elixir_uuid ~> 1.2` (1.2.1, unmaintained) emits `warning: use Bitwise is deprecated` in every consumer build (observed in the throwaway consumer). Consider `uniq` or a 10-line UUIDv4 on `:crypto.strong_rand_bytes/1`.
- `req ~> 0.5` in mix.exs, but Claudio 0.7 requires `~> 0.6 and >= 0.6.1` (locked 0.7.4). Normandy's own constraint understates the real floor; tighten it to `~> 0.6 and >= 0.6.1` if lib uses ≥0.6 APIs (I didn't check).
- Both `poison` and `jason` are runtime deps. Poison is the default `:adapter` (`Application.get_env(:normandy, :adapter, Poison)`) and Jason comes via Req/Claudio anyway. Fine for 2.0; dropping Poison would be a future breaking change.
- Optional deps are correctly optional: the consumer `mix deps.tree` shows only claudio, elixir_uuid, jason, poison, req (finch, mint, ...), telemetry. ecto_sql, postgrex, horde and redix are marked `(optional)` in hex.build output, and lib compiles with `--no-optional-deps`. Mnesia isn't started for consumers (9b62724). OpenTelemetry is a soft runtime dep reached via `apply/3` (lib/normandy/telemetry/otel_ctx.ex), so it doesn't need a declared dep.
- `hex.outdated`: `redix 1.5.3 -> 1.9.2`, `ecto_sql 3.13.5 -> 3.14.0`, `dialyxir`, `ex_doc` and `stream_data` patch/minor updates are available; cowboy and cowlib are pinned (documented OTP 26 reason). None of these block the release.
- The minimum Elixir version is consistent: Claudio, req, finch and postgrex all declare `~> 1.15`.

### REL-13 — LOW — repo hygiene (not shipped)
- `test_json_schema_export.exs` is tracked at the repo root, a stray script.
- Tests create `Mnesia.nonode@nohost/` at the repo root, and it isn't gitignored. It's empty today, so git doesn't track it. Set `:mnesia, dir:` to a tmp path in config/test.exs, or add the directory to .gitignore.
- The root also holds untracked artefacts: `normandy-{0.2.0,0.3.0,1.0.0}.tar`, `erl_crash.dump` (6.7 MB), `cover/`, `doc/`. They're all gitignored and harmless.
- Test log noise: precommit output includes 44 `Application mnesia exited: :stopped` notices and circuit-breaker warnings outside `capture_log`.

### REL-14 — INFO — CI configuration review (no defect found)
- The test matrix covers the stated minimum (Elixir 1.15 / OTP 26) up to 1.19 / OTP 28. Format, credo (`--strict`), dialyzer (`--format github`), `deps.unlock --check-unused`, `hex.audit`, `--no-optional-deps` compile and `docs --warnings-as-errors` all run in `quality`. Unlocked deps, Postgres, Redis and distributed tests each have their own job.
- e2e is not run in CI (it's a `mix run e2e/run.exs` alias). test/e2e/runner_test.exs tests only the runner, offline.
- Excluded by default (test_helper.exs): `:integration, :normandy_integration, :postgres, :distributed, :redis` (203 tests excluded). The only `skip:` tags are conditional on a missing API key (4 files). I found no unconditional `@tag :skip`.
- Slowest tests: the top 10 take 9.1 s, the slowest being `eager_resume_test.exs:13` at 2001 ms. No outliers.
- The integration job uses the 1.15/OTP 26 env, so ex_mcp-dependent e2e scenario 12 is unavailable there by design (mix.exs `e2e_deps/0`).

---

## Release checklist (in dependency order)

1. **Claudio**: tag v0.7.0 in `../Claudio` and `mix hex.publish` it. (REL-1)
2. **Normandy deps**: set `{:claudio, "~> 0.7.0"}` and run `mix deps.update claudio`, which rewrites mix.lock:7. Optionally tighten `req` and replace elixir_uuid. (REL-1, REL-12)
3. **Docs refs**: use `c:Claudio.MCP.Client.call_tool/4` in two places and stop linking ServerGlue. Fix `groups_for_modules` (drop IOModel, add Turn/Hooks/Memory/Stores/Errors/Telemetry groups) and enable `groups_for_extras`. Run `MIX_ENV=dev mix docs --warnings-as-errors` and require exit 0. (REL-2, REL-7)
4. **Package files**: drop `priv` (or move the test migrations), add MIGRATING-2.0.md and Changelog links. Run `mix hex.build --unpack` and inspect the file list. (REL-10, REL-11)
5. **Integration rot**: fix `retry_options` keys in agent_resilience_integration_test.exs and grep for other 1.x options. Run `mix test --only integration --only normandy_integration` once with a key (costs money). (REL-6)
6. **Trace-mode test**: use `register: false` in guide_examples_test.exs, then run `mix test --trace` and require 0 failures. (REL-8)
7. **MIGRATING-2.0.md**: add the undocumented breaking changes from REL-4.
8. **CHANGELOG**: turn `[Unreleased]` into full 2.0 notes and plan the post-bump move under `v2.0.0`. (REL-5)
9. **README/ROADMAP**: link the guides, state the Elixir/OTP minimum, refresh the ROADMAP. (REL-11)
10. **Gate**: run `mix precommit` and require `0 failures`. Also run `mix compile --no-optional-deps --warnings-as-errors` (dev), `mix hex.audit` and `mix hex.build`.
11. **Live gate**: run `mix e2e` once on the final tree, including scenario 14, and record the cost. (REL-9, Q's call)
12. **Merge**: open the PR with a breaking title (`feat!: Normandy 2.0` or similar). Check it with a local squash plus `cog bump --auto --dry-run`, and expect `2.0.0`. Make sure all CI jobs are green, including integration if the secret is set. (REL-3)
13. **After release**: confirm Hex shows 2.0.0 and hexdocs renders the groups and guides. Move the hand-written CHANGELOG block under the `v2.0.0` heading. (REL-5)
