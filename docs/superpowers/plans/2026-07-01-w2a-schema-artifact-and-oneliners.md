# W2-A: Schema Artifact Fix + Coordination One-Liners Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the wrong-schema-artifact bug (silent OUTPUT SCHEMA loss + retry-path crash for composite-typed schemas) and land the five verified one-line coordination fixes from `docs/superpowers/specs/2026-07-01-coordination-reliability-design.md` (plan W2-A).

**Architecture:** Seven independent, behavior-preserving bug fixes, each with its own TDD cycle and commit. No new modules. The only multi-line change is ParallelOrchestrator's timeout handling (spec Fix C3, orchestrator part), pulled into W2-A because `on_timeout: :kill_task` alone would emit `{:exit, :timeout}` elements that the existing reduce clause cannot match — the shape fix must ship atomically with the option.

**Tech Stack:** Elixir, ExUnit, Poison (test env JSON adapter).

## Global Constraints

- Run `mix format` before running tests (repo CLAUDE.md convention).
- All existing tests must pass at every commit; if an unrelated test breaks, fix it before proceeding (repo CLAUDE.md).
- `git add` files individually — `git add .` is forbidden (user CLAUDE.md).
- Commit messages use the repo's conventional style (`fix: …`, `test: …`); no AI attribution of any kind in commits.
- Test fixtures with composite types already exist: `Normandy.LLM.Json.TestFixtures.RecoveryFixture` (`test/support/json_test_fixtures.ex:23-29`) has `field(:facts, {:array, :string}, …)` — use it; do not invent new fixtures.
- Mock LLM clients in this codebase implement the `Normandy.Agents.Model` protocol on a `Normandy.Schema` struct (pattern: `test/batch/processor_test.exs:8-33`). Follow that pattern exactly; both `completitions/6` and `converse/7` must be defined.

---

### Task 1: RetryFeedback encodes the real JSON Schema

**Files:**
- Modify: `lib/normandy/llm/json/retry_feedback.ex:17` and `:65`
- Test: `test/llm/json/retry_feedback_test.exs`

**Interfaces:**
- Consumes: `schema.__struct__.__schema__(:specification)` — compile-time JSON Schema map, defined for every `Normandy.Schema` module (`lib/normandy/schema.ex:293-295`); always Poison-encodable.
- Produces: no signature changes. `RetryFeedback.build/4` return (String.t()) unchanged.

**Background for the implementer:** `__specification__()` returns the internal `%{field_name => type}` map whose values are terms like `{:array, :string}`. Poison has no tuple encoder, so `encode!` raises `Poison.EncodeError` for any schema with a composite-typed field — the JSON retry path crashes. For simple schemas it "works" but embeds the wrong artifact (a field→type map, not the JSON Schema the model is told to match). `__schema__(:specification)` is the real JSON Schema, a compile-time literal.

- [ ] **Step 1: Write the failing tests**

Append inside the module in `test/llm/json/retry_feedback_test.exs` (note: `RecoveryFixture` alias must be added next to the existing `RequiredField` alias at the top):

```elixir
  alias Normandy.LLM.Json.TestFixtures.RecoveryFixture

  test "json_parse_error feedback embeds real JSON Schema for composite-typed schemas" do
    feedback =
      RetryFeedback.build(
        {:json_parse_error, :invalid, "oops"},
        "oops",
        %RecoveryFixture{},
        Poison
      )

    assert feedback =~ "Required Schema"
    assert feedback =~ "properties"
    assert feedback =~ "facts"
  end

  test "validation_error feedback embeds real JSON Schema for composite-typed schemas" do
    # Changeset intentionally built from RequiredField — build/4 only uses the
    # schema argument for the Required Schema block, which is what we exercise.
    {:error, {:validation_error, changeset, content}} =
      Normandy.LLM.JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

    feedback =
      RetryFeedback.build(
        {:validation_error, changeset, content},
        content,
        %RecoveryFixture{},
        Poison
      )

    assert feedback =~ "properties"
    assert feedback =~ "facts"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix format && mix test test/llm/json/retry_feedback_test.exs`
Expected: the two new tests FAIL with `** (Poison.EncodeError)` (tuple `{:array, :string}` unencodable). All pre-existing tests in the file still pass.

- [ ] **Step 3: Fix both encode sites**

In `lib/normandy/llm/json/retry_feedback.ex`, line 17 AND line 65 are identical; change both from:

```elixir
    schema_json = adapter.encode!(schema.__struct__.__specification__(), pretty: true)
```

to:

```elixir
    schema_json = adapter.encode!(schema.__struct__.__schema__(:specification), pretty: true)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/llm/json/retry_feedback_test.exs`
Expected: ALL PASS (existing tests assert `=~ "chat_message"` / `=~ "Required Schema"` — the real JSON Schema for `RequiredField` contains both, so they keep passing).

- [ ] **Step 5: Run the neighboring retry suites (blast-radius check)**

Run: `mix test test/llm/json_deserializer_retry_test.exs test/integration/json_retry_integration_test.exs`
Expected: PASS. If any test asserted on the old field→type "Required Schema" content, update that assertion to the JSON-Schema content — the new artifact is the correct one.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/llm/json/retry_feedback.ex test/llm/json/retry_feedback_test.exs
git commit -m "fix(json): retry feedback embeds JSON Schema, not internal type map"
```

---

### Task 2: BaseAgent OUTPUT SCHEMA block survives composite types

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex:238-252`
- Create: `test/agents/base_agent_output_schema_test.exs`

**Interfaces:**
- Consumes: same `__schema__(:specification)` artifact as Task 1.
- Produces: no signature changes. System prompt content changes: the `# OUTPUT SCHEMA` block now contains the real JSON Schema and is present for ALL output schemas (previously silently absent for composite-typed ones).

**Background:** `base_agent.ex:242` encodes `__specification__()` inside a `try/rescue` whose rescue silently returns the prompt WITHOUT the OUTPUT SCHEMA block. For any output schema with a composite field, Poison raises, the rescue eats it, and the model never sees the schema. The rescue is removed deliberately (spec Fix 0): the JSON Schema literal is always encodable, so a failure there is a programming error that must crash, not silently degrade prompts.

- [ ] **Step 1: Write the failing test**

Create `test/agents/base_agent_output_schema_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentOutputSchemaTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLM.Json.TestFixtures.RecoveryFixture

  defmodule RecordingClient do
    use Normandy.Schema

    schema do
      field(:test_pid, :any)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts) do
        send(client.test_pid, {:llm_messages, messages})
        response_model
      end
    end
  end

  test "system prompt carries a real JSON Schema OUTPUT SCHEMA block for composite-typed output schemas" do
    agent =
      BaseAgent.init(%{
        client: %RecordingClient{test_pid: self()},
        model: "test-model",
        temperature: 0.0,
        output_schema: %RecoveryFixture{}
      })

    {_agent, _response} = BaseAgent.run(agent, %{chat_message: "hi"})

    assert_receive {:llm_messages, messages}, 1_000
    system = Enum.find(messages, &(&1.role == "system"))

    assert system, "expected a system message in the LLM call"
    assert system.content =~ "OUTPUT SCHEMA"
    assert system.content =~ "properties"
    assert system.content =~ "facts"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix format && mix test test/agents/base_agent_output_schema_test.exs`
Expected: FAIL on `assert system.content =~ "OUTPUT SCHEMA"` — the rescue currently strips the block for `RecoveryFixture`'s `{:array, :string}` field.

- [ ] **Step 3: Fix the artifact and remove the silent rescue**

In `lib/normandy/agents/base_agent.ex`, replace lines 238-252:

```elixir
    system_prompt_with_schema =
      if response_model do
        try do
          schema_json =
            Poison.encode!(response_model.__struct__.__specification__(), pretty: true)

          system_prompt <>
            "\n\n# OUTPUT SCHEMA\nYou MUST respond with valid JSON that exactly matches this schema. Use these exact field names:\n```json\n#{schema_json}\n```\nIMPORTANT: The response must be valid JSON with the field names shown above. Do not add extra fields or change field names."
        rescue
          _ ->
            system_prompt
        end
      else
        system_prompt
      end
```

with:

```elixir
    system_prompt_with_schema =
      if response_model do
        schema_json =
          Poison.encode!(response_model.__struct__.__schema__(:specification), pretty: true)

        system_prompt <>
          "\n\n# OUTPUT SCHEMA\nYou MUST respond with valid JSON that exactly matches this schema. Use these exact field names:\n```json\n#{schema_json}\n```\nIMPORTANT: The response must be valid JSON with the field names shown above. Do not add extra fields or change field names."
      else
        system_prompt
      end
```

(`grep -n "__specification__" lib/normandy/agents/base_agent.ex` must return zero hits afterward — line 242 was the only one.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/agents/base_agent_output_schema_test.exs`
Expected: PASS

- [ ] **Step 5: Run the agents suite (blast-radius check)**

Run: `mix test test/agents`
Expected: PASS. If a test asserted the OLD prompt content (field→type map) or relied on the missing block, update it — the new content is the spec-approved behavior.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/base_agent.ex test/agents/base_agent_output_schema_test.exs
git commit -m "fix(agents): OUTPUT SCHEMA prompt block uses real JSON Schema, never silently dropped"
```

---

### Task 3: Retry jitter guard for tiny delays

**Files:**
- Modify: `lib/normandy/resilience/retry.ex:260-263`
- Test: `test/resilience/retry_test.exs`

**Interfaces:**
- Consumes: `Retry.with_retry(fun, opts)` → `{:ok, term()} | {:error, {reason, attempts, errors}}` (existing public API, `lib/normandy/resilience/retry.ex:109-131`).
- Produces: no signature changes.

**Background:** `add_jitter/1` computes `jitter_range = div(delay, 4)`; for `delay < 4` that is `0` and `:rand.uniform(0)` raises — a transient failure with a small `base_delay` crashes the retry machinery instead of retrying.

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/resilience/retry_test.exs`:

```elixir
  test "tiny base_delay with jitter retries instead of crashing" do
    # Exact tuple internals are do_retry's business; the contract under test is
    # "returns {:error, {reason, attempts, errors}} instead of raising from
    # :rand.uniform(0)" (@spec at retry.ex:109-110).
    assert {:error, {:boom, _attempts, errors}} =
             Normandy.Resilience.Retry.with_retry(
               fn -> {:error, :boom} end,
               base_delay: 2,
               max_attempts: 2,
               jitter: true,
               retry_if: fn _ -> true end
             )

    assert is_list(errors)
  end
```

(If the file already aliases `Retry`, use the alias to match its style.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix format && mix test test/resilience/retry_test.exs`
Expected: the new test FAILS with an error raised from `:rand.uniform(0)` (ArgumentError/FunctionClauseError) instead of returning `{:error, _}`.

- [ ] **Step 3: Fix the guard**

In `lib/normandy/resilience/retry.ex`, replace lines 260-263:

```elixir
  defp add_jitter(delay) do
    jitter_range = div(delay, 4)
    delay + :rand.uniform(jitter_range * 2) - jitter_range
  end
```

with:

```elixir
  defp add_jitter(delay) do
    jitter_range = max(1, div(delay, 4))
    delay + :rand.uniform(jitter_range * 2) - jitter_range
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/resilience/retry_test.exs`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/resilience/retry.ex test/resilience/retry_test.exs
git commit -m "fix(resilience): retry jitter no longer crashes for base_delay < 4"
```

---

### Task 4: Batch.Processor survives per-item timeouts

**Files:**
- Modify: `lib/normandy/batch/processor.ex:131-135`
- Test: `test/batch/processor_test.exs`

**Interfaces:**
- Consumes: existing `MockClient` in the test file (`test/batch/processor_test.exs:8-33`, has a `:delay` field).
- Produces: no signature changes. Behavior change: an item exceeding `:timeout` now yields `nil` (ordered) or an `{:exit, :timeout}` error entry (unordered stats) instead of exiting the caller and destroying the whole batch.

**Background:** `Task.async_stream` here has no `on_timeout` option, so the default `:exit` kills the calling process on any single slow item. The `{:exit, _reason}` branches in `process_results` (`processor.ex:250`) and `results_to_stats` (`processor.ex:272`) are currently dead code that exactly handles the `{:exit, :timeout}` shape `on_timeout: :kill_task` emits — this fix makes them live.

- [ ] **Step 1: Write the failing tests**

Append inside the `describe "process_batch/3"` block in `test/batch/processor_test.exs`:

```elixir
    test "a timed-out item does not crash the batch (ordered)", %{client: client} do
      slow_agent =
        BaseAgent.init(%{
          client: %{client | delay: 500},
          model: "test-model",
          temperature: 0.7
        })

      inputs = [%{chat_message: "a"}, %{chat_message: "b"}]

      {:ok, results} = Processor.process_batch(slow_agent, inputs, timeout: 100)
      assert results == [nil, nil]
    end

    test "a timed-out item is reported in stats (unordered)", %{client: client} do
      slow_agent =
        BaseAgent.init(%{
          client: %{client | delay: 500},
          model: "test-model",
          temperature: 0.7
        })

      inputs = [%{chat_message: "a"}]

      {:ok, stats} =
        Processor.process_batch(slow_agent, inputs, timeout: 100, ordered: false)

      assert stats.success == []
      assert stats.error_count == 1
      assert Enum.any?(stats.errors, &match?({:exit, :timeout}, &1))
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix format && mix test test/batch/processor_test.exs`
Expected: both new tests FAIL — the test process EXITS with `{:timeout, {Task.Supervised, :stream, [100]}}` (ExUnit reports the exit, not an assertion failure).

- [ ] **Step 3: Add the option**

In `lib/normandy/batch/processor.ex`, replace lines 132-135:

```elixir
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: ordered
      )
```

with:

```elixir
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: ordered,
        on_timeout: :kill_task
      )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/batch/processor_test.exs`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/batch/processor.ex test/batch/processor_test.exs
git commit -m "fix(batch): per-item timeout no longer kills the whole batch"
```

---

### Task 5: ParallelOrchestrator survives per-agent timeouts

**Files:**
- Modify: `lib/normandy/coordination/parallel_orchestrator.ex:122-176`
- Create: `test/coordination/parallel_orchestrator_test.exs`

**Interfaces:**
- Consumes: `ParallelOrchestrator.execute(agent_specs, opts)` (advanced API, `parallel_orchestrator.ex:93-96`); each spec is `%{id: _, agent: _, input: _}`.
- Produces: no signature changes. Behavior change: a timed-out agent becomes `errors[agent_id] = {:exit, :timeout}` in the execution result instead of exiting the caller. The `:ordered` option is removed from the stream call (it never affected the output — results are keyed maps); its doc line is deleted.

**Background (why this is more than one line):** adding `on_timeout: :kill_task` makes the stream emit `{:exit, :timeout}` — WITHOUT an agent_id. The existing reduce clause pattern-matches `{:exit, {agent_id, reason}}`, a shape that can never occur, so the option alone converts a caller-exit into a `FunctionClauseError` in the reduce. The stream must run `ordered: true` internally and be zipped with the input specs to attribute exits (spec Fix C3, ParallelOrchestrator part — pulled into W2-A for atomicity).

- [ ] **Step 1: Write the failing test**

Create `test/coordination/parallel_orchestrator_test.exs`:

```elixir
defmodule Normandy.Coordination.ParallelOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.ParallelOrchestrator

  defmodule MockClient do
    use Normandy.Schema

    schema do
      field(:delay, :integer, default: 0)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        if client.delay > 0, do: Process.sleep(client.delay)
        %{response_model | chat_message: "Response"}
      end
    end
  end

  defp agent(delay) do
    BaseAgent.init(%{
      client: %MockClient{delay: delay},
      model: "test-model",
      temperature: 0.7
    })
  end

  test "one timed-out agent does not destroy the other agents' results" do
    specs = [
      %{id: "fast", agent: agent(0), input: %{chat_message: "hi"}},
      %{id: "slow", agent: agent(500), input: %{chat_message: "hi"}}
    ]

    {:ok, result} = ParallelOrchestrator.execute(specs, timeout: 100)

    assert Map.has_key?(result.results, "fast")
    assert result.errors["slow"] == {:exit, :timeout}
    refute result.success
  end

  test "all agents completing yields no errors" do
    specs = [
      %{id: "a", agent: agent(0), input: %{chat_message: "hi"}},
      %{id: "b", agent: agent(0), input: %{chat_message: "hi"}}
    ]

    {:ok, result} = ParallelOrchestrator.execute(specs, [])

    assert result.success
    assert map_size(result.results) == 2
    assert result.errors == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix format && mix test test/coordination/parallel_orchestrator_test.exs`
Expected: the timeout test FAILS — the test process EXITS with `{:timeout, {Task.Supervised, :stream, [100]}}`. The all-complete test PASSES (it exercises today's happy path).

- [ ] **Step 3: Fix the stream call and exit attribution**

In `lib/normandy/coordination/parallel_orchestrator.ex`:

(a) Delete line 128 (`ordered = Keyword.get(opts, :ordered, false)`) and the `- \`:ordered\` - Return results in spec order (default: false)` doc line above `execute/2`. Run `grep -n "ordered" lib/normandy/coordination/parallel_orchestrator.ex` — remaining hits must only be the `ordered: true` introduced below.

(b) Replace the pipeline beginning `results =` (through `|> Enum.to_list()`) AND the `{successes, errors} = Enum.reduce(...)` block that follows it (lines 130-176 before the deletion in (a) shifts numbering) with:

```elixir
    # Execute agents in parallel using Task.async_stream.
    # ordered: true + zip attributes timeouts to their agent_id; on_timeout
    # converts a slow agent into a per-agent error instead of killing us.
    results =
      agent_specs
      |> Task.async_stream(
        fn spec ->
          agent_id = Map.fetch!(spec, :id)
          agent = Map.fetch!(spec, :agent)
          input = Map.fetch!(spec, :input)
          transform_fn = Map.get(spec, :transform, & &1)

          result =
            case execute_agent(agent, input) do
              {:ok, agent_result} ->
                transformed = transform_fn.(agent_result)

                if on_complete do
                  on_complete.(agent_id, transformed)
                end

                {:ok, transformed}

              {:error, reason} ->
                {:error, reason}
            end

          {agent_id, result}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: true,
        on_timeout: :kill_task
      )
      |> Enum.zip(agent_specs)
      |> Enum.map(fn
        {{:ok, {agent_id, result}}, _spec} -> {agent_id, result}
        {{:exit, reason}, spec} -> {Map.fetch!(spec, :id), {:error, {:exit, reason}}}
      end)

    # Separate successes and errors
    {successes, errors} =
      Enum.reduce(results, {%{}, %{}}, fn
        {agent_id, {:ok, result}}, {succ, err} ->
          {Map.put(succ, agent_id, result), err}

        {agent_id, {:error, reason}}, {succ, err} ->
          {succ, Map.put(err, agent_id, reason)}
      end)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/coordination/parallel_orchestrator_test.exs`
Expected: ALL PASS

- [ ] **Step 5: Run the coordination suite (blast-radius check)**

Run: `mix test test/coordination`
Expected: PASS. `execute_same_input/3` and the simple API funnel through the same `execute_with_specs/2`, so they inherit the fix; if any existing test passed `:ordered` in opts, delete that option from the call (it was a no-op).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/coordination/parallel_orchestrator.ex test/coordination/parallel_orchestrator_test.exs
git commit -m "fix(coordination): parallel orchestrator survives per-agent timeouts"
```

---

### Task 6: SequentialOrchestrator simple API returns errors instead of crashing

**Files:**
- Modify: `lib/normandy/coordination/sequential_orchestrator.ex:92-94`
- Create: `test/coordination/sequential_orchestrator_test.exs`

**Interfaces:**
- Consumes: `SequentialOrchestrator.execute(agents, input)` simple API (`sequential_orchestrator.ex:72-95`).
- Produces: no signature changes — the `@spec` already declares `{:error, term()}` as a possible return (`sequential_orchestrator.ex:67-68`); the implementation finally honors it.

**Background:** the simple API crash-matches `{:ok, %{results: results}} =` on `execute_with_specs/3`, which returns `{:error, %{...}}` whenever a pipeline agent fails under the default `on_error: :stop` — any agent failure raises `MatchError` in the caller instead of returning the error.

- [ ] **Step 1: Write the failing test**

Create `test/coordination/sequential_orchestrator_test.exs`:

```elixir
defmodule Normandy.Coordination.SequentialOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.SequentialOrchestrator

  defmodule MockClient do
    use Normandy.Schema

    schema do
      field(:failure_rate, :float, default: 0.0)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        if :rand.uniform() < client.failure_rate do
          raise "Simulated failure"
        end

        %{response_model | chat_message: "Response"}
      end
    end
  end

  defp agent(failure_rate) do
    BaseAgent.init(%{
      client: %MockClient{failure_rate: failure_rate},
      model: "test-model",
      temperature: 0.7
    })
  end

  test "simple API returns {:error, _} when a pipeline agent fails" do
    assert {:error, _} = SequentialOrchestrator.execute([agent(1.0)], %{chat_message: "hi"})
  end

  test "simple API returns the final result when the pipeline succeeds" do
    assert {:ok, result} = SequentialOrchestrator.execute([agent(0.0)], %{chat_message: "hi"})
    assert result.chat_message == "Response"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix format && mix test test/coordination/sequential_orchestrator_test.exs`
Expected: the failure test FAILS with `** (MatchError) no match of right hand side value: {:error, %{...}}`. The success test PASSES.

- [ ] **Step 3: Fix the match**

In `lib/normandy/coordination/sequential_orchestrator.ex`, replace lines 92-94:

```elixir
        # Execute and return just the final result
        {:ok, %{results: results}} = execute_with_specs(agent_specs, input, [])
        {:ok, List.last(results)}
```

with:

```elixir
        # Execute and return just the final result
        case execute_with_specs(agent_specs, input, []) do
          {:ok, %{results: results}} -> {:ok, List.last(results)}
          {:error, _} = error -> error
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/coordination/sequential_orchestrator_test.exs`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/sequential_orchestrator.ex test/coordination/sequential_orchestrator_test.exs
git commit -m "fix(coordination): sequential orchestrator simple API returns errors"
```

---

### Task 7: AgentPool checkout strategies un-inverted

**Files:**
- Modify: `lib/normandy/coordination/agent_pool.ex:377-382`
- Test: `test/coordination/agent_pool_test.exs`

**Interfaces:**
- Consumes: `AgentPool.start_link(agent_config:, size:, strategy:)`, `checkout/1` → `{:ok, pid}`, `checkin/2` → `:ok` (existing API; usage pattern at `test/coordination/agent_pool_test.exs:194-242`).
- Produces: no signature changes. Behavior change: `:lifo` now actually returns the most recently checked-in agent, `:fifo` the least recently — previously each did the other.

**Background:** `do_checkin` PREPENDS to `available` (`agent_pool.ex:410`), so the head is the newest. `do_checkout`'s `:lifo` takes `List.last` (the oldest — FIFO behavior) and `:fifo` takes `List.first` (the newest — LIFO behavior). Semantics inverted. Minimal swap here; W2-B's pool rebuild replaces the list with proper structures. Ordering note for the tests: `checkin/2` is a cast, but BEAM guarantees signals from one sender to one receiver are processed in order, so a subsequent `checkout` call from the same test process always observes prior checkins.

- [ ] **Step 1: Write the failing tests**

Append a new describe block inside `test/coordination/agent_pool_test.exs` (it already defines `create_agent_config/0`):

```elixir
  describe "checkout strategy semantics" do
    test ":lifo returns the most recently checked-in agent" do
      {:ok, pool} =
        AgentPool.start_link(agent_config: create_agent_config(), size: 2, strategy: :lifo)

      {:ok, p1} = AgentPool.checkout(pool)
      {:ok, p2} = AgentPool.checkout(pool)
      :ok = AgentPool.checkin(pool, p1)
      :ok = AgentPool.checkin(pool, p2)

      assert {:ok, ^p2} = AgentPool.checkout(pool)
      AgentPool.stop(pool)
    end

    test ":fifo returns the least recently checked-in agent" do
      {:ok, pool} =
        AgentPool.start_link(agent_config: create_agent_config(), size: 2, strategy: :fifo)

      {:ok, p1} = AgentPool.checkout(pool)
      {:ok, p2} = AgentPool.checkout(pool)
      :ok = AgentPool.checkin(pool, p1)
      :ok = AgentPool.checkin(pool, p2)

      assert {:ok, ^p1} = AgentPool.checkout(pool)
      AgentPool.stop(pool)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix format && mix test test/coordination/agent_pool_test.exs`
Expected: both new tests FAIL on the pin-match (each strategy returns the other's agent). All pre-existing pool tests pass.

- [ ] **Step 3: Swap the strategy clauses**

In `lib/normandy/coordination/agent_pool.ex`, replace lines 378-382:

```elixir
    {agent_pid, remaining} =
      case strategy do
        :lifo -> {List.last(available), Enum.drop(available, -1)}
        :fifo -> {List.first(available), Enum.drop(available, 1)}
      end
```

with:

```elixir
    # do_checkin prepends, so the head is the newest agent.
    {agent_pid, remaining} =
      case strategy do
        :lifo -> {List.first(available), Enum.drop(available, 1)}
        :fifo -> {List.last(available), Enum.drop(available, -1)}
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/coordination/agent_pool_test.exs`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_pool.ex test/coordination/agent_pool_test.exs
git commit -m "fix(coordination): agent pool :lifo/:fifo strategies were inverted"
```

---

### Task 8: Full-suite verification

**Files:**
- No source changes. This task gates W2-A completion.

- [ ] **Step 1: Format check**

Run: `mix format --check-formatted`
Expected: exits 0. If not, `mix format`, amend the offending commit or add a `style:` commit.

- [ ] **Step 2: Full test suite**

Run: `mix test`
Expected: ALL PASS, zero failures. Repo rule: any failing test — related or not — must be fixed before W2-A is complete.

- [ ] **Step 3: Verify no stray artifact references remain**

Run: `grep -rn "encode!(.*__specification__" lib/`
Expected: no output. (`__specification__/0` itself legitimately remains in `validate.ex:104` and `schema_binder.ex` — those consume the type map on purpose; only encoding-for-prompt sites were wrong.)

- [ ] **Step 4: Report**

Report per-task: `VERIFY: Ran <command> — Result: PASS/FAIL`. W2-A done; W2-B (pool internals + breaker) is next per the spec's packaging table.
