# Fix 5: LLM Error Propagation — Tuples Inside, Raise at Edge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop both LLM adapters from swallowing API/transport failures into empty response structs. Introduce one canonical error struct (`Normandy.LLM.APIError`), return it as `{:error, %APIError{}}` from `Model.converse/7`, thread it through the Turn FSM's three interpreters as data, and raise it only at the public edge (`BaseAgent.run/2` via the Driver's `:fail` clause; `BaseAgent.get_response/2` directly). This is what makes the Retry/CircuitBreaker layer real: today adapters convert failures into successes before the resilience wrapper can see them, so retry conditions and breaker thresholds almost never trigger.

**Architecture:**

- **One error currency.** `Normandy.LLM.APIError` (defexception) carries `type` / `status` / `provider` / `message` / `retryable?`. Adapters map provider-specific failures into it at the boundary (`ClaudioAdapter.handle_error`, `__raw_completion__`; `OpenAICompatibleAdapter`'s two error branches). `IO.warn` becomes `Logger.error`.
- **Tuples inside.** `Model.converse` contract becomes `struct() | {struct(), usage} | {:error, APIError.t()}` (documented on the protocol). `ConverseResult.normalize/1` passes `{:error, _}` through unchanged. `call_llm_with_resilience` returns `{:error, %APIError{}}` instead of raising, after Retry (`retry_if` on `retryable?`) and CircuitBreaker (records the failure) have seen it. The `JsonDeserializer` corrective-call loop aborts on `{:error, _}` — an API error is not content to parse.
- **Raise at the edge.** `call_turn_llm` returns `{:llm_error, error}`; Driver and Server distinguish that from a normal response before feeding the FSM (`Turn.step` already handles `{:llm_error, reason}` → `:failed` → `{:fail, reason}` at `turn.ex:237-240` — **no `turn.ex` change**). The Driver's `:fail` clause re-raises an `APIError` reason (preserving `BaseAgent.run/2`'s `{config, response}`-or-raise contract); Inline already returns `{:error, reason, state}`; Server already replies `{:error, reason}`.
- **Structured-outputs fallback preserved.** `__structured_error_action__/1` is untouched: a structured-outputs `:invalid_request_error` (schema rejection) still falls back to the legacy parse-retry path and is never surfaced as `{:error, APIError}` to the caller. Only errors that today reach `handle_error` change shape.
- **Interpreter rule.** No new `Turn` effect is added, so the cross-cutting three-interpreter constraint is satisfied by construction; but the *handler-return* interpretation changes in Driver and Server (Inline's `call_llm` dep already returns `{:ok, _} | {:error, _}`). Both get explicit wiring + tests.

**Tech Stack:** Elixir, ExUnit, Poison, Req (OpenAI-compatible transport), Claudio (private git LLM client), `Normandy.Resilience.{Retry, CircuitBreaker}`.

**Reference:** `docs/superpowers/specs/2026-07-01-critical-fixes-design.md` — section "Fix 5" and the "Decisions" table ("Tuples inside, raise at the public edge").

**Verified baseline (2026-07-01, `main`):** `mix test` → `71 doctests, 26 properties, 1432 tests, 0 failures (128 excluded)`.

## Global Constraints

- **Public contract preserved:** `BaseAgent.run/2` keeps returning `{config, response}` or raising. All indirect callers (`DSL.Agent`, `DSL.Workflow`, A2A server, batch processor, coordination modules) rely on the raise contract and are audited in Task 9.
- **`__structured_error_action__/1` is a Chesterton's fence** — do not touch it. `:invalid_request_error` → `:fallback` (legacy path) must survive this plan; regression-tested in Task 3.
- **The `:on_parse_failure` policy shape is untouched.** New error branches pattern-match `{:error, %Normandy.LLM.APIError{}}` *precisely*, never bare `{:error, _}`, so the existing `:error`-policy return shape from `apply_parse_failure` keeps flowing exactly as it does today.
- **Streaming is out of scope.** `stream_converse` already returns `{:error, term}` and the streaming Driver handler throws `{:stream_turn_error, ...}`; neither changes. `completitions/6` is untouched.
- **Full suite green at every task checkpoint.** One *intentional* existing-test change: `test/agents/converse_result_test.exs`'s "any other shape is wrapped" test asserts `{{:error, :boom}, nil}`; Task 2 changes that assertion to pass-through (contract change from the approved spec). No other existing assertion may be weakened — if the full suite reveals a call site the audit missed, fix the call site, not the test.
- **Run `mix format` before every test run** (project CLAUDE.md). All tests must pass at plan completion, including ones we were not working on.
- **Git:** never `git add .` — add files individually. Use each task's commit message verbatim. No AI authorship attribution in commits (no "Generated with", no Co-Authored-By).
- **Strict TDD:** every task writes the failing test first, observes the failure (a compile error against a not-yet-existing module counts as the observed failing state), implements, observes the pass, then commits.

---

### Task 1: `Normandy.LLM.APIError` exception + provider mappings

**Files:**
- Create: `lib/normandy/llm/api_error.ex`
- Create: `test/llm/api_error_test.exs`

**Interfaces:**
- Produces: `Normandy.LLM.APIError` — `defexception` with fields `:type` (`:auth | :rate_limit | :overloaded | :invalid_request | :transport | :unknown`), `:status` (`integer | nil`), `:provider` (`atom`), `:message` (`String.t`), `:retryable?` (`boolean`).
- Constructors: `from_claudio/1` (maps `%Claudio.APIError{type, message, status_code, raw_body}` — the shape `claudio_adapter.ex` pattern-matches at line 1052 and `deps/claudio/lib/claudio/api_error.ex` defines — or any transport term), `from_status/3` (HTTP status → error, for OpenAI-compatible), `from_transport/2`.
- Consumes: `Claudio.APIError` struct shape only (compile-time dep already present).

**Complete `Claudio.APIError` → `APIError` mapping (from_claudio/1):**

| Claudio `:type`          | `APIError.type`    | `retryable?`         |
|--------------------------|--------------------|----------------------|
| `:authentication_error`  | `:auth`            | `false`              |
| `:permission_error`      | `:auth`            | `false`              |
| `:invalid_request_error` | `:invalid_request` | `false`              |
| `:not_found_error`       | `:invalid_request` | `false`              |
| `:rate_limit_error`      | `:rate_limit`      | `true`               |
| `:overloaded_error`      | `:overloaded`      | `true`               |
| `:api_error`             | `:unknown`         | `status in 500..599` |
| any string / other       | `:unknown`         | `status in 500..599` |
| non-`Claudio.APIError` term | `:transport`    | `true`               |

**HTTP status mapping (from_status/3, OpenAI-compatible):**

| Status        | `type`             | `retryable?` |
|---------------|--------------------|--------------|
| 401, 403      | `:auth`            | `false`      |
| 429           | `:rate_limit`      | `true`       |
| 503, 529      | `:overloaded`      | `true`       |
| other 4xx     | `:invalid_request` | `false`      |
| other 5xx     | `:unknown`         | `true`       |
| anything else | `:unknown`         | `false`      |

- [ ] **Step 1: Write the failing test**

Create `test/llm/api_error_test.exs`:

```elixir
defmodule Normandy.LLM.APIErrorTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.APIError

  describe "from_claudio/1 — Claudio.APIError type mapping" do
    test "authentication_error -> :auth, not retryable" do
      err = %Claudio.APIError{type: :authentication_error, message: "bad key", status_code: 401}

      assert %APIError{
               type: :auth,
               status: 401,
               provider: :anthropic,
               message: "bad key",
               retryable?: false
             } = APIError.from_claudio(err)
    end

    test "permission_error -> :auth, not retryable" do
      err = %Claudio.APIError{type: :permission_error, message: "forbidden", status_code: 403}
      assert %APIError{type: :auth, status: 403, retryable?: false} = APIError.from_claudio(err)
    end

    test "invalid_request_error and not_found_error -> :invalid_request, not retryable" do
      for {type, status} <- [{:invalid_request_error, 400}, {:not_found_error, 404}] do
        err = %Claudio.APIError{type: type, message: "nope", status_code: status}

        assert %APIError{type: :invalid_request, status: ^status, retryable?: false} =
                 APIError.from_claudio(err)
      end
    end

    test "rate_limit_error -> :rate_limit, retryable" do
      err = %Claudio.APIError{type: :rate_limit_error, message: "slow down", status_code: 429}
      assert %APIError{type: :rate_limit, status: 429, retryable?: true} = APIError.from_claudio(err)
    end

    test "overloaded_error -> :overloaded, retryable" do
      err = %Claudio.APIError{type: :overloaded_error, message: "busy", status_code: 529}
      assert %APIError{type: :overloaded, status: 529, retryable?: true} = APIError.from_claudio(err)
    end

    test "api_error with a 5xx status -> :unknown, retryable" do
      err = %Claudio.APIError{type: :api_error, message: "internal", status_code: 500}
      assert %APIError{type: :unknown, status: 500, retryable?: true} = APIError.from_claudio(err)
    end

    test "unrecognized string type with a 4xx status -> :unknown, not retryable" do
      err = %Claudio.APIError{type: "weird_error", message: "?", status_code: 418}
      assert %APIError{type: :unknown, status: 418, retryable?: false} = APIError.from_claudio(err)
    end

    test "a non-Claudio.APIError term is a transport error, retryable" do
      assert %APIError{type: :transport, status: nil, provider: :anthropic, retryable?: true} =
               APIError.from_claudio(%RuntimeError{message: "socket closed"})

      assert %APIError{type: :transport, message: ":timeout", retryable?: true} =
               APIError.from_claudio(:timeout)
    end
  end

  describe "from_status/3 — OpenAI-compatible HTTP status mapping" do
    test "401 and 403 -> :auth, not retryable" do
      for status <- [401, 403] do
        assert %APIError{type: :auth, status: ^status, provider: :openai_compatible, retryable?: false} =
                 APIError.from_status(:openai_compatible, status, "denied")
      end
    end

    test "429 -> :rate_limit, retryable" do
      assert %APIError{type: :rate_limit, status: 429, retryable?: true} =
               APIError.from_status(:openai_compatible, 429, "rate limited")
    end

    test "503 and 529 -> :overloaded, retryable" do
      for status <- [503, 529] do
        assert %APIError{type: :overloaded, status: ^status, retryable?: true} =
                 APIError.from_status(:openai_compatible, status, "busy")
      end
    end

    test "other 4xx -> :invalid_request, not retryable" do
      assert %APIError{type: :invalid_request, status: 422, retryable?: false} =
               APIError.from_status(:openai_compatible, 422, "unprocessable")
    end

    test "other 5xx -> :unknown, retryable" do
      assert %APIError{type: :unknown, status: 500, retryable?: true} =
               APIError.from_status(:openai_compatible, 500, "boom")
    end
  end

  describe "from_transport/2" do
    test "wraps an exception with its message" do
      assert %APIError{
               type: :transport,
               status: nil,
               provider: :openai_compatible,
               message: "connection refused",
               retryable?: true
             } = APIError.from_transport(:openai_compatible, %RuntimeError{message: "connection refused"})
    end

    test "inspects a non-exception term" do
      assert %APIError{type: :transport, message: ":nxdomain"} =
               APIError.from_transport(:openai_compatible, :nxdomain)
    end
  end

  describe "Exception behaviour" do
    test "message/1 includes provider, type, and status" do
      err = %APIError{type: :rate_limit, status: 429, provider: :anthropic, message: "slow down", retryable?: true}
      assert Exception.message(err) == "[anthropic] rate_limit (HTTP 429): slow down"
    end

    test "message/1 omits the status segment when status is nil" do
      err = %APIError{type: :transport, status: nil, provider: :anthropic, message: "timeout", retryable?: true}
      assert Exception.message(err) == "[anthropic] transport: timeout"
    end

    test "is raisable" do
      err = %APIError{type: :auth, status: 401, provider: :anthropic, message: "bad key", retryable?: false}
      raised = assert_raise APIError, fn -> raise err end
      assert raised.type == :auth
    end
  end
end
```

- [ ] **Step 2: Run it, watch it fail**

```
mix format && mix test test/llm/api_error_test.exs
```

Expected: **compilation error** — `Normandy.LLM.APIError.__struct__/1 is undefined` (module does not exist yet). `VERIFY: Ran test/llm/api_error_test.exs — Result: FAIL (compile error)`.

- [ ] **Step 3: Implement**

Create `lib/normandy/llm/api_error.ex`:

```elixir
defmodule Normandy.LLM.APIError do
  @moduledoc """
  Canonical LLM provider error for `Normandy.Agents.Model.converse/7`.

  Adapters map provider-specific failures — HTTP error responses and
  transport-level failures — into this exception and return
  `{:error, %Normandy.LLM.APIError{}}` from `converse/7`. Inside the framework
  the error travels as a tuple ("tuples inside"); the public edge raises it
  ("raise at edge"): `BaseAgent.run/2` via the Turn Driver's `:fail` clause,
  `BaseAgent.get_response/2` directly. `Turn.Inline` returns
  `{:error, reason, state}` and `Turn.Server` replies `{:error, reason}`.

  `retryable?` drives the resilience layer: `BaseAgent`'s default `retry_if`
  retries only `retryable?: true` errors (rate limit, overloaded, transport,
  and 5xx-backed unknowns) and never retries `:auth` / `:invalid_request`.
  """

  @type error_type ::
          :auth | :rate_limit | :overloaded | :invalid_request | :transport | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          status: integer() | nil,
          provider: atom(),
          message: String.t(),
          retryable?: boolean()
        }

  defexception type: :unknown,
               status: nil,
               provider: :unknown,
               message: "LLM API error",
               retryable?: false

  @impl true
  def message(%__MODULE__{type: type, status: nil, provider: provider, message: msg}) do
    "[#{provider}] #{type}: #{msg}"
  end

  def message(%__MODULE__{type: type, status: status, provider: provider, message: msg}) do
    "[#{provider}] #{type} (HTTP #{status}): #{msg}"
  end

  @doc """
  Maps a `Claudio.Messages.create/2` error term to `t()`.

  `Claudio.Messages.create/2` returns `{:error, %Claudio.APIError{}}` for HTTP
  error responses and `{:error, transport_term}` (e.g. a `Mint`/`Req`
  exception) for transport failures; this constructor accepts either.

  Type mapping:

  | Claudio `:type`          | type               | retryable?           |
  |--------------------------|--------------------|----------------------|
  | `:authentication_error`  | `:auth`            | false                |
  | `:permission_error`      | `:auth`            | false                |
  | `:invalid_request_error` | `:invalid_request` | false                |
  | `:not_found_error`       | `:invalid_request` | false                |
  | `:rate_limit_error`      | `:rate_limit`      | true                 |
  | `:overloaded_error`      | `:overloaded`      | true                 |
  | `:api_error`             | `:unknown`         | `status in 500..599` |
  | any string / other       | `:unknown`         | `status in 500..599` |
  | non-`Claudio.APIError`   | `:transport`       | true                 |
  """
  @spec from_claudio(term()) :: t()
  def from_claudio(%Claudio.APIError{type: type, message: msg, status_code: status}) do
    {mapped, retryable} = map_claudio_type(type, status)

    %__MODULE__{
      type: mapped,
      status: status,
      provider: :anthropic,
      message: msg || "Unknown error",
      retryable?: retryable
    }
  end

  def from_claudio(other), do: from_transport(:anthropic, other)

  @doc """
  Maps an HTTP status from an OpenAI-compatible Chat Completions endpoint.

  | Status        | type               | retryable? |
  |---------------|--------------------|------------|
  | 401, 403      | `:auth`            | false      |
  | 429           | `:rate_limit`      | true       |
  | 503, 529      | `:overloaded`      | true       |
  | other 4xx     | `:invalid_request` | false      |
  | other 5xx     | `:unknown`         | true       |
  | anything else | `:unknown`         | false      |
  """
  @spec from_status(atom(), integer(), String.t()) :: t()
  def from_status(provider, status, message) when is_integer(status) do
    {type, retryable} = map_status(status)

    %__MODULE__{
      type: type,
      status: status,
      provider: provider,
      message: message,
      retryable?: retryable
    }
  end

  @doc """
  Wraps a transport-level failure (a `Req`/`Mint`/`Finch` exception or any
  non-HTTP error term). Always `type: :transport, retryable?: true`.
  """
  @spec from_transport(atom(), term()) :: t()
  def from_transport(provider, error) do
    %__MODULE__{
      type: :transport,
      status: nil,
      provider: provider,
      message: transport_message(error),
      retryable?: true
    }
  end

  defp map_claudio_type(:authentication_error, _status), do: {:auth, false}
  defp map_claudio_type(:permission_error, _status), do: {:auth, false}
  defp map_claudio_type(:invalid_request_error, _status), do: {:invalid_request, false}
  defp map_claudio_type(:not_found_error, _status), do: {:invalid_request, false}
  defp map_claudio_type(:rate_limit_error, _status), do: {:rate_limit, true}
  defp map_claudio_type(:overloaded_error, _status), do: {:overloaded, true}

  defp map_claudio_type(_other, status),
    do: {:unknown, is_integer(status) and status in 500..599}

  defp map_status(status) when status in [401, 403], do: {:auth, false}
  defp map_status(429), do: {:rate_limit, true}
  defp map_status(status) when status in [503, 529], do: {:overloaded, true}
  defp map_status(status) when status in 400..499, do: {:invalid_request, false}
  defp map_status(status) when status in 500..599, do: {:unknown, true}
  defp map_status(_status), do: {:unknown, false}

  defp transport_message(error) when is_exception(error), do: Exception.message(error)
  defp transport_message(error), do: inspect(error)
end
```

- [ ] **Step 4: Run it, watch it pass**

```
mix format && mix test test/llm/api_error_test.exs
```

Expected: `17 tests, 0 failures`. `VERIFY: Ran test/llm/api_error_test.exs — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/llm/api_error.ex test/llm/api_error_test.exs
git commit -m "feat(llm): add Normandy.LLM.APIError canonical provider error"
```

---

### Task 2: Contract — `Model.converse` doc/spec + `ConverseResult.normalize/1` pass-through

**Files:**
- Modify: `lib/normandy/agents/model.ex` (protocol `@spec` + `@doc` on `converse/7`)
- Modify: `lib/normandy/agents/converse_result.ex`
- Modify: `test/agents/converse_result_test.exs`

**Interfaces:**
- Produces: `Model.converse` documented contract `struct() | {struct(), map() | nil} | {:error, Normandy.LLM.APIError.t()}`; `ConverseResult.normalize/1 :: {term(), map() | nil} | {:error, term()}` where `{:error, _}` passes through unchanged.
- Consumes: `Normandy.LLM.APIError` (Task 1).
- **Intentional test change:** the existing assertion `assert {{:error, :boom}, nil} = ConverseResult.normalize({:error, :boom})` encodes the pre-fix wrap-anything behavior and is replaced by the pass-through assertion (approved spec: "ConverseResult.normalize/1 passes `{:error, _}` through unchanged").

- [ ] **Step 1: Write the failing test**

In `test/agents/converse_result_test.exs`, replace the test `"any other shape is wrapped with nil usage"` with:

```elixir
  test "{:error, reason} passes through unchanged (Fix 5 contract)" do
    err = %Normandy.LLM.APIError{
      type: :rate_limit,
      status: 429,
      provider: :anthropic,
      message: "slow down",
      retryable?: true
    }

    assert {:error, ^err} = ConverseResult.normalize({:error, err})
    assert {:error, :boom} = ConverseResult.normalize({:error, :boom})
  end

  test "any other shape is wrapped with nil usage" do
    assert {nil, nil} = ConverseResult.normalize(nil)
    assert {%{a: 1}, nil} = ConverseResult.normalize(%{a: 1})
  end
```

- [ ] **Step 2: Run it, watch it fail**

```
mix format && mix test test/agents/converse_result_test.exs
```

Expected: `6 tests, 1 failure` — the pass-through test fails with `MatchError`-style assertion (`{{:error, %APIError{...}}, nil}` ≠ `{:error, %APIError{...}}`). `VERIFY: Ran test/agents/converse_result_test.exs — Result: FAIL (1 failure)`.

- [ ] **Step 3: Implement**

In `lib/normandy/agents/converse_result.ex`, replace the module body:

```elixir
defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the dual-shaped `Normandy.Agents.Model.converse/7` return —
  `struct()` or `{struct(), usage}` (and, in raw mode, `binary()` /
  `{binary(), usage}`) — into a single `{response, usage}` tuple, so callers
  stop assuming one shape. The protocol contract is intentionally left
  dual-shaped for backward compatibility; this is the single place consumers
  normalize it.

  An `{:error, reason}` return (the Fix 5 error contract:
  `{:error, %Normandy.LLM.APIError{}}`) passes through **unchanged** — it is
  a failed call, not a response to normalize. Callers must pattern-match the
  error tuple before destructuring `{response, usage}`.
  """

  @spec normalize(term()) :: {term(), map() | nil} | {:error, term()}
  def normalize({:error, _reason} = error), do: error

  def normalize({response, usage}) when is_struct(response) or is_binary(response),
    do: {response, usage}

  def normalize(response) when is_struct(response) or is_binary(response),
    do: {response, nil}

  def normalize(other), do: {other, nil}
end
```

In `lib/normandy/agents/model.ex`, update the `converse/7` doc and spec (leave `completitions/6` alone):

```elixir
  @doc """
  Converse with the model, optionally providing tool schemas.

  ## Parameters
    - config: Model client configuration
    - model: Model identifier
    - temperature: Sampling temperature (0.0-1.0)
    - max_tokens: Maximum tokens to generate
    - messages: List of conversation messages
    - response_model: Expected response schema
    - opts: Optional keyword list with :tools key for tool schemas

  ## Returns

  One of:

    - `struct()` — a populated response model
    - `{struct(), usage}` — response plus a provider-specific token usage map,
      consumed internally for observability
    - `{:error, %Normandy.LLM.APIError{}}` — the provider call failed (HTTP
      error or transport failure). Errors travel as tuples inside the
      framework and are raised only at the public edge (`BaseAgent.run/2`,
      `BaseAgent.get_response/2`); `Turn.Inline`/`Turn.Server` surface them
      as `{:error, reason, state}` / `{:error, reason}`.

  Use `Normandy.Agents.ConverseResult.normalize/1` to flatten the success
  shapes; it passes `{:error, _}` through unchanged.
  """
  @spec converse(t(), String.t(), float(), integer(), list(), struct(), keyword()) ::
          struct() | {struct(), map() | nil} | {:error, Normandy.LLM.APIError.t()}
  def converse(config, model, temperature, max_tokens, messages, response_model, opts \\ [])
```

- [ ] **Step 4: Run it, watch it pass — then the files that consume normalize/1**

```
mix format && mix test test/agents/converse_result_test.exs test/llm/json_deserializer_retry_test.exs test/context/summarizer_test.exs
```

Expected: `0 failures` (existing normalize consumers only ever feed success shapes today). `VERIFY: Ran the three files — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/converse_result.ex lib/normandy/agents/model.ex test/agents/converse_result_test.exs
git commit -m "feat(agents): document {:error, APIError} converse contract; normalize/1 passes errors through"
```

---

### Task 3: ClaudioAdapter — `handle_error` returns `{:error, APIError}`, `Logger.error`, raw-path mapping

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex`
- Modify: `test/llm/claudio_adapter_test.exs`

**Interfaces:**
- Produces: `converse/7` returns `{:error, %Normandy.LLM.APIError{}}` on provider failure (legacy path, structured `:propagate` path, and — once Task 5 lands — a failed corrective call inside `deserialize_with_retry`). `__raw_completion__({:error, _})` returns `{:error, %APIError{}}` (single error currency for the deserializer loop).
- Preserves: `__structured_error_action__/1` unchanged — structured-outputs schema rejection (`:invalid_request_error`) still silently falls back to the legacy path; `apply_parse_failure`'s `:on_parse_failure` policy shapes unchanged.
- Consumes: `Normandy.LLM.APIError.from_claudio/1` (Task 1).
- Note: `handle_error/2` is a `defp` inside the `defimpl` and `Claudio.Messages.create/2` has no transport seam, so the converse-level error path is covered by (a) the mapping units here and in Task 1, and (b) the mock-client end-to-end tests in Tasks 6–8/10. State this honestly; do not fake a live-API test.

- [ ] **Step 1: Write the failing tests**

Append to `test/llm/claudio_adapter_test.exs` (the file already has `alias Normandy.LLM.ClaudioAdapter`):

```elixir
  describe "__raw_completion__/1 error mapping (Fix 5)" do
    test "maps a Claudio.APIError to {:error, %Normandy.LLM.APIError{}}" do
      claudio_err = %Claudio.APIError{
        type: :rate_limit_error,
        message: "slow down",
        status_code: 429
      }

      assert {:error,
              %Normandy.LLM.APIError{
                type: :rate_limit,
                status: 429,
                provider: :anthropic,
                message: "slow down",
                retryable?: true
              }} = ClaudioAdapter.__raw_completion__({:error, claudio_err})
    end

    test "maps a transport term to {:error, %Normandy.LLM.APIError{type: :transport}}" do
      assert {:error, %Normandy.LLM.APIError{type: :transport, retryable?: true}} =
               ClaudioAdapter.__raw_completion__({:error, :timeout})
    end

    test "the success shape is unchanged" do
      response = %{content: [%{type: :text, text: "hi"}], usage: %{input_tokens: 1}}
      assert {"hi", %{input_tokens: 1}} = ClaudioAdapter.__raw_completion__({:ok, response})
    end
  end

  describe "structured-outputs fallback preservation (Fix 5 interaction)" do
    test ":invalid_request_error still routes to legacy fallback, not {:error, APIError}" do
      err = %Claudio.APIError{
        type: :invalid_request_error,
        message: "output_format is not supported",
        status_code: 400
      }

      # Chesterton's fence: schema rejection is recoverable via the legacy
      # parse-retry path (no output_format) and MUST NOT surface to the caller.
      assert :fallback = ClaudioAdapter.__structured_error_action__(err)
    end
  end
```

- [ ] **Step 2: Run them, watch the raw-mapping tests fail**

```
mix format && mix test test/llm/claudio_adapter_test.exs
```

Expected: the two `__raw_completion__` error-mapping tests fail (current code returns the *unmapped* Claudio error: `{:error, %Claudio.APIError{...}}` / `{:error, :timeout}`); the fallback-preservation test already passes. `VERIFY: Ran test/llm/claudio_adapter_test.exs — Result: FAIL (2 failures)`.

- [ ] **Step 3: Implement (four edits, one file)**

**(a)** In the `defimpl Normandy.Agents.Model do` block, add `require Logger` after the aliases:

```elixir
    alias Normandy.Components.Message
    alias Normandy.Components.ContentBlock.Document, as: DocumentBlock
    alias Normandy.Components.ContentBlock.Image, as: ImageBlock
    alias Normandy.Components.ContentBlock.Text, as: TextBlock

    require Logger
```

**(b)** Replace `handle_error/2` (currently `claudio_adapter.ex:982-987`):

```elixir
    defp handle_error(error, _response_model) do
      Logger.error("Claudio API error: #{inspect(error)}")
      {:error, Normandy.LLM.APIError.from_claudio(error)}
    end
```

**(c)** In `converse_structured/8`, the `:propagate` branch (currently `{handle_error(error, response_model), nil}` at ~line 251) becomes the bare error tuple:

```elixir
            :propagate ->
              handle_error(error, response_model)
```

(The `:fallback` branch — `do_converse_legacy(...)` — is untouched.)

**(d)** In `do_converse_legacy/7`, the success branch must let an `APIError` produced *inside* deserialization (a failed corrective call, live after Task 5) escape without being wrapped in the `{response, usage}` tuple. Replace the `{:ok, response}` branch body:

```elixir
        {:ok, response} ->
          # Pass context for JSON retry
          context = %{
            client: client,
            model: model,
            temperature: temperature,
            max_tokens: max_tokens,
            messages: messages,
            tools: tools
          }

          case convert_response_to_normandy(response, response_model, context) do
            {:error, %Normandy.LLM.APIError{}} = error ->
              # A corrective call inside the deserializer retry loop failed;
              # propagate the API error rather than wrapping it as a response.
              error

            normalized_response ->
              {normalized_response, Normandy.LLM.ClaudioAdapter.extract_usage(response)}
          end
```

and in `populate_standard_schema/3`, insert an `APIError`-precise clause ABOVE the existing `{:error, reason}` clause (which keeps routing to `apply_parse_failure` for parse failures — the `:on_parse_failure` policy is untouched):

```elixir
        {:ok, validated_schema} ->
          validated_schema

        {:error, %Normandy.LLM.APIError{} = api_error} ->
          # Fix 5: a failed corrective LLM call is not a parse failure — do not
          # fall back to raw text; propagate the error to the caller.
          {:error, api_error}

        {:error, reason} ->
          Normandy.LLM.ClaudioAdapter.apply_parse_failure(schema, content, reason, context)
```

**(e)** Replace `__raw_completion__({:error, error})` (currently `claudio_adapter.ex:1116`):

```elixir
  def __raw_completion__({:error, error}) do
    require Logger
    Logger.error("Claudio API error (raw completion): #{inspect(error)}")
    {:error, Normandy.LLM.APIError.from_claudio(error)}
  end
```

- [ ] **Step 4: Run it, watch it pass**

```
mix format && mix test test/llm/claudio_adapter_test.exs test/llm/claudio_structured_dep_test.exs test/llm/json_deserializer_retry_test.exs
```

Expected: `0 failures`. `VERIFY: Ran the three files — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/llm/claudio_adapter.ex test/llm/claudio_adapter_test.exs
git commit -m "feat(llm): ClaudioAdapter returns {:error, APIError} instead of empty response models"
```

---

### Task 4: OpenAICompatibleAdapter — error mapping

**Files:**
- Modify: `lib/normandy/llm/openai_compatible_adapter.ex`
- Modify: `test/llm/openai_compatible_adapter_test.exs`

**Interfaces:**
- Produces: non-2xx → `{:error, APIError.from_status(:openai_compatible, status, msg)}`; Req transport failure → `{:error, APIError.from_transport(:openai_compatible, error)}`; `IO.warn` → `Logger.error`. New pure helper `extract_error_message/1` (public for tests, mirrors `extract_text/1` style).
- Consumes: Task 1 constructors; Req's `:adapter` injection seam already used by the existing test.
- Note: pass `retry: false` in the stubbed clients' `req_options` so Req's own retry step cannot interfere with deterministic call counts.

- [ ] **Step 1: Write the failing tests**

Append to `test/llm/openai_compatible_adapter_test.exs`:

```elixir
  describe "converse/7 error mapping (stubbed transport, Fix 5)" do
    defp err_client(adapter_fn) do
      %Adapter{
        api_key: "test-key",
        base_url: "https://example.test/v1",
        options: %{req_options: [adapter: adapter_fn, retry: false]}
      }
    end

    defp converse_with(client) do
      schema = %Normandy.Agents.BaseAgentOutputSchema{}
      msgs = [%Message{role: "user", content: "hi"}]
      Normandy.Agents.Model.converse(client, "gpt-4o", 0.7, 64, msgs, schema, [])
    end

    test "HTTP 429 -> {:error, %APIError{type: :rate_limit, retryable?: true}}" do
      adapter_fn = fn request ->
        response = %Req.Response{
          status: 429,
          body: %{"error" => %{"message" => "rate limited"}}
        }

        {request, response}
      end

      assert {:error,
              %Normandy.LLM.APIError{
                type: :rate_limit,
                status: 429,
                provider: :openai_compatible,
                message: "rate limited",
                retryable?: true
              }} = converse_with(err_client(adapter_fn))
    end

    test "HTTP 401 -> {:error, %APIError{type: :auth, retryable?: false}}" do
      adapter_fn = fn request ->
        {request, %Req.Response{status: 401, body: %{"error" => %{"message" => "bad key"}}}}
      end

      assert {:error, %Normandy.LLM.APIError{type: :auth, status: 401, retryable?: false}} =
               converse_with(err_client(adapter_fn))
    end

    test "a transport exception -> {:error, %APIError{type: :transport, retryable?: true}}" do
      adapter_fn = fn request ->
        {request, %RuntimeError{message: "connection refused"}}
      end

      assert {:error,
              %Normandy.LLM.APIError{
                type: :transport,
                status: nil,
                provider: :openai_compatible,
                message: "connection refused",
                retryable?: true
              }} = converse_with(err_client(adapter_fn))
    end
  end

  describe "extract_error_message/1" do
    test "pulls the OpenAI error envelope message" do
      assert Adapter.extract_error_message(%{"error" => %{"message" => "boom"}}) == "boom"
    end

    test "falls back to inspect for unknown bodies" do
      assert Adapter.extract_error_message(%{"weird" => true}) == ~s(%{"weird" => true})
    end
  end
```

- [ ] **Step 2: Run them, watch them fail**

```
mix format && mix test test/llm/openai_compatible_adapter_test.exs
```

Expected: the three converse tests fail — current code returns `{%BaseAgentOutputSchema{}, nil}` (the empty-response defect this fix removes) — and the `extract_error_message/1` tests fail with `UndefinedFunctionError`. `VERIFY: Ran test/llm/openai_compatible_adapter_test.exs — Result: FAIL (5 failures)`.

- [ ] **Step 3: Implement**

In `lib/normandy/llm/openai_compatible_adapter.ex`:

**(a)** Add the pure helper to the outer module (next to `extract_text/1`):

```elixir
  @doc false
  def extract_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  def extract_error_message(body), do: inspect(body)
```

**(b)** In the `defimpl`, add `require Logger` after `alias Normandy.LLM.OpenAICompatibleAdapter, as: A`, and replace the two error branches (currently lines 111-117):

```elixir
        {:ok, %Req.Response{status: status, body: resp_body}} ->
          Logger.error("OpenAI-compatible API error #{status}: #{inspect(resp_body)}")

          {:error,
           Normandy.LLM.APIError.from_status(
             :openai_compatible,
             status,
             A.extract_error_message(resp_body)
           )}

        {:error, error} ->
          Logger.error("OpenAI-compatible transport error: #{inspect(error)}")
          {:error, Normandy.LLM.APIError.from_transport(:openai_compatible, error)}
```

- [ ] **Step 4: Run it, watch it pass**

```
mix format && mix test test/llm/openai_compatible_adapter_test.exs
```

Expected: `0 failures` (10 tests). `VERIFY: Ran test/llm/openai_compatible_adapter_test.exs — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/llm/openai_compatible_adapter.ex test/llm/openai_compatible_adapter_test.exs
git commit -m "feat(llm): OpenAICompatibleAdapter returns {:error, APIError} on HTTP/transport failure"
```

---

### Task 5: JsonDeserializer — a failed corrective call aborts the retry loop

**Files:**
- Modify: `lib/normandy/llm/json_deserializer.ex` (`retry_with_feedback/12`, ~lines 297-368; moduledoc "Retry raw-completion contract" section; `deserialize_with_retry/8` Returns doc)
- Modify: `test/llm/json_deserializer_retry_test.exs`

**Interfaces:**
- Produces: `deserialize_with_retry/8` gains the return `{:error, %Normandy.LLM.APIError{}}` — the corrective `raw: true` call failed; remaining retry budget is NOT consumed. All existing return shapes unchanged.
- Consumes: `{:error, %APIError{}}` from `Model.converse(..., raw: true)` (ClaudioAdapter maps it in `__raw_completion__`, Task 3).

- [ ] **Step 1: Write the failing test**

In `test/llm/json_deserializer_retry_test.exs`, add a mock client above the test module (same pattern as `Normandy.Test.RawRecoveryClient` in that file) and a test:

```elixir
defmodule Normandy.Test.ErroringRawClient do
  @moduledoc false
  defstruct pid: nil
end

defimpl Normandy.Agents.Model, for: Normandy.Test.ErroringRawClient do
  def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

  # Every corrective call fails at the provider; notifies the test pid so the
  # test can count invocations.
  def converse(client, _m, _t, _mt, _msgs, _response_model, _opts) do
    if client.pid, do: send(client.pid, :corrective_call)

    {:error,
     %Normandy.LLM.APIError{
       type: :overloaded,
       status: 529,
       provider: :anthropic,
       message: "Overloaded",
       retryable?: true
     }}
  end
end
```

and inside `Normandy.LLM.JsonDeserializerRetryTest`:

```elixir
  test "a failed corrective call aborts the retry loop and propagates the APIError" do
    assert {:error, %Normandy.LLM.APIError{type: :overloaded, status: 529}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               %Normandy.Test.ErroringRawClient{pid: self()},
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 2
             )

    # Exactly ONE corrective call was made: the loop aborted instead of
    # burning the remaining retry budget on a failing provider.
    assert_received :corrective_call
    refute_received :corrective_call
  end
```

- [ ] **Step 2: Run it, watch it fail**

```
mix format && mix test test/llm/json_deserializer_retry_test.exs
```

Expected: `3 tests, 1 failure` — today `ConverseResult.normalize({:error, ...})` passes the error tuple through, the `cond` falls to `true ->` and the loop returns `{:error, :llm_call_failed}` after the FIRST corrective call... **observe the actual failure output**: the return-shape assertion fails (`{:error, :llm_call_failed}` ≠ `{:error, %APIError{}}`). `VERIFY: Ran test/llm/json_deserializer_retry_test.exs — Result: FAIL (1 failure)`.

- [ ] **Step 3: Implement**

In `retry_with_feedback/12`, replace the converse call + `cond` (currently lines ~317-367) with:

```elixir
    # Call LLM again
    tools = Keyword.get(opts, :tools, [])
    llm_opts = [raw: true] ++ if(tools != [], do: [tools: tools], else: [])

    case Normandy.Agents.Model.converse(
           client,
           model,
           temperature,
           max_tokens,
           augmented_messages,
           schema,
           llm_opts
         ) do
      {:error, %Normandy.LLM.APIError{}} = error ->
        # Fix 5: a failed corrective call is not content to parse. Abort the
        # retry loop and propagate the API error to the adapter/caller.
        error

      raw ->
        {response, _usage} = ConverseResult.normalize(raw)

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
    end
```

Update the moduledoc "Retry raw-completion contract" section — append:

```
  A corrective call that returns `{:error, %Normandy.LLM.APIError{}}` (the
  provider call itself failed) ABORTS the retry loop immediately and the
  error propagates to the caller; it is not content to parse and the
  remaining retry budget is not consumed.
```

and add `- {:error, %Normandy.LLM.APIError{}}` — corrective LLM call failed — to `deserialize_with_retry/8`'s "## Returns" doc.

- [ ] **Step 4: Run it, watch it pass**

```
mix format && mix test test/llm/json_deserializer_retry_test.exs test/llm/json_deserializer_test.exs
```

Expected: `0 failures`. `VERIFY: Ran both files — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/llm/json_deserializer.ex test/llm/json_deserializer_retry_test.exs
git commit -m "feat(llm): abort JSON retry loop when the corrective call returns an APIError"
```

---

### Task 6: BaseAgent resilience core — tuple-aware `llm_call`, `retry_if`, `get_response` raises at the edge

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`call_llm_with_resilience/4` ~lines 292-352; `get_response/2` ~lines 166-170; `@spec` of `get_response_with_usage/2` ~line 219)
- Create: `test/agents/base_agent_llm_error_test.exs`

**Interfaces:**
- Produces: `call_llm_with_resilience/4` and `get_response_with_usage/2` return `{struct(), map() | nil} | {:error, Normandy.LLM.APIError.t()}`. The default `retry_if` retries `%APIError{retryable?: true}` (rate limit, overloaded, transport, 5xx-unknown) and does NOT retry `:auth`/`:invalid_request`; `{:error, :open}` stays non-retryable and keeps its existing `RuntimeError` raise. `get_response/2` (public) raises the `APIError` at the edge.
- **This is what makes the resilience layer real:** the adapters previously swallowed errors into empty response structs *before* `Retry.with_retry` / `CircuitBreaker.call` could observe a failure — the breaker only ever saw raised exceptions, never API errors. After this task, `{:error, %APIError{}}` flows through `llm_call` un-wrapped, so Retry counts it, the breaker records it, and non-retryable errors fail fast.
- Sequencing note: `call_turn_llm/3` (line ~571) still destructures `{r, usage}` until Task 7 — safe, because no existing test drives an error tuple through `BaseAgent.run` yet. Task 6 tests therefore exercise `BaseAgent.get_response/2` only; `run/2` tests come in Task 7.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/base_agent_llm_error_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentLLMErrorTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLM.APIError

  # Always fails with the APIError seeded in the struct; counts calls via an Agent pid.
  defmodule ErrClient do
    use Normandy.Schema

    schema do
      field(:error, :any)
      field(:counter, :any, default: nil)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

      def converse(client, _m, _t, _mt, _msgs, _response_model, _opts) do
        if client.counter, do: Agent.update(client.counter, &(&1 + 1))
        {:error, client.error}
      end
    end
  end

  # Fails `failures` times with the seeded APIError, then succeeds.
  defmodule FlakyClient do
    use Normandy.Schema

    schema do
      field(:error, :any)
      field(:failures, :integer, default: 1)
      field(:counter, :any)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

      def converse(client, _m, _t, _mt, _msgs, response_model, _opts) do
        n = Agent.get_and_update(client.counter, fn n -> {n, n + 1} end)

        if n < client.failures do
          {:error, client.error}
        else
          %{response_model | chat_message: "recovered"}
        end
      end
    end
  end

  defp rate_limit_error do
    %APIError{
      type: :rate_limit,
      status: 429,
      provider: :anthropic,
      message: "slow down",
      retryable?: true
    }
  end

  defp auth_error do
    %APIError{
      type: :auth,
      status: 401,
      provider: :anthropic,
      message: "bad key",
      retryable?: false
    }
  end

  describe "get_response/2 raises the APIError at the public edge" do
    test "a failed adapter call raises instead of returning an empty response model" do
      agent =
        BaseAgent.init(%{client: %ErrClient{error: auth_error()}, model: "m", temperature: 0.0})

      err = assert_raise APIError, fn -> BaseAgent.get_response(agent) end
      assert err.type == :auth
      assert err.status == 401
    end
  end

  describe "retry_if: the resilience layer now sees adapter errors" do
    test "retries a retryable APIError and succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      client = %FlakyClient{error: rate_limit_error(), failures: 1, counter: counter}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "m",
          temperature: 0.0,
          retry_options: [max_attempts: 3, base_delay: 1, jitter: false]
        })

      response = BaseAgent.get_response(agent)
      assert response.chat_message == "recovered"
      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "does NOT retry an auth error — exactly one adapter call, then raise" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      client = %ErrClient{error: auth_error(), counter: counter}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "m",
          temperature: 0.0,
          retry_options: [max_attempts: 5, base_delay: 1, jitter: false]
        })

      assert_raise APIError, fn -> BaseAgent.get_response(agent) end
      assert Agent.get(counter, & &1) == 1
      Agent.stop(counter)
    end

    test "a retryable error that never recovers exhausts attempts, then raises the APIError" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      client = %ErrClient{error: rate_limit_error(), counter: counter}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "m",
          temperature: 0.0,
          retry_options: [max_attempts: 2, base_delay: 1, jitter: false]
        })

      err = assert_raise APIError, fn -> BaseAgent.get_response(agent) end
      assert err.type == :rate_limit
      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end
  end
end
```

- [ ] **Step 2: Run it, watch it fail**

```
mix format && mix test test/agents/base_agent_llm_error_test.exs
```

Expected: 4 failures. Today `converse`'s `{:error, %APIError{}}` gets wrapped in `{:ok, ...}` by `llm_call`, flows through unwrap as a "success", `ConverseResult.normalize/1` (Task 2) passes it through, and `get_response`'s `{response, _usage}` destructure binds `response = :error` — the assert on `chat_message` / `assert_raise` fails. Record the *actual* failure shapes observed. `VERIFY: Ran test/agents/base_agent_llm_error_test.exs — Result: FAIL (4 failures)`.

- [ ] **Step 3: Implement (three edits in `base_agent.ex`)**

**(a)** `call_llm_with_resilience/4` — new `llm_call`, `retry_if`, unwrap, and `@spec`:

```elixir
  # Private helper to call LLM with retry and circuit breaker protection.
  # Fix 5: adapter failures arrive as {:error, %Normandy.LLM.APIError{}} and are
  # handed to Retry/CircuitBreaker UN-wrapped, so the resilience layer finally
  # sees them (previously adapters swallowed errors into empty response structs
  # before this wrapper could observe a failure). Retryable errors (rate limit,
  # overloaded, transport) retry; :auth/:invalid_request fail fast; the
  # breaker's {:error, :open} keeps its legacy raise.
  @spec call_llm_with_resilience(BaseAgentConfig.t(), list(), struct(), keyword()) ::
          {struct(), map() | nil} | {:error, Normandy.LLM.APIError.t()}
  defp call_llm_with_resilience(config, messages, response_model, opts) do
    llm_call = fn ->
      case Normandy.Agents.Model.converse(
             config.client,
             config.model,
             config.temperature,
             config.max_tokens,
             messages,
             response_model,
             opts
           ) do
        {:error, %Normandy.LLM.APIError{}} = error ->
          # Surface as a failure so Retry counts it and the breaker records it.
          error

        result ->
          # Wrap in {:ok, result} for retry/circuit breaker compatibility
          {:ok, result}
      end
    end

    # Apply retry first if configured, then circuit breaker wraps the whole thing
    retryable_call =
      if config.retry_options do
        fn ->
          # Add default retry_if for exceptions if not provided
          retry_opts =
            if !Keyword.has_key?(config.retry_options, :retry_if) do
              Keyword.put(config.retry_options, :retry_if, fn
                {:error, %Normandy.LLM.APIError{retryable?: retryable}} -> retryable
                {:error, {:exception, _, _}} -> true
                {:error, :open} -> false
                {:error, error} when is_atom(error) -> true
                _ -> false
              end)
            else
              config.retry_options
            end

          Normandy.Resilience.Retry.with_retry(llm_call, retry_opts)
        end
      else
        llm_call
      end

    # Apply circuit breaker if configured (wraps the retry logic)
    protected_call =
      if config.circuit_breaker do
        fn ->
          Normandy.Resilience.CircuitBreaker.call(config.circuit_breaker, retryable_call)
        end
      else
        retryable_call
      end

    # Execute and unwrap result. APIError tuples RETURN (tuples inside); all
    # other failures keep the legacy raise (exceptions from mocks, :open, …).
    case protected_call.() do
      {:ok, {:ok, response}} -> ConverseResult.normalize(response)
      {:ok, response} -> ConverseResult.normalize(response)
      {:error, {%Normandy.LLM.APIError{} = error, _attempts, _errors}} -> {:error, error}
      {:error, %Normandy.LLM.APIError{} = error} -> {:error, error}
      {:error, {reason, _attempts, _errors}} -> raise_llm_call_error(reason)
      {:error, reason} -> raise_llm_call_error(reason)
    end
  end
```

**(b)** `get_response_with_usage/2` `@spec` (implementation unchanged — the error tuple flows through from `call_llm_with_resilience`):

```elixir
  @spec get_response_with_usage(BaseAgentConfig.t(), struct() | nil) ::
          {struct(), map() | nil} | {:error, Normandy.LLM.APIError.t()}
```

**(c)** `get_response/2` — raise at the public edge. The error clause MUST come first: `{:error, %APIError{}}` also matches the `{response, _usage}` pattern (binding `response = :error`).

```elixir
  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(config = %BaseAgentConfig{}, response_model \\ nil) do
    case get_response_with_usage(config, response_model) do
      {:error, %Normandy.LLM.APIError{} = error} -> raise error
      {response, _usage} -> response
    end
  end
```

- [ ] **Step 4: Run it, watch it pass — plus the resilience suite (raising-mock behavior must be unchanged)**

```
mix format && mix test test/agents/base_agent_llm_error_test.exs test/agents/base_agent_resilience_test.exs test/agents/base_agent_test.exs
```

Expected: `0 failures` — in particular `base_agent_resilience_test.exs`'s `"LLM call failed: Service unavailable"` and `"LLM call failed: :open"` raises are byte-identical to before. `VERIFY: Ran the three files — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/base_agent.ex test/agents/base_agent_llm_error_test.exs
git commit -m "feat(agents): thread APIError tuples through resilience layer; get_response raises at edge"
```

---

### Task 7: Driver path — `call_turn_llm` emits `{:llm_error, _}`; Driver raises the APIError through `BaseAgent.run`

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`call_turn_llm/3` ~lines 566-594; stale comment block ~lines 476-485)
- Modify: `lib/normandy/agents/turn/driver.ex` (`{:call_llm, _}` clause ~lines 57-59; `{:fail, _}` clause ~lines 91-92; `Handlers` typedoc)
- Modify: `test/agents/base_agent_llm_error_test.exs`

**Interfaces:**
- Produces: the shared `call_llm` handler (`BaseAgent.call_turn_llm/3`, used by both Driver and Server via `non_streaming_handlers/0`) returns `{:llm_error, %APIError{}}` on `{:error, _}` from `get_response_with_usage`. The Driver feeds `{:llm_error, reason}` into the FSM (existing `turn.ex:237-240` clause → `:failed` → `{:fail, reason}` — **no turn.ex change**) and its `:fail` clause re-raises an `APIError` reason; any other reason keeps the legacy `RuntimeError`. `BaseAgent.run/2` contract preserved: `{config, response}` or raise — the raise now carries the `APIError`.
- Streaming unaffected: `call_stream_llm` throws `{:stream_turn_error, ...}` and never returns `{:llm_error, _}`, so the new Driver case is inert on that path.

- [ ] **Step 1: Write the failing tests**

Append to `test/agents/base_agent_llm_error_test.exs`:

```elixir
  describe "BaseAgent.run/2 — the Driver raises the APIError at the edge" do
    test "a no-tools run raises the adapter's APIError (not an empty response)" do
      agent =
        BaseAgent.init(%{
          client: %ErrClient{error: rate_limit_error()},
          model: "m",
          temperature: 0.0
        })

      err = assert_raise APIError, fn -> BaseAgent.run(agent, %{chat_message: "hi"}) end
      assert err.type == :rate_limit
      assert err.status == 429
    end
  end

  describe "Turn.Driver {:llm_error, _} wiring" do
    alias Normandy.Agents.Turn
    alias Normandy.Agents.Turn.Driver

    defp driver_handlers(call_llm) do
      %Driver.Handlers{
        call_llm: call_llm,
        dispatch_tools: fn _acc, _calls -> [] end,
        convert: fn _acc, raw, _schema -> raw end,
        validate: fn _acc, v -> v end,
        guard: fn _acc, _v -> :ok end,
        append: fn acc, _role, _content -> acc end,
        compact: fn acc, _state, _info -> {acc, %{}} end,
        emit: fn _acc, _name, _meta -> :ok end
      }
    end

    test "a handler returning {:llm_error, %APIError{}} raises that APIError" do
      handlers = driver_handlers(fn _acc, _state, _req -> {:llm_error, rate_limit_error()} end)
      state = Turn.new(max_iterations: 2, response_model: :rm)

      err = assert_raise APIError, fn -> Driver.drive(state, handlers, :acc) end
      assert err.type == :rate_limit
    end

    test "a non-APIError failure keeps the legacy RuntimeError" do
      handlers = driver_handlers(fn _acc, _state, _req -> {:llm_error, :boom} end)
      state = Turn.new(max_iterations: 2, response_model: :rm)

      assert_raise RuntimeError, ~r/Turn FSM reached :failed unexpectedly/, fn ->
        Driver.drive(state, handlers, :acc)
      end
    end
  end
```

- [ ] **Step 2: Run them, watch them fail**

```
mix format && mix test test/agents/base_agent_llm_error_test.exs
```

Expected: the run test fails with `BadMapError` (or similar) — `call_turn_llm` destructures `{r, usage} = {:error, %APIError{}}`, binds `r = :error`, then `Map.get(:error, :tool_calls)` blows up. The first Driver test fails because the driver wraps the handler return as `{:llm_response, {:llm_error, ...}}` (the FSM sees no tool_calls and finalizes with the tuple as the response — observe and record the actual failure). `VERIFY: Ran test/agents/base_agent_llm_error_test.exs — Result: FAIL (3 new failures)`.

- [ ] **Step 3: Implement**

**(a)** `lib/normandy/agents/turn/driver.ex` — `{:call_llm, _}` clause distinguishes error returns, and `{:fail, _}` re-raises an APIError:

```elixir
      {:call_llm, request} ->
        case handlers.call_llm.(acc, state, request) do
          {:llm_error, reason} ->
            advance(acc, state, {:llm_error, reason}, handlers)

          response ->
            advance(acc, state, {:llm_response, response}, handlers)
        end
```

```elixir
      {:fail, %Normandy.LLM.APIError{} = error} ->
        # Raise-at-edge: an adapter failure travelled the FSM as data and is
        # raised here, preserving BaseAgent.run/2's {config, response}-or-raise
        # contract with the APIError as the raised exception.
        raise error

      {:fail, reason} ->
        raise "Turn FSM reached :failed unexpectedly: #{inspect(reason)}"
```

Update the `Handlers` struct typedoc for `call_llm`:

```elixir
            call_llm: (acc(), Turn.State.t(), map() -> term() | {:llm_error, term()}),
```

**(b)** `lib/normandy/agents/base_agent.ex` — `call_turn_llm/3` cases on the resilience-layer result. Error clause FIRST (`{:error, e}` also matches `{r, usage}`):

```elixir
  defp call_turn_llm(config, state, %{response_model: response_model}) do
    iteration = config.max_tool_iterations - state.iterations_left + 1
    llm_metadata = %{model: config.model, iteration: iteration, agent_name: config.name}

    with_llm_call_span(config, llm_metadata, fn ->
      case get_response_with_usage(config, response_model) do
        {:error, %Normandy.LLM.APIError{} = error} ->
          # Tuples inside: hand the failure to the FSM as {:llm_error, _}.
          # The Driver raises it at the public edge; Inline/Server return it.
          meta =
            Map.merge(llm_metadata, %{has_tool_calls: false, tool_call_count: 0, usage: nil})

          {{:llm_error, error}, meta}

        {r, usage} ->
          # When this agent has no tools, strip any tool_calls the LLM may have
          # returned (e.g. a misbehaving or generic mock). Old run_without_tools
          # never inspected tool_calls on the response, so the FSM must not see
          # them either — this preserves the no-tools parity contract.
          r =
            case {has_tools?(config), r} do
              {false, %{tool_calls: [_ | _]}} -> Map.put(r, :tool_calls, [])
              _ -> r
            end

          tool_calls = Map.get(r, :tool_calls) || []

          meta =
            Map.merge(llm_metadata, %{
              has_tool_calls: tool_calls != [],
              tool_call_count: length(tool_calls),
              usage: usage
            })

          {r, meta}
      end
    end)
  end
```

**(c)** Update the stale interpreter comment (`base_agent.ex` ~lines 481-485). Replace:

```
  # are admission control performed before :start (they raise on failure, as the
  # pre-FSM loop did). LLM failures raise inside the :call_llm handler (parity:
  # exceptions propagate out of run/2), so the FSM's :failed path is only reached
  # on an unexpected event-sequencing bug.
```

with:

```
  # are admission control performed before :start (they raise on failure, as the
  # pre-FSM loop did). Adapter failures ({:error, %APIError{}}) travel the FSM as
  # {:llm_error, _} events and the Driver raises the APIError at the public edge
  # via its {:fail, _} clause; non-APIError exceptions still propagate out of
  # run/2 directly, and any other :failed reason is an event-sequencing bug.
```

- [ ] **Step 4: Run it, watch it pass — plus the Driver/turn suites**

```
mix format && mix test test/agents/base_agent_llm_error_test.exs test/agents/turn_driver_test.exs test/agents/base_agent_turn_driver_test.exs test/agents/turn_test.exs test/agents/base_agent_tool_loop_test.exs test/agents/base_agent_streaming_test.exs
```

Expected: `0 failures`. `VERIFY: Ran the six files — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/turn/driver.ex lib/normandy/agents/base_agent.ex test/agents/base_agent_llm_error_test.exs
git commit -m "feat(agents): Turn driver feeds {:llm_error, _} to the FSM and raises APIError at the edge"
```

---

### Task 8: Server wiring + Inline verification

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`{:call_llm, _}` effect ~lines 310-313)
- Modify: `test/agents/turn/server_test.exs`
- Modify: `test/agents/turn_inline_test.exs` (verification tests only — **no `inline.ex` code change**: its `call_llm` dep contract is already `{:ok, _} | {:error, _}` → `{:llm_error, _}` event → `{:fail, _}` → `{:error, reason, state}`)

**Interfaces:**
- Produces: Server's spawned LLM task distinguishes `{:llm_error, reason}` from a normal response before tagging the event; a failed turn replies `{:error, %APIError{}}` to the `run/2` caller and persists a terminal `:failed` turn state (existing `{:fail, _}` interpreter clause — unchanged).
- Memory rule satisfied: no new `Turn` effect was introduced, but the *handler-return* convention changed, and all three interpreters are now explicitly wired/tested — Driver (Task 7), Server (this task), Inline (native, verified here).

- [ ] **Step 1: Write the failing Server test + the Inline verification tests**

Append to `test/agents/turn/server_test.exs` (uses the file's existing `base_config/0` and `Resp`):

```elixir
  test "an LLM error fails the turn, replies {:error, %APIError{}}, and persists :failed" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    api_error = %Normandy.LLM.APIError{
      type: :rate_limit,
      status: 429,
      provider: :anthropic,
      message: "slow down",
      retryable?: true
    }

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> {:llm_error, api_error} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-llm-err",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: nil
      )

    assert {:error, ^api_error} = Turn.Server.run(srv, "hello")

    # Terminal :failed state persisted — the resume reaper must never see a
    # mid-turn status for this session.
    assert {:ok, %Turn.State{status: :failed, error: ^api_error}} =
             InMemory.load_turn_state(store, "s-llm-err")
  end

  test "end-to-end: default handlers + an erroring client reply {:error, %APIError{}}" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    api_error = %Normandy.LLM.APIError{
      type: :overloaded,
      status: 529,
      provider: :anthropic,
      message: "Overloaded",
      retryable?: true
    }

    config = %{base_config() | client: %ServerErrClient{error: api_error}}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-llm-err-e2e",
        config: config,
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        subscriber: nil
      )

    assert {:error, %Normandy.LLM.APIError{type: :overloaded}} = Turn.Server.run(srv, "hello")
  end
```

and add the erroring client module near the top of `server_test.exs` (beside `FakeTool`; protocol consolidation is off in test env, so a per-file `defimpl` works):

```elixir
  # Client whose converse always fails with the seeded APIError — drives the
  # default non_streaming_handlers -> call_turn_llm -> {:llm_error, _} path.
  defmodule ServerErrClient do
    use Normandy.Schema

    schema do
      field(:error, :any)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model
      def converse(client, _m, _t, _mt, _msgs, _rm, _opts), do: {:error, client.error}
    end
  end
```

Append to `test/agents/turn_inline_test.exs`:

```elixir
  describe "run/2 when the LLM call fails (Fix 5)" do
    test "returns {:error, %APIError{}, state} with status :failed" do
      api_error = %Normandy.LLM.APIError{
        type: :overloaded,
        status: 529,
        provider: :anthropic,
        message: "Overloaded",
        retryable?: true
      }

      deps = %{
        call_llm: fn _req -> {:error, api_error} end,
        dispatch: fn _calls -> flunk("dispatch must not run after an LLM error") end
      }

      state = Turn.new(max_iterations: 5, response_model: :rm)

      assert {:error, ^api_error, final} = Inline.run(state, deps)
      assert final.status == :failed
      assert final.error == api_error
    end
  end
```

- [ ] **Step 2: Run them, watch the Server tests fail (Inline passes — it already models this natively)**

```
mix format && mix test test/agents/turn/server_test.exs test/agents/turn_inline_test.exs
```

Expected: the two new Server tests FAIL — the server's task wraps the handler return as `{:llm_response, {:llm_error, ...}}`, the FSM treats the tuple as a response and finalizes, so `run/2` replies `{:ok, ...}` instead of `{:error, ...}`. The Inline test PASSES with no code change (record this: it verifies the existing path per the spec). `VERIFY: Ran both files — Result: FAIL (2 failures, both in server_test.exs)`.

- [ ] **Step 3: Implement**

In `lib/normandy/agents/turn/server.ex`, replace the `{:call_llm, request}` effect clause:

```elixir
      {:call_llm, request} ->
        spawn_task(data, fn h, d ->
          # Fix 5: the shared call_llm handler returns {:llm_error, %APIError{}}
          # on adapter failure; feed it to the core as the matching event
          # instead of wrapping it as an {:llm_response, _}.
          case h.call_llm.(d.config, d.turn_state, request) do
            {:llm_error, _reason} = event -> event
            response -> {:llm_response, response}
          end
        end)
```

- [ ] **Step 4: Run it, watch it pass — plus the server integration suites**

```
mix format && mix test test/agents/turn/server_test.exs test/agents/turn_inline_test.exs test/agents/turn/server_integration_test.exs
```

Expected: `0 failures`. `VERIFY: Ran the three files — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs test/agents/turn_inline_test.exs
git commit -m "feat(agents): Turn.Server surfaces {:llm_error, _} as {:error, APIError} replies; verify Inline path"
```

---

### Task 9: Call-site audit — Summarizer update + verified-no-change list

**Files:**
- Modify: `lib/normandy/context/summarizer.ex` (`call_llm_for_summary/5`, lines 189-213)
- Modify: `test/context/summarizer_test.exs`

**Audit results (every `Model.converse` / `BaseAgent.run` consumer in `lib/`, verified 2026-07-01):**

| Site | Verdict |
|---|---|
| `lib/normandy/context/summarizer.ex:189-213` (`call_llm_for_summary/5`) — direct `Model.converse` + `normalize` destructure | **UPDATE (this task)** — `{response, _usage} = normalize(...)` would bind `response = :error` on an error tuple |
| `lib/normandy/llm/json_deserializer.ex:321-332` — direct `Model.converse` (raw) | UPDATED in Task 5 |
| `lib/normandy/agents/base_agent.ex:292-352` — direct `Model.converse` | UPDATED in Task 6 |
| `lib/normandy/context/window_manager.ex:303` — calls `Summarizer.compress_conversation` | No change: already returns `{:ok, agent} \| {:error, term}`; the `APIError` rides the existing error tuple |
| `lib/normandy/batch/processor.ex:225-238` (`process_single`) — `BaseAgent.run` in `try/rescue e ->` + `catch` | No change: raised `APIError` becomes `{:error, {:exception, %APIError{}, stack}}` per item |
| `lib/normandy/coordination/reactive.ex:323-334` — `BaseAgent.run` in `rescue e ->` | No change (same conversion) |
| `lib/normandy/coordination/hierarchical_coordinator.ex:205-216, 307-319` — `BaseAgent.run` in `rescue e ->` | No change |
| `lib/normandy/coordination/parallel_orchestrator.ex:275-289` — `BaseAgent.run` in `rescue e ->` | No change |
| `lib/normandy/coordination/sequential_orchestrator.ex:228-242` — `BaseAgent.run` in `rescue e ->` | No change |
| `lib/normandy/coordination/agent_process.ex:371-397, 607-617` — `BaseAgent.run` in `rescue e ->` | No change |
| `lib/normandy/coordination/pattern.ex:426-430` (`try_wrap/1`) — `rescue e -> {:error, e}` | No change |
| `lib/normandy/dsl/agent.ex:383, 387, 398`; `lib/normandy/dsl/workflow.ex:416`; `lib/normandy/a2a/server.ex:103` — pass-through `BaseAgent.run` callers | No change: `run/2`'s raise contract is preserved; a raised `APIError` propagates exactly like today's `RuntimeError`s |

- [ ] **Step 1: Write the failing test**

Append to `test/context/summarizer_test.exs` (a per-file mock client, matching the file's existing style):

```elixir
  defmodule ErroringSummarizerClient do
    use Normandy.Schema

    schema do
      field(:noop, :any, default: nil)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

      def converse(_c, _m, _t, _mt, _msgs, _rm, _opts) do
        {:error,
         %Normandy.LLM.APIError{
           type: :overloaded,
           status: 529,
           provider: :anthropic,
           message: "Overloaded",
           retryable?: true
         }}
      end
    end
  end

  describe "adapter error propagation (Fix 5)" do
    test "summarize_messages returns {:error, %APIError{}} instead of a bogus summary" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      assert {:error, %Normandy.LLM.APIError{type: :overloaded, status: 529}} =
               Normandy.Context.Summarizer.summarize_messages(
                 %ErroringSummarizerClient{},
                 %{model: "test-model"},
                 messages
               )
    end
  end
```

- [ ] **Step 2: Run it, watch it fail**

```
mix format && mix test test/context/summarizer_test.exs
```

Expected: 1 new failure — today `{response, _usage} = ConverseResult.normalize({:error, ...})` binds `response = :error`, and the function returns `{:error, {:unexpected_response, :error}}` (or crashes) instead of `{:error, %APIError{}}`. Record the actual shape observed. `VERIFY: Ran test/context/summarizer_test.exs — Result: FAIL (1 failure)`.

- [ ] **Step 3: Implement**

Replace `call_llm_for_summary/5` in `lib/normandy/context/summarizer.ex`:

```elixir
  defp call_llm_for_summary(client, model, temperature, max_tokens, messages) do
    # Create a proper struct response model for text output
    response_model = %Normandy.Agents.BaseAgentOutputSchema{chat_message: ""}

    case Normandy.Agents.Model.converse(
           client,
           model,
           temperature,
           max_tokens,
           messages,
           response_model,
           []
         ) do
      {:error, %Normandy.LLM.APIError{} = error} ->
        # Fix 5: a failed provider call is an error, not a summary.
        {:error, error}

      raw ->
        {response, _usage} = Normandy.Agents.ConverseResult.normalize(raw)

        case response do
          %{chat_message: summary} when is_binary(summary) ->
            {:ok, summary}

          other ->
            {:error, {:unexpected_response, other}}
        end
    end
  end
```

- [ ] **Step 4: Run it, watch it pass — plus the compactor (Summarizer's other consumer)**

```
mix format && mix test test/context/summarizer_test.exs test/behaviours/compactor_test.exs test/context/
```

Expected: `0 failures`. `VERIFY: Ran summarizer/compactor/context suites — Result: PASS`.

- [ ] **Step 5: Commit**

```
git add lib/normandy/context/summarizer.ex test/context/summarizer_test.exs
git commit -m "fix(context): summarizer propagates adapter APIError instead of misreading it as a response"
```

---

### Task 10: Integration — the circuit breaker opens on adapter error tuples

**Files:**
- Modify: `test/agents/base_agent_llm_error_test.exs` (test-only task; reuses `ErrClient` from Task 6)

**Interfaces:**
- Verifies the spec's headline claim end-to-end: adapters returning `{:error, %APIError{}}` (never raising) are counted as failures by `CircuitBreaker.call/2`'s `execute_and_record` (`{:error, _} → record_failure`), the breaker opens after `failure_threshold` consecutive failures, and an open breaker fails fast with the unchanged legacy `RuntimeError` raise (`"LLM call failed: :open"`) without invoking the adapter.

- [ ] **Step 1: Write the failing-only-if-broken test (it should pass immediately if Tasks 6-7 are correct — run it to verify, and if it fails, STOP and debug the implementation, not the test)**

Append to `test/agents/base_agent_llm_error_test.exs`:

```elixir
  describe "circuit breaker integration (Fix 5: the breaker finally sees adapter errors)" do
    test "opens after N consecutive {:error, %APIError{}} returns, then fails fast" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      overloaded = %APIError{
        type: :overloaded,
        status: 529,
        provider: :anthropic,
        message: "Overloaded",
        retryable?: true
      }

      client = %ErrClient{error: overloaded, counter: counter}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7,
          enable_circuit_breaker: true,
          circuit_breaker_options: [failure_threshold: 2, timeout: 60_000]
        })

      # Two failing turns: each raises the APIError at the public edge...
      assert_raise APIError, fn -> BaseAgent.run(agent, %{chat_message: "t1"}) end
      assert_raise APIError, fn -> BaseAgent.run(agent, %{chat_message: "t2"}) end

      # ...and the breaker counted both tuple-shaped failures and opened.
      assert Normandy.Resilience.CircuitBreaker.state(agent.circuit_breaker) == :open

      # Open breaker fails fast with the unchanged legacy raise, and the
      # adapter is NOT called again.
      assert_raise RuntimeError, "LLM call failed: :open", fn ->
        BaseAgent.run(agent, %{chat_message: "t3"})
      end

      assert Agent.get(counter, & &1) == 2

      Agent.stop(counter)
      GenServer.stop(agent.circuit_breaker)
    end
  end
```

- [ ] **Step 2: Run it, watch it pass (this is the verification checkpoint for the whole tuples-inside pipeline)**

```
mix format && mix test test/agents/base_agent_llm_error_test.exs test/agents/base_agent_resilience_test.exs
```

Expected: `0 failures`, adapter call count exactly 2. If the breaker does NOT open, the failure means `{:error, %APIError{}}` was re-wrapped as a success somewhere between `llm_call` and `CircuitBreaker.call` — STOP, report, debug before touching anything. `VERIFY: Ran both files — Result: PASS`.

- [ ] **Step 3: Commit**

```
git add test/agents/base_agent_llm_error_test.exs
git commit -m "test(agents): circuit breaker opens on consecutive adapter APIError tuples"
```

---

### Task 11: Full-suite sweep + missed-call-site check

**Files:**
- None expected; any file surfaced by the sweep.

This plan changes a protocol-level contract; the audit (Task 9) was manual. This task is the mechanical proof no consumer was missed.

- [ ] **Step 1: Sweep for consumers the audit could have missed**

```
grep -rn "ConverseResult.normalize" lib/
grep -rn "Model.converse" lib/
grep -rn "get_response_with_usage\|get_response(" lib/
```

Expected: `normalize` consumers are exactly `summarizer.ex` (error-matched first, Task 9), `json_deserializer.ex` (error-matched first, Task 5), `base_agent.ex` (success-only unwrap, Task 6). `Model.converse` direct callers are exactly those three files (plus doc mentions). If any OTHER site destructures `{response, usage}` from a converse/normalize return, fix it with the same pattern (match `{:error, %Normandy.LLM.APIError{}}` first) and add a test before proceeding.

- [ ] **Step 2: Run the FULL suite**

```
mix format && mix test
```

Expected: `0 failures` — baseline was `71 doctests, 26 properties, 1432 tests, 0 failures (128 excluded)`; the total test count rises by roughly 30 (Tasks 1-10). Any failure — including in tests this plan did not touch — must be fixed before completion (project rule: "If tests fail, they must be fixed, even if were items we were not working on"). `VERIFY: Ran mix test (full suite) — Result: PASS, N tests, 0 failures`.

- [ ] **Step 3: Dialyzer gate (CI re-enabled it in cf8fd08 — don't ship a spec mismatch)**

```
mix dialyzer
```

Expected: clean. The changed `@spec`s (`Model.converse`, `ConverseResult.normalize/1`, `call_llm_with_resilience/4`, `get_response_with_usage/2`) are the likely offenders if not.

- [ ] **Step 4: Commit (only if the sweep changed anything)**

```
git add <each fixed file individually>
git commit -m "fix(llm): align remaining converse call sites with the APIError contract"
```

---

## Task Summary

| # | Task | Files touched |
|---|---|---|
| 1 | `Normandy.LLM.APIError` exception + provider mappings | `lib/normandy/llm/api_error.ex` (new) |
| 2 | `Model.converse` contract + `normalize/1` error pass-through | `model.ex`, `converse_result.ex` |
| 3 | ClaudioAdapter → `{:error, APIError}`, `Logger.error`, raw-path mapping | `claudio_adapter.ex` |
| 4 | OpenAICompatibleAdapter error mapping | `openai_compatible_adapter.ex` |
| 5 | JsonDeserializer: corrective-call error aborts retries | `json_deserializer.ex` |
| 6 | BaseAgent resilience core + `get_response` raise at edge | `base_agent.ex` |
| 7 | Driver path: `{:llm_error, _}` + APIError raise through `run/2` | `base_agent.ex`, `turn/driver.ex` |
| 8 | Server wiring + Inline verification | `turn/server.ex` |
| 9 | Call-site audit: Summarizer fix + no-change verdicts | `context/summarizer.ex` |
| 10 | Circuit-breaker-opens integration test | tests only |
| 11 | Full-suite sweep + Dialyzer | as surfaced |
