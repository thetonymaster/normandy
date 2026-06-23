# Anthropic Structured Outputs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ClaudioAdapter` use Anthropic native structured outputs (constrained decoding) by default to get schema-valid JSON without the parse-retry loop, with automatic fallback to the legacy path for incompatible schemas, refusal/max_tokens, and API rejection.

**Architecture:** A pure `SchemaTranslator` turns a Normandy schema spec into a constrained-decoding JSON Schema (or declares it incompatible). A `StructuredOutputs` gate decides structured-vs-legacy. `ClaudioAdapter.do_converse/7` routes through the gate: structured path sends `output_config` and decodes+binds the guaranteed-valid response via the existing `Json.Decoder`/`Json.SchemaBinder`; everything else falls back to the legacy `deserialize_with_retry` path. The `:on_parse_failure` policy is extracted into a shared helper both paths use.

**Tech Stack:** Elixir, ExUnit, Poison, Claudio `~> 0.6.0`, `:telemetry`.

**Reference:** `docs/superpowers/specs/2026-06-19-structured-outputs-design.md`.

## Global Constraints

- **Non-breaking:** no `Normandy.Agents.Model` protocol signature/`@spec` change; `JsonDeserializer.parse_and_validate/3` + `deserialize_with_retry/8` keep signatures and all return shapes.
- **Default-on with kill-switch:** structured outputs used by default; disabled via `Application.get_env(:normandy, :structured_outputs, true)` or per-client `client.options[:structured_outputs]` (per-client overrides global).
- **Gate-skip path is byte-identical to today's legacy path.**
- **Full suite green at every checkpoint.** Verified baseline before this plan: `1385 tests, 0 failures (128 excluded)` @ HEAD. The `[error] normandy agent exception` log line is expected output, not a failure.
- **Run `mix format` before every test run.** Never `git add .` (add files individually). Use each task's commit message verbatim. No AI-authorship attribution.
- **Verified facts (from codebase/dep):** `response_model.__struct__.get_json_schema/0` == `__schema__(:specification)`, nested schemas inline via `inline_nested_schema/1` (keys `:type,:properties,:required,:description`). Claudio parses `stop_reason` to atoms: `:end_turn, :max_tokens, :stop_sequence, :tool_use, :pause_turn, :refusal, :model_context_window_exceeded`. No offline test drives `ClaudioAdapter.converse`/`Claudio.Messages.create` (the caching test only exercises `add_single_message`), so default-on does not perturb the unit suite.

---

### Task 1: Upgrade Claudio to `~> 0.6.0`

**Files:**
- Modify: `mix.exs` (the `{:claudio, "~> 0.5.0"}` dep, line ~142)
- Test: `test/llm/claudio_structured_dep_test.exs` (create)

**Interfaces:**
- Produces: `Claudio.Messages.Request.set_output_format/2` available; `Claudio.Messages.Request` has an `output_config` field.

- [ ] **Step 1: Write the failing capability test**

Create `test/llm/claudio_structured_dep_test.exs`:

```elixir
defmodule Normandy.LLM.ClaudioStructuredDepTest do
  use ExUnit.Case, async: true

  test "Claudio exposes set_output_format/2 for structured outputs" do
    assert function_exported?(Claudio.Messages.Request, :set_output_format, 2)
  end

  test "set_output_format sets a json_schema output_config.format on the request" do
    req =
      Claudio.Messages.Request.new("claude-haiku-4-5")
      |> Claudio.Messages.Request.set_output_format(%{
        "type" => "object",
        "properties" => %{"chat_message" => %{"type" => "string"}},
        "required" => ["chat_message"],
        "additionalProperties" => false
      })

    assert %{format: %{type: "json_schema", schema: %{"type" => "object"}}} = req.output_config
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/claudio_structured_dep_test.exs`
Expected: FAIL — Claudio 0.5.0 has no `set_output_format/2` / `output_config`.

- [ ] **Step 3: Bump the dependency**

In `mix.exs`, change `{:claudio, "~> 0.5.0"}` to `{:claudio, "~> 0.6.0"}`. Then:

Run: `mix deps.update claudio && mix deps.get`
Expected: claudio resolves to a 0.6.x version.

- [ ] **Step 4: Run the capability test, then the whole suite**

Run: `mix format && mix test test/llm/claudio_structured_dep_test.exs && mix test`
Expected: PASS. The capability test passes; the whole suite stays at `1385 tests, 0 failures` (the 0.5→0.6 bump must not break anything). If the upgrade breaks compilation or any test, STOP and report (a 0.6.0 breaking change needs a decision, not a workaround).

> Note: the exact `req.output_config` shape in Step 1 (`%{format: %{type: "json_schema", schema: ...}}`) is the documented 0.6.0 behavior of `set_output_format/2`. If the real shape differs (e.g. string keys on `type`/`schema`), adjust the assertion to the real shape and note it in your report — the assertion exists to pin whatever 0.6.0 actually produces.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock test/llm/claudio_structured_dep_test.exs
git commit -m "build(deps): upgrade Claudio to ~> 0.6.0 for structured outputs"
```

---

### Task 2: `Normandy.LLM.Json.SchemaTranslator`

**Files:**
- Create: `lib/normandy/llm/json/schema_translator.ex`
- Test: `test/llm/json/schema_translator_test.exs`

**Interfaces:**
- Produces: `SchemaTranslator.translate(spec_map) :: {:ok, map()} | {:incompatible, term()}` — converts Normandy's `__schema__(:specification)` form into a constrained-decoding JSON Schema (string keys, recursive `additionalProperties: false`, allowlisted keys), or declares it incompatible.
- Consumes: nothing.

- [ ] **Step 1: Write the failing unit tests**

Create `test/llm/json/schema_translator_test.exs`:

```elixir
defmodule Normandy.LLM.Json.SchemaTranslatorTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.SchemaTranslator

  test "translates a flat object: string keys, additionalProperties:false, required" do
    spec = %{
      type: :object,
      title: "Out",
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      properties: %{
        chat_message: %{type: :string, description: "msg", default: ""},
        count: %{type: :integer, description: ""}
      },
      required: [:chat_message]
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)

    assert schema == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["chat_message"],
             "properties" => %{
               "chat_message" => %{"type" => "string", "description" => "msg"},
               "count" => %{"type" => "integer"}
             }
           }
  end

  test "recurses additionalProperties:false into nested objects" do
    spec = %{
      type: :object,
      properties: %{
        addr: %{type: :object, properties: %{city: %{type: :string}}, required: [:city]}
      },
      required: [:addr]
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)
    assert schema["properties"]["addr"]["additionalProperties"] == false
    assert schema["properties"]["addr"]["required"] == ["city"]
  end

  test "translates arrays via items" do
    spec = %{type: :object, properties: %{tags: %{type: :array, items: %{type: :string}}}, required: []}
    assert {:ok, schema} = SchemaTranslator.translate(spec)
    assert schema["properties"]["tags"] == %{"type" => "array", "items" => %{"type" => "string"}}
  end

  test "strips unsupported keywords (title/$schema/default/min_length)" do
    spec = %{
      type: :object,
      "$schema": "x",
      properties: %{name: %{type: :string, min_length: 3, default: "z"}},
      required: [:name]
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)
    refute Map.has_key?(schema, "$schema")
    refute Map.has_key?(schema["properties"]["name"], "min_length")
    refute Map.has_key?(schema["properties"]["name"], "default")
  end

  test "open object (no properties — a Normandy :map field) is incompatible" do
    spec = %{type: :object, properties: %{meta: %{type: :object, default: nil}}, required: []}
    assert {:incompatible, {:open_object, _}} = SchemaTranslator.translate(spec)
  end

  test "runaway nesting depth is incompatible" do
    deep = Enum.reduce(1..12, %{type: :string}, fn _, acc ->
      %{type: :object, properties: %{n: acc}, required: [:n]}
    end)

    assert {:incompatible, :too_deep} = SchemaTranslator.translate(deep)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/json/schema_translator_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the translator**

Create `lib/normandy/llm/json/schema_translator.ex`. Uses an allowlist (emit only supported keys, so unsupported keywords like `title`/`default`/`min_length` are dropped by construction) and `throw`/`catch` to surface incompatibility from deep recursion:

```elixir
defmodule Normandy.LLM.Json.SchemaTranslator do
  @moduledoc """
  Translates a Normandy schema specification (`__schema__(:specification)`)
  into a JSON Schema suitable for Anthropic structured outputs (constrained
  decoding): string keys, recursive `additionalProperties: false`, only the
  supported keywords. Returns `{:incompatible, reason}` for schemas
  constrained decoding cannot express (open `:map` objects, runaway nesting),
  so the caller can fall back to the legacy path.
  """

  @max_depth 8

  @spec translate(map()) :: {:ok, map()} | {:incompatible, term()}
  def translate(spec) when is_map(spec) do
    {:ok, node(spec, 0)}
  catch
    {:incompatible, reason} -> {:incompatible, reason}
  end

  defp node(_spec, depth) when depth > @max_depth, do: throw({:incompatible, :too_deep})

  defp node(%{type: :object} = spec, depth) do
    props = Map.get(spec, :properties)

    if is_nil(props) or props == %{} do
      throw({:incompatible, {:open_object, Map.get(spec, :title)}})
    end

    translated =
      props
      |> Enum.map(fn {k, v} -> {to_string(k), node(v, depth + 1)} end)
      |> Map.new()

    %{
      "type" => "object",
      "properties" => translated,
      "required" => spec |> Map.get(:required, []) |> Enum.map(&to_string/1),
      "additionalProperties" => false
    }
    |> with_description(spec)
  end

  defp node(%{type: :array} = spec, depth) do
    items = Map.get(spec, :items, %{type: :string})

    %{"type" => "array", "items" => node(items, depth + 1)}
    |> with_description(spec)
  end

  defp node(%{type: type} = spec, _depth) do
    %{"type" => to_string(type)}
    |> with_description(spec)
    |> with_enum(spec)
  end

  defp node(_spec, _depth), do: throw({:incompatible, :unsupported_node})

  defp with_description(map, spec) do
    case Map.get(spec, :description) do
      desc when is_binary(desc) and desc != "" -> Map.put(map, "description", desc)
      _ -> map
    end
  end

  defp with_enum(map, spec) do
    case Map.get(spec, :enum) do
      enum when is_list(enum) -> Map.put(map, "enum", enum)
      _ -> map
    end
  end
end
```

- [ ] **Step 4: Run the unit tests**

Run: `mix format && mix test test/llm/json/schema_translator_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: PASS (baseline + 6 new tests, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/schema_translator.ex test/llm/json/schema_translator_test.exs
git commit -m "feat(llm): add Json.SchemaTranslator for structured-output schemas"
```

---

### Task 3: `Normandy.LLM.StructuredOutputs` gate

**Files:**
- Create: `lib/normandy/llm/structured_outputs.ex`
- Test: `test/llm/structured_outputs_test.exs`

**Interfaces:**
- Consumes: `Normandy.LLM.Json.SchemaTranslator.translate/1` (Task 2).
- Produces:
  - `StructuredOutputs.enabled?(client) :: boolean()` — `client.options[:structured_outputs]` when set, else `Application.get_env(:normandy, :structured_outputs, true)`.
  - `StructuredOutputs.schema_for(client, response_model) :: {:ok, map()} | :skip` — `:skip` when disabled, when `response_model` is not a struct, or when translation is `{:incompatible, _}`; else `{:ok, json_schema}`.

- [ ] **Step 1: Write the failing unit tests**

Create `test/llm/structured_outputs_test.exs`:

```elixir
defmodule Normandy.LLM.StructuredOutputsTest do
  use ExUnit.Case, async: false

  alias Normandy.LLM.StructuredOutputs
  alias Normandy.LLM.Json.TestFixtures.MultiField

  defmodule OpenMapSchema do
    use Normandy.Schema

    io_schema "schema with an open map" do
      field(:meta, :map, description: "open")
    end
  end

  defp client(opts \\ %{}), do: %Normandy.LLM.ClaudioAdapter{api_key: "k", options: opts}

  test "enabled? defaults to true" do
    assert StructuredOutputs.enabled?(client())
  end

  test "enabled? honors a per-client false override" do
    refute StructuredOutputs.enabled?(client(%{structured_outputs: false}))
  end

  test "schema_for returns {:ok, schema} for a compatible struct" do
    assert {:ok, schema} = StructuredOutputs.schema_for(client(), %MultiField{})
    assert schema["additionalProperties"] == false
    assert "chat_message" in Map.keys(schema["properties"])
  end

  test "schema_for skips when disabled per client" do
    assert :skip = StructuredOutputs.schema_for(client(%{structured_outputs: false}), %MultiField{})
  end

  test "schema_for skips an incompatible (open-map) schema" do
    assert :skip = StructuredOutputs.schema_for(client(), %OpenMapSchema{})
  end

  test "schema_for skips a non-struct response_model" do
    assert :skip = StructuredOutputs.schema_for(client(), %{})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/structured_outputs_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the gate**

Create `lib/normandy/llm/structured_outputs.ex`:

```elixir
defmodule Normandy.LLM.StructuredOutputs do
  @moduledoc """
  Decides whether a request should use Anthropic structured outputs. Enabled
  by default; disable globally via `config :normandy, :structured_outputs,
  false` or per-call via `client.options[:structured_outputs]`. A schema that
  the `SchemaTranslator` cannot express falls back (`:skip`).
  """

  alias Normandy.LLM.Json.SchemaTranslator

  @spec enabled?(struct()) :: boolean()
  def enabled?(client) do
    case Map.get(client.options || %{}, :structured_outputs) do
      nil -> Application.get_env(:normandy, :structured_outputs, true)
      value -> value
    end
  end

  @spec schema_for(struct(), term()) :: {:ok, map()} | :skip
  def schema_for(client, response_model) do
    with true <- enabled?(client),
         true <- is_struct(response_model),
         spec <- response_model.__struct__.get_json_schema(),
         {:ok, schema} <- SchemaTranslator.translate(spec) do
      {:ok, schema}
    else
      _ -> :skip
    end
  end
end
```

- [ ] **Step 4: Run the unit tests**

Run: `mix format && mix test test/llm/structured_outputs_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: PASS (baseline + 6 new tests, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/structured_outputs.ex test/llm/structured_outputs_test.exs
git commit -m "feat(llm): add StructuredOutputs gate (default-on + kill-switch)"
```

---

### Task 4: Extract `apply_parse_failure/4` (shared policy)

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`populate_standard_schema/3` failure branch ~lines 849-879; add `apply_parse_failure/4` in the outer module near `__on_parse_failure_policy__/1`)
- Test: `test/llm/claudio_adapter_test.exs` (append)

**Interfaces:**
- Produces: `Normandy.LLM.ClaudioAdapter.apply_parse_failure(schema, content, reason, context) :: struct() | {:error, term()}` — resolves `:on_parse_failure` policy: `:error` → `{:error, reason}`; `:fallback` → `Logger.warning` + `[:normandy, :json_deserializer, :fallback]` telemetry, then `Map.put(schema, :chat_message, content)` (binary content) or `schema` (non-binary). Same behavior the inline branch had.

- [ ] **Step 1: Write the failing unit tests for the extracted helper**

Append to `test/llm/claudio_adapter_test.exs` (inside `defmodule NormandyTest.LLM.ClaudioAdapterTest`):

```elixir
  describe "apply_parse_failure/4" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    test ":fallback policy with binary content returns schema with chat_message set" do
      result = ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw text", :some_reason, %{on_parse_failure: :fallback})
      assert %MultiField{chat_message: "raw text"} = result
    end

    test ":fallback policy with non-binary content returns the schema unchanged" do
      result = ClaudioAdapter.apply_parse_failure(%MultiField{}, nil, :some_reason, %{on_parse_failure: :fallback})
      assert %MultiField{chat_message: nil} = result
    end

    test ":error policy returns {:error, reason}" do
      assert {:error, :some_reason} =
               ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw", :some_reason, %{on_parse_failure: :error})
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/claudio_adapter_test.exs`
Expected: FAIL — `ClaudioAdapter.apply_parse_failure/4` is undefined.

- [ ] **Step 3: Add the helper and call it from `populate_standard_schema/3`**

In `lib/normandy/llm/claudio_adapter.ex`, add to the OUTER module (next to `__on_parse_failure_policy__/1`):

```elixir
  @doc false
  def apply_parse_failure(schema, content, reason, context) do
    case __on_parse_failure_policy__(context) do
      :error ->
        {:error, reason}

      :fallback when is_binary(content) ->
        require Logger
        Logger.warning("JSON parse failed; falling back to raw text. reason=#{inspect(reason)}")
        :telemetry.execute([:normandy, :json_deserializer, :fallback], %{count: 1}, %{reason: reason})
        Map.put(schema, :chat_message, content)

      :fallback ->
        require Logger
        Logger.warning("JSON parse failed; returning schema unchanged. reason=#{inspect(reason)}")
        :telemetry.execute([:normandy, :json_deserializer, :fallback], %{count: 1}, %{reason: reason})
        schema
    end
  end
```

Then in the `defimpl`, replace the `{:error, reason} ->` branch body of `populate_standard_schema/3` (currently the inline `case __on_parse_failure_policy__(context) do ... end`, ~lines 850-879) with a single delegation:

```elixir
        {:error, reason} ->
          Normandy.LLM.ClaudioAdapter.apply_parse_failure(schema, content, reason, context)
```

(The `require Logger` that was at the top of the impl for the inline branch may now be unused there — if so, remove it; the helper has its own `require Logger`.)

- [ ] **Step 4: Run the unit tests then the whole suite**

Run: `mix format && mix test test/llm/claudio_adapter_test.exs && mix test`
Expected: PASS (baseline + 3 new tests, 0 failures). The legacy fallback behavior is unchanged — it now flows through the shared helper.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/llm/claudio_adapter.ex test/llm/claudio_adapter_test.exs
git commit -m "refactor(llm): extract shared apply_parse_failure policy helper"
```

---

### Task 5: Structured `converse` path + gate routing

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`do_converse/7`; add `converse_structured/8`, `do_converse_legacy/7`; add `__handle_structured_response__/3` in the outer module)
- Test: `test/llm/claudio_adapter_test.exs` (append)

**Interfaces:**
- Consumes: `StructuredOutputs.schema_for/2` (Task 3); `apply_parse_failure/4` (Task 4); `Normandy.LLM.Json.Decoder.decode/3`, `Normandy.LLM.Json.SchemaBinder.bind/3` (Phase 1); `Claudio.Messages.Request.set_output_format/2` (Task 1); the outer-module `extract_content/1`, `extract_usage/1` (from the retry fix).
- Produces: `ClaudioAdapter.__handle_structured_response__(response, response_model, context) :: struct() | {:error, term()}` — interprets a `{:ok, _}` Claudio response: normal stop → decode+bind → bound struct; refusal/max_tokens/context-exceeded → `apply_parse_failure`; decode/bind failure → `apply_parse_failure`.

- [ ] **Step 1: Write the failing offline tests for response interpretation**

Append to `test/llm/claudio_adapter_test.exs`:

```elixir
  describe "structured response interpretation" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    defp text_response(stop_reason, text) do
      %{stop_reason: stop_reason, content: [%{type: :text, text: text}], usage: %{}}
    end

    test "normal stop with valid JSON decodes and binds to the schema" do
      resp = text_response(:end_turn, ~s({"chat_message": "hi", "count": 2}))

      assert %MultiField{chat_message: "hi", count: 2} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "refusal routes to the parse-failure policy (default :fallback)" do
      resp = text_response(:refusal, "I can't help with that.")

      assert %MultiField{chat_message: "I can't help with that."} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "max_tokens routes to the parse-failure policy" do
      resp = text_response(:max_tokens, ~s({"chat_message": "trunca))

      assert %MultiField{chat_message: ~s({"chat_message": "trunca)} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "non-conforming content under :error policy returns an error tuple" do
      resp = text_response(:refusal, "nope")

      assert {:error, {:structured_output_incomplete, :refusal}} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{on_parse_failure: :error})
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/claudio_adapter_test.exs`
Expected: FAIL — `ClaudioAdapter.__handle_structured_response__/3` is undefined.

- [ ] **Step 3: Add the response interpreter (outer module)**

In `lib/normandy/llm/claudio_adapter.ex` outer module, add (it reuses `extract_content/1` from the retry fix, the configured JSON adapter, and the Phase-1 units):

```elixir
  @doc false
  def __handle_structured_response__(response, response_model, context) do
    content = extract_content(response)

    case Map.get(response, :stop_reason) do
      reason when reason in [:refusal, "refusal", :max_tokens, "max_tokens", :model_context_window_exceeded, "model_context_window_exceeded"] ->
        apply_parse_failure(response_model, content, {:structured_output_incomplete, reason}, context)

      _ ->
        adapter = Normandy.LLM.JsonDeserializer.get_json_adapter()

        with {:ok, parsed} when is_map(parsed) <- Normandy.LLM.Json.Decoder.decode(content, adapter, []),
             {:ok, bound} <- Normandy.LLM.Json.SchemaBinder.bind(parsed, response_model, content) do
          bound
        else
          _ -> apply_parse_failure(response_model, content, {:structured_output_unparseable, content}, context)
        end
    end
  end
```

> `Normandy.LLM.JsonDeserializer.get_json_adapter/0` is currently private. Make it public (`@doc false def get_json_adapter`) so the adapter can resolve the configured JSON adapter the same way — or, if you prefer not to touch it, inline `Application.get_env(:normandy, :adapter, Poison)` here with a brief comment. Pick one and note it in your report.

- [ ] **Step 4: Run the interpreter tests**

Run: `mix format && mix test test/llm/claudio_adapter_test.exs`
Expected: PASS.

- [ ] **Step 5: Route `do_converse/7` through the gate**

In the `defimpl`, split `do_converse/7` into a gate router + the existing legacy body. Rename the current `do_converse/7` body to `do_converse_legacy/7`, and make `do_converse/7` route:

```elixir
    defp do_converse(client, model, temperature, max_tokens, messages, response_model, opts) do
      case Normandy.LLM.StructuredOutputs.schema_for(client, response_model) do
        {:ok, json_schema} ->
          converse_structured(client, model, temperature, max_tokens, messages, response_model, opts, json_schema)

        :skip ->
          do_converse_legacy(client, model, temperature, max_tokens, messages, response_model, opts)
      end
    end

    defp do_converse_legacy(client, model, temperature, max_tokens, messages, response_model, opts) do
      # ... the EXISTING do_converse/7 body, verbatim (build request, Claudio.Messages.create,
      #     convert_response_to_normandy + extract_usage) ...
    end

    defp converse_structured(client, model, temperature, max_tokens, messages, response_model, opts, json_schema) do
      claudio_client = build_claudio_client(client)
      enable_caching = Map.get(client.options, :enable_caching, false)
      tools = Keyword.get(opts, :tools, [])
      mcp_servers = Keyword.get(opts, :mcp_servers, nil)

      request =
        Claudio.Messages.Request.new(model)
        |> add_temperature(temperature)
        |> add_max_tokens(max_tokens)
        |> add_messages(messages, enable_caching)
        |> add_tools(tools, enable_caching)
        |> add_mcp_servers(mcp_servers)
        |> add_client_options(client.options)
        |> Claudio.Messages.Request.set_output_format(json_schema)

      case Claudio.Messages.create(claudio_client, request) do
        {:ok, response} ->
          context = %{client: client, model: model, temperature: temperature, max_tokens: max_tokens, messages: messages, tools: tools}
          {Normandy.LLM.ClaudioAdapter.__handle_structured_response__(response, response_model, context),
           Normandy.LLM.ClaudioAdapter.extract_usage(response)}

        {:error, _error} ->
          do_converse_legacy(client, model, temperature, max_tokens, messages, response_model, opts)
      end
    end
```

- [ ] **Step 6: Run the file then the whole suite**

Run: `mix format && mix test test/llm/claudio_adapter_test.exs && mix test`
Expected: PASS (baseline + Task 5 tests, 0 failures). Default-on does not perturb the suite (no offline test drives `converse`/`Claudio.Messages.create`); the structured live wiring is exercised by the Phase 2 harness.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/llm/claudio_adapter.ex test/llm/claudio_adapter_test.exs
git commit -m "feat(llm): route ClaudioAdapter.converse through structured outputs with legacy fallback"
```

---

### Task 6: Consolidate the `base_agent` normalizer (must-verify)

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`normalize_model_response/1` at lines 1346-1350; its two call sites at lines 344-345)
- Test: `test/agents/base_agent_test.exs` (the existing base_agent test, if present) — rely on existing tests

**Interfaces:**
- Consumes: `Normandy.Agents.ConverseResult.normalize/1`.

- [ ] **Step 1: Read and confirm equivalence**

Read `lib/normandy/agents/base_agent.ex:1346-1350`:
```elixir
defp normalize_model_response({response, usage}) when is_map(usage) or is_nil(usage), do: {response, usage}
defp normalize_model_response(response), do: {response, nil}
```
Confirm `Normandy.Agents.ConverseResult.normalize/1` is behavior-equivalent for the inputs `base_agent` actually receives (a `{struct, map|nil}` tuple from `ClaudioAdapter`, or a bare struct from mock clients): both map `{struct, usage}`→`{struct, usage}`, bare struct→`{struct, nil}`. If you find an input shape `base_agent` handles that `ConverseResult.normalize/1` does not, STOP and report (per spec §9.5, defer the consolidation rather than force it).

- [ ] **Step 2: Swap the calls**

In `base_agent.ex`, replace the two call sites (lines 344-345):
```elixir
        {:ok, {:ok, response}} -> normalize_model_response(response)
        {:ok, response} -> normalize_model_response(response)
```
with:
```elixir
        {:ok, {:ok, response}} -> Normandy.Agents.ConverseResult.normalize(response)
        {:ok, response} -> Normandy.Agents.ConverseResult.normalize(response)
```
and DELETE the now-unused `defp normalize_model_response/1` (both clauses). Add `alias Normandy.Agents.ConverseResult` near the other aliases and use `ConverseResult.normalize(response)` if you prefer the alias form (pristine output — no unused alias).

- [ ] **Step 3: Run the base_agent test then the whole suite**

Run: `mix format && mix test test/agents/base_agent_test.exs && mix test`
Expected: PASS (same count, 0 failures — this is a behavior-preserving consolidation, no new tests). If any base_agent test fails, the swap was not equivalent — STOP and report.

- [ ] **Step 4: Commit**

```bash
git add lib/normandy/agents/base_agent.ex
git commit -m "refactor(agents): use ConverseResult.normalize as the single normalizer"
```

---

### Task 7: Final verification & docs

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex` (moduledoc: structured-outputs behavior + kill-switch)
- Modify: `CLAUDE.md` (note the structured-outputs default + config)

**Interfaces:** none new.

- [ ] **Step 1: Document the behavior**

Extend the `Normandy.LLM.ClaudioAdapter` `@moduledoc` to state: structured outputs are used by default (constrained decoding → schema-valid JSON, no parse-retry) when the model+schema support it; disable via `config :normandy, :structured_outputs, false` or `client.options[:structured_outputs]`; incompatible schemas (`open :map`, runaway nesting) and `refusal`/`max_tokens`/API-rejection fall back to the legacy parse-retry path. In `CLAUDE.md`, add a one-line note under Configuration: `:structured_outputs` (default `true`) toggles Anthropic native structured outputs.

- [ ] **Step 2: Full suite + formatter**

Run: `mix format && mix test`
Expected: PASS (baseline + all new tests from Tasks 1-5, 0 failures).

- [ ] **Step 3: Commit**

```bash
git add lib/normandy/llm/claudio_adapter.ex CLAUDE.md
git commit -m "docs(llm): document structured-outputs default and kill-switch"
```

---

## Self-Review

**Spec coverage:**
- §3.1 SchemaTranslator → Task 2. §3.2 StructuredOutputs gate → Task 3. §3.3 ClaudioAdapter routing → Task 5. §3.4 Decoder/SchemaBinder reuse → Task 5 (`__handle_structured_response__`). §3.5 base_agent consolidation → Task 6. §3.6 Claudio upgrade → Task 1.
- §4 translator detail → Task 2 (transform + open-object + depth-guard). §5 routing + 4 outcomes + `apply_parse_failure` → Task 4 (extract) + Task 5 (use). §6 error handling → Task 5 (API-error→legacy; refusal→policy). §7 testing → Tasks 2,3,5 (offline interpreter) + Task 6. §8 sequence → Tasks 1-7. §9 open questions → resolved in Global Constraints (verified facts).

**Placeholder scan:** all code steps show full code; "verbatim body" in Task 5 Step 5 names the exact rename (the existing `do_converse` body → `do_converse_legacy`); Task 1's `output_config` assertion has a note to pin whatever 0.6.0 actually emits. No TBD/TODO.

**Type consistency:** `SchemaTranslator.translate/1` `{:ok, map()} | {:incompatible, _}` (Task 2) consumed by `StructuredOutputs.schema_for/2` (Task 3), which returns `{:ok, map()} | :skip` consumed by `do_converse/7` routing (Task 5). `apply_parse_failure/4` (Task 4) consumed by `__handle_structured_response__/3` (Task 5). `extract_content/1`/`extract_usage/1` (retry fix, outer module) reused in Task 5. `ConverseResult.normalize/1` (retry fix) consumed in Task 6. All consistent.
