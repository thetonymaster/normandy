# Normandy 2.0 Pre-Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every 2.0 blocker and land every accepted breaking change from the pre-2.0 audit, so Normandy 2.0 can be published to Hex.

**Architecture:** Seven sequential waves on `feat/claudio-0.7-migration`. Each wave ends green on `mix precommit` and is committed task by task. Wave 1 is specified to code level here. Waves 2–7 are specified to task, file, interface and acceptance-test level. Each one gets a code-level plan (`plan-wave-N.md`) written just before it starts, because each wave rewrites interfaces the next one builds on (the Model protocol in Wave 2, the config shape in Wave 3).

**Tech Stack:** Elixir ~> 1.15, ExUnit + StreamData, Claudio (Anthropic client), NimbleOptions (new in Wave 3), telemetry, OpenTelemetry API.

**Spec:** `investigations/pre-2.0-audit/decisions.md` (settled decisions; do not re-ask). Evidence and finding IDs: `consolidated.md`, `release.md`, `security.md`, `telemetry.md`, `perf.md`, `devex.md`, `agentx.md` in the same directory.

## Global Constraints

- Elixir `~> 1.15`; CI matrix Elixir 1.15–1.19 on OTP 26–28. Anything newer than 1.15 needs a guard or a different approach.
- Each wave ends with `mix precommit` exiting 0 (`compile --warnings-as-errors`, `deps.unlock --check-unused`, `format`, `credo --strict`, `dialyzer`, `test`). Run `mix format` before tests. Gate on the literal ` 0 failures`, never on `| tail` output.
- Credo: stock `.credo.exs`. A complexity or nesting finding gets an inline `# credo:disable-for-next-line`, never a threshold change.
- Dialyzer: a new entry in `.dialyzer_ignore.exs` needs a reason comment.
- Every emitted telemetry event must be documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs` enforces it).
- A new Turn core effect must be wired into **all three** interpreters: `Turn.Driver`, `Turn.Inline`, `Turn.Server`.
- No silent fallbacks (`|| default`, `rescue _ ->`) that turn a hard failure into wrong data. Error messages say what was expected and what was received.
- Commits: conventional messages; add files individually (`git add .` is forbidden); no AI attribution lines (Q's global rule overrides the session default). Do not merge or push the branch: it stays unmerged until 2.0 is complete.
- If a test fails, fix it, even when it isn't in the task's scope.

## Review Focus

Five inputs that the decisions imply but no single task's happy-path tests cover. Each line names the task that owns its test.

1. **A session persisted under 1.x and rebuilt under 2.0** (`ConfigTemplate.rebuild/3`, with `max_tokens: nil`, a stored breaker pid, or old tool structs). Expect either a loaded config with 2.0 defaults or an `ArgumentError` naming the field and the migration step, never a crash deep in a turn. Tests: Task 1.3 (`max_tokens: nil`), Task 4.1 (breaker), Task 3.4 (tool structs).
2. **A non-chat `output_schema` whose final answer arrives on the fallback path** (structured outputs disabled, or the schema rejected). Expect a parsed output struct or `{:error, %Normandy.Schema.ValidationError{}}`, never a raw `%ToolCallResponse{}`. Test: Task 5.1.
3. **A 429 after tools already ran, under `Turn.Server`.** Expect the caller to get `{:error, %LLMError{type: :rate_limit}}`, and the persisted turn state and telemetry metadata to hold no stacktrace. Test: Task 2.3.
4. **A shared breaker (one per client and model) whose half-open probe process is killed.** Expect the other agents on that key to get a new probe after `reset_timeout`, without calling `reset/1`. Test: Task 4.1.
5. **A tool result over the 100_000-char cap that ends in multibyte UTF-8.** Expect truncation on a grapheme boundary, valid UTF-8, and the truncation note appended. Test: Task 5.4.

---
## Wave 1 — Blockers and quick non-breaking fixes

Findings: REL-2, TEL-1, DX-1/AX-2, DX-12, REL-6, REL-8, DX-9, DX-10 (root module only), REL LOW (package hygiene). Out of scope here: anything Wave 2+ rewrites (README `run` shape, docs groups for renamed modules, output validation result).

### Task 1.1: `mix docs --warnings-as-errors` passes (REL-2)

**Files:**
- Modify: `lib/normandy/telemetry.ex:438` (moduledoc, Known limits)
- Modify: `lib/normandy/mcp/tool_wrapper.ex:33` (moduledoc, Trace context)
- Modify: `lib/normandy/hooks/handlers.ex:6` (moduledoc)
- Modify: `mix.exs:68` (remove `Normandy.Agents.IOModel`, a module that does not exist)

**Interfaces:** none (docs only).

- [ ] **Step 1: Reproduce the failure**

Run: `mix docs --warnings-as-errors 2>&1 | grep -E "warning|error" | head`
Expected: three warnings: two for `Claudio.MCP.Client.call_tool/4` (a callback, so the ref needs `c:`) and one for the hidden `Normandy.Hooks.ServerGlue`.

- [ ] **Step 2: Fix the two callback refs**

In both `lib/normandy/telemetry.ex:438` and `lib/normandy/mcp/tool_wrapper.ex:33`, replace `` `Claudio.MCP.Client.call_tool/4` `` with `` `c:Claudio.MCP.Client.call_tool/4` ``.

- [ ] **Step 3: Stop linking the hidden module**

In `lib/normandy/hooks/handlers.ex`, change
```
  keeps its set unwrapped and, in `Normandy.Hooks.ServerGlue`, wraps a copy whose
```
to
```
  keeps its set unwrapped and, in its internal hook glue, wraps a copy whose
```

- [ ] **Step 4: Remove the nonexistent module from the docs groups**

In `mix.exs`, delete the line `Normandy.Agents.IOModel,` from the `Agents:` group. (The full regrouping is Task 7.2, after the Wave 3 renames.)

- [ ] **Step 5: Verify**

Run: `mix docs --warnings-as-errors`
Expected: exit 0, no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/telemetry.ex lib/normandy/mcp/tool_wrapper.ex lib/normandy/hooks/handlers.ex mix.exs
git commit -m "docs: fix broken callback and hidden-module refs so docs build with warnings-as-errors"
```

### Task 1.2: Require telemetry 1.3+ (TEL-1)

`lib/normandy/tools/memory.ex:143` returns `{result, measurements, metadata}` from `:telemetry.span/3`, which telemetry only accepts from 1.3.0 (deps/telemetry/CHANGELOG.md, "1.3.0 … Ability to return extra measurements from telemetry:span/3"). `~> 1.0` lets a consumer resolve 1.0–1.2 and crash on every memory command.

**Files:**
- Modify: `mix.exs:165`

- [ ] **Step 1: Tighten the requirement**

```elixir
      {:telemetry, "~> 1.3"},
```

- [ ] **Step 2: Verify the lock still satisfies it**

Run: `mix deps.get && mix deps.unlock --check-unused && grep '"telemetry"' mix.lock`
Expected: exit 0; lock still at `1.4.2` (no change to `mix.lock`).

- [ ] **Step 3: Commit**

```bash
git add mix.exs
git commit -m "fix(deps): require telemetry ~> 1.3 for span measurement returns"
```

### Task 1.3: Default `max_tokens` to 16_000 (DX-1 / AX-2)

`init/1` defaults `max_tokens` to `nil`. `add_max_tokens(request, nil)` (`lib/normandy/llm/claudio_adapter.ex:573`) leaves the key out, and the Messages API requires it, so the README quickstart's first `run/2` gets a 400. Decision 10: one default of 16_000 for `init/1`, the DSL, and template rebuilds.

**Files:**
- Modify: `lib/normandy/agents/base_agent_config.ex:24,59`
- Modify: `lib/normandy/agents/base_agent.ex:154` (and a new private helper)
- Modify: `lib/normandy/agents/config_template.ex:149`
- Modify: `lib/normandy/dsl/agent.ex:18,42,105,472`
- Modify: `test/agents/base_agent_test.exs:33`
- Create: `test/agents/base_agent_max_tokens_test.exs`

**Interfaces:**
- Produces: `Normandy.Agents.BaseAgentConfig.default_max_tokens/0 :: pos_integer()` (returns `16_000`). Wave 3's NimbleOptions schema uses it as the `:max_tokens` default.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/base_agent_max_tokens_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentMaxTokensTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate}

  defmodule CapturingClient do
    defstruct [:pid]

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(client, _model, _temperature, max_tokens, _messages, response_model, _opts) do
        send(client.pid, {:max_tokens, max_tokens})

        if Map.has_key?(response_model, :chat_message),
          do: %{response_model | chat_message: "ok"},
          else: response_model
      end
    end
  end

  defp init(extra \\ %{}) do
    BaseAgent.init(Map.merge(%{client: %CapturingClient{pid: self()}, model: "m"}, extra))
  end

  test "default_max_tokens/0 is 16_000" do
    assert BaseAgentConfig.default_max_tokens() == 16_000
  end

  test "init/1 without :max_tokens uses the default" do
    assert init().max_tokens == 16_000
  end

  test "the default reaches the client on run/2" do
    BaseAgent.run(init(), %{chat_message: "hi"})
    assert_receive {:max_tokens, 16_000}
  end

  test "an explicit :max_tokens is kept" do
    assert init(%{max_tokens: 2048}).max_tokens == 2048
  end

  test "an explicit nil or non-positive :max_tokens raises with the expected type" do
    for bad <- [nil, 0, -1, "4096"] do
      assert_raise ArgumentError, ~r/:max_tokens must be a positive integer.*got: #{Regex.escape(inspect(bad))}/, fn ->
        init(%{max_tokens: bad})
      end
    end
  end

  test "a 1.x template with max_tokens: nil rebuilds with the default" do
    config = init(%{max_tokens: 100})

    supp = %{
      tool_registry: %Normandy.Tools.Registry{tools: %{}},
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token -> %CapturingClient{pid: self()} end
    }

    tmpl = config |> ConfigTemplate.from_config("t") |> Map.put(:max_tokens, nil)

    assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").max_tokens == 16_000
  end

  defmodule DefaultDSLAgent do
    use Normandy.DSL.Agent

    agent do
      model("m")
    end
  end

  test "a DSL agent without max_tokens uses the same default" do
    {:ok, agent} = DefaultDSLAgent.new(client: %CapturingClient{pid: self()})
    assert agent.max_tokens == 16_000
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/base_agent_max_tokens_test.exs`
Expected: FAIL. `default_max_tokens/0` is undefined; the others see `nil` or `4096`.

- [ ] **Step 3: Add the default to `BaseAgentConfig`**

In `lib/normandy/agents/base_agent_config.ex`, above the schema:

```elixir
  # The Messages API requires max_tokens; a nil here would drop the key and
  # every request would get a 400.
  @default_max_tokens 16_000

  @doc "The `max_tokens` used when a config sets none: #{@default_max_tokens}."
  @spec default_max_tokens() :: pos_integer()
  def default_max_tokens, do: @default_max_tokens
```

Change the field to `field(:max_tokens, :integer, default: @default_max_tokens)` and the type at line 24 from `pos_integer() | nil` to `pos_integer()`.

- [ ] **Step 4: Validate in `init/1`**

In `lib/normandy/agents/base_agent.ex:154`, replace `max_tokens: Map.get(config, :max_tokens, nil),` with `max_tokens: max_tokens!(config),` and add:

```elixir
  defp max_tokens!(config) do
    case Map.fetch(config, :max_tokens) do
      :error ->
        BaseAgentConfig.default_max_tokens()

      {:ok, n} when is_integer(n) and n > 0 ->
        n

      {:ok, other} ->
        raise ArgumentError,
              "Normandy.Agents.BaseAgent.init/1: :max_tokens must be a positive integer " <>
                "(the Messages API requires it), got: #{inspect(other)}. Omit it to use " <>
                "the default of #{BaseAgentConfig.default_max_tokens()}."
    end
  end
```

- [ ] **Step 5: Default in template rebuilds**

In `lib/normandy/agents/config_template.ex:149`:

```elixir
      # Templates saved by 1.x store nil for an unset max_tokens; 2.0 sends the default.
      max_tokens: tmpl.max_tokens || BaseAgentConfig.default_max_tokens(),
```

- [ ] **Step 6: Use the same default in the DSL**

In `lib/normandy/dsl/agent.ex:472`, replace `4096` with `Normandy.Agents.BaseAgentConfig.default_max_tokens()`. Update the docs at lines 18, 42 and 105 to say `16_000` (line 105: ``- `max_tokens` - Maximum tokens in response (default: 16_000)``).

- [ ] **Step 7: Update the old assertion**

In `test/agents/base_agent_test.exs:33`, change `== nil` to `== 16_000`.

- [ ] **Step 8: Run the new and affected tests**

Run: `mix test test/agents/base_agent_max_tokens_test.exs test/agents/base_agent_test.exs test/agents/config_template_test.exs test/dsl/agent_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 9: Run the full suite**

Run: `mix test 2>&1 | tail -3`
Expected: ` 0 failures`. Any test asserting `max_tokens: nil` or `4096` as a default gets updated to `16_000`. A test that expects the key to be absent from a request is a real behaviour change: list it in the commit body.

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/agents/base_agent_config.ex lib/normandy/agents/base_agent.ex lib/normandy/agents/config_template.ex lib/normandy/dsl/agent.ex test/agents/base_agent_test.exs test/agents/base_agent_max_tokens_test.exs
git commit -m "fix(agent): default max_tokens to 16_000 so requests always carry it"
```

### Task 1.4: Reject typos in the default input schema (DX-12)

`validation_middleware.ex:80-83` skips validation for `BaseAgentInputSchema` and builds it with `struct/2`, which drops unknown keys. `%{chat_mesage: "hi"}` therefore sends a nil user message with no error. A binary input (`run(agent, "hi")`) is out of scope here; it lands with the new `run/3` in Task 2.4.

**Files:**
- Modify: `lib/normandy/agents/validation_middleware.ex:80-83` (and a new private helper)
- Test: `test/agents/validation_middleware_test.exs`

**Interfaces:**
- Produces: `validate_input/2` returns `{:error, [%{type: "Input validation error", path: [...], message: String.t(), constraint: :unknown_keys | :type}]}` for bad base-schema input. `validate_turn_input!/2` (`base_agent.ex:635`) already turns that into `Normandy.Schema.ValidationError`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agents/validation_middleware_test.exs`, inside the describe block that already uses `config(input_schema: %BaseAgentInputSchema{})`:

```elixir
    test "the default schema rejects an unknown key instead of sending a nil message" do
      assert {:error, [%{constraint: :unknown_keys, path: [:chat_mesage], message: message}]} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{chat_mesage: "hi"}
               )

      assert message =~ "expected only :chat_message"
    end

    test "the default schema rejects a missing or non-string chat_message" do
      for input <- [%{}, %{chat_message: nil}, %{chat_message: 42}] do
        assert {:error, [%{constraint: :type, path: [:chat_message]}]} =
                 ValidationMiddleware.validate_input(
                   config(input_schema: %BaseAgentInputSchema{}),
                   input
                 )
      end
    end

    test "the default schema still accepts an empty string" do
      assert {:ok, %BaseAgentInputSchema{chat_message: ""}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{chat_message: ""}
               )
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/validation_middleware_test.exs`
Expected: the three new tests FAIL (unknown key accepted; nil accepted).

- [ ] **Step 3: Validate the base schema**

In `validate_input_map/2`, replace the branch

```elixir
      schema_module == Normandy.Agents.BaseAgentInputSchema ->
        {:ok, struct(schema_module, input_map)}
```

with

```elixir
      schema_module == Normandy.Agents.BaseAgentInputSchema ->
        validate_base_input(input_map)
```

and add:

```elixir
  # The default schema has one field. struct/2 would drop a typo such as
  # :chat_mesage and send a nil user turn, so check the keys and the type here.
  defp validate_base_input(input_map) do
    case Map.keys(input_map) -- [:chat_message, :__meta__] do
      [] ->
        case Map.get(input_map, :chat_message) do
          message when is_binary(message) ->
            {:ok, %Normandy.Agents.BaseAgentInputSchema{chat_message: message}}

          other ->
            {:error,
             format_validation_errors("Input", [
               %{
                 path: [:chat_message],
                 message: "must be a string, got: #{inspect(other)}",
                 constraint: :type
               }
             ])}
        end

      unknown ->
        {:error,
         format_validation_errors("Input", [
           %{
             path: unknown,
             message:
               "unknown keys #{inspect(unknown)} for the default input schema; " <>
                 "expected only :chat_message",
             constraint: :unknown_keys
           }
         ])}
    end
  end
```

- [ ] **Step 4: Run the file, then the full suite**

Run: `mix test test/agents/validation_middleware_test.exs && mix test 2>&1 | tail -3`
Expected: PASS, then ` 0 failures`. If a library call site builds base input without `chat_message` (for example a continuation turn), it must pass `nil` input, not `%{}`. Fix the call site, not the validation.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/validation_middleware.ex test/agents/validation_middleware_test.exs
git commit -m "fix(agent): reject unknown keys and non-string chat_message on the default input schema"
```

### Task 1.5: Fix the live integration test's retry options (REL-6)

`test/integration/agent_resilience_integration_test.exs:27-28,47` passes `max_retries`/`initial_delay`, which `Retry` now rejects (`retry.ex:149`, supported: `max_attempts`, `base_delay`, `max_delay`, `backoff_factor`, `jitter`, `retry_on`, `retry_if`). The job runs on pushes to main whenever the API key secret is set.

**Files:**
- Modify: `test/integration/agent_resilience_integration_test.exs:24-31,47`

- [ ] **Step 1: Confirm the failure without calling the API**

Run: `mix run -e 'Normandy.Resilience.Retry.with_retry(fn -> {:ok, 1} end, max_retries: 3)'`
Expected: `** (ArgumentError) Retry.with_retry/2: unknown option :max_retries; supported: ...`

- [ ] **Step 2: Rename the options**

Lines 24-31 become:

```elixir
          retry_options: [
            max_attempts: 4,
            base_delay: 100,
            max_delay: 1000,
            jitter: true
          ]
```

Line 47: `retry_options: [max_attempts: 1]`. `max_retries: 0` meant one attempt; `max_retries: 3` meant four.

- [ ] **Step 3: Check that nothing else uses the old names**

Run: `grep -rn "max_retries\|initial_delay" test/ lib/ docs/ README.md examples/ | grep -v "_build"`
Expected: no hits that reach `Retry`. Rename any that do the same way, in the same commit.

- [ ] **Step 4: Commit**

```bash
git add test/integration/agent_resilience_integration_test.exs
git commit -m "test(integration): use current Retry option names"
```

### Task 1.6: `mix test --trace` works again (REL-8)

`test/hooks/guide_examples_test.exs:44` compiles the guide's `ExUnit.Case` module after the suite has started. Under `--trace` (and `--slowest`), ExUnit refuses: "cannot add module … after the suite starts running".

**Files:**
- Modify: `test/hooks/guide_examples_test.exs:46-52`

- [ ] **Step 1: Reproduce**

Run: `mix test test/hooks/guide_examples_test.exs --trace 2>&1 | grep -i "cannot add module"`
Expected: one match.

- [ ] **Step 2: Compile the guide module unregistered**

Replace `[{module, _binary}] = Code.compile_string(source)` with:

```elixir
    # The guide's module is run by hand below; registering it with ExUnit after
    # the suite started fails under --trace and --slowest.
    source = String.replace(source, "use ExUnit.Case,", "use ExUnit.Case, register: false,")
    [{module, _binary}] = Code.compile_string(source)
```

The guide's header is `use ExUnit.Case, async: true` (`docs/guides/hooks.md:257`), so the replacement matches once.

- [ ] **Step 3: Verify on the oldest supported Elixir**

Run: `mix test test/hooks/guide_examples_test.exs --trace && mix test --slowest 5 2>&1 | tail -8`
Expected: PASS, and the slowest list prints. `register: false` must also work on Elixir 1.15: check the 1.15 CI job (or `asdf`/`mise` 1.15 locally). If 1.15 rejects the option, guard it with `Version.match?(System.version(), ">= 1.16.0")` and tag the test `@tag :skip_on_trace` only for 1.15. **Ask Q before adding a skip.**

- [ ] **Step 4: Commit**

```bash
git add test/hooks/guide_examples_test.exs
git commit -m "test(hooks): compile the guide's test module unregistered so --trace works"
```

### Task 1.7: Export the DSL macros to users' formatters (DX-9)

`.formatter.exs` exports no `locals_without_parens`, so `mix format` in a user's app rewrites `model "x"` to `model("x")`. `docs/guides/hooks.md` already shows the parenthesised form.

**Files:**
- Modify: `.formatter.exs`
- Test: `test/formatter_export_test.exs` (create)

**Interfaces:**
- Produces: `export: [locals_without_parens: ...]` in `.formatter.exs`. Users opt in with `import_deps: [:normandy]`. Task 3.x renames must update this list.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Normandy.FormatterExportTest do
  use ExUnit.Case, async: true

  @dsl_macros [
    {Normandy.DSL.Agent,
     ~w(agent name description model temperature max_tokens max_tool_concurrency system_prompt
        background steps output_instructions tool memory max_messages guardrails streaming_mode
        streaming_chunk_size hooks)a},
    {Normandy.DSL.Workflow, ~w(workflow step parallel race agent input transform when_result)a},
    {Normandy.Schema, ~w(schema io_schema field)a}
  ]

  test "every public DSL macro is exported without parens at every arity" do
    {opts, _} = Code.eval_file(".formatter.exs")
    exported = opts |> Keyword.fetch!(:export) |> Keyword.fetch!(:locals_without_parens)

    for {mod, names} <- @dsl_macros, {name, arity} <- mod.__info__(:macros), name in names do
      assert {name, arity} in exported, "#{inspect(mod)}.#{name}/#{arity} is not exported"
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/formatter_export_test.exs`
Expected: FAIL with `KeyError` for `:export`.

- [ ] **Step 3: Export the list**

```elixir
# Used by "mix format"
locals_without_parens = [
  # Normandy.DSL.Agent
  agent: 1, name: 1, description: 1, model: 1, temperature: 1, max_tokens: 1,
  max_tool_concurrency: 1, system_prompt: 1, background: 1, steps: 1,
  output_instructions: 1, tool: 1, memory: 0, memory: 1, max_messages: 1,
  guardrails: 2, guardrails: 3, streaming_mode: 1, streaming_chunk_size: 1, hooks: 1,
  # Normandy.DSL.Workflow
  workflow: 1, step: 2, parallel: 2, race: 2, agent: 2, input: 1, transform: 1,
  when_result: 1,
  # Normandy.Schema
  schema: 1, io_schema: 2, field: 1, field: 2, field: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  export: [locals_without_parens: locals_without_parens]
]
```

Step 1's test derives arities from `__info__(:macros)`, so a wrong arity here fails it. Fix the list from the failure message. Don't add `locals_without_parens` to the repo's own config: that would reformat every file in this branch.

- [ ] **Step 4: Verify**

Run: `mix test test/formatter_export_test.exs && mix format --check-formatted`
Expected: PASS; exit 0.

- [ ] **Step 5: Commit**

```bash
git add .formatter.exs test/formatter_export_test.exs
git commit -m "feat(format): export DSL macros as locals_without_parens for import_deps"
```

### Task 1.8: Package and repo hygiene (REL LOW, DX-10 root module)

**Files:**
- Modify: `lib/normandy.ex` (replace the `mix new` stub)
- Modify: `mix.exs:167,270-278` (req constraint, Changelog link, exclude test-only migrations)
- Modify: `.gitignore` (Mnesia test directory)
- Delete: `test_json_schema_export.exs`. This is a manual exploration script from `9c2efc0` (schema-based tools). Nothing references it and it isn't in `elixirc_paths`. It's tracked at the repo root.

- [ ] **Step 1: Find anything using `Normandy.hello/0`**

Run: `grep -rn "Normandy.hello" lib test docs README.md examples`
Expected: only `lib/normandy.ex` itself (its doctest). If a test file runs `doctest Normandy`, remove that line in this task.

- [ ] **Step 2: Replace the stub module**

```elixir
defmodule Normandy do
  @moduledoc """
  Normandy builds Claude-powered agents in Elixir: typed I/O schemas, tools,
  conversation memory, hooks, guardrails and durable turns.

  Start with `Normandy.Agents.BaseAgent` (or the declarative
  `Normandy.DSL.Agent`), define inputs and outputs with `Normandy.Schema`, and
  see the guides for tools, memory, hooks and distributed sessions.
  """
end
```

- [ ] **Step 3: Fix the package metadata**

In `mix.exs`:
- `{:req, "~> 0.5"}` → `{:req, "~> 0.6 and >= 0.6.1"}` (the same constraint Claudio declares, `../Claudio/mix.exs:60`)
- `links:` add `"Changelog" => "https://github.com/thetonymaster/normandy/blob/main/CHANGELOG.md"`
- `exclude_patterns:` add `"priv/test_repo"` and `"priv/test_repo/*"`

- [ ] **Step 4: Ignore the Mnesia directory tests create**

Append `/Mnesia.*` to `.gitignore`. Check it with `git status --short`: `Mnesia.nonode@nohost` must not show.

- [ ] **Step 5: Delete the stray script**

```bash
git rm test_json_schema_export.exs
```

- [ ] **Step 6: Verify the tarball contents**

Run: `mix deps.get && mix hex.build --unpack -o /private/tmp/claude-501/-Users-antonio-personal-normandy/bd6c82ec-83a9-49c1-bb9f-6d35ad048243/scratchpad/pkg 2>&1 | tail -5; ls /private/tmp/claude-501/-Users-antonio-personal-normandy/bd6c82ec-83a9-49c1-bb9f-6d35ad048243/scratchpad/pkg/priv 2>&1`
Expected: the build still stops on the Claudio path dependency (REL-1, fixed in Wave 7). If it gets far enough to unpack, `priv/test_repo` must be absent. Record the actual output in the commit body.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy.ex mix.exs .gitignore
git commit -m "chore: replace root module stub, align req with Claudio, keep test migrations out of the package"
```

### Task 1.9: Wave 1 gate

- [ ] **Step 1: Format and run precommit**

Run: `mix format && mix precommit 2>&1 | tail -15`
Expected: exit 0; the test summary contains ` 0 failures`; dialyzer reports `Unnecessary Skips: 0`.

- [ ] **Step 2: Run the commands Wave 1 fixed**

Run: `mix docs --warnings-as-errors && mix test --trace 2>&1 | tail -3`
Expected: both exit 0.

- [ ] **Step 3: Record the wave**

Append a Wave 1 line to `investigations/pre-2.0-audit/decisions.md` → "Progress": commit range, test count, and the outcome of the 1.15 check in Task 1.6. Write `plan-wave-2.md` next (see the Wave 2 section).

---
## Waves 2–7 — Roadmap

Each wave below lists its tasks, the findings each one closes, the files involved, the interfaces later waves rely on, and the acceptance tests that define done. Before a wave starts, write `investigations/pre-2.0-audit/plan-wave-N.md` at the same code level as Wave 1, against the code as it stands then, and have Q review it. Every wave ends with the Task 1.9 gate (precommit, `--trace`, docs build), adjusted for that wave.

### Wave 2 — Model protocol, error model, entry points (decisions 5, 6, 13; DX-2, DX-4, DX-5, DX-11, DX-30, TEL-2, SEC-5/TEL-4)

**Task 2.1: Request/Response structs and the two-function protocol**
- Files: create `lib/normandy/llm/request.ex`, `lib/normandy/llm/response.ex`. Rewrite `lib/normandy/agents/model.ex`. Migrate `lib/normandy/llm/claudio_adapter.ex` and `lib/normandy/llm/openai_compatible_adapter.ex`, and delete the `ConverseResult` normalization. Migrate every test client in `test/support/` (`stub_client.ex`, `model_mockup.ex`, `scripted_tool_client.ex`, `streaming_probe_client.ex`, `tagging_client.ex`, `mock_summarizer_client.ex`) and inline test impls (`grep -rln "defimpl Normandy.Agents.Model" test`).
- Produces: `%Normandy.LLM.Request{model, system, messages, response_model, temperature, max_tokens, tools, tool_choice, output_format, options}`; `%Normandy.LLM.Response{content, stop_reason, usage, meta}` (`stop_reason` is required by Wave 5); `Model.converse(client, %Request{}, opts) :: {:ok, %Response{}} | {:error, %LLMError{}}`; `Model.stream(client, %Request{}, opts) :: {:ok, Enumerable.t()} | {:error, %LLMError{}}`; `LLMError` type `:unsupported`.
- Acceptance: `Normandy.Agents.Model.__protocol__(:functions) == [converse: 3, stream: 3]`; `completitions` appears nowhere in `lib/` or `test/`; a non-streaming client's `stream/3` returns `{:error, %LLMError{type: :unsupported}}` and `BaseAgent.stream/3` surfaces it as `{:error, ...}`; the Task 1.3 test asserts `request.max_tokens == 16_000`; the ClaudioAdapter tests assert `stop_reason` is carried on `%Response{}` for `:end_turn`, `:tool_use`, `:max_tokens`, `:refusal` and `:pause_turn`.

**Task 2.2: Claudio gap list (decision 2)**
- List every field `%Request{}` needs that Claudio 0.7.0 can't express (for example `output_config.format` together with tools, used in Task 5.1). **Ask Q before editing `../Claudio`.** Claudio is published after this wave (Task 7.5).
- Acceptance: a short `claudio-gaps.md` in this directory listing each gap with its Claudio file:line, or the line "no gaps".

**Task 2.3: Tuple error model everywhere**
- Files: `lib/normandy/agents/base_agent.ex` (`run`, `run!`, `validate_turn_output`), `lib/normandy/agents/turn/server.ex:128-132,633-645,1157,1220-1258`, `lib/normandy/coordination/agent_process.ex:116`, `lib/normandy/dsl/workflow.ex:539-545`, `lib/normandy/dsl/agent.ex`.
- Produces: `BaseAgent.run(config, input, opts \\ []) :: {:ok, config, output} | {:error, Exception.t()}`; `run!/2,3 :: {config, output}`, raising the same exception. Turn.Server, AgentProcess and Workflow reply `{:error, exception}` with the exception unwrapped. Output that fails schema validation becomes `{:error, %Normandy.Schema.ValidationError{}}`, with no `IO.warn` (SEC-5/TEL-4); the full output stays out of logs.
- Acceptance: Review Focus #3. A `StubClient` 429 gives `{:error, %LLMError{type: :rate_limit}}` from `run/2` and raises from `run!/2`. Under `Turn.Server`, the reply is the bare `%LLMError{}`. The persisted turn state (read back from the InMemory store) contains no stacktrace tuple. The run `:exception` telemetry metadata has `error.type == "rate_limit"` and no `:stacktrace` args. Invalid output returns `{:error, %ValidationError{}}`, and `ExUnit.CaptureIO.capture_io(:stderr, ...)` is empty.

**Task 2.4: Entry points `run/2,3`, `run!/2,3`, `stream/3`**
- Delete `run_with_tools/2`, `stream_response/3`, `stream_with_tools/3` (BaseAgent and DSL). `stream/3` returns `{:ok, config, output}` with the final message converted to the output schema; callback payloads are `%StreamEvent{}` (DX-30). `run(config, "text")` is accepted as `%{chat_message: "text"}` for the default schema (rest of DX-12).
- Acceptance: `function_exported?(BaseAgent, :run_with_tools, 2) == false` (and the same for the other two); streaming and non-streaming runs of the same `StubClient` script return equal output structs; a binary input reaches the client as the user message.

**Task 2.5: README quickstart test**
- Files: create `test/readme_test.exs`. Extract the README's quickstart block the way `test/hooks/guide_examples_test.exs` does, swap the client for `Normandy.Test.StubClient`, and run it. Update `README.md` to the tuple API.
- Acceptance: the README block runs and the captured request has `max_tokens == 16_000`. Changing the README so it no longer runs fails this test.

### Wave 3 — Config, options, tool contract (decisions 1, 7, 9; DX-6, DX-7, DX-14–19, DX-21, DX-22, DX-25, DX-26, SEC-1)

**Task 3.1: NimbleOptions and a strict `BaseAgent.init/1`**
- Add `{:nimble_options, "~> 1.1"}`. `init/1` accepts a map or a keyword list, validated by one schema whose defaults include `BaseAgentConfig.default_max_tokens()`. An unknown key raises `ArgumentError` naming the key and listing the supported ones, with a hint for `:system_prompt` (use `prompt_specification`) and `:tools` (use the toolset). A missing `:model` raises `"BaseAgent.init/1 requires :model (a string), got none"`.
- Acceptance: one test per message above, asserting the exact text; `init(model: "m", client: c)` (a keyword list) works; the `init/1` docs embed `NimbleOptions.docs/1`.

**Task 3.2: Config reshape (DX-18, DX-19)**
- `retry: keyword | nil`, `circuit_breaker: keyword | nil` (Wave 4 fills in what it means), `guardrails: [input:, output:, streaming_mode:, chunk_size:, on_violation:]`. The compactor option `:max_tokens` is renamed `:context_window`. Remove `Behaviours.Config.session_store`/`session_registry`. `ConfigTemplate.rebuild/3` translates 1.x templates (old keys mapped to new ones, the dead slots dropped) and raises `ArgumentError` naming the field for anything it can't translate.
- Acceptance: Review Focus #1 for config keys. A 1.x template fixture (`:erlang.term_to_binary` of a 1.x-shaped map, saved under `test/fixtures/`) rebuilds into a working config; `retry_options:` passed to `init/1` raises with "renamed to :retry"; `docs/guides/distributed_sessions.md` no longer mentions `session_store`.

**Task 3.3: Options validated at every public entry point (DX-7)**
- Files: `turn/server.ex`, `turn/session.ex`, `coordination/*` (orchestrators, AgentPool, AgentProcess, AgentSupervisor), `batch/*`, `resilience/circuit_breaker.ex`, `dsl/workflow.ex` (`execute`), `a2a/*`, `mcp/*`. Each gets an `@opts_schema` with NimbleOptions and generated `## Options` docs.
- Acceptance: a table-driven test calls each entry point with a misspelled option (for example `approval_timout_ms`) and asserts an `ArgumentError` naming the module, the function and the key. `grep -rn "Keyword.get(opts" lib/` returns no hits in public functions without a schema.

**Task 3.4: One tool contract; model input kept off the tool struct (DX-22, SEC-1)**
- Produces: the `Normandy.Tool` behaviour, `run(tool, %Normandy.Tools.Context{input: validated_input}) :: {:ok, term} | {:error, term}`, with `input_schema/1`. `Context` gains `:input`. `Dispatch.prepare_tool/2` is removed: input is validated against the input schema into a struct or map and never merged into the tool. Timeouts come from registration options. `Normandy.Tools.Registry` is renamed `Normandy.Tools.Toolset`. `BaseTool`, `SchemaBaseTool` and `ContextualTool` collapse into the behaviour. Built-ins (`Tools.Memory`, `A2A.AgentTool`, `MCP.ToolWrapper`) migrate.
- Acceptance: the SEC-1 test. A tool `defstruct [:endpoint, timeout: 5_000]` with input schema `{query}` receives model input `{"query": "x", "endpoint": "evil", "timeout": "x"}`. The struct is unchanged, the unknown keys produce an `is_error: true` tool_result naming them, and the turn continues. The registration timeout applies. Review Focus #1: a 1.x template that references a removed tool module raises `ArgumentError` naming the module and pointing at MIGRATING §tools.

**Task 3.5: Session handle and orchestrator arity (DX-14, DX-15)**
- `Turn.Session.new(opts) :: %Session{}` (validated once); `Session.run(session, input)`, `Session.approve(session, decisions)`; `SequentialOrchestrator`/`ParallelOrchestrator`: `execute(agents, input, opts \\ [])` with one return shape.
- Acceptance: a struct input to `ParallelOrchestrator.execute/3` reaches every agent (today it's dropped); all orchestrators return the same `{:ok, results} | {:error, ...}` shape, asserted by one shared test.

**Task 3.6: Naming and shape conventions (DX-16, DX-17, DX-21)**
- Lookups return `{:ok, v} | :error`; bang variants raise. `NonExistentTurn` → `TurnNotFoundError`, `NonExistentContextProvider` → `ContextProviderNotFoundError`, each with a moduledoc. Remove `__str__/__rich__` from `BaseIOSchema`.
- Acceptance: `get_tool`, `get_context_provider` and `AgentMemory.get_entry` all return `{:ok, _} | :error`, plus raising `!` variants; the old exception modules don't exist.

**Task 3.7: Jason default; examples out of `lib` (DX-25, DX-26)**
- Default JSON adapter: Jason, read through one helper (`Normandy.JSON`). Poison is dropped as a dependency (decision 1 says drop it); `@derive {Poison.Encoder, ...}` is replaced. `lib/normandy/tools/examples/*` moves to `examples/`, which isn't compiled into the package.
- Acceptance: `mix.exs` has no `:poison`; `grep -rn "Poison" lib/` returns nothing; `mix hex.build --unpack` contains no `tools/examples`; the 13 former `Application.get_env(:normandy, :adapter, Poison)` sites go through `Normandy.JSON`.

### Wave 4 — Supervised circuit breaker (decisions 8a, 8b; PERF-1, PERF-2, PERF-5, PERF-9, A2 remainder, DX-27, TEL-6)

**Task 4.1: Breaker registry under Normandy's supervision tree**
- Produces: `Normandy.Resilience.CircuitBreaker.ensure_started(key, opts) :: {:ok, key}`, with breakers under a `DynamicSupervisor` and a `Registry` started by `Normandy.Application`. The key is `{client_module, endpoint, model}`, never anything secret (no api key). The config and template hold the key and opts, never a pid. The half-open probe holder is monitored and its slot is freed on `:DOWN`. Each state transition bumps a generation, and a result tagged with an older generation is ignored. `init/1` no longer starts linked processes. AgentPool stops starting a breaker per overflow agent.
- Acceptance: Review Focus #4; the process that called `init/1` exits and later turns still use the breaker (PERF-2); a probe killed with `Process.exit(pid, :kill)` frees the slot within one `reset_timeout` (PERF-1); a result from a call admitted before a transition doesn't count as a probe result (PERF-9, with a deterministic test that uses message ordering, not sleeps); two agents with the same client and model share one breaker process and an agent on another model doesn't; a 1.x template holding a pid rebuilds with a key.

**Task 4.2: Breaker and retry telemetry (TEL-6)**
- Events `[:normandy, :circuit_breaker, :state_change]` (from, to, key) and `[:normandy, :retry, :attempt]` (attempt, delay_ms, error type). Retry logs name the error type, not `inspect(error)` with its stacktrace. Both events go into the `Normandy.Telemetry` catalogue.
- Acceptance: the catalogue test passes; a telemetry capture test sees closed→open→half_open→closed; the captured log contains no stacktrace.

### Wave 5 — Agent loop and model-facing correctness (decisions 11, 12a, 12b; AX-1, AX-3–AX-10, SEC-2, SEC-3/AX-8, SEC-4, SEC-6/PERF-11, SEC-7, SEC-9, agentx MEDIUM/LOW)

**Task 5.1: Output schema with tools (AX-1)**
- Send `output_config.format` on tool-loop calls. The structured-response handler passes `stop_reason: :tool_use` through to the loop. The fallback path appends the OUTPUT SCHEMA to the system prompt and parses the final JSON into the schema. `convert_turn_output` never returns `raw` for a non-chat schema. Update CLAUDE.md's "tool-bearing calls fall back" note.
- Acceptance: Review Focus #2. With a `ScriptedToolClient` (one tool turn, then a JSON text turn), a non-chat `output_schema` comes back as that struct, and the captured request carries `output_format`. The fallback test has `structured_outputs: false` and asserts the schema text is in the system prompt and the result is the struct. An unparseable final answer gives `{:error, %ValidationError{}}`.

**Task 5.2: stop_reason handling (AX-4, AX-10, AX-5)**
- `:max_tokens` with a partial `tool_use` doesn't run the tool and returns `{:error, %LLMError{type: :max_tokens}}`. `:pause_turn` continues the loop. `:refusal` becomes `{:error, %LLMError{type: :refusal}}`. A truncated structured answer is never stored as `chat_message`. At the iteration cap the model gets a notice and tools are withheld from the final call, with the cached system prompt unchanged.
- Acceptance: one scripted-client test per stop_reason, asserting the return value and that memory holds no truncated answer.

**Task 5.3: Tool-call protocol fidelity (AX-6, AX-3, AX-7)**
- All tool results of one assistant turn go back in **one** user message. Server-side MCP blocks are not dispatched locally and are replayed as received. Assistant turns are replayed as received (append-only: no merging of text blocks, no reordering of thinking, no dropping of server, compaction or fallback blocks).
- Acceptance: three parallel tool calls produce one user message with three `tool_result` blocks in call order; a replay test asserts byte-equal content blocks between the response and the next request's history; the live 400 check for AX-7 (PLAUSIBLE) runs in Task 7.6.

**Task 5.4: Size caps (SEC-3/AX-8, SEC-6/PERF-11)**
- Tool results: truncate at `max_tool_result_chars` (default 100_000, per agent and per tool, `nil` = off) on a grapheme boundary, append `"[truncated: N of M chars shown]"`, and emit `[:normandy, :tool, :result_truncated]`. Memory: every backend tracks namespace bytes and the document count in the same CAS write; `max_namespace_documents` defaults to 1000.
- Acceptance: Review Focus #5; `memory_store_contract.ex` gains cases for the byte cap counting every document past 1000, the count cap, and two concurrent writers that together exceed the cap (exactly one succeeds), run against all 5 backends.

**Task 5.5: Compaction and summarizer (AX-9, mid-turn thinking, summarizer budget)**
- The summarizer reads tool results and assistant text from tool turns (the atom/string key mismatch). Mid-turn compaction keeps the in-progress tool call's thinking. The summarizer's default `max_tokens` is raised from 500 to fit always-on thinking.
- Acceptance: a summary built from a scripted conversation includes a tool result's text; a mid-turn compaction keeps the thinking block of the open tool call.

**Task 5.6: Model-facing text (agentx MEDIUM/LOW, AX-25, AX-11)**
- Error tool_results say what to do next; the sync path stops claiming `pending_approval: true`; the MCP wrapper honours `isError`; memory tool errors aren't double-wrapped; the shouting in the memory tool description goes; the dated section headers (AX-25) are replaced; empty `description: ""` is omitted from schemas (AX-11, which the 2026-10-04 run showed emits `""`, not `null`); schema properties keep declaration order.
- Acceptance: golden-text tests for each changed string, and a schema test asserting field order and no empty descriptions.

**Task 5.7: Security hardening (SEC-2, SEC-4, SEC-7, SEC-8, SEC-9, security LOW)**
- MCP tool names get a server prefix by default. Guardrail `:on_error` covers exits and timeouts, not only raises. A session namespace that equals a mount namespace is rejected. A2A gets a request-size limit and a per-caller `tool_context` hook. SEC-8 (template integrity): **decide with Q in plan-wave-5** between documenting the trust boundary and signing templates.
- Acceptance: one test per item, each asserting the failure mode from `security.md`.

### Wave 6 — Performance and observability (PERF-3/B1, B2, B3, B5, PERF-4, PERF-6–8, PERF-10, PERF-12–16, A7, July leftovers, TEL-3, TEL-5, TEL-7–17)

**Task 6.1: Linear-time history (PERF-3/B1, B3)**: encode each message once and keep the encoding with it, cache prompt, schema and tool definitions per config, and stop the compactor re-encoding everything. Acceptance: a counting test shows N turns cost O(N) message encodings in total (asserted with a telemetry counter or an injected encoder that counts calls).

**Task 6.2: Turn.Server startup and store failures (PERF-4, PERF-7, B2)**: move store IO out of `init/1` into `handle_continue`; store timeouts become a handled state instead of a crash, so they don't use up the shared restart limit; stop copying the whole config into each worker. Acceptance: 50 concurrent session starts against a store that delays 200 ms finish in under 1 s total; a store timeout doesn't restart the server.

**Task 6.3: Cluster hygiene (PERF-6, PERF-8, PERF-10, PERF-12, July Redis items)**: the Redis registry resolves `whereis` without the GenServer hop; the eager-resume set is pruned and gains a session delete; `WAIT` runs on its own connection; ETS and Mnesia memory stores use one row per document. Acceptance: contract tests still pass on all backends; a test shows the eager set shrinks after a session is deleted.

**Task 6.4: Telemetry fixes (TEL-3, TEL-5, TEL-7–TEL-17)**: admission and `on_turn_end` run inside the caller's trace context; hook contract errors don't inspect user data; the run stop event carries total usage, iteration count and finish reason; start/stop logs drop to `:debug`. Acceptance: span-parenting tests for admission and `on_turn_end`; the catalogue test; one assertion per TEL item.

**Task 6.5: Remaining process hygiene (A7, PERF-13–16, the July MEDIUM/LOW list)**: decide the `AgentProcess` default mode in plan-wave-6 (today `:inline` blocks `handle_call`); handle supervised `run_async` limits, `Reactive.race` cleanup, `delete_turn` O(N²), and the `OtelCtx` code-server lookups. Acceptance: one test per item from `perf.md`.

### Wave 7 — Docs, release, publish (REL-1, REL-3–5, REL-7, REL-9, DX-8, DX-10, DX-13)

**Task 7.1: MIGRATING-2.0.md** covers every breaking change: the ~15 found in REL-4 plus every wave's, each with an old→new table and a code sample. Acceptance: every commit on the branch whose diff touches a public function is matched to a MIGRATING section, checked against `git log main..HEAD`.

**Task 7.2: Docs groups (DX-13/REL-7)**: every public module goes into a group; internals (`Hooks.Runner`, `Turn.Driver`, the Telemetry helpers, …) get `@moduledoc false`; add an "Errors" group. Acceptance: a test loads every `lib/` module with docs and asserts it's in exactly one group in `mix.exs`.

**Task 7.3: API docs and the testing story (DX-10, DX-8)**: `@doc` on `init`, `run`, `run!`, `stream`, `reset_memory` and the Session functions; ship `Normandy.Test.FakeClient` in `lib/` (scripted replies, captures requests) plus `docs/guides/testing.md`; move the store contract suites to where users can reuse them. Acceptance: `mix docs` lists no public function without docs in BaseAgent or Session; the testing guide's examples run in a guide test.

**Task 7.4: CHANGELOG (REL-5)**: write the 2.0.0 entry by hand from MIGRATING and the waves; make sure cog's generated section doesn't land below a stale `[Unreleased]` block (rehearse `cog bump --auto` on a scratch clone, as the release audit did). Acceptance: on the scratch clone, a `feat!:` squash produces `v2.0.0` and a CHANGELOG with one 2.0.0 section.

**Task 7.5: Claudio on Hex, version 2.0.0 (REL-1, decision 2)**: **Q publishes Claudio 0.7.0** once Task 2.2's gaps are closed. Then switch to `{:claudio, "~> 0.7.0"}`, refresh `mix.lock` (drop the stale 0.6.0 entry), set `version: "2.0.0"` and `source_ref: "v2.0.0"` in `mix.exs`, and update CLAUDE.md's dependency note. Acceptance: `mix hex.build` succeeds and the unpacked tarball has no `priv/test_repo`, `investigations/` or `tools/examples`.

**Task 7.6: One live e2e run (decision 4, REL-9)**: **ask Q before spending**. Run `mix e2e` once; it includes scenario 14 (never run live) and a probe for AX-7 (history replay under preserved thinking). Fix failures and rerun only the failed scenarios. Acceptance: all scenarios pass, with the run log saved to this directory.

**Task 7.7: Release PR (decision 3)**: open the PR from `feat/claudio-0.7-migration` to `main` titled `feat!: Normandy 2.0`. **Confirm with Q before opening it** (it's outward-facing). Acceptance: CI green on the whole matrix.

---

## Finding coverage

Every Tier 0–2 finding in `consolidated.md` maps to a task above. Tier 3–4 findings are assigned by area: security → 5.7, telemetry → 6.4, perf → 6.3/6.5, agentx → 5.6, devex non-breaking → 7.3, release LOW → 1.8. Each `plan-wave-N.md` starts by listing the finding IDs it closes. A finding a wave can't close goes back to Q, never silently dropped.
