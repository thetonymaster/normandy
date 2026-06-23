# JsonDeserializer Refactor & Harden — Implementation Plan (Phase 1: Offline)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose `Normandy.LLM.JsonDeserializer` into a thin facade plus five focused units and apply four robustness hardening changes, without changing the public API.

**Architecture:** Characterization-tests-first. Lock current behavior, then extract leaf units bottom-up (Scanner, ContentCleaner) → mid-layers (Decoder, SchemaBinder, RetryFeedback), running the full suite green after each extraction. Only then apply the four hardening changes, each behind its own test, each off the happy path so the Poison default stays byte-identical.

**Tech Stack:** Elixir, ExUnit, Poison (configured JSON adapter), `:telemetry`.

**Scope note:** This is Phase 1 (offline, deterministic). The live smoke-test + prompt-tuning harness (`mix normandy.json_smoke`) is Phase 2 — a separate plan to be written after this one lands, because it depends on the `RetryFeedback` module produced here and its only TDD-able output (captured fixtures) cannot be authored until real failures are captured.

## Global Constraints

- **Public API frozen.** `JsonDeserializer.parse_and_validate/3` and `JsonDeserializer.deserialize_with_retry/8` keep exact signatures and all current return shapes: `{:ok, struct}`, `{:error, {:json_parse_error, reason, content}}`, `{:error, {:validation_error, changeset, content}}`, `{:error, {:max_retries_reached, reason}}`, `{:error, :llm_call_failed}`, `{:error, {:unexpected_parse_result, content}}`.
- **New modules live under `Normandy.LLM.Json.*`** in `lib/normandy/llm/json/`.
- **Run `mix format` before every test run** (project CLAUDE.md).
- **The full suite must be green at every checkpoint.** Any pre-existing failure gets fixed (project CLAUDE.md).
- **Hardening changes must not alter the Poison/default path** — assert that explicitly in each hardening task.
- **Default config:** `:adapter` is `Poison` (config/dev.exs, config/test.exs).

---

### Task 1: Shared test fixtures + characterization tests — pin current behavior

**Files:**
- Create: `test/support/json_test_fixtures.ex`
- Modify: `test/llm/json_deserializer_test.exs` (drop inline fixtures, re-alias, append characterization describe blocks)

**Interfaces:**
- Produces: `Normandy.LLM.Json.TestFixtures.{MultiField, RequiredField, RecoveryFixture}` — shared schema fixtures. `test/support` is already in `elixirc_paths(:test)` (mix.exs:188), so these structs compile for **every** test run, including single-file runs of the `Normandy.LLM.Json.*` unit tests in Tasks 5–7. Also a green characterization net asserting every current return shape, so later extraction tasks can prove no behavior change. RetryFeedback assertions check **structural invariants** — never verbatim feedback text — so Phase 2 can tune the prompt without rewriting tests.
- Consumes: existing public API `JsonDeserializer.parse_and_validate/3`, `JsonDeserializer.deserialize_with_retry/8`.

> **Why a support module (pre-flight finding):** the three fixtures are currently defined inline at the top of `test/llm/json_deserializer_test.exs` as `Normandy.LLM.JsonDeserializerTest.WrapperFixtures.*`. A single-file run (`mix test test/llm/json/<unit>_test.exs`) does **not** compile sibling test files, so any new unit-test file referencing those structs fails to compile (`MultiField.__struct__/1 is undefined`). Moving them to `test/support/` — compiled in `:test` for all runs — fixes this while preserving every existing test body.

- [ ] **Step 1: Create the shared fixtures support module**

Create `test/support/json_test_fixtures.ex`, moving the three schemas **verbatim** out of the inline `WrapperFixtures` module:

```elixir
defmodule Normandy.LLM.Json.TestFixtures do
  @moduledoc false

  defmodule MultiField do
    @moduledoc false
    use Normandy.Schema

    io_schema "multi-field schema for wrapper tests" do
      field(:chat_message, :string, description: "message")
      field(:count, :integer, description: "count", default: 0)
    end
  end

  defmodule RequiredField do
    @moduledoc false
    use Normandy.Schema

    io_schema "schema with a required field" do
      field(:chat_message, :string, description: "required message", required: true)
    end
  end

  defmodule RecoveryFixture do
    @moduledoc false
    use Normandy.Schema

    io_schema "fixture for truncated-string recovery tests" do
      field(:page_text, :string, description: "transcribed text", default: "")
      field(:facts, {:array, :string}, description: "facts", default: [])
    end
  end
end
```

- [ ] **Step 2: Re-point the existing test file at the shared module**

In `test/llm/json_deserializer_test.exs`, DELETE the inline `defmodule Normandy.LLM.JsonDeserializerTest.WrapperFixtures do ... end` block (currently lines 1-32, ending with the `end` just before `defmodule Normandy.LLM.JsonDeserializerTest do`), and replace the three `WrapperFixtures` aliases at the top of `Normandy.LLM.JsonDeserializerTest` with:

```elixir
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.Json.TestFixtures.RequiredField
  alias Normandy.LLM.Json.TestFixtures.RecoveryFixture
```

No test bodies change — `MultiField`, `RequiredField`, `RecoveryFixture` resolve to the same structs.

- [ ] **Step 3: Run the file to confirm the fixture move changed no behavior**

Run: `mix format && mix test test/llm/json_deserializer_test.exs`
Expected: PASS (identical results to before the move).

- [ ] **Step 4: Append characterization tests for the return shapes**

Append inside `defmodule Normandy.LLM.JsonDeserializerTest`:

```elixir
  describe "characterization — return shapes (parse_and_validate/3)" do
    test "valid JSON returns {:ok, struct}" do
      assert {:ok, %MultiField{chat_message: "hi", count: 0}} =
               JsonDeserializer.parse_and_validate(~s({"chat_message": "hi"}), %MultiField{})
    end

    test "unparseable content returns {:error, {:json_parse_error, reason, content}}" do
      assert {:error, {:json_parse_error, _reason, "not json"}} =
               JsonDeserializer.parse_and_validate("not json", %MultiField{})
    end

    test "missing required field returns {:error, {:validation_error, changeset, content}}" do
      content = ~s({"count": 5})

      assert {:error, {:validation_error, changeset, ^content}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})

      refute changeset.valid?
    end

    test "non-map top-level JSON returns an unexpected_parse_result tuple" do
      assert {:error, {:unexpected_parse_result, "[1, 2, 3]"}} =
               JsonDeserializer.parse_and_validate("[1, 2, 3]", %MultiField{})
    end
  end
```

> **Note (pre-flight finding):** `"[1, 2, 3]"` decodes to a **list**, which fails the `is_map(parsed)` guard in `parse_and_populate/4` (json_deserializer.ex:311) and falls through to the catch-all `{:error, {:unexpected_parse_result, content}}` branch (json_deserializer.ex:330) — verified against current code. The assertion pins that real behavior; it is **not** a `:json_parse_error`.

- [ ] **Step 5: Append a characterization test for RetryFeedback structural invariants**

The current feedback builder is private; the feedback string is only produced inside `deserialize_with_retry`'s retry path (which needs a live client). Pin it instead at the boundary we control: assert the validation-error changeset carries the field error that the feedback will format. Append:

```elixir
  describe "characterization — validation error detail is preserved" do
    test "changeset exposes the missing required field for feedback formatting" do
      assert {:error, {:validation_error, changeset, _}} =
               JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

      errors = Normandy.Validate.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      assert Map.has_key?(errors, :chat_message)
    end
  end
```

- [ ] **Step 6: Run the file, then the whole suite to capture the green baseline**

Run: `mix format && mix test test/llm/json_deserializer_test.exs && mix test`
Expected: PASS for both (record the whole-suite count; this is the baseline every later task must match or exceed).

- [ ] **Step 7: Commit**

```bash
git add test/support/json_test_fixtures.ex test/llm/json_deserializer_test.exs
git commit -m "test(llm): share JSON schema fixtures and pin JsonDeserializer return shapes"
```

---

### Task 2: Extract `Normandy.LLM.Json.Scanner`

**Files:**
- Create: `lib/normandy/llm/json/scanner.ex`
- Modify: `lib/normandy/llm/json_deserializer.ex` (remove moved fns; delegate)
- Test: `test/llm/json/scanner_test.exs`

**Interfaces:**
- Produces: `Normandy.LLM.Json.Scanner.recover_truncated_string(binary) :: {:ok, binary} | :error` — recovers an unclosed top-level string at depth 1 (the Nemotron-VL `page_text` case). Pure, zero project deps.
- Consumes: nothing.

- [ ] **Step 1: Write the failing unit test**

Create `test/llm/json/scanner_test.exs`:

```elixir
defmodule Normandy.LLM.Json.ScannerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.Scanner

  test "recovers an unclosed top-level string truncated at a \\n runaway" do
    truncated = ~s({"page_text": "hello world\\n\\n\\n)
    assert {:ok, recovered} = Scanner.recover_truncated_string(truncated)
    assert {:ok, %{"page_text" => "hello world"}} = Poison.decode(recovered)
  end

  test "recovers an immediately-truncated empty top-level string" do
    assert {:ok, recovered} = Scanner.recover_truncated_string(~s({"page_text": "))
    assert {:ok, %{"page_text" => ""}} = Poison.decode(recovered)
  end

  test "declines recovery for truncation inside a nested object" do
    assert :error = Scanner.recover_truncated_string(~s({"a": {"b": "oops\\n\\n))
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/json/scanner_test.exs`
Expected: FAIL — `Normandy.LLM.Json.Scanner` is undefined.

- [ ] **Step 3: Create the Scanner module by moving the byte-scanner verbatim**

Create `lib/normandy/llm/json/scanner.ex`. Move these private functions **verbatim** from `lib/normandy/llm/json_deserializer.ex`, making `recover_truncated_string/1` public (`def`), the rest private (`defp`): `recover_truncated_string/1`, every clause of `scan/7`, and `build_closers/1`. Wrap them:

```elixir
defmodule Normandy.LLM.Json.Scanner do
  @moduledoc """
  Byte-scanner recovery for a single JSON truncation failure mode:
  an unclosed top-level string at depth 1 (e.g. a vision worker's `page_text`
  payload that exhausts max_tokens mid-string). Pure; zero dependencies.
  """

  @doc """
  Attempt to recover a truncated payload. Returns `{:ok, recovered_string}`
  when the failure matches "unclosed top-level string at depth 1", else `:error`.
  """
  @spec recover_truncated_string(binary()) :: {:ok, binary()} | :error
  def recover_truncated_string(content) when is_binary(content) do
    # ... moved verbatim from json_deserializer.ex ...
  end

  # scan/7 clauses moved verbatim (defp)
  # build_closers/1 moved verbatim (defp)
end
```

- [ ] **Step 4: Run the Scanner unit test**

Run: `mix format && mix test test/llm/json/scanner_test.exs`
Expected: PASS.

- [ ] **Step 5: Point the deserializer at the Scanner and run the full suite**

In `lib/normandy/llm/json_deserializer.ex`, delete the moved `recover_truncated_string/1`, `scan/7`, and `build_closers/1`, and replace the call site in `decode_with_optional_recovery/3` to use `Normandy.LLM.Json.Scanner.recover_truncated_string(cleaned_content)`. Add `alias Normandy.LLM.Json.Scanner` and call `Scanner.recover_truncated_string/1`.

Run: `mix format && mix test`
Expected: PASS (baseline count from Task 1 Step 4, unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/scanner.ex lib/normandy/llm/json_deserializer.ex test/llm/json/scanner_test.exs
git commit -m "refactor(llm): extract truncated-string recovery into Json.Scanner"
```

---

### Task 3: Extract `Normandy.LLM.Json.ContentCleaner`

**Files:**
- Create: `lib/normandy/llm/json/content_cleaner.ex`
- Modify: `lib/normandy/llm/json_deserializer.ex`
- Test: `test/llm/json/content_cleaner_test.exs`

**Interfaces:**
- Produces: `ContentCleaner.clean(content) :: String.t() | term()` — fence-strip + trim (current behavior; non-binary passes through unchanged). Also stubs `ContentCleaner.extract_balanced/1` (real logic added in Task 9 hardening #3) so the module's public surface is fixed now.
- Consumes: nothing.

- [ ] **Step 1: Write the failing unit test for current cleaning behavior**

Create `test/llm/json/content_cleaner_test.exs`:

```elixir
defmodule Normandy.LLM.Json.ContentCleanerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.ContentCleaner

  test "strips a leading ```json fence and trailing fence" do
    assert ~s({"a": 1}) =
             ContentCleaner.clean("```json\n{\"a\": 1}\n```")
  end

  test "trims surrounding whitespace" do
    assert ~s({"a": 1}) = ContentCleaner.clean("   {\"a\": 1}   ")
  end

  test "passes non-binary content through unchanged" do
    assert %{a: 1} = ContentCleaner.clean(%{a: 1})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/json/content_cleaner_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the ContentCleaner by moving `clean_content/1` verbatim**

Create `lib/normandy/llm/json/content_cleaner.ex`. Move both `clean_content/1` clauses verbatim from the deserializer, renamed to `clean/1` and made public:

```elixir
defmodule Normandy.LLM.Json.ContentCleaner do
  @moduledoc """
  Cleans raw LLM output into a parseable JSON string: strips markdown code
  fences and trims. `extract_balanced/1` is the prose-extraction fallback
  (implemented in the hardening phase).
  """

  @doc "Strip code fences and trim. Non-binary content passes through unchanged."
  def clean(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n/, "")
    |> String.replace(~r/^```\n/, "")
    |> String.replace(~r/\n```$/, "")
    |> String.trim()
  end

  def clean(content), do: content

  @doc "Locate the outermost balanced JSON object/array within surrounding prose. Stub until hardening #3."
  @spec extract_balanced(binary()) :: {:ok, binary()} | :error
  def extract_balanced(content) when is_binary(content), do: :error
  def extract_balanced(_content), do: :error
end
```

- [ ] **Step 4: Run the unit test**

Run: `mix format && mix test test/llm/json/content_cleaner_test.exs`
Expected: PASS.

- [ ] **Step 5: Delegate from the deserializer and run the full suite**

In `lib/normandy/llm/json_deserializer.ex`, delete both `clean_content/1` clauses, add `alias Normandy.LLM.Json.ContentCleaner`, and in `parse_and_populate/4` replace `cleaned_content = clean_content(content)` with `cleaned_content = ContentCleaner.clean(content)`.

Run: `mix format && mix test`
Expected: PASS (baseline count unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/content_cleaner.ex lib/normandy/llm/json_deserializer.ex test/llm/json/content_cleaner_test.exs
git commit -m "refactor(llm): extract content cleaning into Json.ContentCleaner"
```

---

### Task 4: Extract `Normandy.LLM.Json.Decoder`

**Files:**
- Create: `lib/normandy/llm/json/decoder.ex`
- Modify: `lib/normandy/llm/json_deserializer.ex`
- Test: `test/llm/json/decoder_test.exs`

**Interfaces:**
- Consumes: `Scanner.recover_truncated_string/1`.
- Produces: `Decoder.decode(content, adapter, opts) :: {:ok, map()} | {:error, term()}` — runs `adapter.decode/1`; on failure, when `opts[:recover_truncated_strings]` is true and the content is a top-level object, retries once via Scanner recovery and emits `[:normandy, :json_deserializer, :recovery]` telemetry on success. (Input-size guard added in Task 8.)

- [ ] **Step 1: Write the failing unit test**

Create `test/llm/json/decoder_test.exs`:

```elixir
defmodule Normandy.LLM.Json.DecoderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.Decoder

  test "decodes valid JSON via the adapter" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), Poison, [])
  end

  test "returns the adapter error for invalid JSON" do
    assert {:error, _reason} = Decoder.decode("not json", Poison, [])
  end

  test "recovers a truncated top-level string when opt is enabled" do
    truncated = ~s({"page_text": "hello\\n\\n\\n)
    assert {:ok, %{"page_text" => "hello"}} =
             Decoder.decode(truncated, Poison, recover_truncated_strings: true)
  end

  test "without the opt, truncated content returns the adapter error" do
    truncated = ~s({"page_text": "hello\\n\\n\\n)
    assert {:error, _reason} = Decoder.decode(truncated, Poison, [])
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/json/decoder_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the Decoder by moving the recovery/decode helpers verbatim**

Create `lib/normandy/llm/json/decoder.ex`. Move `decode_with_optional_recovery/3`, `top_level_object?/1`, and `emit_recovery_telemetry/2` verbatim from the deserializer. Rename `decode_with_optional_recovery/3` to `decode/3` and make it public; have it call `Scanner.recover_truncated_string/1`:

```elixir
defmodule Normandy.LLM.Json.Decoder do
  @moduledoc """
  Decodes a cleaned JSON string via the configured adapter, with an optional
  one-shot truncated-string recovery pass (see Json.Scanner).
  """

  alias Normandy.LLM.Json.Scanner

  @spec decode(binary(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode(content, adapter, opts) do
    # body moved verbatim from decode_with_optional_recovery/3,
    # calling Scanner.recover_truncated_string/1
  end

  # top_level_object?/1 moved verbatim (defp)
  # emit_recovery_telemetry/2 moved verbatim (defp)
end
```

- [ ] **Step 4: Run the unit test**

Run: `mix format && mix test test/llm/json/decoder_test.exs`
Expected: PASS.

- [ ] **Step 5: Delegate from the deserializer and run the full suite**

In `lib/normandy/llm/json_deserializer.ex`: delete the three moved functions; add `alias Normandy.LLM.Json.Decoder`. In `parse_and_populate/4`, replace `case decode_with_optional_recovery(cleaned_content, adapter, opts) do` with `case Decoder.decode(cleaned_content, adapter, opts) do`. Remove the now-unused `Scanner` alias from the deserializer if nothing else references it.

Run: `mix format && mix test`
Expected: PASS (baseline count unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/decoder.ex lib/normandy/llm/json_deserializer.ex test/llm/json/decoder_test.exs
git commit -m "refactor(llm): extract adapter decode + recovery into Json.Decoder"
```

---

### Task 5: Extract `Normandy.LLM.Json.SchemaBinder`

**Files:**
- Create: `lib/normandy/llm/json/schema_binder.ex`
- Modify: `lib/normandy/llm/json_deserializer.ex`
- Test: `test/llm/json/schema_binder_test.exs`

**Interfaces:**
- Consumes: `Normandy.Validate`.
- Produces: `SchemaBinder.bind(parsed_map, schema, content) :: {:ok, struct()} | {:error, {:validation_error, changeset, content}}` — normalizes field names, casts against the schema, validates required fields, and unwraps a one-level `"arguments"` tool-use envelope. `content` is threaded only to populate the error tuple.

- [ ] **Step 1: Write the failing unit test**

Create `test/llm/json/schema_binder_test.exs`:

```elixir
defmodule Normandy.LLM.Json.SchemaBinderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.SchemaBinder
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.Json.TestFixtures.RequiredField

  test "binds a bare map to the schema" do
    assert {:ok, %MultiField{chat_message: "hi", count: 2}} =
             SchemaBinder.bind(%{"chat_message" => "hi", "count" => 2}, %MultiField{}, "src")
  end

  test "normalizes response/message/text to chat_message" do
    assert {:ok, %MultiField{chat_message: "yo"}} =
             SchemaBinder.bind(%{"response" => "yo"}, %MultiField{}, "src")
  end

  test "unwraps a tool-use arguments envelope" do
    assert {:ok, %MultiField{chat_message: "inner"}} =
             SchemaBinder.bind(%{"arguments" => %{"chat_message" => "inner"}}, %MultiField{}, "src")
  end

  test "surfaces a validation error tuple when a required field is missing" do
    assert {:error, {:validation_error, _changeset, "src"}} =
             SchemaBinder.bind(%{"count" => 1}, %RequiredField{}, "src")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/json/schema_binder_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the SchemaBinder by moving the cast/unwrap/normalize helpers verbatim**

Create `lib/normandy/llm/json/schema_binder.ex`. Move verbatim from the deserializer: `cast_map/5`, `maybe_unwrap_arguments/6`, `outer_eligible?/3`, `resolve_inner/5`, `all_defaults?/3`, `inner_targets_schema?/2`, `normalize_field_names/1`, `get_permitted_fields/1`, `get_required_fields/1`, `required_from_specification/1`. Add a public `bind/3` that reproduces the body of the current `parse_and_populate/4` from the point of a successful decode onward:

```elixir
defmodule Normandy.LLM.Json.SchemaBinder do
  @moduledoc """
  Binds a parsed JSON map to a Normandy schema: normalize field names, cast,
  validate required fields, and unwrap a one-level tool-use "arguments" envelope.
  """

  alias Normandy.Validate

  @spec bind(map(), struct(), binary()) :: {:ok, struct()} | {:error, term()}
  def bind(parsed, schema, content) when is_map(parsed) do
    permitted_fields = get_permitted_fields(schema)
    required_fields = get_required_fields(schema)
    outer = cast_map(parsed, schema, permitted_fields, required_fields, content)
    maybe_unwrap_arguments(outer, parsed, schema, permitted_fields, required_fields, content)
  end

  # cast_map/5, maybe_unwrap_arguments/6, outer_eligible?/3, resolve_inner/5,
  # all_defaults?/3, inner_targets_schema?/2, normalize_field_names/1,
  # get_permitted_fields/1, get_required_fields/1, required_from_specification/1
  # — all moved verbatim (defp)
end
```

- [ ] **Step 4: Run the unit test**

Run: `mix format && mix test test/llm/json/schema_binder_test.exs`
Expected: PASS.

- [ ] **Step 5: Delegate from the deserializer and run the full suite**

In `lib/normandy/llm/json_deserializer.ex`: delete the ten moved functions; add `alias Normandy.LLM.Json.SchemaBinder`. Rewrite `parse_and_populate/4` so the success branch delegates:

```elixir
  defp parse_and_populate(content, schema, adapter, opts) do
    cleaned_content = ContentCleaner.clean(content)

    case Decoder.decode(cleaned_content, adapter, opts) do
      {:ok, parsed} when is_map(parsed) ->
        SchemaBinder.bind(parsed, schema, content)

      {:error, reason} ->
        {:error, {:json_parse_error, reason, content}}

      _ ->
        {:error, {:unexpected_parse_result, content}}
    end
  end
```

Run: `mix format && mix test`
Expected: PASS (baseline count unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/schema_binder.ex lib/normandy/llm/json_deserializer.ex test/llm/json/schema_binder_test.exs
git commit -m "refactor(llm): extract schema binding into Json.SchemaBinder"
```

---

### Task 6: Extract `Normandy.LLM.Json.RetryFeedback`

**Files:**
- Create: `lib/normandy/llm/json/retry_feedback.ex`
- Modify: `lib/normandy/llm/json_deserializer.ex`
- Test: `test/llm/json/retry_feedback_test.exs`

**Interfaces:**
- Consumes: `Normandy.Validate`, `Normandy.Components.Message`. For now the encode stays on `Poison` (the adapter-consistency fix is Task 7).
- Produces:
  - `RetryFeedback.build(error, content, schema) :: String.t()`
  - `RetryFeedback.augment_messages(messages, feedback_string) :: [Message.t()]`

- [ ] **Step 1: Write the failing unit test (structural invariants only)**

Create `test/llm/json/retry_feedback_test.exs`:

```elixir
defmodule Normandy.LLM.Json.RetryFeedbackTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.Components.Message
  alias Normandy.LLM.Json.TestFixtures.RequiredField

  test "json_parse_error feedback contains the error and a correction instruction" do
    feedback = RetryFeedback.build({:json_parse_error, :invalid, "oops"}, "oops", %RequiredField{})
    assert feedback =~ "JSON"
    assert feedback =~ "valid JSON"
  end

  test "validation_error feedback names the offending field" do
    {:error, {:validation_error, changeset, content}} =
      Normandy.LLM.JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

    feedback = RetryFeedback.build({:validation_error, changeset, content}, content, %RequiredField{})
    assert feedback =~ "chat_message"
    assert feedback =~ "Required Schema"
  end

  test "augment_messages appends feedback to the system message only" do
    messages = [
      %Message{turn_id: "t", role: "system", content: "base"},
      %Message{turn_id: "t", role: "user", content: "hi"}
    ]

    [sys, user] = RetryFeedback.augment_messages(messages, "FEEDBACK")
    assert sys.content =~ "base"
    assert sys.content =~ "FEEDBACK"
    assert user.content == "hi"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/json/retry_feedback_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the RetryFeedback by moving the feedback builders verbatim**

Create `lib/normandy/llm/json/retry_feedback.ex`. Move verbatim from the deserializer: all three `build_error_feedback/3` clauses (rename the public entry to `build/3`), `format_validation_errors/1`, `format_json_error/1` (all clauses), and `augment_messages_with_error/2` (rename to `augment_messages/2`, make public):

```elixir
defmodule Normandy.LLM.Json.RetryFeedback do
  @moduledoc """
  Builds the corrective feedback appended to the system prompt on a JSON
  retry, and augments the message history with it.
  """

  alias Normandy.Components.Message
  alias Normandy.Validate

  @spec build(term(), binary(), struct()) :: String.t()
  def build(error, content, schema) do
    # three build_error_feedback/3 clauses, moved verbatim, head renamed to build/3
  end

  @spec augment_messages([Message.t()], String.t()) :: [Message.t()]
  def augment_messages(messages, feedback) do
    # augment_messages_with_error/2 body, moved verbatim
  end

  # format_validation_errors/1, format_json_error/1 — moved verbatim (defp)
end
```

- [ ] **Step 4: Run the unit test**

Run: `mix format && mix test test/llm/json/retry_feedback_test.exs`
Expected: PASS.

- [ ] **Step 5: Delegate from the deserializer and run the full suite**

In `lib/normandy/llm/json_deserializer.ex`: delete the moved functions; add `alias Normandy.LLM.Json.RetryFeedback`. In `retry_with_feedback/12`, replace `error_message = build_error_feedback(error, failed_content, schema)` with `error_message = RetryFeedback.build(error, failed_content, schema)`, and `augmented_messages = augment_messages_with_error(messages, error_message)` with `augmented_messages = RetryFeedback.augment_messages(messages, error_message)`. The `Message` alias may now be unused in the facade — remove it if so.

Run: `mix format && mix test`
Expected: PASS (baseline count unchanged). The facade is now thin: public API, `deserialize_loop/11`, `retry_with_feedback/12`, `parse_and_populate/4`, `extract_content_from_response/1`, `get_json_adapter/0`.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/retry_feedback.ex lib/normandy/llm/json_deserializer.ex test/llm/json/retry_feedback_test.exs
git commit -m "refactor(llm): extract retry feedback into Json.RetryFeedback"
```

---

### Task 7: Hardening #1 — adapter-consistent encode (RetryFeedback)

**Files:**
- Modify: `lib/normandy/llm/json/retry_feedback.ex`
- Modify: `lib/normandy/llm/json_deserializer.ex` (thread adapter to `RetryFeedback.build/4`)
- Test: `test/llm/json/retry_feedback_test.exs`

**Interfaces:**
- Produces (changed): `RetryFeedback.build(error, content, schema, adapter) :: String.t()` — encodes the schema spec via `adapter.encode!(spec, pretty: true)` instead of hardcoded `Poison.encode!/2`.

- [ ] **Step 1: Write the failing test proving the adapter is used**

Append to `test/llm/json/retry_feedback_test.exs`:

```elixir
  defmodule FakeAdapter do
    def encode!(_term, _opts), do: "<<ENCODED-BY-FAKE>>"
  end

  test "build/4 encodes the schema via the injected adapter" do
    feedback =
      RetryFeedback.build(
        {:json_parse_error, :invalid, "oops"},
        "oops",
        %RequiredField{},
        FakeAdapter
      )

    assert feedback =~ "<<ENCODED-BY-FAKE>>"
  end

  test "build/4 with Poison is byte-identical to the unchanged default path" do
    err = {:json_parse_error, :invalid, "oops"}
    assert RetryFeedback.build(err, "oops", %RequiredField{}, Poison) =~ "Required Schema"
  end
```

- [ ] **Step 2: Run to verify the first new test fails**

Run: `mix test test/llm/json/retry_feedback_test.exs`
Expected: FAIL — `build/4` undefined.

- [ ] **Step 3: Add the adapter parameter and use `adapter.encode!`**

In `lib/normandy/llm/json/retry_feedback.ex`, change the public head to `build(error, content, schema, adapter)`, thread `adapter` into both clauses that build a schema JSON, and replace each `Poison.encode!(schema.__struct__.__specification__(), pretty: true)` with `adapter.encode!(schema.__struct__.__specification__(), pretty: true)`. Keep the third (catch-all) clause's signature consistent by accepting and ignoring `adapter`:

```elixir
  def build({:validation_error, changeset, content}, _failed_content, schema, adapter) do
    schema_json = adapter.encode!(schema.__struct__.__specification__(), pretty: true)
    # ... rest unchanged ...
  end

  def build({:json_parse_error, reason, content}, _failed_content, schema, adapter) do
    schema_json = adapter.encode!(schema.__struct__.__specification__(), pretty: true)
    # ... rest unchanged ...
  end

  def build(reason, content, _schema, _adapter) do
    # ... catch-all unchanged ...
  end
```

Update the two earlier (Task 6) tests that call `build/3` to call `build/4` with `Poison` as the adapter.

- [ ] **Step 4: Thread the adapter from the facade**

In `lib/normandy/llm/json_deserializer.ex`, `retry_with_feedback/12` already has `adapter` in scope. Change the call to `RetryFeedback.build(error, failed_content, schema, adapter)`.

- [ ] **Step 5: Run unit tests then the full suite**

Run: `mix format && mix test test/llm/json/retry_feedback_test.exs && mix test`
Expected: PASS (baseline count unchanged; Poison path byte-identical).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/retry_feedback.ex lib/normandy/llm/json_deserializer.ex test/llm/json/retry_feedback_test.exs
git commit -m "fix(llm): encode retry-feedback schema via configured adapter, not hardcoded Poison"
```

---

### Task 8: Hardening #4 — input size guard (Decoder)

**Files:**
- Modify: `lib/normandy/llm/json/decoder.ex`
- Test: `test/llm/json/decoder_test.exs`

**Interfaces:**
- Produces (changed): `Decoder.decode/3` now checks `opts[:max_input_bytes]` (default `10_000_000`) before any decode; over-limit returns `{:error, {:input_too_large, byte_size, limit}}` (a new, additive error shape).

- [ ] **Step 1: Write the failing test**

Append to `test/llm/json/decoder_test.exs`:

```elixir
  test "rejects input larger than max_input_bytes with an explicit error" do
    big = "\"" <> String.duplicate("a", 50) <> "\""
    assert {:error, {:input_too_large, size, 10}} =
             Decoder.decode(big, Poison, max_input_bytes: 10)
    assert size > 10
  end

  test "uses a generous default limit that does not trip normal payloads" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), Poison, [])
  end
```

- [ ] **Step 2: Run to verify the first new test fails**

Run: `mix test test/llm/json/decoder_test.exs`
Expected: FAIL — large input currently decodes/erros without `:input_too_large`.

- [ ] **Step 3: Add the size guard at the top of `decode/3`**

In `lib/normandy/llm/json/decoder.ex`, add a module attribute and guard the entry:

```elixir
  @default_max_input_bytes 10_000_000

  def decode(content, adapter, opts) when is_binary(content) do
    limit = Keyword.get(opts, :max_input_bytes, @default_max_input_bytes)
    size = byte_size(content)

    if size > limit do
      {:error, {:input_too_large, size, limit}}
    else
      decode_inner(content, adapter, opts)
    end
  end
```

Rename the existing decode body to `decode_inner/3` (private).

- [ ] **Step 4: Run unit tests then the full suite**

Run: `mix format && mix test test/llm/json/decoder_test.exs && mix test`
Expected: PASS (baseline count unchanged — the default limit never trips existing tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/llm/json/decoder.ex test/llm/json/decoder_test.exs
git commit -m "feat(llm): add configurable max_input_bytes guard to Json.Decoder"
```

---

### Task 9: Hardening #3 — robust prose extraction (ContentCleaner + facade fallback)

**Files:**
- Modify: `lib/normandy/llm/json/content_cleaner.ex` (implement `extract_balanced/1`)
- Modify: `lib/normandy/llm/json_deserializer.ex` (`parse_and_populate/4` fallback)
- Test: `test/llm/json/content_cleaner_test.exs`, `test/llm/json_deserializer_test.exs`

**Interfaces:**
- Produces (real impl): `ContentCleaner.extract_balanced(content) :: {:ok, binary()} | :error` — returns the first outermost balanced `{...}` or `[...]` substring, string- and escape-aware. Used by the facade only after a strict decode fails, so the happy path is unchanged.

- [ ] **Step 1: Write the failing unit tests for extraction**

Append to `test/llm/json/content_cleaner_test.exs`:

```elixir
  test "extracts a balanced object embedded in prose" do
    input = ~s(Here's the JSON:\n{"a": 1}\nHope that helps!)
    assert {:ok, ~s({"a": 1})} = ContentCleaner.extract_balanced(input)
  end

  test "ignores braces inside strings when balancing" do
    input = ~s(text {"a": "}{"} more)
    assert {:ok, ~s({"a": "}{"})} = ContentCleaner.extract_balanced(input)
  end

  test "returns :error when no balanced object is present" do
    assert :error = ContentCleaner.extract_balanced("no json here")
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/llm/json/content_cleaner_test.exs`
Expected: FAIL — `extract_balanced/1` still returns `:error` (stub).

- [ ] **Step 3: Implement `extract_balanced/1`**

Replace the stub in `lib/normandy/llm/json/content_cleaner.ex` with a single-pass byte scan that finds the first `{` or `[`, then walks tracking string/escape state and a brace/bracket depth, returning the slice when depth returns to zero:

```elixir
  def extract_balanced(content) when is_binary(content) do
    case :binary.match(content, ["{", "["]) do
      {start, 1} ->
        opener = :binary.at(content, start)
        closer = if opener == ?{, do: ?}, else: ?]
        scan_balanced(content, start + 1, opener, closer, 1, false, false, start)

      :nomatch ->
        :error
    end
  end

  def extract_balanced(_content), do: :error

  # scan(content, pos, opener, closer, depth, in_string?, escape?, start)
  defp scan_balanced(content, pos, _opener, _closer, 0, _in_str, _esc, start) do
    {:ok, binary_part(content, start, pos - start)}
  end

  defp scan_balanced(content, pos, opener, closer, depth, in_str, esc, start)
       when pos < byte_size(content) do
    byte = :binary.at(content, pos)

    cond do
      in_str and esc ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, false, start)

      in_str and byte == ?\\ ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, true, start)

      in_str and byte == ?" ->
        scan_balanced(content, pos + 1, opener, closer, depth, false, false, start)

      in_str ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, false, start)

      byte == ?" ->
        scan_balanced(content, pos + 1, opener, closer, depth, true, false, start)

      byte == opener ->
        scan_balanced(content, pos + 1, opener, closer, depth + 1, false, false, start)

      byte == closer ->
        scan_balanced(content, pos + 1, opener, closer, depth - 1, false, false, start)

      true ->
        scan_balanced(content, pos + 1, opener, closer, depth, false, false, start)
    end
  end

  defp scan_balanced(_content, _pos, _opener, _closer, _depth, _in_str, _esc, _start), do: :error
```

- [ ] **Step 4: Run the unit tests**

Run: `mix format && mix test test/llm/json/content_cleaner_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the facade integration test, then wire the fallback**

Append to `test/llm/json_deserializer_test.exs`:

```elixir
  describe "hardening — prose-wrapped JSON extraction" do
    test "extracts and parses JSON wrapped in explanatory prose" do
      content = ~s(Sure! Here is the result:\n```json\n{"chat_message": "ok"}\n```\nLet me know!)

      assert {:ok, %MultiField{chat_message: "ok"}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "bare valid JSON is unaffected (happy path unchanged)" do
      assert {:ok, %MultiField{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(~s({"chat_message": "hi"}), %MultiField{})
    end
  end
```

Note: the example above already passes via fence-stripping; change the test's `content` to a case that fence-stripping alone does **not** fix, to actually exercise extraction:

```elixir
      content = ~s(Sure! Here is the result: {"chat_message": "ok"} — anything else?)
```

Then in `lib/normandy/llm/json_deserializer.ex`, change `parse_and_populate/4` so a failed decode attempts prose extraction once before giving up:

```elixir
  defp parse_and_populate(content, schema, adapter, opts) do
    cleaned_content = ContentCleaner.clean(content)

    case Decoder.decode(cleaned_content, adapter, opts) do
      {:ok, parsed} when is_map(parsed) ->
        SchemaBinder.bind(parsed, schema, content)

      {:error, reason} ->
        case ContentCleaner.extract_balanced(cleaned_content) do
          {:ok, extracted} ->
            case Decoder.decode(extracted, adapter, opts) do
              {:ok, parsed} when is_map(parsed) -> SchemaBinder.bind(parsed, schema, content)
              _ -> {:error, {:json_parse_error, reason, content}}
            end

          :error ->
            {:error, {:json_parse_error, reason, content}}
        end

      _ ->
        {:error, {:unexpected_parse_result, content}}
    end
  end
```

- [ ] **Step 6: Run the facade test then the full suite**

Run: `mix format && mix test test/llm/json_deserializer_test.exs && mix test`
Expected: PASS (all prior shapes preserved; prose case now recovers).

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/llm/json/content_cleaner.ex lib/normandy/llm/json_deserializer.ex test/llm/json/content_cleaner_test.exs test/llm/json_deserializer_test.exs
git commit -m "feat(llm): recover JSON embedded in surrounding prose as a parse fallback"
```

---

### Task 10: Hardening #2 — configurable `:on_parse_failure` (claudio_adapter)

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`populate_standard_schema/3` around line 819-856)
- Test: `test/llm/claudio_adapter_test.exs`

**Interfaces:**
- Consumes: app config `Application.get_env(:normandy, :on_parse_failure, :fallback)`, overridable via `context[:on_parse_failure]`.
- Produces: parse-failure policy at the integration boundary — `:fallback` (default) still returns `Map.put(schema, :chat_message, content)` but first emits `Logger.warning` + `[:normandy, :json_deserializer, :fallback]` telemetry; `:error` returns the raw `{:error, reason}`.

- [ ] **Step 1: Read the current call site**

Run: `grep -n "populate_standard_schema" lib/normandy/llm/claudio_adapter.ex`
Expected: the `defp populate_standard_schema(schema, content, context)` at ~line 819 and its `{:error, _reason}` fallback branches at ~850-855.

- [ ] **Step 2: Write the failing test for the `:error` policy**

Append to `test/llm/claudio_adapter_test.exs` (a unit test that drives `populate_standard_schema` indirectly is awkward because it's private and calls the LLM; instead test the policy resolver directly). Add a small public helper to keep the test deterministic — in `claudio_adapter.ex` add:

```elixir
    @doc false
    def __on_parse_failure_policy__(context),
      do: Map.get(context, :on_parse_failure) ||
            Application.get_env(:normandy, :on_parse_failure, :fallback)
```

Then the test:

```elixir
  describe "on_parse_failure policy" do
    test "defaults to :fallback" do
      assert :fallback = Normandy.LLM.ClaudioAdapter.__on_parse_failure_policy__(%{})
    end

    test "honors a per-call override" do
      assert :error =
               Normandy.LLM.ClaudioAdapter.__on_parse_failure_policy__(%{on_parse_failure: :error})
    end
  end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/llm/claudio_adapter_test.exs`
Expected: FAIL — `__on_parse_failure_policy__/1` undefined.

- [ ] **Step 4: Implement the policy and branch the fallback**

Add `require Logger` near the top of the `Normandy.Agents.Model` impl module if not present. Add the `__on_parse_failure_policy__/1` helper from Step 2. Then change the failure branches of `populate_standard_schema/3`:

```elixir
        {:error, reason} ->
          case __on_parse_failure_policy__(context) do
            :error ->
              {:error, reason}

            :fallback when is_binary(content) ->
              Logger.warning(
                "JSON parse failed after retries; falling back to raw text. reason=#{inspect(reason)}"
              )

              :telemetry.execute(
                [:normandy, :json_deserializer, :fallback],
                %{count: 1},
                %{reason: reason}
              )

              Map.put(schema, :chat_message, content)

            :fallback ->
              Logger.warning(
                "JSON parse failed after retries; returning schema unchanged. reason=#{inspect(reason)}"
              )

              :telemetry.execute(
                [:normandy, :json_deserializer, :fallback],
                %{count: 1},
                %{reason: reason}
              )

              schema
          end
```

This collapses the two prior `{:error, _reason}` branches into one policy-aware branch. Note `context` must carry `:on_parse_failure` — it is passed through unchanged from the caller; no other call site needs to change since the key is optional.

- [ ] **Step 5: Run unit tests then the full suite**

Run: `mix format && mix test test/llm/claudio_adapter_test.exs && mix test`
Expected: PASS (default `:fallback` keeps existing behavior; new policy tests green).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/claudio_adapter.ex test/llm/claudio_adapter_test.exs
git commit -m "feat(llm): make post-retry parse-failure policy configurable and observable"
```

---

### Task 11: Final verification & docs

**Files:**
- Modify: `lib/normandy/llm/json_deserializer.ex` (moduledoc: document the new layout + new opts)

**Interfaces:** none new.

- [ ] **Step 1: Update the facade moduledoc**

In `lib/normandy/llm/json_deserializer.ex`, extend the `@moduledoc` to (a) list the five units and their responsibilities, and (b) document the new options `:max_input_bytes` (default 10_000_000) and the `:on_parse_failure` config (`:fallback | :error`, default `:fallback`). Keep existing option docs.

- [ ] **Step 2: Run the full suite and formatter**

Run: `mix format && mix test`
Expected: PASS (baseline count plus all new unit + hardening tests).

- [ ] **Step 3: Confirm the facade is thin**

Run: `wc -l lib/normandy/llm/json_deserializer.ex lib/normandy/llm/json/*.ex`
Expected: the facade is materially smaller than the original 825 lines; logic now lives in the five `json/` units.

- [ ] **Step 4: Commit**

```bash
git add lib/normandy/llm/json_deserializer.ex
git commit -m "docs(llm): document JsonDeserializer module layout and new options"
```

---

## Self-Review

**Spec coverage:**
- §3 module layout → Tasks 2–6 (Scanner, ContentCleaner, Decoder, SchemaBinder, RetryFeedback) + facade thinning.
- §4 #1 adapter consistency → Task 7.
- §4 #2 configurable `:on_parse_failure` → Task 10.
- §4 #3 robust prose extraction → Task 9.
- §4 #4 resource guard → Task 8.
- §5 characterization-first + structural RetryFeedback invariants → Task 1 + Task 6 test design.
- §6 live harness → **Phase 2, deliberately out of this plan** (documented at top).
- §7 sequence → Tasks 1→11 mirror steps 1→11.

**Placeholder scan:** "move verbatim" instructions name the exact functions to relocate (they already exist in the source file and are reproduced/renamed only where their head changes); all new logic (extract_balanced, size guard, policy branch, adapter encode) is shown in full. No TBD/TODO.

**Type consistency:** `Decoder.decode/3`, `SchemaBinder.bind/3`, `RetryFeedback.build/3`→`build/4` (Task 7), `RetryFeedback.augment_messages/2`, `ContentCleaner.clean/1` + `extract_balanced/1`, `Scanner.recover_truncated_string/1` are used consistently across tasks. The one signature change (`build/3`→`build/4`) is explicitly handled in Task 7 Step 3 (update Task 6 callers).
