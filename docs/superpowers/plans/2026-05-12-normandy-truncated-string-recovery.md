# Normandy 0.6.3 — `JsonDeserializer` Truncated-String Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `:recover_truncated_strings` option to `Normandy.LLM.JsonDeserializer` that recovers from one specific failure mode — vision-model responses where a single top-level JSON string field is unclosed at EOF because the model emitted a runaway of `\n` escape sequences and ran out of output tokens — by truncating at a safe boundary, closing the string, and balancing the brace stack.

**Architecture:** Thread an `opts` keyword list down to the internal `parse_and_populate` (currently passes only `adapter`). On adapter decode failure, when `:recover_truncated_strings` is true AND the cleaned content starts with `{` AND a single-pass byte scanner determines the failure is "unclosed top-level string at depth 1 at EOF," produce a recovered string by truncating at the last position whose preceding byte sequence was not part of a `\n` escape, appending `"`, and appending closers (`}` / `]`) in reverse stack order. Re-decode and run through the existing cast pipeline. Emit `[:normandy, :json_deserializer, :recovery]` telemetry on successful recovery. Default off; pre-existing behavior preserved for every shape the suite already covers.

**Tech Stack:** Elixir 1.15+, ExUnit, `:telemetry` (already a dep), Poison (Jason-compatible adapter; tests use `adapter: Poison`).

## Scope

**In scope (this plan, this repo):** Surface 3 from `2026-05-12-vision-page-text-truncation-hardening.md` — the Normandy 0.6.3 patch release.

**Out of scope (separate work in `event_crew` sibling repo, after 0.6.3 publishes):** Surface 1 (vision-worker `stop: ["\n\n\n"]` request param) and Surface 2 (prompt tightening in `ExtractionPrompts`). These ship in the wedding-bot repo against the bumped dep.

## File map

| File | Action | Responsibility |
|---|---|---|
| `lib/normandy/llm/json_deserializer.ex` | Modify | Refactor `parse_and_populate/3` → `/4`. Add `decode_with_optional_recovery/3`, `recover_truncated_string/1`, scanner clauses, telemetry emit. |
| `test/llm/json_deserializer_test.exs` | Modify | Add fixture schemas + `describe "recover_truncated_strings option"` block. |
| `mix.exs` | Modify | Bump `@version "0.6.2"` → `"0.6.3"`. |
| `CHANGELOG.md` | Modify | Add `## [0.6.3] - 2026-05-12` section under `## [Unreleased]`. |

Net implementation size budget: ≤120 LOC in `json_deserializer.ex` (per design doc). Tests are separate from that budget.

## Pre-flight (do once at the start of execution)

- [ ] **Confirm baseline tests are green before touching anything.**

  Run: `mix test test/llm/json_deserializer_test.exs`
  Expected: all tests pass. If anything is red, STOP and surface to user — the plan assumes a clean baseline.

- [ ] **Confirm `mix format --check-formatted` passes.**

  Run: `mix format --check-formatted`
  Expected: exit 0, no output. If anything's mis-formatted, run `mix format` and commit separately before proceeding (existing-code hygiene, not part of this plan).

---

### Task 1: Plumb opts through `parse_and_populate` (refactor, no behavior change)

**Why first:** `parse_and_populate/3` currently takes `(content, schema, adapter)` — the third positional arg is the adapter, not opts. Subsequent tasks need to read `:recover_truncated_strings` from opts inside this function. Doing the refactor in isolation keeps the behavior-change task in Task 2 small and reviewable.

**Files:**
- Modify: `lib/normandy/llm/json_deserializer.ex:102` (the `parse_and_validate/3` body)
- Modify: `lib/normandy/llm/json_deserializer.ex:182-191` (the max-retries-reached `deserialize_loop` clause — bind currently-underscored `_opts`)
- Modify: `lib/normandy/llm/json_deserializer.ex:206` (the recursive `deserialize_loop` clause — already binds `opts`)
- Modify: `lib/normandy/llm/json_deserializer.ex:290` (the `parse_and_populate/3` definition)

- [ ] **Step 1: Update `parse_and_validate/3` to pass opts to `parse_and_populate`.**

  Edit `lib/normandy/llm/json_deserializer.ex:100-103`. Replace:

  ```elixir
  def parse_and_validate(content, schema, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, get_json_adapter())
    parse_and_populate(content, schema, adapter)
  end
  ```

  With:

  ```elixir
  def parse_and_validate(content, schema, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, get_json_adapter())
    parse_and_populate(content, schema, adapter, opts)
  end
  ```

- [ ] **Step 2: Un-underscore `_opts` and forward it in the max-retries `deserialize_loop` clause.**

  Edit `lib/normandy/llm/json_deserializer.ex:169-191`. Replace:

  ```elixir
  defp deserialize_loop(
         content,
         schema,
         _client,
         _model,
         _temperature,
         _max_tokens,
         _messages,
         _opts,
         adapter,
         attempt,
         max_retries
       )
       when attempt >= max_retries do
    # Max retries reached, attempt final parse and return result
    case parse_and_populate(content, schema, adapter) do
      {:ok, populated_schema} ->
        {:ok, populated_schema}

      {:error, reason} ->
        {:error, {:max_retries_reached, reason}}
    end
  end
  ```

  With:

  ```elixir
  defp deserialize_loop(
         content,
         schema,
         _client,
         _model,
         _temperature,
         _max_tokens,
         _messages,
         opts,
         adapter,
         attempt,
         max_retries
       )
       when attempt >= max_retries do
    # Max retries reached, attempt final parse and return result
    case parse_and_populate(content, schema, adapter, opts) do
      {:ok, populated_schema} ->
        {:ok, populated_schema}

      {:error, reason} ->
        {:error, {:max_retries_reached, reason}}
    end
  end
  ```

- [ ] **Step 3: Forward opts in the recursive `deserialize_loop` clause.**

  Edit `lib/normandy/llm/json_deserializer.ex:206`. Replace the single line:

  ```elixir
    case parse_and_populate(content, schema, adapter) do
  ```

  With:

  ```elixir
    case parse_and_populate(content, schema, adapter, opts) do
  ```

- [ ] **Step 4: Update the `parse_and_populate` definition to take a fourth arg.**

  Edit `lib/normandy/llm/json_deserializer.ex:289-290`. Replace:

  ```elixir
    # Parse JSON and validate using Normandy.Validate
    defp parse_and_populate(content, schema, adapter) do
  ```

  With:

  ```elixir
    # Parse JSON and validate using Normandy.Validate
    defp parse_and_populate(content, schema, adapter, _opts) do
  ```

  (Leading underscore on `_opts` because nothing uses it yet — Task 2 will un-underscore it.)

- [ ] **Step 5: Run the existing deserializer suite to confirm refactor is behavior-preserving.**

  Run: `mix test test/llm/json_deserializer_test.exs`
  Expected: all tests pass with the same count as the pre-flight run. No new failures, no skipped tests.

- [ ] **Step 6: Format and commit.**

  Run:

  ```bash
  mix format lib/normandy/llm/json_deserializer.ex
  git add lib/normandy/llm/json_deserializer.ex
  git commit -m "refactor(llm): thread opts through parse_and_populate"
  ```

---

### Task 2: Add scanner + recovery hook, gated by `:recover_truncated_strings` opt (TDD: happy path first)

**Why now:** This is the load-bearing behavior change. Writing the simplest passing test first forces the implementation to handle the canonical case (`page_text` unclosed at EOF with `\n` runaway tail) before anything else.

**Files:**
- Modify: `test/llm/json_deserializer_test.exs` (add fixture + first test)
- Modify: `lib/normandy/llm/json_deserializer.ex` (add `decode_with_optional_recovery/3`, `recover_truncated_string/1`, scanner clauses, integrate into `parse_and_populate/4`)

- [ ] **Step 1: Add a fixture schema for recovery tests at the top of the test file.**

  Edit `test/llm/json_deserializer_test.exs:1-22` (the `WrapperFixtures` module). Add a third fixture module inside the `defmodule Normandy.LLM.JsonDeserializerTest.WrapperFixtures do` block, after the `RequiredField` definition (around line 21, just before the closing `end` of `WrapperFixtures`):

  ```elixir
    defmodule RecoveryFixture do
      @moduledoc false
      use Normandy.Schema

      io_schema "fixture for truncated-string recovery tests" do
        field(:page_text, :string, description: "transcribed text", default: "")
        field(:facts, {:array, :string}, description: "facts", default: [])
      end
    end
  ```

- [ ] **Step 2: Add an alias for the new fixture at the top of the test module.**

  Edit `test/llm/json_deserializer_test.exs:30` (after the existing `alias` for `RequiredField`). Add:

  ```elixir
    alias Normandy.LLM.JsonDeserializerTest.WrapperFixtures.RecoveryFixture
  ```

- [ ] **Step 3: Add the first failing recovery test as a new `describe` block.**

  Append a new `describe` block before the final `end` of the test module (i.e., before line 395 `end` of `defmodule Normandy.LLM.JsonDeserializerTest do`):

  ```elixir
    describe "parse_and_validate/3 — :recover_truncated_strings option" do
      test "recovers a top-level string field truncated at a \\n-escape runaway" do
        # Bytes: { " p a g e _ t e x t " :   " h e l l o   w o r l d \ n \ n \ n \ n
        # No closing " and no closing }. The trailing \n sequences are the model
        # runaway; recovery should truncate at the last position before the runaway,
        # close the string, and close the object.
        truncated = ~s({"page_text": "hello world\\n\\n\\n\\n)

        assert {:ok, %RecoveryFixture{page_text: "hello world"}} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison,
                   recover_truncated_strings: true
                 )
      end
    end
  ```

- [ ] **Step 4: Run the new test to confirm it fails for the expected reason.**

  Run: `mix test test/llm/json_deserializer_test.exs -t describe:"parse_and_validate/3 — :recover_truncated_strings option"`

  (Or, simpler: run the file and look for the new test.)

  Run: `mix test test/llm/json_deserializer_test.exs`

  Expected: the new test fails. The failure mode should be `{:error, {:json_parse_error, ...}}` (because recovery doesn't exist yet — the opt is ignored). If the test fails for any *other* reason (compile error, fixture not found, wrong assertion), STOP and fix the test before implementing the scanner.

- [ ] **Step 5: Un-underscore `_opts` in `parse_and_populate/4` and route the decode through the new recovery helper.**

  Edit `lib/normandy/llm/json_deserializer.ex:290-318` (the entire `parse_and_populate/4` function plus the `clean_content` flow). Replace the whole function body:

  ```elixir
    # Parse JSON and validate using Normandy.Validate
    defp parse_and_populate(content, schema, adapter, _opts) do
      # Clean content (remove markdown code fences, etc.)
      cleaned_content = clean_content(content)

      # Try to parse JSON
      case adapter.decode(cleaned_content) do
        {:ok, parsed} when is_map(parsed) ->
          permitted_fields = get_permitted_fields(schema)
          required_fields = get_required_fields(schema)

          outer = cast_map(parsed, schema, permitted_fields, required_fields, content)

          maybe_unwrap_arguments(
            outer,
            parsed,
            schema,
            permitted_fields,
            required_fields,
            content
          )

        {:error, reason} ->
          # JSON parse failed
          {:error, {:json_parse_error, reason, content}}

        _ ->
          {:error, {:unexpected_parse_result, content}}
      end
    end
  ```

  With:

  ```elixir
    # Parse JSON and validate using Normandy.Validate
    defp parse_and_populate(content, schema, adapter, opts) do
      # Clean content (remove markdown code fences, etc.)
      cleaned_content = clean_content(content)

      case decode_with_optional_recovery(cleaned_content, adapter, opts) do
        {:ok, parsed} when is_map(parsed) ->
          permitted_fields = get_permitted_fields(schema)
          required_fields = get_required_fields(schema)

          outer = cast_map(parsed, schema, permitted_fields, required_fields, content)

          maybe_unwrap_arguments(
            outer,
            parsed,
            schema,
            permitted_fields,
            required_fields,
            content
          )

        {:error, reason} ->
          # JSON parse failed
          {:error, {:json_parse_error, reason, content}}

        _ ->
          {:error, {:unexpected_parse_result, content}}
      end
    end
  ```

- [ ] **Step 6: Add `decode_with_optional_recovery/3` immediately below `parse_and_populate/4`.**

  Insert into `lib/normandy/llm/json_deserializer.ex` right after the closing `end` of `parse_and_populate/4`:

  ```elixir
    # Decode JSON, optionally retrying once via truncated-string recovery.
    #
    # When :recover_truncated_strings is true AND the cleaned content looks like a
    # single top-level object AND the strict decode fails AND the failure mode is
    # "unclosed top-level string at depth 1 with a \n-escape runaway tail" (as
    # determined by recover_truncated_string/1), we synthesize a closing quote and
    # balance the brace stack, then re-decode once. On success we emit a recovery
    # telemetry event. On any failure we return the original adapter error so the
    # caller's existing {:json_parse_error, _, _} contract is preserved.
    defp decode_with_optional_recovery(cleaned_content, adapter, opts) do
      case adapter.decode(cleaned_content) do
        {:ok, parsed} ->
          {:ok, parsed}

        {:error, _reason} = original_error ->
          with true <- Keyword.get(opts, :recover_truncated_strings, false),
               true <- top_level_object?(cleaned_content),
               {:ok, recovered} <- recover_truncated_string(cleaned_content),
               {:ok, parsed} <- adapter.decode(recovered) do
            emit_recovery_telemetry(byte_size(cleaned_content), byte_size(recovered))
            {:ok, parsed}
          else
            _ -> original_error
          end
      end
    end

    defp top_level_object?(content) when is_binary(content) do
      case String.trim_leading(content) do
        "{" <> _ -> true
        _ -> false
      end
    end

    defp emit_recovery_telemetry(byte_size_before, byte_size_after) do
      :telemetry.execute(
        [:normandy, :json_deserializer, :recovery],
        %{recovered: 1},
        %{
          strategy: :truncated_string,
          byte_size_before: byte_size_before,
          byte_size_after: byte_size_after
        }
      )
    end
  ```

  (`emit_recovery_telemetry/2` is added here even though Task 4 has the test for it — keeping the helper colocated with the call site is cleaner than splitting across tasks. The test in Task 4 just verifies it fires.)

- [ ] **Step 7: Add `recover_truncated_string/1` and the byte-walking scanner clauses.**

  Append below the helpers added in Step 6:

  ```elixir
    # Attempt to recover a truncated JSON payload whose failure mode is "unclosed
    # top-level string at depth 1 with a \n-escape runaway tail" (Nemotron-VL
    # vision worker page_text case). Returns {:ok, recovered_string} on success
    # or :error if the truncation doesn't match this specific shape.
    #
    # Algorithm:
    #   1. Single-pass byte scan tracking a stack of :object/:array opens, an
    #      in_string flag, and a "safe_until" byte index — the byte index just
    #      past the most recent character that is NOT part of a \n escape
    #      sequence and is inside the currently-open string at depth 1.
    #   2. At EOF, recover iff in_string AND opener_depth == 1 AND safe_until
    #      is set AND the stack is non-empty.
    #   3. Recovered string = first safe_until bytes of input + "\"" + closers
    #      derived from the stack (head = innermost, so reverse for output is
    #      not needed — head is the LAST opened container, which closes FIRST).
    defp recover_truncated_string(content) when is_binary(content) do
      case scan(content, 0, [], false, false, nil, nil, nil) do
        {:unclosed_top_level_string, safe_until, stack}
        when is_integer(safe_until) and stack != [] ->
          prefix = binary_part(content, 0, safe_until)
          {:ok, prefix <> "\"" <> build_closers(stack)}

        _ ->
          :error
      end
    end

    # scan(rest, pos, stack, in_string?, escape_pending?, opener_depth, safe_until, prev_escape_was_n?)
    #
    # stack head = innermost open container. List head close char closes the
    # innermost open first — exactly the order JSON needs.
    #
    # escape_pending? is true for exactly one byte: the byte immediately after a
    # \ inside a string. That byte is consumed unconditionally.
    #
    # safe_until is updated only inside the string opened at depth 1, and only
    # for characters that are not part of a \n escape sequence. It marks the
    # byte position just past the last "safe to truncate after" character.
    #
    # prev_escape_was_n is plumbed only for clarity; it isn't read again — the
    # safe_until logic handles it inline. (Left as the trailing arg so future
    # tweaks can use it without re-shaping the function signature.)

    # EOF inside an unclosed string at depth-1 opener with at least one safe
    # boundary recorded → recovery possible.
    defp scan(<<>>, _pos, stack, true, _esc, 1, safe_until, _prev_n)
         when is_integer(safe_until) and stack != [] do
      {:unclosed_top_level_string, safe_until, stack}
    end

    # EOF in any other state → no recovery.
    defp scan(<<>>, _pos, _stack, _in_string, _esc, _opener_depth, _safe_until, _prev_n) do
      :no_recovery
    end

    # Inside string, escape pending: consume the escaped byte. If it is "n" (or
    # "r"), it is part of a runaway sequence — do NOT advance safe_until. For
    # every other escape (\" \\ \t \b \f \/ \uXXXX), the escape represents a
    # legitimate character — advance safe_until past the two bytes.
    defp scan(<<byte, rest::binary>>, pos, stack, true, true, opener_depth, safe_until, _prev_n) do
      new_safe_until =
        cond do
          opener_depth != 1 -> safe_until
          byte == ?n or byte == ?r -> safe_until
          true -> pos + 1
        end

      scan(rest, pos + 1, stack, true, false, opener_depth, new_safe_until, byte == ?n)
    end

    # Inside string, backslash starts an escape — next byte handled by the
    # escape_pending? clause above.
    defp scan(<<?\\, rest::binary>>, pos, stack, true, false, opener_depth, safe_until, prev_n) do
      scan(rest, pos + 1, stack, true, true, opener_depth, safe_until, prev_n)
    end

    # Inside string, closing unescaped quote: exit string, reset opener tracking.
    defp scan(<<?", rest::binary>>, pos, stack, true, false, _opener_depth, _safe_until, _prev_n) do
      scan(rest, pos + 1, stack, false, false, nil, nil, false)
    end

    # Inside string, any other byte (including literal \n, \r — which JSON
    # technically forbids unescaped, but we don't reject; the surrounding decode
    # will). Advance safe_until only at depth 1.
    defp scan(<<_byte, rest::binary>>, pos, stack, true, false, opener_depth, safe_until, _prev_n) do
      new_safe_until = if opener_depth == 1, do: pos + 1, else: safe_until
      scan(rest, pos + 1, stack, true, false, opener_depth, new_safe_until, false)
    end

    # Outside string, opening quote: enter string. opener_depth = current stack
    # depth. Initialize safe_until at the byte AFTER the opener so an immediately
    # truncated empty string `{"k": "` recovers to {"k": ""}.
    defp scan(<<?", rest::binary>>, pos, stack, false, _esc, _opener_depth, _safe_until, _prev_n) do
      depth = length(stack)
      initial_safe_until = if depth == 1, do: pos + 1, else: nil
      scan(rest, pos + 1, stack, true, false, depth, initial_safe_until, false)
    end

    # Outside string, object/array openers push onto the stack.
    defp scan(<<?{, rest::binary>>, pos, stack, false, _esc, opener_depth, safe_until, prev_n) do
      scan(rest, pos + 1, [:object | stack], false, false, opener_depth, safe_until, prev_n)
    end

    defp scan(<<?[, rest::binary>>, pos, stack, false, _esc, opener_depth, safe_until, prev_n) do
      scan(rest, pos + 1, [:array | stack], false, false, opener_depth, safe_until, prev_n)
    end

    # Outside string, matching closers pop the stack. Mismatches fall through to
    # the catch-all below, which keeps walking; the surrounding decode will have
    # already failed for the right reason if the input is malformed in a way the
    # scanner can't help with.
    defp scan(<<?}, rest::binary>>, pos, [:object | tail], false, _esc, opener_depth, safe_until, prev_n) do
      scan(rest, pos + 1, tail, false, false, opener_depth, safe_until, prev_n)
    end

    defp scan(<<?], rest::binary>>, pos, [:array | tail], false, _esc, opener_depth, safe_until, prev_n) do
      scan(rest, pos + 1, tail, false, false, opener_depth, safe_until, prev_n)
    end

    # Outside string, any other byte (whitespace, structural chars like : , ,
    # mismatched closers): walk on. We don't validate structure; that's the
    # adapter's job. We only need enough state to know "are we inside a top-level
    # string at EOF, and where's the last safe byte."
    defp scan(<<_byte, rest::binary>>, pos, stack, false, _esc, opener_depth, safe_until, prev_n) do
      scan(rest, pos + 1, stack, false, false, opener_depth, safe_until, prev_n)
    end

    # Build the closer string for a stack. Head of stack = innermost open =
    # closes first.
    defp build_closers(stack) do
      stack
      |> Enum.map(fn
        :object -> "}"
        :array -> "]"
      end)
      |> Enum.join("")
    end
  ```

- [ ] **Step 8: Run the new test from Step 3 to confirm it now passes.**

  Run: `mix test test/llm/json_deserializer_test.exs`

  Expected: the recovery test from Step 3 passes. All pre-existing tests still pass (the new code path is gated behind the opt, default off, and only activates on adapter decode failure — so existing tests are not on the recovery path).

  If pre-existing tests fail, STOP — the refactor in Task 1 or the routing change in Step 5 has a regression. Do not proceed to Step 9.

- [ ] **Step 9: Format and commit.**

  Run:

  ```bash
  mix format lib/normandy/llm/json_deserializer.ex test/llm/json_deserializer_test.exs
  git add lib/normandy/llm/json_deserializer.ex test/llm/json_deserializer_test.exs
  git commit -m "feat(llm): add :recover_truncated_strings option to JsonDeserializer"
  ```

---

### Task 3: Add boundary/edge-case tests (no-recover when nested, empty-string recovery, regression guard)

**Why now:** The scanner already handles these cases in code (Task 2's implementation has the `opener_depth == 1` gate and initializes `safe_until` for empty strings). This task locks the behavior in with explicit tests so a future refactor can't silently regress them.

**Files:**
- Modify: `test/llm/json_deserializer_test.exs` (append tests to the `describe` block added in Task 2)

- [ ] **Step 1: Add a regression-guard test that recovery is OFF by default.**

  Append inside the `describe "parse_and_validate/3 — :recover_truncated_strings option" do` block:

  ```elixir
      test "default-off: truncated content returns the original parse error" do
        truncated = ~s({"page_text": "hello\\n\\n\\n)

        assert {:error, {:json_parse_error, _, _}} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison
                 )
      end

      test "explicit false: truncated content returns the original parse error" do
        truncated = ~s({"page_text": "hello\\n\\n\\n)

        assert {:error, {:json_parse_error, _, _}} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison,
                   recover_truncated_strings: false
                 )
      end
  ```

- [ ] **Step 2: Add a test that recovery declines for truncation inside a nested object/array.**

  Append inside the same `describe` block:

  ```elixir
      test "declines recovery when truncation is inside a nested object" do
        # Truncation is in an inner object's string value (offerings[0].name).
        # opener_depth at EOF is 3 (outer object, array, inner object) — recovery
        # must not fire here, because manufacturing a closer would produce a
        # half-truthful inner record rather than an empty top-level field.
        truncated = ~s({"offerings": [{"name": "Paq)

        assert {:error, {:json_parse_error, _, _}} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison,
                   recover_truncated_strings: true
                 )
      end

      test "declines recovery when truncation is inside a top-level array element string" do
        # Same shape: the inner string lives at depth 2 (object → array → string).
        truncated = ~s({"facts": ["fact one", "fact tw)

        assert {:error, {:json_parse_error, _, _}} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison,
                   recover_truncated_strings: true
                 )
      end
  ```

- [ ] **Step 3: Add a test that an immediately-truncated empty top-level string recovers to "".**

  Append inside the same `describe` block:

  ```elixir
      test "recovers an immediately-truncated empty top-level string to \"\"" do
        # The model emitted the opening quote of page_text and ran out of tokens
        # right there. Recovery should produce an empty string for page_text
        # rather than giving up.
        truncated = ~s({"page_text": ")

        assert {:ok, %RecoveryFixture{page_text: ""}} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison,
                   recover_truncated_strings: true
                 )
      end
  ```

- [ ] **Step 4: Add a test that valid JSON with the flag on passes through unchanged.**

  Append inside the same `describe` block:

  ```elixir
      test "valid JSON with recover_truncated_strings: true behaves exactly as without" do
        valid = ~s({"page_text": "complete", "facts": ["a", "b"]})

        with_flag =
          JsonDeserializer.parse_and_validate(
            valid,
            %RecoveryFixture{},
            adapter: Poison,
            recover_truncated_strings: true
          )

        without_flag =
          JsonDeserializer.parse_and_validate(
            valid,
            %RecoveryFixture{},
            adapter: Poison
          )

        assert {:ok, %RecoveryFixture{page_text: "complete", facts: ["a", "b"]}} = with_flag
        assert with_flag == without_flag
      end
  ```

- [ ] **Step 5: Add a test that the multi-field, page-text-last shape from the captured fixture recovers correctly.**

  Append inside the same `describe` block. This is the closest in-suite analogue of the `lanativa_mixologia` failure mode:

  ```elixir
      test "recovers the page_text-last shape from the captured Nemotron-VL fixture" do
        # Mirrors the captured fixture: facts populated, page_text opens, model
        # emits some real prose, then runs away with \n escapes and EOFs without
        # closing the string or the outer object. Recovery must:
        #   * keep facts populated;
        #   * truncate page_text at the last non-\n-escape position;
        #   * close the string and the outer object.
        truncated =
          ~s({"facts": ["Mixology", "Premium Bar"], "page_text": "NATIVA MIXOLOGY\\n\\n\\n\\n\\n\\n\\n\\n)

        assert {:ok,
                %RecoveryFixture{
                  page_text: "NATIVA MIXOLOGY",
                  facts: ["Mixology", "Premium Bar"]
                }} =
                 JsonDeserializer.parse_and_validate(
                   truncated,
                   %RecoveryFixture{},
                   adapter: Poison,
                   recover_truncated_strings: true
                 )
      end
  ```

- [ ] **Step 6: Run the full deserializer suite to confirm all five new tests pass.**

  Run: `mix test test/llm/json_deserializer_test.exs`

  Expected: every test in the file passes. The recovery `describe` block now has six tests (one from Task 2 + five from this task).

  If any test fails, STOP. Most likely culprit: the `safe_until` logic in the scanner mis-handles a byte. Read the scanner clauses in Task 2 Step 7 again with the failing input in mind before patching.

- [ ] **Step 7: Format and commit.**

  Run:

  ```bash
  mix format test/llm/json_deserializer_test.exs
  git add test/llm/json_deserializer_test.exs
  git commit -m "test(llm): cover edge cases for truncated-string recovery"
  ```

---

### Task 4: Verify telemetry emission with a test

**Why now:** The `emit_recovery_telemetry/2` helper was added in Task 2 Step 6 (colocated with its call site). This task adds the test that proves it fires with the right name, measurements, and metadata. Splitting the test from the implementation here is fine because the helper is small and obviously correct; the test is value-add, not gating.

**Files:**
- Modify: `test/llm/json_deserializer_test.exs` (one more test in the same `describe` block)

- [ ] **Step 1: Add the telemetry test.**

  Append inside the `describe "parse_and_validate/3 — :recover_truncated_strings option" do` block:

  ```elixir
      test "emits [:normandy, :json_deserializer, :recovery] on successful recovery" do
        handler_id = "recovery-telemetry-test-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:normandy, :json_deserializer, :recovery],
          fn name, measurements, metadata, %{test_pid: pid} ->
            send(pid, {:telemetry, name, measurements, metadata})
          end,
          %{test_pid: test_pid}
        )

        try do
          truncated = ~s({"page_text": "hello world\\n\\n\\n)

          {:ok, _} =
            JsonDeserializer.parse_and_validate(
              truncated,
              %RecoveryFixture{},
              adapter: Poison,
              recover_truncated_strings: true
            )

          assert_received {:telemetry, [:normandy, :json_deserializer, :recovery],
                           %{recovered: 1},
                           %{
                             strategy: :truncated_string,
                             byte_size_before: before,
                             byte_size_after: after_
                           }}

          assert is_integer(before) and before > 0
          assert is_integer(after_) and after_ > 0
          # Recovery may produce a slightly smaller payload (runaway bytes dropped,
          # `"` + `}` appended); strictness here would over-couple the test to the
          # exact scanner output, so we just assert both sizes are sane.
        after
          :telemetry.detach(handler_id)
        end
      end

      test "does not emit recovery telemetry when recovery did not fire" do
        handler_id = "recovery-telemetry-negative-test-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:normandy, :json_deserializer, :recovery],
          fn name, measurements, metadata, %{test_pid: pid} ->
            send(pid, {:telemetry, name, measurements, metadata})
          end,
          %{test_pid: test_pid}
        )

        try do
          valid = ~s({"page_text": "complete"})

          {:ok, _} =
            JsonDeserializer.parse_and_validate(
              valid,
              %RecoveryFixture{},
              adapter: Poison,
              recover_truncated_strings: true
            )

          refute_received {:telemetry, _, _, _}
        after
          :telemetry.detach(handler_id)
        end
      end
  ```

- [ ] **Step 2: Run the telemetry tests.**

  Run: `mix test test/llm/json_deserializer_test.exs`

  Expected: both new tests pass alongside the rest of the suite. If the positive test fails with "did not receive telemetry," verify that `emit_recovery_telemetry/2` is being called inside the `with` block in `decode_with_optional_recovery/3` (Task 2 Step 6).

- [ ] **Step 3: Format and commit.**

  Run:

  ```bash
  mix format test/llm/json_deserializer_test.exs
  git add test/llm/json_deserializer_test.exs
  git commit -m "test(llm): assert recovery telemetry fires on successful truncated-string recovery"
  ```

---

### Task 5: Run the full suite + verify LOC budget

**Why now:** Before bumping version, confirm no other module broke and the implementation respects the design's ≤120 LOC budget for `json_deserializer.ex` net additions.

- [ ] **Step 1: Run the full project test suite.**

  Run: `mix test`

  Expected: every test in the project passes. If any test outside `test/llm/json_deserializer_test.exs` fails, STOP and investigate — the refactor in Task 1 may have leaked a behavior change that other callers depend on.

- [ ] **Step 2: Confirm the LOC budget.**

  Run:

  ```bash
  git diff main -- lib/normandy/llm/json_deserializer.ex | grep -E "^\+" | grep -v "^+++" | wc -l
  ```

  Expected: ≤ 120 lines added (per the design doc's stated budget). If significantly over, surface to user before proceeding — likely indicates the scanner grew complexity beyond what the failure mode warrants.

- [ ] **Step 3: Confirm formatting and run dialyzer (if configured).**

  Run: `mix format --check-formatted`
  Expected: exit 0, no output.

  Run: `mix dialyzer` (only if it usually runs in this project; otherwise skip)
  Expected: no new warnings on the modified module. If dialyzer flags `scan/8` clauses for unmatched returns, double-check that every clause head matches a reachable input and that the `:no_recovery` atom is consistently returned by the catch-all EOF clause.

---

### Task 6: Bump version + CHANGELOG entry

**Why last:** Version bump and CHANGELOG are user-visible release artifacts; they should reference the merged-and-tested state of the code, not be set in advance.

**Files:**
- Modify: `mix.exs:4`
- Modify: `CHANGELOG.md:8` (the `## [Unreleased]` section — replace with the new release header and add the entry)

- [ ] **Step 1: Bump `@version` in `mix.exs`.**

  Edit `mix.exs:4`. Replace:

  ```elixir
    @version "0.6.2"
  ```

  With:

  ```elixir
    @version "0.6.3"
  ```

- [ ] **Step 2: Add the 0.6.3 entry to `CHANGELOG.md`.**

  Edit `CHANGELOG.md`. After the line `## [Unreleased]` (line 8) and the blank line below it, insert a new release section. The end state of lines 8–11 should be:

  ```markdown
  ## [Unreleased]

  ## [0.6.3] - 2026-05-12

  ### Added

  - **`Normandy.LLM.JsonDeserializer` now supports opt-in recovery from a
    specific truncated-JSON failure mode**: when an LLM (notably
    Nemotron-Nano-12B-VL on DigitalOcean Inference) emits a response that
    ends inside an unclosed top-level string field — typically because the
    model entered a `\n`-escape runaway and ran out of output tokens —
    `parse_and_validate/3` and `deserialize_with_retry/8` now accept
    `recover_truncated_strings: true`. When the flag is on AND the strict
    decode fails AND the content looks like a single top-level object AND a
    byte scanner determines the unclosed string is at the outermost depth,
    Normandy truncates the string at the last position whose preceding
    bytes were not part of a `\n` escape, appends a closing `"`, and
    appends `}`/`]` closers derived from a tracked open-container stack.
    The recovered payload is re-decoded once through the adapter and run
    through the same cast pipeline as the happy path; a
    `[:normandy, :json_deserializer, :recovery]` telemetry event is
    emitted on success with `%{recovered: 1}` measurements and
    `%{strategy: :truncated_string, byte_size_before: _, byte_size_after: _}`
    metadata. Default is `false` — pre-existing callers see no behaviour
    change. Designed for vision-pipeline `page_text` transcription
    payloads where the alternative is an empty `%Output{}` and zero RAG
    indexing on customer-grade documents; not a general-purpose JSON
    repair. Nested-string truncation (e.g. `{"offerings":[{"name":"Paq`)
    explicitly does NOT recover, since manufacturing a closer there would
    produce a half-truthful inner record rather than empty top-level data.
  ```

  (Mirror the verbose-but-precise tone of the existing 0.6.2 entry above it; keep the `## [Unreleased]` heading at the top so future work has a place to land.)

- [ ] **Step 3: Run `mix compile` and the full suite one more time.**

  Run: `mix compile && mix test`
  Expected: clean compile (no warnings on the modified module), every test passes.

- [ ] **Step 4: Format and commit the release artifacts.**

  Run:

  ```bash
  mix format
  git add mix.exs CHANGELOG.md
  git commit -m "chore(release): cut v0.6.3"
  ```

  (Do NOT tag yet. Tagging and publishing to Hex is a separate user-driven step that happens after the PR merges to main, mirroring the v0.6.2 release flow.)

---

## Post-implementation handoff notes

After this plan is fully executed and merged:

1. **The wedding-bot follow-up PR (separate plan, sibling repo) can then:**
   - Bump `{:normandy, "~> 0.6.3"}` in `event_crew`'s `mix.exs` once 0.6.3 publishes to Hex.
   - Pass `recover_truncated_strings: true` at the `JsonDeserializer.parse_and_validate/3` call site in `Pipeline.ExtractOfferings.Vision`.
   - Add the stop-sequence + prompt-tightening (surfaces 1+2) per the design doc.

2. **Monitoring after rollout:** The `[:normandy, :json_deserializer, :recovery]` event lets downstream operators see how often recovery fires in prod. If it fires on inputs that surface as "wrong" populated offerings — i.e., recovery misfired on a non-truncation parse error — that's the signal to tighten the heuristic (e.g., require `\n`-runaway detection, not just unclosed string at depth 1).

3. **If `mix dialyzer` is run as part of CI:** the new `scan/8` clauses use binary pattern matching with `_byte` catch-alls. If dialyzer reports overlap warnings between clauses (e.g., the catch-all in-string clause vs the `\\`, `"`, etc. clauses), the order is intentional — Elixir tries clauses top-down, and the specific patterns are listed before the catch-all. No reordering needed.
