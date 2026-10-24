# Benchmarks

Benchee scripts that put numbers on Normandy's performance claims. They run by hand in
`MIX_ENV=dev`. There is no CI job, and nothing a run writes is committed.

## Run

```bash
mix bench                              # every bench/*.exs script
mix bench bench/json_regions.exs       # one script (or several paths)
BENCH_QUICK=1 mix bench                # smoke run: 0.2 s warmup, 1 s per scenario
```

A full run takes 1 s of warmup plus 5 s per scenario and input, plus 1 s of memory
measurement.

| Script | Measures |
|---|---|
| `type_dump.exs` | `Normandy.Type.dump/2` scalars (x1000 per call) and a 1k array; the `@compile {:inline}` question |
| `json_regions.exs` | `JsonDeserializer.parse_and_validate/3` region extraction, balanced, one stray opener and adversarial, 1–240 KB |
| `output_guards.exs` | `BaseAgent.stream/3` with output guards, `:incremental` vs `:accumulate` vs none, 16–256 KB |
| `request_messages.exs` | `AgentMemory.request_messages_for/2` on 10 to 5k messages |
| `session_store.exs` | SessionStore `history` (10/100/1k entries), then `append_entry` and `save_turn_state` + `load_turn_state`, per backend. Two runs, saved as `session_store_history` and `session_store_writes` |
| `memory_store.exs` | MemoryStore `put` (one document, overwritten), `get`, `list` over 100 documents per backend |

### Store backends

The two store scripts run InMemory, ETS, Mnesia, Redis and Postgres. Redis and
Postgres must be running: `REDIS_URL` (default `redis://localhost:6379`) and
`POSTGRES_URL` (default `ecto://postgres:postgres@localhost:55432/normandy_bench`).
An unreachable backend fails the run and names it. `BENCH_STORES=in_memory,mnesia`
runs only the listed backends. Postgres uses its own `normandy_bench` database, created
and migrated on first use. Redis keys go under a random `normandy_bench*` prefix.
Mnesia tables are `ram_copies` in the Mnesia that dev already runs, and a disc schema
is refused. Every session and namespace a run creates is deleted afterwards, even when
a scenario raises.

## Compare two commits

`BENCH_SAVE=<tag>` saves a run to `bench/results/<script>-<tag>.benchee`, which is
gitignored. `BENCH_COMPARE=<tag>` runs again and prints each scenario next to its
`(<tag>)` twin, with a Comparison section.

```bash
git switch main && BENCH_SAVE=main mix bench bench/type_dump.exs
git switch - && BENCH_COMPARE=main mix bench bench/type_dump.exs
```

Tags may use letters, digits, `.`, `_` and `-`. Comparing against a tag that has no
saved file for that script is an error, as is saving and comparing under the same tag.
Compare on one machine with the same load: the numbers are only comparable with each
other.

### The `@compile {:inline}` experiment (principles audit schema#10)

1. `BENCH_SAVE=inline mix bench bench/type_dump.exs` on HEAD.
2. On a scratch branch, delete the `@compile {:inline, ...}` block in `lib/normandy/type.ex`.
3. `BENCH_COMPARE=inline mix bench bench/type_dump.exs` there, then throw the branch away.

## Read the output

Each script first prints a banner: what it measures, its inputs, and the shape to expect
(constant, linear or quadratic in the input). Check the shape across inputs before you
look at absolute numbers. For example, 4x the input should cost about 4x the time where
the banner says linear. Before measuring, each script asserts once that its input reaches
the path it claims to measure, and it stops if it doesn't.

Benchee's memory column counts only the calling process. Work done in another process
(the InMemory Agent, the ETS and Mnesia owners, Redix, Postgrex) is not in it, so the
store scripts' memory figures compare unlike things across backends.

## Adding a script

- Put it in `bench/<name>.exs` and start it with `Code.require_file("support.exs", __DIR__)`.
- Call `Benchee.run(jobs, Bench.Support.run_opts("<name>", extra))`.
- Use only what `lib/` ships. `test/support` is not compiled in dev.
- Give it a banner (`Bench.Support.banner/3`) and one path assertion (`Bench.Support.assert!/2`).
- Keep scenario and input names fixed: `BENCH_COMPARE` matches on them.
- A scenario that runs in a few ns gets Benchee's fast-execution warning. Repeat the
  call inside the job and say so in the name (for example `x1000`).
