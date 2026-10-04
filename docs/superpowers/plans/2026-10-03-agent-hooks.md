# Agent Lifecycle Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistable `Normandy.Behaviours.Hooks` behaviour — an ordered list of `{module, opts}` entries on `Behaviours.Config` — whose callbacks run at eight lifecycle points and can rewrite, halt, inject or audit.

**Architecture:** One `Normandy.Hooks.Runner` owns calling hook modules (order, rewrite threading, halts, `:on_error`, logged-only events, return contracts, telemetry). Call sites are the shared functions every shell already goes through: `Config.to_pipeline/1` (tool hooks, by prepending adapter funs to the existing hook lists, so `Dispatch` is unchanged), `BaseAgent.admit_turn_input/2`, `call_turn_llm`/`call_stream_llm`, `compact_turn_memory/3`, `with_agent_run_span/3`, plus `Turn.Server`-only sites. The pure `Turn` core and `Turn.Inline` do not change.

**Tech Stack:** Elixir, ExUnit, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-10-03-agent-hooks-design.md`

## Global Constraints

- Events, exactly: `on_session_start/2`, `on_passivate/2`, `on_prompt/3`, `before_llm/3`, `before_tool/3`, `after_tool/4`, `after_compact/4`, `on_turn_end/3`; plus optional `validate_opts!/1`. All optional.
- `Behaviours.Config.hooks` defaults to `[]`; an agent with no hooks behaves byte-identically to today.
- `:on_error` is `:reraise` (default) | `:open` | `:closed`; it is removed from opts before a callback sees them.
- Logged-only events: `on_passivate`, `on_turn_end` (a crash is logged and emitted, never re-raised). Haltable events: `on_prompt`, `before_llm`, `before_tool`.
- A return value outside the callback's spec raises `ArgumentError` regardless of `:on_error`.
- `BaseAgent` raises `%Normandy.HookHaltError{event, hook, reason}`; `Turn.Server` replies `{:error, {:hook_halted, event, reason}}`.
- Telemetry span `[:normandy, :hook, :start | :stop | :exception]`; stop `result` ∈ `:cont | :rewrite | :halt | :inject | :ok | :rescued`.
- Module hooks run before the existing `before_hooks`/`after_hooks` functions; a module halt skips the functions.
- `after_compact` injections are memory-only; `on_session_start` injections are written to the session store.
- `Turn.Inline` runs no hooks.
- Repo rules: run `mix format` before tests; run `mix precommit` before every commit and commit only when its output contains ` 0 failures` (never chain a commit after `mix precommit | tail`); `git add` files individually, never `git add .`; commit messages carry no AI attribution (no Co-Authored-By, no "Generated with"); never run `mix e2e`; leave `investigations/genai-telemetry-audit.md` untracked and untouched.
- Line numbers below are as of commit `b241330`; locate code by the quoted function names if they moved.

## Review Focus

1. A hook that rewrites `on_prompt` input into a value the input schema rejects — expect a `Normandy.Schema.ValidationError`, never an unvalidated input in memory (test in Task 4).
2. Hook opts holding a pid or function on an agent whose config is saved as a template — expect `ConfigTemplate.from_config/2` to raise naming the value, not a template that fails on rebuild (test in Task 3).
3. A compactor that rebuilds memory with new entry ids (keeping some messages) — expect `dropped` to hold only the messages that are really gone, matched by role and content (test in Task 5).
4. Two module hooks where the first halts `before_tool` — expect the second module and the function `before_hooks` not to run, and one `[:normandy, :tool, :denied]` event (test in Task 3).
5. Approval expiry with `on_approval_timeout: :fail` — expect the expired results to pass through `after_tool` before the turn fails (test in Task 7).

---

### Task 1: Behaviour, context, halt error, entry validation

**Files:**
- Create: `lib/normandy/behaviours/hooks.ex`
- Create: `lib/normandy/hooks/context.ex`
- Modify: `lib/normandy/exceptions.ex` (append `Normandy.HookHaltError`)
- Test: `test/behaviours/hooks_test.exs`, `test/hooks/context_test.exs`

**Interfaces:**
- Produces:
  - `Normandy.Behaviours.Hooks.events() :: [{atom(), arity}]` — the eight event callbacks.
  - `Normandy.Behaviours.Hooks.validate_entries!(entries, opts \\ []) :: :ok` — raises `ArgumentError`; `opts[:load]` (default `true`) `false` skips module loading/export/`validate_opts!` checks (DSL compile time).
  - `Normandy.Hooks.Context.build(config, opts \\ []) :: %Context{}` — `opts[:turn_id]` overrides (pass `turn_id: nil` to force nil).
  - `%Normandy.HookHaltError{event: atom(), hook: module(), reason: String.t()}`.

- [ ] **Step 1: Write the failing tests**

`test/behaviours/hooks_test.exs`:

```elixir
defmodule Normandy.Behaviours.HooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Hooks

  defmodule OnlyTurnEnd do
    @behaviour Normandy.Behaviours.Hooks
    @impl true
    def on_turn_end(_outcome, _ctx, _opts), do: :ok
  end

  defmodule NoCallbacks do
    def unrelated, do: :ok
  end

  defmodule ChecksOpts do
    @behaviour Normandy.Behaviours.Hooks
    @impl true
    def on_turn_end(_outcome, _ctx, _opts), do: :ok
    @impl true
    def validate_opts!(opts) do
      if Keyword.has_key?(opts, :on_error), do: raise("on_error leaked into validate_opts!")
      unless is_binary(opts[:label]), do: raise(ArgumentError, "label must be a string")
      :ok
    end
  end

  test "events/0 lists the eight event callbacks" do
    assert Hooks.events() == [
             on_session_start: 2,
             on_passivate: 2,
             on_prompt: 3,
             before_llm: 3,
             before_tool: 3,
             after_tool: 4,
             after_compact: 4,
             on_turn_end: 3
           ]
  end

  test "accepts an empty list and well-formed entries" do
    assert :ok = Hooks.validate_entries!([])
    assert :ok = Hooks.validate_entries!([{OnlyTurnEnd, []}, {OnlyTurnEnd, on_error: :open}])
  end

  test "rejects a non-list" do
    assert_raise ArgumentError, ~r/hooks must be a list of \{module, opts\} entries, got: :nope/, fn ->
      Hooks.validate_entries!(:nope)
    end
  end

  test "rejects an entry that is not {module, keyword}" do
    assert_raise ArgumentError, ~r/invalid hook entry OnlyTurnEnd/, fn ->
      Hooks.validate_entries!([OnlyTurnEnd])
    end

    assert_raise ArgumentError, ~r/invalid hook entry/, fn ->
      Hooks.validate_entries!([{OnlyTurnEnd, %{}}])
    end
  end

  test "rejects a module that is not available" do
    assert_raise ArgumentError, ~r/hook module Does.Not.Exist is not available/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, []}])
    end
  end

  test "rejects a module that exports no hook callback" do
    assert_raise ArgumentError, ~r/exports none of the hook callbacks/, fn ->
      Hooks.validate_entries!([{NoCallbacks, []}])
    end
  end

  test "rejects an unknown :on_error" do
    assert_raise ArgumentError,
                 ~r/invalid :on_error for .*OnlyTurnEnd: expected :reraise, :open or :closed, got: :maybe/,
                 fn -> Hooks.validate_entries!([{OnlyTurnEnd, on_error: :maybe}]) end
  end

  test "runs validate_opts!/1 without :on_error" do
    assert :ok = Hooks.validate_entries!([{ChecksOpts, label: "x", on_error: :open}])

    assert_raise ArgumentError, ~r/label must be a string/, fn ->
      Hooks.validate_entries!([{ChecksOpts, []}])
    end
  end

  test "load: false checks shape and :on_error only" do
    assert :ok = Hooks.validate_entries!([{Does.Not.Exist, []}], load: false)

    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, on_error: :x}], load: false)
    end
  end
end
```

`test/hooks/context_test.exs`:

```elixir
defmodule Normandy.Hooks.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context

  test "builds from a config and keeps the config" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()

    config = %{
      name: "a",
      session_id: "s",
      memory: memory,
      tool_context: %{user: 1}
    }

    ctx = Context.build(config)

    assert %Context{agent_name: "a", session_id: "s", values: %{user: 1}, config: ^config} = ctx
    assert ctx.turn_id == memory.current_turn_id
    refute is_nil(ctx.turn_id)
  end

  test "turn_id: nil forces no turn id; missing fields default" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    assert %Context{turn_id: nil} = Context.build(%{memory: memory}, turn_id: nil)
    assert %Context{values: %{}, session_id: nil, agent_name: nil} = Context.build(%{})
  end
end
```

Also append to an existing exceptions test file, or create `test/hooks/hook_halt_error_test.exs`:

```elixir
defmodule Normandy.HookHaltErrorTest do
  use ExUnit.Case, async: true

  test "message names the event, hook and reason" do
    e = %Normandy.HookHaltError{event: :on_prompt, hook: MyApp.Redact, reason: "contains SSN"}
    assert Exception.message(e) == "hook MyApp.Redact halted on_prompt: contains SSN"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/behaviours/hooks_test.exs test/hooks/context_test.exs test/hooks/hook_halt_error_test.exs`
Expected: FAIL — `Normandy.Behaviours.Hooks` / `Normandy.Hooks.Context` / `Normandy.HookHaltError` undefined.

- [ ] **Step 3: Implement**

`lib/normandy/behaviours/hooks.ex`:

```elixir
defmodule Normandy.Behaviours.Hooks do
  @moduledoc """
  Lifecycle hooks: modules an agent lists on `Normandy.Behaviours.Config` `:hooks` as
  `{module, opts}` entries, run in list order by `Normandy.Hooks.Runner`.

  Every callback is optional; an entry whose module does not export an event's callback is
  skipped for that event. A hook exists where it can change an outcome (rewrite, halt,
  inject) or must run application code in-process; to only observe, attach to telemetry.

  `opts` must be plain data: the list is saved in the session's config template.
  `:on_error` (`:reraise` default, `:open`, `:closed`) is reserved and removed before a
  callback sees `opts`. See `docs/guides/hooks.md`.
  """

  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Context

  @type opts :: keyword()
  @type entry :: {module(), opts()}
  @type outcome ::
          {:ok, response :: term()} | {:error, reason :: term()} | {:rejected, Exception.t()}

  @callback on_session_start(Context.t(), opts()) :: :ok | {:inject, [String.t()]}
  @callback on_passivate(Context.t(), opts()) :: :ok
  @callback on_prompt(input :: term(), Context.t(), opts()) ::
              {:cont, term()} | {:halt, reason :: String.t()}
  @callback before_llm(%{final: boolean(), iterations_left: integer()}, Context.t(), opts()) ::
              :cont | {:halt, reason :: String.t()}
  @callback before_tool(ToolCall.t(), Context.t(), opts()) ::
              {:cont, ToolCall.t()} | {:halt, ToolResult.t()}
  @callback after_tool(ToolCall.t(), ToolResult.t(), Context.t(), opts()) ::
              {:cont, ToolResult.t()}
  @callback after_compact(dropped :: [Message.t()], meta :: map(), Context.t(), opts()) ::
              :ok | {:inject, [String.t()]}
  @callback on_turn_end(outcome(), Context.t(), opts()) :: :ok
  @callback validate_opts!(opts()) :: :ok

  @optional_callbacks on_session_start: 2,
                      on_passivate: 2,
                      on_prompt: 3,
                      before_llm: 3,
                      before_tool: 3,
                      after_tool: 4,
                      after_compact: 4,
                      on_turn_end: 3,
                      validate_opts!: 1

  @events [
    on_session_start: 2,
    on_passivate: 2,
    on_prompt: 3,
    before_llm: 3,
    before_tool: 3,
    after_tool: 4,
    after_compact: 4,
    on_turn_end: 3
  ]

  @on_error [:reraise, :open, :closed]

  @doc "The event callbacks, as `{name, arity}`."
  @spec events() :: [{atom(), non_neg_integer()}]
  def events, do: @events

  @doc """
  Raises `ArgumentError` naming the first malformed entry. With `load: false` (DSL compile
  time, when the hook module may not be compiled yet) only the entry shape and `:on_error`
  are checked.
  """
  @spec validate_entries!(term(), keyword()) :: :ok
  def validate_entries!(entries, opts \\ [])

  def validate_entries!(entries, opts) when is_list(entries) do
    load? = Keyword.get(opts, :load, true)
    Enum.each(entries, &validate_entry!(&1, load?))
  end

  def validate_entries!(other, _opts) do
    raise ArgumentError,
          "hooks must be a list of {module, opts} entries, got: #{inspect(other)}"
  end

  defp validate_entry!({mod, opts} = entry, load?) when is_atom(mod) and is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_entry!(entry)

    case Keyword.get(opts, :on_error, :reraise) do
      policy when policy in @on_error ->
        :ok

      other ->
        raise ArgumentError,
              "invalid :on_error for #{inspect(mod)}: expected :reraise, :open or :closed, " <>
                "got: #{inspect(other)}"
    end

    if load?, do: validate_module!(mod, Keyword.delete(opts, :on_error))
    :ok
  end

  defp validate_entry!(entry, _load?), do: invalid_entry!(entry)

  defp invalid_entry!(entry) do
    raise ArgumentError,
          "invalid hook entry #{inspect(entry)}: expected {module, keyword_opts}"
  end

  defp validate_module!(mod, opts) do
    unless Code.ensure_loaded?(mod) do
      raise ArgumentError, "hook module #{inspect(mod)} is not available"
    end

    unless Enum.any?(@events, fn {fun, arity} -> function_exported?(mod, fun, arity) end) do
      raise ArgumentError,
            "hook module #{inspect(mod)} exports none of the hook callbacks " <>
              "#{Enum.map_join(@events, ", ", fn {f, a} -> "#{f}/#{a}" end)}"
    end

    if function_exported?(mod, :validate_opts!, 1), do: mod.validate_opts!(opts)
    :ok
  end
end
```

`lib/normandy/hooks/context.ex`:

```elixir
defmodule Normandy.Hooks.Context do
  @moduledoc """
  What a hook callback knows about the agent it runs for. `values` is the agent's
  `tool_context`; `config` is the agent's config, read-only (no return value can change
  it). `turn_id` is `nil` for `on_session_start`, `on_passivate` and `on_prompt`.
  """

  defstruct [:agent_name, :session_id, :turn_id, :config, values: %{}]

  @type t :: %__MODULE__{
          agent_name: String.t() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          config: map() | nil,
          values: map()
        }

  @doc "Builds the context from `config`; `turn_id:` in `opts` overrides the memory's."
  @spec build(map(), keyword()) :: t()
  def build(config, opts \\ []) do
    memory = Map.get(config, :memory)

    %__MODULE__{
      agent_name: Map.get(config, :name),
      session_id: Map.get(config, :session_id),
      turn_id: Keyword.get(opts, :turn_id, memory && Map.get(memory, :current_turn_id)),
      config: config,
      values: Map.get(config, :tool_context) || %{}
    }
  end
end
```

Append to `lib/normandy/exceptions.ex`:

```elixir

defmodule Normandy.HookHaltError do
  @moduledoc """
  Raised by `Normandy.Agents.BaseAgent` when an `on_prompt` or `before_llm` hook halts the
  turn. `Turn.Server` replies `{:error, {:hook_halted, event, reason}}` instead.
  """
  defexception [:event, :hook, :reason]

  @impl true
  def message(%__MODULE__{event: event, hook: hook, reason: reason}) do
    "hook #{inspect(hook)} halted #{event}: #{reason}"
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/behaviours/hooks_test.exs test/hooks/context_test.exs test/hooks/hook_halt_error_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures` (credo or dialyzer findings must be fixed first).

```bash
git add lib/normandy/behaviours/hooks.ex lib/normandy/hooks/context.ex lib/normandy/exceptions.ex test/behaviours/hooks_test.exs test/hooks/context_test.exs test/hooks/hook_halt_error_test.exs
git commit -m "feat(hooks): Hooks behaviour, hook context, HookHaltError, entry validation"
```

### Task 2: The Runner, test probes, telemetry catalogue

**Files:**
- Create: `lib/normandy/hooks/runner.ex`
- Create: `test/support/hook_probes.ex`
- Modify: `lib/normandy/telemetry.ex` (moduledoc: add the hook span, next to the memory command entry)
- Test: `test/hooks/runner_test.exs`

**Interfaces:**
- Consumes: `Hooks.events/0`, `Hooks.Context.build/2`, `%HookHaltError{}` (Task 1).
- Produces (every function takes the entry list first; `[]` returns the pass value with no telemetry):
  - `Runner.entries(config) :: [Hooks.entry()]` — `config.behaviours.hooks`, or `[]`.
  - `Runner.prompt(entries, config, input) :: {:cont, term()} | {:halt, module(), String.t()}`
  - `Runner.before_llm(entries, config, %{final: boolean(), iterations_left: integer()}) :: :cont | {:halt, module(), String.t()}`
  - `Runner.before_tool(entries, config, %ToolCall{}) :: {:cont, %ToolCall{}} | {:halt, %ToolResult{}}`
  - `Runner.after_tool(entries, config, %ToolCall{}, %ToolResult{}) :: %ToolResult{}`
  - `Runner.after_compact(entries, config, dropped :: [%Message{}], meta :: map()) :: [String.t()]`
  - `Runner.session_start(entries, config) :: [String.t()]`
  - `Runner.passivate(entries, config) :: :ok`
  - `Runner.turn_end(entries, config, outcome, ctx_opts \\ []) :: :ok` — `ctx_opts` go to `Context.build/2` (e.g. `turn_id: nil`)
  - Test probes `Normandy.Test.Hooks.Probe` and `Normandy.Test.Hooks.TurnEndOnly` (used by Tasks 3–8).

- [ ] **Step 1: Create the test probes**

`test/support/hook_probes.ex`:

```elixir
defmodule Normandy.Test.Hooks.Probe do
  @moduledoc """
  A hook implementing every event. Each call sends
  `{:hook, tag, event, args}` to `opts[:notify]` (a pid or registered name; omitted = no
  message) and returns `opts[:returns][event]`, or passes (`{:cont, value}`, `:cont`,
  `:ok`). `returns: [on_prompt: {:raise, "boom"}]` raises a RuntimeError,
  `{:exit, reason}` exits, `{:throw, value}` throws. `tag` defaults to the module.
  """
  @behaviour Normandy.Behaviours.Hooks

  @impl true
  def on_session_start(ctx, opts), do: report(:on_session_start, [ctx], opts, :ok)
  @impl true
  def on_passivate(ctx, opts), do: report(:on_passivate, [ctx], opts, :ok)
  @impl true
  def on_prompt(input, ctx, opts), do: report(:on_prompt, [input, ctx], opts, {:cont, input})
  @impl true
  def before_llm(info, ctx, opts), do: report(:before_llm, [info, ctx], opts, :cont)
  @impl true
  def before_tool(call, ctx, opts), do: report(:before_tool, [call, ctx], opts, {:cont, call})
  @impl true
  def after_tool(call, result, ctx, opts),
    do: report(:after_tool, [call, result, ctx], opts, {:cont, result})

  @impl true
  def after_compact(dropped, meta, ctx, opts),
    do: report(:after_compact, [dropped, meta, ctx], opts, :ok)

  @impl true
  def on_turn_end(outcome, ctx, opts), do: report(:on_turn_end, [outcome, ctx], opts, :ok)

  defp report(event, args, opts, default) do
    if dest = opts[:notify],
      do: send(dest, {:hook, Keyword.get(opts, :tag, __MODULE__), event, args})

    case Keyword.fetch(Keyword.get(opts, :returns, []), event) do
      {:ok, {:raise, message}} -> raise message
      {:ok, {:exit, reason}} -> exit(reason)
      {:ok, {:throw, value}} -> throw(value)
      {:ok, ret} -> ret
      :error -> default
    end
  end
end

defmodule Normandy.Test.Hooks.TurnEndOnly do
  @moduledoc "Implements only on_turn_end; sends {:turn_end_only, outcome} to opts[:notify]."
  @behaviour Normandy.Behaviours.Hooks

  @impl true
  def on_turn_end(outcome, _ctx, opts) do
    if dest = opts[:notify], do: send(dest, {:turn_end_only, outcome})
    :ok
  end
end
```

- [ ] **Step 2: Write the failing Runner tests**

`test/hooks/runner_test.exs`:

```elixir
defmodule Normandy.Hooks.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Normandy.Behaviours.Config
  alias Normandy.Components.{Message, ToolCall, ToolResult}
  alias Normandy.Hooks.{Context, Runner}
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}
  alias Normandy.Test.TelemetryCapture

  defmodule EchoOpts do
    @moduledoc false
    @behaviour Normandy.Behaviours.Hooks
    @impl true
    def on_passivate(_ctx, opts) do
      send(opts[:notify], {:opts, opts})
      :ok
    end
  end

  defp config(name \\ "runner-agent"), do: %{name: name, session_id: "s", tool_context: %{u: 1}}
  defp probe(tag, opts \\ []), do: {Probe, [notify: self(), tag: tag] ++ opts}
  defp call, do: %ToolCall{id: "c1", name: "t", input: %{"a" => 1}}
  defp result, do: %ToolResult{tool_call_id: "c1", output: "ok", is_error: false}

  describe "entries/1" do
    test "reads behaviours.hooks, else []" do
      assert Runner.entries(%{behaviours: %Config{hooks: [{Probe, []}]}}) == [{Probe, []}]
      assert Runner.entries(%{behaviours: nil}) == []
      assert Runner.entries(%{}) == []
    end
  end

  describe "chains" do
    test "no entries passes the value through" do
      assert Runner.prompt([], config(), "hi") == {:cont, "hi"}
      assert Runner.before_llm([], config(), %{final: false, iterations_left: 3}) == :cont
      assert Runner.before_tool([], config(), call()) == {:cont, call()}
      assert Runner.after_tool([], config(), call(), result()) == result()
      assert Runner.after_compact([], config(), [], %{}) == []
      assert Runner.session_start([], config()) == []
      assert Runner.passivate([], config()) == :ok
      assert Runner.turn_end([], config(), {:ok, 1}) == :ok
    end

    test "entries run in order; a rewrite is what the next entry receives" do
      entries = [probe(:a, returns: [on_prompt: {:cont, "rewritten"}]), probe(:b)]
      assert Runner.prompt(entries, config(), "hi") == {:cont, "rewritten"}
      assert_received {:hook, :a, :on_prompt, ["hi", %Context{turn_id: nil}]}
      assert_received {:hook, :b, :on_prompt, ["rewritten", _ctx]}
    end

    test "the first halt stops the chain and names the hook" do
      entries = [probe(:a, returns: [on_prompt: {:halt, "no"}]), probe(:b)]
      assert Runner.prompt(entries, config(), "hi") == {:halt, Probe, "no"}
      refute_received {:hook, :b, _, _}

      llm = [probe(:a, returns: [before_llm: {:halt, "budget"}]), probe(:b)]
      assert Runner.before_llm(llm, config(), %{final: false, iterations_left: 1}) ==
               {:halt, Probe, "budget"}

      denied = %ToolResult{tool_call_id: "c1", output: %{error: "x"}, is_error: true}
      tool = [probe(:a, returns: [before_tool: {:halt, denied}]), probe(:b)]
      assert Runner.before_tool(tool, config(), call()) == {:halt, denied}
      refute_received {:hook, :b, :before_tool, _}
    end

    test "after_tool threads rewritten results" do
      rewritten = %{result() | output: "redacted"}
      entries = [probe(:a, returns: [after_tool: {:cont, rewritten}]), probe(:b)]
      assert Runner.after_tool(entries, config(), call(), result()) == rewritten
      assert_received {:hook, :b, :after_tool, [_call, ^rewritten, _ctx]}
    end

    test "inject results are concatenated in list order" do
      entries = [
        probe(:a, returns: [after_compact: {:inject, ["one"]}, on_session_start: {:inject, ["s1"]}]),
        probe(:b),
        probe(:c, returns: [after_compact: {:inject, ["two", "three"]}])
      ]

      dropped = [%Message{role: "user", content: "old"}]
      assert Runner.after_compact(entries, config(), dropped, %{compacted: true}) ==
               ["one", "two", "three"]

      assert_received {:hook, :b, :after_compact, [^dropped, %{compacted: true}, _]}
      assert Runner.session_start(entries, config()) == ["s1"]
    end

    test "an entry without the event's callback is skipped" do
      entries = [{TurnEndOnly, notify: self()}]
      assert Runner.prompt(entries, config(), "hi") == {:cont, "hi"}
      assert Runner.turn_end(entries, config(), {:ok, :r}) == :ok
      assert_received {:turn_end_only, {:ok, :r}}
    end

    test "the context carries config, values and agent name" do
      Runner.passivate([probe(:a, on_error: :open)], config())
      assert_received {:hook, :a, :on_passivate, [ctx]}
      assert %Context{agent_name: "runner-agent", session_id: "s", values: %{u: 1}} = ctx
      assert ctx.config == config()
    end

    test ":on_error is removed from opts before the callback sees them" do
      Runner.passivate([{EchoOpts, notify: self(), on_error: :open, label: "x"}], config())
      assert_received {:opts, opts}
      assert Enum.sort(opts) == Enum.sort(notify: self(), label: "x")
    end
  end

  describe ":on_error" do
    test ":reraise (default) propagates raise, exit and throw" do
      assert_raise RuntimeError, "boom", fn ->
        Runner.prompt([probe(:a, returns: [on_prompt: {:raise, "boom"}])], config(), "x")
      end

      assert catch_exit(
               Runner.before_llm([probe(:a, returns: [before_llm: {:exit, :down}])], config(), %{
                 final: false,
                 iterations_left: 1
               })
             ) == :down

      assert catch_throw(
               Runner.after_compact([probe(:a, returns: [after_compact: {:throw, :t}])], config(), [], %{})
             ) == :t
    end

    @tag :capture_log
    test ":open logs and passes the value unchanged to the next entry" do
      entries = [probe(:a, on_error: :open, returns: [on_prompt: {:raise, "boom"}]), probe(:b)]

      log = capture_log(fn -> assert Runner.prompt(entries, config(), "hi") == {:cont, "hi"} end)
      assert log =~ "hook Normandy.Test.Hooks.Probe on_prompt crashed"
      assert_received {:hook, :b, :on_prompt, ["hi", _]}

      assert Runner.after_compact(
               [probe(:a, on_error: :open, returns: [after_compact: {:exit, :x}])],
               config(),
               [],
               %{}
             ) == []
    end

    @tag :capture_log
    test ":closed halts a haltable event with a reason naming the hook" do
      entries = [probe(:a, on_error: :closed, returns: [on_prompt: {:raise, "boom"}])]

      assert {:halt, Probe, reason} = Runner.prompt(entries, config(), "hi")
      assert reason == "hook Normandy.Test.Hooks.Probe crashed: RuntimeError"

      tool = [probe(:a, on_error: :closed, returns: [before_tool: {:throw, :t}])]

      assert {:halt, %ToolResult{tool_call_id: "c1", is_error: true, output: %{error: msg}}} =
               Runner.before_tool(tool, config(), call())

      assert msg == "hook Normandy.Test.Hooks.Probe crashed: throw"
    end

    test ":closed on a non-haltable event re-raises" do
      entries = [probe(:a, on_error: :closed, returns: [after_tool: {:raise, "boom"}])]

      assert_raise RuntimeError, "boom", fn ->
        Runner.after_tool(entries, config(), call(), result())
      end
    end

    @tag :capture_log
    test "logged-only events never re-raise, whatever :on_error says" do
      for policy <- [:reraise, :closed] do
        entries = [probe(:a, on_error: policy, returns: [on_turn_end: {:raise, "late"}])]
        assert Runner.turn_end(entries, config(), {:ok, 1}) == :ok

        entries = [probe(:a, on_error: policy, returns: [on_passivate: {:exit, :late}])]
        assert Runner.passivate(entries, config()) == :ok
      end
    end
  end

  describe "return contract" do
    test "a value outside the spec raises ArgumentError even under :open" do
      entries = [probe(:a, on_error: :open, returns: [on_prompt: :yes])]

      assert_raise ArgumentError,
                   ~r/expected Normandy.Test.Hooks.Probe.on_prompt\/3 to return .*, got: :yes/,
                   fn -> Runner.prompt(entries, config(), "hi") end

      assert_raise ArgumentError, ~r/got: \{:inject, "not a list"\}/, fn ->
        Runner.after_compact(
          [probe(:a, returns: [after_compact: {:inject, "not a list"}])],
          config(),
          [],
          %{}
        )
      end

      assert_raise ArgumentError, fn ->
        Runner.before_tool([probe(:a, returns: [before_tool: {:halt, "string"}])], config(), call())
      end

      # A logged-only event's contract violation is a bug too; it is not swallowed.
      assert_raise ArgumentError, fn ->
        Runner.turn_end([probe(:a, returns: [on_turn_end: :done])], config(), {:ok, 1})
      end
    end
  end

  describe "telemetry" do
    test "one span per entry call with event, hook and result" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :start], [:normandy, :hook, :stop]],
        agent_name: name
      )

      entries = [probe(:a, returns: [on_prompt: {:cont, "new"}]), probe(:b)]
      Runner.prompt(entries, config(name), "hi")

      assert_received {:span, [:normandy, :hook, :start], %{event: :on_prompt, hook: Probe}}
      assert_received {:span, [:normandy, :hook, :stop], %{result: :rewrite}}
      assert_received {:span, [:normandy, :hook, :stop], %{result: :cont}}

      Runner.before_llm([probe(:a, returns: [before_llm: {:halt, "x"}])], config(name), %{
        final: true,
        iterations_left: 0
      })

      assert_received {:span, [:normandy, :hook, :stop], %{event: :before_llm, result: :halt}}

      Runner.after_compact([probe(:a, returns: [after_compact: {:inject, ["t"]}])], config(name), [], %{})
      assert_received {:span, [:normandy, :hook, :stop], %{result: :inject}}

      Runner.turn_end([probe(:a)], config(name), {:ok, 1})
      assert_received {:span, [:normandy, :hook, :stop], %{event: :on_turn_end, result: :ok}}
    end

    @tag :capture_log
    test "a rescued crash stops with result: :rescued; a re-raised one emits :exception" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :stop], [:normandy, :hook, :exception]],
        agent_name: name
      )

      Runner.turn_end([probe(:a, returns: [on_turn_end: {:raise, "x"}])], config(name), {:ok, 1})
      assert_received {:span, [:normandy, :hook, :stop], %{result: :rescued}}

      catch_error(Runner.prompt([probe(:a, returns: [on_prompt: {:raise, "x"}])], config(name), "hi"))
      assert_received {:span, [:normandy, :hook, :exception], %{event: :on_prompt}}
    end
  end
end
```

Before writing these, read `test/support/telemetry_capture.ex` to confirm `attach_span/2`'s message shape (`{:span, event, metadata}` per its moduledoc). If it differs, adapt the `assert_received` patterns, not the helper.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/hooks/runner_test.exs`
Expected: FAIL — `Normandy.Hooks.Runner` undefined.

- [ ] **Step 4: Implement the Runner**

`lib/normandy/hooks/runner.ex`:

```elixir
defmodule Normandy.Hooks.Runner do
  @moduledoc """
  The only caller of hook modules (`Normandy.Behaviours.Hooks`). Each call site makes one
  call per event with the agent's entries (`entries/1`).

  Entries run in list order; a rewrite is what the next entry receives and the first halt
  stops the chain. `:on_error` (removed from opts before the callback runs):

    * `:reraise` (default) — a raise, exit or throw propagates.
    * `:open` — logged; the entry passes the value on unchanged.
    * `:closed` — on `on_prompt`, `before_llm` and `before_tool` the entry halts with a
      reason naming the hook; elsewhere it behaves as `:reraise`.

  `on_passivate` and `on_turn_end` run after the outcome is settled: a crash there is
  logged and emitted, never re-raised. A return value outside the callback's spec raises
  `ArgumentError` whatever `:on_error` says. Each entry call is a
  `[:normandy, :hook, :start | :stop | :exception]` span.
  """

  require Logger

  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Context

  @haltable [:on_prompt, :before_llm, :before_tool]
  @logged_only [:on_passivate, :on_turn_end]
  @arity Map.new(Hooks.events())

  @doc "The agent's hook entries: `config.behaviours.hooks`, or `[]`."
  @spec entries(map()) :: [Hooks.entry()]
  def entries(%{behaviours: %{hooks: hooks}}) when is_list(hooks), do: hooks
  def entries(_config), do: []

  @spec prompt([Hooks.entry()], map(), term()) :: {:cont, term()} | {:halt, module(), String.t()}
  def prompt(entries, config, input) do
    ctx = Context.build(config, turn_id: nil)

    entries
    |> chain(:on_prompt, ctx, input, fn mod, value, opts -> mod.on_prompt(value, ctx, opts) end)
    |> string_halt()
  end

  @spec before_llm([Hooks.entry()], map(), map()) :: :cont | {:halt, module(), String.t()}
  def before_llm(entries, config, info) do
    ctx = Context.build(config)

    entries
    |> chain(:before_llm, ctx, info, fn mod, value, opts -> mod.before_llm(value, ctx, opts) end)
    |> string_halt()
    |> case do
      {:cont, _info} -> :cont
      halt -> halt
    end
  end

  @spec before_tool([Hooks.entry()], map(), ToolCall.t()) ::
          {:cont, ToolCall.t()} | {:halt, ToolResult.t()}
  def before_tool(entries, config, %ToolCall{} = call) do
    ctx = Context.build(config)

    case chain(entries, :before_tool, ctx, call, fn mod, value, opts ->
           mod.before_tool(value, ctx, opts)
         end) do
      {:cont, call} -> {:cont, call}
      {:halt, _mod, %ToolResult{} = result} -> {:halt, result}
      {:halt, _mod, {:crashed, reason}} -> {:halt, crash_result(call, reason)}
    end
  end

  @spec after_tool([Hooks.entry()], map(), ToolCall.t(), ToolResult.t()) :: ToolResult.t()
  def after_tool(entries, config, %ToolCall{} = call, %ToolResult{} = result) do
    ctx = Context.build(config)

    {:cont, result} =
      chain(entries, :after_tool, ctx, result, fn mod, value, opts ->
        mod.after_tool(call, value, ctx, opts)
      end)

    result
  end

  @spec after_compact([Hooks.entry()], map(), list(), map()) :: [String.t()]
  def after_compact(entries, config, dropped, meta) do
    ctx = Context.build(config)
    collect(entries, :after_compact, ctx, fn mod, opts -> mod.after_compact(dropped, meta, ctx, opts) end)
  end

  @spec session_start([Hooks.entry()], map()) :: [String.t()]
  def session_start(entries, config) do
    ctx = Context.build(config, turn_id: nil)
    collect(entries, :on_session_start, ctx, fn mod, opts -> mod.on_session_start(ctx, opts) end)
  end

  @spec passivate([Hooks.entry()], map()) :: :ok
  def passivate(entries, config) do
    ctx = Context.build(config, turn_id: nil)
    _ = collect(entries, :on_passivate, ctx, fn mod, opts -> mod.on_passivate(ctx, opts) end)
    :ok
  end

  @spec turn_end([Hooks.entry()], map(), Hooks.outcome(), keyword()) :: :ok
  def turn_end(entries, config, outcome, ctx_opts \\ []) do
    ctx = Context.build(config, ctx_opts)
    _ = collect(entries, :on_turn_end, ctx, fn mod, opts -> mod.on_turn_end(outcome, ctx, opts) end)
    :ok
  end

  # ── chains ──────────────────────────────────────────────────────────────────

  # Threads `value` through the entries. Returns {:cont, value} or
  # {:halt, mod, payload}; a :closed crash halts with {:crashed, reason}.
  defp chain(entries, event, ctx, value, call) do
    Enum.reduce_while(entries, {:cont, value}, fn {mod, _opts} = entry, {:cont, value} ->
      case run_entry(event, entry, ctx, &call.(mod, value, &1), &classify(event, mod, value, &1)) do
        {:cont, new} -> {:cont, {:cont, new}}
        {:halt, payload} -> {:halt, {:halt, mod, payload}}
        {:rescued, :closed, crash} -> {:halt, {:halt, mod, {:crashed, crash_reason(mod, crash)}}}
        _skip_or_open -> {:cont, {:cont, value}}
      end
    end)
  end

  # Runs every entry; returns the concatenated injections.
  defp collect(entries, event, ctx, call) do
    Enum.flat_map(entries, fn {mod, _opts} = entry ->
      case run_entry(event, entry, ctx, &call.(mod, &1), &classify(event, mod, nil, &1)) do
        {:inject, texts} -> texts
        _ok_skip_or_rescued -> []
      end
    end)
  end

  defp string_halt({:halt, mod, {:crashed, reason}}), do: {:halt, mod, reason}
  defp string_halt(other), do: other

  # Calls one entry inside its span. Returns the classified value, :skip when the module
  # does not export the callback, or {:rescued, policy, crash}.
  defp run_entry(event, {mod, opts}, ctx, invoke, classify) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, event, Map.fetch!(@arity, event)) do
      {policy, opts} = Keyword.pop(opts, :on_error, :reraise)
      policy = effective_policy(event, policy)

      meta = %{
        event: event,
        hook: mod,
        agent_name: ctx.agent_name,
        session_id: ctx.session_id,
        turn_id: ctx.turn_id
      }

      :telemetry.span([:normandy, :hook], meta, fn ->
        case guarded(policy, fn -> invoke.(opts) end) do
          {:ok, ret} ->
            {result, value} = classify.(ret)
            {value, Map.put(meta, :result, result)}

          {:crashed, crash} ->
            Logger.warning("hook #{inspect(mod)} #{event} crashed: #{describe(crash)}")
            {{:rescued, policy, crash}, Map.put(meta, :result, :rescued)}
        end
      end)
    else
      :skip
    end
  end

  defp effective_policy(event, _policy) when event in @logged_only, do: :log
  defp effective_policy(event, :closed) when event not in @haltable, do: :reraise
  defp effective_policy(_event, policy), do: policy

  defp guarded(:reraise, fun), do: {:ok, fun.()}

  defp guarded(_policy, fun) do
    {:ok, fun.()}
  rescue
    e -> {:crashed, e}
  catch
    kind, reason -> {:crashed, {kind, reason}}
  end

  # ── return contracts: {telemetry result, value} or ArgumentError ────────────

  defp classify(:on_prompt, _mod, value, {:cont, value}), do: {:cont, {:cont, value}}
  defp classify(:on_prompt, _mod, _value, {:cont, new}), do: {:rewrite, {:cont, new}}

  defp classify(event, _mod, _value, {:halt, reason})
       when event in [:on_prompt, :before_llm] and is_binary(reason),
       do: {:halt, {:halt, reason}}

  defp classify(:before_llm, _mod, value, :cont), do: {:cont, {:cont, value}}

  defp classify(:before_tool, _mod, value, {:cont, value}), do: {:cont, {:cont, value}}
  defp classify(:before_tool, _mod, _value, {:cont, %ToolCall{} = new}), do: {:rewrite, {:cont, new}}
  defp classify(:before_tool, _mod, _value, {:halt, %ToolResult{} = r}), do: {:halt, {:halt, r}}

  defp classify(:after_tool, _mod, value, {:cont, value}), do: {:cont, {:cont, value}}
  defp classify(:after_tool, _mod, _value, {:cont, %ToolResult{} = new}), do: {:rewrite, {:cont, new}}

  defp classify(event, mod, _value, {:inject, texts} = ret)
       when event in [:after_compact, :on_session_start] do
    if is_list(texts) and texts != [] and Enum.all?(texts, &is_binary/1),
      do: {:inject, {:inject, texts}},
      else: contract!(event, mod, ret)
  end

  defp classify(event, _mod, _value, :ok)
       when event in [:after_compact, :on_session_start, :on_passivate, :on_turn_end],
       do: {:ok, :ok}

  defp classify(event, mod, _value, ret), do: contract!(event, mod, ret)

  @specs %{
    on_prompt: "{:cont, input} or {:halt, reason :: String.t()}",
    before_llm: ":cont or {:halt, reason :: String.t()}",
    before_tool: "{:cont, %ToolCall{}} or {:halt, %ToolResult{}}",
    after_tool: "{:cont, %ToolResult{}}",
    after_compact: ":ok or {:inject, [String.t(), ...]}",
    on_session_start: ":ok or {:inject, [String.t(), ...]}",
    on_passivate: ":ok",
    on_turn_end: ":ok"
  }

  defp contract!(event, mod, ret) do
    raise ArgumentError,
          "expected #{inspect(mod)}.#{event}/#{Map.fetch!(@arity, event)} to return " <>
            "#{Map.fetch!(@specs, event)}, got: #{inspect(ret)}"
  end

  # ── crash descriptions (no exception message: it may carry the hook's data) ─

  defp crash_reason(mod, crash), do: "hook #{inspect(mod)} crashed: #{describe(crash)}"

  defp describe({kind, _reason}) when kind in [:exit, :throw], do: Atom.to_string(kind)
  defp describe(%module{}), do: inspect(module)

  defp crash_result(%ToolCall{id: id}, reason),
    do: %ToolResult{tool_call_id: id, output: %{error: reason}, is_error: true}
end
```

Note on `classify(:on_prompt, _mod, value, {:cont, value})`: Elixir matches the repeated `value` variable as an equality pin, which is what distinguishes `:cont` from `:rewrite`. The `:open` log line uses `describe/1` (exception module, `exit`, `throw`), not `Exception.message/1`, so a hook's data does not reach logs.

- [ ] **Step 5: Document the event in the telemetry catalogue**

In `lib/normandy/telemetry.ex`, after the `[:normandy, :memory, :command, …]` entry, add:

```markdown
  ### `[:normandy, :hook, :start | :stop | :exception]`

  One hook module call (`Normandy.Hooks.Runner`), one span per `{module, opts}` entry per
  event.

    * Start metadata: `event` (`:on_session_start | :on_passivate | :on_prompt |
      :before_llm | :before_tool | :after_tool | :after_compact | :on_turn_end`), `hook`
      (the module), `agent_name`, `session_id`, `turn_id`.
    * Stop metadata adds `result`: `:cont` (passed the value on unchanged), `:rewrite`,
      `:halt`, `:inject`, `:ok`, or `:rescued` (a crash rescued under `on_error: :open` or
      `:closed`, or on a logged-only event).
    * `:exception` fires when a crash propagates (`on_error: :reraise`) or a return value
      breaks the callback's contract.
```

Match the surrounding entries' heading level and indentation exactly; read the memory entry first.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks/runner_test.exs test/telemetry/catalogue_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/runner.ex lib/normandy/telemetry.ex test/support/hook_probes.ex test/hooks/runner_test.exs
git commit -m "feat(hooks): Runner with ordering, on_error, return contracts and telemetry"
```

### Task 3: `Config.hooks`, tool hooks, template persistence, init validation

**Files:**
- Modify: `lib/normandy/behaviours/config.ex` (struct field, type, moduledoc, `to_pipeline/1`)
- Modify: `lib/normandy/agents/config_template.ex` (`from_config/2` `behaviours_refs`, `rebuild/3`)
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1`: validate hooks next to `validate_policy_opts!`)
- Test: `test/hooks/tool_hooks_test.exs`, `test/agents/config_template_test.exs` (add tests)

**Interfaces:**
- Consumes: `Runner.before_tool/3`, `Runner.after_tool/4`, `Hooks.validate_entries!/1`, `Normandy.Test.Hooks.Probe`.
- Produces: `%Normandy.Behaviours.Config{hooks: [Hooks.entry()]}` (default `[]`); `Runner.entries/1` now finds them; `behaviours_refs.hooks` in templates.

- [ ] **Step 1: Write the failing tests**

`test/hooks/tool_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.ToolHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, ScriptedToolClient, TelemetryCapture}
  alias Normandy.Test.Hooks.Probe

  defp call, do: %ToolCall{id: "call_1", name: "probe", input: %{}}

  defp agent(behaviours, name \\ "tool-hooks-agent") do
    %{client: %ScriptedToolClient{}, model: "test", name: name, behaviours: behaviours}
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: self()})
  end

  defp dispatch(agent), do: Dispatch.dispatch_one(agent, call(), BaseAgent.base_agent_pipeline(agent))

  test "no hooks: the pipeline's hook lists are exactly the function lists" do
    f = fn _config, call -> {:cont, call} end
    pipeline = Config.to_pipeline(%Config{before_hooks: [f]})
    assert pipeline.before_hooks == [f]
    assert pipeline.after_hooks == []
  end

  test "module before_tool runs first; its rewrite reaches the function hooks" do
    test_pid = self()
    rewritten = %ToolCall{call() | input: %{"redacted" => true}}

    fun_hook = fn _config, call ->
      send(test_pid, {:fun_before, call.input})
      {:cont, call}
    end

    behaviours = %Config{
      hooks: [{Probe, notify: test_pid, tag: :m, returns: [before_tool: {:cont, rewritten}]}],
      before_hooks: [fun_hook]
    }

    assert %ToolResult{is_error: false} = dispatch(agent(behaviours))
    assert_received {:hook, :m, :before_tool, [%ToolCall{input: %{}}, _ctx]}
    assert_received {:fun_before, %{"redacted" => true}}
  end

  test "a module halt skips later modules and the function hooks, emitting one denial" do
    test_pid = self()
    name = "tool-hooks-halt-#{System.unique_integer([:positive])}"
    ref = TelemetryCapture.attach([[:normandy, :tool, :denied]], agent_name: name)
    denied = %ToolResult{tool_call_id: "other", output: %{error: "blocked"}, is_error: true}

    behaviours = %Config{
      hooks: [
        {Probe, notify: test_pid, tag: :first, returns: [before_tool: {:halt, denied}]},
        {Probe, notify: test_pid, tag: :second}
      ],
      before_hooks: [fn _c, call -> send(test_pid, :fun_ran) && {:cont, call} end]
    }

    # The result answers the model's call id, whatever the hook put there.
    assert %ToolResult{tool_call_id: "call_1", is_error: true} = dispatch(agent(behaviours, name))
    refute_received {:hook, :second, :before_tool, _}
    refute_received :fun_ran
    refute_received {:probe_ctx, _}
    assert_received {:telemetry, ^ref, %{count: 1}, %{reason: :hook_halt}}
    refute_received {:telemetry, ^ref, _, _}
  end

  test "module after_tool runs before the function after-hooks; its rewrite reaches them" do
    test_pid = self()
    from_module = %ToolResult{tool_call_id: "call_1", output: "from-module", is_error: false}

    behaviours = %Config{
      hooks: [{Probe, notify: test_pid, tag: :m, returns: [after_tool: {:cont, from_module}]}],
      after_hooks: [
        fn _c, _call, result ->
          send(test_pid, {:fun_after, result.output})
          %{result | output: "from-function"}
        end
      ]
    }

    assert %ToolResult{output: "from-function"} = dispatch(agent(behaviours))
    assert_received {:hook, :m, :after_tool, [_call, %ToolResult{output: original}, _ctx]}
    refute original == "from-module"
    assert_received {:fun_after, "from-module"}
  end

  test "init/1 rejects malformed hooks" do
    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      agent(%Config{hooks: [{Probe, on_error: :sometimes}]})
    end

    assert_raise ArgumentError, ~r/hook module Nope.Missing is not available/, fn ->
      agent(%Config{hooks: [{Nope.Missing, []}]})
    end
  end
end
```

Add to `test/agents/config_template_test.exs`, inside the `describe` block that defines `round_trip_supplement/0` and `full_config/1` (the one holding `"tool_context travels in the template"`):

```elixir
    test "hooks travel in the template" do
      supp = round_trip_supplement()
      hooks = [{Normandy.Test.Hooks.Probe, tag: :audit, on_error: :open}]
      config = %{full_config(supp) | behaviours: %{full_config(supp).behaviours | hooks: hooks}}

      rebuilt = config |> ConfigTemplate.from_config("t") |> ConfigTemplate.rebuild(supp, "TOKEN")

      assert rebuilt.behaviours.hooks == hooks
    end

    test "a template saved before hooks existed rebuilds with []" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      tmpl = %{tmpl | behaviours_refs: Map.delete(tmpl.behaviours_refs, :hooks)}

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").behaviours.hooks == []
    end

    test "from_config refuses a pid in hook opts" do
      supp = round_trip_supplement()
      hooks = [{Normandy.Test.Hooks.Probe, notify: self()}]
      config = %{full_config(supp) | behaviours: %{full_config(supp).behaviours | hooks: hooks}}

      assert_raise ArgumentError, ~r/:hooks contains a function or pid/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end

    test "rebuild rejects a hook module that no longer exists" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      tmpl = put_in(tmpl, [:behaviours_refs, :hooks], [{Gone.Hook, []}])

      assert_raise ArgumentError, ~r/hook module Gone.Hook is not available/, fn ->
        ConfigTemplate.rebuild(tmpl, supp, "TOKEN")
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/hooks/tool_hooks_test.exs test/agents/config_template_test.exs`
Expected: FAIL — `%Config{}` has no `:hooks` key (KeyError / CompileError in the test).

- [ ] **Step 3: Implement**

`lib/normandy/behaviours/config.ex`:
- Moduledoc: after "One `{module, opts}` ref per behaviour plus the two first-class hook lists." add: "`hooks` is an ordered list of `Normandy.Behaviours.Hooks` entries, persisted with the refs; `to_pipeline/1` runs their `before_tool`/`after_tool` callbacks ahead of the function lists."
- Add `alias Normandy.Behaviours.Hooks` and `alias Normandy.Hooks.Runner`.
- Type: add `hooks: [Hooks.entry()],` after `after_hooks`.
- Struct: add `hooks: [],` after `after_hooks: [],`.
- `to_pipeline/1`:

```elixir
    %Pipeline{
      before_hooks: module_before_hooks(bundle.hooks) ++ bundle.before_hooks,
      after_hooks: module_after_hooks(bundle.hooks) ++ bundle.after_hooks,
      # ... policy_fn, budget_check_fn, budget_record_fn, execute_fn unchanged
    }
```

and below `scope/1`:

```elixir
  # Hook modules run as one adapter fun ahead of the function hooks, so a module halt
  # skips the functions (Dispatch stops at the first halt). No modules, no adapter: the
  # pipeline is exactly what it was before hooks existed.
  defp module_before_hooks([]), do: []

  defp module_before_hooks(hooks),
    do: [fn config, call -> Runner.before_tool(hooks, config, call) end]

  defp module_after_hooks([]), do: []

  defp module_after_hooks(hooks),
    do: [fn config, call, result -> Runner.after_tool(hooks, config, call, result) end]
```

`lib/normandy/agents/config_template.ex`:
- Moduledoc: in "Everything else travels in the template: …", change "and behaviour module refs" to "behaviour module refs and hook entries".
- `from_config/2`: add `hooks: storable_hooks!(b.hooks)` as the last key of `behaviours_refs`.
- `rebuild/3`: add `hooks: Map.get(refs, :hooks, []),` to the `%Config{}` (after `session_registry:`), and after building `behaviours` call `:ok = Normandy.Behaviours.Hooks.validate_entries!(behaviours.hooks)`.
- Add next to `storable_fields!/1`:

```elixir
  # Hook entries are saved as given; their opts must be plain data like the fields above.
  defp storable_hooks!(hooks) do
    if unstorable?(hooks) do
      raise ArgumentError,
            "ConfigTemplate.from_config/2: :hooks contains a function or pid, which a " <>
              "template cannot store. Hook opts must be plain data; name a registered " <>
              "process instead of passing a pid."
    end

    hooks
  end
```

`lib/normandy/agents/base_agent.ex` `init/1`: after `:ok = validate_policy_opts!(Map.get(config, :behaviours))` add `:ok = validate_hooks!(Map.get(config, :behaviours))`, and next to `validate_policy_opts!/1`:

```elixir
  # Hook entries are checked where the config is made, like the policy's opts.
  defp validate_hooks!(%Normandy.Behaviours.Config{hooks: hooks}),
    do: Normandy.Behaviours.Hooks.validate_entries!(hooks)

  defp validate_hooks!(_behaviours), do: :ok
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks/tool_hooks_test.exs test/agents/config_template_test.exs test/agents/dispatch_split_test.exs test/behaviours/config_test.exs`
Expected: PASS (the last two prove existing hook behaviour is unchanged).

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/behaviours/config.ex lib/normandy/agents/config_template.ex lib/normandy/agents/base_agent.ex test/hooks/tool_hooks_test.exs test/agents/config_template_test.exs
git commit -m "feat(hooks): hooks on Behaviours.Config, tool hooks via to_pipeline, persisted in templates"
```

### Task 4: BaseAgent `on_prompt` and `on_turn_end`

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`admit_turn_input/2` ~line 586, `with_agent_run_span/3` ~line 1681)
- Create: `test/support/streaming_probe_client.ex` (moved out of `test/agents/tool_context_test.exs`)
- Modify: `test/agents/tool_context_test.exs` (use the moved client)
- Test: `test/hooks/base_agent_hooks_test.exs`

**Interfaces:**
- Consumes: `Runner.entries/1`, `Runner.prompt/3`, `Runner.turn_end/3`, `%HookHaltError{}`, `Normandy.Test.Hooks.Probe`.
- Produces: `BaseAgent.run/2,3`, `run_with_tools/2`, `stream_response/3`, `stream_with_tools/3` raise `%HookHaltError{event: :on_prompt}` on a prompt halt; `on_turn_end` fires once per run with `{:ok, response}`, `{:rejected, e}` or `{:error, reason}`. `Normandy.Test.StreamingProbeClient` (Task 5 uses it).

- [ ] **Step 1: Move the streaming test client into support**

Cut `defmodule StreamingProbeClient do … end` from `test/agents/tool_context_test.exs` into `test/support/streaming_probe_client.ex`, renamed `Normandy.Test.StreamingProbeClient`, with this moduledoc: `"Streams a tool_use of the \"probe\" tool until the conversation holds a tool result, then streams the text \"done\"."` In `tool_context_test.exs` replace the references with `Normandy.Test.StreamingProbeClient` (add it to the `alias Normandy.Test.{…}` line). Run `mix test test/agents/tool_context_test.exs` — expected PASS, unchanged count.

- [ ] **Step 2: Write the failing tests**

`test/hooks/base_agent_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.BaseAgentHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context
  alias Normandy.Test.{ContextProbe, StreamingProbeClient}
  alias Normandy.Test.Hooks.Probe

  # Answers with the response model; tells the test it was called.
  defmodule EchoClient do
    @moduledoc false
    defstruct notify: nil, raise?: false, options: %{}

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

      def converse(client, _m, _t, _mt, _msgs, response_model, _opts) do
        if client.notify, do: send(client.notify, :llm_called)
        if client.raise?, do: raise("llm down")
        response_model
      end
    end
  end

  defmodule RequiredQueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end

  defp agent(hooks, extra \\ %{}) do
    %{
      client: %EchoClient{notify: self()},
      model: "test",
      name: "hooks-agent",
      behaviours: %Config{hooks: hooks},
      retry_options: nil
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  defp probe(opts \\ []), do: {Probe, [notify: self(), tag: :p] ++ opts}
  defp input(text), do: %BaseAgentInputSchema{chat_message: text}

  defp last_user_content(config) do
    config.memory
    |> AgentMemory.messages()
    |> Enum.filter(&(&1.role == "user"))
    |> List.last()
    |> Map.fetch!(:content)
  end

  describe "on_prompt" do
    test "a rewrite is what memory holds" do
      hooks = [probe(returns: [on_prompt: {:cont, input("[redacted]")}])]
      {config, _response} = BaseAgent.run(agent(hooks), input("my ssn is 1"))

      assert_received {:hook, :p, :on_prompt, [%BaseAgentInputSchema{chat_message: "my ssn is 1"}, ctx]}
      assert %Context{turn_id: nil} = ctx
      assert %BaseAgentInputSchema{chat_message: "[redacted]"} = last_user_content(config)
    end

    test "a halt raises HookHaltError before memory or the LLM is touched" do
      agent = agent([probe(returns: [on_prompt: {:halt, "off-topic"}])])

      error =
        assert_raise Normandy.HookHaltError, fn -> BaseAgent.run(agent, input("hi")) end

      assert %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"} = error
      refute_received :llm_called
    end

    test "the rewritten input is validated: a rewrite the schema rejects raises ValidationError" do
      hooks = [probe(returns: [on_prompt: {:cont, %{}}])]
      agent = agent(hooks, %{input_schema: %RequiredQueryInput{}})

      assert_raise Normandy.Schema.ValidationError, fn ->
        BaseAgent.run(agent, %RequiredQueryInput{query: "fine"})
      end

      refute_received :llm_called
    end

    test "a nil input runs no on_prompt hook" do
      BaseAgent.run(agent([probe()]), nil)
      refute_received {:hook, :p, :on_prompt, _}
    end
  end

  describe "on_turn_end" do
    test "a completed run reports {:ok, response} with the turn's id" do
      {config, response} = BaseAgent.run(agent([probe()]), input("hi"))

      assert_received {:hook, :p, :on_turn_end, [{:ok, ^response}, %Context{turn_id: turn_id}]}
      assert turn_id == config.memory.current_turn_id
      refute is_nil(turn_id)
    end

    test "an on_prompt halt reports {:rejected, %HookHaltError{}}" do
      agent = agent([probe(returns: [on_prompt: {:halt, "no"}])])
      catch_error(BaseAgent.run(agent, input("hi")))

      assert_received {:hook, :p, :on_turn_end,
                       [{:rejected, %Normandy.HookHaltError{event: :on_prompt}}, ctx]}

      assert %Context{turn_id: nil} = ctx
    end

    test "a schema rejection reports {:rejected, %ValidationError{}}" do
      agent = agent([probe()], %{input_schema: %RequiredQueryInput{}})
      catch_error(BaseAgent.run(agent, %{}))

      assert_received {:hook, :p, :on_turn_end,
                       [{:rejected, %Normandy.Schema.ValidationError{}}, _ctx]}
    end

    test "a failing run reports {:error, _} and still raises the original error" do
      agent = agent([probe()], %{client: %EchoClient{raise?: true}})
      catch_error(BaseAgent.run(agent, input("hi")))
      assert_received {:hook, :p, :on_turn_end, [{:error, _reason}, _ctx]}
    end

    @tag :capture_log
    test "a crashing on_turn_end does not change the result" do
      agent = agent([probe(returns: [on_turn_end: {:raise, "audit down"}])])
      assert {_config, _response} = BaseAgent.run(agent, input("hi"))
    end

    test "fires once on the streaming path" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "test",
          name: "hooks-stream",
          behaviours: %Config{hooks: [probe()]}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      {_config, _response} = BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)

      assert_received {:hook, :p, :on_turn_end, [{:ok, _}, _ctx]}
      refute_received {:hook, :p, :on_turn_end, _}
    end
  end
end
```

If `BaseAgent.init/1` rejects `retry_options: nil` or the `RequiredQueryInput` schema needs the `BaseIOSchema` stubs `Turn.ServerTest` defines, adapt the fixture, not the assertions. The `{:error, _}` test may see the error wrapped by the retry layer; it asserts only the outcome tag.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/hooks/base_agent_hooks_test.exs`
Expected: FAIL — no `:hook` messages are received (hooks are not wired yet); the halt test fails with "expected exception Normandy.HookHaltError but nothing was raised".

- [ ] **Step 4: Wire `on_prompt`**

In `lib/normandy/agents/base_agent.ex` add `alias Normandy.Hooks.Runner` to the alias block. In `admit_turn_input(config, user_input)` (the non-nil clause), make the first line of the body:

```elixir
    user_input = run_prompt_hooks!(config, user_input)
```

and add below `admit_turn_input/2`:

```elixir
  # on_prompt runs before validation and guardrails, so a rewritten input is checked
  # exactly like a caller's. No turn exists yet: the context's turn_id is nil.
  defp run_prompt_hooks!(config, user_input) do
    case Runner.prompt(Runner.entries(config), config, user_input) do
      {:cont, input} ->
        input

      {:halt, hook, reason} ->
        raise Normandy.HookHaltError, event: :on_prompt, hook: hook, reason: reason
    end
  end
```

- [ ] **Step 5: Wire `on_turn_end`**

Replace the body of `with_agent_run_span/3` so the success hook runs after the `try` (a contract violation in the hook must not be re-reported as the run's own failure) and the failure hook runs before re-raising:

```elixir
  defp with_agent_run_span(config, telemetry_metadata, fun) do
    :telemetry.span([:normandy, :agent, :run], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy agent run start",
        agent: log_agent_name(config),
        iteration: 0,
        max_iterations: max_run_iterations(config)
      )

      started_at = System.monotonic_time()

      {result, stop_metadata} =
        try do
          {result, stop_metadata} = fun.()
          stop_metadata = put_turn_id(stop_metadata, result)
          duration_ms = Map.get(stop_metadata, :duration_ms, elapsed_ms(started_at))

          log_lifecycle(:info, "normandy agent run stop",
            agent: log_agent_name(config),
            iterations: completed_iterations(result),
            status: :ok,
            duration_ms: duration_ms
          )

          {result, stop_metadata}
        rescue
          error ->
            log_span_exception("normandy agent exception", config, :error, error)
            Runner.turn_end(Runner.entries(config), config, turn_outcome(error), turn_id: nil)
            reraise(error, __STACKTRACE__)
        catch
          kind, reason ->
            log_span_exception("normandy agent exception", config, kind, reason)
            Runner.turn_end(Runner.entries(config), config, {:error, {kind, reason}},
              turn_id: nil
            )
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      turn_end_ok(config, result)
      {result, stop_metadata}
    end)
  end

  # The run's own config carries the memory, so its turn id reaches the hook. A raised
  # run loses that config with the exception, so its hook gets turn_id: nil rather than
  # the previous turn's id still on `config`.
  defp turn_end_ok(_config, {%BaseAgentConfig{} = after_run, response}),
    do: Runner.turn_end(Runner.entries(after_run), after_run, {:ok, response})

  defp turn_end_ok(config, result),
    do: Runner.turn_end(Runner.entries(config), config, {:ok, result})

  # Input that never became a turn is :rejected, as Turn.Server reports it.
  defp turn_outcome(%Normandy.HookHaltError{event: :before_llm, reason: reason}),
    do: {:error, {:hook_halted, :before_llm, reason}}

  defp turn_outcome(%Normandy.HookHaltError{} = e), do: {:rejected, e}
  defp turn_outcome(%Normandy.Schema.ValidationError{} = e), do: {:rejected, e}
  defp turn_outcome(%Normandy.Guardrails.ViolationError{} = e), do: {:rejected, e}
  defp turn_outcome(error), do: {:error, error}
```

Keep every other line of the original function exactly as it was; diff the result against the original before running tests.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks/base_agent_hooks_test.exs test/agents test/telemetry`
Expected: PASS — the hooks tests, and no change in the existing agent and telemetry suites (span shape unchanged when no hooks are set).

- [ ] **Step 7: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/agents/base_agent.ex test/support/streaming_probe_client.ex test/agents/tool_context_test.exs test/hooks/base_agent_hooks_test.exs
git commit -m "feat(hooks): on_prompt and on_turn_end in BaseAgent runs"
```

### Task 5: BaseAgent `before_llm` and `after_compact`

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`call_turn_llm/3` ~line 653, `call_stream_llm/3` ~line 1014 and its handler at ~line 992, `compact_turn_memory/3` ~line 800)
- Create: `test/support/keep_last_compactor.ex`
- Test: `test/hooks/llm_compaction_hooks_test.exs`

**Interfaces:**
- Consumes: `Runner.before_llm/3`, `Runner.after_compact/4`, `Normandy.Test.StreamingProbeClient` (Task 4), `EchoClient` pattern (Task 4 — redefine it in this test file).
- Produces: `before_llm` halts raise `%HookHaltError{event: :before_llm}` from the LLM handler (Task 6 relies on this to map the Server reply); `compact_turn_memory/3` returns the config with injected texts appended when `meta.compacted`.

- [ ] **Step 1: Add the test compactor**

`test/support/keep_last_compactor.ex`:

```elixir
defmodule Normandy.Test.KeepLastCompactor do
  @moduledoc """
  Compactor for tests: keeps the last `opts[:keep]` messages and drops the rest. Kept
  messages are re-added to a fresh memory, so their entry ids change (as a summarizing
  compactor's would). `compacted: true` only when it dropped something.
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Components.AgentMemory

  @impl true
  def maybe_compact(config, _ctx, opts) do
    messages = AgentMemory.messages(config.memory)
    keep = Keyword.fetch!(opts, :keep)

    if length(messages) <= keep do
      {config, %{compacted: false}}
    else
      memory =
        messages
        |> Enum.take(-keep)
        |> Enum.reduce(AgentMemory.new_memory(), fn m, mem ->
          AgentMemory.add_message(mem, m.role, m.content, turn_id: m.turn_id)
        end)

      memory = %{memory | current_turn_id: config.memory.current_turn_id}
      {%{config | memory: memory}, %{compacted: true, strategy: :keep_last}}
    end
  end
end
```

- [ ] **Step 2: Write the failing tests**

`test/hooks/llm_compaction_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.LlmCompactionHooksTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{AgentMemory, Message, ToolResult}
  alias Normandy.Test.{ContextProbe, KeepLastCompactor, StreamingProbeClient}
  alias Normandy.Test.Hooks.Probe

  defmodule EchoClient do
    @moduledoc false
    defstruct notify: nil, options: %{}

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

      def converse(client, _m, _t, _mt, _msgs, response_model, _opts) do
        if client.notify, do: send(client.notify, :llm_called)
        response_model
      end
    end
  end

  defp probe(opts \\ []), do: {Probe, [notify: self(), tag: :p] ++ opts}
  defp input(text), do: %BaseAgentInputSchema{chat_message: text}

  defp agent(behaviours, extra \\ %{}) do
    %{
      client: %EchoClient{notify: self()},
      model: "test",
      name: "llm-hooks-agent",
      behaviours: behaviours
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  # Memory holding three earlier messages, so a keep: 2 compaction drops two of them
  # plus nothing from the new turn.
  defp seeded_memory do
    AgentMemory.new_memory()
    |> AgentMemory.add_message("user", "old-1")
    |> AgentMemory.add_message("assistant", "old-2")
    |> AgentMemory.add_message("user", "old-3")
  end

  describe "before_llm" do
    test "runs before each LLM call with the call's info" do
      BaseAgent.run(agent(%Config{hooks: [probe()]}), input("hi"))

      assert_received {:hook, :p, :before_llm, [%{final: false, iterations_left: left}, _ctx]}
      assert is_integer(left)
      assert_received :llm_called
    end

    test "a halt raises HookHaltError, skips the LLM and reports the halt at turn end" do
      agent = agent(%Config{hooks: [probe(returns: [before_llm: {:halt, "budget spent"}])]})

      error = assert_raise Normandy.HookHaltError, fn -> BaseAgent.run(agent, input("hi")) end
      assert %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget spent"} = error

      refute_received :llm_called

      assert_received {:hook, :p, :on_turn_end,
                       [{:error, {:hook_halted, :before_llm, "budget spent"}}, _ctx]}
    end

    test "runs on the streaming path, once per LLM call" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "test",
          name: "llm-hooks-stream",
          behaviours: %Config{hooks: [probe()]}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)

      # StreamingProbeClient makes two calls: the tool_use round, then the text answer.
      assert_received {:hook, :p, :before_llm, _}
      assert_received {:hook, :p, :before_llm, _}
      refute_received {:hook, :p, :before_llm, _}
    end
  end

  describe "after_compact" do
    test "receives exactly the dropped messages, even though kept entry ids changed" do
      behaviours = %Config{compactor: {KeepLastCompactor, keep: 2, max_tokens: 200_000}, hooks: [probe()]}
      agent = agent(behaviours, %{memory: seeded_memory()})

      BaseAgent.run(agent, input("now"))

      assert_received {:hook, :p, :after_compact, [dropped, %{compacted: true}, _ctx]}
      assert [%Message{role: "user", content: "old-1"}, %Message{role: "assistant", content: "old-2"}] = dropped
    end

    test "injected texts are appended to the compacted memory, before the LLM call" do
      behaviours = %Config{
        compactor: {KeepLastCompactor, keep: 2, max_tokens: 200_000},
        hooks: [probe(returns: [after_compact: {:inject, ["remember: prefers metric"]}])]
      }

      {config, _response} = BaseAgent.run(agent(behaviours, %{memory: seeded_memory()}), input("now"))

      contents = config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)

      assert ["old-3", %BaseAgentInputSchema{chat_message: "now"}, "remember: prefers metric" | _assistant] =
               contents
    end

    test "does not fire when nothing was compacted" do
      behaviours = %Config{compactor: {KeepLastCompactor, keep: 100, max_tokens: 200_000}, hooks: [probe()]}
      BaseAgent.run(agent(behaviours), input("hi"))
      refute_received {:hook, :p, :after_compact, _}
    end

    test "an injected user message after tool results converts to a valid request" do
      messages = [
        %Message{role: "user", content: "hi"},
        %Message{
          role: "tool",
          content: %ToolResult{tool_call_id: "toolu_1", output: "ok", is_error: false}
        },
        %Message{role: "user", content: "remember: prefers metric"}
      ]

      request =
        Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter.add_messages(Request.new("m"), messages, false)

      roles = Enum.map(request.messages, &(Map.get(&1, :role) || Map.get(&1, "role")))
      assert Enum.map(roles, &to_string/1) == ["user", "user", "user"]
    end
  end
end
```

Read `Claudio.Messages.Request` (`../Claudio/lib/claudio/messages/request.ex`) for the element shape of `request.messages` and adjust the `roles` extraction only. Read `BaseAgent.validate_compaction_config!/1` (~line 866): a non-NoOp compactor with a non-Claudio client needs `:max_tokens` in its opts, which these tests pass.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/hooks/llm_compaction_hooks_test.exs`
Expected: FAIL — no `before_llm`/`after_compact` hook messages; the halt test reports nothing raised. (The request-shape test may already pass; it pins existing behaviour.)

- [ ] **Step 4: Wire `before_llm`**

In `lib/normandy/agents/base_agent.ex`:

Change `call_turn_llm(config, state, %{response_model: response_model})` to `call_turn_llm(config, state, %{response_model: response_model} = request)` and make its first line:

```elixir
    :ok = run_before_llm_hooks!(config, state, request)
```

In `streaming_handlers` (~line 992) change `call_llm: fn config, state, _request -> call_stream_llm(config, state, callback) end` to `call_llm: fn config, state, request -> call_stream_llm(config, state, request, callback) end`, change `defp call_stream_llm(config, state, callback)` to `defp call_stream_llm(config, state, request, callback)` and make its first line the same `:ok = run_before_llm_hooks!(config, state, request)`. Update the comment above it that says `call_stream_llm/3` to `/4` (and the one at ~line 1164 mentioning `call_stream_llm/3`).

Add next to `call_turn_llm/3`:

```elixir
  # Outside the llm_call span and the retry loop: a halt is a decision, not a failed
  # call, so it is neither retried nor recorded as an LLM exception.
  defp run_before_llm_hooks!(config, state, request) do
    info = %{final: Map.get(request, :final, false), iterations_left: state.iterations_left}

    case Runner.before_llm(Runner.entries(config), config, info) do
      :cont -> :ok
      {:halt, hook, reason} -> raise Normandy.HookHaltError, event: :before_llm, hook: hook, reason: reason
    end
  end
```

- [ ] **Step 5: Wire `after_compact`**

In `compact_turn_memory/3`, replace the final `{config2, meta}` with:

```elixir
    {after_compact(config, config2, meta), meta}
```

and add below it:

```elixir
  # Only a compaction that removed something has anything to report. `dropped` is
  # matched on role and content, not entry id: a compactor may re-add kept messages as
  # new entries. Injected texts go to memory only, like the compaction itself.
  defp after_compact(before, compacted, %{compacted: true} = meta) do
    case Runner.entries(compacted) do
      [] ->
        compacted

      entries ->
        dropped = dropped_messages(before.memory, compacted.memory)

        entries
        |> Runner.after_compact(compacted, dropped, meta)
        |> Enum.reduce(compacted, fn text, config ->
          %{config | memory: AgentMemory.add_message(config.memory, "user", text)}
        end)
    end
  end

  defp after_compact(_before, compacted, _meta), do: compacted

  defp dropped_messages(before, compacted) do
    kept = compacted |> AgentMemory.messages() |> Enum.map(&{&1.role, &1.content})

    {dropped, _kept} =
      before
      |> AgentMemory.messages()
      |> Enum.flat_map_reduce(kept, fn message, kept ->
        key = {message.role, message.content}
        if key in kept, do: {[], List.delete(kept, key)}, else: {[message], kept}
      end)

    dropped
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/agents test/integration/compaction_turn_test.exs test/behaviours/compactor_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/agents/base_agent.ex test/support/keep_last_compactor.ex test/hooks/llm_compaction_hooks_test.exs
git commit -m "feat(hooks): before_llm gate and after_compact with dropped messages and injection"
```

### Task 6: Turn.Server — halts, turn end, session start, passivation

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex`
- Test: `test/hooks/server_hooks_test.exs`

**Interfaces:**
- Consumes: `Runner.entries/1`, `Runner.session_start/2`, `Runner.passivate/2`, `Runner.turn_end/4`, `%HookHaltError{}` raised by `BaseAgent.admit_turn_input/2` (Task 4) and by the default `call_llm` handler (Task 5).
- Produces: `Turn.Server.run/2` replies `{:error, {:hook_halted, :on_prompt | :before_llm, reason}}`; `on_turn_end` fires at every reply of a turn; `on_session_start` fires once per new session; `on_passivate` fires on idle passivation.

- [ ] **Step 1: Write the failing tests**

`test/hooks/server_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.ServerHooksTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Test.Hooks.Probe
  alias Normandy.Test.TurnConfig

  defp probe(opts \\ []), do: {Probe, [notify: self(), tag: :p] ++ opts}

  defp config(hooks) do
    config = TurnConfig.build()
    %{config | behaviours: %{config.behaviours | hooks: hooks}}
  end

  defp stub_handlers do
    %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> %TurnConfig.Resp{content: "hi", tool_calls: nil} end
    }
  end

  defp start(sid, hooks, opts \\ []) do
    Turn.Server.start_link(
      [
        session_id: sid,
        config: config(hooks),
        store: Keyword.get(opts, :store, {InMemory, InMemory.new()}),
        registry: {Native, Native.new()},
        handlers: Keyword.get(opts, :handlers, stub_handlers())
      ] ++ Keyword.drop(opts, [:store, :handlers])
    )
  end

  defp sid, do: "hooks-#{System.unique_integer([:positive])}"

  describe "halts" do
    test "an on_prompt halt replies {:hook_halted, :on_prompt, reason}; turn end sees :rejected" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:halt, "off-topic"}])])

      assert Turn.Server.run(srv, "hello") == {:error, {:hook_halted, :on_prompt, "off-topic"}}

      assert_received {:hook, :p, :on_turn_end,
                       [{:rejected, %Normandy.HookHaltError{event: :on_prompt}}, _ctx]}

      assert Process.alive?(srv)
    end

    test "a before_llm halt replies {:hook_halted, :before_llm, reason} and fails the turn" do
      # Default handlers: the real call_turn_llm runs the hook, which halts before any
      # request is made, so the fixture's client is never used.
      {:ok, srv} =
        start(sid(), [probe(returns: [before_llm: {:halt, "budget"}])],
          handlers: BaseAgent.non_streaming_handlers()
        )

      assert Turn.Server.run(srv, "hello") == {:error, {:hook_halted, :before_llm, "budget"}}

      assert_received {:hook, :p, :on_turn_end,
                       [{:error, {:hook_halted, :before_llm, "budget"}}, _ctx]}
    end
  end

  describe "on_turn_end" do
    test "a completed turn reports {:ok, final} before the caller gets the reply" do
      {:ok, srv} = start(sid(), [probe()])
      assert {:ok, %TurnConfig.Resp{content: "hi"} = final} = Turn.Server.run(srv, "hello")
      assert_received {:hook, :p, :on_turn_end, [{:ok, ^final}, ctx]}
      refute is_nil(ctx.turn_id)
    end

    test "a crashing on_turn_end does not change the reply" do
      {:ok, srv} = start(sid(), [probe(returns: [on_turn_end: {:raise, "audit down"}])])
      assert {:ok, _} = Turn.Server.run(srv, "hello")
      assert Process.alive?(srv)
    end
  end

  describe "on_session_start" do
    test "a new session runs it once; injected texts reach memory and the store" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric units"]}])]

      {:ok, srv} = start(session, hooks, store: {InMemory, store})
      assert_received {:hook, :p, :on_session_start, [ctx]}
      assert ctx.session_id == session
      assert is_nil(ctx.turn_id)

      assert {:ok, entries} = InMemory.history(store, session)
      assert [%{role: "user", content: "profile: metric units"}] = entries

      # A rehydrate of the same session finds entries: no second run, no second copy.
      :ok = :gen_statem.stop(srv)
      {:ok, srv2} = start(session, hooks, store: {InMemory, store})
      refute_received {:hook, :p, :on_session_start, _}

      %{config: config} = :sys.get_state(srv2) |> elem(1)

      assert ["profile: metric units"] =
               config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)
    end

    test "a session with stored entries does not run it" do
      store = InMemory.new()
      session = sid()
      {:ok, srv} = start(session, [], store: {InMemory, store})
      {:ok, _} = Turn.Server.run(srv, "hello")
      :ok = :gen_statem.stop(srv)

      {:ok, _srv} = start(session, [probe()], store: {InMemory, store})
      refute_received {:hook, :p, :on_session_start, _}
    end

    test "a crash fails the start under :reraise and is logged under :open" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = start(sid(), [probe(returns: [on_session_start: {:raise, "crm down"}])])

      assert {:ok, _srv} =
               start(sid(), [probe(on_error: :open, returns: [on_session_start: {:raise, "crm down"}])])
    end
  end

  describe "on_passivate" do
    test "runs when the idle server passivates; a crash still stops it normally" do
      {:ok, srv} = start(sid(), [probe(returns: [on_passivate: {:raise, "late"}])], idle_timeout_ms: 20)
      ref = Process.monitor(srv)

      assert_receive {:hook, :p, :on_passivate, [_ctx]}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^srv, :normal}, 1_000
    end
  end
end
```

Read `Turn.Server.start_link/1` and `init/1` first: confirm the option names (`:idle_timeout_ms`, `:handlers`), whether a `:config` start saves a config template (it must not, or the pid in the probe's opts raises — if it does, register the test process under a unique atom and pass that as `notify:`), and the `:sys.get_state/1` shape (`{state_name, %Data{}}`). Adapt the fixture, not the assertions. `TurnConfig.Resp` may need a `BaseIOSchema` implementation for the assistant append; if the turn fails on it, define one in the test as `Turn.ServerTest` does for its `Resp`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/hooks/server_hooks_test.exs`
Expected: FAIL — the on_prompt halt replies `{:error, {:rejected, …}}` is not yet produced (it crashes or replies differently), the before_llm halt replies `{:error, {:task_down, …}}`, and no `on_turn_end`/`on_session_start`/`on_passivate` messages arrive.

- [ ] **Step 3: Implement**

In `lib/normandy/agents/turn/server.ex`, add `alias Normandy.Hooks.Runner`.

(a) `admit/2` — rescue the halt too:

```elixir
  defp admit(config, user_input) do
    {:ok, BaseAgent.admit_turn_input(config, user_input)}
  rescue
    e in [Normandy.Schema.ValidationError, Normandy.Guardrails.ViolationError, Normandy.HookHaltError] ->
      {:rejected, e}
  end
```

Update its comment: "Schema, input-guardrail and on_prompt-hook rejections are expected outcomes: …".

(b) The `{:turn, …}` `:idle` clause's `{:rejected, exception}` branch:

```elixir
      {:rejected, exception} ->
        emit_rejected_run(data, caller_ctx, exception)
        Runner.turn_end(Runner.entries(data.config), data.config, {:rejected, exception}, turn_id: nil)
        {:keep_state, data, [{:reply, from, rejection_reply(exception)}]}
```

and next to `admit/2`:

```elixir
  defp rejection_reply(%Normandy.HookHaltError{event: event, reason: reason}),
    do: {:error, {:hook_halted, event, reason}}

  defp rejection_reply(exception), do: {:error, {:rejected, exception}}
```

(c) The `{:call_llm, request}` effect — the task turns a `before_llm` halt into an `:llm_error` the core fails the turn with:

```elixir
      {:call_llm, request} ->
        spawn_task(data, :llm, fn h, d ->
          try do
            {:llm_response, h.call_llm.(d.config, d.turn_state, request)}
          rescue
            e in Normandy.HookHaltError -> {:llm_error, {:hook_halted, e.event, e.reason}}
          end
        end)
```

(d) The `{:finalize, value}` and `{:fail, reason}` effects — the hook runs after the run span stops and before the reply:

```elixir
      {:finalize, value} ->
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :stop, %{})
        Runner.turn_end(Runner.entries(data.config), data.config, {:ok, value})
        reply(data, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}

      {:fail, reason} ->
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :exception, %{kind: :error, reason: reason, stacktrace: []})
        Runner.turn_end(Runner.entries(data.config), data.config, fail_outcome(reason))
        reply(data, {:error, reason})
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}
```

Keep the existing comments on those clauses. Add:

```elixir
  # An output-guardrail block fails the turn as {:rejected, e}; report it as a rejection.
  defp fail_outcome({:rejected, exception}), do: {:rejected, exception}
  defp fail_outcome(reason), do: {:error, reason}
```

(e) Passivation:

```elixir
  def handle_event(:state_timeout, :passivate, state, data)
      when state in [:idle, :unavailable] do
    # An :unavailable server never loaded a config, so it has no hooks to run.
    if state == :idle and data.config,
      do: Runner.passivate(Runner.entries(data.config), data.config)

    {:stop, :normal, data}
  end
```

(f) Session start — run inside `load_session/3`, so a first start and a retry after a store fault both get it:

```elixir
  defp load_session(opts, store, session_id) do
    with {:ok, config, template} <- start_config(opts, store, session_id),
         {:ok, config} <- with_stored_memory(config, store, session_id),
         {:ok, turn_state} <- load_turn_state(store, session_id),
         {:ok, config} <- start_session(config, turn_state, store, session_id) do
      {:ok, config, template, turn_state}
    end
  end

  # A session with nothing stored (no entries, no turn state) is new: its
  # on_session_start hooks run, and what they inject is stored like any message. A
  # later start of the session finds those entries and does not run them again. A
  # store fault mid-injection fails the load (the server retries), and the retry sees
  # the entries already written, so injection is at most once, possibly partial.
  defp start_session(config, nil = _turn_state, store, session_id) when not is_nil(config) do
    if AgentMemory.messages(config.memory) == [] do
      config = with_session_id(config, session_id)
      data = %Data{store: store, session_id: session_id}

      config
      |> Runner.entries()
      |> Runner.session_start(config)
      |> Enum.reduce_while({:ok, config}, fn text, {:ok, config} ->
        next = %{config | memory: AgentMemory.add_message(config.memory, "user", text)}

        case append_to_store(data, next, "user", text) do
          :ok -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:ok, config}
    end
  end

  defp start_session(config, _turn_state, _store, _session_id), do: {:ok, config}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks/server_hooks_test.exs test/agents/turn test/telemetry`
Expected: PASS — including the unchanged `Turn.ServerTest` suite (no hooks configured there).

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/agents/turn/server.ex test/hooks/server_hooks_test.exs
git commit -m "feat(hooks): Turn.Server halts, turn end, session start and passivation hooks"
```

### Task 7: Results the Server answers without running a tool pass through after-hooks

**Files:**
- Modify: `lib/normandy/agents/dispatch.ex` (public `apply_after_hooks/4`)
- Modify: `lib/normandy/agents/turn/server.ex` (`Data.synthesized`, approval cast ~line 537, expiry ~line 564, `{:append_message, …}` effect ~line 925, `close_batch/2` ~line 836)
- Test: `test/agents/turn/server_test.exs` (new `describe "after-hooks on results the Server answers"`), `test/agents/dispatch_split_test.exs` (one test)

**Interfaces:**
- Consumes: `Config.to_pipeline/1` prepending the module `after_tool` adapter (Task 3); `Normandy.Test.Hooks.Probe`.
- Produces: `Dispatch.apply_after_hooks(config, %ToolCall{}, %ToolResult{}, %Pipeline{}) :: %ToolResult{}` — runs `pipeline.after_hooks` (module adapter first, then functions) and forces `tool_call_id` to the call's id.

- [ ] **Step 1: Write the failing tests**

In `test/agents/dispatch_split_test.exs` add:

```elixir
  test "apply_after_hooks runs the after-hooks and keeps the call's id" do
    call = %Normandy.Components.ToolCall{id: "c9", name: "t", input: %{}}
    result = %Normandy.Components.ToolResult{tool_call_id: "c9", output: "raw", is_error: true}

    pipeline = %{
      Dispatch.default_pipeline()
      | after_hooks: [fn _config, _call, r -> %{r | output: "audited", tool_call_id: "x"} end]
    }

    assert %Normandy.Components.ToolResult{tool_call_id: "c9", output: "audited"} =
             Dispatch.apply_after_hooks(%{}, call, result, pipeline)
  end
```

In `test/agents/turn/server_test.exs` add at the end of the module:

```elixir
  describe "after-hooks on results the Server answers" do
    defp approval_config(test_pid, extra_hooks) do
      %{
        config_with_notify(test_pid)
        | behaviours: %Normandy.Behaviours.Config{
            policy:
              {Normandy.Behaviours.PolicyEngine.Ruleset,
               rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
               default_action: :allow},
            hooks: [{Normandy.Test.Hooks.Probe, notify: test_pid, tag: :audit}],
            after_hooks: extra_hooks
          }
      }
    end

    defp parking_llm do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fn _c, _s, _r ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0,
          do: %Resp{content: "", tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]},
          else: %Resp{content: "done", tool_calls: nil}
      end
    end

    defp start_parking(sid, config, server_opts \\ []) do
      test_pid = self()

      Turn.Server.start_link(
        [
          session_id: sid,
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: parking_llm()},
          subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
        ] ++ server_opts
      )
    end

    test "a rejected call's result passes through the module and function after-hooks" do
      test_pid = self()
      fun = fn _c, call, r -> send(test_pid, {:fun_after, call.id}) && r end
      {:ok, srv} = start_parking("s-hook-reject", approval_config(test_pid, [fun]))

      parent = self()
      spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)
      assert_receive {:event, :awaiting_approval, _}, 2_000

      :ok = Turn.Server.approve(srv, %{"pk1" => :reject})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_received {:hook, :audit, :after_tool,
                       [%ToolCall{id: "pk1"}, %ToolResult{tool_call_id: "pk1", is_error: true}, _]}

      assert_received {:fun_after, "pk1"}
    end

    test "expired results pass through after_tool before an on_approval_timeout: :fail turn fails" do
      test_pid = self()

      {:ok, srv} =
        start_parking("s-hook-expire", approval_config(test_pid, []),
          approval_timeout_ms: 30,
          on_approval_timeout: :fail
        )

      assert {:error, {:approval_timeout, ["pk1"]}} = Turn.Server.run(srv, "go")

      assert_received {:hook, :audit, :after_tool,
                       [%ToolCall{id: "pk1"}, %ToolResult{tool_call_id: "pk1"}, _]}
    end

    test "an approved call's result passes through after-hooks exactly once" do
      test_pid = self()
      {:ok, srv} = start_parking("s-hook-approve", approval_config(test_pid, []))

      parent = self()
      spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)
      assert_receive {:event, :awaiting_approval, _}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_received {:hook, :audit, :after_tool, [%ToolCall{id: "pk1"}, _, _]}
      refute_received {:hook, :audit, :after_tool, _}
    end

    test "an interrupted result passes through after-hooks and is stored as rewritten" do
      test_pid = self()

      rewrite = fn _c, _call, r -> %{r | output: Map.put(r.output, :audited, true)} end

      config_overrides = %{
        behaviours: %Normandy.Behaviours.Config{
          hooks: [{Normandy.Test.Hooks.Probe, notify: test_pid, tag: :audit}],
          after_hooks: [rewrite]
        }
      }

      {srv, store} = start_dangling_server("s-hook-dangling", config_overrides)
      assert {:ok, _} = Turn.Server.run(srv, "next")

      assert_received {:hook, :audit, :after_tool, [%ToolCall{id: "t1"}, %ToolResult{}, _]}

      {:ok, entries} = InMemory.history(store, "s-hook-dangling")

      assert Enum.any?(entries, fn e ->
               match?(%ToolResult{tool_call_id: "t1", output: %{audited: true}}, e.content)
             end)
    end
  end
```

Read `start_dangling_server/2,3` before writing the last test: confirm its arguments (`config_overrides` as the second argument), its `store` return (it may return a handle for a wrapper store; use the store module it was started with), and that its default `behaviours` has no policy that would interfere. Confirm `Turn.Server.start_link/1` accepts `:approval_timeout_ms` and `:on_approval_timeout` and the expiry reply shape `{:error, {:approval_timeout, ids}}` (`turn.ex:269`). Adapt fixtures, not assertions.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/agents/turn/server_test.exs test/agents/dispatch_split_test.exs`
Expected: FAIL — `Dispatch.apply_after_hooks/4` undefined; the reject/expire/interrupted tests receive no `after_tool` hook message. The "approved … exactly once" test passes already (approved calls go through `Dispatch.execute/4`); it guards against double-running in Step 4.

- [ ] **Step 3: Add `Dispatch.apply_after_hooks/4`**

In `lib/normandy/agents/dispatch.ex`, after `emit_denied/4`:

```elixir
  @doc """
  Runs `pipeline.after_hooks` over a result a shell produced without `execute/4`
  (`Turn.Server`: approval rejected or expired, interrupted-batch repair), so every tool
  result passes the same after-hooks. The result answers `call`'s id, as in `execute/4`.
  """
  @spec apply_after_hooks(map(), ToolCall.t(), ToolResult.t(), Pipeline.t()) :: ToolResult.t()
  def apply_after_hooks(config, %ToolCall{} = call, %ToolResult{} = result, %Pipeline{} = pipeline) do
    %{run_after_hooks(config, call, result, pipeline.after_hooks) | tool_call_id: call.id}
  end
```

and make `execute/4` use it: replace `%{run_after_hooks(config, call, result, pipeline.after_hooks) | tool_call_id: call.id}` with `apply_after_hooks(config, call, result, pipeline)`.

- [ ] **Step 4: Wire the Server**

In `lib/normandy/agents/turn/server.ex`:

(a) `Data`: add `synthesized: %{}` to the `defstruct` (after `retry_ms: nil`), with a comment above the struct field list entry or the struct: `# synthesized: call id => %ToolCall{} for results the core builds without running the tool (approval rejected/expired); their after-hooks run when they are appended.`

(b) The approval cast clause — after `data = with_approver_ctx(…)`:

```elixir
    data = remember_synthesized(data, rejected)
```

(c) The `:approval_expiry` clause — after `data = stop_approval_span(data, :expired)`:

```elixir
    data = remember_synthesized(data, parked)
```

(d) The `{:append_message, role, content}` effect:

```elixir
      {:append_message, role, content} ->
        guarded(
          data,
          :append,
          fn ->
            content = synthesized_after_hooks(data, role, content)
            {content, data.handlers.append.(data.config, role, content)}
          end,
          fn {content, config} ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case append_to_store(data, config, role, content) do
              :ok -> interpret(rest, %{forget_synthesized(data, content) | config: config})
              # Memory must match the store: do not adopt `config` when the write failed,
              # so the next turn's repair sees exactly what the store lacks.
              {:error, reason} -> fail(data, {:persist_failed, reason})
            end
          end
        )
```

(e) Helpers, next to `interrupted_result/1`:

```elixir
  defp remember_synthesized(data, calls) do
    %{data | synthesized: Map.merge(data.synthesized, Map.new(calls, &{&1.id, &1}))}
  end

  # The core builds approval-rejected and -expired results itself, so they never pass
  # Dispatch.execute/4; their after-hooks run here, where they enter memory.
  defp synthesized_after_hooks(
         %Data{synthesized: synthesized} = data,
         "tool",
         %Normandy.Components.ToolResult{tool_call_id: id} = result
       )
       when is_map_key(synthesized, id) do
    Dispatch.apply_after_hooks(
      data.config,
      Map.fetch!(synthesized, id),
      result,
      BaseAgent.base_agent_pipeline(data.config)
    )
  end

  defp synthesized_after_hooks(_data, _role, content), do: content

  defp forget_synthesized(data, %Normandy.Components.ToolResult{tool_call_id: id}),
    do: %{data | synthesized: Map.delete(data.synthesized, id)}

  defp forget_synthesized(data, _content), do: data
```

(f) `close_batch/2` — run the after-hooks on each interrupted result before it is folded in:

```elixir
  defp close_batch(data, missing) do
    call_handler(data, :append, fn ->
      pipeline = BaseAgent.base_agent_pipeline(data.config)

      {repairs, _config} =
        Enum.map_reduce(missing, data.config, fn call, config ->
          result =
            Dispatch.apply_after_hooks(
              config,
              Dispatch.to_tool_call(call),
              interrupted_result(call),
              pipeline
            )

          folded = data.handlers.append.(config, "tool", result)
          {{call, result, folded}, folded}
        end)

      repairs
    end)
  end
```

Update the comment above `close_batch/2`: add "Each result passes the after-hooks first, like any tool result."

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn test/agents/dispatch_split_test.exs test/hooks`
Expected: PASS.

- [ ] **Step 6: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/agents/dispatch.ex lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs test/agents/dispatch_split_test.exs
git commit -m "feat(hooks): after-hooks run on approval-rejected, -expired and interrupted results"
```

### Task 8: DSL `hooks` declaration

**Files:**
- Modify: `lib/normandy/dsl/agent.ex` (`__using__/1`, new `hooks/1` macro, `@agent_compile_config`, `config/0`, `build_config/2`, new `put_declared_hooks/2`)
- Test: `test/dsl/agent_hooks_test.exs`

**Interfaces:**
- Consumes: `Hooks.validate_entries!(entries, load: false)` (Task 1); `BaseAgent.init/1` full validation (Task 3).
- Produces: `hooks [{Mod, opts}, …]` inside `agent do … end`; declared entries run before any `hooks` in a `behaviours:` passed to `new/1`.

- [ ] **Step 1: Write the failing tests**

`test/dsl/agent_hooks_test.exs`:

```elixir
defmodule Normandy.DSL.AgentHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Config
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}

  defmodule HookedAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      hooks([{Normandy.Test.Hooks.Probe, tag: :dsl, on_error: :open}])
    end
  end

  defmodule PlainAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "declared hooks reach the agent's behaviours" do
    {:ok, agent} = HookedAgent.new(client: client())
    assert agent.behaviours.hooks == [{Probe, tag: :dsl, on_error: :open}]
    assert HookedAgent.config().hooks == [{Probe, tag: :dsl, on_error: :open}]
  end

  test "declared hooks run before hooks given at runtime" do
    {:ok, agent} =
      HookedAgent.new(
        client: client(),
        behaviours: %Config{hooks: [{TurnEndOnly, []}]}
      )

    assert agent.behaviours.hooks == [{Probe, tag: :dsl, on_error: :open}, {TurnEndOnly, []}]
  end

  test "an agent without hooks keeps the default behaviours" do
    {:ok, agent} = PlainAgent.new(client: client())
    assert agent.behaviours in [nil, %Config{}]
  end

  test "a malformed literal declaration fails at compile time" do
    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.BadOnError do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([{Normandy.Test.Hooks.Probe, on_error: :sometimes}])
        end
      end
      """)
    end

    assert_raise ArgumentError, ~r/invalid hook entry/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.BadShape do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([Normandy.Test.Hooks.Probe])
        end
      end
      """)
    end
  end

  test "a module that does not exist fails at new/1" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.MissingModule do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([{Normandy.DSL.AgentHooksTest.NoSuchHook, []}])
        end
      end
      """)

    assert_raise ArgumentError, ~r/hook module .*NoSuchHook is not available/, fn ->
      mod.new(client: client())
    end
  end
end
```

Check what `PlainAgent.new/1` leaves in `behaviours` today (`nil` or `%Config{}`) and pin the third test to that exact value.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/dsl/agent_hooks_test.exs`
Expected: FAIL — `undefined function hooks/1` (CompileError) for `HookedAgent`.

- [ ] **Step 3: Implement**

In `lib/normandy/dsl/agent.ex`:

`__using__/1` — register the attribute:

```elixir
      Module.register_attribute(__MODULE__, :agent_hooks, accumulate: false)
```

The macro, after `guardrails/3`:

```elixir
  @doc """
  Declares lifecycle hooks (`Normandy.Behaviours.Hooks`): an ordered list of
  `{module, opts}` entries. They run before any `hooks` in a `behaviours:` given to
  `new/1`. A literal list is shape-checked at compile time; modules and their opts are
  checked when `new/1` builds the agent.

      hooks [{MyApp.Redact, fields: [:ssn]}, {MyApp.Audit, on_error: :open}]
  """
  defmacro hooks(entries) do
    expanded = Macro.prewalk(entries, &Macro.expand(&1, __CALLER__))

    if Macro.quoted_literal?(expanded),
      do: Normandy.Behaviours.Hooks.validate_entries!(expanded, load: false)

    quote do
      Module.put_attribute(__MODULE__, :agent_hooks, unquote(entries))
    end
  end
```

`@agent_compile_config` in `__before_compile__/1`: add `hooks: Module.get_attribute(__MODULE__, :agent_hooks) || [],`.

`config/0`: add `hooks: @agent_compile_config.hooks,`.

`build_config/2`: change the last expression so declared hooks are merged after the overrides:

```elixir
        config = Map.merge(base_config, Map.new(overrides))
        config = Normandy.DSL.Agent.put_declared_hooks(config, @agent_compile_config.hooks)
```

(insert the second line right after the existing `config = Map.merge(…)` line).

Public helper, next to `memory_tool!/3`:

```elixir
  @doc false
  # Declared hooks first, then any given at runtime in `behaviours:`.
  def put_declared_hooks(config, []), do: config

  def put_declared_hooks(config, declared) do
    behaviours = Map.get(config, :behaviours) || %Normandy.Behaviours.Config{}
    Map.put(config, :behaviours, %{behaviours | hooks: declared ++ behaviours.hooks})
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/dsl`
Expected: PASS.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/dsl/agent.ex test/dsl/agent_hooks_test.exs
git commit -m "feat(hooks): hooks declaration in the agent DSL"
```

---

### Task 9: Guide, migration notes, project docs

**Files:**
- Create: `docs/guides/hooks.md`
- Modify: `mix.exs` (docs `extras`: add `"docs/guides/hooks.md"` next to `"docs/guides/agent-memory.md"`)
- Modify: `MIGRATING-2.0.md` (new section after §15)
- Modify: `CLAUDE.md` (Architecture: new "Lifecycle Hooks" subsection after "Long-term Memory & Tool Context")
- Modify: `lib/normandy/agents/turn/inline.ex` (moduledoc: one sentence)
- Modify: `docs/superpowers/specs/2026-10-03-agent-hooks-design.md` (§3: turn_id note)

**Interfaces:**
- Consumes: everything above. Every code example must use the real API: `%Normandy.Behaviours.Config{hooks: …}`, the callbacks' exact arities, `Normandy.HookHaltError`, `{:error, {:hook_halted, event, reason}}`.

- [ ] **Step 1: Write `docs/guides/hooks.md`**

Sections, in order (prose in the style of `docs/guides/agent-memory.md`; read it first):

1. **What hooks are for** — the four purposes; "to only observe, attach to telemetry (`Normandy.Telemetry`)".
2. **Declaring hooks** — `%Normandy.Behaviours.Config{hooks: [{Mod, opts}]}` on `BaseAgentConfig.behaviours`, and the DSL `hooks [...]`; order; opts are plain data (saved with the session template) — name a registered process instead of a pid.
3. **Events** — a table: event, where it fires, return values, what the return does (copy from spec §5; include "`on_session_start` fires only for a session with nothing stored", "`after_compact` fires only when the compactor removed something", "`on_prompt` runs before validation and input guardrails").
4. **Halts** — `HookHaltError` from `BaseAgent`; `{:error, {:hook_halted, event, reason}}` from `Turn.Server`; what `on_turn_end` sees.
5. **Errors (`:on_error`)** — the three modes, the logged-only events and why, the return-contract `ArgumentError`.
6. **Injection** — appended as `"user"` messages; session-start injections are stored, `after_compact` injections are memory-only and why.
7. **Examples** — four complete modules:
   - `MyApp.Hooks.Redact` — `on_prompt` replacing digits runs in a `%Normandy.Agents.BaseAgentInputSchema{chat_message: text}` with `Regex.replace(~r/\d{3}-\d{2}-\d{4}/, text, "[ssn]")`, passing anything else through.
   - `MyApp.Hooks.Profile` — `on_session_start` reading `ctx.values[:user_id]` and returning `{:inject, ["User profile: …"]}` (stubbed lookup function).
   - `MyApp.Hooks.SaveDropped` — `after_compact` writing each dropped message into the memory store with `Normandy.Behaviours.MemoryStore` (use the store from opts as `{module, handle}` where the handle is a registered name or atom, and the namespace from `ctx.values[:memory_namespace]`); read `docs/guides/agent-memory.md` and `lib/normandy/behaviours/memory_store.ex` for the exact callback names and arities before writing it.
   - `MyApp.Hooks.Audit` — `after_tool` and `on_turn_end` writing via `Logger.info/1`, with `on_error: :open` in the declaration.
8. **What hooks do not cover** — `Turn.Inline`; no session-end event (passivation only; supervisor shutdown, kill and node loss run no callback); no LLM request/response rewriting; `BaseAgent.admit/2,3` runs no hooks.
9. **Telemetry** — the `[:normandy, :hook, …]` span and its `result` values.

- [ ] **Step 2: Migration notes**

`MIGRATING-2.0.md`, new section (next number after §15, same heading style):

```markdown
## 16. Lifecycle hooks

- New: `Normandy.Behaviours.Hooks` modules on `Behaviours.Config.hooks` (see
  `docs/guides/hooks.md`). No hooks are configured by default; nothing changes for an
  agent that sets none.
- **Behaviour change:** `after_hooks` functions now also run on tool results `Turn.Server`
  produces without running the tool — approval rejected, approval expired, and the
  interrupted results it records when a turn was cut short. A hook that assumed every
  result came from a tool run should check `result.is_error` and `result.output`.
- New error and reply: `Normandy.HookHaltError` (raised by `BaseAgent` when an
  `on_prompt` or `before_llm` hook halts) and `{:error, {:hook_halted, event, reason}}`
  (replied by `Turn.Server.run/2`).
- Config templates gain `behaviours_refs.hooks`; templates saved earlier rebuild with
  `[]`.
```

- [ ] **Step 3: CLAUDE.md, Inline moduledoc, spec note**

`CLAUDE.md`, after the "Long-term Memory & Tool Context" subsection:

```markdown
### Lifecycle Hooks

- **`Normandy.Behaviours.Hooks`** - Ordered `{module, opts}` entries on `Behaviours.Config.hooks`
  (persisted in the config template); optional callbacks `on_session_start`, `on_passivate`,
  `on_prompt`, `before_llm`, `before_tool`, `after_tool`, `after_compact`, `on_turn_end`
- **`Normandy.Hooks.Runner`** - The only caller of hook modules: order, rewrites, halts,
  `:on_error` (`:reraise`/`:open`/`:closed`), logged-only events, return contracts, the
  `[:normandy, :hook, *]` span. Called from `Config.to_pipeline/1` (tool hooks, ahead of the
  `before_hooks`/`after_hooks` functions), `BaseAgent` and `Turn.Server`; `Turn.Inline` runs none
```

`lib/normandy/agents/turn/inline.ex` moduledoc: append "Lifecycle hooks (`Normandy.Behaviours.Hooks`) do not run here: the caller supplies every effect function."

Spec §3, the `turn_id` bullet: append "and for `on_turn_end` after a `BaseAgent` run that raised (the run's config is lost with the exception)."

- [ ] **Step 4: Verify the docs build and links**

Run: `mix docs 2>&1 | grep -iE "warning|error" ; echo "exit: $?"`
Expected: no warnings mentioning `hooks.md`, `Hooks` or `HookHaltError`. Fix any broken reference.

Run: `mix format && mix test`
Expected: ` 0 failures`.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add docs/guides/hooks.md mix.exs MIGRATING-2.0.md CLAUDE.md lib/normandy/agents/turn/inline.ex docs/superpowers/specs/2026-10-03-agent-hooks-design.md
git commit -m "docs(hooks): hooks guide, migration notes, architecture entry"
```
