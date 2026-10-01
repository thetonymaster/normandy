# LLM Error Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A failed LLM call fails visibly: adapters return `{:error, %Normandy.LLMError{}}`, retries happen only for `retryable?` errors, and `BaseAgent.run/2` and the streaming functions raise `Normandy.LLMError`.

**Architecture:** Errors are values inside the library and raise once at the `BaseAgent` edge. `Model.converse/7` gains an additive `{:error, %LLMError{}}` return; `ConverseResult.normalize/1` becomes `{:ok, triple} | {:error, e}`, which is exactly `Retry`'s and `CircuitBreaker`'s contract. Each adapter classifies its own failures.

**Tech Stack:** Elixir, ExUnit, `Req.Test` (stubs through `client.options[:req_options]`), Claudio 0.7 (path dep `../Claudio`).

**Spec:** `docs/superpowers/specs/2026-09-30-llm-error-contract-design.md`

## Global Constraints

- Address the user as Q. No AI attribution in commits (no Co-Authored-By, no "Generated with").
- `git add` files individually; `git add .` / `-A` forbidden.
- Run `mix format` before running tests. Failing tests must be fixed, even outside the task.
- Never push. Never edit `CHANGELOG.md` or `@version` (cocogitto owns them).
- Error messages and log lines never inspect a client struct, `client.options` or `req_options` (they may hold an API key or auth header).
- `Normandy.LLMError` fields: `type`, `status`, `retryable?`, `message`, `reason`. Types: `:rate_limit`, `:overloaded`, `:server`, `:transport`, `:authentication`, `:permission`, `:not_found`, `:invalid_request`, `:invalid_output`, `:stream`, `:circuit_open`, `:unknown`.
- Message format: `"LLM call failed: <type> (<status>): <detail>"`; ` (<status>)` omitted when status is nil, `: <detail>` omitted when there is no detail.
- Breaking commits use `type(scope)!:` plus a `BREAKING CHANGE:` footer.
- Each task ends with `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and the full `mix test` green. The last task also runs `MIX_ENV=test mix dialyzer`, `mix test.postgres` and `mix test.redis`.
- Credo stock config: complexity/nesting findings get an inline `# credo:disable-for-next-line Credo.Check.Refactor.<Check>`, never a config change.

## Review Focus

1. A user-supplied `retry_if` written for the old shapes now receives `{:error, %LLMError{}}`; the term it receives must be exactly that (Task 2 test "custom retry_if receives the LLMError").
2. A custom `retry_if` that returns false for an exception used to produce `RuntimeError "LLM call failed: :exception"` (the `{:exception, e, stacktrace}` 3-tuple was mistaken for `{reason, attempts, errors}`); the original exception must be re-raised (Task 2 test).
3. A third-party `Model` returning `{:error, "anything"}` must raise `LLMError{type: :unknown}` with the term in `reason` and not in `message` (Task 2 test).
4. An `error` event mid-stream with incremental output guardrails must raise, not be treated as a guardrail halt (Task 6 test).
5. An `{:error, _}` item inside a stream (transport failure after the stream started) must raise `LLMError{type: :stream}` in both stream consumers (Task 6 tests).

---

### Task 1: `Normandy.LLMError`

**Files:**
- Create: `lib/normandy/llm/error.ex`
- Test: `test/llm/error_test.exs`

**Interfaces:**
- Produces:
  - `%Normandy.LLMError{type: atom, status: non_neg_integer | nil, retryable?: boolean, message: String.t, reason: term}` (an exception)
  - `Normandy.LLMError.new(keyword) :: t` — keys `:type` (required), `:retryable?` (required), `:status`, `:detail` (string for the message), `:reason`; raises `ArgumentError` on an unknown type or non-boolean `retryable?`
  - `Normandy.LLMError.wrap(term) :: t` — an `LLMError` passes through; anything else becomes `type: :unknown, retryable?: false, reason: term`
  - `@type t` and `@type error_type`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Normandy.LLMErrorTest do
  use ExUnit.Case, async: true

  alias Normandy.LLMError

  describe "new/1" do
    test "builds the message from type, status and detail" do
      e = LLMError.new(type: :rate_limit, status: 429, retryable?: true, detail: "slow down")

      assert %LLMError{type: :rate_limit, status: 429, retryable?: true} = e
      assert e.message == "LLM call failed: rate_limit (429): slow down"
      assert Exception.message(e) == e.message
    end

    test "omits the status and detail parts when absent" do
      assert LLMError.new(type: :transport, retryable?: true).message ==
               "LLM call failed: transport"
    end

    test "keeps the original error in :reason" do
      assert LLMError.new(type: :unknown, retryable?: false, reason: {:boom, 1}).reason ==
               {:boom, 1}
    end

    test "rejects an unknown type, naming the value" do
      assert_raise ArgumentError, ~r/unknown :type :nope/, fn ->
        LLMError.new(type: :nope, retryable?: false)
      end
    end

    test "rejects a non-boolean retryable?" do
      assert_raise ArgumentError, ~r/:retryable\? must be a boolean, got: :yes/, fn ->
        LLMError.new(type: :server, retryable?: :yes)
      end
    end
  end

  describe "wrap/1" do
    test "passes an LLMError through unchanged" do
      e = LLMError.new(type: :server, status: 500, retryable?: true)
      assert LLMError.wrap(e) == e
    end

    test "wraps any other term as :unknown without putting it in the message" do
      e = LLMError.wrap({:secret_ish, "sk-ant-canary"})

      assert %LLMError{type: :unknown, retryable?: false, reason: {:secret_ish, "sk-ant-canary"}} =
               e

      assert e.message == "LLM call failed: unknown"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix format && mix test test/llm/error_test.exs`
Expected: FAIL — `Normandy.LLMError.__struct__/1 is undefined` (module does not exist).

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Normandy.LLMError do
  @moduledoc """
  A failed LLM call.

  Adapters return `{:error, %Normandy.LLMError{}}` from `Normandy.Agents.Model.converse/7`;
  `Normandy.Agents.BaseAgent` raises it once retries (if configured) are exhausted.

  - `:type` — failure class (see `t:error_type/0`)
  - `:status` — HTTP status when there was one, else `nil`
  - `:retryable?` — whether a retry can help; set by the adapter that classified the failure
  - `:message` — `"LLM call failed: <type> (<status>): <detail>"`
  - `:reason` — the provider's original error, for debugging

  The message never includes the client, its options or `req_options`.
  """

  @types [
    :rate_limit,
    :overloaded,
    :server,
    :transport,
    :authentication,
    :permission,
    :not_found,
    :invalid_request,
    :invalid_output,
    :stream,
    :circuit_open,
    :unknown
  ]

  defexception [:type, :status, :retryable?, :message, :reason]

  @type error_type ::
          :rate_limit
          | :overloaded
          | :server
          | :transport
          | :authentication
          | :permission
          | :not_found
          | :invalid_request
          | :invalid_output
          | :stream
          | :circuit_open
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          status: non_neg_integer() | nil,
          retryable?: boolean(),
          message: String.t(),
          reason: term()
        }

  @doc """
  Builds an error. `:type` and `:retryable?` are required; `:status`, `:detail` (text for
  the message) and `:reason` are optional.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    type = Keyword.fetch!(fields, :type)
    retryable? = Keyword.fetch!(fields, :retryable?)
    status = Keyword.get(fields, :status)

    unless type in @types do
      raise ArgumentError,
            "Normandy.LLMError.new/1: unknown :type #{inspect(type)}, expected one of " <>
              inspect(@types)
    end

    unless is_boolean(retryable?) do
      raise ArgumentError,
            "Normandy.LLMError.new/1: :retryable? must be a boolean, got: #{inspect(retryable?)}"
    end

    %__MODULE__{
      type: type,
      status: status,
      retryable?: retryable?,
      reason: Keyword.get(fields, :reason),
      message: build_message(type, status, Keyword.get(fields, :detail))
    }
  end

  @doc """
  Returns an `LLMError` unchanged; wraps any other term as `type: :unknown`,
  `retryable?: false`, keeping the term in `:reason` (never in the message).
  """
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = error), do: error
  def wrap(reason), do: new(type: :unknown, retryable?: false, reason: reason)

  defp build_message(type, status, detail) do
    status_part = if is_integer(status), do: " (#{status})", else: ""
    detail_part = if is_binary(detail) and detail != "", do: ": " <> detail, else: ""
    "LLM call failed: #{type}#{status_part}#{detail_part}"
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/llm/error_test.exs`
Expected: PASS (8 tests, 0 failures).

- [ ] **Step 5: Gate and commit**

Run: `mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: compile clean, credo "found no issues", 0 failures.

```bash
git add lib/normandy/llm/error.ex test/llm/error_test.exs
git commit -m "feat(llm): add Normandy.LLMError for classified LLM call failures"
```

---

### Task 2: Error contract through `ConverseResult`, `BaseAgent` resilience, `JsonDeserializer` and `Summarizer`

**Files:**
- Modify: `lib/normandy/agents/converse_result.ex` (whole module)
- Modify: `lib/normandy/agents/base_agent.ex` — `call_llm_with_resilience/4` (~lines 310-372) and `raise_llm_call_error/1` (search `defp raise_llm_call_error`)
- Modify: `lib/normandy/llm/json_deserializer.ex` — `retry_with_feedback/12` (~lines 300-375)
- Modify: `lib/normandy/context/summarizer.ex` — `call_llm_for_summary/5` (~lines 193-217)
- Modify: `lib/normandy/agents/model.ex` (moduledoc / `converse` doc), `CLAUDE.md`, `MIGRATING-2.0.md`
- Test: `test/agents/converse_result_test.exs` (update), `test/agents/base_agent_llm_error_test.exs` (create), `test/llm/json_deserializer_retry_test.exs` (add), `test/context/summarizer_test.exs` (add)

**Interfaces:**
- Consumes: `Normandy.LLMError.new/1`, `wrap/1` (Task 1)
- Produces:
  - `ConverseResult.normalize(term) :: {:ok, {response, usage | nil, map}} | {:error, Normandy.LLMError.t}`
  - `BaseAgent` raises `Normandy.LLMError` for a final LLM failure (exceptions from `converse/7` are still re-raised with their original type and stacktrace)
  - `Summarizer.call_llm_for_summary/5` and the JSON retry loop return `{:error, %LLMError{}}` on an LLM failure

- [ ] **Step 1: Update the `normalize` tests to the new contract (failing)**

Replace the body of `test/agents/converse_result_test.exs`'s tests so every success is wrapped in `{:ok, _}` and errors become `LLMError`. Keep the module's existing `R` struct alias/definition; replace the assertions as follows:

```elixir
  test "3-tuple with map meta passes through" do
    assert {:ok, {%R{}, %{a: 1}, %{served_by: "m"}}} =
             ConverseResult.normalize({%R{}, %{a: 1}, %{served_by: "m"}})
  end

  test "2-tuple gets empty meta" do
    assert {:ok, {%R{}, %{a: 1}, %{}}} = ConverseResult.normalize({%R{}, %{a: 1}})
  end

  test "raw 2-tuple gets empty meta" do
    assert {:ok, {"raw", %{a: 1}, %{}}} = ConverseResult.normalize({"raw", %{a: 1}})
  end

  test "bare struct" do
    assert {:ok, {%R{}, nil, %{}}} = ConverseResult.normalize(%R{})
  end

  test "bare binary" do
    assert {:ok, {"raw", nil, %{}}} = ConverseResult.normalize("raw")
  end

  test "an LLMError passes through as {:error, e}" do
    e = Normandy.LLMError.new(type: :rate_limit, status: 429, retryable?: true)
    assert {:error, ^e} = ConverseResult.normalize({:error, e})
  end

  test "any other {:error, term} becomes an :unknown LLMError keeping the term" do
    assert {:error, %Normandy.LLMError{type: :unknown, retryable?: false, reason: :boom}} =
             ConverseResult.normalize({:error, :boom})
  end

  test "any other term is passed through as the response" do
    assert {:ok, {nil, nil, %{}}} = ConverseResult.normalize(nil)
  end

  test "a non-map meta raises, naming the function" do
    assert_raise ArgumentError, ~r/ConverseResult.normalize\/1/, fn ->
      ConverseResult.normalize({%R{}, %{a: 1}, nil})
    end
  end
```

(If the file's existing test names differ, replace them one for one — the file must end with exactly these nine tests.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix format && mix test test/agents/converse_result_test.exs`
Expected: FAIL — the `{:ok, ...}` matches fail against the old `{response, usage, meta}` returns.

- [ ] **Step 3: Implement the new `normalize/1`**

Replace `lib/normandy/agents/converse_result.ex` with:

```elixir
defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the `Normandy.Agents.Model.converse/7` return into
  `{:ok, {response, usage, meta}}` or `{:error, %Normandy.LLMError{}}`.

  Implementations may return `struct()`, `{struct(), usage}`, `{struct(), usage, meta}`
  (and, in raw mode, the same shapes with a binary), or `{:error, %Normandy.LLMError{}}`.
  `meta` carries per-call facts that are not token usage, such as `:served_by`. Bare and
  2-tuple returns stay accepted so third-party `Model` implementations keep working; an
  `{:error, term}` that is not an `LLMError` becomes `type: :unknown`.
  """

  alias Normandy.LLMError

  @spec normalize(term()) :: {:ok, {term(), map() | nil, map()}} | {:error, LLMError.t()}
  def normalize({:error, reason}), do: {:error, LLMError.wrap(reason)}

  def normalize({response, usage, meta})
      when (is_struct(response) or is_binary(response)) and is_map(meta),
      do: {:ok, {response, usage, meta}}

  def normalize({response, _usage, meta}) when is_struct(response) or is_binary(response) do
    raise ArgumentError,
          "Normandy.Agents.ConverseResult.normalize/1: a {response, usage, meta} return " <>
            "needs a map as meta, got: #{inspect(meta)}. Return %{} when there is no meta."
  end

  def normalize({response, usage}) when is_struct(response) or is_binary(response),
    do: {:ok, {response, usage, %{}}}

  def normalize(response) when is_struct(response) or is_binary(response),
    do: {:ok, {response, nil, %{}}}

  def normalize(other), do: {:ok, {other, nil, %{}}}
end
```

- [ ] **Step 4: Run the `normalize` tests**

Run: `mix format && mix test test/agents/converse_result_test.exs`
Expected: PASS (9 tests). The full suite is now broken at the three callers; Steps 5-12 fix them.

- [ ] **Step 5: Write the failing `BaseAgent` tests**

Create `test/agents/base_agent_llm_error_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentLLMErrorTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError

  # Returns {:error, error} from converse/7 and reports each call to `notify`.
  defmodule ErrorClient do
    defstruct notify: nil, error: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentLLMErrorTest.ErrorClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _m, _t, _mt, _msgs, _response_model, _opts) do
      send(client.notify, :converse_called)
      {:error, client.error}
    end
  end

  # Raises from converse/7.
  defmodule RaisingClient do
    defstruct notify: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentLLMErrorTest.RaisingClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _m, _t, _mt, _msgs, _response_model, _opts) do
      send(client.notify, :converse_called)
      raise ArgumentError, "transport blew up"
    end
  end

  defp agent(client, extra \\ %{}) do
    BaseAgent.init(Map.merge(%{client: client, model: "claude-opus-5-5", temperature: nil}, extra))
  end

  defp input, do: %Normandy.Agents.BaseAgentInputSchema{chat_message: "hi"}

  defp calls do
    receive do
      :converse_called -> 1 + calls()
    after
      0 -> 0
    end
  end

  @retry [max_attempts: 3, base_delay: 1, max_delay: 2]

  test "without retry_options an LLM error raises on the first call" do
    e = LLMError.new(type: :server, status: 500, retryable?: true)
    agent = agent(%ErrorClient{notify: self(), error: e})

    assert_raise LLMError, "LLM call failed: server (500)", fn -> BaseAgent.run(agent, input()) end
    assert calls() == 1
  end

  test "a retryable error is attempted max_attempts times, then raised" do
    e = LLMError.new(type: :overloaded, status: 529, retryable?: true)
    agent = agent(%ErrorClient{notify: self(), error: e}, %{retry_options: @retry})

    raised = assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert raised == e
    assert calls() == 3
  end

  test "a non-retryable error is attempted once, then raised" do
    e = LLMError.new(type: :authentication, status: 401, retryable?: false)
    agent = agent(%ErrorClient{notify: self(), error: e}, %{retry_options: @retry})

    assert_raise LLMError, ~r/authentication \(401\)/, fn -> BaseAgent.run(agent, input()) end
    assert calls() == 1
  end

  test "custom retry_if receives the LLMError" do
    test_pid = self()
    e = LLMError.new(type: :rate_limit, status: 429, retryable?: true)

    retry_if = fn term ->
      send(test_pid, {:retry_if_got, term})
      false
    end

    agent =
      agent(%ErrorClient{notify: self(), error: e}, %{
        retry_options: Keyword.put(@retry, :retry_if, retry_if)
      })

    assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert_received {:retry_if_got, {:error, ^e}}
  end

  test "a custom retry_if that refuses an exception re-raises the original exception" do
    agent =
      agent(%RaisingClient{notify: self()}, %{
        retry_options: Keyword.put(@retry, :retry_if, fn _ -> false end)
      })

    assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run(agent, input()) end
    assert calls() == 1
  end

  test "a third-party {:error, term} raises an :unknown LLMError keeping the term out of the message" do
    agent = agent(%ErrorClient{notify: self(), error: "sk-ant-canary detail"})

    raised = assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert raised.type == :unknown
    assert raised.reason == "sk-ant-canary detail"
    refute raised.message =~ "sk-ant-canary"
  end

  test "repeated failures open the circuit breaker, then calls raise :circuit_open" do
    e = LLMError.new(type: :server, status: 503, retryable?: true)

    agent =
      agent(%ErrorClient{notify: self(), error: e}, %{
        enable_circuit_breaker: true,
        circuit_breaker_options: [failure_threshold: 2, timeout: 60_000]
      })

    assert_raise LLMError, ~r/server/, fn -> BaseAgent.run(agent, input()) end
    assert_raise LLMError, ~r/server/, fn -> BaseAgent.run(agent, input()) end

    raised = assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert raised.type == :circuit_open
    assert calls() == 2
  end
end
```

Note for the implementer: `BaseAgent.run/2` returns `{config, response}` on success; each `run` above raises, so reusing `agent` across calls is intended (the circuit breaker is a process held in the config). If `BaseAgentInputSchema` needs a different constructor in this codebase, use whatever `test/agents/base_agent_test.exs` uses for a user input.

- [ ] **Step 6: Run to verify it fails**

Run: `mix format && mix test test/agents/base_agent_llm_error_test.exs`
Expected: FAIL — today `{:error, e}` is wrapped as `{:ok, {:error, e}}` and treated as a response, so no `LLMError` is raised (likely a MatchError/FunctionClauseError downstream or a returned response instead).

- [ ] **Step 7: Implement the resilience change in `BaseAgent`**

Add `alias Normandy.LLMError` to the aliases at the top of `lib/normandy/agents/base_agent.ex`.

Replace `call_llm_with_resilience/4` with:

```elixir
  # Private helper to call LLM with retry and circuit breaker protection.
  # The call returns {:ok, triple} | {:error, %LLMError{}} (ConverseResult.normalize/1),
  # which is Retry's and CircuitBreaker's contract, so returned API errors are retried
  # (when the adapter marked them retryable?) and counted, exactly like raises.
  @spec call_llm_with_resilience(BaseAgentConfig.t(), list(), struct(), keyword()) ::
          {struct(), map() | nil, map()}
  defp call_llm_with_resilience(config, messages, response_model, opts) do
    llm_call = fn ->
      config.client
      |> Model.converse(
        config.model,
        config.temperature,
        config.max_tokens,
        messages,
        response_model,
        opts
      )
      |> ConverseResult.normalize()
    end

    # Apply retry first if configured, then circuit breaker wraps the whole thing
    retryable_call =
      if config.retry_options do
        fn ->
          retry_opts =
            if Keyword.has_key?(config.retry_options, :retry_if) do
              config.retry_options
            else
              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              Keyword.put(config.retry_options, :retry_if, &default_retry_if/1)
            end

          Retry.with_retry(llm_call, retry_opts)
        end
      else
        llm_call
      end

    # Apply circuit breaker if configured (wraps the retry logic)
    protected_call =
      if config.circuit_breaker do
        fn -> CircuitBreaker.call(config.circuit_breaker, retryable_call) end
      else
        retryable_call
      end

    case protected_call.() do
      {:ok, triple} ->
        triple

      # Retry gave up: {last_error, attempts, errors}. The integer guard keeps
      # {:exception, error, stacktrace} (also a 3-tuple) out of this clause.
      {:error, {reason, attempts, errors}} when is_integer(attempts) and is_list(errors) ->
        raise_llm_call_error(reason)

      {:error, reason} ->
        raise_llm_call_error(reason)
    end
  end

  defp default_retry_if({:error, %LLMError{retryable?: retryable?}}), do: retryable?
  defp default_retry_if({:error, {:exception, _, _}}), do: true
  defp default_retry_if({:error, :open}), do: false
  defp default_retry_if({:error, error}) when is_atom(error), do: true
  defp default_retry_if(_), do: false
```

Replace the `raise_llm_call_error/1` clauses with:

```elixir
  defp raise_llm_call_error(%LLMError{} = error), do: raise(error)

  defp raise_llm_call_error(:open),
    do: raise(LLMError.new(type: :circuit_open, retryable?: false, detail: "circuit breaker is open"))

  defp raise_llm_call_error({:exception, error, stacktrace}) do
    if Kernel.is_exception(error) do
      reraise(error, stacktrace)
    else
      raise LLMError.wrap({:exception, error})
    end
  end

  defp raise_llm_call_error({:exception, error}) do
    if Kernel.is_exception(error) do
      raise RuntimeError, "LLM call failed: #{Exception.message(error)}"
    else
      raise LLMError.wrap({:exception, error})
    end
  end

  defp raise_llm_call_error(reason), do: raise(LLMError.wrap(reason))
```

- [ ] **Step 8: Run the `BaseAgent` tests**

Run: `mix format && mix test test/agents/base_agent_llm_error_test.exs`
Expected: PASS (7 tests). If the breaker test's option names or threshold semantics differ, read `lib/normandy/resilience/circuit_breaker.ex` (`start_link/1` docs, `record_failure`) and set the options so the breaker opens after exactly 2 failures; do not change the assertions.

- [ ] **Step 9: Write the failing JSON-retry and Summarizer tests**

In `test/llm/json_deserializer_retry_test.exs`, add a client and test (keep the file's existing aliases; add `alias Normandy.LLMError` if absent):

```elixir
  defmodule FailingRetryClient do
    defstruct notify: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.LLM.JsonDeserializerRetryTest.FailingRetryClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _m, _t, _mt, _msgs, _schema, _opts) do
      send(client.notify, :retry_called)
      {:error, Normandy.LLMError.new(type: :overloaded, status: 529, retryable?: true)}
    end
  end

  test "an LLM error during a parse retry is returned, with no further attempts" do
    client = %FailingRetryClient{notify: self()}

    assert {:error, %Normandy.LLMError{type: :overloaded}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               client,
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 2
             )

    assert_received :retry_called
    refute_received :retry_called
  end
```

(`MultiField`, `JsonDeserializer` and `@msgs` — a system message, which the retry feedback augments — are already defined in this test module; `MultiField` has non-`chat_message` fields, so "not json" is a parse failure that triggers a retry.)

In `test/context/summarizer_test.exs`, add near the existing client modules at the top:

```elixir
defmodule Normandy.Test.LLMErrorSummarizerClient do
  @moduledoc false
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, _response_model, _opts),
      do: {:error, Normandy.LLMError.new(type: :rate_limit, status: 429, retryable?: true)}
  end
end
```

and inside `Normandy.Context.SummarizerTest`:

```elixir
  describe "LLM failures" do
    test "summarize_messages returns the LLMError instead of an empty summary" do
      agent =
        BaseAgent.init(%{
          client: %Normandy.Test.LLMErrorSummarizerClient{},
          model: "test-model",
          temperature: nil
        })

      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      assert {:error, %Normandy.LLMError{type: :rate_limit}} =
               Summarizer.summarize_messages(agent.client, agent, messages)
    end
  end
```

Check `Summarizer`'s public function that summarizes a list of messages (`summarize_messages/3` or similar — read the module's `@doc`s) and call that one; the assertion stays.

- [ ] **Step 10: Run to verify they fail**

Run: `mix format && mix test test/llm/json_deserializer_retry_test.exs test/context/summarizer_test.exs`
Expected: FAIL — both callers destructure `{response, _usage, _meta} = ConverseResult.normalize(...)`, which no longer matches (`MatchError` on `{:error, ...}` / `{:ok, ...}`).

- [ ] **Step 11: Update the two callers**

`lib/normandy/llm/json_deserializer.ex`, in `retry_with_feedback/12`, replace from `{response, _usage, _meta} =` through the end of the `cond` with:

```elixir
    case ConverseResult.normalize(
           Model.converse(
             client,
             model,
             temperature,
             max_tokens,
             augmented_messages,
             schema,
             llm_opts
           )
         ) do
      # An LLM failure is not a parse failure: stop and hand it back.
      {:error, %LLMError{}} = error ->
        error

      {:ok, {response, _usage, _meta}} ->
        continue_after_retry(
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
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp continue_after_retry(
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
       ) do
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

(The closing `end` of `retry_with_feedback` now closes the `case`; make sure the function and the new `continue_after_retry/11` each have exactly one closing `end`.) Add `alias Normandy.LLMError` to the module's aliases.

`lib/normandy/context/summarizer.ex`, replace `call_llm_for_summary/5`'s body after `response_model = ...` with:

```elixir
    case ConverseResult.normalize(
           Model.converse(client, model, temperature, max_tokens, messages, response_model, [])
         ) do
      {:ok, {%{chat_message: summary}, _usage, _meta}} when is_binary(summary) ->
        {:ok, summary}

      {:ok, {other, _usage, _meta}} ->
        {:error, {:unexpected_response, other}}

      {:error, %Normandy.LLMError{}} = error ->
        error
    end
```

(The empty-summary guard is Task 3.)

- [ ] **Step 12: Run the caller tests**

Run: `mix format && mix test test/llm/json_deserializer_retry_test.exs test/context/summarizer_test.exs test/behaviours/compactor_test.exs`
Expected: PASS.

- [ ] **Step 13: Docs**

`lib/normandy/agents/model.ex`: in the moduledoc / `converse` `@doc`, where it lists the accepted return shapes (bare response, `{response, usage}`, `{response, usage, meta}`), add: "or `{:error, %Normandy.LLMError{}}` when the call failed. Set `retryable?` to true only when resending the same request can succeed (rate limit, overload, 5xx, transport)."

`CLAUDE.md`, the `Normandy.Agents.Model` bullet: change "`converse/7` may return a bare response, `{response, usage}` or `{response, usage, meta}`" to "`converse/7` may return a bare response, `{response, usage}`, `{response, usage, meta}`, or `{:error, %Normandy.LLMError{}}`".

`MIGRATING-2.0.md`: add before `## New, non-breaking`:

```markdown
## 11. LLM failures raise `Normandy.LLMError`

- `Model.converse/7` may now return `{:error, %Normandy.LLMError{}}`. Code that calls
  `converse/7` directly must handle it; `ConverseResult.normalize/1` now returns
  `{:ok, {response, usage, meta}}` or `{:error, %Normandy.LLMError{}}`.
- `BaseAgent.run/2` and the DSL's `run/1-3` raise `Normandy.LLMError` when a call fails for
  good. They used to raise `RuntimeError` for transport exceptions. Rescue
  `Normandy.LLMError` instead.
- The default `retry_if` retries errors whose `retryable?` is true. A custom `retry_if`
  receives `{:error, %Normandy.LLMError{}}` for returned failures.
```

- [ ] **Step 14: Gate and commit**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean; 0 failures. Fix any other test that matched the old `normalize` return or relied on a returned `{:error, _}` being treated as a response — update it to the new contract, never the code back.

```bash
git add lib/normandy/agents/converse_result.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/llm/json_deserializer.ex lib/normandy/context/summarizer.ex \
  lib/normandy/agents/model.ex CLAUDE.md MIGRATING-2.0.md \
  test/agents/converse_result_test.exs test/agents/base_agent_llm_error_test.exs \
  test/llm/json_deserializer_retry_test.exs test/context/summarizer_test.exs
git commit -F - <<'EOF'
feat(llm)!: carry LLM failures as {:error, %LLMError{}} through retry and breaker

ConverseResult.normalize/1 returns {:ok, triple} | {:error, %LLMError{}}, which
is Retry's and CircuitBreaker's contract, so a returned failure is retried when
retryable? and counted by the breaker, then raised by BaseAgent. The JSON
parse-retry loop and the Summarizer hand LLM failures back instead of treating
them as output. A custom retry_if that refuses an exception now re-raises it
(the {:exception, e, stacktrace} 3-tuple was mistaken for Retry's give-up tuple).

BREAKING CHANGE: Model.converse/7 may return {:error, %Normandy.LLMError{}};
ConverseResult.normalize/1 returns {:ok, _} | {:error, _}; BaseAgent raises
Normandy.LLMError (not RuntimeError) for a failed LLM call.
EOF
```

(Add any other test file you had to update to the `git add` list, individually.)

---

### Task 3: Compaction never wipes history on a failed or empty summary

**Files:**
- Modify: `lib/normandy/context/summarizer.ex` — `call_llm_for_summary/5` (the `case` from Task 2)
- Modify: `lib/normandy/context/window_manager.ex` — `@spec` of `ensure_within_limit/2` and `truncate_conversation/2`
- Modify: `.dialyzer_ignore.exs` — remove the `behaviours/compactor/window_manager.ex` entry
- Test: `test/behaviours/compactor_test.exs` (add)

**Interfaces:**
- Consumes: Task 2's `call_llm_for_summary/5` returning `{:error, %LLMError{}}`
- Produces: `call_llm_for_summary/5` returns `{:error, :empty_summary}` for a non-binary or empty `chat_message`; `WindowManager.ensure_within_limit/2 :: {:ok, struct()} | {:error, term()}`

- [ ] **Step 1: Write the failing tests**

At the top of `test/behaviours/compactor_test.exs`, next to `Normandy.Test.BadResponseClient`, add:

```elixir
defmodule Normandy.Test.EmptySummaryClient do
  @moduledoc "Stub LLM client whose summary comes back empty."
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts),
      do: %{response_model | chat_message: ""}
  end
end

defmodule Normandy.Test.LLMErrorCompactionClient do
  @moduledoc "Stub LLM client whose summarization call fails."
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, _response_model, _opts),
      do: {:error, Normandy.LLMError.new(type: :overloaded, status: 529, retryable?: true)}
  end
end
```

Inside the `describe` that holds the existing test ":summarize strategy returns error meta when client returns unexpected response shape", add two tests built exactly like it (same `msgs`, `mem_with/1`, `WMCompactor.maybe_compact/3` call with `strategy: :summarize, reserved_tokens: 64`):

```elixir
    test ":summarize keeps history when the summarization call fails" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}
      acc = %{memory: mem_with(msgs), client: %Normandy.Test.LLMErrorCompactionClient{}, model: "m"}
      original_history = AgentMemory.history(acc.memory)

      {returned_acc, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      assert meta.compacted == false
      assert %Normandy.LLMError{type: :overloaded} = meta.error
      assert AgentMemory.history(returned_acc.memory) == original_history
    end

    test ":summarize keeps history when the summary comes back empty" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}
      acc = %{memory: mem_with(msgs), client: %Normandy.Test.EmptySummaryClient{}, model: "m"}
      original_history = AgentMemory.history(acc.memory)

      {returned_acc, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      assert meta.compacted == false
      assert meta.error == :empty_summary
      assert AgentMemory.history(returned_acc.memory) == original_history
    end
```

- [ ] **Step 2: Run to verify**

Run: `mix format && mix test test/behaviours/compactor_test.exs`
Expected: the LLM-failure test PASSES already (Task 2 made the Summarizer return the error — note it as "passed on first run, made green by Task 2"); the empty-summary test FAILS (history is replaced by "Previous conversation summary: ").

- [ ] **Step 3: Implement the empty-summary guard**

In `call_llm_for_summary/5`, change the first clause and add one after it:

```elixir
      {:ok, {%{chat_message: summary}, _usage, _meta}} when is_binary(summary) and summary != "" ->
        {:ok, summary}

      {:ok, {%{chat_message: _empty_or_not_text}, _usage, _meta}} ->
        {:error, :empty_summary}
```

(Keep the `{:ok, {other, _, _}} -> {:error, {:unexpected_response, other}}` and `{:error, %Normandy.LLMError{}}` clauses after these.)

- [ ] **Step 4: Run the tests**

Run: `mix format && mix test test/behaviours/compactor_test.exs test/context/summarizer_test.exs test/context/window_manager_test.exs`
Expected: PASS.

- [ ] **Step 5: Fix the specs and the Dialyzer ignore entry**

In `lib/normandy/context/window_manager.ex`, change both specs to:

```elixir
  @spec ensure_within_limit(struct(), t()) :: {:ok, struct()} | {:error, term()}
```

```elixir
  @spec truncate_conversation(struct(), t()) :: {:ok, struct()} | {:error, term()}
```

Update the `ensure_within_limit/2` `@doc` to say it returns `{:error, reason}` when the `:summarize` strategy's summarization fails, leaving the agent unchanged.

Run: `MIX_ENV=test mix dialyzer --list-unused-filters`
Expected: the output lists `{"lib/normandy/behaviours/compactor/window_manager.ex", :pattern_match}` as unused (the `{:error, reason}` arm in `Compactor.WindowManager` is now reachable per the spec).

Delete that entry and its comment block (the lines starting `# behaviours/compactor/window_manager.ex run/2 (line 56)`) from `.dialyzer_ignore.exs`.

Run: `MIX_ENV=test mix dialyzer`
Expected: `done (passed successfully)`, `Unnecessary Skips: 0`.

- [ ] **Step 6: Gate and commit**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean; 0 failures.

```bash
git add lib/normandy/context/summarizer.ex lib/normandy/context/window_manager.ex \
  .dialyzer_ignore.exs test/behaviours/compactor_test.exs
git commit -m "fix(context): keep history when a summary fails or comes back empty"
```

---

### Task 4: `ClaudioAdapter` returns classified errors

**Files:**
- Modify: `lib/normandy/llm/claudio_adapter.ex`:
  - `handle_error/2` (search `defp handle_error`) and its two call sites (legacy `converse` ~line 221, structured ~line 282)
  - the legacy success branch (~line 215, `normalized_response = convert_response_to_normandy(...)`) and the structured success branch (~line 262, `{ClaudioAdapter.__handle_structured_response__(...), ...}`)
  - `populate_standard_schema/3` (`case JsonDeserializer.deserialize_with_retry(...)`)
  - `apply_parse_failure/4` `:error` clause
  - `__raw_completion__/1` error clause
  - `stream_converse/7` connection-error branch (`{:error, error} -> {:error, error}` at the end)
  - new public `@doc false` `__to_llm_error__/1` on the outer `Normandy.LLM.ClaudioAdapter` module
  - moduledoc
- Modify: `lib/normandy/llm/json_deserializer.ex` — moduledoc `:on_parse_failure` / `:error` bullet
- Modify: `MIGRATING-2.0.md` — section 11 (from Task 2)
- Test: `test/llm/claudio_adapter_errors_test.exs` (create), `test/llm/claudio_adapter_test.exs` (update the `:error`-policy assertions)

**Interfaces:**
- Consumes: `Normandy.LLMError.new/1`, `wrap/1` (Task 1); `normalize/1` contract (Task 2)
- Produces: `ClaudioAdapter.__to_llm_error__(term) :: Normandy.LLMError.t()`; `Model.converse/7` and `Model.stream_converse/7` for `%ClaudioAdapter{}` return `{:error, %LLMError{}}` on failure; `on_parse_failure: :error` yields `{:error, %LLMError{type: :invalid_output}}` at the top level

Classification (spec §2, with one refinement): the specific Claudio types map directly; a generic `:api_error` (or an unrecognised type) is classified by HTTP status, because Claudio types every streaming HTTP error as `:api_error` regardless of status.

| Claudio `APIError.type` | `type` | `retryable?` |
|---|---|---|
| `:rate_limit_error` | `:rate_limit` | true |
| `:overloaded_error` | `:overloaded` | true |
| `:authentication_error` | `:authentication` | false |
| `:permission_error` | `:permission` | false |
| `:not_found_error` | `:not_found` | false |
| `:invalid_request_error` | `:invalid_request` | false |
| other (incl. `:api_error`), by status: nil, 408, ≥500 except 529 | `:server` | true |
| … 429 | `:rate_limit` | true |
| … 529 | `:overloaded` | true |
| … 401 / 403 / 404 | `:authentication` / `:permission` / `:not_found` | false |
| … other 4xx | `:invalid_request` | false |
| `%Req.TransportError{}`, `%Mint.TransportError{}`, `%Mint.HTTPError{}` | `:transport` | true |
| anything else | `:unknown` (via `LLMError.wrap/1`) | false |

- [ ] **Step 1: Write the failing tests**

Create `test/llm/claudio_adapter_errors_test.exs`:

```elixir
defmodule Normandy.LLM.ClaudioAdapterErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLMError

  @key "sk-ant-test-canary-key"

  defp client(stub, extra_options \\ %{}) do
    %ClaudioAdapter{
      api_key: @key,
      options:
        Map.merge(
          %{req_options: [plug: {Req.Test, stub}, retry: false]},
          extra_options
        )
    }
  end

  defp converse(client) do
    Model.converse(
      client,
      "claude-opus-5-5",
      nil,
      1024,
      [%Message{role: "user", content: "hi"}],
      %Normandy.Agents.BaseAgentOutputSchema{},
      []
    )
  end

  defp stub_error(stub, status, api_type, message) do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"type" => "error", "error" => %{"type" => api_type, "message" => message}})
    end)
  end

  @matrix [
    {401, "authentication_error", :authentication, false},
    {403, "permission_error", :permission, false},
    {404, "not_found_error", :not_found, false},
    {400, "invalid_request_error", :invalid_request, false},
    {429, "rate_limit_error", :rate_limit, true},
    {529, "overloaded_error", :overloaded, true},
    {500, "api_error", :server, true},
    {408, "api_error", :server, true}
  ]

  describe "legacy path (structured_outputs: false)" do
    for {status, api_type, type, retryable?} <- @matrix do
      test "HTTP #{status} #{api_type} -> #{type}, retryable?: #{retryable?}" do
        stub_error(__MODULE__.Legacy, unquote(status), unquote(api_type), "boom")

        assert {:error, %LLMError{} = e} =
                 converse(client(__MODULE__.Legacy, %{structured_outputs: false}))

        assert e.type == unquote(type)
        assert e.status == unquote(status)
        assert e.retryable? == unquote(retryable?)
        assert e.message =~ "boom"
        refute inspect(e) =~ @key
      end
    end

    test "a transport error -> :transport, retryable" do
      Req.Test.stub(__MODULE__.Transport, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %LLMError{type: :transport, retryable?: true, status: nil} = e} =
               converse(client(__MODULE__.Transport, %{structured_outputs: false}))

      refute inspect(e) =~ @key
    end
  end

  describe "structured path (default)" do
    test "a non-request-shape error is returned at the top level, not inside a tuple" do
      stub_error(__MODULE__.Structured, 529, "overloaded_error", "busy")

      assert {:error, %LLMError{type: :overloaded, status: 529}} =
               converse(client(__MODULE__.Structured))
    end

    test "an invalid_request_error falls back to legacy once, then returns the error" do
      test_pid = self()

      Req.Test.stub(__MODULE__.Fallback, fn conn ->
        send(test_pid, :request)

        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "type" => "error",
          "error" => %{"type" => "invalid_request_error", "message" => "bad"}
        })
      end)

      assert {:error, %LLMError{type: :invalid_request}} = converse(client(__MODULE__.Fallback))
      assert_received :request
      assert_received :request
      refute_received :request
    end
  end

  describe "stream_converse/7" do
    test "a connection-time HTTP error is classified (streaming errors arrive as :api_error)" do
      Req.Test.stub(__MODULE__.Stream, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, %LLMError{type: :rate_limit, status: 429, retryable?: true}} =
               Model.stream_converse(
                 client(__MODULE__.Stream),
                 "claude-opus-5-5",
                 nil,
                 1024,
                 [%Message{role: "user", content: "hi"}],
                 %Normandy.Agents.BaseAgentOutputSchema{},
                 []
               )
    end
  end

  describe "__to_llm_error__/1" do
    test "an unknown term is wrapped as :unknown" do
      assert %LLMError{type: :unknown, retryable?: false, reason: :weird} =
               ClaudioAdapter.__to_llm_error__(:weird)
    end
  end
end
```

In `test/llm/claudio_adapter_test.exs`, update the three `:error`-policy assertions:

```elixir
    test ":error policy returns {:error, reason}" do
      assert {:error, %Normandy.LLMError{type: :invalid_output, retryable?: false, reason: :some_reason}} =
               ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw", :some_reason, %{
                 on_parse_failure: :error
               })
    end
```

```elixir
      assert {:error,
              %Normandy.LLMError{
                type: :invalid_output,
                reason: {:structured_output_incomplete, :refusal}
              }} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
                 on_parse_failure: :error
               })
```

```elixir
      assert {:error,
              %Normandy.LLMError{
                type: :invalid_output,
                reason: {:structured_output_incomplete, "refusal"}
              }} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
                 on_parse_failure: :error
               })
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix format && mix test test/llm/claudio_adapter_errors_test.exs test/llm/claudio_adapter_test.exs`
Expected: FAIL — `converse` returns the blank response model (legacy) or `{blank, nil}` (structured); `__to_llm_error__/1` is undefined; the policy tests get bare reasons.

If the streaming stub test returns something other than `{:error, %Claudio.APIError{type: :api_error, status_code: 429}}` before the fix (inspect it), adjust only the stub's response shape so Claudio produces that error; the assertion stays.

- [ ] **Step 3: Implement the classifier**

On the outer `Normandy.LLM.ClaudioAdapter` module (next to `__structured_error_action__/1`), add `alias Normandy.LLMError` at the top of the outer module and:

```elixir
  @doc false
  # Classifies a Claudio failure (spec §2). A generic :api_error is classified by
  # status: Claudio types every streaming HTTP error as :api_error.
  @spec __to_llm_error__(term()) :: LLMError.t()
  def __to_llm_error__(%LLMError{} = error), do: error

  def __to_llm_error__(%Claudio.APIError{type: type, status_code: status, message: message} = e) do
    {llm_type, retryable?} = classify_api_error(type, status)
    LLMError.new(type: llm_type, status: status, retryable?: retryable?, detail: message, reason: e)
  end

  def __to_llm_error__(%module{} = e)
      when module in [Req.TransportError, Mint.TransportError, Mint.HTTPError] do
    LLMError.new(type: :transport, retryable?: true, detail: Exception.message(e), reason: e)
  end

  def __to_llm_error__(other), do: LLMError.wrap(other)

  defp classify_api_error(:rate_limit_error, _status), do: {:rate_limit, true}
  defp classify_api_error(:overloaded_error, _status), do: {:overloaded, true}
  defp classify_api_error(:authentication_error, _status), do: {:authentication, false}
  defp classify_api_error(:permission_error, _status), do: {:permission, false}
  defp classify_api_error(:not_found_error, _status), do: {:not_found, false}
  defp classify_api_error(:invalid_request_error, _status), do: {:invalid_request, false}
  defp classify_api_error(_type, status), do: classify_status(status)

  defp classify_status(nil), do: {:server, true}
  defp classify_status(429), do: {:rate_limit, true}
  defp classify_status(529), do: {:overloaded, true}
  defp classify_status(408), do: {:server, true}
  defp classify_status(status) when status >= 500, do: {:server, true}
  defp classify_status(401), do: {:authentication, false}
  defp classify_status(403), do: {:permission, false}
  defp classify_status(404), do: {:not_found, false}
  defp classify_status(status) when status >= 400, do: {:invalid_request, false}
  defp classify_status(_status), do: {:unknown, false}
```

- [ ] **Step 4: Return errors from every adapter path**

Inside the `defimpl` (add `alias Normandy.LLMError` there too):

1. Replace `handle_error/2` with:

```elixir
    defp handle_error(error), do: {:error, ClaudioAdapter.__to_llm_error__(error)}
```

and its call sites: legacy `{:error, error} -> handle_error(error, response_model)` becomes `{:error, error} -> handle_error(error)`; structured `:propagate -> {handle_error(error, response_model), nil}` becomes `:propagate -> handle_error(error)`.

2. Legacy success branch — replace

```elixir
          normalized_response = convert_response_to_normandy(response, response_model, context)

          {normalized_response, ClaudioAdapter.extract_usage(response),
           ClaudioAdapter.response_meta(response)}
```

with

```elixir
          case convert_response_to_normandy(response, response_model, context) do
            {:error, %LLMError{}} = error ->
              error

            normalized_response ->
              {normalized_response, ClaudioAdapter.extract_usage(response),
               ClaudioAdapter.response_meta(response)}
          end
```

3. Structured success branch — replace

```elixir
          {ClaudioAdapter.__handle_structured_response__(
             response,
             response_model,
             context
           ), ClaudioAdapter.extract_usage(response), ClaudioAdapter.response_meta(response)}
```

with

```elixir
          case ClaudioAdapter.__handle_structured_response__(response, response_model, context) do
            {:error, %LLMError{}} = error ->
              error

            handled ->
              {handled, ClaudioAdapter.extract_usage(response),
               ClaudioAdapter.response_meta(response)}
          end
```

4. `populate_standard_schema/3` — add a clause before the parse-policy clause:

```elixir
        {:ok, validated_schema} ->
          validated_schema

        # An LLM failure during a parse retry is not a parse failure.
        {:error, %LLMError{}} = error ->
          error

        {:error, reason} ->
          ClaudioAdapter.apply_parse_failure(schema, content, reason, context)
```

5. `stream_converse/7` — the final branch becomes:

```elixir
        {:error, error} ->
          {:error, ClaudioAdapter.__to_llm_error__(error)}
```

On the outer module:

6. `apply_parse_failure/4`'s `:error` clause becomes:

```elixir
      :error ->
        {:error,
         LLMError.new(
           type: :invalid_output,
           retryable?: false,
           detail: "model output did not match the schema",
           reason: reason
         )}
```

7. `__raw_completion__/1`'s error clause becomes:

```elixir
  def __raw_completion__({:error, error}), do: {:error, __to_llm_error__(error)}
```

Grep the file for any remaining `IO.warn` on an error path (`grep -n "IO.warn" lib/normandy/llm/claudio_adapter.ex`) — there must be none.

- [ ] **Step 5: Run the tests**

Run: `mix format && mix test test/llm/`
Expected: PASS. If an existing `__raw_completion__` test asserted `{:error, raw}`, update it to `{:error, %Normandy.LLMError{}}`.

- [ ] **Step 6: Docs**

- `ClaudioAdapter` moduledoc: add a "## Errors" section: `converse/7` and `stream_converse/7` return `{:error, %Normandy.LLMError{}}` on failure, classified per the table above (one line per type), and `on_parse_failure: :error` returns `type: :invalid_output`. Mention that Claudio's client-level `retry:` (in `req_options`/client config) retries HTTP failures before Normandy sees them, and that enabling it together with `retry_options` multiplies attempts.
- `JsonDeserializer` moduledoc, the `:error` bullet: "Returns `{:error, %Normandy.LLMError{type: :invalid_output, reason: reason}}` to the caller; no fallback text is produced."
- `MIGRATING-2.0.md` section 11: add the bullet "API errors (401, 429, 529, 5xx, …) and transport errors used to come back as an empty response. They now return `{:error, %Normandy.LLMError{}}` from the adapter and raise from `run/2`. `on_parse_failure: :error` returns `type: :invalid_output`."

- [ ] **Step 7: Gate and commit**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean; 0 failures. Tests elsewhere that stubbed an HTTP error and expected a blank response must be updated to the error (they encoded the bug).

```bash
git add lib/normandy/llm/claudio_adapter.ex lib/normandy/llm/json_deserializer.ex MIGRATING-2.0.md \
  test/llm/claudio_adapter_errors_test.exs test/llm/claudio_adapter_test.exs
git commit -F - <<'EOF'
fix(llm)!: ClaudioAdapter returns classified LLMErrors instead of empty replies

API and transport failures used to be logged with IO.warn and returned as the
caller's blank response model, so retry and the circuit breaker never fired
and the Summarizer wiped history. converse/7 and stream_converse/7 now return
{:error, %Normandy.LLMError{}} with type and retryable? from the API error
type (or HTTP status for Claudio's generic :api_error). on_parse_failure:
:error returns type :invalid_output at the top level instead of nesting the
error inside the {response, usage, meta} triple.

BREAKING CHANGE: a failed Claude call raises Normandy.LLMError from run/2
instead of returning an empty response.
EOF
```

---

### Task 5: `OpenAICompatibleAdapter` returns classified errors

**Files:**
- Modify: `lib/normandy/llm/openai_compatible_adapter.ex` — the two error branches of `converse/7` (`{:ok, %Req.Response{status: status, body: resp_body}} ->` non-2xx, and `{:error, error} ->`), new public `@doc false` `__to_llm_error__/1` and `__to_llm_error__/2` on the outer module, moduledoc
- Test: `test/llm/openai_compatible_adapter_test.exs` (add)

**Interfaces:**
- Consumes: `Normandy.LLMError.new/1`, `wrap/1` (Task 1)
- Produces: `OpenAICompatibleAdapter.__to_llm_error__(status :: integer, body :: term) :: LLMError.t()`, `__to_llm_error__(term) :: LLMError.t()`; `Model.converse/7` for `%OpenAICompatibleAdapter{}` returns `{:error, %LLMError{}}` on failure

Classification (spec §2): 429 → `:rate_limit`/true; 408 and 500..599 → `:server`/true; 401 → `:authentication`/false; 403 → `:permission`/false; 404 → `:not_found`/false; other 4xx → `:invalid_request`/false; any other status → `:unknown`/false; `%Req.TransportError{}`/`%Mint.TransportError{}`/`%Mint.HTTPError{}` → `:transport`/true; anything else → `LLMError.wrap/1`. Detail: `body["error"]["message"]` when it is a binary, else `"HTTP <status>"`.

- [ ] **Step 1: Write the failing tests**

Add to `test/llm/openai_compatible_adapter_test.exs` (inside the module; `Adapter`, `Model`, `Message` are already aliased there):

```elixir
  describe "converse/7 failures" do
    @key "sk-openai-test-canary"

    defp failing_client(adapter_fn) do
      %Adapter{
        api_key: @key,
        base_url: "https://example.test/v1",
        options: %{req_options: [adapter: adapter_fn, retry: false]}
      }
    end

    defp call(client) do
      Model.converse(
        client,
        "gpt-4o",
        nil,
        1024,
        [%Message{role: "user", content: "hi"}],
        %Normandy.Agents.BaseAgentOutputSchema{},
        []
      )
    end

    for {status, type, retryable?} <- [
          {401, :authentication, false},
          {403, :permission, false},
          {404, :not_found, false},
          {422, :invalid_request, false},
          {429, :rate_limit, true},
          {408, :server, true},
          {500, :server, true},
          {503, :server, true}
        ] do
      test "HTTP #{status} -> #{type}, retryable?: #{retryable?}" do
        adapter_fn = fn request ->
          {request,
           Req.Response.new(
             status: unquote(status),
             body: %{"error" => %{"message" => "provider says no"}}
           )}
        end

        assert {:error, %Normandy.LLMError{} = e} = call(failing_client(adapter_fn))
        assert e.type == unquote(type)
        assert e.status == unquote(status)
        assert e.retryable? == unquote(retryable?)
        assert e.message =~ "provider says no"
        refute inspect(e) =~ @key
      end
    end

    test "a body without an error message falls back to HTTP <status>" do
      adapter_fn = fn request -> {request, Req.Response.new(status: 502, body: "")} end

      assert {:error, %Normandy.LLMError{message: "LLM call failed: server (502): HTTP 502"}} =
               call(failing_client(adapter_fn))
    end

    test "a transport error -> :transport, retryable" do
      adapter_fn = fn request -> {request, %Req.TransportError{reason: :timeout}} end

      assert {:error, %Normandy.LLMError{type: :transport, retryable?: true, status: nil}} =
               call(failing_client(adapter_fn))
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix format && mix test test/llm/openai_compatible_adapter_test.exs`
Expected: FAIL — `converse` returns `{response_model, nil}` after `IO.warn`.

- [ ] **Step 3: Implement**

On the outer `Normandy.LLM.OpenAICompatibleAdapter` module add `alias Normandy.LLMError` and:

```elixir
  @doc false
  # Classifies a non-2xx chat-completions response (spec §2).
  @spec __to_llm_error__(integer(), term()) :: LLMError.t()
  def __to_llm_error__(status, body) when is_integer(status) do
    {type, retryable?} = classify_status(status)

    LLMError.new(
      type: type,
      status: status,
      retryable?: retryable?,
      detail: error_detail(body, status),
      reason: body
    )
  end

  @doc false
  @spec __to_llm_error__(term()) :: LLMError.t()
  def __to_llm_error__(%module{} = e)
      when module in [Req.TransportError, Mint.TransportError, Mint.HTTPError] do
    LLMError.new(type: :transport, retryable?: true, detail: Exception.message(e), reason: e)
  end

  def __to_llm_error__(other), do: LLMError.wrap(other)

  defp classify_status(429), do: {:rate_limit, true}
  defp classify_status(408), do: {:server, true}
  defp classify_status(status) when status in 500..599, do: {:server, true}
  defp classify_status(401), do: {:authentication, false}
  defp classify_status(403), do: {:permission, false}
  defp classify_status(404), do: {:not_found, false}
  defp classify_status(status) when status in 400..499, do: {:invalid_request, false}
  defp classify_status(_status), do: {:unknown, false}

  defp error_detail(%{"error" => %{"message" => message}}, _status) when is_binary(message),
    do: message

  defp error_detail(_body, status), do: "HTTP #{status}"
```

In `converse/7`, replace the two error branches:

```elixir
        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, A.__to_llm_error__(status, resp_body)}

        {:error, error} ->
          {:error, A.__to_llm_error__(error)}
```

(`A` is the alias the `defimpl` already uses for the outer module — check the file; use whatever alias it uses for `A.build_body/4`.)

- [ ] **Step 4: Run the tests**

Run: `mix format && mix test test/llm/openai_compatible_adapter_test.exs`
Expected: PASS.

- [ ] **Step 5: Docs**

`OpenAICompatibleAdapter` moduledoc: add a short "Errors" paragraph — `converse/7` returns `{:error, %Normandy.LLMError{}}` on a non-2xx response or transport failure, with the status table above.

- [ ] **Step 6: Gate and commit**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean; 0 failures.

```bash
git add lib/normandy/llm/openai_compatible_adapter.ex test/llm/openai_compatible_adapter_test.exs
git commit -F - <<'EOF'
fix(llm)!: OpenAI-compatible adapter returns classified LLMErrors

Non-2xx responses and transport failures used to be logged with IO.warn and
returned as {response_model, nil}. They now return {:error, %Normandy.LLMError{}}
classified by HTTP status (429/408/5xx/transport retryable; other 4xx not).

BREAKING CHANGE: a failed OpenAI-compatible call raises Normandy.LLMError from
run/2 instead of returning an empty response.
EOF
```

---

### Task 6: Streaming errors raise

**Files:**
- Modify: `lib/normandy/components/stream_processor.ex` — new public `stream_error/1`
- Modify: `lib/normandy/agents/base_agent.ex`:
  - `stream_response_from_llm/3` (search `defp stream_response_from_llm`): the accumulate branch (`events = Enum.to_list(stream)`), the `{:error, _} = error -> error` branch, and the `{:error, "Client does not support streaming"}` return
  - `consume_stream_with_incremental_guards/3`: check for a stream error before building the final message
  - `run_stream_turn/3`: the `catch {:stream_turn_error, ...}` clause
  - `stream_response/3` and `stream_with_tools/3` `@doc` ("Returns" / new "Raises")
- Modify: `MIGRATING-2.0.md` — section 11
- Test: `test/components/stream_processor_test.exs` (add), `test/agents/base_agent_stream_errors_test.exs` (create), `test/agents/base_agent_streaming_test.exs` (update "handles streaming errors gracefully")

**Interfaces:**
- Consumes: `Normandy.LLMError.new/1`, `wrap/1` (Task 1); `ClaudioAdapter.stream_converse/7` returns `{:error, %LLMError{}}` at connect (Task 4)
- Produces: `StreamProcessor.stream_error([term]) :: Normandy.LLMError.t() | nil`; `BaseAgent.stream_response/3` and `stream_with_tools/3` raise `Normandy.LLMError` on a failed stream. `call_stream_llm` still `throw`s `{:stream_turn_error, error, config}` internally (test/agents/base_agent_task_budget_test.exs relies on `catch_throw`); only `run_stream_turn/3` raises.

- [ ] **Step 1: Write the failing `stream_error/1` tests**

Add to `test/components/stream_processor_test.exs` (alias `Normandy.Components.StreamProcessor` is already there or add it):

```elixir
  describe "stream_error/1" do
    @complete [
      %{type: "message_start", message: %{"id" => "m"}},
      %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => "hi"}, index: 0},
      %{type: "message_stop"}
    ]

    test "nil for a complete stream" do
      assert StreamProcessor.stream_error(@complete) == nil
    end

    test "an error event becomes a :stream LLMError carrying the API message" do
      events = [
        %{type: "message_start", message: %{}},
        %{type: "error", error: %{"type" => "overloaded_error", "message" => "Overloaded"}}
      ]

      assert %Normandy.LLMError{type: :stream, retryable?: false, message: message, reason: reason} =
               StreamProcessor.stream_error(events)

      assert message == "LLM call failed: stream: Overloaded"
      assert reason == %{"type" => "overloaded_error", "message" => "Overloaded"}
    end

    test "an {:error, reason} item becomes a :stream LLMError" do
      assert %Normandy.LLMError{type: :stream, reason: :closed} =
               StreamProcessor.stream_error([%{type: "message_start", message: %{}}, {:error, :closed}])
    end

    test "a stream that ends without message_stop is an error" do
      assert %Normandy.LLMError{type: :stream, message: "LLM call failed: stream: stream ended before message_stop"} =
               StreamProcessor.stream_error(Enum.drop(@complete, -1))
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix format && mix test test/components/stream_processor_test.exs`
Expected: FAIL — `StreamProcessor.stream_error/1 is undefined`.

- [ ] **Step 3: Implement `stream_error/1`**

In `lib/normandy/components/stream_processor.ex` add `alias Normandy.LLMError` and:

```elixir
  @doc """
  Returns the failure a collected stream carries, or `nil` for a complete stream.

  A stream fails when it contains an `error` event (e.g. a mid-stream `overloaded_error`),
  an `{:error, reason}` item (a transport failure after the stream started), or ends
  without a `message_stop` event. The result is a `Normandy.LLMError` with `type: :stream`,
  `retryable?: false` (callbacks have already received partial output).
  """
  @spec stream_error([term()]) :: LLMError.t() | nil
  def stream_error(events) when is_list(events) do
    case Enum.find_value(events, &event_error/1) do
      %LLMError{} = error ->
        error

      nil ->
        if Enum.any?(events, &message_stop?/1),
          do: nil,
          else: stream_failure("stream ended before message_stop", nil)
    end
  end

  defp event_error(%{type: "error", error: error}),
    do: stream_failure(error_event_detail(error), error)

  defp event_error({:error, reason}), do: stream_failure("stream transport error", reason)
  defp event_error(_event), do: nil

  defp error_event_detail(%{"message" => message}) when is_binary(message), do: message
  defp error_event_detail(%{message: message}) when is_binary(message), do: message
  defp error_event_detail(_error), do: "error event in stream"

  defp message_stop?(%{type: "message_stop"}), do: true
  defp message_stop?(%StreamEvent{type: :message_stop}), do: true
  defp message_stop?(_event), do: false

  defp stream_failure(detail, reason),
    do: LLMError.new(type: :stream, retryable?: false, detail: detail, reason: reason)
```

Check `StreamEvent`'s type for message stop (`grep -n "message_stop" lib/normandy/components/stream_event.ex`); if `StreamEvent` has no `:message_stop` type, drop that clause.

- [ ] **Step 4: Run the `stream_error/1` tests**

Run: `mix format && mix test test/components/stream_processor_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing `BaseAgent` streaming tests**

Create `test/agents/base_agent_stream_errors_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentStreamErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings
  alias Normandy.LLMError

  # stream_converse/7 returns {:ok, events} (a list is Enumerable) or {:error, reason}.
  defmodule EventsClient do
    defstruct events: [], connect_error: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentStreamErrorsTest.EventsClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model
    def converse(_c, _m, _t, _mt, _msgs, response_model, _opts), do: response_model

    def stream_converse(%{connect_error: nil} = client, _m, _t, _mt, _msgs, _rm, _opts),
      do: {:ok, client.events}

    def stream_converse(client, _m, _t, _mt, _msgs, _rm, _opts), do: {:error, client.connect_error}
  end

  defp start, do: %{type: "message_start", message: %{"id" => "m", "role" => "assistant"}}
  defp block, do: %{type: "content_block_start", content_block: %{"type" => "text", "text" => ""}, index: 0}

  defp delta(text),
    do: %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}, index: 0}

  defp error_event,
    do: %{type: "error", error: %{"type" => "overloaded_error", "message" => "Overloaded"}}

  defp agent(events, extra \\ %{}) do
    BaseAgent.init(
      Map.merge(
        %{client: %EventsClient{events: events}, model: "claude-opus-5-5", temperature: nil},
        extra
      )
    )
  end

  defp stream(agent), do: BaseAgent.stream_response(agent, %{chat_message: "hi"}, fn _, _ -> :ok end)

  @incremental %{
    output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
    output_guardrails_streaming_mode: :incremental,
    output_guardrails_chunk_size: 5
  }

  test "a mid-stream error event raises" do
    agent = agent([start(), block(), delta("Hel"), error_event()])

    assert_raise LLMError, "LLM call failed: stream: Overloaded", fn -> stream(agent) end
  end

  test "an {:error, _} item in the stream raises" do
    agent = agent([start(), block(), delta("Hel"), {:error, :closed}])

    assert %LLMError{type: :stream, reason: :closed} =
             assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "a stream that ends without message_stop raises" do
    agent = agent([start(), block(), delta("Hel")])

    assert_raise LLMError, ~r/stream ended before message_stop/, fn -> stream(agent) end
  end

  test "a connection-time error raises it" do
    e = LLMError.new(type: :rate_limit, status: 429, retryable?: true)

    agent =
      BaseAgent.init(%{
        client: %EventsClient{connect_error: e},
        model: "claude-opus-5-5",
        temperature: nil
      })

    assert ^e = assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "incremental guardrails: a mid-stream error event raises (not a guardrail halt)" do
    agent = agent([start(), block(), delta("Hello there"), error_event()], @incremental)

    assert_raise LLMError, ~r/Overloaded/, fn -> stream(agent) end
  end

  test "incremental guardrails: an {:error, _} item raises" do
    agent = agent([start(), block(), delta("Hello there"), {:error, :closed}], @incremental)

    assert_raise LLMError, fn -> stream(agent) end
  end

  test "incremental guardrails: a violation halt is not an error" do
    agent =
      agent([start(), block(), delta("this has a badword in it"), delta(" more")], @incremental)

    {_agent, response} = stream(agent)
    assert response.guardrail_violations != []
  end
end
```

Update `test/agents/base_agent_streaming_test.exs`, test "handles streaming errors gracefully": rename it to `"a failed stream_converse raises LLMError"` and replace its last three lines with:

```elixir
      assert_raise Normandy.LLMError, fn ->
        BaseAgent.stream_response(config, user_input, callback)
      end
```

- [ ] **Step 6: Run to verify they fail**

Run: `mix format && mix test test/agents/base_agent_stream_errors_test.exs test/agents/base_agent_streaming_test.exs`
Expected: FAIL — streams with errors return `{config, response}` (partial text) or `{config, %{error: _}}` instead of raising. The "violation halt is not an error" test passes on first run (it pins existing behaviour) — note that.

- [ ] **Step 7: Implement**

In `lib/normandy/agents/base_agent.ex` (`LLMError` alias added in Task 2):

1. `stream_response_from_llm/3`, the accumulate branch:

```elixir
            _ ->
              events = Enum.to_list(stream)

              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              case StreamProcessor.stream_error(events) do
                nil -> {:ok, StreamProcessor.build_final_message(events)}
                %LLMError{} = error -> {:error, error}
              end
```

2. Same function, connection error and unsupported client:

```elixir
        {:error, reason} ->
          {:error, LLMError.wrap(reason)}
```

```elixir
      {:error,
       LLMError.new(
         type: :unknown,
         retryable?: false,
         detail: "client does not implement stream_converse/7"
       )}
```

3. `consume_stream_with_incremental_guards/3`: after `events = Enum.reverse(final_acc.events)`, return early on a stream failure unless the stream was halted by a guardrail violation (a deliberate stop, which has no `message_stop`):

```elixir
    events = Enum.reverse(final_acc.events)

    case final_acc.violations == [] and StreamProcessor.stream_error(events) do
      %LLMError{} = error ->
        {:error, error}

      _no_error_or_halted ->
        build_incremental_final_message(events, final_acc)
    end
  end
```

Move the existing code that follows `events = ...` (building `final_message`, the `case final_acc.violations do` block, and the final `{:ok, final_message}`) into a new private `build_incremental_final_message(events, final_acc)` returning `{:ok, final_message}` unchanged. Update the function's comment: it now returns `{:ok, final_message}` or `{:error, %LLMError{}}`.

4. `run_stream_turn/3`'s catch clause:

```elixir
    catch
      {:stream_turn_error, error, _config_at_failure} ->
        raise LLMError.wrap(error)
    end
```

(`call_stream_llm` keeps throwing; do not change it.)

- [ ] **Step 8: Run the tests**

Run: `mix format && mix test test/agents/base_agent_stream_errors_test.exs test/agents/base_agent_streaming_test.exs test/agents/base_agent_streaming_guardrails_test.exs test/agents/base_agent_task_budget_test.exs test/agents/base_agent_run_span_test.exs test/components/stream_processor_test.exs`
Expected: PASS. A streaming test elsewhere whose mock omits `message_stop` will now raise; add `%{type: "message_stop"}` to that mock's events (a real stream always ends with one), never weaken the check.

- [ ] **Step 9: Docs**

- `stream_response/3` `@doc`: keep "## Returns `{config, final_response}`" and add "## Raises `Normandy.LLMError` when the stream fails to start, carries an `error` event or `{:error, _}` item, or ends without `message_stop`. Streams are not retried." Same addition on `stream_with_tools/3`.
- `MIGRATING-2.0.md` section 11: add "`stream_response/3` and `stream_with_tools/3` raise `Normandy.LLMError` when the stream fails. They used to return `{config, %{error: reason}}`. A stream that ends without `message_stop` is now a failure, not a complete message."

- [ ] **Step 10: Full gate and commit**

Run:
```bash
mix format && mix compile --warnings-as-errors && mix credo --strict && mix test
MIX_ENV=test mix dialyzer
mix test.postgres
mix test.redis
```
Expected: compile clean; credo no issues; Dialyzer `done (passed successfully)` with 0 unnecessary skips; all three test runs 0 failures. (Postgres and Redis must be reachable: `docker ps` shows `normandy-test-postgres` and `normandy-test-redis`; start them as in the CI jobs if not.)

```bash
git add lib/normandy/components/stream_processor.ex lib/normandy/agents/base_agent.ex MIGRATING-2.0.md \
  test/components/stream_processor_test.exs test/agents/base_agent_stream_errors_test.exs \
  test/agents/base_agent_streaming_test.exs
git commit -F - <<'EOF'
feat(agents)!: streaming raises Normandy.LLMError on a failed stream

StreamProcessor.stream_error/1 detects an error event, an {:error, _} item, or
a stream that ends without message_stop; both stream consumers check it (an
incremental-guardrail halt is not an error). run_stream_turn/3 raises instead
of IO.warn plus {config, %{error: reason}}.

BREAKING CHANGE: stream_response/3 and stream_with_tools/3 raise
Normandy.LLMError instead of returning {config, %{error: reason}}.
EOF
```
