## Principles audit: schema system + DSLs (lib/normandy/schema/*.ex, lib/normandy/dsl/*.ex, schema.ex, type.ex, validate.ex, parameterized_type.ex; whole modules, branch feat/claudio-0.7-migration @ 7561497)

Verdict: ship with follow-ups — no defect blocks release, but findings 1 and 2 trim public API (Ecto/DB residue in the type contract and the changeset struct). They land before 2.0 or wait for 3.0. Everything else is internal.

### Findings (ranked)

1. [composition · over] lib/normandy/type.ex:259, :334-377, :412-431, :534-572, :682-695 and lib/normandy/parameterized_type.ex:170 — the custom-type contract still carries Ecto's database, embed and query machinery. Normandy has no database, embeds or queries, and nothing in lib/ calls this code.
   Evidence:
   - Callers in lib/ outside type.ex (grep `Type.<fn>(`): `match?` 0, `primitive?` 0, `parameterized?` 0, `load` 0, `cast!` 0, `embedded_load` 0, `embedded_dump` 0. `embed_as` has no caller outside type.ex and parameterized_type.ex; only `embedded_dump/3` and `embedded_load/3` reach it, and those have no caller.
   - Even so, `c:embed_as/1` (type.ex:259) and `c:embed_as/2` (parameterized_type.ex:170) are part of the behaviour, and `use` injects defaults for them.
   - `cast_fun/1` has clauses for `:id`, `:binary_id`, `:time_usec`, `:naive_datetime(_usec)`, `:utc_datetime(_usec)`, `{:supertype, :datetime}` and the `@variadic ~w(in splice)` qualifiers (type.ex:195, 682-695). `do_match?` matches `:decimal`, `:binary_id` and `:id` (type.ex:423-430).
   - A probe compiling `field :x, T` (scratchpad probe.exs) raised `unknown type ... for field :x` for each of `:utc_datetime :naive_datetime :id :binary_id :time_usec :decimal`. Fields can never use these types, yet `Type.cast(:utc_datetime, ...)` still returns `{:ok, ~U[...]}`.
   - The contract is also inconsistent: `Type.load/3` calls `module.load(value, loader, params)` for a parameterized type (type.ex:537), and the moduledoc example defines `load/3` (parameterized_type.ex:47), but `Normandy.ParameterizedType` declares no `load` callback (callbacks are at :110-170).
   Fix: drop `embed_as` (both behaviours and both `__using__` defaults), `embedded_dump/3`, `embedded_load/3`, `match?/2` and `do_match?`. Drop the cast clauses for types `field/3` rejects, and `:in`/`:splice`. Then either remove `Type.load/2,3` (no lib caller) or add a `load/3` callback to ParameterizedType.
   Public API: YES. This changes behaviour callbacks and public `Normandy.Type` functions. It needs a MIGRATING-2.0.md entry and will show up in `tools/api_diff/run.sh main`.

2. [composition · over] lib/normandy/validate.ex:39-41, :53-55, :71, :251 — `%Normandy.Validate{}` keeps Ecto changeset fields and types for features Normandy does not have.
   Evidence:
   - `constraints:`, `filters:` and `prepare:` are set only by `defstruct` defaults. Grepping lib/, test/ and docs/ for `.constraints`, `.filters`, `.prepare` or `constraints:|filters:|prepare:` on a Validate finds no read or write; the hits are unrelated (toolset metadata, logger).
   - `@type types` admits `{:assoc, term()} | {:embed, term()}`, and nothing produces either.
   - `cast_type!/2` says a missing field "is a :through association (which are read-only)". Normandy has no associations.
   - `changes:` defaults to `[]` (line 44) but is used as a map everywhere (e.g. `Map.put(changes, ...)` at :219), and `@type t` (lines 46-58) leaves `changes` out.
   Fix: delete the three fields and the `:assoc`/`:embed` alternatives, rewrite the unknown-field message, default `changes: %{}` and add it to `@type t`.
   Public API: YES for the struct shape: anyone pattern-matching or building `%Validate{}` with those keys breaks. The message and type change are not API.

3. [false-claim] lib/normandy/schema.ex:844-849 — the error for `field :x, :datetime` tells users to pick `:naive_datetime` or `:utc_datetime`, and both of those are also rejected.
   Evidence: probe output: `{:datetime, "invalid type :datetime ... You probably meant to choose one between :naive_datetime ... or :utc_datetime"}`, then `{:utc_datetime, "unknown type :utc_datetime for field :x"}` and `{:naive_datetime, "unknown type :naive_datetime for field :x"}`. `@base` (type.ex:190-193) has neither.
   Fix: say there is no datetime field type and name what works: a `:string` field with `format: "date-time"`, or a custom `Normandy.Type`.
   Public API: no (message text only).

4. [false-claim] lib/normandy/type.ex:163-245, :437, :584-588; lib/normandy/parameterized_type.ex:20-22, :125, :177; CLAUDE.md "Normandy.Type" bullet — the docs describe Ecto and database behaviour Normandy does not have, and CLAUDE.md overstates the callback contract.
   Evidence:
   - `grep -c Ecto`: type.ex has 10 hits, parameterized_type.ex 1. Examples: "When casting values by `Ecto.Changeset`" / "When passing arguments to `Ecto.Query`" (type.ex:216-217), "Dumps the given term into an Ecto native type" (:234, parameterized_type.ex:125), "`cast/2` is used by the finder queries" (:584), "data stores allow nil to be set on any column" (:587), "customize `cast` behavior per query" (parameterized_type.ex:21).
   - `ParameterizedType.init/2` claims to be "Useful ... for schemaless changesets" (:177), but `Validate.cast(%{}, %{"a" => 1}, [:a])` raises `FunctionClauseError` (probe), because cast/4 only takes structs (validate.ex:142).
   - CLAUDE.md says custom types "require `type/0`, `cast/1`, `dump/1`, `load/1`", but `load: 1` is in `@optional_callbacks` (type.ex:270) and lib/ never calls it.
   Fix: rewrite those docs for Normandy (schema field <-> model JSON), drop the schemaless and query claims, and correct the CLAUDE.md bullet. Most of this disappears with finding 1.
   Public API: no (docs only).

5. [composition · under] lib/normandy/dsl/workflow.ex:230-310, :463-616 — the `step`, `parallel` and `race` macros are three copies of the same 20-line quote, and about 125 lines of workflow runtime are generated into every workflow module.
   Evidence:
   - Lines 230-252, 259-281 and 288-310 are identical except `current_step_type = :sequential | :parallel | :race`.
   - The generated `execute_step/3` repeats `Map.put(state.results, step.name, result)` plus `%{state | ..., current_input: ...}` three times (:516-517, :529-530, :540-541). That logic already exists as `put_step_result/3` in the DSL module (:200-201).
   - `execute_workflow`, `get_agent(s)`, `run_agent`, `name_results` and `prepare_input` depend on nothing per-module except `__workflow_transform__`/`__workflow_condition__`, yet they need the `LongQuoteBlocks` and `CyclomaticComplexity` disables (:395, :462).
   - Contrast `Normandy.DSL.Agent`, which moves its helpers out of the generated module on purpose (agent.ex:702-705: "Lives here, not in the user's module").
   Fix:
   - Make one private `step_quote(name, type, block)` that all three macros call.
   - Move the runtime into `Normandy.DSL.Workflow.__run__(steps, agents_map, input, transform_fun, after_step_fun)`, reusing `put_step_result/3`.
   - Keep `execute/1`, `steps/0` and the generated transform/condition clauses in the user module.
   Public API: no. `execute/1` and `steps/0` stay; only private generated functions move.

6. [flat-code · under] lib/normandy/schema/validator.ex:821-950 — the composition and conditional checks nest to depth 4-5. That nesting is why five credo disables exist (Nesting at :830, :861, :903, :940; CyclomaticComplexity at :916), and the module already has the call that flattens it.
   Evidence: `nesting_depth.py --max 3` reports `validate_any_of: depth 4`, `validate_one_of: depth 4`, `validate_all_of: depth 4` and `validate_conditionals: depth 5`. Each nested `case validate_against_spec(...) do {:ok,_} -> ...; {:error, e} -> e ++ acc end` is equivalent to the existing accumulator form `validate_schema(acc, data, schema, path)` (see :148, :288).
   Fix:
   - allOf: `Enum.reduce(schemas, errors, &validate_schema(&2, data, &1, path))`.
   - anyOf and oneOf: a `matches?(data, schema, path)` (`validate_schema([], data, schema, path) == []`).
   - Conditionals: pick `branch = if matches?(data, if_schema, path), do: spec[:then], else: spec[:else]`, then call a nil-tolerant `validate_branch(errors, data, branch, path)`.
   - All five disables go. Project rule (CLAUDE.md) permits inline disables; this finding is that the depth is avoidable, not that the rule was broken.
   Public API: no.

7. [flat-code · under] lib/normandy/validate.ex:153-287 — the cast helpers thread a flag through without using it, and run at 9-arity behind two `FunctionArity` disables (:196, :262).
   Evidence:
   - `cast_field/9` takes `valid?` only to return it unchanged (`{:ok, value, valid?}`, :274), and `process_param` rebinds it from that tuple (:218).
   - `empty_values`, `defaults`, `force?` and `msg_func` are built once in `cast/6` (:155-170) and passed down both calls unchanged.
   - `defaults = case data do %{__struct__: struct} -> struct.__struct__() # %{} -> %{} end` (:165-170) is a single-clause case with a commented-out branch; cast/4 only accepts structs (:142).
   - `convert_params/1` (:329-349) reaches depth 4 with a Nesting disable at :333.
   Fix:
   - Drop `valid?` from `cast_field`.
   - Pack the four per-call values into one map built in `cast/6`. Both functions then take at most 5 arguments, and both disables go.
   - Replace the case with `defaults = struct(data.__struct__)`.
   - Extract `string_key!(key, params)` from the comprehension.
   Public API: no (private functions).

8. [flat-code · over-branching] lib/normandy/schema.ex:752-786, :699-730, :733-806, :358-447 — four-way branching and copied helpers stand in for what is one optional-put each.
   Evidence:
   - `add_conditional_constraints/2` has a 5-arm `cond` that enumerates the then/else combinations. It is equivalent to `Map.put(:if, ...)` followed by two conditional puts.
   - `add_any_of`, `add_one_of` and `add_all_of` are the same 9 lines with a different key.
   - `build_composition_schema/1` and `build_conditional_schema/1` differ only in the word in their error message.
   - `schema/1` and `io_schema/2` repeat the same prelude and postlude (struct, `__specification__`, `__schema__` clauses); io_schema only adds `@description` and the `defimpl`.
   - `add_constraints(spec, _type, opts)` (:648) ignores `type`.
   Fix:
   - Conditionals: `spec |> Map.put(:if, build_sub_schema(if_s, "conditional")) |> maybe_put(:then, then_s && build_sub_schema(then_s, ...)) |> ...`.
   - Composition: one `put_schemas(spec, key, opts_key)`.
   - Have `io_schema` reuse a shared `schema_quote/2`.
   Public API: no.

9. [false-claim] lib/normandy/schema/validator.ex:45, :72-79, :496 — the moduledoc lists six supported formats, but `validate_format/4` handles ten, and one comment is attached to the wrong function.
   Evidence: `validate_format/4` (:421-436) also handles `"date"`, `"time"`, `"duration"` and `"hostname"`; the moduledoc lists only email, uri, uuid, date-time, ipv4 and ipv6. The comment "ISO 8601 date-time format validation (simplified)" (:496) sits above `duration_regex/0`, not above `validate_datetime_format/3` (:514).
   Fix: list all ten formats and move the comment.
   Public API: no.

10. [measure-first · over] lib/normandy/type.ex:841-850 — `@compile {:inline, ...}` on nine helpers, with no measurement behind it.
    Evidence: `ls bench` returns "No such file or directory". `grep -rl Benchee bench test lib` finds nothing, and mix.exs has no benchee. `git log -S"@compile {:inline" -- lib/normandy/type.ex` shows a single commit, `16ad35a Stuff`. Three of the inlined functions (`primitive?/1`, `composite?/1`, `base?/1`) are public, and `primitive?/1` has no lib caller.
    Fix: delete the directive, or keep it with a Benchee number that justifies it.
    Public API: no.

### Survived scrutiny
- `Normandy.Type` and `Normandy.ParameterizedType` as behaviours. They are the user extension point for field types. Implementations exist in test/type_test.exs, test/parameterized_type_test.exs and test/schema/json_schema_types_test.exs, and `check_field_type!` (schema.ex:873-891) dispatches on them. They are kept; only their Ecto residue is flagged (finding 1).
- Two validation engines, `Normandy.Validate` (changeset cast) and `Normandy.Schema.Validator` (JSON Schema keywords). They have separate callers and jobs: Validate serves `Type.cast_schema` (type.ex:747-758) and `llm/json/schema_binder.ex:26`; Validator serves `tools/input.ex:81` and `agents/validation_middleware.ex:117,224`. This is not duplicate abstraction.
- `Validator.validate_schema/4` (validator.ex:148-162): a flat pipe of 12 single-job keyword checks, each a no-op when its keyword is absent. Depth stays at 1-3 except the composition/conditional functions (finding 6).
- `Normandy.Schema.Wire`: 4 lib callers (toolset.ex:285, retry_feedback.ex:18/85, schema_translator.ex:80, base_agent.ex:1542). Its hardwired `Jason.OrderedObject` while `:adapter` is configurable is stated in its moduledoc (:27-28), and Jason is a hard dependency, so it is a documented constraint rather than a hidden one. The recursion keys in the moduledoc match `@schema_keys`/`@schema_list_keys`.
- `Normandy.DSL.Agent`: the generated code is thin. Option checking, memory-tool building, hook merging and the prompt spec live in the DSL module (`init_config!/4`, `memory_tool!/3`, `put_declared_hooks/2`, `__prompt_specification__/1`). The `LongQuoteBlocks` disable covers a config map and delegators. The `max_tool_concurrency` doc claim (`ordered: true`) is verified at base_agent.ex:843.
- `Normandy.Schema.Introspection`: thin wrappers, but they are public and used by `Tools.Toolset` (toolset.ex:389-396). Per-field calls re-read the spec (O(fields²)), but over a schema's field count, which is small and fixed at compile time.
- `Regex.compile!` on every validation (validator.ex:294, :402): linear in keys × patterns, not quadratic on unbounded input, and nothing has measured it. Under measure-first it is not flagged.
- `cast_integer` `byte_size < 32` guard (type.ex:768): it bounds work on model-supplied input. Kept, though its comment's "database key" rationale is Ecto's.
- Global state: in scope there is no `Application.*env`, `:persistent_term`, named ETS table, `Process.put/get` or `name: __MODULE__` registration (the single `__MODULE__` hit, workflow.ex:473, is telemetry metadata).
- DI: nothing in scope does IO or holds a client. No finding.

### Not checked
- `mix dialyzer` and `mix xref graph --label compile-connected` were not run (time; dialyzer PLT build). The compile-time coupling from `use Normandy.Schema` / `use Normandy.DSL.*` is unmeasured.
- The tests were not run (read-only audit, no code changed). The probe used `mix run --no-start` on a scratch script outside the repo; `git status` stayed clean.
- validate.ex :410-680 and :980-1130, and type.ex :860-1371, were covered only by credo (0 issues) and `nesting_depth.py` (no hits), not read line by line.
- docs/guides and README were not audited beyond the greps cited. `tools/api_diff/run.sh main` was not run, so the API impact of findings 1-2 against MIGRATING-2.0.md is untested.
- Mechanical-pass tools, all run under `bash -c` with split `$FILES`: `mix credo --strict` (10 files, 0 issues; it passes only because of the 20 inline disables, which are listed by grep and judged in findings 6-8), `nesting_depth.py --max 3` (7 leads, all judged), and the composition/DI greps.
