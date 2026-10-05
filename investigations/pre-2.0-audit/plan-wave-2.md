# Normandy 2.0 — Wave 2 Implementation Plan (Model protocol, error model, entry points)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the positional `Model.converse/7` protocol with `converse/3` + `stream/3` over request/response structs, make every turn entry point return `{:ok, config, output} | {:error, exception}` (with raising `!` variants), and collapse the five run/stream entry points into `run/2,3`, `run!/2,3` and `stream/3`.

**Architecture:** The provider-facing change (Tasks 2.1–2.3) lands first and keeps the user-facing API unchanged. The error model (Tasks 2.4–2.6) then changes what callers receive, first in `BaseAgent` and its in-library callers, then in `Turn.Server`. The user-facing entry points (Tasks 2.7–2.8) change last, and Task 2.9 pins the README quickstart with a test. Every task ends green on the full suite, so each commit is a working library.

**Tech Stack:** Elixir ~> 1.15, ExUnit, Req.Test (HTTP stubs), Claudio (path dep `../Claudio`), telemetry.

**Spec:** `investigations/pre-2.0-audit/decisions.md`: decisions 5, 6 and 13, and **decision 15** (Wave 2 details Q settled on 2026-10-04). Roadmap and findings: `plan.md` §"Wave 2", `devex.md` (DX-2, DX-4, DX-5, DX-11, DX-12, DX-30), `telemetry.md` (TEL-2), `security.md` (SEC-5).

**Findings closed:** DX-2, DX-4, DX-5 (except DSL `new/1`, which moves to Task 3.1 with the NimbleOptions `init/1`), DX-11, DX-12 (the rest of it), DX-30, TEL-2, SEC-5/TEL-4. Wave 1 deferred minors closed here: `reactive_test.exs:381` vacuous assertion (Task 2.4), `%BaseAgentInputSchema{chat_message: nil}` validation bypass (Task 2.7), `guide_examples_test.exs:57` silent `String.replace` (Task 2.9), the missing Task 1.3 and 1.4 MIGRATING lines (Task 2.0). Wave 1 whole-wave review findings I2, I3, M1, M2, M5 (Tasks 2.0 and 2.4); I1 is open for Q.

**Out of scope (owner):** `Request.output_format`/`tool_choice` (YAGNI here; Task 5.1 adds what it needs), orchestrator/batch/A2A error shapes (Task 3.5; here they switch to `run!/2` and keep today's behaviour), `Turn.Session.approve/2` errors (Task 3.5), DSL `new/1` return shape (Task 3.1), the `examples/` projects (Wave 7: they use a path dep and are not in `mix precommit`).

## Global Constraints

- Elixir `~> 1.15`; CI matrix Elixir 1.15–1.19 on OTP 26–28. Anything newer than 1.15 needs a guard.
- Each task ends with `mix format` then `mix test` showing ` 0 failures`; the wave ends with `mix precommit` exit 0. Gate on the literal ` 0 failures`, never on `| tail` output alone.
- Credo: stock `.credo.exs`. Complexity or nesting findings get an inline `# credo:disable-for-next-line`, never a threshold change.
- Dialyzer: a new `.dialyzer_ignore.exs` entry needs a reason comment.
- Every emitted telemetry event is documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs` enforces it).
- A new Turn core effect must be wired into all three interpreters (`Turn.Driver`, `Turn.Inline`, `Turn.Server`). This wave adds none; it changes how `Turn.Server` reports failures.
- No silent fallbacks (`|| default`, `rescue _ ->`) that turn a hard failure into wrong data. Error messages say what was expected and what was received.
- Never log or put into telemetry a stacktrace's arguments or a config value (Turn.Server's `describe_crash/3` and `arity_only/1` policy). Stacktraces are logged only; they are never persisted, replied or emitted.
- Commits: conventional messages; add files individually (`git add .` is forbidden); no AI attribution lines. Do not push or merge.
- `MIGRATING-2.0.md` is updated in the task that makes the change (Task 7.1 audits it at the end).
- If any test fails, fix it, even outside the task's scope.

## Review Focus

1. **A 429 after tools already ran, under `Turn.Server`.** The caller gets `{:error, %LLMError{type: :rate_limit}}`; the persisted turn state, the run `:exception` telemetry and the reply hold no stacktrace; the server stays alive. Test: Task 2.5.
2. **A third-party `Model` implementation still written for 1.x** (returns a bare struct from `converse/3`). Expect an `ArgumentError` naming the implementation, the expected shape and the received type, not a `MatchError` deep inside the turn. Test: Task 2.2.
3. **A session whose store is down.** `Turn.Session.run/2` and `Turn.Server.run/2` return `{:error, %Normandy.TurnError{type: :session_unavailable}}`, never a raw store term or tagged tuple. Test: Task 2.5.
4. **A non-chat `output_schema` through `stream/3` whose final text is not JSON.** Expect the same result `run/2` gives for that answer (`{:error, %LLMError{type: :invalid_output}}` under `on_parse_failure: :error`), never the raw message map. Test: Task 2.8.
5. **A stream that fails after text already reached the callback.** Expect `{:error, %LLMError{type: :stream}}` from `stream/3`, no retry (the callback saw output), and the callback's received events unchanged. Test: Task 2.8.

---

### Task 2.0: Wave 1 review follow-ups

The whole-wave review of `f7991a9..481b0fd` (2026-10-04) found no critical issues and these follow-ups. **I1** (the OpenAI adapter now always sends `max_tokens: 16_000`) is decided (option (b), see "Decided by Q" at the end) and lands in Task 2.2 Step 6, not in this task.

**Files:**
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex:36-41` (`build_manager/2` → `/3`)
- Modify: `lib/normandy/agents/validation_middleware.ex:103` (string `"__meta__"`)
- Modify: `test/formatter_export_test.exs`, `.formatter.exs`
- Modify: `MIGRATING-2.0.md` (new §17 and §18)
- Test: `test/behaviours/compactor/window_manager_test.exs` (add cases; find the existing compactor test with `grep -rln "Compactor.WindowManager" test`), `test/agents/validation_middleware_test.exs`

- [ ] **Step 1: Write the failing tests**

The compactor reserves the agent's `max_tokens` for the answer (review I2: it reserved a fixed 4096 while every request now asks for 16_000):

```elixir
    test "reserves the agent's max_tokens for the answer by default" do
      config = %{config_with_history() | max_tokens: 16_000}

      {_config, meta} =
        Normandy.Behaviours.Compactor.WindowManager.maybe_compact(config, %{window: 20_000}, [])

      # 20_000 window - 16_000 reserved = 4_000 tokens of history at most
      assert meta.tokens_after <= 4_000
    end

    test "an explicit :reserved_tokens wins" do
      config = %{config_with_history() | max_tokens: 16_000}

      {_config, meta} =
        Normandy.Behaviours.Compactor.WindowManager.maybe_compact(config, %{window: 20_000},
          reserved_tokens: 1_000
        )

      assert meta.tokens_after > 4_000
    end

    test "a reserve that leaves no room for history raises naming both numbers" do
      config = %{config_with_history() | max_tokens: 16_000}

      assert_raise ArgumentError, ~r/reserved_tokens \(16000\).*context window \(8000\)/, fn ->
        Normandy.Behaviours.Compactor.WindowManager.maybe_compact(config, %{window: 8_000}, [])
      end
    end
```

`config_with_history/0` is whatever helper the existing test file uses to build a config whose history exceeds ~5_000 estimated tokens; write one if none exists (a `BaseAgentConfig` from `BaseAgent.init/1` with a `StubClient` and 40 user/assistant messages of ~600 characters). Adjust the meta key to what `run/2` reports (`:tokens_after`, see the moduledoc's "measurements") without weakening the bounds.

A string-keyed `"__meta__"` is accepted like the atom one (review M5), in `validation_middleware_test.exs`:

```elixir
    test "the default schema ignores a string-keyed __meta__ like the atom one" do
      assert {:ok, %BaseAgentInputSchema{chat_message: "x"}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{"chat_message" => "x", "__meta__" => %{}}
               )
    end
```

The formatter export test derives the macro list instead of naming it (review M2). Replace `@dsl_macros` and the test in `test/formatter_export_test.exs` with:

```elixir
  @dsl_modules [Normandy.DSL.Agent, Normandy.DSL.Workflow, Normandy.Schema]
  # Compiler hooks are never written by users.
  @not_user_macros [:__using__, :__before_compile__]

  test "every public DSL macro is exported without parens at every arity" do
    {opts, _} = Code.eval_file(".formatter.exs")
    exported = opts |> Keyword.fetch!(:export) |> Keyword.fetch!(:locals_without_parens)

    for mod <- @dsl_modules,
        {name, arity} <- mod.__info__(:macros),
        name not in @not_user_macros do
      assert {name, arity} in exported, "#{inspect(mod)}.#{name}/#{arity} is not exported"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/formatter_export_test.exs test/agents/validation_middleware_test.exs <the compactor test file>`
Expected: the formatter test names the unexported macros (the review found `tool_schema/3` and `when_result/3`); the `"__meta__"` test gets `:unknown_keys`; the compactor tests see `tokens_after` above 4_000 and no raise.

- [ ] **Step 3: Reserve `max_tokens` in the compactor**

In `lib/normandy/behaviours/compactor/window_manager.ex`, `maybe_compact/3` calls `build_manager(window, opts, acc)`, and:

```elixir
  # Honour an explicit opts :max_tokens; otherwise use the model window; if
  # neither is known, skip (no trigger basis). The answer's room is the agent's
  # max_tokens unless opts pins :reserved_tokens.
  defp build_manager(window, opts, acc) do
    opts = Keyword.put_new(opts, :reserved_tokens, Map.fetch!(acc, :max_tokens))

    cond do
      Keyword.has_key?(opts, :max_tokens) -> checked_manager(opts)
      is_integer(window) -> checked_manager(Keyword.put(opts, :max_tokens, window))
      true -> nil
    end
  end

  defp checked_manager(opts) do
    reserved = Keyword.fetch!(opts, :reserved_tokens)
    window = Keyword.fetch!(opts, :max_tokens)

    if reserved >= window do
      raise ArgumentError,
            "Compactor.WindowManager: reserved_tokens (#{reserved}) must be smaller than " <>
              "the context window (#{window}); lower the agent's max_tokens or pass " <>
              ":reserved_tokens in the compactor opts"
    end

    WM.new(opts)
  end
```

Update the moduledoc paragraph on `opts`: "`:reserved_tokens` defaults to the agent's `max_tokens`". `Normandy.Context.WindowManager.new/1`'s own 4096 default stays for direct callers.

- [ ] **Step 4: Accept a string `"__meta__"`**

In `validate_base_input/1` (`validation_middleware.ex`), change `Map.keys(input_map) -- [:chat_message, :__meta__]` to `Map.keys(input_map) -- [:chat_message, :__meta__, "__meta__"]`. (`atomize_field_keys/2` already turned a string `"chat_message"` into the atom.)

- [ ] **Step 5: Export the two macros**

Add `tool_schema: 3` to the `# Normandy.DSL.Agent` group and `when_result: 3` to the `# Normandy.DSL.Workflow` group in `.formatter.exs` (use the arities the test reports).

- [ ] **Step 6: Record the Wave 1 behaviour changes in MIGRATING**

Append before "## New, non-breaking" in `MIGRATING-2.0.md`:

```markdown
## 17. `max_tokens` defaults to 16_000

`BaseAgent.init/1`, the DSL and `ConfigTemplate.rebuild/3` now always send `max_tokens`
(the Messages API requires it): 16_000 unless you set it. In 1.x `init/1` left it unset and
the DSL defaulted to 4096.

- An explicit `max_tokens: nil` (for example `max_tokens: opts[:max_tokens]`) now raises
  `ArgumentError`. Leave the key out to get the default.
- `Compactor.WindowManager` now reserves the agent's `max_tokens` for the answer (it was a
  fixed 4096), so it keeps less history. Pass `:reserved_tokens` in the compactor opts to
  choose; a reserve as large as the context window raises.

## 18. The default input schema rejects what it used to drop

With the default `BaseAgentInputSchema`, input must be `%{chat_message: string}`. An unknown
key (`%{chat_mesage: "hi"}`), a missing or `nil` `chat_message`, or a non-string one now
fails validation (`Normandy.Schema.ValidationError`) instead of sending an empty user turn.

This also reaches input you don't build by hand:
- `SequentialOrchestrator`, `ParallelOrchestrator`, `AgentProcess` and `Reactive` pass an
  agent's output to the next agent. An agent with a custom output struct feeding a
  default-schema agent now fails; add a transform that produces `%{chat_message: text}`.
- An `on_prompt` hook that rewrites the input to another map is validated the same way.
- A previous agent's reply whose `chat_message` is `nil` no longer becomes an empty turn.
```

- [ ] **Step 7: Run and commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`. A compactor test elsewhere that used a small window with the default `max_tokens` now raises: give it an explicit `reserved_tokens:` (or `max_tokens:` on its agent) and list each such test in the commit body.

```bash
git add lib/normandy/behaviours/compactor/window_manager.ex lib/normandy/agents/validation_middleware.ex .formatter.exs test/formatter_export_test.exs test/agents/validation_middleware_test.exs MIGRATING-2.0.md
# plus the compactor test file(s) by name
git commit -m "fix(compactor): reserve the agent's max_tokens; record Wave 1 behaviour changes in MIGRATING"
```

---

### Task 2.1: `Normandy.LLM.Request` and `Normandy.LLM.Response`

The data contract every later task uses. Pure structs; no protocol change yet.

**Files:**
- Create: `lib/normandy/llm/request.ex`
- Create: `lib/normandy/llm/response.ex`
- Modify: `lib/normandy/llm/error.ex` (add type `:unsupported`)
- Test: `test/llm/request_response_test.exs` (create)
- Test: `test/llm/llm_error_test.exs` (add one case; create the file if it doesn't exist)

**Interfaces:**
- Produces: `%Normandy.LLM.Request{model, system, messages, response_model, temperature, max_tokens, tools, mcp_servers, task_budget_remaining}` with `@enforce_keys [:model, :messages, :max_tokens]`; `Request.t()`.
- Produces: `%Normandy.LLM.Response{content, stop_reason, usage, meta}` with `@enforce_keys [:content]`, `meta` default `%{}`; `Response.t()`, `Response.stop_reason()`.
- Produces: `Normandy.LLMError.new(type: :unsupported, retryable?: false, detail: ...)` is accepted.

- [ ] **Step 1: Write the failing tests**

Create `test/llm/request_response_test.exs`:

```elixir
defmodule Normandy.LLM.RequestResponseTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.{Request, Response}

  test "a request needs model, messages and max_tokens" do
    assert_raise ArgumentError, ~r/the following keys must also be given.*:max_tokens/, fn ->
      struct!(Request, model: "m", messages: [])
    end
  end

  test "a request defaults the optional fields" do
    request = %Request{model: "m", messages: [%Message{role: "user", content: "hi"}], max_tokens: 10}

    assert %Request{
             system: nil,
             response_model: nil,
             temperature: nil,
             tools: [],
             mcp_servers: nil,
             task_budget_remaining: nil
           } = request
  end

  test "a response needs content and defaults the rest" do
    assert %Response{content: "x", stop_reason: nil, usage: nil, meta: %{}} =
             %Response{content: "x"}

    assert_raise ArgumentError, fn -> struct!(Response, []) end
  end
end
```

Add to `test/llm/llm_error_test.exs` (inside its module; create the module with `use ExUnit.Case, async: true` if the file is new):

```elixir
  test ":unsupported is a known type" do
    assert %Normandy.LLMError{type: :unsupported, retryable?: false} =
             Normandy.LLMError.new(type: :unsupported, retryable?: false, detail: "no streaming")
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/llm/request_response_test.exs test/llm/llm_error_test.exs`
Expected: FAIL: `Normandy.LLM.Request` is undefined; `LLMError.new/1` raises `unknown :type :unsupported`.

- [ ] **Step 3: Create the request struct**

`lib/normandy/llm/request.ex`:

```elixir
defmodule Normandy.LLM.Request do
  @moduledoc """
  One call to a model: what `Normandy.Agents.Model.converse/3` and
  `Normandy.Agents.Model.stream/3` receive.

  - `:model` - the model id
  - `:system` - the system prompt, or `nil`. `:messages` never holds a `"system"` message.
  - `:messages` - the conversation, oldest first, as `Normandy.Components.Message` structs
  - `:response_model` - an empty struct of the shape the caller expects back (see
    "Response content" in `Normandy.Agents.Model`), or `nil` for the answer as text
  - `:temperature` - `nil` leaves it unset (Opus 4.7+ reject sampling parameters)
  - `:max_tokens` - required by the Messages API
  - `:tools` - tool schemas, `%{name:, description:, input_schema:}` maps
  - `:mcp_servers` - MCP server configs for server-side MCP, or `nil`
  - `:task_budget_remaining` - the remaining task budget after in-turn compaction, or `nil`
  """

  alias Normandy.Components.Message

  @enforce_keys [:model, :messages, :max_tokens]
  defstruct model: nil,
            system: nil,
            messages: [],
            response_model: nil,
            temperature: nil,
            max_tokens: nil,
            tools: [],
            mcp_servers: nil,
            task_budget_remaining: nil

  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t() | nil,
          messages: [Message.t()],
          response_model: struct() | nil,
          temperature: float() | nil,
          max_tokens: pos_integer(),
          tools: [map()],
          mcp_servers: [struct() | map()] | nil,
          task_budget_remaining: non_neg_integer() | nil
        }
end
```

If `Normandy.Components.Message` has no `t/0` type, use `struct()` in the spec instead (check with `grep -n "@type t" lib/normandy/components/message.ex`).

- [ ] **Step 4: Create the response struct**

`lib/normandy/llm/response.ex`:

```elixir
defmodule Normandy.LLM.Response do
  @moduledoc """
  A model's answer to one `Normandy.LLM.Request`.

  - `:content` - the request's `response_model` filled in, or the answer text when the
    request's `response_model` was `nil`
  - `:stop_reason` - why the model stopped (`:end_turn`, `:tool_use`, `:max_tokens`,
    `:stop_sequence`, `:pause_turn`, `:refusal`, `:model_context_window_exceeded`,
    `:compaction`), or `nil` when the client doesn't report one
  - `:usage` - the provider's token usage map, or `nil`
  - `:meta` - per-call facts that are not usage: `:served_by`, `:fallback_model`,
    `:input_transformations`, `:response_id`, `:finish_reason` (the stop reason as a
    string, for telemetry)
  """

  @enforce_keys [:content]
  defstruct content: nil, stop_reason: nil, usage: nil, meta: %{}

  @type stop_reason ::
          :end_turn
          | :tool_use
          | :max_tokens
          | :stop_sequence
          | :pause_turn
          | :refusal
          | :model_context_window_exceeded
          | :compaction
          | atom()

  @type t :: %__MODULE__{
          content: struct() | String.t(),
          stop_reason: stop_reason() | nil,
          usage: map() | nil,
          meta: map()
        }
end
```

- [ ] **Step 5: Add `:unsupported` to `LLMError`**

In `lib/normandy/llm/error.ex`, add `:unsupported` after `:circuit_open` in both `@types` and `@type error_type`. In the moduledoc's field list, after the `:type` line, add nothing; instead add this paragraph after the first paragraph of the moduledoc:

```
  `type: :unsupported` means the client can't do what was asked (a client without
  streaming answering `Normandy.Agents.Model.stream/3`); it is never retryable.
```

- [ ] **Step 6: Run the tests**

Run: `mix format && mix test test/llm/request_response_test.exs test/llm/llm_error_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/llm/request.ex lib/normandy/llm/response.ex lib/normandy/llm/error.ex test/llm/request_response_test.exs test/llm/llm_error_test.exs
git commit -m "feat(llm): add Request and Response structs and the :unsupported error type"
```

---

### Task 2.2: The two-function `Model` protocol (decision 5; DX-2, DX-4)

One atomic change: the protocol, both adapters, every caller and every test client move together, because a protocol change does not compile half-done. The **user-facing** API does not change in this task: `run/2`, `stream_response/3` and the arity-2 stream callback behave as before. Streaming moves the callback out of the adapters: an adapter's `stream/3` returns events, and `BaseAgent` calls the user's callback.

**Files:**
- Rewrite: `lib/normandy/agents/model.ex`
- Create: `lib/normandy/llm/call.ex`
- Delete: `lib/normandy/agents/converse_result.ex`, `test/agents/converse_result_test.exs`
- Modify: `lib/normandy/llm/claudio_adapter.ex` (impl block lines 150–1031; `__structured_schema_for__/3`, `__raw_completion__/1`, moduledoc "Errors")
- Modify: `lib/normandy/llm/openai_compatible_adapter.ex:92-97,181-260` (impl block; `build_body/5`, new `validate_options!/1`, `:max_tokens_param`)
- Modify: `lib/normandy/llm/json_deserializer.ex` (public `deserialize_with_retry/5`, retry loop, moduledoc "Retry raw-completion contract")
- Modify: `lib/normandy/context/summarizer.ex:218-262`
- Modify: `lib/normandy/telemetry/provider.ex:110-118`
- Modify: `lib/normandy/agents/base_agent.ex` (`get_response_with_usage/3` 292–367, `call_llm_with_resilience/4` 374–410, `task_budget_call_opts/2` 692–700, `call_turn_llm/3` 702–758, `build_stream_messages/1` 1415–1437, `stream_opts/2` 1439–1455, `stream_llm_attempt/4` 1096–1128, `stream_attempt/3` 1522–1580)
- Modify docs that name the old functions: `lib/normandy/llm/error.ex:5`, `lib/normandy/telemetry/request.ex:24`, `lib/normandy/telemetry.ex` (every `converse/7`), `CLAUDE.md` (Model protocol bullet), `MIGRATING-2.0.md` §4
- Modify test clients: `test/support/{stub_client,model_mockup,scripted_tool_client,streaming_probe_client,tagging_client,mock_summarizer_client}.ex` and every inline `defimpl Normandy.Agents.Model` in `test/` (`grep -rln "defimpl Normandy.Agents.Model" test`, 19 files today)
- Modify adapter/deserializer tests that call the old functions: `test/llm/claudio_adapter*_test.exs`, `test/llm/openai_compatible_adapter_test.exs`, `test/llm/json_deserializer*_test.exs`, plus any test that receives StubClient's `{:converse, messages, opts}` notification (`grep -rln "{:converse," test`, 8 files)
- Test: `test/agents/model_protocol_test.exs` (create)

**Interfaces:**
- Consumes: Task 2.1's `Request`, `Response`, `LLMError` `:unsupported`.
- Produces: `Normandy.Agents.Model.converse(client, Request.t(), keyword()) :: {:ok, Response.t()} | {:error, LLMError.t()}`; `Normandy.Agents.Model.stream(client, Request.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, LLMError.t()}`. `__protocol__(:functions) == [converse: 3, stream: 3]`.
- Produces: `Normandy.LLM.Call.converse/3` and `Normandy.LLM.Call.stream/3` (`@moduledoc false`): dispatch through the protocol and raise `ArgumentError` on any other return. Every library caller goes through them.
- Produces: `Normandy.LLM.JsonDeserializer.deserialize_with_retry(content, schema, client, Request.t(), opts) :: {:ok, struct()} | {:error, term()}` (was 8 positional args). A retry sends `%{request | messages: augmented, response_model: nil}`.
- Produces: `StubClient` notifies `{:converse, %Request{}, opts}` (was `{:converse, messages, opts}`); its `stream/3` returns `{:error, %LLMError{type: :unsupported}}`.
- Produces: `ClaudioAdapter.__structured_schema_for__(client, response_model, tools :: list())` (third argument is the tools list, was opts).

- [ ] **Step 1: Write the failing protocol tests**

Create `test/agents/model_protocol_test.exs`:

```elixir
defmodule Normandy.Agents.ModelProtocolTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, Model}
  alias Normandy.LLM.{Call, Request, Response}
  alias Normandy.LLMError

  defmodule OneXClient do
    @moduledoc "A client still written for 1.x: converse/3 returns the bare struct."
    defstruct []

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts), do: request.response_model

      def stream(_client, _request, _opts),
        do: {:error, LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp request(response_model \\ %BaseAgentOutputSchema{}) do
    %Request{
      model: "m",
      messages: [%Normandy.Components.Message{role: "user", content: "hi"}],
      max_tokens: 16_000,
      response_model: response_model
    }
  end

  test "the protocol has exactly converse/3 and stream/3" do
    assert Enum.sort(Model.__protocol__(:functions)) == [converse: 3, stream: 3]
  end

  test "Call.converse/3 passes an {:ok, %Response{}} through" do
    client = %Normandy.Test.StubClient{}
    assert {:ok, %Response{content: %BaseAgentOutputSchema{}}} = Call.converse(client, request(), [])
  end

  test "Call.converse/3 raises naming the impl, the expected shape and what came back" do
    message =
      assert_raise ArgumentError, fn -> Call.converse(%OneXClient{}, request(), []) end

    assert Exception.message(message) =~ "OneXClient"
    assert Exception.message(message) =~ "{:ok, %Normandy.LLM.Response{}}"
    assert Exception.message(message) =~ "Normandy.Agents.BaseAgentOutputSchema"
  end

  test "a 1.x-style client fails run!/2 with the ArgumentError, not a MatchError" do
    agent = BaseAgent.init(%{client: %OneXClient{}, model: "m"})

    assert_raise ArgumentError, ~r/must return \{:ok, %Normandy.LLM.Response\{\}\}/, fn ->
      BaseAgent.run(agent, %{chat_message: "hi"})
    end
  end

  test "a non-streaming client's stream/3 is :unsupported" do
    assert {:error, %LLMError{type: :unsupported, retryable?: false}} =
             Call.stream(%Normandy.Test.StubClient{}, request(nil), [])
  end

  test "the default max_tokens reaches the request" do
    client = %Normandy.Test.StubClient{notify: self()}
    agent = BaseAgent.init(%{client: client, model: "m"})
    BaseAgent.run(agent, %{chat_message: "hi"})

    assert_receive {:converse, %Request{max_tokens: 16_000, system: system, messages: messages},
                    _opts}

    assert is_binary(system)
    refute Enum.any?(messages, &(&1.role == "system"))
  end
end
```

(Task 2.4 renames the `BaseAgent.run` calls in this file to `run!`; leave them as `run` here.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/model_protocol_test.exs`
Expected: compile error (`Normandy.LLM.Call` undefined) or FAIL on the protocol functions.

- [ ] **Step 3: Rewrite the protocol**

Replace `lib/normandy/agents/model.ex` with:

```elixir
defprotocol Normandy.Agents.Model do
  @moduledoc """
  The interface between Normandy and a model provider.

  An implementation answers one `Normandy.LLM.Request` at a time:

    * `converse/3` returns the whole answer as `{:ok, %Normandy.LLM.Response{}}`.
    * `stream/3` returns `{:ok, stream}`, an enumerable of stream events (see "Stream
      events"). A client that can't stream returns
      `{:error, %Normandy.LLMError{type: :unsupported, retryable?: false}}`.

  Both return `{:error, %Normandy.LLMError{}}` when the call failed. Set `retryable?` to
  true only when resending the same request can succeed (rate limit, overload, 5xx,
  transport). Normandy raises `ArgumentError` for any other return value.

  ## Response content

  `request.response_model` is an empty struct of the shape the caller expects. Return it
  filled in as `response.content`: `%Normandy.Agents.BaseAgentOutputSchema{}` gets the
  answer text in `:chat_message`, and `%Normandy.Agents.ToolCallResponse{}` gets
  `:content`, `:tool_calls` and `:thinking`. When `response_model` is `nil`, return the
  answer text as a binary.

  ## Options

  `opts` carries Normandy's call plumbing, never request content. An implementation may
  ignore all of it:

    * `:request_tracker` - a `Normandy.Telemetry.Request` tracker, passed by BaseAgent
      (one per llm_call) and by the JSON retry loop
    * `:request_kind` - `:json_retry` when `Normandy.LLM.JsonDeserializer` re-asks after
      an unparseable answer; absent otherwise
    * `:json_retries` - how many times to re-ask after an answer that doesn't parse

  To emit a `[:normandy, :llm, :request]` span per provider request, wrap each request
  in `Normandy.Telemetry.Request.span/5`, passing `opts[:request_tracker]`, the kind
  (`opts[:request_kind]`, or `:structured_fallback`/`nil` as the implementation knows),
  metadata (`%{model: model, provider: :my_provider, stream: false}`), the request
  function, and an outcome function mapping its result to
  `{:ok, Normandy.Telemetry.Request.stop_metadata(id, finish_reason, usage)}` or
  `{:error, %Normandy.LLMError{}}`. With `nil` as the kind the span is `:initial` or
  `:retry` from the tracker's count.

  ## Stream events

  Maps with a string `:type`, in Anthropic SSE order: `"message_start"` (`:message`),
  `"content_block_start"` (`:index`, `:content_block`), `"content_block_delta"`
  (`:index`, `:delta`), `"content_block_stop"` (`:index`), `"message_delta"` (`:delta`,
  `:usage`), `"message_stop"`, `"ping"` and `"error"` (`:error`). Nested maps are
  string-keyed. A transport failure after the stream started is an `{:error, reason}`
  item. `Normandy.Components.StreamProcessor` builds the final message from them, and
  Normandy, not the implementation, delivers them to the caller's callback.
  """

  @spec converse(t(), Normandy.LLM.Request.t(), keyword()) ::
          {:ok, Normandy.LLM.Response.t()} | {:error, Normandy.LLMError.t()}
  def converse(client, request, opts)

  @spec stream(t(), Normandy.LLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Normandy.LLMError.t()}
  def stream(client, request, opts)
end
```

- [ ] **Step 4: Create the checked dispatcher**

`lib/normandy/llm/call.ex`:

```elixir
defmodule Normandy.LLM.Call do
  @moduledoc false
  # The only caller of Normandy.Agents.Model. A wrong return from an implementation
  # (a 1.x bare struct, {:ok, struct}, nil) fails here, naming the implementation,
  # instead of as a MatchError far from the cause.

  alias Normandy.Agents.Model
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLM.{Request, Response}
  alias Normandy.LLMError

  @spec converse(Model.t(), Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, LLMError.t()}
  def converse(client, %Request{} = request, opts) do
    case Model.converse(client, request, opts) do
      {:ok, %Response{}} = ok -> ok
      {:error, %LLMError{}} = error -> error
      other -> raise ArgumentError, bad_return(client, :converse, "{:ok, %Normandy.LLM.Response{}}", other)
    end
  end

  @spec stream(Model.t(), Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, LLMError.t()}
  def stream(client, %Request{} = request, opts) do
    case Model.stream(client, request, opts) do
      {:ok, stream} = ok when not is_nil(stream) ->
        if Enumerable.impl_for(stream),
          do: ok,
          else: raise(ArgumentError, bad_return(client, :stream, "{:ok, enumerable}", ok))

      {:error, %LLMError{}} = error ->
        error

      other ->
        raise ArgumentError, bad_return(client, :stream, "{:ok, enumerable}", other)
    end
  end

  defp bad_return(client, fun, expected, got) do
    "#{inspect(Model.impl_for(client))}.#{fun}/3 must return #{expected} or " <>
      "{:error, %Normandy.LLMError{}}, got: #{describe(got)}"
  end

  defp describe({tag, value}) when is_atom(tag), do: "{#{inspect(tag)}, #{describe(value)}}"
  defp describe(%module{}), do: "%#{inspect(module)}{}"
  defp describe(other), do: Describe.type_of(other)
end
```

Check `Describe.type_of/1` exists with that name (`grep -n "def type_of" lib/normandy/components/content_block/describe.ex`); it is what `ConverseResult` used.

- [ ] **Step 5: Migrate `ClaudioAdapter`**

In the `defimpl Normandy.Agents.Model` block of `lib/normandy/llm/claudio_adapter.ex`:

1. Delete `completitions/6` and its `@doc`.
2. Replace `converse/7`, `do_converse/7`, `do_converse_legacy/8`, `converse_structured/8`, `converse_raw/6` with request-based versions. Every function takes `(client, %Request{} = request, opts)` (plus the extra argument it had: `request_kind` / `json_schema`), reads `request.response_model`, `request.tools`, etc. instead of positional arguments, and returns `{:ok, %Response{}}`:

```elixir
    def converse(client, %Request{response_model: nil} = request, opts),
      do: converse_raw(client, request, opts)

    def converse(client, %Request{} = request, opts) do
      case ClaudioAdapter.__structured_schema_for__(client, request.response_model, request.tools) do
        {:ok, json_schema} -> converse_structured(client, request, opts, json_schema)
        :skip -> converse_legacy(client, request, opts, nil)
      end
    end
```

In `converse_legacy/4` (was `do_converse_legacy`), the JSON-retry context becomes:

```elixir
          context = %{
            client: client,
            request: request,
            json_retries: Keyword.get(opts, :json_retries, 2),
            retry_usage_ref: make_ref(),
            request_tracker: Keyword.get(opts, :request_tracker)
          }
```

and the success branch returns

```elixir
              {:ok, ClaudioAdapter.__response__(normalized_response, response, usage)}
```

In `converse_structured/4`, `context = %{client: client, request: request}` and the success branch returns `{:ok, ClaudioAdapter.__response__(handled, response, ClaudioAdapter.extract_usage(response))}`. `converse_raw/3`:

```elixir
    # The answer as text, with no schema deserialization: response_model nil. Used by
    # JsonDeserializer's retry loop so it owns parsing and retrying.
    defp converse_raw(client, request, opts) do
      claudio_client = build_claudio_client(client)

      case create(claudio_client, build_request(client, request), request.model, opts,
             Keyword.get(opts, :request_kind)) do
        {:ok, response} ->
          {:ok,
           ClaudioAdapter.__response__(
             ClaudioAdapter.extract_content(response),
             response,
             ClaudioAdapter.extract_usage(response)
           )}

        {:error, error} ->
          handle_error(error)
      end
    end
```

3. Replace `stream_converse/7` with `stream/3`. Delete the `:callback` handling and every `invoke_stream_callback/2` clause; the adapter only converts events:

```elixir
    def stream(client, %Request{} = request, _opts) do
      claudio_client = build_claudio_client(client)

      request =
        client
        |> build_request(request, stream: true)
        |> Claudio.Messages.Request.enable_streaming()

      case Claudio.Messages.create(claudio_client, request) do
        {:ok, %Req.Response{body: stream}} ->
          {:ok,
           stream
           |> Claudio.Messages.Stream.parse_events()
           |> Stream.map(fn
             {:ok, event} -> to_stream_processor_event(event)
             {:error, _} = error -> error
           end)}

        {:error, error} ->
          {:error, ClaudioAdapter.__to_llm_error__(error)}
      end
    end
```

4. `build_request/7` becomes `build_request(client, %Request{} = request, call_opts \\ [])`:

```elixir
    defp build_request(client, %Request{} = request, call_opts \\ []) do
      enable_caching = Map.get(client.options, :enable_caching, false)

      Claudio.Messages.Request.new(request.model)
      |> add_temperature(request.temperature)
      |> Claudio.Messages.Request.set_max_tokens(request.max_tokens)
      |> add_messages(request_messages(request), enable_caching)
      |> add_tools(request.tools, enable_caching)
      |> add_mcp_servers(request.mcp_servers)
      |> add_client_options(client.options, call_opts ++ task_budget_opts(request))
    end

    # add_messages/3 takes the system prompt as a leading "system" message.
    defp request_messages(%Request{system: nil, messages: messages}), do: messages

    defp request_messages(%Request{system: system, messages: messages}),
      do: [%Message{role: "system", content: system} | messages]

    defp task_budget_opts(%Request{task_budget_remaining: nil}), do: []
    defp task_budget_opts(%Request{task_budget_remaining: n}), do: [task_budget_remaining: n]
```

Delete `add_max_tokens/2` (both clauses): `max_tokens` is required by the struct, and a `nil` must fail here, not be dropped. `add_messages/3` keeps `ensure_single_leading_system!/1`, so a caller that puts a `"system"` message in `request.messages` *and* sets `:system` gets its `ArgumentError`.

5. `populate_standard_schema/3` passes the request through:

```elixir
      case JsonDeserializer.deserialize_with_retry(content, schema, context.client, context.request, opts) do
```

with `opts = [max_retries: ..., on_retry_usage: ..., request_tracker: ...]` as today (drop the `:tools` and `:task_budget_remaining` handling: the request carries both).

6. Outside the impl block: change `__structured_schema_for__/3`'s third argument to the tools list:

```elixir
  def __structured_schema_for__(client, response_model, tools) when is_list(tools) do
    case tools do
      [] -> StructuredOutputs.schema_for(client, response_model)
      _ -> :skip
    end
  end
```

and add the response builder next to `response_meta/1`:

```elixir
  @doc false
  # The %Normandy.LLM.Response{} for a Claudio response; usage is passed in because
  # JSON retries add theirs to the first response's.
  @spec __response__(struct() | String.t(), Claudio.Messages.Response.t(), map() | nil) ::
          Normandy.LLM.Response.t()
  def __response__(content, %Claudio.Messages.Response{} = response, usage) do
    %Normandy.LLM.Response{
      content: content,
      stop_reason: response.stop_reason,
      usage: usage,
      meta: response_meta(response)
    }
  end
```

Delete `__raw_completion__/1` (its only caller was `converse_raw`). Update the moduledoc "Errors" paragraph: `converse/3` and `stream/3` return `{:error, %Normandy.LLMError{}}`. Fix the comment on `response_meta/1` ("returned as the third element of converse/7") to "carried as `Response.meta`".

7. Add `alias Normandy.LLM.Request` inside the impl block and at the top of the module.

- [ ] **Step 6: Migrate `OpenAICompatibleAdapter`**

In its impl block: delete `completitions/6`; `converse/3` reads the request:

```elixir
    def converse(client, %Request{} = request, opts) do
      if request.tools != [] do
        raise ArgumentError,
              "OpenAICompatibleAdapter does not support tools (text-only v1), got " <>
                "#{length(request.tools)} tool schema(s)"
      end

      url = String.trim_trailing(client.base_url, "/") <> "/chat/completions"
      body = A.build_body(request.model, request.temperature, request.max_tokens, A.request_messages(request))
      # ... req_options and Request.span exactly as today, with request.model in the span metadata

      case result do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          content = A.extract_text(resp_body)

          case populate(content, client, request) do
            {:error, %Normandy.LLMError{} = error} ->
              {:error, Normandy.LLMError.with_usage(error, Map.get(resp_body, "usage"))}

            populated ->
              {:ok,
               %Normandy.LLM.Response{
                 content: populated,
                 stop_reason: A.stop_reason(resp_body),
                 usage: Map.get(resp_body, "usage"),
                 meta: A.response_meta(resp_body)
               }}
          end

        # the two error clauses unchanged
      end
    end

    def stream(_client, _request, _opts) do
      {:error,
       Normandy.LLMError.new(
         type: :unsupported,
         retryable?: false,
         detail: "OpenAICompatibleAdapter does not stream"
       )}
    end

    defp populate(content, client, %Request{response_model: %{__struct__: _} = schema} = request) do
      case JsonDeserializer.deserialize_with_retry(content, schema, client, request, max_retries: 0) do
        {:ok, validated} -> validated
        {:error, reason} -> ParseFailure.apply(schema, content, reason, %{client: client})
      end
    end

    defp populate(content, _client, _request), do: content
```

Add to the outer module (`A`):

```elixir
  @doc false
  # Chat Completions has no system field: the system prompt is the first message.
  def request_messages(%Normandy.LLM.Request{system: nil, messages: messages}), do: messages

  def request_messages(%Normandy.LLM.Request{system: system, messages: messages}),
    do: [%Normandy.Components.Message{role: "system", content: system} | messages]

  @doc false
  # The first choice's finish_reason mapped onto Anthropic's stop reasons. A closed
  # mapping: a provider string never becomes an atom. response_meta/1 keeps the raw
  # string as :finish_reason.
  def stop_reason(%{"choices" => [%{"finish_reason" => reason} | _]}) do
    case reason do
      "stop" -> :end_turn
      "length" -> :max_tokens
      "tool_calls" -> :tool_use
      "content_filter" -> :refusal
      _ -> nil
    end
  end

  def stop_reason(_body), do: nil
```

Add a test to `test/llm/openai_compatible_adapter_test.exs` next to its existing success case: a stubbed body with `"finish_reason" => "length"` gives `{:ok, %Normandy.LLM.Response{stop_reason: :max_tokens}}`.

**Which key carries `max_tokens` (Wave 1 review I1; Q chose option (b), 2026-10-04).** Since Task 1.3 every request carries `max_tokens`. OpenAI's reasoning models want `max_completion_tokens`, and some compatible servers reject one key or the other, so the client chooses with a new option. `options[:max_tokens_param]` takes three values:

- `:max_tokens` (the default; same as today)
- `:max_completion_tokens`
- `:omit` (send neither; the server's own limit applies)

Tests first, in `openai_compatible_adapter_test.exs`, using the file's existing body-capturing `Req.Test` stub:

```elixir
  describe ":max_tokens_param" do
    for {param, key} <- [max_tokens: "max_tokens", max_completion_tokens: "max_completion_tokens"] do
      test "#{param} sends max_tokens as #{key}" do
        body = capture_request_body(%{max_tokens_param: unquote(param)}, max_tokens: 2048)
        assert body[unquote(key)] == 2048
        other = if unquote(key) == "max_tokens", do: "max_completion_tokens", else: "max_tokens"
        refute Map.has_key?(body, other)
      end
    end

    test "the default is max_tokens" do
      assert capture_request_body(%{}, max_tokens: 2048)["max_tokens"] == 2048
    end

    test ":omit sends neither key" do
      body = capture_request_body(%{max_tokens_param: :omit}, max_tokens: 2048)
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
    end

    test "an unknown value raises at init naming the allowed ones" do
      client = %Normandy.LLM.OpenAICompatibleAdapter{api_key: "k", options: %{max_tokens_param: "max_tokens"}}

      assert_raise ArgumentError,
                   ~r/:max_tokens_param must be :max_tokens, :max_completion_tokens or :omit, got: "max_tokens"/,
                   fn -> Normandy.Agents.BaseAgent.init(%{client: client, model: "m"}) end
    end
  end
```

`capture_request_body(options, max_tokens: n)` is a helper in the test module. It calls `Model.converse/3` with a `%Request{max_tokens: n, response_model: nil}`, against a client whose `options` are `options` merged with the stub's `req_options`, and returns the decoded JSON body. Write it if the file has no equivalent.

Implementation in `lib/normandy/llm/openai_compatible_adapter.ex`:

```elixir
  @max_tokens_params [:max_tokens, :max_completion_tokens, :omit]

  @doc """
  Checks `client.options` once, up front; `BaseAgent.init/1` calls it. Raises
  `ArgumentError` for an unknown `:max_tokens_param`.
  """
  @spec validate_options!(t()) :: t()
  def validate_options!(%__MODULE__{options: options} = client) do
    case Map.get(options, :max_tokens_param, :max_tokens) do
      param when param in @max_tokens_params ->
        client

      other ->
        raise ArgumentError,
              "OpenAICompatibleAdapter: :max_tokens_param must be :max_tokens, " <>
                ":max_completion_tokens or :omit, got: #{inspect(other)}"
    end
  end

  @doc false
  def build_body(model, temperature, max_tokens, messages, max_tokens_param \\ :max_tokens) do
    %{"model" => model, "messages" => convert_messages(messages)}
    |> put_unless_nil("temperature", temperature)
    |> put_max_tokens(max_tokens_param, max_tokens)
  end

  defp put_max_tokens(body, :omit, _max_tokens), do: body
  defp put_max_tokens(body, param, max_tokens), do: put_unless_nil(body, Atom.to_string(param), max_tokens)
```

In `converse/3`, pass `Map.get(client.options, :max_tokens_param, :max_tokens)` as `build_body/5`'s last argument. In `lib/normandy/agents/base_agent.ex` (`validate_client_options!/1`, line 890), add a clause before the catch-all:

```elixir
  def validate_client_options!(%Normandy.LLM.OpenAICompatibleAdapter{} = client),
    do: Normandy.LLM.OpenAICompatibleAdapter.validate_options!(client)
```

Document the option in the adapter moduledoc (a "## Options" section listing `:timeout`, `:req_options` and `:max_tokens_param` with its three values), and add this line to MIGRATING §17 (Task 2.0's section):

```markdown
- `OpenAICompatibleAdapter` sends `max_tokens` on every request too. For OpenAI reasoning
  models set `options: %{max_tokens_param: :max_completion_tokens}`; `:omit` sends neither
  key and leaves the limit to the server.
```

Update the moduledoc: "`converse/3` returns ..." and "`stream/3` returns `{:error, %Normandy.LLMError{type: :unsupported}}`".

- [ ] **Step 7: Migrate `JsonDeserializer`**

1. `deserialize_with_retry(content, schema, client, %Request{} = request, opts \\ [])`; `@spec` accordingly. `deserialize_loop` and `retry_with_feedback`/`continue_after_retry` take `(content, schema, client, request, opts, adapter, attempt, max_retries)`; drop the `model/temperature/max_tokens/messages` parameters and the `# credo:disable-for-next-line Credo.Check.Refactor.FunctionArity` lines that no longer apply (keep any still needed: credo's limit is 8).
2. The retry call:

```elixir
    error_message = RetryFeedback.build(error, failed_content, schema, adapter)

    retry_request = %{
      request
      | messages: RetryFeedback.augment_messages(request.messages, error_message),
        response_model: nil
    }

    llm_opts =
      [request_kind: :json_retry] ++ Keyword.take(opts, [:request_tracker])

    case Call.converse(client, retry_request, llm_opts) do
      # An LLM failure is not a parse failure: stop and hand it back.
      {:error, %LLMError{}} = error ->
        error

      {:ok, %Response{content: response, usage: usage}} ->
        report_retry_usage(opts, usage)
        continue_after_retry(response, schema, client, request, opts, adapter, attempt, max_retries)
    end
```

The retry keeps the **original** `request.messages` for the next attempt (as today: each retry augments the original conversation, not the previous retry's). `continue_after_retry/8` keeps its `is_binary`/`is_struct` branches.
3. Replace the "Retry raw-completion contract" moduledoc section with:

```
  ## Retries

  On a parse failure the loop calls `Normandy.Agents.Model.converse/3` again with the
  error feedback appended to `request.messages` and `response_model: nil`, which asks
  the client for the answer as text. Every attempt, initial or corrective, is parsed
  here (`parse_and_populate/4`), so this module is the single parse-and-retry
  authority. A client that ignores `response_model: nil` and returns a struct still
  works: its text is extracted and parsed.
```

4. Update the moduledoc "Usage with Agent" example to `{:ok, agent, response} = BaseAgent.run(agent, input)` in Task 2.4, not here.

- [ ] **Step 8: Migrate the summarizer and Provider**

`lib/normandy/context/summarizer.ex` `call_llm_for_summary/6`:

```elixir
    request = %Normandy.LLM.Request{
      model: model,
      messages: messages,
      response_model: response_model,
      temperature: temperature,
      max_tokens: max_tokens
    }

    llm_call_span(metadata, tracker, fn ->
      Request.note_call(tracker)
      Call.converse(client, request, request_tracker: tracker)
    end)
    |> case do
      {:ok, %Response{content: %{chat_message: summary}}}
      when is_binary(summary) and summary != "" ->
        {:ok, summary}

      {:ok, %Response{content: %{chat_message: _empty_or_not_text}}} ->
        {:error, :empty_summary}

      {:ok, %Response{content: other}} ->
        {:error, {:unexpected_response, other}}

      {:error, %LLMError{}} = error ->
        error
    end
```

Note the existing alias `Request` there is `Normandy.Telemetry.Request`: alias the LLM one as `Normandy.LLM.Request, as: LLMRequest` (or the telemetry one as `TelemetryRequest`) so both stay readable. Check `llm_call_span/3`'s outcome handling still matches (it pattern-matches the `fun` result; update its `{:ok, {_, usage, _}}` match to `{:ok, %Response{usage: usage}}` if it reads usage).

`lib/normandy/telemetry/provider.ex:113-117`: pass the tools list directly:

```elixir
      ClaudioAdapter.__structured_schema_for__(
        config.client,
        Keyword.get(opts, :response_model),
        if(Keyword.get(opts, :tools?, false), do: [:tools], else: [])
      ) != :skip
```

- [ ] **Step 9: Migrate BaseAgent's non-streaming call**

In `get_response_with_usage/3`, build the request instead of a message list. Replace lines 326–362 (from `# Convert history plain maps...` to the `call_llm_with_resilience` call) with:

```elixir
    request = %Normandy.LLM.Request{
      model: config.model,
      system: system_prompt_with_schema,
      messages: Enum.map(history, fn %{role: role, content: content} -> %Message{role: role, content: content} end),
      response_model: response_model,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      tools: tool_schemas,
      mcp_servers: config.mcp_servers,
      task_budget_remaining: Keyword.get(extra_opts, :task_budget_remaining)
    }

    # How many times the adapter re-asks after a response that does not parse.
    json_retries = if config.enable_json_retry, do: config.json_retry_max_attempts, else: 0

    # Numbers the provider requests of this call (get_response/2 has no llm_call
    # span to create one).
    tracker = Keyword.get_lazy(extra_opts, :request_tracker, fn -> request_tracker(config) end)

    {response, usage, meta} =
      call_llm_with_resilience(config, request, json_retries: json_retries, request_tracker: tracker)
```

`tool_schemas` is already computed above (line 312); it is `[]` without tools, which is what `Request.tools` expects.

`call_llm_with_resilience/3` (drop the `messages`/`response_model` parameters):

```elixir
  @spec call_llm_with_resilience(BaseAgentConfig.t(), Normandy.LLM.Request.t(), keyword()) ::
          {struct() | String.t(), map() | nil, map()}
  defp call_llm_with_resilience(config, request, opts) do
    tracker = Keyword.get(opts, :request_tracker)

    llm_call = fn ->
      Request.note_call(tracker)
      Call.converse(config.client, request, opts)
    end

    case with_resilience(config, llm_call) do
      {:ok, %Normandy.LLM.Response{content: content, usage: usage, meta: meta}} ->
        {content, usage, meta}

      # (the two {:error, ...} clauses unchanged)
    end
  end
```

Update the comment above it: "The call returns `{:ok, %Response{}} | {:error, %LLMError{}}` (`Normandy.LLM.Call`), which is Retry's and CircuitBreaker's contract...". Remove `alias Normandy.Agents.ConverseResult` and `alias Normandy.Agents.Model` if unused; add `alias Normandy.LLM.Call`.

`task_budget_call_opts/2` keeps returning `[task_budget_remaining: n]` or `[]`; `call_turn_llm/3` already passes it in `extra_opts`, which the new code reads with `Keyword.get/2`.

- [ ] **Step 10: Migrate BaseAgent's streaming call and move the callback**

`build_stream_messages/1` becomes `build_stream_request/1`, returning `{%Request{}, prefix_key}`:

```elixir
  defp build_stream_request(config) do
    system_prompt = SystemPromptGenerator.generate_prompt(config.prompt_specification)

    tool_schemas =
      if has_tools?(config), do: Registry.to_tool_schemas(config.tool_registry), else: []

    # Streaming calls cannot use :fallbacks, so the requested model produces it.
    prefix_key = ToolCallResponse.prefix_key(system_prompt, tool_schemas, config.model)

    messages =
      config.memory
      |> AgentMemory.drop_stale_thinking(prefix_key)
      |> AgentMemory.history()
      |> Enum.map(fn %{role: role, content: content} -> %Message{role: role, content: content} end)

    request = %Normandy.LLM.Request{
      model: config.model,
      system: system_prompt,
      messages: messages,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      tools: tool_schemas,
      mcp_servers: config.mcp_servers
    }

    {request, prefix_key}
  end
```

Delete `stream_opts/2`. In `stream_llm_attempt/4`:

```elixir
    {request, prefix_key} = build_stream_request(config)
    request = %{request | task_budget_remaining: Keyword.get(task_budget_call_opts(config, state), :task_budget_remaining)}
    {callback, first_chunk} = track_first_chunk(callback)
    tracker = request_tracker(config)

    case stream_response_from_llm(config, request, callback, first_chunk, tracker) do
```

`stream_response_from_llm/5` takes `(config, request, callback, first_chunk, tracker)`; replace its `opts = Keyword.update(opts, :callback, ...)` with `callback = track_delivery(callback, delivered)` and call `stream_attempt(config, request, callback)`. `stream_attempt/3`:

```elixir
  defp stream_attempt(config, request, callback) do
    case Call.stream(config.client, request, []) do
      {:ok, stream} ->
        # Normandy, not the adapter, delivers events to the caller's callback, in
        # stream order, as the stream is consumed.
        stream = Stream.each(stream, &deliver_stream_event(&1, callback))

        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        case config do
          %BaseAgentConfig{output_guardrails: [_ | _], output_guardrails_streaming_mode: :incremental} ->
            consume_stream_with_incremental_guards(stream, config, callback)

          _ ->
            events = Enum.to_list(stream)

            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case StreamProcessor.stream_error(events) do
              nil -> {:ok, StreamProcessor.build_final_message(events)}
              %LLMError{} = error -> {:error, stream_error_with_usage(error, events)}
            end
        end

      {:error, %LLMError{}} = error ->
        error
    end
  end

  # The events the stream callback receives, from the adapter-neutral stream events
  # (Normandy.Agents.Model, "Stream events"). Everything else is not delivered.
  defp deliver_stream_event(
         %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}},
         callback
       ),
       do: callback.(:text_delta, text)

  defp deliver_stream_event(
         %{type: "content_block_delta", delta: %{"type" => "thinking_delta", "thinking" => text}},
         callback
       ),
       do: callback.(:thinking_delta, text)

  defp deliver_stream_event(
         %{type: "content_block_start", content_block: %{"type" => "tool_use"} = tool},
         callback
       ),
       do: callback.(:tool_use_start, tool)

  defp deliver_stream_event(%{type: "message_start", message: message}, callback),
    do: callback.(:message_start, message)

  defp deliver_stream_event(%{type: "message_stop"}, callback), do: callback.(:message_stop, %{})
  defp deliver_stream_event(_event, _callback), do: :ok
```

These five clauses are the adapter's former `invoke_stream_callback/2` mapping, on the converted events; `:tool_result` and `:guardrail_violation` stay where BaseAgent already sends them. Update the comment at line 1460 ("adapters emit none for stream_converse/7") to "adapters emit none for stream/3". Delete the `Model.impl_for`/`Code.ensure_loaded`/`function_exported?` probe and the "client does not implement stream_converse/7" error: `Call.stream/3` returns the client's `:unsupported`.

- [ ] **Step 11: Migrate the support clients**

The rule for every test client: delete `completitions/6`; `converse/7` becomes `converse(client, request, opts)` reading `request.messages`, `request.response_model`, `request.max_tokens`, etc.; the return value is wrapped:

| 1.x return | 2.0 return |
|---|---|
| `response` (a struct or binary) | `{:ok, %Normandy.LLM.Response{content: response}}` |
| `{response, usage}` | `{:ok, %Normandy.LLM.Response{content: response, usage: usage}}` |
| `{response, usage, meta}` | `{:ok, %Normandy.LLM.Response{content: response, usage: usage, meta: meta}}` |
| `{:error, %LLMError{}}` | unchanged |
| raises | unchanged |

A client that read the system prompt from `List.first(messages)` reads `request.system`; one that read the last message reads `List.last(request.messages)` (unchanged, since the system prompt was never last). `stream_converse/7` becomes `stream(client, request, opts)`: **delete any code that calls `opts[:callback]`** (Normandy calls it now; keeping it delivers every event twice) and return `{:ok, events}`. A client without streaming gets:

```elixir
    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
```

`test/support/stub_client.ex` in full:

```elixir
defmodule Normandy.Test.StubClient do
  @moduledoc """
  A model client for tests. `converse/3` sends `{:converse, request, opts}` (a
  `%Normandy.LLM.Request{}`) to `:notify` when it is set, then returns what `:reply`
  gives:

    * `fn response_model -> reply end`, or
    * `fn response_model, opts -> reply end`

  where `reply` is the response content (wrapped as `{:ok, %Normandy.LLM.Response{}}`),
  an `{:ok, %Normandy.LLM.Response{}}`, or `{:error, %Normandy.LLMError{}}`; or the
  function raises. The default returns the response model unchanged.

  `stream/3` returns `{:error, %Normandy.LLMError{type: :unsupported}}`.
  """
  defstruct reply: &Function.identity/1, notify: nil, options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.Response

    def converse(client, request, opts) do
      if client.notify, do: send(client.notify, {:converse, request, opts})

      reply =
        case client.reply do
          reply when is_function(reply, 1) -> reply.(request.response_model)
          reply when is_function(reply, 2) -> reply.(request.response_model, opts)
        end

      case reply do
        {:ok, %Response{}} = ok -> ok
        {:error, _} = error -> error
        content -> {:ok, %Response{content: content}}
      end
    end

    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
  end
end
```

Tests that `assert_receive {:converse, messages, opts}` become `assert_receive {:converse, %Normandy.LLM.Request{messages: messages}, opts}`, and an assertion on the system message moves to `request.system`. A `StubClient` reply that returned `{response, usage}` or `{response, usage, meta}` becomes `{:ok, %Normandy.LLM.Response{content: response, usage: usage, meta: meta}}`.

Apply the table to `model_mockup.ex`, `scripted_tool_client.ex` (`Enum.any?(request.messages, &(&1.role == "tool"))`), `streaming_probe_client.ex`, `tagging_client.ex` (`List.last(request.messages)`), `mock_summarizer_client.ex`, then to each inline impl from `grep -rln "defimpl Normandy.Agents.Model" test`.

- [ ] **Step 12: Migrate the adapter and deserializer tests**

- `test/llm/json_deserializer*_test.exs`: calls become `deserialize_with_retry(content, schema, client, request, opts)` with `request = %Normandy.LLM.Request{model: "m", messages: messages, max_tokens: 1024, temperature: nil}` built from the same values. The "proves raw: true is threaded" test (`json_deserializer_retry_test.exs:36`) becomes "a retry asks for text with response_model: nil": its client returns `~s({"chat_message": "recovered"})` when `request.response_model == nil`, else `"not json"`.
- `test/llm/claudio_adapter*_test.exs` and `openai_compatible_adapter_test.exs`: calls to `Model.converse(client, model, temp, max_tokens, messages, schema, opts)` become `Model.converse(client, %Request{model: model, temperature: temp, max_tokens: max_tokens, messages: messages, response_model: schema, tools: opts[:tools] || [], mcp_servers: opts[:mcp_servers]}, rest_opts)`; a leading `%Message{role: "system"}` in `messages` moves to `system:`. Results `{resp, usage, meta}` / `{resp, usage}` are matched as `{:ok, %Response{content: resp, usage: usage, meta: meta}}`. Direct calls to `...ClaudioAdapter.stream_converse(client, model, ..., callback: cb)` become `stream(client, request, [])`, and assertions on callback events consume the returned stream instead.
- Add to `test/llm/claudio_adapter_test.exs` (in a describe that already stubs the HTTP layer with `Req.Test`) one test per stop reason, asserting it is carried on the response:

```elixir
    for reason <- ~w(end_turn tool_use max_tokens refusal pause_turn) do
      test "stop_reason #{reason} is carried on the response" do
        name = Module.concat(__MODULE__, "Stop#{unquote(reason)}")

        Req.Test.stub(name, fn conn ->
          Req.Test.json(conn, %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-opus-5-5",
            "content" => [%{"type" => "text", "text" => "hi"}],
            "stop_reason" => unquote(reason),
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        end)

        client = %ClaudioAdapter{api_key: "k", options: %{req_options: [plug: {Req.Test, name}, retry: false]}}

        request = %Normandy.LLM.Request{
          model: "claude-opus-5-5",
          messages: [%Normandy.Components.Message{role: "user", content: "hi"}],
          max_tokens: 64
        }

        assert {:ok, %Normandy.LLM.Response{stop_reason: stop_reason}} =
                 Normandy.Agents.Model.converse(client, request, [])

        assert stop_reason == String.to_existing_atom(unquote(reason))
      end
    end
```

(`response_model: nil` takes the raw path, so no JSON parsing is involved. If the file has no `use ExUnit.Case` module attribute for `Req.Test` names, the `Module.concat` name is enough; `Req.Test` stubs are process-owned.)

- [ ] **Step 13: Update the docs that name the old protocol**

- `MIGRATING-2.0.md` §4: replace the section with:

```markdown
## 4. The `Model` protocol is `converse/3` + `stream/3`

`Normandy.Agents.Model` has two functions, both taking a `%Normandy.LLM.Request{}`:

| 1.x | 2.0 |
|---|---|
| `completitions/6` | removed: delete your implementation |
| `converse(client, model, temperature, max_tokens, messages, response_model, opts)` | `converse(client, %Request{model:, system:, messages:, response_model:, temperature:, max_tokens:, tools:, mcp_servers:, task_budget_remaining:}, opts)` |
| returns `response`, `{response, usage}` or `{response, usage, meta}` | returns `{:ok, %Normandy.LLM.Response{content:, stop_reason:, usage:, meta:}}` |
| `{:error, %LLMError{}}` | unchanged |
| `stream_converse/7` (optional, found by `function_exported?`) | `stream(client, %Request{}, opts)`, required; return `{:error, %LLMError{type: :unsupported}}` if you can't stream |
| `opts[:raw]` | `request.response_model == nil`: return the answer text |
| `opts[:tools]`, `opts[:mcp_servers]`, `opts[:task_budget_remaining]` | `request.tools`, `request.mcp_servers`, `request.task_budget_remaining` |
| the system prompt as the first `"system"` message | `request.system`; `request.messages` holds no system message |
| your `stream_converse/7` called `opts[:callback]` | `stream/3` returns events only; Normandy calls the callback |

`Normandy.Agents.ConverseResult` is gone. Any other return from `converse/3` raises
`ArgumentError` naming your implementation. `JsonDeserializer.deserialize_with_retry/5`
takes `(content, schema, client, %Request{}, opts)` instead of eight arguments.
```

- `CLAUDE.md`, "Agent System" → `Normandy.Agents.Model` bullet: `Requires: converse/3 and stream/3 over %Normandy.LLM.Request{}; converse/3 returns {:ok, %Normandy.LLM.Response{}} or {:error, %Normandy.LLMError{}}; a non-streaming client's stream/3 returns {:error, %LLMError{type: :unsupported}}`.
- `lib/normandy/llm/error.ex:5`, `lib/normandy/telemetry/request.ex:24`, `lib/normandy/telemetry.ex`: replace `converse/7` with `converse/3` (and `stream_converse/7` with `stream/3`). Check with `grep -rn "converse/7\|stream_converse\|completitions\|ConverseResult" lib CLAUDE.md MIGRATING-2.0.md`: only MIGRATING's table may still mention them.

- [ ] **Step 14: Run the protocol tests, then the suite**

Run: `mix format && mix test test/agents/model_protocol_test.exs`
Expected: PASS.

Run: `mix compile --warnings-as-errors && mix test 2>&1 | tail -5`
Expected: ` 0 failures`. Then: `grep -rn "completitions\|stream_converse\|ConverseResult" lib test` → no hits.

- [ ] **Step 15: Commit**

Add each changed file by name (`git status --short` lists them; the deleted ones with `git rm`):

```bash
git rm lib/normandy/agents/converse_result.ex test/agents/converse_result_test.exs
git add lib/normandy/agents/model.ex lib/normandy/llm/call.ex lib/normandy/llm/claudio_adapter.ex lib/normandy/llm/openai_compatible_adapter.ex lib/normandy/llm/json_deserializer.ex lib/normandy/context/summarizer.ex lib/normandy/telemetry/provider.ex lib/normandy/agents/base_agent.ex lib/normandy/llm/error.ex lib/normandy/telemetry/request.ex lib/normandy/telemetry.ex CLAUDE.md MIGRATING-2.0.md test/agents/model_protocol_test.exs
# then each modified test/ and test/support/ file by name
git commit -m "feat(model)!: converse/3 and stream/3 over Request/Response structs" -m "BREAKING CHANGE: Normandy.Agents.Model is converse/3 + stream/3; completitions/6, stream_converse/7 and ConverseResult are removed. See MIGRATING-2.0.md §4."
```

---

### Task 2.3: Claudio gap list (decision 2)

Before Claudio 0.7.0 is published (Task 7.5), list what the later waves need from it that it can't express. **Do not edit `../Claudio`;** a gap goes to Q.

**Files:**
- Create: `investigations/pre-2.0-audit/claudio-gaps.md`
- Test: `test/llm/claudio_request_capabilities_test.exs` (create)

**Interfaces:**
- Produces: `claudio-gaps.md`, read by Task 5.1 (output format with tools), Task 5.3 (replaying server-side and compaction blocks) and Task 7.5 (publish gate).

- [ ] **Step 1: Write the capability test**

These are the request shapes Waves 5 and 6 depend on. If one fails, that is a gap to record, not a test to fix.

```elixir
defmodule Normandy.LLM.ClaudioRequestCapabilitiesTest do
  @moduledoc "What the 2.0 waves need Claudio's request builder to express."
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  defp body(request), do: request |> Request.to_map() |> Jason.encode!() |> Jason.decode!()

  test "tools and output_config.format in one request (Task 5.1)" do
    body =
      Request.new("claude-opus-5-5")
      |> Request.set_max_tokens(64)
      |> Request.add_tool(%{name: "t", description: "d", input_schema: %{"type" => "object"}})
      |> Request.set_output_format(%{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "required" => ["a"],
        "additionalProperties" => false
      })
      |> body()

    assert [%{"name" => "t"}] = body["tools"]
    assert %{"format" => %{"type" => "json_schema"}} = body["output_config"]
  end

  test "an assistant message replayed with raw content blocks (Task 5.3)" do
    blocks = [
      %{"type" => "thinking", "thinking" => "x", "signature" => "s"},
      %{"type" => "mcp_tool_use", "id" => "m1", "name" => "n", "server_name" => "srv", "input" => %{}},
      %{"type" => "text", "text" => "a"},
      %{"type" => "text", "text" => "b"}
    ]

    body =
      Request.new("claude-opus-5-5")
      |> Request.set_max_tokens(64)
      |> Request.add_message(:user, "hi")
      |> Request.add_message(:assistant, blocks)
      |> body()

    assert [_, %{"role" => "assistant", "content" => ^blocks}] = body["messages"]
  end
end
```

If `Request.to_map/1` is not Claudio's serializer, find the one `Claudio.Messages.create/2` uses (`grep -n "def to_map\|def to_body\|Jason.encode" ../Claudio/lib/claudio/messages/*.ex`) and use it; adjust only the call, not the assertions. If `add_message/3` takes string roles, pass `"user"`/`"assistant"`.

- [ ] **Step 2: Run it**

Run: `mix test test/llm/claudio_request_capabilities_test.exs`
Expected: PASS, or a failure that names a gap.

- [ ] **Step 3: Check the remaining needs against Claudio's source**

For each row, find the Claudio function and record `file:line`, or "gap":

| Need | Used by | Where to look |
|---|---|---|
| `stop_reason` `:pause_turn`, `:refusal`, `:max_tokens`, `:compaction` parsed | Task 5.2 | `../Claudio/lib/claudio/messages/response.ex` `parse_stop_reason/1` |
| `output_config.format` together with tools | Task 5.1 | Step 1 test |
| assistant content blocks sent back byte-equal (thinking, `mcp_tool_use`, `mcp_tool_result`, compaction, fallback blocks) | Task 5.3 | Step 1 test; `Request.add_message/3` |
| streaming `message_delta` carries `stop_reason` and usage | Task 5.2 streaming | `../Claudio/lib/claudio/messages/stream.ex` |
| request headers per call (`:headers`) | telemetry (committed `a9dff4b`) | `Claudio.Messages.create/2` options |

- [ ] **Step 4: Write `claudio-gaps.md`**

```markdown
# Claudio 0.7.0 gaps for Normandy 2.0

Checked 2026-10-04 against ../Claudio at <git -C ../Claudio rev-parse --short HEAD>.

| Need | Claudio | Status |
|---|---|---|
| ... one row per Step 3 need, with file:line ... | | ok / gap |

<"No gaps." or, per gap: what is missing, which Normandy task needs it, a proposed Claudio change. Q decides before Task 7.5.>
```

- [ ] **Step 5: Commit**

`claudio-gaps.md` is in the untracked `investigations/` directory: commit only the test.

```bash
git add test/llm/claudio_request_capabilities_test.exs
git commit -m "test(llm): pin the Claudio request shapes 2.0 depends on"
```

If any row is a gap, stop and report it to Q before Task 2.4.

---

### Task 2.4: `run/2,3` returns tuples; `run!/2,3` raises (decision 6, 15c; DX-5)

`BaseAgent.run` returns `{:ok, config, output} | {:error, exception}` for Normandy's own failures and still raises for bugs. `run!` keeps today's behaviour. In-library callers move with it. `Turn.Server` is Task 2.5.

**Files:**
- Create: `lib/normandy/turn_error.ex`
- Modify: `lib/normandy/agents/base_agent.ex:448-517` (`run/2`, `run/3`), the moduledoc
- Modify: `lib/normandy/dsl/agent.ex:570-595` (`run/2`, `run/3`; add `run!/2,3`)
- Modify, switch to `run!/2` with no behaviour change: `lib/normandy/coordination/sequential_orchestrator.ex:255`, `parallel_orchestrator.ex:341`, `hierarchical_coordinator.ex:219,353`, `lib/normandy/batch/processor.ex:274`, `lib/normandy/a2a/server.ex:187`
- Modify, reply the bare exception: `lib/normandy/coordination/agent_process.ex:397-435` (inline `handle_call`), `:647-657` (`handle_async_run/3`), `lib/normandy/coordination/reactive.ex:397-405` (`execute_agent/2`), `lib/normandy/dsl/workflow.ex:539-546` (`run_agent/2`)
- Modify docs: `lib/normandy/llm/json_deserializer.ex:32`, `lib/normandy/llm/claudio_adapter.ex:34`, `README.md` quickstart (`{:ok, agent, response} = ...`), `CLAUDE.md` (`run/2` bullet), `MIGRATING-2.0.md` §11
- Test: `test/agents/base_agent_run_result_test.exs` (create), `test/turn_error_test.exs` (create), `test/coordination/reactive_test.exs:370-392`, `test/coordination/agent_process_test.exs`, every test calling `BaseAgent.run(` or a DSL agent's `run(`

**Interfaces:**
- Consumes: Task 2.2 (`run` reaches the client through `Normandy.LLM.Call`).
- Produces: `BaseAgent.run(config, input \\ nil, opts \\ []) :: {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}`; `BaseAgent.run!(config, input \\ nil, opts \\ []) :: {BaseAgentConfig.t(), term()}`.
- Produces: `%Normandy.TurnError{type, handler, reason}` with `type in [:handler_crashed, :persist_failed, :approval_timeout, :task_down, :session_unavailable, :unexpected_event, :unresumable_state]`; `TurnError.domain?(exception) :: boolean()` (true for `LLMError`, `Schema.ValidationError`, `Guardrails.ViolationError`, `HookHaltError`, `ModelCatalogError`, `TurnError`); `TurnError.task_down(exit_reason) :: t()`; `TurnError.format_stacktrace(stacktrace) :: String.t()` (arities only).
- Produces: `AgentProcess.run/3`, `Reactive` results and `Workflow` step errors carry the bare exception: `{:error, exception}` (was `{:error, {:exception, e, stacktrace}}`).

`ModelCatalogError` is in the `domain?` list though decision 15(c) names four exceptions plus `TurnError`: it is Normandy's own failure (a catalog lookup, usually network), raised mid-turn by compaction, and a caller should be able to handle it like an `LLMError`.

- [ ] **Step 1: Write the failing tests**

`test/turn_error_test.exs`:

```elixir
defmodule Normandy.TurnErrorTest do
  use ExUnit.Case, async: true

  alias Normandy.TurnError

  test "domain? is true for Normandy's failure exceptions only" do
    for e <- [
          Normandy.LLMError.new(type: :rate_limit, retryable?: true),
          %Normandy.Schema.ValidationError{message: "m", errors: []},
          %Normandy.Guardrails.ViolationError{message: "m", violations: []},
          %Normandy.HookHaltError{event: :on_prompt, hook: M, reason: "r"},
          %Normandy.ModelCatalogError{model: "m", reason: :timeout},
          %TurnError{type: :persist_failed, reason: :disk_full}
        ],
        do: assert(TurnError.domain?(e), inspect(e.__struct__))

    refute TurnError.domain?(%RuntimeError{message: "bug"})
    refute TurnError.domain?(%FunctionClauseError{})
  end

  test "an unknown type raises naming the known ones" do
    assert_raise ArgumentError, ~r/unknown :type :nope.*:persist_failed/, fn ->
      TurnError.exception(type: :nope)
    end
  end

  test "task_down drops a stacktrace and keeps the exception" do
    e = %RuntimeError{message: "x"}
    assert %TurnError{type: :task_down, reason: ^e} = TurnError.task_down({e, [{M, :f, 1, []}]})
    assert %TurnError{type: :task_down, reason: :killed} = TurnError.task_down(:killed)
  end

  test "messages name the failure, never a config or argument value" do
    secret = %{api_key: "sk-secret"}

    for e <- [
          %TurnError{type: :handler_crashed, handler: :append, reason: %MatchError{term: secret}},
          %TurnError{type: :task_down, reason: {:timeout, {GenServer, :call, [secret]}}},
          %TurnError{type: :session_unavailable, reason: {:no_config_template, "s1"}}
        ] do
      message = Exception.message(e)
      refute message =~ "sk-secret"
      assert message =~ String.replace(Atom.to_string(e.type), "_", " ")
    end
  end

  test "format_stacktrace keeps arities, never arguments" do
    text = TurnError.format_stacktrace([{M, :f, [%{api_key: "sk-secret"}], [file: ~c"m.ex", line: 1]}])
    assert text =~ "M.f/1"
    refute text =~ "sk-secret"
  end
end
```

`test/agents/base_agent_run_result_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentRunResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
  alias Normandy.LLMError
  alias Normandy.Test.StubClient

  defp agent(reply), do: BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})

  defp rate_limited(_rm),
    do: {:error, LLMError.new(type: :rate_limit, retryable?: true, status: 429)}

  test "run/2 returns {:ok, config, output}" do
    agent = agent(fn rm -> %{rm | chat_message: "hi"} end)

    assert {:ok, %Normandy.Agents.BaseAgentConfig{} = config, %BaseAgentOutputSchema{chat_message: "hi"}} =
             BaseAgent.run(agent, %{chat_message: "hello"})

    # The returned config carries the turn.
    assert length(Normandy.Components.AgentMemory.history(config.memory)) == 2
  end

  test "run/2 returns an LLM failure as {:error, %LLMError{}}" do
    assert {:error, %LLMError{type: :rate_limit, status: 429}} =
             BaseAgent.run(agent(&rate_limited/1), %{chat_message: "hello"})
  end

  test "run/2 returns invalid input as {:error, %ValidationError{}}" do
    assert {:error, %Normandy.Schema.ValidationError{}} =
             BaseAgent.run(agent(& &1), %{chat_mesage: "typo"})
  end

  test "run!/2 returns {config, output} and raises the same exception" do
    assert {_config, %BaseAgentOutputSchema{}} = BaseAgent.run!(agent(& &1), %{chat_message: "x"})

    assert_raise LLMError, ~r/rate_limit/, fn ->
      BaseAgent.run!(agent(&rate_limited/1), %{chat_message: "hello"})
    end
  end

  test "a bug in a client still raises from run/2" do
    agent = agent(fn _rm -> raise "client bug" end)
    assert_raise RuntimeError, "client bug", fn -> BaseAgent.run(agent, %{chat_message: "x"}) end
  end

  test "the run :exception event still fires for a returned error" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:normandy, :agent, :run, :exception]])
    BaseAgent.run(agent(&rate_limited/1), %{chat_message: "hello"})

    assert_received {[:normandy, :agent, :run, :exception], ^ref, _measurements,
                     %{kind: :error, reason: %LLMError{type: :rate_limit}, stacktrace: stacktrace}}

    # Frames carry arities, not arguments (a raised LLMError has no argument frames).
    assert Enum.all?(stacktrace, fn {_m, _f, arity, _loc} -> is_integer(arity) end)
  end
end
```

If the StubClient's `retry_options` default retries a retryable error, the test still sees one `{:error, ...}` at the end; it does not depend on attempts.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/turn_error_test.exs test/agents/base_agent_run_result_test.exs`
Expected: compile error (`Normandy.TurnError` undefined); after Step 3 the run tests still fail (`run/2` returns a 2-tuple, `run!/2` undefined).

- [ ] **Step 3: Create `Normandy.TurnError`**

`lib/normandy/turn_error.ex`:

```elixir
defmodule Normandy.TurnError do
  @moduledoc """
  A turn that failed for a reason that is not the model, the input or a guardrail.

  `Turn.Server.run/2`, `Turn.Session.run/2` and `AgentProcess.run/3` return
  `{:error, exception}`. The exception is Normandy's own (`Normandy.LLMError`,
  `Normandy.Schema.ValidationError`, `Normandy.Guardrails.ViolationError`,
  `Normandy.HookHaltError`, `Normandy.ModelCatalogError`) when that is what failed, and a
  `TurnError` otherwise. `:type` says which:

    * `:handler_crashed` - a handler or hook raised, exited or threw; `:handler` names it
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`, `:admit`, `:after_tool`,
      `:before_llm`, `:after_compact`, `:on_session_start`); `:reason` is the exception, or
      `{kind, term}` for an exit or throw
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason
    * `:approval_timeout` - nobody approved in time and `on_approval_timeout: :fail`;
      `:reason` is the list of tool call ids
    * `:task_down` - the LLM call, the compactor or the tool dispatch raised an exception
      that is not one of the above, or its worker stopped; `:reason` is the exception or
      the exit reason
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure
    * `:unexpected_event`, `:unresumable_state` - a persisted turn that can't continue, or
      a Normandy bug; `:reason` describes it

  A `TurnError` never carries a stacktrace; Normandy logs it where the failure happened.
  Its message names the failure but not values from it (they can hold the config or user
  data); read `:reason` for those.
  """

  @types [
    :handler_crashed,
    :persist_failed,
    :approval_timeout,
    :task_down,
    :session_unavailable,
    :unexpected_event,
    :unresumable_state
  ]

  # Normandy's failure exceptions: run/2,3 returns them, Turn.Server replies them bare.
  @domain [
    Normandy.LLMError,
    Normandy.Schema.ValidationError,
    Normandy.Guardrails.ViolationError,
    Normandy.HookHaltError,
    Normandy.ModelCatalogError,
    __MODULE__
  ]

  defexception [:type, :handler, :reason]

  @type type ::
          :handler_crashed
          | :persist_failed
          | :approval_timeout
          | :task_down
          | :session_unavailable
          | :unexpected_event
          | :unresumable_state

  @type t :: %__MODULE__{type: type(), handler: atom() | nil, reason: term()}

  @impl true
  def exception(fields) when is_list(fields) do
    type = Keyword.get(fields, :type)

    unless type in @types do
      raise ArgumentError,
            "Normandy.TurnError: unknown :type #{inspect(type)}, expected one of #{inspect(@types)}"
    end

    struct!(__MODULE__, fields)
  end

  @impl true
  def message(%__MODULE__{type: :handler_crashed, handler: handler, reason: reason}),
    do: "turn failed: handler crashed: #{inspect(handler)} (#{describe(reason)})"

  def message(%__MODULE__{type: :persist_failed, reason: reason}),
    do: "turn failed: persist failed: the session store rejected a write (#{describe(reason)})"

  def message(%__MODULE__{type: :approval_timeout, reason: ids}) when is_list(ids),
    do: "turn failed: approval timeout: #{length(ids)} tool call(s) not approved in time"

  def message(%__MODULE__{type: :task_down, reason: reason}),
    do: "turn failed: task down: the turn's worker failed (#{describe(reason)})"

  def message(%__MODULE__{type: :session_unavailable, reason: reason}),
    do: "session unavailable: the session could not be started (#{describe(reason)})"

  def message(%__MODULE__{type: type, reason: reason}),
    do: "turn failed: #{type |> Atom.to_string() |> String.replace("_", " ")} (#{describe(reason)})"

  @doc false
  # True for the exceptions run/2,3 returns instead of raising.
  @spec domain?(Exception.t()) :: boolean()
  def domain?(%module{}), do: module in @domain

  @doc false
  # A worker's exit reason as a TurnError; an {exception, stacktrace} reason keeps the
  # exception and drops the stacktrace.
  @spec task_down(term()) :: t()
  def task_down({exception, stacktrace}) when is_exception(exception) and is_list(stacktrace),
    do: %__MODULE__{type: :task_down, reason: exception}

  def task_down(reason), do: %__MODULE__{type: :task_down, reason: reason}

  @doc false
  # A stacktrace for a log line: frames keep the arity, never the arguments (a
  # FunctionClauseError's top frame holds them, and one may be the config).
  @spec format_stacktrace(Exception.stacktrace()) :: String.t()
  def format_stacktrace(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
    |> Exception.format_stacktrace()
  end

  # The module of an exception, the tag of a tagged tuple, an atom as is; never a value.
  defp describe(%module{}), do: inspect(module)
  defp describe(atom) when is_atom(atom), do: inspect(atom)
  defp describe({kind, _}) when kind in [:exit, :throw], do: Atom.to_string(kind)

  defp describe(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
    do: "{#{inspect(elem(tuple, 0))}, ...}"

  defp describe(_term), do: "a term"
end
```

In Turn.Server (Task 2.5), replace the private `arity_only/1` + `Exception.format_stacktrace/1` pair with `TurnError.format_stacktrace/1`.

- [ ] **Step 4: Split `run` into `run` and `run!`**

In `lib/normandy/agents/base_agent.ex`, rename today's two clauses to `run!` and add the tuple-returning `run`. Replace lines 448–517 (the `@spec run`, both `run` clauses and the `@doc` between them) with:

```elixir
  @doc """
  Runs one turn: validates `user_input` against the input schema, calls the model (and
  the tools it asks for, when the agent has tools) and returns the answer converted to
  the output schema.

  Returns `{:ok, config, output}`, where `config` holds the turn in its memory, or
  `{:error, exception}` when Normandy's own checks or the model failed:
  `Normandy.LLMError`, `Normandy.Schema.ValidationError`,
  `Normandy.Guardrails.ViolationError`, `Normandy.HookHaltError`,
  `Normandy.ModelCatalogError` or `Normandy.TurnError`. Any other exception (a bug in a
  tool, a hook under `on_error: :reraise`, a client) is raised. On `{:error, _}` the
  turn is lost: keep using the config you passed in.

  `user_input` may be `nil` to continue the conversation without a new user message.

  ## Example

      {:ok, agent, response} = BaseAgent.run(agent, %{chat_message: "Hello"})
  """
  @spec run(BaseAgentConfig.t(), term(), keyword()) ::
          {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}
  def run(config, user_input \\ nil, opts \\ []) do
    {config, output} = run!(config, user_input, opts)
    {:ok, config, output}
  rescue
    e -> if TurnError.domain?(e), do: {:error, e}, else: reraise(e, __STACKTRACE__)
  end

  @doc """
  Like `run/3`, but returns `{config, output}` and raises the exception `run/3` would
  return.
  """
  @spec run!(BaseAgentConfig.t(), term(), keyword()) :: {BaseAgentConfig.t(), term()}
  def run!(config, user_input \\ nil, opts \\ [])

  def run!(%BaseAgentConfig{tool_registry: tool_registry} = config, user_input, []) do
    # ... today's run/2 body, unchanged ...
  end

  def run!(config, user_input, opts) when is_list(opts) do
    # ... today's run/3 body, unchanged, except its last line
    # `run(config, user_input)` becomes `run!(config, user_input, [])`
  end
```

The rescue sits outside `with_agent_run_span/3`, so the run `:exception` event and `on_turn_end` still see the raise. Add `alias Normandy.TurnError`. Fix the comment in `run/2`'s old body that mentions "the public run_with_tools/2" only if it no longer reads true (Task 2.8 deletes `run_with_tools`).

- [ ] **Step 5: Move the tests to `run!`**

Tests whose subject is not the return shape keep their assertions by calling `run!`:

```bash
grep -rl "BaseAgent\.run(" test | xargs sed -i '' 's/BaseAgent\.run(/BaseAgent.run!(/g'
```

Then restore `BaseAgent.run(` in `test/agents/base_agent_run_result_test.exs` (the new file is about `run/2`). `mix test`: remaining failures are DSL agents (`MyAgent.run(agent, ...)` now returns a 3-tuple); switch each to `MyAgent.run!(` after Step 6. Do not change an assertion's meaning; if a test asserted that `run` raises, `run!` still does.

- [ ] **Step 6: The DSL gets the same pair**

In `lib/normandy/dsl/agent.ex`, replace the `run/2` and `run/3` definitions (keep `run_with_tools/2` until Task 2.8) with:

```elixir
      @doc """
      Runs the agent with input; see `Normandy.Agents.BaseAgent.run/3`.

      ## Examples

          {:ok, agent, response} = MyAgent.run(agent, "Hello!")
          {:ok, agent, response} = MyAgent.run(agent, %{chat_message: "Hello!"})
      """
      def run(agent, input, opts \\ []) when is_list(opts),
        do: BaseAgent.run(agent, prepare_input(input), opts)

      @doc "Like `run/3`, but returns `{agent, response}` and raises on failure."
      def run!(agent, input, opts \\ []) when is_list(opts),
        do: BaseAgent.run!(agent, prepare_input(input), opts)
```

Update the moduledoc example at `dsl/agent.ex:35` to `{:ok, updated_agent, response} = MyResearchAgent.run(agent, "Research quantum computing")`. Check `formatter_export_test` still passes (these are functions, not macros).

- [ ] **Step 7: Callers that keep raising switch to `run!`**

In `sequential_orchestrator.ex:255`, `parallel_orchestrator.ex:341`, `hierarchical_coordinator.ex:219` and `:353`, `batch/processor.ex:274` and `a2a/server.ex:187`, replace `BaseAgent.run(` with `BaseAgent.run!(`. Each sits inside an existing `rescue` that builds its error tuple; their return shapes are Task 3.5's.

- [ ] **Step 8: AgentProcess, Reactive and Workflow return the bare exception**

`agent_process.ex`, inline `handle_call({:run, input, otel_ctx}, _from, state)` (lines 397–435), the `try` body becomes:

```elixir
      try do
        case BaseAgent.run(state.agent, prepare_input(input)) do
          {:ok, updated_agent, response} ->
            runtime = System.monotonic_time(:millisecond) - start_time

            updated_state = %{
              state
              | agent: updated_agent,
                run_count: state.run_count + 1,
                last_run: DateTime.utc_now(),
                total_runtime_ms: state.total_runtime_ms + runtime
            }

            {:reply, {:ok, extract_result(response)}, updated_state}

          {:error, exception} ->
            Logger.error("Agent #{state.agent_id} failed: #{Exception.message(exception)}")
            {:reply, {:error, exception}, state}
        end
      rescue
        # A bug, not a Normandy error: reply it instead of crashing the process. The
        # stacktrace is logged (arities only), never replied.
        e ->
          Logger.error(
            "Agent #{state.agent_id} raised #{inspect(e.__struct__)}\n" <>
              TurnError.format_stacktrace(__STACKTRACE__)
          )

          {:reply, {:error, e}, state}
      after
        OtelCtx.detach(token)
      end
```

`handle_async_run/3` (line 647):

```elixir
  defp handle_async_run(agent, input, agent_id) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _updated_agent, response} -> {:ok, extract_result(response)}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e ->
      Logger.error(
        "Async agent #{agent_id} raised #{inspect(e.__struct__)}\n" <>
          TurnError.format_stacktrace(__STACKTRACE__)
      )

      {:error, e}
  end
```

`reactive.ex` `execute_agent/2` (struct clause) and `dsl/workflow.ex` `run_agent/2` follow the same shape (`{:ok, _, response} -> {:ok, response}`, `{:error, e} -> {:error, e}`, `rescue e ->` log with `TurnError.format_stacktrace/1` and `{:error, e}`). Add `require Logger` where missing (`reactive.ex`, `workflow.ex`'s quoted block if the function is inside `quote`: check `grep -n "require Logger" lib/normandy/dsl/workflow.ex`). Update `workflow.ex`'s comment above `run_agent` ("BaseAgent.run/2 raises on failure...") to describe the new shape, and `AgentProcess.run/3`'s `@spec` to `{:ok, term()} | {:error, Exception.t()}`.

The server-mode paths of `AgentProcess` (`spawn_run/3`, the `{:DOWN, ...}` clause, `handle_cast({:run_async, ...}, %{turn_engine: :server})`) are Task 2.5.

- [ ] **Step 9: Pin the coordinator tests to the cause (review M1, deferred 1.4 minor)**

In `test/coordination/reactive_test.exs`:

```elixir
      # A map without chat_message is rejected by the default input schema
      assert {:error, :all_failed} = Reactive.race(agents, %{custom: "data"})
```

stays (race reports only `:all_failed`), and the two vague assertions become:

```elixir
      assert {:ok, results} = Reactive.all(agents, %{data: 42})
      assert map_size(results) == 2

      assert Enum.all?(
               Map.values(results),
               &match?({:error, %Normandy.Schema.ValidationError{}}, &1)
             )
```

```elixir
      assert {:error, %Normandy.Schema.ValidationError{}} =
               Reactive.some(agents, %{data: 42}, count: 1)
```

If `Reactive.some/3` reports its failure as something other than the last agent's reason (read its `@doc`), assert that documented shape and the `ValidationError` inside it; do not loosen to `{:error, _}`. Tests matching `{:error, {:exception, e, _}}` from `AgentProcess.run`, `Reactive` or a workflow step become `{:error, e}` (`grep -rn "{:exception," test`).

- [ ] **Step 10: Docs**

- `README.md` quickstart step 3: `{:ok, agent, response} =` (Task 2.9 tests it).
- `lib/normandy/llm/json_deserializer.ex:32` and `lib/normandy/llm/claudio_adapter.ex:34`: `{:ok, agent, response} = ...BaseAgent.run(agent, input)`.
- `CLAUDE.md` BaseAgent bullet: `run/3` - Execute agent turn; returns `{:ok, config, response}` or `{:error, exception}` (Normandy errors only; bugs raise); `run!/3` returns `{config, response}` and raises`.
- `MIGRATING-2.0.md` §11: replace the bullets that say `run/2` raises with:

```markdown
- `BaseAgent.run/2,3` (and a DSL agent's `run/2,3`) return `{:ok, config, response}` or
  `{:error, exception}`, where the exception is a `Normandy.LLMError`,
  `Schema.ValidationError`, `Guardrails.ViolationError`, `HookHaltError`,
  `ModelCatalogError` or `TurnError`. Other exceptions (bugs) still raise.
  `run!/2,3` keeps 1.x's shape: `{config, response}`, raising the same exceptions. The
  quickest migration is `run(` → `run!(`.
- `AgentProcess.run/3`, `Reactive` results and workflow step errors are `{:error, exception}`
  (was `{:error, {:exception, exception, stacktrace}}`); the stacktrace is logged.
```

Keep §11's other bullets (retry, circuit breaker, `retry_if`) as they are.

- [ ] **Step 11: Run and commit**

Run: `mix format && mix test test/turn_error_test.exs test/agents/base_agent_run_result_test.exs && mix test 2>&1 | tail -5`
Expected: PASS, then ` 0 failures`.

```bash
git add lib/normandy/turn_error.ex lib/normandy/agents/base_agent.ex lib/normandy/dsl/agent.ex lib/normandy/dsl/workflow.ex lib/normandy/coordination/agent_process.ex lib/normandy/coordination/reactive.ex lib/normandy/coordination/sequential_orchestrator.ex lib/normandy/coordination/parallel_orchestrator.ex lib/normandy/coordination/hierarchical_coordinator.ex lib/normandy/batch/processor.ex lib/normandy/a2a/server.ex lib/normandy/llm/json_deserializer.ex lib/normandy/llm/claudio_adapter.ex README.md CLAUDE.md MIGRATING-2.0.md test/turn_error_test.exs test/agents/base_agent_run_result_test.exs
# then each modified test file by name (git status --short)
git commit -m "feat(agent)!: run/2,3 returns {:ok, config, output} | {:error, exception}; add run!/2,3" -m "BREAKING CHANGE: run/2,3 returns tuples; run!/2,3 keeps the 1.x shape. AgentProcess, Reactive and workflow steps return the bare exception. See MIGRATING-2.0.md §11."
```

---

### Task 2.5: `Turn.Server` replies exceptions, never tagged tuples or stacktraces (decision 6, 15b; DX-5, TEL-2)

**Files:**
- Modify: `lib/normandy/turn_error.ex` (add `from_reason/1`)
- Modify: `lib/normandy/agents/turn/server.ex`: moduledoc "Errors from `run/2`" (108–131); unavailable reply (515–524); admission replies (562–578); `start_turn/5` persist failure (809–818); `:DOWN` clause (634–648); `spawn_task/3` (1212–1242); `{:fail, reason}` clause (1155–1163); `arity_only/1` and its `Exception.format_stacktrace` uses
- Modify: `lib/normandy/agents/turn/session.ex:54-57` (`run/2`)
- Modify: `lib/normandy/hooks/server_glue.ex:16-18` (`fail_outcome/1`), `lib/normandy/hooks/base_agent_glue.ex:54-58` (`raised_outcome/2`), `lib/normandy/exceptions.ex:140-165` (`HookHaltError` moduledoc and `outcome/1`), `lib/normandy/behaviours/hooks.ex:53-54` (`outcome` type)
- Modify: `lib/normandy/coordination/agent_process.ex:563-622` (server-mode `spawn_run`, `:DOWN`), `:503-530` (server-mode `run_async`)
- Modify docs: `lib/normandy/telemetry.ex:327` (`error.type` rule), `MIGRATING-2.0.md` §12
- Test: `test/agents/turn/server_errors_test.exs` (create); update `test/agents/turn/server_test.exs`, `test/agents/turn/session_test.exs`, `test/agents/turn_approval_test.exs`, `test/coordination/agent_process_server_test.exs`, `test/hooks/*`, `test/a2a/agent_tool_test.exs`, `test/telemetry/{metadata,span_hierarchy}_test.exs` (`grep -rln "task_down\|handler_crashed\|:rejected, \|hook_halted\|persist_failed\|approval_timeout" test`)

**Interfaces:**
- Consumes: Task 2.4's `TurnError`, `TurnError.domain?/1`, `TurnError.task_down/1`, `TurnError.format_stacktrace/1`.
- Produces: `Turn.Server.run/2`, `Turn.Session.run/2`, server-mode `AgentProcess.run/3` :: `{:ok, term()} | {:error, Exception.t()}`.
- Produces: `TurnError.from_reason(turn_reason) :: Exception.t()` (`@doc false`): the one mapping from the Turn core's and the server's failure reasons to the replied exception.
- Produces: the `on_turn_end` outcome is `{:ok, response} | {:error, Exception.t()} | {:rejected, Exception.t()}` in both shells (`before_llm` halt: `{:error, %HookHaltError{}}`, was `{:error, {:hook_halted, e}}`).

Old reply → new reply (the table for updating tests and §12):

| 1.x / Wave 1 reply | 2.0 reply |
|---|---|
| `{:error, {:rejected, e}}` | `{:error, e}` (`ValidationError`, `ViolationError` or `HookHaltError{event: :on_prompt}`) |
| `{:error, {:hook_halted, e}}` | `{:error, e}` (`HookHaltError{event: :before_llm}`) |
| `{:error, {:task_down, {%LLMError{} = e, stacktrace}}}` | `{:error, e}` |
| `{:error, {:task_down, {other_exception, stacktrace}}}` | `{:error, %TurnError{type: :task_down, reason: other_exception}}` |
| `{:error, {:task_down, exit_reason}}` | `{:error, %TurnError{type: :task_down, reason: exit_reason}}` |
| `{:error, {:handler_crashed, name, e}}` | `{:error, %TurnError{type: :handler_crashed, handler: name, reason: e}}` |
| `{:error, {:persist_failed, r}}` | `{:error, %TurnError{type: :persist_failed, reason: r}}` |
| `{:error, {:approval_timeout, ids}}` | `{:error, %TurnError{type: :approval_timeout, reason: ids}}` |
| `{:error, {:unexpected_event, ...} = r}` | `{:error, %TurnError{type: :unexpected_event, reason: r}}` |
| `{:error, {:unresumable_state, status}}` | `{:error, %TurnError{type: :unresumable_state, reason: status}}` |
| `{:error, store_or_template_reason}` (session couldn't start) | `{:error, %TurnError{type: :session_unavailable, reason: store_or_template_reason}}` |

- [ ] **Step 1: Write the failing tests**

`test/agents/turn/server_errors_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerErrorsTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ToolCallResponse, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall
  alias Normandy.LLMError
  alias Normandy.TurnError

  # A store whose history read fails: the server starts :unavailable.
  defmodule DownStore do
    @moduledoc false
    def history(_handle, _sid), do: {:error, :store_down}
    def load_turn_state(_handle, _sid), do: {:error, :store_down}
    def save_turn_state(_handle, _sid, _ts), do: {:error, :store_down}
    def append_entry(_handle, _sid, _entry), do: {:error, :store_down}
  end

  # The first call asks for the weather tool; the second, after the tool ran, gets a 429.
  defp tool_then_429_client do
    calls = :counters.new(1, [])

    %Normandy.Test.StubClient{
      reply: fn _response_model ->
        :counters.add(calls, 1, 1)

        case :counters.get(calls, 1) do
          1 ->
            %ToolCallResponse{
              content: nil,
              tool_calls: [%ToolCall{id: "call_1", name: "weather", input: %{"city" => "Paris"}}]
            }

          _ ->
            {:error, LLMError.new(type: :rate_limit, retryable?: true, status: 429)}
        end
      end
    }
  end

  defp start_server(sid, config, store) do
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: store,
        registry: {Native, Native.new()}
      )

    srv
  end

  test "a 429 after tools ran replies the bare LLMError and leaves no stacktrace anywhere" do
    sid = "s-429-#{System.unique_integer([:positive])}"
    store = InMemory.new()

    config =
      BaseAgent.init(%{
        client: tool_then_429_client(),
        model: "m",
        tool_registry: Normandy.Tools.Registry.new([%Normandy.Test.FakeTool{notify: self()}])
      })

    ref = :telemetry_test.attach_event_handlers(self(), [[:normandy, :agent, :run, :exception]])
    srv = start_server(sid, config, {InMemory, store})

    assert {:error, %LLMError{type: :rate_limit, status: 429}} =
             Turn.Server.run(srv, %{chat_message: "weather in Paris?"})

    assert_received {:tool_ran, "weather"}
    assert Process.alive?(srv)

    assert {:ok, turn_state} = InMemory.load_turn_state(store, sid)
    refute contains_stacktrace?(turn_state)

    assert_received {[:normandy, :agent, :run, :exception], ^ref, _,
                     %{kind: :error, reason: %LLMError{type: :rate_limit}, stacktrace: []}}
  end

  test "a session whose store is down replies a :session_unavailable TurnError" do
    srv = start_server("s-down", BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}), {DownStore, nil})

    assert {:error, %TurnError{type: :session_unavailable, reason: :store_down}} =
             Turn.Server.run(srv, %{chat_message: "hi"})
  end

  test "Turn.Session.run/2 wraps a registry failure the same way" do
    defmodule DownRegistry do
      @moduledoc false
      def whereis(_handle, _sid), do: {:error, :registry_down}
    end

    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Turn.Session.run(
               [session_id: "s", registry: {DownRegistry, nil}, store: {InMemory, InMemory.new()},
                supervisor: nil, config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"})],
               "hi"
             )
  end

  test "a rejected input replies the bare ValidationError" do
    srv = start_server("s-reject", BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}), {InMemory, InMemory.new()})

    assert {:error, %Normandy.Schema.ValidationError{}} =
             Turn.Server.run(srv, %{chat_mesage: "typo"})
  end

  # A stacktrace is a list whose first element is an {module, function, arity_or_args, location} frame.
  defp contains_stacktrace?([{m, f, a, loc} | _])
       when is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)) and is_list(loc),
       do: true

  defp contains_stacktrace?(list) when is_list(list), do: Enum.any?(list, &contains_stacktrace?/1)
  defp contains_stacktrace?(tuple) when is_tuple(tuple), do: contains_stacktrace?(Tuple.to_list(tuple))
  defp contains_stacktrace?(%_{} = struct), do: contains_stacktrace?(Map.from_struct(struct))
  defp contains_stacktrace?(map) when is_map(map), do: contains_stacktrace?(Map.to_list(map))
  defp contains_stacktrace?(_term), do: false
end
```

Adjust only setup calls to the real API if they differ (for example `Native.new/0`'s return, or `tool_registry:` being accepted by `init/1`; if it isn't, build the agent and call `BaseAgent.register_tool/2`). Keep every assertion.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/turn/server_errors_test.exs`
Expected: FAIL. The 429 test gets `{:error, {:task_down, {%LLMError{}, _}}}`; the store test gets `{:error, :store_down}`; the rejection test gets `{:error, {:rejected, _}}`.

- [ ] **Step 3: Map every failure reason to its exception in one place**

Add to `lib/normandy/turn_error.ex`:

```elixir
  @doc false
  # The exception a failed turn returns, from a failure reason of the Turn core or
  # Turn.Server (decision 15b): Normandy's own exceptions bare, anything else a
  # TurnError. Never a tagged tuple, never a stacktrace.
  @spec from_reason(term()) :: Exception.t()
  def from_reason({:rejected, exception}) when is_exception(exception), do: exception
  def from_reason({:hook_halted, exception}) when is_exception(exception), do: exception

  def from_reason({:handler_crashed, name, reason}),
    do: %__MODULE__{type: :handler_crashed, handler: name, reason: reason}

  def from_reason({:persist_failed, reason}), do: %__MODULE__{type: :persist_failed, reason: reason}
  def from_reason({:approval_timeout, ids}), do: %__MODULE__{type: :approval_timeout, reason: ids}
  def from_reason({:task_down, reason}), do: task_down(reason)

  def from_reason({:unexpected_event, _state, _event} = reason),
    do: %__MODULE__{type: :unexpected_event, reason: reason}

  def from_reason({:unresumable_state, status}),
    do: %__MODULE__{type: :unresumable_state, reason: status}

  def from_reason(exception) when is_exception(exception),
    do: if(domain?(exception), do: exception, else: task_down(exception))

  def from_reason(other) do
    raise ArgumentError,
          "Normandy.TurnError.from_reason/1: no exception for turn failure #{inspect(other)}; " <>
            "a new failure reason needs a clause here"
  end
```

Add `from_reason/1` cases to `test/turn_error_test.exs`: one per row of the table above, plus the raise for an unknown term.

- [ ] **Step 4: The worker returns exceptions instead of dying**

In `spawn_task/3`, wrap the work so a raise becomes the turn's error event in the worker (DX-5: today the worker crashes and the `:DOWN` carries `{exception, stacktrace}`, which reaches the persisted turn state, the reply and telemetry):

```elixir
        run_while_server_alive(server, ref, fn ->
          OtelCtx.restore(otel_ctx)
          worker_event(kind, current.session_id, fn -> fun.(handlers, current) end)
        end)
```

and add:

```elixir
  # A raise in the LLM call, the compactor or the tool dispatch fails the turn with
  # that exception instead of killing the worker. Normandy's own exceptions (a 429's
  # LLMError) are expected outcomes and are not logged; anything else is a bug and is
  # logged here with its stacktrace (arities only), the one place the stacktrace goes.
  defp worker_event(kind, session_id, work) do
    work.()
  rescue
    e ->
      unless TurnError.domain?(e) do
        Logger.error(
          "Turn.Server #{kind} worker raised (session #{inspect(session_id)}): " <>
            describe_crash(:error, e, __STACKTRACE__) <>
            "\n" <> TurnError.format_stacktrace(__STACKTRACE__)
        )
      end

      {error_event(kind), e}
  end

  defp error_event(:tools), do: :tool_error
  defp error_event(_llm_or_compact), do: :llm_error
```

An exit or throw still kills the worker and arrives as `:DOWN`. In that clause, build the event from `TurnError.task_down/1` so no stacktrace enters the core:

```elixir
    event =
      case data.task_kind do
        :tools -> {:tool_error, TurnError.task_down(reason)}
        _llm_or_compact -> {:llm_error, TurnError.task_down(reason)}
      end
```

Replace `arity_only(stacktrace)` + `Exception.format_stacktrace(...)` in `handler_crash/5` with `TurnError.format_stacktrace(stacktrace)` and delete `arity_only/1`.

- [ ] **Step 5: Reply exceptions**

1. `{:fail, reason}` clause in `interpret/2`:

```elixir
      {:fail, reason} ->
        # Persist the terminal (:failed) turn state (best-effort) for the same reason.
        _ = persist_turn_state(data, data.turn_state)
        exception = TurnError.from_reason(reason)
        stop_run_span(data, :exception, %{kind: :error, reason: exception, stacktrace: []})
        reply(data, {:error, exception})
        turn_end(data, data.config, ServerGlue.fail_outcome(reason))
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}
```

2. Admission (`handle_event({:call, from}, {:turn, user_input, caller_ctx}, :idle, data)`): `{:rejected, exception}` replies `{:error, exception}`; `{:crashed, reason}` replies `{:error, TurnError.from_reason(reason)}` and passes `{:error, TurnError.from_reason(reason)}` to `turn_end`.
3. `start_turn/5`'s persist failure and `persist_failed/1`:

```elixir
  defp persist_failed(reason), do: {:error, %TurnError{type: :persist_failed, reason: reason}}
```

4. `:unavailable` turn request: `{:reply, from, {:error, %TurnError{type: :session_unavailable, reason: reason}}}`.
5. Add `alias Normandy.TurnError`.

- [ ] **Step 6: Hook outcomes carry exceptions**

- `ServerGlue.fail_outcome/1`:

```elixir
  def fail_outcome({:rejected, exception}), do: {:rejected, exception}
  def fail_outcome(reason), do: {:error, Normandy.TurnError.from_reason(reason)}
```

- `HookHaltError.outcome/1`: the `before_llm` clause returns `{:error, e}`; update its `@spec` (`{:rejected, t()} | {:error, t()}`), `@doc` and the moduledoc sentence ("`Turn.Server` replies `{:error, e}` for both").
- `BaseAgentGlue.raised_outcome/2`: the last clause becomes `defp raised_outcome(kind, reason), do: {:error, Normandy.TurnError.task_down({kind, reason})}`.
- `Normandy.Behaviours.Hooks` `@type outcome :: {:ok, response :: term()} | {:error, Exception.t()} | {:rejected, Exception.t()}`.

- [ ] **Step 7: `Turn.Session.run/2` and server-mode `AgentProcess`**

```elixir
  @spec run(keyword(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def run(opts, user_input) do
    case ensure_server(opts) do
      {:ok, pid} -> Server.run(pid, user_input)
      {:error, reason} -> {:error, %Normandy.TurnError{type: :session_unavailable, reason: reason}}
    end
  end
```

`AgentProcess`: the `{:DOWN, ref, ...}` clause replies `{:error, TurnError.task_down(reason)}`. In the server-mode `run_async` task, the `rescue e ->` branch returns `{:error, e}` (logging `TurnError.format_stacktrace(__STACKTRACE__)`, not `inspect`), and the `catch kind, reason ->` branch returns `{:error, TurnError.task_down({kind, reason})}` and logs `"Async agent #{agent_id} #{kind}"` without `inspect(reason)`.

- [ ] **Step 8: Docs**

- Rewrite Turn.Server's moduledoc section "Errors from `run/2`" as: `run/2` returns `{:error, exception}`; Normandy's own exceptions (list them) bare; anything else a `Normandy.TurnError`, whose `:type` (one line each, copied from `TurnError`'s moduledoc) says what failed; "A rejected input or a blocked answer persists nothing of the answer (the user message is kept for a blocked answer); the server stays alive in every case." Remove every `{:rejected, ...}`, `{:handler_crashed, ...}`, `{:task_down, ...}` example from the moduledoc and the `:exception` telemetry paragraph (`reason` is now the exception).
- `lib/normandy/telemetry.ex:327`: `error.type` is "an `LLMError`'s or `TurnError`'s `type`, else the exception module; tool `error_type`".
- `MIGRATING-2.0.md` §12: replace the reply table with the old→new table above (all rows), and add: "`on_turn_end` hooks receive `{:error, exception}` too; a `before_llm` halt is `{:error, %HookHaltError{}}`, not `{:error, {:hook_halted, e}}`."

- [ ] **Step 9: Update the existing tests, then run**

Rewrite each old-shape match with the table above (do not loosen to `{:error, _}`): `server_test.exs:560` becomes `reason: %TurnError{type: :task_down, reason: %RuntimeError{message: "llm down"}}`, `:1380` becomes `{:error, %Normandy.ModelCatalogError{model: "test"}}` (a domain exception, now bare), `agent_process_server_test.exs:377` asserts `%TurnError{type: :task_down}`.

Run: `mix format && mix test test/agents/turn test/coordination test/hooks test/telemetry test/a2a test/turn_error_test.exs && mix test 2>&1 | tail -5`
Expected: PASS, then ` 0 failures`. Also: `grep -rn "task_down, {\|:handler_crashed,\|{:rejected,\|{:hook_halted," lib` shows only the Turn core's internal reasons (`turn.ex`, `server.ex` internals, `TurnError.from_reason/1`), none in a reply or a moduledoc.

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/turn_error.ex lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/session.ex lib/normandy/hooks/server_glue.ex lib/normandy/hooks/base_agent_glue.ex lib/normandy/exceptions.ex lib/normandy/behaviours/hooks.ex lib/normandy/coordination/agent_process.ex lib/normandy/telemetry.ex MIGRATING-2.0.md test/agents/turn/server_errors_test.exs test/turn_error_test.exs
# then each modified test file by name
git commit -m "feat(turn)!: Turn.Server replies the exception; TurnError for shell failures" -m "BREAKING CHANGE: Turn.Server.run/2, Turn.Session.run/2 and server-mode AgentProcess.run/3 return {:error, exception}. No stacktrace is replied, persisted or emitted. See MIGRATING-2.0.md §12."
```

---

### Task 2.6: Output that fails its schema is an error (SEC-5, TEL-4)

`validate_turn_output/2` (`base_agent.ex:808-820`) prints the whole output to stderr with `IO.warn` and returns it as valid. An output that is already the schema's struct is never checked (`validation_middleware.ex:157`), so a client that returns the struct directly bypasses validation.

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex:808-820`
- Modify: `lib/normandy/agents/validation_middleware.ex:154-164`
- Modify: `lib/normandy/agents/turn/server.ex` (`{:validate_output, value}` effect)
- Modify: `MIGRATING-2.0.md` (new §19)
- Test: `test/agents/base_agent_output_validation_test.exs` (create)

**Interfaces:**
- Consumes: Task 2.4 (`run/2` returns `ValidationError`), Task 2.5 (`Turn.Server` replies it bare).
- Produces: an invalid output gives `{:error, %Normandy.Schema.ValidationError{message: "Agent output validation failed"}}` from `run/2` and `Turn.Server.run/2`; nothing is written to stderr; the assistant answer is not saved.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Normandy.Agents.BaseAgentOutputValidationTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Schema.ValidationError

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true, enum: ["approve", "deny"])
    end
  end

  defp agent(action) do
    BaseAgent.init(%{
      client: %Normandy.Test.StubClient{reply: fn _rm -> %Decision{action: action} end},
      model: "m",
      output_schema: %Decision{}
    })
  end

  test "a valid output is returned" do
    assert {:ok, _config, %Decision{action: "approve"}} = BaseAgent.run(agent("approve"), %{chat_message: "x"})
  end

  test "an output outside its schema is {:error, %ValidationError{}}, with nothing on stderr" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:result, BaseAgent.run(agent("delete_everything"), %{chat_message: "x"})})
      end)

    assert_received {:result, {:error, %ValidationError{errors: [_ | _]}}}
    assert stderr == ""
  end

  test "Turn.Server replies the ValidationError and does not save the answer" do
    store = InMemory.new()

    {:ok, srv} =
      Normandy.Agents.Turn.Server.start_link(
        session_id: "s-invalid-out",
        config: agent("delete_everything"),
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    assert {:error, %ValidationError{}} = Normandy.Agents.Turn.Server.run(srv, %{chat_message: "x"})
    assert {:ok, entries} = InMemory.history(store, "s-invalid-out")
    refute Enum.any?(entries, &(&1.role == "assistant"))
  end
end
```

Use the schema DSL's real option for allowed values (`enum:`, `inclusion:` or a validation callback; check `grep -n "enum\|inclusion" lib/normandy/schema*.ex lib/normandy/schema/*.ex`). The point is a constraint a struct-typed value can break.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/base_agent_output_validation_test.exs`
Expected: FAIL; the invalid output is returned as `{:ok, _, %Decision{action: "delete_everything"}}`.

- [ ] **Step 3: Validate struct outputs**

In `ValidationMiddleware.validate_output/2`, the same-struct branch validates too:

```elixir
  def validate_output(%BaseAgentConfig{output_schema: output_schema}, output)
      when is_struct(output) do
    # An output already of the schema's struct is checked like any other: a client that
    # builds the struct itself must not bypass the schema's constraints.
    validate_output_map(output_schema, Map.from_struct(output))
  end
```

`validate_output_map/2` already skips `BaseAgentOutputSchema` and schemas without `__schema__/1`. If `Map.from_struct/1` keeps `:__meta__` and `Validator.validate/2` rejects it, drop that key first.

- [ ] **Step 4: Raise instead of warning**

```elixir
  # An output that breaks its schema is an error (SEC-5): run/2 returns the
  # ValidationError. Neither the value nor the errors are logged: they can hold user data.
  defp validate_turn_output(config, value) do
    case ValidationMiddleware.validate_output(config, value) do
      {:ok, validated} ->
        validated || value

      {:error, errors} ->
        raise Normandy.Schema.ValidationError,
          message: "Agent output validation failed",
          errors: errors
    end
  end
```

Delete the inner `alias Normandy.Agents.ValidationMiddleware` (the module alias at the top already covers it).

- [ ] **Step 5: Turn.Server treats it as a rejection, not a handler crash**

In `interpret/2`, the `{:validate_output, value}` effect:

```elixir
      {:validate_output, value} ->
        # An output that breaks its schema is a rejection of the answer, not a crash.
        guarded(
          data,
          :validate,
          fn -> validate_output(data, value) end,
          fn
            {:output_invalid, e} -> fail(data, {:rejected, e})
            validated -> advance(rest, data, {:output_validated, validated})
          end
        )
```

with, next to `guard_output/2`:

```elixir
  defp validate_output(data, value) do
    data.handlers.validate.(data.config, value)
  rescue
    e in Normandy.Schema.ValidationError -> {:output_invalid, e}
  end
```

`fail(data, {:rejected, e})` replies `{:error, e}` through `TurnError.from_reason/1` (Task 2.5) and gives `on_turn_end` `{:rejected, e}`, like a blocked output guardrail.

- [ ] **Step 6: MIGRATING and run**

Append before "## New, non-breaking":

```markdown
## 19. An output that breaks its schema is an error

When the model's answer doesn't satisfy the agent's `output_schema` (a required field
missing, a value outside its allowed set), `run/2` returns
`{:error, %Normandy.Schema.ValidationError{}}` and `Turn.Server.run/2` replies it. The
answer is not saved. In 1.x it was returned as if valid, and the whole value was printed to
stderr. An output already of the schema's struct is now validated too.
```

Run: `mix format && mix test test/agents/base_agent_output_validation_test.exs && mix test 2>&1 | tail -5`
Expected: PASS, then ` 0 failures`. A test that relied on an invalid output being returned is a real behaviour change: update it to expect the `ValidationError` and name it in the commit body.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/base_agent.ex lib/normandy/agents/validation_middleware.ex lib/normandy/agents/turn/server.ex MIGRATING-2.0.md test/agents/base_agent_output_validation_test.exs
# plus any updated test file by name
git commit -m "fix(agent)!: an output that breaks its schema is a ValidationError, not a warning" -m "BREAKING CHANGE: invalid output returns {:error, %ValidationError{}} instead of being returned with an IO.warn. See MIGRATING-2.0.md §19."
```

---

### Task 2.7: Text input for the default schema; no bypass for a default-schema struct (DX-12 rest)

**Files:**
- Modify: `lib/normandy/agents/validation_middleware.ex:48-74` (`validate_input/2`)
- Modify: `MIGRATING-2.0.md` §18 (Task 2.0's section)
- Test: `test/agents/validation_middleware_test.exs`, `test/agents/base_agent_run_result_test.exs`

**Interfaces:**
- Produces: `run(config, "text")`, `stream(config, "text", cb)` and `Turn.Server.run(srv, "text")` send `%BaseAgentInputSchema{chat_message: "text"}` when the agent uses the default input schema. With another input schema, a non-map input is `{:error, %ValidationError{}}`. With `input_schema: nil`, any input passes through as today.

- [ ] **Step 1: Write the failing tests**

In `validation_middleware_test.exs`, inside the describe that uses `config(input_schema: %BaseAgentInputSchema{})`:

```elixir
    test "a string becomes the chat_message of the default schema" do
      assert {:ok, %BaseAgentInputSchema{chat_message: "hi"}} =
               ValidationMiddleware.validate_input(config(input_schema: %BaseAgentInputSchema{}), "hi")
    end

    test "a default-schema struct is validated, not trusted" do
      assert {:error, [%{constraint: :type, path: [:chat_message]}]} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %BaseAgentInputSchema{chat_message: nil}
               )
    end
```

and in a describe for a custom schema (reuse one the file has, or the `RequiredQueryInput`-style schema from `test/agents/turn/server_test.exs`):

```elixir
    test "a non-map input for a custom schema is a type error naming the schema" do
      assert {:error, [%{constraint: :type, path: [], message: message}]} =
               ValidationMiddleware.validate_input(config(input_schema: %CustomInput{}), "hi")

      assert message =~ "CustomInput"
      assert message =~ "got: a string"
    end
```

In `base_agent_run_result_test.exs`:

```elixir
  test "run/2 accepts text for the default schema and sends it as the user message" do
    client = %StubClient{notify: self()}
    agent = BaseAgent.init(%{client: client, model: "m"})

    assert {:ok, _config, _output} = BaseAgent.run(agent, "hello")

    assert_receive {:converse, %Normandy.LLM.Request{messages: [%{role: "user", content: content}]}, _}
    assert %Normandy.Agents.BaseAgentInputSchema{chat_message: "hello"} = content
  end
```

(If memory stores the input as its JSON encoding rather than the struct, assert the `chat_message` text is in it; keep the check that the text reached the client.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/validation_middleware_test.exs test/agents/base_agent_run_result_test.exs`
Expected: FAIL; a string passes through unvalidated; the nil struct is accepted.

- [ ] **Step 3: Implement**

In `validate_input/2`, before the `is_map(input)` clause:

```elixir
  def validate_input(%BaseAgentConfig{input_schema: %BaseAgentInputSchema{}}, text)
      when is_binary(text),
      do: {:ok, %BaseAgentInputSchema{chat_message: text}}

  # A default-schema struct is checked like a map: %BaseAgentInputSchema{chat_message: nil}
  # would otherwise send an empty user turn.
  def validate_input(%BaseAgentConfig{input_schema: %BaseAgentInputSchema{}}, %BaseAgentInputSchema{} = input),
    do: validate_base_input(Map.from_struct(input))
```

and replace the catch-all clause:

```elixir
  # Anything but a map or struct can't be cast into a schema.
  def validate_input(%BaseAgentConfig{input_schema: %schema{}}, input) do
    {:error,
     format_validation_errors("Input", [
       %{
         path: [],
         message: "expected a map or %#{inspect(schema)}{}, got: #{Describe.type_of(input)}",
         constraint: :type
       }
     ])}
  end
```

Add `alias Normandy.Agents.BaseAgentInputSchema` and `alias Normandy.Components.ContentBlock.Describe`. `validate_base_input/1` already subtracts `:__meta__`, which `Map.from_struct/1` keeps.

- [ ] **Step 4: MIGRATING**

Append to §18:

```markdown
- `run(agent, "text")` is `run(agent, %{chat_message: "text"})` for the default schema. With
  a custom input schema, input that isn't a map or the schema's struct (a string, a number)
  is now a `ValidationError`; in 1.x it was sent as is.
- A `%BaseAgentInputSchema{}` struct is validated too: `chat_message: nil` is rejected.
```

- [ ] **Step 5: Run and commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`. A test that passed a bare string to an agent with a custom schema now gets a `ValidationError`: if the test meant a chat message, give it `%{chat_message: ...}` or the default schema; name it in the commit body.

```bash
git add lib/normandy/agents/validation_middleware.ex MIGRATING-2.0.md test/agents/validation_middleware_test.exs test/agents/base_agent_run_result_test.exs
git commit -m "feat(agent): text input for the default schema; validate default-schema structs"
```

---

### Task 2.8: One streaming entry point, `stream/3`, with schema output and `%StreamEvent{}` callbacks (decision 13, 15d; DX-11, DX-30)

**Files:**
- Rewrite: `lib/normandy/components/stream_event.ex`
- Modify: `lib/normandy/components/stream_processor.ex` (drop the three old `%StreamEvent{}` clauses: 44, 123, 129; the `@spec` at 81)
- Modify: `lib/normandy/agents/base_agent.ex`: delete `run_with_tools/2` (525–554), `stream_response/3` (1238–1286), `stream_with_tools/3` (1288–1345); `run!/3`'s opts clause; `run_stream_turn/3` (1019–1037); `streaming_handlers/1` (1047–1063); `track_first_chunk/1`, `track_delivery/2`, `deliver_stream_event/2` (Task 2.2), `dispatch_stream_tools/3`, `report_incremental_violation/4`, `run_streaming_output_guardrails/3`; `build_stream_request/1`
- Modify: `lib/normandy/dsl/agent.ex` (delete `run_with_tools/2`, add `stream/3`; the `max_tool_concurrency` doc at 181)
- Modify docs: `lib/normandy/telemetry.ex:33`, `lib/normandy/guardrails.ex:70-110`, `lib/normandy/dsl/agent.ex:287`, `CLAUDE.md`, `MIGRATING-2.0.md` (new §20; §11's last bullet)
- Create: `test/support/scripted_text_client.ex`
- Test: `test/agents/base_agent_stream_test.exs` (create); migrate `test/agents/base_agent_streaming*_test.exs`, `base_agent_stream_*_test.exs`, `test/telemetry/*` and every test calling the deleted functions (`grep -rln "run_with_tools\|stream_response\|stream_with_tools\|stream: true" test`)

**Interfaces:**
- Consumes: Task 2.2 (`deliver_stream_event/2`, `build_stream_request/1`), Task 2.4 (`TurnError.domain?/1`), Task 2.6 (`validate_turn_output/2` raises).
- Produces: `BaseAgent.stream(config, input, callback) :: {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}`, `callback :: (Normandy.Components.StreamEvent.t() -> any())`. The output is converted to the output schema exactly like `run/2`'s.
- Produces: `%Normandy.Components.StreamEvent{type, data}` with `type in [:message_start, :text_delta, :thinking_delta, :tool_use_start, :tool_result, :guardrail_violation, :message_stop]`; `data` per type: `%{id:, model:}`, text, text, `%{id:, name:}`, `%Normandy.Components.ToolResult{}`, `%{stage:, mode:, violations:}`, `nil`.
- Produces: `run!/3` and `run/3` raise `ArgumentError` for any option (none exist yet; Wave 3 adds them), with a `stream/3` hint for `:stream`/`:on_chunk`.
- Removes: `BaseAgent.run_with_tools/2`, `stream_response/2,3`, `stream_with_tools/2,3`, the DSL's `run_with_tools/2`, the `:guardrail_violations` key on streamed responses.

- [ ] **Step 1: Add the scripted text client**

`test/support/scripted_text_client.ex`:

```elixir
defmodule Normandy.Test.ScriptedTextClient do
  @moduledoc """
  A model client for tests that answers every request with `:text`.

  `converse/3` fills the response model the way an adapter does: `:chat_message` gets
  the text, any other schema gets the text decoded as JSON. `stream/3` streams the same
  text as two text deltas. With `fail_after_first_delta: true`, the stream ends in a
  transport error after its first delta. `:calls`, a `:counters` ref, counts `stream/3`
  calls.
  """
  defstruct text: "", fail_after_first_delta: false, calls: nil, options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.Response

    def converse(client, request, _opts),
      do: {:ok, %Response{content: fill(request.response_model, client.text), stop_reason: :end_turn}}

    def stream(client, _request, _opts) do
      if client.calls, do: :counters.add(client.calls, 1, 1)
      {first, rest} = String.split_at(client.text, div(String.length(client.text), 2))

      head = [
        %{type: "message_start", message: %{"id" => "msg_1", "model" => "m", "role" => "assistant"}},
        %{type: "content_block_start", index: 0, content_block: %{"type" => "text", "text" => ""}},
        delta(first)
      ]

      tail =
        if client.fail_after_first_delta do
          [{:error, :closed}]
        else
          [
            delta(rest),
            %{type: "content_block_stop", index: 0},
            %{type: "message_delta", delta: %{"stop_reason" => "end_turn"}, usage: %{"output_tokens" => 2}},
            %{type: "message_stop"}
          ]
        end

      {:ok, head ++ tail}
    end

    defp delta(text),
      do: %{type: "content_block_delta", index: 0, delta: %{"type" => "text_delta", "text" => text}}

    defp fill(nil, text), do: text
    defp fill(%{chat_message: _} = response_model, text), do: %{response_model | chat_message: text}
    defp fill(%module{}, text), do: struct(module, Jason.decode!(text, keys: :atoms))
  end
end
```

- [ ] **Step 2: Write the failing tests**

`test/agents/base_agent_stream_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentStreamTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
  alias Normandy.Components.StreamEvent
  alias Normandy.LLMError
  alias Normandy.Test.ScriptedTextClient

  defmodule Answer do
    use Normandy.Schema

    io_schema "An answer" do
      field(:answer, :string, required: true)
    end
  end

  defp agent(client, extra \\ %{}), do: BaseAgent.init(Map.merge(%{client: client, model: "m"}, extra))

  defp collect do
    test_pid = self()
    fn %StreamEvent{} = event -> send(test_pid, {:event, event}) end
  end

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  test "stream/3 and run/2 return the same chat output" do
    client = %ScriptedTextClient{text: "Actors share nothing."}

    assert {:ok, _, %BaseAgentOutputSchema{chat_message: "Actors share nothing."} = streamed} =
             BaseAgent.stream(agent(client), %{chat_message: "hi"}, collect())

    assert {:ok, _, ^streamed} = BaseAgent.run(agent(client), %{chat_message: "hi"})
  end

  test "stream/3 and run/2 return the same struct for a non-chat schema" do
    client = %ScriptedTextClient{text: ~s({"answer": "42"})}
    a = agent(client, %{output_schema: %Answer{}})

    assert {:ok, _, %Answer{answer: "42"} = streamed} = BaseAgent.stream(a, "q", collect())
    assert {:ok, _, ^streamed} = BaseAgent.run(a, "q")
  end

  test "the callback receives %StreamEvent{} in order" do
    BaseAgent.stream(agent(%ScriptedTextClient{text: "abcd"}), "hi", collect())

    assert [
             %StreamEvent{type: :message_start, data: %{id: "msg_1", model: "m"}},
             %StreamEvent{type: :text_delta, data: "ab"},
             %StreamEvent{type: :text_delta, data: "cd"},
             %StreamEvent{type: :message_stop, data: nil}
           ] = events()
  end

  test "a non-chat answer that isn't JSON is the error run/2 would give" do
    client = %ScriptedTextClient{text: "not json at all", options: %{on_parse_failure: :error}}

    assert {:error, %LLMError{type: :invalid_output}} =
             BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
  end

  test "a stream that fails after output reached the callback is not retried" do
    calls = :counters.new(1, [])
    client = %ScriptedTextClient{text: "abcd", fail_after_first_delta: true, calls: calls}
    a = agent(client, %{retry_options: [max_attempts: 3, base_delay: 1]})

    assert {:error, %LLMError{type: :stream}} = BaseAgent.stream(a, "hi", collect())
    assert :counters.get(calls, 1) == 1

    assert [%StreamEvent{type: :message_start}, %StreamEvent{type: :text_delta, data: "ab"}] =
             events()
  end

  test "a client that can't stream gives {:error, %LLMError{type: :unsupported}}" do
    assert {:error, %LLMError{type: :unsupported}} =
             BaseAgent.stream(agent(%Normandy.Test.StubClient{}), "hi", collect())
  end

  test "the old entry points are gone" do
    refute function_exported?(BaseAgent, :run_with_tools, 2)
    refute function_exported?(BaseAgent, :stream_response, 3)
    refute function_exported?(BaseAgent, :stream_with_tools, 3)
  end

  test "run/3 rejects the old streaming options with a stream/3 hint" do
    assert_raise ArgumentError, ~r/BaseAgent.stream\/3/, fn ->
      BaseAgent.run(agent(%ScriptedTextClient{text: "x"}), "hi", stream: true, on_chunk: & &1)
    end
  end
end
```

If `ParseFailure` reads `:on_parse_failure` from somewhere other than `client.options` (check `ParseFailure.policy/1`), set it there. `Code.ensure_loaded!(BaseAgent)` before the `function_exported?` checks if the module may not be loaded yet.

- [ ] **Step 3: Run to verify they fail**

Run: `mix test test/agents/base_agent_stream_test.exs`
Expected: FAIL; `BaseAgent.stream/3` is undefined.

- [ ] **Step 4: Redefine `StreamEvent`**

Replace `lib/normandy/components/stream_event.ex`:

```elixir
defmodule Normandy.Components.StreamEvent do
  @moduledoc """
  What a `Normandy.Agents.BaseAgent.stream/3` callback receives, in stream order.

  | `type` | `data` |
  |---|---|
  | `:message_start` | `%{id: String.t() \\| nil, model: String.t() \\| nil}` |
  | `:text_delta` | the new text |
  | `:thinking_delta` | the new thinking text |
  | `:tool_use_start` | `%{id: String.t(), name: String.t()}`; the input arrives later |
  | `:tool_result` | the `%Normandy.Components.ToolResult{}` of a finished tool call |
  | `:guardrail_violation` | `%{stage: :output, mode: :accumulate \\| :incremental, violations: list()}` |
  | `:message_stop` | `nil` |

  With tools, one `stream/3` call streams several model messages, each from
  `:message_start` to `:message_stop`, with `:tool_result` events between them. With
  `max_tool_concurrency > 1`, `:tool_result` events arrive in completion order.
  """

  @enforce_keys [:type]
  defstruct [:type, :data]

  @type type ::
          :message_start
          | :text_delta
          | :thinking_delta
          | :tool_use_start
          | :tool_result
          | :guardrail_violation
          | :message_stop

  @type t :: %__MODULE__{type: type(), data: term()}
end
```

In `stream_processor.ex`, delete `defp message_stop?(%StreamEvent{type: :message_stop})`, the `%StreamEvent{}` clauses of `text_delta?/1` and `extract_text_delta/1`, and the alias; change `build_final_message/1`'s spec to `[map()] :: map()`.

- [ ] **Step 5: Deliver `%StreamEvent{}`**

Every internal callback call becomes arity 1:

- `deliver_stream_event/2` (Task 2.2):

```elixir
  defp deliver_stream_event(%{type: "message_start", message: message}, callback),
    do: callback.(%StreamEvent{type: :message_start, data: %{id: message["id"], model: message["model"]}})

  defp deliver_stream_event(
         %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}},
         callback
       ),
       do: callback.(%StreamEvent{type: :text_delta, data: text})

  defp deliver_stream_event(
         %{type: "content_block_delta", delta: %{"type" => "thinking_delta", "thinking" => text}},
         callback
       ),
       do: callback.(%StreamEvent{type: :thinking_delta, data: text})

  defp deliver_stream_event(
         %{type: "content_block_start", content_block: %{"type" => "tool_use"} = tool},
         callback
       ),
       do: callback.(%StreamEvent{type: :tool_use_start, data: %{id: tool["id"], name: tool["name"]}})

  defp deliver_stream_event(%{type: "message_stop"}, callback),
    do: callback.(%StreamEvent{type: :message_stop, data: nil})

  defp deliver_stream_event(_event, _callback), do: :ok
```

- `dispatch_stream_tools/3`: `callback.(%StreamEvent{type: :tool_result, data: result})`.
- `report_incremental_violation/4` and `run_streaming_output_guardrails/3`: `callback.(%StreamEvent{type: :guardrail_violation, data: %{stage: :output, mode: mode, violations: violations}})`; drop the `is_function(callback, 2)` guards (the callback is always arity 1 now).
- `track_first_chunk/1` and `track_delivery/2`: guard on `is_function(callback, 1)` and wrap `fn event -> ...; callback.(event) end`.

- [ ] **Step 6: Convert the streamed answer to the output schema**

The Turn core converts only when `response_model != output_schema` (`turn.ex:465`). A streamed answer is always a message map, so `run_stream_turn/3` gives the core a response model that never equals the output schema:

```elixir
  # A streamed answer is the accumulated message map, never the output schema, so the
  # core always converts it (Turn.convert_needed?/1).
  @streamed_message :streamed_message

  defp run_stream_turn(config, user_input, callback) when is_function(callback, 1) do
    config = admit_turn_input(config, user_input)

    state =
      Turn.new(
        max_iterations: config.max_tool_iterations,
        response_model: @streamed_message,
        output_schema: config.output_schema
      )

    try do
      {config, final_state} =
        Driver.drive(state, HookHandlers.wrap(streaming_handlers(callback), config), config)

      {config, final_state.final_response}
    catch
      {:stream_turn_error, error} -> raise LLMError.wrap(error)
    end
  end
```

Check `call_stream_llm/3` and the streaming handlers never read `state.response_model` (they don't today: the request comes from `build_stream_request/1`).

`streaming_handlers/1`: the output guardrails move to `convert`, where the raw message (with its text) is still available; `validate` checks the schema like the non-streaming path:

```elixir
      # Accumulate-mode output guardrails run on the streamed text before it is
      # converted; they report, they don't block (the text already reached the caller).
      convert: fn config, message, output_schema ->
        run_streaming_output_guardrails(config, message, callback)
        convert_stream_output(config, message, output_schema)
      end,
      validate: &validate_turn_output/2,
      guard: fn _config, _value -> :ok end,
```

`run_streaming_output_guardrails/3` returns `:ok` (no more `:guardrail_violations` tagging); replace its `IO.warn(...)` with `Logger.warning("normandy agent streaming output guardrail violation", agent: log_agent_name(config), guards: Enum.map(guards, &guard_module/1))` (no violation text: it quotes the output). Add:

```elixir
  # The streamed message as the output schema, the way the non-streaming path returns
  # it: a :chat_message schema gets the text; any other schema parses the text as JSON
  # (the system prompt carried the schema, see build_stream_request/1) under the same
  # :on_parse_failure policy.
  defp convert_stream_output(_config, message, nil), do: message

  defp convert_stream_output(_config, message, %{chat_message: _} = schema),
    do: Map.put(schema, :chat_message, unwrap_llm_content(extract_streaming_text(message)))

  defp convert_stream_output(config, message, %{__struct__: _} = schema) do
    text = extract_streaming_text(message)

    request = %Normandy.LLM.Request{model: config.model, messages: [], max_tokens: config.max_tokens}

    case JsonDeserializer.deserialize_with_retry(text, schema, config.client, request, max_retries: 0) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        case ParseFailure.apply(schema, text, reason, %{client: config.client}) do
          {:error, %LLMError{} = error} -> raise error
          fallback -> fallback
        end
    end
  end
```

`build_stream_request/1` puts the schema in the system prompt for a non-chat schema (a chat schema streams plain text, so it gets none):

```elixir
    system_prompt =
      case config.output_schema do
        %{chat_message: _} -> system_prompt
        nil -> system_prompt
        schema -> with_output_schema(system_prompt, schema)
      end
```

placed before `prefix_key` is computed, so the prefix covers what was sent. Add aliases `Normandy.LLM.JsonDeserializer`, `Normandy.LLM.ParseFailure`, `Normandy.Components.StreamEvent`.

- [ ] **Step 7: `stream/3`; delete the old entry points; strict `run/3` options**

Add, after `run!/3`:

```elixir
  @doc """
  Runs one turn like `run/3`, streaming the model's output to `callback` as it arrives.

  `callback` receives a `Normandy.Components.StreamEvent` per event (text and thinking
  deltas, tool calls and results, guardrail reports). The return value is `run/3`'s:
  `{:ok, config, output}` with the answer converted to the output schema, or
  `{:error, exception}`. A client that can't stream gives
  `{:error, %Normandy.LLMError{type: :unsupported}}`.

  `retry_options` and the circuit breaker apply, but a stream is retried only until its
  first event reaches the callback, so no output is shown twice. Output guardrails
  report (`:guardrail_violation` event, telemetry) and don't block: the text was already
  delivered; with `output_guardrails_streaming_mode: :incremental` a violation stops
  the stream at the next chunk boundary.

  ## Example

      {:ok, agent, response} =
        BaseAgent.stream(agent, "Explain OTP", fn
          %StreamEvent{type: :text_delta, data: text} -> IO.write(text)
          _event -> :ok
        end)
  """
  @spec stream(BaseAgentConfig.t(), term(), (StreamEvent.t() -> any())) ::
          {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}
  def stream(config, user_input, callback) when is_function(callback, 1) do
    metadata = Metadata.run(config)

    {config, output} =
      with_agent_run_span(config, metadata, fn ->
        {run_stream_turn(config, user_input, callback), metadata}
      end)

    {:ok, config, output}
  rescue
    e -> if TurnError.domain?(e), do: {:error, e}, else: reraise(e, __STACKTRACE__)
  end
```

Delete `run_with_tools/2`, `stream_response/3` and `stream_with_tools/3` with their docs. `run!/3` becomes one function:

```elixir
  def run!(%BaseAgentConfig{tool_registry: tool_registry} = config, user_input, opts)
      when is_list(opts) do
    check_run_opts!(opts)
    # ... today's run/2 body (the agent.run span around run_turn/2) ...
  end

  # run/3 takes no options yet (Wave 3 adds them with NimbleOptions).
  defp check_run_opts!([]), do: :ok

  defp check_run_opts!(opts) do
    keys = Keyword.keys(opts)

    hint =
      if Enum.any?(keys, &(&1 in [:stream, :on_chunk])),
        do: " Streaming moved to BaseAgent.stream/3.",
        else: ""

    raise ArgumentError,
          "BaseAgent.run/3: unknown options #{inspect(keys)}; run/3 takes no options.#{hint}"
  end
```

The old `run/3` streaming body and its `stream: true requires :on_chunk` error go away. Remove the comment in the old `run/2` body about "the public run_with_tools/2".

- [ ] **Step 8: The DSL**

In `lib/normandy/dsl/agent.ex`, delete `run_with_tools/2` and its doc, and add:

```elixir
      @doc "Streams a turn; see `Normandy.Agents.BaseAgent.stream/3`."
      def stream(agent, input, callback) when is_function(callback, 1),
        do: BaseAgent.stream(agent, prepare_input(input), callback)
```

Fix the `max_tool_concurrency` doc (line 181): "`BaseAgent.stream/3` delivers `%StreamEvent{type: :tool_result}` from inside each worker...". Fix line 287's `:guardrail_violations` sentence: streaming output reports violations through the `:guardrail_violation` event and telemetry.

- [ ] **Step 9: Migrate the streaming tests**

- `stream_response(config, input, cb)` / `stream_with_tools(...)` → `BaseAgent.stream(config, input, cb)`, matching `{:ok, config, response}`; a test that expected a raise now matches `{:error, %LLMError{}}`.
- Arity-2 callbacks become arity 1: `fn :text_delta, t -> ...; _, _ -> :ok end` → `fn %StreamEvent{type: :text_delta, data: t} -> ...; _ -> :ok end`.
- `BaseAgent.run(config, input, stream: true, on_chunk: f)` → `BaseAgent.stream(config, input, f1)` with `f1` the arity-1 form.
- Assertions on the streamed response's content blocks (`response.content`) become assertions on the output struct (`response.chat_message`); `response.guardrail_violations` assertions become assertions on the received `%StreamEvent{type: :guardrail_violation}` (the tests already collect callback events; assert the violation list there). Keep each test's intent; name in the commit body any test whose assertion had to change meaning.
- `run_with_tools(config, input)` → `run!(config, input)`.

- [ ] **Step 10: Docs**

- `lib/normandy/telemetry.ex:33`: "One agent run: `BaseAgent.run/3`, `run!/3` or `stream/3`".
- `lib/normandy/guardrails.ex:70-110`: entry points are `run/3` and `stream/3`; streaming violations are reported through the `:guardrail_violation` `StreamEvent` and telemetry; delete the `:guardrail_violations` field description.
- `CLAUDE.md` BaseAgent bullets: add `stream/3 - like run/3, streaming %StreamEvent{} to a 1-arity callback`; remove anything naming the deleted functions.
- `MIGRATING-2.0.md` §11 last bullet: "`stream/3` returns `{:error, %Normandy.LLMError{}}` when the stream fails..." (replace the `stream_response/3` wording). Append before "## New, non-breaking":

```markdown
## 20. Entry points: `run/3`, `run!/3`, `stream/3`

| 1.x | 2.0 |
|---|---|
| `run(agent, input)` → `{agent, response}` | `run(agent, input)` → `{:ok, agent, response}` / `{:error, e}`, or `run!(agent, input)` → `{agent, response}` |
| `run_with_tools(agent, input)` | `run(agent, input)`: it runs the tool loop when tools are registered |
| `stream_response(agent, input, fn event, data -> ... end)` | `stream(agent, input, fn %StreamEvent{type: event, data: data} -> ... end)` |
| `stream_with_tools(agent, input, callback)` | `stream(agent, input, callback)` |
| `run(agent, input, stream: true, on_chunk: f)` | `stream(agent, input, f)` (raises `ArgumentError` otherwise) |
| DSL `MyAgent.run_with_tools/2` | `MyAgent.run/2`; streaming is `MyAgent.stream/3` |

- `stream/3` returns the answer converted to the output schema, like `run/3` (1.x returned
  the raw message map with its content blocks).
- Callbacks take one argument, a `%Normandy.Components.StreamEvent{type, data}`; the old
  `StreamEvent` (an SSE event with `:delta`, `:content_block`, ...) is gone. `:tool_use_start`
  data is `%{id:, name:}`, not the raw string-keyed block.
- The streamed response no longer has `:guardrail_violations`; violations arrive as a
  `:guardrail_violation` event and `[:normandy, :guardrail, ...]` telemetry.
- A client that can't stream gives `{:error, %LLMError{type: :unsupported}}`.
```

- [ ] **Step 11: Run and commit**

Run: `mix format && mix test test/agents/base_agent_stream_test.exs && mix test 2>&1 | tail -5`
Expected: PASS, then ` 0 failures`. Then `grep -rn "run_with_tools\|stream_response\|stream_with_tools\|guardrail_violations\|on_chunk" lib test docs/guides README.md CLAUDE.md` shows only MIGRATING-2.0.md.

```bash
git add lib/normandy/components/stream_event.ex lib/normandy/components/stream_processor.ex lib/normandy/agents/base_agent.ex lib/normandy/dsl/agent.ex lib/normandy/telemetry.ex lib/normandy/guardrails.ex CLAUDE.md MIGRATING-2.0.md test/support/scripted_text_client.ex test/agents/base_agent_stream_test.exs
# then each migrated test file by name
git commit -m "feat(agent)!: stream/3 replaces stream_response, stream_with_tools and run_with_tools" -m "BREAKING CHANGE: one streaming entry point returning the output schema; callbacks receive %StreamEvent{}. See MIGRATING-2.0.md §20."
```

---

### Task 2.9: The README quickstart is a test

**Files:**
- Create: `test/readme_test.exs`
- Modify: `test/hooks/guide_examples_test.exs:57` (assert before replacing; Wave 1 deferred minor)
- Modify: `README.md` only if the test shows the quickstart doesn't run

**Interfaces:**
- Consumes: Tasks 2.4 (tuple `run`), 1.3 (`max_tokens` default).

- [ ] **Step 1: Write the test**

```elixir
defmodule Normandy.ReadmeTest do
  @moduledoc """
  Runs the README's quickstart against a stubbed Messages API: if the README stops
  running, this fails.
  """
  use ExUnit.Case, async: true

  @api_key_line ~s|api_key: System.get_env("ANTHROPIC_API_KEY"),|
  @options_line "options: %{enable_caching: true}"

  test "the quickstart runs and sends max_tokens 16_000" do
    [block] =
      Regex.run(~r/## Quick Start.*?```elixir\n(.*?)```/s, File.read!("README.md"),
        capture: :all_but_first
      )

    # The swap below must not silently do nothing if the README changes.
    assert block =~ @api_key_line
    assert block =~ @options_line

    source =
      block
      |> String.replace(@api_key_line, ~s|api_key: "test-key",|)
      |> String.replace(
        @options_line,
        "options: %{enable_caching: true, req_options: [plug: {Req.Test, #{inspect(__MODULE__)}}, retry: false]}"
      )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-6",
        "content" => [%{"type" => "text", "text" => ~s({"chat_message": "Actors share nothing."})}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })
    end)

    {_value, binding} = Code.eval_string(source)

    assert %Normandy.Agents.BaseAgentOutputSchema{chat_message: "Actors share nothing."} =
             binding[:response]

    assert_received {:request, %{"max_tokens" => 16_000}}
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/readme_test.exs`
Expected: PASS (Task 2.4 already changed the README to `{:ok, agent, response} =`). If it fails because the quickstart doesn't run, fix `README.md`, not the test's assertions. Then check it bites: temporarily change `{:ok, agent, response}` to `{agent, response}` in `README.md`, see the test fail with a `MatchError`, and restore it.

- [ ] **Step 3: Guard the guide test's replacement**

In `test/hooks/guide_examples_test.exs`, before the `String.replace` (line 57):

```elixir
    assert source =~ "use ExUnit.Case,", "the guide's test module header changed"
```

- [ ] **Step 4: Commit**

```bash
git add test/readme_test.exs test/hooks/guide_examples_test.exs
# plus README.md if Step 2 changed it
git commit -m "test: run the README quickstart against a stubbed API"
```

---

### Task 2.10: Wave 2 gate

- [ ] **Step 1: Precommit**

Run: `mix format && mix precommit 2>&1 | tail -15`
Expected: exit 0; ` 0 failures`; credo no issues; dialyzer `Unnecessary Skips: 0`. A new dialyzer warning gets fixed, or an ignore entry with a reason.

- [ ] **Step 2: Docs and trace**

Run: `mix docs --warnings-as-errors && mix test --trace 2>&1 | tail -3`
Expected: both exit 0. New modules (`Normandy.LLM.Request`, `Response`, `Normandy.TurnError`) go into a `mix.exs` docs group next to their neighbours (`LLM` / errors); the full regrouping is Task 7.2.

- [ ] **Step 3: Acceptance greps**

```bash
grep -rn "completitions\|stream_converse\|ConverseResult\|run_with_tools\|stream_response\|stream_with_tools" lib test docs/guides README.md CLAUDE.md
grep -rn "{:exception, e, __STACKTRACE__}" lib/normandy/coordination/agent_process.ex lib/normandy/coordination/reactive.ex lib/normandy/dsl/workflow.ex
grep -rn "IO.warn(\"Agent output validation" lib
```

Expected: no hits.

- [ ] **Step 4: Record**

Append a Wave 2 line to `investigations/pre-2.0-audit/decisions.md` → "Progress": commit range, test count, and any rulings made during execution. Update the memory file `pre-2-0-audit-2026-10.md` and its `MEMORY.md` line. Next: `plan-wave-3.md`.

---

## Decided by Q (2026-10-04)

1. **OpenAI-compatible `max_tokens` (Wave 1 review I1):** option (b), a client option `:max_tokens_param` (`:max_tokens` default, `:max_completion_tokens` or `:omit`). Lands in Task 2.2 Step 6.
2. **Compactor reserve as large as the context window (Task 2.0):** raise, never clamp.
3. **`ModelCatalogError` among the errors `run/2,3` returns (Task 2.4):** accepted.
