# Audit: `schema` area

Scope read in full: schema.ex, schema/{validator,introspection,validation_error}.ex, type.ex, parameterized_type.ex (callbacks, lines 100-197), validate.ex, metadata.ex, exceptions.ex, tools/{registry,executor,base_tool,schema_base_tool}.ex, tools/examples/*, guardrails.ex, guardrails/guard.ex, guardrails/violation_error.ex, guardrails/builtins/*.
Cross-checked callers in agents/dispatch.ex, agents/validation_middleware.ex, agents/base_agent.ex, llm/json/schema_binder.ex. No `mix` run; all findings are from reading code and tests (grep).

### SCHEMA-1. Schema emits non-JSON-Schema `type` values for most non-primitive field types
- Severity: HIGH
- Category: 4 (contracts) / 8 (docs vs reality)
- Location: lib/normandy/schema.ex:511-544 (`get_base_type_spec/2`, `normalize_type/1`)
- Evidence:
  ```elixir
  defp get_base_type_spec(type, description) when is_atom(type) do
    if schema_module?(type) do ... else
      %{type: normalize_type(type), description: description}
  defp get_base_type_spec(type, description) do
    %{type: normalize_type(type), description: description}   # tuples, {:parameterized, _}
  defp normalize_type(:float), do: :number
  defp normalize_type(type), do: type
  ```
- Why it's a problem: only `:float` is translated. `field :meta, :map` emits `type: :map` (JSON Schema needs `object`); `:any`, `:binary`, `:bitstring`, `:date`, `:time`, `:duration`, `:struct` are emitted verbatim; a custom `Normandy.Type` module emits `type: MyApp.EncodedId` (not its `type/0`); `{:array, {:array, :string}}` emits `items: %{type: {:array, :string}}` and a parameterized field emits a `{:parameterized, ...}` tuple (the Poison encode then raises). A `SchemaBaseTool` with a `:map` field produces a tool `input_schema` Anthropic should reject (400) on every request; an `io_schema` output with such a field breaks structured outputs. The schema.ex moduledoc itself uses `field(:value, :any, ...)` and `field(:contact_info, :map, ...)`. `Validator.valid_type?/2` is keyed on these same Elixir atoms (`:map`, `:date`), so the two sides are coupled and a fix must change both.
- Fix: map base types to JSON Schema (`:map`->`object`, `:any`->omit `type`, `:binary`/`:bitstring`->`string`, `:date`->`string`+`format: "date"`, `:time`, `:duration`->`string`), resolve custom types via `Normandy.Type.type/1`, recurse for nested `{:array, _}`/`{:map, inner}` (`additionalProperties`), and teach `Validator.valid_type?/2` the JSON names.
- Confidence: verified (read the clauses; API 400 behaviour is theory, confirm with a tool that has a `:map` field)

### SCHEMA-2. `Validate.cast` crashes on nested schema fields (and `:struct`) in the LLM-output binding path
- Severity: HIGH
- Category: 4 (contracts)
- Location: lib/normandy/type.ex:708-713 (`cast_fun/1` generic atom clause), type.ex:509 (`dump`), validate.ex:104; caller lib/normandy/llm/json/schema_binder.ex:24
- Evidence:
  ```elixir
  defp cast_fun(mod) when is_atom(mod) do
    fn nil -> {:ok, nil}
       value -> mod.cast(value)      # mod = nested io_schema module, or :struct
  ```
- Why it's a problem: `Schema.check_field_type!` accepts a schema module as a field type (moduledoc advertises `field(:address, Address)` and `{:array, Address}` for io_schema). `Validate.cast/4` uses `__specification__/0` (field -> type), so the type is the nested module. Nothing in `use Normandy.Schema` defines `cast/1` on it, so `SchemaBinder.bind/3` (legacy parse path) raises `UndefinedFunctionError` (`Address.cast/1`) for any LLM reply that populates such a field. `{:array, Address}` goes through the same clause. `:struct` is in `@base` (and CLAUDE.md) but `cast(:struct, _)` hits `:struct.cast/1`, a nonexistent module. No test covers nested fields through `Validate.cast` (only schema_nested_test checks JSON generation).
- Fix: in `cast_fun/1` (or in `Validate.cast`) handle schema modules by recursively casting into the struct (`struct`-building with `Validate.cast` of the nested map), add a `:struct` clause, and raise a clear error for modules that are neither `Normandy.Type` nor schema.
- Confidence: verified by reading (call chain SchemaBinder -> Validate.cast -> Type.cast -> cast_fun); not executed

### SCHEMA-3. Validator silently skips composition and conditionals on scalar/`:any`/`:map` fields; `const` unsupported
- Severity: HIGH
- Category: 1 (silent fallback), 8 (docs)
- Location: lib/normandy/schema/validator.ex:231-239 (`validate_value/4`), :668-678 (`validate_nested_object/4`), :683-819
- Evidence:
  ```elixir
  defp validate_value(errors, value, field_spec, path) do
    errors |> validate_type(...) |> validate_string_constraints(...) |> validate_number_constraints(...)
    |> validate_array_constraints(...) |> validate_enum(...) |> validate_nested_object(...)
  end
  defp validate_nested_object(errors, value, spec, path) when is_map(value) do
    if spec[:properties] do ... validate_against_spec(...)   # only place any_of/one_of/if run
  ```
- Why it's a problem: `validate_composition/4` and `validate_conditionals/4` are only reached through `validate_against_spec/3`, i.e. for the root spec or a map value whose spec has `:properties`. A field `field(:id, :any, one_of: [%{type: :string, format: "uuid"}, %{type: :integer, minimum: 1}])` (the moduledoc example), a `:string` field with `any_of`, or the documented `:map` + `one_of: [EmailContact, PhoneContact]` (no `:properties` on that spec) is never checked: invalid data is accepted. Separately `if_schema: %{properties: %{type: %{const: "premium"}}}` (moduledoc) relies on `const`, which the validator does not implement, so the `if` always passes and `then_schema` is always enforced. Other keywords emitted into the spec but never enforced: `additionalProperties`, `multipleOf`, `not`, `patternProperties`. Tests assert the generated spec, not validation results.
- Fix: call `validate_composition`/`validate_conditionals` from `validate_value/4`; implement `const`; return an error (or raise at schema definition) for keywords the validator does not support instead of ignoring them.
- Confidence: verified (read all paths)

### SCHEMA-4. `Executor.execute_parallel/3` (and `execute/3`, `execute_sequential/3`) ignore the supplied tool instance
- Severity: HIGH
- Category: 4 (contracts), 7 (dead code)
- Location: lib/normandy/tools/executor.ex:100-111, :44-55, :127-138; lib/normandy/tools/registry.ex:61-64
- Evidence:
  ```elixir
  |> Enum.map(fn {tool_name, _params} ->
    Task.async(fn -> ... execute(registry, tool_name, opts) end)
  ```
  and `Registry.register`: `%{registry | tools: Map.put(tools, tool_name, tool)}`
- Why it's a problem: the spec says `[{String.t(), struct()}]` and the @doc shows two `CalculatorTool` instances with different params, but the struct is discarded and the instance stored in the registry is run. test/tools/executor_test.exs:82-98 registers `calc1` (add) and `calc2` (multiply) under the same name `"calculator"`; `Registry.register` silently overwrites, so both calls run multiply and the test passes because it only asserts `{:ok, _}`. Wrong results, masked by the test. None of the three entry points is called anywhere in lib (only `execute_tool/2` is, via Dispatch/BaseAgent/Config), so this is dead public API that is also wrong.
- Fix: either delete `execute/3`, `execute_parallel/3`, `execute_sequential/3`, or make `execute_parallel` run the given struct (`execute_tool(struct, opts)`) and have `Registry.register/2` raise (or return an error) on a duplicate name unless `replace: true`. Tighten the test to assert distinct results.
- Confidence: verified

### SCHEMA-5. `Validate.validate_number/3` raises for every valid option (inverted guard), untested
- Severity: HIGH
- Category: 4 (contracts)
- Location: lib/normandy/validate.ex:759-765
- Evidence:
  ```elixir
  unless is_atom(target_value) do
    raise ArgumentError,
          "expected option `#{spec_key}` to be a decimal, integer, or float, got: #{inspect(target_value)}"
  ```
- Why it's a problem: Ecto's check is `is_number(target) or Decimal.decimal?(target)`. Here it is `is_atom`, so `validate_number(cs, :age, greater_than: 0)` raises "expected option `greater_than` to be a decimal, integer, or float, got: 0", while an atom target such as `:foo` passes the guard and then compares a number with an atom (term ordering, wrong answer). `grep -rn validate_number test lib` finds no test and no caller outside validate.ex, which is how this shipped. The same file has other copied-but-unexercised Ecto API (`validate_acceptance`, `validate_confirmation`, `validate_subset`, `validate_exclusion`: no callers in lib).
- Fix: `unless is_number(target_value)`; add tests for every `validate_*` (or delete the unused ones).
- Confidence: verified

### SCHEMA-6. Tool returning a non-conforming result crashes the turn; Executor claims "Result validation" but does none
- Severity: MEDIUM
- Category: 4 (contracts), 1
- Location: lib/normandy/tools/executor.ex:8-9 (moduledoc), :142-153, :155-183; consumer lib/normandy/agents/base_agent.ex:1462-1463 (`elem(r, 0)`), lib/normandy/agents/dispatch.ex:262-267
- Evidence:
  ```elixir
  r = Executor.execute_tool(prepared_tool)
  {r, Map.put(tool_meta, :status, elem(r, 0))}
  ```
  `execute_with_timeout` returns whatever `BaseTool.run/1` returns; `execute_with_retries` has only `{:ok,_}`/`{:error,_}` clauses.
- Why it's a problem: the callback contract is `{:ok, term} | {:error, String.t()}` but it is not enforced. A third-party tool that returns `:ok`, a bare string, or `nil` makes `elem/2` raise `ArgumentError` (or `execute_with_retries` raise `CaseClauseError` on the `execute/3` path), outside the rescue that wraps the tool, aborting the whole agent turn instead of producing an error ToolResult for the model. A `{:error, atom_or_map}` also violates the `String.t()` spec silently.
- Fix: in `execute_with_timeout` normalize with a final clause: `other -> {:error, "Tool returned invalid result: #{inspect(other)}"}` (inspect only a truncated value) and update the moduledoc.
- Confidence: verified (reading); not run

### SCHEMA-7. Field option values and leftover Ecto options are never validated at definition time
- Severity: MEDIUM
- Category: 2 (option handling)
- Location: lib/normandy/schema.ex:213-252 (`@field_opts`), :803-820 (`check_options!`), :598-648, :708-720
- Evidence:
  ```elixir
  @field_opts [:default, :redact, :defaults, :type, :where, :references, :skip_default_validation, ...]
  defp check_options!({:parameterized, _}, _opts, _valid, _fun_arity), do: :ok
  ```
- Why it's a problem: only option names are checked, not values. `min_length: "3"` compiles; in Validator `String.length(v) >= "3"` is always false (number < binary), so every value fails, and `max_length: "3"` never fails. `pattern: ~r/x/` (a Regex, not a string) or an invalid pattern string is not caught until `Regex.compile!/1` raises per validation (validator.ex:306), i.e. at runtime inside `Dispatch.validate_input/2`, which runs before the policy rescue. `required: "yes"` is truthy. `enum: "abc"`, `any_of: :foo` (a `case` with no clause raises `CaseClauseError` during module compilation, unhelpful message). `:defaults`, `:type`, `:where`, `:references` are Ecto options accepted and ignored, so a typo-adjacent option passes silently. Parameterized types skip `check_options!` entirely.
- Fix: validate option value types in `__field__/4` (integers for lengths/items, binary for pattern/format and `Regex.compile!` it once at compile time, list for enum/composition), drop the Ecto leftovers from `@field_opts`.
- Confidence: verified

### SCHEMA-8. Built-in guards fail open when `:field` is misspelled or the value is not a map
- Severity: MEDIUM
- Category: 1 (silent fallback), 2
- Location: lib/normandy/guardrails/builtins/max_length.ex:58-60; forbidden_substrings.ex:73-74; regex_guard.ex:108-109 (and the `nil -> :ok` arms)
- Evidence:
  ```elixir
  defp extract(value, field) when is_map(value), do: Map.get(value, field)
  defp extract(_value, _field), do: nil          # max_length.ex only
  ...
  case extract(value, field) do
    nil -> :ok
  ```
- Why it's a problem: `Map.get(struct, :summery)` returns `nil` for a typo, and `nil` is treated as "nothing to check", so `{MaxLength, limit: 500, field: :summery}` or `{ForbiddenSubstrings, field: :sumary, ...}` never blocks anything and never complains. This is a safety control, so a config typo silently disables it. `MaxLength.extract/2` additionally returns `nil` for non-map input (e.g. a string input with `field:` set) while the sibling guards raise, so the three guards disagree. (RegexGuard `:require` correctly fails on nil, but `:deny` fails open.)
- Fix: when `field` is set and `value` is a struct, `Map.fetch!`-style: raise `ArgumentError` if the key is not a field of the struct (a present-but-`nil` field stays a no-op); make MaxLength raise for non-maps like its siblings.
- Confidence: verified

### SCHEMA-9. `InvalidChangesetError` message dumps raw params, data and the full changeset
- Severity: MEDIUM
- Category: 3 (security)
- Location: lib/normandy/exceptions.ex:46-69
- Evidence:
  ```elixir
  Params
  #{pretty(changeset.params)}
  Changeset
  #{pretty(changeset)}
  ```
- Why it's a problem: `Normandy.Validate.apply_action!/2` raises this with the exception message containing `inspect(changeset.params)` (raw, unredacted input) and `inspect(changeset)` (including `data`, which only honours the struct's derived Inspect). A schema field declared `redact: true` (e.g. `password`) is hidden in `inspect(struct)` but its value is printed in `Params`, and `Changes`. Exception messages end up in logs, error trackers and telemetry. Ecto's version has the same shape, but Normandy advertises field redaction, so this is a hole in that promise.
- Fix: drop `Params` and the full-changeset sections, or redact keys listed in `data.__struct__.__schema__(:redact_fields)` before inspecting.
- Confidence: verified

### SCHEMA-10. `redact: true` only affects `Inspect`; `to_json/__str__/__rich__` still serialize redacted fields
- Severity: MEDIUM
- Category: 3 (security), 8 (docs)
- Location: lib/normandy/schema.ex:336-342, :424-427; consumers lib/normandy/components/agent_memory.ex:94, lib/normandy/behaviours/compactor/window_manager.ex:81
- Evidence:
  ```elixir
  def __str__(str), do: @adapter.encode!(str)
  def __rich__(str), do: @adapter.encode!(str, pretty: true)
  def to_json(str), do: @adapter.encode!(str)
  ```
  vs `Module.put_attribute(module, :derive, {Inspect, except: redacted_fields})`
- Why it's a problem: the moduledoc lists "Field redaction support". Redaction is implemented only by deriving Inspect. Every `BaseIOSchema` path encodes the whole struct, so a `redact: true` field is written into memory history (`AgentMemory.history/1`) and sent to the LLM on each turn, and `__str__/__rich__` (intended for display/logging) print it. Also `__meta__` is encoded (known: B7 in the prior audit). Poison's struct-encoding behaviour is the unverified step.
- Fix: define `to_json/__str__/__rich__` over `Map.drop(Map.from_struct(s), [:__meta__ | redacted_fields])` (or `@derive {Poison.Encoder, except: ...}`), or document that redaction is inspect-only and rename the option.
- Confidence: theory (confirm: `Poison.encode!(%MySchemaWithRedactedField{password: "x"})` and read `AgentMemory.history/1` output)

### SCHEMA-11. `Normandy.Type` has missing `load`/`dump`/`cast` clauses for declared base types
- Severity: MEDIUM
- Category: 4 (contracts)
- Location: lib/normandy/type.ex:190-193 (`@base`), :499-509 (dump), :556-563 (load), :666-713 (cast_fun)
- Evidence:
  ```elixir
  @base ~w(integer float boolean string bitstring map binary any date time duration any struct)a
  def load(:time, value, _loader), do: load_time(value)
  def load(mod, value, _loader), do: mod.load(value)     # :any, :binary, :duration, :bitstring, :struct land here
  def dump(mod, value, _dumper) when is_atom(mod), do: mod.dump(value)   # :bitstring, :struct
  ```
- Why it's a problem: `Type.load(:any, v)`, `load(:binary, v)`, `load(:duration, v)` call `:any.load/1`, `:binary.load/1` (Erlang's `:binary` module exists, no such function) and raise `UndefinedFunctionError`; `dump(:bitstring, _)`/`dump(:struct, non_nil)` and `cast(:struct, _)` likewise. `Schema.validate_default!/3` calls `dump`, so `field :blob, :bitstring, default: <<1::3>>` fails at compile time with an unrelated `UndefinedFunctionError`. Property tests (type_property_test.exs) cover only integer/float/boolean/string/map/array.
- Fix: add the missing clauses (`:any`, `:binary`, `:bitstring`, `:duration`, `:struct`) to load/dump/cast, and a property test per `@base` member.
- Confidence: verified (read clause order)

### SCHEMA-12. Executor option handling and retry semantics
- Severity: MEDIUM
- Category: 2 (options), 4 (contracts), 3
- Location: lib/normandy/tools/executor.ex:44-50, :68-77, :142-153, :165-172
- Evidence:
  ```elixir
  timeout = Keyword.get(opts, :timeout, @default_timeout)            # execute/3: per-tool :timeout ignored, nil/bad value reaches Task.yield
  timeout = Keyword.get(opts, :timeout) || Map.get(tool, :timeout) || @default_timeout   # execute_tool/2
  {:error, _reason} when retries_left > 0 -> execute_with_retries(...)
  kind, reason -> {:error, "Tool execution failed (#{kind}): #{inspect(reason)}"}
  ```
- Why it's a problem: (a) precedence differs between `execute/3` and `execute_tool/2` (the former ignores the per-tool `:timeout` the latter documents); `timeout: nil` or `max_retries: -1`/`"2"` are unvalidated (`nil` crashes in `Task.yield/2`; a negative count silently means 0). (b) `max_retries` retries every `{:error, _}`, including the tool's own "timeout" and validation-style errors, re-running a side-effecting tool (`send_email`) with no idempotency warning and no cap on total time (`(n+1) * timeout`). (c) `Exception.message(error)` and `inspect(exit_reason)` are interpolated into the string that becomes the ToolResult shown to the model; GenServer-call exit reasons embed the call arguments (SQL, params, tokens) and exception messages often embed connection details.
- Fix: validate opts once with a shared `fetch_timeout/2`; retry only on errors the tool marks retryable (or document loudly and default to 0 as now); truncate and sanitize the strings handed back to the model, log the full reason server-side.
- Confidence: verified for (a),(b); (c) partly theory (string is built here, the ToolResult hop is in dispatch.ex)

### SCHEMA-13. Stale docs and lying specs in Validate, SchemaBaseTool and the shipped examples
- Severity: LOW
- Category: 8 (docs vs reality), 4
- Location: validate.ex:16-18, :88-94, :438-441; schema_base_tool.ex:41, examples/calculator.ex:8-16, enhanced_calculator.ex:34-41, weather.ex:11-14; schema.ex:158-166
- Evidence:
  - validate.ex moduledoc: `Validate.validate(data, params, types, required: [:name, :email])` (no such arity). Actual `validate/2` (no @doc/@spec, no callers) casts every field in `__schema__(:fields)` and calls `validate_required` on all of them, ignoring each field's `required:` option.
  - `@spec cast(Normandy.Schema.t() | t | {data, types}, ...)`: passing a `%Validate{}` or `{data, types}` raises `UndefinedFunctionError` (`module.__specification__()`/CaseClauseError); `validate_required` treats `"   "` as present (Ecto trims).
  - SchemaBaseTool and both calculators claim "Handles default values and type coercion"; `Validator` is strict (`limit: "5"` fails) and returns the input map untouched.
  - Docs show `{:ok, 8}` but `Calculator.execute` returns `8.0` (and `Float.round` in EnhancedCalculator); Weather doc shows `"Temperature: 15.2°C, Conditions: ..."` but the code returns `"Current weather in X: ..."`.
  - schema.ex moduledoc: `defp compute_total` referenced as `&__MODULE__.compute_total/1` (private function cannot be captured remotely).
- Why it's a problem: copy-pasted examples fail; `Validate.validate/2` marks optional fields required.
- Fix: correct the docs, delete or document `validate/2`, trim the spec of `Validate.cast/4`.
- Confidence: verified

### SCHEMA-14. Ecto-port leftovers and dead code in the schema layer
- Severity: LOW
- Category: 7 (design/dead code)
- Location: type.ex:830-873 (`adapter_autogenerate/load/dump`, `process_loaders/dumpers`), type.ex:186-188, :194-195 (`:try`, `:in`, `:param`, `:supertype`, `splice`), schema.ex:377-383 (`__after_verify__` stub and its registration at :393-395), schema.ex:276-282/:314-320/:336,348 (`try ... after :ok end` no-ops), schema.ex:258-268 (`@schema_context`)
- Evidence: `def __after_verify__(_module) do ... :ok end`; `try do ... after :ok end`; `adapter.loaders(...)`.
- Why it's a problem: `adapter_*` call `adapter.loaders/dumpers/autogenerate` that no Normandy adapter provides and have no callers (lib or test); `__after_verify__` is registered for every schema module and does nothing; the `try/after :ok` wrappers do nothing. `Type.autogenerate` callback is documented for a `:autogenerate` field flag that `@field_opts` rejects. Each is surface a contributor must understand for no benefit.
- Fix: delete them.
- Confidence: verified (grep for callers)

### SCHEMA-15. Inconsistent tool-schema representation and introspection helpers give wrong answers
- Severity: LOW
- Category: 4 (contracts), 7
- Location: lib/normandy/tools/registry.ex:414-426 (`has_param_type?`), :428-440; lib/normandy/schema/introspection.ex:175-185 (`virtual_field?/2`); tools/examples/weather.ex:81-100
- Evidence:
  ```elixir
  Enum.any?(fn prop -> prop[:type] == param_type end)     # param_type is a String
  field_exists? and not in_properties?                     # "virtual" == "absent from JSON properties"
  ```
- Why it's a problem: `SchemaBaseTool` tools expose atom types (`type: :number`) while hand-written tools (StringManipulator, ListProcessor) use strings (`"number"`), so `Registry.filter_by_param_type(reg, "number")` (the @doc example uses Calculator) silently excludes every schema-based tool. `Introspection.virtual_field?/2` returns `false` for `virtual: true, include_in_json_schema: true` fields, although `__schema__(:virtual_fields)` holds the truth. Weather example (shipped in lib): calls `:inets.start()`/`:ssl.start()` as a library side effect on every call, hardcodes `Poison` instead of the configured adapter, and uses `:httpc` with no explicit TLS verification options (theory: behaviour differs by OTP version; confirm on OTP 26+ with `ssl: [verify: ...]` unset).
- Fix: normalize `type` to strings when comparing (`to_string/1`); use `:virtual_fields` in `virtual_field?/2`; pass `ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]` to httpc or drop the example from `lib/`.
- Confidence: verified for the first two, theory for the TLS point

## Known (from prior audit)
- A8 (output schema silently missing / retry path crashes, `__specification__/0` used as JSON schema): still present? yes — lib/normandy/agents/base_agent.ex:259-260 (encode inside silent `rescue _ ->`), lib/normandy/llm/json/retry_feedback.ex:17 and :58. Root cause is the two same-named artifacts in schema.ex (`__specification__/0` = field->type map at schema.ex:289, vs `__schema__(:specification)` = JSON Schema).
- B7 (`__meta__` serialized into every message JSON): still present? yes — lib/normandy/schema.ex:336-341 (no `__meta__` exclusion in `to_json`).
- B4 (adapter resolved inconsistently): still present? yes — `Application.compile_env(:normandy, :adapter, Poison)` inside a macro at schema.ex:338 (baked into consumer modules, checked by the consumer's compile-env validation), while base_agent.ex:260/489 hardcode `Poison`.

## Area summary
- Two correctness clusters dominate: the JSON Schema generator/validator pair only handles a small set of primitive types and ignores most advertised keywords (SCHEMA-1, -3), and the Ecto-derived code was ported without exercising it (SCHEMA-2, -5, -11), with `Validate.validate_number/3` unusable and nested-schema casting crashing.
- Tools: only `Executor.execute_tool/2` is live; the registry-based Executor entry points are dead and wrong (SCHEMA-4), and the tool result contract is unenforced (SCHEMA-6).
- Count: 5 HIGH, 7 MEDIUM, 3 LOW (15 total). Tests mostly assert generated specs or `{:ok, _}`, not behaviour, which is why SCHEMA-3, -4 and -5 survived.
