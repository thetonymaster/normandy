# Benchee benchmarks — design

Date: 2026-10-23. Source: `investigations/backlog-2.x.md` ("Add Benchee", parked by Q on 2026-10-23).

## Why

The pre-2.0 principles audit raised measure-first findings that nobody can settle with numbers. The repo has no
`bench/` folder and no Benchee dependency. Every timing in the audits was a single `mix run` with no repeats, and
the audit reports say so (`investigations/pre-2.0-audit/principles-audit/llm.md:78`, `.../agents.md:101`,
`.../coordination.md:68`). Wave 8 item E,
which would have deleted the `@compile {:inline, ...}` in `Normandy.Type`, was rejected without a number either
way.

The goal: when someone makes a performance claim about Normandy, they can run one command and get a repeatable
number, and compare two versions of the code on their own machine.

## Goals

1. `{:benchee, "~> 1.5", only: :dev}` in `mix.exs`, plus a `bench/` folder with one `.exs` script per target.
2. `mix bench` runs every script in `bench/`. `mix bench bench/<name>.exs [...]` runs only the scripts named.
3. Base-vs-head comparison on one machine. A script can save its run to a local, gitignored file, and a later run
   (on another branch) loads that file so Benchee prints the comparison.
4. Four first scripts, one per parked target (see Targets).
5. Each script prints what it measures, its input sizes, and the scaling the code should show (linear,
   quadratic, constant), so a reader can tell from the output alone whether the result is healthy.

## Non-goals

- No CI job and no CI gate (Q).
- No committed baselines or result files. Everything a run writes stays local (Q).
- No fixes. Whatever the numbers show (keeping or deleting the inline directive, for example) is a separate decision
  for Q afterwards.
- No benchmarks of the live HTTP path or distributed code. (Postgres, Redis and Mnesia stores were added by
  Q mid-build; see "Amendment: store backends".)
- No benchmark helper library or DSL. Scripts call `Benchee.run/2` directly.

## Anti-goals

- Numbers that look precise but aren't: a single iteration, no warmup, or input sizes the reader can't see.
- A bench run that writes anything tracked by git.
- Benchmarks that reach into private functions through `:erlang` tricks or by copying code into the script. Each
  target is measured through public (or `@doc false` but callable) API, so the bench measures what ships.

## Constraints

- Scripts run in `MIX_ENV=dev`. `test/support` is not compiled there. Use only what `lib/` ships:
  `Normandy.Test.FakeClient` lives in `lib/normandy/test/` and is usable in dev.
- `mix precommit`, `mix compile --no-optional-deps` (CI) and `deps.unlock --check-unused` must stay green.
  `benchee` being `only: :dev` keeps it out of the Hex package and out of the test env.
- `bench/*.exs` files are not compiled by `mix compile`, so they are invisible to dialyzer and credo's default
  globs. Run them through `mix format` (add `bench/**/*.exs` to `.formatter.exs` inputs).
- Docs tests (`test/docs/`) must stay green. The bench adds no `lib/` module, so no docs group is needed.

## How it fits (decided)

- **Layout:** `bench/README.md` (how to run, how to compare) plus one script per target, `bench/<target>.exs`.
- **Alias:** `mix bench` is a function alias in `mix.exs`, with `preferred_envs: [bench: :dev]` in `cli/0`. With no
  args it runs every `bench/*.exs` in name order. With args it runs those paths. Each script is run in the same VM
  via `Mix.Task.run("run", [path])` or `Code.require_file/1`. The builder picks, but scripts must not leak state
  into each other (no `Application.put_env` left set).
- **Comparison:** an env var turns on save and load. The suggested names are `BENCH_SAVE=<tag>` and
  `BENCH_COMPARE=<tag>`. Saved files go to `bench/results/<script>-<tag>.benchee`, and `/bench/results/` is
  gitignored. Without either var the script just prints. A shared `bench/support.exs` (required by each script)
  may build the `save:`/`load:` options from these vars; it is the only shared code allowed.
- **Defaults per script:** `warmup: 1`, `time: 5`, `memory_time: 1`, unless a script states why it differs.
  `BENCH_QUICK=1` drops to `warmup: 0.2, time: 1` for a smoke run.

## Targets

| Script | Measures (public entry point) | Inputs | Expected shape | Settles |
|---|---|---|---|---|
| `type_dump.exs` | `Normandy.Type.dump/2` (the inlined `same_*` helpers are its scalar clauses; `cast/2` timed alongside as a reference) over the base types the inlined helpers serve (`:integer`, `:boolean`, `:map`, `:string`, `:binary`, `:date`, `:duration`), plus an `{:array, :integer}` of 1k items | scalars; array of 1k | constant per scalar; linear in the array | schema#10: whether the `@compile {:inline, ...}` at `lib/normandy/type.ex:594` is worth anything. Compared by saving on HEAD, deleting the directive on a scratch branch, and loading |
| `json_regions.exs` | `Normandy.LLM.JsonDeserializer.parse_and_validate/3` on prose-wrapped JSON | balanced JSON in prose: 1, 30, 120, 240 KB; adversarial unclosed openers (`String.duplicate("{\"a\": ", n)`) at the same sizes | linear for both (the region budget is `8 * size + 1024`) | llm#1: that the bounded extraction stays linear on the inputs that used to be quadratic (30 KB 451 ms … 240 KB 30 s before) |
| `request_messages.exs` | `Normandy.Components.AgentMemory.request_messages_for/2` | memories of 10, 100, 1k, 5k messages; one plain-text variant and one with tool rounds and thinking blocks | linear in message count | that building each request from a long history stays linear (it runs on every LLM call) |
| `output_guards.exs` | `BaseAgent.stream/3` with `Normandy.Test.FakeClient` scripted to stream text in 50-byte chunks, `guardrails: [output: [RegexGuard with 2 patterns], streaming_mode: :incremental]`; control: the same with `:accumulate` | streamed answers of 16, 64, 256 KB; `chunk_size` default (200) | incremental is quadratic (it rescans the accumulated text at every check); accumulate is linear | agents audit note: how much the rescans cost against the control. The audit measured 3 ms (64 KB) and 52 ms (256 KB) |

The builder picks the exact payloads, as long as each script prints them.

### Settled after the builder check (my calls, not Q's)

- **Scaling is printed, not checked.** A script prints the expected shape next to Benchee's table and a human
  reads it. No ratio computation, no thresholds, no non-zero exit on a bad shape.
- **Each script asserts its input reaches the path it claims to measure, once, before `Benchee.run/2`.** For example:
  `json_regions` checks that the adversarial input returns the extraction error, not an early rejection.
  `output_guards` counts output-guard checks (with a counting guard module defined in the script, or telemetry) and
  checks the count is about `size / chunk_size`, so the incremental path really rescans. A failed assertion raises
  and stops the run.
- **`output_guards.exs` is built first, as a spike.** Before writing it, confirm that `FakeClient` streaming
  `{:text, chunks}` reaches `consume_stream_with_incremental_guards/3` one delta at a time. If it doesn't, stop
  and report rather than measuring something else.
- **Schemas** used by `json_regions` and `output_guards` are trivial `io_schema`s defined in the script.
- **Scenario names are fixed strings** (for example `"dump :integer"`, `"240 KB adversarial"`) that never change
  between commits, because Benchee's `load:` matches on them.
- **A missing comparison file is an error.** If `BENCH_COMPARE=<tag>` names a tag with no saved file for a script,
  that script raises naming the missing path. It does not silently run without the comparison.
- **Checking off the backlog item** happens after merge, not in the build.

## Left to the builder

- Function alias vs. a `Mix.Tasks.Bench` module. Prefer the alias unless argument handling gets awkward. A `lib/`
  task module would need a docs group or `@moduledoc false`, and would ship in the package.
- How each script builds its inputs (memory entries, FakeClient scripts, guard specs) from public API.
- Benchee formatter: the console default is enough. Add no HTML formatter (it is another dependency).
- Whether `request_messages.exs` also times `AgentMemory.history/1` as a reference.

## Done when

- `mix bench` with `BENCH_QUICK=1` runs all four scripts to completion from a clean checkout after `mix deps.get`.
- `BENCH_SAVE=main mix bench bench/type_dump.exs` on one commit, then `BENCH_COMPARE=main mix bench
  bench/type_dump.exs` on another, prints Benchee's comparison table.
- `git status` is clean after any bench run.
- `mix precommit` exits 0. `bench/README.md` says how to run, compare and read the output. `CLAUDE.md` gets one
  line under Common Commands. `mix.lock` carries the new `benchee` (and its `deep_merge`/`statistex`) entries.

## Amendment: store backends (Q, 2026-10-23, approved mid-build)

Q asked to also measure Redis, Postgres and Mnesia. Scope as approved:

- **Scripts:** `bench/session_store.exs` and `bench/memory_store.exs`. Backends: Mnesia, Redis, Postgres, with
  InMemory and ETS as in-process baselines.
- **SessionStore operations:** `append_entry/3`, `history/2` at 10, 100 and 1k entries, and
  `save_turn_state/4` + `load_turn_state/2`.
- **MemoryStore operations:** `put/6` with limits, `get/3`, and `list/3` over a namespace of 100 documents.
- **Services:** the local containers (Redis `redis://localhost:6379`, Postgres `localhost:55432`), overridable
  with `REDIS_URL` and `POSTGRES_URL`. A backend that cannot be reached fails the run, naming it.
  `BENCH_STORES=<comma list>` (backend names `in_memory,ets,mnesia,redis,postgres`) selects a subset. No backend
  is ever skipped silently, because a missing one would skew a comparison.
- **Isolation:**
  - Postgres: a script-local Repo on its own `normandy_bench` database, created if missing and migrated on start.
  - Redis: a random `normandy_bench:<id>` namespace.
  - Mnesia: a temp dir.
  - Everything is deleted at the end of the run, and `git status` stays clean.
- The same rules as the other scripts apply: a banner, one path assertion per backend before measuring, and fixed
  scenario names (`"<backend> <operation>"`).
