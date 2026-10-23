## Principles audit: lib/normandy/tools/**, lib/normandy/hooks/**, lib/normandy/guardrails/**, lib/normandy/guardrails.ex, lib/normandy/tool.ex (24 files, 3,798 lines, branch feat/claudio-0.7-migration @ 7561497)

Verdict: ship with follow-ups. No finding is a correctness or design defect that blocks 2.0. The one item to settle before 2.0 is #4, because removing public functions after the release is a breaking change. The rest are internal cleanups.

### Findings (ranked)

1. [Composition · over] lib/normandy/hooks/server_glue.ex:53-72. `before_llm/4` and `after_compact/5` build a stub handler set and wrap it only so they can reach two private functions in `Hooks.Handlers`.
   Evidence: `%{handlers | call_llm: fn _config, _state, _request -> :ok end} |> HookHandlers.wrap(config) |> then(& &1.call_llm.(config, state, request))` (lines 55-57). The `compact` path does the same at lines 69-71. The `handlers` argument supplies only a struct to overwrite: the server's real `call_llm` and `compact` run apart from it (server.ex:1729-1731, 1740-1743). Two of the four `Handlers.wrap/2` call sites are these stub calls; the other two are in base_agent.ex:679 and 1245. `Handlers`' moduledoc (handlers.ex:11-13) says `wrap/2` is not idempotent ("never wrap a set that is already wrapped"). The stub pattern is one reason that rule exists.
   Fix: make `Handlers.before_llm!/3` and `Handlers.after_compact/2` `@doc false` public. Have ServerGlue call them directly and drop its `handlers` parameter. Edits: handlers.ex, server_glue.ex, and the two server.ex call sites.
   Public API: no. All three modules are `@moduledoc false`.

2. [Composition · under → Flat code] lib/normandy/guardrails/builtins/forbidden_substrings.ex:23-73, max_length.ex:22-58, regex_guard.ex:57-122. Three string guards repeat the same skeleton: extract the field, return `:ok` on nil, check the string, raise on any other value. That repetition causes the nesting and three of the six credo disables in scope.
   Evidence: there are 3 copies of `defp field_suffix/1`. `path = if field, do: [field], else: []` appears 5 times (forbidden_substrings.ex:52, max_length.ex:38, regex_guard.ex:58, 81, 102). nesting_depth.py: `forbidden_substrings.ex:56: check: depth 4`. The repeated skeleton is the cause of credo disables at forbidden_substrings.ex:22 (CyclomaticComplexity), forbidden_substrings.ex:54 (Nesting) and max_length.ex:37 (Nesting).
   Fix: put `string!(guard, value, field) :: nil | String.t()` (it raises with the field suffix) and `path(field)` in the existing internal `Builtins.Field`. Each guard's `check/2` then becomes option checks plus one `case` on `nil | string`, and the three disables go.
   Public API: no. `Field` is `@moduledoc false`; violation shapes and messages stay the same.

3. [False claim] lib/normandy/tools/memory.ex:89-135. `Memory.new/1` validates its options by hand, although CLAUDE.md says every public entry point goes through `Normandy.Options.validate!/3`. CLAUDE.md:67 reads: "`validate!(opts, schema, {mod, fun, arity})` for every public entry point". CLAUDE.md:248 reads: "option schemas for every public entry point".
   Evidence: `grep -rn "Options.validate!"` over the scope finds only toolset.ex:82 and executor.ex:71,85. `new/1` does not follow the house conventions. It reports only the first unknown key (`[key | _] ->`, line 94), while Options names all of them. It says "allowed:" where Options says "supported:". It does not accept a map. Its errors `inspect` values (lines 290 and 346) without going through `sensitive_keys/0`. Line 290 echoes a malformed `:store` whole, and a store handle can carry connection options.
   Fix: give `new/1` a NimbleOptions schema validated through `Normandy.Options.validate!/3`, and keep the cross-field checks (mounts, store behaviour) after it. Or narrow the claim in CLAUDE.md.
   Public API: the signature is unchanged. Error message text changes, and a map argument becomes accepted.

4. [Composition · over + false claim] lib/normandy/tools/toolset.ex:307-363 and 367-400. `fetch_metadata/2`, `list_metadata/1` and `introspect_schema/2` are public functions that nothing in the library or its docs calls.
   Evidence: `grep -rnE "(fetch_metadata|list_metadata|introspect_schema)\(" lib docs README.md` outside toolset.ex returns nothing. The only callers are 16 calls in test/tools/toolset_metadata_test.exs. toolset.ex:341 claims the function returns "nil for legacy tools", but 2.0 removed legacy tools (`check_tool!/2` refuses them, line 122). `nil` now means a tool with a hand-written `input_schema/1` map, such as Memory or an MCP tool, as the comment at line 384 says.
   Fix: decide before 2.0. Either remove the three functions (with a MIGRATING-2.0.md entry and `tools/api_diff/run.sh main`), or keep them and correct the doc at line 341.
   Public API: yes if removed; no if only the doc changes.

5. [Composition · under] lib/normandy/tools/toolset.ex:18-24, 99-109, 186-194. Per-registration data is held in three parallel maps keyed by tool name (`tools`, `timeouts`, `max_result_chars`). Every new registration option must therefore be added in several places.
   Evidence: register (lines 99-109) and unregister (lines 188-193) each update all three maps. The `@type t` (lines 18-22) and the doctest output at line 183 (`%Normandy.Tools.Toolset{tools: %{}, timeouts: %{}, max_result_chars: %{}}`) list all three. A fourth option would touch the struct, type, register, unregister, the doctest and a new accessor.
   Fix: store one map of `name => %{tool:, timeout:, max_result_chars:}` and keep the accessors' signatures. Do this only if another per-registration option is planned; otherwise this is a note, not work.
   Public API: yes. The struct fields and `@type t` are visible, and the doctest prints them.

6. [Flat code · under] lib/normandy/guardrails.ex:217-246. `invoke/4` puts a `try` inside a `case` branch, then `rescue`, then an `if` inside a rescue clause.
   Evidence: nesting_depth.py: `guardrails.ex:230: invoke: depth 4 (limit 3, heuristic)`. Line 230: `if builtin?(mod), do: reraise(...), else: on_error_result(...)`.
   Fix: move the `try` into `defp guarded_check(policy, mod, value, opts, context)` with a function-level `rescue`/`catch`, so `invoke/4` becomes a three-way `case` on the policy.
   Public API: no.

7. [Flat code · under] lib/normandy/tools/memory/commands.ex:200-236. `edit/6` goes `case` (get), then `with` (transform, fits), then `case` (put with CAS retry). A credo disable at line 211 keeps it passing.
   Evidence: nesting_depth.py: `commands.ex:212: edit: depth 4`. The innermost `case` is the CAS write with its retry and error mapping, a concept with its own name.
   Fix: extract `cas_put(tool, loc, content, version, updated, info, ...)` (the CAS write, including the retry call), then remove the disable.
   Public API: no.

8. [Composition · under] lib/normandy/guardrails.ex:259. Whether a guard counts as a built-in is decided by the prefix of its module name.
   Evidence: `defp builtin?(mod), do: String.starts_with?(inspect(mod), "Normandy.Guardrails.Builtins.")`. Under `:open`/`:closed`, a built-in's `ArgumentError`/`KeyError` re-raises (lines 229-232), so this check decides policy. Any module under that namespace, including a host's, gets the built-in treatment. lib has 5 built-ins.
   Fix: use an explicit `@builtins [MaxLength, ForbiddenSubstrings, RegexGuard, RequiredFields, SemanticScope]` and `mod in @builtins`.
   Public API: no, unless a host relies on the prefix.

9. [False claim] lib/normandy/guardrails/violation_error.ex:3. The moduledoc says the error is "raised when an input guardrail rejects an agent's input", but output guards return it too.
   Evidence: the same file's `@normandy_messages` (line 29) includes "Agent output guardrail violation". guardrails.ex:89-90 says output `:block` returns `{:error, %Normandy.Guardrails.ViolationError{}}`.
   Fix: change the line to "an input or output guardrail".
   Public API: no (docs only).

10. [Composition · under, minor] lib/normandy/tools/memory/commands.ex:17-18, 89. Commands has its own `@root "/memories"`, which also exists in paths.ex:8 (`Paths.root/0`). It reads the list limit at compile time (`@list_limit`, used at line 347) and at runtime (`MemoryStore.list_limit()`, line 89).
    Evidence: `grep '@root "/memories"'` finds paths.ex:8 and commands.ex:17.
    Fix: use `Paths.root()` and read the limit once.
    Public API: no.

Count by principle: Composition 6 (#1, #2, #4, #5, #8, #10), Dependency injection 0, Flat code 3 (#2 shared with composition, #6, #7), Measure first 0, False claim 3 (#3, #4 shared, #9).

### Survived scrutiny
- `Normandy.Tool` behaviour plus `use Normandy.Tool` (tool.ex:61-117). There are 3 lib implementers (tools/memory.ex, a2a/agent_tool.ex, mcp/tool_wrapper.ex) and 23 test files that `use` it. The macro only generates the callbacks its options name. There is no `defoverridable` and no inherited behaviour, so this is composition, not a base class.
- `Normandy.Guardrails.Guard` with the optional `check/3` (guard.ex:55-76). There are 5 built-in implementers plus host guards. `check/3` has a real implementer (SemanticScope), and `do_check/4` dispatches on what the module exports.
- MemoryStore injected as `{module, handle}` (memory.ex:272-284, commands.ex:463-469). There are 5 backends (InMemory, ETS, Mnesia, Postgres, Redis) under a shared contract. `store/3` wraps only the store call.
- SemanticScope's `:classifier`/`:fast_path` are injected functions. The guard does no IO. Host failures become `GuardError` only under `:open`/`:closed`.
- `Hooks.Runner` as the only caller of hook callbacks. Grepping lib for `.on_prompt(`, `.before_tool(` etc. outside Runner and the glue modules finds nothing, so the moduledoc claim holds. Its eight event functions look alike but each ends in a different step (`string_halt`, `gate`, `tool_halt`, `answered`, `collect`), so a table-driven version would hide the differences.
- `Hooks.Handlers.wrap/2` is reused by BaseAgent's non-streaming and streaming sets (base_agent.ex:679, 1245). Only ServerGlue's stub use is questioned (#1).
- `Tools.Input`'s two paths (`validate_schema` for `input:` tools, `validate_map` for hand-written maps). Both kinds exist in lib: Memory and MCP tools hand-write the map; `use ... input:` tools get a struct.
- `Tools.Context` vs `Hooks.Context`. Their fields overlap, but they serve different audiences: a tool gets `input`/`tool_call_id`; a hook gets `event`/`model` and no input. Merging them would expose more to each.
- Executor's one `Task` per call (executor.ex:103-131). It is needed for the timeout and for crash isolation, not as an optimisation.
- RegexGuard recompiles each pattern on every check (regex_guard.ex:52-55). This is done for correctness: a compiled regex is only valid on the VM that compiled it, and a guard spec may be restored from storage on another node. Under `:incremental` streaming it runs about n/chunk_size times per answer, but no benchmark exists (`grep -rln Benchee` returned nothing), so there is no measured cost to act on. Measure it before caching.
- Credo `--strict` over the 24 files reported 0 issues; the remaining disables follow the CLAUDE.md rule (inline, no threshold change). `commands.ex:68 view` (depth 4 by the heuristic) holds up: the extra level is a one-line `with` inside a `case` arm.
- No tests in test/tools, test/hooks or test/guardrails patch the environment (`Application.put_env`, `:meck`, `Mimic`: 0 hits).

### Not checked
- `mix dialyzer`, `mix xref graph --label compile-connected` and the test suite were not run. That keeps the run short, and none of the findings depends on them.
- nesting_depth.py is a heuristic. Each of its 4 hits was confirmed by reading the code, but functions it did not flag were not all read for depth.
- Callers outside the scope (Dispatch, Turn.Server, BaseAgent) were read only at the lines cited above, not audited.
- Whether a host relies on the `Normandy.Guardrails.Builtins.` prefix (#8) or on the Toolset metadata functions (#4) cannot be seen from this repo.
- No benchmarks exist, so the measure-first checks were limited to looking for unbounded loops. None were found, apart from the documented quadratic cost of `:incremental` streaming guards, which is enforced in BaseAgent (outside the scope).
