# Agent Lifecycle Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistable `Normandy.Behaviours.Hooks` behaviour — an ordered list of `{module, opts}` entries on `Behaviours.Config` — whose callbacks run at eight lifecycle points and can rewrite, halt, inject or audit, without any hook outcome being able to terminate a `Turn.Server`.

**Architecture:** One `Normandy.Hooks.Runner` owns calling hook modules (order, rewrite threading, halts, `:on_error`, return contracts, telemetry); its functions take the agent's config. Call sites live in three small glue modules so `base_agent.ex` and `server.ex` keep one-line call sites: `Normandy.Hooks.BaseAgentGlue` (`on_prompt`, `on_turn_end` for `BaseAgent`), `Normandy.Hooks.ServerGlue` (session start, core-built results for `Turn.Server`) and `Normandy.Hooks.Handlers` (wraps any `Turn.Driver.Handlers` set with `before_llm`/`after_compact`, used by both shells). Tool hooks enter through `Config.to_pipeline/1` (a `before_hooks` adapter and a new `Dispatch.Pipeline.after_tool` slot). `after_compact` reads the entries a compactor reports in `meta.dropped`. The pure `Turn` core does not change.

**Tech Stack:** Elixir, ExUnit, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-10-03-agent-hooks-design.md`

## Global Constraints

- Events, exactly: `on_session_start/2`, `on_passivate/2`, `on_prompt/3`, `before_llm/3`, `before_tool/3`, `after_tool/4`, `after_compact/4`, `on_turn_end/3`; plus optional `validate_opts!/1`. All optional. `Hooks.events/0` is the single source; `@optional_callbacks` derives from it.
- `Behaviours.Config.hooks` defaults to `[]`; an agent with no hooks behaves byte-identically to today, and its hot paths (`BaseAgent.run/2`, `Turn.Server` turns) build no hook context and emit no hook telemetry.
- Hook opts are plain data (no function, pid, reference or port) and are checked at `BaseAgent.init/1`. Tests reach the test process through `Normandy.Test.Hooks.sink/0` (a registered name), never `self()`.
- `:on_error` is `:reraise` (default) | `:open` | `:closed`, removed from opts before a callback sees them; per-event meaning is the spec §4 table.
- Logged-only events (`on_turn_end`, `on_passivate`) never raise and ignore return values. Other events check a return value only where the library consumes it (spec §1 table) and raise `ArgumentError` on a violation, whatever `:on_error` says.
- Halts: `%Normandy.HookHaltError{event, hook, reason}`; `HookHaltError.outcome/1` maps it (`on_prompt` → `{:rejected, e}`, `before_llm` → `{:error, {:hook_halted, e}}`) for both shells.
- No hook outcome terminates `Turn.Server`: every hook call in the server process goes through `call_handler/3`; `on_turn_end` runs after the reply.
- Every tool result the model sees passes the module `after_tool` exactly once; the function `after_hooks` keep today's meaning (results of tools that ran).
- `after_compact` fires only when `meta.dropped` is non-empty; its injections are memory-only. `on_session_start` injections are written to the session store as one entry.
- No hook timeouts. Hooks run inline.
- Repo rules: run `mix format` before tests; run `mix precommit` before every commit and commit only when its output contains ` 0 failures` (never chain a commit after `mix precommit | tail`); `git add` files individually, never `git add .`; commit messages carry no AI attribution (no Co-Authored-By, no "Generated with"); never run `mix e2e`; leave `investigations/genai-telemetry-audit.md` untracked and untouched.
- Line numbers below are as of commit `b241330` (lib is unchanged at `66f8e39`); locate code by the quoted function names if they moved. Each task's replacement code shows the full new text of what it replaces.
- Credo: a complexity or nesting finding gets an inline `# credo:disable-for-next-line <Check>` on the flagged line, never a config change (CLAUDE.md).

## Review Focus

1. `on_prompt` receives the validated input; a rewrite to a plain map the input schema rejects raises `Normandy.Schema.ValidationError` with nothing in memory and no LLM call, while a rewrite that is already the schema's struct is trusted as a caller's struct is (`validation_middleware.ex:56-59`) (tests in Task 6).
2. A hook that raises in `on_prompt` under the default `:reraise` inside `Turn.Server` — expect `{:error, {:handler_crashed, :admit, %RuntimeError{}}}` and a live server, not a crashed session (test in Task 6).
3. `Compactor.WindowManager` (`:oldest_first`) through `BaseAgent.run` — expect `after_compact` to receive exactly the removed entries with the ids they had, and the kept entries to keep theirs (tests in Tasks 3 and 8).
4. A `Turn.Server` started with custom `:handlers` (stubbed `call_llm`) — expect `before_llm` to run once per LLM call and a halt to reply `{:error, {:hook_halted, %HookHaltError{event: :before_llm}}}` (test in Task 8).
5. Approval expiry with `on_approval_timeout: :fail` — expect each expired result to pass `after_tool` exactly once before the turn fails, and the function `after_hooks` not to see it (test in Task 10).

---

### Task 1: Behaviour with `use` checks, context, halt error, entry validation, `Config.hooks`

**Files:**
- Create: `lib/normandy/behaviours/hooks.ex`
- Create: `lib/normandy/hooks/context.ex`
- Modify: `lib/normandy/exceptions.ex` (append `Normandy.HookHaltError`)
- Modify: `lib/normandy/behaviours/config.ex` (struct field `hooks: []`, type, moduledoc sentence)
- Test: `test/behaviours/hooks_test.exs`, `test/hooks/context_test.exs`, `test/hooks/hook_halt_error_test.exs`

**Interfaces:**
- Produces:
  - `Normandy.Behaviours.Hooks.events() :: [{atom(), non_neg_integer()}]` — the eight event callbacks, the single source for `@optional_callbacks`.
  - `use Normandy.Behaviours.Hooks` — sets `@behaviour`; compile-time `check_definitions!/1`.
  - `Normandy.Behaviours.Hooks.validate_entries!(entries, opts \\ []) :: :ok` — raises `ArgumentError`; `load: false` checks shape, `:on_error` and plain data only.
  - `Normandy.Behaviours.Hooks.check_entries(entries) :: :ok | {:error, {:invalid_hooks, String.t()}}`.
  - `Normandy.Hooks.Context.build(config, event, opts \\ []) :: %Context{}` — `turn_id:` in opts overrides the memory's (pass `turn_id: nil` to force nil).
  - `%Normandy.HookHaltError{event, hook, reason}` and `HookHaltError.outcome/1`.
  - `%Normandy.Behaviours.Config{hooks: []}`.

- [ ] **Step 1: Write the failing tests**

`test/behaviours/hooks_test.exs`:

```elixir
defmodule Normandy.Behaviours.HooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Normandy.Behaviours.Hooks

  defmodule OnlyTurnEnd do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_turn_end(_outcome, _ctx, _opts), do: :ok
  end

  defmodule NoCallbacks do
    def unrelated, do: :ok
  end

  # Plain @behaviour, no `use`: only validate_entries!/2 sees the function-hook arity.
  defmodule FunctionHookArity do
    @behaviour Normandy.Behaviours.Hooks
    def before_tool(_config, call), do: {:cont, call}
  end

  defmodule ChecksOpts do
    use Normandy.Behaviours.Hooks

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

  test "every callback is optional and the callbacks are exactly events/0 plus validate_opts!/1" do
    expected = Enum.sort(Hooks.events() ++ [validate_opts!: 1])
    assert Enum.sort(Hooks.behaviour_info(:optional_callbacks)) == expected
    assert Enum.sort(Hooks.behaviour_info(:callbacks)) == expected
  end

  test "Behaviours.Config has hooks: [] by default" do
    assert %Normandy.Behaviours.Config{}.hooks == []
  end

  test "accepts an empty list and well-formed entries" do
    assert :ok = Hooks.validate_entries!([])
    assert :ok = Hooks.validate_entries!([{OnlyTurnEnd, []}, {OnlyTurnEnd, on_error: :open}])
  end

  test "rejects a non-list" do
    assert_raise ArgumentError,
                 ~r/hooks must be a list of \{module, opts\} entries, got: :nope/,
                 fn -> Hooks.validate_entries!(:nope) end
  end

  test "rejects an entry that is not {module, keyword}" do
    assert_raise ArgumentError,
                 ~r/invalid hook entry Normandy\.Behaviours\.HooksTest\.OnlyTurnEnd: expected \{module, keyword_opts\}/,
                 fn -> Hooks.validate_entries!([OnlyTurnEnd]) end

    assert_raise ArgumentError, ~r/invalid hook entry/, fn ->
      Hooks.validate_entries!([{OnlyTurnEnd, %{}}])
    end
  end

  test "rejects an unknown :on_error" do
    assert_raise ArgumentError,
                 ~r/invalid :on_error for .*OnlyTurnEnd: expected :reraise, :open or :closed, got: :maybe/,
                 fn -> Hooks.validate_entries!([{OnlyTurnEnd, on_error: :maybe}]) end
  end

  test "rejects opts holding a pid, function or reference, at any depth and without loading" do
    for bad <- [self(), fn -> :ok end, make_ref()] do
      assert_raise ArgumentError, ~r/hook opts for .*OnlyTurnEnd must be plain data/, fn ->
        Hooks.validate_entries!([{OnlyTurnEnd, notify: bad}])
      end
    end

    assert_raise ArgumentError, ~r/must be plain data/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, sink: %{to: [self()]}}], load: false)
    end
  end

  test "rejects a module that is not available" do
    assert_raise ArgumentError, ~r/hook module Does.Not.Exist is not available/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, []}])
    end
  end

  test "rejects a module that exports none of the hook callbacks" do
    assert_raise ArgumentError, ~r/exports none of the hook callbacks/, fn ->
      Hooks.validate_entries!([{NoCallbacks, []}])
    end
  end

  test "rejects a module exporting an event name only with the wrong arity" do
    assert_raise ArgumentError,
                 ~r/exports before_tool\/2, but the hook callback is before_tool\/3/,
                 fn -> Hooks.validate_entries!([{FunctionHookArity, []}]) end
  end

  test "runs validate_opts!/1 without :on_error and names the hook when it fails" do
    assert :ok = Hooks.validate_entries!([{ChecksOpts, label: "x", on_error: :open}])

    assert_raise ArgumentError,
                 ~r/invalid opts for hook Normandy\.Behaviours\.HooksTest\.ChecksOpts: label must be a string/,
                 fn -> Hooks.validate_entries!([{ChecksOpts, []}]) end
  end

  test "load: false checks shape, :on_error and plain data only" do
    assert :ok = Hooks.validate_entries!([{Does.Not.Exist, []}], load: false)

    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, on_error: :x}], load: false)
    end
  end

  test "check_entries/1 returns the validation error as data" do
    assert Hooks.check_entries([{OnlyTurnEnd, []}]) == :ok

    assert Hooks.check_entries([{Does.Not.Exist, []}]) ==
             {:error, {:invalid_hooks, "hook module Does.Not.Exist is not available"}}
  end

  test "use raises for an event name with the wrong arity" do
    assert_raise ArgumentError,
                 ~r/on_prompt\/2 is not a hook callback: on_prompt takes 3 arguments/,
                 fn ->
                   Code.compile_string("""
                   defmodule Normandy.Behaviours.HooksTest.WrongArity do
                     use Normandy.Behaviours.Hooks
                     def on_prompt(input, _ctx), do: {:cont, input}
                   end
                   """)
                 end
  end

  test "use warns for a name close to an event's" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Normandy.Behaviours.HooksTest.Misspelled do
          use Normandy.Behaviours.Hooks
          def on_promt(input, _ctx, _opts), do: {:cont, input}
          def on_turn_end(_outcome, _ctx, _opts), do: :ok
        end
        """)
      end)

    assert warning =~ "on_promt is not a hook callback; did you mean on_prompt?"
  end
end
```

`test/hooks/context_test.exs`:

```elixir
defmodule Normandy.Hooks.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context

  test "builds the event, names, model and values; the turn id comes from memory" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()

    config = %{
      name: "a",
      model: "m",
      session_id: "s",
      memory: memory,
      tool_context: %{user: 1},
      client: %{api_key: "sk-secret"}
    }

    ctx = Context.build(config, :after_tool)

    assert %Context{
             event: :after_tool,
             agent_name: "a",
             model: "m",
             session_id: "s",
             values: %{user: 1}
           } = ctx

    assert ctx.turn_id == memory.current_turn_id
    refute is_nil(ctx.turn_id)
    refute inspect(ctx) =~ "sk-secret"
  end

  test "turn_id: nil forces no turn id; missing fields default" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    assert %Context{turn_id: nil} = Context.build(%{memory: memory}, :on_prompt, turn_id: nil)

    assert %Context{values: %{}, session_id: nil, agent_name: nil, model: nil, turn_id: nil} =
             Context.build(%{}, :on_passivate)
  end

  test "the context carries no config" do
    refute Map.has_key?(%Context{}, :config)
  end
end
```

`test/hooks/hook_halt_error_test.exs`:

```elixir
defmodule Normandy.HookHaltErrorTest do
  use ExUnit.Case, async: true

  alias Normandy.HookHaltError

  test "message names the event, hook and reason" do
    e = %HookHaltError{event: :on_prompt, hook: MyApp.Redact, reason: "contains SSN"}
    assert Exception.message(e) == "hook MyApp.Redact halted on_prompt: contains SSN"
  end

  test "outcome/1: an on_prompt halt is a rejection, a before_llm halt an error" do
    prompt = %HookHaltError{event: :on_prompt, hook: MyApp.Redact, reason: "r"}
    llm = %HookHaltError{event: :before_llm, hook: MyApp.Budget, reason: "r"}

    assert HookHaltError.outcome(prompt) == {:rejected, prompt}
    assert HookHaltError.outcome(llm) == {:error, {:hook_halted, llm}}
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/behaviours/hooks_test.exs test/hooks/context_test.exs test/hooks/hook_halt_error_test.exs`
Expected: FAIL — compilation error, `Normandy.Behaviours.Hooks` is not loaded (the test modules `use` it).

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
  Hooks run inline, with no timeout: a slow hook stalls its turn, so hand slow side effects
  to a process of your own.

  `use Normandy.Behaviours.Hooks` sets `@behaviour` and checks at compile time that a
  public function named like an event has that event's arity (`ArgumentError` otherwise),
  and warns for a public function whose name is close to an event's (`on_promt`).

  Return values, checked only where the library consumes them:

  | Callback | Pass | Change | Stop |
  |---|---|---|---|
  | `on_prompt/3` | `{:cont, input}` | `{:cont, new_input}` | `{:halt, reason}` |
  | `before_llm/3` | `:cont` | — | `{:halt, reason}` |
  | `before_tool/3` | `{:cont, call}` | `{:cont, new_call}` | `{:halt, reason}` or `{:halt, %ToolResult{}}` |
  | `after_tool/4` | `{:cont, result}` | `{:cont, new_result}` | — |
  | `after_compact/4`, `on_session_start/2` | any value | `{:inject, [String.t()]}` | — |
  | `on_turn_end/3`, `on_passivate/2` | any value (ignored) | — | — |

  `opts` must be plain data (no function, pid, reference or port) and hold no secrets: the
  list is saved in the session's plaintext config template. `:on_error` (`:reraise`
  default, `:open`, `:closed`) is reserved and removed before a callback sees `opts`. See
  `docs/guides/hooks.md`.
  """

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Context

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

  @type opts :: keyword()
  @type entry :: {module(), opts()}
  @type outcome ::
          {:ok, response :: term()} | {:error, reason :: term()} | {:rejected, Exception.t()}

  @callback on_session_start(Context.t(), opts()) :: {:inject, [String.t()]} | term()
  @callback on_passivate(Context.t(), opts()) :: term()
  @callback on_prompt(input :: term(), Context.t(), opts()) ::
              {:cont, term()} | {:halt, reason :: String.t()}
  @callback before_llm(%{final: boolean(), iterations_left: integer()}, Context.t(), opts()) ::
              :cont | {:halt, reason :: String.t()}
  @callback before_tool(ToolCall.t(), Context.t(), opts()) ::
              {:cont, ToolCall.t()} | {:halt, String.t() | ToolResult.t()}
  @callback after_tool(ToolCall.t(), ToolResult.t(), Context.t(), opts()) ::
              {:cont, ToolResult.t()}
  @callback after_compact(dropped :: [Entry.t()], meta :: map(), Context.t(), opts()) ::
              {:inject, [String.t()]} | term()
  @callback on_turn_end(outcome(), Context.t(), opts()) :: term()
  @callback validate_opts!(opts()) :: term()

  @optional_callbacks @events ++ [validate_opts!: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour Normandy.Behaviours.Hooks
      @before_compile Normandy.Behaviours.Hooks
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    for warning <- check_definitions!(Module.definitions_in(env.module, :def)) do
      IO.warn(warning, Macro.Env.stacktrace(env))
    end

    nil
  end

  @doc "The event callbacks, as `{name, arity}`."
  @spec events() :: [{atom(), non_neg_integer()}]
  def events, do: @events

  @doc false
  # Compile-time check for `use`: raises for a public function named like an event with
  # another arity; returns a warning for each public function whose name is close to an
  # event's. A misspelled callback is skipped at runtime, silently.
  @spec check_definitions!([{atom(), non_neg_integer()}]) :: [String.t()]
  def check_definitions!(definitions) do
    Enum.each(definitions, fn {name, arity} -> check_definition_arity!(name, arity) end)

    definitions
    |> Enum.flat_map(fn {name, _arity} -> near_miss(name) end)
    |> Enum.uniq()
  end

  defp check_definition_arity!(name, arity) do
    case Keyword.fetch(@events, name) do
      {:ok, ^arity} ->
        :ok

      {:ok, expected} ->
        raise ArgumentError,
              "#{name}/#{arity} is not a hook callback: #{name} takes #{expected} arguments"

      :error ->
        :ok
    end
  end

  defp near_miss(name) do
    if Keyword.has_key?(@events, name) or name == :validate_opts! do
      []
    else
      text = Atom.to_string(name)

      for {event, _arity} <- @events,
          String.jaro_distance(text, Atom.to_string(event)) >= 0.9,
          do: "#{name} is not a hook callback; did you mean #{event}? A misspelled callback never runs"
    end
  end

  @doc """
  Raises `ArgumentError` naming the first malformed entry. With `load: false` (DSL compile
  time and `ConfigTemplate.from_config/2`, where the module may not be loaded) only the
  entry shape, `:on_error` and the plain-data rule are checked.
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

  @doc """
  `validate_entries!/1` as data, for `Turn.Server`: an invalid list (a hook module missing
  on this node, say) is reported like a store fault instead of crashing the start.
  """
  @spec check_entries(term()) :: :ok | {:error, {:invalid_hooks, String.t()}}
  def check_entries(entries) do
    validate_entries!(entries)
  rescue
    e in ArgumentError -> {:error, {:invalid_hooks, Exception.message(e)}}
  end

  defp validate_entry!({mod, opts} = entry, load?) when is_atom(mod) and is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_entry!(entry)
    validate_on_error!(mod, Keyword.get(opts, :on_error, :reraise))

    unless plain_data?(opts) do
      raise ArgumentError,
            "hook opts for #{inspect(mod)} must be plain data: they are saved in the " <>
              "session's config template. Found a function, pid, reference or port; name a " <>
              "registered process instead of passing a pid, and read secrets at call time."
    end

    if load?, do: validate_module!(mod, Keyword.delete(opts, :on_error))
    :ok
  end

  defp validate_entry!(entry, _load?), do: invalid_entry!(entry)

  defp invalid_entry!(entry) do
    raise ArgumentError,
          "invalid hook entry #{inspect(entry)}: expected {module, keyword_opts}"
  end

  defp validate_on_error!(_mod, policy) when policy in @on_error, do: :ok

  defp validate_on_error!(mod, other) do
    raise ArgumentError,
          "invalid :on_error for #{inspect(mod)}: expected :reraise, :open or :closed, " <>
            "got: #{inspect(other)}"
  end

  defp validate_module!(mod, opts) do
    unless Code.ensure_loaded?(mod) do
      raise ArgumentError, "hook module #{inspect(mod)} is not available"
    end

    exports = mod.module_info(:exports)
    Enum.each(@events, fn {event, arity} -> check_export_arity!(mod, exports, event, arity) end)

    unless Enum.any?(@events, &(&1 in exports)) do
      raise ArgumentError,
            "hook module #{inspect(mod)} exports none of the hook callbacks " <>
              Enum.map_join(@events, ", ", fn {f, a} -> "#{f}/#{a}" end)
    end

    if {:validate_opts!, 1} in exports, do: run_validate_opts!(mod, opts)
    :ok
  end

  # A module without `use` gets this check here instead of at compile time.
  defp check_export_arity!(mod, exports, event, arity) do
    case for({^event, other} <- exports, other != arity, do: other) do
      [] ->
        :ok

      [other | _] ->
        unless {event, arity} in exports do
          raise ArgumentError,
                "hook module #{inspect(mod)} exports #{event}/#{other}, but the hook " <>
                  "callback is #{event}/#{arity}"
        end
    end
  end

  defp run_validate_opts!(mod, opts) do
    mod.validate_opts!(opts)
  rescue
    e ->
      reraise ArgumentError,
              "invalid opts for hook #{inspect(mod)}: #{Exception.message(e)}",
              __STACKTRACE__
  end

  defp plain_data?(value)
       when is_function(value) or is_pid(value) or is_reference(value) or is_port(value),
       do: false

  defp plain_data?([head | tail]), do: plain_data?(head) and plain_data?(tail)
  defp plain_data?(value) when is_tuple(value), do: value |> Tuple.to_list() |> plain_data?()
  defp plain_data?(%_{} = value), do: value |> Map.from_struct() |> plain_data?()

  defp plain_data?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> plain_data?(k) and plain_data?(v) end)

  defp plain_data?(_value), do: true
end
```

`lib/normandy/hooks/context.ex`:

```elixir
defmodule Normandy.Hooks.Context do
  @moduledoc """
  What a hook callback knows about the agent it runs for: the `event`, the agent's `name`
  (`agent_name`), `model` and `session_id`, the `turn_id`, and `values` (the agent's
  `tool_context`). It carries no config, memory or client, so a hook that logs it leaks
  nothing the agent was not told to share.

  `turn_id` is `nil` for `on_session_start`, `on_passivate` and `on_prompt` (the prompt is
  admitted before the turn starts), and for `on_turn_end` after a rejected input or a
  `BaseAgent` run that raised.
  """

  defstruct [:event, :agent_name, :model, :session_id, :turn_id, values: %{}]

  @type t :: %__MODULE__{
          event: atom() | nil,
          agent_name: String.t() | nil,
          model: String.t() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          values: map()
        }

  @doc "Builds the context for `event` from `config`; `turn_id:` in `opts` overrides the memory's."
  @spec build(map(), atom(), keyword()) :: t()
  def build(config, event, opts \\ []) do
    %__MODULE__{
      event: event,
      agent_name: Map.get(config, :name),
      model: Map.get(config, :model),
      session_id: Map.get(config, :session_id),
      turn_id: Keyword.get_lazy(opts, :turn_id, fn -> memory_turn_id(config) end),
      values: Map.get(config, :tool_context) || %{}
    }
  end

  defp memory_turn_id(%{memory: %{current_turn_id: id}}), do: id
  defp memory_turn_id(_config), do: nil
end
```

Append to `lib/normandy/exceptions.ex`:

```elixir

defmodule Normandy.HookHaltError do
  @moduledoc """
  Raised by `Normandy.Agents.BaseAgent` when an `on_prompt` or `before_llm` hook halts the
  turn. `outcome/1` is how both shells report it: `Turn.Server` replies
  `{:error, outcome_reason}` and `on_turn_end` hooks receive the outcome.
  """
  defexception [:event, :hook, :reason]

  @type t :: %__MODULE__{event: atom(), hook: module(), reason: String.t()}

  @impl true
  def message(%__MODULE__{event: event, hook: hook, reason: reason}) do
    "hook #{inspect(hook)} halted #{event}: #{reason}"
  end

  @doc """
  An `on_prompt` halt is a rejection (the input never became a turn, nothing is stored):
  `{:rejected, e}`. A `before_llm` halt fails a started turn: `{:error, {:hook_halted, e}}`.
  """
  @spec outcome(t()) :: {:rejected, t()} | {:error, {:hook_halted, t()}}
  def outcome(%__MODULE__{event: :on_prompt} = e), do: {:rejected, e}
  def outcome(%__MODULE__{} = e), do: {:error, {:hook_halted, e}}
end
```

`lib/normandy/behaviours/config.ex`:
- Moduledoc: after "One `{module, opts}` ref per behaviour plus the two first-class hook lists." add the sentence: "`hooks` is an ordered list of `Normandy.Behaviours.Hooks` entries, persisted with the refs."
- In the `@type t` map, after `after_hooks: [hook()],` add `hooks: [Normandy.Behaviours.Hooks.entry()],`.
- In `defstruct`, after `after_hooks: [],` add `hooks: [],`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/behaviours/hooks_test.exs test/hooks/context_test.exs test/hooks/hook_halt_error_test.exs test/behaviours/config_test.exs`
Expected: PASS (`config_test.exs` proves the existing bundle behaviour is unchanged).

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures` (credo or dialyzer findings must be fixed first).

```bash
git add lib/normandy/behaviours/hooks.ex lib/normandy/hooks/context.ex lib/normandy/exceptions.ex lib/normandy/behaviours/config.ex test/behaviours/hooks_test.exs test/hooks/context_test.exs test/hooks/hook_halt_error_test.exs
git commit -m "feat(hooks): Hooks behaviour with compile-time checks, hook context, HookHaltError, entry validation"
```

### Task 2: The Runner, test probes, telemetry catalogue

**Files:**
- Create: `lib/normandy/hooks/runner.ex`
- Create: `test/support/hook_probes.ex`
- Modify: `lib/normandy/telemetry.ex` (moduledoc: the hook span, after the `[:normandy, :memory, :command, …]` entry)
- Test: `test/hooks/runner_test.exs`

**Interfaces:**
- Consumes: `Hooks.events/0`, `Hooks.Context.build/3` (Task 1).
- Produces (each takes the agent's config; the entries are `config.behaviours.hooks`; with no entry exporting the event's callback the pass value returns at once, with no context and no telemetry):
  - `Runner.entries(config) :: [Hooks.entry()]`, `Runner.hooks?(config) :: boolean()`, `Runner.handles?(config, event) :: boolean()`.
  - `Runner.prompt(config, input) :: {:cont, term()} | {:halt, module(), String.t()}`
  - `Runner.before_llm(config, %{final: boolean(), iterations_left: integer()}) :: :cont | {:halt, module(), String.t()}`
  - `Runner.before_tool(config, %ToolCall{}) :: {:cont, %ToolCall{}} | {:halt, %ToolResult{}}`
  - `Runner.after_tool(config, %ToolCall{}, %ToolResult{}) :: %ToolResult{}`
  - `Runner.after_compact(config, dropped :: [%AgentMemory.Entry{}], meta :: map()) :: [String.t()]`
  - `Runner.session_start(config) :: [String.t()]`
  - `Runner.passivate(config) :: :ok`
  - `Runner.turn_end(config, outcome, ctx_opts \\ []) :: :ok` — `ctx_opts` go to `Context.build/3` (e.g. `turn_id: nil`).
  - `Runner.contract(event) :: String.t()` (`@doc false`, drift test).
  - Test support: `Normandy.Test.Hooks.sink/0`, `Normandy.Test.Hooks.Probe`, `Normandy.Test.Hooks.TurnEndOnly` (used by Tasks 3–12).

- [ ] **Step 1: Create the test probes**

`test/support/hook_probes.ex`:

```elixir
defmodule Normandy.Test.Hooks do
  @moduledoc """
  Hook test helpers. Hook opts must be plain data (they are saved in config templates and
  checked at `BaseAgent.init/1`), so a test names its process instead of passing a pid:
  `sink/0` registers the calling process under a unique name, once, and returns the name.
  """

  @spec sink() :: atom()
  def sink do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _unregistered ->
        name = :"normandy_hook_sink_#{System.unique_integer([:positive])}"
        Process.register(self(), name)
        name
    end
  end
end

defmodule Normandy.Test.Hooks.Probe do
  @moduledoc """
  A hook implementing every event. Each call sends `{:hook, tag, event, args}` to
  `opts[:notify]` (a registered name; omitted = no message) and returns
  `opts[:returns][event]`, or passes (`{:cont, value}`, `:cont`, `:ok`).
  `returns: [on_prompt: {:raise, "boom"}]` raises a RuntimeError, `{:exit, reason}` exits,
  `{:throw, value}` throws. `tag` defaults to the module.
  """
  use Normandy.Behaviours.Hooks

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
  use Normandy.Behaviours.Hooks

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

  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Hooks.{Context, Runner}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}
  alias Normandy.Test.TelemetryCapture

  defmodule EchoOpts do
    @moduledoc false
    use Normandy.Behaviours.Hooks

    @impl true
    def on_passivate(_ctx, opts) do
      send(opts[:notify], {:opts, opts})
      :ok
    end
  end

  defp config(hooks, name \\ "runner-agent") do
    %{
      name: name,
      model: "m",
      session_id: "s",
      tool_context: %{u: 1},
      behaviours: %{hooks: hooks}
    }
  end

  defp probe(tag, opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: tag] ++ opts}
  defp call, do: %ToolCall{id: "c1", name: "t", input: %{"a" => 1}}
  defp result, do: %ToolResult{tool_call_id: "c1", output: "ok", is_error: false}
  defp info, do: %{final: false, iterations_left: 3}

  # Every message in the mailbox, in arrival order.
  defp mailbox do
    receive do
      msg -> [msg | mailbox()]
    after
      0 -> []
    end
  end

  describe "entries/1, hooks?/1, handles?/2" do
    test "read behaviours.hooks, else []" do
      assert Runner.entries(config([{Probe, []}])) == [{Probe, []}]
      assert Runner.entries(%{behaviours: nil}) == []
      assert Runner.entries(%{}) == []
      refute Runner.hooks?(config([]))
      assert Runner.hooks?(config([{TurnEndOnly, []}]))
      assert Runner.handles?(config([{TurnEndOnly, []}]), :on_turn_end)
      refute Runner.handles?(config([{TurnEndOnly, []}]), :on_prompt)
    end
  end

  describe "chains" do
    test "no entries passes the value through" do
      config = config([])
      assert Runner.prompt(config, "hi") == {:cont, "hi"}
      assert Runner.before_llm(config, info()) == :cont
      assert Runner.before_tool(config, call()) == {:cont, call()}
      assert Runner.after_tool(config, call(), result()) == result()
      assert Runner.after_compact(config, [], %{}) == []
      assert Runner.session_start(config) == []
      assert Runner.passivate(config) == :ok
      assert Runner.turn_end(config, {:ok, 1}) == :ok
    end

    test "entries run in order; a rewrite is what the next entry receives" do
      config = config([probe(:a, returns: [on_prompt: {:cont, "rewritten"}]), probe(:b)])
      assert Runner.prompt(config, "hi") == {:cont, "rewritten"}

      assert [
               {:hook, :a, :on_prompt, ["hi", %Context{event: :on_prompt, turn_id: nil}]},
               {:hook, :b, :on_prompt, ["rewritten", _ctx]}
             ] = mailbox()
    end

    test "the first halt stops the chain and names the hook" do
      assert Runner.prompt(config([probe(:a, returns: [on_prompt: {:halt, "no"}]), probe(:b)]), "hi") ==
               {:halt, Probe, "no"}

      refute_received {:hook, :b, _, _}

      llm = config([probe(:a, returns: [before_llm: {:halt, "budget"}]), probe(:b)])
      assert Runner.before_llm(llm, info()) == {:halt, Probe, "budget"}
      refute_received {:hook, :b, :before_llm, _}
    end

    test "a before_tool halt with a reason becomes a denial answering the call" do
      tool = config([probe(:a, returns: [before_tool: {:halt, "blocked"}]), probe(:b)])

      assert Runner.before_tool(tool, call()) ==
               {:halt,
                %ToolResult{tool_call_id: "c1", output: %{error: "blocked", denied: true}, is_error: true}}

      refute_received {:hook, :b, :before_tool, _}
    end

    test "a before_tool halt with a %ToolResult{} is returned as given" do
      denied = %ToolResult{tool_call_id: "c1", output: %{error: "custom"}, is_error: true}
      tool = config([probe(:a, returns: [before_tool: {:halt, denied}])])
      assert Runner.before_tool(tool, call()) == {:halt, denied}
    end

    test "after_tool threads rewritten results" do
      rewritten = %{result() | output: "redacted"}
      config = config([probe(:a, returns: [after_tool: {:cont, rewritten}]), probe(:b)])
      assert Runner.after_tool(config, call(), result()) == rewritten
      assert_received {:hook, :b, :after_tool, [_call, ^rewritten, _ctx]}
    end

    test "inject results are concatenated in list order; [] and other values inject nothing" do
      config =
        config([
          probe(:a, returns: [after_compact: {:inject, ["one"]}, on_session_start: {:inject, ["s1"]}]),
          probe(:b, returns: [after_compact: {:inject, []}]),
          probe(:c, returns: [after_compact: {:inject, ["two", "three"]}]),
          probe(:d, returns: [after_compact: {:ok, 3}])
        ])

      dropped = [%Entry{id: "e1", role: "user", content: "old"}]

      assert Runner.after_compact(config, dropped, %{compacted: true}) == ["one", "two", "three"]
      assert_received {:hook, :b, :after_compact, [^dropped, %{compacted: true}, _]}
      assert Runner.session_start(config) == ["s1"]
    end

    test "an entry without the event's callback is skipped" do
      config = config([{TurnEndOnly, notify: TestHooks.sink()}])
      assert Runner.prompt(config, "hi") == {:cont, "hi"}
      assert Runner.turn_end(config, {:ok, :r}) == :ok
      assert_received {:turn_end_only, {:ok, :r}}
    end

    test "the context carries the event, agent name, model, session and values" do
      Runner.passivate(config([probe(:a)]))
      assert_received {:hook, :a, :on_passivate, [ctx]}

      assert %Context{
               event: :on_passivate,
               agent_name: "runner-agent",
               model: "m",
               session_id: "s",
               values: %{u: 1},
               turn_id: nil
             } = ctx
    end

    test ":on_error is removed from opts before the callback sees them" do
      sink = TestHooks.sink()
      Runner.passivate(config([{EchoOpts, notify: sink, on_error: :open, label: "x"}]))
      assert_received {:opts, opts}
      assert Enum.sort(opts) == Enum.sort(notify: sink, label: "x")
    end

    test "a module that is not loaded raises, except on logged-only events" do
      config = config([{Nope.Missing, []}])

      assert_raise ArgumentError, "hook module Nope.Missing is not available", fn ->
        Runner.prompt(config, "hi")
      end

      log = capture_log(fn -> assert Runner.turn_end(config, {:ok, 1}) == :ok end)
      assert log =~ "hook module Nope.Missing is not available"
    end
  end

  describe ":on_error" do
    test ":reraise (default) propagates raise, exit and throw" do
      assert_raise RuntimeError, "boom", fn ->
        Runner.prompt(config([probe(:a, returns: [on_prompt: {:raise, "boom"}])]), "x")
      end

      assert catch_exit(
               Runner.before_llm(config([probe(:a, returns: [before_llm: {:exit, :down}])]), info())
             ) == :down

      assert catch_throw(
               Runner.after_compact(
                 config([probe(:a, returns: [after_compact: {:throw, :t}])]),
                 [],
                 %{}
               )
             ) == :t
    end

    test ":open logs the hook, event, exception and message, and passes the value on" do
      config = config([probe(:a, on_error: :open, returns: [on_prompt: {:raise, "boom"}]), probe(:b)])

      log = capture_log(fn -> assert Runner.prompt(config, "hi") == {:cont, "hi"} end)
      assert log =~ "hook Normandy.Test.Hooks.Probe on_prompt crashed: RuntimeError: boom"
      assert_received {:hook, :b, :on_prompt, ["hi", _]}

      exit_log =
        capture_log(fn ->
          assert Runner.after_compact(
                   config([probe(:a, on_error: :open, returns: [after_compact: {:exit, {:secret, 1}}])]),
                   [],
                   %{}
                 ) == []
        end)

      assert exit_log =~ "after_compact crashed: exit"
      refute exit_log =~ "secret"
    end

    @tag :capture_log
    test ":closed halts a haltable event with a reason naming the hook, not the message" do
      assert {:halt, Probe, reason} =
               Runner.prompt(config([probe(:a, on_error: :closed, returns: [on_prompt: {:raise, "boom"}])]), "hi")

      assert reason == "hook Normandy.Test.Hooks.Probe crashed: RuntimeError"

      tool = config([probe(:a, on_error: :closed, returns: [before_tool: {:throw, :t}])])

      assert {:halt, %ToolResult{tool_call_id: "c1", is_error: true, output: %{error: msg, denied: true}}} =
               Runner.before_tool(tool, call())

      assert msg == "hook Normandy.Test.Hooks.Probe crashed: throw"
    end

    @tag :capture_log
    test ":closed on after_tool replaces the result with an error result" do
      config = config([probe(:a, on_error: :closed, returns: [after_tool: {:raise, "redactor down"}])])

      assert %ToolResult{tool_call_id: "c1", is_error: true, output: %{error: msg}} =
               Runner.after_tool(config, call(), result())

      assert msg == "hook Normandy.Test.Hooks.Probe crashed: RuntimeError"
    end

    test ":closed on after_compact and on_session_start re-raises" do
      assert_raise RuntimeError, "boom", fn ->
        Runner.after_compact(
          config([probe(:a, on_error: :closed, returns: [after_compact: {:raise, "boom"}])]),
          [],
          %{}
        )
      end

      assert_raise RuntimeError, "boom", fn ->
        Runner.session_start(
          config([probe(:a, on_error: :closed, returns: [on_session_start: {:raise, "boom"}])])
        )
      end
    end

    @tag :capture_log
    test "logged-only events never raise, whatever :on_error says" do
      for policy <- [:reraise, :open, :closed] do
        assert Runner.turn_end(
                 config([probe(:a, on_error: policy, returns: [on_turn_end: {:raise, "late"}])]),
                 {:ok, 1}
               ) == :ok

        assert Runner.passivate(
                 config([probe(:a, on_error: policy, returns: [on_passivate: {:exit, :late}])])
               ) == :ok
      end
    end
  end

  describe "return contract" do
    test "a consumed value outside the contract raises ArgumentError even under :open" do
      assert_raise ArgumentError,
                   ~r/expected Normandy.Test.Hooks.Probe.on_prompt\/3 to return .*, got: :yes/,
                   fn ->
                     Runner.prompt(config([probe(:a, on_error: :open, returns: [on_prompt: :yes])]), "hi")
                   end

      assert_raise ArgumentError, ~r/got: \{:inject, "not a list"\}/, fn ->
        Runner.after_compact(
          config([probe(:a, returns: [after_compact: {:inject, "not a list"}])]),
          [],
          %{}
        )
      end

      assert_raise ArgumentError, ~r/before_tool\/3 to return/, fn ->
        Runner.before_tool(config([probe(:a, returns: [before_tool: {:halt, 42}])]), call())
      end

      assert_raise ArgumentError, ~r/before_llm\/3 to return/, fn ->
        Runner.before_llm(config([probe(:a, returns: [before_llm: {:cont, info()}])]), info())
      end
    end

    test "logged-only events ignore their return value" do
      assert Runner.turn_end(config([probe(:a, returns: [on_turn_end: :done])]), {:ok, 1}) == :ok
      assert Runner.passivate(config([probe(:a, returns: [on_passivate: {:error, :x}])])) == :ok
    end

    test "every event has a contract description" do
      for {event, _arity} <- Hooks.events(), do: assert(is_binary(Runner.contract(event)))
    end

    test "the test Probe implements every event" do
      for {event, arity} <- Hooks.events(), do: assert(function_exported?(Probe, event, arity))
    end
  end

  describe "telemetry" do
    test "one span per entry call with event, hook and result, in call order" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :start], [:normandy, :hook, :stop]],
        agent_name: name
      )

      config = config([probe(:a, returns: [on_prompt: {:cont, "new"}]), probe(:b)], name)
      Runner.prompt(config, "hi")

      spans = for {:span, event, meta} <- mailbox(), do: {List.last(event), meta}

      assert [
               {:start, %{event: :on_prompt, hook: Probe}},
               {:stop, %{event: :on_prompt, hook: Probe, result: :rewrite}},
               {:start, %{event: :on_prompt, hook: Probe}},
               {:stop, %{event: :on_prompt, hook: Probe, result: :cont}}
             ] = spans

      Runner.before_llm(config([probe(:a, returns: [before_llm: {:halt, "x"}])], name), info())
      assert_received {:span, [:normandy, :hook, :stop], %{event: :before_llm, result: :halt}}

      Runner.after_compact(config([probe(:a, returns: [after_compact: {:inject, ["t"]}])], name), [], %{})
      assert_received {:span, [:normandy, :hook, :stop], %{event: :after_compact, result: :inject}}

      Runner.turn_end(config([probe(:a)], name), {:ok, 1})
      assert_received {:span, [:normandy, :hook, :stop], %{event: :on_turn_end, result: :ok}}
    end

    test "tool events carry the call id and tool name" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :hook, :stop]], agent_name: name)

      Runner.after_tool(config([probe(:a)], name), call(), result())

      assert_received {:span, [:normandy, :hook, :stop],
                       %{event: :after_tool, tool_call_id: "c1", tool: "t", result: :cont}}
    end

    @tag :capture_log
    test "a rescued crash stops with result: :rescued; a re-raised one emits :exception" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :stop], [:normandy, :hook, :exception]],
        agent_name: name
      )

      Runner.turn_end(config([probe(:a, returns: [on_turn_end: {:raise, "x"}])], name), {:ok, 1})
      assert_received {:span, [:normandy, :hook, :stop], %{event: :on_turn_end, result: :rescued}}

      catch_error(Runner.prompt(config([probe(:a, returns: [on_prompt: {:raise, "x"}])], name), "hi"))
      assert_received {:span, [:normandy, :hook, :exception], %{event: :on_prompt}}
    end
  end
end
```

`test/support/telemetry_capture.ex` sends `{:span, event, metadata}` from `attach_span/2` and filters on `agent_name` (lines 33-57), so these patterns match its messages as they are.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/hooks/runner_test.exs`
Expected: FAIL — `Normandy.Hooks.Runner.entries/1 is undefined (module Normandy.Hooks.Runner is not available)`.

- [ ] **Step 4: Implement the Runner**

`lib/normandy/hooks/runner.ex`:

```elixir
defmodule Normandy.Hooks.Runner do
  @moduledoc """
  The only caller of hook modules (`Normandy.Behaviours.Hooks`). Every function takes the
  agent's config, reads its entries (`config.behaviours.hooks`) and runs, in list order,
  the entries whose module exports the event's callback. With none it returns the pass
  value at once: no context is built and no telemetry is emitted.

  These functions are also the supported way to test a hook with the library's rules
  applied (rewrite threading, halts, `:on_error`, return contracts): pass a config map such
  as `%{name: "a", behaviours: %{hooks: [{MyHook, []}]}}`.

  ## Rules

    * A rewrite (`{:cont, new}`) is what the next entry receives; the first halt stops the
      chain.
    * `:on_error`, removed from opts before the callback sees them:

      | Event | `:reraise` (default) | `:open` | `:closed` |
      |---|---|---|---|
      | `on_prompt`, `before_llm`, `before_tool` | propagates | logged; the value passes on | halts, reason naming the hook |
      | `after_tool` | propagates | logged; the result passes on | the result becomes an error result naming the hook |
      | `after_compact`, `on_session_start` | propagates | logged; injects nothing | propagates |
      | `on_turn_end`, `on_passivate` | logged | logged | logged |

    * A return value is checked only where the library consumes it; a violation raises
      `ArgumentError` whatever `:on_error` says. `on_turn_end` and `on_passivate` ignore
      their return value, and so do `after_compact`/`on_session_start` for anything but
      `{:inject, texts}`.
    * A module that is not loaded raises `ArgumentError` (logged and skipped on
      `on_turn_end`/`on_passivate`).
    * Each entry call is a `[:normandy, :hook, :start | :stop | :exception]` span.
  """

  require Logger

  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Context

  @arity Map.new(Hooks.events())
  @logged_only [:on_turn_end, :on_passivate]
  @closable [:on_prompt, :before_llm, :before_tool, :after_tool]
  @injecting [:after_compact, :on_session_start]

  @contracts %{
    on_prompt: "{:cont, input} or {:halt, reason :: String.t()}",
    before_llm: ":cont or {:halt, reason :: String.t()}",
    before_tool: "{:cont, %ToolCall{}} or {:halt, reason :: String.t() | %ToolResult{}}",
    after_tool: "{:cont, %ToolResult{}}",
    after_compact: "{:inject, [String.t()]} or any other value (ignored)",
    on_session_start: "{:inject, [String.t()]} or any other value (ignored)",
    on_passivate: "any value (ignored)",
    on_turn_end: "any value (ignored)"
  }

  @doc "The agent's hook entries: `config.behaviours.hooks`, or `[]`."
  @spec entries(map() | nil) :: [Hooks.entry()]
  def entries(%{behaviours: %{hooks: hooks}}) when is_list(hooks), do: hooks
  def entries(_config), do: []

  @doc "Whether the agent has any hook entry."
  @spec hooks?(map() | nil) :: boolean()
  def hooks?(config), do: entries(config) != []

  @doc "Whether any entry's module exports `event`'s callback."
  @spec handles?(map() | nil, atom()) :: boolean()
  def handles?(config, event), do: callable(config, event) != []

  @doc false
  @spec contract(atom()) :: String.t()
  def contract(event), do: Map.fetch!(@contracts, event)

  @doc "Runs `on_prompt`. A halt returns the halting module and its reason."
  @spec prompt(map(), term()) :: {:cont, term()} | {:halt, module(), String.t()}
  def prompt(config, input) do
    case callable(config, :on_prompt) do
      [] ->
        {:cont, input}

      entries ->
        ctx = Context.build(config, :on_prompt, turn_id: nil)
        invoke = fn mod, value, opts -> mod.on_prompt(value, ctx, opts) end
        entries |> chain(ctx, %{}, input, invoke) |> string_halt()
    end
  end

  @doc "Runs `before_llm` with the call's `%{final: boolean(), iterations_left: integer()}`."
  @spec before_llm(map(), map()) :: :cont | {:halt, module(), String.t()}
  def before_llm(config, info) do
    case callable(config, :before_llm) do
      [] ->
        :cont

      entries ->
        ctx = Context.build(config, :before_llm)
        invoke = fn mod, value, opts -> mod.before_llm(value, ctx, opts) end
        entries |> chain(ctx, %{}, info, invoke) |> gate()
    end
  end

  @doc "Runs `before_tool`. A halt is the error result that answers the call."
  @spec before_tool(map(), ToolCall.t()) :: {:cont, ToolCall.t()} | {:halt, ToolResult.t()}
  def before_tool(config, %ToolCall{} = call) do
    case callable(config, :before_tool) do
      [] ->
        {:cont, call}

      entries ->
        ctx = Context.build(config, :before_tool)
        invoke = fn mod, value, opts -> mod.before_tool(value, ctx, opts) end
        entries |> chain(ctx, tool_meta(call), call, invoke) |> tool_halt(call)
    end
  end

  @doc "Runs `after_tool`; returns the result the model will see."
  @spec after_tool(map(), ToolCall.t(), ToolResult.t()) :: ToolResult.t()
  def after_tool(config, %ToolCall{} = call, %ToolResult{} = result) do
    case callable(config, :after_tool) do
      [] ->
        result

      entries ->
        ctx = Context.build(config, :after_tool)
        invoke = fn mod, value, opts -> mod.after_tool(call, value, ctx, opts) end
        entries |> chain(ctx, tool_meta(call), result, invoke) |> answered(call)
    end
  end

  @doc "Runs `after_compact` with the compactor's dropped entries; returns the texts to inject."
  @spec after_compact(map(), list(), map()) :: [String.t()]
  def after_compact(config, dropped, meta) do
    case callable(config, :after_compact) do
      [] ->
        []

      entries ->
        ctx = Context.build(config, :after_compact)
        collect(entries, ctx, fn mod, opts -> mod.after_compact(dropped, meta, ctx, opts) end)
    end
  end

  @doc "Runs `on_session_start`; returns the texts to inject."
  @spec session_start(map()) :: [String.t()]
  def session_start(config) do
    case callable(config, :on_session_start) do
      [] ->
        []

      entries ->
        ctx = Context.build(config, :on_session_start, turn_id: nil)
        collect(entries, ctx, fn mod, opts -> mod.on_session_start(ctx, opts) end)
    end
  end

  @doc "Runs `on_passivate` (logged-only)."
  @spec passivate(map()) :: :ok
  def passivate(config) do
    case callable(config, :on_passivate) do
      [] ->
        :ok

      entries ->
        ctx = Context.build(config, :on_passivate, turn_id: nil)
        _ = collect(entries, ctx, fn mod, opts -> mod.on_passivate(ctx, opts) end)
        :ok
    end
  end

  @doc "Runs `on_turn_end` (logged-only). `ctx_opts` go to `Normandy.Hooks.Context.build/3`."
  @spec turn_end(map(), Hooks.outcome(), keyword()) :: :ok
  def turn_end(config, outcome, ctx_opts \\ []) do
    case callable(config, :on_turn_end) do
      [] ->
        :ok

      entries ->
        ctx = Context.build(config, :on_turn_end, ctx_opts)
        _ = collect(entries, ctx, fn mod, opts -> mod.on_turn_end(outcome, ctx, opts) end)
        :ok
    end
  end

  # ── entry selection ─────────────────────────────────────────────────────────

  defp callable(config, event) do
    arity = Map.fetch!(@arity, event)

    for {mod, _opts} = entry <- entries(config),
        loaded?(mod, event),
        function_exported?(mod, event, arity),
        do: entry
  end

  # Validation catches a missing module on every path that builds a config; one that
  # slipped through is a configuration error, raised, except where nothing may raise.
  defp loaded?(mod, event) do
    cond do
      Code.ensure_loaded?(mod) ->
        true

      event in @logged_only ->
        Logger.error("hook module #{inspect(mod)} is not available; its #{event} did not run")
        false

      true ->
        raise ArgumentError, "hook module #{inspect(mod)} is not available"
    end
  end

  # ── chains ──────────────────────────────────────────────────────────────────

  # Threads `value` through the entries: {:cont, value} or {:halt, module, payload}, where
  # a :closed crash's payload is {:crashed, reason}.
  defp chain(entries, ctx, meta, value, invoke) do
    Enum.reduce_while(entries, {:cont, value}, fn {mod, _opts} = entry, {:cont, value} ->
      entry
      |> run_entry(ctx, meta, &invoke.(mod, value, &1), &classify(ctx.event, mod, value, &1))
      |> chain_step(mod, value)
    end)
  end

  defp chain_step({:cont, new}, _mod, _value), do: {:cont, {:cont, new}}
  defp chain_step({:halt, payload}, mod, _value), do: {:halt, {:halt, mod, payload}}

  defp chain_step({:rescued, :closed, reason}, mod, _value),
    do: {:halt, {:halt, mod, {:crashed, reason}}}

  defp chain_step({:rescued, _policy, _reason}, _mod, value), do: {:cont, {:cont, value}}

  # Runs every entry; returns the concatenated injections.
  defp collect(entries, ctx, invoke) do
    Enum.flat_map(entries, fn {mod, _opts} = entry ->
      case run_entry(entry, ctx, %{}, &invoke.(mod, &1), &classify(ctx.event, mod, nil, &1)) do
        {:inject, texts} -> texts
        _ok_or_rescued -> []
      end
    end)
  end

  defp string_halt({:halt, mod, {:crashed, reason}}), do: {:halt, mod, reason}
  defp string_halt(other), do: other

  defp gate({:cont, _info}), do: :cont
  defp gate(halt), do: string_halt(halt)

  defp tool_halt({:cont, call}, _call), do: {:cont, call}
  defp tool_halt({:halt, _mod, %ToolResult{} = result}, _call), do: {:halt, result}
  defp tool_halt({:halt, _mod, {:crashed, reason}}, call), do: {:halt, denial(call, reason)}
  defp tool_halt({:halt, _mod, reason}, call), do: {:halt, denial(call, reason)}

  defp answered({:cont, result}, _call), do: result

  defp answered({:halt, _mod, {:crashed, reason}}, call),
    do: %ToolResult{tool_call_id: call.id, output: %{error: reason}, is_error: true}

  defp denial(call, reason),
    do: %ToolResult{tool_call_id: call.id, output: %{error: reason, denied: true}, is_error: true}

  defp tool_meta(%ToolCall{id: id, name: name}), do: %{tool_call_id: id, tool: name}

  # ── one entry ───────────────────────────────────────────────────────────────

  # Calls one entry inside its span. Returns the classified value, or
  # {:rescued, policy, halt_reason} for a crash the entry's policy rescued.
  defp run_entry({mod, opts}, ctx, extra_meta, invoke, classify) do
    {policy, opts} = Keyword.pop(opts, :on_error, :reraise)
    policy = effective_policy(ctx.event, policy)

    meta =
      Map.merge(
        %{
          event: ctx.event,
          hook: mod,
          agent_name: ctx.agent_name,
          session_id: ctx.session_id,
          turn_id: ctx.turn_id
        },
        extra_meta
      )

    :telemetry.span([:normandy, :hook], meta, fn ->
      {value, result} = invoke_entry(mod, ctx.event, policy, fn -> invoke.(opts) end, classify)
      {value, Map.put(meta, :result, result)}
    end)
  end

  defp invoke_entry(mod, event, policy, invoke, classify) do
    case guarded(policy, invoke) do
      {:ok, ret} ->
        {result, value} = classify.(ret)
        {value, result}

      {:crashed, kind, reason, stacktrace} ->
        Logger.error("hook #{inspect(mod)} #{event} crashed: #{describe(kind, reason, stacktrace)}")
        {{:rescued, policy, crash_reason(mod, kind, reason, stacktrace)}, :rescued}
    end
  end

  defp effective_policy(event, _policy) when event in @logged_only, do: :open
  defp effective_policy(event, :closed) when event not in @closable, do: :reraise
  defp effective_policy(_event, policy), do: policy

  defp guarded(:reraise, fun), do: {:ok, fun.()}

  defp guarded(_policy, fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:crashed, kind, reason, __STACKTRACE__}
  end

  # ── return contracts: {telemetry result, value for the chain} or ArgumentError ─

  defp classify(:on_prompt, _mod, value, {:cont, new}), do: pass_or_rewrite(value, new)

  defp classify(:before_tool, _mod, value, {:cont, %ToolCall{} = new}),
    do: pass_or_rewrite(value, new)

  defp classify(:after_tool, _mod, value, {:cont, %ToolResult{} = new}),
    do: pass_or_rewrite(value, new)

  defp classify(:before_llm, _mod, value, :cont), do: {:cont, {:cont, value}}

  defp classify(event, _mod, _value, {:halt, reason})
       when event in [:on_prompt, :before_llm, :before_tool] and is_binary(reason),
       do: {:halt, {:halt, reason}}

  defp classify(:before_tool, _mod, _value, {:halt, %ToolResult{} = result}),
    do: {:halt, {:halt, result}}

  defp classify(event, mod, _value, {:inject, texts} = ret) when event in @injecting do
    cond do
      not (is_list(texts) and Enum.all?(texts, &is_binary/1)) -> contract!(event, mod, ret)
      texts == [] -> {:ok, :ok}
      true -> {:inject, {:inject, texts}}
    end
  end

  defp classify(event, _mod, _value, _ret) when event in @injecting or event in @logged_only,
    do: {:ok, :ok}

  defp classify(event, mod, _value, ret), do: contract!(event, mod, ret)

  # Same value back is a pass; anything else is a rewrite.
  defp pass_or_rewrite(value, value), do: {:cont, {:cont, value}}
  defp pass_or_rewrite(_value, new), do: {:rewrite, {:cont, new}}

  defp contract!(event, mod, ret) do
    raise ArgumentError,
          "expected #{inspect(mod)}.#{event}/#{Map.fetch!(@arity, event)} to return " <>
            "#{Map.fetch!(@contracts, event)}, got: #{inspect(ret)}"
  end

  # ── crash descriptions ──────────────────────────────────────────────────────

  # Log text: the exception module, plus the message of a RuntimeError or ArgumentError
  # (author-written text) cut to 200 characters; never an exit or throw payload or another
  # exception's message, which can carry the hook's data (Turn.Server logs handler crashes
  # by the same rule).
  defp describe(:error, reason, stacktrace) do
    case Exception.normalize(:error, reason, stacktrace) do
      %mod{} = e when mod in [RuntimeError, ArgumentError] ->
        "#{inspect(mod)}: " <> String.slice(Exception.message(e), 0, 200)

      %mod{} ->
        inspect(mod)
    end
  end

  defp describe(kind, _reason, _stacktrace), do: Atom.to_string(kind)

  # A halt reason reaches the model or the caller: the exception module or the kind only.
  defp crash_reason(mod, :error, reason, stacktrace) do
    %exception{} = Exception.normalize(:error, reason, stacktrace)
    "hook #{inspect(mod)} crashed: #{inspect(exception)}"
  end

  defp crash_reason(mod, kind, _reason, _stacktrace), do: "hook #{inspect(mod)} crashed: #{kind}"
end
```

- [ ] **Step 5: Document the event in the telemetry catalogue**

In `lib/normandy/telemetry.ex`, after the `[:normandy, :memory, :command, :start | :stop | :exception]` entry (it starts at line 119 with `  ### \``), add, with the same indentation:

```markdown
  ### `[:normandy, :hook, :start | :stop | :exception]`

  One hook module call (`Normandy.Hooks.Runner`): one span per `{module, opts}` entry per
  event, for entries whose module exports the event's callback. No hooks, no spans.

    * Start metadata: `event` (`:on_session_start | :on_passivate | :on_prompt |
      :before_llm | :before_tool | :after_tool | :after_compact | :on_turn_end`), `hook`
      (the module), `agent_name`, `session_id`, `turn_id`; `before_tool` and `after_tool`
      add `tool_call_id` and `tool`.
    * Stop metadata adds `result`: `:cont` (passed the value on unchanged), `:rewrite`,
      `:halt`, `:inject`, `:ok`, or `:rescued` (a crash rescued under `on_error: :open` or
      `:closed`, or on a logged-only event).
    * `:exception` fires when a crash propagates (`on_error: :reraise`) or a return value
      breaks the callback's contract.
```

Add to `test/hooks/runner_test.exs`, inside `describe "telemetry"`:

```elixir
    test "the Normandy.Telemetry moduledoc names every hook event" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy.Telemetry)
      assert doc =~ "[:normandy, :hook, :start | :stop | :exception]"
      for {event, _arity} <- Hooks.events(), do: assert(doc =~ ":#{event}")
    end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks/runner_test.exs test/telemetry/catalogue_test.exs`
Expected: PASS (the catalogue test reads the literal `:telemetry.span([:normandy, :hook], …)` call site and finds it documented).

- [ ] **Step 7: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/runner.ex lib/normandy/telemetry.ex test/support/hook_probes.ex test/hooks/runner_test.exs
git commit -m "feat(hooks): Runner with ordering, on_error, return contracts and telemetry"
```

### Task 3: Compactors report what they dropped, and kept messages keep their entry ids

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (`add_message/4` accepts `:id`)
- Modify: `lib/normandy/context/window_manager.ex` (`truncate_oldest_first/2`, `rebuild_memory/2`, ~lines 278-311 and 386-399)
- Modify: `lib/normandy/context/summarizer.ex` (`rebuild_memory_with_summary/4`, `recent_turn_ids/2` → `recent_entries/2`, the call at ~line 394)
- Modify: `lib/normandy/behaviours/compactor.ex` (moduledoc: `:dropped`)
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex` (`run/2`, `tokens_removed_this_turn/2`, new `dropped_entries/2`, remove `message_keys/1`)
- Create: `test/support/keep_last_compactor.ex`
- Test: `test/components/agent_memory_test.exs`, `test/context/window_manager_test.exs`, `test/context/summarizer_test.exs`, `test/behaviours/compactor_test.exs` (add tests)

**Interfaces:**
- Produces:
  - `AgentMemory.add_message(memory, role, content, id: id)` — the entry gets `id` instead of a new UUID.
  - The `Compactor` contract: `meta` may carry `:dropped :: [%AgentMemory.Entry{}]` — the entries the compactor removed from the active branch, oldest first, each with the id it had in `acc.memory` and its original content.
  - `Compactor.WindowManager` sets `meta.dropped` on every successful run (`[]` when nothing was removed); `NoOp` is unchanged.
  - `Normandy.Test.KeepLastCompactor` (Task 8 uses it).
- Why `%AgentMemory.Entry{}`: it is what memory and `SessionStore.history/2` already hold, it carries the id natively, and its content is the original (the rebuilt memory holds kept content in the JSON form `AgentMemory.history/1` renders, `agent_memory.ex:89-105`).

- [ ] **Step 1: Write the failing tests**

In `test/components/agent_memory_test.exs`, inside `describe "add_message/4"`, add:

```elixir
    test "id: gives the entry that id instead of a new one" do
      memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", "x", id: "entry-1")

      assert [%Entry{id: "entry-1", content: "x"}] = AgentMemory.entry_chain(memory)
      assert memory.head == "entry-1"
    end
```

In `test/context/window_manager_test.exs`, inside `describe "truncate_conversation/2 with :oldest_first strategy"`, add:

```elixir
    test "kept messages keep their entry ids" do
      manager = WindowManager.new(max_tokens: 80, reserved_tokens: 20, strategy: :oldest_first)

      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "First message that is quite long")
        |> AgentMemory.add_message("assistant", "First response that is quite long")
        |> AgentMemory.add_message("user", "Second message that is quite long")
        |> AgentMemory.add_message("assistant", "Second response that is quite long")
        |> AgentMemory.add_message("user", "Third message that is quite long")
        |> AgentMemory.add_message("assistant", "Third response that is quite long")

      {:ok, truncated} = WindowManager.truncate_conversation(%{memory: memory, config: %{}}, manager)

      kept = AgentMemory.entry_chain(truncated.memory)
      assert length(kept) < 6

      assert Enum.map(kept, & &1.id) ==
               memory |> AgentMemory.entry_chain() |> Enum.take(-length(kept)) |> Enum.map(& &1.id)
    end
```

In `test/context/summarizer_test.exs`, before the module's final `end`, add (the module's `setup` provides `agent` and `client`):

```elixir
  describe "compress_conversation/3 and entry ids" do
    test "kept messages keep their entry ids; the summary is a new entry",
         %{agent: agent, client: client} do
      alias Normandy.Components.AgentMemory

      memory =
        Enum.reduce(1..8, AgentMemory.new_memory(), fn i, m ->
          AgentMemory.add_message(m, "user", "message #{i}")
        end)

      {:ok, compressed} =
        Normandy.Context.Summarizer.compress_conversation(client, %{agent | memory: memory},
          keep_recent: 3
        )

      before = AgentMemory.entry_chain(memory)
      [summary | kept] = AgentMemory.entry_chain(compressed.memory)

      assert summary.content =~ "Previous conversation summary"
      refute summary.id in Enum.map(before, & &1.id)
      assert Enum.map(kept, & &1.id) == before |> Enum.take(-3) |> Enum.map(& &1.id)
    end
  end
```

In `test/behaviours/compactor_test.exs`, inside `describe "WindowManager impl"` (it defines `mem_with/1` and aliases `WMCompactor` and `AgentMemory`), add:

```elixir
    test "meta.dropped holds the removed entries, oldest first; kept entries keep their ids" do
      msgs = for i <- 1..40, do: {"user", "message number #{i} padding"}
      acc = %{memory: mem_with(msgs)}

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      before = AgentMemory.entry_chain(acc.memory)
      kept = AgentMemory.entry_chain(result.memory)

      assert meta.compacted
      assert meta.dropped == Enum.take(before, length(before) - length(kept))
      assert Enum.map(kept, & &1.id) == before |> Enum.take(-length(kept)) |> Enum.map(& &1.id)
    end

    test "nothing removed: meta.dropped is []" do
      acc = %{memory: mem_with([{"user", "short"}, {"assistant", "ok"}])}
      {_result, meta} = WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, [])
      assert meta.dropped == []
    end

    test ":summarize reports the summarized entries as dropped, never the summary" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: mem_with(msgs),
        client: %Normandy.Test.MockSummarizerClient{summary_response: "a short summary"},
        model: "m"
      }

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      before = AgentMemory.entry_chain(acc.memory)
      [summary | kept] = AgentMemory.entry_chain(result.memory)

      refute summary.id in Enum.map(before, & &1.id)
      assert meta.dropped == Enum.take(before, length(before) - length(kept))
      assert Enum.map(kept, & &1.id) == before |> Enum.take(-length(kept)) |> Enum.map(& &1.id)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/components/agent_memory_test.exs test/context/window_manager_test.exs test/context/summarizer_test.exs test/behaviours/compactor_test.exs`
Expected: FAIL — `add_message/4` raises `ArgumentError` for the unknown `:id` option; kept ids differ; `meta` has no `:dropped` key (KeyError).

- [ ] **Step 3: Implement**

`lib/normandy/components/agent_memory.ex`, replace the `add_message/4` doc and the first lines of its body:

```elixir
  @doc """
  Appends a message to the active branch.

  `turn_id:` stores the message under that turn instead of `current_turn_id`;
  compaction uses it to keep each kept message's turn. `id:` gives the entry that id
  instead of a new one (compaction keeps a kept message's id, which compactors report
  dropped entries by); it must not already be in `memory`.
  """
  @spec add_message(t(), String.t(), term(), keyword()) :: t()
  def add_message(%__MODULE__{} = memory, role, content, opts \\ []) do
    opts = Keyword.validate!(opts, [:turn_id, :id])
    memory = if memory.current_turn_id == nil, do: initialize_turn(memory), else: memory

    id = Keyword.get(opts, :id) || UUID.uuid4()
```

(the rest of the function, from `entry = %Entry{`, is unchanged).

`lib/normandy/context/window_manager.ex`, in `truncate_oldest_first/2` replace from the comment `# Remove oldest messages until under limit.` through `new_memory = rebuild_memory(...)` with:

```elixir
      # Remove oldest messages until under limit. history/1 and entry_chain/1 are
      # the same chain in the same order: the kept suffix's entries give each kept
      # message its turn and its entry id.
      history = AgentMemory.history(agent.memory)
      {fitting, _removed} = split_to_fit(history, target_tokens)

      # Start the kept window at a user message (see AgentMemory.keep_count/2);
      # a newest message larger than the target keeps its turn rather than
      # emptying the memory.
      keep =
        history
        |> Enum.reverse()
        |> Enum.map(& &1.role)
        |> AgentMemory.keep_count(max(length(fitting), 1))

      keep_messages = Enum.take(history, -keep)

      kept_entries =
        agent.memory
        |> AgentMemory.entry_chain()
        |> Enum.take(-length(keep_messages))

      new_memory = rebuild_memory(Enum.zip(keep_messages, kept_entries), agent.memory)
```

and replace `rebuild_memory/2`:

```elixir
  defp rebuild_memory(kept, original_memory) do
    max_messages = Map.get(original_memory, :max_messages)
    turn_id = Map.get(original_memory, :current_turn_id)

    # Start from a fresh entry-graph memory, preserving the active turn id so the
    # rebuilt entries stay grouped exactly as before.
    memory = %{AgentMemory.new_memory(max_messages) | current_turn_id: turn_id}

    # Add messages in chronological order, each under its original turn and entry id
    # (a compactor reports what it dropped by entry id). Their thinking was produced
    # after the removed messages, so it no longer applies.
    Enum.reduce(kept, memory, fn {msg, entry}, mem ->
      AgentMemory.add_message(mem, msg.role, AgentMemory.drop_thinking(msg.content),
        turn_id: entry.turn_id,
        id: entry.id
      )
    end)
  end
```

`lib/normandy/context/summarizer.ex`: in `rebuild_memory_with_summary/4` replace the comment and reduce that add the recent messages with:

```elixir
    # Add recent messages in chronological order, each under its original turn and
    # entry id. The summary (added above) takes current_turn_id and a new id. Their
    # thinking was produced before the summary existed, so it no longer applies.
    Enum.reduce(recent_messages, memory, fn {msg, entry}, mem ->
      AgentMemory.add_message(mem, msg.role, AgentMemory.drop_thinking(msg.content),
        turn_id: entry.turn_id,
        id: entry.id
      )
    end)
```

replace `recent_turn_ids/2` (and its comment) with:

```elixir
  # history/1 and entry_chain/1 walk the same chain in the same order, so the kept
  # suffix's entries are the last `count` entries.
  defp recent_entries(memory, count) do
    memory |> AgentMemory.entry_chain() |> Enum.take(-count)
  end
```

and in `do_compress_conversation/7` replace
`Enum.zip(recent_messages, recent_turn_ids(agent.memory, length(recent_messages)))` with
`Enum.zip(recent_messages, recent_entries(agent.memory, length(recent_messages)))`.

`lib/normandy/behaviours/compactor.ex` moduledoc: after the paragraph ending "…the design's default-off principle." add:

```markdown
  `meta` may also carry `:dropped`: the `%Normandy.Components.AgentMemory.Entry{}`
  structs the compactor removed from the active branch, oldest first, each with the id
  it had in `acc.memory` and its original content. A compactor that fills it keeps each
  kept message under its entry id (`AgentMemory.add_message/4`'s `:id`), so a message is
  reported under one id for as long as the memory lives. `after_compact` hooks
  (`Normandy.Behaviours.Hooks`) run only when `:dropped` is non-empty. The WindowManager
  impl fills it; `NoOp` does not.
```

`lib/normandy/behaviours/compactor/window_manager.ex`: replace `run/2`, `tokens_removed_this_turn/2` and `message_keys/1` with:

```elixir
  defp run(acc, manager) do
    before = WM.estimate_conversation_tokens(acc.memory)

    case WM.ensure_within_limit(acc, manager) do
      {:ok, acc2} ->
        after_tokens = WM.estimate_conversation_tokens(acc2.memory)
        dropped = dropped_entries(acc.memory, acc2.memory)

        {acc2,
         %{
           compacted: after_tokens < before,
           tokens_before: before,
           tokens_after: after_tokens,
           tokens_removed: tokens_removed_this_turn(acc.memory, dropped),
           strategy: manager.strategy,
           dropped: dropped
         }}

      {:error, reason} ->
        {acc, %{compacted: false, error: reason}}
    end
  end

  # The entries of `before` that `after` no longer holds, oldest first. Every strategy
  # keeps a kept message's entry id and gives a summary a new one, so this is exactly
  # what compaction removed.
  defp dropped_entries(before_memory, after_memory) do
    kept = MapSet.new(AgentMemory.entry_chain(after_memory), & &1.id)
    Enum.reject(AgentMemory.entry_chain(before_memory), &MapSet.member?(kept, &1.id))
  end

  # Gross estimated tokens of the dropped messages that belong to the current turn:
  # what the task budget's `remaining` must subtract (Anthropic task-budgets doc,
  # "Carrying a budget across compaction"). Earlier turns were never this task's
  # spend, and a summary is new, so it is never dropped. Content is estimated in its
  # JSON form, the form the model was sent.
  defp tokens_removed_this_turn(before_memory, dropped) do
    turn_id = AgentMemory.get_current_turn_id(before_memory)

    dropped
    |> Enum.filter(&(&1.turn_id == turn_id))
    |> Enum.map(&(WM.estimate_message_content_tokens(BaseIOSchema.to_json(&1.content)) + 10))
    |> Enum.sum()
  end
```

Also update this module's moduledoc: append "Its meta carries `:dropped`, the removed entries (see `Normandy.Behaviours.Compactor`)."

`test/support/keep_last_compactor.ex`:

```elixir
defmodule Normandy.Test.KeepLastCompactor do
  @moduledoc """
  Compactor for tests: keeps the last `opts[:keep]` messages of the active branch,
  re-added under their own entry ids and turns, and reports the rest in `meta.dropped`
  (the `Normandy.Behaviours.Compactor` contract). `compacted: true` only when it dropped
  something.
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Components.AgentMemory

  @impl true
  def maybe_compact(config, _ctx, opts) do
    entries = AgentMemory.entry_chain(config.memory)
    keep = Keyword.fetch!(opts, :keep)

    if length(entries) <= keep do
      {config, %{compacted: false, dropped: []}}
    else
      {dropped, kept} = Enum.split(entries, length(entries) - keep)
      fresh = %{AgentMemory.new_memory() | current_turn_id: config.memory.current_turn_id}

      memory =
        Enum.reduce(kept, fresh, fn entry, mem ->
          AgentMemory.add_message(mem, entry.role, entry.content,
            turn_id: entry.turn_id,
            id: entry.id
          )
        end)

      {%{config | memory: memory}, %{compacted: true, strategy: :keep_last, dropped: dropped}}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/components test/context test/behaviours/compactor_test.exs test/integration/compaction_turn_test.exs test/agents`
Expected: PASS — including the existing `tokens_removed` tests (`compactor_test.exs:176-225`), which now read the dropped entries.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/context/window_manager.ex lib/normandy/context/summarizer.ex lib/normandy/behaviours/compactor.ex lib/normandy/behaviours/compactor/window_manager.ex test/support/keep_last_compactor.ex test/components/agent_memory_test.exs test/context/window_manager_test.exs test/context/summarizer_test.exs test/behaviours/compactor_test.exs
git commit -m "feat(compaction): compactors report dropped entries; kept messages keep their entry ids"
```

### Task 4: `Turn.Server` stores each message under its memory entry id

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`append_to_store/4` → `/5`, new `new_entry_id/2`; callers in `interpret/2` `{:append_message, …}` ~line 928, `persist_interrupted/2` ~line 884, `persist_user_message/4` ~line 1228)
- Modify: `lib/normandy/behaviours/session_store/redis.ex` (`decode_stream/1` ~line 225, `take_through/2` ~line 253)
- Test: `test/agents/turn/server_test.exs` (new `describe "entry ids"` at the end of the module), `test/behaviours/session_store/redis_store_extra_test.exs` (two tests, `@moduletag :redis`)

**Interfaces:**
- Consumes: nothing new.
- Produces: store entries carry the id memory gave the message, on every store: `InMemory`, `ETS`, `Mnesia`, `Postgres` honour `entry.id` (`entry.id || UUID…` in their `append_entry`); `SessionStore.Redis` writes it as the `id` field and, after this task, reads it back from `history/2` (stream id as fallback) and accepts it in `fork/3`. A rehydrated memory (`AgentMemory.from_entries/1` keeps store ids) then has the ids the live memory had, which `after_compact` hooks deduplicate on (Task 8).

- [ ] **Step 1: Write the failing tests**

At the end of `test/agents/turn/server_test.exs` (before the module's final `end`), add:

```elixir
  describe "entry ids" do
    test "the store keeps the id memory gave each message" do
      store = InMemory.new()

      handlers = %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _config, _state, _req -> %Resp{content: "hi", tool_calls: nil} end
      }

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: "s-entry-ids",
          config: base_config(),
          store: {InMemory, store},
          registry: {Native, Native.new()},
          handlers: handlers
        )

      assert {:ok, _} = Turn.Server.run(srv, "hello")
      {_state, data} = :sys.get_state(srv)
      {:ok, stored} = InMemory.history(store, "s-entry-ids")

      assert [_user, _assistant] = stored

      assert Enum.map(stored, & &1.id) ==
               data.config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)
    end

    test "interrupted results and the user message after them keep their ids too" do
      {srv, store} = start_dangling_server("s-entry-ids-dangling", %{})
      capture_log(fn -> assert {:ok, _} = Turn.Server.run(srv, "next") end)

      {_state, data} = :sys.get_state(srv)
      {:ok, stored} = InMemory.history(store, "s-entry-ids-dangling")

      assert Enum.map(stored, & &1.role) == ["user", "assistant", "tool", "user", "assistant"]

      assert Enum.map(stored, & &1.id) ==
               data.config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)
    end
  end
```

In `test/behaviours/session_store/redis_store_extra_test.exs` add:

```elixir
  test "history returns the id an entry was appended with; stream id when none", %{handle: h} do
    {:ok, _} = Redis.append_entry(h, "s-ids", %{e("user", "a") | id: "mem-1"})
    {:ok, stream_id} = Redis.append_entry(h, "s-ids", e("assistant", "b"))

    {:ok, [first, second]} = Redis.history(h, "s-ids")
    assert first.id == "mem-1"
    assert second.id == stream_id
    assert second.parent_id == "mem-1"
  end

  test "fork accepts the id history returned", %{handle: h} do
    {:ok, _} = Redis.append_entry(h, "s-fork-ids", %{e("user", "a") | id: "mem-1"})
    {:ok, _} = Redis.append_entry(h, "s-fork-ids", %{e("assistant", "b") | id: "mem-2"})
    {:ok, _} = Redis.append_entry(h, "s-fork-ids", %{e("user", "c") | id: "mem-3"})

    {:ok, forked} = Redis.fork(h, "s-fork-ids", "mem-2")
    {:ok, entries} = Redis.history(h, forked)
    assert Enum.map(entries, &{&1.id, &1.content}) == [{"mem-1", "a"}, {"mem-2", "b"}]
  end
```

These are tagged `:redis` (excluded by default); run them with `--include redis` against the local Redis.

(`start_dangling_server/4` is defined in this module's `describe "dangling tool_use repair"`, server_test.exs:2097; it seeds the store with store-assigned ids, which the server's memory takes on load.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — the two new tests: the stored ids are the store's UUIDs, not memory's.

- [ ] **Step 3: Implement**

In `lib/normandy/agents/turn/server.ex`, replace `append_to_store/4` and its comment with:

```elixir
  # The entry carries the turn id the memory gave this message, so a memory rebuilt from
  # the store keeps the turn boundaries, and the entry id the memory gave it, so a
  # rehydrated memory has the ids the live one had (after_compact hooks deduplicate on
  # them).
  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, config, role, content, id) do
    case mod.append_entry(handle, sid, %Normandy.Components.AgentMemory.Entry{
           id: id,
           turn_id: current_turn_id(config),
           role: role,
           content: content
         }) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The id of the entry `after_config`'s memory gained over `before`'s; nil when the
  # append handler added none (the store then assigns one).
  defp new_entry_id(%{memory: %AgentMemory{head: head}}, %{memory: %AgentMemory{head: head}}),
    do: nil

  defp new_entry_id(_before, %{memory: %AgentMemory{head: head}}), do: head
  defp new_entry_id(_before, _after), do: nil
```

In `interpret/2`, the `{:append_message, role, content}` clause: replace `case append_to_store(data, config, role, content) do` with `case append_to_store(data, config, role, content, new_entry_id(data.config, config)) do`.

Replace `persist_interrupted/2`'s reduce with:

```elixir
    result =
      Enum.reduce_while(repairs, {:ok, data.config}, fn {_call, result, folded}, {:ok, prev} ->
        case append_to_store(data, data.config, "tool", result, new_entry_id(prev, folded)) do
          :ok -> {:cont, {:ok, folded}}
          {:error, reason} -> {:halt, {:error, prev, reason}}
        end
      end)
```

Replace `persist_user_message/4`'s second clause with:

```elixir
  defp persist_user_message(data, config, _user_input, repaired) do
    id = new_entry_id(repaired, config)

    with {:error, reason} <-
           append_to_store(data, config, "user", config.current_user_input, id),
         do: {:error, repaired, reason}
  end
```

In `lib/normandy/behaviours/session_store/redis.ex`, `decode_stream/1`: the entry id is the stored `id` field when present, else the stream id, and the parent chain follows that id:

```elixir
    defp decode_stream(raw) do
      raw
      |> Enum.reduce({nil, []}, fn [stream_id, kv], {prev_id, acc} ->
        m = kv_to_map(kv)
        # The id the writer gave the entry (Turn.Server writes memory's), else the stream id
        # (entries written without one, including every entry before 2.0).
        id = blank_to_nil(m["id"]) || stream_id

        entry = %Entry{
          id: id,
          parent_id: prev_id,
          turn_id: blank_to_nil(m["turn_id"]),
          role: m["role"],
          content: decode(m["content"])
        }

        {id, [entry | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
    end
```

and `take_through/2` matches either id, so `fork/3` accepts any id `history/2` returned:

```elixir
    defp take_through(raw, target_id) do
      raw
      |> Enum.reduce_while([], fn [stream_id, kv] = item, acc ->
        if stream_id == target_id or kv_to_map(kv)["id"] == target_id,
          do: {:halt, Enum.reverse([item | acc])},
          else: {:cont, [item | acc]}
      end)
    end
```

Read the existing `decode_stream/1` and `take_through/2` first and keep any detail this replacement omits (e.g. a miss returning the full list vs. an error is decided by `fork/3`'s caller — keep it).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn test/behaviours/session_store && mix test --include redis test/behaviours/session_store/redis_store_extra_test.exs test/behaviours/session_store/redis_test.exs`
Expected: PASS (the Redis run needs the local Redis that the memory feature's tests used).

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/behaviours/session_store/redis.ex test/agents/turn/server_test.exs test/behaviours/session_store/redis_store_extra_test.exs
git commit -m "feat(turn-server): store each message under its memory entry id"
```

### Task 5: Tool hooks through the pipeline, template persistence, validation at init and load

**Files:**
- Modify: `lib/normandy/agents/dispatch.ex` (`Pipeline.after_tool`, `classify/3` → `route/3` + `answer/4`, `execute/4`, `dispatch_one/3`, moduledoc)
- Modify: `lib/normandy/behaviours/config.ex` (`to_pipeline/1`, moduledoc)
- Modify: `lib/normandy/agents/config_template.ex` (`from_config/2`, `rebuild/3`, moduledoc)
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1`: validate hooks next to `validate_policy_opts!`)
- Modify: `lib/normandy/agents/turn/server.ex` (`load_session/3`: `check_hooks/1`; moduledoc "Store unavailable")
- Test: `test/hooks/tool_hooks_test.exs` (new), `test/agents/config_template_test.exs` (add tests), `test/hooks/server_hooks_test.exs` (new)

**Interfaces:**
- Consumes: `Runner.before_tool/2`, `Runner.after_tool/3`, `Runner.handles?/2`, `Hooks.validate_entries!/2`, `Hooks.check_entries/1`, `Normandy.Test.Hooks.{sink/0, Probe, TurnEndOnly}`.
- Produces:
  - `%Dispatch.Pipeline{after_tool: (config, call, result -> result) | nil}` — applied by `Dispatch` to every result it returns, before the function `after_hooks` (which still see only results of tools that ran).
  - `Config.to_pipeline/1` installs a `before_hooks` adapter and `after_tool` only when some entry exports the callback.
  - `behaviours_refs.hooks` in templates; `BaseAgent.init/1` raises on invalid hooks; `Turn.Server` loading a config with invalid hooks goes `:unavailable` with `{:invalid_hooks, message}`.
  - `test/hooks/server_hooks_test.exs` helpers `Resp`, `config/2`, `llm/1`, `start/3`, `sid/0` (Tasks 6–9 extend this file).

- [ ] **Step 1: Write the failing tests**

`test/hooks/tool_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.ToolHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, ScriptedToolClient, TelemetryCapture}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}

  defp call(name \\ "probe"), do: %ToolCall{id: "call_1", name: name, input: %{}}

  defp agent(behaviours, name \\ "tool-hooks-agent") do
    %{client: %ScriptedToolClient{}, model: "test", name: name, behaviours: behaviours}
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: self()})
  end

  defp dispatch(agent, call \\ call()),
    do: Dispatch.dispatch_one(agent, call, BaseAgent.base_agent_pipeline(agent))

  defp probe(tag, opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: tag] ++ opts}

  test "no tool callbacks: the pipeline is exactly what it was before hooks" do
    f = fn _config, call -> {:cont, call} end
    pipeline = Config.to_pipeline(%Config{before_hooks: [f], hooks: [{TurnEndOnly, []}]})

    assert pipeline.before_hooks == [f]
    assert pipeline.after_hooks == []
    assert pipeline.after_tool == nil
  end

  test "module before_tool runs first; its rewrite reaches the function hooks" do
    test_pid = self()
    rewritten = %ToolCall{call() | input: %{"redacted" => true}}

    fun_hook = fn _config, call ->
      send(test_pid, {:fun_before, call.input})
      {:cont, call}
    end

    behaviours = %Config{
      hooks: [probe(:m, returns: [before_tool: {:cont, rewritten}])],
      before_hooks: [fun_hook]
    }

    assert %ToolResult{is_error: false} = dispatch(agent(behaviours))
    assert_received {:hook, :m, :before_tool, [%ToolCall{input: seen}, _ctx]}
    assert seen == %{}
    assert_received {:fun_before, %{"redacted" => true}}
  end

  test "a module halt skips later modules and the function hooks, emitting one denial" do
    test_pid = self()
    name = "tool-hooks-halt-#{System.unique_integer([:positive])}"
    ref = TelemetryCapture.attach([[:normandy, :tool, :denied]], agent_name: name)

    fun_hook = fn _config, call ->
      send(test_pid, :fun_ran)
      {:cont, call}
    end

    behaviours = %Config{
      hooks: [probe(:first, returns: [before_tool: {:halt, "blocked"}]), probe(:second)],
      before_hooks: [fun_hook]
    }

    assert %ToolResult{
             tool_call_id: "call_1",
             is_error: true,
             output: %{error: "blocked", denied: true}
           } = dispatch(agent(behaviours, name))

    refute_received {:hook, :second, :before_tool, _}
    refute_received :fun_ran
    refute_received {:probe_ctx, _}
    assert_received {:telemetry, ^ref, %{count: 1}, %{reason: :hook_halt}}
    refute_received {:telemetry, ^ref, _, _}
  end

  test "module after_tool runs before the function after-hooks; its rewrite reaches them" do
    test_pid = self()
    from_module = %ToolResult{tool_call_id: "call_1", output: "from-module", is_error: false}

    fun_hook = fn _config, _call, result ->
      send(test_pid, {:fun_after, result.output})
      %{result | output: "from-function"}
    end

    behaviours = %Config{
      hooks: [probe(:m, returns: [after_tool: {:cont, from_module}])],
      after_hooks: [fun_hook]
    }

    assert %ToolResult{output: "from-function"} = dispatch(agent(behaviours))
    assert_received {:hook, :m, :after_tool, [_call, %ToolResult{output: original}, _ctx]}
    assert original == "ns=nil"
    assert_received {:fun_after, "from-module"}
  end

  test "a policy denial passes after_tool once and the function after-hooks not at all" do
    test_pid = self()

    behaviours = %Config{
      policy:
        {Normandy.Behaviours.PolicyEngine.Ruleset,
         rules: [%{match: "probe", action: :deny, rule_id: "R1"}], default_action: :allow},
      hooks: [probe(:m)],
      after_hooks: [
        fn _config, _call, result ->
          send(test_pid, :fun_after)
          result
        end
      ]
    }

    assert %ToolResult{tool_call_id: "call_1", is_error: true, output: %{denied: true}} =
             dispatch(agent(behaviours))

    assert_received {:hook, :m, :after_tool,
                     [%ToolCall{id: "call_1"}, %ToolResult{is_error: true}, _ctx]}

    refute_received {:hook, :m, :after_tool, _}
    refute_received :fun_after
  end

  test "a registry miss passes after_tool" do
    assert %ToolResult{tool_call_id: "call_1", is_error: true} =
             dispatch(agent(%Config{hooks: [probe(:m)]}), call("nope"))

    assert_received {:hook, :m, :after_tool,
                     [%ToolCall{name: "nope"}, %ToolResult{is_error: true}, _ctx]}
  end

  test "after_tool cannot change which call a result answers" do
    other = %ToolResult{tool_call_id: "other", output: "x", is_error: false}
    behaviours = %Config{hooks: [probe(:m, returns: [after_tool: {:cont, other}])]}
    assert %ToolResult{tool_call_id: "call_1", output: "x"} = dispatch(agent(behaviours))
  end

  test "init/1 rejects malformed hooks and opts that are not plain data" do
    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      agent(%Config{hooks: [{Probe, on_error: :sometimes}]})
    end

    assert_raise ArgumentError, ~r/hook module Nope.Missing is not available/, fn ->
      agent(%Config{hooks: [{Nope.Missing, []}]})
    end

    assert_raise ArgumentError, ~r/must be plain data/, fn ->
      agent(%Config{hooks: [{Probe, notify: self()}]})
    end
  end
end
```

Add to `test/agents/config_template_test.exs`, inside `describe "round trip"` (it defines `round_trip_supplement/1` and `full_config/1`, config_template_test.exs:134-175):

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

    test "from_config refuses hook opts that are not plain data" do
      supp = round_trip_supplement()
      hooks = [{Normandy.Test.Hooks.Probe, notify: self()}]
      config = %{full_config(supp) | behaviours: %{full_config(supp).behaviours | hooks: hooks}}

      assert_raise ArgumentError, ~r/must be plain data/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end
```

`test/hooks/server_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.ServerHooksTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}

  # The FSM finalizes on a response with no tool_calls. Normandy.Test.TurnConfig.Resp has
  # no BaseIOSchema impl; this one does, so AgentMemory.history/1 can render memory.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def __str__(resp), do: resp.content
    def __rich__(resp), do: resp.content
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Built directly, as a :config start takes it (Turn.Server saves no template for a
  # :config start, server.ex:265-270): BaseAgent.init/1 validation does not run, so the
  # server's own load-time check is what these tests see.
  defp config(hooks, extra \\ %{}) do
    Map.merge(
      %BaseAgentConfig{
        input_schema: nil,
        output_schema: %Resp{},
        client: nil,
        model: "test",
        name: "server-hooks",
        memory: AgentMemory.new_memory(),
        initial_memory: AgentMemory.new_memory(),
        prompt_specification: %PromptSpecification{},
        tool_registry: nil,
        behaviours: %Config{hooks: hooks}
      },
      extra
    )
  end

  defp llm(content \\ "hi"),
    do: fn _config, _state, _request -> %Resp{content: content, tool_calls: nil} end

  # opts: :config (map merged into config/2), :handlers (map merged into the stubbed
  # default set), :store ({mod, handle}); the rest go to Turn.Server.start_link/1.
  defp start(sid, hooks, opts \\ []) do
    {config_extra, opts} = Keyword.pop(opts, :config, %{})
    {handler_overrides, opts} = Keyword.pop(opts, :handlers, %{})
    {store, opts} = Keyword.pop_lazy(opts, :store, fn -> {InMemory, InMemory.new()} end)

    handlers =
      Map.merge(%{BaseAgent.non_streaming_handlers() | call_llm: llm()}, handler_overrides)

    Turn.Server.start_link(
      [
        session_id: sid,
        config: config(hooks, config_extra),
        store: store,
        registry: {Native, Native.new()},
        handlers: handlers
      ] ++ opts
    )
  end

  defp sid, do: "server-hooks-#{System.unique_integer([:positive])}"

  describe "hook entries checked at load" do
    test "a hook module missing on this node keeps the server :unavailable with the reason" do
      {:ok, srv} = start(sid(), [{Gone.Hook, []}])

      assert {:unavailable, _} = :sys.get_state(srv)

      assert Turn.Server.run(srv, "hello") ==
               {:error, {:invalid_hooks, "hook module Gone.Hook is not available"}}

      assert Process.alive?(srv)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/hooks/tool_hooks_test.exs test/agents/config_template_test.exs test/hooks/server_hooks_test.exs`
Expected: FAIL — no hook messages; `pipeline.after_tool` is an unknown key (KeyError); `behaviours.hooks` is not restored; `init/1` accepts the bad hooks; the server with `Gone.Hook` starts `:idle`.

- [ ] **Step 3: Implement**

`lib/normandy/agents/dispatch.ex`:

Moduledoc: after the `## Telemetry` section add:

```markdown
  ## `after_tool`

  `Pipeline.after_tool` (`fn config, call, result -> result end`, default `nil`) runs on
  every result the chokepoint returns: executed, budget-denied, every `classify/3` denial
  (registry miss, invalid or schema-failing input, a before-hook halt, a policy deny) and
  `dispatch_one/3`'s interim approval denial. It runs before the function `after_hooks`,
  which see only results of tools that ran, and the result answers the call's id
  whatever it returns. `Normandy.Behaviours.Config.to_pipeline/1` sets it from the agent's
  hook modules. For a denial it receives the call as the model sent it (input
  normalized); for an executed result, the call the before-hooks produced.
```

`Pipeline`: in `@type t` after `after_hooks: [function()]` add
`after_tool: (map(), ToolCall.t(), ToolResult.t() -> ToolResult.t()) | nil` (put a comma after the `after_hooks` line), and in `defstruct` after `after_hooks: []` add `after_tool: nil` (comma after `after_hooks: []`).

Replace the `classify/3` struct clause (from `# credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity` above `def classify(config, %ToolCall{} = call, %Pipeline{} = pipeline) do` through its `end`) with:

```elixir
  def classify(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    call = %{call | input: normalize_tool_input(call.input)}

    case route(config, call, pipeline) do
      {:deny, %ToolResult{} = result} -> {:deny, answer(config, call, result, pipeline)}
      verdict -> verdict
    end
  end
```

Keep the raw-map `classify/3` clause right after it, unchanged, and add below that clause:

```elixir
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp route(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case Registry.get(config.tool_registry, call.name) do
      {:ok, _tool} when not is_map(call.input) ->
        {:deny, invalid_input_result(call)}

      {:ok, tool} ->
        # A hook may change a call's input, not which call it is: the result must
        # answer the model's tool_use id, and both shells order results by it.
        case run_before_hooks(config, call, pipeline.before_hooks) do
          {:halt, %ToolResult{} = result} ->
            emit_denied(config, call, :hook_halt)
            {:deny, %{result | tool_call_id: call.id}}

          {:cont, hooked} ->
            call = %{hooked | id: call.id}

            prepared = prepare_tool(tool, call.input)

            case validate_input(tool, call.input) do
              {:error, errors} ->
                {:deny, validation_error_result(call, errors)}

              :ok ->
                # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                case apply_policy(pipeline, config, call, prepared) do
                  {:allow, _meta} -> {:execute, prepared, call}
                  {:deny, info} -> {:deny, policy_denial(config, call, info, false)}
                  {:needs_approval, info} -> {:needs_approval, prepared, call, info}
                end
            end
        end

      :error ->
        {:deny, not_found_result(call)}
    end
  end

  # Every result the model will see passes the after_tool slot once; the result answers
  # the call's id whatever the slot returns.
  defp answer(_config, _call, result, %Pipeline{after_tool: nil}), do: result

  defp answer(config, call, result, %Pipeline{after_tool: after_tool}),
    do: %{after_tool.(config, call, result) | tool_call_id: call.id}
```

(The `route/3` body is the old `classify/3` body from `case Registry.get(...)` on, unchanged.)

In `execute/4`, replace the `case` with:

```elixir
    case pipeline.budget_check_fn.(config, call) do
      :ok ->
        result = execute_and_wrap(config, call, prepared, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)
        result = answer(config, call, result, pipeline)
        %{run_after_hooks(config, call, result, pipeline.after_hooks) | tool_call_id: call.id}

      {:error, reason} ->
        emit_denied(config, call, :budget)
        answer(config, call, budget_denial_result(call, reason), pipeline)
    end
```

In `dispatch_one/3`'s struct clause replace
`{:needs_approval, _prepared, call, info} -> policy_denial(config, call, info, true)` with
`{:needs_approval, _prepared, call, info} -> answer(config, call, policy_denial(config, call, info, true), pipeline)`.

`lib/normandy/behaviours/config.ex`:
- Moduledoc: change "adapts the **dispatch-path** slots (`policy`, `budget`, `before_hooks`, `after_hooks`)" to "adapts the **dispatch-path** slots (`policy`, `budget`, `before_hooks`, `after_hooks`, and the `before_tool`/`after_tool` callbacks of `hooks`)".
- Add `alias Normandy.Hooks.Runner` to the alias block.
- In `to_pipeline/1`, replace `before_hooks: bundle.before_hooks,` and `after_hooks: bundle.after_hooks,` with:

```elixir
      before_hooks: module_before_tool(bundle) ++ bundle.before_hooks,
      after_hooks: bundle.after_hooks,
      after_tool: module_after_tool(bundle),
```

- Below `scope/1` add:

```elixir
  # Hook modules run ahead of the function hooks: one adapter at the head of
  # before_hooks (a module halt skips the functions, since Dispatch stops at the first
  # halt) and the after_tool slot, which Dispatch applies to every result. The adapter
  # runs the hooks of the config the call is dispatched with (the agent's, whose
  # behaviours this bundle is). No entry exporting the callback, no adapter: the
  # pipeline is exactly what it was before hooks.
  defp module_before_tool(bundle) do
    if Runner.handles?(%{behaviours: bundle}, :before_tool),
      do: [fn config, call -> Runner.before_tool(config, call) end],
      else: []
  end

  defp module_after_tool(bundle) do
    if Runner.handles?(%{behaviours: bundle}, :after_tool),
      do: fn config, call, result -> Runner.after_tool(config, call, result) end,
      else: nil
  end
```

`lib/normandy/agents/config_template.ex`:
- Moduledoc: in "Everything else travels in the template: …", change "and behaviour module refs" to "behaviour module refs and hook entries (`Normandy.Behaviours.Hooks`; their opts must be plain data and hold no secrets)".
- `from_config/2`: add `hooks: storable_hooks!(b.hooks)` as the last key of `behaviours_refs` (comma after `session_registry: b.session_registry`).
- `rebuild/3`: in the `%Config{}` add `hooks: Map.get(refs, :hooks, []),` after `session_registry: refs.session_registry,`. It is not validated here: `Turn.Server` checks it when it loads the session, and reports a hook module missing on this node as `{:invalid_hooks, message}`.
- Next to `storable_fields!/1` add:

```elixir
  # Hook entries travel as given; validate_entries!/2 (load: false) refuses opts that
  # are not plain data, as unstorable?/1 does for the fields above.
  defp storable_hooks!(hooks) do
    :ok = Normandy.Behaviours.Hooks.validate_entries!(hooks, load: false)
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

`lib/normandy/agents/turn/server.ex`:
- Add `alias Normandy.Behaviours.Hooks` and `alias Normandy.Hooks.Runner` to the alias block.
- Replace `load_session/3` with:

```elixir
  defp load_session(opts, store, session_id) do
    with {:ok, config, template} <- start_config(opts, store, session_id),
         :ok <- check_hooks(config),
         {:ok, config} <- with_stored_memory(config, store, session_id),
         {:ok, turn_state} <- load_turn_state(store, session_id) do
      {:ok, config, template, turn_state}
    end
  end
```

- Next to `reconstruct_config/2` add:

```elixir
  # A hook list this node cannot run (a hook module not deployed here, invalid opts) is
  # reported like a store fault: the server waits :unavailable and retries, instead of
  # failing the start into a supervisor restart loop or running without its hooks.
  defp check_hooks(nil), do: :ok
  defp check_hooks(config), do: Hooks.check_entries(Runner.entries(config))
```

- Moduledoc, `## Store unavailable`: append the paragraph "A hook list this node cannot run (`{:invalid_hooks, message}`: a hook module missing on this node, or invalid hook opts) is handled the same way: the server waits `:unavailable`, retries, and replies that reason."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/agents/config_template_test.exs test/agents/dispatch_split_test.exs test/behaviours/config_test.exs test/agents/turn test/agents/tool_context_test.exs`
Expected: PASS (`dispatch_split_test.exs`, `config_test.exs` and `tool_context_test.exs` prove the existing hook and pipeline behaviour is unchanged).

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/agents/dispatch.ex lib/normandy/behaviours/config.ex lib/normandy/agents/config_template.ex lib/normandy/agents/base_agent.ex lib/normandy/agents/turn/server.ex test/hooks/tool_hooks_test.exs test/agents/config_template_test.exs test/hooks/server_hooks_test.exs
git commit -m "feat(hooks): tool hooks through the pipeline, every tool result passes after_tool, hooks persisted and validated"
```

### Task 6: `on_prompt` in both shells (admission split; `Turn.Server` never crashes on admission)

**Files:**
- Create: `lib/normandy/hooks/base_agent_glue.ex`
- Modify: `lib/normandy/agents/base_agent.ex` (`admit_turn_input/2` ~line 584 → `admit_input!/2` + `begin_turn/2` + `validate_turn_input!/2`; alias)
- Modify: `lib/normandy/agents/turn/server.ex` (`admit/2` ~line 646, the `{:turn, …}` `:idle` clause ~line 464, `call_handler/3` → shared `handler_crash/5`, moduledoc "Errors from `run/2`" and "Interrupted tool calls")
- Create: `test/support/streaming_probe_client.ex` (moved out of `test/agents/tool_context_test.exs`)
- Modify: `test/agents/tool_context_test.exs` (use the moved client)
- Test: `test/hooks/base_agent_hooks_test.exs` (new), `test/hooks/server_hooks_test.exs` (add)

**Interfaces:**
- Consumes: `Runner.hooks?/1`, `Runner.prompt/2`, `%HookHaltError{}` (Tasks 1–2); the `server_hooks_test.exs` helpers (Task 5).
- Produces:
  - `BaseAgent.admit_input!(config, input) :: term()` (`@doc false`) — validation, `on_prompt` on the validated input, validation of a rewrite, input guardrails; raises `ValidationError`, `HookHaltError` or `ViolationError`. `admit_input!(_, nil)` is `nil`.
  - `BaseAgent.begin_turn(config, admitted) :: config` (`@doc false`) — `initialize_turn` + the user message; `begin_turn(config, nil)` is `config`.
  - `BaseAgent.admit_turn_input/2` = `begin_turn(config, admit_input!(config, input))` (unchanged contract).
  - `Normandy.Hooks.BaseAgentGlue.prompt!/2`.
  - `Turn.Server.run/2` replies `{:error, {:rejected, %HookHaltError{event: :on_prompt}}}` for an `on_prompt` halt and `{:error, {:handler_crashed, :admit, e}}` for anything else admission raises, exits or throws; admission runs before the interrupted-batch repair.
  - `Normandy.Test.StreamingProbeClient` (Tasks 7–8 use it).
- What "validated again" guarantees (`validation_middleware.ex:51-74`): a rewrite that is a plain map, or a struct of another module, is cast and checked against the input schema; a rewrite that is already the input schema's struct is trusted as-is, exactly as a caller's struct input is; a non-map rewrite passes through unchanged (as a non-map caller input does); with `input_schema: nil` nothing is checked. A hook that builds the schema's struct by hand owns its validity.

- [ ] **Step 1: Move the streaming test client into support**

Cut `defmodule StreamingProbeClient do … end` (`test/agents/tool_context_test.exs:10-55`) into `test/support/streaming_probe_client.ex`, renamed `Normandy.Test.StreamingProbeClient`, with `@moduledoc "Streams a tool_use of the \"probe\" tool until the conversation holds a tool result, then streams the text \"done\"."` in place of `@moduledoc false`. In `tool_context_test.exs` change the alias line `alias Normandy.Test.{ContextProbe, ScriptedToolClient}` to `alias Normandy.Test.{ContextProbe, ScriptedToolClient, StreamingProbeClient}` (the one use, `%StreamingProbeClient{}` at ~line 91, then resolves to the moved module). Run `mix test test/agents/tool_context_test.exs` — expected PASS, same test count as before.

- [ ] **Step 2: Write the failing tests**

`test/hooks/base_agent_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.BaseAgentHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context
  alias Normandy.Test.{ContextProbe, StreamingProbeClient, StubClient}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe

  defmodule QueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end

  # StubClient sends {:converse, messages, opts} to :notify on every LLM call and answers
  # with the response model (test/support/stub_client.ex). retry_options defaults to nil
  # (base_agent.ex:156), so an LLM raise reaches the caller unwrapped.
  defp agent(hooks, extra \\ %{}) do
    %{
      client: %StubClient{notify: self()},
      model: "test",
      name: "hooks-agent",
      behaviours: %Config{hooks: hooks}
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  defp probe(opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}
  defp input(text), do: %BaseAgentInputSchema{chat_message: text}

  defp user_contents(config) do
    for %{role: "user", content: content} <- AgentMemory.messages(config.memory), do: content
  end

  describe "on_prompt" do
    test "the hook receives the validated input" do
      BaseAgent.run(agent([probe()], %{input_schema: %QueryInput{}}), %{"query" => "q"})

      assert_received {:hook, :p, :on_prompt,
                       [%QueryInput{query: "q"}, %Context{event: :on_prompt, turn_id: nil}]}
    end

    test "a rewrite is what memory holds" do
      hooks = [probe(returns: [on_prompt: {:cont, input("[redacted]")}])]
      {config, _response} = BaseAgent.run(agent(hooks), input("my ssn is 1"))

      assert_received {:hook, :p, :on_prompt,
                       [%BaseAgentInputSchema{chat_message: "my ssn is 1"}, _ctx]}

      assert user_contents(config) == [input("[redacted]")]
    end

    test "a plain-map rewrite the schema rejects raises ValidationError before the LLM call" do
      hooks = [probe(returns: [on_prompt: {:cont, %{}}])]
      agent = agent(hooks, %{input_schema: %QueryInput{}})

      assert_raise Normandy.Schema.ValidationError, fn ->
        BaseAgent.run(agent, %{"query" => "fine"})
      end

      refute_received {:converse, _, _}
    end

    test "a rewrite already of the schema's struct is trusted, as a caller's struct is" do
      hooks = [probe(returns: [on_prompt: {:cont, %QueryInput{query: nil}}])]

      {config, _response} =
        BaseAgent.run(agent(hooks, %{input_schema: %QueryInput{}}), %{"query" => "q"})

      assert user_contents(config) == [%QueryInput{query: nil}]
    end

    test "a halt raises HookHaltError before memory or the LLM is touched" do
      agent = agent([probe(returns: [on_prompt: {:halt, "off-topic"}])])

      error = assert_raise Normandy.HookHaltError, fn -> BaseAgent.run(agent, input("hi")) end
      assert %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"} = error
      refute_received {:converse, _, _}
    end

    test "a nil input runs no on_prompt hook" do
      BaseAgent.run(agent([probe()]), nil)
      refute_received {:hook, :p, :on_prompt, _}
    end

    test "runs on the streaming path" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "test",
          name: "hooks-stream",
          behaviours: %Config{hooks: [probe()]}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)

      assert_received {:hook, :p, :on_prompt, [%BaseAgentInputSchema{chat_message: "go"}, _ctx]}
    end
  end
end
```

In `test/hooks/server_hooks_test.exs`, replace the alias block with:

```elixir
  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate, Turn}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe
```

add, after the `Resp` impl:

```elixir
  defmodule QueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end
```

add, after `sid/0`:

```elixir
  defp probe(opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}
```

and add this describe at the end of the module:

```elixir
  describe "on_prompt" do
    test "a halt replies {:rejected, %HookHaltError{}}, stores nothing and keeps the server" do
      store = InMemory.new()
      session = sid()

      {:ok, srv} =
        start(session, [probe(returns: [on_prompt: {:halt, "off-topic"}])],
          store: {InMemory, store}
        )

      assert {:error,
              {:rejected,
               %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"}}} =
               Turn.Server.run(srv, "hello")

      assert {:ok, []} = InMemory.history(store, session)
      assert Process.alive?(srv)
    end

    test "the hook sees the validated input; the rewrite is what the store holds" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_prompt: {:cont, %QueryInput{query: "[redacted]"}}])]

      {:ok, srv} =
        start(session, hooks, store: {InMemory, store}, config: %{input_schema: %QueryInput{}})

      assert {:ok, _} = Turn.Server.run(srv, %{"query" => "my ssn is 1"})

      assert_receive {:hook, :p, :on_prompt,
                      [%QueryInput{query: "my ssn is 1"}, %Normandy.Hooks.Context{turn_id: nil}]}

      assert {:ok, [%{role: "user", content: %QueryInput{query: "[redacted]"}} | _]} =
               InMemory.history(store, session)
    end

    test "a hook crashing under :reraise replies {:handler_crashed, :admit, e}; the server lives" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:raise, "redactor down"}])])

      assert {:error, {:handler_crashed, :admit, %RuntimeError{message: "redactor down"}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
      assert {:error, {:handler_crashed, :admit, _}} = Turn.Server.run(srv, "again")
    end

    test "a contract violation is replied the same way" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: :yes])])

      assert {:error, {:handler_crashed, :admit, %ArgumentError{}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "hooks saved in a config template run after a thin start" do
      sink = TestHooks.sink()
      session = sid()
      store = InMemory.new()
      {:ok, catalog} = Catalog.start_link([])

      :ok =
        Catalog.put(catalog, "hooks-kind", %{
          tool_registry: nil,
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _token -> nil end
        })

      behaviours = %Config{
        hooks: [{Probe, notify: sink, tag: :tmpl}],
        credential: {Normandy.Test.StubCreds, []}
      }

      tmpl = ConfigTemplate.from_config(config([], %{behaviours: behaviours}), "hooks-kind")
      :ok = InMemory.save_config_template(store, session, tmpl)

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: session,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          template_provider: {Catalog, catalog},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: llm()}
        )

      assert {:ok, %Resp{content: "hi"}} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :tmpl, :on_prompt, ["hello", _ctx]}
    end
  end
```

Also add to `test/agents/turn/server_test.exs`, inside `describe "dangling tool_use repair"` after the test "a rejected input in a dangling session changes nothing":

```elixir
    test "a rejected input runs no repair; the accepted input after it repairs once" do
      {srv, store} =
        start_dangling_server("s-dangling-reject-then-run", %{input_schema: %RequiredQueryInput{}})

      assert {:error, {:rejected, _}} = Turn.Server.run(srv, %{})
      refute_received {:llm_messages, _}

      capture_log(fn -> assert {:ok, _} = Turn.Server.run(srv, %{"query" => "q"}) end)

      {:ok, entries} = InMemory.history(store, "s-dangling-reject-then-run")
      assert Enum.count(entries, &(&1.role == "tool")) == 1
    end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/hooks/base_agent_hooks_test.exs test/hooks/server_hooks_test.exs test/agents/turn/server_test.exs`
Expected: FAIL — no `on_prompt` messages; the halt tests see no `HookHaltError`; the Server crash test exits the caller instead of replying (the server crashes). The new dangling test passes already (it pins that the reorder keeps a rejected input from storing anything).

- [ ] **Step 4: Implement**

`lib/normandy/hooks/base_agent_glue.ex`:

```elixir
defmodule Normandy.Hooks.BaseAgentGlue do
  @moduledoc false
  # BaseAgent's hook call sites, so base_agent.ex keeps one-line calls. An agent with no
  # hooks does no hook work: each function checks Runner.hooks?/1 first.

  alias Normandy.HookHaltError
  alias Normandy.Hooks.Runner

  @doc "Runs `on_prompt` on the validated input; raises `HookHaltError` on a halt."
  @spec prompt!(map(), term()) :: term()
  def prompt!(config, input) do
    if Runner.hooks?(config), do: run_prompt!(config, input), else: input
  end

  defp run_prompt!(config, input) do
    case Runner.prompt(config, input) do
      {:cont, admitted} ->
        admitted

      {:halt, hook, reason} ->
        raise HookHaltError, event: :on_prompt, hook: hook, reason: reason
    end
  end
end
```

`lib/normandy/agents/base_agent.ex`: add `alias Normandy.Hooks.BaseAgentGlue` to the alias block, and replace both `admit_turn_input/2` clauses (from `@doc false` above `def admit_turn_input(config, nil)` through the end of the second clause) with:

```elixir
  @doc false
  def admit_turn_input(config, nil), do: config

  def admit_turn_input(config, user_input),
    do: begin_turn(config, admit_input!(config, user_input))

  @doc false
  # Admission without the memory append, so Turn.Server can admit a turn's input before
  # it repairs an interrupted batch: schema validation, on_prompt hooks on the validated
  # input, validation of a rewritten input, input guardrails. Raises
  # Normandy.Schema.ValidationError, Normandy.HookHaltError or
  # Normandy.Guardrails.ViolationError; returns the admitted input.
  @spec admit_input!(BaseAgentConfig.t(), term()) :: term()
  def admit_input!(_config, nil), do: nil

  def admit_input!(config, user_input) do
    validated = validate_turn_input!(config, user_input)

    # A rewrite is validated like a caller's input: a plain map or another struct is
    # cast and checked against the input schema; a value already of the schema's struct
    # is trusted, as a caller's is (ValidationMiddleware.validate_input/2).
    admitted =
      case BaseAgentGlue.prompt!(config, validated) do
        ^validated -> validated
        rewritten -> validate_turn_input!(config, rewritten)
      end

    run_input_guardrails!(config, admitted)
    admitted
  end

  @doc false
  # Starts the turn in memory with an admitted input.
  @spec begin_turn(BaseAgentConfig.t(), term()) :: BaseAgentConfig.t()
  def begin_turn(config, nil), do: config

  def begin_turn(config, admitted) do
    updated_memory =
      config.memory
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", admitted)

    config
    |> Map.put(:current_user_input, admitted)
    |> Map.put(:memory, updated_memory)
  end

  defp validate_turn_input!(config, user_input) do
    case ValidationMiddleware.validate_input(config, user_input) do
      {:ok, validated} ->
        validated || user_input

      {:error, errors} ->
        raise Normandy.Schema.ValidationError,
          message: "Agent input validation failed",
          errors: errors,
          details: ValidationMiddleware.error_message(errors)
    end
  end
```

`lib/normandy/agents/turn/server.ex`:

Replace `call_handler/3` (keep its comment) with:

```elixir
  defp call_handler(data, name, fun) do
    {:ok, fun.()}
  catch
    kind, reason -> handler_crash(data, name, kind, reason, __STACKTRACE__)
  end

  # Logs a crash in a handler or hook the server ran (never its values, see
  # describe_crash/3) and returns {:crashed, {:handler_crashed, name, exception_or_term}}.
  defp handler_crash(data, name, kind, reason, stacktrace) do
    Logger.error(
      "Turn.Server handler #{inspect(name)} crashed (session #{inspect(data.session_id)}): " <>
        describe_crash(kind, reason, stacktrace) <>
        "\n" <> Exception.format_stacktrace(arity_only(stacktrace))
    )

    {:crashed, {:handler_crashed, name, Exception.normalize(kind, reason, stacktrace)}}
  end
```

Replace `admit/2` and its comment with:

```elixir
  # Schema, input-guardrail and on_prompt-hook rejections are expected outcomes: reply
  # them as data without touching state. Anything else admission raises, exits or throws
  # (a hook or input guardrail crashing under on_error: :reraise, a hook's contract
  # violation) is replied as {:handler_crashed, :admit, e} instead of crashing the
  # session (and, through restart intensity, Turn.Supervisor).
  defp admit(data, user_input) do
    {:ok, BaseAgent.admit_input!(data.config, user_input)}
  rescue
    e in [
      Normandy.Schema.ValidationError,
      Normandy.Guardrails.ViolationError,
      Normandy.HookHaltError
    ] ->
      {:rejected, e}
  catch
    kind, reason -> handler_crash(data, :admit, kind, reason, __STACKTRACE__)
  end
```

Replace the `{:turn, user_input, caller_ctx}` `:idle` clause with:

```elixir
  def handle_event({:call, from}, {:turn, user_input, caller_ctx}, :idle, data) do
    missing = data.config.memory |> AgentMemory.messages() |> Turn.unanswered_tool_calls()

    # Admission first: a rejected input changes nothing, and the interrupted results the
    # repair builds belong to a turn that runs.
    with {:ok, admitted} <- admit(data, user_input),
         {:ok, repairs} <- close_batch(data, missing) do
      config = BaseAgent.begin_turn(last_config(repairs, data.config), admitted)
      start_turn(from, {user_input, caller_ctx}, config, repairs, data)
    else
      {:rejected, exception} ->
        emit_rejected_run(data, caller_ctx, exception)
        {:keep_state, data, [{:reply, from, {:error, {:rejected, exception}}}]}

      {:crashed, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end
```

Moduledoc, `## Errors from run/2`: replace the `{:rejected, exception}` and `{:handler_crashed, …}` bullets with:

```markdown
    * `{:rejected, exception}` — the input failed its schema
      (`Normandy.Schema.ValidationError`) or an input guardrail
      (`Normandy.Guardrails.ViolationError`), or an `on_prompt` hook halted it
      (`Normandy.HookHaltError`), and nothing was persisted; or an output guardrail
      blocked the answer (`Normandy.Guardrails.ViolationError`), and the answer was not
      saved (the user message was).
    * `{:handler_crashed, name, exception_or_term}` — a synchronous handler
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`) raised, exited or threw; or
      admission did (`:admit`: an `on_prompt` hook or an input guardrail crashing under
      `on_error: :reraise`, or a hook's return-contract violation).
```

and in `## Interrupted tool calls` change "The next turn appends an `interrupted: true` tool result for each missing call," to "The next turn whose input is admitted (a rejected input repairs nothing) appends an `interrupted: true` tool result for each missing call,".

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/agents test/integration/compaction_turn_test.exs`
Expected: PASS — including the unchanged dangling-repair tests in `server_test.exs` (an append crash during repair still replies `{:handler_crashed, :append, _}`, server_test.exs:2206).

- [ ] **Step 6: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/base_agent_glue.ex lib/normandy/agents/base_agent.ex lib/normandy/agents/turn/server.ex test/support/streaming_probe_client.ex test/agents/tool_context_test.exs test/hooks/base_agent_hooks_test.exs test/hooks/server_hooks_test.exs test/agents/turn/server_test.exs
git commit -m "feat(hooks): on_prompt on validated input in both shells; Turn.Server replies admission crashes"
```

### Task 7: `on_turn_end` in both shells (after the run span; after the reply)

**Files:**
- Modify: `lib/normandy/hooks/base_agent_glue.ex` (`turn_end_ok/2`, `turn_end_raised/4`)
- Create: `lib/normandy/hooks/server_glue.ex` (`fail_outcome/1`)
- Modify: `lib/normandy/agents/base_agent.ex` (`with_agent_run_span/3` ~line 1681)
- Modify: `lib/normandy/agents/turn/server.ex` (`{:finalize, _}`/`{:fail, _}` ~lines 997-1011, the `{:turn, …}` clause's `else`, `start_turn/5`'s `else`, new `turn_end/5`)
- Test: `test/hooks/base_agent_hooks_test.exs`, `test/hooks/server_hooks_test.exs` (add)

**Interfaces:**
- Consumes: `Runner.turn_end/3`, `HookHaltError.outcome/1`, `call_handler/3` (server.ex).
- Produces:
  - `BaseAgentGlue.turn_end_ok(config, result) :: :ok`, `BaseAgentGlue.turn_end_raised(config, kind, reason, stacktrace) :: :ok`.
  - `Normandy.Hooks.ServerGlue.fail_outcome(reason) :: Hooks.outcome()` — `{:rejected, e}` stays a rejection, anything else is `{:error, reason}`.
  - `on_turn_end` outcomes per spec §6. `BaseAgent` runs it after `[:normandy, :agent, :run, :stop | :exception]`; `Turn.Server` after the caller's reply, at `:finalize`, `:fail`, a rejected input, an admission or repair crash, and a failed write of the turn's first messages.

- [ ] **Step 1: Write the failing tests**

In `test/hooks/base_agent_hooks_test.exs` add `alias Normandy.Test.TelemetryCapture` to the alias block, this helper after `user_contents/1`:

```elixir
  # Every message in the mailbox, in arrival order.
  defp mailbox do
    receive do
      msg -> [msg | mailbox()]
    after
      0 -> []
    end
  end

  defp raising_client,
    do: %StubClient{reply: fn _ -> raise ArgumentError, "transport blew up" end}
```

and this describe at the end of the module:

```elixir
  describe "on_turn_end" do
    test "a completed run reports {:ok, response} with the turn's id, after the run span closes" do
      name = "hooks-turn-end-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :stop]], agent_name: name)

      {config, response} = BaseAgent.run(agent([probe()], %{name: name}), input("hi"))

      ordered =
        Enum.filter(
          mailbox(),
          &(match?({:span, _, _}, &1) or match?({:hook, :p, :on_turn_end, _}, &1))
        )

      assert [
               {:span, [:normandy, :agent, :run, :stop], _},
               {:hook, :p, :on_turn_end, [{:ok, ^response}, %Context{turn_id: turn_id}]}
             ] = ordered

      assert turn_id == config.memory.current_turn_id
      refute is_nil(turn_id)
    end

    test "an on_prompt halt reports {:rejected, %HookHaltError{}} with no turn id" do
      agent = agent([probe(returns: [on_prompt: {:halt, "no"}])])
      catch_error(BaseAgent.run(agent, input("hi")))

      assert_received {:hook, :p, :on_turn_end,
                       [
                         {:rejected, %Normandy.HookHaltError{event: :on_prompt}},
                         %Context{turn_id: nil}
                       ]}
    end

    test "a schema rejection reports {:rejected, %ValidationError{}}" do
      agent = agent([probe()], %{input_schema: %QueryInput{}})
      catch_error(BaseAgent.run(agent, %{}))

      assert_received {:hook, :p, :on_turn_end,
                       [{:rejected, %Normandy.Schema.ValidationError{}}, _ctx]}
    end

    test "a failing run reports {:error, exception} and raises the original error" do
      agent = agent([probe()], %{client: raising_client()})

      assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run(agent, input("hi")) end

      assert_received {:hook, :p, :on_turn_end,
                       [{:error, %ArgumentError{message: "transport blew up"}}, %Context{turn_id: nil}]}
    end

    @tag :capture_log
    test "a crashing on_turn_end changes neither a result nor a raised error" do
      crashing = [probe(returns: [on_turn_end: {:raise, "audit down"}])]
      assert {_config, _response} = BaseAgent.run(agent(crashing), input("hi"))

      assert_raise ArgumentError, "transport blew up", fn ->
        BaseAgent.run(agent(crashing, %{client: raising_client()}), input("hi"))
      end
    end

    test "an on_turn_end return value is ignored, on success and on failure" do
      assert {_config, _response} =
               BaseAgent.run(agent([probe(returns: [on_turn_end: :done])]), input("hi"))

      failing = agent([probe(returns: [on_turn_end: {:error, :audit}])], %{client: raising_client()})
      assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run(failing, input("hi")) end
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
```

In `test/hooks/server_hooks_test.exs` add, after `QueryInput`:

```elixir
  # Holds on_turn_end until released: run/2 returning while it waits proves the reply
  # went out first.
  defmodule HoldsTurnEnd do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_turn_end(_outcome, _ctx, opts) do
      send(opts[:notify], :turn_end_running)

      receive do
        :release -> :ok
      end
    end
  end

  # Fails every "user" append; everything else goes to InMemory.
  defmodule UserAppendFailStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory
    def new, do: InMemory.new()
    def append_entry(_h, _sid, %{role: "user"}), do: {:error, :disk_full}
    def append_entry(h, sid, e), do: InMemory.append_entry(h, sid, e)
    def save_turn_state(h, sid, t), do: InMemory.save_turn_state(h, sid, t)
    def load_turn_state(h, sid), do: InMemory.load_turn_state(h, sid)
    def history(h, sid), do: InMemory.history(h, sid)
  end
```

and this describe at the end of the module:

```elixir
  describe "on_turn_end" do
    test "a completed turn reports {:ok, final} with the turn's id" do
      {:ok, srv} = start(sid(), [probe()])

      assert {:ok, %Resp{content: "hi"} = final} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :on_turn_end, [{:ok, ^final}, ctx]}
      refute is_nil(ctx.turn_id)
    end

    test "the caller gets the reply before on_turn_end runs" do
      {:ok, srv} = start(sid(), [{HoldsTurnEnd, notify: TestHooks.sink()}])

      task = Task.async(fn -> Turn.Server.run(srv, "hello") end)
      assert {:ok, {:ok, %Resp{content: "hi"}}} = Task.yield(task, 2_000)
      assert_receive :turn_end_running
      send(srv, :release)
    end

    test "a crashing or contract-violating on_turn_end changes neither the reply nor the server" do
      {:ok, crashing} = start(sid(), [probe(returns: [on_turn_end: {:raise, "audit down"}])])
      assert {:ok, _} = Turn.Server.run(crashing, "hello")

      {:ok, violating} = start(sid(), [probe(returns: [on_turn_end: :done])])
      assert {:ok, _} = Turn.Server.run(violating, "hello")

      assert Process.alive?(crashing)
      assert Process.alive?(violating)
    end

    test "a rejected input reports {:rejected, e} with no turn id" do
      {:ok, srv} = start(sid(), [probe()], config: %{input_schema: %QueryInput{}})

      assert {:error, {:rejected, %Normandy.Schema.ValidationError{}}} =
               Turn.Server.run(srv, %{})

      assert_receive {:hook, :p, :on_turn_end,
                      [
                        {:rejected, %Normandy.Schema.ValidationError{}},
                        %Normandy.Hooks.Context{turn_id: nil}
                      ]}
    end

    test "an admission crash reports {:error, {:handler_crashed, :admit, e}}" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:raise, "x"}])])

      assert {:error, {:handler_crashed, :admit, _}} = Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end,
                      [{:error, {:handler_crashed, :admit, %RuntimeError{}}}, _ctx]}
    end

    test "a failed write of the turn's first message reports {:error, {:persist_failed, reason}}" do
      {:ok, srv} =
        start(sid(), [probe()], store: {UserAppendFailStore, UserAppendFailStore.new()})

      assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :on_turn_end, [{:error, {:persist_failed, :disk_full}}, _ctx]}
    end

    test "ServerGlue.fail_outcome/1: an output-guardrail block is a rejection, the rest errors" do
      e = %Normandy.Guardrails.ViolationError{message: "blocked", violations: []}
      assert Normandy.Hooks.ServerGlue.fail_outcome({:rejected, e}) == {:rejected, e}

      assert Normandy.Hooks.ServerGlue.fail_outcome({:approval_timeout, ["t"]}) ==
               {:error, {:approval_timeout, ["t"]}}
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/hooks/base_agent_hooks_test.exs test/hooks/server_hooks_test.exs`
Expected: FAIL — no `on_turn_end` messages arrive (the reply-order test fails at `assert_receive :turn_end_running`); the `fail_outcome/1` test fails with `Normandy.Hooks.ServerGlue` undefined.

- [ ] **Step 3: Implement**

Append to `lib/normandy/hooks/base_agent_glue.ex` (inside the module), and add `alias Normandy.Guardrails.ViolationError` and `alias Normandy.Schema.ValidationError` to its alias block:

```elixir
  @doc """
  Runs `on_turn_end` for a run that returned. The run's own config carries the memory,
  so the turn's id reaches the hook.
  """
  @spec turn_end_ok(map(), term()) :: :ok
  def turn_end_ok(_config, {%{memory: _} = after_run, response}) do
    if Runner.hooks?(after_run), do: Runner.turn_end(after_run, {:ok, response})
    :ok
  end

  def turn_end_ok(config, result) do
    if Runner.hooks?(config), do: Runner.turn_end(config, {:ok, result})
    :ok
  end

  @doc """
  Runs `on_turn_end` for a run that raised, exited or threw. The run's config is lost
  with the exception, so the hook gets `turn_id: nil` rather than the previous turn's.
  The Runner never raises for `on_turn_end`, so the caller re-raises the original.
  """
  @spec turn_end_raised(map(), atom(), term(), Exception.stacktrace()) :: :ok
  def turn_end_raised(config, kind, reason, stacktrace) do
    if Runner.hooks?(config) do
      outcome = raised_outcome(kind, Exception.normalize(kind, reason, stacktrace))
      Runner.turn_end(config, outcome, turn_id: nil)
    end

    :ok
  end

  # Input that never became a turn is :rejected, as Turn.Server reports it; an output
  # guardrail block is a rejection too.
  defp raised_outcome(:error, %HookHaltError{} = e), do: HookHaltError.outcome(e)
  defp raised_outcome(:error, %ValidationError{} = e), do: {:rejected, e}
  defp raised_outcome(:error, %ViolationError{} = e), do: {:rejected, e}
  defp raised_outcome(:error, exception), do: {:error, exception}
  defp raised_outcome(kind, reason), do: {:error, {kind, reason}}
```

`lib/normandy/hooks/server_glue.ex`:

```elixir
defmodule Normandy.Hooks.ServerGlue do
  @moduledoc false
  # Turn.Server's hook logic, so server.ex keeps one-line call sites. Every call the
  # server makes into hook code goes through its call_handler/3, so no hook outcome
  # terminates the server.

  @doc "The `on_turn_end` outcome of a failed turn: an output-guardrail block stays a rejection."
  @spec fail_outcome(term()) :: Normandy.Behaviours.Hooks.outcome()
  def fail_outcome({:rejected, exception}), do: {:rejected, exception}
  def fail_outcome(reason), do: {:error, reason}
end
```

`lib/normandy/agents/base_agent.ex`: replace `with_agent_run_span/3` with (the span's body is the original, unchanged):

```elixir
  # on_turn_end runs after the run span closes, on both outcomes, so its time is not
  # the run's and its hook span is not the run's child; a raised run's exception is
  # re-raised unchanged after the hook (the Runner never raises for on_turn_end).
  defp with_agent_run_span(config, telemetry_metadata, fun) do
    :telemetry.span([:normandy, :agent, :run], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy agent run start",
        agent: log_agent_name(config),
        iteration: 0,
        max_iterations: max_run_iterations(config)
      )

      started_at = System.monotonic_time()

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
          reraise(error, __STACKTRACE__)
      catch
        kind, reason ->
          log_span_exception("normandy agent exception", config, kind, reason)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      BaseAgentGlue.turn_end_raised(config, kind, reason, stacktrace)
      :erlang.raise(kind, reason, stacktrace)
  else
    result ->
      BaseAgentGlue.turn_end_ok(config, result)
      result
  end
```

`lib/normandy/agents/turn/server.ex`: add `alias Normandy.Hooks.ServerGlue` to the alias block, and add next to `call_handler/3`:

```elixir
  # on_turn_end is logged-only (the Runner logs a crashing hook and ignores its return);
  # call_handler/3 is the belt over those braces. Callers run it after the reply.
  defp turn_end(data, config, outcome, ctx_opts \\ []) do
    if Runner.hooks?(config),
      do: call_handler(data, :on_turn_end, fn -> Runner.turn_end(config, outcome, ctx_opts) end)

    :ok
  end
```

In `interpret/2` replace the `{:finalize, value}` and `{:fail, reason}` clauses (keeping their comments) with:

```elixir
      {:finalize, value} ->
        # Persist the terminal (:stopped) turn state so the resume reaper can tell a
        # completed session from a mid-turn one. Best-effort: the turn already
        # succeeded, so a failed marker-persist must not fail it.
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :stop, %{})
        reply(data, {:ok, value})
        turn_end(data, data.config, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}

      {:fail, reason} ->
        # Persist the terminal (:failed) turn state (best-effort) for the same reason.
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :exception, %{kind: :error, reason: reason, stacktrace: []})
        reply(data, {:error, reason})
        turn_end(data, data.config, ServerGlue.fail_outcome(reason))
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}
```

In the `{:turn, user_input, caller_ctx}` clause replace the `else` branches with:

```elixir
    else
      {:rejected, exception} ->
        emit_rejected_run(data, caller_ctx, exception)
        :gen_statem.reply(from, {:error, {:rejected, exception}})
        turn_end(data, data.config, {:rejected, exception}, turn_id: nil)
        {:keep_state, data}

      {:crashed, reason} ->
        :gen_statem.reply(from, {:error, reason})
        turn_end(data, data.config, {:error, reason}, turn_id: nil)
        {:keep_state, data}
    end
```

In `start_turn/5` replace the `else` branch with:

```elixir
    else
      {:error, stored, reason} ->
        :gen_statem.reply(from, persist_failed(reason))
        turn_end(data, config, persist_failed(reason))
        {:keep_state, %{data | config: stored}}
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/agents test/telemetry`
Expected: PASS — the agent and telemetry suites unchanged (no hooks configured there: `turn_end/5` and both glue functions return at the `Runner.hooks?/1` check).

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/base_agent_glue.ex lib/normandy/hooks/server_glue.ex lib/normandy/agents/base_agent.ex lib/normandy/agents/turn/server.ex test/hooks/base_agent_hooks_test.exs test/hooks/server_hooks_test.exs
git commit -m "feat(hooks): on_turn_end after the run span and after the reply, in both shells"
```

### Task 8: `before_llm` and `after_compact` around any handler set

**Files:**
- Create: `lib/normandy/hooks/handlers.ex`
- Modify: `lib/normandy/agents/base_agent.ex` (`drive_turn/2` ~line 615, `run_stream_turn/3` ~line 978; alias)
- Modify: `lib/normandy/agents/turn/server.ex` (`init_data/4` handlers ~line 306, the `{:call_llm, request}` effect ~line 978, new `call_llm_event/3`, moduledoc)
- Test: `test/hooks/llm_compaction_hooks_test.exs` (new), `test/hooks/server_hooks_test.exs` (add)

**Interfaces:**
- Consumes: `Runner.handles?/2`, `Runner.before_llm/2`, `Runner.after_compact/3`, the `Compactor` `:dropped` contract and `Normandy.Test.KeepLastCompactor` (Task 3), store entry ids (Task 4), `Normandy.Test.StreamingProbeClient` (Task 6), `on_turn_end` (Task 7).
- Produces:
  - `Normandy.Hooks.Handlers.wrap(%Turn.Driver.Handlers{}, config) :: %Turn.Driver.Handlers{}` — wraps `call_llm` (`before_llm`; a halt raises `%HookHaltError{event: :before_llm}`) when an entry exports `before_llm`, and `compact` (`after_compact` on a non-empty `meta.dropped`; injected texts appended to the compacted memory) when an entry exports `after_compact`. Otherwise returns the set unchanged. Each shell wraps its set once; the default handler sets hold no hook calls, so nothing runs twice.
  - `Turn.Server.run/2` replies `{:error, {:hook_halted, %HookHaltError{event: :before_llm}}}` for a `before_llm` halt, with default or custom `:handlers`.

- [ ] **Step 1: Write the failing tests**

`test/hooks/llm_compaction_hooks_test.exs`:

```elixir
defmodule Normandy.Hooks.LlmCompactionHooksTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{AgentMemory, Message, ToolResult}
  alias Normandy.Test.{ContextProbe, KeepLastCompactor, StreamingProbeClient, StubClient}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe

  defp probe(opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}
  defp input(text), do: %BaseAgentInputSchema{chat_message: text}

  defp agent(behaviours, extra \\ %{}) do
    %{
      client: %StubClient{notify: self()},
      model: "test",
      name: "llm-hooks-agent",
      behaviours: behaviours
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  # Every message in the mailbox, in arrival order.
  defp mailbox do
    receive do
      msg -> [msg | mailbox()]
    after
      0 -> []
    end
  end

  defp seeded_memory do
    AgentMemory.new_memory()
    |> AgentMemory.add_message("user", "old-1")
    |> AgentMemory.add_message("assistant", "old-2")
    |> AgentMemory.add_message("user", "old-3")
  end

  # keep: 2 at turn start holds old-3 and the new input; the rest is dropped.
  defp keep_two(hooks),
    do: %Config{compactor: {KeepLastCompactor, keep: 2, max_tokens: 200_000}, hooks: hooks}

  describe "before_llm" do
    test "runs before each LLM call with the call's info" do
      BaseAgent.run(agent(%Config{hooks: [probe()]}), input("hi"))

      assert [
               {:hook, :p, :before_llm, [%{final: false, iterations_left: left}, _ctx]},
               {:converse, _, _}
             ] =
               Enum.filter(
                 mailbox(),
                 &(match?({:hook, :p, :before_llm, _}, &1) or match?({:converse, _, _}, &1))
               )

      assert is_integer(left)
    end

    test "a halt raises HookHaltError, skips the LLM and reports the halt at turn end" do
      agent = agent(%Config{hooks: [probe(returns: [before_llm: {:halt, "budget spent"}])]})

      error = assert_raise Normandy.HookHaltError, fn -> BaseAgent.run(agent, input("hi")) end

      assert %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget spent"} =
               error

      refute_received {:converse, _, _}
      assert_received {:hook, :p, :on_turn_end, [{:error, {:hook_halted, ^error}}, _ctx]}
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
    test "receives the compactor's dropped entries, with their ids, and meta without :dropped" do
      memory = seeded_memory()
      [old1, old2, _old3] = AgentMemory.entry_chain(memory)

      BaseAgent.run(agent(keep_two([probe()]), %{memory: memory}), input("now"))

      assert_received {:hook, :p, :after_compact, [dropped, meta, _ctx]}
      assert dropped == [old1, old2]
      assert meta.compacted
      refute Map.has_key?(meta, :dropped)
    end

    test "injected texts are appended to the compacted memory, before the LLM call" do
      hooks = [probe(returns: [after_compact: {:inject, ["remember: prefers metric"]}])]

      {config, _response} =
        BaseAgent.run(agent(keep_two(hooks), %{memory: seeded_memory()}), input("now"))

      contents = config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)

      assert [
               "old-3",
               %BaseAgentInputSchema{chat_message: "now"},
               "remember: prefers metric" | _assistant
             ] = contents

      assert_received {:converse, messages, _opts}
      assert Enum.any?(messages, &(&1.content == "remember: prefers metric"))
    end

    test "does not fire when the compactor dropped nothing" do
      behaviours = %Config{
        compactor: {KeepLastCompactor, keep: 100, max_tokens: 200_000},
        hooks: [probe()]
      }

      BaseAgent.run(agent(behaviours), input("hi"))
      refute_received {:hook, :p, :after_compact, _}
    end

    test "Compactor.WindowManager: dropped is exactly what :oldest_first removed, by id" do
      memory =
        Enum.reduce(1..40, AgentMemory.new_memory(), fn i, m ->
          AgentMemory.add_message(m, "user", "message number #{i} padding")
        end)

      seeded_ids = memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)

      behaviours = %Config{
        compactor:
          {Normandy.Behaviours.Compactor.WindowManager, max_tokens: 80, reserved_tokens: 16},
        hooks: [probe()]
      }

      {config, _response} = BaseAgent.run(agent(behaviours, %{memory: memory}), input("now"))

      assert_received {:hook, :p, :after_compact, [dropped, _meta, _ctx]}
      dropped_ids = Enum.map(dropped, & &1.id)
      kept_ids = config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)

      assert dropped != []
      assert dropped_ids == Enum.take(seeded_ids, length(dropped_ids))
      assert MapSet.disjoint?(MapSet.new(dropped_ids), MapSet.new(kept_ids))
    end

    test "the adapter neither merges nor drops consecutive user messages" do
      messages =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "hi")
        |> AgentMemory.add_message("tool", %ToolResult{
          tool_call_id: "toolu_1",
          output: "ok",
          is_error: false
        })
        |> AgentMemory.add_message("user", "remember: prefers metric")
        |> AgentMemory.history()
        |> Enum.map(fn %{role: role, content: content} -> %Message{role: role, content: content} end)

      request =
        Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter.add_messages(
          Request.new("m"),
          messages,
          false
        )

      assert Enum.map(request.messages, & &1["role"]) == ["user", "user", "user"]
    end
  end
end
```

In `test/hooks/server_hooks_test.exs` add `alias Normandy.Test.KeepLastCompactor` to the alias block and this describe at the end:

```elixir
  describe "before_llm and after_compact with the server's handlers" do
    # start/3 always passes custom handlers (a stubbed call_llm): these tests prove the
    # hooks do not depend on BaseAgent's own handler functions.
    test "before_llm runs once per LLM call" do
      {:ok, srv} = start(sid(), [probe()])

      assert {:ok, _} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :before_llm, [%{final: false}, _ctx]}
      refute_received {:hook, :p, :before_llm, _}
    end

    test "a before_llm halt replies {:hook_halted, e} and on_turn_end sees the same" do
      {:ok, srv} = start(sid(), [probe(returns: [before_llm: {:halt, "budget"}])])

      assert {:error,
              {:hook_halted,
               %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget"} = e}} =
               Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end, [{:error, {:hook_halted, ^e}}, _ctx]}
      assert Process.alive?(srv)
    end

    test "after_compact gets dropped entries under their store ids; injections stay out of the store" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [after_compact: {:inject, ["remember: metric"]}])]

      behaviours = %Config{
        hooks: hooks,
        compactor: {KeepLastCompactor, keep: 1, max_tokens: 200_000}
      }

      {:ok, srv} =
        start(session, hooks, store: {InMemory, store}, config: %{behaviours: behaviours})

      assert {:ok, _} = Turn.Server.run(srv, "one")
      {:ok, first_turn} = InMemory.history(store, session)

      assert {:ok, _} = Turn.Server.run(srv, "two")
      assert_receive {:hook, :p, :after_compact, [dropped, _meta, _ctx]}
      assert Enum.map(dropped, & &1.id) == Enum.map(first_turn, & &1.id)

      {:ok, stored} = InMemory.history(store, session)
      refute Enum.any?(stored, &(&1.content == "remember: metric"))

      {_state, data} = :sys.get_state(srv)
      assert Enum.any?(AgentMemory.messages(data.config.memory), &(&1.content == "remember: metric"))
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/hooks/llm_compaction_hooks_test.exs test/hooks/server_hooks_test.exs`
Expected: FAIL — no `before_llm`/`after_compact` hook messages; the halt tests see nothing raised and the server replies `{:ok, _}`. (The adapter test passes already: it pins existing behaviour.)

- [ ] **Step 3: Implement**

`lib/normandy/hooks/handlers.ex`:

```elixir
defmodule Normandy.Hooks.Handlers do
  @moduledoc """
  Wraps a `Normandy.Agents.Turn.Driver.Handlers` set so `before_llm` and `after_compact`
  hooks run whatever handlers a shell was given: BaseAgent's own sets, or the `:handlers`
  a caller passes to `Turn.Server`. Each shell wraps its set once, and the default sets
  hold no hook calls, so no hook runs twice. A config with no entry exporting a callback
  gets its handler back unwrapped.
  """

  alias Normandy.Agents.Turn.Driver
  alias Normandy.Components.AgentMemory
  alias Normandy.HookHaltError
  alias Normandy.Hooks.Runner

  @spec wrap(Driver.Handlers.t(), map() | nil) :: Driver.Handlers.t()
  def wrap(%Driver.Handlers{} = handlers, config) do
    handlers
    |> wrap_call_llm(Runner.handles?(config, :before_llm))
    |> wrap_compact(Runner.handles?(config, :after_compact))
  end

  defp wrap_call_llm(handlers, false), do: handlers

  defp wrap_call_llm(%Driver.Handlers{call_llm: call_llm} = handlers, true) do
    %{
      handlers
      | call_llm: fn config, state, request ->
          :ok = before_llm!(config, state, request)
          call_llm.(config, state, request)
        end
    }
  end

  defp wrap_compact(handlers, false), do: handlers

  defp wrap_compact(%Driver.Handlers{compact: compact} = handlers, true) do
    %{
      handlers
      | compact: fn config, state, info ->
          {compacted, meta} = compact.(config, state, info)
          {after_compact(compacted, meta), meta}
        end
    }
  end

  # Outside the llm_call span and the retry loop (both live in the wrapped handler): a
  # halt is a decision, not a failed call, so it is neither retried nor recorded as an
  # LLM exception.
  defp before_llm!(config, state, request) do
    info = %{final: Map.get(request, :final, false), iterations_left: state.iterations_left}

    case Runner.before_llm(config, info) do
      :cont -> :ok
      {:halt, hook, reason} -> raise HookHaltError, event: :before_llm, hook: hook, reason: reason
    end
  end

  # Only a compaction that reports what it removed (meta.dropped, see
  # Normandy.Behaviours.Compactor) has anything to tell. Injected texts are appended to
  # the compacted memory, before the next LLM call; Turn.Server never stores compacted
  # memory, so they stay out of the session store.
  defp after_compact(config, %{dropped: [_ | _] = dropped} = meta) do
    case Runner.after_compact(config, dropped, Map.delete(meta, :dropped)) do
      [] ->
        config

      texts ->
        memory = Enum.reduce(texts, config.memory, &AgentMemory.add_message(&2, "user", &1))
        %{config | memory: memory}
    end
  end

  defp after_compact(config, _meta), do: config
end
```

`lib/normandy/agents/base_agent.ex`: add `alias Normandy.Hooks.Handlers, as: HookHandlers` to the alias block; in `drive_turn/2` replace `Driver.drive(state, non_streaming_handlers(), config)` with `Driver.drive(state, HookHandlers.wrap(non_streaming_handlers(), config), config)`; in `run_stream_turn/3` replace `Driver.drive(state, streaming_handlers(callback), config)` with `Driver.drive(state, HookHandlers.wrap(streaming_handlers(callback), config), config)`.

`lib/normandy/agents/turn/server.ex`:
- Add `alias Normandy.Hooks.Handlers, as: HookHandlers` to the alias block.
- In `init_data/4` replace `handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),` with:

```elixir
      handlers:
        HookHandlers.wrap(
          Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
          config
        ),
```

- In `interpret/2` replace the `{:call_llm, request}` clause with:

```elixir
      {:call_llm, request} ->
        spawn_task(data, :llm, &call_llm_event(&1, &2, request))
```

  and add next to `spawn_task/3`:

```elixir
  # The worker's event for a :call_llm effect. A before_llm halt (raised by the hook
  # wrapper, Normandy.Hooks.Handlers) fails the turn with {:hook_halted, e} rather than
  # {:task_down, _}.
  defp call_llm_event(handlers, data, request) do
    {:llm_response, handlers.call_llm.(data.config, data.turn_state, request)}
  rescue
    e in Normandy.HookHaltError -> {:llm_error, {:hook_halted, e}}
  end
```

- Moduledoc, `## Options`, the `:handlers` bullet: append "Hook modules' `before_llm` and `after_compact` run around whichever set is used (`Normandy.Hooks.Handlers`)." In `## Errors from run/2`, after the `{:approval_timeout, …}` bullet add: "* `{:hook_halted, %Normandy.HookHaltError{}}` — a `before_llm` hook halted the turn."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/agents test/integration/compaction_turn_test.exs test/behaviours/compactor_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/handlers.ex lib/normandy/agents/base_agent.ex lib/normandy/agents/turn/server.ex test/hooks/llm_compaction_hooks_test.exs test/hooks/server_hooks_test.exs
git commit -m "feat(hooks): before_llm and after_compact wrap any handler set, in both shells"
```

### Task 9: `Turn.Server` session start (after `init/1`) and passivation

**Files:**
- Modify: `lib/normandy/hooks/server_glue.ex` (`session_start?/2`, `session_start/1`)
- Modify: `lib/normandy/agents/turn/server.ex` (`init/1` ~line 201, `unavailable/2` → `unavailable_data/2`, `retry_load/1` ~line 253, `init_data/4` `start_opts`, new `:internal, :session_start` clause, `start_session/1`, `store_session_start/2`, `start_session_if_new/1`, `with_session_start/1`, `describe_reason/1`, the `:passivate` clause ~line 592, moduledoc)
- Test: `test/hooks/server_hooks_test.exs` (add)

**Interfaces:**
- Consumes: `Runner.session_start/1`, `Runner.passivate/1`, `Runner.handles?/2`, `call_handler/3`, `append_to_store/5` + `new_entry_id/2` (Task 4), `UserAppendFailStore` (Task 7 test module).
- Produces:
  - `ServerGlue.session_start?(config, turn_state) :: boolean()` — store had no entries and no turn state, and an entry exports `on_session_start`.
  - `ServerGlue.session_start(config) :: String.t() | nil` — all entries' texts joined by a blank line.
  - A new session's hooks run as `{:next_event, :internal, :session_start}` after `init/1` (and inline in `retry_load/1`); their texts are stored as one user entry. A crash goes `:unavailable` with `{:handler_crashed, :on_session_start, e}`; a store fault with `{:persist_failed, reason}`.
  - `on_passivate` runs in `:idle` before `{:stop, :normal, data}`, through `call_handler/3`.

- [ ] **Step 1: Write the failing tests**

In `test/hooks/server_hooks_test.exs` add `import ExUnit.CaptureLog` under `@moduletag :capture_log`, this module after `UserAppendFailStore`:

```elixir
  # Holds on_session_start until released: start_link returning while it waits proves
  # the hook runs after init/1.
  defmodule HoldsSessionStart do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_session_start(_ctx, opts) do
      send(opts[:notify], :session_start_running)

      receive do
        :release -> :ok
      end
    end
  end
```

and these describes at the end:

```elixir
  describe "on_session_start" do
    test "a new session runs it after init; its texts are stored as one user message" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric", "plan: pro"]}])]

      {:ok, srv} = start(session, hooks, store: {InMemory, store})

      assert_receive {:hook, :p, :on_session_start, [ctx]}
      assert %Normandy.Hooks.Context{session_id: ^session, turn_id: nil} = ctx

      {_state, data} = :sys.get_state(srv)

      assert {:ok, [%{role: "user", content: "profile: metric\n\nplan: pro"}]} =
               InMemory.history(store, session)

      assert ["profile: metric\n\nplan: pro"] =
               data.config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)
    end

    test "start_link returns before the hook runs" do
      sink = TestHooks.sink()
      task = Task.async(fn -> start(sid(), [{HoldsSessionStart, notify: sink}]) end)

      assert {:ok, {:ok, srv}} = Task.yield(task, 2_000)
      assert_receive :session_start_running
      send(srv, :release)
      assert {:idle, _} = :sys.get_state(srv)
      :ok = :gen_statem.stop(srv)
    end

    test "a restarted session that stored its injection does not run it again" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric"]}])]

      {:ok, srv} = start(session, hooks, store: {InMemory, store})
      assert_receive {:hook, :p, :on_session_start, _}
      :ok = :gen_statem.stop(srv)

      {:ok, srv2} = start(session, hooks, store: {InMemory, store})
      {_state, data} = :sys.get_state(srv2)

      refute_received {:hook, :p, :on_session_start, _}

      assert ["profile: metric"] =
               data.config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)
    end

    test "a session whose hooks injected nothing runs them again on its next start" do
      store = InMemory.new()
      session = sid()

      {:ok, srv} = start(session, [probe()], store: {InMemory, store})
      assert_receive {:hook, :p, :on_session_start, _}
      :ok = :gen_statem.stop(srv)

      {:ok, _srv2} = start(session, [probe()], store: {InMemory, store})
      assert_receive {:hook, :p, :on_session_start, _}
    end

    test "a crash under :reraise leaves the server :unavailable, replying the crash" do
      {:ok, srv} = start(sid(), [probe(returns: [on_session_start: {:raise, "crm down"}])])

      assert {:unavailable, _} = :sys.get_state(srv)

      assert {:error, {:handler_crashed, :on_session_start, %RuntimeError{message: "crm down"}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "a crash under :open is logged and the session starts without injection" do
      hooks = [probe(on_error: :open, returns: [on_session_start: {:raise, "crm down"}])]

      log =
        capture_log(fn ->
          {:ok, srv} = start(sid(), hooks)
          assert {:ok, _} = Turn.Server.run(srv, "hello")
        end)

      assert log =~ "on_session_start crashed: RuntimeError: crm down"
    end

    test "a store fault writing the injection leaves the server :unavailable" do
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric"]}])]
      {:ok, srv} = start(sid(), hooks, store: {UserAppendFailStore, UserAppendFailStore.new()})

      assert {:unavailable, _} = :sys.get_state(srv)
      assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "hello")
    end
  end

  describe "on_passivate" do
    test "runs when the idle server passivates; a crash still stops it normally" do
      # Linked by start_link and trapping exits, the test sees the stop reason however
      # soon passivation fires: no monitor to race.
      Process.flag(:trap_exit, true)

      {:ok, srv} =
        start(sid(), [probe(returns: [on_passivate: {:raise, "late"}])], idle_timeout_ms: 50)

      assert_receive {:hook, :p, :on_passivate, [%Normandy.Hooks.Context{event: :on_passivate}]},
                     1_000

      assert_receive {:EXIT, ^srv, :normal}, 1_000
    end
  end
```

`:sys.get_state/1` right after `start_link/1` sees the state after the `:session_start` event: `gen_statem` handles inserted (`next_event`) events before it reads its mailbox, system messages included.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/hooks/server_hooks_test.exs`
Expected: FAIL — no `on_session_start`/`on_passivate` messages; nothing stored; the crash tests see `:idle`.

- [ ] **Step 3: Implement**

Append to `lib/normandy/hooks/server_glue.ex` (inside the module) and add `alias Normandy.Hooks.Runner` to it:

```elixir
  @doc """
  Whether a loaded session is new (its store held no entries and no turn state) and has
  `on_session_start` hooks.
  """
  @spec session_start?(map() | nil, term()) :: boolean()
  def session_start?(nil, _turn_state), do: false

  def session_start?(config, turn_state) do
    turn_state == nil and config.memory.head == nil and
      Runner.handles?(config, :on_session_start)
  end

  @doc """
  Runs `on_session_start`. Returns the texts of all entries joined by a blank line, so
  they are stored as one entry (all or none), or `nil` when nothing was injected.
  """
  @spec session_start(map()) :: String.t() | nil
  def session_start(config) do
    case Runner.session_start(config) do
      [] -> nil
      texts -> Enum.join(texts, "\n\n")
    end
  end
```

`lib/normandy/agents/turn/server.ex`:

In `init/1` replace the success branch `{:ok, config, template, turn_state} -> init_data(opts, config, template, turn_state)` with:

```elixir
      {:ok, config, template, turn_state} ->
        opts |> init_data(config, template, turn_state) |> with_session_start()
```

Replace `unavailable/2` with:

```elixir
  defp unavailable(opts, reason) do
    {data, actions} = unavailable_data(opts, reason)
    {:ok, :unavailable, data, actions}
  end

  defp unavailable_data(opts, reason) do
    session_id = Keyword.fetch!(opts, :session_id)

    Logger.warning(
      "Turn.Server could not start session #{inspect(session_id)} " <>
        "(#{describe_reason(reason)}); retrying"
    )

    data = %Data{
      session_id: session_id,
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000),
      start_opts: opts,
      retry_ms: @retry_initial_ms
    }

    {data, [{{:timeout, :retry}, @retry_initial_ms, :retry}, idle_timeout(data)]}
  end

  # A handler crash was logged where it happened, and its exception can carry hook data:
  # name the handler only. Store reasons are logged as before.
  defp describe_reason({:handler_crashed, name, _exception}), do: "handler #{inspect(name)} crashed"
  defp describe_reason(reason), do: inspect(reason)
```

Replace `retry_load/1` and its comment with:

```elixir
  # Loads the session again. On success the transition is the one init/1 would have
  # made, except that a new session's on_session_start hooks run here, inline: a caller
  # or the retry timer triggered this, and a failure must reach that caller now. The
  # retry timer is cancelled.
  defp retry_load(%Data{start_opts: opts}) do
    store = Keyword.fetch!(opts, :store)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, config, template, turn_state} <- load_session(opts, store, session_id),
         {:ok, :idle, data, actions} = init_data(opts, config, template, turn_state),
         {:ok, data} <- start_session_if_new(data) do
      {:ok, {:next_state, :idle, data, [{{:timeout, :retry}, :cancel} | List.wrap(actions)]}}
    end
  end
```

In `init_data/4`'s `%Data{}` add `start_opts: opts,` (after `idle_timeout_ms: timeouts.idle_timeout_ms`, with a comma before it), so a session-start failure after init can go `:unavailable`.

Add after `init_data/4`:

```elixir
  # A new session's on_session_start hooks run as the first event after init/1 returns,
  # so a slow hook does not block the supervisor starting this server and a crashing one
  # sends it :unavailable instead of failing the start.
  defp with_session_start({:ok, :idle, data, _actions} = init) do
    if ServerGlue.session_start?(data.config, data.turn_state),
      do: {:ok, :idle, data, [{:next_event, :internal, :session_start}]},
      else: init
  end

  defp start_session_if_new(data) do
    if ServerGlue.session_start?(data.config, data.turn_state),
      do: start_session(data),
      else: {:ok, data}
  end

  # Runs on_session_start and stores what it injects as one user message, so the store
  # holds all of it or none: a retry finds the session new again only while nothing was
  # stored.
  defp start_session(data) do
    case call_handler(data, :on_session_start, fn -> ServerGlue.session_start(data.config) end) do
      {:ok, nil} -> {:ok, data}
      {:ok, text} -> store_session_start(data, text)
      {:crashed, reason} -> {:error, reason}
    end
  end

  defp store_session_start(data, text) do
    config = %{data.config | memory: AgentMemory.add_message(data.config.memory, "user", text)}

    case append_to_store(data, config, "user", text, new_entry_id(data.config, config)) do
      :ok -> {:ok, %{data | config: config}}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end
```

Add, next to the `handle_event(:internal, :resume, :idle, data)` clause:

```elixir
  # The first event of a new session (with_session_start/1). A crash or a store fault
  # sends the server :unavailable, which retries the load and the hook on its backoff
  # and on each run/2, replying the reason meanwhile.
  def handle_event(:internal, :session_start, :idle, data) do
    case start_session(data) do
      {:ok, data} ->
        {:keep_state, data, idle_timeout(data)}

      {:error, reason} ->
        {data, actions} = unavailable_data(data.start_opts, reason)
        {:next_state, :unavailable, data, actions}
    end
  end
```

Replace the `:passivate` clause and its comment with:

```elixir
  # Idle long enough → passivate. Final turn state is already persisted; on_passivate
  # hooks run (logged-only, through call_handler/3), then the server stops. An
  # :unavailable server nobody calls stops too, with no hooks (it loaded no config); the
  # next caller starts it again.
  def handle_event(:state_timeout, :passivate, state, data)
      when state in [:idle, :unavailable] do
    if state == :idle and Runner.hooks?(data.config),
      do: call_handler(data, :on_passivate, fn -> Runner.passivate(data.config) end)

    {:stop, :normal, data}
  end
```

Moduledoc: after `## Store unavailable` add:

```markdown
  ## Session start

  A session whose store holds no entries and no turn state is new. Its
  `on_session_start` hooks (`Normandy.Behaviours.Hooks`) run as the first event after
  `init/1` returns, so the supervisor starting the server is not blocked by them. What
  they inject is stored as one user message. A hook crash (`{:handler_crashed,
  :on_session_start, e}`) or a store fault writing that message (`{:persist_failed,
  reason}`) sends the server `:unavailable`, which retries both like a load. A session
  whose hooks injected nothing is still new on its next start, and runs them again.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/hooks test/agents/turn`
Expected: PASS — including the `store unavailable at start` tests in `server_test.exs` (server_test.exs:2387), unchanged.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/server_glue.ex lib/normandy/agents/turn/server.ex test/hooks/server_hooks_test.exs
git commit -m "feat(hooks): Turn.Server session start after init and passivation hooks"
```

### Task 10: `Turn.Server` results the core or the server builds pass `after_tool` exactly once

**Files:**
- Modify: `lib/normandy/hooks/server_glue.ex` (`after_tool/3`, `after_tool_built/3`)
- Modify: `lib/normandy/agents/turn/server.ex` (approval cast ~line 537, expiry ~line 564, new `interpret_built/3`, `close_batch/2` ~line 836, new `interrupted_results/2`)
- Test: `test/agents/turn/server_test.exs` (new `describe "after_tool on results the core or the server builds"` at the end)

**Interfaces:**
- Consumes: `Runner.after_tool/3`, `Runner.handles?/2`, `Dispatch.to_tool_call/1`, `call_handler/3`, `fail/2`.
- Produces:
  - `ServerGlue.after_tool(config, call_or_raw_map, result) :: %ToolResult{}`.
  - `ServerGlue.after_tool_built(config, calls, {state, effects}) :: {state, effects}` — applies `after_tool` to the results the core built for `calls` in one `Turn.step/2` result: its `{:append_message, "tool", r}` effects and `state.held_results`. No server state outlives the callback, so nothing can leak or desync.
  - The function `after_hooks` do not run on these results (unchanged behaviour).
- Why no core change: each built result is created in exactly one step, and that step's caller (the approval cast or the expiry timeout) is the one place it can be rewritten before it is appended or held. A core "synthesized" marker would need wiring into Driver, Inline and Server (three interpreters) for no added guarantee.

- [ ] **Step 1: Write the failing tests**

At the end of `test/agents/turn/server_test.exs` (before the final `end`), add:

```elixir
  describe "after_tool on results the core or the server builds" do
    # Marks a result and reports its call id; outputs here are maps (interrupted results).
    defmodule MarkAudited do
      use Normandy.Behaviours.Hooks

      @impl true
      def after_tool(_call, result, _ctx, opts) do
        send(opts[:notify], {:after_tool, result.tool_call_id})
        {:cont, %{result | output: Map.put(result.output, :audited, true)}}
      end
    end

    defp approval_config(after_hooks) do
      %{
        config_with_notify(self())
        | behaviours: %Normandy.Behaviours.Config{
            policy:
              {Normandy.Behaviours.PolicyEngine.Ruleset,
               rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
               default_action: :allow},
            hooks: [{Normandy.Test.Hooks.Probe, notify: Normandy.Test.Hooks.sink(), tag: :audit}],
            after_hooks: after_hooks
          }
      }
    end

    # The first LLM call asks for `calls`; every later one answers.
    defp parking_llm(calls) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fn _c, _s, _r ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0,
          do: %Resp{content: "", tool_calls: calls},
          else: %Resp{content: "done", tool_calls: nil}
      end
    end

    defp start_parking(sid, config, calls, server_opts \\ []) do
      test_pid = self()

      Turn.Server.start_link(
        [
          session_id: sid,
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: parking_llm(calls)},
          subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
        ] ++ server_opts
      )
    end

    defp billing(id), do: %ToolCall{id: id, name: "billing", input: %{}}

    defp run_in_background(srv) do
      parent = self()
      spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)
    end

    defp reporting_after_hook do
      test_pid = self()

      fn _config, call, result ->
        send(test_pid, {:fun_after, call.id})
        result
      end
    end

    test "a rejected call's result passes after_tool once; the function after-hooks never see it" do
      {:ok, srv} =
        start_parking("s-hook-reject", approval_config([reporting_after_hook()]), [billing("pk1")])

      run_in_background(srv)
      assert_receive {:event, :awaiting_approval, _}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :reject})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_receive {:hook, :audit, :after_tool,
                      [%ToolCall{id: "pk1"}, %ToolResult{tool_call_id: "pk1", is_error: true}, _]}

      refute_received {:hook, :audit, :after_tool, _}
      refute_received {:fun_after, "pk1"}
    end

    test "expired results pass after_tool once before an on_approval_timeout: :fail turn fails" do
      # run/2 blocks until the 30 ms window expires: the timeout is a lower bound, no race.
      {:ok, srv} =
        start_parking("s-hook-expire", approval_config([reporting_after_hook()]), [billing("pk1")],
          approval_timeout_ms: 30,
          on_approval_timeout: :fail
        )

      assert {:error, {:approval_timeout, ["pk1"]}} = Turn.Server.run(srv, "go")

      assert_receive {:hook, :audit, :after_tool,
                      [%ToolCall{id: "pk1"}, %ToolResult{tool_call_id: "pk1", output: %{expired: true}}, _]}

      refute_received {:hook, :audit, :after_tool, _}
      refute_received {:fun_after, "pk1"}
    end

    test "a mixed decision: the held rejection and the approved result each pass once" do
      {:ok, srv} =
        start_parking("s-hook-mixed", approval_config([]), [billing("pk1"), billing("pk2")])

      run_in_background(srv)
      assert_receive {:event, :awaiting_approval, _}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve, "pk2" => :reject})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_receive {:hook, :audit, :after_tool,
                      [%ToolCall{id: "pk2"}, %ToolResult{tool_call_id: "pk2", is_error: true}, _]}

      assert_receive {:hook, :audit, :after_tool,
                      [%ToolCall{id: "pk1"}, %ToolResult{tool_call_id: "pk1"}, _]}

      refute_received {:hook, :audit, :after_tool, _}
    end

    test "an approved call's result passes after_tool exactly once" do
      {:ok, srv} = start_parking("s-hook-approve", approval_config([]), [billing("pk1")])

      run_in_background(srv)
      assert_receive {:event, :awaiting_approval, _}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_receive {:hook, :audit, :after_tool, [%ToolCall{id: "pk1"}, _, _]}
      refute_received {:hook, :audit, :after_tool, _}
    end

    test "an interrupted result passes after_tool once and is stored as rewritten" do
      sink = Normandy.Test.Hooks.sink()
      overrides = %{behaviours: %Normandy.Behaviours.Config{hooks: [{MarkAudited, notify: sink}]}}
      {srv, store} = start_dangling_server("s-hook-dangling", overrides)

      capture_log(fn -> assert {:ok, _} = Turn.Server.run(srv, "next") end)

      assert_received {:after_tool, "t1"}
      refute_received {:after_tool, _}

      {:ok, entries} = InMemory.history(store, "s-hook-dangling")

      assert Enum.any?(entries, fn e ->
               match?(
                 %ToolResult{tool_call_id: "t1", output: %{audited: true, interrupted: true}},
                 e.content
               )
             end)
    end

    test "a rejected input reports no interrupted result; the accepted one after it, once" do
      sink = Normandy.Test.Hooks.sink()

      overrides = %{
        input_schema: %RequiredQueryInput{},
        behaviours: %Normandy.Behaviours.Config{hooks: [{MarkAudited, notify: sink}]}
      }

      {srv, _store} = start_dangling_server("s-hook-dangling-reject", overrides)

      assert {:error, {:rejected, _}} = Turn.Server.run(srv, %{})
      refute_received {:after_tool, _}

      capture_log(fn -> assert {:ok, _} = Turn.Server.run(srv, %{"query" => "q"}) end)
      assert_received {:after_tool, "t1"}
      refute_received {:after_tool, _}
    end
  end
```

The interrupted-result hooks run in the server process before it replies, so `assert_received` after the synchronous `run/2` is ordered by a single sender; the approval tests cross processes (the server, a tools task) and use `assert_receive`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — the reject, expire, mixed (pk2) and interrupted tests receive no `after_tool` message. The approved test passes already (approved calls run through `Dispatch.execute/4`); it guards against a second run.

- [ ] **Step 3: Implement**

Append to `lib/normandy/hooks/server_glue.ex` (inside the module) and add `alias Normandy.Agents.Dispatch`, `alias Normandy.Agents.Turn`, `alias Normandy.Components.ToolCall` and `alias Normandy.Components.ToolResult` to it:

```elixir
  @doc """
  Runs `after_tool` on a result the server built (an interrupted result). `call` may be a
  raw tool-call map; the result answers its id.
  """
  @spec after_tool(map(), ToolCall.t() | map(), ToolResult.t()) :: ToolResult.t()
  def after_tool(config, call, %ToolResult{} = result) do
    if Runner.hooks?(config) do
      call = Dispatch.to_tool_call(call)
      %{Runner.after_tool(config, call, result) | tool_call_id: call.id}
    else
      result
    end
  end

  @doc """
  Runs `after_tool` on the results the core built for `calls` (approval rejected or
  expired) in one `Turn.step/2` result: in its append effects and in the state's held
  results (kept while approved calls run). Other results are left alone: they passed
  `after_tool` in `Dispatch`.
  """
  @spec after_tool_built(map(), [ToolCall.t()], {Turn.State.t(), list()}) ::
          {Turn.State.t(), list()}
  def after_tool_built(config, calls, {state, effects} = step) do
    if calls != [] and Runner.handles?(config, :after_tool) do
      by_id = Map.new(calls, &{&1.id, &1})
      answer = &answer_built(config, by_id, &1)

      {%{state | held_results: Enum.map(state.held_results, answer)},
       Enum.map(effects, fn
         {:append_message, "tool", result} -> {:append_message, "tool", answer.(result)}
         effect -> effect
       end)}
    else
      step
    end
  end

  defp answer_built(config, by_id, %ToolResult{tool_call_id: id} = result)
       when is_map_key(by_id, id),
       do: %{Runner.after_tool(config, Map.fetch!(by_id, id), result) | tool_call_id: id}

  defp answer_built(_config, _by_id, result), do: result
```

`lib/normandy/agents/turn/server.ex`:

In the approval cast clause (`handle_event(:cast, {:approval, decisions, approver_ctx}, :awaiting_approval, data)`), replace the last two lines

```elixir
    {state, effects} = Turn.step(data.turn_state, {:approval, decisions})
    interpret(effects, %{data | turn_state: state})
```

with

```elixir
    interpret_built(data, rejected, Turn.step(data.turn_state, {:approval, decisions}))
```

In the `:approval_expiry` clause, replace

```elixir
    {state, effects} =
      Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})

    interpret(effects, %{data | turn_state: state})
```

with

```elixir
    step = Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})
    interpret_built(data, parked, step)
```

Add next to `interpret/2`:

```elixir
  # The core answers rejected and expired calls itself. Their results pass after_tool
  # here, in the callback whose step built them (in the append effects it returned, or
  # in the held results it keeps while approved calls run), so each passes exactly once
  # and no state outlives the callback. A crashing hook fails the turn like a crashing
  # handler; the next turn repairs the batch's unanswered calls.
  defp interpret_built(data, calls, {state, effects}) do
    case call_handler(data, :after_tool, fn ->
           ServerGlue.after_tool_built(data.config, calls, {state, effects})
         end) do
      {:ok, {state, effects}} -> interpret(effects, %{data | turn_state: state})
      {:crashed, reason} -> fail(%{data | turn_state: state}, reason)
    end
  end
```

Replace `close_batch/2`'s second clause and the comment above `close_batch/2` with:

```elixir
  # A failed or killed turn can leave the last assistant tool_use without results;
  # the Claude API rejects the next request unless every tool_use is answered. Fold
  # an interrupted result per missing call into memory (no turn exists yet, so a
  # crashing append or hook replies instead of going through fail/2). Each result
  # passes after_tool first, like any result the model sees; callers admit the turn's
  # input before this, so a rejected input reports none. Returns one
  # {call, result, config_after_this_result} per missing call.
  defp close_batch(_data, []), do: {:ok, []}

  defp close_batch(data, missing) do
    with {:ok, results} <-
           call_handler(data, :after_tool, fn -> interrupted_results(data.config, missing) end) do
      call_handler(data, :append, fn ->
        {repairs, _config} =
          missing
          |> Enum.zip(results)
          |> Enum.map_reduce(data.config, fn {call, result}, config ->
            folded = data.handlers.append.(config, "tool", result)
            {{call, result, folded}, folded}
          end)

        repairs
      end)
    end
  end

  defp interrupted_results(config, missing),
    do: Enum.map(missing, &ServerGlue.after_tool(config, &1, interrupted_result(&1)))
```

Moduledoc, `## Interrupted tool calls`: after "…and logs a warning." add "Each interrupted result passes the hook modules' `after_tool` once (`Normandy.Behaviours.Hooks`); so do the results the core builds for approval rejections and expiries."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn test/hooks`
Expected: PASS.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add lib/normandy/hooks/server_glue.ex lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(hooks): approval-rejected, expired and interrupted results pass after_tool exactly once"
```

### Task 11: DSL `hooks` declaration

**Files:**
- Modify: `lib/normandy/dsl/agent.ex` (`__using__/1`, new `hooks/1` macro after `guardrails/3`, `@agent_compile_config`, `config/0`, `build_config/2`, new `put_declared_hooks/2` next to `memory_tool!/3`)
- Test: `test/dsl/agent_hooks_test.exs`

**Interfaces:**
- Consumes: `Hooks.validate_entries!(entries, load: false)` (Task 1); `BaseAgent.init/1` full validation (Task 5).
- Produces: `hooks [{Mod, opts}, …]` inside `agent do … end` (once per agent); declared entries run before any `hooks` in a `behaviours:` passed to `new/1`; `config().hooks`.

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

  test "declared hooks reach the agent's behaviours and config/0" do
    {:ok, agent} = HookedAgent.new(client: client())
    assert agent.behaviours.hooks == [{Probe, tag: :dsl, on_error: :open}]
    assert HookedAgent.config().hooks == [{Probe, tag: :dsl, on_error: :open}]
  end

  test "declared hooks run before hooks given at runtime" do
    {:ok, agent} =
      HookedAgent.new(client: client(), behaviours: %Config{hooks: [{TurnEndOnly, []}]})

    assert agent.behaviours.hooks == [{Probe, tag: :dsl, on_error: :open}, {TurnEndOnly, []}]
  end

  test "an agent without hooks keeps behaviours nil, as before" do
    {:ok, agent} = PlainAgent.new(client: client())
    assert agent.behaviours == nil
    assert PlainAgent.config().hooks == []
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

  test "a second hooks declaration fails at compile time" do
    assert_raise ArgumentError, ~r/hooks\/1 is declared twice/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.Twice do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([{Normandy.Test.Hooks.Probe, []}])
          hooks([{Normandy.Test.Hooks.TurnEndOnly, []}])
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

(`PlainAgent.new/1` passes no `:behaviours`, and `BaseAgent.init/1` keeps `Map.get(config, :behaviours, nil)`, base_agent.ex:169, so `nil` is today's value.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/dsl/agent_hooks_test.exs`
Expected: FAIL — `undefined function hooks/1` (CompileError) for `HookedAgent`.

- [ ] **Step 3: Implement**

In `lib/normandy/dsl/agent.ex`:

`__using__/1` — after `Module.register_attribute(__MODULE__, :agent_tools, accumulate: true)` add:

```elixir
      Module.register_attribute(__MODULE__, :agent_hooks, accumulate: false)
```

The macro, after `guardrails/3`:

```elixir
  @doc """
  Declares lifecycle hooks (`Normandy.Behaviours.Hooks`): an ordered list of
  `{module, opts}` entries, once per agent. They run before any `hooks` in a
  `behaviours:` given to `new/1`. A literal list is checked at compile time (shape,
  `:on_error`, plain-data opts); modules and their `validate_opts!/1` are checked when
  `new/1` builds the agent.

      hooks [{MyApp.Hooks.Redact, []}, {MyApp.Hooks.Audit, on_error: :open}]
  """
  defmacro hooks(entries) do
    expanded = Macro.prewalk(entries, &Macro.expand(&1, __CALLER__))

    if Macro.quoted_literal?(expanded),
      do: Normandy.Behaviours.Hooks.validate_entries!(expanded, load: false)

    quote do
      if Module.get_attribute(__MODULE__, :agent_hooks) != nil do
        raise ArgumentError,
              "hooks/1 is declared twice in #{inspect(__MODULE__)}; declare one list"
      end

      Module.put_attribute(__MODULE__, :agent_hooks, unquote(entries))
    end
  end
```

`@agent_compile_config` in `__before_compile__/1`: add `hooks: Module.get_attribute(__MODULE__, :agent_hooks) || [],` (after `memory: …`).

`config/0`: add `hooks: @agent_compile_config.hooks,` after `tools: @agent_compile_config.tools,`.

`build_config/2`: right after the line `config = Map.merge(base_config, Map.new(overrides))` add:

```elixir
        config = Normandy.DSL.Agent.put_declared_hooks(config, @agent_compile_config.hooks)
```

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

Moduledoc of `Normandy.DSL.Agent`: in its list of declarations add "`hooks` - lifecycle hook modules (`Normandy.Behaviours.Hooks`), `[{Mod, opts}]`".

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

### Task 12: Guide (with compiled examples), migration notes, project docs

**Files:**
- Create: `docs/guides/hooks.md`
- Create: `test/hooks/guide_examples_test.exs`
- Modify: `mix.exs` (docs `extras`: add `"docs/guides/hooks.md"` after `"docs/guides/agent-memory.md"`, mix.exs:47)
- Modify: `MIGRATING-2.0.md` (new section 16 after section 15, before `## New, non-breaking`)
- Modify: `CLAUDE.md` (Architecture: "Lifecycle Hooks" subsection after "Long-term Memory & Tool Context")
- Modify: `lib/normandy/agents/turn/inline.ex` (moduledoc: one paragraph)

**Interfaces:**
- Consumes: everything above. The spec is not edited by this task: it already describes the final design.

- [ ] **Step 1: Write the failing test**

`test/hooks/guide_examples_test.exs`:

```elixir
defmodule Normandy.Hooks.GuideExamplesTest do
  use ExUnit.Case, async: true

  @guide Path.expand("../../docs/guides/hooks.md", __DIR__)

  # Every ```elixir block in the guide that defines a MyApp.Hooks.* module.
  defp example_modules do
    ~r/```elixir\n(defmodule MyApp\.Hooks\..*?)```/s
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> List.flatten()
  end

  test "the guide's example hook modules compile without warnings" do
    sources = example_modules()
    assert length(sources) == 4

    for source <- sources do
      {_modules, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(source) end)
      assert diagnostics == [], "example did not compile cleanly: #{inspect(diagnostics)}"
    end
  end

  test "the guide's event table names every event" do
    guide = File.read!(@guide)
    for {event, _arity} <- Normandy.Behaviours.Hooks.events(), do: assert(guide =~ "`#{event}`")
  end
end
```

Run: `mix test test/hooks/guide_examples_test.exs`
Expected: FAIL — `File.Error` (the guide does not exist).

- [ ] **Step 2: Write `docs/guides/hooks.md`**

Write this file exactly (headings, tables and code verbatim; the four `MyApp.Hooks.*` modules are compiled by the test above):

````markdown
# Lifecycle hooks

## What hooks are for

A hook is a module an agent lists in `Normandy.Behaviours.Config` `:hooks`. Normandy calls
it at eight points of an agent's life. Use a hook to:

- **guard or rewrite** — redact a prompt, block an off-topic request, stop an LLM call
  over budget, rewrite a tool call or its result;
- **inject context** — add a user profile when a session starts, or a reminder after
  compaction;
- **save what compaction drops** — copy dropped messages to long-term memory;
- **audit** — record tool results and turn outcomes.

To only observe, attach to telemetry (`Normandy.Telemetry`) instead: a hook runs inline,
in the turn, with no timeout. A slow hook stalls its turn (in `Turn.Server`, its session):
hand slow side effects to a process of your own.

## Declaring hooks

```elixir
alias Normandy.Behaviours.Config

BaseAgent.init(%{
  client: client,
  model: "claude-sonnet-4-5",
  behaviours: %Config{hooks: [{MyApp.Hooks.Redact, []}, {MyApp.Hooks.Audit, on_error: :open}]}
})
```

or, in the DSL, once per agent:

```elixir
agent do
  model("claude-sonnet-4-5")
  hooks([{MyApp.Hooks.Redact, []}, {MyApp.Hooks.Audit, on_error: :open}])
end
```

Entries run in list order. A module implements any subset of the callbacks; `use
Normandy.Behaviours.Hooks` checks at compile time that a function named like a callback
has its arity, and warns about a near-miss such as `on_promt`, which would never run.
`BaseAgent.init/1` raises `ArgumentError` for a malformed entry, a module that is not
loaded, an unknown `:on_error`, opts that are not plain data, or opts the module's
`validate_opts!/1` rejects.

### Module hooks and function hooks

| | Hook modules (`hooks`) | Function hooks (`before_hooks`, `after_hooks`) |
|---|---|---|
| Events | all eight | tool calls only |
| Signature | `before_tool(call, ctx, opts)`, `after_tool(call, result, ctx, opts)` | `fn config, call -> … end`, `fn config, call, result -> result end` |
| Persisted | yes, in the session's config template | no, node-local (template supplement) |
| `after_tool` sees | every tool result the model sees | results of tools that ran |
| Order | first | after the modules; a module halt skips them |

Use a function hook only for a closure over a runtime value on one node.

## Events

| Event | Runs | Returns |
|---|---|---|
| `on_session_start(ctx, opts)` | `Turn.Server`, once per start of a session whose store is empty | `{:inject, [text]}` or anything (ignored) |
| `on_prompt(input, ctx, opts)` | before a turn, after input validation, before input guardrails | `{:cont, input}` or `{:halt, reason}` |
| `before_llm(info, ctx, opts)` | before each LLM call; `info` is `%{final: boolean, iterations_left: n}` | `:cont` or `{:halt, reason}` |
| `before_tool(call, ctx, opts)` | before each tool call | `{:cont, call}`, `{:halt, reason}` or `{:halt, %ToolResult{}}` |
| `after_tool(call, result, ctx, opts)` | on every tool result the model will see, once | `{:cont, result}` |
| `after_compact(dropped, meta, ctx, opts)` | after a compaction that removed messages | `{:inject, [text]}` or anything (ignored) |
| `on_turn_end(outcome, ctx, opts)` | after a turn's outcome is delivered | anything (ignored) |
| `on_passivate(ctx, opts)` | `Turn.Server`, before an idle session stops | anything (ignored) |

`on_prompt` receives the validated input: the input schema's struct for a map or struct
input, or the input itself when it is not a map. A rewrite is validated again: a plain map
is cast and checked against the schema, while a value that is already the schema's struct
is trusted, as a caller's would be.

`ctx` is a `%Normandy.Hooks.Context{}`: `event`, `agent_name`, `model`, `session_id`,
`turn_id` (`nil` before a turn starts and in session events) and `values` (the agent's
`tool_context`). It carries no config or credentials.

## Outcomes and halts

| Halt | `BaseAgent` | `Turn.Server.run/2` | `on_turn_end` sees |
|---|---|---|---|
| `on_prompt` | raises `Normandy.HookHaltError` | `{:error, {:rejected, %HookHaltError{}}}` | `{:rejected, %HookHaltError{}}` |
| `before_llm` | raises `Normandy.HookHaltError` | `{:error, {:hook_halted, %HookHaltError{}}}` | `{:error, {:hook_halted, %HookHaltError{}}}` |

`on_turn_end` sees `{:ok, response}` for a completed turn; `{:rejected, exception}` for a
schema, input-guardrail or output-guardrail rejection; `{:error, reason}` otherwise. A
`before_tool` halt is not a turn halt: its result answers the call.

## Errors (`:on_error`)

| Event | `:reraise` (default) | `:open` | `:closed` |
|---|---|---|---|
| `on_prompt`, `before_llm`, `before_tool` | the crash propagates | logged; the value passes on | halts with "hook X crashed: …" |
| `after_tool` | the crash propagates | logged; the result passes on | the result becomes an error result |
| `after_compact`, `on_session_start` | the crash propagates | logged; nothing injected | the crash propagates |
| `on_turn_end`, `on_passivate` | logged | logged | logged |

A return value the library consumes (the `Returns` column above, except "ignored") that is
outside its contract raises `ArgumentError`, whatever `:on_error` says. In `Turn.Server` no
hook outcome stops the session: a crash in `on_prompt` replies `{:error,
{:handler_crashed, :admit, e}}`; in `after_tool` on a result the server builds, it fails the
turn with `{:handler_crashed, :after_tool, e}`; in `on_session_start`, the session waits
`:unavailable` and retries.

## Injection

Injected texts reach the model as user messages, and input guardrails do not run on them.
Label them, and vet any text from an untrusted source before injecting it:

```elixir
{:inject, [~s(<context source="profile">prefers metric units</context>)]}
```

Session-start texts are stored as one message and survive a restart. `after_compact` texts
live in memory only, like the compacted memory itself.

## Compaction and deduplication

`after_compact` receives `dropped`, the `%Normandy.Components.AgentMemory.Entry{}` structs
the compactor removed (`id`, `turn_id`, `role`, original `content`), oldest first. After a
`Turn.Server` session passivates and starts again, it rebuilds the uncompacted
conversation, compaction runs again, and `after_compact` reports the same messages again,
under the same entry ids. Deduplicate on `entry.id`.

## Reaching runtime resources

Hook opts are saved in the session's config template, in plaintext, and must mean the same
on another node after a restart: no pids, functions, references or ports, and no secrets.

- Name processes: a registered name or a `{:via, …}` tuple, not a pid.
- Name modules: `repo: MyApp.Repo`, `store: {MemoryStore.ETS, :my_table}`.
- Read secrets at call time, from application env or your credential provider.
- Derive per-session resources from `ctx.session_id` or `ctx.values`.

A session keeps the hook list it was created with; a hook added to an agent later does not
reach existing sessions. Deploy a hook module to every node before any session uses it: a
node without it keeps such a session `:unavailable` until it is deployed.

## Examples

### Redact a prompt

```elixir
defmodule MyApp.Hooks.Redact do
  use Normandy.Behaviours.Hooks

  alias Normandy.Agents.BaseAgentInputSchema

  @impl true
  def on_prompt(%BaseAgentInputSchema{chat_message: text} = input, _ctx, _opts)
      when is_binary(text),
      do: {:cont, %{input | chat_message: redact(text)}}

  def on_prompt(text, _ctx, _opts) when is_binary(text), do: {:cont, redact(text)}

  # Fail closed: an input this hook cannot read is not let through unredacted.
  def on_prompt(_input, _ctx, _opts), do: {:halt, "unsupported input shape"}

  defp redact(text), do: Regex.replace(~r/\b\d{3}-\d{2}-\d{4}\b/, text, "[ssn]")
end
```

### Inject a profile when a session starts

```elixir
defmodule MyApp.Hooks.Profile do
  use Normandy.Behaviours.Hooks

  @impl true
  def on_session_start(ctx, _opts) do
    case ctx.values[:user_id] do
      nil -> :ok
      user_id -> {:inject, [~s(<context source="profile">) <> profile(user_id) <> "</context>"]}
    end
  end

  defp profile(user_id), do: "user #{user_id} prefers metric units"
end
```

### Save what compaction drops

```elixir
defmodule MyApp.Hooks.SaveDropped do
  use Normandy.Behaviours.Hooks

  # opts: store: {MemoryStore module, handle}, the handle a registered name or table.
  @impl true
  def after_compact(dropped, _meta, ctx, opts) do
    {store, handle} = Keyword.fetch!(opts, :store)
    namespace = Map.fetch!(ctx.values, :memory_namespace)

    Enum.each(dropped, fn entry ->
      # :new conflicts when the path exists, so an entry reported again is not
      # written twice.
      case store.put(handle, namespace, "/memories/compacted/#{entry.id}.md", render(entry), :new) do
        {:ok, _version} -> :ok
        {:error, :conflict} -> :ok
        {:error, reason} -> raise "could not save entry #{entry.id}: #{inspect(reason)}"
      end
    end)
  end

  defp render(%{role: role, content: content}) when is_binary(content), do: "#{role}: #{content}"
  defp render(%{role: role, content: content}), do: "#{role}: #{inspect(content)}"
end
```

### Audit tool results and turns

```elixir
defmodule MyApp.Hooks.Audit do
  use Normandy.Behaviours.Hooks

  require Logger

  @impl true
  def after_tool(call, result, ctx, _opts) do
    Logger.info("tool #{call.name} answered (error: #{result.is_error}) in #{ctx.session_id}")
    {:cont, result}
  end

  @impl true
  def on_turn_end(outcome, ctx, _opts) do
    Logger.info("turn #{ctx.turn_id} ended: #{elem(outcome, 0)}")
  end
end
```

Declare it with `on_error: :open` so a logging failure never fails a tool call.

## Testing a hook

Call the callback directly with a context:

```elixir
defmodule MyAppTest.RedactHookTest do
  use ExUnit.Case, async: true

  alias Normandy.Hooks.{Context, Runner}

  test "redacts an SSN" do
    ctx = %Context{event: :on_prompt}
    assert {:cont, "id [ssn]"} = MyApp.Hooks.Redact.on_prompt("id 123-45-6789", ctx, [])
  end

  test "under the library's rules" do
    config = %{name: "test", behaviours: %{hooks: [{MyApp.Hooks.Redact, []}]}}
    assert Runner.prompt(config, 42) == {:halt, MyApp.Hooks.Redact, "unsupported input shape"}
  end
end
```

`Normandy.Hooks.Runner` applies ordering, `:on_error` and the return contracts, as an
agent would. To receive messages from a hook in a test, register the test process under a
name and pass the name in opts (a pid is refused).

## What hooks do not cover

- `Turn.Inline` has no hook site of its own; tool hooks run there when its `:dispatch`
  calls `Dispatch.dispatch_one/3` with an agent pipeline.
- There is no session-end event: passivation runs `on_passivate`, but a supervisor
  shutdown, `:kill` or node loss runs no callback.
- LLM requests and responses cannot be rewritten.
- `BaseAgent.admit/2,3` runs no hooks.
- Hooks have no timeout.

## Telemetry

Each hook call is a `[:normandy, :hook, :start | :stop | :exception]` span with `event`,
`hook`, `agent_name`, `session_id`, `turn_id` (tool events add `tool_call_id` and `tool`);
`:stop` adds `result`: `:cont`, `:rewrite`, `:halt`, `:inject`, `:ok` or `:rescued`.
````

- [ ] **Step 3: Migration notes, CLAUDE.md, Inline moduledoc, mix.exs**

`MIGRATING-2.0.md`, after section 15 and before `## New, non-breaking`:

```markdown
## 16. Lifecycle hooks

- New: `Normandy.Behaviours.Hooks` modules on `Behaviours.Config.hooks` (see
  `docs/guides/hooks.md`). Nothing changes for an agent that sets none. Config templates
  gain `behaviours_refs.hooks`; templates saved earlier rebuild with `[]`.
- New replies from `Turn.Server.run/2`: `{:error, {:rejected, %Normandy.HookHaltError{}}}`
  (an `on_prompt` hook halted the input), `{:error, {:hook_halted,
  %Normandy.HookHaltError{}}}` (a `before_llm` hook halted the turn),
  `{:error, {:handler_crashed, :admit | :after_tool | :on_session_start, e}}` and
  `{:error, {:invalid_hooks, message}}` (a hook module missing on this node). `BaseAgent`
  raises `Normandy.HookHaltError` for both halts.
- **Behaviour change:** in `Turn.Server`, an admission that raises something other than a
  rejection (an input guardrail crashing, for example) now replies `{:error,
  {:handler_crashed, :admit, e}}` instead of crashing the session.
- **Behaviour change:** `Turn.Server` now admits a turn's input before it repairs an
  interrupted tool batch; a rejected input repairs nothing (it stored nothing before too).
- **Behaviour change:** compaction keeps each kept message's entry id, and `Turn.Server`
  stores each message under the id its memory gave it, on every session store.
  `SessionStore.Redis.history/2` now returns the id an entry was written with (the stream id
  for entries written without one), and `fork/3` accepts either. Code that relied on
  compaction minting new ids, or on store-assigned ids, must not.
- `Normandy.Behaviours.Compactor` meta may carry `:dropped` (the removed entries);
  `Compactor.WindowManager` fills it. A custom compactor fills it to trigger
  `after_compact` hooks. `AgentMemory.add_message/4` accepts `:id`.
- `Dispatch.Pipeline` gains `after_tool` (default `nil`). The function `after_hooks` are
  unchanged: they still see only results of tools that ran.
```

`CLAUDE.md`, after the "Long-term Memory & Tool Context" subsection:

```markdown
### Lifecycle Hooks

- **`Normandy.Behaviours.Hooks`** - Ordered `{module, opts}` entries on `Behaviours.Config.hooks`
  (persisted in the config template; opts plain data, checked at `BaseAgent.init/1`); optional
  callbacks `on_session_start`, `on_passivate`, `on_prompt`, `before_llm`, `before_tool`,
  `after_tool`, `after_compact`, `on_turn_end`; `use` checks callback names and arities
- **`Normandy.Hooks.Runner`** - The only caller of hook modules: order, rewrites, halts,
  `:on_error`, return contracts, the `[:normandy, :hook, *]` span; call sites in
  `Normandy.Hooks.BaseAgentGlue`, `Normandy.Hooks.ServerGlue`, `Normandy.Hooks.Handlers`
  (wraps any handler set with `before_llm`/`after_compact`) and `Config.to_pipeline/1`
  (tool hooks; `after_tool` sees every tool result once). No hook outcome terminates
  `Turn.Server`; no hook timeouts
```

`lib/normandy/agents/turn/inline.ex` moduledoc: after the paragraph that ends "…approval shells come in later phases." add:

```markdown
  Lifecycle hooks (`Normandy.Behaviours.Hooks`) have no site here: this shell calls only
  its `deps`. Tool hooks run when `:dispatch` dispatches through an agent pipeline
  (`Dispatch.dispatch_one/3` with `BaseAgent.base_agent_pipeline/1`); no other event runs.
```

`mix.exs` docs `extras`: change `"docs/guides/agent-memory.md"` to `"docs/guides/agent-memory.md",` and add `"docs/guides/hooks.md"` on the next line.

- [ ] **Step 4: Verify the docs build, the examples and the suite**

Run: `mix test test/hooks/guide_examples_test.exs`
Expected: PASS.

Run: `mix docs > "${TMPDIR:-/tmp}/normandy-docs.log" 2>&1; echo "mix docs exit: $?"`
Expected: `mix docs exit: 0`.

Run: `grep -inE "warning" "${TMPDIR:-/tmp}/normandy-docs.log" | grep -iE "hook|HookHaltError" || echo "no hook doc warnings"`
Expected: `no hook doc warnings`. Fix any reference a warning names.

Run: `mix format && mix test`
Expected: output contains ` 0 failures`.

- [ ] **Step 5: Commit**

Run `mix precommit`; proceed only if its output contains ` 0 failures`.

```bash
git add docs/guides/hooks.md test/hooks/guide_examples_test.exs mix.exs MIGRATING-2.0.md CLAUDE.md lib/normandy/agents/turn/inline.ex
git commit -m "docs(hooks): hooks guide with compiled examples, migration notes, architecture entry"
```

---

## Appendix: Audit dispositions

The five audits of the first draft (2026-10-03): `correctness`, `design`, `ergonomics`,
`maintainability`, `performance`. Each finding is **applied** (where), **deferred** (why;
listed in the spec's Out of scope) or **rejected** (why). `design#U1–U5` are the five
unnumbered bullets under that audit's "Left undefined in the spec".

| Finding | Disposition |
|---|---|
| correctness#1 | Applied: `Config.hooks` lands in Task 1; Runner tests use plain config maps. |
| correctness#2 | Applied: Task 1 regex names the full module (`Normandy\.Behaviours\.HooksTest\.OnlyTurnEnd`). |
| correctness#3 | Applied: admission catch-all → `{:handler_crashed, :admit, e}` (Task 6); logged-only events ignore returns (Task 2); every server-side hook call goes through `call_handler/3` (Tasks 7, 9, 10). |
| correctness#4 | Applied: admission runs before the repair, so interrupted results pass `after_tool` once per accepted turn; test in Task 10. |
| correctness#5 | Applied: `on_turn_end` runs after the run span closes (Task 7, function-level `catch`/`else`); ordering test. |
| correctness#6 | Applied: Review Focus 1 and Task 6 state the precise guarantee; a test pins the trusted schema-struct rewrite. |
| correctness#7 | Applied: documented (spec §8, guide, server moduledoc); test "injected nothing runs again" (Task 9). |
| correctness#8 | Applied: `{:inject, []}` injects nothing (Task 2). |
| correctness#9 | Applied: `[%ToolCall{input: seen}, _]` then `assert seen == %{}` (Task 5). |
| correctness#10 | Applied: renamed "the adapter neither merges nor drops consecutive user messages", built from `AgentMemory.history/1` (Task 8). |
| correctness#11 | Applied: `assert_receive` for every cross-process hook message; `assert_received` only where one sender orders it (stated in Task 10). |
| design#1 | Applied: spec §8 invariant; Tasks 6, 7, 9, 10. |
| design#2 | Applied: logged-only returns ignored (Task 2). |
| design#3 | Applied (Q decision 9): compactors report `meta.dropped`; the memory diff is gone (Tasks 3, 8). |
| design#4 | Applied in part: kept entries keep ids (Task 3), the Server stores memory ids (Task 4), at-least-once and dedup on entry id documented. Marking injected entries: deferred (needs an entry metadata field; a hook recognises its own texts). Compaction watermark: deferred (turn-state schema change). |
| design#5 | Applied: `Normandy.Hooks.Handlers.wrap/2` around any handler set (Task 8). |
| design#6 | Applied: an unloaded module raises in the Runner (Task 2); the Server checks hooks on every load, `:config` starts included (Task 5). |
| design#7 | Applied, variant (b) without a core change: every result passes the module `after_tool` once (Dispatch slot, Task 5; core-built results rewritten in the creating callback, Task 10); `Data.synthesized` removed; function `after_hooks` unchanged. |
| design#8 | Applied in part: session start leaves `init/1`, one joined entry (no partial write), crash → `:unavailable` (Task 9). Durable "started" marker and Horde concurrent first starts: deferred (need a store-level marker or compare-and-set). |
| design#9 | Applied in part: missing module / invalid opts → `{:invalid_hooks, …}` `:unavailable` (Task 5); deploy order and frozen templates documented (spec §2, guide). Resolving hooks from the node-local supplement: rejected (Q decision 3 persists them). |
| design#10 | Applied in part: both shells run `on_turn_end` outside the run span; Server reply sites added (rejected, crashed, persist failure); halt shapes normalized through `HookHaltError.outcome/1`; `:unavailable` and `terminate/3` documented. BaseAgent failure `turn_id`: deferred (needs a wrapping exception or process state). |
| design#11 | Applied (Q decision 11): `Context.config` removed (Task 1). |
| design#12 | Applied: precise Inline statement (spec §5, Inline moduledoc, guide). |
| design#U1 | Applied: moot without `config` in the context; the context fields are documented. |
| design#U2 | Applied: a rewrite may change type; it is validated again (Task 6, guide). |
| design#U3 | Applied: documented that the hook sees no memory; the Server's memory comes from the store, not `initial_memory`. |
| design#U4 | Applied: injections precede whichever LLM call follows compaction, forced-final included (spec §5). |
| design#U5 | Applied (Q decision 10): hooks run inline, no timeout; documented. |
| ergonomics#1 | Applied: logged-only returns ignored; `after_compact`/`on_session_start` ignore non-inject values (Task 2). |
| ergonomics#2 | Applied (Q decision 4): `on_prompt` after validation; the guide's example fails closed (Task 12). |
| ergonomics#3 | Applied: plain-data check at `BaseAgent.init/1`, refs and ports included (Tasks 1, 5); secrets guidance and "Reaching runtime resources" (guide). |
| ergonomics#4 | Applied: guide "Testing a hook"; the Runner documented as the testing entry point; `sink/0` pattern. |
| ergonomics#5 | Applied in part: `{:inject, []}`, `before_tool {:halt, String.t()}`, one return table. Rejected: `before_llm {:cont, _}` (the info is not rewritable, accepting it would suggest it is); bare `after_tool` result (every rewriting callback answers `{:cont, value}`); function-hook argument order (module callbacks take `ctx, opts` like other behaviours; the guide contrasts them). |
| ergonomics#6 | Applied: `use Normandy.Behaviours.Hooks` with compile-time arity raise and near-miss warning; wrong-arity check at validation; `validate_opts!` failures name the hook (Task 1). |
| ergonomics#7 | Applied: normalized halts and the full outcome table (spec §6, guide). |
| ergonomics#8 | Applied in part: crash logs at `:error` with the exception module and, for RuntimeError/ArgumentError, the message cut to 200 characters (Turn.Server's rule). Stacktraces and crash metadata on telemetry: deferred (can carry argument values; the log line suffices). |
| ergonomics#9 | Applied: `:closed` on `after_tool` replaces the result with an error result; per-event table (Task 2, guide). Warning when `:on_error` cannot apply to a module's callbacks: deferred (the table documents it). |
| ergonomics#10 | Applied: `event` added, `config` removed. BaseAgent failure `turn_id`: deferred (as design#10). |
| ergonomics#11 | Applied in part: "Module hooks and function hooks" guide section; a second DSL `hooks` raises (Task 11). Bare `Mod` entries: rejected (one entry shape keeps templates and validation simple; the error names the fix). Replacing declared hooks at `new/1`: deferred. |
| ergonomics#12 | Applied: labelling convention and "guardrails do not run on injections" (spec §7, guide). Structured injections: deferred. |
| maintainability#1 | Applied: `server_hooks_test.exs` defines its own `Resp` with `BaseIOSchema` (TurnConfig.Resp has none); the `:config`-start template question is settled in the plan (server.ex:265-270); no "adapt the fixture" text remains. |
| maintainability#2 | Applied: `BaseAgentGlue`, `ServerGlue`, `Hooks.Handlers`; `HookHaltError.outcome/1`; Runner API takes the config only. |
| maintainability#3 | Applied: each raise lands with its Server handling (Tasks 6, 8); no commit leaves a crashing path. |
| maintainability#4 | Applied: `pass_or_rewrite/2`, `run_entry`/`invoke_entry` split, no pipe into `case`, tagged chain payloads. |
| maintainability#5 | Applied: thin-start template test (Task 6), Server compaction test (Task 8), Server `before_llm` pass-through (Task 8), streaming `on_prompt` (Task 6), `fail_outcome/1` test (Task 7); DSL `validate_opts!` is covered by `BaseAgent.init/1`'s tests (`new/1` calls it). |
| maintainability#6 | Applied: passivation via `trap_exit` + link (no monitor race); `assert_receive` across processes; the 30 ms expiry justified as a lower bound. |
| maintainability#7 | Applied: `Data.synthesized` removed (Task 10). |
| maintainability#8 | Applied: `StubClient` instead of a duplicated `EchoClient`; `StreamingProbeClient` moved to support; Task 10 reuses `start_dangling_server/4`; the `retry_options` hedge removed (nil is the default, base_agent.ex:156). |
| maintainability#9 | Applied: spans asserted in mailbox order with event, hook and result. |
| maintainability#10 | Applied: `@optional_callbacks` derived from `@events`; drift tests for callbacks, Probe, Runner contracts, telemetry moduledoc, guide table. |
| maintainability#11 | Applied: guide examples compiled by a test; spec final before Task 1; `mix docs` step reports `mix docs`' own exit status. CLAUDE.md entry stays in Task 12 (deferred: one docs commit; moduledocs ship with each module). |
| maintainability#12 | Applied: the Runner never raises for `on_turn_end`; test "a crashing or contract-violating `on_turn_end` … failure still raises the original" (Task 7). |
| performance#1 | Applied: reply before `on_turn_end` (Task 7); test proves it. |
| performance#2 | Rejected (Q decision 10): no hook timeouts; documented. |
| performance#3 | Applied: session start after `init/1` (Task 9). |
| performance#4 | Deferred: `before_tool` stays serial in `Turn.Server` classify (the shape function hooks already have); documented. |
| performance#5 | Applied: the diff is gone; `dropped_entries/2` is one `MapSet` pass. |
| performance#6 | Applied: `hooks?/1`/`handles?/2` fast paths at every call site; `memory.head == nil` freshness check. |
| performance#7 | Applied: only entries exporting the callback run; adapters and handler wrappers are installed only when an entry exports the callback. |
| performance#8 | Applied in part: `tool_call_id`/`tool` span metadata. Per-entry `telemetry: false`: deferred. |
| performance#9 | Applied: `Data.synthesized` removed. |
| performance#10 | Applied: `on_turn_end` outside the run span (Task 7). |
| performance#11 | Deferred: rate-limited crash logs (a new mechanism; telemetry counts `:rescued`). |
| performance#12 | Applied: `Context.config` removed (nothing large to copy); `on_passivate` documented as inline (keep it fast). |
