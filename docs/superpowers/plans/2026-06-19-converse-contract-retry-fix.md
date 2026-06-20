# Model.converse Contract + Retry-Architecture Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the JSON feedback-retry loop and conversation summarizer work correctly with the real `ClaudioAdapter` by de-ambiguating the `Model.converse/7` return contract (non-breaking) and giving the retry loop a raw-completion path so the deserializer is the single parse+retry authority.

**Architecture:** Approach A from the design spec. Part 1: a pure `ConverseResult.normalize/1` flattens the dual-shaped (`struct()` | `{struct(), usage}`) converse return at the two crashing call sites. Part 2: the deserializer retry loop calls `converse(..., raw: true)`; `ClaudioAdapter` honors `raw` by returning raw text without re-entering its own `deserialize_with_retry`, removing the nested-retry layer.

**Tech Stack:** Elixir, ExUnit, Poison, Claudio (private git LLM client), `:telemetry`.

**Reference:** `docs/superpowers/specs/2026-06-19-converse-contract-retry-fix-design.md` and `investigations/converse-return-contract.md`.

## Global Constraints

- **Non-breaking:** no change to `Normandy.Agents.Model` protocol signatures or `@spec`; no new required callback. `raw` is an opt non-raw clients ignore; `normalize/1` accepts both legacy return shapes. (v1.1.0 semver.)
- **Public API frozen:** `JsonDeserializer.parse_and_validate/3` and `deserialize_with_retry/8` keep their signatures and all return shapes (`{:ok, struct}`, `{:error, {:json_parse_error,…}}`, `{:error, {:validation_error,…}}`, `{:error, {:max_retries_reached,…}}`, `{:error, :llm_call_failed}`, `{:error, {:unexpected_parse_result,…}}`, `{:error, {:input_too_large,…}}`).
- **Full suite green at every checkpoint.** Verified baseline before this plan: `1374 tests, 0 failures (128 excluded)`. The log line `[error] normandy agent exception` is expected test output, not a failure.
- **Run `mix format` before every test run** (project CLAUDE.md). Never `git add .` — add files individually. Use each task's commit message verbatim. No AI authorship attribution in commits.
- **Do not alter the normal (non-raw) `converse` path or the Poison/default parse path.**

---

### Task 1: `Normandy.Agents.ConverseResult.normalize/1`

**Files:**
- Create: `lib/normandy/agents/converse_result.ex`
- Test: `test/agents/converse_result_test.exs`

**Interfaces:**
- Produces: `Normandy.Agents.ConverseResult.normalize(term()) :: {term(), map() | nil}` — coerces a `converse/7` return into `{response, usage}`. `{response, usage}` with a struct-or-binary first element passes through; a bare `struct()` or `binary()` becomes `{it, nil}`; anything else becomes `{other, nil}`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing unit test**

Create `test/agents/converse_result_test.exs`:

```elixir
defmodule Normandy.Agents.ConverseResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ConverseResult

  defmodule R do
    defstruct chat_message: nil
  end

  test "tuple whose first element is a struct passes through" do
    assert {%R{}, %{a: 1}} = ConverseResult.normalize({%R{}, %{a: 1}})
  end

  test "tuple whose first element is a binary passes through" do
    assert {"raw", %{a: 1}} = ConverseResult.normalize({"raw", %{a: 1}})
  end

  test "a bare struct gets nil usage" do
    assert {%R{}, nil} = ConverseResult.normalize(%R{})
  end

  test "a bare binary gets nil usage" do
    assert {"raw", nil} = ConverseResult.normalize("raw")
  end

  test "any other shape is wrapped with nil usage" do
    assert {{:error, :boom}, nil} = ConverseResult.normalize({:error, :boom})
    assert {nil, nil} = ConverseResult.normalize(nil)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/converse_result_test.exs`
Expected: FAIL — `Normandy.Agents.ConverseResult` is undefined.

- [ ] **Step 3: Create the module**

Create `lib/normandy/agents/converse_result.ex`:

```elixir
defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the dual-shaped `Normandy.Agents.Model.converse/7` return —
  `struct()` or `{struct(), usage}` (and, in raw mode, `binary()` /
  `{binary(), usage}`) — into a single `{response, usage}` tuple, so callers
  stop assuming one shape. The protocol contract is intentionally left
  dual-shaped for backward compatibility; this is the single place consumers
  normalize it.
  """

  @spec normalize(term()) :: {term(), map() | nil}
  def normalize({response, usage}) when is_struct(response) or is_binary(response),
    do: {response, usage}

  def normalize(response) when is_struct(response) or is_binary(response),
    do: {response, nil}

  def normalize(other), do: {other, nil}
end
```

- [ ] **Step 4: Run the unit test**

Run: `mix format && mix test test/agents/converse_result_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: PASS (`1374` + 5 new tests, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/converse_result.ex test/agents/converse_result_test.exs
git commit -m "feat(agents): add ConverseResult.normalize/1 to flatten converse return shapes"
```

---

### Task 2: Summarizer normalizes the converse result

**Files:**
- Modify: `lib/normandy/context/summarizer.ex` (`call_llm_for_summary/5`, around lines 189-209)
- Test: `test/context/summarizer_test.exs` (append)

**Interfaces:**
- Consumes: `Normandy.Agents.ConverseResult.normalize/1` (Task 1).
- Produces: `Summarizer.summarize_messages/4` succeeds (`{:ok, summary}`) when the client returns the `{struct, usage}` tuple shape (e.g. `ClaudioAdapter`).

- [ ] **Step 1: Write the failing regression test**

Append to `test/context/summarizer_test.exs`. First add a top-level tuple-returning mock client at the very top of the file (above `defmodule Normandy.Context.SummarizerTest`):

```elixir
defmodule Normandy.Test.TupleSummarizerClient do
  @moduledoc false
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
      # Mirrors ClaudioAdapter: returns {struct, usage} tuple on success.
      {%{response_model | chat_message: "tuple-summary"}, %{tokens: 1}}
    end
  end
end
```

Then append this test inside `describe "summarize_messages/4"`:

```elixir
    test "succeeds when the client returns a {struct, usage} tuple (ClaudioAdapter shape)" do
      client = %Normandy.Test.TupleSummarizerClient{}
      agent = BaseAgent.init(%{client: client, model: "test-model", temperature: 0.7})

      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      assert {:ok, "tuple-summary"} = Summarizer.summarize_messages(client, agent, messages)
    end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/context/summarizer_test.exs`
Expected: FAIL — current `call_llm_for_summary/5` matches the tuple as `other`, returning `{:error, {:unexpected_response, {struct, %{tokens: 1}}}}`.

- [ ] **Step 3: Normalize before matching**

In `lib/normandy/context/summarizer.ex`, change `call_llm_for_summary/5` (the `case Normandy.Agents.Model.converse(...) do ... end` block) to normalize first:

```elixir
  defp call_llm_for_summary(client, model, temperature, max_tokens, messages) do
    # Create a proper struct response model for text output
    response_model = %Normandy.Agents.BaseAgentOutputSchema{chat_message: ""}

    {response, _usage} =
      Normandy.Agents.ConverseResult.normalize(
        Normandy.Agents.Model.converse(
          client,
          model,
          temperature,
          max_tokens,
          messages,
          response_model,
          []
        )
      )

    case response do
      %{chat_message: summary} when is_binary(summary) ->
        {:ok, summary}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end
```

Note: `normalize/1` leaves a plain map like `%{}` (the `BadResponseClient` case in `test/behaviours/compactor_test.exs`) as `{%{}, nil}`, so the `unexpected_response` negative path is preserved.

- [ ] **Step 4: Run the file then the whole suite**

Run: `mix format && mix test test/context/summarizer_test.exs && mix test`
Expected: PASS (baseline + 1 new test, 0 failures; the existing `BadResponseClient`/`unexpected_response` tests still pass).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/context/summarizer.ex test/context/summarizer_test.exs
git commit -m "fix(context): normalize converse result in summarizer so the adapter tuple works"
```

---

### Task 3: Retry loop uses `raw: true` + normalizes

**Files:**
- Modify: `lib/normandy/llm/json_deserializer.ex` (`retry_with_feedback/12`, lines ~304-336; add an alias)
- Test: `test/llm/json_deserializer_retry_test.exs` (create)

**Interfaces:**
- Consumes: `Normandy.Agents.ConverseResult.normalize/1` (Task 1); `Normandy.Agents.Model.converse/7`.
- Produces: the retry loop passes `raw: true`, normalizes the result, and re-parses a binary response directly (a struct response goes through the existing `extract_content_from_response/1`); a non-struct/non-binary response yields `{:error, :llm_call_failed}`.

- [ ] **Step 1: Write the failing regression tests**

Create `test/llm/json_deserializer_retry_test.exs`. Define two top-level mock clients, then the tests:

```elixir
defmodule Normandy.Test.RawRecoveryClient do
  @moduledoc false
  defstruct []
end

defimpl Normandy.Agents.Model, for: Normandy.Test.RawRecoveryClient do
  def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

  # Returns valid JSON as RAW TEXT only when the retry loop asks for raw output.
  # If raw: true is not threaded, this returns malformed text and recovery fails.
  def converse(_c, _m, _t, _mt, _msgs, _response_model, opts) do
    if Keyword.get(opts, :raw, false) do
      ~s({"chat_message": "recovered"})
    else
      "not json"
    end
  end
end

defmodule Normandy.Test.TupleRecoveryResponse do
  @moduledoc false
  defstruct chat_message: nil
end

defmodule Normandy.Test.TupleRecoveryClient do
  @moduledoc false
  defstruct []
end

defimpl Normandy.Agents.Model, for: Normandy.Test.TupleRecoveryClient do
  def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

  # Mirrors ClaudioAdapter's {struct, usage} return; the struct carries valid
  # JSON as its chat_message, which the retry loop must extract and re-parse.
  def converse(_c, _m, _t, _mt, _msgs, _response_model, _opts) do
    {%Normandy.Test.TupleRecoveryResponse{chat_message: ~s({"chat_message": "recovered"})}, %{tokens: 1}}
  end
end

defmodule Normandy.LLM.JsonDeserializerRetryTest do
  use ExUnit.Case, async: false

  alias Normandy.LLM.JsonDeserializer
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.Components.Message

  @msgs [%Message{turn_id: "t", role: "system", content: "sys"}]

  test "retry recovers via a raw-text completion (proves raw: true is threaded)" do
    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               %Normandy.Test.RawRecoveryClient{},
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 1
             )
  end

  test "retry recovers when the client returns a {struct, usage} tuple" do
    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               %Normandy.Test.TupleRecoveryClient{},
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 1
             )
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/llm/json_deserializer_retry_test.exs`
Expected: FAIL — current `retry_with_feedback/12` does not pass `raw: true` (so `RawRecoveryClient` returns `"not json"` → no recovery) and rejects the tuple via `is_struct` (so `TupleRecoveryClient` → `{:error, :llm_call_failed}`).

- [ ] **Step 3: Add the alias**

In `lib/normandy/llm/json_deserializer.ex`, add near the other aliases (alphabetically with the existing `alias Normandy.LLM.Json.*` block):

```elixir
  alias Normandy.Agents.ConverseResult
```

- [ ] **Step 4: Rewrite the converse handling in `retry_with_feedback/12`**

Replace the current block (lines ~304-336):

```elixir
    tools = Keyword.get(opts, :tools, [])
    llm_opts = if tools != [], do: [tools: tools], else: []

    case Normandy.Agents.Model.converse(
           client,
           model,
           temperature,
           max_tokens,
           augmented_messages,
           schema,
           llm_opts
         ) do
      response when is_struct(response) ->
        # Got response, try to extract content again
        new_content = extract_content_from_response(response)

        deserialize_loop(
          new_content,
          schema,
          client,
          model,
          temperature,
          max_tokens,
          messages,
          opts,
          adapter,
          attempt,
          max_retries
        )

      _ ->
        {:error, :llm_call_failed}
    end
```

with:

```elixir
    tools = Keyword.get(opts, :tools, [])
    llm_opts = [raw: true | if(tools != [], do: [tools: tools], else: [])]

    {response, _usage} =
      ConverseResult.normalize(
        Normandy.Agents.Model.converse(
          client,
          model,
          temperature,
          max_tokens,
          augmented_messages,
          schema,
          llm_opts
        )
      )

    cond do
      is_binary(response) ->
        deserialize_loop(
          response,
          schema,
          client,
          model,
          temperature,
          max_tokens,
          messages,
          opts,
          adapter,
          attempt,
          max_retries
        )

      is_struct(response) ->
        deserialize_loop(
          extract_content_from_response(response),
          schema,
          client,
          model,
          temperature,
          max_tokens,
          messages,
          opts,
          adapter,
          attempt,
          max_retries
        )

      true ->
        {:error, :llm_call_failed}
    end
```

- [ ] **Step 5: Run the file then the whole suite**

Run: `mix format && mix test test/llm/json_deserializer_retry_test.exs && mix test`
Expected: PASS (baseline + 2 new tests, 0 failures). The `raw: true` opt is harmless to clients that ignore it (they keep returning their normal shape, which `normalize/1` + the `is_struct` branch handle exactly as before).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json_deserializer.ex test/llm/json_deserializer_retry_test.exs
git commit -m "fix(llm): retry loop requests raw completion and normalizes converse result"
```

---

### Task 4: `ClaudioAdapter` raw-completion branch

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex` (`converse/7` ~line 94; add `converse_raw/6` in the `defimpl`; **move** `extract_content/1` + `extract_usage/1` from the `defimpl` to the outer module and add `__raw_completion__/1` near `__on_parse_failure_policy__/1` ~line 898)
- Test: `test/llm/claudio_adapter_test.exs` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ClaudioAdapter.converse(..., raw: true)` returns `{raw_text, usage}` from a single Claudio call, skipping `convert_response_to_normandy`/`populate_standard_schema`/the nested `deserialize_with_retry`; on a Claudio API error it returns `{:error, error}`. Testable mapping: `Normandy.LLM.ClaudioAdapter.__raw_completion__({:ok, response}) :: {binary(), map() | nil}` and `__raw_completion__({:error, term()}) :: {:error, term()}`.

- [ ] **Step 1: Write the failing unit tests for the pure mapping**

Append to `test/llm/claudio_adapter_test.exs` (inside `defmodule NormandyTest.LLM.ClaudioAdapterTest`):

```elixir
  describe "raw completion mapping" do
    test "__raw_completion__ maps a successful Claudio response to {content, usage}" do
      response = %{content: [%{type: :text, text: "hello"}], usage: %{input_tokens: 5}}
      assert {"hello", %{input_tokens: 5}} = ClaudioAdapter.__raw_completion__({:ok, response})
    end

    test "__raw_completion__ joins multiple text blocks and ignores non-text blocks" do
      response = %{
        content: [%{type: :text, text: "a"}, %{type: :tool_use}, %{type: :text, text: "b"}]
      }

      assert {"a\nb", nil} = ClaudioAdapter.__raw_completion__({:ok, response})
    end

    test "__raw_completion__ passes a Claudio API error straight through" do
      assert {:error, :boom} = ClaudioAdapter.__raw_completion__({:error, :boom})
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/llm/claudio_adapter_test.exs`
Expected: FAIL — `ClaudioAdapter.__raw_completion__/1` is undefined.

- [ ] **Step 3: Move extraction to the outer module (single source) and add the raw mapping**

In `lib/normandy/llm/claudio_adapter.ex`:

**(a)** MOVE `extract_content/1` (both clauses, the `defp` at ~line 749) and `extract_usage/1` (both clauses, ~line 883) OUT of the `defimpl Normandy.Agents.Model` block and INTO the OUTER `defmodule Normandy.LLM.ClaudioAdapter do` block (next to `__on_parse_failure_policy__/1`, ~line 898), changing them from `defp` to `@doc false def` so both the impl and tests can call them (verbatim bodies — only the head changes from `defp` to `def`):

```elixir
  @doc false
  def extract_content(%{content: content_blocks}) when is_list(content_blocks) do
    content_blocks
    |> Enum.filter(fn block ->
      Map.get(block, :type) == :text || Map.get(block, "type") == "text"
    end)
    |> Enum.map(fn block ->
      Map.get(block, :text) || Map.get(block, "text") || ""
    end)
    |> Enum.join("\n")
  end

  def extract_content(_response), do: ""

  @doc false
  def extract_usage(response) when is_map(response),
    do: Map.get(response, :usage) || Map.get(response, "usage")

  def extract_usage(_response), do: nil
```

**(b)** Update EVERY call site of `extract_content(` and `extract_usage(` that is INSIDE the `defimpl` block to the qualified `Normandy.LLM.ClaudioAdapter.extract_content(...)` / `Normandy.LLM.ClaudioAdapter.extract_usage(...)`. Find them all first:

Run: `grep -n "extract_content(\|extract_usage(" lib/normandy/llm/claudio_adapter.ex`

Expected sites in the impl include at least `convert_response_to_normandy/3` (the `content = extract_content(claudio_response)` line ~735) and the normal `converse`/`do_converse` return (`{normalized_response, extract_usage(response)}` ~line 129). Rewire ALL of them; after the move, an unqualified call would fail to compile (the impl no longer defines these).

**(c)** Add the raw mapping in the outer module (next to the moved functions). It reuses the moved `extract_content/1` + `extract_usage/1`, so there is NO duplication:

```elixir
  @doc false
  # Maps a `Claudio.Messages.create/2` result to the raw-completion shape used
  # by the deserializer retry loop. Reuses extract_content/1 + extract_usage/1
  # (the same logic the normal path uses). Lives in the outer module so it is
  # unit-testable without a live Claudio call.
  def __raw_completion__({:ok, response}), do: {extract_content(response), extract_usage(response)}
  def __raw_completion__({:error, error}), do: {:error, error}
```

- [ ] **Step 4: Run the unit tests**

Run: `mix format && mix test test/llm/claudio_adapter_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the `raw` branch to `converse/7` and `converse_raw/6`**

In `lib/normandy/llm/claudio_adapter.ex`, INSIDE the `defimpl Normandy.Agents.Model` block, change the head of `converse/7` to route on `:raw`, and add `converse_raw/6`. Replace:

```elixir
    def converse(client, model, temperature, max_tokens, messages, response_model, opts \\ []) do
      # Extract tools and MCP servers from opts if provided
      tools = Keyword.get(opts, :tools, [])
```

with:

```elixir
    def converse(client, model, temperature, max_tokens, messages, response_model, opts \\ []) do
      if Keyword.get(opts, :raw, false) do
        converse_raw(client, model, temperature, max_tokens, messages, opts)
      else
        do_converse(client, model, temperature, max_tokens, messages, response_model, opts)
      end
    end

    defp do_converse(client, model, temperature, max_tokens, messages, response_model, opts) do
      # Extract tools and MCP servers from opts if provided
      tools = Keyword.get(opts, :tools, [])
```

(i.e. the existing body of `converse/7` becomes the private `do_converse/7` — rename only the head; the body is unchanged.)

Then add `converse_raw/6` immediately after `do_converse/7` closes:

```elixir
    # Raw completion: one Claudio call returning {raw_text, usage}, with no
    # schema deserialization. Used by JsonDeserializer's retry loop so it owns
    # parsing+retry without ClaudioAdapter re-entering deserialize_with_retry.
    defp converse_raw(client, model, temperature, max_tokens, messages, opts) do
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

      Normandy.LLM.ClaudioAdapter.__raw_completion__(
        Claudio.Messages.create(claudio_client, request)
      )
    end
```

- [ ] **Step 6: Run the file then the whole suite**

Run: `mix format && mix test test/llm/claudio_adapter_test.exs && mix test`
Expected: PASS (baseline + Task 4 unit tests, 0 failures). The normal `converse` path keeps identical behavior (its body moved into `do_converse/7`; `extract_content`/`extract_usage` calls now qualified to the outer module, same functions); the raw branch's live HTTP path is exercised by the Phase 2 harness, while `__raw_completion__/1` covers its mapping logic offline.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/llm/claudio_adapter.ex test/llm/claudio_adapter_test.exs
git commit -m "feat(llm): add raw-completion branch to ClaudioAdapter.converse for retry"
```

---

### Task 5: Final verification & docs

**Files:**
- Modify: `lib/normandy/llm/json_deserializer.ex` (moduledoc note on the retry raw-completion contract)

**Interfaces:** none new.

- [ ] **Step 1: Document the retry contract**

In `lib/normandy/llm/json_deserializer.ex`, add a short paragraph to the `@moduledoc` (under the existing layout/options docs) stating: on a parse-failure retry, the loop calls `Normandy.Agents.Model.converse/7` with `raw: true` to obtain raw model text (clients may ignore `raw` and return their normal shape, which is normalized via `Normandy.Agents.ConverseResult.normalize/1`); a `ClaudioAdapter` honoring `raw` returns raw text without re-entering deserialization, so the deserializer is the single parse+retry authority. Keep all existing moduledoc content.

- [ ] **Step 2: Full suite + formatter**

Run: `mix format && mix test`
Expected: PASS (baseline 1374 + all new tests from Tasks 1-4, 0 failures).

- [ ] **Step 3: Commit**

```bash
git add lib/normandy/llm/json_deserializer.ex
git commit -m "docs(llm): document the raw-completion retry contract"
```

---

## Self-Review

**Spec coverage:**
- §3 Part 1 (de-ambiguate contract) → Task 1 (`normalize/1`) + Task 2 (summarizer) + Task 3 (retry loop normalize).
- §3 Part 2 (`raw: true` single retry authority) → Task 3 (retry passes `raw: true`) + Task 4 (`ClaudioAdapter` honors `raw`).
- §4.1 ConverseResult → Task 1. §4.2 Summarizer → Task 2. §4.3 retry loop → Task 3. §4.4 ClaudioAdapter raw branch → Task 4. §4.5 test mocks → inline mocks in Tasks 2 & 3.
- §6 error handling (non-struct/non-binary → `:llm_call_failed`; raw API error → `{:error, error}`) → Task 3 `cond` true-branch + Task 4 `__raw_completion__({:error, _})`.
- §7 testing → Task 1 (normalize shapes), Task 3 (raw-recovery + tuple-recovery), Task 2 (summarizer tuple), Task 4 (mapping). §8.1 (offline raw-branch testability) → Task 4 `__raw_completion__` hook.
- §9 sequence → Tasks 1→5 mirror steps 1→5.

**Placeholder scan:** every code step shows full code; "move the body into `do_converse/7`" names the exact rename; no TBD/TODO. The only deliberately-deferred item is the raw branch's live HTTP path (covered by Phase 2), with its mapping logic unit-tested offline.

**Type consistency:** `ConverseResult.normalize/1` (Task 1) is used identically in Tasks 2 and 3. `__raw_completion__/1` returns `{binary, usage}` / `{:error, term}` (Task 4), consumed by the retry loop's `is_binary`/`true` branches (Task 3). `converse(..., raw: true)` (Task 3) is honored by `converse/7`'s routing (Task 4). The `do_converse/7` rename preserves `converse/7`'s public arity/return for all non-raw callers.
